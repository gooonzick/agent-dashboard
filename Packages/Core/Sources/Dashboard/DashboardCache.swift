import CoreModels
import Foundation

/// What the dashboard keeps from one run to the next, so that the window has something to show before the scan of the
/// disk is through: the repositories that were found, and the sizes that were measured, of the worktrees and of what
/// the Caches and Docker page shows.
///
/// It holds paths, ids and sizes and nothing else: no remote, no host, no branch. A remote can carry a token
/// (`https://user:token@host/...`), and a file in Application Support is no place for one.
public struct DashboardCache: Sendable {
    public struct Contents: Sendable, Equatable, Codable {
        /// The canonical paths of the repositories.
        public var repositories: [String]
        /// By the canonical path of a worktree.
        public var sizes: [String: SizeInfo]
        /// What the Caches and Docker page measured, by the key of `CleanupState.sizes`: the id of a cache, the path of
        /// a build output, or `CleanupState.dockerDiskKey`. A file written before the page existed has none.
        public var cleanupSizes: [String: SizeInfo]

        public init(
            repositories: [String] = [], sizes: [String: SizeInfo] = [:], cleanupSizes: [String: SizeInfo] = [:]
        ) {
            self.repositories = repositories
            self.sizes = sizes
            self.cleanupSizes = cleanupSizes
        }

        private enum CodingKeys: String, CodingKey { case repositories, sizes, cleanupSizes }

        public init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            repositories = try container.decode([String].self, forKey: .repositories)
            sizes = try container.decode([String: SizeInfo].self, forKey: .sizes)
            cleanupSizes = try container.decodeIfPresent([String: SizeInfo].self, forKey: .cleanupSizes) ?? [:]
        }
    }

    /// The layout of the file. A file of another version is not read: it starts empty.
    private struct File: Codable {
        static let currentVersion = 1
        let version: Int
        let contents: Contents
    }

    public let url: URL

    public init(url: URL) {
        self.url = url
    }

    /// `~/Library/Application Support/AgentDashboard/cache.json`.
    public static var standard: DashboardCache {
        DashboardCache(url: URL.applicationSupportDirectory.appending(path: "AgentDashboard/cache.json"))
    }

    /// What the file holds, or nothing if there is no file or it cannot be read. Entries that are not absolute paths
    /// are dropped: the file is outside the app's control.
    public func load() -> Contents {
        guard let data = try? Data(contentsOf: url),
            let file = try? JSONDecoder().decode(File.self, from: data), file.version == File.currentVersion
        else { return Contents() }
        return Contents(
            repositories: file.contents.repositories.filter { $0.hasPrefix("/") },
            sizes: file.contents.sizes.filter { $0.key.hasPrefix("/") }, cleanupSizes: file.contents.cleanupSizes)
    }

    /// Replaces what the file holds, making its folder if there is none. The file is replaced as a whole, so a reader
    /// never sees half of it.
    public func save(_ contents: Contents) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(File(version: File.currentVersion, contents: contents)).write(to: url, options: .atomic)
    }
}

/// Writes the cache away from the main actor, in the order the versions were made: a write that comes later than a
/// newer one is dropped.
actor CacheWriter {
    private let cache: DashboardCache
    private var written = 0

    init(cache: DashboardCache) {
        self.cache = cache
    }

    func write(_ contents: DashboardCache.Contents, version: Int) {
        guard version > written else { return }
        written = version
        // A cache that cannot be written is one that the next start does without: nothing depends on it.
        try? cache.save(contents)
    }
}
