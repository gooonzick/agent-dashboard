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
