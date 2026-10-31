import CoreModels
import Foundation
import ProcessKit
import Testing

private let worktree = "/Users/dev/projects/dashboard-worktrees/PYMEP-1"
/// A parent that no sample has: a process of another user, or one that has exited.
private let nobody: Int32 = 9_999

/// What a `ProcessAttributor` for the worktrees `roots` makes of `processes`.
private func attribute(_ processes: [ProcessRecord], roots: [String] = [worktree]) -> [String: [ProcessGroup]] {
    ProcessAttributor(roots: roots).attribute(processes)
}

/// The pids of a group: its leader, then its members.
private func pids(of group: ProcessGroup) -> [Int32] { [group.leader.pid] + group.members.map(\.pid) }

/// The pids of every group of every worktree, as `[worktree: [[leader, members...]]]`.
private func shape(_ result: [String: [ProcessGroup]]) -> [String: [[Int32]]] { result.mapValues { $0.map(pids(of:)) } }

/// The one group that a test expects. The test stops here if there is none or more, instead of going on to index.
private func theOnly(
    _ groups: [ProcessGroup]?, sourceLocation: SourceLocation = #_sourceLocation
) throws -> ProcessGroup {
    let groups = try #require(groups, "no group at all", sourceLocation: sourceLocation)
    try #require(groups.count == 1, "\(groups.map(pids(of:))) are groups, not one", sourceLocation: sourceLocation)
    return groups[0]
}

@Suite struct ProcessAttributorTests {
    // The seven examples of the brief, on the shapes that were found on a Mac on 2026-10-30.

    @Test func desktopClaudeSessionIsOneGroup() throws {
        let result = attribute(Fixture.desktopSession(in: worktree))
        let group = try theOnly(result[worktree])
        #expect(group.kind == .agentSession && group.title == "Claude Code · desktop, 5 MCP servers")
        #expect(group.members.count == 7)  // disclaimer + 5 MCP + node
        #expect(group.leader.pid == 601 && group.members.map(\.pid) == [600, 610, 611, 612, 613, 614, 620])
        // The Claude app is in the sample and runs in `/`: it is nowhere.
        #expect(result.keys.sorted() == [worktree])
    }

    @Test func cliSessionStartedFromShell() throws {
        let groups = try #require(attribute(Fixture.cliSession(in: worktree))[worktree])
        try #require(groups.count == 2, "\(groups.map(pids(of:))) are groups, not two")
        // The shell that started the session is a group of its own: it is not part of the session.
        let (session, shell) = (groups[0], groups[1])
        #expect(session.kind == .agentSession && session.title == "Claude Code · CLI, 1 MCP server")
        #expect(session.leader.pid == 702 && session.members.map(\.pid) == [703])
        #expect(shell.kind == .shell && shell.title == "zsh" && shell.leader.pid == 701 && shell.members.isEmpty)
    }

    @Test func builtAppAttributedByExecutablePath() throws {
        let minuta = "/Users/dev/projects/minuta"
        let result = attribute(Fixture.builtApp(in: minuta), roots: [worktree, minuta])
        let group = try theOnly(result[minuta])
        #expect(group.kind == .builtHere && group.title == "Minuta")
        #expect(result.keys.sorted() == [minuta])
    }

    @Test func launchdChildIsDaemon() throws {
        let dashboard = "/Users/dev/projects/dashboard"
        let group = try theOnly(attribute(Fixture.codexDaemon(in: dashboard), roots: [dashboard])[dashboard])
        #expect(group.kind == .daemon && group.title == "codex")
    }

    @Test func deepestRootWinsAndPrefixIsByComponent() {
        let dashboard = "/r/dashboard"
        let ticket = "/r/dashboard-worktrees/PYMEP-1"
        let processes = [
            proc(10, "node", parent: nobody, cwd: "\(ticket)/apps/web"),
            // Next to the folder of the ticket, and in neither root, though "/r/dashboard" is how its path begins.
            proc(11, "sleep", parent: nobody, cwd: "/r/dashboard-worktrees/PYMEP-2"),
        ]
        let result = attribute(processes, roots: [dashboard, ticket])
        #expect(result.keys.sorted() == [ticket])
        #expect(result[ticket]?.map(\.leader.pid) == [10])
    }

    @Test func devServerByListeningPort() throws {
        let group = try theOnly(attribute(Fixture.devServer(in: worktree))[worktree])
        #expect(group.kind == .devServer && group.ports == [4200])
        #expect(group.title == "node" && group.leader.pid == 1001 && group.members.map(\.pid) == [1002])
    }

    @Test func childWithForeignCwdFollowsAncestor() throws {
        let processes = [
            proc(10, "make", parent: nobody, cwd: worktree),
            proc(11, "cc", parent: 10, cwd: "/"),
            proc(12, "ld", parent: 11, cwd: "/tmp"),  // a grandchild, in a folder of its own
        ]
        let group = try theOnly(attribute(processes)[worktree])
        #expect(group.leader.pid == 10 && group.members.map(\.pid) == [11, 12])
    }
}

// MARK: - Which worktree a process is in

struct RootPathCase: Sendable, CustomTestStringConvertible {
    let path: String
    let inRoot: Bool
    var testDescription: String { "\(path) is \(inRoot ? "in" : "not in") /r/dashboard" }
}

private let rootPathCases = [
    RootPathCase(path: "/r/dashboard", inRoot: true),
    RootPathCase(path: "/r/dashboard/", inRoot: true),
    RootPathCase(path: "/r/dashboard/apps/web", inRoot: true),
    RootPathCase(path: "/r/dashboard-worktrees/PYMEP-1", inRoot: false),  // begins like the root, is another folder
    RootPathCase(path: "/r/dashboard2", inRoot: false),
    RootPathCase(path: "/r/dash", inRoot: false),
    RootPathCase(path: "/r", inRoot: false),
    RootPathCase(path: "/", inRoot: false),
    RootPathCase(path: "/home/r/dashboard", inRoot: false),
]

struct RootArgumentCase: Sendable, CustomTestStringConvertible {
    let argument: String
    let inRoot: Bool
    var testDescription: String { "\(argument) is \(inRoot ? "in" : "not in") /r/x" }
}

private let rootArgumentCases = [
    // The argument is a path in the root, or is the part of `name=path` after the `=`.
    RootArgumentCase(argument: "/r/x", inRoot: true),
    RootArgumentCase(argument: "/r/x/", inRoot: true),
    RootArgumentCase(argument: "/r/x/src/main.ts", inRoot: true),
    RootArgumentCase(argument: "--cwd=/r/x", inRoot: true),
    RootArgumentCase(argument: "--config=/r/x/conf.json", inRoot: true),
    // A folder that begins like the root.
    RootArgumentCase(argument: "/r/xylophone", inRoot: false),
    RootArgumentCase(argument: "/r/x-other/file", inRoot: false),
    RootArgumentCase(argument: "--cwd=/r/xylophone", inRoot: false),
    // The root somewhere in the middle of the argument.
    RootArgumentCase(argument: "/elsewhere/r/x/file", inRoot: false),
    RootArgumentCase(argument: "--flag=/elsewhere/r/x", inRoot: false),
    RootArgumentCase(argument: "-I/r/x/include", inRoot: false),
    RootArgumentCase(argument: "file:///r/x/file", inRoot: false),
    RootArgumentCase(argument: "a=b=/r/x", inRoot: false),  // only the first `=` splits
    RootArgumentCase(argument: "r/x/file", inRoot: false),  // not an absolute path
    RootArgumentCase(argument: "--cwd=r/x", inRoot: false),
    // A path that goes up out of the root again.
    RootArgumentCase(argument: "/r/x/../y", inRoot: false),
    RootArgumentCase(argument: "--cwd=/r/x/..", inRoot: false),
]

