import Cleanup
import CoreModels
import Discovery
import DiskUsage
import Foundation
import GitKit
import Hosting
import ProcessKit
import Shell

/// Everything that the store reads, runs and writes through: the disk, git, the hosting services, the processes,
/// Docker, the caches and the clock. Tests put fakes in it.
public struct DashboardEnvironment: Sendable {
    public var scanner: any RepoScanning
    public var git: any GitReading
    public var reviews: any ReviewLooking
    /// What each host runs. It is the detector that `reviews` asks too, so that a host is probed once.
    public var hosting: any HostingDetecting
    public var sizes: any SizeMeasuring
    public var sampler: any ProcessSampling
    public var signaler: any ProcessSignaling
    public var remover: any WorktreeRemoving
    public var watcher: any FileWatching
    /// The Docker VM of the current docker context, for the Caches and Docker page.
    public var docker: any DockerControlling
    /// The package manager and Xcode caches, for the same page.
    public var caches: any CacheCataloging
    /// The build outputs inside the worktrees, for the same page.
    public var buildOutputs: any BuildOutputFinding
    public var cache: DashboardCache
    public var settings: SettingsStore
    public var now: @Sendable () -> Date
    /// How the store waits between two samples of the processes.
    public var sleep: @Sendable (Duration) async throws -> Void
    /// How long a process that was told to stop gets before it is killed (`ProcessStopper`). Tests make it short.
    public var stopTimeout: Duration = .seconds(5)
    /// The bytes of memory in use on the Mac, read with each sample of the processes. `nil` if it cannot be read.
    public var systemMemory: @Sendable () -> UInt64? = SystemMemory.inUse

    public init(
        scanner: any RepoScanning, git: any GitReading, reviews: any ReviewLooking, hosting: any HostingDetecting,
        sizes: any SizeMeasuring, sampler: any ProcessSampling, signaler: any ProcessSignaling,
        remover: any WorktreeRemoving, watcher: any FileWatching, docker: any DockerControlling,
        caches: any CacheCataloging, buildOutputs: any BuildOutputFinding, cache: DashboardCache,
        settings: SettingsStore, now: @escaping @Sendable () -> Date = { Date() },
        sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
    ) {
        self.scanner = scanner
        self.git = git
        self.reviews = reviews
        self.hosting = hosting
        self.sizes = sizes
        self.sampler = sampler
        self.signaler = signaler
        self.remover = remover
        self.watcher = watcher
        self.docker = docker
        self.caches = caches
        self.buildOutputs = buildOutputs
        self.cache = cache
        self.settings = settings
        self.now = now
        self.sleep = sleep
    }

    /// The environment of the app: the real disk, `git`, Keychain tokens, GitHub and GitLab, the user's processes, and
    /// the user's Docker and caches.
    ///
    /// The hosting services are asked through a session of their own, ephemeral and stripped of credential storage,
    /// cookies and cache, so that no request carries anything but what the clients put in it.
    public static func live(settings: SettingsStore, tokens: any TokenStoring = KeychainTokenStore()) -> Self {
        let runner = CommandRunner()
        let session = bareSession()
        let detector = HostingDetector(overrides: settings.hostingOverrides, session: session)
        let sampler = ProcessSampler()
        let signaler = ProcessSignaler()
        let home = FileManager.default.homeDirectoryForCurrentUser
        return DashboardEnvironment(
            scanner: RepoScanner(), git: GitReader(runner: runner),
            reviews: ReviewService(detector: detector, tokens: tokens, session: session), hosting: detector,
            sizes: PrivateSizeScanner(), sampler: sampler, signaler: signaler,
            remover: WorktreeRemover(runner: runner, signaler: signaler, sampler: sampler), watcher: FileWatcher(),
            docker: DockerController(runner: runner, home: home), caches: CacheCatalog(runner: runner, home: home),
            buildOutputs: BuildOutputFinder(runner: runner), cache: .standard, settings: settings)
    }

    /// An ephemeral session with nothing of its own to add to a request.
    static func bareSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCredentialStorage = nil
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        return URLSession(configuration: configuration)
    }
}
