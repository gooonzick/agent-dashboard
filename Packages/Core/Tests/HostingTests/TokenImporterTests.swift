import Foundation
import Hosting
import Shell
import Synchronization
import Testing

/// A `CommandRunning` that has a few tools, knows what they print, and remembers what it was asked to run.
///
/// It behaves as `CommandRunner` does: a tool that is not there has no executable for `which`, and running it throws
/// `CommandError.notFound`.
private final class FakeRunner: CommandRunning, Sendable {
    private let tools: Set<String>
    private let replies: [String: CommandResult]
    private let error: (any Error)?
    private let commands = Mutex<[String]>([])

    /// `replies` are by command line, `glab config get token --host h` and the like. A command that is not there
    /// fails, as a tool does that is given arguments it does not know. `error` is what every run throws instead.
    init(tools: Set<String> = ["glab", "gh"], replies: [String: CommandResult] = [:], error: (any Error)? = nil) {
        self.tools = tools
        self.replies = replies
        self.error = error
    }

    /// The command lines that were run, in order.
    var ran: [String] { commands.withLock { $0 } }

    func run(_ tool: String, _ args: [String], in directory: URL?, timeout: Duration) async throws -> CommandResult {
        let command = ([tool] + args).joined(separator: " ")
        commands.withLock { $0.append(command) }
        guard tools.contains(tool) else { throw CommandError.notFound(tool) }
        if let error { throw error }
        return replies[command] ?? CommandResult(exitCode: 1, stdout: "", stderr: "unknown command")
    }

    func which(_ tool: String) -> URL? {
        tools.contains(tool) ? URL(filePath: "/opt/fake/bin/\(tool)") : nil
    }
}

private func prints(_ stdout: String, exitCode: Int32 = 0) -> CommandResult {
    CommandResult(exitCode: exitCode, stdout: stdout, stderr: "")
}

@Suite struct TokenImporterTests {
    // MARK: What the brief asks for

    @Test func importsTokenFromGlab() async {
        let runner = FakeRunner(replies: ["glab config get token --host h": prints("glpat-xxx\n")])

        let token = await TokenImporter(runner: runner).importToken(host: "h", kind: .gitlab)

        #expect(token == "glpat-xxx")
        #expect(runner.ran == ["glab config get token --host h"])
    }

    // What the brief's example leaves open: the other tool, and everything that is not a token.

    @Test func importsTokenFromGh() async {
        let runner = FakeRunner(replies: ["gh auth token --hostname github.example.com": prints("gho_abc123\n")])

        let token = await TokenImporter(runner: runner).importToken(host: "github.example.com", kind: .github)

        #expect(token == "gho_abc123")
        #expect(runner.ran == ["gh auth token --hostname github.example.com"])
    }

    @Test(arguments: ["glpat-xxx", "glpat-xxx\n", "glpat-xxx\r\n", "\n glpat-xxx \n\n"])
    func trimsWhatSurroundsTheToken(output: String) async {
        let runner = FakeRunner(replies: ["glab config get token --host h": prints(output)])

        #expect(await TokenImporter(runner: runner).importToken(host: "h", kind: .gitlab) == "glpat-xxx")
    }

    @Test(arguments: ["", "\n", "  \n", "\r\n\r\n"])
    func emptyOutputIsNoToken(output: String) async {
        let runner = FakeRunner(replies: ["glab config get token --host h": prints(output)])

        #expect(await TokenImporter(runner: runner).importToken(host: "h", kind: .gitlab) == nil)
    }

    @Test func aFailedCommandIsNoTokenWhateverItPrinted() async {
        let runner = FakeRunner(replies: [
            "glab config get token --host h": prints("glpat-xxx\n", exitCode: 1),
            "gh auth token --hostname h": CommandResult(exitCode: 1, stdout: "", stderr: "no oauth token found for h"),
        ])
        let importer = TokenImporter(runner: runner)

        #expect(await importer.importToken(host: "h", kind: .gitlab) == nil)
        #expect(await importer.importToken(host: "h", kind: .github) == nil)
    }

    @Test(arguments: [
        "No token found for h\n",  // a message
        "glpat-xxx\nglpat-yyy\n",  // two lines
        "glpat-xxx\r\nX-Injected: 1\n",  // what a header must never be made of
        "glpat xxx",  // a token has no spaces
        "glpät-xxx",  // and is plain ASCII
        "glpat-\u{7}xxx",  // and has no control characters
    ])
    func outputThatIsNotASingleWordIsNoToken(output: String) async {
        let runner = FakeRunner(replies: ["glab config get token --host h": prints(output)])

        #expect(await TokenImporter(runner: runner).importToken(host: "h", kind: .gitlab) == nil)
    }

    // MARK: A tool that is not there, or does not work

    @Test(arguments: [HostingKind.gitlab, .github])
    func aToolThatIsNotInstalledIsNoToken(kind: HostingKind) async {
        let runner = FakeRunner(tools: [])  // `which` finds nothing, and `run` throws `notFound`

        #expect(await TokenImporter(runner: runner).importToken(host: "h", kind: kind) == nil)
    }

    @Test(arguments: [CommandError.notFound("glab"), .timedOut("glab"), .notFound("gh")])
    func aToolThatThrowsIsNoToken(error: CommandError) async {
        let runner = FakeRunner(error: error)

        #expect(await TokenImporter(runner: runner).importToken(host: "h", kind: .gitlab) == nil)
        #expect(await TokenImporter(runner: runner).importToken(host: "h", kind: .github) == nil)
    }

    @Test func aCancelledImportIsNoToken() async {
        let runner = FakeRunner(error: CancellationError())

        #expect(await TokenImporter(runner: runner).importToken(host: "h", kind: .gitlab) == nil)
    }

    // MARK: What is asked of the tool

    @Test func aHostThatIsNoSupportedHostingKindRunsNothing() async {
        let runner = FakeRunner(replies: ["glab config get token --host h": prints("glpat-xxx\n")])

        #expect(await TokenImporter(runner: runner).importToken(host: "h", kind: .unsupported) == nil)
        #expect(runner.ran.isEmpty)
    }

    @Test(arguments: ["", "--config", "-h", "h h", "h\n--other", "a@b", "h/x", "h:1"])
    func aNameThatIsNoHostIsNeverHandedToATool(host: String) async {
        // The host is an argument of another program: it must not be able to pose as an option of that program.
        let runner = FakeRunner(replies: [
            "glab config get token --host \(host)": prints("glpat-xxx\n"),
            "gh auth token --hostname \(host)": prints("gho_abc\n"),
        ])
        let importer = TokenImporter(runner: runner)

        #expect(await importer.importToken(host: host, kind: .gitlab) == nil)
        #expect(await importer.importToken(host: host, kind: .github) == nil)
        #expect(runner.ran.isEmpty)
    }
}