extension ProcessAttributorTests {
    /// The order of the rules: the folder of the process, the folder of its nearest ancestor that is in a worktree, and
    /// last its executable and its arguments. The deepest worktree wins in each.
    @Suite struct WhichWorktree {
        @Test(arguments: rootPathCases) func aPathIsInARootByFolderNotByCharacters(_ pathCase: RootPathCase) {
            // The same path as the folder, as the executable and as an argument of three processes, each in `/`
            // otherwise: all three are in the root, or none is.
            let processes = [
                proc(10, "a", parent: nobody, cwd: pathCase.path),
                proc(11, "b", parent: nobody, exe: pathCase.path),
                proc(12, "c", parent: nobody, args: ["c", pathCase.path]),
            ]
            let leaders = attribute(processes, roots: ["/r/dashboard"])["/r/dashboard"]?.map(\.leader.pid)
            #expect(leaders == (pathCase.inRoot ? [10, 11, 12] : nil))
        }

        @Test(arguments: rootArgumentCases) func anArgumentIsInARootOnlyByFolders(_ argumentCase: RootArgumentCase) {
            // The process sits in `/`, so its arguments are all that tie it to a worktree.
            let process = proc(10, "tool", parent: nobody, args: ["tool", argumentCase.argument])
            #expect(attribute([process], roots: ["/r/x"]).keys.contains("/r/x") == argumentCase.inRoot)
        }

        @Test func theNameThatTheProgramWasStartedByIsAnArgumentLikeAnyOther() {
            let process = proc(10, "tool", parent: nobody, exe: "/usr/bin/env", args: ["/r/x/build/tool", "--help"])
            #expect(attribute([process], roots: ["/r/x"]).keys.contains("/r/x"))
        }

        @Test func ofNestedWorktreesTheInnermostWinsWhateverTheOrderOfTheRoots() {
            let repo = "/r/dashboard"
            let nested = "/r/dashboard/.claude/worktrees/x"
            let processes = [proc(10, "node", parent: nobody, cwd: "\(nested)/src")]
            for roots in [[repo, nested], [nested, repo]] {
                #expect(attribute(processes, roots: roots).keys.sorted() == [nested])
            }
        }

        @Test func rootsAreComparedAsTheyAreGiven() {
            // Nothing is resolved here: roots arrive as the kernel reports paths, `/private/var` and never `/var`.
            let processes = [proc(10, "node", parent: nobody, cwd: "/private/var/folders/x")]
            #expect(attribute(processes, roots: ["/var/folders/x"]).isEmpty)
            #expect(attribute(processes, roots: ["/private/var/folders/x"]).keys.sorted() == ["/private/var/folders/x"])
        }

        @Test func aTrailingSlashOfARootDoesNotMatterAndTheGroupsAreKeyedByThePathAsGiven() {
            let processes = [proc(10, "node", parent: nobody, cwd: "/r/x/src")]
            #expect(attribute(processes, roots: ["/r/x/"]).keys.sorted() == ["/r/x/"])
        }

        @Test func somethingThatIsNoFolderIsNoRoot() {
            // `/` would be every process of the machine, and an empty or relative path is not a place.
            let processes = [
                proc(10, "node", parent: nobody, cwd: "/r/x"), proc(11, "sleep", parent: nobody, cwd: "/"),
            ]
            #expect(attribute(processes, roots: ["", "/", "//", "r/x", "x"]).isEmpty)
        }

        @Test func theFolderOfTheProcessIsLookedAtFirst() {
            let processes = [
                proc(10, "make", parent: nobody, cwd: "/r/a"),
                proc(11, "cc", parent: 10, cwd: "/r/b"),
            ]
            #expect(shape(attribute(processes, roots: ["/r/a", "/r/b"])) == ["/r/a": [[10]], "/r/b": [[11]]])
        }

        @Test func aChildThatHasALowerPidThanItsParentIsStillItsParentsMember() {
            // Pids wrap around at 99999, so a process that has run for long starts children with pids below its own.
            let processes = [
                proc(60, "make", parent: nobody, cwd: worktree),
                proc(20, "cc", parent: 60, cwd: "/"),
                proc(30, "ld", parent: 20, cwd: "/"),
                proc(10, "as", parent: 60, cwd: worktree),
            ]
            #expect(shape(attribute(processes)) == [worktree: [[60, 10, 20, 30]]])
        }

        @Test func theNearestAncestorThatIsInAWorktreeDecides() {
            let processes = [
                proc(10, "make", parent: nobody, cwd: "/r/a"),
                proc(11, "sh", parent: 10, cwd: "/r/b"),
                proc(12, "cc", parent: 11, cwd: "/"),  // nearer to /r/b than to /r/a
                proc(20, "make", parent: nobody, cwd: "/r/a"),
                proc(21, "sh", parent: 20, cwd: "/tmp"),  // in no worktree: the walk goes on
                proc(22, "cc", parent: 21, cwd: "/"),
            ]
            let result = shape(attribute(processes, roots: ["/r/a", "/r/b"]))
            #expect(result == ["/r/a": [[10], [20, 21, 22]], "/r/b": [[11, 12]]])
        }

        @Test func aProcessThatLaunchdAdoptedKeepsItsFolderToItself() {
            // A tmux server sits in a worktree, because it was started from there. The shells below it are in whatever
            // project their panes were opened in, and that is no worktree: the server's folder says nothing about them.
            let elsewhere = "/Users/dev/projects/other"
            let processes = [
                proc(10, "tmux", parent: 1, exe: "/opt/homebrew/bin/tmux", args: ["tmux: server"], cwd: worktree),
                proc(11, "zsh", parent: 10, exe: "/bin/zsh", args: ["-zsh"], cwd: elsewhere),
                proc(12, "vim", parent: 11, cwd: elsewhere),
                proc(13, "node", parent: 11, args: ["node", "serve.js"], cwd: elsewhere, ports: [3000]),
            ]
            let result = attribute(processes)
            #expect(shape(result) == [worktree: [[10]]])  // the server alone, and no group for what is below it
            #expect(result[worktree]?.first?.kind == .daemon && result[worktree]?.first?.title == "tmux")
        }

        @Test func onlyAProcessThatLaunchdAdoptedKeepsItsFolderToItself() {
            // The same chain twice. When another process started `make`, it passes its folder down to `cc`.
            func groups(startedBy parent: Int32) -> [String: [[Int32]]] {
                shape(
                    attribute([proc(10, "make", parent: parent, cwd: worktree), proc(11, "cc", parent: 10, cwd: "/")]))
            }
            #expect(groups(startedBy: nobody) == [worktree: [[10, 11]]])
            #expect(groups(startedBy: 0) == [worktree: [[10, 11]]])  // the kernel is not launchd
            #expect(groups(startedBy: 1) == [worktree: [[10]]])
        }

