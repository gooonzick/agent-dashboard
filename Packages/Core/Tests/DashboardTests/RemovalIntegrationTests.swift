import CoreModels
@testable import Dashboard
import Foundation
import GitKit
import Hosting
import Safety
import Shell
import TestSupport
import Testing

/// The removal of a worktree from end to end, as the Remove button of the sheet asks for it (Ruling 60): real git in a
/// `GitSandbox`, the real `Reader` and `WorktreeRemover`, and nothing faked but the host's answer, the processes and the
/// disk scan. Nothing outside the sandbox is ever named to the remover.
@MainActor
@Suite(.timeLimit(.minutes(1))) struct RemovalIntegrationTests {
    @Test func theSheetsRemoveDeletesTheFolderAndTheBranchAndTheRowGoes() async throws {
        let sandbox = try GitSandbox()
        let (repo, _) = try await sandbox.makeRepository()
        let folder = try await sandbox.addWorktree(of: repo, branch: "feature/done", in: "worktrees/done")
        try sandbox.write("done\n", to: "done.txt", in: folder)
        try await sandbox.git(["add", "done.txt"], in: folder)
        try await sandbox.git(["commit", "--message", "Done"], in: folder)
        try await sandbox.git(["push", "--set-upstream", "origin", "feature/done"], in: folder)
        let head = try await sandbox.revision(in: folder)
        // The request is merged on the host: main takes the branch, and is pushed.
        try await sandbox.git(["merge", "--no-ff", "--message", "Merge feature/done", "feature/done"], in: repo)
        try await sandbox.git(["push", "origin", "main"], in: repo)

        let repoPath = sandbox.canonicalPath + "/repo"
        let worktreePath = sandbox.canonicalPath + "/worktrees/done"
        let setting = try Scene()
        let reviews = FakeReviews()
        reviews.answer("feature/done", ReviewInfo(state: .merged, number: 7, headSHA: head))
        let env = DashboardEnvironment(
            scanner: FakeScanner(roots: [URL(filePath: sandbox.canonicalPath)], found: [repoPath]),
            git: OriginOnAHost(GitReader(runner: sandbox.runner)), reviews: reviews, hosting: FakeHosting(),
            sizes: FakeSizes(), sampler: FakeSampler(), signaler: FakeSignaler(),
            remover: WorktreeRemover(runner: sandbox.runner, signaler: FakeSignaler(), sampler: FakeSampler()),
            watcher: FakeWatcher(), cache: setting.cache, settings: setting.settings)
        let store = DashboardStore(env: env)
        await store.start()
        await setting.settle(store)

        let row = try #require(store.row(worktreePath))
        #expect(row.eligibility == .ready(needsStopping: false))
        // Only ever a folder of the sandbox.
        try #require(row.worktree.path.hasPrefix(sandbox.canonicalPath + "/"))
        try #require(row.repoPath.hasPrefix(sandbox.canonicalPath + "/"))

        let outcomes = await store.remove([row], deleteBranches: true)

        #expect(outcomes == [.removed(worktreePath)])
        #expect(!FileManager.default.fileExists(atPath: folder.path))
        #expect(try await sandbox.git(["branch", "--list", "feature/done"], in: repo).stdout.isEmpty)
        #expect(store.row(worktreePath) == nil)
        #expect(store.row(repoPath) != nil)
    }
}

/// The real git of the sandbox, but with `origin` on a host: the bare remote of the sandbox is a folder, which no
/// hosting service is asked about. Fetching still goes to the folder.
private struct OriginOnAHost: GitReading {
    let base: GitReader

    init(_ base: GitReader) {
        self.base = base
    }

    func remotes(repo: URL) async throws -> [Remote] {
        try await base.remotes(repo: repo).map { Remote(name: $0.name, url: "https://gitlab.example.test/team/app.git") }
    }

    func worktrees(repo: URL) async throws -> [Worktree] { try await base.worktrees(repo: repo) }
    func status(worktree: URL) async throws -> WorktreeStatus { try await base.status(worktree: worktree) }
    func stashCount(repo: URL, branch: String) async throws -> Int {
        try await base.stashCount(repo: repo, branch: branch)
    }
    func commitsNotOnAnyRemote(worktree: URL) async throws -> Int {
        try await base.commitsNotOnAnyRemote(worktree: worktree)
    }
    func isAncestorOrEqual(_ commit: String, of other: String, repo: URL) async throws -> Bool? {
        try await base.isAncestorOrEqual(commit, of: other, repo: repo)
    }
    func fetchPrune(repo: URL) async throws { try await base.fetchPrune(repo: repo) }
}
