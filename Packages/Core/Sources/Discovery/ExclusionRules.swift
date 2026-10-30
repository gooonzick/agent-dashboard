import Foundation

/// Where the scan for repositories does not look.
public struct ExclusionRules: Sendable, Equatable, Codable {
    /// Absolute paths without a trailing slash. Each is left out of the scan together with everything in it.
    public var excludedPaths: [String]
    /// Whether the scan also covers the disks connected besides the startup disk.
    public var includeExternalVolumes: Bool

    public init(excludedPaths: [String], includeExternalVolumes: Bool = false) {
        self.excludedPaths = excludedPaths
        self.includeExternalVolumes = includeExternalVolumes
    }

    private static let systemPaths = [
        "/System", "/Library", "/usr", "/bin", "/sbin", "/private", "/dev", "/cores", "/opt/homebrew",
        "/Applications", "/Volumes",
    ]

    /// Relative to the home folder.
    private static let homePaths = [
        "Library", ".Trash", ".cargo", ".rustup", ".npm", ".cache", ".bun", ".nvm", ".pnpm-store", ".local/share",
        ".local/state", "go/pkg", ".gradle", ".m2", ".cocoapods", ".claude/plugins", ".codex", ".vscode/extensions",
        ".cursor/extensions", ".docker", ".colima", ".lima", ".orbstack",
    ]

    /// What a fresh install starts with: the system folders, and the folders where tools keep their own files in
    /// `home`. External disks are left out (`/Volumes`), and `includeExternalVolumes` is off.
    public static func defaults(home: URL) -> ExclusionRules {
        ExclusionRules(excludedPaths: systemPaths + homePaths.map { "\(home.path)/\($0)" })
    }

    /// Folders that belong to the tools of a project, not to the project. Inside a repository they are not entered,
    /// and a repository found in one is not a project of its own (SwiftPM checkouts in `.build`, the `protos` clone
    /// in `tmp`). `RepoScanner` documents what it does with them outside a repository.
    public static let serviceDirectoryNames: Set<String> = [
        "node_modules", "build", ".build", "DerivedData", "target", "dist", "tmp", "Pods", ".next", ".nx", ".turbo",
        ".git",
    ]

    /// Whether `path` is one of `excludedPaths` or lies in one of them.
    ///
    /// Paths are compared folder by folder, not character by character: `/Users/x/.cargo` covers
    /// `/Users/x/.cargo/registry` but not `/Users/x/.cargo-other`. Trailing slashes do not matter. An entry that is
    /// not an absolute path (an empty one, say) covers nothing, rather than everything.
    public func isExcluded(_ path: String) -> Bool {
        guard let folders = Self.folders(of: path) else { return false }
        return excludedPaths.contains { entry in
            guard let excluded = Self.folders(of: entry) else { return false }
            return folders.starts(with: excluded)
        }
    }

    /// The folder names of an absolute path from the top, or `nil` for a path that is not absolute.
    private static func folders(of path: String) -> [Substring]? {
        path.hasPrefix("/") ? path.split(separator: "/") : nil
    }
}
