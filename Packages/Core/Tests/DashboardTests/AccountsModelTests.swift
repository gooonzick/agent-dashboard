import CoreModels
@testable import Dashboard
import Foundation
import Hosting
import Shell
import TestSupport
import Testing

/// What the Accounts tab shows and does, with nothing real behind it: the tokens are in memory, `glab` and `gh` are
/// stand-ins, and the host of the one test that asks a service is a `.test` name behind a stub.
@MainActor
@Suite struct AccountsModelTests {
    /// A token as a test uses one. It must never show up in what the model keeps.
    private let secret = "glpat-TESTSECRET123"

    /// The hosts whose requests the model asked for again.
    private final class Refreshed {
        var hosts: [String] = []
    }

    private struct Setup {
        let scene: Scene
        let tokens: FakeTokens
        let tools: FakeTools
        let model: AccountsModel
        let refreshed: Refreshed
    }

    private func setup(
        hosts: [String] = ["github.com", "gitlab.example.org"], tokens: [String: String] = [:],
        kinds: [String: HostingKind] = ["github.com": .github, "gitlab.example.org": .gitlab],
        tools: FakeTools = FakeTools(), reviews: (any ReviewLooking)? = nil
    ) throws -> Setup {
        let scene = try Scene(hosting: FakeHosting(kinds))
        let store = FakeTokens(tokens)
        let refreshed = Refreshed()
        let model = AccountsModel(
            hosts: { hosts }, settings: scene.settings, detector: scene.hosting, tokens: store,
            importer: TokenImporter(runner: tools), tools: tools, reviews: reviews ?? scene.reviews,
            refreshReviews: { host in refreshed.hosts.append(host) })
        return Setup(scene: scene, tokens: store, tools: tools, model: model, refreshed: refreshed)
    }

    @Test func listsHostsWithKindsAndTokens() async throws {
        let s = try setup(tokens: ["gitlab.example.org": secret])

        await s.model.reload()

        #expect(s.model.items.map(\.host) == ["github.com", "gitlab.example.org"])
        #expect(s.model.items.map(\.kind) == [.github, .gitlab])
        #expect(s.model.items.map(\.hasToken) == [false, true])
        #expect(s.model.items.map(\.isManual) == [false, false])
    }

    @Test func importStoresTokenAndClearsError() async throws {
        let s = try setup(tools: FakeTools(printed: ["glab": secret]))
        s.tokens.failWrites(with: TokenStoreError.unreadable)
        await s.model.reload()
        await s.model.importToken(host: "gitlab.example.org")
        #expect(s.model.items.last?.lastError != nil)  // the error that the import is to clear
        s.tokens.failWrites(with: nil)

        await s.model.importToken(host: "gitlab.example.org")

        #expect(try s.tokens.token(for: "gitlab.example.org") == secret)
        let item = try #require(s.model.items.first { $0.host == "gitlab.example.org" })
        #expect(item.hasToken)
        #expect(item.lastError == nil)
        #expect(s.tools.commands == Array(repeating: "glab config get token --host gitlab.example.org", count: 2))
        #expect(s.refreshed.hosts == ["gitlab.example.org"])
    }

    @Test func importThatFindsNothingStoresNothingAndSaysSo() async throws {
        let s = try setup(tools: FakeTools(printed: [:]))
        await s.model.reload()

        await s.model.importToken(host: "gitlab.example.org")

        #expect(s.tokens.writes.isEmpty)
        let item = try #require(s.model.items.first { $0.host == "gitlab.example.org" })
        #expect(!item.hasToken)
        #expect(item.lastError?.contains("glab") == true)
        #expect(s.refreshed.hosts.isEmpty)
    }

    @Test func importButtonsFollowTheToolsThatAreFound() async throws {
        let withBoth = try setup()
        await withBoth.model.reload()
        #expect(withBoth.model.items.map(\.importTool) == ["gh", "glab"])

        let onlyGh = try setup(tools: FakeTools(installed: ["gh"]))
        await onlyGh.model.reload()
        #expect(onlyGh.model.items.map(\.importTool) == ["gh", nil])

        let neither = try setup(tools: FakeTools(installed: []))
        await neither.model.reload()
        #expect(neither.model.items.map(\.importTool) == [nil, nil])
    }

    @Test func manualKindOverridesDetection() async throws {
        let s = try setup(hosts: ["git.corp"], kinds: ["git.corp": .unsupported])
        await s.model.reload()
        #expect(s.model.items.first?.kind == .unsupported)
        #expect(s.model.items.first?.isManual == false)

        await s.model.setKind(.gitlab, host: "git.corp")

        #expect(s.scene.settings.hostingOverrides["git.corp"] == .gitlab)
        // The detector that the store asks hears of it at once: no relaunch.
        #expect(s.scene.hosting.overrides["git.corp"] == .gitlab)
        #expect(s.model.items.first?.kind == .gitlab)
        #expect(s.model.items.first?.isManual == true)
        #expect(s.refreshed.hosts == ["git.corp"])

        await s.model.setKind(nil, host: "git.corp")

        #expect(s.scene.settings.hostingOverrides["git.corp"] == nil)
        #expect(s.model.items.first?.isManual == false)
    }

