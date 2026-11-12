import Cleanup
import CoreModels
import DiskUsage
import Foundation

/// What the store knows for the Caches and Docker page: the Docker VM and what it holds, the caches, the build outputs
/// of the worktrees, and their sizes. `CachesPage` makes the page of it.
public struct CleanupState: Equatable, Sendable {
    /// The size of the disk of the Docker VM, in `sizes`.
    public static let dockerDiskKey = "docker-disk"
    /// "Start and inspect", in `working`.
    public static let startDockerID = "docker-start"
    /// Removing the unused images, in `working`.
    public static let unusedImagesID = "docker-images"
    /// Removing the stopped containers, in `working`.
    public static let stoppedContainersID = "docker-containers"

    /// `nil` until Docker has been asked.
    public var docker: DockerStatus?
    /// What the VM holds. `nil` while it does not run, or when it did not say.
    public var inventory: DockerInventory?
    public var caches: [CacheEntry]
    public var buildOutputs: [BuildOutput]
    /// What deleting would free, in bytes (`SizeInfo.privateBytes`): by `CacheEntry.id`, by `BuildOutput.path`, and the
    /// disk of the VM at `dockerDiskKey`. A key that has none is still to be measured.
    public var sizes: [String: UInt64]
    /// What is being cleaned or started now: the id of a cache, the path of a build output, or one of the Docker ids
    /// above. The page offers nothing more for them until they are done.
    public var working: Set<String>
    /// When the last load was through.
    public var loadedAt: Date?
    /// Whether a load is under way.
    public var isLoading: Bool

    public init(
        docker: DockerStatus? = nil, inventory: DockerInventory? = nil, caches: [CacheEntry] = [],
        buildOutputs: [BuildOutput] = [], sizes: [String: UInt64] = [:], working: Set<String> = [],
        loadedAt: Date? = nil, isLoading: Bool = false
    ) {
        self.docker = docker
        self.inventory = inventory
        self.caches = caches
        self.buildOutputs = buildOutputs
        self.sizes = sizes
        self.working = working
        self.loadedAt = loadedAt
        self.isLoading = isLoading
    }
}

extension DashboardStore {
    /// How often a VM that was started is asked whether it runs, and for how long at most (Ruling 2). Docker Desktop
    /// and OrbStack are only asked to open, and answer a while after that.
    static let dockerStartPoll: Duration = .seconds(2)
    static let dockerStartLimit: Duration = .seconds(120)

    // MARK: Loading

    /// Asks Docker, the caches and the worktrees what there is, shows it, and then measures what has no size or one
    /// older than `sizeIntervalOnStart`, one folder at a time in the background; `force` measures everything again.
    /// The window calls it when the page is first shown and for Refresh. A call while one is under way does nothing.
    ///
    /// Everything is asked away from the main actor, and the three at the same time.
    public func loadCleanup(force: Bool = false) async {
        guard didOnboard, !cleanup.isLoading else { return }
        loadCacheIfNeeded()
        cleanup.isLoading = true
        defer { cleanup.isLoading = false }
        let (docker, caches, finder) = (env.docker, env.caches, env.buildOutputs)
        let (repos, worktrees) = (repositories.keys.sorted(), worktreeRoots)
        async let status = CleanupWork.status(of: docker)
        async let entries = CleanupWork.entries(of: caches, repositories: repos)
        async let outputs = CleanupWork.find(in: worktrees, with: finder)
        await show(await status)
        cleanup.caches = await entries
        cleanup.buildOutputs = await outputs
        cleanup.loadedAt = env.now()
        // Only now that all three are in: the sizes of what is no longer there go, and those of what is not listed yet
        // must not.
        updateCleanupTargets()
        let keys = orderedCleanupKeys()
        measureCleanup(force ? keys : keys.filter(isCleanupSizeDue))
    }

    // MARK: Cleaning

    /// Cleans `entry` (`CacheCataloging.clean`) and measures it again. The caches are listed again too, without being
    /// measured: a cleaned cache may have nothing left to clean (no unavailable simulators) or be gone (old pnpm
    /// stores). Returns what went wrong, for the user, or `nil`.
    public func clean(cache entry: CacheEntry) async -> String? {
        guard !cleanup.working.contains(entry.id) else { return nil }
        cleanup.working.insert(entry.id)
        defer { cleanup.working.remove(entry.id) }
        let failure = await CleanupWork.clean(entry, with: env.caches)
        cleanup.caches = await CleanupWork.entries(of: env.caches, repositories: repositories.keys.sorted())
        updateCleanupTargets()
        // A clean that stopped half way deleted what it deleted, so the size is measured again either way.
        measureCleanup([entry.id], first: true)
        return failure.map(CachesPresenter.message(for:))
    }

    /// Deletes `output` (`BuildOutputFinding.delete`, which checks it again first). Once it is gone it leaves the page,
    /// and its worktree is measured again. One that was gone already counts as deleted (Ruling 7).
    public func clean(output: BuildOutput) async -> String? {
        guard !cleanup.working.contains(output.path) else { return nil }
        cleanup.working.insert(output.path)
        defer { cleanup.working.remove(output.path) }
        if let failure = await CleanupWork.delete(output, with: env.buildOutputs) {
            measureCleanup([output.path], first: true)
            return CachesPresenter.message(for: failure)
        }
        cleanup.buildOutputs.removeAll { $0.path == output.path }
        updateCleanupTargets()
        measureNow([output.worktree])
        saveCache()
        return nil
    }

