import CoreModels
import Foundation
import Hosting
import Testing

/// A branch name, and what it has to be in the query of a request.
struct BranchEncoding: Sendable, CustomTestStringConvertible {
    let branch: String
    let encoded: String
    var testDescription: String { "\(branch.debugDescription) -> \(encoded)" }

    init(_ branch: String, _ encoded: String) {
        self.branch = branch
        self.encoded = encoded
    }
}

let branchEncodings = [
    // Everything but a letter, a digit and `-`, `.`, `_`, `~` is written as the bytes of its UTF-8, in percent escapes.
    BranchEncoding("feature/x", "feature%2Fx"), BranchEncoding("feature/ünï", "feature%2F%C3%BCn%C3%AF"),
    BranchEncoding("x~y.z-w_v", "x~y.z-w_v"), BranchEncoding("A-Z_0.9", "A-Z_0.9"),
    // What a query would read as something else: a space, `+`, the end of a value, of a name, of the query.
    BranchEncoding("a b", "a%20b"), BranchEncoding("fix+1", "fix%2B1"), BranchEncoding("a&b=c", "a%26b%3Dc"),
    BranchEncoding("a#b", "a%23b"), BranchEncoding("a?b", "a%3Fb"), BranchEncoding("100%", "100%25"),
    BranchEncoding("%2F", "%252F"),  // the letters of an escape are not one
    BranchEncoding("a:b", "a%3Ab"), BranchEncoding("a@b", "a%40b"), BranchEncoding("a;b,c", "a%3Bb%2Cc"),
    BranchEncoding("$x", "%24x"), BranchEncoding("(x)!*'", "%28x%29%21%2A%27"), BranchEncoding("[x]", "%5Bx%5D"),
    BranchEncoding("a\"b<c>d", "a%22b%3Cc%3Ed"), BranchEncoding("a\\b", "a%5Cb"),
    BranchEncoding("{x}|^`", "%7Bx%7D%7C%5E%60"),
    BranchEncoding("a\nb", "a%0Ab"), BranchEncoding("日本", "%E6%97%A5%E6%9C%AC"), BranchEncoding("🙂", "%F0%9F%99%82"),
]

