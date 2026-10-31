import CoreModels
import Foundation
import Hosting
import Testing

@Suite(.timeLimit(.minutes(1))) struct GitHubClientTests {
    private let list = Provider.gitHub.listPath

    /// What the client says of a server that answers the list of pull requests with `body`.
    private func review(
        answering body: Data, token: String? = "t", branch: String = "feature/x"
    ) async throws -> ReviewInfo {
        let server = StubServer(routes: [list: .status(200, body: body)])
        return try await Provider.gitHub.client(host: server.host, token: token, session: server.session)
            .review(remote: Provider.gitHub.remote(on: server.host), branch: branch)
    }

    // MARK: What the brief asks for

    @Test func gitHubMergedClosedDraft() async throws {
        let server = StubServer(routes: [list: .status(200, body: try fixture("github-merged"))])
        let client = GitHubClient(host: server.host, token: "t", session: server.session)
        let remote = try Provider.gitHub.remote(on: server.host)

        let merged = try await client.review(remote: remote, branch: "feature/x")
        #expect(merged.state == .merged && merged.number == 17)
        #expect(merged.headSHA == "9fceb02d0ae598e95dc970b74767f19372d61af8")
        let url = try #require(server.requests.last?.url?.absoluteString)
        #expect(url.contains("head=gooonzick:feature%2Fx"))

        server.answer(list, with: .status(200, body: try fixture("github-closed")))
        let closed = try await client.review(remote: remote, branch: "feature/x")
        #expect(closed.state == .closed && closed.number == 18)

        server.answer(list, with: .status(200, body: try fixture("github-draft")))
        let draft = try await client.review(remote: remote, branch: "feature/x")
        #expect(draft.state == .draft && draft.number == 19)
    }

    @Test func gitHubEnterpriseUsesApiV3() async throws {
        let server = StubServer(routes: [list: .status(200, body: try fixture("github-merged"))])
        let client = GitHubClient(host: server.host, token: "t", session: server.session)

        _ = try await client.review(remote: try Provider.gitHub.remote(on: server.host), branch: "feature/x")

        let url = try #require(server.requests.first?.url?.absoluteString)
        #expect(url.hasPrefix("https://\(server.host)/api/v3/repos/gooonzick/meetily/pulls?"))
    }

    // What the brief's examples leave open: which state is which, how strict the reading is, which fields are taken and
    // how the request is written.

    // MARK: Which state is which

    @Test(arguments: [(nil, ReviewState.open), (false, .open), (true, .draft)])
    func anOpenPullRequestIsOpenOrADraft(draft: Bool?, expected: ReviewState) async throws {
        #expect(try await review(answering: try gitHubList(state: "open", draft: draft)).state == expected)
    }

    @Test func aClosedPullRequestIsMergedIfAndOnlyIfItHasAMergeTime() async throws {
        let time = "2026-10-22T14:03:11Z"
        #expect(try await review(answering: try gitHubList(state: "closed", mergedAt: NSNull())).state == .closed)
        #expect(try await review(answering: try gitHubList(state: "closed", mergedAt: time)).state == .merged)
        // Whether it was a draft does not matter once it is closed.
        #expect(
            try await review(answering: try gitHubList(state: "closed", draft: true, mergedAt: NSNull())).state
                == .closed)
        #expect(
            try await review(answering: try gitHubList(state: "closed", draft: true, mergedAt: time)).state == .merged)
    }

    @Test func aPullRequestThatIsOpenIsOpenWhateverItsMergeTimeSays() async throws {
        let r = try await review(answering: try gitHubList(state: "open", mergedAt: "2026-10-22T14:03:11Z"))
        #expect(r.state == .open)
    }

    @Test(arguments: [
        "",  // not there at all: a closed pull request that does not say whether it was merged
        #""merged_at": """#, #""merged_at": 0"#, #""merged_at": 1"#, #""merged_at": true"#, #""merged_at": false"#,
        #""merged_at": []"#, #""merged_at": {}"#, #""merged_at": ["2026-10-22T14:03:11Z"]"#,
    ])
    func aClosedPullRequestWithoutAClearMergeTimeIsAnErrorAndNeverAMerge(field: String) async {
        let json = #"[{"number": 1, "state": "closed"\#(field.isEmpty ? "" : ", " + field)}]"#
        await #expect(throws: ReviewError.unreadableAnswer) { try await review(answering: Data(json.utf8)) }
    }

    @Test(arguments: [
        "Open", "OPEN", "Closed", "CLOSED", "merged", "MERGED", "opened", "all", "draft", "locked", "", " open",
        "open\n", "closed ", "o",
    ])
    func aStateThatIsNotKnownIsAnErrorAndNeverAMerge(state: String) async throws {
        await #expect(throws: ReviewError.unknownState(state)) {
            try await review(answering: try gitHubList(state: state, mergedAt: "2026-10-22T14:03:11Z"))
        }
    }

    @Test(arguments: [
        #"[{"number": 1, "merged_at": "2026-10-22T14:03:11Z"}]"#,  // no state at all
        #"[{"number": 1, "state": null, "merged_at": "2026-10-22T14:03:11Z"}]"#,
        #"[{"number": 1, "state": 3, "merged_at": "2026-10-22T14:03:11Z"}]"#,
        #"[{"number": 1, "state": true}]"#,
        #"[{"number": 1, "state": ["closed"], "merged_at": "2026-10-22T14:03:11Z"}]"#,
        #"[{"number": 1, "State": "closed", "merged_at": "2026-10-22T14:03:11Z"}]"#,
    ])
    func aPullRequestWithoutAStateIsAnError(json: String) async {
        await #expect(throws: ReviewError.unreadableAnswer) { try await review(answering: Data(json.utf8)) }
    }

    @Test func theFirstPullRequestIsTheOneThatCounts() async throws {
        let merged = try item(of: gitHubList(state: "closed", mergedAt: "2026-10-22T14:03:11Z"))
        let open = try item(of: gitHubList(state: "open"))

        #expect(try await review(answering: try json([merged, open])).state == .merged)
        #expect(try await review(answering: try json([open, merged])).state == .open)
    }

    // MARK: Which fields are read, and how strictly

    @Test func takesTheFieldsThatMatterAndNotTheOnesThatLookLikeThem() async throws {
        // The fixture has an `id` that is not the `number`, a `url` that is not the `html_url`, and a `base.sha` and a
        // `merge_commit_sha` that are not the `head.sha`. What was merged is the head of the branch.
        let r = try await review(answering: try fixture("github-merged"))

        #expect(
            r
                == ReviewInfo(
                    state: .merged, number: 17, webURL: URL(string: "https://github.com/gooonzick/meetily/pull/17"),
                    headSHA: "9fceb02d0ae598e95dc970b74767f19372d61af8"))
    }

    @Test(arguments: [
        #"[{"state": "open"}]"#, #"[{"state": "open", "head": null}]"#, #"[{"state": "open", "head": {}}]"#,
        #"[{"state": "open", "head": {"sha": null}}]"#, #"[{"state": "open", "number": null, "html_url": null}]"#,
    ])
    func fieldsThatAreNotThereOrAreNullAreAbsent(json: String) async throws {
        #expect(try await review(answering: Data(json.utf8)) == ReviewInfo(state: .open))
    }

    @Test(arguments: [
        #"[{"state": "open", "number": "17"}]"#, #"[{"state": "open", "number": 1.5}]"#,
        #"[{"state": "open", "draft": "true"}]"#, #"[{"state": "open", "draft": 1}]"#,
        #"[{"state": "open", "html_url": 5}]"#, #"[{"state": "open", "head": "abc"}]"#,
        #"[{"state": "open", "head": ["sha"]}]"#, #"[{"state": "open", "head": {"sha": 5}}]"#,
    ])
    func aFieldOfTheWrongKindIsAnError(json: String) async {
        await #expect(throws: ReviewError.unreadableAnswer) { try await review(answering: Data(json.utf8)) }
    }

    // MARK: The request

    @Test func asksForTheNewestPullRequestOfTheBranchInAnyState() async throws {
        let server = StubServer(routes: [list: .status(200, body: try fixture("empty-list"))])
        let client = GitHubClient(host: server.host, token: "t", session: server.session)

        let r = try await client.review(remote: try Provider.gitHub.remote(on: server.host), branch: "feature/ünï")

        #expect(r == ReviewInfo.none)
        let request = try #require(server.requests.first)
        #expect(
            request.url?.absoluteString
                == "https://\(server.host)/api/v3/repos/gooonzick/meetily/pulls"
                + "?head=gooonzick:feature%2F%C3%BCn%C3%AF&state=all&sort=updated&direction=desc&per_page=1")
        #expect(request.httpMethod == "GET")
        #expect(server.requests.count == 1)
    }

    @Test func theHeadIsTheOwnerOfTheProjectAndTheBranch() async throws {
        let server = StubServer(routes: [
            "/api/v3/repos/Some-Owner/some.repo/pulls": .status(200, body: Data("[]".utf8))
        ])
        let client = GitHubClient(host: server.host, token: nil, session: server.session)

        let r = try await client.review(
            remote: try #require(RemoteURL("git@\(server.host):Some-Owner/some.repo.git")), branch: "fix/a:b")

        #expect(r == ReviewInfo.none)  // a request for another path is answered with a 404 here
        let url = try #require(server.requests.first?.url?.absoluteString)
        #expect(url.contains("head=Some-Owner:fix%2Fa%3Ab&"))  // the one `:` that is left is the one that was meant
    }

    @Test(arguments: ["a/b/c", "group/sub/deeper/repo"])
    func aProjectThatIsNotAnOwnerAndARepositoryIsAnErrorAndAsksNothing(path: String) async throws {
        let server = StubServer(routes: [
            "/api/v3/repos/\(path)/pulls": .status(200, body: try fixture("github-merged"))
        ])
        let client = GitHubClient(host: server.host, token: "t", session: server.session)
        let remote = try #require(RemoteURL("git@\(server.host):\(path).git"))

        await #expect(throws: ReviewError.notOwnerAndRepository(path)) {
            try await client.review(remote: remote, branch: "feature/x")
        }
        #expect(server.requests.isEmpty)
    }

    @Test func gitHubComIsAskedAtApiGitHubCom() async throws {
        // A name that no other test uses: servers of tests are found by it, and two would be mistaken for each other.
        let server = StubServer(
            host: "api.github.com",
            routes: ["/repos/gooonzick/meetily/pulls": .status(200, body: try fixture("github-merged"))])
        let client = GitHubClient(host: "github.com", token: "t", session: server.session)

        // The port of an `ssh://` remote is the one of SSH, and `github.com` has no API at it.
        let r = try await client.review(
            remote: try #require(RemoteURL("ssh://git@github.com:2222/gooonzick/meetily.git")), branch: "feature/x")

        #expect(r.state == .merged)
        #expect(
            server.requests.first?.url?.absoluteString
                == "https://api.github.com/repos/gooonzick/meetily/pulls"
                + "?head=gooonzick:feature%2Fx&state=all&sort=updated&direction=desc&per_page=1")
    }

    @Test func aPortOfAnEnterpriseServerIsKept() async throws {
        let server = StubServer(routes: [list: .status(200, body: Data("[]".utf8))])
        let client = GitHubClient(host: server.host, token: nil, session: server.session)

        _ = try await client.review(
            remote: try #require(RemoteURL("https://\(server.host):8443/gooonzick/meetily.git")), branch: "b")

        #expect(server.requests.first?.url?.port == 8443)
        #expect(server.requests.first?.url?.path == "/api/v3/repos/gooonzick/meetily/pulls")
    }

    @Test func theTokenIsABearerAndTheAnswerIsAskedForAsJSONOfTheCurrentVersion() async throws {
        let server = StubServer(routes: [list: .status(200, body: try fixture("github-merged"))])
        let client = GitHubClient(host: server.host, token: "ghp_S3CRET", session: server.session)

        _ = try await client.review(remote: try Provider.gitHub.remote(on: server.host), branch: "b")

        let request = try #require(server.requests.first)
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer ghp_S3CRET")
        #expect(request.value(forHTTPHeaderField: "Accept") == "application/vnd.github+json")
        #expect(request.value(forHTTPHeaderField: "X-GitHub-Api-Version") == "2022-11-28")
        #expect(request.value(forHTTPHeaderField: "PRIVATE-TOKEN") == nil)  // that is GitLab's
        let address = request.url?.absoluteString ?? ""
        #expect(!address.contains("S3CRET"))
    }

    @Test func withoutATokenItStillAsksForJSON() async throws {
        let server = StubServer(routes: [list: .status(200, body: try fixture("github-merged"))])
        let client = GitHubClient(host: server.host, token: nil, session: server.session)

        _ = try await client.review(remote: try Provider.gitHub.remote(on: server.host), branch: "b")

        let request = try #require(server.requests.first)
        #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
        #expect(request.value(forHTTPHeaderField: "Accept") == "application/vnd.github+json")
        #expect(request.value(forHTTPHeaderField: "X-GitHub-Api-Version") == "2022-11-28")
    }
}
