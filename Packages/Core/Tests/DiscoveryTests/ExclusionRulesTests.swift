import Discovery
import Foundation
import Testing

@Suite struct ExclusionRulesTests {
    @Test func defaultsAreTheSpecsListWithHomeExpanded() {
        let rules = ExclusionRules.defaults(home: URL(filePath: "/Users/x"))

        let system = [
            "/System", "/Library", "/usr", "/bin", "/sbin", "/private", "/dev", "/cores", "/opt/homebrew",
            "/Applications", "/Volumes",
        ]
        let inHome = [
            "Library", ".Trash", ".cargo", ".rustup", ".npm", ".cache", ".bun", ".nvm", ".pnpm-store", ".local/share",
            ".local/state", "go/pkg", ".gradle", ".m2", ".cocoapods", ".claude/plugins", ".codex", ".vscode/extensions",
            ".cursor/extensions", ".docker", ".colima", ".lima", ".orbstack",
        ].map { "/Users/x/" + $0 }
        #expect(rules.excludedPaths.sorted() == (system + inHome).sorted())  // nothing missing, nothing twice
        #expect(!rules.includeExternalVolumes)
    }

    @Test func defaultsIgnoreATrailingSlashOnHome() {
        let withSlash = ExclusionRules.defaults(home: URL(filePath: "/Users/x/", directoryHint: .isDirectory))
        #expect(withSlash.excludedPaths.contains("/Users/x/.cargo"))
        #expect(withSlash == ExclusionRules.defaults(home: URL(filePath: "/Users/x")))
    }

    @Test func survivesAJSONRoundTrip() throws {
        // The settings keep the rules as JSON.
        let rules = ExclusionRules(excludedPaths: ["/Users/x/.cargo", "/Volumes/Backup"], includeExternalVolumes: true)
        let data = try JSONEncoder().encode(rules)
        #expect(try JSONDecoder().decode(ExclusionRules.self, from: data) == rules)
    }

    @Test func serviceDirectoryNamesAreTheSpecsList() {
        #expect(
            ExclusionRules.serviceDirectoryNames == [
                "node_modules", "build", ".build", "DerivedData", "target", "dist", "tmp", "Pods", ".next", ".nx",
                ".turbo", ".git",
            ])
    }

    @Test func excludesTheFolderItselfAndEverythingInIt() {
        let rules = ExclusionRules(excludedPaths: ["/Users/x/.cargo"])
        #expect(rules.isExcluded("/Users/x/.cargo"))
        #expect(rules.isExcluded("/Users/x/.cargo/registry"))
        #expect(rules.isExcluded("/Users/x/.cargo/registry/src/foo"))
        #expect(!rules.isExcluded("/Users/x"))  // its parent is not excluded with it
        #expect(!rules.isExcluded("/Users/x/projects"))
    }

    @Test func comparesFolderByFolderNotCharacterByCharacter() {
        let rules = ExclusionRules(excludedPaths: ["/Users/x/.cargo"])
        #expect(rules.isExcluded("/Users/x/.cargo/registry"))
        #expect(!rules.isExcluded("/Users/x/.cargo-other"))
        #expect(!rules.isExcluded("/Users/x/.cargo-other/registry"))
        #expect(!rules.isExcluded("/Users/x/.carg"))
    }

    @Test func ignoresTrailingSlashesOnBothSides() {
        let rules = ExclusionRules(excludedPaths: ["/Users/x/.cargo/"])
        #expect(rules.isExcluded("/Users/x/.cargo"))
        #expect(rules.isExcluded("/Users/x/.cargo/"))
        #expect(rules.isExcluded("/Users/x/.cargo/registry/"))
        #expect(!rules.isExcluded("/Users/x/.cargo-other/"))
    }

    @Test func excludingTheRootExcludesEverything() {
        #expect(ExclusionRules(excludedPaths: ["/"]).isExcluded("/Users/x/projects"))
    }

    @Test func aBlankOrRelativeEntryExcludesNothing() {
        // A row left empty in a settings list must not switch the whole disk off.
        let rules = ExclusionRules(excludedPaths: ["", ".cargo", "x", "/Users/x/real"])
        #expect(rules.isExcluded("/Users/x/real/inner"))  // the one proper entry still works
        #expect(!rules.isExcluded("/Users/x/projects"))
        #expect(!rules.isExcluded("/Users/x/.cargo"))
        #expect(!rules.isExcluded("/x"))
    }
}