/// What `GitLabClient` and `GitHubClient` have in common: the same answers are read in the same way, and the same
/// requests are written in the same way. What is particular to one of them is in its own tests.
@Suite(.timeLimit(.minutes(1))) struct ReviewClientTests {
    /// A server that answers the list of `provider` with `reply` (a merged request, if `nil`), a client for it, and
    /// a remote on it.
    private func setUp(
        _ provider: Provider, answering reply: StubReply? = nil, token: String? = "t"
    ) throws -> (server: StubServer, client: any ReviewProviding, remote: RemoteURL) {
        let server = StubServer(routes: [provider.listPath: try reply ?? .status(200, body: provider.merged())])
        let client = provider.client(host: server.host, token: token, session: server.session)
        return (server, client, try provider.remote(on: server.host))
    }

    // MARK: What the host may answer

    @Test(
        arguments: Provider.allCases,
        [
            // Redirects, which are not followed; other 2xx, which the list does not come with; and what a host or a
            // proxy says when it cannot or will not answer. Each has the body of a merged request: the status decides.
            201, 202, 204, 206, 301, 302, 304, 307, 308, 400, 401, 403, 404, 408, 410, 422, 429, 500, 502, 503, 504,
        ])
    func anAnswerThatIsNotA200IsAnErrorWhateverItHolds(provider: Provider, status: Int) async throws {
        let (_, client, remote) = try setUp(provider, answering: .status(status, body: try provider.merged()))

        await #expect(throws: ReviewError.status(status)) {
            try await client.review(remote: remote, branch: "feature/x")
        }
    }

    @Test(
        arguments: Provider.allCases,
        [
            "", " ", "not json", "<html><body>Sign in to continue</body></html>", "{}", "[1, 2]", "null", "true",
            #""merged""#,
            #"{"message": "404 Project Not Found"}"#, "[{}]", "[null]", #"[{"state": "merged""#,
            #"[{"state": "merged"}] and then some"#,
        ])
    func aBodyThatIsNotAListOfRequestsIsAnError(provider: Provider, body: String) async throws {
        let (_, client, remote) = try setUp(provider, answering: .status(200, body: Data(body.utf8)))

        await #expect(throws: ReviewError.unreadableAnswer) {
            try await client.review(remote: remote, branch: "feature/x")
        }
    }

    @Test(
        arguments: Provider.allCases,
        [
            URLError.Code.timedOut, .cannotFindHost, .cannotConnectToHost, .secureConnectionFailed,
            .serverCertificateUntrusted, .notConnectedToInternet, .networkConnectionLost,
        ])
    func aHostThatCannotBeReachedIsAnError(provider: Provider, code: URLError.Code) async throws {
        let (_, client, remote) = try setUp(provider, answering: .failure(code))

        let error = await #expect(throws: URLError.self) {
            try await client.review(remote: remote, branch: "feature/x")
        }

        #expect(error?.code == code)
    }

    @Test(arguments: Provider.allCases)
    func aRedirectIsNotFollowedAndTakesNoTokenAlong(provider: Provider) async throws {
        // The host sends the client elsewhere, to a server that would say that the request is merged. What a host says
        // is what it says, and its token is for it and for no other.
        let elsewhere = StubServer(routes: [provider.listPath: .status(200, body: try provider.merged())])
        let target = try #require(URL(string: "https://\(elsewhere.host)\(provider.listPath)"))
        let (_, client, remote) = try setUp(provider, answering: .redirect(to: target), token: "S3CRET")

        await #expect(throws: ReviewError.status(302)) { try await client.review(remote: remote, branch: "feature/x") }

        #expect(elsewhere.requests.isEmpty)
    }

    // MARK: The head commit

    @Test(
        arguments: Provider.allCases,
        [
            "abc", "ABCDEF", "0123456789abcdef", "0123456789abcdef0123456789abcdef01234567",  // SHA-1
            String(repeating: "f", count: 64),  // SHA-256
        ])
    func aCommitIdIsTakenAsItIs(provider: Provider, sha: String) async throws {
        let (_, client, remote) = try setUp(provider, answering: .status(200, body: try provider.list(mergedWith: sha)))

        #expect(try await client.review(remote: remote, branch: "feature/x").headSHA == sha)
    }

    @Test(
        arguments: Provider.allCases,
        [
            // Git takes more than a commit id for a commit: `HEAD` or a branch name would make the head of a worktree
            // "contained in" whatever it is itself, and the id is what a merge is checked against.
            "HEAD", "main", "origin/main", "HEAD~1", "@", "v1.0", "refs/heads/main", "abc^", "abc..def",
            // Or for an option, or for more than one word.
            "--help", "-x", "abc def", " abc", "abc ", "abc\n", "ünï", "ghij", "0x1234",
            "", String(repeating: "a", count: 65),
        ])
    func anythingThatIsNoCommitIdIsAnErrorAndNeverAMerge(provider: Provider, sha: String) async throws {
        let (_, client, remote) = try setUp(provider, answering: .status(200, body: try provider.list(mergedWith: sha)))

        await #expect(throws: ReviewError.unreadableAnswer) {
            try await client.review(remote: remote, branch: "feature/x")
        }
    }

    @Test(arguments: Provider.allCases)
    func aMergedRequestWithoutAHeadCommitIsStillMerged(provider: Provider) async throws {
        // The head is what a merge is checked against. Without one it cannot be, which is for the caller to see.
        let (_, client, remote) = try setUp(provider, answering: .status(200, body: try provider.list(mergedWith: nil)))

        let r = try await client.review(remote: remote, branch: "feature/x")

        #expect(r.state == .merged && r.headSHA == nil)
    }

    // MARK: The address of the page

    @Test(
        arguments: Provider.allCases,
        [
            "http://g/mr/1", "https://g/mr/1", "HTTPS://G/mr/1", "https://g:8443/a/b/-/merge_requests/1",
        ])
    func aWebAddressIsTaken(provider: Provider, address: String) async throws {
        let (_, client, remote) = try setUp(
            provider, answering: .status(200, body: try provider.list(mergedAt: address)))

        #expect(try await client.review(remote: remote, branch: "feature/x").webURL == URL(string: address))
    }

    @Test(
        arguments: Provider.allCases,
        [
            // The address is opened on a click. A host does not get to pick what is opened.
            "file:///Applications/Calculator.app", "javascript:alert(1)", "vscode://file/etc/passwd", "ftp://g/mr/1",
            "x-apple.systempreferences:com.apple.preference.security", "//g/mr/1", "/mr/1", "mr/1", "", "https:",
            "https://",
            "not an address",
        ])
    func anAddressThatIsNoWebAddressIsDropped(provider: Provider, address: String) async throws {
        let (_, client, remote) = try setUp(
            provider, answering: .status(200, body: try provider.list(mergedAt: address)))

        let r = try await client.review(remote: remote, branch: "feature/x")

        #expect(r.state == .merged && r.number == 3 && r.webURL == nil)  // the rest of the answer is not given up
    }

    // MARK: The token

    @Test(arguments: Provider.allCases, [nil, ""] as [String?])
    func noTokenMeansNoCredentialAtAll(provider: Provider, token: String?) async throws {
        // A project that is public can be read without one, and an empty token is no token.
        let (server, client, remote) = try setUp(provider, token: token)

        let r = try await client.review(remote: remote, branch: "feature/x")

        #expect(r.state == .merged)
        let request = try #require(server.requests.first)
        let names = (request.allHTTPHeaderFields ?? [:]).keys.map { $0.lowercased() }
        #expect(!names.contains("authorization") && !names.contains("cookie") && !names.contains("proxy-authorization"))
        #expect(!names.contains(where: { $0.contains("token") }))  // `PRIVATE-TOKEN`, `X-…-Token`
    }

    @Test(
        arguments: Provider.allCases,
        [
            // Anything that is not one word of printable ASCII cannot be put in a header as it is, and a token with a
            // line break in it could put a header of its own in.
            "tok en", "tok\n", "\ttok", " tok", " ", "tok\r\nX-Evil: 1", "tökén", "tok\u{7F}", "tok\u{0}",
            "tok\u{2028}x",
        ])
    func aTokenThatCannotBeSentAsAHeaderIsAnErrorAndAsksNothing(provider: Provider, token: String) async throws {
        let (server, client, remote) = try setUp(provider, token: token)

        let error = await #expect(throws: ReviewError.self) {
            try await client.review(remote: remote, branch: "feature/x")
        }

        #expect(error == .unusableToken)
        #expect(server.requests.isEmpty)  // not even without it: a project that is not public would answer with a 404
    }

    @Test(arguments: Provider.allCases)
    func aTokenIsInNothingButItsHeader(provider: Provider) async throws {
        // Not in the address, not in another header, and not in what is thrown when the request goes wrong.
        let secret = "S3CRET-tOkEn_0123456789"
        let (server, client, remote) = try setUp(
            provider, answering: .status(401, body: Data("{}".utf8)), token: secret)

        let error = await #expect(throws: ReviewError.self) {
            try await client.review(remote: remote, branch: "feature/x")
        }

        let thrown = try #require(error)
        for text in [String(describing: thrown), String(reflecting: thrown), thrown.localizedDescription] {
            #expect(!text.contains(secret), "\(text)")
        }
        let request = try #require(server.requests.first)
        #expect(request.httpBody == nil && request.httpBodyStream == nil)
        let address = request.url?.absoluteString ?? ""
        #expect(!address.contains(secret))
        let others = (request.allHTTPHeaderFields ?? [:]).filter {
            !["authorization", "private-token"].contains($0.key.lowercased())
        }
        #expect(!others.values.contains(where: { $0.contains(secret) }))
    }

    @Test(arguments: Provider.allCases)
    func aClientNeverShowsItsToken(provider: Provider) {
        // A client has to keep the token that it sends. That must not put it in a description, a dump or a log.
        let secret = "S3CRET-tOkEn_0123456789"
        let client = provider.client(host: "host.example", token: secret, session: StubServer().session)
        var dumped = ""
        dump(client, to: &dumped)

        for text in [String(describing: client), String(reflecting: client), dumped] {
            #expect(!text.contains(secret), "\(text)")
        }
    }

    // MARK: What is asked, and of whom

    @Test(
        arguments: Provider.allCases,
        [
            // The port of a remote is mostly the one of SSH, which the web interface does not have, and `RemoteURL`
            // does not keep the scheme to tell the two apart. The API is asked at the usual port of HTTPS, whatever
            // the remote names, for GitLab and for a GitHub Enterprise server alike.
            "ssh://git@{host}:2222/{path}.git", "ssh://git@{host}:22/{path}.git", "ssh://git@{host}/{path}.git",
            "git@{host}:{path}.git", "git://{host}:9418/{path}.git",
            // Not even when it may well be the one of the web interface.
            "https://{host}:8443/{path}.git", "http://{host}:3000/{path}.git",
        ])
    func thePortOfARemoteIsNeverUsedForTheRequest(provider: Provider, form: String) async throws {
        let server = StubServer(routes: [provider.listPath: .status(200, body: try provider.merged())])
        let client = provider.client(host: server.host, token: "t", session: server.session)
        let raw = form.replacing("{host}", with: server.host).replacing("{path}", with: provider.projectPath)

        let r = try await client.review(remote: try #require(RemoteURL(raw)), branch: "feature/x")

        #expect(r.state == .merged)
        let url = try #require(server.requests.first?.url)
        #expect(url.port == nil)
        #expect(url.absoluteString.hasPrefix("https://\(server.host)\(provider.apiPath)?"), "\(url)")
    }

    @Test(arguments: Provider.allCases)
    func theRequestIsAPlainHTTPSGetThatKeepsToItself(provider: Provider) async throws {
        let (server, client, remote) = try setUp(provider)

        _ = try await client.review(remote: remote, branch: "feature/x")

        let request = try #require(server.requests.first)
        let url = try #require(request.url)
        #expect(request.httpMethod == "GET" && request.httpBody == nil && request.httpBodyStream == nil)
        #expect(url.scheme == "https" && url.host == server.host && url.fragment == nil)
        #expect(url.user == nil && url.password == nil)
        #expect(request.httpShouldHandleCookies == false)  // no cookie of the session goes with it
        #expect(request.cachePolicy == .reloadIgnoringLocalCacheData)  // the service keeps answers, not the session
        #expect(request.timeoutInterval > 0 && request.timeoutInterval <= 30)  // the default is a minute
        #expect(server.requests.count == 1)
    }

    @Test(arguments: Provider.allCases, branchEncodings)
    func aBranchIsWrittenInTheQueryWithEverythingButUnreservedCharactersEscaped(
        provider: Provider, encoding: BranchEncoding
    ) async throws {
        let (server, client, remote) = try setUp(provider)

        _ = try await client.review(remote: remote, branch: encoding.branch)

        let url = try #require(server.requests.first?.url)
        let items = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false)?.percentEncodedQueryItems)
        let values = items.filter { $0.name == provider.branchParameter }.map(\.value)
        #expect(values == [provider.branchValue(encoded: encoding.encoded)])
        #expect(items.count == 5)  // and no parameter has been made by the branch
    }

    @Test(arguments: Provider.allCases)
    func theHostOfAClientIsNotCaseSensitive(provider: Provider) async throws {
        let server = StubServer(routes: [provider.listPath: .status(200, body: try provider.merged())])
        let client = provider.client(host: server.host.uppercased(), token: "t", session: server.session)

        let r = try await client.review(remote: try provider.remote(on: server.host), branch: "feature/x")

        #expect(r.state == .merged)
    }

    @Test(arguments: Provider.allCases)
    func aProjectOfAnotherHostIsNotAskedAboutAndGetsNoToken(provider: Provider) async throws {
        // The token is for one host, and the project that the remote names is not one of it: a project of the same name
        // may be there, with another merge request, or none.
        let mine = StubServer(routes: [provider.listPath: .status(200, body: try provider.merged())])
        let other = StubServer(routes: [provider.listPath: .status(200, body: try provider.merged())])
        let client = provider.client(host: mine.host, token: "S3CRET", session: mine.session)

        await #expect(throws: ReviewError.otherHost) {
            try await client.review(remote: try provider.remote(on: other.host), branch: "feature/x")
        }

        #expect(mine.requests.isEmpty && other.requests.isEmpty)
    }

    @Test(arguments: Provider.allCases)
    func noBranchIsNotAskedAboutBecauseTheHostWouldAnswerForAllOfThem(provider: Provider) async throws {
        let (server, client, remote) = try setUp(provider)

        await #expect(throws: ReviewError.noBranch) { try await client.review(remote: remote, branch: "") }

        #expect(server.requests.isEmpty)
    }
}
