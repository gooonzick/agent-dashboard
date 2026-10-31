import CoreModels
import Foundation
import GitKit
import ProcessKit
import Safety
import Shell
import TestSupport
import Testing

extension WorktreeRemoverTests {
    /// Claude Code locks the worktree of each session, with the id of the session's process in the reason. A lock is
    /// only taken off when that process is no more: the lock is then stale. Anything else about a lock is not the
    /// app's to say, and git is left to refuse it.
    @Suite(.timeLimit(.minutes(1))) struct Locks {
        let sandbox: GitSandbox
        let remover: WorktreeRemover

        init() throws {
            sandbox = try GitSandbox()
            remover = sandbox.makeRemover()
        }

        @Test(arguments: [
            "",  // a bare `git worktree lock`
            "kept for the release",
            "pid is 4242",  // no number after the word
            "pid 0",  // 0 would stand for a whole group of processes
        ])
        func aLockThatNamesNoOwnerIsNeverUnlocked(reason: String) async throws {
            let scene = try await sandbox.makeRemovalScene()
            try await scene.lock(reason: reason)
            let request = try await scene.request()
            #expect(request.worktree.lock != nil && request.worktree.lock?.ownerPID == nil)
            let runner = WatchedRunner(wrapping: sandbox.runner)

            let error = await #expect(throws: RemovalError.self) {
                try await sandbox.makeRemover(through: runner).remove(request, recheck: stillReady)
            }

            guard case .gitRefused(let message)? = error else {
                Issue.record("expected RemovalError.gitRefused, got \(String(describing: error))")
                return
            }
            #expect(!message.isEmpty)
            #expect(runner.calls.map { $0.subcommand.first } == ["worktree"])  // the removal was tried, not an unlock
            #expect(try await scene.worktree().lock != nil)
            #expect(scene.folderExists)
        }

        @Test func aLockWhoseOwnerRunsIsKeptAndNothingIsRemoved() async throws {
            let scene = try await sandbox.makeRemovalScene()
            let owner = try spawn("/bin/sleep", ["30"])
            defer { owner.killWithoutWaiting() }
            let pid = owner.processIdentifier
            try await scene.lock(reason: "claude session x (pid \(pid) start Fri Oct 30 14:39:21 2026)")
            let runner = WatchedRunner(wrapping: sandbox.runner)
            let request = try await scene.request()  // nobody is to stop the owner

            let error = await #expect(throws: RemovalError.self) {
                try await sandbox.makeRemover(through: runner).remove(request, recheck: stillReady)
            }

            #expect(error == .processStillRunning(pid))
            #expect(runner.calls.isEmpty)
            #expect(try await scene.worktree().lock?.ownerPID == pid)
            #expect(scene.folderExists)
            #expect(ProcessSignaler().isAlive(pid))
        }

        @Test func stopsTheOwnerOfTheLockThenUnlocksAndRemoves() async throws {
            let scene = try await sandbox.makeRemovalScene()
            let session = try spawn("/bin/sleep", ["30"], cwd: scene.folder)
            defer { session.killWithoutWaiting() }
            let pid = session.processIdentifier
            try await scene.lock(reason: "claude session x (pid \(pid) start Fri Oct 30 14:39:21 2026)")
            let group = processGroup(try liveRecord(of: pid))

            try await remover.remove(try await scene.request(stopping: [group]), recheck: stillReady)

            #expect(!ProcessSignaler().isAlive(pid))
            #expect(!scene.folderExists)
            #expect(try await !scene.branchExists())
        }

        @Test func leavesTheLockAloneWhenTheRecheckRefuses() async throws {
            let scene = try await sandbox.makeRemovalScene()
            try await scene.lock(reason: "claude session x (pid 999999 start Fri Oct 30 14:39:21 2026)")
            let request = try await scene.request()

            await #expect(throws: RemovalError.stateChanged(.blocked([.modified(1)]))) {
                try await remover.remove(request, recheck: { .blocked([.modified(1)]) })
            }

            #expect(try await scene.worktree().lock?.ownerPID == 999_999)  // not unlocked before the state was checked
            #expect(scene.folderExists)
        }

        @Test func doesNotRemoveAnythingWhenTheUnlockFails() async throws {
            let scene = try await sandbox.makeRemovalScene()
            try await scene.lock(reason: "claude session x (pid 999999 start Fri Oct 30 14:39:21 2026)")
            let request = try await scene.request()
            let failure = CommandResult(exitCode: 128, stdout: "", stderr: "fatal: no unlocking\n")
            let runner = WatchedRunner(wrapping: sandbox.runner) { args in
                args.contains("unlock") ? failure : nil
            }

            await #expect(throws: RemovalError.gitRefused("fatal: no unlocking")) {
                try await sandbox.makeRemover(through: runner).remove(request, recheck: stillReady)
            }

            #expect(runner.calls.map(\.subcommand) == [["worktree", "unlock", "--", scene.path]])  // nothing after it
            #expect(scene.folderExists)
        }
    }
}
