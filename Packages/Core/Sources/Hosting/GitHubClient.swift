import CoreModels
import Foundation

/// Asks GitHub, or a GitHub Enterprise server, for the pull request of a branch: `GET /repos/<owner>/<repo>/pulls`.
public struct GitHubClient: ReviewProviding {
    private let host: String
    private let token: AccessToken?
    private let session: URLSession

    /// - Parameters:
    ///   - host: `github.com`, which is asked at `api.github.com`, or a GitHub Enterprise server, which is asked at its
    ///     own address under `/api/v3`. The client asks about the projects of this host only.
    ///   - token: The access token for `host`, or `nil` to ask without one, which a public project allows. It is sent
    ///     as a bearer in the `Authorization` header, and nowhere else.
    ///   - session: What the requests are sent with. They carry no cookie, but the session may add a header or a
    ///     credential of its own, so this is a session that has none, such as an ephemeral one.
    public init(host: String, token: String?, session: URLSession) {
        self.host = host.lowercased()
        self.token = token.map(AccessToken.init)
        self.session = session
    }

    public func review(remote: RemoteURL, branch: String) async throws -> ReviewInfo {
        try HostingAPI.check(remote, on: host, branch: branch)
        let names = remote.projectPath.split(separator: "/")
        guard names.count == 2 else { throw ReviewError.notOwnerAndRepository(remote.projectPath) }
        let (owner, repository) = (HostingAPI.encode(String(names[0])), HostingAPI.encode(String(names[1])))
        let credential = try token?.headerValue()

        let isGitHubCom = host == "github.com"
        let url = try HostingAPI.url(
            host: isGitHubCom ? "api.github.com" : host,
            // An Enterprise server is asked at the port that its remote names, if it names one. For an `ssh://`
            // remote that is the port of SSH, which the web interface does not have, and `RemoteURL` does not keep the
            // scheme to tell the two apart. GitHub.com is asked at the usual port.
            port: isGitHubCom ? nil : remote.port,
            path: (isGitHubCom ? "" : "/api/v3") + "/repos/\(owner)/\(repository)/pulls",
            // `head` is the branch of the owner of the project, as `owner:branch`: a pull request from a fork has
            // another owner, and is not the one of this branch. The owner is written as it is, and the `:` stays.
            query: [
                ("head", "\(owner):\(HostingAPI.encode(branch))"), ("state", "all"), ("sort", "updated"),
                ("direction", "desc"), ("per_page", "1"),
            ])
        var headers = ["Accept": "application/vnd.github+json", "X-GitHub-Api-Version": "2022-11-28"]
        if let credential { headers["Authorization"] = "Bearer \(credential)" }

        let requests = try await HostingAPI.list(of: PullRequest.self, at: url, headers: headers, using: session)
        return try requests.first?.info() ?? ReviewInfo.none
    }
}

/// A pull request, as far as it is read. Fields that are not named here are not looked at, and fields that are named
/// and are not there are `nil`, except the `state`, and the `merged_at` of a closed one: there is no telling what a
/// pull request is without them.
private struct PullRequest: Decodable {
    let state: String
    let number: Int?
    let draft: Bool?
    let mergeTime: MergeTime
    /// The page of the pull request, and not its `url`, which is the one of the API.
    let htmlURL: String?
    let head: Head?

    /// What `merged_at` says. Not being there is not the same as being `null`: a closed pull request that does not say
    /// whether it was merged is not one that was not.
    enum MergeTime {
        case absent
        case null
        case at(String)
    }

    struct Head: Decodable {
        /// The commit that the branch was at, and not the `sha` of the base or the `merge_commit_sha` of the merge.
        let sha: String?
    }

    private enum CodingKeys: String, CodingKey {
        case state, number, draft, head
        case mergedAt = "merged_at"
        case htmlURL = "html_url"
    }

    init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        state = try values.decode(String.self, forKey: .state)
        number = try values.decodeIfPresent(Int.self, forKey: .number)
        draft = try values.decodeIfPresent(Bool.self, forKey: .draft)
        htmlURL = try values.decodeIfPresent(String.self, forKey: .htmlURL)
        head = try values.decodeIfPresent(Head.self, forKey: .head)
        if !values.contains(.mergedAt) {
            mergeTime = .absent
        } else if try values.decodeNil(forKey: .mergedAt) {
            mergeTime = .null
        } else {
            mergeTime = .at(try values.decode(String.self, forKey: .mergedAt))
        }
    }

    func info() throws -> ReviewInfo {
        let reviewState: ReviewState
        switch state {
        case "open":
            reviewState = draft == true ? .draft : .open
        case "closed":
            switch mergeTime {
            case .null: reviewState = .closed
            case .at(let time) where !time.isEmpty: reviewState = .merged
            // Not there, or a time that is no time: whether it was merged is not said.
            case .absent, .at: throw ReviewError.unreadableAnswer
            }
        default:
            throw ReviewError.unknownState(state)
        }
        return ReviewInfo(
            state: reviewState, number: number, webURL: HostingAPI.webURL(htmlURL),
            headSHA: try HostingAPI.commitID(head?.sha))
    }
}
