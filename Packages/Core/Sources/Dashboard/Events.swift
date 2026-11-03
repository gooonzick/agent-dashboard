import CoreModels
import Discovery
import Foundation

/// Whether `path` is `folder` or lies in it, folder by folder: `/x/a` holds `/x/a/b` but not `/x/ab`.
func isInside(_ path: String, _ folder: String) -> Bool {
    path == folder || path.hasPrefix(folder == "/" ? "/" : folder + "/")
}

/// What a change in the worktrees means for the store.
struct WorktreeChanges: Equatable {
    /// Repositories to read again as a whole: their list of worktrees, or a ref that any of them may use, changed.
    var repositories: Set<String> = []
    /// Single worktrees to read again, by their path, with the path of their repository.
    var worktrees: [String: String] = [:]
    /// Folders whose size is out of date.
    var sizes: Set<String> = []

    /// What a change in the folders `paths` means, given the repositories and their worktrees.
    ///
    /// A change in a worktree's own folder is that worktree's: the deepest worktree that holds it. Below the `.git` of
    /// a repository it depends on what changed: objects and logs change no status, only the size of the repository;
    /// the folder of a linked worktree in `.git/worktrees/<name>` (its index and HEAD) is that worktree's; anything
    /// else (refs, `packed-refs`, the index and HEAD of the main worktree, the list of worktrees) may change the
    /// status of every worktree, and the repository is read again.
    init(_ paths: [String], in repositories: some Collection<Repository>) {
        for path in paths {
            if let repo = repositories.first(where: { isInside(path, $0.path + "/.git") }) {
                sizes.insert(repo.path)
                let below = path.dropFirst(repo.path.count + "/.git".count).split(separator: "/")
                switch (below.first, below.dropFirst().first) {
                case ("objects", _), ("logs", _):
                    break
                case ("worktrees", let name?):
                    if let worktree = repo.adminNames[String(name)] {
                        worktrees[worktree] = repo.path
                    } else {
                        self.repositories.insert(repo.path)
                    }
                default:
                    self.repositories.insert(repo.path)
                }
                continue
            }
            let holders = repositories.flatMap { repo in
                repo.worktrees.filter { !$0.isPrunable && isInside(path, $0.path) }.map { (repo: repo.path, $0.path) }
            }
            if let deepest = holders.max(by: { $0.1.count < $1.1.count }) {
                worktrees[deepest.1] = deepest.repo
                sizes.insert(deepest.1)
            }
        }
        for repo in self.repositories { worktrees = worktrees.filter { $0.value != repo } }
    }
}

/// What a change below the scan roots means: repositories that appeared, and known ones that are gone.
struct RepositoryChanges: Sendable, Equatable {
    var added: Set<String> = []
    var gone: Set<String> = []

    /// Looks at the disk for what `paths`, folders in which something changed, can mean.
    ///
    /// A path inside a `.git` folder is about the folder that holds that `.git`. Any other is about the folder itself,
    /// the folders in it (a repository moved in changes nothing inside itself, only the folder that it was moved
    /// into) and the known repositories in it (a folder deleted or moved away with the repository in it). A folder that
    /// has a `.git` folder is added if a scan would find it (`RepoScanner.wouldFind`, which applies the exclusions
    /// below a root, never above it); a known repository whose `.git` folder is gone is gone.
    ///
    /// The roots are the whole disk, and most of what changes on it is of no interest here: the caches of the system
    /// and the apps, which are excluded, and the builds in the repositories that are known. Those paths are passed
    /// over before anything is read from the disk for them (Ruling 70): a path in an excluded folder (below every root
    /// that lies in it), and the folders in a known repository, or the repository itself, which are looked at only for
    /// the known repositories that they hold. So a repository that appears inside a known one without a `.git` of its
    /// own changing, moved in say, is found by the next scan, not by the watch.
    @concurrent
    static func inspect(_ paths: [String], known: Set<String>, roots: [URL], rules: ExclusionRules) async -> Self {
        var changes = RepositoryChanges()
        var looked: Set<String> = []
        func consider(_ folder: String) {
            guard looked.insert(folder).inserted else { return }
            if known.contains(folder) {
                if !hasGitFolder(folder) { changes.gone.insert(folder) }
            } else if RepoScanner.wouldFind(folder, roots: roots, rules: rules) {
                changes.added.insert(folder)
            }
        }
        for path in paths where !isExcluded(path, roots: roots, rules: rules) {
            let names = path.split(separator: "/", omittingEmptySubsequences: true)
            if let git = names.firstIndex(of: ".git") {
                consider("/" + names[..<git].joined(separator: "/"))
                continue
            }
            for repo in known where isInside(repo, path) { consider(repo) }
            guard !known.contains(where: { isInside(path, $0) }) else { continue }
            consider(path)
            guard RepoScanner.walks(into: path, roots: roots, rules: rules) else { continue }
            for child in (try? FileManager.default.contentsOfDirectory(atPath: path)) ?? [] {
                consider(path == "/" ? "/" + child : path + "/" + child)
            }
        }
        return changes
    }

    /// Whether `path` lies in a folder that `rules` exclude, and in no root inside that folder: a scan never looks
    /// there. Paths alone are compared, and nothing is read from the disk.
    private static func isExcluded(_ path: String, roots: [URL], rules: ExclusionRules) -> Bool {
        rules.excludedPaths.contains { excluded in
            excluded.hasPrefix("/") && isInside(path, excluded)
                && !roots.contains { $0.path != excluded && isInside($0.path, excluded) && isInside(path, $0.path) }
        }
    }

    private static func hasGitFolder(_ folder: String) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: folder + "/.git", isDirectory: &isDirectory)
            && isDirectory.boolValue
    }
}
