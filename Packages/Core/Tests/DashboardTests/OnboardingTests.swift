import CoreModels
@testable import Dashboard
import Foundation
import Hosting
import TestSupport
import Testing

/// The first run (Ruling 64, in place of the manual check): nothing is read, sampled or asked before `Start scan`.
@MainActor
@Suite struct OnboardingTests {
    private func firstRun() throws -> (Scene, DashboardStore) {
        let scene = try Scene(onboarded: false)
        scene.addRepository("/x/repo", worktrees: [linked("/x/wt", branch: "feature")])
        try scene.cache.save(DashboardCache.Contents(repositories: ["/x/repo"]))
        return (scene, scene.makeStore())
    }

    @Test func aNewStoreWantsOnboardingAndAnOnboardedOneDoesNot() throws {
        let (_, fresh) = try firstRun()
        #expect(!fresh.didOnboard)

        let scene = try Scene()
        #expect(scene.makeStore().didOnboard)
    }

    @Test func nothingStartsBeforeStartScan() async throws {
        let (scene, store) = try firstRun()

        await store.start()
        await store.refresh()
        await store.fetchAll()
        await store.refreshReviews(host: "gitlab.example.test")
        store.isWindowVisible = true
        await scene.clock.advance(by: .seconds(10))

        #expect(scene.scanner.scans == 0)
        #expect(scene.git.calls.isEmpty)
        #expect(scene.reviews.lookups.isEmpty)
        #expect(scene.reviews.invalidations == 0)
        #expect(scene.hosting.hostsAsked.isEmpty)
        #expect(scene.sampler.samples == 0)
        #expect(scene.clock.sleepers == 0)
        #expect(scene.watcher.all.isEmpty)
        #expect(store.projects.isEmpty)  // not even what the cache holds
        #expect(!scene.settings.didOnboard)
    }

    @Test func startScanRecordsItAndThenScans() async throws {
        let (scene, store) = try firstRun()
        store.isWindowVisible = true

        await store.completeOnboarding()
        await scene.settle(store)

        #expect(store.didOnboard)
        #expect(scene.settings.didOnboard)
        #expect(scene.scanner.scans == 1)
        #expect(store.projects.map(\.path) == ["/x/repo"])
        #expect(!scene.reviews.lookups.isEmpty)
        // The window was on the screen already, so the processes are sampled now.
        #expect(await poll { scene.sampler.samples >= 1 })
    }

    @Test func startScanTwiceScansOnce() async throws {
        let (scene, store) = try firstRun()

        async let first: Void = store.completeOnboarding()
        async let second: Void = store.completeOnboarding()
        _ = await (first, second)
        await scene.settle(store)

        #expect(scene.scanner.scans == 1)
    }

    @Test func anOnboardedStoreStartsAsItDid() async throws {
        let scene = try Scene()
        scene.addRepository("/x/repo")

        let store = await scene.startedStore()

        #expect(scene.scanner.scans == 1)
        #expect(store.projects.map(\.path) == ["/x/repo"])
    }
}
