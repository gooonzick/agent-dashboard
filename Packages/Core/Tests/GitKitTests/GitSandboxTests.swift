import Foundation
import Shell
import TestSupport
import Testing

/// The sandbox is what keeps the tests of git away from the repositories of the person who runs them.
@Suite(.timeLimit(.minutes(1))) struct GitSandboxTests {
    @Test func aSandboxIsNeverPartOfARepositoryItLivesIn() async throws {
        // The temporary folder of a machine can be inside a repository. Git looks for the repository in the folders
        // above the one it is run in, so a test that runs git in a folder that is no repository would be running it on
        // that one, which may be a real one. Here the folder that holds the sandbox is made a repository, as it would
        // be.
        let sandbox = try GitSandbox()
        try await sandbox.git(["init"], in: sandbox.url.deletingLastPathComponent())

        let result = try await sandbox.runner.run(
            "git", ["-C", sandbox.url.path, "rev-parse", "--git-dir"], in: nil, timeout: .seconds(30))

        #expect(result.exitCode != 0, "git found \(result.stdout)")
    }

    @Test func aRepositoryInsideTheSandboxIsFoundAsEver() async throws {
        let sandbox = try GitSandbox()
        let (repo, _) = try await sandbox.makeRepository()
        let worktree = try await sandbox.addWorktree(of: repo, branch: "topic", in: "worktrees/topic wt")

        #expect(try await sandbox.git(["rev-parse", "--git-dir"], in: repo).stdout == ".git\n")
        #expect(try await sandbox.git(["rev-parse", "--show-toplevel"], in: worktree).stdout.hasSuffix("topic wt\n"))
    }
}
