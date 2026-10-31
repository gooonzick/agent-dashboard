import CoreModels

/// Why a worktree is not to be removed: something in it that is saved nowhere else, or something that makes it
/// impossible to tell. A count says how many of the thing there are.
public enum UnsavedReason: Sendable, Equatable, Codable {
    /// Tracked files that are changed, added, deleted or renamed, or in conflict.
    case modified(Int)
    /// Files that git neither tracks nor ignores.
    case untracked(Int)
    /// Stash entries that were made on the branch of the worktree.
    case stash(Int)
    /// Commits that the upstream does not have, when the upstream is still there.
    case unpushed(Int)
    /// Commits that are on no remote branch at all: the branch has no upstream, or its upstream is gone, and its
    /// request is not merged.
    case notOnRemote(Int)
    /// The request is merged and the branch has no upstream that is there, but HEAD is neither the commit that the
    /// merge took in nor an ancestor of it: there is work that the merge did not take.
    case commitsAfterMerge
    /// Whether the commits are saved could not be found out: HEAD could not be compared with the head of the merged
    /// request, the commits that are on no remote branch could not be counted, or a count below zero, which no reading
    /// gives, was given for them or for the stash.
    case cantVerify
    /// The worktree is locked, and the reason of the lock names no process (`ownerPID == nil`): somebody locked it by
    /// hand, for a reason that the app does not know.
    case lockedManually
    /// `git status` of the worktree could not be read, or gave a count below zero, which no reading gives.
    case statusUnavailable
}

/// What may be done with the folder of a worktree.
public enum RemovalEligibility: Sendable, Equatable, Codable {
    /// The repository's own folder. It is never removed.
    case mainWorktree
    /// The folder is gone. There is nothing to remove, only an entry to prune.
    case missing
    /// Removing the folder would lose work, or the app cannot tell that it would not. The reasons come in the order of
    /// the table of `RemovalPolicy`, and there is at least one.
    case blocked([UnsavedReason])
    /// Its request is merged and nothing is unsaved: the app offers it in "Ready to remove". `needsStopping` is true
    /// when something runs in it, or the process that holds its lock is alive: that has to be stopped first.
    case ready(needsStopping: Bool)
    /// Nothing is unsaved, but its request is not merged, or nobody can say how it stands: it can be removed by hand,
    /// from the inspector, and is never offered. `needsStopping` is as for `ready`.
    case manual(needsStopping: Bool)
}

/// Everything that `RemovalPolicy` decides on. The caller reads it, from git, from the host of the repository and from
/// the list of processes, as late as it can: the policy reads nothing, so a decision is only as new as its facts.
public struct RemovalFacts: Sendable {
    public let worktree: Worktree
    /// `nil` when `git status` could not be read.
    public let status: WorktreeStatus?
    public let review: ReviewInfo
    /// Stash entries that were made on the branch of the worktree.
    public let stashCount: Int
    /// Commits of HEAD that are on no remote branch (`git rev-list --count HEAD --not --remotes`). `nil` when they
    /// could not be counted.
    public let commitsNotOnAnyRemote: Int?
    /// Whether HEAD is the head of the request or one of its ancestors. `nil` when that could not be found out: the
    /// request has no head, or git could not say.
    public let headContainedInReview: Bool?
    /// How many groups of processes run in the worktree.
    public let runningGroups: Int
    /// The process that the lock of the worktree names is still running.
    public let lockOwnerAlive: Bool

    /// Every fact is given: none has a default that a caller could leave in by mistake.
    public init(
        worktree: Worktree, status: WorktreeStatus?, review: ReviewInfo, stashCount: Int, commitsNotOnAnyRemote: Int?,
        headContainedInReview: Bool?, runningGroups: Int, lockOwnerAlive: Bool
    ) {
        self.worktree = worktree
        self.status = status
        self.review = review
        self.stashCount = stashCount
        self.commitsNotOnAnyRemote = commitsNotOnAnyRemote
        self.headContainedInReview = headContainedInReview
        self.runningGroups = runningGroups
        self.lockOwnerAlive = lockOwnerAlive
    }
}

