import CoreModels
import Foundation

/// Measures what removing a folder would give back.
public protocol SizeMeasuring: Sendable {
    /// The size of the folder `root`, and how much of it removing the folder would free.
    ///
    /// `excluding` holds folders that are left out with everything in them, such as the worktrees that lie inside the
    /// main checkout of a repository. Entries are the canonical paths (`canonicalPath`) of the folders themselves:
    /// `/x/repo/wt` leaves out `/x/repo/wt/...`, not `/x/repo/wt-2`. An entry that is neither `root` nor below it does
    /// nothing, and one that is `root` leaves nothing to measure.
    ///
    /// `isCancelled` is asked once for every folder. When it says yes the walk stops and the call throws
    /// `CancellationError`. Cancelling the task that runs the walk has the same effect.
    ///
    /// The walk stays on the volume of `root`. A folder below `root` that another volume is mounted on is left out with
    /// everything on that volume: removing the folder does not remove what is mounted on it.
    ///
    /// A folder below `root` that cannot be read is left out, and so is a file that goes away during the walk: the
    /// result counts what could be read. A `root` that is not a folder that can be read and searched throws a
    /// `POSIXError`.
    ///
    /// The walk is file system work that blocks its thread for as long as it takes: run it from a background task, at
    /// `.utility` priority or lower.
    func measure(_ root: URL, excluding: Set<String>, isCancelled: @Sendable () -> Bool) throws -> SizeInfo
}

/// Measures a folder by walking it and asking the file system, for every file, how much of the file is its own.
///
/// What deleting a file frees is its private size, which APFS gives through `getattrlist`
/// (`ATTR_CMNEXT_PRIVATESIZE`): the bytes that no clone shares and no snapshot holds. `du` cannot tell the difference.
///
/// Only regular files are counted, and only those on the volume of the folder itself: a volume that is mounted inside
/// it is not entered. Symlinks are not followed, and they and the folders take nothing themselves. The numbers can be
/// too low but are never too high:
/// - A file with several hard links is counted once for `apparentBytes`, and frees nothing: removing one name leaves
///   the data to the other names, and they may lie outside the folder.
/// - A file on a volume that is not on this computer (a network share, say) frees nothing, whatever the volume says
///   about it: such a volume can be an APFS volume of a server, with clones that this Mac cannot see, and what it says
///   is about the file system of the server.
/// - A file that its volume cannot say anything about frees nothing. The one exception is a volume on this computer
///   that has no private sizes and is not APFS (HFS+ or exFAT, say): there are no clones there, so a file frees all
///   that it takes.
/// - Data that two files of the folder share is counted for neither, although removing both frees it.
public struct PrivateSizeScanner: SizeMeasuring {
    /// Tells what kind of volume the file at a path is on, or `nil` if it cannot say.
    typealias VolumeLookup = @Sendable (UnsafePointer<CChar>) -> Volume?

    private let lookUpVolume: VolumeLookup

    public init() {
        lookUpVolume = { Volume(at: $0) }
    }

    /// Not public: the tests cannot mount a network share to see what becomes of the files on one.
    init(lookUpVolume: @escaping VolumeLookup) {
        self.lookUpVolume = lookUpVolume
    }

