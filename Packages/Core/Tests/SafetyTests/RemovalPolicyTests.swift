import CoreModels
import Foundation
import Safety
import Testing

/// The review states, since `ReviewState` is not `CaseIterable`.
private let reviewStates: [ReviewState] = [.open, .draft, .merged, .closed, .none, .unknown]

/// Facts about a worktree that is safe to remove, unless a test says otherwise: not the main one, not missing, nothing
/// changed or untracked, no stash, no lock, an upstream that is there and has no commit that the branch lacks, its
/// request merged, nothing running, and (if a test gives it a lock) a lock owner that is not alive. What a test leaves
/// out blocks nothing, so `notOnRemote` and `contained` are the answers for a branch that is saved.
private func facts(
    main: Bool = false, prunable: Bool = false, branch: String? = "feature", detached: Bool = false,
    review: ReviewState = .merged, statusUnavailable: Bool = false, modified: Int = 0, untracked: Int = 0,
    stash: Int = 0, upstream: String? = "origin/feature", upstreamGone: Bool = false, ahead: Int = 0, behind: Int = 0,
    notOnRemote: Int? = 0, contained: Bool? = true, lock: String? = nil, lockAlive: Bool = false, running: Int = 0
) -> RemovalFacts {
    RemovalFacts(
        worktree: Worktree(
            path: "/r/wt", branch: branch, isMain: main, isDetached: detached,
            lock: lock.map { WorktreeLock(reason: $0) }, isPrunable: prunable),
        status: statusUnavailable
            ? nil
            : WorktreeStatus(
                upstream: upstream, upstreamGone: upstreamGone, ahead: ahead, behind: behind, modified: modified,
                untracked: untracked),
        review: ReviewInfo(state: review),
        stashCount: stash, commitsNotOnAnyRemote: notOnRemote, headContainedInReview: contained,
        runningGroups: running, lockOwnerAlive: lockAlive)
}

@Suite struct RemovalPolicyTests {
    // MARK: The brief: a test per row of the table

    @Test func mergedCleanIsReady() {
        #expect(RemovalPolicy.evaluate(facts(review: .merged)) == .ready(needsStopping: false))
    }

    @Test func mergedCleanWithSessionNeedsStopping() {
        #expect(RemovalPolicy.evaluate(facts(review: .merged, running: 1)) == .ready(needsStopping: true))
    }

    @Test func untrackedBlocks() {
        #expect(RemovalPolicy.evaluate(facts(review: .merged, untracked: 1)) == .blocked([.untracked(1)]))
    }

