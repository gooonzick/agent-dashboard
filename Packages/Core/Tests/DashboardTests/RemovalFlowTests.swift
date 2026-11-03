import CoreModels
@testable import Dashboard
import Foundation
import GitKit
import ProcessKit
import Safety
import Shell
import Testing

/// What happens around `WorktreeRemoving.remove`: the recheck, the order of removals, and what is read afterwards.
@MainActor
@Suite struct RemovalFlowTests {
    private let worktree = linked("/x/wt", branch: "feature")

    /// A repository with a worktree whose request is merged and that has nothing unsaved.
    private func readyScene() throws -> Scene {
        let scene = try Scene()
        scene.addRepository("/x/repo", worktrees: [worktree])
        scene.reviews.answer("feature", ReviewInfo(state: .merged, number: 1, headSHA: sha("a")))
        return scene
    }

    @Test func aFetchThatFailsMakesTheRecheckRefuse() async throws {
        let scene = try readyScene()
        let store = await scene.startedStore()
        let row = try #require(store.row(worktree.path))
        scene.git.update("/x/repo") { $0.fetchFails = true }
        let statusReads = scene.git.count { $0 == .status(worktree.path) }

        let outcomes = await store.remove([row], deleteBranches: true)

        #expect(outcomes == [.failed(worktree.path, .stateChanged(.blocked([.cantVerify])))])
        #expect(scene.remover.rechecks == [.blocked([.cantVerify])])
        // Nothing is read from a remote-tracking branch that may be stale: the recheck ends at the fetch.
        #expect(scene.git.count { $0 == .status(worktree.path) } == statusReads + 1)  // the refresh afterwards
    }

    @Test func theRecheckCountsWhatRunsFromAFreshSample() async throws {
        let scene = try readyScene()
        let store = await scene.startedStore()
        let row = try #require(store.row(worktree.path))
        #expect(row.groups.isEmpty)
        // Something started in the worktree after the row was shown.
        scene.sampler.set([process(700, cwd: worktree.path + "/src")])

        let outcomes = await store.remove([row], deleteBranches: true)

        #expect(outcomes == [.failed(worktree.path, .stateChanged(.ready(needsStopping: true)))])
        #expect(scene.sampler.samples == 1)
    }

    @Test func whatWasStoppedIsNotCountedAgain() async throws {
        let scene = try readyScene()
        scene.sampler.set([process(700, cwd: worktree.path)])
        let store = await scene.startedStore()
        await store.refresh()
        let row = try #require(store.row(worktree.path))
        #expect(row.eligibility == .ready(needsStopping: true))
        scene.remover.onRemoval { _ in }
        scene.sampler.set([])  // the remover stopped it

        let outcomes = await store.remove([row], deleteBranches: false)

        #expect(outcomes == [.removed(worktree.path)])
        #expect(scene.remover.requests.first?.stopGroups.map(\.leader.pid) == [700])
        #expect(scene.remover.requests.first?.deleteBranch == false)
    }

    @Test func removalsInOneRepositoryRunOneAtATime() async throws {
        let scene = try Scene()
        let first = linked("/x/wt-1", branch: "one")
        let second = linked("/x/wt-2", branch: "two")
        let elsewhere = linked("/y/wt", branch: "three")
        scene.addRepository("/x/repo", worktrees: [first, second])
        scene.addRepository("/y/repo", worktrees: [elsewhere])
        for branch in ["one", "two", "three"] {
            scene.reviews.answer(branch, ReviewInfo(state: .merged, number: 1, headSHA: sha("a")))
        }
        let gate = Gate()
        scene.remover.onRemoval { _ in await gate.wait() }
        let store = await scene.startedStore()
        let rows = try [first, second, elsewhere].map { try #require(store.row($0.path)) }

        async let a = store.remove([rows[0]], deleteBranches: true)
        async let b = store.remove([rows[1]], deleteBranches: true)
        async let c = store.remove([rows[2]], deleteBranches: true)
        // Both repositories are at it at once, and the second worktree of /x waits for the first.
        #expect(await poll { scene.remover.runningRepos == ["/x/repo", "/y/repo"] })
        try await Task.sleep(for: .milliseconds(50))
        #expect(scene.remover.requests.count == 2)
        gate.open()
        let outcomes = await [a, b, c]

        #expect(outcomes == [[.removed(first.path)], [.removed(second.path)], [.removed(elsewhere.path)]])
        #expect(scene.remover.maxRunningInOneRepo == 1)
    }

    @Test func aFailedRemovalRefreshesTheRepository() async throws {
        let scene = try readyScene()
        scene.remover.onRemoval { [git = scene.git, path = worktree.path] _ in
            // git refused, and something changed in the worktree meanwhile
            git.update("/x/repo") { $0.statuses[path] = WorktreeStatus(upstream: "origin/x", modified: 2) }
            throw RemovalError.gitRefused("fatal: contains modified or untracked files")
        }
        let store = await scene.startedStore()
        let row = try #require(store.row(worktree.path))

        let outcomes = await store.remove([row], deleteBranches: true)

        #expect(outcomes == [.failed(worktree.path, .gitRefused("fatal: contains modified or untracked files"))])
        #expect(store.row(worktree.path)?.status?.modified == 2)
        #expect(store.row(worktree.path)?.eligibility == .blocked([.modified(2)]))
    }

    @Test func aMissingWorktreeIsNeverAskedToLoseItsBranch() async throws {
        let scene = try Scene()
        let gone = linked("/x/wt-gone", branch: "gone", prunable: true)
        scene.addRepository("/x/repo", worktrees: [gone])
        let store = await scene.startedStore()
        let row = try #require(store.row(gone.path))

        let outcomes = await store.remove([row], deleteBranches: true)

        #expect(outcomes == [.failed(gone.path, .stateChanged(.missing))])
        #expect(scene.remover.requests.map(\.deleteBranch) == [false])
    }

    @Test func anErrorThatIsNoRemovalErrorIsReportedAsGitFailing() async throws {
        let scene = try readyScene()
        scene.remover.onRemoval { _ in throw CommandError.timedOut("git") }
        let store = await scene.startedStore()
        let row = try #require(store.row(worktree.path))

        let outcomes = await store.remove([row], deleteBranches: true)

        guard case .failed(let path, .gitRefused(let message)) = outcomes.first else {
            Issue.record("expected gitRefused, got \(outcomes)")
            return
        }
        #expect(path == worktree.path)
        #expect(message.contains("git"))
    }
}
