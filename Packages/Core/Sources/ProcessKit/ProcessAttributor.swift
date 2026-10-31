import CoreModels
import Foundation

/// Tells which worktree each process of a sample is in, and gathers what runs in a worktree into groups.
///
/// It reads the records that it is given and nothing else: no file system, no system call. A sample gives the same
/// groups whatever the order of its records.
///
/// **Which worktree.** A process is in the deepest worktree that holds the first of these that lies in any:
/// 1. its working directory;
/// 2. the working directory of its nearest ancestor that lies in a worktree, not counting an ancestor that launchd
///    adopted (`ppid == 1`): it is a daemon, or what is left of a shell that exited, and it sits where it was started
///    while what it starts works wherever it is asked to. A tmux server in a worktree does not bring in every shell
///    below it. The process that launchd adopted is in its worktree by its own working directory all the same;
/// 3. its executable, or an argument: one that is a path in the worktree, or `name=path` with such a path after the
///    first `=`. Of several worktrees the deepest wins; of as deep ones, the one of the executable, then of the first
///    argument.
///
/// Paths are compared by folder and as they are given: `/r/dashboard` holds `/r/dashboard/a` and not
/// `/r/dashboard-worktrees/a`, and a path that leaves the worktree again with `..` is not in it. Nothing is resolved,
/// so the roots have to be in the form that the kernel reports paths in. A process that none of this puts in a worktree
/// is in none, whatever its parent is.
///
/// **Sessions.** `claude` (by its name, by the name that it was started by, or by an executable in
/// `/claude.app/Contents/MacOS/`) and `codex` (unless it was started with the argument `app-server`, which makes it the
/// daemon) lead a session. Its members are all of its descendants that are in its worktree or in none, whatever they
/// are called and wherever they run, and the helper `disclaimer` of the Claude app if that is its parent, in whatever
/// worktree the helper is. If launchd adopted the leader, the descendants that are in none are not taken, as it passes
/// no folder down to them: the session is what is in its worktree by itself. A session inside a session of the same
/// worktree is part of the outer one.
///
/// A session of Claude Code is titled `Claude Code · desktop` if the Claude app started it, which the helper shows, and
/// `Claude Code · CLI` if not. Then comes `, 3 MCP servers`, for the children of the session that have `mcp` in an
/// argument, in any case: nothing for none, and `, 1 MCP server` for one. A session of Codex is titled `Codex CLI`.
///
/// **Everything else.** A process leads a group when its parent is not in the same worktree, and the group is the
/// descendants that are, down to the first that is not. Its kind is the first of: `devServer` if anything in the group
/// listens on a port; `builtHere` if the leader runs a file in the worktree, however it was started (an app that is
/// opened from the Finder has launchd for its parent); `daemon` if launchd started the leader; `shell` if it is one;
/// `other`. A dev server is titled with the name of the process that listens, the first by pid of those that do, the
/// leader's among them: a shell that runs one is a `node`, not a `zsh`. Any other group is titled with the name of the
/// leader.
///
/// A process is in at most one group, and a group is of one worktree: a process that is in another worktree than its
/// parent leaves the parent's group, and leads one in its own. Processes in no worktree are in no group, but for the
/// descendants of a session, and neither are launchd and the kernel (pid 1 and 0), whose children no one started.
/// Groups come in order of memory, the most first, then of the pid of the leader; members in order of pid.
public struct ProcessAttributor: Sendable {
    private let roots: [Root]

    /// - Parameter roots: The worktrees, as absolute paths in the form that the kernel reports paths in (physical, as
    ///   `canonicalPath` gives them). A path that is not absolute, or is `/` itself, is no worktree and is left out.
    public init(roots: [String]) {
        self.roots = roots.compactMap(Root.init)
    }