        @Test func aChildOfTheCodexDaemonThatRunsInAnotherProjectIsNotInTheWorktreeOfTheDaemon() {
            // `codex app-server` sits in the folder of the repository and launchd adopted it. What it starts runs in
            // the project that it was asked about: if that is no worktree, it is in none, and no session of this one.
            let dashboard = "/Users/dev/projects/dashboard"
            let codex = "/Users/dev/.codex/packages/app-server-daemon/releases/0.166.0-aarch64-apple-darwin/bin/codex"
            func groups(childIn folder: String) -> [String: [[Int32]]] {
                let processes = [
                    proc(10, "codex", parent: 1, exe: codex, args: [codex, "app-server", "daemon"], cwd: dashboard),
                    proc(11, "codex", parent: 10, exe: codex, args: [codex, "exec", "fix the tests"], cwd: folder),
                ]
                return shape(attribute(processes, roots: [dashboard]))
            }
            #expect(groups(childIn: "/Users/dev/projects/other") == [dashboard: [[10]]])
            // In the repository, it is a session of it by its own folder.
            #expect(groups(childIn: "\(dashboard)/apps/web") == [dashboard: [[10], [11]]])
        }

        @Test func anAncestorBeatsWhatTheProcessItselfRunsAndIsGiven() {
            let child = proc(11, "tool", parent: 10, args: ["tool", "/r/b/file"])
            let withAncestor = [proc(10, "make", parent: nobody, cwd: "/r/a"), child]
            let withoutAncestor = [proc(10, "make", parent: nobody, cwd: "/r/c"), child]
            #expect(shape(attribute(withAncestor, roots: ["/r/a", "/r/b"])) == ["/r/a": [[10, 11]]])
            #expect(shape(attribute(withoutAncestor, roots: ["/r/a", "/r/b"])) == ["/r/b": [[11]]])
        }

        @Test func theDeepestRootOfTheExecutableAndTheArgumentsWins() {
            let roots = ["/r/a", "/r/b/c", "/r/d/e"]
            func rootOf(exe: String, args: [String]) -> [String] {
                attribute([proc(10, "tool", parent: nobody, exe: exe, args: args)], roots: roots).keys.sorted()
            }
            // The deeper of the two, whichever of the executable and the arguments it is found in.
            #expect(rootOf(exe: "/r/a/bin/tool", args: ["tool", "/r/b/c/file"]) == ["/r/b/c"])
            #expect(rootOf(exe: "/r/b/c/bin/tool", args: ["tool", "/r/a/file"]) == ["/r/b/c"])
            // As deep as each other: the executable first, then the arguments in the order that they are given.
            #expect(rootOf(exe: "/r/d/e/bin/tool", args: ["tool", "/r/b/c/file"]) == ["/r/d/e"])
            #expect(rootOf(exe: "/usr/bin/tool", args: ["tool", "/r/d/e/x", "/r/b/c/y"]) == ["/r/d/e"])
            #expect(rootOf(exe: "/usr/bin/tool", args: ["tool", "/r/b/c/y", "/r/d/e/x"]) == ["/r/b/c"])
        }

        @Test func aProcessWithoutAFolderIsLookedAtThroughItsAncestors() {
            let processes = [
                proc(10, "make", parent: nobody, cwd: worktree),
                proc(11, "cc", parent: 10, cwd: nil),
                proc(20, "lonely", parent: nobody, binaryDeleted: true, args: [], cwd: nil),
            ]
            #expect(shape(attribute(processes)) == [worktree: [[10, 11]]])
        }

        @Test func aProcessThatRunsNowhereNearAWorktreeIsLeftOut() {
            let processes = [
                proc(10, "Safari", parent: 1, args: ["/Applications/Safari.app/Contents/MacOS/Safari"]),
                proc(11, "zsh", parent: 10, args: ["-zsh"], cwd: "/Users/dev"),
            ]
            #expect(attribute(processes).isEmpty)
        }
    }
}

// MARK: - Agent sessions

struct AgentCase: Sendable, CustomTestStringConvertible {
    let name: String
    let executable: String?
    /// The first argument: how the program was called. The name, if a case leaves it out.
    var startedAs: String?
    let isSession: Bool
    var testDescription: String {
        "\(name) from \(executable ?? "a deleted file"), started as \(startedAs ?? name)"
    }
}

private let agentCases = [
    // The kernel's name for the process is `claude`: the Claude app keeps the file under that name.
    AgentCase(name: "claude", executable: Fixture.appClaude, isSession: true),
    AgentCase(name: "claude", executable: "/usr/local/bin/claude", isSession: true),
    // The file is gone: the name is all that is left.
    AgentCase(name: "claude", executable: nil, isSession: true),
    // From the folder that the Claude app keeps it in, whatever the name.
    AgentCase(name: "node", executable: Fixture.appClaude, isSession: true),
    // The kernel's name alone, whatever the file and the name that it was started by.
    AgentCase(name: "claude", executable: "/opt/tools/launcher", startedAs: "ugrep", isSession: true),
    // The command line install: the kernel names the process after the file, which is named by its version, and only
    // the first argument says `claude`.
    AgentCase(name: "2.1.310", executable: Fixture.cliClaude, startedAs: "claude", isSession: true),
    AgentCase(name: "2.1.310", executable: nil, startedAs: "claude", isSession: true),
    AgentCase(
        name: "2.1.310", executable: Fixture.cliClaude, startedAs: "/Users/dev/.local/bin/claude", isSession: true),
    // The same file, run as something else: a tool of Claude Code, or a program whose name only ends like it.
    AgentCase(name: "2.1.310", executable: Fixture.cliClaude, startedAs: "ugrep", isSession: false),
    AgentCase(name: "2.1.310", executable: Fixture.cliClaude, startedAs: "notclaude", isSession: false),
    AgentCase(name: "2.1.310", executable: Fixture.cliClaude, startedAs: "/opt/notclaude", isSession: false),
    // The Claude app and its helpers are not sessions: the match is on case.
    AgentCase(name: "Claude", executable: "\(Fixture.claudeApp)/Contents/MacOS/Claude", isSession: false),
    AgentCase(
        name: "Claude Helper",
        executable: "\(Fixture.claudeApp)/Contents/Frameworks/Claude Helper.app/Contents/MacOS/Claude Helper",
        isSession: false),
    AgentCase(name: "claudette", executable: "/usr/bin/claudette", isSession: false),
    AgentCase(name: "node", executable: "/usr/bin/node", isSession: false),
]

struct TitleCase: Sendable, CustomTestStringConvertible {
    let startedByTheApp: Bool
    let servers: Int
    let title: String
    var testDescription: String { title }
}

private let titleCases = [
    TitleCase(startedByTheApp: false, servers: 0, title: "Claude Code · CLI"),
    TitleCase(startedByTheApp: false, servers: 1, title: "Claude Code · CLI, 1 MCP server"),
    TitleCase(startedByTheApp: false, servers: 2, title: "Claude Code · CLI, 2 MCP servers"),
    TitleCase(startedByTheApp: false, servers: 5, title: "Claude Code · CLI, 5 MCP servers"),
    TitleCase(startedByTheApp: true, servers: 0, title: "Claude Code · desktop"),
    TitleCase(startedByTheApp: true, servers: 1, title: "Claude Code · desktop, 1 MCP server"),
    TitleCase(startedByTheApp: true, servers: 2, title: "Claude Code · desktop, 2 MCP servers"),
    TitleCase(startedByTheApp: true, servers: 5, title: "Claude Code · desktop, 5 MCP servers"),
]

private let disclaimer = "\(Fixture.claudeApp)/Contents/Helpers/disclaimer"

extension ProcessAttributorTests {
    @Suite struct Sessions {
        @Test(arguments: agentCases) func claudeCodeIsKnownByItsNameTheNameItWasStartedByOrWhereItRunsFrom(
            _ agentCase: AgentCase
        ) {
            let process = proc(
                10, agentCase.name, parent: nobody, exe: agentCase.executable,
                binaryDeleted: agentCase.executable == nil, args: [agentCase.startedAs ?? agentCase.name],
                cwd: worktree)
            #expect(attribute([process])[worktree]?.first?.kind == (agentCase.isSession ? .agentSession : .other))
        }

