import CoreModels
import Foundation
import GitKit
import ProcessKit
import Safety
import Shell
import Synchronization
import TestSupport
import Testing

/// These run the real `git` in a `GitSandbox`, and stop real processes. The suite holds the sandbox, so its folder
/// outlives every test; every process that a test starts is killed again by the test.
///
/// The tests of this suite and of the suites in it run one after the other. Each of them runs a dozen git commands,
/// and run side by side they once left so little of the machine to the other suites that two tests with a deadline of
/// 200 ms, in `HostingTests`, failed in one run in four.
@Suite(.serialized, .timeLimit(.minutes(1))) struct WorktreeRemoverTests {
    let sandbox: GitSandbox
    let remover: WorktreeRemover

    init() throws {
        sandbox = try GitSandbox()
        remover = sandbox.makeRemover()
    }

    // MARK: Removing

    @Test func removesCleanWorktreeWithIgnoredTmpAndNestedRepo() async throws {
        let scene = try await sandbox.makeRemovalScene()
        // The folder that a ticket leaves in every worktree: ignored by git, with a clone of another repository in it.
        try sandbox.write("brief\n", to: "tmp/PYMEP-1/brief.md", in: scene.folder)
        try sandbox.write("syntax = \"proto3\";\n", to: "tmp/protos/api.proto", in: scene.folder)
        let protos = scene.folder.appending(path: "tmp/protos")
        try await sandbox.git(["init"], in: protos)
        try await sandbox.git(["add", "."], in: protos)
        try await sandbox.git(["commit", "--message", "protos"], in: protos)
        #expect(try await sandbox.git(["status", "--porcelain"], in: scene.folder).stdout.isEmpty)  // clean, for git

        try await remover.remove(try await scene.request(), recheck: stillReady)

        #expect(!scene.folderExists)
        #expect(try await sandbox.git(["branch", "--list", removalBranch], in: scene.repo).stdout.isEmpty)
    }

    @Test func keepsBranchWhenAsked() async throws {
        let scene = try await sandbox.makeRemovalScene()

        try await remover.remove(try await scene.request(deleteBranch: false), recheck: stillReady)

        #expect(!scene.folderExists)
        #expect(try await scene.branchExists())
    }

    @Test func abortsWhenStateChanged() async throws {
        let scene = try await sandbox.makeRemovalScene()
        let request = try await scene.request()

        await #expect(throws: RemovalError.stateChanged(.blocked([.untracked(1)]))) {
            try await remover.remove(request, recheck: { .blocked([.untracked(1)]) })
        }

        #expect(scene.folderExists)
        #expect(try await scene.branchExists())
    }

    @Test func unlocksStaleClaudeLockAndRemoves() async throws {
        let scene = try await sandbox.makeRemovalScene()
        // No process has an id of 999999: macOS has no more than 99999.
        try await scene.lock(reason: "claude session x (pid 999999 start Fri Oct 30 14:39:21 2026)")
        let request = try await scene.request()
        #expect(request.worktree.lock?.ownerPID == 999_999)

        try await remover.remove(request, recheck: stillReady)

        #expect(!scene.folderExists)
        #expect(try await !scene.branchExists())
    }

    @Test func stopsProcessesBeforeRemoving() async throws {
        let scene = try await sandbox.makeRemovalScene()
        let sleeper = try spawn("/bin/sleep", ["30"], cwd: scene.folder)
        defer { sleeper.killWithoutWaiting() }
        let pid = sleeper.processIdentifier
        let group = processGroup(try liveRecord(of: pid))
        let seenAlive = Recorder<Bool>()

        try await remover.remove(
            try await scene.request(stopping: [group]),
            recheck: {
                seenAlive.append(ProcessSignaler().isAlive(pid))
                return .ready(needsStopping: false)
            })

        #expect(seenAlive.all == [false])  // it was stopped by the time that the state was looked at again
        #expect(!ProcessSignaler().isAlive(pid))
        #expect(!scene.folderExists)
    }

    @Test func reportsGitRefusal() async throws {
        let scene = try await sandbox.makeRemovalScene()
        try sandbox.write("changed\n", to: "README.md", in: scene.folder)  // a tracked file, modified

        let message = await refusalMessage(of: try await scene.request())  // the recheck says ready all the same

        #expect(message?.isEmpty == false)
        #expect(scene.folderExists)
        #expect(try String(contentsOf: scene.folder.appending(path: "README.md"), encoding: .utf8) == "changed\n")
        #expect(try await scene.branchExists())
    }

    @Test func prunesMissingWorktree() async throws {
        let scene = try await sandbox.makeRemovalScene()
        try FileManager.default.removeItem(at: scene.folder)  // by hand
        #expect(try await scene.listedPaths().contains(scene.path))  // git still lists it

        try await remover.prune(repo: scene.repo)

        #expect(try await !scene.listedPaths().contains(scene.path))
        #expect(try await scene.branchExists())  // the branch may hold commits that no remote has: pruning keeps it
    }

    // MARK: What the user confirmed (Ruling 57)

    @Test func aWorktreeConfirmedAsReadyIsLeftAloneWhenTheRecheckSaysManual() async throws {
        // The user removed it as merged, perhaps without a sheet ("Don't ask again"); by the time of the recheck the
        // host no longer says merged, or cannot be asked. Nobody confirmed removing a worktree whose request is not
        // merged.
        let scene = try await sandbox.makeRemovalScene()
        let request = try await scene.request(confirmedAs: .ready)
        let runner = WatchedRunner(wrapping: sandbox.runner)

        await #expect(throws: RemovalError.stateChanged(.manual(needsStopping: false))) {
            try await sandbox.makeRemover(through: runner).remove(
                request, recheck: { .manual(needsStopping: false) })
        }

        #expect(runner.calls.isEmpty)  // not a single git command
        #expect(scene.folderExists)
        #expect(try await scene.branchExists())
    }

    @Test func aWorktreeConfirmedAsManualIsRemovedWhenTheRecheckSaysManual() async throws {
        let scene = try await sandbox.makeRemovalScene()

        try await remover.remove(
            try await scene.request(confirmedAs: .manual), recheck: { .manual(needsStopping: false) })

        #expect(!scene.folderExists)
        #expect(try await !scene.branchExists())
    }

    @Test func aWorktreeConfirmedAsManualIsRemovedWhenItHasBeenMergedSince() async throws {
        let scene = try await sandbox.makeRemovalScene()

        try await remover.remove(try await scene.request(confirmedAs: .manual), recheck: stillReady)

        #expect(!scene.folderExists)
        #expect(try await !scene.branchExists())
    }

    @Test func aWorktreeConfirmedAsManualIsLeftAloneWhenSomethingRunsAgain() async throws {
        let scene = try await sandbox.makeRemovalScene()
        let request = try await scene.request(confirmedAs: .manual)

        await #expect(throws: RemovalError.stateChanged(.manual(needsStopping: true))) {
            try await remover.remove(request, recheck: { .manual(needsStopping: true) })
        }

        #expect(scene.folderExists)
        #expect(try await scene.branchExists())
    }

    // MARK: What git is asked

    @Test func anUntrackedFileStopsTheRemovalWhateverTheGitConfigurationSays() async throws {
        // `status.showUntrackedFiles=no` is a setting that people have in their ~/.gitconfig. With it, a plain
        // `git worktree remove` takes a worktree that holds untracked files for a clean one, and deletes it.
        let scene = try await sandbox.makeRemovalScene()
        try await sandbox.git(["config", "status.showUntrackedFiles", "no"], in: scene.repo)
        try sandbox.write("loose\n", to: "notes.txt", in: scene.folder)
        #expect(try await sandbox.git(["status", "--porcelain"], in: scene.folder).stdout.isEmpty)  // git does not say

        let message = await refusalMessage(of: try await scene.request())

        #expect(message?.isEmpty == false)
        #expect(FileManager.default.fileExists(atPath: scene.folder.appending(path: "notes.txt").path))
    }

    @Test func runsGitOnTheRepositoryInTheOrderOfTheSpecAndNeverForces() async throws {
        let scene = try await sandbox.makeRemovalScene()
        try await scene.lock(reason: "claude session x (pid 999999 start Fri Oct 30 14:39:21 2026)")
        let request = try await scene.request()
        let runner = WatchedRunner(wrapping: sandbox.runner)

        try await sandbox.makeRemover(through: runner).remove(request, recheck: stillReady)

        let calls = runner.calls
        #expect(
            calls.map(\.subcommand) == [
                ["worktree", "list", "--porcelain"],  // the worktree as it is now
                ["ls-files", "-v", "-z"],  // the work in it that git does not show
                ["worktree", "unlock", "--", scene.path],
                ["worktree", "remove", "--", scene.path],
                ["rev-parse", "--verify", "--quiet", "--end-of-options", "refs/heads/\(removalBranch)"],
                ["branch", "-D", "--", removalBranch],
            ])
        for call in calls {
            // git -C <repo>, except for the one command that reads the index of the worktree itself
            let folder = call.subcommand.first == "ls-files" ? scene.path : scene.repo.path
            let option = call.args.firstIndex(of: "-C")
            #expect(option.map { call.args[$0 + 1] } == folder, "\(call.args)")
        }
        #expect(!calls.flatMap(\.args).contains { $0 == "--force" || $0 == "-f" })
        // The removal asks for untracked files itself, whatever the configuration of the user says.
        let removal = try #require(calls.first { $0.subcommand.starts(with: ["worktree", "remove"]) })
        #expect(removal.args.starts(with: ["-c", "status.showUntrackedFiles=normal", "-C"]))
    }

    @Test func aRefusedRemovalNeverGetsToTheBranch() async throws {
        let scene = try await sandbox.makeRemovalScene()
        try sandbox.write("changed\n", to: "README.md", in: scene.folder)
        let runner = WatchedRunner(wrapping: sandbox.runner)

        _ = await refusalMessage(of: try await scene.request(), using: sandbox.makeRemover(through: runner))

        #expect(runner.writes == [["worktree", "remove", "--", scene.path]])  // the removal, and nothing after it
    }

    // MARK: The branch

    @Test func aBranchThatCannotBeDeletedIsReportedOnceTheFolderIsGone() async throws {
        let scene = try await sandbox.makeRemovalScene()
        // The branch is checked out in a second worktree, which git allows only when it is told to.
        let second = sandbox.url.appending(path: "worktrees/second wt")
        try await sandbox.git(["worktree", "add", "--force", second.path, removalBranch], in: scene.repo)
        let request = try await scene.request()

        let error = await #expect(throws: RemovalError.self) {
            try await remover.remove(request, recheck: stillReady)
        }

        guard case .branchNotDeleted(let message)? = error else {
            Issue.record("expected RemovalError.branchNotDeleted, got \(String(describing: error))")
            return
        }
        #expect(message.contains(removalBranch))
        #expect(!scene.folderExists)  // reported, and not undone: the folder was removed
        #expect(try await scene.branchExists())
    }

    @Test func aDetachedWorktreeHasNoBranchToDelete() async throws {
        let scene = try await sandbox.makeRemovalScene(branch: nil)
        let runner = WatchedRunner(wrapping: sandbox.runner)

        let request = try await scene.request(deleteBranch: true)

        try await sandbox.makeRemover(through: runner).remove(request, recheck: stillReady)

        #expect(!scene.folderExists)
        #expect(runner.writes.map(\.first) == ["worktree"])  // the removal, and no branch to delete after it
        #expect(try await scene.branchExists("main"))
    }

    // MARK: What is never removed

    @Test func theMainWorktreeIsNeverRemovedAndNothingIsStoppedForIt() async throws {
        let scene = try await sandbox.makeRemovalScene()
        let main = try #require(try await GitReader(runner: sandbox.runner).worktrees(repo: scene.repo).first)
        #expect(main.isMain)
        let running = processRecord(4242)
        let signaler = ScriptedSignaler(alive: [4242])
        let runner = WatchedRunner(wrapping: sandbox.runner)
        let remover = WorktreeRemover(
            runner: runner, signaler: signaler, sampler: ScriptedSampler(always: [running]))
        let rechecks = Recorder<Void>()
        let request = RemovalRequest(
            repo: scene.repo, worktree: main, deleteBranch: true, stopGroups: [processGroup(running)],
            confirmedAs: .ready)

        await #expect(throws: RemovalError.stateChanged(.mainWorktree)) {
            try await remover.remove(
                request,
                recheck: {
                    rechecks.append(())
                    return await stillReady()
                })
        }

        // It is answered before anything is done: no process was signalled, git was not asked, nobody was asked again.
        #expect(signaler.sent.isEmpty && runner.calls.isEmpty && rechecks.all.isEmpty)
        #expect(FileManager.default.fileExists(atPath: scene.repo.appending(path: ".git").path))
    }

    @Test func aWorktreeWhoseFolderIsGoneIsNotRemovedAndItsBranchIsKept() async throws {
        let scene = try await sandbox.makeRemovalScene()
        try FileManager.default.removeItem(at: scene.folder)  // by hand
        let request = try await scene.request()
        #expect(request.worktree.isPrunable)
        let runner = WatchedRunner(wrapping: sandbox.runner)
        let remover = sandbox.makeRemover(through: runner)
        let rechecks = Recorder<Void>()

        await #expect(throws: RemovalError.stateChanged(.missing)) {
            try await remover.remove(
                request,
                recheck: {
                    rechecks.append(())
                    return await stillReady()  // wrong, and not even asked
                })
        }

        // Such a worktree is for `prune`, which keeps the branch. Its commits may be on no remote, and with no folder
        // to read the status from, nothing says that they are not.
        #expect(runner.calls.isEmpty && rechecks.all.isEmpty)
        #expect(try await scene.branchExists())
    }

    @Test func aFailedPruneIsReported() async throws {
        // A folder that is not there: no git can find a repository, a real one included, by looking above it.
        let nowhere = sandbox.url.appending(path: "no such folder")

        let error = await #expect(throws: RemovalError.self) { try await remover.prune(repo: nowhere) }

        guard case .gitRefused(let message)? = error else {
            Issue.record("expected RemovalError.gitRefused, got \(String(describing: error))")
            return
        }
        #expect(!message.isEmpty)
    }

    // MARK: Giving up

    @Test func aCallerThatGivesUpBeforeTheDeletionBeginsHasNothingDeleted() async throws {
        let scene = try await sandbox.makeRemovalScene()
        let request = try await scene.request()
        let remover = remover
        let caller = Task {
            try await remover.remove(
                request,
                recheck: {
                    withUnsafeCurrentTask { $0?.cancel() }  // the caller gives up while the state is looked at again
                    return .ready(needsStopping: false)
                })
        }

        await #expect(throws: CancellationError.self) { try await caller.value }

        #expect(scene.folderExists)
        #expect(try await scene.branchExists())
    }

    @Test func aCallerThatGivesUpDuringTheDeletionDoesNotInterruptGit() async throws {
        // Git that is asked to stop halfway through a folder leaves half of it behind, a worktree that is not clean.
        let scene = try await sandbox.makeRemovalScene()
        let request = try await scene.request()
        let handle = Mutex<Task<Void, any Error>?>(nil)
        let runner = WatchedRunner(wrapping: sandbox.runner) { args in
            if args.contains("remove") { handle.withLock { $0 }?.cancel() }  // the caller gives up as git is started
            return nil
        }
        let remover = sandbox.makeRemover(through: runner)
        let caller = Task {
            try await remover.remove(
                request,
                recheck: {
                    while handle.withLock({ $0 }) == nil { await Task.yield() }  // not before the test has the task
                    return .ready(needsStopping: false)
                })
        }
        handle.withLock { $0 = caller }

        try await caller.value

        #expect(!scene.folderExists)
        #expect(try await !scene.branchExists())
        #expect(runner.writes.count == 2)  // the removal, and the branch
        #expect(!runner.calls.isEmpty && runner.calls.allSatisfy { !$0.cancelled })
    }

    // MARK: Helpers

    /// What git said when it refused to remove the worktree of `request`, with a recheck that finds nothing wrong.
    private func refusalMessage(
        of request: RemovalRequest, using remover: WorktreeRemover? = nil,
        sourceLocation: SourceLocation = #_sourceLocation
    ) async -> String? {
        let remover = remover ?? self.remover
        let error = await #expect(throws: RemovalError.self, sourceLocation: sourceLocation) {
            try await remover.remove(request, recheck: stillReady)
        }
        guard case .gitRefused(let message)? = error else {
            Issue.record(
                "expected RemovalError.gitRefused, got \(String(describing: error))", sourceLocation: sourceLocation)
            return nil
        }
        return message
    }
}
