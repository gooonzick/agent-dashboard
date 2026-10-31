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
    /// result counts what could be read. A `root` that is not a folder that can be read throws a `POSIXError`.
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
/// - A file that its volume cannot say anything about frees nothing. The one exception is a volume that has no private
///   sizes and is local and not APFS (HFS+ or exFAT, say): there are no clones there, so a file frees all that it
///   takes. A network volume is no exception, because it can be an APFS volume of the server, with clones that this
///   Mac cannot see.
/// - Data that two files of the folder share is counted for neither, although removing both frees it.
public struct PrivateSizeScanner: SizeMeasuring {
    public init() {}

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

            if entry.pointee.fts_level == 0, kind != FTS_D, kind != FTS_DP {
                // `root` is gone, or is not a folder, or is one that cannot be read.
                throw POSIXError(errno: entry.pointee.fts_errno == 0 ? ENOTDIR : entry.pointee.fts_errno)
            }
            switch kind {
            case FTS_D:
                guard !Task.isCancelled, !isCancelled() else { throw CancellationError() }
                if excluded.contains(String(cString: entry.pointee.fts_path)) { fts_set(tree, entry, FTS_SKIP) }
            case FTS_F:
                tally.count(entry)
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

    /// What deleting a file that takes `allocated` bytes frees, given the `answer` of its volume. `nil` for a file that
    /// is gone: it takes nothing any more, so it is left out of the sums altogether.
    ///
    /// `volumeMayShareData` is only asked when a volume has refused to give private sizes. A volume that is known not
    /// to share data is the only one where the refusal means that a file frees all that it takes.
    ///
    /// Not private, because it holds decisions that the tests cannot provoke with a volume of every kind.
    static func freedBytes(
        allocated: Int64, answer: Answer, volumeMayShareData: @autoclosure () -> Bool
    ) -> Int64? {
        switch answer {
        case .bytes(let bytes):
            return bytes
        case .failed(let code) where code == ENOTSUP || code == EINVAL:
            // The volume has no private sizes. `getattrlist` documents ENOTSUP for that. HFS+ and exFAT, tried on disk
            // images, answer EINVAL: the attribute is not one that they have. APFS should have it. The attribute is in
            // a part of the system headers that is marked unstable, so if a later macOS stopped answering on APFS, the
            // numbers must not become those of `du`: nothing is known then, and nothing is counted.
            return volumeMayShareData() ? 0 : allocated
        case .failed(let code) where code == ENOENT || code == ENOTDIR:
            return nil
        case .failed:
            // Not known, so the lowest number that can be true.
            return 0
        }
    }

    /// Whether files on the volume that holds `path` can share their data: `false` only for a volume that is known not
    /// to (see `mayShareData`), `true` for the rest, and for a volume that cannot be asked.
    static func volumeMayShareData(at path: UnsafePointer<CChar>) -> Bool {
        var info = statfs()
        guard statfs(path, &info) == 0 else { return true }
        return mayShareData(volume: info)
    }

    /// Whether files on a volume can share their data, given what `statfs` says about it. Only APFS has clones, so a
    /// volume that is on this computer and is something else has none. A volume that is not on this computer (no
    /// `MNT_LOCAL`), such as a network share, is no such volume: it can be an APFS volume of the server, with clones
    /// that this Mac cannot see.
    static func mayShareData(volume: statfs) -> Bool {
        let fileSystem = withUnsafePointer(to: volume.f_fstypename) { name in
            name.withMemoryRebound(to: CChar.self, capacity: Int(MFSTYPENAMELEN)) { String(cString: $0) }
        }
        return fileSystem == "apfs" || volume.f_flags & UInt32(MNT_LOCAL) == 0
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
        /// Which of the volumes (`st_dev`) that files were found on can share data. A walk does not leave the volume of
        /// its root, so this hardly ever has more than one entry.
        private var volumesThatMayShareData: [dev_t: Bool] = [:]

        /// Counts `file`, a regular file.
        mutating func count(_ file: UnsafeMutablePointer<FTSENT>) {
            // `fts` ran `lstat` on every file that it reports, and keeps what it found out. Every entry that it returns
            // has a path.
            let info = file.pointee.fts_statp.pointee
            let allocated = info.st_blocks * 512  // always in units of 512 bytes, whatever block size the volume has

            if info.st_nlink > 1 {
                if linked.insert(FileID(device: info.st_dev, inode: info.st_ino)).inserted { apparent += allocated }
                return
            }
            let path = file.pointee.fts_path!
            let answer = PrivateSizeScanner.privateSize(ofFileAt: path)
            guard
                let own = PrivateSizeScanner.freedBytes(
                    allocated: allocated, answer: answer, volumeMayShareData: mayShareData(on: info.st_dev, at: path))
            else { return }
            apparent += allocated
            freed += own
        }

        private mutating func mayShareData(on device: dev_t, at path: UnsafePointer<CChar>) -> Bool {
            if let known = volumesThatMayShareData[device] { return known }
            let mayShare = PrivateSizeScanner.volumeMayShareData(at: path)
            volumesThatMayShareData[device] = mayShare
            return mayShare
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
