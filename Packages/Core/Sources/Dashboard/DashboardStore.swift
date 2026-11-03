import CoreModels
import Discovery
import Foundation
import GitKit
import Hosting
import Observation
import ProcessKit
import Safety

/// What the store knows of one repository.
struct Repository {
    let path: String
    var name: String { (path as NSString).lastPathComponent }
    /// As git lists them, the main one first. Empty until git has listed them.
    var worktrees: [Worktree] = []
    var remote: RemoteURL?
    /// What the host of `remote` runs, as it was found out in the last lookup of requests.
    var kind: HostingKind?
    /// By worktree path.
    var facts: [String: GitFacts] = [:]
    /// By worktree path.
    var reviews: [String: KnownReview] = [:]
    /// The linked worktree of each folder in `.git/worktrees`, by the folder's name.
    var adminNames: [String: String] = [:]
    /// Which read the list of worktrees, and the facts of each worktree, come from: an older read that arrives later
    /// is not taken.
    var listTicket = 0
    var factTickets: [String: Int] = [:]

    init(path: String) {
        self.path = path
    }

    /// The worktrees that have a folder.
    var presentWorktrees: [Worktree] { worktrees.filter { !$0.isPrunable } }
}

/// The repositories and worktrees of the Mac, with their status, their merge or pull requests, their size and what runs
/// in them, kept up to date for the window.
///
/// Everything is read through `DashboardEnvironment`. The store's state lives on the main actor; the work does not:
/// git and the hosting services are asked from tasks that are not the main actor's, at most four git commands and four
/// requests at a time; the scan of the disk runs at utility priority and the sizes are measured one at a time at
/// background priority, and nothing that the main actor waits for lends them its priority.
@MainActor @Observable public final class DashboardStore {
    public private(set) var projects: [ProjectRow] = []
    public private(set) var scanState: ScanState = .idle
    public private(set) var lastUpdated: Date?
    /// Whether `start()` is running, from the first line of it to the last: a second `start()` in that time does
    /// nothing, so the window waits for this to be `false` before it offers one.
    public private(set) var isStarting = false
    /// Whether the user has been through the first-run window. Until then the store reads nothing, samples nothing and
    /// asks no host: `start()`, `refresh()`, `fetchAll()` and `refreshReviews(host:)` do nothing, and the processes are
    /// not sampled. `completeOnboarding()` ends it.
    public private(set) var didOnboard: Bool

    /// Whether the window is on the screen. The processes are sampled every 3 seconds while it is, and not at all while
    /// it is not.
    public var isWindowVisible = false {
        didSet { if isWindowVisible != oldValue { visibilityChanged() } }
    }

    /// What the user has set: the window reads and writes "Don't ask again for merged, pushed worktrees" here.
    public var settings: SettingsStore { env.settings }

    /// The worktrees whose request is merged and that hold nothing unsaved: `.ready`, whether something runs in them or
    /// not.
    public var readyToRemove: [WorktreeRow] {
        projects.flatMap(\.worktrees).filter {
            if case .ready = $0.eligibility { true } else { false }
        }
    }

    @ObservationIgnored let env: DashboardEnvironment
    @ObservationIgnored let reader: Reader
    @ObservationIgnored var repositories: [String: Repository] = [:]
    /// What runs in each worktree, by its path, from the last sample.
    @ObservationIgnored var groups: [String: [ProcessGroup]] = [:]
    @ObservationIgnored var sizes: [String: SizeInfo] = [:]
    @ObservationIgnored var measuredAt: [String: Date] = [:]
    @ObservationIgnored var staleSizes: Set<String> = []
    @ObservationIgnored var sizeQueue: [String] = []
    @ObservationIgnored var sizeWorker: Task<Void, Never>?
    @ObservationIgnored var pollTask: Task<Void, Never>?
    @ObservationIgnored var roots: [URL] = []
    @ObservationIgnored var rootsWatch: (paths: [String], token: AnyObject)?
    @ObservationIgnored var worktreeWatch: (paths: [String], token: AnyObject)?
    @ObservationIgnored let eventsReceived = Counter()
    @ObservationIgnored var eventsHandled = 0
    @ObservationIgnored var pendingEvents: [(stream: WatchStream, paths: [String])] = []
    @ObservationIgnored var eventWorker: Task<Void, Never>?
    @ObservationIgnored var ticket = 0
    @ObservationIgnored var cacheLoaded = false
    /// What the watcher added and removed while a scan was under way: the scan's answer may be older.
    @ObservationIgnored var changesDuringScan: RepositoryChanges?
    @ObservationIgnored var removalLocks: [String: Limiter] = [:]
    @ObservationIgnored let cacheWriter: CacheWriter
    @ObservationIgnored var cacheVersion = 0
    @ObservationIgnored var pendingCacheWrites = 0

