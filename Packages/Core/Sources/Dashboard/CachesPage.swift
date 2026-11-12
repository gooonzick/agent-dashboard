import Cleanup
import CoreModels
import Foundation

/// The Caches and Docker page as the store's `CleanupState` makes it: the total on top and what of it can be cleaned,
/// the bar of categories, the Docker card and the rows of the three lists. Made of the state alone, so that what is on
/// the page can be tested without a window.
public struct CachesPage: Equatable, Sendable {
    /// Everything measured: the disk of the VM, the build outputs and the caches.
    public let total: UInt64
    /// The build outputs that nothing runs in, the caches whose clean empties them, and what Docker would free of
    /// unused images and stopped containers while it is known.
    public let cleanable: UInt64
    /// The categories by size, the largest first, and the caches of no category as `Other`, last. A category with
    /// nothing measured is left out.
    public let bar: [MemorySegment]
    public let docker: DockerSection
    /// The largest first; one that is not measured yet last.
    public let outputs: [CleanupRow]
    /// In the order of the catalog.
    public let packages: [CleanupRow]
    public let xcode: [CleanupRow]

    /// The caches whose clean frees only part of them, which `cleanable` does not count: `pnpm store prune` removes
    /// the packages no project uses, and the simulators that are deleted are the unavailable ones (Ruling 10).
    private static let partialCleans: Set<String> = ["pnpm", "simulators"]

    /// The categories of the bar and the rows that each one sums, by the key of `CleanupState.sizes`. The build
    /// outputs are a category of their own, added in `init`.
    private static let categories: [(label: String, keys: [String])] = [
        ("Xcode", ["derived-data", "simulators"]),
        ("Docker VM", [CleanupState.dockerDiskKey]),
        ("pnpm store", ["pnpm", "pnpm-old"]),
        ("Homebrew", ["homebrew"]),
        ("Go", ["go"]),
        ("npm", ["npm"]),
    ]

    /// `users` is the store's `buildOutputUsers`: a build output that a process runs in, or runs a file of, is not
    /// offered. A `query` keeps the rows whose title, subtitle or path holds it; the totals and the bar stay those of
    /// everything. `home` is shown as `~` in the paths.
    public init(
        state: CleanupState, users: [String: String], query: String = "",
        home: String = FileManager.default.homeDirectoryForCurrentUser.path
    ) {
        let needle = query.trimmingCharacters(in: .whitespaces).lowercased()
        let sizes = state.sizes

        let outputs = state.buildOutputs.map { output in
            CleanupRow(output, size: sizes[output.path], user: users[output.path], state: state)
        }
        let caches = state.caches.map { CleanupRow($0, size: sizes[$0.id], home: home, state: state) }
        func shown(_ row: CleanupRow, _ paths: [String]) -> Bool {
            needle.isEmpty || ([row.title, row.subtitle] + paths).contains { $0.lowercased().contains(needle) }
        }
        self.outputs = zip(outputs, state.buildOutputs).filter { shown($0, [$1.path]) }.map(\.0).sorted {
            switch ($0.size, $1.size) {
            case (let a?, let b?) where a != b: a > b
            case (.some, nil): true
            case (nil, .some): false
            default: $0.title == $1.title ? $0.id < $1.id : $0.title < $1.title
            }
        }
        let shownCaches = zip(caches, state.caches).filter { shown($0, $1.paths) }
        packages = shownCaches.filter { $1.group == .packages }.map(\.0)
        xcode = shownCaches.filter { $1.group == .xcode }.map(\.0)
        docker = DockerSection(state: state)

        let outputBytes = state.buildOutputs.reduce(UInt64(0)) { $0.adding(sizes[$1.path]) }
        let cacheBytes = state.caches.reduce(UInt64(0)) { $0.adding(sizes[$1.id]) }
        total = cacheBytes.adding(outputBytes).adding(sizes[CleanupState.dockerDiskKey])
        let freeOutputs = state.buildOutputs.filter { users[$0.path] == nil }.reduce(UInt64(0)) {
            $0.adding(sizes[$1.path])
        }
        let freeCaches = state.caches.filter { $0.clean != nil && !Self.partialCleans.contains($0.id) }
            .reduce(UInt64(0)) { $0.adding(sizes[$1.id]) }
        cleanable = freeOutputs.adding(freeCaches).adding(docker.reclaimable)

        var named = Self.categories.map { category in
            MemorySegment(
                label: category.label, bytes: category.keys.reduce(UInt64(0)) { $0.adding(sizes[$1]) }, worktree: nil)
        }
        named.insert(MemorySegment(label: "Build outputs", bytes: outputBytes, worktree: nil), at: 2)
        let known = Set(Self.categories.flatMap(\.keys))
        let other = state.caches.filter { !known.contains($0.id) }.reduce(UInt64(0)) { $0.adding(sizes[$1.id]) }
        // Sorted with the order above breaking a tie, so that the bar does not reorder itself between two draws.
        bar = named.enumerated().filter { $0.element.bytes > 0 }
            .sorted { a, b in
                a.element.bytes == b.element.bytes ? a.offset < b.offset : a.element.bytes > b.element.bytes
            }
            .map(\.element) + (other > 0 ? [MemorySegment(label: "Other", bytes: other, worktree: nil)] : [])
    }

