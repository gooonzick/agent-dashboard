import Foundation

/// Where the merge request (GitLab) or pull request (GitHub) of a branch stands.
public enum ReviewState: String, Sendable, Codable {
    case open
    case draft
    /// The request was merged. Nothing else says so: a state that is not known, or an answer that was not understood,
    /// is `unknown`, because a worktree whose request is merged is one that the app offers to remove.
    case merged
    /// The request was closed without being merged.
    case closed
    /// The branch has no request.
    case none
    /// Nobody could say: the host cannot be asked, did not answer, or answered with something that is not understood.
    case unknown
}

/// The merge request or pull request of a branch, as far as the dashboard needs it.
public struct ReviewInfo: Sendable, Equatable, Codable {
    public let state: ReviewState
    /// The number that people know the request by: the `iid` of GitLab, the `number` of GitHub.
    public let number: Int?
    /// The page of the request in a browser. The clients of `Hosting` only give an `http` or `https` address.
    public let webURL: URL?
    /// The commit that the branch of the request was at: the `sha` of GitLab, the `head.sha` of GitHub. It is the
    /// commit that a merge took in, so a worktree whose HEAD is not that commit or one of its ancestors holds work that
    /// the merge did not take. The clients of `Hosting` give hexadecimal digits and nothing else: it is handed to git.
    public let headSHA: String?

    public init(state: ReviewState, number: Int? = nil, webURL: URL? = nil, headSHA: String? = nil) {
        self.state = state
        self.number = number
        self.webURL = webURL
        self.headSHA = headSHA
    }

    /// Nobody could say how the request stands.
    public static let unknown = ReviewInfo(state: .unknown)
    /// The branch has no request.
    public static let none = ReviewInfo(state: .none)
}
