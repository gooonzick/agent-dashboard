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
    /// How long a measured size stands before a change makes it worth measuring again. A worktree in which a build
    /// runs changes all the time, and walking its `node_modules` again every two seconds would be most of what the app
    /// does.
    static let sizeInterval: TimeInterval = 30
    static let watchLatency: Duration = .seconds(2)
    static let pollInterval: Duration = .seconds(3)

    // MARK: Processes

    func visibilityChanged() {
        pollTask?.cancel()
        pollTask = nil
        guard isWindowVisible, didOnboard else { return }
        let sleep = env.sleep
        pollTask = Task(priority: .utility) { [weak self] in
            while !Task.isCancelled {
                guard await self?.tick() != nil else { return }
                do { try await sleep(Self.pollInterval) } catch { return }
            }
        }
    }

    /// What is done every 3 seconds while the window is visible.
    private func tick() async {
        await sampleProcesses()
        flushStaleSizes()
    }

    // MARK: Sizes

    /// Measures the folders at `paths` that have not been measured lately. The others keep their size.
    func measureIfDue(_ paths: [String]) {
        for path in paths where isDue(path) { enqueueSize(path) }
    }

    /// Notes that what is in the folders at `paths` changed: each is measured again now if it has not been lately, or
    /// else once it is due (`flushStaleSizes`).
    func markStale(_ paths: some Sequence<String>) {
        for path in paths {
            if isDue(path) { enqueueSize(path) } else { staleSizes.insert(path) }
        }
    }

    func flushStaleSizes() {
        let due = staleSizes.filter(isDue)
        staleSizes.subtract(due)
        for path in due.sorted() { enqueueSize(path) }
    }

    private func isDue(_ path: String) -> Bool {
        measuredAt[path].map { env.now().timeIntervalSince($0) >= Self.sizeInterval } ?? true
    }

    private func enqueueSize(_ path: String) {
        if !sizeQueue.contains(path) { sizeQueue.append(path) }
        guard sizeWorker == nil else { return }
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
            return SizeJob(path: path, excluding: Set(nested))
        }
        sizeWorker = nil
        saveCache()
        return nil
    }

    private func finishSize(of path: String, _ size: SizeInfo?) {
        guard repositories.values.contains(where: { $0.presentWorktrees.contains { $0.path == path } }) else { return }
        sizes[path] = size
        measuredAt[path] = env.now()
        publish()
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
            repositories: repositories.keys.sorted(), sizes: sizes.filter { worktrees.contains($0.key) })
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
