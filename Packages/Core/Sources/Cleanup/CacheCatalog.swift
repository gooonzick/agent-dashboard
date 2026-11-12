import CoreModels
import Foundation
import Shell

public enum CacheGroup: String, Sendable { case packages, xcode }

/// How a cache is cleaned.
public enum CacheClean: Sendable, Equatable {
    /// Through the runner, with a timeout of 600 s.
    case command(tool: String, args: [String])
    /// Everything inside the folder; the folder stays, because the tool that owns it expects it.
    case deleteContents(of: String)
    /// These folders, whole.
    case deleteFolders([String])
}

public struct CacheEntry: Sendable, Equatable, Identifiable {
    /// `pnpm`, `pnpm-old`, `homebrew`, `go`, `npm`, `playwright`, `cocoapods`, `derived-data` or `simulators`.
    public let id: String
    public let group: CacheGroup
    public let title: String
    /// What to measure; the size of the entry is their sum.
    public let paths: [String]
    /// What the page says next to the size: `used by 34 projects`, `3 unavailable`.
    public let note: String?
    /// The title of the button: `Prune`, `Clean` or `Delete Unavailable`.
    public let action: String
    /// `nil` when there is nothing to clean: the button is disabled and its help says why.
    public let clean: CacheClean?

    public init(
        id: String, group: CacheGroup, title: String, paths: [String], note: String?, action: String,
        clean: CacheClean?
    ) {
        self.id = id
        self.group = group
        self.title = title
        self.paths = paths
        self.note = note
        self.action = action
        self.clean = clean
    }
}

public protocol CacheCataloging: Sendable {
    /// The known caches that are on this machine: the ones whose folder exists and whose tool, if cleaning needs one,
    /// is installed.
    func entries(projectsUsingPnpm: Int) async -> [CacheEntry]
    /// Checks the paths of `entry` again, right before acting, and then cleans it.
    func clean(_ entry: CacheEntry) async throws
}

public enum CleanupError: Error, Equatable {
    /// The path leads outside the folder the cache lives in or outside the home folder, for instance through a
    /// symlink. Nothing was deleted.
    case pathEscapes(String)
    /// There is nothing to clean in this, or it is not something that may be cleaned.
    case notEligible(String)
    /// The first line of what the tool said, or what stopped it from running.
    case failed(String)
}

/// The package manager and Xcode caches Agent Dashboard knows, where each lives, and how each is cleaned safely: with
/// the tool that owns it where there is one, and otherwise by deleting inside a folder that was checked to be the one
/// that is meant.
///
/// `@unchecked Sendable`: `FileManager` is the only stored value that is not, and it has no delegate here, which makes
/// its methods safe to call from any thread.
public struct CacheCatalog: CacheCataloging, @unchecked Sendable {
    private static let queryTimeout: Duration = .seconds(15)
    private static let simulatorTimeout: Duration = .seconds(30)
    private static let cleanTimeout: Duration = .seconds(600)

    private let runner: any CommandRunning
    private let home: URL
    private let fileManager: FileManager

    public init(runner: any CommandRunning, home: URL, fileManager: FileManager = .default) {
        self.runner = runner
        self.home = home
        self.fileManager = fileManager
    }

    public func entries(projectsUsingPnpm: Int) async -> [CacheEntry] {
        var entries: [CacheEntry] = []
        if let store = await pnpmStore() {
            if exists(store) {
                entries.append(
                    CacheEntry(
                        id: "pnpm", group: .packages, title: "pnpm store", paths: [store],
                        note: projectsUsingPnpm > 0 ? "used by \(projectsUsingPnpm) projects" : nil, action: "Prune",
                        clean: .command(tool: "pnpm", args: ["store", "prune"])))
            }
            let old = Self.oldStores(besides: store, fileManager: fileManager)
            if !old.isEmpty {
                entries.append(
                    CacheEntry(
                        id: "pnpm-old", group: .packages, title: "Old pnpm stores", paths: old, note: nil,
                        action: "Clean", clean: .deleteFolders(old)))
            }
        }
        let library = home.path + "/Library"
        let known: [(id: String, group: CacheGroup, title: String, paths: [String], clean: CacheClean)] = [
            (
                "homebrew", .packages, "Homebrew", [library + "/Caches/Homebrew"],
                .command(tool: "brew", args: ["cleanup", "--prune=all", "-s"])
            ),
            (
                "go", .packages, "Go modules and build cache", [home.path + "/go/pkg/mod", library + "/Caches/go-build"],
                .command(tool: "go", args: ["clean", "-modcache", "-cache"])
            ),
            ("npm", .packages, "npm", [home.path + "/.npm/_cacache"], .deleteContents(of: home.path + "/.npm/_cacache")),
            (
                "playwright", .packages, "Playwright browsers", [library + "/Caches/ms-playwright"],
                .deleteContents(of: library + "/Caches/ms-playwright")
            ),
            (
                "cocoapods", .packages, "CocoaPods", [library + "/Caches/CocoaPods"],
                .deleteContents(of: library + "/Caches/CocoaPods")
            ),
            (
                "derived-data", .xcode, "DerivedData", [library + "/Developer/Xcode/DerivedData"],
                .deleteContents(of: library + "/Developer/Xcode/DerivedData")
            ),
        ]
        for cache in known {
            let present = cache.paths.filter(exists)
            if present.isEmpty { continue }
            if case .command(let tool, _) = cache.clean, runner.which(tool) == nil { continue }
            entries.append(
                CacheEntry(
                    id: cache.id, group: cache.group, title: cache.title, paths: present, note: nil, action: "Clean",
                    clean: cache.clean))
        }
        let devices = library + "/Developer/CoreSimulator/Devices"
        if exists(devices) {
            let unavailable = await unavailableSimulators()
            entries.append(
                CacheEntry(
                    id: "simulators", group: .xcode, title: "Simulators", paths: [devices],
                    note: unavailable > 0 ? "\(unavailable) unavailable" : nil, action: "Delete Unavailable",
                    clean: unavailable > 0 ? .command(tool: "xcrun", args: ["simctl", "delete", "unavailable"]) : nil))
        }
        return entries
    }

