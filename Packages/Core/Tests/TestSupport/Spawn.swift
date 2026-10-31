import Darwin
import Foundation

/// The longest that `Process.kill()` waits for a process that it has sent `SIGKILL` to.
private let killTimeout: Duration = .seconds(10)

/// Starts `executable` with `arguments` as a child of the test, in `cwd` if one is given, and returns it, running.
///
/// The child reads from and writes to the null device, so it neither adds to the test output nor waits for input, and
/// it gets only the descriptors that `Process` passes on. Whoever starts one has to end it: stop it with `kill()` in a
/// `defer`, so that it does not outlive the test even when an expectation fails.
public func spawn(_ executable: String, _ arguments: [String], cwd: URL? = nil) throws -> Process {
    let process = Process()
    process.executableURL = URL(filePath: executable)
    process.arguments = arguments
    process.currentDirectoryURL = cwd
    process.standardInput = FileHandle.nullDevice
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    try process.run()
    return process
}

extension Process {
    /// Ends the process with `SIGKILL`, which it cannot ignore, and waits until Foundation reports it gone
    /// (`isRunning` is false), so that nothing is left behind when the test goes on. It waits for 10 seconds at most.
    /// Does nothing for a process that has ended already, whoever ended it.
    ///
    /// It polls and does not call `waitUntilExit`, which waits for the exit on the run loop of the calling thread. In
    /// async tests that ran beside each other that was seen not to return in ten minutes, with threads of Swift
    /// concurrency parked in it.
    public func kill() {
        killWithoutWaiting()
        let deadline = ContinuousClock.now.advanced(by: killTimeout)
        while isRunning, ContinuousClock.now < deadline { usleep(1_000) }
    }

    /// Ends the process with `SIGKILL` and does not wait for it: for a moment it is a zombie, until Foundation collects
    /// it, and `ProcessSignaling.isAlive` does not count a zombie as alive. For the `defer` of a test that has no
    /// reason to wait. Does nothing for a process that has ended already, whoever ended it.
    public func killWithoutWaiting() {
        guard isRunning else { return }
        Darwin.kill(processIdentifier, SIGKILL)
    }
}
