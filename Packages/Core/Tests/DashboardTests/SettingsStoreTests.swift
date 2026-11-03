import Dashboard
import Discovery
import Foundation
import Hosting
import TestSupport
import Testing

@Suite struct SettingsStoreTests {
    /// Defaults of the test's own, in a folder that goes with the test, and the name of their suite.
    private static func withDefaults(_ body: (UserDefaults, String) throws -> Void) throws {
        let folder = try TempDir(named: "Settings")
        try body(try testDefaults(in: folder), folder.canonicalPath + "/settings")
    }

    @Test func settingsRoundTrip() throws {
        try Self.withDefaults { defaults, suite in
            let settings = SettingsStore(defaults: defaults)
            // What a fresh install starts with, as the spec says.
            #expect(settings.rules == .defaults(home: FileManager.default.homeDirectoryForCurrentUser))
            #expect(settings.rules.includeExternalVolumes == false)
            #expect(settings.hostingOverrides.isEmpty)
            #expect(settings.skipConfirmForMergedPushed == false)
            #expect(settings.didOnboard == false)
            #expect(settings.hiddenRepos.isEmpty)

            let rules = ExclusionRules(excludedPaths: ["/a", "/b/c"], includeExternalVolumes: true)
            settings.rules = rules
            settings.hostingOverrides = ["git.corp": .gitlab, "ghe.corp": .github]
            settings.skipConfirmForMergedPushed = true
            settings.didOnboard = true
            settings.hiddenRepos = ["/x/hidden", "/y/also"]

            // Another store on the same defaults reads what this one wrote: it is kept in the defaults, not in memory.
            let again = SettingsStore(defaults: try #require(UserDefaults(suiteName: suite)))
            #expect(again.rules == rules)
            #expect(again.hostingOverrides == ["git.corp": .gitlab, "ghe.corp": .github])
            #expect(again.skipConfirmForMergedPushed)
            #expect(again.didOnboard)
            #expect(again.hiddenRepos == ["/x/hidden", "/y/also"])
        }
    }

    @Test func valuesThatCannotBeReadAreTheDefaults() throws {
        try Self.withDefaults { defaults, _ in
            defaults.set(Data("not json".utf8), forKey: "exclusionRules")
            defaults.set(["git.corp": "bitbucket", "ok.corp": "github"], forKey: "hostingOverrides")
            defaults.set("not a list", forKey: "hiddenRepos")

            let settings = SettingsStore(defaults: defaults)

            #expect(settings.rules == .defaults(home: FileManager.default.homeDirectoryForCurrentUser))
            #expect(settings.hostingOverrides == ["ok.corp": .github])  // a kind that is not known is dropped
            #expect(settings.hiddenRepos.isEmpty)
        }
    }
}
