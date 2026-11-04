import CoreModels
import Darwin
import Foundation
import ProcessKit
import Synchronization

// Processes that exist only in a test: what stopping them does, and what a sample says of them, is as the test says.
// For the tests of `ProcessStopper` and of the removal, which stops what runs in a worktree.

/// A signaler for processes that exist only here: they stop, or do not, when they are sent a signal, as the test says.
public final class ScriptedSignaler: ProcessSignaling {
    public struct Sent: Equatable, Sendable {
        public let pid: Int32
        public let sig: Int32
        public let at: ContinuousClock.Instant
    }

    private struct Processes {
        var alive: Set<Int32>
        var exitsAt: [Int32: ContinuousClock.Instant] = [:]
        var sent: [Sent] = []

        /// A process that was given a time to exit is gone once it has passed.
        mutating func settle(at now: ContinuousClock.Instant) {
            for (pid, time) in exitsAt where time <= now {
                alive.remove(pid)
                exitsAt[pid] = nil
            }
        }
    }

    private let store: Mutex<Processes>
    private let ignoringTerm: Set<Int32>
    private let unkillable: Set<Int32>
    private let lingering: [Int32: Duration]

    /// - Parameters:
    ///   - alive: The processes that run. All the others are gone.
    ///   - ignoringTerm: The processes that stay as they are when they are sent `SIGTERM`.
    ///   - unkillable: The processes that stay as they are even when they are sent `SIGKILL`.
    ///   - lingering: The processes that take that long to exit after `SIGTERM`.
    public init(
        alive: [Int32], ignoringTerm: Set<Int32> = [], unkillable: Set<Int32> = [], lingering: [Int32: Duration] = [:]
    ) {
        store = Mutex(Processes(alive: Set(alive)))
        self.ignoringTerm = ignoringTerm
        self.unkillable = unkillable
        self.lingering = lingering
    }

    public var sent: [Sent] { store.withLock { $0.sent } }

    /// Who was sent which signal, in order, without the times.
    public var signals: [[Int32]] { sent.map { [$0.pid, $0.sig] } }

    public func firstTime(of sig: Int32) -> ContinuousClock.Instant? {
        sent.first { $0.sig == sig }?.at
    }

    public func signal(_ pid: Int32, _ sig: Int32) -> Bool {
        let now = ContinuousClock.now
        return store.withLock { processes in
            processes.settle(at: now)
            processes.sent.append(Sent(pid: pid, sig: sig, at: now))
            guard processes.alive.contains(pid) else { return false }
            switch sig {
            case SIGKILL where !unkillable.contains(pid):
                processes.alive.remove(pid)
            case SIGTERM where !ignoringTerm.contains(pid):
                if let delay = lingering[pid] {
                    processes.exitsAt[pid] = now + delay
                } else {
                    processes.alive.remove(pid)
                }
            default:
                break
            }
            return true
        }
    }

    public func isAlive(_ pid: Int32) -> Bool {
        let now = ContinuousClock.now
        return store.withLock { processes in
            processes.settle(at: now)
            return processes.alive.contains(pid)
        }
    }
}

/// A sampler that answers from a script: the first call gets the first snapshot, the next call the next one, and every
/// call after the last gets the last.
public final class ScriptedSampler: ProcessSampling {
    private let snapshots: [[ProcessRecord]]
    private let calls = Mutex<Int>(0)

    public init(successive snapshots: [[ProcessRecord]]) {
        precondition(!snapshots.isEmpty)
        self.snapshots = snapshots
    }

    public convenience init(always records: [ProcessRecord]) {
        self.init(successive: [records])
    }

    public var sampleCount: Int { calls.withLock { $0 } }

    public func sample() -> [ProcessRecord] {
        let call = calls.withLock { count in
            defer { count += 1 }
            return count
        }
        return snapshots[min(call, snapshots.count - 1)]
    }
}

/// A process that was started a given number of seconds after a fixed moment. What a test leaves out is true of any
/// process: it has no working directory, no memory and listens on no port.
public func processRecord(_ pid: Int32, parent: Int32 = 1, name: String = "node", started: Double = 0)
    -> ProcessRecord
{
    ProcessRecord(
        pid: pid, ppid: parent, name: name, executablePath: nil, arguments: [], cwd: nil, footprintBytes: 0,
        startDate: Date(timeIntervalSince1970: 1_800_000_000 + started), listeningPorts: [])
}

public func processGroup(_ leader: ProcessRecord, _ members: ProcessRecord...) -> ProcessGroup {
    ProcessGroup(kind: .other, title: leader.name, leader: leader, members: members)
}

extension ProcessRecord {
    /// The same process as the kernel could have it at another time: it has another name, or began later.
    public func replacing(name: String? = nil, startDate: Date? = nil) -> ProcessRecord {
        ProcessRecord(
            pid: pid, ppid: ppid, name: name ?? self.name, executablePath: executablePath, arguments: arguments,
            cwd: cwd, footprintBytes: footprintBytes, startDate: startDate ?? self.startDate,
            listeningPorts: listeningPorts)
    }
}
