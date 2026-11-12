import CoreModels
import DiskUsage
import Foundation

/// The two watches of the store.
enum WatchStream: Sendable {
    /// The scan roots: repositories that appear and go.
    case roots
    /// The worktrees: statuses and sizes.
    case worktrees
}

extension DashboardStore {
    /// How long a size, from the cache or from a measure, stands when the app starts (Ruling 70). Walking every
    /// worktree's `node_modules` on each launch keeps a core busy for minutes, and the sizes of folders that nobody
    /// looks at change little in a day.
    static let sizeIntervalOnStart: TimeInterval = 6 * 60 * 60
    /// How long a measured size stands before a change in the folder makes it worth measuring again. A worktree in
    /// which a build runs changes all the time, and walking its `node_modules` again every few seconds would be most of
    /// what the app does (Ruling 70).
    static let sizeIntervalOnChange: TimeInterval = 10 * 60
    /// How old a size may be when the user looks at it: in the inspector, or in the sheet that removes the worktree.
    static let sizeIntervalOnDemand: TimeInterval = 60
    /// The sizes reach the cache at most this often while they are measured, and once more when the last is done, so
    /// that quitting in the middle of a pass loses at most this much of it.
    static let sizeSaveInterval: TimeInterval = 30
    static let watchLatency: Duration = .seconds(2)
    static let pollInterval: Duration = .seconds(3)
    /// How often the processes are sampled while the window is on the screen but another app is in front: nobody
    /// watches the table closely then, and a sample reads every process of the user, a thousand of them on a busy Mac.
    static let backgroundPollInterval: Duration = .seconds(15)

    // MARK: Processes

    func visibilityChanged() {
        pollTask?.cancel()
        pollTask = nil
        guard isWindowVisible, didOnboard else { return }
        let (sleep, interval) = (env.sleep, isAppActive ? Self.pollInterval : Self.backgroundPollInterval)
        pollTask = Task(priority: .utility) { [weak self] in
            while !Task.isCancelled {
                guard await self?.tick() != nil else { return }
                do { try await sleep(interval) } catch { return }
            }
        }
    }

    /// What is done every 3 seconds while the window is visible, or every 15 while another app is in front.
    private func tick() async {
        await sampleProcesses()
        flushStaleSizes()
    }

    // MARK: Sizes

    /// Measures the folders at `paths` that have no size, or one older than `sizeIntervalOnStart`. The others keep
    /// their size.
    func measureIfDue(_ paths: [String]) {
        for path in paths where isDue(path, after: Self.sizeIntervalOnStart) { enqueueSize(path) }
    }

    /// Measures the folders at `paths` before any other, if their size is older than a minute
    /// (`sizeIntervalOnDemand`): the window calls it for the worktree that the inspector shows and for the rows of the
    /// sheet that removes worktrees, whose sizes the user reads then. One that is being measured is not asked for
    /// twice.
    public func refreshSizes(of paths: [String]) {
        measureNow(paths.filter { $0 != sizeInFlight && isDue($0, after: Self.sizeIntervalOnDemand) })
    }

    /// Measures the folders of worktrees at `paths` before any other, however new their size: after a build output in
    /// one was deleted, say. One that is being measured is measured again, as that measure may have begun before.
    func measureNow(_ paths: [String]) {
        let due = paths.filter(isMeasurable)
        guard !due.isEmpty else { return }
        staleSizes.subtract(due)
        sizeQueue.removeAll { due.contains($0) }
        sizeQueue.insert(contentsOf: due, at: 0)
        enqueueSize(nil)
    }

    /// Notes that what is in the folders at `paths` changed: each is measured again now if its size is older than
    /// `sizeIntervalOnChange`, or else once it is (`flushStaleSizes`).
    func markStale(_ paths: some Sequence<String>) {
        for path in paths {
            if isDue(path, after: Self.sizeIntervalOnChange) { enqueueSize(path) } else { staleSizes.insert(path) }
        }
    }

    func flushStaleSizes() {
        let due = staleSizes.filter { isDue($0, after: Self.sizeIntervalOnChange) }
        staleSizes.subtract(due)
        for path in due.sorted() { enqueueSize(path) }
    }

    private func isDue(_ path: String, after interval: TimeInterval) -> Bool {
        measuredAt[path].map { env.now().timeIntervalSince($0) >= interval } ?? true
    }

    /// Whether `path` is the folder of a worktree that has one.
    private func isMeasurable(_ path: String) -> Bool {
        repositories.values.contains { $0.presentWorktrees.contains { $0.path == path } }
    }

    /// Puts `path` at the end of the queue, if it is not in it, and starts the worker if it is not running.
    private func enqueueSize(_ path: String?) {
        if let path, !sizeQueue.contains(path) { sizeQueue.append(path) }
        guard sizeWorker == nil, !sizeQueue.isEmpty else { return }
        let measurer = env.sizes
        // One folder at a time, at background priority. Nothing waits for this task, so nothing raises its priority.
        sizeWorker = Task(priority: .background) { [weak self] in
            while let job = self?.nextSizeJob() {
                let size = await SizeJob.measure(job, with: measurer)
                self?.finishSize(of: job.path, size)
            }
        }
    }

