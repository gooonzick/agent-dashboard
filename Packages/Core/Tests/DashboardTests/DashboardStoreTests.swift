import CoreModels
@testable import Dashboard
import Foundation
import GitKit
import Hosting
import Safety
import TestSupport
import Testing

@MainActor
@Suite struct DashboardStoreTests {
    @Test func showsCachedProjectsBeforeScanFinishes() async throws {
        let scene = try Scene(scanner: FakeScanner(hangs: true))
        try scene.cache.save(DashboardCache.Contents(repositories: ["/x/a", "/x/b"]))
        scene.addRepository("/x/a")
        let store = scene.makeStore()

        let start = Task { await store.start() }

        #expect(await poll { store.scanState == .scanning(found: 2) })
        #expect(store.projects.count == 2)
        #expect(store.projects.map(\.path) == ["/x/a", "/x/b"])
        start.cancel()
        await start.value
        #expect(store.scanState == .idle)
        #expect(store.projects.count == 2)  // a scan that was given up on removes nothing
    }

    @Test func whatGitSaysWhenItCannotReadAStatusIsKeptForTheInspector() async throws {
        let scene = try Scene()
        scene.addRepository("/x/repo", worktrees: [linked("/x/wt", branch: "b")])
        scene.git.update("/x/repo") { $0.statuses["/x/repo"] = nil }  // git fails with "fake failure"

        let store = await scene.startedStore()

        #expect(store.row("/x/repo")?.status == nil)
        #expect(store.row("/x/repo")?.statusError == "fake failure")
        #expect(store.row("/x/wt")?.statusError == nil)
    }

    @Test func theErrorOfAStatusNamesNoCredentials() {
        let error = GitError.failed(
            command: "git status", exitCode: 128,
            stderr: "fatal: could not read https://deploy:glpat-SECRET@gitlab.example.test/team/app.git\nmore")
        #expect(Reader.describe(error) == "fatal: could not read https://gitlab.example.test/team/app.git")
        #expect(Reader.describe(GitError.failed(command: "git status", exitCode: 3, stderr: "")) == "git exited with 3")
    }

    @Test func aListOfWorktreesThatGitCannotGiveKeepsTheRowsAndTheirSizes() async throws {
        let scene = try Scene()
        scene.addRepository("/x/repo", worktrees: [linked("/x/wt", branch: "b")])
        let store = await scene.startedStore()
        let size = try #require(store.row("/x/wt")?.size)
        let repo = try #require(scene.git.repo("/x/repo"))

        scene.git.forget("/x/repo")  // every command fails: a repository that is busy, or a git that is broken
        await store.refresh()
        await scene.settle(store)

        #expect(store.projects.map(\.path) == ["/x/repo"])
        #expect(store.row("/x/wt")?.size == size)
        // Nothing that was read before is taken for true: the status is not known now.
        #expect(store.row("/x/wt")?.status == nil)
        #expect(store.row("/x/wt")?.eligibility == .blocked([.statusUnavailable]))

        scene.git.set("/x/repo", repo)
        await store.refresh()
        #expect(store.row("/x/wt")?.status == cleanAndPushed)
    }

    @Test func theWindowStartsTheStoreOnceInARun() async throws {
        let scene = try Scene()
        scene.addRepository("/x/repo")
        let store = scene.makeStore()

        await store.startIfNeeded()
        await store.startIfNeeded()  // the window appears again
        #expect(scene.scanner.scans == 1)

        await store.start()  // Refresh
        #expect(scene.scanner.scans == 2)
        await store.startIfNeeded()
        #expect(scene.scanner.scans == 2)
        await scene.settle(store)
    }

    @Test func readyContainsOnlyMergedClean() async throws {
        let scene = try Scene()
        let mergedClean = linked("/x/wt-a", branch: "a")
        let mergedUntracked = linked("/x/wt-b", branch: "b")
        let openClean = linked("/x/wt-c", branch: "c")
        scene.addRepository("/x/repo", worktrees: [mergedClean, mergedUntracked, openClean])
        scene.git.update("/x/repo") {
            $0.statuses[mergedUntracked.path] = WorktreeStatus(upstream: "origin/b", untracked: 1)
        }
        scene.reviews.answer("a", ReviewInfo(state: .merged, number: 1, headSHA: sha("a")))
        scene.reviews.answer("b", ReviewInfo(state: .merged, number: 2, headSHA: sha("a")))
        scene.reviews.answer("c", ReviewInfo(state: .open, number: 3, headSHA: sha("a")))

        let store = await scene.startedStore()

        #expect(store.readyToRemove.map(\.id) == [mergedClean.path])
        #expect(store.row(mergedUntracked.path)?.eligibility == .blocked([.untracked(1)]))
        #expect(store.row(openClean.path)?.eligibility == .manual(needsStopping: false))
        #expect(store.row(mergedClean.path)?.review.state == .merged)
        #expect(store.row(mergedClean.path)?.hosting == .gitlab)
    }

    @Test func hostingFailureLeavesNothingReady() async throws {
        let scene = try Scene()
        scene.addRepository("/x/repo", worktrees: [linked("/x/wt-a", branch: "a"), linked("/x/wt-b", branch: "b")])
        // The real service, on a host that answers 401 to everything, as it does without a token.
        let session = Unauthorized.session()
        let detector = HostingDetector(overrides: [:], session: session)
        let service = ReviewService(detector: detector, tokens: NoTokens(), session: session)

        let store = await scene.startedStore(reviews: service, hosting: detector)

        #expect(store.rows.count == 3)
        #expect(store.rows.allSatisfy { $0.review == .unknown })
        #expect(store.readyToRemove.isEmpty)
        #expect(store.row("/x/wt-a")?.eligibility == .manual(needsStopping: false))
        #expect(await service.lastError(host: "gitlab.example.test")?.contains("401") == true)
    }

