import CoreModels
import Foundation
import Hosting
import Testing

@Suite(.timeLimit(.minutes(1))) struct GitLabClientTests {
    private let list = Provider.gitLab.listPath

    /// What the client says of a server that answers the list of merge requests with `body`.
    private func review(
        answering body: Data, token: String? = "t", branch: String = "feature/x"
    ) async throws -> ReviewInfo {
        let server = StubServer(routes: [list: .status(200, body: body)])
        return try await Provider.gitLab.client(host: server.host, token: token, session: server.session)
            .review(remote: Provider.gitLab.remote(on: server.host), branch: branch)
    }

    // MARK: What the brief asks for

    @Test func gitLabMergedMR() async throws {
        let server = StubServer(routes: [list: .status(200, body: try fixture("gitlab-merged"))])
        let client = GitLabClient(host: server.host, token: "t", session: server.session)

        let r = try await client.review(
            remote: try #require(RemoteURL("git@\(server.host):team/app.git")), branch: "feature/ünï")

        #expect(r.state == .merged && r.headSHA == "abc" && r.number == 42)
        let request = try #require(server.requests.last)
        let url = try #require(request.url?.absoluteString)
        #expect(url.contains("projects/team%2Fapp/merge_requests"))
        #expect(url.contains("source_branch=feature%2F%C3%BCn%C3%AF"))
        #expect(request.value(forHTTPHeaderField: "PRIVATE-TOKEN") == "t")
    }

    @Test func gitLabDraftAndEmpty() async throws {
        let server = StubServer(routes: [list: .status(200, body: try fixture("gitlab-draft"))])
        let client = GitLabClient(host: server.host, token: "t", session: server.session)
        let remote = try Provider.gitLab.remote(on: server.host)

        let draft = try await client.review(remote: remote, branch: "feature/ünï")
        #expect(draft.state == .draft && draft.number == 7 && draft.headSHA == "def4567")

        server.answer(list, with: .status(200, body: try fixture("empty-list")))
        #expect(try await client.review(remote: remote, branch: "feature/ünï") == ReviewInfo.none)
    }

    // What the brief's examples leave open: which state is which, how strict the reading is, which fields are taken and
    // how the request is written.

    // MARK: Which state is which

    @Test(arguments: [
        ("opened", nil, ReviewState.open), ("opened", false, .open), ("opened", true, .draft),
        ("merged", nil, .merged), ("merged", false, .merged), ("merged", true, .merged),  // a merge is not a draft
        ("closed", nil, .closed), ("closed", true, .closed), ("locked", nil, .closed), ("locked", false, .closed),
    ])
    func readsTheStateOfAMergeRequest(state: String, draft: Bool?, expected: ReviewState) async throws {
        let r = try await review(answering: try gitLabList(state: state, draft: draft))
        #expect(r.state == expected)
    }

    @Test(arguments: [
        "Merged", "MERGED", "merge", "reopened", "open", "draft", "unknown", "", " ", "opened ", " merged", "merged\n",
        "closed.", "locked ", "m", "all",
    ])
    func aStateThatIsNotKnownIsAnErrorAndNeverAMerge(state: String) async throws {
        await #expect(throws: ReviewError.unknownState(state)) {
            try await review(answering: try gitLabList(state: state))
        }
    }

    @Test(arguments: [
        #"[{"iid": 1, "draft": false, "sha": "abc"}]"#,  // no state at all
        #"[{"iid": 1, "state": null}]"#,
        #"[{"iid": 1, "state": 3}]"#,
        #"[{"iid": 1, "state": true}]"#,
        #"[{"iid": 1, "state": ["merged"]}]"#,
        #"[{"iid": 1, "state": {"name": "merged"}}]"#,
        #"[{"iid": 1, "State": "merged"}]"#,  // a name is spelled as the host spells it
    ])
    func aMergeRequestWithoutAStateIsAnError(json: String) async {
        await #expect(throws: ReviewError.unreadableAnswer) { try await review(answering: Data(json.utf8)) }
    }

    @Test func theFirstMergeRequestIsTheOneThatCounts() async throws {
        // The list is asked for newest first and for one request. A host that sends more than one has the newest first.
        let merged = try item(of: gitLabList(state: "merged"))
        let open = try item(of: gitLabList(state: "opened"))
        let (mergedFirst, openFirst) = (try json([merged, open]), try json([open, merged]))

        #expect(try await review(answering: mergedFirst).state == .merged)
        #expect(try await review(answering: openFirst).state == .open)
    }

    // MARK: Which fields are read, and how strictly

    @Test func takesTheFieldsThatMatterAndNotTheOnesThatLookLikeThem() async throws {
        // The fixture has an `id` that is not the `iid`, a `merge_commit_sha` that is not the `sha` and a lot more.
        let r = try await review(answering: try fixture("gitlab-merged"))

        #expect(r == ReviewInfo(state: .merged, number: 42, webURL: URL(string: "https://g/mr/42"), headSHA: "abc"))
    }

    @Test func aMergeRequestThatHasNothingButAStateIsRead() async throws {
        let r = try await review(answering: Data(#"[{"state": "merged"}]"#.utf8))
        #expect(r == ReviewInfo(state: .merged))
    }

    @Test func fieldsThatAreNullAreAbsent() async throws {
        let json = #"[{"state": "opened", "iid": null, "sha": null, "web_url": null, "draft": null}]"#
        #expect(try await review(answering: Data(json.utf8)) == ReviewInfo(state: .open))
    }

    @Test(arguments: [
        #"[{"iid": "42", "state": "merged"}]"#,
        #"[{"iid": 4.5, "state": "merged"}]"#,
        #"[{"iid": [42], "state": "merged"}]"#,
        #"[{"state": "merged", "sha": 123}]"#,
        #"[{"state": "merged", "draft": "false"}]"#,
        #"[{"state": "merged", "draft": 0}]"#,
        #"[{"state": "merged", "web_url": 5}]"#,
        #"[{"state": "merged", "web_url": ["https://g/mr/1"]}]"#,
        #"[{"state": "merged", "source_project_id": "3", "target_project_id": 3}]"#,
        #"[{"state": "merged", "source_project_id": 3, "target_project_id": [3]}]"#,
    ])
    func aFieldOfTheWrongKindIsAnError(json: String) async {
        await #expect(throws: ReviewError.unreadableAnswer) { try await review(answering: Data(json.utf8)) }
    }

    // MARK: Requests of other projects

    @Test(arguments: [
        ("merged", 77, 3), ("opened", 77, 3), ("closed", 3, 77), ("merged", 1, 2),
    ])
    func aMergeRequestOfAnotherProjectIsNotThisBranchesAndNeverAMerge(
        state: String, source: Int, target: Int
    ) async throws {
        // A search by the name of a branch finds the requests of every project that has a branch of that name: a fork
        // has its own `main`. Whatever happened to a request of a fork, it is not what happened to this branch.
        let item: [String: Any] = [
            "iid": 9, "state": state, "sha": "abc", "source_project_id": source, "target_project_id": target,
        ]
        let body = try json([item])

        await #expect(throws: ReviewError.fromAnotherProject) { try await review(answering: body) }
    }

    @Test(arguments: [(3, 3), (nil, 3), (3, nil), (nil, nil)] as [(Int?, Int?)])
    func aMergeRequestOfTheProjectItselfOrOfNoKnownProjectIsRead(source: Int?, target: Int?) async throws {
        var item: [String: Any] = ["iid": 9, "state": "merged", "sha": "abc"]
        if let source { item["source_project_id"] = source }
        if let target { item["target_project_id"] = target }

        let r = try await review(answering: try json([item]))

        #expect(r.state == .merged && r.number == 9)  // with only one of the two, or none, nothing says that it is not
    }

    // MARK: The request

    @Test func asksForTheNewestMergeRequestOfTheBranchInAnyState() async throws {
        let server = StubServer(routes: [list: .status(200, body: try fixture("empty-list"))])
        let client = GitLabClient(host: server.host, token: "t", session: server.session)

        _ = try await client.review(remote: try Provider.gitLab.remote(on: server.host), branch: "feature/ünï")

        let request = try #require(server.requests.first)
        #expect(
            request.url?.absoluteString
                == "https://\(server.host)/api/v4/projects/team%2Fapp/merge_requests"
                + "?source_branch=feature%2F%C3%BCn%C3%AF&state=all&order_by=updated_at&sort=desc&per_page=1")
        #expect(request.httpMethod == "GET")
        #expect(server.requests.count == 1)
    }

    @Test(arguments: [
        ("team/app", "team%2Fapp"), ("a/b/c", "a%2Fb%2Fc"), ("group/sub/deeper/repo", "group%2Fsub%2Fdeeper%2Frepo"),
        ("team/my.app", "team%2Fmy.app"), ("my_team/app-2", "my_team%2Fapp-2"), ("team/.github", "team%2F.github"),
    ])
    func theProjectPathIsOneSegmentAndIsEncodedOnce(path: String, encoded: String) async throws {
        let server = StubServer(routes: ["/api/v4/projects/\(path)/merge_requests": .status(200, body: Data("[]".utf8))]
        )
        let client = GitLabClient(host: server.host, token: nil, session: server.session)

        let r = try await client.review(remote: try #require(RemoteURL("git@\(server.host):\(path).git")), branch: "b")

        #expect(r == ReviewInfo.none)  // a request for a path that is not the one is answered with a 404 here
        let url = try #require(server.requests.first?.url?.absoluteString)
        #expect(url.hasPrefix("https://\(server.host)/api/v4/projects/\(encoded)/merge_requests?"))
        #expect(!url.contains("%25"))
    }

    @Test func aPortOfASelfHostedServerIsKept() async throws {
        let server = StubServer(routes: [list: .status(200, body: Data("[]".utf8))])
        let client = GitLabClient(host: server.host, token: nil, session: server.session)

        _ = try await client.review(
            remote: try #require(RemoteURL("https://\(server.host):8443/team/app.git")), branch: "b")

        #expect(server.requests.first?.url?.port == 8443)
        #expect(server.requests.first?.url?.scheme == "https")
    }

    @Test func gitLabComIsAskedAtItsOwnAddressWhateverPortTheRemoteNames() async throws {
        // A name that no other test uses: servers of tests are found by it, and two would be mistaken for each other.
        let server = StubServer(host: "gitlab.com", routes: [list: .status(200, body: Data("[]".utf8))])
        let client = GitLabClient(host: "gitlab.com", token: nil, session: server.session)

        _ = try await client.review(
            remote: try #require(RemoteURL("ssh://git@gitlab.com:2222/team/app.git")), branch: "b")

        #expect(server.requests.first?.url?.host == "gitlab.com" && server.requests.first?.url?.port == nil)
    }

    @Test func theTokenGoesInItsHeaderAndNowhereElse() async throws {
        let server = StubServer(routes: [list: .status(200, body: try fixture("gitlab-merged"))])
        let client = GitLabClient(host: server.host, token: "glpat-S3CRET", session: server.session)

        _ = try await client.review(remote: try Provider.gitLab.remote(on: server.host), branch: "b")

        let request = try #require(server.requests.first)
        #expect(request.value(forHTTPHeaderField: "PRIVATE-TOKEN") == "glpat-S3CRET")
        #expect(request.value(forHTTPHeaderField: "Authorization") == nil)  // that is GitHub's
        let address = request.url?.absoluteString ?? ""
        #expect(!address.contains("S3CRET"))
    }
}
