import CoreModels
import Foundation

/// Finds git repositories on disk.
public protocol RepoScanning: Sendable {
    /// The repositories under `roots`: directory URLs with canonical paths (`canonicalPath`), sorted by path, each one
    /// once however many roots lead to it.
    ///
    /// A repository is a folder that holds a `.git` folder. A `.git` file, as in a worktree or a submodule, does not
    /// make one. The walk goes on below a repository, so repositories inside repositories are found as well.
    ///
    /// The walk does not follow symlinks, does not look inside packages such as `.app`, and passes over folders it is
    /// not allowed to read. The tool folders in `ExclusionRules.serviceDirectoryNames` are not entered, except `tmp`
    /// and `build`, which are only skipped inside a repository: outside one they are ordinary folders that may hold
    /// projects.
    ///
    /// A folder in `rules.excludedPaths` is left out with everything in it. That holds for a root, too, but not for a
    /// folder above a root, so that a disk under `/Volumes` can be scanned although the default rules exclude
    /// `/Volumes`.
    ///
    /// `isCancelled` is asked once for every folder. When it says yes the scan stops, and returns what it has found
    /// until then. Cancelling the task that runs the scan has the same effect.
    ///
    /// The walk is file system work that blocks its thread for as long as it takes: run it from a background task, at
    /// `.utility` priority or lower.
    func scan(roots: [URL], rules: ExclusionRules, isCancelled: @Sendable () -> Bool) async -> [URL]
}

public struct RepoScanner: RepoScanning {
    /// Service folders that are ordinary folders outside a repository: anyone can name a folder `tmp` or `build`.
    private static let skippedOnlyInsideRepositories: Set<String> = ["tmp", "build"]

    public init() {}

    /// The startup disk and, if `rules` ask for it, the other disks that are mounted.
    public func defaultRoots(rules: ExclusionRules) -> [URL] {
        let startupDisk = URL(filePath: "/", directoryHint: .isDirectory)
        guard rules.includeExternalVolumes else { return [startupDisk] }
        // The hidden volumes are the ones macOS keeps for itself (`/System/Volumes/...`). Their files are on the
        // startup disk already.
        let mounted = FileManager.default.mountedVolumeURLs(
            includingResourceValuesForKeys: nil, options: [.skipHiddenVolumes])
        return [startupDisk] + (mounted ?? []).filter { $0.path != startupDisk.path }
    }

    /// `@concurrent`: the walk blocks its thread for as long as it takes, so it must never run on the actor that calls
    /// it, the main actor say. A plain `async` function would, as soon as the module is built with
    /// `NonisolatedNonsendingByDefault`, which Xcode's "approachable concurrency" turns on.
    @concurrent
    public func scan(roots: [URL], rules: ExclusionRules, isCancelled: @Sendable () -> Bool) async -> [URL] {
        // The walk sees canonical paths, so the paths it is compared with have to be canonical too. An entry that is
        // not absolute would be taken relative to the working directory by `realpath`.
        // Looking each folder up in this set is enough, because the walk reaches a folder through its parents. It is
        // also why an excluded folder above a root does not matter.
        let excluded = Set(rules.excludedPaths.filter { $0.hasPrefix("/") }.map(canonicalPath))
        var repositories: Set<String> = []
        for root in roots {
            let finished = Self.walk(
                canonicalPath(root.path), excluding: excluded, isCancelled: { Task.isCancelled || isCancelled() },
                into: &repositories)
            if !finished { break }
        }
        return repositories.sorted().map { URL(filePath: $0, directoryHint: .isDirectory) }
    }

    /// Adds the canonical paths of the repositories in `root` to `repositories`. Returns `false` if `isCancelled` made
    /// it stop before it was through.
    private static func walk(
        _ root: String, excluding excluded: Set<String>, isCancelled: () -> Bool, into repositories: inout Set<String>
    ) -> Bool {
        guard !excluded.contains(root) else { return true }
        guard !isCancelled() else { return false }

        // The depth of the topmost repository that the walk is in, with `root` at level 0. `nil` outside repositories.
        var repositoryLevel: Int?
        if isRepository(root) {
            repositories.insert(root)
            repositoryLevel = 0
        }

        // Hidden folders are walked too: the `.git` of a repository is one. With no error handler, a folder that cannot
        // be read is passed over without a word.
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .isSymbolicLinkKey, .isPackageKey]
        guard
            let items = FileManager.default.enumerator(
                at: URL(filePath: root, directoryHint: .isDirectory), includingPropertiesForKeys: Array(keys),
                options: [.skipsPackageDescendants])
        else { return true }

        while let item = items.nextObject() as? URL {
            // Only folders matter. A symlink is not one (`isDirectory` is false for it, and the enumerator does not
            // enter it), but it is not taken on trust.
            guard let values = try? item.resourceValues(forKeys: keys),
                values.isDirectory == true, values.isSymbolicLink != true
            else { continue }
            guard !isCancelled() else { return false }

            // The walk has left a repository once it is back at the level of that repository's folder, or above.
            if let level = repositoryLevel, items.level <= level { repositoryLevel = nil }

            let path = item.path
            let name = item.lastPathComponent
            let isServiceDirectory =
                ExclusionRules.serviceDirectoryNames.contains(name)
                && (repositoryLevel != nil || !skippedOnlyInsideRepositories.contains(name))
            if excluded.contains(path) || values.isPackage == true || isServiceDirectory {
                items.skipDescendants()
                continue
            }

            if isRepository(path) {
                repositories.insert(canonicalPath(path))
                repositoryLevel = repositoryLevel ?? items.level
            }
        }
        return true
    }

    /// Whether `directory` holds a `.git` folder. A symlink named `.git` does not count: symlinks are not opened.
    private static func isRepository(_ directory: String) -> Bool {
        var info = stat()
        return lstat(directory + "/.git", &info) == 0 && (info.st_mode & S_IFMT) == S_IFDIR
    }
}
