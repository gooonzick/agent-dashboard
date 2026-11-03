import Discovery
import Foundation
import TestSupport
import Testing

/// `RepoScanner.wouldFind`, which the file watcher asks about one folder, has to say what a scan would.
@Suite struct WouldFindTests {
    /// A tree with a folder for every rule of the scan, and some folders that are not repositories.
    private static let folders = [
        "a/.git", "a/src", "a/node_modules/x/.git", "a/tmp/protos/.git", "a/build/dep/.git", "a/vendor/lib/.git",
        "plain/tmp/proj/.git", "plain/build/y/.git", "plain/src/node_modules/z/.git", "plain/empty",
        "Foo.app/inner/.git", "excluded/r/.git", "excluded-not/r/.git", ".hidden/r/.git", "wt/tmp/clone/.git",
        "wt/src/inner/.git", "deep/1/2/3/4/.git",
    ]

    private func makeTree() throws -> TempDir {
        let tmp = try TempDir(named: "My Projects")
        for folder in Self.folders {
            try FileManager.default.createDirectory(
                at: tmp.url.appending(path: folder), withIntermediateDirectories: true)
        }
        try Data().write(to: tmp.url.appending(path: "wt/.git"))  // a worktree's checkout
        return tmp
    }

    @Test func agreesWithTheScanOnEveryFolder() async throws {
        let tmp = try makeTree()
        let rules = ExclusionRules(excludedPaths: [tmp.canonicalPath + "/excluded"])
        let roots = [tmp.url]
        let found = Set(await RepoScanner().scan(roots: roots, rules: rules, isCancelled: { false }).map(\.path))
        #expect(found.count == 8)  // the tree is not trivial

        let candidates = Self.folders.map { tmp.canonicalPath + "/" + $0.replacing("/.git", with: "") }
            + [tmp.canonicalPath, tmp.canonicalPath + "/wt"]
        for candidate in candidates {
            #expect(
                RepoScanner.wouldFind(candidate, roots: roots, rules: rules) == found.contains(candidate),
                "\(candidate)")
        }
    }

    @Test func aFolderOutsideTheRootsIsNotFound() throws {
        let tmp = try makeTree()
        let rules = ExclusionRules(excludedPaths: [])
        let plain = [tmp.url.appending(path: "plain")]
        #expect(!RepoScanner.wouldFind(tmp.canonicalPath + "/a", roots: plain, rules: rules))
        #expect(RepoScanner.wouldFind(tmp.canonicalPath + "/a", roots: [tmp.url.appending(path: "a")], rules: rules))
    }

    @Test func anExcludedFolderAboveTheRootDoesNotCount() throws {
        let tmp = try makeTree()
        let rules = ExclusionRules(excludedPaths: [tmp.canonicalPath + "/deep", tmp.canonicalPath + "/deep/1/2"])
        let root = tmp.url.appending(path: "deep/1/2/3")
        let above = ExclusionRules(excludedPaths: [tmp.canonicalPath + "/deep"])

        #expect(RepoScanner.wouldFind(tmp.canonicalPath + "/deep/1/2/3/4", roots: [root], rules: above))
        #expect(!RepoScanner.wouldFind(tmp.canonicalPath + "/deep/1/2/3/4", roots: [tmp.url], rules: above))
        let excludedRoot = [tmp.url.appending(path: "deep/1/2")]
        #expect(!RepoScanner.wouldFind(tmp.canonicalPath + "/deep/1/2/3/4", roots: excludedRoot, rules: rules))
    }

    @Test func walksIntoWhatTheScanWalksInto() throws {
        let tmp = try makeTree()
        let rules = ExclusionRules(excludedPaths: [tmp.canonicalPath + "/excluded"])
        let roots = [tmp.url]
        #expect(RepoScanner.walks(into: tmp.canonicalPath + "/plain/empty", roots: roots, rules: rules))
        #expect(RepoScanner.walks(into: tmp.canonicalPath + "/plain/tmp", roots: roots, rules: rules))
        #expect(!RepoScanner.walks(into: tmp.canonicalPath + "/a/tmp", roots: roots, rules: rules))
        #expect(!RepoScanner.walks(into: tmp.canonicalPath + "/excluded", roots: roots, rules: rules))
        #expect(!RepoScanner.walks(into: tmp.canonicalPath + "/Foo.app", roots: roots, rules: rules))
        #expect(!RepoScanner.walks(into: tmp.canonicalPath + "/missing", roots: roots, rules: rules))
    }
}