    public func measure(_ root: URL, excluding: Set<String>, isCancelled: @Sendable () -> Bool) throws -> SizeInfo {
        // The walk sees physical paths, so the paths that it is compared with have to be physical too. Looking up each
        // folder in this set is enough, because the walk reaches a folder through its parents.
        let excluded = Set(excluding.map(canonicalPath))

        guard let rootPath = strdup(canonicalPath(root.path)) else { throw POSIXError(errno: ENOMEM) }
        defer { free(rootPath) }
        // PHYSICAL: a symlink is reported, not followed. NOCHDIR: the walk does not change the working directory,
        // which all threads of the app share. XDEV: a folder that has another volume mounted on it is reported, but not
        // entered.
        guard let tree = fts_open([rootPath, nil], FTS_PHYSICAL | FTS_NOCHDIR | FTS_XDEV, nil) else {
            throw POSIXError(errno: errno)
        }
        defer { fts_close(tree) }

        var tally = Tally()
        while true {
            errno = 0  // `fts_read` ends the walk with 0 in it, or with the error that stopped it
            guard let entry = fts_read(tree) else { break }
            let kind = Int32(entry.pointee.fts_info)

            if entry.pointee.fts_level == 0 {
                if kind == FTS_D {
                    // A folder that can be listed and not searched (r--) gives `fts` its names, and then every file
                    // in it comes back as an error that is passed over below `root`: the result would be zero,
                    // without a word.
                    guard access(entry.pointee.fts_path, R_OK | X_OK) == 0 else { throw POSIXError(errno: errno) }
                } else if kind != FTS_DP {
                    // `root` is gone, or is not a folder, or is one that cannot be read.
                    throw POSIXError(errno: entry.pointee.fts_errno == 0 ? ENOTDIR : entry.pointee.fts_errno)
                }
            }
            switch kind {
            case FTS_D:
                guard !Task.isCancelled, !isCancelled() else { throw CancellationError() }
                if excluded.contains(String(cString: entry.pointee.fts_path)) { fts_set(tree, entry, FTS_SKIP) }
            case FTS_F:
                tally.count(entry, volumeAt: lookUpVolume)
            default:
                // Below `root`, what is passed over: the end of a folder, a folder that cannot be read, a file that has
                // gone away, a symlink, and whatever else is not a regular file.
                break
            }
        }
        if errno != 0 { throw POSIXError(errno: errno) }

        return SizeInfo(apparentBytes: tally.apparent, privateBytes: tally.freed, computedAt: Date())
    }
}

extension PrivateSizeScanner {
    /// What a volume said when it was asked for the private size of a file.
    enum Answer: Equatable {
        /// The private size of the file.
        case bytes(Int64)
        /// `getattrlist` failed with this `errno`.
        case failed(Int32)
    }

    /// What a volume is, as far as the numbers that it gives for a file can be believed.
    enum Volume: Equatable {
        /// An APFS volume on this computer. Its files can share data, and it says how much of a file is shared.
        case apfs
        /// A volume on this computer that is not APFS, HFS+ or exFAT say. Its files cannot share data.
        case localWithoutClones
        /// A volume that is not on this computer, such as a network share, or that could not be asked. It can be an
        /// APFS volume of a server, with clones that this Mac cannot see, and what it says about a file is about the
        /// file system of the server. Nothing that it says is believed, and nothing is counted for its files.
        case untrusted

        /// The kind of volume that `statfs` describes. `statfs` marks the volumes that are on this computer with
        /// `MNT_LOCAL`.
        init(_ info: statfs) {
            guard info.f_flags & UInt32(MNT_LOCAL) != 0 else {
                self = .untrusted
                return
            }
            let fileSystem = withUnsafePointer(to: info.f_fstypename) { name in
                name.withMemoryRebound(to: CChar.self, capacity: Int(MFSTYPENAMELEN)) { String(cString: $0) }
            }
            self = fileSystem == "apfs" ? .apfs : .localWithoutClones
        }

        /// The kind of volume that the file at `path` is on, or `nil` if the volume cannot be asked.
        init?(at path: UnsafePointer<CChar>) {
            var info = statfs()
            guard statfs(path, &info) == 0 else { return nil }
            self.init(info)
        }
    }

    /// What deleting a file that takes `allocated` bytes frees, given the kind of its `volume` and the `answer` that
    /// the volume gives. `nil` for a file that is gone: it takes nothing any more, so it is left out of the sums
    /// altogether.
    ///
    /// `answer` is only asked of a volume that is believed. An `untrusted` one is not asked: its files free nothing,
    /// whatever it would say.
    ///
    /// Not private, because it holds decisions that the tests cannot provoke with a volume of every kind.
    static func freedBytes(allocated: Int64, volume: Volume, answer: @autoclosure () -> Answer) -> Int64? {
        if volume == .untrusted { return 0 }
        switch answer() {
        case .bytes(let bytes):
            return bytes
        case .failed(let code) where code == ENOTSUP || code == EINVAL:
            // The volume has no private sizes. `getattrlist` documents ENOTSUP for that. HFS+ and exFAT, tried on disk
            // images, answer EINVAL: the attribute is not one that they have. APFS should have it. The attribute is in
            // a part of the system headers that is marked unstable, so if a later macOS stopped answering on APFS, the
            // numbers must not become those of `du`: nothing is known then, and nothing is counted.
            return volume == .localWithoutClones ? allocated : 0
        case .failed(let code) where code == ENOENT || code == ENOTDIR:
            return nil
        case .failed:
            // Not known, so the lowest number that can be true.
            return 0
        }
    }

