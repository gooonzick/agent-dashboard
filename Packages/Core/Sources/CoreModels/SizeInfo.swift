import Foundation

/// How much disk space a folder takes, and how much of that removing it would give back.
///
/// The two differ on APFS, where files can share their data (a clone made by `cp -c`, or by a package manager such as
/// pnpm, takes no space of its own until it is changed). `du` counts shared data once for every file that shares it, so
/// it can say 2.8 GB for a folder whose removal frees 30 MB.
public struct SizeInfo: Sendable, Equatable, Codable {
    /// What the folder takes on disk, counted the way `du` does: the blocks allocated to its files, not the lengths
    /// of the files, and data that files share is counted for each of them. A file with several hard links counts
    /// once.
    public let apparentBytes: Int64
    /// What removing the folder would free. The number can be too low but is never too high: data that two files of the
    /// folder share is counted for neither, because removing one of them frees none of it, although removing both
    /// frees it.
    public let privateBytes: Int64
    /// When the folder was measured.
    public let computedAt: Date

    public init(apparentBytes: Int64, privateBytes: Int64, computedAt: Date) {
        self.apparentBytes = apparentBytes
        self.privateBytes = privateBytes
        self.computedAt = computedAt
    }
}