    @Test func mergedGoneUpstreamHeadMatches() {
        #expect(
            RemovalPolicy.evaluate(facts(review: .merged, upstreamGone: true, contained: true))
                == .ready(needsStopping: false))
    }

    @Test func commitAfterMergeBlocks() {
        #expect(
            RemovalPolicy.evaluate(facts(review: .merged, upstreamGone: true, contained: false))
                == .blocked([.commitsAfterMerge]))
    }

    @Test func missingReviewHeadCantVerify() {
        #expect(
            RemovalPolicy.evaluate(facts(review: .merged, upstreamGone: true, contained: nil))
                == .blocked([.cantVerify]))
    }

    @Test func openMRIsManualOnly() {
        #expect(RemovalPolicy.evaluate(facts(review: .open)) == .manual(needsStopping: false))
    }

    @Test func unknownReviewIsManualOnly() {
        #expect(RemovalPolicy.evaluate(facts(review: .unknown)) == .manual(needsStopping: false))
    }

    @Test func localOnlyBranchBlocks() {
        #expect(
            RemovalPolicy.evaluate(facts(review: .none, upstream: nil, notOnRemote: 3)) == .blocked([.notOnRemote(3)]))
    }

    @Test func detachedPushedIsManual() {
        #expect(
            RemovalPolicy.evaluate(facts(branch: nil, detached: true, review: .unknown, upstream: nil, notOnRemote: 0))
                == .manual(needsStopping: false))
    }

    @Test func staleClaudeLockDoesNotBlock() {
        #expect(
            RemovalPolicy.evaluate(
                facts(review: .merged, lock: "claude session x (pid 999999 start …)", lockAlive: false))
                == .ready(needsStopping: false))
    }

    @Test func liveClaudeLockNeedsStopping() {
        #expect(
            RemovalPolicy.evaluate(facts(review: .merged, lock: "claude session x (pid 4242 start …)", lockAlive: true))
                == .ready(needsStopping: true))
    }

    @Test func manualLockBlocks() {
        #expect(RemovalPolicy.evaluate(facts(review: .merged, lock: "on usb drive")) == .blocked([.lockedManually]))
    }

    @Test func mainAndMissing() {
        #expect(RemovalPolicy.evaluate(facts(main: true)) == .mainWorktree)
        #expect(RemovalPolicy.evaluate(facts(prunable: true)) == .missing)
    }

    @Test func reasonsKeepOrder() {
        #expect(
            RemovalPolicy.evaluate(facts(review: .merged, modified: 2, untracked: 1, stash: 1))
                == .blocked([.modified(2), .untracked(1), .stash(1)]))
    }

    // MARK: Rows 1 to 3: the folder as a whole

    @Test func theFirstRowThatAppliesDecides() {
        let dirty = facts(main: true, modified: 3, untracked: 2, stash: 1, lock: "on usb drive")
        #expect(RemovalPolicy.evaluate(dirty) == .mainWorktree)
        #expect(RemovalPolicy.evaluate(facts(main: true, prunable: true)) == .mainWorktree)
        #expect(RemovalPolicy.evaluate(facts(main: true, statusUnavailable: true)) == .mainWorktree)
        #expect(RemovalPolicy.evaluate(facts(main: true, modified: -1)) == .mainWorktree)
        #expect(RemovalPolicy.evaluate(facts(prunable: true, modified: 3, stash: 1, lock: "on usb drive")) == .missing)
        #expect(RemovalPolicy.evaluate(facts(prunable: true, statusUnavailable: true)) == .missing)
        #expect(RemovalPolicy.evaluate(facts(prunable: true, ahead: -1)) == .missing)
    }

    @Test func noStatusBlocksAndNothingElseIsLookedAt() {
        #expect(
            RemovalPolicy.evaluate(facts(review: .merged, statusUnavailable: true)) == .blocked([.statusUnavailable]))
        #expect(
            RemovalPolicy.evaluate(facts(review: .open, statusUnavailable: true, stash: 2, lock: "on usb drive"))
                == .blocked([.statusUnavailable]))
    }

    // MARK: Row 4: changes, stash, lock

    @Test func modifiedBlocks() {
        #expect(RemovalPolicy.evaluate(facts(review: .merged, modified: 4)) == .blocked([.modified(4)]))
    }

    @Test func stashBlocks() {
        #expect(RemovalPolicy.evaluate(facts(review: .merged, stash: 2)) == .blocked([.stash(2)]))
    }

    @Test(arguments: [
        "",  // a bare `git worktree lock` is a lock all the same
        "on usb drive",
        "claude session x (pid 0 start …)",  // it says pid, but a number that is no pid names no owner
        "claude session x (pid 99999999999 start …)",
    ])
    func aLockThatNamesNoOwnerBlocks(reason: String) {
        #expect(RemovalPolicy.evaluate(facts(review: .merged, lock: reason)) == .blocked([.lockedManually]))
    }

    // MARK: Row 5: the commits

    @Test(arguments: reviewStates)
    func unpushedCommitsBlockWhateverTheRequest(review: ReviewState) {
        #expect(RemovalPolicy.evaluate(facts(review: review, ahead: 3)) == .blocked([.unpushed(3)]))
    }

    @Test func aSingleCommitIsEnoughToBlock() {
        // The commonest case that the gate is for: one commit that is not pushed, or that is on no remote branch.
        #expect(RemovalPolicy.evaluate(facts(review: .merged, ahead: 1)) == .blocked([.unpushed(1)]))
        #expect(RemovalPolicy.evaluate(facts(review: .open, ahead: 1)) == .blocked([.unpushed(1)]))
        #expect(
            RemovalPolicy.evaluate(facts(review: .none, upstream: nil, notOnRemote: 1)) == .blocked([.notOnRemote(1)]))
        #expect(
            RemovalPolicy.evaluate(facts(review: .closed, upstreamGone: true, notOnRemote: 1))
                == .blocked([.notOnRemote(1)]))
    }

    @Test func anUpstreamThatIsThereDecidesByAheadAlone() {
        // A commit that is not ahead of an upstream that is there is on it: neither the head of the request nor the
        // commits that are on no remote branch are asked.
        #expect(RemovalPolicy.evaluate(facts(review: .merged, contained: false)) == .ready(needsStopping: false))
        #expect(RemovalPolicy.evaluate(facts(review: .merged, contained: nil)) == .ready(needsStopping: false))
        #expect(RemovalPolicy.evaluate(facts(review: .open, notOnRemote: 5)) == .manual(needsStopping: false))
        #expect(RemovalPolicy.evaluate(facts(review: .open, notOnRemote: nil)) == .manual(needsStopping: false))
    }

    @Test func behindDoesNotBlock() {
        #expect(RemovalPolicy.evaluate(facts(review: .merged, behind: 7)) == .ready(needsStopping: false))
        #expect(RemovalPolicy.evaluate(facts(review: .open, behind: 7)) == .manual(needsStopping: false))
    }

    @Test func withoutAnUpstreamAMergedBranchIsJudgedByTheHeadOfItsRequest() {
        for gone in [true, false] {
            let upstream = gone ? "origin/feature" : nil
            #expect(
                RemovalPolicy.evaluate(facts(review: .merged, upstream: upstream, upstreamGone: gone, contained: true))
                    == .ready(needsStopping: false))
            #expect(
                RemovalPolicy.evaluate(facts(review: .merged, upstream: upstream, upstreamGone: gone, contained: false))
                    == .blocked([.commitsAfterMerge]))
            #expect(
                RemovalPolicy.evaluate(facts(review: .merged, upstream: upstream, upstreamGone: gone, contained: nil))
                    == .blocked([.cantVerify]))
        }
    }

    @Test func aMergedBranchIsNotJudgedByTheCommitsOnNoRemoteBranch() {
        // A squash merge leaves the commits of the branch on no remote branch: only the head of the request says
        // whether the merge took them, in either direction.
        #expect(
            RemovalPolicy.evaluate(facts(review: .merged, upstreamGone: true, notOnRemote: 4, contained: true))
                == .ready(needsStopping: false))
        #expect(
            RemovalPolicy.evaluate(facts(review: .merged, upstream: nil, notOnRemote: 4, contained: true))
                == .ready(needsStopping: false))
        #expect(
            RemovalPolicy.evaluate(facts(review: .merged, upstreamGone: true, notOnRemote: 0, contained: false))
                == .blocked([.commitsAfterMerge]))
    }

    @Test(arguments: reviewStates.filter { $0 != .merged })
    func withoutAMergeTheCommitsOnNoRemoteBranchDecide(review: ReviewState) {
        for gone in [true, false] {
            let upstream = gone ? "origin/feature" : nil
            #expect(
                RemovalPolicy.evaluate(facts(review: review, upstream: upstream, upstreamGone: gone, notOnRemote: 2))
                    == .blocked([.notOnRemote(2)]))
            #expect(
                RemovalPolicy.evaluate(facts(review: review, upstream: upstream, upstreamGone: gone, notOnRemote: 0))
                    == .manual(needsStopping: false))
            #expect(
                RemovalPolicy.evaluate(facts(review: review, upstream: upstream, upstreamGone: gone, notOnRemote: nil))
                    == .blocked([.cantVerify]))
        }
    }

    @Test func detachedWithCommitsOnNoRemoteBranchBlocks() {
        #expect(
            RemovalPolicy.evaluate(facts(branch: nil, detached: true, review: .unknown, upstream: nil, notOnRemote: 2))
                == .blocked([.notOnRemote(2)]))
    }

    // MARK: Row 6: the order of the reasons

    @Test func lockAndNotOnRemoteKeepOrder() {
        #expect(
            RemovalPolicy.evaluate(facts(review: .none, upstream: nil, notOnRemote: 4, lock: "on usb drive"))
                == .blocked([.lockedManually, .notOnRemote(4)]))
        #expect(
            RemovalPolicy.evaluate(
                facts(
                    review: .none, modified: 2, untracked: 1, stash: 3, upstream: nil, notOnRemote: 4,
                    lock: "on usb drive"))
                == .blocked([.modified(2), .untracked(1), .stash(3), .lockedManually, .notOnRemote(4)]))
    }

    @Test func theReasonAboutCommitsIsLastWhicheverOfTheFourItIs() {
        let first: [UnsavedReason] = [.modified(1), .untracked(1), .stash(1), .lockedManually]
        let cases: [(given: RemovalFacts, last: UnsavedReason)] = [
            (
                facts(
                    review: .open, modified: 1, untracked: 1, stash: 1, ahead: 2, lock: "on usb drive"),
                .unpushed(2)
            ),
            (
                facts(
                    review: .open, modified: 1, untracked: 1, stash: 1, upstream: nil, notOnRemote: 2,
                    lock: "on usb drive"),
                .notOnRemote(2)
            ),
            (
                facts(
                    review: .merged, modified: 1, untracked: 1, stash: 1, upstreamGone: true, contained: false,
                    lock: "on usb drive"),
                .commitsAfterMerge
            ),
            (
                facts(
                    review: .merged, modified: 1, untracked: 1, stash: 1, upstreamGone: true, contained: nil,
                    lock: "on usb drive"),
                .cantVerify
            ),
        ]
        for (given, last) in cases {
            #expect(RemovalPolicy.evaluate(given) == .blocked(first + [last]))
        }
    }

    // MARK: Row 7: ready or manual, and what has to be stopped

    @Test(arguments: reviewStates.filter { $0 != .merged })
    func whateverIsNotMergedIsManual(review: ReviewState) {
        #expect(RemovalPolicy.evaluate(facts(review: review)) == .manual(needsStopping: false))
    }

    @Test(arguments: [
        (0, false, false), (1, false, true), (3, false, true), (0, true, true), (2, true, true),
    ])
    func aSessionOrALiveLockOwnerNeedsStopping(running: Int, lockAlive: Bool, needsStopping: Bool) {
        let lock = lockAlive ? "claude session x (pid 4242 start …)" : nil
        #expect(
            RemovalPolicy.evaluate(facts(review: .merged, lock: lock, lockAlive: lockAlive, running: running))
                == .ready(needsStopping: needsStopping))
        #expect(
            RemovalPolicy.evaluate(facts(review: .open, lock: lock, lockAlive: lockAlive, running: running))
                == .manual(needsStopping: needsStopping))
    }

    @Test func aRunningSessionDoesNotUnblock() {
        #expect(RemovalPolicy.evaluate(facts(review: .merged, untracked: 1, running: 2)) == .blocked([.untracked(1)]))
    }

    // MARK: Every input has an answer

    // No reading of git gives a count below zero, so one is an unknown, and an unknown blocks.

    @Test(arguments: [-1, Int.min])
    func aCountBelowZeroInTheStatusIsAStatusThatCannotBeRead(count: Int) {
        let unreadable = RemovalEligibility.blocked([.statusUnavailable])
        #expect(RemovalPolicy.evaluate(facts(review: .merged, modified: count)) == unreadable)
        #expect(RemovalPolicy.evaluate(facts(review: .merged, untracked: count)) == unreadable)
        #expect(RemovalPolicy.evaluate(facts(review: .merged, ahead: count)) == unreadable)
        // `ahead` is zero when there is no upstream that is there, and no less impossible below zero
        #expect(RemovalPolicy.evaluate(facts(review: .merged, upstream: nil, ahead: count)) == unreadable)
        #expect(RemovalPolicy.evaluate(facts(review: .merged, upstreamGone: true, ahead: count)) == unreadable)
        // and nothing else of the worktree is looked at
        #expect(
            RemovalPolicy.evaluate(facts(review: .open, modified: count, stash: 2, lock: "on usb drive")) == unreadable)
    }

    @Test(arguments: [-1, Int.min])
    func aStashOrACountOfCommitsBelowZeroCannotBeVerified(count: Int) {
        let cantVerify = RemovalEligibility.blocked([.cantVerify])
        #expect(RemovalPolicy.evaluate(facts(review: .merged, stash: count)) == cantVerify)
        #expect(RemovalPolicy.evaluate(facts(review: .none, upstream: nil, notOnRemote: count)) == cantVerify)
        // wherever it is, also where the table does not ask for the count: with an upstream that is there, or a merge
        #expect(RemovalPolicy.evaluate(facts(review: .open, notOnRemote: count)) == cantVerify)
        #expect(RemovalPolicy.evaluate(facts(review: .merged, notOnRemote: count)) == cantVerify)
        #expect(RemovalPolicy.evaluate(facts(review: .merged, upstreamGone: true, notOnRemote: count)) == cantVerify)
    }

    @Test(arguments: [-1, Int.min])
    func aNumberOfRunningGroupsBelowZeroIsTakenForSomethingRunning(count: Int) {
        #expect(RemovalPolicy.evaluate(facts(review: .merged, running: count)) == .ready(needsStopping: true))
        #expect(RemovalPolicy.evaluate(facts(review: .open, running: count)) == .manual(needsStopping: true))
    }

    @Test func anUnknownIsLastAndOnceAndGivesWayToAReasonAboutTheCommits() {
        // after the reasons of row 4, where `.cantVerify` always comes
        #expect(
            RemovalPolicy.evaluate(facts(review: .merged, modified: 2, untracked: 1, stash: -1, lock: "on usb drive"))
                == .blocked([.modified(2), .untracked(1), .lockedManually, .cantVerify]))
        // once, however many things are unknown
        #expect(
            RemovalPolicy.evaluate(facts(review: .none, stash: -1, upstream: nil, notOnRemote: -1))
                == .blocked([.cantVerify]))
        #expect(
            RemovalPolicy.evaluate(facts(review: .none, stash: -1, upstream: nil, notOnRemote: nil))
                == .blocked([.cantVerify]))
        // a reason about the commits that is known is the one that is given: at most one stands in that place
        #expect(RemovalPolicy.evaluate(facts(review: .open, stash: -1, ahead: 2)) == .blocked([.unpushed(2)]))
        #expect(RemovalPolicy.evaluate(facts(review: .open, ahead: 2, notOnRemote: -1)) == .blocked([.unpushed(2)]))
        #expect(
            RemovalPolicy.evaluate(facts(review: .none, stash: -1, upstream: nil, notOnRemote: 3))
                == .blocked([.notOnRemote(3)]))
        #expect(
            RemovalPolicy.evaluate(facts(review: .merged, stash: -1, upstreamGone: true, contained: false))
                == .blocked([.commitsAfterMerge]))
    }

    @Test func hugeCountsAreCounted() {
        #expect(
            RemovalPolicy.evaluate(facts(modified: .max, untracked: .max, stash: .max))
                == .blocked([.modified(.max), .untracked(.max), .stash(.max)]))
        #expect(RemovalPolicy.evaluate(facts(review: .open, ahead: .max)) == .blocked([.unpushed(.max)]))
        #expect(
            RemovalPolicy.evaluate(facts(review: .none, upstream: nil, notOnRemote: .max))
                == .blocked([.notOnRemote(.max)]))
        #expect(RemovalPolicy.evaluate(facts(review: .merged, running: .max)) == .ready(needsStopping: true))
    }

    // MARK: The point of the module

    /// Every combination of the facts that the table tells apart: each count below zero, none and one, the five states
    /// of the upstream, and the facts that are not known. The answer is `.blocked` exactly when the spec says that
    /// something is unsaved or unknown, and a worktree that is not blocked is `.ready` if its request is merged and
    /// `.manual` if it is not: nothing that is unsaved or unknown is ever either of the two.
    @Test func blockedExactlyWhenSomethingIsUnsavedOrUnknown() {
        var combos = [Combo()]
        combos = vary(combos, \.review, reviewStates)
        combos = vary(combos, \.modified, [-1, 0, 1])
        combos = vary(combos, \.untracked, [-1, 0, 1])
        combos = vary(combos, \.stash, [-1, 0, 1])
        combos = vary(combos, \.lock, Combo.Lock.allCases)
        combos = vary(combos, \.tracking, Combo.Tracking.allCases)
        combos = vary(combos, \.notOnRemote, [nil, -1, 0, 1, 5])
        combos = vary(combos, \.contained, [nil, false, true])

        var broken: [String] = []
        var ready = 0
        var manual = 0
        var blocked = 0
        for combo in combos {
            let result = RemovalPolicy.evaluate(facts(for: combo))
            switch result {
            case .ready:
                ready += 1
                if combo.review != .merged || combo.blocks {
                    broken.append("ready, but not merged, or something is unsaved or unknown: \(combo)")
                }
            case .manual:
                manual += 1
                if combo.review == .merged || combo.blocks {
                    broken.append("manual, but merged, or something is unsaved or unknown: \(combo)")
                }
            case .blocked(let reasons):
                blocked += 1
                if !combo.blocks {
                    broken.append("blocked, but nothing is unsaved or unknown: \(combo)")
                }
                if reasons.isEmpty || !reasons.map(\.position).isStrictlyIncreasing {
                    broken.append("blocked with \(reasons), which is empty or out of order: \(combo)")
                }
            case .mainWorktree, .missing:
                broken.append("neither main nor missing, but \(result): \(combo)")
            }
        }

        // A count and three examples: an expectation on the array would print every one of them.
        let violations = broken.count
        let firstThree = Array(broken.prefix(3))
        #expect(violations == 0, "among \(combos.count) combinations, the first of them: \(firstThree)")
        // The checks above are not vacuous: every kind of answer is reached.
        #expect(ready > 0 && manual > 0 && blocked > 0)
    }

    // MARK: JSON

    @Test func theAnswersSurviveJSON() throws {
        let reasons: [UnsavedReason] = [
            .modified(1), .untracked(2), .stash(3), .unpushed(4), .notOnRemote(5), .commitsAfterMerge, .cantVerify,
            .lockedManually, .statusUnavailable,
        ]
        let answers: [RemovalEligibility] = [
            .mainWorktree, .missing, .blocked(reasons), .ready(needsStopping: true), .ready(needsStopping: false),
            .manual(needsStopping: true), .manual(needsStopping: false),
        ]

        for reason in reasons {
            #expect(try JSONDecoder().decode(UnsavedReason.self, from: JSONEncoder().encode(reason)) == reason)
        }
        for answer in answers {
            #expect(try JSONDecoder().decode(RemovalEligibility.self, from: JSONEncoder().encode(answer)) == answer)
        }
    }
}

