import CoreModels
import Darwin
import Foundation
import ProcessKit
import TestSupport
import Testing

/// How groups of processes are stopped, with processes that exist only in the test: the order, the timeout and who is
/// signalled are exact. One test stops a process that the system really runs.
@Suite(.timeLimit(.minutes(1))) struct ProcessStopperTests {
    // MARK: Order

    @Test func stopsEveryProcessBeforeTheOneThatStartedItWhicheverGroupEachIsIn() async throws {
        // A shell that leads one group and started the server that leads another, which started a worker whose id is
        // lower than its parent's. A daemon of a third group is not related to either.
        let shell = processRecord(100, name: "zsh")
        let server = processRecord(300, parent: 100)
        let worker = processRecord(200, parent: 300)
        let daemon = processRecord(50)
        let signaler = ScriptedSignaler(alive: [50, 100, 200, 300])

        // The groups are not in the order of the tree, and the last lists the worker again.
        try await stop(
            [processGroup(shell), processGroup(daemon), processGroup(server, worker), processGroup(worker)],
            with: signaler, seeing: ScriptedSampler(always: [daemon, shell, worker, server]))

        #expect(signaler.signals == [[200, SIGTERM], [300, SIGTERM], [50, SIGTERM], [100, SIGTERM]])
    }

    @Test func ordersTheProcessesAsTheyAreStopped() {
        let helper = processRecord(10, name: "disclaimer")
        let leader = processRecord(20, parent: 10, name: "claude")
        let server = processRecord(30, parent: 20)

        let order = ProcessStopper.stopOrder(of: [processGroup(leader, helper, server), processGroup(server)])

        #expect(order.map(\.pid) == [30, 20, 10])  // the helper started the leader, and comes after it
    }

    // MARK: Time

    @Test func killsWhatIgnoresTerminationOnceTheTimeIsUp() async throws {
        let leader = processRecord(10)
        let stubborn = processRecord(20, parent: 10)
        let signaler = ScriptedSignaler(alive: [10, 20], ignoringTerm: [20])
        let sampler = ScriptedSampler(always: [leader, stubborn])

        try await stop(
            [processGroup(leader, stubborn)], with: signaler, seeing: sampler, stopTimeout: .milliseconds(300))

        #expect(signaler.signals == [[20, SIGTERM], [10, SIGTERM], [20, SIGKILL]])
        let asked = try #require(signaler.firstTime(of: SIGTERM))
        let killed = try #require(signaler.firstTime(of: SIGKILL))
        #expect(asked.duration(to: killed) >= .milliseconds(300))
        #expect(sampler.sampleCount == 2)  // who is who is looked at before each of the two signals
    }

    @Test func namesTheFirstProcessThatSurvivesTheKill() async throws {
        let parent = processRecord(10)
        let child = processRecord(20, parent: 10)
        let signaler = ScriptedSignaler(alive: [10, 20], ignoringTerm: [10, 20], unkillable: [10, 20])

        await #expect(throws: ProcessStopError.stillRunning(20)) {  // the child is stopped first
            try await stop(
                [processGroup(parent, child)], with: signaler, seeing: ScriptedSampler(always: [parent, child]),
                stopTimeout: .milliseconds(100))
        }
    }

    @Test func givesUpWhenTheTaskIsCancelled() async throws {
        let process = processRecord(10)
        let signaler = ScriptedSignaler(alive: [10], ignoringTerm: [10])
        let stopper = ProcessStopper(
            signaler: signaler, sampler: ScriptedSampler(always: [process]), stopTimeout: .seconds(30))
        let task = Task { try await stopper.stop([processGroup(process)]) }
        while signaler.sent.isEmpty { try await Task.sleep(for: .milliseconds(5)) }

        task.cancel()

        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(signaler.signals == [[10, SIGTERM]])  // no kill for a caller who has gone
    }

    // MARK: Who is signalled

    enum Mismatch: String, CaseIterable, Sendable {
        /// What runs under the id now was started later: the process that was sampled is gone, its id was reused.
        case startDate
        /// What runs under the id is another program.
        case name
        /// Nothing is sampled under that id any more.
        case gone
    }

    @Test(arguments: Mismatch.allCases)
    func neverSignalsAnIdThatIsNotTheProcessThatWasSampled(mismatch: Mismatch) async throws {
        let sampled = processRecord(10, name: "node")
        let sampleNow: [ProcessRecord] =
            switch mismatch {
            case .startDate: [sampled.replacing(startDate: sampled.startDate.addingTimeInterval(3600))]
            case .name: [sampled.replacing(name: "zsh")]
            case .gone: []
            }
        let signaler = ScriptedSignaler(alive: [10])  // something runs under that id, and it is not to be touched

        try await stop([processGroup(sampled)], with: signaler, seeing: ScriptedSampler(always: sampleNow))

        #expect(signaler.sent.isEmpty)
    }

    @Test func neverSignalsTheAppItself() async throws {
        let own = processRecord(ProcessInfo.processInfo.processIdentifier)
        let child = processRecord(10, parent: own.pid)
        let signaler = ScriptedSignaler(alive: [own.pid, 10])

        try await stop([processGroup(own, child)], with: signaler, seeing: ScriptedSampler(always: [own, child]))

        #expect(signaler.signals == [[10, SIGTERM]])
    }

    @Test func looksAtNoProcessWhenThereIsNothingToStop() async throws {
        let signaler = ScriptedSignaler(alive: [])
        let sampler = ScriptedSampler(always: [])

        try await stop([], with: signaler, seeing: sampler)

        #expect(sampler.sampleCount == 0 && signaler.sent.isEmpty)
    }

    // MARK: A real process

    @Test func killsARealProcessThatIgnoresTermination() async throws {
        // The shell ignores `SIGTERM`, says so by making a file, and becomes `sleep`, which goes on ignoring it: an
        // ignored signal stays ignored through `exec`. No child is left behind when it dies.
        let folder = try TempDir(named: "stopper")
        let ready = folder.url.appending(path: "ignoring-term")
        let stubborn = try spawn("/bin/sh", ["-c", "trap '' TERM; : > '\(ready.path)'; exec /bin/sleep 30"])
        defer { stubborn.killWithoutWaiting() }
        let pid = stubborn.processIdentifier
        let sampler = ProcessSampler()
        let clock = ContinuousClock()
        let deadline = clock.now + .seconds(10)
        var record: ProcessRecord?
        while record == nil, clock.now < deadline {
            let current = sampler.sample().first { $0.pid == pid }
            if FileManager.default.fileExists(atPath: ready.path), current?.name == "sleep" { record = current }
            try await Task.sleep(for: .milliseconds(10))
        }
        let sleeping = try #require(record)
        let stopper = ProcessStopper(signaler: ProcessSignaler(), sampler: sampler, stopTimeout: .milliseconds(300))

        let took = try await clock.measure { try await stopper.stop([processGroup(sleeping)]) }

        #expect(took >= .milliseconds(300), "\(took)")  // it did not give in to the request
        #expect(!ProcessSignaler().isAlive(pid))
    }

    // MARK: Helpers

    private func stop(
        _ groups: [ProcessGroup], with signaler: ScriptedSignaler, seeing sampler: ScriptedSampler,
        stopTimeout: Duration = .milliseconds(200)
    ) async throws {
        try await ProcessStopper(signaler: signaler, sampler: sampler, stopTimeout: stopTimeout).stop(groups)
    }
}
