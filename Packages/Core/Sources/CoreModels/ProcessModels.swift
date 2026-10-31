import Foundation

/// One process of the user, as it was when it was sampled.
///
/// A record is a snapshot: the process may have exited, or changed what it does, by the time it is looked at. It
/// carries what the dashboard needs to tell which project a process belongs to, and to stop it: who it is (`pid`,
/// `ppid`), where it works (`cwd`, `executablePath`, `arguments`), what it costs (`footprintBytes`) and what it
/// serves (`listeningPorts`).
public struct ProcessRecord: Sendable, Equatable, Codable, Identifiable {
    public var id: Int32 { pid }
    public let pid: Int32
    /// The process that started this one, or `1` (launchd) once that has exited.
    public let ppid: Int32
    /// The name that the kernel has for the process: the file name of its executable, cut off after 31 bytes. Not the
    /// name of an app as the Finder shows it.
    public let name: String
    /// The file the process runs, as the kernel reports it: symlinks resolved (`/private/var/...`, never `/var/...`).
    /// `nil` when the kernel does not say, which it does not once the file has been deleted.
    public let executablePath: String?
    /// What the process was started with, `argv`: the first element is how the program was called, the environment is
    /// not part of it. Empty when it cannot be read.
    public let arguments: [String]
    /// The working directory, as the kernel reports it, like `executablePath`. A directory that has been deleted since
    /// is still reported, by the path that it had. `nil` when the kernel does not say.
    public let cwd: String?
    /// The physical footprint, the number that Activity Monitor shows as the memory of a process. 0 when it cannot be
    /// read.
    public let footprintBytes: UInt64
    public let startDate: Date
    /// The TCP ports that the process listens on, over IPv4 or IPv6: ascending, each once.
    public let listeningPorts: [UInt16]

    public init(
        pid: Int32, ppid: Int32, name: String, executablePath: String?, arguments: [String], cwd: String?,
        footprintBytes: UInt64, startDate: Date, listeningPorts: [UInt16]
    ) {
        self.pid = pid
        self.ppid = ppid
        self.name = name
        self.executablePath = executablePath
        self.arguments = arguments
        self.cwd = cwd
        self.footprintBytes = footprintBytes
        self.startDate = startDate
        self.listeningPorts = listeningPorts
    }
}

/// What a group of processes is, as far as the dashboard tells it apart.
public enum ProcessKind: String, Sendable, Codable {
    /// A session of Claude Code or of Codex, with the processes that it started.
    case agentSession
    /// Something in the group listens on a TCP port.
    case devServer
    /// The parent of the leader is launchd: the system started it, or whatever did has exited. Not so for what runs a
    /// file of the worktree, which is `builtHere`.
    case daemon
    /// The leader runs a file that lies in the worktree: a build product, whoever started it. An app that is opened
    /// from the Finder has launchd for its parent.
    case builtHere
    /// A shell, a login shell included.
    case shell
    /// Anything else.
    case other
}

/// The processes of one worktree that belong together: a leader and the processes that it started.
///
/// A process is in one group at most: it leads it, or is one of its members. To stop the group is to stop all of
/// them.
public struct ProcessGroup: Sendable, Equatable, Codable, Identifiable {
    /// The pid of the leader: no process leads two groups.
    public var id: Int32 { leader.pid }
    public let kind: ProcessKind
    /// What the dashboard calls the group. A session is titled by what it is (`Claude Code · CLI, 2 MCP servers`), a
    /// dev server by the name of the process that listens, and any other group by the name of its leader.
    public let title: String
    /// The process that the group is named for: the session of an agent, or the first process of its worktree to have
    /// been started from outside it.
    public let leader: ProcessRecord
    /// The other processes of the group, in order of pid. Never the leader. For a session of the Claude app, the helper
    /// that started it is among them.
    public let members: [ProcessRecord]

    public init(kind: ProcessKind, title: String, leader: ProcessRecord, members: [ProcessRecord]) {
        self.kind = kind
        self.title = title
        self.leader = leader
        self.members = members
    }

    /// The memory of the leader and of every member together. Not above the largest number: a sum that would not fit is
    /// that number.
    public var totalFootprint: UInt64 {
        members.reduce(leader.footprintBytes) { sum, member in
            let (total, overflow) = sum.addingReportingOverflow(member.footprintBytes)
            return overflow ? .max : total
        }
    }

    /// The TCP ports that the leader or a member listens on: ascending, each once.
    public var ports: [UInt16] {
        Array(Set(leader.listeningPorts).union(members.lazy.flatMap(\.listeningPorts))).sorted()
    }

    /// How long the leader has run at `now`: the group is as old as what it is named for, and its members may be older.
    /// Never negative, though the kernel's clock and the caller's can be a moment apart.
    public func uptime(now: Date) -> TimeInterval {
        max(0, now.timeIntervalSince(leader.startDate))
    }
}
