import CoreModels
import Foundation
import GitKit
import ProcessKit
import Safety
import Shell
import TestSupport
import Testing

extension WorktreeRemoverTests {
    /// How the processes of a worktree are stopped, with processes that exist only in the test: the order, the
    /// timeout and who is signalled are exact. Nothing here runs git for real, so what the runner was asked is all
    /// there is to say about the folder.
    @Suite(.timeLimit(.minutes(1))) struct Stopping {
        private let runner = WatchedRunner()

        // MARK: Order

        @Test func stopsDescendantsBeforeTheProcessesThatStartedThem() async throws {
            // Process ids wrap around, so a child can have a lower id than its parent. The order is that of the tree,
            // and not that of the ids: 200 is a child of 300, which is a child of 100.
            let leader = processRecord(100)
            let child = processRecord(300, parent: 100)
            let grandchild = processRecord(200, parent: 300)
            let signaler = ScriptedSignaler(alive: [100, 200, 300])

            try await remove(
                stopping: [processGroup(leader, grandchild, child)], with: signaler,
                seeing: ScriptedSampler(always: [leader, child, grandchild]))

            #expect(signaler.signals == [[200, SIGTERM], [300, SIGTERM], [100, SIGTERM]])
        }

        @Test func stopsTheLeaderBeforeTheHelperThatStartedItAndAfterWhatItStarted() async throws {
            // The Claude app starts a helper, which starts the session: the helper is a member of the group, and the
            // parent of its leader.
            let helper = processRecord(10, name: "disclaimer")
            let leader = processRecord(20, parent: 10, name: "claude")
            let server = processRecord(30, parent: 20)
            let signaler = ScriptedSignaler(alive: [10, 20, 30])

            try await remove(
                stopping: [processGroup(leader, helper, server)], with: signaler,
                seeing: ScriptedSampler(always: [helper, leader, server]))

            #expect(signaler.signals == [[30, SIGTERM], [20, SIGTERM], [10, SIGTERM]])
        }

        @Test func stopsEveryGroupInTheOrderGivenAndNothingTwice() async throws {
            let shell = processRecord(10, name: "zsh")
            let server = processRecord(11, parent: 10)
            let daemon = processRecord(20)
            let signaler = ScriptedSignaler(alive: [10, 11, 20])

            // The second group lists a process of the first one again.
            try await remove(
                stopping: [processGroup(shell, server), processGroup(daemon, server)], with: signaler,
                seeing: ScriptedSampler(always: [shell, server, daemon]))

            #expect(signaler.signals == [[11, SIGTERM], [10, SIGTERM], [20, SIGTERM]])
        }

        // MARK: Time

        @Test func killsOnlyWhatIsStillThereWhenTheTimeIsUp() async throws {
            let leader = processRecord(10)
            let polite = processRecord(20, parent: 10)
            let stubborn = processRecord(30, parent: 10)
            let signaler = ScriptedSignaler(alive: [10, 20, 30], ignoringTerm: [30])
            let sampler = ScriptedSampler(always: [leader, polite, stubborn])

            try await remove(stopping: [processGroup(leader, polite, stubborn)], with: signaler, seeing: sampler)

            #expect(signaler.signals == [[20, SIGTERM], [30, SIGTERM], [10, SIGTERM], [30, SIGKILL]])
            #expect(sampler.sampleCount == 2)  // who is who is looked at before each of the two rounds
            #expect(runner.calls.count == 1)  // and then the removal went on
        }

        @Test func waitsTheWholeTimeoutBeforeItKills() async throws {
            let process = processRecord(10)
            let signaler = ScriptedSignaler(alive: [10], ignoringTerm: [10])

            try await remove(
                stopping: [processGroup(process)], with: signaler, seeing: ScriptedSampler(always: [process]),
                stopTimeout: .milliseconds(300))

            let asked = try #require(signaler.firstTime(of: SIGTERM))
            let killed = try #require(signaler.firstTime(of: SIGKILL))
            #expect(asked.duration(to: killed) >= .milliseconds(300))
        }

        @Test func carriesOnAsSoonAsEveryoneIsGone() async throws {
            let process = processRecord(10)
            let signaler = ScriptedSignaler(alive: [10], lingering: [10: .milliseconds(100)])
            let sampler = ScriptedSampler(always: [process])
            let waited = Recorder<Duration>()

            try await remove(
                stopping: [processGroup(process)], with: signaler, seeing: sampler, stopTimeout: .seconds(20),
                recheck: {
                    if let asked = signaler.firstTime(of: SIGTERM) { waited.append(asked.duration(to: .now)) }
                    return .ready(needsStopping: false)
                })

            let elapsed = try #require(waited.all.first)
            #expect(elapsed >= .milliseconds(100) && elapsed < .seconds(10), "\(elapsed)")  // not the 20 s to wait
            #expect(signaler.signals == [[10, SIGTERM]])  // it left in time: no kill
            #expect(sampler.sampleCount == 1)
        }

        @Test func reportsWhatSurvivesTheKillAndChangesNothing() async throws {
            let first = processRecord(10)
            let second = processRecord(20, parent: 10)
            let signaler = ScriptedSignaler(alive: [10, 20], ignoringTerm: [10, 20], unkillable: [10, 20])
            let rechecks = Recorder<Void>()

            let error = await #expect(throws: RemovalError.self) {
                try await remove(
                    stopping: [processGroup(first, second)], with: signaler,
                    seeing: ScriptedSampler(always: [first, second]), stopTimeout: .milliseconds(100),
                    recheck: {
                        rechecks.append(())
                        return .ready(needsStopping: false)
                    })
            }

            #expect(error == .processStillRunning(20))  // the child is stopped first, so it is the first one named
            #expect(rechecks.all.isEmpty)
            #expect(runner.calls.isEmpty)
        }