    // MARK: Docker

    /// "Start and inspect": starts the VM if it is not running, waits for it to run, asking every 2 seconds for up to
    /// 2 minutes, and then reads what it holds and measures its disk again. Returns what went wrong, for the user, or
    /// `nil`.
    public func startDocker() async -> String? {
        guard case .runtime(let runtime)? = cleanup.docker else {
            return cleanup.docker.flatMap(CachesPresenter.dockerProblem(with:)) ?? "Docker did not answer"
        }
        let id = CleanupState.startDockerID
        guard !cleanup.working.contains(id) else { return nil }
        cleanup.working.insert(id)
        defer { cleanup.working.remove(id) }
        if !runtime.isRunning, let failure = await CleanupWork.start(runtime, with: env.docker) {
            return CachesPresenter.message(for: failure)
        }
        var waited = Duration.zero
        while true {
            let status = await CleanupWork.status(of: env.docker)
            if case .runtime(let now) = status {
                setDocker(status)
                if now.isRunning { break }
            }
            guard waited < Self.dockerStartLimit else {
                setDocker(status)
                return "Docker did not start in 2 minutes"
            }
            do { try await env.sleep(Self.dockerStartPoll) } catch { return nil }
            waited += Self.dockerStartPoll
        }
        updateCleanupTargets()
        measureCleanup([CleanupState.dockerDiskKey], first: true)
        do {
            cleanup.inventory = try await CleanupWork.inventory(of: env.docker)
        } catch {
            return CachesPresenter.message(for: error)
        }
        return nil
    }

    /// `docker image prune -a -f`, then Docker is read again and the disk of the VM measured again.
    public func removeUnusedImages() async -> String? {
        await prune(CleanupState.unusedImagesID)
    }

    /// `docker container prune -f`, then Docker is read again and the disk of the VM measured again.
    public func removeStoppedContainers() async -> String? {
        await prune(CleanupState.stoppedContainersID)
    }

    private func prune(_ id: String) async -> String? {
        guard !cleanup.working.contains(id) else { return nil }
        cleanup.working.insert(id)
        defer { cleanup.working.remove(id) }
        let failure = await CleanupWork.prune(images: id == CleanupState.unusedImagesID, with: env.docker)
        // A prune that failed half way removed what it removed.
        await show(await CleanupWork.status(of: env.docker))
        updateCleanupTargets()
        measureCleanup([CleanupState.dockerDiskKey], first: true)
        return failure.map(CachesPresenter.message(for:))
    }

    /// Takes `status`, and what the VM holds if it runs. A VM that runs and does not say what it holds shows nothing of
    /// it.
    private func show(_ status: DockerStatus) async {
        setDocker(status)
        guard case .runtime(let runtime) = status, runtime.isRunning else {
            cleanup.inventory = nil
            return
        }
        let inventory = try? await CleanupWork.inventory(of: env.docker)
        if cleanup.inventory != inventory { cleanup.inventory = inventory }
    }

    /// Sets the status only when it changed: every set draws the page again, and the start asks every 2 seconds.
    private func setDocker(_ status: DockerStatus) {
        if cleanup.docker != status { cleanup.docker = status }
    }

    // MARK: Sizes

    /// Notes which folders each row stands for, now that the rows changed, and drops the sizes of the rows that are
    /// gone.
    private func updateCleanupTargets() {
        var targets: [String: [String]] = [:]
        if case .runtime(let runtime)? = cleanup.docker, let disk = runtime.diskPath {
            targets[CleanupState.dockerDiskKey] = [disk]
        }
        for entry in cleanup.caches { targets[entry.id] = entry.paths }
        for output in cleanup.buildOutputs { targets[output.path] = [output.path] }
        cleanupTargets = targets
        cleanupSizes = cleanupSizes.filter { targets[$0.key] != nil }
        cleanupQueue.removeAll { targets[$0] == nil }
        let sizes = cleanupSizes.mapValues { UInt64(clamping: $0.privateBytes) }
        if cleanup.sizes != sizes { cleanup.sizes = sizes }
    }

    /// The keys of the rows in the order of the page: the VM's disk, the caches, the build outputs.
    private func orderedCleanupKeys() -> [String] {
        let docker = cleanupTargets[CleanupState.dockerDiskKey] == nil ? [] : [CleanupState.dockerDiskKey]
        return docker + cleanup.caches.map(\.id) + cleanup.buildOutputs.map(\.path)
    }

    private func isCleanupSizeDue(_ key: String) -> Bool {
        cleanupSizes[key].map { env.now().timeIntervalSince($0.computedAt) >= Self.sizeIntervalOnStart } ?? true
    }