    @Test(.timeLimit(.minutes(1)))
    func samplesProcessesOnlyWhenVisible() async throws {
        let scene = try Scene()
        scene.addRepository("/x/repo")
        let store = await scene.startedStore()

        await scene.clock.advance(by: .seconds(10))
        #expect(scene.sampler.samples == 0)

        store.isWindowVisible = true
        #expect(await poll { scene.sampler.samples == 1 && scene.clock.sleepers == 1 })
        await scene.clock.advance(by: .seconds(10))
        #expect(scene.sampler.samples >= 3)

        let paused = scene.sampler.samples
        store.isWindowVisible = false
        #expect(await poll { scene.clock.sleepers == 0 })
        try await Task.sleep(for: .milliseconds(50))  // time for a loop that should not be there to sample
        await scene.clock.advance(by: .seconds(10))
        #expect(scene.sampler.samples == paused)
    }

    @Test func removeRechecksAndReportsStateChange() async throws {
        let scene = try Scene()
        let worktree = linked("/x/wt", branch: "feature")
        scene.addRepository("/x/repo", worktrees: [worktree])
        scene.reviews.answer("feature", ReviewInfo(state: .merged, number: 1, headSHA: sha("a")))
        let store = await scene.startedStore()
        let row = try #require(store.row(worktree.path))
        #expect(row.eligibility == .ready(needsStopping: false))

        scene.git.update("/x/repo") { $0.statuses[worktree.path] = WorktreeStatus(upstream: "origin/x", untracked: 1) }
        let outcomes = await store.remove([row], deleteBranches: true)

        #expect(outcomes == [.failed(worktree.path, .stateChanged(.blocked([.untracked(1)])))])
        #expect(scene.git.calls.contains(.fetch("/x/repo")))
        #expect(scene.reviews.invalidations >= 1)
    }

    @Test func removeRefreshesTheRepo() async throws {
        let scene = try Scene()
        let worktree = linked("/x/wt", branch: "feature")
        scene.addRepository("/x/repo", worktrees: [worktree])
        scene.reviews.answer("feature", ReviewInfo(state: .merged, number: 1, headSHA: sha("a")))
        scene.remover.onRemoval { [git = scene.git] request in
            git.update("/x/repo") { $0.worktrees.removeAll { $0.path == request.worktree.path } }
        }
        let store = await scene.startedStore()
        let row = try #require(store.row(worktree.path))

        let outcomes = await store.remove([row], deleteBranches: true)

        #expect(outcomes == [.removed(worktree.path)])
        #expect(store.row(worktree.path) == nil)
        #expect(store.projects.map(\.path) == ["/x/repo"])
        #expect(scene.remover.requests.first?.deleteBranch == true)
    }

    @Test func missingWorktreeCanBePruned() async throws {
        let scene = try Scene()
        let gone = linked("/x/wt-gone", branch: "gone", prunable: true)
        scene.addRepository("/x/repo", worktrees: [gone])
        scene.remover.onPrune { [git = scene.git] repo in
            git.update(repo) { $0.worktrees.removeAll(where: \.isPrunable) }
        }
        let store = await scene.startedStore()
        #expect(store.row(gone.path)?.eligibility == .missing)
        #expect(!scene.git.calls.contains(.status(gone.path)))  // a folder that is gone has no status (Ruling 20)

        let error = await store.prune(repoPath: "/x/repo")

        #expect(error == nil)
        #expect(scene.remover.pruned == ["/x/repo"])
        #expect(store.row(gone.path) == nil)
    }

    @Test func newRepoAppearsFromWatcher() async throws {
        let disk = try TempDir(named: "x")
        let root = disk.canonicalPath
        try FileManager.default.createDirectory(atPath: root + "/new/.git", withIntermediateDirectories: true)
        let scene = try Scene(scanner: FakeScanner(roots: [URL(filePath: root)]))
        scene.addRepository(root + "/old")
        let store = await scene.startedStore()
        scene.addRepository(root + "/new")

        #expect(scene.watcher.send([root + "/new/.git"], toWatchOf: root))
        await scene.settle(store)

        #expect(store.projects.map(\.path) == [root + "/new", root + "/old"])
        #expect(store.row(root + "/new")?.status == cleanAndPushed)
        #expect(scene.scanner.scans == 1)
    }

    @Test func deletedRepoDisappearsFromWatcher() async throws {
        let disk = try TempDir(named: "x")
        let root = disk.canonicalPath
        try FileManager.default.createDirectory(atPath: root + "/old/.git", withIntermediateDirectories: true)
        let scene = try Scene(scanner: FakeScanner(roots: [URL(filePath: root)]))
        scene.addRepository(root + "/old")
        scene.addRepository(root + "/kept")
        let store = await scene.startedStore()
        try FileManager.default.removeItem(atPath: root + "/old")

        #expect(scene.watcher.send([root + "/old/.git"], toWatchOf: root))
        await scene.settle(store)

        #expect(store.projects.map(\.path) == [root + "/kept"])
        #expect(scene.scanner.scans == 1)
    }
}
