import CoreModels
import Foundation
import Testing
import TestSupport

@testable import Cleanup
@testable import Shell

private func simctlUnavailable() throws -> String {
    let url = try #require(
        Bundle.module.url(
            forResource: "simctl-unavailable", withExtension: "json", subdirectory: "Fixtures/caches"))
    return try String(contentsOf: url, encoding: .utf8)
}

private let noDevices = ok(#"{"devices":{}}"#)

/// A home with the folders of every cache in it, and the pnpm store of the current version with an older one next to it.
private struct Machine {
    let dir: TempDir
    let home: URL
    let store: String
    let oldStore: String

    init() throws {
        dir = try TempDir(named: "home")
        home = dir.url
        store = home.path + "/Library/pnpm/store/v11"
        oldStore = home.path + "/Library/pnpm/store/v10"
        for path in [
            store, oldStore, home.path + "/Library/pnpm/store/v3", home.path + "/Library/Caches/Homebrew",
            home.path + "/go/pkg/mod", home.path + "/Library/Caches/go-build", home.path + "/.npm/_cacache",
            home.path + "/Library/Caches/ms-playwright", home.path + "/Library/Caches/CocoaPods",
            home.path + "/Library/Developer/Xcode/DerivedData", home.path + "/Library/Developer/CoreSimulator/Devices",
        ] {
            try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        }
        // Not a store: a file in the folder of the stores, and a folder whose name is not `v<digits>`.
        try Data().write(to: URL(filePath: home.path + "/Library/pnpm/store/v9"))
        try FileManager.default.createDirectory(
            atPath: home.path + "/Library/pnpm/store/vendor", withIntermediateDirectories: true)
    }

    var tools: Set<String> { ["pnpm", "brew", "go", "xcrun"] }

    /// What every tool prints on this machine: the store path and two unavailable simulators.
    func answers(simulators: CommandResult? = nil) throws -> [String: CommandResult] {
        [
            "pnpm store path": ok(store + "\n"),
            "xcrun simctl list devices unavailable -j": try simulators ?? ok(simctlUnavailable()),
        ]
    }

    func catalog(_ runner: FakeDocker) -> CacheCatalog { CacheCatalog(runner: runner, home: home) }

    func path(_ relative: String) -> String { home.path + "/" + relative }
}

@Suite("CacheCatalog")
struct CacheCatalogTests {
    @Test func theCatalogIsExactlyThis() async throws {
        let machine = try Machine()
        let runner = FakeDocker(installed: machine.tools, answers: try machine.answers())

        let entries = await machine.catalog(runner).entries(projectsUsingPnpm: 34)

        struct Row: Equatable {
            let id: String
            let group: CacheGroup
            let title: String
            let paths: [String]
            let action: String
            let clean: CacheClean?
        }
        let home = machine.home.path
        let expected = [
            Row(
                id: "pnpm", group: .packages, title: "pnpm store", paths: [machine.store], action: "Prune",
                clean: .command(tool: "pnpm", args: ["store", "prune"])),
            Row(
                id: "pnpm-old", group: .packages, title: "Old pnpm stores",
                paths: [home + "/Library/pnpm/store/v10", home + "/Library/pnpm/store/v3"], action: "Clean",
                clean: .deleteFolders([home + "/Library/pnpm/store/v10", home + "/Library/pnpm/store/v3"])),
            Row(
                id: "homebrew", group: .packages, title: "Homebrew", paths: [home + "/Library/Caches/Homebrew"],
                action: "Clean", clean: .command(tool: "brew", args: ["cleanup", "--prune=all", "-s"])),
            Row(
                id: "go", group: .packages, title: "Go modules and build cache",
                paths: [home + "/go/pkg/mod", home + "/Library/Caches/go-build"], action: "Clean",
                clean: .command(tool: "go", args: ["clean", "-modcache", "-cache"])),
            Row(
                id: "npm", group: .packages, title: "npm", paths: [home + "/.npm/_cacache"], action: "Clean",
                clean: .deleteContents(of: home + "/.npm/_cacache")),
            Row(
                id: "playwright", group: .packages, title: "Playwright browsers",
                paths: [home + "/Library/Caches/ms-playwright"], action: "Clean",
                clean: .deleteContents(of: home + "/Library/Caches/ms-playwright")),
            Row(
                id: "cocoapods", group: .packages, title: "CocoaPods", paths: [home + "/Library/Caches/CocoaPods"],
                action: "Clean", clean: .deleteContents(of: home + "/Library/Caches/CocoaPods")),
            Row(
                id: "derived-data", group: .xcode, title: "DerivedData",
                paths: [home + "/Library/Developer/Xcode/DerivedData"], action: "Clean",
                clean: .deleteContents(of: home + "/Library/Developer/Xcode/DerivedData")),
            Row(
                id: "simulators", group: .xcode, title: "Simulators",
                paths: [home + "/Library/Developer/CoreSimulator/Devices"], action: "Delete Unavailable",
                clean: .command(tool: "xcrun", args: ["simctl", "delete", "unavailable"])),
        ]
        let actual = entries.map {
            Row(id: $0.id, group: $0.group, title: $0.title, paths: $0.paths, action: $0.action, clean: $0.clean)
        }
        #expect(actual == expected)
    }

    @Test func onlyWhatExistsIsListed() async throws {
        let machine = try Machine()
        try FileManager.default.removeItem(atPath: machine.path("Library/Caches/CocoaPods"))
        try FileManager.default.removeItem(atPath: machine.path(".npm/_cacache"))
        let runner = FakeDocker(installed: machine.tools, answers: try machine.answers())

        let ids = await machine.catalog(runner).entries(projectsUsingPnpm: 0).map(\.id)

        #expect(!ids.contains("cocoapods"))
        #expect(!ids.contains("npm"))
        #expect(ids.contains("playwright"))
    }

    @Test func anEntryThatNeedsAToolIsNotListedWithoutIt() async throws {
        let machine = try Machine()
        let runner = FakeDocker(installed: [], answers: [:])

        let ids = await machine.catalog(runner).entries(projectsUsingPnpm: 0).map(\.id)

        // The ones that are only a folder to empty do not need a tool; the rest do.
        #expect(ids == ["npm", "playwright", "cocoapods", "derived-data", "simulators"])
        let simulators = await machine.catalog(runner).entries(projectsUsingPnpm: 0).last
        #expect(simulators?.clean == nil)
    }

    @Test func noStoreIsListedWhenPnpmDoesNotSayWhereItIs() async throws {
        let machine = try Machine()
        let runner = FakeDocker(installed: machine.tools, answers: [:])

        let ids = await machine.catalog(runner).entries(projectsUsingPnpm: 0).map(\.id)

        #expect(!ids.contains("pnpm"))
        #expect(!ids.contains("pnpm-old"))
    }

    @Test func noOldStoresMeansNoEntryForThem() async throws {
        let machine = try Machine()
        for name in ["v10", "v3"] {
            try FileManager.default.removeItem(atPath: machine.path("Library/pnpm/store/\(name)"))
        }
        let runner = FakeDocker(installed: machine.tools, answers: try machine.answers())

        let ids = await machine.catalog(runner).entries(projectsUsingPnpm: 0).map(\.id)

        #expect(ids.contains("pnpm"))
        #expect(!ids.contains("pnpm-old"))
    }

    @Test func theNotesSayWhoUsesItAndWhatIsUnavailable() async throws {
        let machine = try Machine()
        let runner = FakeDocker(installed: machine.tools, answers: try machine.answers())

        let used = await machine.catalog(runner).entries(projectsUsingPnpm: 34)
        let unused = await machine.catalog(runner).entries(projectsUsingPnpm: 0)

        #expect(used.first { $0.id == "pnpm" }?.note == "used by 34 projects")
        #expect(unused.first { $0.id == "pnpm" }?.note == nil)
        #expect(used.first { $0.id == "simulators" }?.note == "2 unavailable")
    }

    @Test func withNoUnavailableSimulatorsThereIsNothingToDelete() async throws {
        let machine = try Machine()
        let runner = FakeDocker(installed: machine.tools, answers: try machine.answers(simulators: noDevices))

        let entries = await machine.catalog(runner).entries(projectsUsingPnpm: 0)

        let simulators = try #require(entries.first { $0.id == "simulators" })
        #expect(simulators.note == nil)
        #expect(simulators.clean == nil)
    }

    @Test func deleteContentsKeepsTheFolder() async throws {
        let machine = try Machine()
        let cache = machine.path(".npm/_cacache")
        try FileManager.default.createDirectory(atPath: cache + "/content-v2/sha512", withIntermediateDirectories: true)
        try Data("x".utf8).write(to: URL(filePath: cache + "/index"))
        let runner = FakeDocker(installed: machine.tools, answers: try machine.answers())
        let catalog = machine.catalog(runner)
        let npm = try #require(await catalog.entries(projectsUsingPnpm: 0).first { $0.id == "npm" })

        try await catalog.clean(npm)

        var isFolder: ObjCBool = false
        #expect(FileManager.default.fileExists(atPath: cache, isDirectory: &isFolder) && isFolder.boolValue)
        #expect(try FileManager.default.contentsOfDirectory(atPath: cache).isEmpty)
        #expect(runner.calls.allSatisfy { !$0.line.hasPrefix("npm") })
    }

    @Test func aCommandRunsThroughTheRunnerWithALongTimeout() async throws {
        let machine = try Machine()
        var answers = try machine.answers()
        answers["brew cleanup --prune=all -s"] = ok("")
        let runner = FakeDocker(installed: machine.tools, answers: answers)
        let catalog = machine.catalog(runner)
        let brew = try #require(await catalog.entries(projectsUsingPnpm: 0).first { $0.id == "homebrew" })

        try await catalog.clean(brew)

        #expect(runner.calls.last == Call(line: "brew cleanup --prune=all -s", timeout: .seconds(600)))
    }

    @Test func aCacheThatBecameASymlinkOutsideIsNotCleaned() async throws {
        let machine = try Machine()
        let outside = try TempDir(named: "elsewhere")
        let precious = outside.url.appending(path: "keep.txt")
        try Data("x".utf8).write(to: precious)
        let runner = FakeDocker(installed: machine.tools, answers: try machine.answers())
        let catalog = machine.catalog(runner)
        let playwright = try #require(await catalog.entries(projectsUsingPnpm: 0).first { $0.id == "playwright" })
        let link = machine.path("Library/Caches/ms-playwright")
        try FileManager.default.removeItem(atPath: link)
        try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: outside.url.path)

        await #expect(throws: CleanupError.pathEscapes(link)) { try await catalog.clean(playwright) }

        #expect(FileManager.default.fileExists(atPath: precious.path))
    }

    @Test func anEntryThatPointsOutsideItsOwnFolderIsNotCleaned() async throws {
        let machine = try Machine()
        let documents = machine.path("Documents")
        try FileManager.default.createDirectory(atPath: documents, withIntermediateDirectories: true)
        let precious = documents + "/keep.txt"
        try Data("x".utf8).write(to: URL(filePath: precious))
        let runner = FakeDocker(installed: machine.tools, answers: [:])
        let forged = CacheEntry(
            id: "npm", group: .packages, title: "npm", paths: [documents], note: nil, action: "Clean",
            clean: .deleteContents(of: documents))

        await #expect(throws: CleanupError.pathEscapes(documents)) { try await machine.catalog(runner).clean(forged) }

        #expect(FileManager.default.fileExists(atPath: precious))
    }

    @Test func anEntryWithNothingToCleanIsNotEligible() async throws {
        let machine = try Machine()
        let runner = FakeDocker(installed: machine.tools, answers: try machine.answers(simulators: noDevices))
        let catalog = machine.catalog(runner)
        let simulators = try #require(await catalog.entries(projectsUsingPnpm: 0).first { $0.id == "simulators" })

        await #expect(throws: CleanupError.notEligible("simulators")) { try await catalog.clean(simulators) }
    }

    @Test func oldPnpmStoresAreDeletedAndTheCurrentOneNever() async throws {
        let machine = try Machine()
        let runner = FakeDocker(installed: machine.tools, answers: try machine.answers())
        let catalog = machine.catalog(runner)
        let old = try #require(await catalog.entries(projectsUsingPnpm: 0).first { $0.id == "pnpm-old" })

        try await catalog.clean(old)

        #expect(!FileManager.default.fileExists(atPath: machine.oldStore))
        #expect(!FileManager.default.fileExists(atPath: machine.path("Library/pnpm/store/v3")))
        #expect(FileManager.default.fileExists(atPath: machine.store))
        #expect(FileManager.default.fileExists(atPath: machine.path("Library/pnpm/store/vendor")))
    }

    @Test func theCurrentPnpmStoreIsRefusedEvenWhenAskedFor() async throws {
        let machine = try Machine()
        let runner = FakeDocker(installed: machine.tools, answers: try machine.answers())
        let forged = CacheEntry(
            id: "pnpm-old", group: .packages, title: "Old pnpm stores", paths: [machine.store], note: nil,
            action: "Clean", clean: .deleteFolders([machine.store]))

        await #expect(throws: CleanupError.notEligible(machine.store)) {
            try await machine.catalog(runner).clean(forged)
        }

        #expect(FileManager.default.fileExists(atPath: machine.store))
    }

    @Test func anOldPnpmStoreThatIsASymlinkOutsideIsNotDeleted() async throws {
        let machine = try Machine()
        let outside = try TempDir(named: "elsewhere")
        try Data("x".utf8).write(to: outside.url.appending(path: "keep.txt"))
        try FileManager.default.removeItem(atPath: machine.oldStore)
        try FileManager.default.createSymbolicLink(atPath: machine.oldStore, withDestinationPath: outside.url.path)
        let runner = FakeDocker(installed: machine.tools, answers: try machine.answers())
        let forged = CacheEntry(
            id: "pnpm-old", group: .packages, title: "Old pnpm stores", paths: [machine.oldStore], note: nil,
            action: "Clean", clean: .deleteFolders([machine.oldStore]))

        await #expect(throws: CleanupError.pathEscapes(machine.oldStore)) {
            try await machine.catalog(runner).clean(forged)
        }

        #expect(FileManager.default.fileExists(atPath: outside.url.appending(path: "keep.txt").path))
    }

    @Test func aFailedCommandSaysWhatTheToolSaid() async throws {
        let machine = try Machine()
        var answers = try machine.answers()
        answers["brew cleanup --prune=all -s"] = CommandResult(
            exitCode: 1, stdout: "", stderr: "Error: Permission denied @ apply2files\nmore\n")
        let runner = FakeDocker(installed: machine.tools, answers: answers)
        let catalog = machine.catalog(runner)
        let brew = try #require(await catalog.entries(projectsUsingPnpm: 0).first { $0.id == "homebrew" })

        await #expect(throws: CleanupError.failed("Error: Permission denied @ apply2files")) {
            try await catalog.clean(brew)
        }
    }
}