    public init(env: DashboardEnvironment) {
        self.env = env
        didOnboard = env.settings.didOnboard
        reader = Reader(
            git: env.git, reviews: env.reviews, hosting: env.hosting, gitLimit: Limiter(limit: 4),
            networkLimit: Limiter(limit: 4))
        cacheWriter = CacheWriter(cache: env.cache)
    }

    isolated deinit {
        pollTask?.cancel()
        sizeWorker?.cancel()
        eventWorker?.cancel()
    }

    // MARK: Public operations

    /// "Start scan" of the first-run window: records that it is through, so that the next launch starts at once, and
    /// then starts. A second call while the first one runs scans no second time.
    public func completeOnboarding() async {
        guard !didOnboard else { return await start() }
        didOnboard = true
        env.settings.didOnboard = true
        // The window may be on the screen already: the processes are sampled from now on.
        visibilityChanged()
        await start()
    }

    /// The hosts of the remotes of the repositories, each once, in lowercase and in order. Read from `RemoteURL`, which
    /// holds no credentials: a remote with `user:token@` in front of its host gives the host only.
    public var hosts: [String] {
        Set(repositories.values.compactMap { $0.remote?.host }).sorted()
    }

    /// Shows what the cache holds, then scans the disk for repositories and, while the scan runs, reads git and the
    /// hosts for the repositories that the cache knows. Once the scan is through, the repositories that it did not find
    /// go and the new ones are read. The sizes come last, in the background. Watching the disk starts at once.
    ///
    /// Cancelling it gives up the scan, and nothing is removed for a scan that did not finish.
    public func start() async {
        guard didOnboard, !isStarting else { return }
        isStarting = true
        defer { isStarting = false }
        let hidden = env.settings.hiddenRepos
        if !cacheLoaded {
            cacheLoaded = true
            let cached = env.cache.load()
            sizes = cached.sizes
            measuredAt = cached.sizes.mapValues(\.computedAt)
            for path in cached.repositories where !hidden.contains(path) && repositories[path] == nil {
                repositories[path] = Repository(path: path)
            }
            publish()
        }

        let rules = env.settings.rules
        roots = env.scanner.defaultRoots(rules: rules)
        watchRoots()
        scanState = .scanning(found: repositories.count)
        changesDuringScan = RepositoryChanges()
        let (scanner, scanRoots) = (env.scanner, roots)
        async let scanned = withoutEscalation(priority: .utility) {
            await scanner.scan(roots: scanRoots, rules: rules, isCancelled: { false })
        }

        let cached = Array(repositories.keys)
        await load(cached)
        await lookUpReviews(of: cached)
        let found = await scanned
        let during = changesDuringScan ?? RepositoryChanges()
        changesDuringScan = nil
        guard !Task.isCancelled else {
            scanState = .idle
            return
        }

        // Read again: a repository may have been hidden while the scan ran.
        let foundPaths = Set(found.map(\.path)).subtracting(env.settings.hiddenRepos)
        let known = Set(repositories.keys)
        for path in known.subtracting(foundPaths).subtracting(during.added) { forget(path) }
        let added = Array(foundPaths.subtracting(known).subtracting(during.gone))
        for path in added { repositories[path] = Repository(path: path) }
        scanState = .idle
        publish()
        saveCache()
        await load(added)
        await lookUpReviews(of: added)
        lastUpdated = env.now()
        measureIfDue(worktreeRoots)
    }

    /// Reads git anew for every repository, and samples the processes. Asks no host.
    public func refresh() async {
        guard didOnboard else { return }
        await sampleProcesses()
        await load(Array(repositories.keys))
        flushStaleSizes()
        lastUpdated = env.now()
    }

