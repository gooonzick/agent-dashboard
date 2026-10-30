import Discovery
import Foundation
import Synchronization
import TestSupport
import Testing

/// Folders of build tools and package managers: skipped wherever they are, repository or not.
private let toolFolders = ["node_modules", ".build", "DerivedData", "target", "dist", "Pods", ".next", ".nx", ".turbo"]
/// Generic names that are skipped inside a repository, but that an ordinary folder can have too.
private let genericFolders = ["tmp", "build"]

@Suite struct RepoScannerTests {
    // The scans below walk a `TempDir` tree. Every tree holds at least one repository that has to be found, so a scan
    // that finds nothing can never pass by accident.

    @Test func findsReposAndSkipsServiceDirsInsideRepos() async throws {
        let tmp = try TempDir(named: "My Projects")
        try tmp.makeDirectories(
            "a/.git", "b/c/.git", "a/node_modules/x/.git", "a/tmp/protos/.git", "plain/tmp/proj/.git",
            "Foo.app/Contents/.git")
        try tmp.makeFile("wt/.git")  // the .git of a worktree or a submodule is a file, and no repository of its own

        let found = await tmp.scan()

        #expect(found.map(\.lastPathComponent) == ["a", "c", "proj"])
    }

    @Test func honoursExcludedPaths() async throws {
        let tmp = try TempDir(named: "My Projects")
        try tmp.makeDirectories("a/.git", "a/inner/.git", "a/inner/deeper/.git", "ab/.git", "b/.git")

        let found = await tmp.scan(excluding: [tmp.canonicalPath + "/a"])

        #expect(found.map(\.lastPathComponent) == ["ab", "b"])  // neither a nor anything in it; ab is not a
    }

    @Test func honoursExcludedPathsGivenThroughASymlink() async throws {
        let tmp = try TempDir(named: "My Projects")
        try tmp.makeDirectories("real/a/.git", "real/b/.git")
        try tmp.makeSymlink("link", to: "real")

        let found = await tmp.scan(in: "real", excluding: [tmp.url.path + "/link/a"])

        #expect(found.map(\.lastPathComponent) == ["b"])
    }

    @Test func toleratesUnusualExcludedEntries() async throws {
        let tmp = try TempDir(named: "My Projects")
        try tmp.makeDirectories("a/.git", "b/.git")

        // A trailing slash is allowed. Entries for folders that do not exist, as most default ones will not on any one
        // Mac, do nothing. A blank or relative entry does not switch the whole scan off.
        let found = await tmp.scan(excluding: [
            tmp.canonicalPath + "/a/", tmp.canonicalPath + "/missing", "", "relative/path",
        ])

        #expect(found.map(\.lastPathComponent) == ["b"])
    }

    @Test func scansARootThatLiesBelowAnExcludedFolder() async throws {
        // Like a disk under /Volumes: the default rules exclude /Volumes, yet a disk that is asked for is scanned.
        let tmp = try TempDir(named: "My Projects")
        try tmp.makeDirectories("Volumes/Backup/x/.git", "Volumes/Backup/skipped/.git", "Volumes/Other/y/.git")

        let found = await tmp.scan(
            in: "Volumes/Backup",
            excluding: [tmp.canonicalPath + "/Volumes", tmp.canonicalPath + "/Volumes/Backup/skipped"])

        #expect(found.map(\.lastPathComponent) == ["x"])
    }

    @Test func skipsARootThatIsExcludedItself() async throws {
        let tmp = try TempDir(named: "My Projects")
        // Three roots. Backup holds a repository, and Gone is one with another inside it: both are excluded as roots.
        try tmp.makeDirectories("Backup/x/.git", "Gone/.git", "Gone/inner/.git", "Other/y/.git")
        let excluding = [tmp.canonicalPath + "/Backup", tmp.canonicalPath + "/Gone"]

        let found = await tmp.scan(in: "Backup", "Gone", "Other", excluding: excluding)

        #expect(found.map(\.lastPathComponent) == ["y"])  // not even the excluded repository itself
    }

