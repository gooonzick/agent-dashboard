import CoreModels
import Foundation

/// Finds git repositories on disk.
public protocol RepoScanning: Sendable {
    /// The repositories under `roots`: directory URLs with canonical paths (`canonicalPath`), sorted by path, each one
    /// once however many roots lead to it.
    ///
    /// A repository is a folder that holds a `.git` folder. A `.git` file, as in a worktree or a submodule, does not
    /// make one, so such a folder is not reported, but it counts as part of a project for the tool folders below. The
    /// walk goes on below a repository, so repositories inside repositories are found as well.
    ///
    /// The walk does not follow symlinks, does not look inside packages such as `.app`, and passes over folders it is
    /// not allowed to read. The tool folders in `ExclusionRules.serviceDirectoryNames` are not entered, except `tmp`
    /// and `build`, which are only skipped inside a project, that is inside a repository or a worktree or submodule
    /// (a folder with a `.git` file): elsewhere they are ordinary folders that may hold projects.
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

    /// The folders that a scan of the whole Mac starts from: the startup disk and, if `rules` ask for it, the other
    /// disks that are mounted.
    func defaultRoots(rules: ExclusionRules) -> [URL]
}

public struct RepoScanner: RepoScanning {
    /// Service folders that are ordinary folders outside a project: anyone can name a folder `tmp` or `build`.
    private static let skippedOnlyInsideProjects: Set<String> = ["tmp", "build"]

    /// What the `.git` in a folder is.
    private enum DotGit {
        /// There is none, or it is something that is not opened, a symlink say.
        case nothing
        /// A folder: the folder is a repository.
        case folder
        /// A regular file, as in a worktree or a submodule: the folder is a checkout of a repository that lies
        /// elsewhere.
        case file
    }

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
        let excluded = Self.excludedFolders(rules)
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

        // The depth of the topmost project folder that the walk is in, with `root` at level 0. `nil` outside projects.
        var projectLevel: Int?
        // What the `.git` in `directory`, which is at `level`, makes of it. Only a `.git` folder makes a repository. A
        // `.git` file, as in a worktree or a submodule, does not (git lists the worktrees of a repository, they are not
        // found by walking). The folder is a project all the same, so the tool folders in it are skipped as they are
        // in a repository, and the clone in the `tmp` of every worktree is not taken for a project of its own.
        func note(_ directory: String, at level: Int) {
            switch dotGit(in: directory) {
            case .folder:
                repositories.insert(canonicalPath(directory))
                projectLevel = projectLevel ?? level
            case .file:
                projectLevel = projectLevel ?? level
            case .nothing:
                break
            }
        }
        note(root, at: 0)

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

            // The walk has left a project once it is back at the level of that project's folder, or above.
            if let level = projectLevel, items.level <= level { projectLevel = nil }

            let path = item.path
            let name = item.lastPathComponent
            let isServiceDirectory =
                ExclusionRules.serviceDirectoryNames.contains(name)
                && (projectLevel != nil || !skippedOnlyInsideProjects.contains(name))
            if excluded.contains(path) || values.isPackage == true || isServiceDirectory {
                items.skipDescendants()
                continue
            }

            note(path, at: items.level)
        }
        return true
    }

    /// What the `.git` in `directory` is. A symlink named `.git` is nothing: symlinks are not opened.
    private static func dotGit(in directory: String) -> DotGit {
        var info = stat()
        guard lstat(directory + "/.git", &info) == 0 else { return .nothing }
        switch info.st_mode & S_IFMT {
        case S_IFDIR: return .folder
        case S_IFREG: return .file
        default: return .nothing
        }
    }
}

// MARK: - Judging one folder

extension RepoScanner {
    /// Whether a scan of `roots` with `rules` reports `folder` as a repository, judged by the folder and the folders
    /// between a root and it, without walking anything else. It is what the file watcher asks when a `.git` folder
    /// appears: the answer is the one that a full scan would give, by the same rules (see `scan`).
    ///
    /// The folder needs a `.git` folder, and it has to lie in a root, or be one. On the way down from that root, no
    /// folder may be excluded by `rules`, be a package or a symlink, or be a tool folder: one of
    /// `ExclusionRules.serviceDirectoryNames`, where `tmp` and `build` count only below a folder that holds a `.git`
    /// folder or file. An excluded folder above the root does not matter, as for `scan`.
    public static func wouldFind(_ folder: String, roots: [URL], rules: ExclusionRules) -> Bool {
        let path = canonicalPath(folder)
        return dotGit(in: path) == .folder && walks(into: path, roots: roots, rules: rules)
    }

    /// Whether a scan of `roots` with `rules` walks into `folder` and looks at what is in it: the conditions of
    /// `wouldFind` without the `.git` folder.
    public static func walks(into folder: String, roots: [URL], rules: ExclusionRules) -> Bool {
        let path = canonicalPath(folder)
        let excluded = excludedFolders(rules)
        return roots.contains { reaches(path, from: canonicalPath($0.path), excluding: excluded) }
    }

    /// The excluded folders as the walk sees paths: canonical, and absolute (`realpath` would take a relative entry
    /// relative to the working directory).
    private static func excludedFolders(_ rules: ExclusionRules) -> Set<String> {
        Set(rules.excludedPaths.filter { $0.hasPrefix("/") }.map(canonicalPath))
    }

    /// Whether the walk from `root` gets to `path`, step by step, as `walk` takes them.
    private static func reaches(_ path: String, from root: String, excluding excluded: Set<String>) -> Bool {
        let rootNames = root.split(separator: "/")
        let names = path.split(separator: "/")
        guard path.hasPrefix("/"), names.starts(with: rootNames), !excluded.contains(root) else { return false }
        var current = root
        // Whether the walk is in a project, as `projectLevel` says in `walk`: a folder on the way holds a `.git`.
        var inProject = dotGit(in: root) != .nothing
        for name in names.dropFirst(rootNames.count) {
            current = current == "/" ? "/\(name)" : "\(current)/\(name)"
            let name = String(name)
            let isServiceDirectory =
                ExclusionRules.serviceDirectoryNames.contains(name)
                && (inProject || !skippedOnlyInsideProjects.contains(name))
            guard !excluded.contains(current), !isServiceDirectory, isWalkedFolder(current) else { return false }
            if dotGit(in: current) != .nothing { inProject = true }
        }
        return true
    }

    /// A folder that the walk enters: a directory that is neither a symlink nor a package.
    private static func isWalkedFolder(_ path: String) -> Bool {
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .isSymbolicLinkKey, .isPackageKey]
        guard let values = try? URL(filePath: path).resourceValues(forKeys: keys) else { return false }
        return values.isDirectory == true && values.isSymbolicLink != true && values.isPackage != true
    }
}
