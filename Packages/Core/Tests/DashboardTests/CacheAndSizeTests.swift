import CoreModels
@testable import Dashboard
import Foundation
import TestSupport
import Testing

@MainActor
@Suite struct CacheAndSizeTests {
    @Test func theCacheFileHoldsNoRemote() async throws {
        let scene = try Scene()
        scene.addRepository("/x/repo", worktrees: [linked("/x/wt", branch: "feature")])
        _ = await scene.startedStore()

        let text = try String(contentsOf: scene.cache.url, encoding: .utf8)

        #expect(scene.cache.load().repositories == ["/x/repo"])
        #expect(Set(scene.cache.load().sizes.keys) == ["/x/repo", "/x/wt"])
        for secret in ["SECRET", "deploy", "gitlab.example.test", "team/app", "https://", "feature"] {
            #expect(!text.contains(secret), "the cache holds \(secret)")
        }
    }

    @Test func showsCachedSizesUntilTheyAreMeasuredAgain() async throws {
        let scene = try Scene(scanner: FakeScanner(hangs: true))
        let cached = SizeInfo(apparentBytes: 7, privateBytes: 3, computedAt: .distantPast)
        try scene.cache.save(DashboardCache.Contents(repositories: ["/x/repo"], sizes: ["/x/repo": cached]))
        scene.addRepository("/x/repo")
        let store = scene.makeStore()

        let start = Task { await store.start() }
        #expect(await poll { store.row("/x/repo")?.size == cached })
        start.cancel()
        await start.value
    }

    @Test func theRepositoryIsMeasuredWithoutTheWorktreesInsideIt() async throws {
        let scene = try Scene()
        let nested = linked("/x/repo/.claude/worktrees/agent", branch: "agent")
        let beside = linked("/x/repo-wt", branch: "beside")
        scene.addRepository("/x/repo", worktrees: [nested, beside])
        let measured = SizeInfo(apparentBytes: 2_000, privateBytes: 500, computedAt: .distantPast)
        scene.sizes.set(beside.path, measured)

        let store = await scene.startedStore()

        let byPath = Dictionary(uniqueKeysWithValues: scene.sizes.measured.map { ($0.path, $0.excluding) })
        #expect(byPath == ["/x/repo": [nested.path], nested.path: [], beside.path: []])
        #expect(store.row(beside.path)?.size == measured)
    }

    @Test func aSizeMeasuredAMomentAgoIsNotMeasuredAgainOnStart() async throws {
        let scene = try Scene()
        let fresh = SizeInfo(apparentBytes: 7, privateBytes: 3, computedAt: scene.now.addingTimeInterval(-5))
        try scene.cache.save(DashboardCache.Contents(repositories: ["/x/repo"], sizes: ["/x/repo": fresh]))
        scene.addRepository("/x/repo")

        let store = await scene.startedStore()

        #expect(scene.sizes.measured.isEmpty)
        #expect(store.row("/x/repo")?.size == fresh)
    }
}

@MainActor
@Suite struct LimitsTests {
    @Test func atMostFourGitCommandsRunAtOnce() async throws {
        let scene = try Scene(git: FakeGit(callTime: .milliseconds(10)))
        for n in 0..<12 { scene.addRepository("/x/repo\(n)", worktrees: [linked("/x/wt\(n)", branch: "b\(n)")]) }

        _ = await scene.startedStore()

        #expect(scene.git.maxRunning == 4)
    }

    @Test func atMostFourRequestsGoToTheHostsAtOnce() async throws {
        let scene = try Scene(reviews: FakeReviews(lookupTime: .milliseconds(20)))
        let worktrees = (0..<10).map { linked("/x/wt\($0)", branch: "b\($0)") }
        scene.addRepository("/x/repo", worktrees: worktrees)

        _ = await scene.startedStore()

        #expect(scene.reviews.lookups.count == 11)
        #expect(scene.reviews.maxRunning == 4)
    }

    @Test func theLimitsHoldForOperationsThatRunTogether() async throws {
        let scene = try Scene(
            git: FakeGit(callTime: .milliseconds(10)), reviews: FakeReviews(lookupTime: .milliseconds(20)))
        for n in 0..<12 { scene.addRepository("/x/repo\(n)", worktrees: [linked("/x/wt\(n)", branch: "b\(n)")]) }
        let store = await scene.startedStore()

        // Each of them alone keeps to four; side by side, only the limits that they share keep them there.
        async let first: Void = store.fetchAll()
        async let second: Void = store.fetchAll()
        _ = await (first, second)

        #expect(scene.git.maxRunning == 4)
        #expect(scene.reviews.maxRunning == 4)
    }

    @Test func eachHostIsAskedWhatItRunsOncePerRefresh() async throws {
        let scene = try Scene()
        scene.addRepository("/x/a", worktrees: [linked("/x/a-wt", branch: "a")])
        scene.addRepository("/x/b", worktrees: [linked("/x/b-wt", branch: "b")])
        scene.addRepository("/x/c", remote: "git@github.com:me/c.git")
        scene.addRepository("/x/local", remote: "/srv/git/local.git")  // no hosting service

        let store = await scene.startedStore()
        #expect(scene.hosting.hostsAsked.sorted() == ["github.com", "gitlab.example.test"])
        #expect(store.row("/x/local")?.hosting == nil)
        #expect(store.row("/x/local")?.review == .unknown)

        await store.fetchAll()
        #expect(scene.hosting.hostsAsked.count == 4)
        #expect(scene.git.count { if case .fetch = $0 { true } else { false } } == 4)
        #expect(scene.reviews.invalidations == 1)
        #expect(store.lastUpdated == scene.now)
    }

    @Test func aHostThatRunsNeitherIsNotAskedForRequests() async throws {
        let scene = try Scene(hosting: FakeHosting(["gitlab.example.test": .unsupported]))
        scene.addRepository("/x/repo", worktrees: [linked("/x/wt", branch: "b")])

        let store = await scene.startedStore()

        #expect(scene.reviews.lookups.isEmpty)
        #expect(store.row("/x/wt")?.hosting == .unsupported)
    }
}