    /// The groups of each worktree that has any, by the path of the worktree as it was given to `init`. A worktree that
    /// nothing runs in has no entry.
    ///
    /// A pid that the sample has twice counts once, for its first record.
    public func attribute(_ processes: [ProcessRecord]) -> [String: [ProcessGroup]] {
        let tree = ProcessTree(processes)
        let rootOf = worktrees(of: tree)
        var claimed = Set<Int32>()
        var found: [(root: Int, group: ProcessGroup)] = []

        // The sessions take what is theirs first, and everything else is grouped out of what is left. The outermost
        // session goes first: a session inside it is taken with the rest, and is none of its own.
        for leader in sessionLeaders(in: tree, rootOf: rootOf) where !claimed.contains(leader.pid) {
            guard let agent = leader.sessionAgent, let root = rootOf[leader.pid] else { continue }
            // What a session takes: processes of its worktree, and those that are in none, unless launchd adopted the
            // leader. Its folder is not passed down, so only what is in the worktree by itself is the session's.
            let takesWhatIsInNoWorktree = leader.ppid != 1
            func isOfTheSession(_ process: ProcessRecord) -> Bool {
                rootOf[process.pid].map { $0 == root } ?? takesWhatIsInNoWorktree
            }

            var members = tree.descendants(of: leader) { isOfTheSession($0) && !claimed.contains($0.pid) }
            // The helper wraps the session, whatever worktree it is in itself: the Claude app starts it in a spare
            // folder, and its arguments are those of `claude`, so an `--add-dir` of another worktree is among them.
            let helper = tree.parent(of: leader).flatMap {
                $0.isClaudeAppHelper && !claimed.contains($0.pid) ? $0 : nil
            }
            if let helper { members.append(helper) }
            members.sort { $0.pid < $1.pid }

            let title = Self.title(of: leader, agent: agent, members: members, startedByTheApp: helper != nil)
            claimed.insert(leader.pid)
            claimed.formUnion(members.map(\.pid))
            found.append((root, ProcessGroup(kind: .agentSession, title: title, leader: leader, members: members)))
        }

        for process in tree.processes where !claimed.contains(process.pid) {
            guard let root = rootOf[process.pid] else { continue }
            // The leader is the first process of the chain above that is in this worktree: something outside it
            // started that one.
            var leader = process
            for ancestor in tree.ancestors(of: process) {
                guard rootOf[ancestor.pid] == root, !claimed.contains(ancestor.pid) else { break }
                leader = ancestor
            }

            let members = tree.descendants(of: leader) { rootOf[$0.pid] == root && !claimed.contains($0.pid) }
            claimed.insert(leader.pid)
            claimed.formUnion(members.map(\.pid))
            found.append((root, Self.group(of: leader, members: members, in: roots[root])))
        }

        var result: [String: [ProcessGroup]] = [:]
        let memory = found.map { $0.group.totalFootprint }
        let order = found.indices.sorted { a, b in
            memory[a] != memory[b] ? memory[a] > memory[b] : found[a].group.leader.pid < found[b].group.leader.pid
        }
        for index in order { result[roots[found[index].root].key, default: []].append(found[index].group) }
        return result
    }

    // MARK: Which worktree

    /// The index in `roots` of the worktree that each process is in. A process that is in none has no entry.
    private func worktrees(of tree: ProcessTree) -> [Int32: Int] {
        var byFolder: [Int32: Int] = [:]
        for process in tree.processes {
            if let cwd = process.cwd, let root = deepestRoot(containing: cwd) { byFolder[process.pid] = root }
        }

        var result: [Int32: Int] = [:]
        for process in tree.processes {
            // An ancestor that launchd adopted passes nothing down: its folder is where it was started, and what it
            // started works elsewhere. It is still in its worktree itself, by its own folder.
            result[process.pid] =
                byFolder[process.pid]
                ?? tree.ancestors(of: process).lazy.filter { $0.ppid != 1 }.compactMap { byFolder[$0.pid] }.first
                ?? deepestRoot(containingThePathsOf: process)
        }
        return result
    }