    /// Asks the volume of the file at `path` for the private size of the file. A symlink is not followed.
    static func privateSize(ofFileAt path: UnsafePointer<CChar>) -> Answer {
        var request = attrlist()
        request.bitmapcount = u_short(ATTR_BIT_MAP_COUNT)
        // With FSOPT_ATTR_CMN_EXTENDED, the ATTR_CMNEXT_* attributes are asked for in `forkattr`.
        request.forkattr = attrgroup_t(ATTR_CMNEXT_PRIVATESIZE)
        let options = UInt32(FSOPT_NOFOLLOW | FSOPT_ATTR_CMN_EXTENDED)

        // The answer is its own length (`UInt32`), then the private size (`off_t`), packed: 12 bytes, with the `off_t`
        // at offset 4, where it is not aligned. It is read without assuming any alignment. The buffer has room for
        // that and starts out as zeros.
        var answer: (UInt64, UInt64) = (0, 0)
        return withUnsafeMutableBytes(of: &answer) { buffer in
            guard getattrlist(path, &request, buffer.baseAddress, buffer.count, options) == 0 else {
                return .failed(errno)
            }
            return .bytes(buffer.loadUnaligned(fromByteOffset: MemoryLayout<UInt32>.size, as: Int64.self))
        }
    }

    /// The totals of a walk.
    fileprivate struct Tally {
        /// What the files take on disk, as `du` counts it.
        private(set) var apparent: Int64 = 0
        /// What deleting the files frees.
        private(set) var freed: Int64 = 0
        /// The files with several hard links that were counted already.
        private var linked: Set<FileID> = []
        /// What kind each of the volumes (`st_dev`) is that files were found on. A walk does not leave the volume of
        /// its root, so this hardly ever has more than one entry.
        private var volumes: [dev_t: Volume] = [:]

        /// Counts `file`, a regular file.
        mutating func count(_ file: UnsafeMutablePointer<FTSENT>, volumeAt lookUpVolume: VolumeLookup) {
            // `fts` ran `lstat` on every file that it reports, and keeps what it found out. Every entry that it returns
            // has a path.
            let info = file.pointee.fts_statp.pointee
            let allocated = info.st_blocks * 512  // always in units of 512 bytes, whatever block size the volume has

            if info.st_nlink > 1 {
                if linked.insert(FileID(device: info.st_dev, inode: info.st_ino)).inserted { apparent += allocated }
                return
            }
            let path = file.pointee.fts_path!
            let volume = kindOfVolume(on: info.st_dev, at: path, lookUp: lookUpVolume)
            guard
                let own = PrivateSizeScanner.freedBytes(
                    allocated: allocated, volume: volume, answer: PrivateSizeScanner.privateSize(ofFileAt: path))
            else { return }
            apparent += allocated
            freed += own
        }

        /// What kind of volume `device` is, which holds the file at `path`. A volume that cannot be asked is not
        /// believed for this file, and is asked again for the next.
        private mutating func kindOfVolume(
            on device: dev_t, at path: UnsafePointer<CChar>, lookUp: VolumeLookup
        ) -> Volume {
            if let known = volumes[device] { return known }
            guard let volume = lookUp(path) else { return .untrusted }
            volumes[device] = volume
            return volume
        }
    }

    /// Tells a file apart on its volume: all names of a file, however many, give the same pair.
    fileprivate struct FileID: Hashable {
        let device: dev_t
        let inode: ino_t
    }
}

extension POSIXError {
    /// The error for an `errno` value, or `EIO` for one that has no `POSIXErrorCode`.
    fileprivate init(errno code: Int32) {
        self.init(POSIXErrorCode(rawValue: code) ?? .EIO)
    }
}
