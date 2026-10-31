import CoreModels
import Foundation
import Hosting
import Synchronization
import Testing

/// The JSON of the fixture `name`, as a host sends it.
func fixture(_ name: String) throws -> Data {
    let url = try #require(Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures"))
    return try Data(contentsOf: url)
}

/// The JSON of `value`.
func json(_ value: Any) throws -> Data {
    try JSONSerialization.data(withJSONObject: value)
}

/// The first element of the JSON list `data`.
func item(of data: Data) throws -> Any {
    try #require((try JSONSerialization.jsonObject(with: data) as? [Any])?.first)
}

/// The JSON of a list that holds one request of GitLab in `state`, and nothing else that matters.
func gitLabList(state: String, draft: Bool? = nil, sha: String? = "abc") throws -> Data {
    var item: [String: Any] = ["iid": 1, "state": state]
    if let draft { item["draft"] = draft }
    if let sha { item["sha"] = sha }
    return try json([item])
}

/// The JSON of a list that holds one pull request of GitHub in `state`. `mergedAt` is what `merged_at` holds: a time,
/// or `NSNull()` for null, which is what a pull request that was not merged has. With `nil` the field is not there.
func gitHubList(
    state: String, draft: Bool? = nil, mergedAt: Any? = NSNull(), sha: String? = "abc"
) throws -> Data {
    var item: [String: Any] = ["number": 1, "state": state]
    if let draft { item["draft"] = draft }
    if let mergedAt { item["merged_at"] = mergedAt }
    if let sha { item["head"] = ["sha": sha] }
    return try json([item])
}

/// Waits until `condition` holds, for `timeout` at the most. Returns whether it did.
func waitUntil(timeout: Duration = .seconds(5), _ condition: () -> Bool) async -> Bool {
    let deadline = ContinuousClock.now + timeout
    while !condition() {
        guard ContinuousClock.now < deadline else { return false }
        try? await Task.sleep(for: .milliseconds(5))
    }
    return true
}

/// The two hosting services, for the tests that both of their clients have to pass in the same way.
enum Provider: CaseIterable, Sendable, CustomTestStringConvertible {
    case gitLab
    case gitHub

    var testDescription: String { self == .gitLab ? "GitLab" : "GitHub" }

    var kind: HostingKind { self == .gitLab ? .gitlab : .github }

    /// The path of a project, as it is in the address of a remote.
    var projectPath: String { self == .gitLab ? "team/app" : "gooonzick/meetily" }

    /// The path at which the requests of that project are asked for on a host that is not `github.com`, as a stub
    /// server sees it: with the percent escapes read, so that `team%2Fapp` is `team/app` here.
    var listPath: String {
        self == .gitLab ? "/api/v4/projects/team/app/merge_requests" : "/api/v3/repos/gooonzick/meetily/pulls"
    }

    /// The path of a request as it is written in its address, on a host that is not `github.com`: with the slashes of a
    /// project of GitLab in one segment of it, as `%2F`.
    var apiPath: String {
        self == .gitLab ? "/api/v4/projects/team%2Fapp/merge_requests" : "/api/v3/repos/gooonzick/meetily/pulls"
    }

    /// The name of the query parameter that holds the branch.
    var branchParameter: String { self == .gitLab ? "source_branch" : "head" }

    /// What the parameter of the branch holds, for a branch that is already percent-encoded as `branch`.
    func branchValue(encoded branch: String) -> String {
        self == .gitLab ? branch : "gooonzick:\(branch)"
    }

    /// A list with a request that is merged, as the host sends it.
    func merged() throws -> Data { try fixture(self == .gitLab ? "gitlab-merged" : "github-merged") }

    /// A list with a request that is merged and has `sha` as its head, or none if `sha` is `nil`.
    func list(mergedWith sha: String?) throws -> Data {
        switch self {
        case .gitLab: try gitLabList(state: "merged", sha: sha)
        case .gitHub: try gitHubList(state: "closed", mergedAt: "2026-10-22T14:03:11Z", sha: sha)
        }
    }

    /// A list with a request that is merged and whose page is at `address`.
    func list(mergedAt address: String) throws -> Data {
        switch self {
        case .gitLab: try json([["iid": 3, "state": "merged", "web_url": address]])
        case .gitHub:
            try json([["number": 3, "state": "closed", "merged_at": "2026-10-22T14:03:11Z", "html_url": address]])
        }
    }

    func remote(on host: String) throws -> RemoteURL {
        try #require(RemoteURL("git@\(host):\(projectPath).git"))
    }

    func client(host: String, token: String?, session: URLSession) -> any ReviewProviding {
        switch self {
        case .gitLab: GitLabClient(host: host, token: token, session: session)
        case .gitHub: GitHubClient(host: host, token: token, session: session)
        }
    }
}

extension StubServer {
    /// The requests that were asked for the list of requests, and not for anything else (a probe of the host).
    func listRequests(of provider: Provider) -> [URLRequest] {
        requests.filter { $0.url?.path == provider.listPath }
    }
}

/// A token store in memory that remembers what it was asked for, and can be made to fail.
final class FakeTokens: TokenStoring, Sendable {
    private struct State: Sendable {
        var tokens: [String: String]
        var failure: (any Error)?
        var reads: [String] = []
    }
    private let state: Mutex<State>

    init(_ tokens: [String: String] = [:], failure: (any Error)? = nil) {
        state = Mutex(State(tokens: tokens, failure: failure))
    }

    /// The hosts whose token was asked for, in order.
    var reads: [String] { state.withLock { $0.reads } }

    /// From now on, reading a token throws `error`, or with `nil` works again.
    func fail(with error: (any Error)?) {
        state.withLock { $0.failure = error }
    }

    func token(for host: String) throws -> String? {
        try state.withLock { state in
            state.reads.append(host)
            if let failure = state.failure { throw failure }
            return state.tokens[host]
        }
    }

    func setToken(_ token: String?, for host: String) throws {
        state.withLock { $0.tokens[host] = token }
    }
}