// MARK: - For the test of every combination

/// One combination of the facts that the table tells apart.
private struct Combo {
    var review = ReviewState.merged
    var modified = 0
    var untracked = 0
    var stash = 0
    var lock = Lock.absent
    var tracking = Tracking.inSync
    var notOnRemote: Int? = 0
    var contained: Bool? = true

    enum Lock: CaseIterable {
        case absent, byHand, ofASession

        var reason: String? {
            switch self {
            case .absent: nil
            case .byHand: "on usb drive"
            case .ofASession: "claude session x (pid 4242 start …)"
            }
        }
    }

    enum Tracking: CaseIterable {
        // `aheadBelowZero` is an upstream that is there, with a count of commits ahead that no reading gives
        case noUpstream, inSync, ahead, gone, aheadBelowZero

        var upstream: String? { self == .noUpstream ? nil : "origin/x" }
        var isGone: Bool { self == .gone }
        var isThere: Bool { self != .noUpstream && self != .gone }
        var aheadBy: Int {
            switch self {
            case .ahead: 1
            case .aheadBelowZero: -1
            case .noUpstream, .inSync, .gone: 0
            }
        }
    }

    /// What the spec calls unsaved work, written from the spec and not from the table of the policy: changes, stash, a
    /// lock that names no process, commits ahead of an upstream that is there, and, with no such upstream, the commits
    /// that a merge did not take (a merged request) or that are on no remote branch (any other).
    var hasUnsavedWork: Bool {
        modified > 0 || untracked > 0 || stash > 0 || lock == .byHand
            || (tracking.isThere && tracking.aheadBy > 0)
            || (!tracking.isThere && review != .merged && (notOnRemote ?? 0) > 0)
            || (!tracking.isThere && review == .merged && contained == false)
    }

