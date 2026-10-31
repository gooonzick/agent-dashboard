import Foundation
import Hosting
import Testing

@Suite(.timeLimit(.minutes(1))) struct HostingDetectorTests {
    // MARK: What the brief asks for

    @Test func detectsSelfHostedGitLabBy401() async {
        let server = StubServer(routes: ["/api/v4/version": .status(401)])
        let detector = HostingDetector(overrides: [:], session: server.session)

        #expect(await detector.kind(for: server.host) == .gitlab)
        #expect(server.paths == ["/api/v4/version"])
    }

    @Test func detectsGitHubEnterpriseByMeta() async {
        let server = StubServer(routes: ["/api/v4/version": .status(404), "/api/v3/meta": .status(200)])
        let detector = HostingDetector(overrides: [:], session: server.session)

        #expect(await detector.kind(for: server.host) == .github)
        #expect(server.paths == ["/api/v4/version", "/api/v3/meta"])  // GitLab is asked first
    }

    @Test func overrideWinsAndResultIsMemoized() async {
        let server = StubServer(routes: ["/api/v3/meta": .status(200)])  // would be GitHub
        let detector = HostingDetector(overrides: [server.host: .gitlab], session: server.session)

        #expect(await detector.kind(for: server.host) == .gitlab)
        #expect(await detector.kind(for: server.host) == .gitlab)
        #expect(server.requests.isEmpty)
    }

    // What the brief's examples leave open: the statuses between the ones it names, what is remembered and what is not,
    // and what a probe of a host that nobody vouches for may and may not do.

    // MARK: Which answer makes which kind

    @Test func aVersionEndpointThatAnswers200IsGitLab() async {
        let server = StubServer(routes: ["/api/v4/version": .status(200)])
        let detector = HostingDetector(overrides: [:], session: server.session)

        #expect(await detector.kind(for: server.host) == .gitlab)
    }

    @Test(arguments: [301, 403, 404, 405])
    func anyOtherAnswerOfTheVersionEndpointIsNotGitLab(status: Int) async {
        let server = StubServer(routes: ["/api/v4/version": .status(status)])
        let detector = HostingDetector(overrides: [:], session: server.session)

        #expect(await detector.kind(for: server.host) == .unsupported)
        #expect(server.paths == ["/api/v4/version", "/api/v3/meta"])  // GitHub was still tried
    }

    @Test(arguments: [301, 401, 403, 404])
    func onlyA200OfTheMetaEndpointIsGitHub(status: Int) async {
        let server = StubServer(routes: ["/api/v3/meta": .status(status)])
        let detector = HostingDetector(overrides: [:], session: server.session)

        #expect(await detector.kind(for: server.host) == .unsupported)
    }

    @Test func aBigBodyDoesNotGetInTheWay() async {
        // A host can answer with as much as it likes. Only the status is looked at.
        let body = Data(repeating: 65, count: 2_000_000)
        let server = StubServer(routes: ["/api/v4/version": .status(401, body: body)])
        let detector = HostingDetector(overrides: [:], session: server.session)

        #expect(await detector.kind(for: server.host) == .gitlab)
    }

    @Test func gitHubComAndGitLabComAreKnownWithoutAskingThem() async {
        // No server stands behind these names: a request for one of them would fail, and the kind would be unsupported.
        let detector = HostingDetector(overrides: [:], session: StubServer().session)

        #expect(await detector.kind(for: "github.com") == .github)
        #expect(await detector.kind(for: "gitlab.com") == .gitlab)
        #expect(await detector.kind(for: "GitHub.COM") == .github)
    }

    // MARK: What is remembered

    @Test func aDetectedKindIsRememberedPerHost() async {
        let gitlab = StubServer(routes: ["/api/v4/version": .status(401)])
        let github = StubServer(routes: ["/api/v3/meta": .status(200)])
        let detector = HostingDetector(overrides: [:], session: gitlab.session)

        #expect(await detector.kind(for: gitlab.host) == .gitlab)
        #expect(await detector.kind(for: github.host) == .github)
        #expect(await detector.kind(for: gitlab.host) == .gitlab)
        #expect(await detector.kind(for: github.host) == .github)
        #expect(gitlab.paths == ["/api/v4/version"])
        #expect(github.paths == ["/api/v4/version", "/api/v3/meta"])
    }

    @Test func aHostThatIsDefinitelyNeitherIsRememberedToo() async {
        let server = StubServer()  // a 404 to everything
        let detector = HostingDetector(overrides: [:], session: server.session)

        #expect(await detector.kind(for: server.host) == .unsupported)
        #expect(await detector.kind(for: server.host) == .unsupported)
        #expect(server.paths == ["/api/v4/version", "/api/v3/meta"])
    }

    @Test func callsThatAskAboutOneHostAtOnceShareOneProbe() async {
        let server = StubServer(routes: ["/api/v4/version": .status(401)])
        let detector = HostingDetector(overrides: [:], session: server.session)
        let host = server.host

        let kinds = await withTaskGroup(of: HostingKind.self) { group in
            for _ in 0..<8 { group.addTask { await detector.kind(for: host) } }
            return await group.reduce(into: []) { $0.append($1) }
        }

        #expect(kinds == Array(repeating: .gitlab, count: 8))
        #expect(server.paths == ["/api/v4/version"])
    }

    // MARK: Overrides

    @Test func overridesApplyToAnyCaseOfTheHostAndAreFinal() async {
        let switchedOff = StubServer(routes: ["/api/v4/version": .status(401)])  // looks like GitLab, and is turned off
        let manual = StubServer()  // looks like nothing, and is said to be GitLab
        let detector = HostingDetector(
            overrides: [switchedOff.host.uppercased(): .unsupported, manual.host: .gitlab], session: manual.session)

        #expect(await detector.kind(for: switchedOff.host) == .unsupported)
        #expect(await detector.kind(for: manual.host.uppercased()) == .gitlab)
        #expect(switchedOff.requests.isEmpty && manual.requests.isEmpty)
    }

    @Test func setOverrideTakesEffectAtOnceAndClearingItDetectsAgain() async {
        let server = StubServer(routes: ["/api/v4/version": .status(401)])
        let detector = HostingDetector(overrides: [:], session: server.session)
        #expect(await detector.kind(for: server.host) == .gitlab)  // detected, and remembered

        await detector.setOverride(.github, for: server.host)
        #expect(await detector.kind(for: server.host) == .github)
        #expect(server.paths == ["/api/v4/version"])  // no new request

        // The server has changed since. Had the first result been kept, clearing the override would bring it back.
        server.answer("/api/v4/version", with: .status(404))
        server.answer("/api/v3/meta", with: .status(200))
        await detector.setOverride(nil, for: server.host)
        #expect(await detector.kind(for: server.host) == .github)
        #expect(server.paths == ["/api/v4/version", "/api/v4/version", "/api/v3/meta"])
    }

    @Test func setOverrideReplacesAnOverrideOfTheInitializerAndIgnoresTheCaseOfTheHost() async {
        let server = StubServer(routes: ["/api/v4/version": .status(401)])
        let detector = HostingDetector(overrides: [server.host: .github], session: server.session)
        #expect(await detector.kind(for: server.host) == .github)

        await detector.setOverride(.unsupported, for: server.host.uppercased())
        #expect(await detector.kind(for: server.host) == .unsupported)

        await detector.setOverride(nil, for: server.host)  // nothing is left to say: the host is asked
        #expect(await detector.kind(for: server.host) == .gitlab)
    }

    @Test func anOverrideThatIsSetWhileTheHostIsBeingAskedWins() async throws {
        let server = StubServer(routes: ["/api/v4/version": .never])
        let detector = HostingDetector(overrides: [:], session: server.session, probeTimeout: .seconds(1))
        let host = server.host
        let asked = Task { await detector.kind(for: host) }

        for _ in 0..<400 where server.requests.isEmpty { try await Task.sleep(for: .milliseconds(5)) }
        try #require(!server.requests.isEmpty, "the probe never went out")
        await detector.setOverride(.github, for: host)  // the user has made up their mind, and the probe is still out

        #expect(await asked.value == .github)
    }

    // MARK: A host that could not be asked, or did not say

    @Test(arguments: [
        URLError.Code.cannotFindHost, .secureConnectionFailed, .serverCertificateUntrusted, .timedOut,
        .notConnectedToInternet, .cannotConnectToHost, .networkConnectionLost,
    ])
    func aFailedProbeIsNoAnswerAndIsNotRemembered(code: URLError.Code) async {
        let server = StubServer(routes: ["/api/v4/version": .failure(code)])
        let detector = HostingDetector(overrides: [:], session: server.session)

        #expect(await detector.kind(for: server.host) == .unsupported)
        #expect(server.paths == ["/api/v4/version"])  // and GitHub was not asked: the host could not be reached

        server.answer("/api/v4/version", with: .status(401))  // the VPN is up again
        #expect(await detector.kind(for: server.host) == .gitlab)
    }

    @Test(arguments: [500, 502, 503, 504, 408, 429])
    func aHostThatIsStrugglingIsNotRememberedAsUnsupported(status: Int) async {
        let server = StubServer(routes: ["/api/v4/version": .status(status), "/api/v3/meta": .status(404)])
        let detector = HostingDetector(overrides: [:], session: server.session)
        #expect(await detector.kind(for: server.host) == .unsupported)

        server.answer("/api/v4/version", with: .status(401))
        #expect(await detector.kind(for: server.host) == .gitlab)
    }

    @Test func aStrugglingHostIsNotRememberedWhenTheSecondProbeIsTheOneThatStruggles() async {
        let server = StubServer(routes: ["/api/v4/version": .status(404), "/api/v3/meta": .status(503)])
        let detector = HostingDetector(overrides: [:], session: server.session)
        #expect(await detector.kind(for: server.host) == .unsupported)

        server.answer("/api/v3/meta", with: .status(200))
        #expect(await detector.kind(for: server.host) == .github)
    }

    @Test func aFailureOfTheSecondProbeIsNotRememberedEither() async {
        let server = StubServer(routes: ["/api/v4/version": .status(404), "/api/v3/meta": .failure(.timedOut)])
        let detector = HostingDetector(overrides: [:], session: server.session)
        #expect(await detector.kind(for: server.host) == .unsupported)

        server.answer("/api/v3/meta", with: .status(200))
        #expect(await detector.kind(for: server.host) == .github)
    }

    @Test func givesUpOnAHostThatNeverAnswersAndDoesNotRememberIt() async {
        let server = StubServer(routes: ["/api/v4/version": .never])
        let detector = HostingDetector(overrides: [:], session: server.session, probeTimeout: .milliseconds(200))

        let elapsed = await ContinuousClock().measure {
            #expect(await detector.kind(for: server.host) == .unsupported)
        }
        #expect(elapsed < .seconds(5))

        server.answer("/api/v4/version", with: .status(401))
        #expect(await detector.kind(for: server.host) == .gitlab)
    }

    // MARK: What a probe may do

    @Test func aProbeIsAnAnonymousPlainHTTPSGet() async throws {
        let server = StubServer()
        let detector = HostingDetector(overrides: [:], session: server.session)
        _ = await detector.kind(for: server.host)

        #expect(server.requests.count == 2)
        for request in server.requests {
            let url = try #require(request.url)
            #expect(request.httpMethod == "GET" && request.httpBody == nil && request.httpBodyStream == nil)
            #expect(url.scheme == "https" && url.host == server.host && url.port == nil)
            #expect(url.user == nil && url.password == nil && url.query == nil && url.fragment == nil)
            #expect(request.httpShouldHandleCookies == false)  // no cookie of the session goes with it
            #expect(request.timeoutInterval <= 5)
            #expect(request.cachePolicy == .reloadIgnoringLocalCacheData)
            let headers = (request.allHTTPHeaderFields ?? [:]).keys.map { $0.lowercased() }
            #expect(!headers.contains("authorization") && !headers.contains("cookie"))
            #expect(!headers.contains(where: { $0.contains("token") }))  // `PRIVATE-TOKEN`, `X-…-Token`
        }
    }

    @Test func aRedirectIsNotFollowed() async throws {
        // A host behind a single sign-on page, or one that sends everything somewhere else, says 200 to a request
        // that was not meant for it. The answer has to be the one of the host that was asked.
        let login = StubServer(routes: ["/login": .status(200)])
        let target = try #require(URL(string: "https://\(login.host)/login"))
        let server = StubServer(routes: [
            "/api/v4/version": .redirect(to: target), "/api/v3/meta": .redirect(to: target),
        ])
        let detector = HostingDetector(overrides: [:], session: server.session)

        #expect(await detector.kind(for: server.host) == .unsupported)
        #expect(login.requests.isEmpty)
    }

    @Test(arguments: ["{host}/x", "{host}/", "user@{host}", "{host}:8443", "{host}?q=1", "{host}#f"])
    func aNameThatWouldSendTheRequestElsewhereIsRefused(template: String) async {
        // Dropped into `https://<host>/…`, each of these reaches the server of the test, at some other address than the
        // one that was meant. `kind(for:)` is public, and what it is given has not necessarily been through `RemoteURL`.
        let server = StubServer(routes: ["/api/v4/version": .status(401)])
        let detector = HostingDetector(overrides: [:], session: server.session)

        #expect(await detector.kind(for: template.replacing("{host}", with: server.host)) == .unsupported)
        #expect(server.requests.isEmpty)
    }

    @Test(arguments: ["-bad.example", "bad-.example", "a..example", ".example", "example."])
    func aNameThatIsNoHostNameIsRefused(host: String) async {
        let server = StubServer(host: host, routes: ["/api/v4/version": .status(401)])
        let detector = HostingDetector(overrides: [:], session: server.session)

        #expect(await detector.kind(for: host) == .unsupported)
        #expect(server.requests.isEmpty)
    }
}
