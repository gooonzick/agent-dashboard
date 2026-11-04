import CoreModels
@testable import Dashboard
import Foundation
import GitKit
import ProcessKit
import Testing

/// What the store does when the user stops what runs in a worktree: who is signalled, what the rows show afterwards,
/// and what is refused.
@MainActor
@Suite(.timeLimit(.minutes(1))) struct StoppingTests {
    private let worktree = linked("/x/wt", branch: "feature")

    @Test func stoppingAGroupSignalsAllOfItAndTheRowLosesIt() async throws {
        let scene = try Scene(signaler: FakeSignaler(alive: [700, 701, 800]))
        scene.addRepository("/x/repo", worktrees: [worktree])
        scene.sampler.set([
            process(700, cwd: worktree.path),
            process(701, parent: 700, name: "esbuild", cwd: worktree.path),
            process(800, name: "vite", cwd: worktree.path),
        ])
        let store = await scene.startedStore()
        await store.sampleProcesses()
        let row = try #require(store.row(worktree.path))
        let node = try #require(row.groups.first { $0.leader.pid == 700 })

        let failure = await store.stop([node], of: row)

        #expect(failure == nil)
        #expect(scene.signaler.signals == [[701, SIGTERM], [700, SIGTERM]])  // the child first, and nothing of vite
        #expect(store.row(worktree.path)?.groups.map(\.leader.pid) == [800])  // sampled again at once
        #expect(store.stopping.isEmpty)
    }

    @Test func aGroupIsStoppingUntilItIsGone() async throws {
        let scene = try Scene(signaler: FakeSignaler(alive: [700], ignoringTerm: [700]))
        scene.addRepository("/x/repo", worktrees: [worktree])
        scene.sampler.set([process(700, cwd: worktree.path)])
        let store = await scene.startedStore()
        await store.sampleProcesses()
        let row = try #require(store.row(worktree.path))

        let stop = Task { await store.stop(row.groups, of: row) }
        #expect(await poll { store.stopping == [700] && scene.signaler.signals == [[700, SIGTERM]] })
        // A second stop of the same group, while the first waits for it to exit, sends nothing.
        #expect(await store.stop(row.groups, of: row) == nil)
        #expect(scene.signaler.signals == [[700, SIGTERM]])
        scene.signaler.exit(700)  // it takes its time, and goes before it is killed
        let failure = await stop.value

        #expect(failure == nil)
        #expect(store.stopping.isEmpty)
        #expect(store.row(worktree.path)?.groups.isEmpty == true)
        #expect(scene.signaler.signals == [[700, SIGTERM]])
    }

    @Test func nothingIsStoppedInAWorktreeThatIsBeingRemoved() async throws {
        let scene = try Scene(signaler: FakeSignaler(alive: [700]))
        scene.addRepository("/x/repo", worktrees: [worktree])
        scene.reviews.answer("feature", ReviewInfo(state: .merged, number: 1, headSHA: sha("a")))
        scene.sampler.set([process(700, cwd: worktree.path)])
        let gate = Gate()
        scene.remover.onRemoval { _ in await gate.wait() }
        let store = await scene.startedStore()
        await store.sampleProcesses()
        let row = try #require(store.row(worktree.path))
        scene.sampler.set([])  // the remover stopped it, and the recheck finds nothing running
        let removal = Task { await store.remove([row], deleteBranches: false) }
        #expect(await poll { scene.remover.runningRepos == ["/x/repo"] })

        let failure = await store.stop(row.groups, of: row)

        #expect(failure == .removalUnderWay)
        #expect(scene.signaler.signals.isEmpty)
        #expect(store.stopping.isEmpty)
        gate.open()
        #expect(await removal.value == [.removed(worktree.path)])
    }

    @Test func aProcessThatSurvivesTheKillIsReported() async throws {
        let scene = try Scene(signaler: FakeSignaler(alive: [700], unkillable: [700]))
        scene.addRepository("/x/repo", worktrees: [worktree])
        scene.sampler.set([process(700, cwd: worktree.path)])
        let store = await scene.startedStore()
        await store.sampleProcesses()
        let row = try #require(store.row(worktree.path))

        let failure = await store.stop(row.groups, of: row)

        #expect(failure == .stillRunning(700))
        #expect(scene.signaler.signals == [[700, SIGTERM], [700, SIGKILL]])
        #expect(store.stopping.isEmpty)
        #expect(store.row(worktree.path)?.groups.map(\.leader.pid) == [700])
    }

    @Test func aRemovalThatFailedNoLongerHoldsBackAStop() async throws {
        let scene = try Scene(signaler: FakeSignaler(alive: [700]))
        scene.addRepository("/x/repo", worktrees: [worktree])
        scene.reviews.answer("feature", ReviewInfo(state: .merged, number: 1, headSHA: sha("a")))
        scene.remover.onRemoval { _ in throw RemovalError.gitRefused("busy") }
        scene.sampler.set([process(700, cwd: worktree.path)])
        let store = await scene.startedStore()
        let ready = try #require(store.row(worktree.path))
        scene.sampler.set([])  // nothing runs while it is removed
        let outcomes = await store.remove([ready], deleteBranches: false)
        #expect(outcomes == [.failed(worktree.path, .gitRefused("busy"))])

        scene.sampler.set([process(700, cwd: worktree.path)])
        await store.sampleProcesses()
        let row = try #require(store.row(worktree.path))
        #expect(await store.stop(row.groups, of: row) == nil)
        #expect(scene.signaler.signals == [[700, SIGTERM]])
    }
}