    @Test(.timeLimit(.minutes(1)))
    func doesNotFollowSymlinkLoops() async throws {
        let tmp = try TempDir(named: "My Projects")
        try tmp.makeDirectories("a/.git")
        try tmp.makeSymlink("a/loop", to: "..")  // back to the folder that holds a

        let found = await tmp.scan()

        #expect(found.map(\.lastPathComponent) == ["a"])
    }

    @Test func doesNotOpenSymlinks() async throws {
        let tmp = try TempDir(named: "My Projects")
        try tmp.makeDirectories(
            "scan/inside/.git", "scan/folder", "elsewhere/outside/.git", "elsewhere/outside-too/.git")
        try tmp.makeSymlink("scan/folder/link", to: "../../elsewhere")  // a way out to a folder with repositories
        try tmp.makeSymlink("scan/repo-link", to: "../elsewhere/outside")  // a repository that sits elsewhere

        let found = await tmp.scan(in: "scan")

        #expect(found.map(\.lastPathComponent) == ["inside"])
    }

    @Test func aSymlinkNamedDotGitIsNoRepository() async throws {
        let tmp = try TempDir(named: "My Projects")
        try tmp.makeDirectories("real/.git", "linked")
        try tmp.makeSymlink("linked/.git", to: "../real/.git")

        let found = await tmp.scan()

        #expect(found.map(\.lastPathComponent) == ["real"])
    }

    @Test(.disabled(if: getuid() == 0, "root can read any folder, so none of them is unreadable"))
    func skipsUnreadableDirectories() async throws {
        let tmp = try TempDir(named: "My Projects")
        try tmp.makeDirectories("a/.git", "locked/inner/.git", "listed/inner/.git", "m/n/.git", "z/.git")
        // One folder that can neither be listed nor entered, and one that can be listed but not entered.
        #expect(chmod(tmp.url.appending(path: "locked").path, 0o000) == 0)
        #expect(chmod(tmp.url.appending(path: "listed").path, 0o444) == 0)
        defer {  // so that the TempDir can delete the folders again. It names tmp, which keeps the TempDir until now
            chmod(tmp.url.appending(path: "locked").path, 0o755)
            chmod(tmp.url.appending(path: "listed").path, 0o755)
        }

        let found = await tmp.scan()

        #expect(found.map(\.lastPathComponent) == ["a", "n", "z"])
    }

    @Test(.timeLimit(.minutes(1)))
    func stopsWhenCancelled() async throws {
        let tmp = try TempDir(named: "My Projects")
        try tmp.makeDirectories("a/.git", "b/.git", "c/.git", "d/.git", "e/.git", "f/g/.git")
        let asked = CallCounter()

        // The first folder is looked at and the answer is no; from the second one on it is yes.
        let found = await tmp.scan(isCancelled: { asked.next() > 1 })

        #expect(found.count < 6)  // incomplete, and no hang
        #expect(asked.total == 2)  // told to stop, it does not ask again
    }

    @Test func doesNothingWhenCancelledFromTheStart() async throws {
        let tmp = try TempDir(named: "My Projects")
        try tmp.makeDirectories("a/.git", "b/.git")

        let found = await tmp.scan(isCancelled: { true })

        #expect(found.isEmpty)
        #expect(await tmp.scan().map(\.lastPathComponent) == ["a", "b"])  // the same scan, not cancelled, finds both
    }

    @Test(.timeLimit(.minutes(1)))
    func stopsWhenTheTaskIsCancelled() async throws {
        let tmp = try TempDir(named: "My Projects")
        try tmp.makeDirectories("a/.git", "b/.git")
        let task = Task {
            while !Task.isCancelled { await Task.yield() }  // the scan only starts once its task has been cancelled
            return await tmp.scan()  // and the isCancelled it is given still says no
        }

        task.cancel()

        #expect(await task.value.isEmpty)
        #expect(await tmp.scan().map(\.lastPathComponent) == ["a", "b"])  // the same scan, not cancelled, finds both
    }