    /// The name of a process that runs in each output, or runs a file of it, by the path of the output. The groups are
    /// looked through in the order of their worktrees and pids, so the name does not change from one draw to the next.
    static func users(of outputs: [BuildOutput], in groups: [String: [ProcessGroup]]) -> [String: String] {
        guard !outputs.isEmpty else { return [:] }
        let processes = groups.sorted { $0.key < $1.key }.flatMap { $0.value.sorted { $0.id < $1.id } }
            .flatMap { [$0.leader] + $0.members }
        var users: [String: String] = [:]
        for output in outputs {
            let user = processes.first { process in
                [process.cwd, process.executablePath].contains { $0.map { isInside($0, output.path) } == true }
            }
            users[output.path] = user?.name
        }
        return users
    }
}

/// A row of the build outputs, the package caches or Xcode.
public struct CleanupRow: Identifiable, Equatable, Sendable {
    /// The path of a build output, or the id of a cache: what `CleanupState.sizes` and `working` know it by.
    public let id: String
    public let title: String
    /// The kind of a build output (`Rust build`), or the paths of a cache with `~` for the home folder, joined by
    /// ` · `.
    public let subtitle: String
    /// `nil` while it is measured.
    public let size: UInt64?
    /// `used by 34 projects`, `3 unavailable`.
    public let note: String?
    /// The title of the button: `Clean`, `Prune`, `Delete Unavailable`.
    public let action: String
    public let isEnabled: Bool
    /// Why the button is off: `In use by vite`, `Nothing to delete`, `No unavailable simulators`.
    public let disabledReason: String?
    /// Being cleaned now.
    public let isWorking: Bool

    init(_ output: BuildOutput, size: UInt64?, user: String?, state: CleanupState) {
        id = output.path
        title = output.title
        subtitle = output.kind
        self.size = size
        note = nil
        action = "Clean"
        isEnabled = user == nil
        disabledReason = user.map { "In use by \($0)" }
        isWorking = state.working.contains(output.path)
    }

    init(_ entry: CacheEntry, size: UInt64?, home: String, state: CleanupState) {
        id = entry.id
        title = entry.title
        subtitle = entry.paths.map { CachesPresenter.abbreviated($0, home: home) }.joined(separator: " · ")
        self.size = size
        note = entry.note
        action = entry.action
        isEnabled = entry.clean != nil
        disabledReason =
            entry.clean != nil ? nil : entry.id == "simulators" ? "No unavailable simulators" : "Nothing to delete"
        isWorking = state.working.contains(entry.id)
    }
}

/// The Docker card: which VM, whether it runs, its disk, and while it runs, what it holds.
public struct DockerSection: Equatable, Sendable {
    /// `nil` until Docker has been asked.
    public let status: DockerStatus?
    public let runtime: DockerRuntime?
    /// `colima · default`; `nil` without a runtime.
    public let title: String?
    /// `VM disk 20.5 GB of 100 GB · 4 CPU · 8 GB RAM`; `nil` without a runtime.
    public let line: String?
    /// What is wrong when there is no runtime to show: `Docker is not installed`, `Unknown Docker context <name>`,
    /// `Docker did not answer`. `nil` with a runtime, and before Docker has been asked.
    public let message: String?
    /// The disk of the VM on the host, in bytes, once it is measured.
    public let diskSize: UInt64?
    public let isRunning: Bool
    /// "Start and inspect" is under way.
    public let isStarting: Bool
    /// Images, Containers, Volumes and Build cache, while the VM runs and has said what it holds.
    public let rows: [DockerRow]
    public let containers: [DockerContainerLine]
    /// What "Remove Unused…" and "Remove Stopped…" remove, for the sheet that confirms it.
    public let unusedImages: [DockerImage]
    public let stoppedContainers: [DockerContainer]
    /// What the two would free, as far as Docker says: the unused images and what the stopped containers wrote. Images
    /// can share layers, so it may be less.
    let reclaimable: UInt64

