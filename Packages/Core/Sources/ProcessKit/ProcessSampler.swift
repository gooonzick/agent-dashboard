import CoreModels
import Darwin
import Foundation

/// Takes snapshots of the user's processes.
public protocol ProcessSampling: Sendable {
    /// The processes of the user that run at this moment, in order of pid.
    ///
    /// It is system calls for every process, and blocks its thread until they are done: call it from a background task,
    /// at `.utility` priority or lower.
    func sample() -> [ProcessRecord]
}

/// Samples the processes of one user by asking the kernel: libproc for the process, its working directory, its memory
/// and its sockets, `sysctl` for its arguments.
///
/// Only the processes whose effective user is `uid` are sampled. The kernel tells nobody but root about the processes
/// of other users, so for any `uid` but the caller's own, the sample of a caller who is not root is empty.
///
/// A process is in the sample when the kernel can say who it is and it was still running when it was read:
/// - A zombie is left out: it has nothing but its place in the table.
/// - So is a process that exited while it was read. The calls that come after it exited fail, and what is left is a
///   record that has no working directory, no arguments and no memory, though the process is gone.
/// - A call that fails for a process that is there leaves out that one field: no `executablePath` or `cwd`, no
///   `arguments`, 0 bytes of `footprintBytes`, no `listeningPorts`. The rest of the record is true.
public struct ProcessSampler: ProcessSampling {
    private let uid: uid_t
    /// Asked about a process after it has been read, to tell if it was still running.
    private let stillRunning: @Sendable (Int32) -> Bool

    public init(uid: uid_t = getuid()) {
        self.init(uid: uid, stillRunning: { !Kernel.hasExited($0) })
    }

    /// Not public: a test cannot make a process exit at the very moment that it is read.
    init(uid: uid_t, stillRunning: @escaping @Sendable (Int32) -> Bool) {
        self.uid = uid
        self.stillRunning = stillRunning
    }

    public func sample() -> [ProcessRecord] {
        var arguments = Kernel.ArgumentsReader()
        var records: [ProcessRecord] = []
        for pid in Kernel.processIDs().sorted() {
            // Most of the table is the processes of other users, which the kernel does not answer for: they end here,
            // after one call.
            guard let info = Kernel.basicInfo(of: pid), info.userID == uid else { continue }
            let record = ProcessRecord(
                pid: pid,
                ppid: info.parentID,
                name: info.name,
                executablePath: Kernel.executablePath(of: pid),
                arguments: arguments.arguments(of: pid) ?? [],
                cwd: Kernel.workingDirectory(of: pid),
                footprintBytes: Kernel.physicalFootprint(of: pid) ?? 0,
                startDate: info.startDate,
                listeningPorts: Kernel.listeningPorts(of: pid)
            )
            if stillRunning(pid) { records.append(record) }
        }
        return records
    }
}