        @Test func codexIsASessionUnlessItIsTheAppServer() throws {
            func groups(_ arguments: [String], parent: Int32) -> [ProcessGroup] {
                let codex = proc(10, "codex", parent: parent, args: arguments, cwd: worktree)
                let server = proc(11, "node", parent: 10, args: ["node", "some-mcp-server.js"], cwd: worktree)
                return attribute([codex, server])[worktree] ?? []
            }

            let session = try #require(groups(["codex", "resume"], parent: nobody).first)
            #expect(session.kind == .agentSession && session.members.map(\.pid) == [11])
            #expect(session.title == "Codex CLI")  // whatever its children are

            // The daemon is the same program, with the argument `app-server` of its own.
            let daemon = try #require(groups(["codex", "app-server", "daemon"], parent: 1).first)
            #expect(daemon.kind == .daemon && daemon.title == "codex" && daemon.members.map(\.pid) == [11])
            // A word that only begins like it does not make it the daemon.
            #expect(groups(["codex", "app-server-notes"], parent: nobody).first?.kind == .agentSession)
        }

        @Test func anAppSessionIsToldByTheHelperThatStartedIt() throws {
            func session(helper: ProcessRecord) throws -> ProcessGroup {
                let claude = proc(11, "claude", parent: helper.pid, exe: Fixture.appClaude, cwd: worktree)
                return try #require(attribute([helper, claude])[worktree]?.first { $0.kind == .agentSession })
            }

            // The helper of the Claude app, wherever the app is installed.
            for path in [disclaimer, "/Users/dev/Applications/Claude.app/Contents/Helpers/disclaimer"] {
                let group = try session(helper: proc(10, "disclaimer", parent: 1, exe: path, cwd: worktree))
                #expect(group.title == "Claude Code · desktop" && group.members.map(\.pid) == [10])
            }
            // In the real world its folder is often a spare one that is in no worktree: it is the session's all the
            // same.
            let spare = try session(
                helper: proc(10, "disclaimer", parent: 1, exe: disclaimer, cwd: "/Users/dev/.claude/x"))
            #expect(spare.title == "Claude Code · desktop" && spare.members.map(\.pid) == [10])
            // Another program that is called `disclaimer` is not it.
            let other = try session(
                helper: proc(10, "disclaimer", parent: 1, exe: "/usr/local/bin/disclaimer", cwd: worktree))
            #expect(other.title == "Claude Code · CLI" && other.members.isEmpty)
        }

        @Test func theHelperIsPartOfTheSessionOnlyAsItsParent() throws {
            let processes = [
                proc(10, "disclaimer", parent: 1, exe: disclaimer, cwd: worktree),
                proc(11, "zsh", parent: 10, exe: "/bin/zsh", args: ["-zsh"], cwd: worktree),
                proc(12, "claude", parent: 11, exe: Fixture.appClaude, cwd: worktree),
            ]
            let session = try #require(attribute(processes)[worktree]?.first { $0.kind == .agentSession })
            #expect(session.title == "Claude Code · CLI" && pids(of: session) == [12])
        }

        @Test func theHelperIsPartOfTheSessionWhateverWorktreeItIsIn() {
            // The helper is started with the command line of `claude` after `--`, so an `--add-dir` of another
            // worktree is in its arguments too, and the Claude app may have started it in a folder of that worktree.
            let command = [Fixture.appClaude, "--add-dir", "/r/b"]
            for folder in ["/Users/dev/.claude/spares/x", "/r/b"] {
                let processes = [
                    proc(
                        10, "disclaimer", parent: 1, exe: disclaimer, args: [disclaimer, "--pgroup", "--"] + command,
                        cwd: folder),
                    proc(11, "claude", parent: 10, exe: Fixture.appClaude, args: command, cwd: "/r/a"),
                ]
                let result = attribute(processes, roots: ["/r/a", "/r/b"])
                #expect(shape(result) == ["/r/a": [[11, 10]]])
                #expect(result["/r/a"]?.first?.title == "Claude Code · desktop")
            }
        }

        @Test(arguments: titleCases) func theTitleSaysWhereItRunsFromAndHowManyServers(_ titleCase: TitleCase) throws {
            let parent: Int32 = titleCase.startedByTheApp ? 19 : nobody
            var processes = [proc(20, "claude", parent: parent, exe: Fixture.appClaude, cwd: worktree)]
            if titleCase.startedByTheApp {
                processes.append(proc(19, "disclaimer", parent: 1, exe: disclaimer, cwd: worktree))
            }
            for server in 0..<titleCase.servers {
                processes.append(
                    proc(30 + Int32(server), "node", parent: 20, args: ["node", "s\(server)-mcp.js"], cwd: worktree))
            }
            let session = try #require(attribute(processes)[worktree]?.first { $0.kind == .agentSession })
            #expect(session.title == titleCase.title)
        }

        @Test func serversAreDirectChildrenWhoseArgumentsSayMcpInAnyCase() throws {
            let processes = [
                proc(10, "claude", parent: nobody, exe: Fixture.cliClaude, args: ["claude"], cwd: worktree),
                proc(11, "node", parent: 10, args: ["node", "/x/FIGMA-Mcp/index.js"], cwd: worktree),  // any case
                proc(12, "uvx", parent: 10, args: ["uvx", "serena", "start-MCP-server"], cwd: worktree),
                // Not a server: nothing in its arguments says so.
                proc(13, "node", parent: 10, args: ["node", "build.js"], cwd: worktree),
                // Only the file says it, and that is not an argument.
                proc(14, "helper", parent: 10, exe: "/x/mcp-helper", args: ["helper"], cwd: worktree),
                // A server of a server: not a child of `claude`.
                proc(15, "node", parent: 11, args: ["node", "/x/figma-mcp/watchdog.js"], cwd: worktree),
                // A server that is run by its path: the name that it was started by is an argument as well.
                proc(16, "plata-mcp", parent: 10, args: ["/opt/bin/plata-mcp"], cwd: worktree),
            ]
            let session = try #require(attribute(processes)[worktree]?.first)
            #expect(session.title == "Claude Code · CLI, 3 MCP servers")
            #expect(session.members.map(\.pid) == [11, 12, 13, 14, 15, 16])  // and all of them are in the session
        }

        @Test func aSessionIsAllItsDescendantsWhateverTheyAreCalledAndWhereTheyRun() {
            // `claude` is in the worktree through an argument only, so nothing of its children says "worktree":
            // they are the session's all the same, down to the first that is in another worktree.
            let processes = [
                proc(10, "claude", parent: nobody, exe: Fixture.cliClaude, args: ["claude", "--add-dir", worktree]),
                proc(11, "node", parent: 10, args: ["node", "server.js"], cwd: "/tmp"),
                proc(12, "sh", parent: 11, cwd: "/"),
                proc(13, "esbuild", parent: 11, cwd: "\(worktree)/apps"),
                proc(14, "make", parent: 11, cwd: "/r/b"),
                proc(15, "cc", parent: 14, cwd: "/"),
            ]
            let result = attribute(processes, roots: [worktree, "/r/b"])
            #expect(shape(result) == [worktree: [[10, 11, 12, 13]], "/r/b": [[14, 15]]])
        }

