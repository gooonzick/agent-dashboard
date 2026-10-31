import CoreModels
import Foundation

/// Asks a hosting service for the merge request or pull request of a branch.
public protocol ReviewProviding: Sendable {
    /// How the request of `branch` in the project of `remote` stands. If the branch has had several, it is the one that
    /// was changed last. A branch that has none is `.none`. A request that is not of this project, such as one of a
    /// fork whose branch has the same name, is not the branch's, and the answer to it is an error.
    ///
    /// Throws if the answer is not a sure one: the host cannot be reached, refuses, or says something that is not
    /// understood. Whatever is thrown, no `.merged` has been answered.
    func review(remote: RemoteURL, branch: String) async throws -> ReviewInfo
}

/// Why a hosting service could not say how the request of a branch stands.
///
/// None of the descriptions holds the token or anything that the host sent: they end up on the screen, and a host is
/// not to be trusted with what is shown there.
public enum ReviewError: Error, Equatable, LocalizedError {
    /// The remote is not on the host that the client was made for. Its token is for that host, and the project that the
    /// remote names is not one of that host.
    case otherHost
    /// There is no branch. A search for the requests of no branch in particular answers with those of all of them.
    case noBranch
    /// A GitHub project is the `owner/repo` of its address, and this path is not that.
    case notOwnerAndRepository(String)
    /// The token is not one word of printable ASCII, so it cannot be sent in a header as it is.
    case unusableToken
    /// The host is neither GitLab nor GitHub, or the app could not tell for now.
    case hostNotRecognized
    /// The token of the host could not be read from where it is kept.
    case tokenUnreadable(String)
    /// The host answered with this HTTP status, where it should have sent the list of requests.
    case status(Int)
    /// The answer is not the list of requests that the API sends: not HTTP, not JSON, or a request whose state or other
    /// fields that matter are missing or of another kind.
    case unreadableAnswer
    /// The request has a state that this app does not know. Whatever it means, it is not a merge.
    case unknownState(String)
    /// The request that was found comes from another project, a fork that has a branch of the same name. It is not
    /// the one of this branch, and which one is, if any, cannot be told from it.
    case fromAnotherProject

    public var errorDescription: String? {
        switch self {
        case .otherHost:
            return "The project is not on the host that this client talks to."
        case .noBranch:
            return "There is no branch to look up."
        case .notOwnerAndRepository(let path):
            return "A GitHub project is an owner and a repository, which \"\(path)\" is not."
        case .unusableToken:
            return "The token holds characters that cannot be sent in a header."
        case .hostNotRecognized:
            return "It could not be told whether this host runs GitLab or GitHub."
        case .tokenUnreadable(let reason):
            return "The token of this host could not be read: \(reason)"
        case .status(let status):
            return "The host answered \(status) (\(HTTPURLResponse.localizedString(forStatusCode: status)))."
        case .unreadableAnswer:
            return "The answer of the host is not one that this app understands."
        case .unknownState:
            return "The host reports a state of the request that this app does not know."
        case .fromAnotherProject:
            return "The newest request for this branch name is one from another project, which is not this branch's."
        }
    }
}
