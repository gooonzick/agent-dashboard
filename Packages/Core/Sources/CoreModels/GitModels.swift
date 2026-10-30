import Foundation

/// A lock that `git worktree lock` put on a worktree.
public struct WorktreeLock: Sendable, Equatable, Codable {
    /// What the lock was given as its reason. Empty when it has none: a bare `git worktree lock` is a lock all the
    /// same.
    public let reason: String
    /// The process that holds the lock, if the reason names one.
    public var ownerPID: Int32?

    public init(reason: String, ownerPID: Int32?) {
        self.reason = reason
        self.ownerPID = ownerPID
    }

    /// A lock with `reason`, held by the process the reason names, if it does.
    ///
    /// Claude Code locks the worktree of each of its sessions with `claude session <name> (pid <N> start <date>)`: the
    /// owner is the number after the first `pid `, which has to be a word of its own. Anything else, a reason somebody
    /// typed by hand, names no owner. Neither does a number that is no process id: zero would stand for a whole
    /// process group when it is passed to `kill`, and a number that does not fit in 32 bits is not one at all.
    public init(reason: String) {
        let owner = reason.firstMatch(of: /\bpid (\d+)/).flatMap { Int32($0.1) }
        self.init(reason: reason, ownerPID: owner.flatMap { $0 > 0 ? $0 : nil })
    }
}

/// One entry of `git worktree list`.
public struct Worktree: Sendable, Equatable, Codable, Identifiable {
    public var id: String { path }
    /// Where the worktree lives. Git reports it; `GitReader` canonicalizes it (`canonicalPath`).
    public let path: String
    /// The commit that is checked out. `nil` when there is none: in a bare repository, or on a branch that has no
    /// commit yet.
    public let head: String?
    /// The checked out branch, without `refs/heads/`. `nil` when HEAD is detached.
    public let branch: String?
    /// The repository's own folder, as opposed to a worktree that was added to it.
    public let isMain: Bool
    public let isDetached: Bool
    public let lock: WorktreeLock?
    /// The folder is gone, so `git worktree prune` would drop the entry.
    public let isPrunable: Bool

    public init(
        path: String, head: String? = nil, branch: String? = nil, isMain: Bool = false, isDetached: Bool = false,
        lock: WorktreeLock? = nil, isPrunable: Bool = false
    ) {
        self.path = path
        self.head = head
        self.branch = branch
        self.isMain = isMain
        self.isDetached = isDetached
        self.lock = lock
        self.isPrunable = isPrunable
    }
}

/// What `git status` says about one worktree, as far as the dashboard needs it.
public struct WorktreeStatus: Sendable, Equatable, Codable {
    /// The branch the checked out branch is set to track, as `origin/main`. `nil` when it tracks none.
    public let upstream: String?
    /// There is an `upstream` but no such branch any more: its remote branch was deleted and `fetch --prune` took it.
    public let upstreamGone: Bool
    /// Commits on this branch that its upstream does not have. Zero when there is no upstream, or it is gone.
    public let ahead: Int
    /// Commits on the upstream that this branch does not have. Zero when there is no upstream, or it is gone.
    public let behind: Int
    /// Tracked files that were changed, added, deleted or renamed, and files with a merge conflict.
    public let modified: Int
    /// Files that git does not track and does not ignore. A folder made up of such files counts once.
    public let untracked: Int
    /// When the commit that is checked out was made. `nil` when there is none.
    public let lastCommitDate: Date?

    public init(
        upstream: String? = nil, upstreamGone: Bool = false, ahead: Int = 0, behind: Int = 0, modified: Int = 0,
        untracked: Int = 0, lastCommitDate: Date? = nil
    ) {
        self.upstream = upstream
        self.upstreamGone = upstreamGone
        self.ahead = ahead
        self.behind = behind
        self.modified = modified
        self.untracked = untracked
        self.lastCommitDate = lastCommitDate
    }
}

/// A remote of a repository, as `git remote -v` lists it.
public struct Remote: Sendable, Equatable, Codable {
    public let name: String
    /// The URL that is fetched from. A separate push URL is not looked at.
    public let url: String

    public init(name: String, url: String) {
        self.name = name
        self.url = url
    }
}
