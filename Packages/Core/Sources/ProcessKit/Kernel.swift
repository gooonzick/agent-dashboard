import Darwin
import Foundation

/// What the kernel knows about processes: the libproc and `sysctl` calls that ask for it, and the reading of what they
/// answer.
///
/// This is the one place in the module that has pointers. Each function lends the system a buffer of its own for the
/// length of one call, of a size that it has worked out, and returns what it read as values. No pointer outlives its
/// closure, and a length that comes back with a buffer is checked against the buffer before it is used.
///
/// A call that fails says so with `nil` or an empty list, and not why. A process can exit between two calls, and a
/// process of another user cannot be looked at: both are ordinary. The one reason that is read is `ESRCH`, for a
/// process that has exited (`hasExited`).
enum Kernel {
    // MARK: All processes

    /// The ids of the processes that run, in no order. Without 0, which is the kernel itself and no process to look at
    /// or to signal.
    static func processIDs() -> [Int32] {
        // The count that a call without a buffer gives is an estimate, with some to spare. Processes start while the
        // list is made, so a buffer that comes back full may have cut it short: it is replaced by one twice as big.
        var capacity = max(Int(proc_listallpids(nil, 0)), 0) + 64
        while true {
            let ids = [Int32](unsafeUninitializedCapacity: capacity) { buffer, count in
                // The size goes in as bytes and the number of ids comes out.
                let size = Int32(clamping: buffer.count * MemoryLayout<Int32>.stride)
                count = min(max(Int(proc_listallpids(buffer.baseAddress, size)), 0), buffer.count)
            }
            if ids.count < capacity { return ids.filter { $0 > 0 } }
            capacity *= 2
        }
    }

    // MARK: One process

    /// What the table of processes says about one process.
    struct BasicInfo: Equatable {
        var parentID: Int32
        /// The effective user.
        var userID: uid_t
        var name: String
        var startDate: Date

        init(_ info: proc_bsdinfo) {
            parentID = Int32(bitPattern: info.pbi_ppid)
            userID = info.pbi_uid
            // As `proc_name` does it: the name that the process was given, which holds twice as many characters as
            // the short one that `ps` shows.
            let longName = Kernel.text(in: info.pbi_name)
            name = longName.isEmpty ? Kernel.text(in: info.pbi_comm) : longName
            let started = TimeInterval(info.pbi_start_tvsec) + TimeInterval(info.pbi_start_tvusec) / 1_000_000
            startDate = Date(timeIntervalSince1970: started)
        }
    }

    /// `nil` for a process that does not run: one that is gone, and a zombie, which the call does not answer for.
    /// Also `nil` for a process of another user: the kernel tells those to nobody but root.
    static func basicInfo(of pid: Int32) -> BasicInfo? {
        guard case .success(let info) = bsdInfo(of: pid) else { return nil }
        return BasicInfo(info)
    }

    /// Whether the process has exited: it is gone, or it is a zombie, which has only its place in the table left, for
    /// its parent to collect the exit status. `kill(pid, 0)` finds a zombie as it finds a process that runs. A process
    /// that the caller may not look at has not exited, as far as the caller can tell.
    static func hasExited(_ pid: Int32) -> Bool {
        guard case .failure(let failure) = bsdInfo(of: pid) else { return false }
        return failure.errno == ESRCH
    }

    /// The file that the process runs, as the kernel has it (symlinks resolved), or `nil` if it does not say. It does
    /// not for a file that has been deleted since the process started.
    static func executablePath(of pid: Int32) -> String? {
        // PROC_PIDPATHINFO_MAXSIZE is a macro that Swift cannot import: it is the most that the call takes.
        let capacity = 4 * Int(MAXPATHLEN)
        let path = [UInt8](unsafeUninitializedCapacity: capacity) { buffer, count in
            // The call returns the length of the path, or 0 if it failed.
            count = min(max(Int(proc_pidpath(pid, buffer.baseAddress, UInt32(buffer.count))), 0), buffer.count)
        }
        return path.isEmpty ? nil : String(decoding: path, as: UTF8.self)
    }

    /// The working directory of the process, as the kernel has it, or `nil` if the kernel does not say. A directory
    /// that has been deleted is still reported by its old path.
    static func workingDirectory(of pid: Int32) -> String? {
        var info = proc_vnodepathinfo()
        let size = Int32(MemoryLayout<proc_vnodepathinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &info, size) == size else { return nil }
        let path = text(in: info.pvi_cdir.vip_path)
        return path.isEmpty ? nil : path
    }