        @Test func aSessionInsideASessionThroughAProcessOfNoWorktreeIsStillTakenByTheOuterOne() {
            let processes = [
                proc(10, "claude", parent: nobody, exe: Fixture.cliClaude, args: ["claude", "--add-dir", worktree]),
                proc(11, "sh", parent: 10, cwd: "/tmp"),
                proc(12, "claude", parent: 11, exe: Fixture.cliClaude, args: ["claude"], cwd: "\(worktree)/apps"),
            ]
            #expect(shape(attribute(processes)) == [worktree: [[10, 11, 12]]])
        }

        @Test func aChildInAnotherWorktreeIsNotInTheSession() throws {
            let processes = [
                proc(100, "claude", parent: nobody, exe: Fixture.cliClaude, args: ["claude"], cwd: "/r/a"),
                proc(101, "node", parent: 100, args: ["node", "a-mcp.js"], cwd: "/r/a"),
                proc(102, "node", parent: 100, args: ["node", "b-mcp.js"], cwd: "/r/b"),
                proc(103, "esbuild", parent: 102, cwd: "/"),
            ]
            let result = attribute(processes, roots: ["/r/a", "/r/b"])
            let session = try theOnly(result["/r/a"])
            let other = try theOnly(result["/r/b"])
            #expect(session.kind == .agentSession && pids(of: session) == [100, 101])
            // The server of the other worktree is not counted.
            #expect(session.title == "Claude Code · CLI, 1 MCP server")
            // Its parent is in another worktree, so it leads a group there, with the process that follows it.
            #expect(other.kind == .other && other.title == "node" && pids(of: other) == [102, 103])
        }

        @Test func aSessionInsideASessionOfTheSameWorktreeIsOneGroup() throws {
            // `claude mcp serve` is a server of the session, and the kernel calls it `claude` as well.
            let processes = [
                proc(100, "claude", parent: nobody, exe: Fixture.cliClaude, args: ["claude"], cwd: "/r/a"),
                proc(
                    101, "claude", parent: 100, exe: Fixture.cliClaude, args: ["claude", "mcp", "serve"], cwd: "/r/a"),
                proc(102, "node", parent: 101, cwd: "/r/a"),
            ]
            let session = try theOnly(attribute(processes, roots: ["/r/a"])["/r/a"])
            #expect(session.leader.pid == 100 && session.members.map(\.pid) == [101, 102])
            #expect(session.title == "Claude Code · CLI, 1 MCP server")
        }

        @Test func aSessionInsideASessionOfAnotherWorktreeIsASessionOfItsOwn() {
            let processes = [
                proc(100, "claude", parent: nobody, exe: Fixture.cliClaude, args: ["claude"], cwd: "/r/a"),
                proc(
                    101, "claude", parent: 100, exe: Fixture.cliClaude, args: ["claude", "mcp", "serve"], cwd: "/r/b"),
                proc(102, "node", parent: 101, cwd: "/"),
            ]
            let result = attribute(processes, roots: ["/r/a", "/r/b"])
            #expect(shape(result) == ["/r/a": [[100]], "/r/b": [[101, 102]]])
            #expect(result["/r/a"]?.first?.title == "Claude Code · CLI")  // `claude mcp serve` is not its server
            #expect(result["/r/b"]?.first?.kind == .agentSession)
        }

        @Test func aSessionThatLaunchdAdoptedTakesOnlyWhatIsInItsWorktreeByItself() throws {
            // The shell of the session is gone, so launchd adopted it: the folder it sits in is not passed down to what
            // it started. What is in the worktree by its own folder is still the session's.
            func session(startedBy parent: Int32) throws -> ProcessGroup {
                let processes = [
                    proc(10, "claude", parent: parent, exe: Fixture.cliClaude, args: ["claude"], cwd: worktree),
                    proc(11, "node", parent: 10, args: ["node", "a-mcp.js"], cwd: worktree),
                    proc(12, "node", parent: 10, args: ["node", "b-mcp.js"], cwd: "/"),
                    proc(13, "sh", parent: 12, cwd: "/"),
                ]
                return try theOnly(attribute(processes)[worktree])
            }
            let started = try session(startedBy: nobody)
            #expect(pids(of: started) == [10, 11, 12, 13] && started.title == "Claude Code · CLI, 2 MCP servers")
            let adopted = try session(startedBy: 1)
            #expect(pids(of: adopted) == [10, 11] && adopted.title == "Claude Code · CLI, 1 MCP server")
        }

        @Test func aSessionInsideASessionIsTakenByTheOuterOneWhateverTheirPids() {
            // Pids wrap around: the inner `claude` was started later, and has the lower pid.
            let processes = [
                proc(60, "claude", parent: nobody, exe: Fixture.cliClaude, args: ["claude"], cwd: worktree),
                proc(
                    20, "claude", parent: 60, exe: Fixture.cliClaude, args: ["claude", "mcp", "serve"], cwd: worktree),
                proc(30, "node", parent: 20, cwd: worktree),
            ]
            #expect(shape(attribute(processes)) == [worktree: [[60, 20, 30]]])
        }

        @Test func aSessionInsideAProcessThatIsNoSessionOfTheWorktreeIsASessionOfItsOwn() {
            // The outer `claude` is in no worktree at all, so it has no session to take the inner one into.
            let processes = [
                proc(100, "claude", parent: nobody, exe: Fixture.cliClaude, args: ["claude"], cwd: "/"),
                proc(101, "claude", parent: 100, exe: Fixture.cliClaude, args: ["claude"], cwd: worktree),
                proc(102, "node", parent: 101, args: ["node", "x-mcp.js"], cwd: worktree),
            ]
            let result = attribute(processes)
            #expect(shape(result) == [worktree: [[101, 102]]])
            #expect(result[worktree]?.first?.kind == .agentSession)
            #expect(result[worktree]?.first?.title == "Claude Code · CLI, 1 MCP server")
        }

        @Test func aSessionBehindAProcessOfAnotherWorktreeIsASessionOfItsOwn() {
            // /r/a: `claude` starts a shell that sits in /r/b, and the shell starts another `claude` in /r/a. The first
            // cannot take the second: between them is a process that is not in /r/a.
            let processes = [
                proc(100, "claude", parent: nobody, exe: Fixture.cliClaude, args: ["claude"], cwd: "/r/a"),
                proc(101, "sh", parent: 100, cwd: "/r/b"),
                proc(102, "claude", parent: 101, exe: Fixture.cliClaude, args: ["claude"], cwd: "/r/a"),
            ]
            let result = attribute(processes, roots: ["/r/a", "/r/b"])
            #expect(shape(result) == ["/r/a": [[100], [102]], "/r/b": [[101]]])
            #expect(result["/r/a"]?.map(\.kind) == [.agentSession, .agentSession])
        }

        @Test func aProcessThatTheHelperStartedBesidesTheSessionLeadsAGroupOfItsOwn() {
            let processes = [
                proc(10, "disclaimer", parent: 1, exe: disclaimer, cwd: worktree),
                proc(11, "claude", parent: 10, exe: Fixture.appClaude, args: ["claude"], cwd: worktree),
                proc(12, "sleep", parent: 10, cwd: worktree),
            ]
            // The helper is the session's. Its other child is not a member of anything but a group of its own.
            #expect(shape(attribute(processes)) == [worktree: [[11, 10], [12]]])
        }

