import Cleanup
import CoreModels
@testable import Dashboard
import Foundation
import Observation
import TestSupport
import Testing

/// A colima VM whose disk is at `/vm/disk`, running or not.
func colima(running: Bool, disk: String = "/vm/disk") -> DockerStatus {
    .runtime(
        DockerRuntime(
            kind: .colima, context: "colima", profile: "default", isRunning: running, diskPath: disk,
            diskLimit: 100 << 30, cpus: 4, memory: 8 << 30))
}

let someInventory = DockerInventory(
    images: [
        DockerImage(id: "aaa", name: "postgres:16", size: 400_000_000, isUnused: false),
        DockerImage(id: "bbb", name: "node:20", size: 1_100_000_000, isUnused: true),
    ],
    containers: [
        DockerContainer(id: "c1", name: "db", image: "postgres:16", isRunning: true, size: 1_000, project: "/x/repo"),
        DockerContainer(id: "c2", name: "old", image: "node:20", isRunning: false, size: 2_000, project: nil),
    ],
    volumesSize: 7_900_000_000, buildCacheSize: 6_000_000_000)

let homebrew = CacheEntry(
    id: "homebrew", group: .packages, title: "Homebrew", paths: ["/c/homebrew"], note: nil, action: "Clean",
    clean: .command(tool: "brew", args: ["cleanup", "--prune=all", "-s"]))
let goCaches = CacheEntry(
    id: "go", group: .packages, title: "Go modules and build cache", paths: ["/c/go/mod", "/c/go/build"], note: nil,
    action: "Clean", clean: .command(tool: "go", args: ["clean", "-modcache", "-cache"]))

/// A build output of the worktree at `worktree`.
func output(_ relative: String, in worktree: String) -> BuildOutput {
    BuildOutput(
        path: worktree + "/" + relative, worktree: worktree,
        title: (worktree as NSString).lastPathComponent + "/" + relative, kind: "Rust build")
}

