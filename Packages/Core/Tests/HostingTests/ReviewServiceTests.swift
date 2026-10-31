import CoreModels
import Foundation
import Testing

@testable import Hosting

/// A service in front of one stub server, whose host is of the kind that `provider` stands for.
private struct Rig: Sendable {
    let provider: Provider
    let server: StubServer
    let tokens: FakeTokens
    let service: ReviewService
    let remote: RemoteURL

    /// `reply` is what the list is answered with, a merged request if it is `nil`. `token` is the token that is kept
    /// for the host, if any, and `tokenFailure` what reading it throws.
    init(
        _ provider: Provider = .gitLab, reply: StubReply? = nil, token: String? = nil,
        tokenFailure: (any Error)? = nil, ttl: Duration = .seconds(300), deadline: Duration = .seconds(60)
    ) throws {
        let server = StubServer(routes: [provider.listPath: try reply ?? .status(200, body: provider.merged())])
        let tokens = FakeTokens(token.map { [server.host: $0] } ?? [:], failure: tokenFailure)
        let detector = HostingDetector(overrides: [server.host: provider.kind], session: server.session)
        self.provider = provider
        self.server = server
        self.tokens = tokens
        self.service = ReviewService(
            detector: detector, tokens: tokens, session: server.session, ttl: ttl, deadline: deadline)
        self.remote = try provider.remote(on: server.host)
    }

    func review(_ branch: String = "feature/x") async -> ReviewInfo {
        await service.review(remote: remote, branch: branch)
    }

    /// How many times the list of requests was asked for.
    var listRequests: Int { server.listRequests(of: provider).count }

    var lastError: String? {
        get async { await service.lastError(host: server.host) }
    }
}

/// A service for the hosts of `servers`, every one of which is GitLab.
private func makeService(for servers: [StubServer], ttl: Duration = .seconds(300)) -> ReviewService {
    let session = servers[0].session
    let detector = HostingDetector(
        overrides: Dictionary(uniqueKeysWithValues: servers.map { ($0.host, .gitlab) }), session: session)
    return ReviewService(detector: detector, tokens: FakeTokens(), session: session, ttl: ttl)
}

/// The list that holds one request in `state`, as `provider` sends it.
private func listBody(_ provider: Provider, _ state: ReviewState) throws -> Data {
    switch (provider, state) {
    case (.gitLab, .open): try gitLabList(state: "opened")
    case (.gitLab, .draft): try gitLabList(state: "opened", draft: true)
    case (.gitLab, .merged): try gitLabList(state: "merged")
    case (.gitLab, .closed): try gitLabList(state: "closed")
    case (.gitHub, .open): try gitHubList(state: "open")
    case (.gitHub, .draft): try gitHubList(state: "open", draft: true)
    case (.gitHub, .merged): try gitHubList(state: "closed", mergedAt: "2026-10-22T14:03:11Z")
    case (.gitHub, .closed): try gitHubList(state: "closed")
    case (_, .none), (_, .unknown): Data("[]".utf8)
    }
}