    init(state: CleanupState) {
        status = state.docker
        if case .runtime(let runtime)? = state.docker { self.runtime = runtime } else { runtime = nil }
        diskSize = state.sizes[CleanupState.dockerDiskKey]
        title = runtime.map(CachesPresenter.dockerTitle)
        line = runtime.map { CachesPresenter.dockerLine($0, disk: state.sizes[CleanupState.dockerDiskKey]) }
        message = state.docker.flatMap(CachesPresenter.dockerProblem(with:))
        isRunning = runtime?.isRunning == true
        isStarting = state.working.contains(CleanupState.startDockerID)
        guard isRunning, let inventory = state.inventory else {
            (rows, containers, unusedImages, stoppedContainers, reclaimable) = ([], [], [], [], 0)
            return
        }
        unusedImages = inventory.images.filter(\.isUnused)
        stoppedContainers = inventory.containers.filter { !$0.isRunning }
        let unusedBytes = unusedImages.reduce(UInt64(0)) { $0.adding($1.size) }
        reclaimable = stoppedContainers.reduce(unusedBytes) { $0.adding($1.size) }
        let imageBytes = inventory.images.reduce(UInt64(0)) { $0.adding($1.size) }
        let running = inventory.containers.count - stoppedContainers.count
        let images = inventory.images.count == 1 ? "1 image" : "\(inventory.images.count) images"
        let unused = unusedImages.isEmpty ? nil : "\(CachesPresenter.disk(unusedBytes)) unused"
        rows = [
            DockerRow(
                id: CleanupState.unusedImagesID, title: "Images",
                detail: "\(images) · \(CachesPresenter.disk(imageBytes))", note: unused, action: "Remove Unused…",
                disabledReason: unusedImages.isEmpty ? "No unused images" : nil, state: state),
            DockerRow(
                id: CleanupState.stoppedContainersID, title: "Containers",
                detail: "\(running) running, \(stoppedContainers.count) stopped", note: nil,
                action: "Remove Stopped…", disabledReason: stoppedContainers.isEmpty ? "No stopped containers" : nil,
                state: state),
            DockerRow(
                id: "volumes", title: "Volumes", detail: CachesPresenter.disk(inventory.volumesSize), note: nil,
                action: nil, disabledReason: nil, state: state),
            DockerRow(
                id: "build-cache", title: "Build cache", detail: CachesPresenter.disk(inventory.buildCacheSize),
                note: nil, action: nil, disabledReason: nil, state: state),
        ]
        containers = inventory.containers.map(DockerContainerLine.init)
    }
}

/// A line of what the VM holds. Volumes and the build cache are shown, never cleaned: they have no `action`.
public struct DockerRow: Identifiable, Equatable, Sendable {
    /// `CleanupState.unusedImagesID`, `CleanupState.stoppedContainersID`, `volumes` or `build-cache`.
    public let id: String
    public let title: String
    /// `4 images · 18.7 GB`, `2 running, 3 stopped`, `7.9 GB`.
    public let detail: String
    /// `5.4 GB unused`.
    public let note: String?
    public let action: String?
    public let isEnabled: Bool
    public let disabledReason: String?
    public let isWorking: Bool

    init(
        id: String, title: String, detail: String, note: String?, action: String?, disabledReason: String?,
        state: CleanupState
    ) {
        self.id = id
        self.title = title
        self.detail = detail
        self.note = note
        self.action = action
        isEnabled = action != nil && disabledReason == nil
        self.disabledReason = disabledReason
        isWorking = state.working.contains(id)
    }
}

/// A container in the list under the Docker card.
public struct DockerContainerLine: Identifiable, Equatable, Sendable {
    public let id: String
    public let name: String
    public let image: String
    /// The name of the folder of its compose project, or `—`.
    public let project: String
    public let isRunning: Bool

