import CoreModels
import Foundation
import GitKit
import Shell
import Synchronization
import TestSupport
import Testing

/// The branch of most tests: a name with a slash and non-ASCII letters, which git has to hand back unharmed.
private let branch = "feature/ünï"

@Suite(.timeLimit(.minutes(1))) struct GitReaderTests {
    // These run the real `git` in a `GitSandbox`, with a configuration that is the same on every machine. The suite
    // holds the sandbox, so its folder outlives every test.
    let sandbox: GitSandbox
    let reader: GitReader

    init() throws {
        sandbox = try GitSandbox()
        reader = GitReader(runner: sandbox.runner)
    }

    // MARK: Worktrees

    @Test func listsTheMainWorktreeAndALinkedOneOnAUnicodeBranch() async throws {
        let (repo, _) = try await sandbox.makeRepository()
        let linked = try await sandbox.addWorktree(of: repo, branch: branch, in: "worktrees/feature wt")
        let head = try await sandbox.revision(in: repo)

        let list = try await reader.worktrees(repo: repo)

        #expect(
            list == [
                Worktree(path: sandbox.canonicalPath + "/repo", head: head, branch: "main", isMain: true),
                Worktree(path: sandbox.canonicalPath + "/worktrees/feature wt", head: head, branch: branch),
            ])
        #expect(try await reader.worktrees(repo: linked) == list)  // the same list from any of the worktrees
    }

    @Test func reportsALockAndWhoHoldsIt() async throws {
        let (repo, _) = try await sandbox.makeRepository()
        let linked = try await sandbox.addWorktree(of: repo, branch: branch, in: "worktrees/feature wt")
        let reason = "claude session ünï (pid 4242 start Fri Oct 30 14:39:21 2026)"

        try await sandbox.git(["worktree", "lock", "--reason", reason, linked.path], in: repo)
        let owned = WorktreeLock(reason: reason, ownerPID: 4242)
        #expect(try await reader.worktrees(repo: repo).map(\.lock) == [nil, owned])

        try await sandbox.git(["worktree", "unlock", linked.path], in: repo)
        try await sandbox.git(["worktree", "lock", linked.path], in: repo)  // no reason: still a lock
        #expect(try await reader.worktrees(repo: repo).map(\.lock) == [nil, WorktreeLock(reason: "", ownerPID: nil)])

        try await sandbox.git(["worktree", "unlock", linked.path], in: repo)
        #expect(try await reader.worktrees(repo: repo).map(\.lock) == [nil, nil])
    }

    @Test func reportsADetachedWorktree() async throws {
        let (repo, _) = try await sandbox.makeRepository()
        let head = try await sandbox.revision(in: repo)
        let detached = sandbox.url.appending(path: "worktrees/detached")
        try await sandbox.git(["worktree", "add", "--detach", detached.path], in: repo)

        let list = try await reader.worktrees(repo: repo)

        #expect(
            list.last
                == Worktree(
                    path: sandbox.canonicalPath + "/worktrees/detached", head: head, branch: nil, isDetached: true))
    }

    @Test func reportsAWorktreeWhoseFolderIsGoneAsPrunable() async throws {
        let (repo, _) = try await sandbox.makeRepository()
        let linked = try await sandbox.addWorktree(of: repo, branch: branch, in: "worktrees/feature wt")
        try FileManager.default.removeItem(at: linked)

        let list = try await reader.worktrees(repo: repo)

        #expect(list.map(\.isPrunable) == [false, true])
        #expect(list.last?.branch == branch)
        // There is no folder to resolve the path against, so it stays as git printed it.
        #expect(list.last?.path == sandbox.canonicalPath + "/worktrees/feature wt")
    }

    @Test func returnsThePathsOfTheWorktreesInCanonicalForm() async throws {
        // Git prints physical paths. Whatever else it prints is made one: /var is a link to /private/var. A folder
        // that is gone cannot be resolved, so its path stays as it is.
        let porcelain = """
            worktree /var/
            HEAD 1
            branch refs/heads/a

            worktree /no/such/folder
            HEAD 2
            detached
            prunable gitdir file points to non-existent location

            """
        let reader = GitReader(runner: StubRunner(result: CommandResult(exitCode: 0, stdout: porcelain, stderr: "")))

        let list = try await reader.worktrees(repo: URL(filePath: "/anywhere"))

        #expect(list.map(\.path) == ["/private/var", "/no/such/folder"])
    }

    @Test func aRepositoryWithoutCommitsHasAWorktreeWithoutAHead() async throws {
        let repo = try await sandbox.initRepository(named: "fresh")

        let list = try await reader.worktrees(repo: repo)

        #expect(list == [Worktree(path: sandbox.canonicalPath + "/fresh", head: nil, branch: "main", isMain: true)])
    }

    // MARK: Status

    @Test func countsAnUnpushedCommitAsAhead() async throws {
        let (_, _, worktree) = try await makePushedWorktree()
        try await sandbox.commit("one", in: worktree)

        let status = try await reader.status(worktree: worktree)

        #expect(status.upstream == "origin/\(branch)")
        #expect(status.ahead == 1 && status.behind == 0)
        #expect(!status.upstreamGone)
        #expect(status.modified == 0 && status.untracked == 0)
    }

    @Test func countsACommitOfSomebodyElseAsBehind() async throws {
        let (repo, remote, worktree) = try await makePushedWorktree()
        let other = try await sandbox.clone(remote, named: "other")
        try await sandbox.git(["switch", branch], in: other)
        try await sandbox.commit("from somebody else", in: other)
        try await sandbox.git(["push"], in: other)

        // Until it is fetched, the clone does not know.
        #expect(try await reader.status(worktree: worktree).behind == 0)
        try await reader.fetchPrune(repo: repo)

        let status = try await reader.status(worktree: worktree)
        #expect(status.behind == 1 && status.ahead == 0)
    }

    @Test func reportsAGoneUpstreamOnceItsRemoteBranchIsDeletedAndPruned() async throws {
        let (repo, remote, worktree) = try await makePushedWorktree()
        try await sandbox.git(["branch", "--delete", "--force", branch], in: remote)

        // Nothing has been fetched yet: as far as the clone knows, the branch is still there.
        #expect(try await reader.status(worktree: worktree).upstreamGone == false)
        try await reader.fetchPrune(repo: repo)

        let status = try await reader.status(worktree: worktree)
        #expect(status.upstreamGone)
        #expect(status.upstream == "origin/\(branch)")
        #expect(status.ahead == 0 && status.behind == 0)
    }

    @Test(arguments: [
        "",  // what a crash leaves behind: a ref file with nothing in it
        "this is not a hash",
    ])
    func aDamagedBranchRefMakesTheStatusAnError(contents: String) async throws {
        // Git exits with 0 and says `(initial)` for the commit, as it does for a branch that has none, but `(unknown)`
        // for the branch. Read as a branch without commits, the status would be: no upstream, nothing ahead, no date.
        // That is not what a branch that has commits, and an upstream, has.
        let (repo, _) = try await sandbox.makeRepository()
        try await sandbox.commit("two", in: repo)
        try sandbox.write(contents, to: ".git/refs/heads/main", in: repo)

        let error = await #expect(throws: GitError.self) { try await reader.status(worktree: repo) }

        guard case .unexpectedOutput(let command, let output)? = error else {
            Issue.record("expected a GitError.unexpectedOutput, got \(String(describing: error))")
            return
        }
        #expect(command.contains("git") && command.contains("status") && command.contains(repo.path))
        #expect(output == "# branch.head (unknown)")
    }

    @Test func aBranchRefToAMissingCommitMakesTheStatusAnError() async throws {
        // Git itself fails here (exit 128), so there is no value to read wrongly. This pins that it stays an error.
        let repo = try await sandbox.initRepository(named: "damaged")
        try await sandbox.commit("one", in: repo)
        try sandbox.write(String(repeating: "1", count: 40), to: ".git/refs/heads/main", in: repo)

        await expectFailure { _ = try await reader.status(worktree: repo) }
    }

    @Test func aBranchThatDoesNotExistYetHasAStatusWithoutADate() async throws {
        // Unlike a damaged ref it is a state that git names: `(initial)`, and the name of the branch to be.
        let fresh = try await sandbox.initRepository(named: "fresh")
        try sandbox.write("loose\n", to: "notes.txt", in: fresh)
        let (repo, _) = try await sandbox.makeRepository()
        let orphan = sandbox.url.appending(path: "worktrees/orphan")
        try await sandbox.git(["worktree", "add", "--orphan", "-b", "orphan", orphan.path], in: repo)

        #expect(try await reader.status(worktree: fresh) == WorktreeStatus(untracked: 1))
        #expect(try await reader.status(worktree: orphan) == WorktreeStatus())
    }

    @Test func aBranchThatTracksNothingHasNoUpstream() async throws {
        let (repo, _) = try await sandbox.makeRepository()
        let worktree = try await sandbox.addWorktree(of: repo, branch: "local", in: "worktrees/local", from: "main")
        let date = try await commitDate(in: worktree)

        let status = try await reader.status(worktree: worktree)

        #expect(status == WorktreeStatus(lastCommitDate: date))
    }

    @Test func countsChangedAndUntrackedFiles() async throws {
        let (_, _, worktree) = try await makePushedWorktree()
        try sandbox.write("changed\n", to: "README.md", in: worktree)  // a tracked file, modified
        try sandbox.write("new\n", to: "staged.txt", in: worktree)
        try await sandbox.git(["add", "staged.txt"], in: worktree)  // a new file, staged
        try sandbox.write("loose\n", to: "notes.txt", in: worktree)  // untracked

        let status = try await reader.status(worktree: worktree)

        #expect(status.modified == 2 && status.untracked == 1)
    }

    @Test func aFolderOfUntrackedFilesCountsOnce() async throws {
        let (_, _, worktree) = try await makePushedWorktree()
        try sandbox.write("a\n", to: "scratch/a.txt", in: worktree)
        try sandbox.write("b\n", to: "scratch/b.txt", in: worktree)

        #expect(try await reader.status(worktree: worktree).untracked == 1)
    }

    @Test func workInASubmoduleCountsWhateverTheRepositorySays() async throws {
        // A project can tell git to leave a submodule out of its status (`submodule.<name>.ignore`). Work in the
        // submodule is still work, and the worktree is not clean.
        let (repo, _) = try await sandbox.makeRepository()
        let inner = try await sandbox.initRepository(named: "inner")
        try await sandbox.commit("Inner", in: inner)
        try await sandbox.git(["-c", "protocol.file.allow=always", "submodule", "add", inner.path, "sub"], in: repo)
        try await sandbox.git(["commit", "--message", "Add a submodule"], in: repo)
        try await sandbox.git(["config", "submodule.sub.ignore", "all"], in: repo)
        try sandbox.write("work\n", to: "sub/notes.txt", in: repo)

        #expect(try await reader.status(worktree: repo).modified == 1)
    }

    @Test func anUntrackedFileCountsWhateverTheGitConfigurationSays() async throws {
        // `status.showUntrackedFiles` is a setting that people have in their ~/.gitconfig. It must not make a worktree
        // that holds work look clean.
        let (repo, _, worktree) = try await makePushedWorktree()
        try await sandbox.git(["config", "status.showUntrackedFiles", "no"], in: repo)
        try sandbox.write("loose\n", to: "notes.txt", in: worktree)

        #expect(try await reader.status(worktree: worktree).untracked == 1)
    }

    @Test func reportsTheCommitDateOfTheCheckedOutCommit() async throws {
        let (_, _, worktree) = try await makePushedWorktree()
        // The committer date counts, not the author date, and not the time of the test.
        let environment = ["GIT_AUTHOR_DATE": "1000000000 +0000", "GIT_COMMITTER_DATE": "1793361600 +0000"]
        try await sandbox.git(
            ["commit", "--allow-empty", "--message", "dated"], in: worktree, environment: environment)

        let status = try await reader.status(worktree: worktree)

        #expect(status.lastCommitDate == Date(timeIntervalSince1970: 1_793_361_600))
    }

    @Test func aBranchWithoutCommitsHasNoCommitDateAndNothingToLose() async throws {
        let repo = try await sandbox.initRepository(named: "fresh")
        try sandbox.write("loose\n", to: "notes.txt", in: repo)

        #expect(try await reader.status(worktree: repo) == WorktreeStatus(untracked: 1))
        #expect(try await reader.commitsNotOnAnyRemote(worktree: repo) == 0)
        #expect(try await reader.stashCount(repo: repo, branch: "main") == 0)
        try await reader.fetchPrune(repo: repo)  // no remote to fetch from is no failure
    }

    @Test func readingTheStatusLeavesTheIndexAlone() async throws {
        let (repo, _) = try await sandbox.makeRepository()
        let index = repo.appending(path: ".git/index")
        try await sandbox.git(["status"], in: repo)  // the index is up to date now
        let before = try Data(contentsOf: index)
        // The same content with a new modification time. What the index remembers of the file is out of date, and git
        // would write a new index to bring it up to date. That is a lock on the user's repository.
        let readme = repo.appending(path: "README.md").path
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(60)], ofItemAtPath: readme)

        _ = try await reader.status(worktree: repo)
        let afterReading = try Data(contentsOf: index)
        try await sandbox.git(["status"], in: repo)
        let afterPlainStatus = try Data(contentsOf: index)

        #expect(afterReading == before)
        #expect(afterPlainStatus != before)  // so the check above would have caught a status that writes
    }

    // MARK: Stashes

    @Test func countsTheStashesOfOneBranch() async throws {
        let (repo, _, worktree) = try await makePushedWorktree()
        try sandbox.write("one\n", to: "README.md", in: worktree)
        try await sandbox.git(["stash"], in: worktree)  // WIP on feature/ünï: …
        #expect(try await reader.stashCount(repo: repo, branch: branch) == 1)

        try sandbox.write("two\n", to: "README.md", in: worktree)
        try await sandbox.git(["stash", "push", "--message", "keep this"], in: worktree)  // On feature/ünï: keep this
        try sandbox.write("three\n", to: "README.md", in: repo)
        try await sandbox.git(["stash"], in: repo)  // on main

        #expect(try await reader.stashCount(repo: repo, branch: branch) == 2)
        #expect(try await reader.stashCount(repo: repo, branch: "main") == 1)
        #expect(try await reader.stashCount(repo: repo, branch: "feature") == 0)
    }

    @Test func aRepositoryWithoutStashesHasNone() async throws {
        let (repo, _) = try await sandbox.makeRepository()

        #expect(try await reader.stashCount(repo: repo, branch: "main") == 0)
    }

    // MARK: Remotes

    @Test func listsTheRemotesWithTheirFetchURLs() async throws {
        let (repo, _) = try await sandbox.makeRepository()
        try await sandbox.git(["remote", "add", "upstream", "git@gitlab.example.com:group/project.git"], in: repo)
        try await sandbox.git(
            ["remote", "set-url", "--push", "upstream", "ssh://git@push.example.com/project.git"], in: repo)
        let origin = try await sandbox.git(["config", "remote.origin.url"], in: repo).stdout
            .trimmingCharacters(in: .whitespacesAndNewlines)

        let remotes = try await reader.remotes(repo: repo)

        #expect(origin.contains("My Projects"))  // a URL with a space in it
        #expect(
            remotes == [
                Remote(name: "origin", url: origin),
                Remote(name: "upstream", url: "git@gitlab.example.com:group/project.git"),
            ])
    }

    @Test func aRepositoryWithoutRemotesHasNone() async throws {
        let repo = try await sandbox.initRepository(named: "solo")

        #expect(try await reader.remotes(repo: repo).isEmpty)
    }

    // MARK: Commits that are not on a remote

    @Test func countsTheCommitsOfABranchWithoutUpstreamThatNoRemoteHas() async throws {
        let (repo, _) = try await sandbox.makeRepository()
        let second = try await sandbox.makeRemote(named: "second.git")
        try await sandbox.git(["remote", "add", "second", second.path], in: repo)
        // Started at the local main, so that the branch tracks nothing.
        let worktree = try await sandbox.addWorktree(of: repo, branch: "local", in: "worktrees/local", from: "main")
        try await sandbox.commit("one", in: worktree)
        try await sandbox.commit("two", in: worktree)

        // The commit it was started at is on origin/main, so it does not count.
        #expect(try await reader.commitsNotOnAnyRemote(worktree: worktree) == 2)

        try await sandbox.git(["push", "second", "local"], in: worktree)  // any remote will do
        #expect(try await reader.commitsNotOnAnyRemote(worktree: worktree) == 0)
    }

    @Test func aRepositoryWithoutRemotesHasAllItsCommitsOffTheRemote() async throws {
        let repo = try await sandbox.initRepository(named: "solo")
        try await sandbox.commit("one", in: repo)
        try await sandbox.commit("two", in: repo)

        #expect(try await reader.commitsNotOnAnyRemote(worktree: repo) == 2)
    }

    @Test func aHeadThatNamesAMissingCommitIsNoBranchWithoutCommits() async throws {
        // A damaged repository: HEAD names a commit that is not there. That is not a branch with no commit, and a count
        // of none would be a guess.
        let repo = try await sandbox.initRepository(named: "damaged")
        try await sandbox.commit("one", in: repo)
        try sandbox.write(String(repeating: "1", count: 40) + "\n", to: ".git/HEAD", in: repo)

        await expectFailure { _ = try await reader.commitsNotOnAnyRemote(worktree: repo) }
    }

    @Test(arguments: [
        "",  // what a crash leaves behind: a ref file with nothing in it
        "this is not a hash",
        "1111111111111111111111111111111111111111",  // a commit that is not there
    ])
    func aDamagedBranchRefIsNoBranchWithoutCommits(contents: String) async throws {
        // The branch has two commits. Git cannot read them through the ref, and `git rev-list HEAD` fails, as it does
        // for a branch that has none yet. `rev-parse --verify --quiet HEAD` exits with 1 for an empty ref and for a
        // branch that does not exist, so it cannot tell them apart. A count of none here would be a guess.
        let repo = try await sandbox.initRepository(named: "damaged")
        try await sandbox.commit("one", in: repo)
        try await sandbox.commit("two", in: repo)
        try sandbox.write(contents, to: ".git/refs/heads/main", in: repo)

        await expectFailure { _ = try await reader.commitsNotOnAnyRemote(worktree: repo) }
    }

    @Test func aBranchThatDoesNotExistYetHasNoCommitsToLose() async throws {
        let repo = try await sandbox.initRepository(named: "fresh")

        #expect(try await reader.commitsNotOnAnyRemote(worktree: repo) == 0)
    }

    @Test func aWorktreeOnAnOrphanBranchHasNoCommitsToLose() async throws {
        // HEAD of a linked worktree is its own, and the branch that it names does not exist until the first commit.
        let (repo, _) = try await sandbox.makeRepository()
        let orphan = sandbox.url.appending(path: "worktrees/orphan")
        try await sandbox.git(["worktree", "add", "--orphan", "-b", "orphan", orphan.path], in: repo)

        #expect(try await reader.commitsNotOnAnyRemote(worktree: orphan) == 0)
    }

    // MARK: Ancestry

    @Test func tellsWhetherACommitIsAnAncestorOfAnother() async throws {
        let (repo, _, worktree) = try await makePushedWorktree()
        let base = try await sandbox.revision(in: repo)
        let tip = try await sandbox.commit("one", in: worktree)

        #expect(try await reader.isAncestorOrEqual(base, of: tip, repo: repo) == true)
        #expect(try await reader.isAncestorOrEqual(tip, of: base, repo: repo) == false)
        #expect(try await reader.isAncestorOrEqual(tip, of: tip, repo: repo) == true)
    }

    @Test func saysNothingWhenTheOtherCommitIsNotInTheRepository() async throws {
        let (repo, _) = try await sandbox.makeRepository()
        let head = try await sandbox.revision(in: repo)
        let unknown = String(repeating: "1", count: 40)

        #expect(try await reader.isAncestorOrEqual(head, of: unknown, repo: repo) == nil)
    }

    // MARK: Failures

    @Test func failuresAreThrownNotTurnedIntoEmptyAnswers() async throws {
        let nowhere = sandbox.url  // a folder, but no repository
        let sha = String(repeating: "1", count: 40)

        await expectFailure { _ = try await reader.worktrees(repo: nowhere) }
        await expectFailure { _ = try await reader.status(worktree: nowhere) }
        await expectFailure { _ = try await reader.stashCount(repo: nowhere, branch: "main") }
        await expectFailure { _ = try await reader.remotes(repo: nowhere) }
        await expectFailure { _ = try await reader.commitsNotOnAnyRemote(worktree: nowhere) }
        await expectFailure { _ = try await reader.isAncestorOrEqual(sha, of: sha, repo: nowhere) }
        await expectFailure { try await reader.fetchPrune(repo: nowhere) }
    }

    @Test func aFolderThatIsNotThereIsAFailureToo() async throws {
        let gone = sandbox.url.appending(path: "no such folder")

        await expectFailure { _ = try await reader.status(worktree: gone) }
    }

    @Test func aFailureSaysWhatWasRunAndWhatGitSaid() async throws {
        let error = await #expect(throws: GitError.self) { try await reader.status(worktree: sandbox.url) }

        guard case .failed(let command, let exitCode, let stderr)? = error else {
            Issue.record("expected a GitError.failed, got \(String(describing: error))")
            return
        }
        #expect(command.contains("git") && command.contains("status") && command.contains(sandbox.url.path))
        #expect(exitCode == 128)
        #expect(stderr.contains("fatal") && !stderr.hasSuffix("\n"))
        #expect(error?.errorDescription?.contains("128") == true)
        #expect(error?.errorDescription?.contains(stderr) == true)
    }

    @Test func fetchPruneFailsWhenTheRemoteCannotBeReached() async throws {
        let (repo, remote) = try await sandbox.makeRepository()
        try FileManager.default.removeItem(at: remote)

        await expectFailure { try await reader.fetchPrune(repo: repo) }
    }

    @Test func aCountThatIsNotANumberIsAnErrorNotZero() async throws {
        let reader = GitReader(runner: StubRunner(result: CommandResult(exitCode: 0, stdout: "many\n", stderr: "")))

        let error = await #expect(throws: GitError.self) {
            try await reader.commitsNotOnAnyRemote(worktree: URL(filePath: "/anywhere"))
        }

        guard case .unexpectedOutput(_, let output)? = error else {
            Issue.record("expected a GitError.unexpectedOutput, got \(String(describing: error))")
            return
        }
        #expect(output == "many")
    }

    // MARK: Read-only

    @Test func everyCommandThatOnlyReadsKeepsGitFromTakingOptionalLocks() async throws {
        let recorder = RecordingRunner()
        let reader = GitReader(runner: recorder)
        let folder = URL(filePath: "/anywhere")

        _ = try? await reader.worktrees(repo: folder)
        _ = try? await reader.status(worktree: folder)
        _ = try? await reader.stashCount(repo: folder, branch: "main")
        _ = try? await reader.remotes(repo: folder)
        _ = try? await reader.commitsNotOnAnyRemote(worktree: folder)
        _ = try? await reader.isAncestorOrEqual("a", of: "b", repo: folder)
        try await reader.fetchPrune(repo: folder)

        let calls = recorder.calls
        let fetches = calls.filter { $0.contains("fetch") }
        let reads = calls.filter { !$0.contains("fetch") }
        #expect(fetches.count == 1 && reads.count > 1, "\(calls)")
        #expect(reads.allSatisfy { $0.first == "--no-optional-locks" }, "\(calls)")
        // Fetching is not reading: it writes to the repository, and has no reason to give up a lock it needs.
        #expect(fetches.allSatisfy { !$0.contains("--no-optional-locks") }, "\(calls)")
    }

    // MARK: Helpers

    /// A repository with a remote, and a worktree on `feature/ünï` whose branch is pushed and tracks its remote branch.
    private func makePushedWorktree() async throws -> (repo: URL, remote: URL, worktree: URL) {
        let (repo, remote) = try await sandbox.makeRepository()
        let worktree = try await sandbox.addWorktree(of: repo, branch: branch, in: "worktrees/feature wt")
        try await sandbox.git(["push", "--set-upstream", "origin", branch], in: worktree)
        return (repo, remote, worktree)
    }

    /// When the commit that is checked out in `directory` was made, from git's own answer.
    private func commitDate(in directory: URL) async throws -> Date {
        let seconds = try await sandbox.git(["log", "-1", "--format=%ct"], in: directory).stdout
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return Date(timeIntervalSince1970: try #require(TimeInterval(seconds)))
    }

    private func expectFailure(
        _ operation: @Sendable () async throws -> Void, sourceLocation: SourceLocation = #_sourceLocation
    ) async {
        let error = await #expect(throws: GitError.self, sourceLocation: sourceLocation) { try await operation() }
        guard case .failed(_, let exitCode, let stderr)? = error else {
            Issue.record("expected a GitError.failed, got \(String(describing: error))", sourceLocation: sourceLocation)
            return
        }
        #expect(exitCode != 0 && !stderr.isEmpty, sourceLocation: sourceLocation)
    }
}

/// Answers every command with `result`.
private struct StubRunner: CommandRunning {
    let result: CommandResult

    func run(_ tool: String, _ args: [String], in directory: URL?, timeout: Duration) async throws -> CommandResult {
        result
    }

    func which(_ tool: String) -> URL? { nil }
}

/// Answers every command with success and keeps the arguments of each.
private final class RecordingRunner: CommandRunning {
    private let recorded = Mutex<[[String]]>([])

    var calls: [[String]] { recorded.withLock { $0 } }

    func run(_ tool: String, _ args: [String], in directory: URL?, timeout: Duration) async throws -> CommandResult {
        recorded.withLock { $0.append(args) }
        return CommandResult(exitCode: 0, stdout: "0\n", stderr: "")
    }

    func which(_ tool: String) -> URL? { nil }
}