    /// `git fetch --prune` in every repository, then everything anew: git, the processes, and the requests, with what
    /// the hosts said before forgotten.
    public func fetchAll() async {
        guard didOnboard else { return }
        let paths = Array(repositories.keys)
        await boundedForEach(paths) { [reader] path in _ = await reader.fetch(path) }
        await env.reviews.invalidate()
        await refresh()
        await lookUpReviews(of: paths)
        lastUpdated = env.now()
    }

    /// Asks the hosts again for the requests of the repositories on `host`, after a token or the kind of the host was
    /// changed: what the hosts said before is forgotten (`ReviewLooking.invalidate()` knows no single host, so the
    /// answers of every host are), and every branch of the repositories of this host is looked up.
    public func refreshReviews(host: String) async {
        guard didOnboard else { return }
        let host = host.lowercased()
        let paths = repositories.values.filter { $0.remote?.host == host }.map(\.path)
        await env.reviews.invalidate()
        await lookUpReviews(of: paths)
    }

    /// Hides the repository at `repoPath`: it goes from the rows and from the watch, and from the cache, and the
    /// settings keep it hidden, so that no scan brings it back. Showing it again is for the settings.
    public func hide(repoPath: String) {
        env.settings.hiddenRepos.insert(repoPath)
        // A scan that is under way may have found it already.
        changesDuringScan?.gone.insert(repoPath)
        changesDuringScan?.added.remove(repoPath)
        forget(repoPath)
        publish()
        updateWorktreeWatch()
        saveCache()
    }

    // MARK: Reading

    /// Reads git for the repositories at `paths`, four at a time, and shows each as soon as it is read.
    func load(_ paths: [String]) async {
        let jobs = paths.compactMap { path -> (path: String, ticket: Int, reviews: [String: KnownReview])? in
            guard let repo = repositories[path] else { return nil }
            return (path, nextTicket(), repo.reviews)
        }
        guard !jobs.isEmpty else { return }
        await boundedForEach(jobs) { [reader] job in
            (job.path, job.ticket, await reader.repository(at: job.path, reviews: job.reviews))
        } take: { path, ticket, snapshot in
            apply(snapshot, to: path, ticket: ticket)
        }
        updateWorktreeWatch()
    }

    private func apply(_ snapshot: RepositorySnapshot, to path: String, ticket: Int) {
        guard var repo = repositories[path], ticket > repo.listTicket else { return }
        let worktrees = snapshot.worktrees ?? []
        let listed = Set(worktrees.map(\.path))
        for gone in repo.worktrees.map(\.path) where !listed.contains(gone) && gone != path {
            sizes[gone] = nil
            measuredAt[gone] = nil
        }
        if snapshot.remote?.host != repo.remote?.host { repo.kind = nil }
        repo.listTicket = ticket
        repo.worktrees = worktrees
        repo.remote = snapshot.remote
        repo.adminNames = snapshot.adminNames
        repo.facts = repo.facts.filter { listed.contains($0.key) }
        repo.reviews = repo.reviews.filter { listed.contains($0.key) }
        for worktree in worktrees where ticket > repo.factTickets[worktree.path, default: 0] {
            repo.facts[worktree.path] = snapshot.facts[worktree.path]
            repo.factTickets[worktree.path] = ticket
        }
        repo.factTickets = repo.factTickets.filter { listed.contains($0.key) }
        repositories[path] = repo
        publish()
    }

    /// Reads the facts of single worktrees anew, by worktree path with the path of their repository.
    func reread(_ worktrees: [String: String]) async {
        let jobs = worktrees.compactMap { path, repoPath -> (Worktree, String, Int, ReviewInfo)? in
            guard let repo = repositories[repoPath], let worktree = repo.worktrees.first(where: { $0.path == path })
            else { return nil }
            return (worktree, repoPath, nextTicket(), repo.reviews.review(of: worktree))
        }
        guard !jobs.isEmpty else { return }
        await boundedForEach(jobs) { [reader] worktree, repo, ticket, review in
            (worktree.path, repo, ticket, await reader.facts(of: worktree, in: repo, review: review))
        } take: { path, repoPath, ticket, facts in
            guard var repo = repositories[repoPath], repo.worktrees.contains(where: { $0.path == path }),
                ticket > repo.factTickets[path, default: 0]
            else { return }
            repo.facts[path] = facts
            repo.factTickets[path] = ticket
            repositories[repoPath] = repo
        }
        publish()
    }