    /// What cannot be told: a count below zero, wherever it is, and, for a branch with no upstream that is there, the
    /// fact that the table asks for and that was not given: the head of the request if that is merged, the number of
    /// commits on no remote branch if it is not.
    var hasUnknownFact: Bool {
        modified < 0 || untracked < 0 || stash < 0 || tracking.aheadBy < 0 || (notOnRemote ?? 0) < 0
            || (!tracking.isThere && review != .merged && notOnRemote == nil)
            || (!tracking.isThere && review == .merged && contained == nil)
    }

    /// Something is unsaved or unknown, so the answer has to be `.blocked`, and is nothing else.
    var blocks: Bool { hasUnsavedWork || hasUnknownFact }
}

private func facts(for combo: Combo) -> RemovalFacts {
    facts(
        review: combo.review, modified: combo.modified, untracked: combo.untracked, stash: combo.stash,
        upstream: combo.tracking.upstream, upstreamGone: combo.tracking.isGone, ahead: combo.tracking.aheadBy,
        notOnRemote: combo.notOnRemote, contained: combo.contained, lock: combo.lock.reason)
}

/// Each of the combos, once for every one of the values.
private func vary<Value>(_ combos: [Combo], _ key: WritableKeyPath<Combo, Value>, _ values: [Value]) -> [Combo] {
    combos.flatMap { combo in
        values.map { value in
            var next = combo
            next[keyPath: key] = value
            return next
        }
    }
}

extension UnsavedReason {
    /// Where the reason belongs in the table. The four about the commits share a place: only one of them is given.
    fileprivate var position: Int {
        switch self {
        case .statusUnavailable: 0
        case .modified: 1
        case .untracked: 2
        case .stash: 3
        case .lockedManually: 4
        case .unpushed, .notOnRemote, .commitsAfterMerge, .cantVerify: 5
        }
    }
}

extension Array where Element: Comparable {
    fileprivate var isStrictlyIncreasing: Bool {
        zip(self, dropFirst()).allSatisfy { $0 < $1 }
    }
}