        @Test func aHelperThatSeveralSessionsHaveAsTheirParentIsTheOneOfTheLowestPid() {
            // Not what the Claude app does, but a sample can be anything: the helper is taken once, by the lowest pid.
            let sessions = (201...206).map { proc($0, "claude", parent: 100, exe: Fixture.appClaude, cwd: worktree) }
            let result = attribute([proc(100, "disclaimer", parent: 1, exe: disclaimer, cwd: worktree)] + sessions)
            #expect(shape(result) == [worktree: [[201, 100], [202], [203], [204], [205], [206]]])
            #expect(
                result[worktree]?.map(\.title) == ["Claude Code · desktop"]
                    + Array(repeating: "Claude Code · CLI", count: 5))
        }

        @Test func twoSessionsOfOneWorktreeAreTwoGroups() {
            let processes = [
                proc(10, "zsh", parent: nobody, exe: "/bin/zsh", args: ["-zsh"], cwd: worktree, mb: 5),
                proc(11, "claude", parent: 10, exe: Fixture.cliClaude, args: ["claude"], cwd: worktree, mb: 300),
                proc(12, "node", parent: 11, args: ["node", "a-mcp.js"], cwd: worktree, mb: 20),
                proc(13, "claude", parent: 10, exe: Fixture.cliClaude, args: ["claude"], cwd: worktree, mb: 200),
            ]
            let groups = attribute(processes)[worktree] ?? []
            #expect(groups.map(\.kind) == [.agentSession, .agentSession, .shell])
            #expect(groups.map(pids(of:)) == [[11, 12], [13], [10]])
        }

        @Test func aSessionStaysASessionWhenSomethingOfItListens() throws {
            let processes = [
                proc(10, "claude", parent: nobody, exe: Fixture.cliClaude, args: ["claude"], cwd: worktree),
                proc(11, "node", parent: 10, args: ["node", "http-mcp.js"], cwd: worktree, ports: [3000]),
            ]
            let session = try #require(attribute(processes)[worktree]?.first)
            #expect(session.kind == .agentSession && session.ports == [3000])
            #expect(session.title == "Claude Code · CLI, 1 MCP server")  // not the name of what listens
        }
    }
}

// MARK: - Groups of everything else

struct ShellCase: Sendable, CustomTestStringConvertible {
    let name: String
    let arguments: [String]
    let isShell: Bool
    var testDescription: String { "\(name) \(arguments)" }
}

private let shellCases = [
    // A login shell: the kernel's name has no dash, the first argument has.
    ShellCase(name: "zsh", arguments: ["-zsh"], isShell: true),
    ShellCase(name: "zsh", arguments: ["zsh"], isShell: true),
    ShellCase(name: "bash", arguments: ["bash", "-l"], isShell: true),
    ShellCase(name: "fish", arguments: ["fish"], isShell: true),
    ShellCase(name: "sh", arguments: ["/bin/sh", "-c", "sleep 100"], isShell: true),
    ShellCase(name: "ksh", arguments: ["-ksh"], isShell: true),  // a login shell that is not on the list
    ShellCase(name: "shasum", arguments: ["shasum"], isShell: false),
    ShellCase(name: "zshrc-watcher", arguments: ["zshrc-watcher"], isShell: false),
    // Only the first argument is the name that the program was started by.
    ShellCase(name: "node", arguments: ["node", "-zsh"], isShell: false),
    ShellCase(name: "node", arguments: [""], isShell: false),
    ShellCase(name: "node", arguments: [], isShell: false),  // the arguments could not be read
]

struct KindCase: Sendable, CustomTestStringConvertible {
    let ports: [UInt16]
    let parent: Int32
    let runsFromTheWorktree: Bool
    let name: String
    let kind: ProcessKind
    var testDescription: String {
        let startedBy = parent == 1 ? "launchd" : "another"
        return "\(name), ports \(ports), parent \(startedBy), \(runsFromTheWorktree ? "built here" : "elsewhere")"
    }
}

private let kindCases = [
    // A shell that listens, runs a file of the worktree and was started by launchd. Each case leaves out what made the
    // one before it what it is.
    KindCase(ports: [8080], parent: 1, runsFromTheWorktree: true, name: "zsh", kind: .devServer),
    // An app that is opened from the Finder has launchd for its parent: the file that it runs says what it is.
    KindCase(ports: [], parent: 1, runsFromTheWorktree: true, name: "zsh", kind: .builtHere),
    KindCase(ports: [], parent: 1, runsFromTheWorktree: false, name: "zsh", kind: .daemon),
    KindCase(ports: [], parent: nobody, runsFromTheWorktree: false, name: "zsh", kind: .shell),
    KindCase(ports: [], parent: nobody, runsFromTheWorktree: false, name: "node", kind: .other),
    // The file of the worktree says it just as well when another process started it.
    KindCase(ports: [], parent: nobody, runsFromTheWorktree: true, name: "zsh", kind: .builtHere),
    // Only what launchd started is a daemon: the parent of launchd itself is the kernel.
    KindCase(ports: [], parent: 0, runsFromTheWorktree: false, name: "node", kind: .other),
]

extension ProcessAttributorTests {
    /// Everything that is not a session: a group of a process that was not started in its worktree, with the processes
    /// that it started there.
    @Suite struct Groups {
        @Test(arguments: shellCases) func aShellIsKnownByItsNameOrByTheDashOfALoginShell(_ shellCase: ShellCase) {
            let process = proc(10, shellCase.name, parent: nobody, args: shellCase.arguments, cwd: worktree)
            #expect(attribute([process])[worktree]?.first?.kind == (shellCase.isShell ? .shell : .other))
        }

        @Test(arguments: kindCases) func theKindIsTheFirstRuleThatFits(_ kindCase: KindCase) {
            let leader = proc(
                10, kindCase.name, parent: kindCase.parent,
                exe: kindCase.runsFromTheWorktree ? "\(worktree)/build/\(kindCase.name)" : "/usr/bin/\(kindCase.name)",
                cwd: worktree,
                ports: kindCase.ports)
            #expect(attribute([leader])[worktree]?.first?.kind == kindCase.kind)
        }

        @Test func aShellThatRunsAServerIsOneGroupTitledByTheServer() throws {
            // The shell started in the worktree by something outside it, so it leads, and the server is its member.
            let processes = [
                proc(10, "zsh", parent: nobody, exe: "/bin/zsh", args: ["-zsh"], cwd: worktree),
                proc(11, "node", parent: 10, args: ["node", "serve.js"], cwd: worktree, ports: [4200]),
                proc(12, "esbuild", parent: 11, cwd: worktree),
            ]
            let group = try theOnly(attribute(processes)[worktree])
            #expect(group.kind == .devServer && group.leader.name == "zsh")
            #expect(group.title == "node")  // what listens is what the group is, not the shell that started it
            #expect(group.ports == [4200] && pids(of: group) == [10, 11, 12])
        }

        @Test func aDevServerIsTitledByTheFirstByPidOfTheProcessesThatListen() {
            // Two servers under a shell. The one with the lower pid is not the first listed, and that is no matter.
            let servers = [
                proc(10, "zsh", parent: nobody, exe: "/bin/zsh", args: ["-zsh"], cwd: worktree),
                proc(30, "vite", parent: 10, cwd: worktree, ports: [5173]),
                proc(20, "node", parent: 10, cwd: worktree, ports: [4200]),
                proc(25, "esbuild", parent: 20, cwd: worktree),
            ]
            #expect(attribute(servers)[worktree]?.map(\.title) == ["node"])

            // The leader is one of the listeners: it is the title if its pid is the lowest, and not otherwise (a pid
            // that wrapped around is below that of the parent that started it).
            let leaderFirst = [
                proc(10, "node", parent: nobody, cwd: worktree, ports: [4200]),
                proc(20, "ws", parent: 10, cwd: worktree, ports: [9229]),
            ]
            let memberFirst = [
                proc(60, "npm", parent: nobody, cwd: worktree, ports: [3000]),
                proc(20, "node", parent: 60, cwd: worktree, ports: [4200]),
            ]
            #expect(attribute(leaderFirst)[worktree]?.map(\.title) == ["node"])
            #expect(attribute(memberFirst)[worktree]?.map(\.title) == ["node"])
        }

