import Foundation
import Synchronization

@testable import Shell

/// What the fake printed for one command line, and what it was asked for.
struct Call: Equatable {
    let line: String
    let timeout: Duration
}

/// `docker`, `colima` and the rest as stand-ins: a command line (`docker info`) maps to what it prints. A line that is
/// not in `answers` fails with exit code 1, and a tool that is not in `installed` is not found. The real tools are
/// never run.
final class FakeDocker: CommandRunning {
    private let installed: Set<String>
    private let answers: [String: CommandResult]
    private let log = Mutex<[Call]>([])

    init(installed: Set<String> = ["docker", "colima", "orbctl", "open"], answers: [String: CommandResult]) {
        self.installed = installed
        self.answers = answers
    }

    var calls: [Call] { log.withLock { $0 } }

    func run(_ tool: String, _ args: [String], in directory: URL?, timeout: Duration) async throws -> CommandResult {
        let line = ([tool] + args).joined(separator: " ")
        log.withLock { $0.append(Call(line: line, timeout: timeout)) }
        guard installed.contains(tool) else { throw CommandError.notFound(tool) }
        return answers[line] ?? CommandResult(exitCode: 1, stdout: "", stderr: "unexpected: \(line)")
    }

    func which(_ tool: String) -> URL? {
        installed.contains(tool) ? URL(filePath: "/opt/fake/bin/\(tool)") : nil
    }
}

/// The same stand-in, under a name for tests that fake a tool that is not Docker's, such as `git`.
typealias FakeCommands = FakeDocker

func ok(_ stdout: String) -> CommandResult { CommandResult(exitCode: 0, stdout: stdout, stderr: "") }