    /// Finds out what the hosts of the repositories at `paths` run, each host once, and then asks them for the request
    /// of every branch. A worktree whose request turns out merged, and whose branch has no live upstream, is read
    /// again, for whether its HEAD is in the merge.
    func lookUpReviews(of paths: [String]) async {
        let hosts = Set(paths.compactMap { repositories[$0]?.remote?.host })
        let kinds = await reader.kinds(of: hosts)
        for path in paths {
            if let host = repositories[path]?.remote?.host { repositories[path]?.kind = kinds[host] }
        }
        let jobs = paths.flatMap { path -> [(String, Worktree, RemoteURL?, HostingKind?)] in
            guard let repo = repositories[path] else { return [] }
            return repo.presentWorktrees.filter { !$0.isDetached && $0.branch != nil }.map {
                (path, $0, repo.remote, repo.kind)
            }
        }
        var toReread: [String: String] = [:]
        await boundedForEach(jobs) { [reader] repo, worktree, remote, kind in
            (repo, worktree, await reader.review(of: worktree, remote: remote, kind: kind))
        } take: { repoPath, worktree, review in
            guard let branch = worktree.branch, var repo = repositories[repoPath],
                repo.worktrees.contains(where: { $0.path == worktree.path && $0.branch == branch })
            else { return }
            repo.reviews[worktree.path] = KnownReview(branch: branch, info: review)
            repositories[repoPath] = repo
            let status = repo.facts[worktree.path]?.status
            if review.state == .merged, !worktree.isMain, status.map({ !$0.hasLiveUpstream }) == true {
                toReread[worktree.path] = repoPath
            }
        }
        publish()
        await reread(toReread)
    }

    /// Asks for a sample of the processes, and shows what runs where.
    func sampleProcesses() async {
        groups = await ProcessGroups.sample(env.sampler, roots: worktreeRoots)
        publish()
    }

    /// While a scan runs, the repositories that the watcher adds count as found.
    func countFoundRepositories() {
        if case .scanning = scanState { scanState = .scanning(found: repositories.count) }
    }

    func forget(_ path: String) {
        guard let repo = repositories.removeValue(forKey: path) else { return }
        for worktree in repo.worktrees.map(\.path) + [path] {
            sizes[worktree] = nil
            measuredAt[worktree] = nil
            staleSizes.remove(worktree)
        }
    }

    private func nextTicket() -> Int {
        ticket += 1
        return ticket
    }

    // MARK: What is shown

    /// The folders of all the worktrees that have one, main worktrees included.
    var worktreeRoots: [String] {
        repositories.values.flatMap { $0.presentWorktrees.map(\.path) }.sorted()
    }

    func publish() {
        projects = repositories.values
            .sorted { ($0.name.lowercased(), $0.path) < ($1.name.lowercased(), $1.path) }
            .map(project)
    }

    private func project(of repo: Repository) -> ProjectRow {
        let main = repo.worktrees.first(where: \.isMain) ?? Worktree(path: repo.path, isMain: true)
        return ProjectRow(
            path: repo.path, name: repo.name, main: row(of: main, in: repo),
            worktrees: repo.worktrees.filter { !$0.isMain }.map { row(of: $0, in: repo) })
    }

    private func row(of worktree: Worktree, in repo: Repository) -> WorktreeRow {
        let facts = repo.facts[worktree.path] ?? GitFacts()
        let review = repo.reviews.review(of: worktree)
        let running = worktree.isPrunable ? [] : groups[worktree.path] ?? []
        let eligibility = RemovalPolicy.evaluate(
            facts.removalFacts(of: worktree, review: review, runningGroups: running.count, signaler: env.signaler))
        return WorktreeRow(
            repoPath: repo.path, repoName: repo.name, worktree: worktree, status: facts.status, review: review,
            hosting: repo.remote == nil ? nil : repo.kind, groups: running, size: sizes[worktree.path],
            eligibility: eligibility)
    }

    /// Whether nothing that the store started on its own is still going: no watcher event on its way or being
    /// handled, no size being measured, no cache being written, no start. For tests.
    var isIdle: Bool {
        eventsReceived.count == eventsHandled && pendingEvents.isEmpty && eventWorker == nil && sizeWorker == nil
            && pendingCacheWrites == 0 && !isStarting
    }
}