        // MARK: Who is signalled

        enum Impostor: String, CaseIterable, Sendable {
            /// What runs under the id now was started later: the process that was sampled is gone, its id was reused.
            case startedLater
            /// What runs under the id is another program.
            case otherName
            /// Nothing was sampled under that id any more.
            case gone
        }

        @Test(arguments: Impostor.allCases)
        func neverSignalsAnIdThatIsNotTheProcessThatWasSampled(impostor: Impostor) async throws {
            let sampled = processRecord(10, name: "node")
            let sampleNow: [ProcessRecord] =
                switch impostor {
                case .startedLater: [sampled.replacing(startDate: sampled.startDate.addingTimeInterval(3600))]
                case .otherName: [sampled.replacing(name: "zsh")]
                case .gone: []
                }
            let signaler = ScriptedSignaler(alive: [10])  // something runs under that id, and it is not to be touched

            try await remove(
                stopping: [processGroup(sampled)], with: signaler, seeing: ScriptedSampler(always: sampleNow))

            #expect(signaler.sent.isEmpty)
            #expect(runner.calls.count == 1)  // it was taken for stopped: not waited for, and no reason to refuse
        }

        @Test(arguments: [true, false])
        func looksAgainBeforeItKills(idWasReused: Bool) async throws {
            let sampled = processRecord(10)
            let later = idWasReused ? [sampled.replacing(startDate: sampled.startDate.addingTimeInterval(3600))] : []
            let signaler = ScriptedSignaler(alive: [10], ignoringTerm: [10])
            let sampler = ScriptedSampler(successive: [[sampled], later])

            // The process ignores the request, and by the time that the time is up it is no more what it was.
            try await remove(stopping: [processGroup(sampled)], with: signaler, seeing: sampler)

            #expect(signaler.signals == [[10, SIGTERM]])
            #expect(sampler.sampleCount == 2)
        }

        @Test func neverSignalsItself() async throws {
            let own = processRecord(ProcessInfo.processInfo.processIdentifier)
            let signaler = ScriptedSignaler(alive: [own.pid])

            try await remove(stopping: [processGroup(own)], with: signaler, seeing: ScriptedSampler(always: [own]))

            #expect(signaler.sent.isEmpty)
        }