    /// The index of the deepest root that holds `path`, if one does.
    private func deepestRoot(containing path: some StringProtocol) -> Int? {
        guard path.hasPrefix("/") else { return nil }
        var deepest: Int?
        for (index, root) in roots.enumerated() where root.contains(path) {
            if deepest.map({ roots[$0].depth < root.depth }) ?? true { deepest = index }
        }
        return deepest
    }

    /// The deepest root that holds the executable or an argument of `process`: the first one found, if two are as deep.
    private func deepestRoot(containingThePathsOf process: ProcessRecord) -> Int? {
        var deepest: Int?
        func consider(_ path: some StringProtocol) {
            guard let root = deepestRoot(containing: path) else { return }
            if deepest.map({ roots[$0].depth < roots[root].depth }) ?? true { deepest = root }
        }
        if let executable = process.executablePath { consider(executable) }
        for argument in process.arguments {
            consider(argument)
            if let equals = argument.firstIndex(of: "=") { consider(argument[argument.index(after: equals)...]) }
        }
        return deepest
    }

    // MARK: Groups

    /// The processes that lead a session, the outermost first: of two in one chain the one above comes first, so that
    /// the session it takes is decided before one inside it. Otherwise by pid.
    private func sessionLeaders(in tree: ProcessTree, rootOf: [Int32: Int]) -> [ProcessRecord] {
        tree.processes
            .filter { $0.sessionAgent != nil && rootOf[$0.pid] != nil }
            .map { (leader: $0, depth: tree.ancestors(of: $0).count) }
            .sorted { ($0.depth, $0.leader.pid) < ($1.depth, $1.leader.pid) }
            .map(\.leader)
    }

    private static func title(
        of leader: ProcessRecord, agent: Agent, members: [ProcessRecord], startedByTheApp: Bool
    ) -> String {
        switch agent {
        case .codex:
            return "Codex CLI"
        case .claudeCode:
            let servers = members.filter { $0.ppid == leader.pid && $0.mentionsMCP }.count
            let title = "Claude Code · " + (startedByTheApp ? "desktop" : "CLI")
            switch servers {
            case 0: return title
            case 1: return title + ", 1 MCP server"
            default: return title + ", \(servers) MCP servers"
            }
        }
    }

    /// A group that is not a session: what it is, and what it is called.
    private static func group(of leader: ProcessRecord, members: [ProcessRecord], in root: Root) -> ProcessGroup {
        // What listens is what the group is, whoever started it: a shell that runs a dev server is the server.
        let listeners = ([leader] + members).filter { !$0.listeningPorts.isEmpty }
        if let listener = listeners.min(by: { $0.pid < $1.pid }) {
            return ProcessGroup(kind: .devServer, title: listener.name, leader: leader, members: members)
        }
        return ProcessGroup(kind: kind(of: leader, in: root), title: leader.name, leader: leader, members: members)
    }

    /// The kind of a group that has nothing that listens.
    private static func kind(of leader: ProcessRecord, in root: Root) -> ProcessKind {
        // A file that is gone proves nothing: its path may still be among the arguments, but the process was not seen
        // to run from the worktree.
        if let executable = leader.executablePath, root.contains(executable) { return .builtHere }
        if leader.ppid == 1 { return .daemon }
        return leader.isShell ? .shell : .other
    }
}

// MARK: - Worktrees

/// A worktree, and the paths that lie in it.
private struct Root: Sendable {
    /// The path as it was given: what the groups are filed under.
    let key: String
    /// How many folders deep it is.
    let depth: Int
    private let path: String
    private let prefix: String

    init?(_ key: String) {
        var folder = Substring(key)
        while folder.hasSuffix("/") { folder.removeLast() }
        // `/` would hold every process of the machine. A path that is not absolute is not a place.
        guard key.hasPrefix("/"), !folder.isEmpty else { return nil }
        self.key = key
        self.path = String(folder)
        self.prefix = String(folder) + "/"
        self.depth = folder.split(separator: "/").count
    }