        @Test func aGroupThatDoesNotListenIsTitledByItsLeader() {
            // A shell, a built app, a daemon and any other process: no listener, so the name of the leader.
            let processes = [
                proc(10, "zsh", parent: nobody, exe: "/bin/zsh", args: ["-zsh"], cwd: worktree),
                proc(11, "node", parent: 10, args: ["node", "build.js"], cwd: worktree),
            ]
            #expect(attribute(processes)[worktree]?.map(\.title) == ["zsh"])
        }

        @Test func aDeletedBinaryIsNeverBuiltHere() {
            // The arguments say where it ran from, so it is in the worktree. The file is gone, and no file is no proof.
            let path = "\(worktree)/build/Minuta.app/Contents/MacOS/Minuta"
            let present = proc(10, "Minuta", parent: nobody, exe: path, args: [path])
            let deleted = proc(10, "Minuta", parent: nobody, binaryDeleted: true, args: [path])
            #expect(attribute([present])[worktree]?.first?.kind == .builtHere)
            #expect(attribute([deleted])[worktree]?.first?.kind == .other)
            // Started by launchd, it is what launchd's children are: no file, no "built here".
            let orphan = proc(10, "Minuta", parent: 1, binaryDeleted: true, args: [path])
            #expect(attribute([orphan])[worktree]?.first?.kind == .daemon)
        }

        @Test func anAppThatLaunchdStartedIsBuiltHereWhenItRunsAFileOfTheWorktree() throws {
            // An app that is opened from the Finder has launchd for its parent. The file that it runs says what it is,
            // and `Minuta.app` from DerivedData is the example of a build product.
            let minuta = "/Users/dev/projects/minuta"
            for parent: Int32 in [1, 4_000] {
                let group = try theOnly(
                    attribute(Fixture.builtApp(in: minuta, startedBy: parent), roots: [minuta])[minuta])
                #expect(group.leader.ppid == parent)
                #expect(group.kind == .builtHere && group.title == "Minuta")
            }
        }

        @Test func builtHereIsAboutTheWorktreeThatTheGroupIsIn() {
            let repo = "/r/dashboard"
            let nested = "/r/dashboard/.claude/worktrees/x"
            // In the worktree `x`, running a program that the repository built: not one that was built in `x`.
            let ofTheRepo = proc(10, "tool", parent: nobody, exe: "\(repo)/dist/tool", cwd: nested)
            let ofTheWorktree = proc(11, "tool", parent: nobody, exe: "\(nested)/dist/tool", cwd: nested)
            #expect(attribute([ofTheRepo], roots: [repo, nested])[nested]?.first?.kind == .other)
            #expect(attribute([ofTheWorktree], roots: [repo, nested])[nested]?.first?.kind == .builtHere)
        }

        @Test func aProcessThatIsInNoWorktreeIsNotPulledInByItsParent() throws {
            // The app is in the worktree by the file that it runs, and so is its helper. Whatever else the app starts
            // is not: nothing about it says "worktree", and what started a process is no proof of where it belongs.
            let app = "\(worktree)/build/Minuta.app/Contents/MacOS/Minuta"
            let processes = [
                proc(10, "Minuta", parent: nobody, exe: app, args: [app]),
                proc(11, "MinutaHelper", parent: 10, exe: "\(worktree)/build/Minuta.app/Contents/Helpers/MinutaHelper"),
                proc(12, "curl", parent: 11),
                proc(13, "zsh", parent: 10, exe: "/bin/zsh", args: ["-zsh"]),
                // In the worktree again, further down: a group of its own, as its parent is not in it.
                proc(14, "node", parent: 13, args: ["node", "serve.js"], cwd: worktree),
                proc(20, "Safari", parent: nobody, args: ["/Applications/Safari.app/Contents/MacOS/Safari"]),
            ]
            let groups = try #require(attribute(processes)[worktree])
            #expect(groups.map(pids(of:)) == [[10, 11], [14]])
            #expect(groups.first?.kind == .builtHere)
        }
    }
}

// MARK: - Samples that are not as they should be

extension ProcessAttributorTests {
    @Suite struct OddSamples {
        @Test func aLoopOfParentsEndsTheWalk() {
            // A pid that was reused while the sample was taken can make two processes each other's parent.
            let pair = [proc(10, "a", parent: 11, cwd: "/"), proc(11, "b", parent: 10, cwd: worktree)]
            #expect(shape(attribute(pair)) == [worktree: [[11, 10]]])

            // A loop has no first process. The walk up from the lowest pid goes round once and ends at the last: that
            // one leads, so that the same loop always gives the same group.
            let ring = (Int32(10)...15).map { (pid: Int32) -> ProcessRecord in
                let next: Int32 = pid == 15 ? 10 : pid + 1
                return proc(pid, "p\(pid)", parent: next, cwd: pid == 12 ? worktree : "/")
            }
            #expect(shape(attribute(ring)) == [worktree: [[15, 10, 11, 12, 13, 14]]])

            // A loop that is in no worktree is in no group.
            let nowhere = [proc(20, "a", parent: 21), proc(21, "b", parent: 22), proc(22, "c", parent: 20)]
            #expect(attribute(nowhere).isEmpty)
        }

        @Test func aProcessThatIsItsOwnParent() {
            #expect(shape(attribute([proc(10, "a", parent: 10, cwd: worktree)])) == [worktree: [[10]]])
            #expect(attribute([proc(11, "a", parent: 11)]).isEmpty)
        }

        @Test func launchdAndTheKernelAreNeverInAGroup() {
            // Not that a sample has them (it is the user's processes), but if it does they are no one's parent.
            let processes = [
                proc(0, "kernel_task", parent: 0, cwd: worktree),
                proc(1, "launchd", parent: 0, cwd: worktree),
                proc(10, "a", parent: 1, cwd: "/"),  // started by launchd, which is in the worktree: no matter
                proc(11, "b", parent: 1, cwd: worktree),
            ]
            #expect(shape(attribute(processes)) == [worktree: [[11]]])
        }

        @Test func aPidThatIsInTheSampleTwiceCountsOnce() {
            let processes = [
                proc(10, "first", parent: nobody, cwd: worktree, mb: 1),
                proc(10, "second", parent: nobody, cwd: worktree, mb: 2),
            ]
            let groups = attribute(processes)[worktree] ?? []
            #expect(groups.map(\.title) == ["first"] && groups.first?.members.isEmpty == true)
        }

        @Test func nothingInAndNothingOutGiveNothing() {
            #expect(attribute([]).isEmpty)
            #expect(attribute(Fixture.desktopSession(in: worktree), roots: []).isEmpty)
        }
    }
}

// MARK: - Order

