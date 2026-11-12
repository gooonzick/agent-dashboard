import CoreModels
import Foundation
import Synchronization
import Testing
import TestSupport

@testable import Cleanup
@testable import Shell

/// The sandbox's git, with every call written down.
private final class RecordingGit: CommandRunning {
    private let runner: any CommandRunning
    private let log = Mutex<[Call]>([])

    init(_ runner: any CommandRunning) { self.runner = runner }

    var calls: [Call] { log.withLock { $0 } }

    func run(_ tool: String, _ args: [String], in directory: URL?, timeout: Duration) async throws -> CommandResult {
        log.withLock { $0.append(Call(line: ([tool] + args).joined(separator: " "), timeout: timeout)) }
        return try await runner.run(tool, args, in: directory, timeout: timeout)
    }

    func which(_ tool: String) -> URL? { runner.which(tool) }
}

/// The sandbox's git, which runs `change` once it has answered `ls-files`: the disk changing while git is asked.
private struct ChangingGit: CommandRunning {
    let runner: any CommandRunning
    let change: @Sendable () throws -> Void

    func run(_ tool: String, _ args: [String], in directory: URL?, timeout: Duration) async throws -> CommandResult {
        let result = try await runner.run(tool, args, in: directory, timeout: timeout)
        if args.contains("ls-files") { try change() }
        return result
    }

    func which(_ tool: String) -> URL? { runner.which(tool) }
}

/// A sandbox of real repositories, each one a worktree as the store would name it: by its canonical path.
private struct Projects {
    let sandbox: GitSandbox

    init() throws { sandbox = try GitSandbox() }

    var finder: BuildOutputFinder { BuildOutputFinder(runner: sandbox.runner) }

    /// A repository in `name`, with `gitignore` committed, and returns its canonical path.
    func repository(_ name: String, ignoring gitignore: String) async throws -> String {
        let repo = try await sandbox.initRepository(named: name)
        try sandbox.write(gitignore, to: ".gitignore", in: repo)
        try await sandbox.git(["add", ".gitignore"], in: repo)
        try await sandbox.git(["commit", "--message", "Ignore build outputs"], in: repo)
        return sandbox.canonicalPath + "/" + name
    }

    /// A folder at `path` with a file in it, so that there is something to delete.
    func folder(_ path: String) throws {
        try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        try Data("built".utf8).write(to: URL(filePath: path + "/artifact.o"))
    }

    func git(_ arguments: [String], in path: String) async throws {
        try await sandbox.git(arguments, in: URL(filePath: path))
    }
}

private let everyName = "target/\nbuild/\ndist/\n.build/\n.next/\nDerivedData/\n.turbo/\nnode_modules/\nout/\n"

private func exists(_ path: String) -> Bool { FileManager.default.fileExists(atPath: path) }

private func relative(_ outputs: [BuildOutput], to worktree: String) -> [String] {
    outputs.map { String($0.path.dropFirst(worktree.count + 1)) }.sorted()
}

