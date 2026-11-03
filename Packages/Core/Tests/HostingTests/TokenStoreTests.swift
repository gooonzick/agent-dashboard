import Foundation
import Hosting
import Security
import Testing

/// The Keychain service of every test here. The service of the app, `dev.gooonzick.AgentDashboard.hosting`, is never
/// read or written by a test: its entries are the user's.
private let testService = "dev.gooonzick.AgentDashboard.tests"

/// A host that no other test uses, so that tests running side by side find only what they put in the Keychain.
private func uniqueHost() -> String { "\(UUID().uuidString.lowercased()).keychain.test" }

/// Removes the entry of `host` from the Keychain, and does it without the store that is under test: a store that is
/// broken must not be what leaves its entries behind.
private func scrub(_ host: String, service: String = testService) {
    let entry: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: service,
        kSecAttrAccount as String: host,
    ]
    SecItemDelete(entry as CFDictionary)
}

/// These tests write the login Keychain of whoever runs them (under a service of their own, which they scrub), so they
/// are off unless the environment has `AD_KEYCHAIN_TESTS=1`:
///
///     AD_KEYCHAIN_TESTS=1 swift test --package-path Packages/Core --filter TokenStoreTests
///
/// The Keychain may ask once for the login password, or for "Always Allow", for the test runner.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["AD_KEYCHAIN_TESTS"] == "1"), .timeLimit(.minutes(1)))
struct TokenStoreTests {
    // Each test scrubs what it stored in a `defer`, so that a failed expectation or a thrown error leaves nothing
    // behind in the user's Keychain.
    let store = KeychainTokenStore(service: testService)

    @Test func keychainRoundTrip() throws {
        let host = uniqueHost()
        defer { scrub(host) }

        #expect(try store.token(for: host) == nil)
        try store.setToken("glpat-abc", for: host)
        #expect(try store.token(for: host) == "glpat-abc")
        try store.setToken(nil, for: host)
        #expect(try store.token(for: host) == nil)
    }

    // What the brief's example leaves open.

    @Test func aNewTokenReplacesTheOldOne() throws {
        let host = uniqueHost()
        defer { scrub(host) }

        try store.setToken("first", for: host)
        try store.setToken("second", for: host)

        #expect(try store.token(for: host) == "second")
        try store.setToken(nil, for: host)
        #expect(try store.token(for: host) == nil)  // one entry was there, not two
    }

    @Test func removingATokenThatIsNotThereIsNoError() throws {
        let host = uniqueHost()
        defer { scrub(host) }
        try store.setToken(nil, for: host)
        try store.setToken("", for: host)
        #expect(try store.token(for: host) == nil)
    }

    @Test func anEmptyTokenIsNoToken() throws {
        let host = uniqueHost()
        defer { scrub(host) }
        try store.setToken("glpat-abc", for: host)

        try store.setToken("", for: host)

        #expect(try store.token(for: host) == nil)  // not "", which a client would send as a header
    }

    @Test func eachHostHasItsOwnToken() throws {
        let (one, other) = (uniqueHost(), uniqueHost())
        defer {
            scrub(one)
            scrub(other)
        }

        try store.setToken("one", for: one)
        try store.setToken("other", for: other)
        #expect(try store.token(for: one) == "one" && store.token(for: other) == "other")

        try store.setToken(nil, for: one)
        #expect(try store.token(for: one) == nil && store.token(for: other) == "other")
    }

    @Test func aHostIsTheSameInAnyCase() throws {
        let host = uniqueHost()
        defer {
            scrub(host)
            scrub(host.uppercased())  // where a store that tells the cases apart would have put it
        }

        try store.setToken("glpat-abc", for: host.uppercased())

        #expect(try store.token(for: host) == "glpat-abc")
        try store.setToken("glpat-def", for: host)
        #expect(try store.token(for: host.uppercased()) == "glpat-def")
    }

    @Test func eachServiceHasItsOwnTokens() throws {
        let host = uniqueHost()
        let other = KeychainTokenStore(service: testService + ".other")
        defer {
            scrub(host)
            scrub(host, service: testService + ".other")
        }

        try store.setToken("glpat-abc", for: host)

        #expect(try other.token(for: host) == nil)
        try other.setToken("glpat-def", for: host)
        #expect(try store.token(for: host) == "glpat-abc")
    }

    @Test func anEntryThatIsNotTextIsAnErrorAndNotAMissingToken() throws {
        let host = uniqueHost()
        defer { scrub(host) }
        let entry: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: testService,
            kSecAttrAccount as String: host,
            kSecValueData as String: Data([0xFF, 0xFE, 0xFD]),  // no UTF-8
        ]
        try #require(SecItemAdd(entry as CFDictionary, nil) == errSecSuccess)

        #expect(throws: TokenStoreError.unreadable) { try store.token(for: host) }
    }
}

/// What can be checked of the Keychain store without the Keychain, on every run.
@Suite struct TokenStoreServiceTests {
    @Test func theTokensOfTheAppAreKeptUnderTheServiceOfTheApp() {
        // Reading this does not touch the Keychain. No test may use this store: its entries are the user's.
        #expect(KeychainTokenStore().service == "dev.gooonzick.AgentDashboard.hosting")
    }
}
