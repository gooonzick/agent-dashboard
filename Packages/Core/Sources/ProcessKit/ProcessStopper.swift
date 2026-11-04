import CoreModels
import Darwin
import Foundation

/// Why the processes that were to be stopped are not all gone.
public enum ProcessStopError: Error, Equatable {
    /// The process with this id still runs after `SIGKILL`, and the moment that it was given to die: it is stuck in the
    /// kernel.
    case stillRunning(Int32)
}

/// Stops groups of processes with signals.
///
/// The processes are stopped bottom-up, each one before the process that started it: every process of every group
/// gets `SIGTERM`, and then up to `stopTimeout` to exit. Those that are still there get `SIGKILL`, and a moment to die.
/// One that does not is `ProcessStopError.stillRunning`.
///
/// A process is signalled only if it is still the one that was sampled. A process id is given to another process once
/// the first has exited, and what runs under the id of a record that is minutes old may be anything. So a fresh sample
/// is taken before each of the two signals, and an id is only signalled if the sample has it with the `startDate` and
/// the `name` of the record: what does not is taken for gone. The process of the app itself is never signalled.
public struct ProcessStopper: Sendable {
    /// The longest that a process gets to die after `SIGKILL`, or `stopTimeout` if that is shorter: it dies at once,
    /// unless it is stuck in the kernel.
    private static let killGrace: Duration = .seconds(2)
    /// How often the processes that were told to stop are looked at.
    private static let pollInterval: Duration = .milliseconds(50)

    private let signaler: any ProcessSignaling
    private let sampler: any ProcessSampling
    private let stopTimeout: Duration

    public init(signaler: any ProcessSignaling, sampler: any ProcessSampling, stopTimeout: Duration = .seconds(5)) {
        self.signaler = signaler
        self.sampler = sampler
        self.stopTimeout = stopTimeout
    }

    /// Stops the processes of `groups`, and returns once they are gone. Nothing is sampled or signalled when there are
    /// no groups.
    ///
    /// It throws `ProcessStopError.stillRunning` for a process that survives `SIGKILL`, and `CancellationError` when
    /// the task is cancelled while it waits for them to exit: what was signalled by then stays signalled. Sampling
    /// blocks its thread (`ProcessSampling.sample()`): call it from a task that is not the main actor's.
    public func stop(_ groups: [ProcessGroup]) async throws {
        let targets = Self.stopOrder(of: groups)
        guard !targets.isEmpty else { return }

        var running = send(SIGTERM, to: targets)
        try await waitUntilGone(running, within: stopTimeout)
        running = running.filter { signaler.isAlive($0.pid) }
        guard !running.isEmpty else { return }

        running = send(SIGKILL, to: running)
        try await waitUntilGone(running, within: min(stopTimeout, Self.killGrace))
        // The first of them in the order in which they are stopped: a child is named before its parent.
        if let survivor = running.first(where: { signaler.isAlive($0.pid) }) {
            throw ProcessStopError.stillRunning(survivor.pid)
        }
    }

    /// Sends `sig` to those of `targets` that are still the processes they were sampled as, in the order given, and
    /// returns them. A signal that is not sent is not an error here: the process is gone, or it is not the app's to
    /// stop, and `isAlive` tells which when it is looked at again.
    private func send(_ sig: Int32, to targets: [ProcessRecord]) -> [ProcessRecord] {
        let live = Dictionary(sampler.sample().map { ($0.pid, $0) }, uniquingKeysWith: { first, _ in first })
        let own = ProcessInfo.processInfo.processIdentifier
        let same = targets.filter { target in
            guard target.pid != own, let current = live[target.pid] else { return false }
            return current.startDate == target.startDate && current.name == target.name
        }
        for target in same { _ = signaler.signal(target.pid, sig) }
        return same
    }

    /// Returns when none of `targets` is alive, or after `limit`, whichever is first.
    private func waitUntilGone(_ targets: [ProcessRecord], within limit: Duration) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: limit)
        while targets.contains(where: { signaler.isAlive($0.pid) }) {
            let remaining = clock.now.duration(to: deadline)
            guard remaining > .zero else { return }
            try await Task.sleep(for: min(remaining, Self.pollInterval))
        }
    }

    /// The processes of all the groups in the order in which they are stopped: one tree of the `ppid`s among all of
    /// them, deepest first, so that every process comes before the one that started it, whichever group each is in. A
    /// process that is listed twice is stopped once.
    ///
    /// Not in the order of the ids: they wrap around, and a child can have a lower one than its parent. Not group after
    /// group either: a server that leads a group of its own is the child of a shell that leads another. Not leader
    /// last: the leader of a session of the Claude app was started by a helper that is a member. Of two processes at
    /// the same depth, the one with the lower id is first.
    public static func stopOrder(of groups: [ProcessGroup]) -> [ProcessRecord] {
        var seen = Set<Identity>()
        let records = groups.flatMap { [$0.leader] + $0.members }.filter { seen.insert(Identity($0)).inserted }
        let byPID = Dictionary(records.map { ($0.pid, $0) }, uniquingKeysWith: { first, _ in first })
        /// How many parents of `record` are among the processes. A chain longer than that is a loop of parents, which
        /// samples that were taken a moment apart can make: it is cut short.
        func depth(of record: ProcessRecord) -> Int {
            var depth = 0
            var current = record
            while depth < records.count, current.ppid != current.pid, let parent = byPID[current.ppid] {
                current = parent
                depth += 1
            }
            return depth
        }
        return records.map { (record: $0, depth: depth(of: $0)) }
            .sorted { $0.depth != $1.depth ? $0.depth > $1.depth : $0.record.pid < $1.record.pid }
            .map(\.record)
    }
}

/// Who a process is, as far as a sample can tell: the id, and what it was started as and when.
private struct Identity: Hashable {
    let pid: Int32
    let startDate: Date
    let name: String

    init(_ record: ProcessRecord) {
        pid = record.pid
        startDate = record.startDate
        name = record.name
    }
}