/// All the shapes, over several worktrees, and some that are not as they should be.
private let richSample: [ProcessRecord] =
    Fixture.desktopSession(in: "/r/a") + Fixture.cliSession(in: "/r/a") + Fixture.builtApp(in: "/r/b")
    + Fixture.codexDaemon(in: "/r/c") + Fixture.devServer(in: "/r/c")
    + [
        // A helper with two sessions: it can be part of one only.
        proc(2000, "disclaimer", parent: 500, exe: disclaimer, cwd: "/r/a"),
        proc(2001, "claude", parent: 2000, exe: Fixture.appClaude, cwd: "/r/a", mb: 10),
        proc(2002, "claude", parent: 2000, exe: Fixture.appClaude, cwd: "/r/a", mb: 10),
        // A session with a session inside, and a child of that one in another worktree.
        proc(2010, "claude", parent: nobody, exe: Fixture.cliClaude, args: ["claude"], cwd: "/r/b"),
        proc(2011, "claude", parent: 2010, exe: Fixture.cliClaude, args: ["claude", "mcp", "serve"], cwd: "/r/b"),
        proc(2012, "node", parent: 2011, cwd: "/r/c"),
        // Loops, a process of its own parent, and a process of the nested worktree.
        proc(2020, "a", parent: 2021, cwd: "/r/b"),
        proc(2021, "b", parent: 2020, cwd: "/"),
        proc(2030, "c", parent: 2030, cwd: "/r/c"),
        proc(2040, "make", parent: nobody, cwd: "/r/c"),
        proc(2041, "cc", parent: 2040, cwd: "/r/c/.claude/worktrees/x"),
        proc(2042, "ld", parent: 2041, cwd: "/"),
        // Not a user's process, and not a process.
        proc(1, "launchd", parent: 0, cwd: "/r/a"),
        proc(0, "kernel_task", parent: 0, cwd: "/r/a"),
    ]
private let richRoots = ["/r/a", "/r/b", "/r/c", "/r/c/.claude/worktrees/x"]

extension ProcessAttributorTests {
    /// Groups ordered by memory, then by the pid of the leader; members by pid. Whatever the order of the sample.
    @Suite struct Order {
        @Test func groupsAreOrderedByMemoryThenByTheLeadersPid() {
            // Scrambled on purpose. 20 and 30 use as much as each other; 40 has the most because of its member.
            let processes = [
                proc(30, "python", parent: nobody, cwd: worktree, mb: 50),
                proc(41, "cc", parent: 40, cwd: worktree, mb: 100),
                proc(10, "zsh", parent: nobody, cwd: worktree, mb: 5),
                proc(20, "node", parent: nobody, cwd: worktree, mb: 50),
                proc(40, "make", parent: nobody, cwd: worktree, mb: 10),
            ]
            #expect(attribute(processes)[worktree]?.map(\.leader.pid) == [40, 20, 30, 10])
        }

        @Test func membersAreInOrderOfPidWhateverTheShapeOfTheTree() {
            let processes = [
                proc(14, "d", parent: 10, cwd: worktree),
                proc(11, "a", parent: 14, cwd: worktree),
                proc(13, "c", parent: 10, cwd: worktree),
                proc(10, "make", parent: nobody, cwd: worktree),
                proc(12, "b", parent: 13, cwd: worktree),
            ]
            #expect(attribute(processes)[worktree]?.first?.members.map(\.pid) == [11, 12, 13, 14])
        }

        @Test func theOrderOfTheSampleDoesNotChangeTheResult() {
            let expected = attribute(richSample, roots: richRoots)
            #expect(Set(expected.keys) == Set(richRoots))  // not an empty result that every order agrees on
            let rotated = { (by: Int) in Array(richSample[by...] + richSample[..<by]) }
            let permutations = [
                richSample.reversed(), rotated(5), rotated(17), rotated(richSample.count - 1),
                richSample.enumerated().filter { $0.offset.isMultiple(of: 2) }.map(\.element)
                    + richSample.enumerated().filter { !$0.offset.isMultiple(of: 2) }.map(\.element),
            ]
            for permutation in permutations {
                #expect(attribute(permutation, roots: richRoots) == expected)
            }
        }

        @Test func noProcessIsInTwoGroupsAndEveryGroupIsInOrder() {
            let result = attribute(richSample, roots: richRoots)
            var seen = Set<Int32>()
            for groups in result.values {
                for group in groups {
                    #expect(group.members.map(\.pid) == group.members.map(\.pid).sorted())
                    for pid in pids(of: group) {
                        #expect(pid > 1, "launchd and the kernel are in no group")
                        #expect(seen.insert(pid).inserted, "\(pid) is in two groups")
                    }
                }
                #expect(!groups.isEmpty)
                let ordered = zip(groups, groups.dropFirst()).allSatisfy { first, second in
                    first.totalFootprint > second.totalFootprint
                        || (first.totalFootprint == second.totalFootprint && first.leader.pid < second.leader.pid)
                }
                #expect(ordered)
            }
            // The sample has the helper and the two sessions of it: the helper is in one of them, once.
            #expect(seen.contains(2000) && seen.contains(2001) && seen.contains(2002))
        }
    }
}

// MARK: - The values of a group

@Suite struct ProcessGroupValues {
    private let leader = proc(10, "node", parent: 1, mb: 100, ports: [4200, 3000], age: 3_600)
    private let members = [
        proc(11, "esbuild", parent: 10, mb: 20, ports: [3000, 9229], age: 99_999),
        proc(12, "sh", parent: 10, mb: 5),
    ]

    @Test func theIdIsThePidOfTheLeader() {
        #expect(ProcessGroup(kind: .other, title: "node", leader: leader, members: members).id == 10)
    }

    @Test func theTotalFootprintAddsTheLeaderAndEveryMember() {
        let group = ProcessGroup(kind: .other, title: "node", leader: leader, members: members)
        #expect(group.totalFootprint == 125 << 20)
        #expect(ProcessGroup(kind: .other, title: "node", leader: leader, members: []).totalFootprint == 100 << 20)
    }

    @Test func theTotalFootprintStopsAtTheLargestNumberInsteadOfTrapping() {
        func process(_ pid: Int32, bytes: UInt64) -> ProcessRecord {
            ProcessRecord(
                pid: pid, ppid: 1, name: "x", executablePath: nil, arguments: [], cwd: nil, footprintBytes: bytes,
                startDate: Fixture.now, listeningPorts: [])
        }
        let group = ProcessGroup(
            kind: .other, title: "x", leader: process(1, bytes: .max - 1), members: [process(2, bytes: 5)])
        #expect(group.totalFootprint == .max)
    }

    @Test func thePortsAreThoseOfTheWholeGroupAscendingEachOnce() {
        let group = ProcessGroup(kind: .devServer, title: "node", leader: leader, members: members)
        #expect(group.ports == [3000, 4200, 9229])
        #expect(ProcessGroup(kind: .other, title: "sh", leader: members[1], members: []).ports.isEmpty)
    }

    @Test func theUptimeIsHowLongTheLeaderHasRun() {
        let group = ProcessGroup(kind: .other, title: "node", leader: leader, members: members)
        // The member is far older. It does not count: the leader is what was started.
        #expect(group.uptime(now: Fixture.now) == 3_600)
        #expect(group.uptime(now: Fixture.now.addingTimeInterval(30)) == 3_630)
    }

    @Test func theUptimeIsNeverNegative() {
        // The kernel's start time and the caller's clock can be a moment apart.
        let group = ProcessGroup(kind: .other, title: "node", leader: leader, members: [])
        #expect(group.uptime(now: Fixture.now.addingTimeInterval(-7_200)) == 0)
    }

    @Test func aGroupSurvivesCodingAndDecoding() throws {
        let group = ProcessGroup(kind: .agentSession, title: "Claude Code · CLI", leader: leader, members: members)
        let decoded = try JSONDecoder().decode(ProcessGroup.self, from: JSONEncoder().encode(group))
        #expect(decoded == group)
    }
}