    public func clean(_ entry: CacheEntry) async throws {
        guard let clean = entry.clean else { throw CleanupError.notEligible(entry.id) }
        switch clean {
        case .command(let tool, let args):
            try await run(tool, args)
        case .deleteContents(let folder):
            guard let root = expectedRoot(of: entry.id) else { throw CleanupError.notEligible(entry.id) }
            try check(folder, within: root)
            for child in try fileManager.contentsOfDirectory(atPath: folder) {
                try fileManager.removeItem(atPath: folder + "/" + child)
            }
        case .deleteFolders(let folders):
            guard entry.id == "pnpm-old" else { throw CleanupError.notEligible(entry.id) }
            guard let store = await pnpmStore() else { throw CleanupError.failed("pnpm did not say where its store is") }
            let root = (store as NSString).deletingLastPathComponent
            let current = canonicalPath(store)
            // Everything is checked before the first folder goes, so a bad one leaves all of them in place.
            for folder in folders {
                guard Self.isStoreVersion((folder as NSString).lastPathComponent) else {
                    throw CleanupError.notEligible(folder)
                }
                try check(folder, within: root)
                let canonical = canonicalPath(folder)
                if canonical == current || canonical.hasPrefix(current + "/") { throw CleanupError.notEligible(folder) }
            }
            for folder in folders { try fileManager.removeItem(atPath: folder) }
        }
    }

    // MARK: - Paths

    private func exists(_ path: String) -> Bool {
        var isFolder: ObjCBool = false
        return fileManager.fileExists(atPath: path, isDirectory: &isFolder) && isFolder.boolValue
    }

    /// The folder a delete-based entry has to stay inside. It is fixed by the entry, not read from it, so an entry
    /// that was altered cannot name another one.
    private func expectedRoot(of id: String) -> String? {
        let library = home.path + "/Library"
        switch id {
        case "npm": return home.path + "/.npm/_cacache"
        case "playwright": return library + "/Caches/ms-playwright"
        case "cocoapods": return library + "/Caches/CocoaPods"
        case "derived-data": return library + "/Developer/Xcode/DerivedData"
        default: return nil
        }
    }

    /// Refuses unless `path` as the file system resolves it equals `root` or lies inside it, and lies inside `home`.
    /// A symlink anywhere on the way that leads out makes the resolved path leave, and so is refused.
    private func check(_ path: String, within root: String) throws {
        let target = canonicalPath(path)
        guard Self.isInside(target, canonicalPath(root)), Self.isInside(target, canonicalPath(home.path)) else {
            throw CleanupError.pathEscapes(path)
        }
    }

    private static func isInside(_ path: String, _ root: String) -> Bool {
        path == root || path.hasPrefix(root + "/")
    }

    // MARK: - pnpm

    /// The store pnpm uses now, or `nil` without pnpm or when it does not say.
    private func pnpmStore() async -> String? {
        guard runner.which("pnpm") != nil,
            let result = try? await runner.run("pnpm", ["store", "path"], in: nil, timeout: Self.queryTimeout),
            result.exitCode == 0
        else { return nil }
        let path = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        return path.isEmpty ? nil : path
    }

    /// `v` and digits: the folders pnpm names after the version of its store.
    private static func isStoreVersion(_ name: String) -> Bool {
        name.wholeMatch(of: /v[0-9]+/) != nil
    }

    /// The stores of other versions next to `store`, which is never among them.
    private static func oldStores(besides store: String, fileManager: FileManager) -> [String] {
        let parent = (store as NSString).deletingLastPathComponent
        let current = (store as NSString).lastPathComponent
        let names = (try? fileManager.contentsOfDirectory(atPath: parent)) ?? []
        return names.filter { isStoreVersion($0) && $0 != current }.sorted().map { parent + "/" + $0 }
            .filter { path in
                var isFolder: ObjCBool = false
                return fileManager.fileExists(atPath: path, isDirectory: &isFolder) && isFolder.boolValue
            }
    }

    // MARK: - Commands

    /// The number of devices `simctl` lists as unavailable, over all runtimes; 0 when it cannot say.
    private func unavailableSimulators() async -> Int {
        guard runner.which("xcrun") != nil,
            let result = try? await runner.run(
                "xcrun", ["simctl", "list", "devices", "unavailable", "-j"], in: nil, timeout: Self.simulatorTimeout),
            result.exitCode == 0,
            let json = (try? JSONSerialization.jsonObject(with: Data(result.stdout.utf8))) as? [String: Any],
            let runtimes = json["devices"] as? [String: Any]
        else { return 0 }
        return runtimes.values.reduce(0) { $0 + (($1 as? [Any])?.count ?? 0) }
    }

    private func run(_ tool: String, _ args: [String]) async throws {
        let result: CommandResult
        do {
            result = try await runner.run(tool, args, in: nil, timeout: Self.cleanTimeout)
        } catch CommandError.notFound(let missing) {
            throw CleanupError.failed("\(missing) is not installed")
        } catch CommandError.timedOut(let slow) {
            throw CleanupError.failed("\(slow) did not finish in time")
        }
        guard result.exitCode == 0 else {
            throw CleanupError.failed(
                firstErrorLine(in: result.stderr) ?? "\(tool) failed with exit code \(result.exitCode)")
        }
    }
}