    @Test func defaultsExpandHome() {
        #expect(
            ExclusionRules.defaults(home: URL(filePath: "/Users/x")).isExcluded("/Users/x/.cargo/registry/foo"))
    }

    // What the brief's examples leave open: the rules it states in prose.

    @Test func findsTheScanRootItselfAndSkipsServiceDirsInIt() async throws {
        let tmp = try TempDir(named: "My Projects")
        try tmp.makeDirectories(".git", "node_modules/x/.git", "tmp/y/.git", "lib/.git")

        let found = await tmp.scan()

        #expect(found.map(\.lastPathComponent) == ["My Projects", "lib"])
    }

    @Test func doesNotOpenPackages() async throws {
        let tmp = try TempDir(named: "My Projects")
        try tmp.makeDirectories(
            "Foo.app/.git", "Foo.app/Contents/Inner/.git", "Thing.bundle/.git", "Proj.xcodeproj/.git", "real/.git")

        let found = await tmp.scan()

        #expect(found.map(\.lastPathComponent) == ["real"])  // neither a package itself, nor anything in it
    }

    @Test func goesOnAsIfOutsideARepositoryOnceItHasLeftOne() async throws {
        // A folder is in a repository only below that repository. Whichever of these the walk reaches first, the
        // tmp folders in the plain folders are ordinary ones, and none of them may inherit what a repository before it
        // was.
        let tmp = try TempDir(named: "My Projects")
        for n in 0..<6 {
            try tmp.makeDirectories("repo\(n)/.git", "repo\(n)/src/lib", "plain\(n)/tmp/inner\(n)/.git")
        }

        let found = await tmp.scan()

        let expected = (0..<6).map { "inner\($0)" } + (0..<6).map { "repo\($0)" }  // plain0/... comes before repo0
        #expect(found.map(\.lastPathComponent) == expected)
    }

    @Test func findsRepositoriesNestedInRepositories() async throws {
        let tmp = try TempDir(named: "My Projects")
        try tmp.makeDirectories("a/.git", "a/vendor/lib/.git", "a/vendor/lib/node_modules/p/.git", "a/vendor/lib/src")

        let found = await tmp.scan()

        #expect(found.map(\.lastPathComponent) == ["a", "lib"])
    }

    @Test func skipsServiceDirsInsideWorktreeCheckouts() async throws {
        // A worktree or a submodule has a .git file. It is no repository, so it is not reported. It is a checkout of
        // one all the same, so a repository in its tmp or build folder is no project of its own, as in a repository.
        // The worktrees that matter lie beside their repository, not in it.
        let tmp = try TempDir(named: "My Projects")
        try tmp.makeFile("wt/.git")
        try tmp.makeFile("wt2/.git")
        try tmp.makeDirectories(
            "wt/tmp/protos/.git", "wt/build/_deps/dep/.git", "wt2/tmp/clone/.git", "plain/tmp/proj/.git")

        let found = await tmp.scan()

        #expect(found.map(\.lastPathComponent) == ["proj"])  // neither wt nor wt2, nor what is in their tmp and build
    }

    @Test func skipsServiceDirsInAWorktreeCheckoutThatIsTheRoot() async throws {
        let tmp = try TempDir(named: "My Projects")
        try tmp.makeFile("wt/.git")
        try tmp.makeDirectories("wt/tmp/protos/.git", "plain/tmp/proj/.git")

        let found = await tmp.scan(in: "wt", "plain")

        #expect(found.map(\.lastPathComponent) == ["proj"])
    }

    @Test(arguments: toolFolders + genericFolders)
    func skipsServiceDirsInsideRepos(name: String) async throws {
        let tmp = try TempDir(named: "My Projects")
        try tmp.makeDirectories("a/.git", "a/\(name)/x/.git", "a/src/\(name)/y/.git", "b/.git")

        let found = await tmp.scan()

        #expect(found.map(\.lastPathComponent) == ["a", "b"])
    }

    @Test(arguments: toolFolders)
    func skipsToolFoldersOutsideReposToo(name: String) async throws {
        let tmp = try TempDir(named: "My Projects")
        try tmp.makeDirectories("plain/\(name)/x/.git", "plain/src/\(name)/y/.git", "plain/real/.git")

        let found = await tmp.scan()

        #expect(found.map(\.lastPathComponent) == ["real"])
    }

    @Test(arguments: genericFolders)
    func looksInsideTmpAndBuildOutsideRepos(name: String) async throws {
        let tmp = try TempDir(named: "My Projects")
        try tmp.makeDirectories("plain/\(name)/x/.git", "plain/src/\(name)/y/.git")

        let found = await tmp.scan()

        #expect(found.map(\.lastPathComponent).sorted() == ["x", "y"])
    }

    @Test func findsRepositoriesInHiddenFolders() async throws {
        let tmp = try TempDir(named: "My Projects")
        try tmp.makeDirectories(".dotfiles/.git", ".config/tool/.git")

        let found = await tmp.scan()

        #expect(found.map(\.lastPathComponent) == ["tool", ".dotfiles"])
    }

    @Test func returnsCanonicalPathsSortedByPath() async throws {
        let tmp = try TempDir(named: "My Projects")
        try tmp.makeDirectories("real/z/.git", "real/a/.git", "real/m/n/.git")
        try tmp.makeSymlink("link", to: "real")  // the scan root is reached through a symlink

        let found = await tmp.scan(in: "link")

        let expected = ["a", "m/n", "z"].map { tmp.canonicalPath + "/real/" + $0 }
        #expect(found.map(\.path) == expected)
    }

    @Test func reportsARepositoryOnceWhenRootsOverlap() async throws {
        let tmp = try TempDir(named: "My Projects")
        try tmp.makeDirectories("a/.git", "b/.git")
        let rules = ExclusionRules(excludedPaths: [])
        let roots = [tmp.url, tmp.url.appending(path: "a"), tmp.url.appending(path: "no-such-folder")]

        let found = await RepoScanner().scan(roots: roots, rules: rules, isCancelled: { false })

        #expect(found.map(\.lastPathComponent) == ["a", "b"])
    }

    @Test func defaultRootsAreTheStartupDiskAlone() {
        let roots = RepoScanner().defaultRoots(rules: ExclusionRules(excludedPaths: []))
        #expect(roots.map(\.path) == ["/"])
    }

    @Test func defaultRootsWithExternalVolumesStartWithTheStartupDisk() {
        // Which volumes there are depends on the machine; the startup disk comes first, once, whatever else is there.
        let rules = ExclusionRules(excludedPaths: [], includeExternalVolumes: true)
        let paths = RepoScanner().defaultRoots(rules: rules).map(\.path)
        #expect(paths.first == "/")
        #expect(Set(paths).count == paths.count)
    }
}

