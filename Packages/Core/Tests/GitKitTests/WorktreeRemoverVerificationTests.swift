import CoreModels
import Foundation
import GitKit
import Safety
import Shell
import TestSupport
import Testing

extension WorktreeRemoverTests {
    /// A request is as old as the list it was made from, and git runs minutes later. What is unlocked and deleted is
    /// the worktree as it is then, so each of these changes the worktree after the request, and with real git.
    @Suite(.timeLimit(.minutes(1))) struct Verification {
        let sandbox: GitSandbox

        init() throws {
            sandbox = try GitSandbox()
        }

        enum Replacement: String, CaseIterable, Sendable {
            case handWritten
            case aLiveSession
        }

        @Test(arguments: Replacement.allCases)
        func aLockThatHasBeenReplacedIsNotTaken(replacement: Replacement) async throws {
            let scene = try await sandbox.makeRemovalScene()
            try await scene.lock(reason: "claude session x (pid 999999 start Fri Oct 30 14:39:21 2026)")
            // The owner of that lock is gone: it is stale, and may be taken off.
            let request = try await scene.request()
            let session = try spawn("/bin/sleep", ["30"])
            defer { session.killWithoutWaiting() }
            let reason =
                switch replacement {
                case .handWritten: "keep until the release"
                case .aLiveSession:
                    "claude session y (pid \(session.processIdentifier) start Fri Oct 30 15:00:00 2026)"
                }
            // Since then the stale lock has been taken off, and another put on, by somebody else.
            try await sandbox.git(["worktree", "unlock", scene.folder.path], in: scene.repo)
            try await scene.lock(reason: reason)
            let runner = WatchedRunner(wrapping: sandbox.runner)

            let error = await #expect(throws: RemovalError.self) {
                try await sandbox.makeRemover(through: runner).remove(request, recheck: stillReady)
            }

            #expect(error == .worktreeChanged)
            #expect(runner.writes.isEmpty)
            #expect(try await scene.worktree().lock?.reason == reason)  // as it was put: not unlocked
            #expect(scene.folderExists)
        }

        @Test func aWorktreeThatSwitchedBranchesKeepsItsOldBranch() async throws {
            let scene = try await sandbox.makeRemovalScene()
            let request = try await scene.request()
            try await sandbox.git(["switch", "--create", "other"], in: scene.folder)
            let runner = WatchedRunner(wrapping: sandbox.runner)

            let error = await #expect(throws: RemovalError.self) {
                try await sandbox.makeRemover(through: runner).remove(request, recheck: stillReady)
            }

