import CoreModels
import Foundation

/// A process for a test sample. What a test leaves out is true of an ordinary process: it runs `/usr/bin/<name>` with
/// its name as the only argument, started a minute before `Fixture.now`, sits in `/`, uses no memory and listens on no
/// port. `parent` has no default: launchd (1) as the parent is a fact that the rules look at, and nearly every test
/// wants another one.
func proc(
    _ pid: Int32, _ name: String, parent: Int32, exe: String? = nil, binaryDeleted: Bool = false,
    args: [String]? = nil, cwd: String? = "/", mb: UInt64 = 0, ports: [UInt16] = [], age: TimeInterval = 60
) -> ProcessRecord {
    ProcessRecord(
        pid: pid, ppid: parent, name: name, executablePath: binaryDeleted ? nil : (exe ?? "/usr/bin/\(name)"),
        arguments: args ?? [name], cwd: cwd, footprintBytes: mb << 20,
        startDate: Fixture.now.addingTimeInterval(-age), listeningPorts: ports)
}

/// Samples of the shapes that were found on a Mac on 2026-10-30, each of what runs in the worktree `root`. The pids of
/// one sample are not those of another, so that samples can be put together.
enum Fixture {
    static let now = Date(timeIntervalSince1970: 1_800_000_000)

    /// Where the Claude app is, as it is on every Mac.
    static let claudeApp = "/Applications/Claude.app"
    /// The Claude Code that the Claude app starts for its sessions.
    static let appClaude =
        "/Users/dev/Library/Application Support/Claude/claude-code/2.1.309/5af865b9901c"
        + "/claude.app/Contents/MacOS/claude"
    /// The Claude Code of the command line: a file that is named by its version and run through a link called `claude`.
    /// The kernel names the process after the file, so only the first argument says `claude`.
    static let cliClaude = "/Users/dev/.local/share/claude/versions/2.1.310"
    /// Where `npx` keeps the MCP servers that it runs.
    static let npx = "/Users/dev/.npm/_npx/9a1b2c/node_modules"

    /// The Claude app, which runs in `/`, starts the helper `disclaimer`, which starts `claude`, which starts five MCP
    /// servers. One of them has a process of its own, and two of them run in `/` as well.
    static func desktopSession(in root: String) -> [ProcessRecord] {
        let helper = "\(claudeApp)/Contents/Helpers/disclaimer"
        return [
            proc(500, "Claude", parent: 1, exe: "\(claudeApp)/Contents/MacOS/Claude", mb: 300),
            proc(
                600, "disclaimer", parent: 500, exe: helper, args: [helper, "--pgroup", "--", appClaude], cwd: root,
                mb: 6),
            proc(
                601, "claude", parent: 600, exe: appClaude,
                args: [appClaude, "--output-format", "stream-json", "--verbose"], cwd: root, mb: 420),
            proc(
                610, "node", parent: 601, args: ["node", "\(npx)/chrome-devtools-mcp/build/src/index.js"], cwd: root,
                mb: 90),
            proc(611, "npm", parent: 601, args: ["npm", "exec", "@playwright/mcp@latest"], cwd: root, mb: 70),
            proc(612, "uv", parent: 601, args: ["uv", "tool", "run", "serena", "start-mcp-server"], cwd: root, mb: 60),
            proc(613, "node", parent: 601, args: ["node", "\(npx)/figma-mcp/dist/index.js"], cwd: "/", mb: 50),
            proc(
                614, "node", parent: 601, args: ["node", "\(npx)/@upstash/context7-mcp/dist/index.js"], cwd: "/", mb: 40
            ),
            proc(
                620, "node", parent: 610, args: ["node", "\(npx)/chrome-devtools-mcp/build/src/telemetry/main.js"],
                cwd: "/", mb: 30),
        ]
    }

    /// A shell that `login` started in the worktree, and `claude` that the shell started, with one MCP server.
    static func cliSession(in root: String) -> [ProcessRecord] {
        [
            proc(700, "login", parent: 650, exe: "/usr/bin/login", args: ["login", "-pf", "dev"]),
            proc(701, "zsh", parent: 700, exe: "/bin/zsh", args: ["-zsh"], cwd: root, mb: 8),
            proc(702, "2.1.310", parent: 701, exe: cliClaude, args: ["claude"], cwd: root, mb: 310),
            proc(
                703, "node", parent: 702, args: ["node", "\(npx)/@upstash/context7-mcp/dist/index.js"], cwd: root,
                mb: 45),
        ]
    }

    /// An app that was built from the project: it sits in `/` and is known by the file that it runs. Xcode started it,
    /// unless `parent` says another process did. An app that is opened from the Finder has launchd (1) for its parent.
    static func builtApp(in root: String, startedBy parent: Int32 = 4_000) -> [ProcessRecord] {
        let app = "\(root)/build/DerivedData/Build/Products/Debug/Minuta.app/Contents/MacOS/Minuta"
        return [proc(800, "Minuta", parent: parent, exe: app, args: [app], mb: 120)]
    }

    /// Codex's daemon, started by launchd, in the folder of the project.
    static func codexDaemon(in root: String) -> [ProcessRecord] {
        let codex = "/Users/dev/.codex/packages/app-server-daemon/releases/0.166.0-aarch64-apple-darwin/bin/codex"
        return [
            proc(
                900, "codex", parent: 1, exe: codex, args: [codex, "app-server", "daemon", "pid-update-loop"],
                cwd: root, mb: 80)
        ]
    }

    /// A dev server that listens on 4200, started from a shell outside the worktree, with a process of its own.
    static func devServer(in root: String) -> [ProcessRecord] {
        [
            proc(1000, "zsh", parent: 999, exe: "/bin/zsh", args: ["-zsh"], cwd: "/Users/dev"),
            proc(
                1001, "node", parent: 1000, args: ["node", "\(root)/node_modules/.bin/nx", "serve"], cwd: root, mb: 600,
                ports: [4200]),
            proc(1002, "esbuild", parent: 1001, args: ["esbuild", "--service=0.25.0", "--ping"], cwd: root, mb: 40),
        ]
    }
}