@Suite("BuildOutputs")
struct BuildOutputsTests {
    @Test func candidatesAreTheseNames() async throws {
        let projects = try Projects()
        let repo = try await projects.repository("app", ignoring: everyName)
        for path in [
            "target", "build", "build/dist", "dist", "ios/.build", "apps/web/.next", "ios/App/Xcode/DerivedData",
            ".turbo",
            // Deeper than 4 below the worktree.
            "a/b/c/d/dist",
            // Inside node_modules and .git, which are never entered.
            "node_modules/left-pad/dist", ".git/build",
            // Ignored, but not a name of a build output.
            "out",
        ] {
            try projects.folder(repo + "/" + path)
        }
        // A file is not a folder.
        try Data().write(to: URL(filePath: repo + "/apps/web/build"))

        let outputs = await projects.finder.find(in: [repo])

        let kinds = Dictionary(
            uniqueKeysWithValues: outputs.map { (String($0.path.dropFirst(repo.count + 1)), $0.kind) })
        #expect(
            kinds == [
                "target": "Rust build",
                "build": "Build output",
                "dist": "Build output",
                "ios/.build": "Swift build",
                "apps/web/.next": "Next.js build",
                "ios/App/Xcode/DerivedData": "Xcode DerivedData copy",
                ".turbo": "Turbo cache",
            ])
    }

    @Test func onlyIgnoredFoldersWithoutTrackedFilesAreOffered() async throws {
        let projects = try Projects()
        let repo = try await projects.repository("app", ignoring: "target/\nbuild/\n")
        try projects.folder(repo + "/target")
        // Ignored, but a file in it is in the index.
        try projects.folder(repo + "/build")
        try await projects.git(["add", "--force", "build/artifact.o"], in: repo)
        // Not ignored.
        try projects.folder(repo + "/dist")

        let outputs = await projects.finder.find(in: [repo])

        #expect(relative(outputs, to: repo) == ["target"])
    }

    /// Real git already calls a folder with a tracked file in it not ignored. The index is asked on its own all the
    /// same, and a git that answers the two questions differently shows that it is.
    @Test func aTrackedFileIsEnoughToRefuseAFolderGitCallsIgnored() async throws {
        let dir = try TempDir(named: "app")
        let repo = dir.canonicalPath
        try FileManager.default.createDirectory(atPath: repo + "/.git", withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: repo + "/target", withIntermediateDirectories: true)
        let git = FakeCommands(
            installed: ["git"],
            answers: [
                "git --no-optional-locks -C \(repo) check-ignore -q -- target": ok(""),
                "git --no-optional-locks -C \(repo) --literal-pathspecs ls-files -- target": ok("target/keep.txt\n"),
            ])
        let finder = BuildOutputFinder(runner: git)
        let output = BuildOutput(path: repo + "/target", worktree: repo, title: "app/target", kind: "Rust build")

        #expect(await finder.find(in: [repo]).isEmpty)
        await #expect(throws: CleanupError.notEligible(output.path)) { try await finder.delete(output) }
        #expect(exists(repo + "/target"))
    }

    @Test func titleIsWorktreeNameAndRelativePath() async throws {
        let projects = try Projects()
        let meetily = try await projects.repository("meetily", ignoring: "target/\n")
        let dashboard = try await projects.repository("dashboard", ignoring: "dist/\n")
        try projects.folder(meetily + "/target")
        try projects.folder(dashboard + "/apps/web/dist")

        let outputs = await projects.finder.find(in: [meetily, dashboard])

        #expect(
            outputs == [
                BuildOutput(
                    path: meetily + "/target", worktree: meetily, title: "meetily/target", kind: "Rust build"),
                BuildOutput(
                    path: dashboard + "/apps/web/dist", worktree: dashboard, title: "dashboard/apps/web/dist",
                    kind: "Build output"),
            ])
    }

    @Test func gitIsAskedWithoutOptionalLocksAndATimeout() async throws {
        let projects = try Projects()
        let repo = try await projects.repository("app", ignoring: "target/\n")
        try projects.folder(repo + "/target")
        let git = RecordingGit(projects.sandbox.runner)
        let finder = BuildOutputFinder(runner: git)

        let outputs = await finder.find(in: [repo])
        try await finder.delete(try #require(outputs.first))

        #expect(git.calls.count == 4)
        for call in git.calls {
            #expect(call.line.hasPrefix("git --no-optional-locks "))
            #expect(call.timeout == .seconds(15))
        }
    }

    @Test func symlinkedFoldersAreNeitherOfferedNorEntered() async throws {
        let projects = try Projects()
        // Without a trailing slash a pattern matches a link too, so git calls these ignored.
        let repo = try await projects.repository("app", ignoring: "build\ndist\nvendor\n")
        let outside = projects.sandbox.canonicalPath + "/elsewhere"
        try projects.folder(outside + "/build")
        try projects.folder(outside + "/lib/dist")
        try FileManager.default.createSymbolicLink(atPath: repo + "/build", withDestinationPath: outside + "/build")
        try FileManager.default.createSymbolicLink(atPath: repo + "/vendor", withDestinationPath: outside + "/lib")

        let outputs = await projects.finder.find(in: [repo])

        #expect(outputs.isEmpty)
    }

    @Test func aRepositoryInsideTheWorktreeIsLeftAlone() async throws {
        let projects = try Projects()
        let repo = try await projects.repository("app", ignoring: "build/\ndist/\n.worktrees/\n")
        // Another repository inside this one, which its own .gitignore and index speak for.
        try projects.folder(repo + "/.worktrees/feature/build")
        try await projects.git(["init"], in: repo + "/.worktrees/feature")
        // A build output that holds a repository of its own, as a checkout of a `gh-pages` branch does.
        try projects.folder(repo + "/dist")
        try await projects.git(["init"], in: repo + "/dist")

        let outputs = await projects.finder.find(in: [repo])

        #expect(outputs.isEmpty)
    }

    @Test func aCandidateGitCannotCheckIsNotOffered() async throws {
        let projects = try Projects()
        // A worktree whose `.git` file leads nowhere, and a folder that is no repository at all.
        let broken = projects.sandbox.canonicalPath + "/broken"
        try projects.folder(broken + "/target")
        try Data("gitdir: /nowhere\n".utf8).write(to: URL(filePath: broken + "/.git"))
        let plain = projects.sandbox.canonicalPath + "/plain"
        try projects.folder(plain + "/target")

        let outputs = await projects.finder.find(in: [broken, plain, projects.sandbox.canonicalPath + "/gone"])

        #expect(outputs.isEmpty)
    }

    // MARK: Deleting

    @Test func deleteRemovesTheFolder() async throws {
        let projects = try Projects()
        let repo = try await projects.repository("app", ignoring: "target/\n")
        try projects.folder(repo + "/target")
        try projects.folder(repo + "/src")
        let output = try #require(await projects.finder.find(in: [repo]).first)

        try await projects.finder.delete(output)

        #expect(!exists(repo + "/target"))
        #expect(exists(repo + "/src/artifact.o"))
        #expect(exists(repo + "/.gitignore"))
        #expect(exists(repo + "/.git"))
    }

    @Test func aFolderThatGainedATrackedFileIsNotDeleted() async throws {
        let projects = try Projects()
        let repo = try await projects.repository("app", ignoring: "target/\n")
        try projects.folder(repo + "/target")
        let output = try #require(await projects.finder.find(in: [repo]).first)
        try Data("keep".utf8).write(to: URL(filePath: repo + "/target/keep.txt"))
        try await projects.git(["add", "--force", "target/keep.txt"], in: repo)

        await #expect(throws: CleanupError.notEligible(output.path)) { try await projects.finder.delete(output) }
        #expect(exists(repo + "/target/keep.txt"))
        #expect(exists(repo + "/target/artifact.o"))
    }

    @Test func aFolderNoLongerIgnoredIsNotDeleted() async throws {
        let projects = try Projects()
        let repo = try await projects.repository("app", ignoring: "target/\n")
        try projects.folder(repo + "/target")
        let output = try #require(await projects.finder.find(in: [repo]).first)
        try Data().write(to: URL(filePath: repo + "/.gitignore"))

        await #expect(throws: CleanupError.notEligible(output.path)) { try await projects.finder.delete(output) }
        #expect(exists(repo + "/target/artifact.o"))
    }

    @Test func aRecheckGitCannotRunRefuses() async throws {
        let projects = try Projects()
        let repo = try await projects.repository("app", ignoring: "target/\n")
        try projects.folder(repo + "/target")
        let output = try #require(await projects.finder.find(in: [repo]).first)
        try FileManager.default.moveItem(atPath: repo + "/.git", toPath: projects.sandbox.canonicalPath + "/app.git")
        try Data("gitdir: /nowhere\n".utf8).write(to: URL(filePath: repo + "/.git"))

        await #expect {
            try await projects.finder.delete(output)
        } throws: { error in
            guard case CleanupError.failed = error else { return false }
            return true
        }
        #expect(exists(repo + "/target/artifact.o"))
    }

    @Test func aSymlinkedOutputOutsideTheWorktreeIsNotDeleted() async throws {
        let projects = try Projects()
        let repo = try await projects.repository("app", ignoring: "target/\ndist/\n")
        try projects.folder(repo + "/target")
        try projects.folder(repo + "/apps/web/dist")
        let outputs = await projects.finder.find(in: [repo])
        let target = try #require(outputs.first { $0.title == "app/target" })
        let dist = try #require(outputs.first { $0.title == "app/apps/web/dist" })
        // The folder itself, and a folder on the way to it, have turned into links to folders outside the worktree.
        let outside = projects.sandbox.canonicalPath + "/elsewhere"
        try projects.folder(outside + "/target")
        try projects.folder(outside + "/apps/web/dist")
        try FileManager.default.removeItem(atPath: repo + "/target")
        try FileManager.default.createSymbolicLink(atPath: repo + "/target", withDestinationPath: outside + "/target")
        try FileManager.default.removeItem(atPath: repo + "/apps")
        try FileManager.default.createSymbolicLink(atPath: repo + "/apps", withDestinationPath: outside + "/apps")

        await #expect(throws: CleanupError.pathEscapes(target.path)) { try await projects.finder.delete(target) }
        await #expect(throws: CleanupError.pathEscapes(dist.path)) { try await projects.finder.delete(dist) }
        #expect(exists(outside + "/target/artifact.o"))
        #expect(exists(outside + "/apps/web/dist/artifact.o"))
    }

    @Test func aLinkSwappedInWhileGitAnswersIsNotFollowed() async throws {
        let projects = try Projects()
        let repo = try await projects.repository("app", ignoring: "target\n")
        try projects.folder(repo + "/target")
        let output = try #require(await projects.finder.find(in: [repo]).first)
        let outside = projects.sandbox.canonicalPath + "/elsewhere"
        try projects.folder(outside)
        let git = ChangingGit(runner: projects.sandbox.runner) {
            try FileManager.default.removeItem(atPath: repo + "/target")
            try FileManager.default.createSymbolicLink(atPath: repo + "/target", withDestinationPath: outside)
        }

        await #expect(throws: CleanupError.pathEscapes(output.path)) {
            try await BuildOutputFinder(runner: git).delete(output)
        }
        #expect(exists(outside + "/artifact.o"))
        #expect(exists(repo + "/target"))
    }

    /// `find` does not look inside a build output, which can be gigabytes; `delete` does, before anything goes.
    @Test func aRepositoryInsideAnOutputIsNotDeleted() async throws {
        let projects = try Projects()
        let repo = try await projects.repository("app", ignoring: "build/\ndist/\n")
        // A repository of its own, with work in it that is in no commit.
        try projects.folder(repo + "/build/sub")
        try await projects.git(["init"], in: repo + "/build/sub")
        try Data("work".utf8).write(to: URL(filePath: repo + "/build/sub/w.txt"))
        // A worktree, which has a `.git` file, deep down.
        try projects.folder(repo + "/dist/a/b/c/wt")
        try Data("gitdir: /elsewhere\n".utf8).write(to: URL(filePath: repo + "/dist/a/b/c/wt/.git"))
        let outputs = await projects.finder.find(in: [repo])
        let build = try #require(outputs.first { $0.title == "app/build" })
        let dist = try #require(outputs.first { $0.title == "app/dist" })

        await #expect(throws: CleanupError.notEligible("holds a git repository: build/sub")) {
            try await projects.finder.delete(build)
        }
        await #expect(throws: CleanupError.notEligible("holds a git repository: dist/a/b/c/wt")) {
            try await projects.finder.delete(dist)
        }
        #expect(exists(repo + "/build/sub/w.txt"))
        #expect(exists(repo + "/build/sub/artifact.o"))
        #expect(exists(repo + "/dist/a/b/c/wt/.git"))
        #expect(exists(repo + "/dist/a/b/c/wt/artifact.o"))
    }

    /// A folder in the output that cannot be read could hide a repository.
    @Test func anOutputWithAFolderThatCannotBeReadIsNotDeleted() async throws {
        let projects = try Projects()
        let repo = try await projects.repository("app", ignoring: "build/\n")
        try projects.folder(repo + "/build")
        try projects.folder(repo + "/build/locked")
        let output = try #require(await projects.finder.find(in: [repo]).first)
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: repo + "/build/locked")
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: repo + "/build/locked")
        }

        await #expect {
            try await projects.finder.delete(output)
        } throws: { error in
            guard case CleanupError.failed(let reason) = error else { return false }
            return reason == "could not read \(repo)/build/locked"
        }
        #expect(exists(repo + "/build/locked"))
        #expect(exists(repo + "/build/artifact.o"))
    }

    /// A name that starts with `-` is a path for git, not an option.
    @Test func aFolderNamedLikeAnOptionIsAPath() async throws {
        let projects = try Projects()
        let repo = try await projects.repository("app", ignoring: "build/\n")
        try projects.folder(repo + "/-x/build")

        let output = try #require(await projects.finder.find(in: [repo]).first)
        try await projects.finder.delete(output)

        #expect(output.title == "app/-x/build")
        #expect(!exists(repo + "/-x/build"))
    }

    @Test func aFolderThatIsGoneIsRefused() async throws {
        let projects = try Projects()
        let repo = try await projects.repository("app", ignoring: "target/\n")
        try projects.folder(repo + "/target")
        let output = try #require(await projects.finder.find(in: [repo]).first)
        try FileManager.default.removeItem(atPath: repo + "/target")

        await #expect(throws: CleanupError.pathEscapes(output.path)) { try await projects.finder.delete(output) }
    }

    @Test func aWorktreeThatIsNowALinkOrGoneIsRefused() async throws {
        let projects = try Projects()
        let repo = try await projects.repository("app", ignoring: "target/\n")
        try projects.folder(repo + "/target")
        let output = try #require(await projects.finder.find(in: [repo]).first)
        let moved = projects.sandbox.canonicalPath + "/moved"
        try FileManager.default.moveItem(atPath: repo, toPath: moved)

        await #expect(throws: CleanupError.pathEscapes(repo)) { try await projects.finder.delete(output) }

        try FileManager.default.createSymbolicLink(atPath: repo, withDestinationPath: moved)
        await #expect(throws: CleanupError.pathEscapes(repo)) { try await projects.finder.delete(output) }
        #expect(exists(moved + "/target/artifact.o"))
    }

    @Test func onlyABuildOutputStrictlyInsideTheWorktreeIsDeleted() async throws {
        let projects = try Projects()
        let repo = try await projects.repository("app", ignoring: "target/\nsrc/\nbuild/\ndist/\n")
        let other = try await projects.repository("other", ignoring: "target/\n")
        for path in [repo + "/src", repo + "/.git/build", repo + "/a/b/c/d/build", repo + "/node_modules/x/build",
            repo + "/build/dist", other + "/target"]
        {
            try projects.folder(path)
        }
        func output(_ path: String) -> BuildOutput {
            BuildOutput(path: path, worktree: repo, title: "", kind: "Build output")
        }
        let finder = projects.finder

        // Not strictly inside the worktree.
        for path in [repo, other + "/target", projects.sandbox.canonicalPath + "/app-target"] {
            await #expect(throws: CleanupError.pathEscapes(path)) { try await finder.delete(output(path)) }
        }
        // Inside, but no build output: a name that is not one, inside `.git` or `node_modules`, inside another build
        // output, too deep, or reached through `..`.
        for path in [
            repo + "/src", repo + "/.git/build", repo + "/node_modules/x/build", repo + "/build/dist",
            repo + "/a/b/c/d/build", repo + "/target/../src", repo + "//build",
        ] {
            await #expect(throws: CleanupError.notEligible(path)) { try await finder.delete(output(path)) }
        }
        for path in [repo + "/src", repo + "/.git/build", repo + "/a/b/c/d/build", repo + "/node_modules/x/build",
            repo + "/build/dist/artifact.o", other + "/target", repo + "/.git/HEAD"]
        {
            #expect(exists(path))
        }
    }

    @Test func aRepositoryThatAppearedOnTheWayIsNotDeleted() async throws {
        let projects = try Projects()
        let repo = try await projects.repository("app", ignoring: "dist/\n.worktrees/\n")
        try projects.folder(repo + "/dist")
        try projects.folder(repo + "/.worktrees/feature/dist")
        let output = try #require(await projects.finder.find(in: [repo]).first { $0.title == "app/dist" })
        try await projects.git(["init"], in: repo + "/dist")
        let nested = BuildOutput(
            path: repo + "/.worktrees/feature/dist", worktree: repo, title: "app/.worktrees/feature/dist",
            kind: "Build output")
        try await projects.git(["init"], in: repo + "/.worktrees/feature")

        await #expect(throws: CleanupError.notEligible(output.path)) { try await projects.finder.delete(output) }
        await #expect(throws: CleanupError.notEligible(nested.path)) { try await projects.finder.delete(nested) }
        #expect(exists(repo + "/dist/.git"))
        #expect(exists(repo + "/.worktrees/feature/dist/artifact.o"))
    }
}