/// Decides which worktrees may be removed. "Never delete unsaved work" is kept here: the app shows "Ready to remove" by
/// it, and asks it again right before it deletes.
///
/// A pure function of the facts: no file, no process, no clock. It answers for every input. A count below zero is no
/// count that any reading gives, so it is an unknown and is never taken for none: it blocks wherever it is, as rows 3,
/// 5 and 7 say. `nil` is another thing, a fact that was not given, and it blocks only where the table asks for it.
///
/// The first of these that applies decides:
/// 1. The main worktree: `.mainWorktree`.
/// 2. A folder that is gone (`isPrunable`): `.missing`.
/// 3. No `status`, or one with `modified`, `untracked` or `ahead` below zero: `.blocked([.statusUnavailable])`, and
///    nothing else is looked at.
/// 4. Reasons, in this order: `modified > 0` is `.modified`; `untracked > 0` is `.untracked`; `stashCount > 0` is
///    `.stash`; a lock with no `ownerPID` is `.lockedManually`. A lock that names its owner never blocks: if the owner
///    is gone the lock is stale, and if it runs, that is for `needsStopping`.
/// 5. At most one more reason, about the commits:
///    - The branch has an upstream that is still there: `.unpushed(ahead)` if `ahead > 0`. Nothing else is asked: a
///      commit that is not ahead of the upstream is on it.
///    - Else the request is merged: `.commitsAfterMerge` if `headContainedInReview == false`, `.cantVerify` if it is
///      `nil`. (A merge, a squash merge above all, leaves the commits of the branch on no remote branch, so they are
///      not counted here: the head of the request says whether the merge took them.)
///    - Else `.notOnRemote(n)` if `commitsNotOnAnyRemote` is `n > 0`, `.cantVerify` if it is `nil`.
///    - If none of these gives a reason, a `stashCount` or a `commitsNotOnAnyRemote` below zero gives `.cantVerify`,
///      whether the table asks for that count or not.
/// 6. Any reason: `.blocked`, with the reasons in the order of 4 and 5.
/// 7. Else `needsStopping` is `runningGroups != 0 || lockOwnerAlive` (below zero is taken for something that runs), and
///    the result is `.ready` if the request is merged and `.manual` if it is anything else.
public enum RemovalPolicy {
    public static func evaluate(_ f: RemovalFacts) -> RemovalEligibility {
        if f.worktree.isMain { return .mainWorktree }
        if f.worktree.isPrunable { return .missing }
        guard let status = f.status, !status.hasImpossibleCount else { return .blocked([.statusUnavailable]) }

        var reasons: [UnsavedReason] = []
        if status.modified > 0 { reasons.append(.modified(status.modified)) }
        if status.untracked > 0 { reasons.append(.untracked(status.untracked)) }
        if f.stashCount > 0 { reasons.append(.stash(f.stashCount)) }
        if let lock = f.worktree.lock, lock.ownerPID == nil { reasons.append(.lockedManually) }
        if let reason = unsavedCommits(f, status) ?? impossibleCount(f) { reasons.append(reason) }
        if !reasons.isEmpty { return .blocked(reasons) }

        let needsStopping = f.runningGroups != 0 || f.lockOwnerAlive
        return f.review.state == .merged ? .ready(needsStopping: needsStopping) : .manual(needsStopping: needsStopping)
    }

    /// `.cantVerify` for a count below zero in the stash or in the commits on no remote branch, wherever the table asks
    /// for that count and where it does not: no reading gives such a count, so the facts cannot be trusted. It is only
    /// given when no other reason about the commits is: that place holds one reason, and a known one says more.
    private static func impossibleCount(_ f: RemovalFacts) -> UnsavedReason? {
        (f.stashCount < 0 || (f.commitsNotOnAnyRemote ?? 0) < 0) ? .cantVerify : nil
    }

    /// The reason that row 5 of the table gives about the commits, if it gives one. A branch is judged by the first of
    /// the three descriptions that fits it, and by nothing that the others ask.
    private static func unsavedCommits(_ f: RemovalFacts, _ status: WorktreeStatus) -> UnsavedReason? {
        if status.upstream != nil, !status.upstreamGone {
            return status.ahead > 0 ? .unpushed(status.ahead) : nil
        }
        if f.review.state == .merged {
            switch f.headContainedInReview {
            case .some(true): return nil
            case .some(false): return .commitsAfterMerge
            case .none: return .cantVerify
            }
        }
        guard let notOnRemote = f.commitsNotOnAnyRemote else { return .cantVerify }
        return notOnRemote > 0 ? .notOnRemote(notOnRemote) : nil
    }
}

extension WorktreeStatus {
    /// A count below zero, which no reading of git gives. `behind` is not looked at: the policy does not depend on it.
    fileprivate var hasImpossibleCount: Bool { modified < 0 || untracked < 0 || ahead < 0 }
}
