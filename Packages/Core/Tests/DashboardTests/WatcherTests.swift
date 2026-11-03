import CoreModels
@testable import Dashboard
import Discovery
import Foundation
import GitKit
import TestSupport
import Testing

/// How the store follows what changes on the disk through its two watches: the scan roots, for repositories that come
/// and go, and the worktrees, for statuses and sizes.
@MainActor
@Suite struct WatcherTests {
    /// A folder on the disk with `folders` made in it, and a scene whose scan root is `root` inside it.
    private func disk(_ folders: [String], root: String = "") throws -> (TempDir, String) {
        let disk = try TempDir(named: "disk")
        for folder in folders {
            try FileManager.default.createDirectory(
                atPath: disk.canonicalPath + "/" + folder, withIntermediateDirectories: true)
        }
        return (disk, disk.canonicalPath + (root.isEmpty ? "" : "/" + root))
    }

    @Test func watchesTheRootsAndTheWorktreesWithTwoSecondsOfLatency() async throws {
        let scene = try Scene(scanner: FakeScanner(roots: [URL(filePath: "/x")]))
        let gone = linked("/x/gone", branch: "g", prunable: true)
        scene.addRepository("/x/repo", worktrees: [linked("/x/wt", branch: "b"), gone])
        let store = await scene.startedStore()

        let live = scene.watcher.live
        #expect(live.map(\.paths).sorted { $0.count < $1.count } == [["/x"], ["/x/repo", "/x/wt"]])
        #expect(live.allSatisfy { $0.latency == .seconds(2) })
        withExtendedLifetime(store) {}  // the watches last as long as the store
    }

    @Test func onlyRepositoriesThatAScanWouldFindAreAdded() async throws {
        let (disk, root) = try disk(
            [
                "x/plain/tmp/proj/.git",  // tmp outside a checkout is an ordinary folder
                "x/checkout/.git", "x/checkout/tmp/protos/.git",  // tmp inside one is the project's own
                "x/web/node_modules/dep/.git", "x/skipped/r/.git", "elsewhere/r/.git",
            ], root: "x")
        let scene = try Scene(scanner: FakeScanner(roots: [URL(filePath: root)]))
        scene.settings.rules = ExclusionRules(excludedPaths: [root + "/skipped"])
        let store = await scene.startedStore()
        let candidates = [
            "plain/tmp/proj", "checkout", "checkout/tmp/protos", "web/node_modules/dep", "skipped/r", "../elsewhere/r",
        ].map { root + "/" + $0 }
        for path in candidates { scene.addRepository(path) }

        scene.watcher.send(candidates.map { $0 + "/.git" }, toWatchOf: root)
        await scene.settle(store)

        #expect(store.projects.map(\.path) == [root + "/checkout", root + "/plain/tmp/proj"])
        _ = disk
    }

    @Test func anExcludedFolderAboveTheRootDoesNotHideWhatIsInTheRoot() async throws {
        let (disk, root) = try disk(["Volumes/Ext/r/.git", "Volumes/Ext/skipped/s/.git"], root: "Volumes/Ext")
        let scene = try Scene(scanner: FakeScanner(roots: [URL(filePath: root)]))
        scene.settings.rules = ExclusionRules(
            excludedPaths: [disk.canonicalPath + "/Volumes", root + "/skipped"], includeExternalVolumes: true)
        let store = await scene.startedStore()
        scene.addRepository(root + "/r")
        scene.addRepository(root + "/skipped/s")

        scene.watcher.send([root + "/r/.git", root + "/skipped/s/.git/objects"], toWatchOf: root)
        await scene.settle(store)

        #expect(store.projects.map(\.path) == [root + "/r"])
    }

    @Test func findsARepositoryThatWasMovedIntoAFolder() async throws {
        let (disk, root) = try disk(["x/projects/moved/.git"], root: "x")
        let scene = try Scene(scanner: FakeScanner(roots: [URL(filePath: root)]))
        let store = await scene.startedStore()
        scene.addRepository(root + "/projects/moved")

        // A move changes nothing inside the repository: FSEvents reports the folder that it was moved into.
        scene.watcher.send([root + "/projects"], toWatchOf: root)
        await scene.settle(store)

        #expect(store.projects.map(\.path) == [root + "/projects/moved"])
        _ = disk
    }

    @Test func aRepositoryThatGoesWithItsParentDisappears() async throws {
        let (disk, root) = try disk(["x/group/a/.git", "x/group/b/.git"], root: "x")
        let scene = try Scene(scanner: FakeScanner(roots: [URL(filePath: root)]))
        scene.addRepository(root + "/group/a")
        scene.addRepository(root + "/group/b")
        let store = await scene.startedStore()
        #expect(store.projects.count == 2)

        try FileManager.default.removeItem(atPath: root + "/group")
        scene.watcher.send([root], toWatchOf: root)
        await scene.settle(store)

        #expect(store.projects.isEmpty)
        _ = disk
    }