    /// Puts `keys` in the queue, at its end or, with `first`, before everything else, and starts the worker if it is
    /// not running. One folder at a time, at background priority, as the worktrees are measured.
    private func measureCleanup(_ keys: [String], first: Bool = false) {
        if first {
            cleanupQueue.removeAll { keys.contains($0) }
            cleanupQueue.insert(contentsOf: keys, at: 0)
        } else {
            for key in keys where !cleanupQueue.contains(key) { cleanupQueue.append(key) }
        }
        guard cleanupWorker == nil, !cleanupQueue.isEmpty else { return }
        let measurer = env.sizes
        // Nothing waits for this task, so nothing raises its priority.
        cleanupWorker = Task(priority: .background) { [weak self] in
            while let job = self?.nextCleanupJob() {
                let size = await CleanupWork.measure(job.paths, with: measurer)
                self?.finishCleanupSize(of: job.key, size)
            }
        }
    }

    /// The next row to measure, or `nil` when there is none, and the worker is done: the cache is written then.
    private func nextCleanupJob() -> (key: String, paths: [String])? {
        while !cleanupQueue.isEmpty {
            let key = cleanupQueue.removeFirst()
            guard let paths = cleanupTargets[key] else { continue }  // gone since it was asked for
            return (key, paths)
        }
        cleanupWorker = nil
        saveCache()
        return nil
    }

    private func finishCleanupSize(of key: String, _ size: SizeInfo) {
        guard cleanupTargets[key] != nil else { return }
        // Stamped with the store's clock, which the 6 hours are counted on, here and after a restart.
        cleanupSizes[key] = SizeInfo(
            apparentBytes: size.apparentBytes, privateBytes: size.privateBytes, computedAt: env.now())
        cleanup.sizes[key] = UInt64(clamping: size.privateBytes)
    }
}

/// What the Caches and Docker page asks of Docker, the caches and the disk, each away from the main actor: the
/// catalog and the finder walk folders and delete them in calls that block their thread for as long as that takes.
enum CleanupWork {
    @concurrent
    static func status(of docker: any DockerControlling) async -> DockerStatus {
        await docker.status()
    }

    @concurrent
    static func inventory(of docker: any DockerControlling) async throws -> DockerInventory {
        try await docker.inventory()
    }

    /// What stopped the start, or `nil`.
    @concurrent
    static func start(_ runtime: DockerRuntime, with docker: any DockerControlling) async -> (any Error)? {
        do {
            try await docker.start(runtime)
            return nil
        } catch {
            return error
        }
    }

    /// The unused images, or else the stopped containers. What stopped it, or `nil`.
    @concurrent
    static func prune(images: Bool, with docker: any DockerControlling) async -> (any Error)? {
        do {
            _ = try await images ? docker.removeUnusedImages() : docker.removeStoppedContainers()
            return nil
        } catch {
            return error
        }
    }

    /// The caches, told how many of `repositories` have a `pnpm-lock.yaml` at their root.
    @concurrent
    static func entries(of caches: any CacheCataloging, repositories: [String]) async -> [CacheEntry] {
        let files = FileManager.default
        let pnpm = repositories.filter { files.fileExists(atPath: $0 + "/pnpm-lock.yaml") }.count
        return await caches.entries(projectsUsingPnpm: pnpm)
    }

    @concurrent
    static func find(in worktrees: [String], with finder: any BuildOutputFinding) async -> [BuildOutput] {
        await finder.find(in: worktrees)
    }

    /// What stopped the clean, or `nil`.
    @concurrent
    static func clean(_ entry: CacheEntry, with caches: any CacheCataloging) async -> (any Error)? {
        do {
            try await caches.clean(entry)
            return nil
        } catch {
            return error
        }
    }

    /// What stopped the delete, or `nil`. `nil` too when nothing is at the path any more: the finder refuses a folder
    /// that it cannot resolve (`pathEscapes`), and one that is gone is as deleted as it gets. Anything at the path, a
    /// link included, is still refused.
    @concurrent
    static func delete(_ output: BuildOutput, with finder: any BuildOutputFinding) async -> (any Error)? {
        do {
            try await finder.delete(output)
            return nil
        } catch CleanupError.pathEscapes(_) where !isAnything(at: output.path) {
            return nil
        } catch {
            return error
        }
    }

    /// Whether there is a file, a folder or a link at `path`. A link is not followed: one that leads nowhere is
    /// something.
    private static func isAnything(at path: String) -> Bool {
        (try? FileManager.default.attributesOfItem(atPath: path)) != nil
    }

    /// The sum of the sizes of `paths`. A path that cannot be measured (it is gone, say) adds nothing, so a row whose
    /// folders are all gone reads 0 rather than waiting for a size forever.
    @concurrent
    static func measure(_ paths: [String], with measurer: any SizeMeasuring) async -> SizeInfo {
        var (apparent, own): (Int64, Int64) = (0, 0)
        for path in paths {
            guard
                let size = try? measurer.measure(
                    URL(filePath: path, directoryHint: .isDirectory), excluding: [], isCancelled: { Task.isCancelled })
            else { continue }
            apparent += size.apparentBytes
            own += size.privateBytes
        }
        return SizeInfo(apparentBytes: apparent, privateBytes: own, computedAt: Date())
    }
}