    /// The next folder to measure, or `nil` when there is none, and the worker is done.
    private func nextSizeJob() -> SizeJob? {
        while !sizeQueue.isEmpty {
            let path = sizeQueue.removeFirst()
            guard let repo = repositories.values.first(where: { $0.presentWorktrees.contains { $0.path == path } })
            else { continue }  // gone since it was asked for
            // A worktree inside this one is measured on its own, and is not freed by removing this one: git refuses.
            let nested = repo.presentWorktrees.map(\.path).filter { $0 != path && isInside($0, path) }
            sizeInFlight = path
            return SizeJob(path: path, excluding: Set(nested))
        }
        sizeWorker = nil
        sizeInFlight = nil
        saveSizes()
        return nil
    }

    private func finishSize(of path: String, _ size: SizeInfo?) {
        sizeInFlight = nil
        guard isMeasurable(path) else { return }
        let now = env.now()
        // The cache keeps the size with its `computedAt`, which the next start takes for the time it was measured.
        sizes[path] = size
        measuredAt[path] = now
        publish()
        if lastSizeSave.map({ now.timeIntervalSince($0) >= Self.sizeSaveInterval }) ?? true { saveSizes() }
    }

    /// Writes the cache for the sizes, and notes when.
    private func saveSizes() {
        lastSizeSave = env.now()
        saveCache()
    }

    // MARK: Watching

    func watchRoots() {
        let paths = roots.map { canonicalPath($0.path) }
        guard rootsWatch?.paths != paths else { return }
        rootsWatch = (paths, watch(paths, as: .roots))
    }

    func updateWorktreeWatch() {
        let paths = worktreeRoots
        guard worktreeWatch?.paths != paths else { return }
        worktreeWatch = paths.isEmpty ? nil : (paths, watch(paths, as: .worktrees))
    }

    private func watch(_ paths: [String], as stream: WatchStream) -> AnyObject {
        let received = eventsReceived
        return env.watcher.watch(paths: paths, latency: Self.watchLatency) { [weak self] changed in
            received.increment()
            guard let self else { return }
            Task { @MainActor in self.receive(changed, from: stream) }
        }
    }

    /// Takes in what a watch reported. Events are handled one batch after the other, in the order they came.
    private func receive(_ paths: [String], from stream: WatchStream) {
        pendingEvents.append((stream, paths))
        guard eventWorker == nil else { return }
        eventWorker = Task { [weak self] in
            while let next = self?.nextEvent() { await self?.handle(next.paths, from: next.stream) }
        }
    }

    private func nextEvent() -> (stream: WatchStream, paths: [String])? {
        guard !pendingEvents.isEmpty else {
            eventWorker = nil
            return nil
        }
        return pendingEvents.removeFirst()
    }

    private func handle(_ paths: [String], from stream: WatchStream) async {
        defer { eventsHandled += 1 }
        switch stream {
        case .worktrees:
            let changes = WorktreeChanges(paths, in: repositories.values)
            markStale(changes.sizes)
            await load(Array(changes.repositories))
            await reread(changes.worktrees)
        case .roots:
            let hidden = env.settings.hiddenRepos
            var changes = await RepositoryChanges.inspect(
                paths, known: Set(repositories.keys).union(hidden), roots: roots, rules: env.settings.rules)
            changes.added = changes.added.filter { repositories[$0] == nil }
            changes.gone = changes.gone.filter { repositories[$0] != nil }
            guard !changes.added.isEmpty || !changes.gone.isEmpty else { return }
            changesDuringScan?.added.formUnion(changes.added)
            changesDuringScan?.gone.formUnion(changes.gone)
            for path in changes.gone { forget(path) }
            for path in changes.added { repositories[path] = Repository(path: path) }
            countFoundRepositories()
            publish()
            saveCache()
            updateWorktreeWatch()
            let added = Array(changes.added)
            await load(added)
            await lookUpReviews(of: added)
            measureIfDue(added.flatMap { repositories[$0]?.presentWorktrees.map(\.path) ?? [] })
        }
    }

    // MARK: Cache

    /// Writes the repositories and the sizes of their worktrees to the cache, away from the main actor.
    func saveCache() {
        let worktrees = Set(worktreeRoots)
        let contents = DashboardCache.Contents(
            repositories: repositories.keys.sorted(), sizes: sizes.filter { worktrees.contains($0.key) },
            cleanupSizes: cleanupSizes)
        cacheVersion += 1
        let (version, writer) = (cacheVersion, cacheWriter)
        pendingCacheWrites += 1
        Task { [weak self] in
            await writer.write(contents, version: version)
            self?.pendingCacheWrites -= 1
        }
    }
}

/// A folder to measure.
struct SizeJob: Sendable {
    let path: String
    let excluding: Set<String>

    /// The size, or `nil` if the folder cannot be measured (it is gone, say).
    @concurrent
    static func measure(_ job: SizeJob, with measurer: any SizeMeasuring) async -> SizeInfo? {
        try? measurer.measure(
            URL(filePath: job.path, directoryHint: .isDirectory), excluding: job.excluding,
            isCancelled: { Task.isCancelled })
    }
}