            #expect(error == .worktreeChanged)
            #expect(runner.writes.isEmpty)
            #expect(try await scene.branchExists())  // the one that the request names: not what the folder is on
            #expect(try await scene.branchExists("other"))
            #expect(scene.folderExists)
        }

        @Test func aWorktreeThatMovedOnToAnotherCommitIsNotRemoved() async throws {
            let scene = try await sandbox.makeRemovalScene()
            let request = try await scene.request()
            try await sandbox.commit("work after the request", in: scene.folder)
            let runner = WatchedRunner(wrapping: sandbox.runner)

            let error = await #expect(throws: RemovalError.self) {
                try await sandbox.makeRemover(through: runner).remove(request, recheck: stillReady)
            }

            #expect(error == .worktreeChanged)
            #expect(runner.writes.isEmpty)
            #expect(scene.folderExists)
        }

        @Test func aLockedWorktreeWhoseFolderIsGoneIsNeitherUnlockedNorRemoved() async throws {
            let scene = try await sandbox.makeRemovalScene()
            let reason = "claude session x (pid 999999 start Fri Oct 30 14:39:21 2026)"
            try await scene.lock(reason: reason)
            let request = try await scene.request()
            try FileManager.default.removeItem(at: scene.folder)  // by hand
            // Git calls a worktree prunable when its folder is gone, but not one that is locked.
            #expect(try await scene.worktree().isPrunable == false)
            let runner = WatchedRunner(wrapping: sandbox.runner)

            let error = await #expect(throws: RemovalError.self) {
                try await sandbox.makeRemover(through: runner).remove(request, recheck: stillReady)
            }

            #expect(error == .stateChanged(.missing))
            #expect(runner.writes.isEmpty)
            #expect(try await scene.worktree().lock?.reason == reason)  // still locked
            #expect(try await scene.branchExists())  // and the branch kept: nothing says that its commits are saved
        }

        @Test func aWorktreeThatGitDoesNotListAnyMoreIsNotRemoved() async throws {
            let scene = try await sandbox.makeRemovalScene()
            let request = try await scene.request()
            try await sandbox.git(["worktree", "remove", scene.folder.path], in: scene.repo)  // by somebody else
            let runner = WatchedRunner(wrapping: sandbox.runner)

            let error = await #expect(throws: RemovalError.self) {
                try await sandbox.makeRemover(through: runner).remove(request, recheck: stillReady)
            }

            #expect(error == .worktreeChanged)
            #expect(runner.writes.isEmpty)
            #expect(try await scene.branchExists())
        }

        @Test func aRequestThatCallsTheMainWorktreeAnythingElseIsRefused() async throws {
            let scene = try await sandbox.makeRemovalScene()
            let main = try #require(try await GitReader(runner: sandbox.runner).worktrees(repo: scene.repo).first)
            let calledLinked = Worktree(path: main.path, head: main.head, branch: main.branch, isMain: false)
            let request = RemovalRequest(
                repo: scene.repo, worktree: calledLinked, deleteBranch: true, stopGroups: [], confirmedAs: .ready)
            let runner = WatchedRunner(wrapping: sandbox.runner)

            let error = await #expect(throws: RemovalError.self) {
                try await sandbox.makeRemover(through: runner).remove(request, recheck: stillReady)
            }

            #expect(error == .stateChanged(.mainWorktree))
            #expect(runner.writes.isEmpty)
            #expect(FileManager.default.fileExists(atPath: scene.repo.appending(path: ".git").path))
        }

        @Test func aBranchThatMovedWhileTheFolderWasBeingDeletedIsKept() async throws {
            // `git branch -D` drops the reflog of the branch with it: what the branch has gained since is not
            // recoverable.
            let scene = try await sandbox.makeRemovalScene()
            let request = try await scene.request()
            let elsewhere = try await sandbox.commit("a commit that the branch does not have", in: scene.repo)
            let sandbox = sandbox
            let runner = WatchedRunner(wrapping: sandbox.runner) { args in
                // As the branch is looked at, once the folder is gone, it is moved on, as a push from elsewhere would.
                if WatchedRunner.subcommand(of: args).first == "rev-parse" {
                    let move = ["update-ref", "refs/heads/\(removalBranch)", elsewhere]
                    _ = try? await sandbox.git(move, in: scene.repo)
                }
                return nil
            }

            let error = await #expect(throws: RemovalError.self) {
                try await sandbox.makeRemover(through: runner).remove(request, recheck: stillReady)
            }

            guard case .branchNotDeleted(let message)? = error else {
                Issue.record("expected RemovalError.branchNotDeleted, got \(String(describing: error))")
                return
            }
            #expect(message.contains(removalBranch) && message.contains(String(elsewhere.prefix(7))), "\(message)")
            #expect(!scene.folderExists)  // reported, and not undone
            #expect(runner.writes == [["worktree", "remove", "--", scene.path]])  // no `branch -D`
            #expect(try await sandbox.revision("refs/heads/\(removalBranch)", in: scene.repo) == elsewhere)
        }
    }

    /// `git worktree remove` without `--force` deletes work that git does not show: it is measured here, with real git,
    /// that the folder in each of these looks clean to it.
    @Suite(.timeLimit(.minutes(1))) struct HiddenWork {
        let sandbox: GitSandbox

        init() throws {
            sandbox = try GitSandbox()
        }

        @Test func aWorktreeInsideTheFolderIsNeverDeletedWithIt() async throws {
            let scene = try await sandbox.makeRemovalScene()
            // A session of Claude Code that worked in the worktree has made a worktree of its own in a folder of it
            // that git ignores, and has not finished: a change that is not saved, a new file, and a lock.
            let inner = scene.folder.appending(path: "tmp/agent-1")
            try await sandbox.git(["worktree", "add", "-b", "agent-1", inner.path, "main"], in: scene.repo)
            try sandbox.write("work that is saved nowhere\n", to: "README.md", in: inner)
            try sandbox.write("a new file\n", to: "new.txt", in: inner)
            try await sandbox.git(["worktree", "lock", "--reason", "claude session y", inner.path], in: scene.repo)
            #expect(try await sandbox.git(["status", "--porcelain"], in: scene.folder).stdout.isEmpty)  // clean, to git
            let runner = WatchedRunner(wrapping: sandbox.runner)
            let request = try await scene.request()

            let error = await #expect(throws: RemovalError.self) {
                try await sandbox.makeRemover(through: runner).remove(request, recheck: stillReady)
            }

            guard case .hiddenWork(let reason)? = error else {
                Issue.record("expected RemovalError.hiddenWork, got \(String(describing: error))")
                return
            }
            #expect(reason.contains("tmp/agent-1"), "\(reason)")
            #expect(runner.writes.isEmpty)
            #expect(scene.folderExists)
            let work = try String(contentsOf: inner.appending(path: "README.md"), encoding: .utf8)
            #expect(work == "work that is saved nowhere\n")
            #expect(FileManager.default.fileExists(atPath: inner.appending(path: "new.txt").path))
        }

        @Test(arguments: ["--assume-unchanged", "--skip-worktree"], [true, false])
        func aFileThatGitIsToldNotToLookAtIsNeverDeleted(flag: String, edited: Bool) async throws {
            // An edit to such a file does not show in `git status`. A file that is not edited yet may be, so it is not
            // told apart from one that is: git cannot say, and the folder is not deleted on its word.
            let scene = try await sandbox.makeRemovalScene()
            try await sandbox.git(["update-index", flag, "README.md"], in: scene.folder)
            if edited { try sandbox.write("my edit\n", to: "README.md", in: scene.folder) }
            #expect(try await sandbox.git(["status", "--porcelain"], in: scene.folder).stdout.isEmpty)  // clean, to git
            let runner = WatchedRunner(wrapping: sandbox.runner)
            let request = try await scene.request()

            let error = await #expect(throws: RemovalError.self) {
                try await sandbox.makeRemover(through: runner).remove(request, recheck: stillReady)
            }

            guard case .hiddenWork(let reason)? = error else {
                Issue.record("expected RemovalError.hiddenWork, got \(String(describing: error))")
                return
            }
            #expect(reason.contains("README.md"), "\(reason)")
            #expect(runner.writes.isEmpty)
            let contents = try String(contentsOf: scene.folder.appending(path: "README.md"), encoding: .utf8)
            #expect(contents == (edited ? "my edit\n" : "# Project\n"))
        }

        @Test func aSkippedFileThatIsNotOnTheDiskHoldsNothing() async throws {
            // What a sparse checkout leaves out: there is nothing in the folder to lose.
            let scene = try await sandbox.makeRemovalScene()
            try await sandbox.git(["update-index", "--skip-worktree", "README.md"], in: scene.folder)
            try FileManager.default.removeItem(at: scene.folder.appending(path: "README.md"))
            #expect(try await sandbox.git(["status", "--porcelain"], in: scene.folder).stdout.isEmpty)

            try await sandbox.makeRemover().remove(try await scene.request(), recheck: stillReady)

            #expect(!scene.folderExists)
        }

        @Test func aRefusalForHiddenWorkLeavesTheLockAlone() async throws {
            let scene = try await sandbox.makeRemovalScene()
            let reason = "claude session x (pid 999999 start Fri Oct 30 14:39:21 2026)"
            try await scene.lock(reason: reason)
            try await sandbox.git(["update-index", "--assume-unchanged", "README.md"], in: scene.folder)
            let runner = WatchedRunner(wrapping: sandbox.runner)
            let request = try await scene.request()

            await #expect(throws: RemovalError.self) {
                try await sandbox.makeRemover(through: runner).remove(request, recheck: stillReady)
            }

            #expect(runner.writes.isEmpty)  // not unlocked first, and refused after
            #expect(try await scene.worktree().lock?.reason == reason)
            #expect(scene.folderExists)
        }
    }

    /// What the deletion asks git, and what it does with the answers, on a stand-in for git.
    @Suite(.timeLimit(.minutes(1))) struct Deletion {
        @Test func aBranchAtTheCommitOfTheWorktreeIsDeleted() async throws {
            let scene = try PretendScene(tip: pretendHead)

            try await remover(for: scene).remove(scene.request(deleteBranch: true), recheck: stillReady)

            #expect(scene.runner.writes.map(\.first) == ["worktree", "branch"])
        }

        @Test func aBranchAtAnotherCommitIsKept() async throws {
            let tip = String(repeating: "b", count: 40)
            let scene = try PretendScene(tip: tip)

            let error = await #expect(throws: RemovalError.self) {
                try await remover(for: scene).remove(scene.request(deleteBranch: true), recheck: stillReady)
            }

            guard case .branchNotDeleted(let message)? = error else {
                Issue.record("expected RemovalError.branchNotDeleted, got \(String(describing: error))")
                return
            }
            #expect(message.contains("'b'") && message.contains("bbbbbbb") && message.contains("aaaaaaa"), "\(message)")
            #expect(scene.runner.writes.map(\.first) == ["worktree"])  // the folder is gone, and the branch is not
        }

        @Test func aBranchThatCannotBeReadIsKept() async throws {
            let scene = try PretendScene(tip: nil)

            let error = await #expect(throws: RemovalError.self) {
                try await remover(for: scene).remove(scene.request(deleteBranch: true), recheck: stillReady)
            }

            guard case .branchNotDeleted(let message)? = error else {
                Issue.record("expected RemovalError.branchNotDeleted, got \(String(describing: error))")
                return
            }
            #expect(message.contains("'b'") && message.contains("could not be read"), "\(message)")
            #expect(scene.runner.writes.map(\.first) == ["worktree"])
        }

        @Test func neverDeletesABranchForAWorktreeThatIsDetached() async throws {
            // A value that git does not give: a worktree that has a branch, and is detached all the same. Whatever else
            // it says, a worktree that is detached has no branch to take.
            let scene = try PretendScene(isDetached: true)

            try await remover(for: scene).remove(scene.request(deleteBranch: true), recheck: stillReady)

            #expect(scene.runner.writes.map(\.first) == ["worktree"])
        }

        @Test func aWorktreeThatIsDetachedNowIsNotTheOneThatWasAskedFor() async throws {
            // On a branch of the same name, as far as the list goes: all that has changed is that it is detached. With
            // real git a detached worktree has no branch, so a change of the branch says it too.
            let scene = try PretendScene(listed: {
                Worktree(path: $0.path, head: $0.head, branch: $0.branch, isDetached: true, lock: $0.lock)
            })

            await #expect(throws: RemovalError.worktreeChanged) {
                try await remover(for: scene).remove(scene.request(deleteBranch: true), recheck: stillReady)
            }

            #expect(scene.runner.writes.isEmpty)
        }

        @Test func aFailureThatSaysNothingNamesTheExitStatus() async throws {
            let scene = try PretendScene(answer: { args in
                WatchedRunner.subcommand(of: args).starts(with: ["worktree", "remove"])
                    ? CommandResult(exitCode: 3, stdout: "", stderr: " \n") : nil
            })

            await #expect(throws: RemovalError.gitRefused("git exited with 3")) {
                try await remover(for: scene).remove(scene.request(deleteBranch: true), recheck: stillReady)
            }
        }

        @Test func aListThatGitCannotGiveEndsTheRemovalBeforeAnythingIsChanged() async throws {
            let scene = try PretendScene(answer: { args in
                WatchedRunner.subcommand(of: args).starts(with: ["worktree", "list"])
                    ? CommandResult(exitCode: 128, stdout: "", stderr: "fatal: not a git repository\n") : nil
            })

            let error = await #expect(throws: RemovalError.self) {
                try await remover(for: scene).remove(scene.request(deleteBranch: true), recheck: stillReady)
            }

            guard case .gitRefused(let message)? = error else {
                Issue.record("expected RemovalError.gitRefused, got \(String(describing: error))")
                return
            }
            #expect(message.contains("not a git repository"), "\(message)")
            #expect(scene.runner.writes.isEmpty)
        }

        @Test func aListOfTheTrackedFilesThatGitCannotGiveEndsTheRemovalBeforeAnythingIsChanged() async throws {
            let scene = try PretendScene(answer: { args in
                WatchedRunner.subcommand(of: args).first == "ls-files"
                    ? CommandResult(exitCode: 128, stdout: "", stderr: "fatal: index file corrupt\n") : nil
            })

            await #expect(throws: RemovalError.gitRefused("fatal: index file corrupt")) {
                try await remover(for: scene).remove(scene.request(deleteBranch: true), recheck: stillReady)
            }

            #expect(scene.runner.writes.isEmpty)
        }

        @Test(arguments: [
            "H README.md\0",  // tracked, as everything is
            "H a.txt\0M b.txt\0R c.txt\0C d.txt\0K e.txt\0",  // unmerged, removed, changed, killed
            "S gone-for-the-sparse-checkout.txt\0",  // skipped, and not on the disk
        ])
        func trackedFilesThatHideNothingAreNoReasonToRefuse(listing: String) async throws {
            let scene = try PretendScene(tracked: listing)

            try await remover(for: scene).remove(scene.request(), recheck: stillReady)

            #expect(scene.runner.writes.map(\.first) == ["worktree"])
        }

        @Test(arguments: [
            ("h tracked.txt\0", "tracked.txt"),  // assume-unchanged
            ("H a.txt\0s b b.txt\0", "b b.txt"),  // assume-unchanged and skipped, in a name with a space
            ("H a.txt\0h dir/ünï.txt\0", "dir/ünï.txt"),
        ])
        func filesThatGitIsToldNotToLookAtAreNamed(listing: String, name: String) async throws {
            let scene = try PretendScene(tracked: listing)

            let error = await #expect(throws: RemovalError.self) {
                try await remover(for: scene).remove(scene.request(), recheck: stillReady)
            }

            guard case .hiddenWork(let reason)? = error else {
                Issue.record("expected RemovalError.hiddenWork, got \(String(describing: error))")
                return
            }
            #expect(reason.contains(name), "\(reason)")
            #expect(scene.runner.writes.isEmpty)
        }

        @Test func moreThanOneFileIsCounted() async throws {
            let scene = try PretendScene(tracked: "h one.txt\0h two.txt\0h three.txt\0")

            let error = await #expect(throws: RemovalError.self) {
                try await remover(for: scene).remove(scene.request(), recheck: stillReady)
            }

            guard case .hiddenWork(let reason)? = error else {
                Issue.record("expected RemovalError.hiddenWork, got \(String(describing: error))")
                return
            }
            #expect(reason.contains("one.txt") && reason.contains("2 more"), "\(reason)")
        }

        /// A remover that stops nothing, as no process is to be stopped, on the stand-in for git of `scene`.
        private func remover(for scene: PretendScene) -> WorktreeRemover {
            WorktreeRemover(
                runner: scene.runner, signaler: ScriptedSignaler(alive: []), sampler: ScriptedSampler(always: []))
        }
    }
}
