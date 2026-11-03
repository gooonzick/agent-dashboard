import CoreModels
@testable import Dashboard
import Discovery
import Foundation
import TestSupport
import Testing

/// The Scan tab: what it lists, and what its buttons write and ask of the store.
@MainActor
@Suite struct ScanSettingsModelTests {
    @Test func listsTheExclusionsAndTheSwitchAsTheSettingsHaveThem() throws {
        let scene = try Scene()
        scene.settings.rules = ExclusionRules(excludedPaths: ["/b", "/a"], includeExternalVolumes: true)

        let model = ScanSettingsModel(store: scene.makeStore())

        #expect(model.excludedPaths == ["/b", "/a"])
        #expect(model.includesExternalVolumes)
    }

    @Test func addingAndRemovingAnExclusionSavesAtOnce() throws {
        let scene = try Scene()
        scene.settings.rules = ExclusionRules(excludedPaths: ["/a"])
        let model = ScanSettingsModel(store: scene.makeStore())

        model.exclude("/Users/x/Work/old/")
        model.exclude("/Users/x/Work/old")  // the same folder
        model.exclude("relative/path")  // not a folder of the disk
        model.exclude("/")  // all of it
        model.exclude("  ")

        #expect(scene.settings.rules.excludedPaths == ["/a", "/Users/x/Work/old"])
        #expect(model.excludedPaths == ["/a", "/Users/x/Work/old"])

        model.removeExclusion("/a")

        #expect(scene.settings.rules.excludedPaths == ["/Users/x/Work/old"])
        #expect(model.excludedPaths == ["/Users/x/Work/old"])
    }

    @Test func theSwitchForExternalDrivesSavesAtOnceAndKeepsTheFolders() throws {
        let scene = try Scene()
        scene.settings.rules = ExclusionRules(excludedPaths: ["/a"])
        let model = ScanSettingsModel(store: scene.makeStore())

        model.setIncludesExternalVolumes(true)

        #expect(scene.settings.rules == ExclusionRules(excludedPaths: ["/a"], includeExternalVolumes: true))
        #expect(model.includesExternalVolumes)
    }

    @Test func hiddenRepositoriesAreListedAndShownAgain() throws {
        let scene = try Scene()
        scene.settings.hiddenRepos = ["/x/two", "/x/one"]
        let model = ScanSettingsModel(store: scene.makeStore())
        #expect(model.hiddenRepositories == ["/x/one", "/x/two"])

        model.show(repoPath: "/x/one")

        #expect(scene.settings.hiddenRepos == ["/x/two"])
        #expect(model.hiddenRepositories == ["/x/two"])

        model.show(repoPath: "/x/two")
        #expect(model.hiddenRepositories.isEmpty)
    }

    @Test func aShownRepositoryComesBackWithTheNextScan() async throws {
        let scene = try Scene()
        scene.addRepository("/x/kept")
        scene.addRepository("/x/hidden")
        let store = await scene.startedStore()
        store.hide(repoPath: "/x/hidden")
        let model = ScanSettingsModel(store: store)
        #expect(store.projects.map(\.path) == ["/x/kept"])

        model.show(repoPath: "/x/hidden")
        await model.rescan()
        await scene.settle(store)

        #expect(store.projects.map(\.path) == ["/x/hidden", "/x/kept"])
    }

    @Test func rescanStartsTheStoreUnlessOneRunsOrTheFirstRunIsNotThrough() async throws {
        let scene = try Scene(scanner: FakeScanner(hangs: true))
        let store = scene.makeStore()
        let model = ScanSettingsModel(store: store)
        #expect(model.canRescan)
        #expect(!model.appliesToTheNextScan)

        let running = Task { await model.rescan() }
        #expect(await poll { store.isStarting })
        #expect(!model.canRescan)
        #expect(model.appliesToTheNextScan)
        await model.rescan()  // dropped
        running.cancel()
        await running.value
        #expect(scene.scanner.scans == 1)

        let first = try Scene(onboarded: false)
        let before = ScanSettingsModel(store: first.makeStore())
        #expect(!before.canRescan)
        await before.rescan()
        #expect(first.scanner.scans == 0)
    }
}
