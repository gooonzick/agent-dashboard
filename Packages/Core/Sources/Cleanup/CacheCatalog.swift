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

    /// Cleaning is partial when it stops half way: what was deleted before an error stays deleted, which is fine for a
    /// cache. The paths are resolved and checked right before, and the deletes go through the resolved paths; a
    /// symlink swapped in between the check and the delete is a window that stays open, accepted for a tool that one
    /// person runs on their own machine.
    public func clean(_ entry: CacheEntry) async throws {
        guard let clean = entry.clean else { throw CleanupError.notEligible(entry.id) }
        switch clean {
        case .command(let tool, let args):
            // What runs is fixed by the id, not read from the entry, so an entry that was altered cannot run anything
            // else.
            guard Self.expectedCommand(of: entry.id) == clean else { throw CleanupError.notEligible(entry.id) }
            try await run(tool, args)
        case .deleteContents(let folder):
            guard let root = expectedRoot(of: entry.id) else { throw CleanupError.notEligible(entry.id) }
            let target = try check(folder, within: root)
            do {
                for child in try fileManager.contentsOfDirectory(atPath: target) {
                    try fileManager.removeItem(atPath: target + "/" + child)
                }
            } catch {
                throw CleanupError.failed(error.localizedDescription)
            }
        case .deleteFolders(let folders):
            guard entry.id == "pnpm-old" else { throw CleanupError.notEligible(entry.id) }
            guard let store = await pnpmStore() else { throw CleanupError.failed("pnpm did not say where its store is") }
            let root = (store as NSString).deletingLastPathComponent
            let current = canonicalPath(store)
            // Everything is checked before the first folder goes, so a bad one leaves all of them in place.
            var targets: [String] = []
            for folder in folders {
                let target = try check(folder, within: root)
                // Strictly inside the folder of the stores, named like one, and neither the current store nor a
                // folder that holds it or lies in it (the current store may itself be a symlink into an old one).
                guard Self.isStoreVersion((target as NSString).lastPathComponent),
                    Self.isStoreVersion((folder as NSString).lastPathComponent),
                    (target as NSString).deletingLastPathComponent == canonicalPath(root),
                    !Self.isInside(target, current), !Self.isInside(current, target)
                else { throw CleanupError.notEligible(folder) }
                targets.append(target)
            }
            do {
                for target in targets { try fileManager.removeItem(atPath: target) }
            } catch {
                throw CleanupError.failed(error.localizedDescription)
            }
        }
    }

    // MARK: - Paths

    private func exists(_ path: String) -> Bool {
        var isFolder: ObjCBool = false
        return fileManager.fileExists(atPath: path, isDirectory: &isFolder) && isFolder.boolValue
    }

    /// What each entry that is cleaned by a command runs.
    private static func expectedCommand(of id: String) -> CacheClean? {
        switch id {
        case "pnpm": return .command(tool: "pnpm", args: ["store", "prune"])
        case "homebrew": return .command(tool: "brew", args: ["cleanup", "--prune=all", "-s"])
        case "go": return .command(tool: "go", args: ["clean", "-modcache", "-cache"])
        case "simulators": return .command(tool: "xcrun", args: ["simctl", "delete", "unavailable"])
        default: return nil
        }
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

    /// `path` as the file system resolves it, when it equals `root` or lies inside it and lies inside `home`; refuses
    /// otherwise. A symlink anywhere on the way that leads out makes the resolved path leave, and a path that cannot
    /// be resolved is refused too: a delete does not go ahead on a guess.
    private func check(_ path: String, within root: String) throws -> String {
        guard let target = Self.resolved(path), let root = Self.resolved(root), let home = Self.resolved(home.path),
            Self.isInside(target, root), Self.isInside(target, home)
        else { throw CleanupError.pathEscapes(path) }
        return target
    }

    private static func resolved(_ path: String) -> String? {
        guard let resolved = realpath(path, nil) else { return nil }
        defer { free(resolved) }
        return String(cString: resolved)
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
        // pnpm may print a warning before the path.
        let line = result.stdout.split(whereSeparator: \.isNewline).last { !$0.allSatisfy(\.isWhitespace) }
        return line.map { $0.trimmingCharacters(in: .whitespaces) }
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
