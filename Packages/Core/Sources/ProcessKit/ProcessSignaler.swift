import Darwin

/// Sends signals to processes, and tells whether a process still runs.
public protocol ProcessSignaling: Sendable {
    /// Sends signal `sig` to the process `pid`. `true` when it was sent. `false` when it was not: there is no such
    /// process, the process is another user's, or `sig` is not a signal.
    ///
    /// A `pid` that is not above 0 is refused, and nothing is sent. `kill` takes 0 for the caller's own group of
    /// processes, -1 for every process of the user, and any other negative number for a group: never for one process.
    func signal(_ pid: Int32, _ sig: Int32) -> Bool

    /// Whether the process `pid` exists and has not exited. A process of another user exists, though it cannot be
    /// signaled. A zombie, which is dead and waits to be collected, does not.
    func isAlive(_ pid: Int32) -> Bool
}

/// Signals processes with `kill(2)`.
public struct ProcessSignaler: ProcessSignaling {
    public init() {}

    public func signal(_ pid: Int32, _ sig: Int32) -> Bool {
        guard pid > 0 else { return false }
        return kill(pid, sig) == 0
    }

    public func isAlive(_ pid: Int32) -> Bool {
        guard pid > 0 else { return false }
        // Signal 0 is only checked for, and not sent. EPERM is the answer for a process that is there and is not ours.
        guard kill(pid, 0) == 0 else { return errno == EPERM }
        // `kill` finds a zombie too, though it has exited.
        return !Kernel.hasExited(pid)
    }
}
