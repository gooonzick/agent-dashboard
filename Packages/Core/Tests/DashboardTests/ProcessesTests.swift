import CoreModels
@testable import Dashboard
import Foundation
import Testing

@MainActor
@Suite struct ProcessesTests {
    @Test func neverShowsTheAppItselfOrWhatItStarted() async throws {
        let scene = try Scene()
        let worktree = linked("/x/wt", branch: "feature")
        scene.addRepository("/x/repo", worktrees: [worktree])
        let own = ProcessInfo.processInfo.processIdentifier
        scene.sampler.set([
            process(own, parent: 1, name: "Agent Dashboard", cwd: worktree.path),
            process(5001, parent: own, name: "git", cwd: worktree.path),  // a git status of the app
            process(5002, parent: 5001, name: "ssh", cwd: worktree.path),  // and what that started
            process(5003, parent: 1, name: "node", cwd: worktree.path + "/web"),  // the user's dev server
        ])
        let store = await scene.startedStore()

        await store.refresh()

        #expect(store.row(worktree.path)?.groups.map(\.leader.pid) == [5003])
        #expect(scene.sampler.samples == 1)
    }

    @Test func whatRunsInAReadyWorktreeHasToBeStoppedFirst() async throws {
        let scene = try Scene()
        let worktree = linked("/x/wt", branch: "feature")
        scene.addRepository("/x/repo", worktrees: [worktree])
        scene.reviews.answer("feature", ReviewInfo(state: .merged, number: 1, headSHA: sha("a")))
        let store = await scene.startedStore()
        #expect(store.readyToRemove.map(\.eligibility) == [.ready(needsStopping: false)])

        scene.sampler.set([process(600, name: "claude", cwd: worktree.path)])
        store.isWindowVisible = true

        #expect(await poll { store.readyToRemove.map(\.eligibility) == [.ready(needsStopping: true)] })
        #expect(store.row(worktree.path)?.groups.first?.kind == .agentSession)
        store.isWindowVisible = false
    }
}