/// The store's side of the Caches and Docker page: what it lists, when it measures, and what cleaning does.
@MainActor
@Suite(.timeLimit(.minutes(1))) struct CleanupStoreTests {
    /// A repository with one linked worktree that has a build output, Homebrew and Go, and a colima VM that is stopped.
    private func machine() throws -> Scene {
        let scene = try Scene()
        scene.addRepository("/x/repo", worktrees: [linked("/x/wt", branch: "b")])
        scene.docker.willAnswer([colima(running: false)])
        scene.caches.set([homebrew, goCaches])
        scene.buildOutputs.set([output("target", in: "/x/wt")])
        return scene
    }

    /// What the scene measured after `count` measures, which were the worktrees'.
    private func measured(_ scene: Scene, after count: Int) -> [String] {
        Array(scene.sizes.measuredPaths.dropFirst(count))
    }

    @Test func sizesArriveOneByOne() async throws {
        let scene = try machine()
        scene.sizes.set("/c/go/mod", SizeInfo(apparentBytes: 9, privateBytes: 3_000, computedAt: .distantPast))
        scene.sizes.set("/c/go/build", SizeInfo(apparentBytes: 9, privateBytes: 500, computedAt: .distantPast))
        let store = await scene.startedStore()
        let before = scene.sizes.measured.count
        scene.sizes.hold("/vm/disk")
        defer { scene.sizes.release("/vm/disk") }

        await store.loadCleanup()

        #expect(store.cleanup.docker == colima(running: false))
        #expect(store.cleanup.caches == [homebrew, goCaches])
        #expect(store.cleanup.buildOutputs == [output("target", in: "/x/wt")])
        #expect(store.cleanup.loadedAt == scene.now)
        #expect(await poll { measured(scene, after: before) == ["/vm/disk"] })
        #expect(store.cleanup.sizes.isEmpty)
        #expect(!store.isIdle)

        scene.sizes.release("/vm/disk")
        await scene.settle(store)

        #expect(
            measured(scene, after: before) == ["/vm/disk", "/c/homebrew", "/c/go/mod", "/c/go/build", "/x/wt/target"])
        #expect(
            store.cleanup.sizes == [
                CleanupState.dockerDiskKey: 100_000_000, "homebrew": 100_000_000, "go": 3_500,
                "/x/wt/target": 100_000_000,
            ])
    }

    @Test func sizesStandSixHours() async throws {
        let scene = try machine()
        let store = await scene.startedStore()
        await store.loadCleanup()
        await scene.settle(store)
        let first = scene.sizes.measured.count

        scene.passTime(60 * 60)
        await store.loadCleanup()
        await scene.settle(store)
        #expect(measured(scene, after: first).isEmpty)
        #expect(store.cleanup.sizes.count == 4)

        scene.passTime(6 * 60 * 60)
        await store.loadCleanup()
        await scene.settle(store)
        let second = scene.sizes.measured.count
        #expect(second - first == 5)

        await store.loadCleanup(force: true)
        await scene.settle(store)
        #expect(scene.sizes.measured.count - second == 5)
    }

    @Test func theSizesOutliveARestartAndAnOldCacheStillLoads() async throws {
        let scene = try machine()
        let store = await scene.startedStore()
        await store.loadCleanup()
        await scene.settle(store)
        let before = scene.sizes.measured.count

        let next = await scene.startedStore()
        await next.loadCleanup()
        await scene.settle(next)

        #expect(next.cleanup.sizes == store.cleanup.sizes)
        // The rows of the page were measured a moment ago, so none is measured again. (The worktrees may be: the fake
        // sizes carry a time long past, which the cache keeps for them.)
        #expect(measured(scene, after: before).allSatisfy { ["/x/repo", "/x/wt"].contains($0) })

        // A file of the first builds, which knew nothing of these sizes.
        let text = """
            {"contents":{"repositories":["/x/repo"],"sizes":{}},"version":1}
            """
        try Data(text.utf8).write(to: scene.cache.url, options: .atomic)
        let loaded = scene.cache.load()
        #expect(loaded.repositories == ["/x/repo"])
        #expect(loaded.cleanupSizes.isEmpty)
    }

    @Test func cleaningRemeasuresThatRowOnly() async throws {
        let scene = try machine()
        let store = await scene.startedStore()
        await store.loadCleanup()
        await scene.settle(store)
        let before = scene.sizes.measured.count

        #expect(await store.clean(cache: homebrew) == nil)
        await scene.settle(store)

        #expect(scene.caches.cleaned == ["homebrew"])
        #expect(measured(scene, after: before) == ["/c/homebrew"])
        #expect(!scene.caches.cleanedOnMain)
    }

    @Test func aCleanedBuildOutputLeavesAndItsWorktreeIsMeasuredAgain() async throws {
        let scene = try machine()
        let store = await scene.startedStore()
        await store.loadCleanup()
        await scene.settle(store)
        let before = scene.sizes.measured.count

        #expect(await store.clean(output: output("target", in: "/x/wt")) == nil)
        await scene.settle(store)

        #expect(scene.buildOutputs.deleted == ["/x/wt/target"])
        #expect(store.cleanup.buildOutputs.isEmpty)
        #expect(store.cleanup.sizes["/x/wt/target"] == nil)
        #expect(measured(scene, after: before) == ["/x/wt"])
        #expect(!scene.buildOutputs.deletedOnMain)
        #expect(scene.cache.load().cleanupSizes["/x/wt/target"] == nil)
    }

    @Test func aRowThatIsCleaningIsWorkingUntilItIsDone() async throws {
        let scene = try machine()
        let store = await scene.startedStore()
        await store.loadCleanup()
        let gate = Gate()
        scene.caches.hold(at: gate)

        let cleaning = Task { await store.clean(cache: homebrew) }
        #expect(await poll { store.cleanup.working == ["homebrew"] })
        // A second click while the first one runs cleans nothing more.
        #expect(await store.clean(cache: homebrew) == nil)
        #expect(scene.caches.cleaned == ["homebrew"])

        gate.open()
        #expect(await cleaning.value == nil)
        #expect(store.cleanup.working.isEmpty)
    }

    @Test func aFailedCleanReturnsTheMessageAndKeepsTheRow() async throws {
        let scene = try machine()
        let store = await scene.startedStore()
        await store.loadCleanup()
        await scene.settle(store)
        scene.caches.fail("homebrew", with: CleanupError.failed("Error: Another active Homebrew process is running"))
        scene.buildOutputs.fail("/x/wt/target", with: CleanupError.notEligible("holds a git repository: target/sub"))

        let cache = await store.clean(cache: homebrew)
        let build = await store.clean(output: output("target", in: "/x/wt"))

        #expect(cache == "Error: Another active Homebrew process is running")
        #expect(build == "Holds a git repository: target/sub.")
        #expect(store.cleanup.caches.contains(homebrew))
        #expect(store.cleanup.buildOutputs == [output("target", in: "/x/wt")])
        #expect(store.cleanup.working.isEmpty)
    }

    @Test func aBuildOutputThatIsAlreadyGoneCountsAsCleaned() async throws {
        let scene = try Scene()
        let root = scene.folder.canonicalPath
        let gone = output("target", in: root + "/wt")
        let present = output("dist", in: root + "/wt")
        try FileManager.default.createDirectory(atPath: present.path, withIntermediateDirectories: true)
        scene.addRepository(root + "/wt")
        scene.buildOutputs.set([gone, present])
        let store = await scene.startedStore()
        await store.loadCleanup()
        scene.buildOutputs.fail(gone.path, with: CleanupError.pathEscapes(gone.path))
        scene.buildOutputs.fail(present.path, with: CleanupError.pathEscapes(present.path))

        #expect(await store.clean(output: gone) == nil)
        #expect(store.cleanup.buildOutputs == [present])

        // One that is still there and escapes is refused, and says so.
        let message = await store.clean(output: present)
        #expect(message?.contains("leads outside") == true)
        #expect(store.cleanup.buildOutputs == [present])
    }

    @Test func startDockerReloadsTheStatusAndInventory() async throws {
        let scene = try machine()
        let store = await scene.startedStore()
        await store.loadCleanup()
        await scene.settle(store)
        #expect(store.cleanup.inventory == nil)
        let before = scene.sizes.measured.count
        // colima is still coming up at the first look, and running at the second.
        scene.docker.willAnswer([colima(running: false), colima(running: true)])
        scene.docker.willHold(someInventory)

        let starting = Task { await store.startDocker() }
        #expect(await poll { scene.clock.sleepers == 1 })
        #expect(store.cleanup.working == [CleanupState.startDockerID])
        await scene.clock.advance(by: .seconds(2))

        #expect(await starting.value == nil)
        await scene.settle(store)
        #expect(scene.docker.count(.start) == 1)
        #expect(store.cleanup.docker == colima(running: true))
        #expect(store.cleanup.inventory == someInventory)
        #expect(store.cleanup.working.isEmpty)
        #expect(measured(scene, after: before) == ["/vm/disk"])
    }

    @Test func aRunningVMIsInspectedOnLoad() async throws {
        let scene = try machine()
        scene.docker.willAnswer([colima(running: true)])
        scene.docker.willHold(someInventory)
        let store = await scene.startedStore()

        await store.loadCleanup()

        #expect(store.cleanup.inventory == someInventory)
    }

    @Test func dockerThatNeverComesUpIsGivenUpOnAfterTwoMinutes() async throws {
        let scene = try machine()
        let store = await scene.startedStore()
        await store.loadCleanup()

        let starting = Task { await store.startDocker() }
        #expect(await poll { scene.clock.sleepers == 1 })
        await scene.clock.advance(by: .seconds(120))

        #expect(await starting.value == "Docker did not start in 2 minutes")
        #expect(scene.docker.count(.inventory) == 0)
        #expect(store.cleanup.working.isEmpty)
    }

    @Test func aFailedStartSaysWhatTheRuntimeSaid() async throws {
        let scene = try machine()
        let store = await scene.startedStore()
        await store.loadCleanup()
        scene.docker.failStart(DockerError(message: "FATA[0003] error starting vm: disk is locked"))

        #expect(await store.startDocker() == "FATA[0003] error starting vm: disk is locked")
        #expect(store.cleanup.working.isEmpty)
    }

    @Test func startingWithoutARuntimeSaysWhy() async throws {
        let scene = try machine()
        scene.docker.willAnswer([.notAnswering])
        let store = await scene.startedStore()
        await store.loadCleanup()

        #expect(await store.startDocker() == "Docker did not answer")
        #expect(scene.docker.count(.start) == 0)
    }

    @Test func removingFromDockerReadsItAgain() async throws {
        let scene = try machine()
        scene.docker.willAnswer([colima(running: true)])
        scene.docker.willHold(someInventory)
        let store = await scene.startedStore()
        await store.loadCleanup()
        await scene.settle(store)
        let before = scene.sizes.measured.count
        let pruned = DockerInventory(
            images: [someInventory.images[0]], containers: [someInventory.containers[0]], volumesSize: 0,
            buildCacheSize: 0)
        scene.docker.willHold(pruned)

        #expect(await store.removeUnusedImages() == nil)
        #expect(store.cleanup.inventory == pruned)
        await scene.settle(store)
        #expect(await store.removeStoppedContainers() == nil)
        await scene.settle(store)

        #expect(scene.docker.count(.removeImages) == 1)
        #expect(scene.docker.count(.removeContainers) == 1)
        #expect(measured(scene, after: before) == ["/vm/disk", "/vm/disk"])

        let busy = "Error response from daemon: a prune operation is already running"
        scene.docker.failPrunes(DockerError(message: busy))
        #expect(await store.removeUnusedImages() == busy)
        #expect(store.cleanup.working.isEmpty)
    }

    @Test func buildOutputsComeFromTheStoresWorktrees() async throws {
        let scene = try Scene()
        scene.addRepository(
            "/x/repo", worktrees: [linked("/x/wt", branch: "b"), linked("/x/gone", branch: "g", prunable: true)])
        scene.addRepository("/y/other")
        let store = await scene.startedStore()

        await store.loadCleanup()

        #expect(scene.buildOutputs.asked == [["/x/repo", "/x/wt", "/y/other"]])
    }

    @Test func pnpmNoteCountsRepositoriesWithAPnpmLock() async throws {
        let scene = try Scene()
        let root = scene.folder.canonicalPath
        for name in ["a", "b", "c", "c-wt"] {
            try FileManager.default.createDirectory(atPath: root + "/" + name, withIntermediateDirectories: true)
        }
        try Data().write(to: URL(filePath: root + "/a/pnpm-lock.yaml"))
        // A lock in a linked worktree only, or deeper than the root, is not the repository's.
        try Data().write(to: URL(filePath: root + "/c-wt/pnpm-lock.yaml"))
        try FileManager.default.createDirectory(atPath: root + "/b/web", withIntermediateDirectories: true)
        try Data().write(to: URL(filePath: root + "/b/web/pnpm-lock.yaml"))
        scene.addRepository(root + "/a")
        scene.addRepository(root + "/b")
        scene.addRepository(root + "/c", worktrees: [linked(root + "/c-wt", branch: "w")])
        let store = await scene.startedStore()

        await store.loadCleanup()

        #expect(scene.caches.projectsUsingPnpm == [1])
    }

    @Test func nothingIsLoadedBeforeOnboarding() async throws {
        let scene = try Scene(onboarded: false)
        let store = scene.makeStore()

        await store.loadCleanup()

        #expect(scene.docker.calls.isEmpty)
        #expect(store.cleanup == CleanupState())
    }

    @Test func theCleanupStateIsNotTouchedByTheProcessPoll() async throws {
        let scene = try machine()
        let store = await scene.startedStore()
        await store.loadCleanup()
        await scene.settle(store)
        let state = store.cleanup
        let changes = Counter()
        withObservationTracking { _ = store.cleanup } onChange: { changes.increment() }

        scene.sampler.set([process(10, name: "vite", cwd: "/x/wt")])
        await store.refresh()
        await scene.settle(store)

        #expect(store.groups["/x/wt"]?.count == 1)
        #expect(changes.count == 0)
        #expect(store.cleanup == state)
    }
}