@Suite(.timeLimit(.minutes(1))) struct ReviewServiceTests {
    // MARK: What the brief asks for

    @Test func serviceTurnsErrorsIntoUnknown() async throws {
        let rig = try Rig(reply: .status(401))

        #expect(await rig.review() == ReviewInfo.unknown)

        #expect(await rig.lastError?.contains("401") == true)
    }

    @Test func serviceCachesForTTLAndInvalidates() async throws {
        let rig = try Rig()

        let first = await rig.review()
        let second = await rig.review()
        #expect(first.state == .merged && second == first)
        #expect(rig.listRequests == 1)

        await rig.service.invalidate()
        #expect(await rig.review() == first)
        #expect(rig.listRequests == 2)
    }

    // What the brief's examples leave open: what is kept and what is not, which client asks, and what happens when
    // calls come at once.

    // MARK: What is kept

    @Test(arguments: Provider.allCases, [ReviewState.open, .draft, .merged, .closed, .none])
    func everyAnswerThatIsSureIsKeptForTheTTL(provider: Provider, state: ReviewState) async throws {
        let rig = try Rig(provider, reply: .status(200, body: try listBody(provider, state)))

        let first = await rig.review()
        #expect(first.state == state)
        #expect(await rig.review() == first)

        #expect(rig.listRequests == 1)
    }

    @Test(
        arguments: Provider.allCases,
        [
            StubReply.status(401), .status(403), .status(404), .status(429), .status(500), .status(502), .status(503),
            .status(302), .status(204),
            .status(200, body: Data("<html>Sign in</html>".utf8)),  // a page that is not the API
            .status(200, body: Data(#"[{"state": "unheard-of"}]"#.utf8)),  // a state that is not known
            .status(200, body: Data("[{}]".utf8)),  // no state
            .failure(.timedOut), .failure(.cannotFindHost), .failure(.notConnectedToInternet),
            .failure(.secureConnectionFailed),
        ])
    func anAnswerThatIsNotSureIsNeverKeptAndNeverAMerge(provider: Provider, bad: StubReply) async throws {
        let rig = try Rig(provider, reply: bad)

        #expect(await rig.review() == ReviewInfo.unknown)
        #expect(await rig.review() == ReviewInfo.unknown)
        #expect(rig.listRequests == 2)  // asked again, and not told that it is still unknown
        #expect(await rig.lastError != nil)

        // The host is well again. A kept `.unknown` would hide that for the whole TTL.
        rig.server.answer(provider.listPath, with: .status(200, body: try provider.merged()))
        #expect(await rig.review().state == .merged)
        #expect(await rig.lastError == nil)  // a success clears the error of the host
        #expect(await rig.review().state == .merged)
        #expect(rig.listRequests == 3)  // and this one is kept
    }

    @Test func anAnswerIsKeptNoLongerThanTheTTL() async throws {
        let rig = try Rig(ttl: .zero)

        _ = await rig.review()
        _ = await rig.review()

        #expect(rig.listRequests == 2)
    }

    @Test func anAnswerIsKeptPerProjectAndBranchAndNotPerPortOfTheRemote() async throws {
        let rig = try Rig()
        rig.server.answer(
            "/api/v4/projects/other/app/merge_requests", with: .status(200, body: try fixture("gitlab-draft")))
        let host = rig.server.host
        // One question, asked by three remotes: the port of a remote is no part of it, as it is none of the request.
        let ofOneProject = [
            rig.remote, try #require(RemoteURL("ssh://git@\(host):2222/team/app.git")),
            try #require(RemoteURL("https://\(host):8443/team/app.git")),
        ]
        let ofAnother = try #require(RemoteURL("git@\(host):other/app.git"))

        func askEverything() async {
            for remote in ofOneProject { _ = await rig.service.review(remote: remote, branch: "feature/x") }
            _ = await rig.service.review(remote: ofAnother, branch: "feature/x")
            _ = await rig.service.review(remote: rig.remote, branch: "feature/y")
        }

        await askEverything()
        #expect(rig.server.requests.count == 3)  // three questions that differ, and no more

        await askEverything()
        #expect(rig.server.requests.count == 3)  // and they are all kept

        await rig.service.invalidate()  // everything is forgotten, not the one answer
        await askEverything()
        #expect(rig.server.requests.count == 6)
    }

    @Test func answersOfTwoHostsAreKeptApart() async throws {
        // The same path of the project and the same branch, on two hosts: two projects.
        let merged = StubServer(routes: [Provider.gitLab.listPath: .status(200, body: try fixture("gitlab-merged"))])
        let draft = StubServer(routes: [Provider.gitLab.listPath: .status(200, body: try fixture("gitlab-draft"))])
        let service = makeService(for: [merged, draft])
        let (mergedRemote, draftRemote) = (
            try Provider.gitLab.remote(on: merged.host), try Provider.gitLab.remote(on: draft.host)
        )

        for _ in 0..<2 {
            #expect(await service.review(remote: mergedRemote, branch: "b").state == .merged)
            #expect(await service.review(remote: draftRemote, branch: "b").state == .draft)
        }

        #expect(merged.requests.count == 1 && draft.requests.count == 1)  // one each, and then kept
    }

    // MARK: The last error

    @Test func theLastErrorIsOfItsHostWhateverTheCaseOfTheHostIs() async throws {
        let broken = StubServer(routes: [Provider.gitLab.listPath: .status(503)])
        let fine = StubServer(routes: [Provider.gitLab.listPath: .status(200, body: try fixture("gitlab-merged"))])
        let service = makeService(for: [broken, fine])

        #expect(await service.lastError(host: broken.host) == nil)  // nothing has gone wrong yet
        _ = await service.review(remote: try Provider.gitLab.remote(on: broken.host), branch: "b")
        _ = await service.review(remote: try Provider.gitLab.remote(on: fine.host), branch: "b")

        #expect(await service.lastError(host: broken.host)?.contains("503") == true)
        #expect(await service.lastError(host: broken.host.uppercased())?.contains("503") == true)
        #expect(await service.lastError(host: fine.host) == nil)
        #expect(await service.lastError(host: "unheard-of.stub.test") == nil)
    }

    @Test func theLastErrorSaysInWordsWhatWentWrong() async throws {
        let rig = try Rig(reply: .status(401))
        let path = rig.provider.listPath

        _ = await rig.review()
        #expect(await rig.lastError == ReviewError.status(401).localizedDescription)

        rig.server.answer(path, with: .failure(.timedOut))
        _ = await rig.review()
        #expect(await rig.lastError == URLError(.timedOut).localizedDescription)

        rig.server.answer(path, with: .status(200, body: try gitLabList(state: "unheard-of")))
        _ = await rig.review()
        #expect(await rig.lastError == ReviewError.unknownState("unheard-of").localizedDescription)
    }

    @Test func theLastErrorIsTheLatestOne() async throws {
        let rig = try Rig(reply: .status(401))
        _ = await rig.review()
        rig.server.answer(rig.provider.listPath, with: .status(503))
        _ = await rig.review()

        #expect(await rig.lastError?.contains("503") == true)
        #expect(await rig.lastError?.contains("401") == false)
    }

    @Test func invalidateKeepsTheLastErrorUntilTheHostAnswersAgain() async throws {
        let rig = try Rig(reply: .status(401))
        _ = await rig.review()

        await rig.service.invalidate()

        #expect(await rig.lastError?.contains("401") == true)
    }

    // MARK: Which client asks, and of what

    @Test(arguments: Provider.allCases)
    func theClientIsTheOneOfTheKindOfTheHost(provider: Provider) async throws {
        let rig = try Rig(provider)

        #expect(await rig.review().state == .merged)

        #expect(rig.server.paths == [provider.listPath])  // GitLab and GitHub are asked in different places
    }

    @Test func theKindOfAHostThatHasNoOverrideIsFoundByAskingIt() async throws {
        let gitlab = StubServer(routes: [
            "/api/v4/version": .status(401), Provider.gitLab.listPath: .status(200, body: try fixture("gitlab-merged")),
        ])
        let github = StubServer(routes: [
            "/api/v4/version": .status(404), "/api/v3/meta": .status(200),
            Provider.gitHub.listPath: .status(200, body: try fixture("github-merged")),
        ])
        let detector = HostingDetector(overrides: [:], session: gitlab.session)
        let service = ReviewService(detector: detector, tokens: FakeTokens(), session: gitlab.session)

        #expect(await service.review(remote: try Provider.gitLab.remote(on: gitlab.host), branch: "b").state == .merged)
        #expect(await service.review(remote: try Provider.gitHub.remote(on: github.host), branch: "b").state == .merged)

        #expect(gitlab.paths == ["/api/v4/version", Provider.gitLab.listPath])
        #expect(github.paths == ["/api/v4/version", "/api/v3/meta", Provider.gitHub.listPath])
    }

    @Test func aHostThatIsNeitherIsUnknownAndOnlyProbedForItsKind() async throws {
        let server = StubServer()  // a 404 for everything
        let detector = HostingDetector(overrides: [:], session: server.session)
        let service = ReviewService(
            detector: detector, tokens: FakeTokens([server.host: "S3CRET"]), session: server.session)

        let r = await service.review(remote: try Provider.gitLab.remote(on: server.host), branch: "b")

        #expect(r == ReviewInfo.unknown)
        #expect(server.paths == ["/api/v4/version", "/api/v3/meta"])  // no request for a list, and so no token goes
        #expect(await service.lastError(host: server.host) != nil)
    }

    @Test func aHostThatCouldNotBeToldIsAskedAgainAndNotKeptAsUnknown() async throws {
        // The VPN is not up yet. The detector does not keep that, and the service must not either.
        let server = StubServer(routes: ["/api/v4/version": .failure(.cannotConnectToHost)])
        let detector = HostingDetector(overrides: [:], session: server.session)
        let service = ReviewService(detector: detector, tokens: FakeTokens(), session: server.session)
        let remote = try Provider.gitLab.remote(on: server.host)
        #expect(await service.review(remote: remote, branch: "b") == ReviewInfo.unknown)

        server.answer("/api/v4/version", with: .status(401))
        server.answer(Provider.gitLab.listPath, with: .status(200, body: try fixture("gitlab-merged")))

        #expect(await service.review(remote: remote, branch: "b").state == .merged)
        #expect(await service.lastError(host: server.host) == nil)
    }

    @Test func aHostThatIsSwitchedOffIsUnknownAndNothingIsAskedOfIt() async throws {
        let server = StubServer(routes: [Provider.gitLab.listPath: .status(200, body: try fixture("gitlab-merged"))])
        let detector = HostingDetector(overrides: [server.host: .unsupported], session: server.session)
        let service = ReviewService(detector: detector, tokens: FakeTokens(), session: server.session)

        let r = await service.review(remote: try Provider.gitLab.remote(on: server.host), branch: "b")

        #expect(r == ReviewInfo.unknown && server.requests.isEmpty)
        #expect(await service.lastError(host: server.host) != nil)
    }

    @Test func aGitHubProjectThatIsNotAnOwnerAndARepositoryIsUnknown() async throws {
        let rig = try Rig(.gitHub)
        let remote = try #require(RemoteURL("git@\(rig.server.host):group/sub/repo.git"))

        let r = await rig.service.review(remote: remote, branch: "b")

        #expect(r == ReviewInfo.unknown && rig.server.requests.isEmpty)
        #expect(await rig.lastError != nil)
    }

    @Test func theServiceIsALookerOfReviews() async throws {
        let rig = try Rig()
        let looking: any ReviewLooking = rig.service

        #expect(await looking.review(remote: rig.remote, branch: "b").state == .merged)
        #expect(await looking.lastError(host: rig.server.host) == nil)
        await looking.invalidate()
    }

    // MARK: The token

    @Test func theTokenOfTheHostIsSentAndIsReadOnlyWhenAsking() async throws {
        let rig = try Rig(.gitLab, token: "glpat-S3CRET")

        _ = await rig.review()
        _ = await rig.review()  // kept: nothing is asked, and no token is read

        #expect(rig.server.requests.first?.value(forHTTPHeaderField: "PRIVATE-TOKEN") == "glpat-S3CRET")
        #expect(rig.tokens.reads == [rig.server.host])
    }

    @Test func aGitHubTokenIsABearer() async throws {
        let rig = try Rig(.gitHub, token: "ghp_S3CRET")

        _ = await rig.review()

        #expect(rig.server.requests.first?.value(forHTTPHeaderField: "Authorization") == "Bearer ghp_S3CRET")
    }

    @Test(arguments: Provider.allCases)
    func aHostWithoutATokenIsAskedWithoutOne(provider: Provider) async throws {
        // A public project can be read without. If the host does not have it, it says so, and that is an error.
        let rig = try Rig(provider)

        #expect(await rig.review().state == .merged)

        let names = (rig.server.requests.first?.allHTTPHeaderFields ?? [:]).keys.map { $0.lowercased() }
        #expect(!names.contains("authorization") && !names.contains("private-token"))
    }

    @Test(arguments: Provider.allCases)
    func aStoreThatCannotBeReadIsUnknownAndNotTakenForAStoreWithoutAToken(provider: Provider) async throws {
        let rig = try Rig(provider, tokenFailure: TokenStoreError.unreadable)

        #expect(await rig.review() == ReviewInfo.unknown)

        // Not asked without a token either: that would read a project that is private as if it were not.
        #expect(rig.server.requests.isEmpty)
        let message = try #require(await rig.lastError)
        #expect(message.contains(TokenStoreError.unreadable.localizedDescription))
        #expect(await rig.review() == ReviewInfo.unknown)  // and not kept as an answer
        #expect(rig.tokens.reads.count == 2)

        rig.tokens.fail(with: nil)
        #expect(await rig.review().state == .merged)
    }

    @Test func aTokenThatCannotBeSentIsUnknownAndHasNoPlaceInTheError() async throws {
        let rig = try Rig(token: "S3CRET tok\nen")

        #expect(await rig.review() == ReviewInfo.unknown)

        #expect(rig.server.requests.isEmpty)
        #expect(await rig.lastError?.contains("S3CRET") == false)
    }

    // MARK: Hosts that do not answer

    @Test(arguments: Provider.allCases)
    func aHostThatNeverAnswersIsGivenUpOnAndHoldsUpNoLaterCall(provider: Provider) async throws {
        // The timeout of a request is for the time in which nothing arrives. A host that sends a little now and then,
        // or that is waited for by a session that waits for the network, is never over it, and a call that shares its
        // request would wait for as long.
        let rig = try Rig(provider, reply: .never, deadline: .milliseconds(200))

        let elapsed = await ContinuousClock().measure {
            #expect(await rig.review() == ReviewInfo.unknown)
        }

        #expect(elapsed < .seconds(5))
        #expect(await rig.lastError == URLError(.timedOut).localizedDescription)
        rig.server.answer(provider.listPath, with: .status(200, body: try provider.merged()))
        #expect(await rig.review().state == .merged)  // the call that was given up on is not what this one waits for
    }

    // MARK: Calls that come at once

    @Test func callsThatAskForOneBranchAtOnceShareOneRequest() async throws {
        let rig = try Rig(reply: .held)
        // Some of the callers have a remote with a port: it is the same question, and the same request.
        let withPort = try #require(RemoteURL("ssh://git@\(rig.server.host):2222/\(rig.provider.projectPath).git"))
        let calls = (0..<8).map { number in
            Task {
                await rig.service.review(remote: number.isMultiple(of: 2) ? rig.remote : withPort, branch: "feature/x")
            }
        }
        #expect(await waitUntil { rig.server.heldCount >= 1 })
        // A service that does not share would have sent its other requests by now. It is given time to, and one that
        // does share is not hurt by it: it waits for the answer.
        _ = await waitUntil(timeout: .milliseconds(300)) { rig.server.requests.count > 1 }

        rig.server.unblock(rig.provider.listPath, with: .status(200, body: try rig.provider.merged()))

        var states: [ReviewState] = []
        for call in calls { states.append(await call.value.state) }
        #expect(states == Array(repeating: .merged, count: 8))
        #expect(rig.listRequests == 1)
    }

    @Test func aHostThatIsBeingWaitedForDoesNotHoldUpAnother() async throws {
        let slow = StubServer(routes: [Provider.gitLab.listPath: .held])
        let quick = StubServer(routes: [Provider.gitLab.listPath: .status(200, body: try fixture("gitlab-merged"))])
        let service = makeService(for: [slow, quick])
        let slowRemote = try Provider.gitLab.remote(on: slow.host)
        let slowCall = Task { await service.review(remote: slowRemote, branch: "b") }
        #expect(await waitUntil { slow.heldCount == 1 })

        let quickAnswer = await service.review(remote: try Provider.gitLab.remote(on: quick.host), branch: "b")

        #expect(quickAnswer.state == .merged)
        #expect(slow.heldCount == 1)  // the other one is still out: this answer did not wait for it

        slow.unblock(Provider.gitLab.listPath, with: .status(200, body: try fixture("gitlab-merged")))
        #expect(await slowCall.value.state == .merged)
    }

    @Test func aRequestThatIsOutAfterInvalidateIsStillSharedWhenAnOlderOneComesBack() async throws {
        let rig = try Rig(reply: .held)
        let path = rig.provider.listPath
        let older = Task { await rig.review() }
        #expect(await waitUntil { rig.server.heldCount == 1 })
        await rig.service.invalidate()
        let newer = Task { await rig.review() }
        #expect(await waitUntil { rig.server.heldCount == 2 })

        // The older one is answered while the newer one is still out. It must not take the newer one's place.
        rig.server.unblockOldest(path, with: .status(200, body: try rig.provider.merged()))
        #expect(await older.value.state == .merged)
        let joiner = Task { await rig.review() }
        // A service that has lost track of the newer one would ask again by now.
        _ = await waitUntil(timeout: .milliseconds(300)) { rig.server.requests.count > 2 }

        rig.server.unblock(path, with: .status(200, body: try rig.provider.merged()))
        let (newerState, joinerState) = (await newer.value.state, await joiner.value.state)
        #expect(newerState == .merged && joinerState == .merged)
        #expect(rig.listRequests == 2)  // the older one and the newer one: the joiner asked for nothing
    }

    @Test func aRequestThatWasOutBeforeInvalidateIsNeitherJoinedNorKeptAfterIt() async throws {
        // `invalidate()` is how a caller says that what it reads next has to be read now: the answer that is on its way
        // was asked for before, and may say what is not so any more.
        let rig = try Rig(reply: .held)
        let path = rig.provider.listPath
        let closed = try listBody(rig.provider, .closed)
        let before = Task { await rig.review() }
        #expect(await waitUntil { rig.server.heldCount == 1 })

        await rig.service.invalidate()
        rig.server.answer(path, with: .status(200, body: closed))
        let after = Task { await rig.review() }
        let askedAgain = await waitUntil { rig.server.requests.count == 2 }

        // The one from before is answered at last, with what it was: a merge.
        rig.server.unblock(path, with: .status(200, body: try rig.provider.merged()))
        rig.server.answer(path, with: .status(200, body: closed))
        let (beforeState, afterState) = (await before.value.state, await after.value.state)

        #expect(askedAgain)  // the call after invalidate() did not wait for the call before it
        #expect(beforeState == .merged)  // its own caller gets what it asked for
        #expect(afterState == .closed)
        #expect(await rig.review().state == .closed)  // and what is kept is the answer to the later call
        #expect(rig.listRequests == 2)
    }
}
