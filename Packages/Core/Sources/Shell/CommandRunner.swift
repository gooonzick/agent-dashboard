import Foundation

/// What a finished command left behind. A non-zero `exitCode` is an ordinary outcome, not an error.
public struct CommandResult: Sendable, Equatable {
    /// The exit status; for a child that a signal ended, the number of that signal.
    public let exitCode: Int32
    public let stdout: String
    public let stderr: String

    public init(exitCode: Int32, stdout: String, stderr: String) {
        self.exitCode = exitCode
        self.stdout = stdout
        self.stderr = stderr
    }
}

public enum CommandError: Error, Equatable {
    /// `tool` is not an executable file on any search path (or at the absolute path given).
    case notFound(String)
    /// The command ran past its timeout and was stopped.
    case timedOut(String)
}

public protocol CommandRunning: Sendable {
    /// Runs `tool` with one argument per element of `args` (no shell is involved) and waits for it to finish.
    func run(_ tool: String, _ args: [String], in directory: URL?, timeout: Duration) async throws -> CommandResult

    /// The executable `run` would start for `tool`, or `nil` if there is none.
    func which(_ tool: String) -> URL?
}

/// Runs command line tools (`git`, `glab`, `gh`) as child processes.
///
/// An app started from Finder does not get the `PATH` of the user's shell. Tools are therefore looked up in
/// `searchPaths` instead of the inherited `PATH`, and the child gets a `PATH` made of those same folders.
/// The rest of the environment (`HOME`, `SSH_AUTH_SOCK` and so on) is inherited.
public struct CommandRunner: CommandRunning {
    /// How long a child gets to stop after being asked to, before it is killed.
    private static let killDelay: Duration = .seconds(1)

    private let searchPaths: [String]

    public init(searchPaths: [String] = ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin"]) {
        self.searchPaths = searchPaths
    }

    /// A `tool` that is an absolute path is used as it is. Any other `tool` is a name, looked up in `searchPaths` in
    /// order; the first folder that holds an executable file of that name wins.
    public func which(_ tool: String) -> URL? {
        let candidates = tool.hasPrefix("/") ? [tool] : searchPaths.map { "\($0)/\(tool)" }
        return candidates.first(where: Self.isExecutableFile).map { URL(filePath: $0) }
    }

    /// Starts `tool` and waits until it has exited and its output has ended.
    ///
    /// The child's input is empty, so a tool that asks for some gets end-of-file instead of hanging.
    /// When `timeout` runs out the child is asked to stop (`terminate()`) and, once it has, the call throws
    /// `CommandError.timedOut(tool)`. A child that is still there `killDelay` later is killed and no longer waited
    /// for, so the call is over soon after `timeout` plus `killDelay` at the latest.
    /// Cancelling the calling task stops the child in the same way, and the call throws `CancellationError`.
    /// Other launch failures, such as a working directory that does not exist, are thrown as Foundation errors.
    public func run(
        _ tool: String, _ args: [String], in directory: URL?, timeout: Duration
    ) async throws -> CommandResult {
        try Task.checkCancellation()
        guard let executable = which(tool) else { throw CommandError.notFound(tool) }

        let process = Process()
        process.executableURL = executable
        process.arguments = args
        process.currentDirectoryURL = directory
        process.environment = environment(for: directory)
        process.standardInput = FileHandle.nullDevice

        // Whatever happens to the child arrives here as an event. A single loop in this task owns the process and
        // the state of the run, so there are no locks, and cancelling the task is just the end of the stream.
        let (events, emit) = AsyncStream.makeStream(of: Event.self)
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        process.terminationHandler = { emit.yield(.exited($0.terminationStatus)) }

        do {
            try process.run()
        } catch {
            // Left to themselves the pipes hold on to their descriptors for a while after the call has returned, so a
            // loop of failed launches (a hundred worktree folders that are gone, say) could use up all the process
            // may open.
            for pipe in [stdoutPipe, stderrPipe] {
                try? pipe.fileHandleForReading.close()
                try? pipe.fileHandleForWriting.close()
            }
            throw error
        }
        // Reading starts only now, so that a failed launch has no dispatch sources to tear down.
        Self.forward(stdoutPipe, to: emit, as: Event.stdout)
        Self.forward(stderrPipe, to: emit, as: Event.stderr)
        defer {
            // Still running means the task was cancelled or we gave up waiting.
            if process.isRunning { process.terminate() }
            stdoutPipe.fileHandleForReading.readabilityHandler = nil
            stderrPipe.fileHandleForReading.readabilityHandler = nil
            emit.finish()
        }

        let timer = Task {
            // Sleeping throws once the run is over and the timer is cancelled.
            guard (try? await Task.sleep(for: timeout)) != nil else { return }
            emit.yield(.timeout)
            guard (try? await Task.sleep(for: Self.killDelay)) != nil else { return }
            emit.yield(.kill)
        }
        defer { timer.cancel() }

        var stdout = Data()
        var stderr = Data()
        var openStreams = 2
        var exitCode: Int32?
        var timedOut = false
        for await event in events {
            switch event {
            case .stdout(let chunk):
                stdout.append(chunk)
            case .stderr(let chunk):
                stderr.append(chunk)
            case .closed:
                openStreams -= 1
            case .exited(let status):
                exitCode = status
            case .timeout:
                timedOut = true
                process.terminate()
            case .kill:
                if process.isRunning { kill(process.processIdentifier, SIGKILL) }
                throw CommandError.timedOut(tool)
            }
            guard let exitCode, openStreams == 0 else { continue }
            if timedOut { throw CommandError.timedOut(tool) }
            return CommandResult(
                exitCode: exitCode,
                stdout: String(decoding: stdout, as: UTF8.self),
                stderr: String(decoding: stderr, as: UTF8.self)
            )
        }
        // The stream ends early only when the calling task is cancelled.
        throw CancellationError()
    }

    private func environment(for directory: URL?) -> [String: String] {
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = searchPaths.joined(separator: ":")
        // A shell exports PWD when it changes directory. Without it the child would inherit the parent's PWD, which
        // names a different directory than the one it runs in.
        if let directory { environment["PWD"] = directory.path }
        return environment
    }

    /// Reports what is written to `pipe` as events built by `event`, and `.closed` once nobody can write to it.
    private static func forward(
        _ pipe: Pipe, to emit: AsyncStream<Event>.Continuation, as event: @escaping @Sendable (Data) -> Event
    ) {
        pipe.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            guard !chunk.isEmpty else {  // end of file
                handle.readabilityHandler = nil
                emit.yield(.closed)
                return
            }
            emit.yield(event(chunk))
        }
    }

    /// A folder passes `FileManager.isExecutableFile` too, so it has to be ruled out separately.
    private static func isExecutableFile(_ path: String) -> Bool {
        var isDirectory: ObjCBool = false
        let fileManager = FileManager.default
        return fileManager.fileExists(atPath: path, isDirectory: &isDirectory)
            && !isDirectory.boolValue
            && fileManager.isExecutableFile(atPath: path)
    }
}

/// What reaches the loop in `CommandRunner.run`.
private enum Event: Sendable {
    case stdout(Data)
    case stderr(Data)
    /// One of the two output streams has ended.
    case closed
    case exited(Int32)
    /// The time is up: ask the child to stop.
    case timeout
    /// The child had its time to stop: kill it if it is still there, and stop waiting.
    case kill
}
