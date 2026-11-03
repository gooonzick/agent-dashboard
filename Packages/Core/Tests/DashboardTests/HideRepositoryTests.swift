import CoreModels
@testable import Dashboard
import Discovery
import Foundation
import Synchronization
import Testing

/// Hide Repository (Ruling 59): the repository goes from the window and stays gone.
@MainActor
@Suite struct HideRepositoryTests {
    @Test func aHiddenRepositoryLeavesTheRowsTheWatchAndTheCache() async throws {
        let scene = try Scene(scanner: FakeScanner(roots: [URL(filePath: "/x")]))
        scene.addRepository("/x/kept")
        scene.addRepository("/x/hidden", worktrees: [linked("/x/hidden-wt", branch: "b")])
        let store = await scene.startedStore()
        #expect(store.projects.map(\.path) == ["/x/hidden", "/x/kept"])

        store.hide(repoPath: "/x/hidden")
        await scene.settle(store)

        #expect(store.projects.map(\.path) == ["/x/kept"])
        #expect(scene.settings.hiddenRepos == ["/x/hidden"])
        #expect(!scene.watcher.live.contains { $0.paths.contains("/x/hidden") || $0.paths.contains("/x/hidden-wt") })
        #expect(scene.cache.load().repositories == ["/x/kept"])
        #expect(scene.cache.load().sizes["/x/hidden-wt"] == nil)
    }

    @Test func aLaterScanDoesNotBringItBack() async throws {
        let scene = try Scene()
        scene.addRepository("/x/kept")
        scene.addRepository("/x/hidden")
        let store = await scene.startedStore()

        store.hide(repoPath: "/x/hidden")
        await store.start()
        await scene.settle(store)

        #expect(scene.scanner.found.contains("/x/hidden"))  // the scan still finds it
        #expect(store.projects.map(\.path) == ["/x/kept"])
        // Nor does a new run of the app, which starts from the cache.
        let next = await scene.startedStore()
        #expect(next.projects.map(\.path) == ["/x/kept"])
    }

    @Test func aScanThatWasUnderWayWhenItWasHiddenDoesNotBringItBack() async throws {
        let scene = try Scene()
        scene.addRepository("/x/kept")
        scene.addRepository("/x/hidden")
        _ = await scene.startedStore()  // fills the cache with both
        let gate = Gate()
        var env = scene.environment()
        env.scanner = GatedScanner(found: scene.scanner.found, gate: gate)
        let store = DashboardStore(env: env)
        let started = Task { await store.start() }
        #expect(await poll { store.projects.count == 2 && store.scanState != .idle })

        store.hide(repoPath: "/x/hidden")
        gate.open()
        await started.value
        await scene.settle(store)

        #expect(store.projects.map(\.path) == ["/x/kept"])
    }
}

/// A scan that finds `found` once the test opens the gate.
private final class GatedScanner: RepoScanning {
    private let found: [URL]
    private let gate: Gate

    init(found: [String], gate: Gate) {
        self.found = found.map { URL(filePath: $0, directoryHint: .isDirectory) }
        self.gate = gate
    }

    func scan(roots: [URL], rules: ExclusionRules, isCancelled: @Sendable () -> Bool) async -> [URL] {
        await gate.wait()
        return found
    }

    func defaultRoots(rules: ExclusionRules) -> [URL] { [URL(filePath: "/")] }
}