    init(_ container: DockerContainer) {
        id = container.id
        name = container.name
        image = container.image
        project = container.project.map { ($0 as NSString).lastPathComponent } ?? "—"
        isRunning = container.isRunning
    }
}

/// The words of the Caches and Docker page that are not a row's own.
public enum CachesPresenter {
    /// `("113 GB", "in caches, toolchains and VMs · about 70 GB can be cleaned safely")`. With nothing to clean, the
    /// detail is the first part alone.
    public static func headline(_ page: CachesPage) -> (total: String, detail: String) {
        let detail = "in caches, toolchains and VMs"
        guard page.cleanable > 0 else { return (amount(page.total), detail) }
        return (amount(page.total), detail + " · about \(amount(page.cleanable)) can be cleaned safely")
    }

    /// `VM disk 20.5 GB of 100 GB · 4 CPU · 8 GB RAM`, with what is not known left out: `VM disk 20.5 GB`, and
    /// `VM disk of 100 GB` while the disk is being measured.
    public static func dockerLine(_ runtime: DockerRuntime, disk: UInt64?) -> String {
        var first = "VM disk"
        if let disk { first += " " + self.disk(disk) }
        if let limit = runtime.diskLimit { first += " of " + binary(limit) }
        var parts = [first]
        if let cpus = runtime.cpus { parts.append("\(cpus) CPU") }
        if let memory = runtime.memory { parts.append(binary(memory) + " RAM") }
        return parts.joined(separator: " · ")
    }

    /// `colima · default`, `Docker Desktop` or `OrbStack`.
    public static func dockerTitle(_ runtime: DockerRuntime) -> String {
        switch runtime.kind {
        case .colima: "colima · \(runtime.profile ?? "default")"
        case .desktop: "Docker Desktop"
        case .orbstack: "OrbStack"
        }
    }

    /// What the Docker card says instead of a VM (Ruling 4); `nil` for a runtime.
    public static func dockerProblem(with status: DockerStatus) -> String? {
        switch status {
        case .notInstalled: "Docker is not installed"
        case .unknownContext(let name): "Unknown Docker context \(name)"
        case .notAnswering: "Docker did not answer"
        case .runtime: nil
        }
    }

    /// What went wrong, for the alert that says it, the one place where errors become words. A refusal of the catalog
    /// or the finder names a path or an id, which says nothing to the user; the walk for repositories names what it
    /// found, and that is said as it is.
    public static func message(for error: any Error) -> String {
        switch error {
        case CleanupError.failed(let text): return text
        case CleanupError.pathEscapes(let path):
            return "\(path) leads outside the folder it belongs to, so nothing was deleted."
        case CleanupError.notEligible(let detail):
            guard !detail.hasPrefix("/"), detail.contains(" ") else {
                return "It can no longer be cleaned safely, so nothing was deleted."
            }
            return detail.prefix(1).uppercased() + detail.dropFirst() + "."
        case let error as DockerError: return error.message
        default: return error.localizedDescription
        }
    }

    /// `path` with `~` for `home`.
    public static func abbreviated(_ path: String, home: String) -> String {
        guard !home.isEmpty, home != "/", isInside(path, home) else { return path }
        return "~" + path.dropFirst(home.count)
    }

    static func disk(_ bytes: UInt64) -> String { SizeFormat.disk(Int64(clamping: bytes)) }

    /// A size in round gigabytes from 10 GB, where a tenth says nothing: `113 GB`, `70 GB`; below, `4.4 GB`.
    private static func amount(_ bytes: UInt64) -> String {
        let tenths = bytes / 100_000_000 + (bytes % 100_000_000 >= 50_000_000 ? 1 : 0)
        guard tenths >= 100 else { return disk(bytes) }
        return "\(bytes / 1_000_000_000 + (bytes % 1_000_000_000 >= 500_000_000 ? 1 : 0)) GB"
    }

    /// What colima was given, which it counts in binary units: `100 GB`, `8 GB`, `1.5 GB`.
    private static func binary(_ bytes: UInt64) -> String {
        let text = SizeFormat.memory(bytes)
        return text.hasSuffix(".0 GB") ? String(text.dropLast(5)) + " GB" : text
    }
}

extension UInt64 {
    /// The sum with `other`, nothing for `nil`, or the largest number when it would not fit.
    fileprivate func adding(_ other: UInt64?) -> UInt64 {
        let (sum, overflow) = addingReportingOverflow(other ?? 0)
        return overflow ? .max : sum
    }
}