    /// Whether `candidate` is the root or a path below it. By folder, not by characters.
    func contains(_ candidate: some StringProtocol) -> Bool {
        guard candidate == path || candidate.hasPrefix(prefix) else { return false }
        // A `..` could lead out of the root again, and that is no longer where the path says.
        return !(candidate.contains("/../") || candidate.hasSuffix("/.."))
    }
}

// MARK: - The tree of processes

/// The processes of a sample, and who started whom.
private struct ProcessTree {
    /// One record for each pid, in order of pid, without launchd and the kernel: they start what no one in the sample
    /// did, and are no one's process to stop.
    let processes: [ProcessRecord]
    private let byPID: [Int32: ProcessRecord]
    private let childrenOf: [Int32: [ProcessRecord]]

    init(_ sample: [ProcessRecord]) {
        var byPID: [Int32: ProcessRecord] = [:]
        for process in sample where process.pid > 1 && byPID[process.pid] == nil { byPID[process.pid] = process }
        self.byPID = byPID
        self.processes = byPID.values.sorted { $0.pid < $1.pid }
        self.childrenOf = Dictionary(grouping: processes, by: \.ppid)
    }

    /// The process that started `process`, if the sample has it.
    func parent(of process: ProcessRecord) -> ProcessRecord? {
        byPID[process.ppid]
    }

    /// The processes above `process`, the parent first, as far as the sample has them. Each is there once: a loop of
    /// parents, which a pid that was reused while the sample was taken can make, ends the walk.
    func ancestors(of process: ProcessRecord) -> [ProcessRecord] {
        var seen: Set<Int32> = [process.pid]
        var ancestors: [ProcessRecord] = []
        var current = process
        while let parent = parent(of: current), seen.insert(parent.pid).inserted {
            ancestors.append(parent)
            current = parent
        }
        return ancestors
    }

    /// The processes below `process` that `isIncluded` says yes to, in order of pid. The walk down does not go on below
    /// one that it says no to.
    func descendants(of process: ProcessRecord, where isIncluded: (ProcessRecord) -> Bool) -> [ProcessRecord] {
        var descendants: [ProcessRecord] = []
        var seen: Set<Int32> = [process.pid]
        var pending = [process]
        while let current = pending.popLast() {
            for child in childrenOf[current.pid] ?? [] {
                guard isIncluded(child), seen.insert(child.pid).inserted else { continue }
                descendants.append(child)
                pending.append(child)
            }
        }
        return descendants.sorted { $0.pid < $1.pid }
    }
}

// MARK: - What a process is

private enum Agent {
    case claudeCode, codex
}

extension ProcessRecord {
    /// The agent that this process is the session of. Case matters: the Claude app is `Claude`, not a session.
    fileprivate var sessionAgent: Agent? {
        if name == "claude" || startedAs("claude") || executablePath?.contains("/claude.app/Contents/MacOS/") == true {
            return .claudeCode
        }
        if name == "codex", !arguments.contains("app-server") { return .codex }
        return nil
    }

    /// Whether the program was started by `command`, bare or by a path: the first argument is how it was called. The
    /// kernel's name is not that of the command when the command is a link, which is what the command line install of
    /// Claude Code is: `claude` is a link to a file that is named by its version, and that is the name of the process.
    private func startedAs(_ command: String) -> Bool {
        guard let first = arguments.first else { return false }
        return first == command || first.hasSuffix("/" + command)
    }

    /// The helper that the Claude app starts a session of Claude Code through.
    fileprivate var isClaudeAppHelper: Bool {
        executablePath?.hasSuffix("/Claude.app/Contents/Helpers/disclaimer") == true
    }

    /// A shell by the name that the kernel has for it, or a login shell: those are started with a first argument that
    /// begins with `-`, and the kernel's name for them has none.
    fileprivate var isShell: Bool {
        ["zsh", "bash", "fish", "sh"].contains(name) || arguments.first?.hasPrefix("-") == true
    }

    fileprivate var mentionsMCP: Bool {
        arguments.contains { $0.range(of: "mcp", options: .caseInsensitive) != nil }
    }
}