    @Test func showsLastReviewError() async throws {
        // The real service, on a host that answers every request with 401.
        let session = Unauthorized.session()
        let detector = HostingDetector(overrides: [:], session: session)
        let service = ReviewService(detector: detector, tokens: NoTokens(), session: session)
        let remote = try #require(RemoteURL("https://gitlab.example.test/team/app.git"))
        _ = await service.review(remote: remote, branch: "feature")
        let s = try setup(hosts: ["gitlab.example.test"], reviews: service)

        await s.model.reload()

        #expect(s.model.items.first?.lastError?.contains("401") == true)
    }

    @Test func aTokenGoesToTheStoreAndNowhereElse() async throws {
        let s = try setup()

        await s.model.setToken("  \(secret)\n", host: "gitlab.example.org")

        #expect(try s.tokens.token(for: "gitlab.example.org") == secret)  // trimmed: a newline is no part of a token
        let item = try #require(s.model.items.first { $0.host == "gitlab.example.org" })
        #expect(item.hasToken)
        #expect(!String(reflecting: s.model.items).contains("TESTSECRET"))
        #expect(!String(reflecting: s.model.items).contains(secret))
    }

    @Test func savingNothingRemovesTheToken() async throws {
        let s = try setup(tokens: ["gitlab.example.org": secret])
        await s.model.reload()
        #expect(s.model.items.map(\.hasToken) == [false, true])

        await s.model.setToken("   ", host: "gitlab.example.org")

        #expect(try s.tokens.token(for: "gitlab.example.org") == nil)
        #expect(s.model.items.map(\.hasToken) == [false, false])
        #expect(s.tokens.writes == ["gitlab.example.org"])  // removed, not skipped
    }

    @Test func afterATokenChangeTheReviewsOfThatHostAreAskedAgain() async throws {
        let s = try setup()

        await s.model.setToken(secret, host: "gitlab.example.org")
        await s.model.setToken("", host: "github.com")

        #expect(s.refreshed.hosts == ["gitlab.example.org", "github.com"])
    }

    @Test func aStoreThatFailsIsSaidSoWithoutTheToken() async throws {
        let s = try setup()
        s.tokens.failWrites(with: TokenStoreError.keychain(-25308))

        await s.model.setToken(secret, host: "gitlab.example.org")

        let item = try #require(s.model.items.first { $0.host == "gitlab.example.org" })
        #expect(!item.hasToken)
        #expect(item.lastError?.contains("saved") == true)
        #expect(!(item.lastError ?? "").contains("TESTSECRET"))
        #expect(s.refreshed.hosts.isEmpty)
    }

    @Test func aStoreThatCannotBeReadIsNotAnEmptyOne() async throws {
        let s = try setup()
        s.tokens.failReads(with: TokenStoreError.unreadable)

        await s.model.reload()

        #expect(s.model.items.allSatisfy { !$0.hasToken })
        #expect(s.model.items.allSatisfy { $0.lastError != nil })
    }

    @Test func theHostsComeFromTheRemotesWithoutTheirCredentials() async throws {
        let scene = try Scene()
        scene.addRepository("/x/a", remote: "https://deploy:glpat-SECRET@GitLab.Example.test/team/a.git")
        scene.addRepository("/x/b", remote: "git@gitlab.example.test:team/b.git")
        scene.addRepository("/x/c", remote: "git@github.com:me/c.git")
        scene.addRepository("/x/d", remote: "/srv/git/d.git")  // a folder: no host
        let store = await scene.startedStore()

        #expect(store.hosts == ["github.com", "gitlab.example.test"])
        #expect(!store.hosts.joined().contains("SECRET"))
    }

    @Test func theStoreAsksAgainOnlyForTheReposOfTheHostAfterATokenChange() async throws {
        let scene = try Scene()
        scene.addRepository("/x/lab", worktrees: [linked("/x/lab-wt", branch: "a")], remote: "git@gitlab.example.test:t/a.git")
        scene.addRepository("/x/hub", worktrees: [linked("/x/hub-wt", branch: "b")], remote: "git@github.com:me/b.git")
        let store = await scene.startedStore()
        let asked = scene.reviews.lookups.count
        let invalidated = scene.reviews.invalidations

        await store.refreshReviews(host: "GitLab.Example.test")

        #expect(scene.reviews.invalidations == invalidated + 1)
        let again = scene.reviews.lookups.dropFirst(asked)
        #expect(!again.isEmpty)
        #expect(again.allSatisfy { $0.host == "gitlab.example.test" })
    }
}
