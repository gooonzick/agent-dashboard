import CoreModels
import Foundation

/// Asks a GitLab server for the merge request of a branch: `GET /api/v4/projects/<project>/merge_requests`.
public struct GitLabClient: ReviewProviding {
    private let host: String
    private let token: AccessToken?
    private let session: URLSession

    /// - Parameters:
    ///   - host: The server, `gitlab.com` or one of a company. The client asks about the projects of this host only.
    ///   - token: The personal access token for `host`, or `nil` to ask without one, which a public project allows. It
    ///     is sent in the `PRIVATE-TOKEN` header, and nowhere else.
    ///   - session: What the requests are sent with. They carry no cookie, but the session may add a header or a
    ///     credential of its own, so this is a session that has none, such as an ephemeral one.
    public init(host: String, token: String?, session: URLSession) {
        self.host = host.lowercased()
        self.token = token.map(AccessToken.init)
        self.session = session
    }

    public func review(remote: RemoteURL, branch: String) async throws -> ReviewInfo {
        try HostingAPI.check(remote, on: host, branch: branch)
        let credential = try token?.headerValue()
        let url = try HostingAPI.url(
            host: host,
            // The path of the project is one segment of the address, slashes and all: `team%2Fapp`.
            path: "/api/v4/projects/\(HostingAPI.encode(remote.projectPath))/merge_requests",
            query: [
                ("source_branch", HostingAPI.encode(branch)), ("state", "all"), ("order_by", "updated_at"),
                ("sort", "desc"), ("per_page", "1"),
            ])
        let headers = credential.map { ["PRIVATE-TOKEN": $0] } ?? [:]

        let requests = try await HostingAPI.list(of: MergeRequest.self, at: url, headers: headers, using: session)
        return try requests.first?.info() ?? ReviewInfo.none
    }
}

/// A merge request, as far as it is read. Fields that are not named here are not looked at, and fields that are named
/// and are not there are `nil`, except the `state`: there is no telling what a merge request is without it.
private struct MergeRequest: Decodable {
    let state: String
    /// The number in the project, which is what people mean by `!42`, and not the `id` that is one in the whole server.
    let iid: Int?
    let draft: Bool?
    /// The commit that the source branch was at, and not the `merge_commit_sha`, which is the one that the merge made.
    let sha: String?
    let webURL: String?
    /// The projects that the request comes from and goes to. They are the same, unless the request is one of a fork.
    let sourceProjectID: Int?
    let targetProjectID: Int?

    private enum CodingKeys: String, CodingKey {
        case state, iid, draft, sha
        case webURL = "web_url"
        case sourceProjectID = "source_project_id"
        case targetProjectID = "target_project_id"
    }

    func info() throws -> ReviewInfo {
        // The requests of a branch are found by its name, and that finds those of every project that has a branch of
        // the name, forks included: a fork has a `main` of its own. Whatever came of one of them, it is not what came
        // of this branch. (Where the host does not say where a request comes from, there is nothing to tell.)
        if let source = sourceProjectID, let target = targetProjectID, source != target {
            throw ReviewError.fromAnotherProject
        }
        let reviewState: ReviewState
        switch state {
        case "opened": reviewState = draft == true ? .draft : .open
        case "merged": reviewState = .merged
        case "closed", "locked": reviewState = .closed
        default: throw ReviewError.unknownState(state)
        }
        return ReviewInfo(
            state: reviewState, number: iid, webURL: HostingAPI.webURL(webURL), headSHA: try HostingAPI.commitID(sha))
    }
}