        @Test func stopsNothingForACallerThatHasGivenUp() async throws {
            let process = processRecord(10)
            let signaler = ScriptedSignaler(alive: [10])
            let sampler = ScriptedSampler(always: [process])
            let remover = WorktreeRemover(runner: runner, signaler: signaler, sampler: sampler)
            let request = RemovalRequest(
                repo: URL(filePath: "/work/repo"), worktree: Worktree(path: "/work/wt", branch: "b"),
                deleteBranch: false, stopGroups: [processGroup(process)])
            let caller = Task {
                withUnsafeCurrentTask { $0?.cancel() }  // before anything is done
                try await remover.remove(request, recheck: stillReady)
            }

            await #expect(throws: CancellationError.self) { try await caller.value }

            #expect(signaler.sent.isEmpty && sampler.sampleCount == 0 && runner.calls.isEmpty)
        }

        @Test func looksAtNoProcessWhenThereIsNothingToStop() async throws {
            let signaler = ScriptedSignaler(alive: [])
            let sampler = ScriptedSampler(always: [])

            try await remove(stopping: [], with: signaler, seeing: sampler)

            #expect(sampler.sampleCount == 0)
            #expect(signaler.sent.isEmpty)
        }

        // MARK: Helpers

        /// Removes a worktree that is not there, through a runner that says yes to all, after the processes of `groups`
        /// are stopped.
        private func remove(
            stopping groups: [ProcessGroup], with signaler: ScriptedSignaler, seeing sampler: ScriptedSampler,
            stopTimeout: Duration = .milliseconds(200),
            recheck: @Sendable () async -> RemovalEligibility = stillReady
        ) async throws {
            let remover = WorktreeRemover(
                runner: runner, signaler: signaler, sampler: sampler, stopTimeout: stopTimeout)
            let request = RemovalRequest(
                repo: URL(filePath: "/work/repo"), worktree: Worktree(path: "/work/wt", branch: "b"),
                deleteBranch: false, stopGroups: groups)
            try await remover.remove(request, recheck: recheck)
        }
    }

    /// The same, with processes that the system really runs.
    @Suite(.timeLimit(.minutes(1))) struct RealProcesses {
        let sandbox: GitSandbox

        init() throws {
            sandbox = try GitSandbox()
        }

        enum Mismatch: String, CaseIterable, Sendable {
            case startDate
            case name
        }

        @Test(arguments: Mismatch.allCases)
        func leavesAProcessAloneThatIsNotWhatWasSampled(mismatch: Mismatch) async throws {
            let scene = try await sandbox.makeRemovalScene()
            let sleeper = try spawn("/bin/sleep", ["30"], cwd: scene.folder)
            defer { sleeper.killWithoutWaiting() }
            let running = try liveRecord(of: sleeper.processIdentifier)
            // What was sampled under this id is a process that started an hour earlier, or another program: not this.
            let sampled =
                switch mismatch {
                case .startDate: running.replacing(startDate: running.startDate.addingTimeInterval(-3600))
                case .name: running.replacing(name: "node")
                }

            try await sandbox.makeRemover().remove(
                try await scene.request(stopping: [processGroup(sampled)]), recheck: stillReady)

            #expect(ProcessSignaler().isAlive(sleeper.processIdentifier))  // it was never signalled
            #expect(!scene.folderExists)
        }

        @Test func killsAProcessThatIgnoresTerminationOnceTheTimeIsUp() async throws {
            let scene = try await sandbox.makeRemovalScene()
            // The shell ignores `SIGTERM`, and says so by making a file, outside of the worktree, when it does.
            let ready = sandbox.url.appending(path: "ignoring-term")
            let script = "trap '' TERM; : > '\(ready.path)'; while :; do sleep 1; done"
            let stubborn = try spawn("/bin/sh", ["-c", script], cwd: scene.folder)
            defer { stubborn.killWithoutWaiting() }
            let pid = stubborn.processIdentifier
            #expect(await eventually(within: .seconds(10)) { FileManager.default.fileExists(atPath: ready.path) })
            let group = processGroup(try liveRecord(of: pid))
            let remover = sandbox.makeRemover(stopTimeout: .milliseconds(300))
            let request = try await scene.request(stopping: [group])

            let took = try await ContinuousClock().measure {
                try await remover.remove(request, recheck: stillReady)
            }

            #expect(took >= .milliseconds(300), "\(took)")  // it did not give in to the request
            #expect(!ProcessSignaler().isAlive(pid))
            #expect(!scene.folderExists)
        }
    }

    /// What the removal does with the answer of the recheck, and when it asks.
    @Suite(.timeLimit(.minutes(1))) struct Recheck {
        private let runner = WatchedRunner()

        @Test(arguments: [
            RemovalEligibility.mainWorktree,
            .missing,
            .blocked([.modified(1)]),
            .blocked([.cantVerify, .lockedManually]),
        ])
        func refusesEveryAnswerButReadyAndManual(answer: RemovalEligibility) async throws {
            let remover = makeRemover()

            await #expect(throws: RemovalError.stateChanged(answer)) {
                try await remover.remove(makeRequest(), recheck: { answer })
            }

            #expect(runner.calls.isEmpty)  // not a single git command: nothing on the disk is changed
        }

        @Test(arguments: [
            RemovalEligibility.ready(needsStopping: false),
            .ready(needsStopping: true),
            .manual(needsStopping: false),
            .manual(needsStopping: true),
        ])
        func carriesOnForReadyAndManualWhetherOrNotSomethingStillRuns(answer: RemovalEligibility) async throws {
            try await makeRemover().remove(makeRequest(), recheck: { answer })

            #expect(runner.calls.map { $0.subcommand.first } == ["worktree", "branch"])
        }

        @Test func asksOnceAfterTheProcessesAreStoppedAndBeforeAnythingIsChanged() async throws {
            struct Seen: Equatable, Sendable {
                let signals: [[Int32]]
                let gitCommands: Int
                let ownerAlive: Bool
            }
            let session = processRecord(4242, name: "claude")
            let signaler = ScriptedSignaler(alive: [4242])
            let lock = WorktreeLock(reason: "claude session x (pid 4242 start Fri Oct 30 14:39:21 2026)")
            let runner = runner
            let remover = makeRemover(signaler: signaler, sampler: ScriptedSampler(always: [session]))
            let seen = Recorder<Seen>()

            try await remover.remove(
                makeRequest(lock: lock, stopping: [processGroup(session)]),
                recheck: {
                    seen.append(
                        Seen(
                            signals: signaler.signals, gitCommands: runner.calls.count,
                            ownerAlive: signaler.isAlive(4242)))
                    return .ready(needsStopping: true)
                })

            // The owner of the lock has been told to stop and has, nothing has been run yet, and it is asked just once.
            #expect(seen.all == [Seen(signals: [[4242, SIGTERM]], gitCommands: 0, ownerAlive: false)])
            #expect(
                runner.calls.map(\.subcommand) == [
                    ["worktree", "unlock", "--", "/work/wt"],
                    ["worktree", "remove", "--", "/work/wt"],
                    ["branch", "-D", "--", "b"],
                ])
        }

        @Test func leavesTheProcessesStoppedWhenTheRecheckRefuses() async throws {
            // The processes cannot be started again, and the removal is refused all the same: that is how it is, and it
            // is for the app to say, so that nobody takes "nothing was changed" for "everything is as it was".
            let session = processRecord(4242)
            let signaler = ScriptedSignaler(alive: [4242])
            let remover = makeRemover(signaler: signaler, sampler: ScriptedSampler(always: [session]))

            await #expect(throws: RemovalError.stateChanged(.blocked([.untracked(1)]))) {
                try await remover.remove(
                    makeRequest(stopping: [processGroup(session)]), recheck: { .blocked([.untracked(1)]) })
            }

            #expect(!signaler.isAlive(4242))
            #expect(runner.calls.isEmpty)
        }

        // MARK: Helpers

        /// Removes a worktree that is not there: its lock, when it has one, and its branch.
        private func makeRequest(lock: WorktreeLock? = nil, stopping groups: [ProcessGroup] = []) -> RemovalRequest {
            RemovalRequest(
                repo: URL(filePath: "/work/repo"), worktree: Worktree(path: "/work/wt", branch: "b", lock: lock),
                deleteBranch: true, stopGroups: groups)
        }

        private func makeRemover(
            signaler: ScriptedSignaler = ScriptedSignaler(alive: []),
            sampler: ScriptedSampler = ScriptedSampler(always: [])
        ) -> WorktreeRemover {
            WorktreeRemover(runner: runner, signaler: signaler, sampler: sampler, stopTimeout: .milliseconds(200))
        }
    }
}