    /// The physical footprint of the process, which is the memory that Activity Monitor shows for it, or `nil` if the
    /// kernel does not say.
    static func physicalFootprint(of pid: Int32) -> UInt64? {
        var usage = rusage_info_v4()
        let status = withUnsafeMutablePointer(to: &usage) { pointer in
            // The call is declared to take a pointer to a `rusage_info_t`, which is a `void *`, and it is the address
            // of the structure to fill in that it is given.
            pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V4, $0) }
        }
        return status == 0 ? usage.ri_phys_footprint : nil
    }

    /// The TCP ports that the process listens on, over IPv4 or IPv6, in ascending order, each once. Empty if there are
    /// none, or if the process cannot be looked at.
    static func listeningPorts(of pid: Int32) -> [UInt16] {
        let entrySize = MemoryLayout<proc_fdinfo>.stride
        // A call without a buffer gives the size of the list. Descriptors that are opened after that, and so do not fit
        // the buffer, are not looked at.
        let capacity = max(Int(proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)), 0) / entrySize + 16
        let descriptors = [proc_fdinfo](unsafeUninitializedCapacity: capacity) { buffer, count in
            // The size goes in as bytes, and the bytes that were written come out.
            let size = Int32(clamping: buffer.count * entrySize)
            let written = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, buffer.baseAddress, size)
            count = min(max(Int(written), 0) / entrySize, buffer.count)
        }

        var ports = Set<UInt16>()
        for descriptor in descriptors where descriptor.proc_fdtype == PROX_FDTYPE_SOCKET {
            var socket = socket_fdinfo()
            let size = Int32(MemoryLayout<socket_fdinfo>.size)
            // A descriptor that has been closed since the list was made makes the call fail, and is skipped.
            guard proc_pidfdinfo(pid, descriptor.proc_fd, PROC_PIDFDSOCKETINFO, &socket, size) == size else { continue }
            if let port = listeningPort(in: socket) { ports.insert(port) }
        }
        return ports.sorted()
    }

    /// The port that a socket listens on, or `nil` if it is not a TCP socket that listens.
    ///
    /// What the kernel says about a socket ends in a union, of which the member that is valid depends on the kind of
    /// socket. The member for TCP is looked at only for a TCP socket: the bytes of any other are not a TCP state.
    static func listeningPort(in socket: socket_fdinfo) -> UInt16? {
        guard Int(socket.psi.soi_kind) == SOCKINFO_TCP else { return nil }
        let tcp = socket.psi.soi_proto.pri_tcp
        guard tcp.tcpsi_state == TSI_S_LISTEN else { return nil }
        // The kernel keeps the port in network byte order, in the low two bytes of an `int`.
        let port = UInt16(bigEndian: UInt16(truncatingIfNeeded: tcp.tcpsi_ini.insi_lport))
        return port == 0 ? nil : port
    }

    // MARK: Arguments

    /// Reads the arguments of one process after another into one buffer. The kernel wants room for the most that a
    /// process can have (`kern.argmax`, a megabyte) and almost none has more than a few kilobytes, so the buffer is
    /// made once, for all the processes of a sample.
    struct ArgumentsReader {
        private var buffer = [UInt8](repeating: 0, count: Self.capacity)

        private static let capacity: Int = {
            var mib = [CTL_KERN, KERN_ARGMAX]
            var argmax: Int32 = 0
            var size = MemoryLayout<Int32>.size
            guard sysctl(&mib, UInt32(mib.count), &argmax, &size, nil, 0) == 0, argmax > 0 else { return 1 << 20 }
            return Int(argmax)
        }()

        /// What the process was started with, or `nil` if the kernel does not say. It does not for the processes of
        /// other users, and for one that does not exist it gives the same error (`EINVAL`), so no failure can be
        /// told from another.
        mutating func arguments(of pid: Int32) -> [String]? {
            var mib = [CTL_KERN, KERN_PROCARGS2, pid]
            var size = buffer.count  // in: the room there is. out: the bytes that were written
            let status = buffer.withUnsafeMutableBytes {
                sysctl(&mib, UInt32(mib.count), $0.baseAddress, &size, nil, 0)
            }
            guard status == 0 else { return nil }
            return Kernel.parseArguments(buffer[..<min(size, buffer.count)])
        }
    }

    /// The arguments in what `sysctl KERN_PROCARGS2` returns: `argc` in the byte order of the host, the path that the
    /// program was started from, the NULs that pad it, then `argc` strings that are `argv`, and then the environment.
    /// Each string ends with a NUL.
    ///
    /// Exactly `argc` strings are returned, not the path, which is no argument, and not the environment. A buffer that
    /// ends before that, or that makes no sense, gives the strings that are whole: one whose NUL is not there may have
    /// been cut short, and is not an argument yet.
    ///
    /// An empty first argument cannot be told from the padding (`ps` cannot either). It is left out, and the reading
    /// goes on into the environment by one string. Almost no program is started like that.
    static func parseArguments(_ bytes: ArraySlice<UInt8>) -> [String] {
        guard bytes.count >= MemoryLayout<Int32>.size else { return [] }
        let argc = bytes.withUnsafeBytes { $0.loadUnaligned(as: Int32.self) }
        guard argc > 0 else { return [] }

        guard let endOfPath = bytes.dropFirst(MemoryLayout<Int32>.size).firstIndex(of: 0) else { return [] }
        var rest = bytes[endOfPath...].drop { $0 == 0 }

        var arguments: [String] = []
        while arguments.count < argc, let end = rest.firstIndex(of: 0) {
            arguments.append(String(decoding: rest[..<end], as: UTF8.self))
            rest = rest[(end + 1)...]
        }
        return arguments
    }

    // MARK: Reading what the system returns

    private struct Failure: Error {
        let errno: Int32
    }

    /// `proc_pidinfo(PROC_PIDTBSDINFO)`: the structure, or the `errno` that the call failed with.
    private static func bsdInfo(of pid: Int32) -> Result<proc_bsdinfo, Failure> {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        // The call returns the number of bytes that it wrote, which is the size of the structure, or 0 for an error.
        // The 0 for the argument is "no zombies".
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else {
            return .failure(Failure(errno: errno))
        }
        return .success(info)
    }

    /// The text in a character array of fixed size, which Swift sees as a tuple: what is before the first NUL, or all
    /// of it if there is none. Bytes that are not UTF-8 are replaced, not refused.
    private static func text<CharacterArray>(in array: CharacterArray) -> String {
        withUnsafeBytes(of: array) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
    }
}
