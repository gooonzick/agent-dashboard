import Cleanup
import CoreModels
@testable import Dashboard
import Discovery
import Foundation
import GitKit
import Hosting
import Synchronization
import TestSupport
import Testing

/// The remote of the repositories of the tests, with a token in it, as people paste them.
let remoteWithToken = "https://deploy:glpat-SECRET@gitlab.example.test/team/app.git"

/// A worktree that was added to a repository, on `branch`, or detached without one.
func linked(_ path: String, branch: String?, head: String = sha("a"), prunable: Bool = false, lock: WorktreeLock? = nil)
    -> Worktree
{
    Worktree(
        path: path, head: head, branch: branch, isDetached: branch == nil, lock: lock, isPrunable: prunable)
}

/// What git says of a worktree whose branch tracks a remote branch that is still there, with nothing to push.
let cleanAndPushed = WorktreeStatus(upstream: "origin/x")
/// What git says of a worktree whose remote branch was deleted after the merge.
let cleanUpstreamGone = WorktreeStatus(upstream: "origin/x", upstreamGone: true)

/// Defaults of a test's own: a suite named by an absolute path keeps its file in `folder`, which goes with the test,
/// and never in the user's Preferences folder, where `cfprefsd` would leave an empty file of every suite behind.
func testDefaults(in folder: TempDir) throws -> UserDefaults {
    try #require(UserDefaults(suiteName: folder.canonicalPath + "/settings"))
}

/// The time of `env.now`, which moves when the test says.
final class FakeDate: Sendable {
    private let date = Mutex(Date(timeIntervalSince1970: 1_800_000_000))
    var now: Date { date.withLock { $0 } }
    func pass(_ seconds: TimeInterval) { date.withLock { $0 += seconds } }
}

/// Everything a store is made of, as fakes, and the store.
@MainActor
final class Scene {
    let git: FakeGit
    let scanner: FakeScanner
    let reviews: FakeReviews
    let hosting: FakeHosting
    let sizes = FakeSizes()
    let sampler = FakeSampler()
    let signaler: FakeSignaler
    let remover = FakeRemover()
    let watcher = FakeWatcher()
    let docker = FakeDockerControl()
    let caches = FakeCaches()
    let buildOutputs = FakeBuildOutputs()
    let clock = FakeClock()
    let folder: TempDir
    let settings: SettingsStore
    let cache: DashboardCache
    private let date = FakeDate()
    /// The memory that `env.systemMemory` says is in use: a fixed value, so that no test reads the Mac it runs on.
    var systemMemory: UInt64? = 4 << 30

    init(
        scanner: FakeScanner = FakeScanner(), git: FakeGit = FakeGit(), reviews: FakeReviews = FakeReviews(),
        hosting: FakeHosting = FakeHosting(), signaler: FakeSignaler = FakeSignaler(), onboarded: Bool = true
    ) throws {
        self.scanner = scanner
        self.git = git
        self.reviews = reviews
        self.hosting = hosting
        self.signaler = signaler
        // A process that ends leaves the samples, as it does on the Mac.
        signaler.onExit { [sampler] in sampler.remove($0) }
        folder = try TempDir(named: "Dashboard")
        cache = DashboardCache(url: folder.url.appending(path: "cache.json"))
        settings = SettingsStore(defaults: try testDefaults(in: folder))
        // The first run is the one test that says so: everything else is a store that is allowed to start.
        settings.didOnboard = onboarded
    }

    /// The time that `env.now` says.
    var now: Date { date.now }
    func passTime(_ seconds: TimeInterval) { date.pass(seconds) }

    func environment(reviews: (any ReviewLooking)? = nil, hosting: (any HostingDetecting)? = nil)
        -> DashboardEnvironment
    {
        let clock = self.clock
        let systemMemory = self.systemMemory
        var env = DashboardEnvironment(
            scanner: scanner, git: git, reviews: reviews ?? self.reviews, hosting: hosting ?? self.hosting,
            sizes: sizes, sampler: sampler, signaler: signaler, remover: remover, watcher: watcher, docker: docker,
            caches: caches, buildOutputs: buildOutputs, cache: cache, settings: settings, now: { [date] in date.now },
            sleep: { try await clock.sleep(for: $0) })
        env.stopTimeout = .milliseconds(100)
        env.systemMemory = { systemMemory }
        return env
    }

    func makeStore(reviews: (any ReviewLooking)? = nil, hosting: (any HostingDetecting)? = nil) -> DashboardStore {
        DashboardStore(env: environment(reviews: reviews, hosting: hosting))
    }

    /// Makes git know the repository at `path` with its main worktree on `main` and `worktrees`. Every worktree is
    /// clean and pushed, and the remote is on GitLab, unless the test says otherwise. The scan finds it.
    func addRepository(_ path: String, worktrees: [Worktree] = [], remote: String = remoteWithToken) {
        let main = Worktree(path: path, head: sha("0"), branch: "main", isMain: true)
        var repo = FakeGit.Repo(worktrees: [main] + worktrees, remotes: [Remote(name: "origin", url: remote)])
        for worktree in [main] + worktrees where !worktree.isPrunable { repo.statuses[worktree.path] = cleanAndPushed }
        git.set(path, repo)
        let found = Set(scanner.found).union([path])
        scanner.willFind(found.sorted())
    }

    /// A store that has started and is done with everything it started.
    func startedStore(reviews: (any ReviewLooking)? = nil, hosting: (any HostingDetecting)? = nil) async
        -> DashboardStore
    {
        let store = makeStore(reviews: reviews, hosting: hosting)
        await store.start()
        await settle(store)
        return store
    }

    func settle(_ store: DashboardStore) async {
        let idle = await poll { store.isIdle }
        #expect(idle, "the store did not finish its work in the background")
    }
}

extension DashboardStore {
    /// Every row, main ones included.
    var rows: [WorktreeRow] { projects.flatMap { [$0.main] + $0.worktrees } }

    func row(_ path: String) -> WorktreeRow? { rows.first { $0.id == path } }
}
