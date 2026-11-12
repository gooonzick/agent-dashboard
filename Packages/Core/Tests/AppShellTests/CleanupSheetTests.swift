import Cleanup
import Testing

@testable import AppShell

/// What the sheet that confirms a clean says. These open no window and ask nothing of the Mac: whether Xcode runs is
/// given.
@MainActor @Suite struct CleanupSheetTests {
    private static let home = "/Users/me"

    @Test func aCacheThatItsToolCleansShowsItsFoldersAndTheCommand() {
        let go = CacheEntry(
            id: "go", group: .packages, title: "Go modules and build cache",
            paths: ["/Users/me/go/pkg/mod", "/Users/me/Library/Caches/go-build"], note: nil, action: "Clean",
            clean: .command(tool: "go", args: ["clean", "-modcache", "-cache"]))
        let model = CleanupSheetModel(CleanupAsk(.cache(go), xcodeIsRunning: { true }), home: Self.home)
        #expect(model.title == "Clean Go modules and build cache?")
        #expect(model.items == ["~/go/pkg/mod", "~/Library/Caches/go-build"])
        #expect(model.itemsArePaths)
        #expect(model.command == "go clean -modcache -cache")
        #expect(model.consequence == "Packages are downloaded again when a project needs them.")
        // Xcode is asked about for DerivedData alone.
        #expect(model.warning == nil)
        #expect(model.confirmTitle == "Clean")
        #expect(model.failureTitle == "Could not clean Go modules and build cache")
    }

    @Test func derivedDataSaysThatXcodeRunsWhenItDoes() {
        let derived = CacheEntry(
            id: "derived-data", group: .xcode, title: "DerivedData",
            paths: ["/Users/me/Library/Developer/Xcode/DerivedData"], note: nil, action: "Clean",
            clean: .deleteContents(of: "/Users/me/Library/Developer/Xcode/DerivedData"))
        let running = CleanupSheetModel(CleanupAsk(.cache(derived), xcodeIsRunning: { true }), home: Self.home)
        #expect(running.items == ["~/Library/Developer/Xcode/DerivedData"])
        #expect(running.command == nil)
        #expect(running.consequence == "Xcode rebuilds what it needs.")
        #expect(running.warning == "Xcode is running; builds in progress may fail.")

        let idle = CleanupSheetModel(CleanupAsk(.cache(derived), xcodeIsRunning: { false }), home: Self.home)
        #expect(idle.warning == nil)
    }

    @Test func oldStoresListEveryFolderThatGoes() {
        let old = CacheEntry(
            id: "pnpm-old", group: .packages, title: "Old pnpm stores",
            paths: ["/Users/me/Library/pnpm/store/v3", "/Users/me/Library/pnpm/store/v9"], note: nil, action: "Clean",
            clean: .deleteFolders(["/Users/me/Library/pnpm/store/v3"]))
        let model = CleanupSheetModel(CleanupAsk(.cache(old)), home: Self.home)
        // What is deleted, not what is measured.
        #expect(model.items == ["~/Library/pnpm/store/v3"])
    }

    @Test func aBuildOutputSaysTheNextBuildMakesItAgain() {
        let output = BuildOutput(
            path: "/Users/me/Development/meetily/target", worktree: "/Users/me/Development/meetily",
            title: "meetily/target", kind: "Rust build")
        let model = CleanupSheetModel(CleanupAsk(.output(output)), home: Self.home)
        #expect(model.title == "Clean meetily/target?")
        #expect(model.items == ["~/Development/meetily/target"])
        #expect(model.consequence == "The next build creates it again.")
        #expect(model.confirmTitle == "Clean")
    }

    @Test func dockerListsWhatItRemoves() {
        let images = CleanupSheetModel(
            CleanupAsk(.unusedImages([DockerImage(id: "a", name: "postgres:16", size: 450_000_000, isUnused: true)])))
        #expect(images.title == "Remove unused images?")
        #expect(images.items == ["postgres:16 · 0.5 GB"])
        #expect(!images.itemsArePaths)
        #expect(images.consequence == "Images are pulled again when a container needs them.")
        #expect(images.confirmTitle == "Remove")
        #expect(images.failureTitle == "Could not remove unused images")

        let containers = CleanupSheetModel(
            CleanupAsk(
                .stoppedContainers([
                    DockerContainer(id: "c", name: "api-db-1", image: "postgres:16", isRunning: false, size: 0, project: nil)
                ])))
        #expect(containers.title == "Remove stopped containers?")
        #expect(containers.items == ["api-db-1 · postgres:16"])
        // Not the images line: what goes is what the containers wrote (Ruling 12).
        #expect(containers.consequence == "What these containers wrote outside volumes is deleted.")
        #expect(containers.confirmTitle == "Remove")
    }
}