    @Test func aChangeInAWorktreeRereadsItsStatusAndMeasuresItAgain() async throws {
        let scene = try Scene(scanner: FakeScanner(roots: [URL(filePath: "/x")]))
        let worktree = linked("/x/wt", branch: "b")
        scene.addRepository("/x/repo", worktrees: [worktree, linked("/x/other", branch: "o")])
        let store = await scene.startedStore()
        let listings = scene.git.count { $0 == .worktrees("/x/repo") }
        scene.git.update("/x/repo") { $0.statuses[worktree.path] = WorktreeStatus(upstream: "origin/x", modified: 4) }
        scene.passTime(60)

        scene.watcher.send([worktree.path + "/src"], toWatchOf: worktree.path)
        await scene.settle(store)

        #expect(store.row(worktree.path)?.status?.modified == 4)
        #expect(scene.git.count { $0 == .worktrees("/x/repo") } == listings)  // one worktree, not the repository
        #expect(scene.git.count { $0 == .status("/x/other") } == 1)
        #expect(scene.sizes.measured.filter { $0.path == worktree.path }.count == 2)
    }

    @Test func aWorktreeIsMeasuredAtMostTwiceAMinute() async throws {
        let scene = try Scene(scanner: FakeScanner(roots: [URL(filePath: "/x")]))
        let worktree = linked("/x/wt", branch: "b")
        scene.addRepository("/x/repo", worktrees: [worktree])
        let store = await scene.startedStore()

        scene.passTime(5)
        scene.watcher.send([worktree.path + "/build"], toWatchOf: worktree.path)
        await scene.settle(store)
        #expect(scene.sizes.measured.filter { $0.path == worktree.path }.count == 1)

        // What changed is measured once the time is up, at the next sample of the processes.
        scene.passTime(30)
        store.isWindowVisible = true
        #expect(await poll { scene.sizes.measured.filter { $0.path == worktree.path }.count == 2 })
        store.isWindowVisible = false
    }

    @Test func aChangeInTheGitFolderOfTheRepositoryReadsItAgain() async throws {
        let scene = try Scene(scanner: FakeScanner(roots: [URL(filePath: "/x")]))
        scene.addRepository("/x/repo")
        let store = await scene.startedStore()
        let added = linked("/x/added", branch: "new")
        scene.git.update("/x/repo") { repo in
            repo.worktrees.append(added)
            repo.statuses[added.path] = cleanAndPushed
        }

        scene.watcher.send(["/x/repo/.git/worktrees"], toWatchOf: "/x/repo")
        await scene.settle(store)

        #expect(store.row(added.path)?.status == cleanAndPushed)
        #expect(scene.watcher.live.contains { $0.paths == ["/x/added", "/x/repo"] })
    }

    @Test func aChangeInTheAdminFolderOfAWorktreeRereadsThatWorktreeAlone() async throws {
        let disk = try TempDir(named: "disk")
        let repo = disk.canonicalPath + "/repo"
        let worktree = disk.canonicalPath + "/wt"
        try FileManager.default.createDirectory(atPath: repo + "/.git/worktrees/wt1", withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: worktree, withIntermediateDirectories: true)
        try "gitdir: \(repo)/.git/worktrees/wt1\n".write(toFile: worktree + "/.git", atomically: true, encoding: .utf8)
        let scene = try Scene(scanner: FakeScanner(roots: [URL(filePath: disk.canonicalPath)]))
        scene.addRepository(repo, worktrees: [linked(worktree, branch: "b")])
        let store = await scene.startedStore()
        let reads = scene.git.calls.count
        scene.git.update(repo) { $0.statuses[worktree] = WorktreeStatus(upstream: "origin/x", modified: 1) }

        // A commit or a `git add` in the worktree writes to its admin folder in the repository, not to its own folder.
        scene.watcher.send([repo + "/.git/worktrees/wt1/logs"], toWatchOf: repo)
        await scene.settle(store)

        #expect(store.row(worktree)?.status?.modified == 1)
        #expect(!scene.git.calls.dropFirst(reads).contains(.worktrees(repo)))
        #expect(!scene.git.calls.dropFirst(reads).contains(.status(repo)))
    }

    @Test func objectsAndLogsChangeNoStatus() async throws {
        let scene = try Scene(scanner: FakeScanner(roots: [URL(filePath: "/x")]))
        scene.addRepository("/x/repo")
        let store = await scene.startedStore()
        let reads = scene.git.calls.count

        scene.watcher.send(["/x/repo/.git/objects/ab", "/x/repo/.git/logs/refs"], toWatchOf: "/x/repo")
        await scene.settle(store)

        #expect(scene.git.calls.count == reads)
    }

    @Test func hiddenRepositoriesAreNotShown() async throws {
        let scene = try Scene()
        scene.addRepository("/x/shown")
        scene.addRepository("/x/hidden")
        scene.settings.hiddenRepos = ["/x/hidden"]

        let store = await scene.startedStore()

        #expect(store.projects.map(\.path) == ["/x/shown"])
        #expect(!scene.git.calls.contains(.worktrees("/x/hidden")))
    }
}
