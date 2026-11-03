import CoreModels
import Foundation
import GitKit
import Hosting
import Safety

/// One worktree as the dashboard shows it: what git, the hosting service, the disk and the process list say about it,
/// and what may be done with it.
public struct WorktreeRow: Sendable, Equatable, Identifiable {
    public var id: String { worktree.path }
    /// The repository that the worktree belongs to: the canonical path of its main worktree.
    public let repoPath: String
    /// The name of the repository's folder.
    public let repoName: String
    public let worktree: Worktree
    /// `nil` while it has not been read, when git could not read it, and always for a worktree whose folder is gone.
    public let status: WorktreeStatus?
    /// `.unknown` until it is known, for a worktree without a branch, and wherever the host cannot be asked.
    public let review: ReviewInfo
    /// What the host of the repository's remote runs. `nil` without a remote on a hosting service, and until it has
    /// been found out.
    public let hosting: HostingKind?
    /// What runs in the worktree, the most memory first.
    public let groups: [ProcessGroup]
    /// What the folder takes and what removing it frees. `nil` until it has been measured.
    public let size: SizeInfo?
    public let eligibility: RemovalEligibility

    public init(
        repoPath: String, repoName: String, worktree: Worktree, status: WorktreeStatus?, review: ReviewInfo,
        hosting: HostingKind?, groups: [ProcessGroup], size: SizeInfo?, eligibility: RemovalEligibility
    ) {
        self.repoPath = repoPath
        self.repoName = repoName
        self.worktree = worktree
        self.status = status
        self.review = review
        self.hosting = hosting
        self.groups = groups
        self.size = size
        self.eligibility = eligibility
    }
}

/// A repository: its own folder, and the worktrees that were added to it.
public struct ProjectRow: Sendable, Equatable, Identifiable {
    public var id: String { path }
    /// The canonical path of the repository's folder.
    public let path: String
    public let name: String
    /// The repository's own folder, which is never removed.
    public let main: WorktreeRow
    /// The other worktrees, in the order git lists them.
    public let worktrees: [WorktreeRow]

    public init(path: String, name: String, main: WorktreeRow, worktrees: [WorktreeRow]) {
        self.path = path
        self.name = name
        self.main = main
        self.worktrees = worktrees
    }
}

/// Where the search of the disk for repositories stands.
public enum ScanState: Sendable, Equatable {
    case idle
    /// A scan is under way. `found` is how many repositories are known so far.
    case scanning(found: Int)
    case failed(String)
}

/// What became of one worktree that was to be removed. The string is the path of the worktree.
public enum RemovalOutcome: Sendable, Equatable {
    case removed(String)
    /// Not removed, or not all the way: `RemovalError` says which, and what is left.
    case failed(String, RemovalError)
}
