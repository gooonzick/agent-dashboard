import Darwin
import Foundation

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
    /// Ends the process with `SIGKILL`, which it cannot ignore, and waits until it is gone, so that nothing is left
    /// behind when the test goes on. Does nothing for a process that has ended already, whoever ended it.
    public func kill() {
        guard isRunning else { return }
        Darwin.kill(processIdentifier, SIGKILL)
        waitUntilExit()
    }
}
