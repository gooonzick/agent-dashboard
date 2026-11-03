import CoreModels
@testable import Dashboard
import Foundation
import GitKit
import Safety
import Testing

/// The facts that the store gathers for `RemovalPolicy`, by the rulings of Tasks 4, 6 and 10.
@MainActor
@Suite struct RemovalFactsTests {
    @Test func everyDetachedWorktreeCountsTheStashesMadeOnNoBranch() async throws {
        let scene = try Scene()
        let first = linked("/x/detached-1", branch: nil)
        let second = linked("/x/detached-2", branch: nil)
        let onBranch = linked("/x/on-branch", branch: "b")
        scene.addRepository("/x/repo", worktrees: [first, second, onBranch])
        scene.git.update("/x/repo") { repo in
            repo.stashes = ["(no branch)": 1]
            for path in [first.path, second.path] { repo.statuses[path] = WorktreeStatus() }  // no upstream
        }

        let store = await scene.startedStore()

        #expect(store.row(first.path)?.eligibility == .blocked([.stash(1)]))
        #expect(store.row(second.path)?.eligibility == .blocked([.stash(1)]))
        #expect(store.row(onBranch.path)?.eligibility == .manual(needsStopping: false))
        #expect(scene.git.count { $0 == .stash("/x/repo", branch: "(no branch)") } == 2)
        #expect(scene.git.calls.contains(.stash("/x/repo", branch: "b")))
    }

    nonisolated static let headCases: [(sha: String?, trusted: Bool)] = [
        (sha("a"), true),
        (String(repeating: "0123456789abcdef", count: 4), true),  // SHA-256
        (String(repeating: "ABCDEF0123", count: 4), true),
        ("abc1234", false),  // git could take it for a branch or a tag
        (String(repeating: "a", count: 39), false),
        (String(repeating: "g", count: 40), false),
        (String(repeating: "\u{FF21}", count: 40), false),  // fullwidth A: a hex digit to `Character`, not to git
        (nil, false),
    ]

    @Test(arguments: headCases)
    func trustsOnlyAFullCommitIdOfAMergedRequest(sha head: String?, trusted: Bool) async throws {
        let scene = try Scene()
        let worktree = linked("/x/wt", branch: "feature")
        scene.addRepository("/x/repo", worktrees: [worktree])
        scene.git.update("/x/repo") { repo in
            repo.statuses[worktree.path] = cleanUpstreamGone
            if let head { repo.ancestry[head] = true }
        }
        scene.reviews.answer("feature", ReviewInfo(state: .merged, number: 1, headSHA: head))

        let store = await scene.startedStore()

        let asked = scene.git.calls.contains { if case .ancestor = $0 { true } else { false } }
        #expect(asked == trusted)
        let expected: RemovalEligibility = trusted ? .ready(needsStopping: false) : .blocked([.cantVerify])
        #expect(store.row(worktree.path)?.eligibility == expected)
    }

    @Test func aMergeThatDidNotTakeTheHeadBlocks() async throws {
        let scene = try Scene()
        let worktree = linked("/x/wt", branch: "feature")
        scene.addRepository("/x/repo", worktrees: [worktree])
        scene.git.update("/x/repo") { repo in
            repo.statuses[worktree.path] = cleanUpstreamGone
            repo.ancestry[sha("b")] = false
        }
        scene.reviews.answer("feature", ReviewInfo(state: .merged, number: 1, headSHA: sha("b")))

        let store = await scene.startedStore()

        #expect(store.row(worktree.path)?.eligibility == .blocked([.commitsAfterMerge]))
        #expect(scene.git.calls.contains(.ancestor(sha("a"), of: sha("b"))))
    }

    @Test func neverLooksUpTheRequestOfADetachedWorktree() async throws {
        let scene = try Scene()
        let detached = linked("/x/detached", branch: nil)
        scene.addRepository("/x/repo", worktrees: [detached, linked("/x/on-branch", branch: "b")])
        scene.reviews.answer("b", ReviewInfo(state: .merged, number: 1, headSHA: sha("a")))

        let store = await scene.startedStore()

        #expect(scene.reviews.lookups.map(\.branch).sorted() == ["b", "main"])
        #expect(store.row(detached.path)?.review == .unknown)
    }

    @Test func countsTheCommitsOnNoRemoteOnlyWithoutALiveUpstream() async throws {
        let scene = try Scene()
        let pushed = linked("/x/pushed", branch: "p")
        let local = linked("/x/local", branch: "l")
        let gone = linked("/x/gone", branch: "g")
        scene.addRepository("/x/repo", worktrees: [pushed, local, gone])
        scene.git.update("/x/repo") { repo in
            repo.statuses[local.path] = WorktreeStatus()
            repo.notOnRemote[local.path] = 3
            repo.statuses[gone.path] = cleanUpstreamGone
            repo.notOnRemoteFails = [gone.path]
        }

        let store = await scene.startedStore()

        #expect(!scene.git.calls.contains(.notOnRemote(pushed.path)))
        #expect(store.row(local.path)?.eligibility == .blocked([.notOnRemote(3)]))
        #expect(store.row(gone.path)?.eligibility == .blocked([.cantVerify]))  // nil, never a made-up count
    }

    @Test func aStashListThatCannotBeReadBlocks() async throws {
        let scene = try Scene()
        let worktree = linked("/x/wt", branch: "feature")
        scene.addRepository("/x/repo", worktrees: [worktree])
        scene.git.update("/x/repo") { $0.stashFails = true }
        scene.reviews.answer("feature", ReviewInfo(state: .merged, number: 1, headSHA: sha("a")))

        let store = await scene.startedStore()

        #expect(store.row(worktree.path)?.eligibility == .blocked([.statusUnavailable]))
        #expect(store.row(worktree.path)?.status == cleanAndPushed)  // what git said is still shown
    }

    @Test func aLockWhoseOwnerRunsHasToBeStopped() async throws {
        let scene = try Scene(signaler: FakeSignaler(alive: [4242]))
        let held = linked("/x/held", branch: "h", lock: WorktreeLock(reason: "claude session a (pid 4242 start x)"))
        let stale = linked("/x/stale", branch: "s", lock: WorktreeLock(reason: "claude session b (pid 4343 start x)"))
        scene.addRepository("/x/repo", worktrees: [held, stale])
        for branch in ["h", "s"] { scene.reviews.answer(branch, ReviewInfo(state: .merged, headSHA: sha("a"))) }

        let store = await scene.startedStore()

        #expect(store.row(held.path)?.eligibility == .ready(needsStopping: true))
        #expect(store.row(stale.path)?.eligibility == .ready(needsStopping: false))
    }

    @Test func readsOnlyTheStatusOfTheMainWorktree() async throws {
        let scene = try Scene()
        scene.addRepository("/x/repo")

        let store = await scene.startedStore()

        #expect(store.row("/x/repo")?.eligibility == .mainWorktree)
        #expect(store.row("/x/repo")?.status == cleanAndPushed)
        #expect(!scene.git.calls.contains(.notOnRemote("/x/repo")))
        #expect(scene.git.count { if case .stash = $0 { true } else { false } } == 0)
    }
}