/// Counts calls, for a closure that has to be `Sendable`.
private final class CallCounter: Sendable {
    private let calls = Mutex(0)

    /// Counts one more call and returns how many there have been so far.
    func next() -> Int { calls.withLock { $0 += 1; return $0 } }
    var total: Int { calls.withLock { $0 } }
}

private extension TempDir {
    /// Creates each of `paths`, relative to this folder, as a folder.
    func makeDirectories(_ paths: String...) throws {
        for path in paths {
            try FileManager.default.createDirectory(at: url.appending(path: path), withIntermediateDirectories: true)
        }
    }

    /// Creates an empty file at `path`, relative to this folder.
    func makeFile(_ path: String) throws {
        let file = url.appending(path: path)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data().write(to: file)
    }

    /// Creates a symlink at `path`, relative to this folder, that points to `destination` (relative to the link).
    func makeSymlink(_ path: String, to destination: String) throws {
        try FileManager.default.createSymbolicLink(
            atPath: url.appending(path: path).path, withDestinationPath: destination)
    }

    /// Scans this folder, or the `subfolders` of it as roots, with only `excludedPaths` left out and external volumes
    /// off. A method of the `TempDir`, so that the folder is there for as long as the scan runs.
    func scan(
        in subfolders: String..., excluding excludedPaths: [String] = [],
        isCancelled: @Sendable () -> Bool = { false }
    ) async -> [URL] {
        let rules = ExclusionRules(excludedPaths: excludedPaths, includeExternalVolumes: false)
        let roots = subfolders.isEmpty ? [url] : subfolders.map { url.appending(path: $0) }
        return await RepoScanner().scan(roots: roots, rules: rules, isCancelled: isCancelled)
    }
}
