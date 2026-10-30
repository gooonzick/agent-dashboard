import Foundation
import Shell

/// Real `git` for tests: a scratch folder to make repositories in, and a runner whose `git` is the same on every
/// machine.
///
/// The folder is called `My Projects`, with a space in it, as the folders of real projects are. The `git` that the
/// sandbox starts has a configuration of its own instead of the developer's: no global or system config file, `main`
/// as the default branch, a made up author, no prompts, and none of the `GIT_DIR` variables that a hook of an outer
/// repository leaves behind. A test then gives the same result whatever is in `~/.gitconfig`, and whatever runs it.
///
/// Keep the sandbox for as long as the test goes on: the folder is removed with it. A test suite that holds it in a
/// property does that.
public struct GitSandbox: Sendable {
    /// A git command that did not exit with 0.
    public struct Failure: Error, CustomStringConvertible {
        public let command: String
        public let exitCode: Int32
        public let stderr: String

        public var description: String { "\(command) exited with \(exitCode): \(stderr)" }
    }

    private let scratch: TempDir

    public init(named name: String = "My Projects") throws {
        scratch = try TempDir(named: name)
    }

    /// The scratch folder.
    public var url: URL { scratch.url }

    /// The scratch folder as git reports it (`TempDir.canonicalPath`).
    public var canonicalPath: String { scratch.canonicalPath }

    /// A runner for the code under test. It runs `git` the way the sandbox does, and anything else as it is.
    public var runner: any CommandRunning { IsolatedGitRunner(scratch: scratch.url) }

    // MARK: Running git

    /// Runs `git <arguments>` in `directory` and returns what it printed. `environment` adds variables for this one
    /// command, such as `GIT_COMMITTER_DATE`.
    ///
    /// Throws a `Failure` if git exits with anything but 0, so that a step of a test's setup that goes wrong stops the
    /// test there. The code under test is run through `runner`, which reports a failure as a result.
    @discardableResult
    public func git(
        _ arguments: [String], in directory: URL, environment: [String: String] = [:]
    ) async throws -> CommandResult {
        let isolated = IsolatedGitRunner(scratch: scratch.url, environment: environment)
        let result = try await isolated.run("git", ["-C", directory.path] + arguments, in: nil, timeout: .seconds(60))
        guard result.exitCode == 0 else {
            throw Failure(
                command: "git " + arguments.joined(separator: " "), exitCode: result.exitCode, stderr: result.stderr)
        }
        return result
    }

    /// What `name` stands for in `directory`, as a full commit id: `git rev-parse <name>`.
    public func revision(_ name: String = "HEAD", in directory: URL) async throws -> String {
        try await git(["rev-parse", name], in: directory).stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: Repositories

    /// A repository, with no commit and no remote, in the sandbox folder `name`.
    public func initRepository(named name: String) async throws -> URL {
        try await git(["init", name], in: url)
        return url.appending(path: name, directoryHint: .isDirectory)
    }

    /// A bare repository, as a server keeps it, in `name`, with no branch in it yet.
    public func makeRemote(named name: String = "remote.git") async throws -> URL {
        try await git(["init", "--bare", name], in: url)
        return url.appending(path: name, directoryHint: .isDirectory)
    }

    /// A clone of `remote` in `name`.
    public func clone(_ remote: URL, named name: String) async throws -> URL {
        try await git(["clone", remote.path, name], in: url)
        return url.appending(path: name, directoryHint: .isDirectory)
    }

    /// The usual starting point: a bare remote and a clone of it. The clone has one commit, with a `README.md`, on
    /// `main`, which is pushed, so that `origin/main` exists and `main` tracks it.
    public func makeRepository(
        named name: String = "repo", remoteNamed remoteName: String = "remote.git"
    ) async throws -> (repo: URL, remote: URL) {
        let remote = try await makeRemote(named: remoteName)
        let repo = try await clone(remote, named: name)
        try write("# Project\n", to: "README.md", in: repo)
        try await git(["add", "README.md"], in: repo)
        try await git(["commit", "--message", "Initial commit"], in: repo)
        try await git(["push", "--set-upstream", "origin", "main"], in: repo)
        return (repo, remote)
    }

    /// Adds a worktree of `repo` on the new branch `branch`, started at `base`, in the sandbox folder `folder`.
    /// (A branch that is started at a remote branch, as `origin/main` is, tracks it.)
    public func addWorktree(
        of repo: URL, branch: String, in folder: String, from base: String = "origin/main"
    ) async throws -> URL {
        let worktree = url.appending(path: folder, directoryHint: .isDirectory)
        try await git(["worktree", "add", "-b", branch, worktree.path, base], in: repo)
        return worktree
    }

    /// Makes a commit that changes nothing and returns its id.
    @discardableResult
    public func commit(_ message: String, in directory: URL) async throws -> String {
        try await git(["commit", "--allow-empty", "--message", message], in: directory)
        return try await revision(in: directory)
    }

    /// Writes `contents` to `path`, which is relative to `directory`, and makes the folders on the way.
    public func write(_ contents: String, to path: String, in directory: URL) throws {
        let file = directory.appending(path: path)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try contents.write(to: file, atomically: true, encoding: .utf8)
    }
}

/// Starts `git` with a configuration of its own, through `env`. Everything but `git` runs as it is.
struct IsolatedGitRunner: CommandRunning {
    private let runner = CommandRunner()
    /// What `env` is given before the command: `-u NAME` for the variables to remove, then those to set.
    private let settings: [String]

    init(scratch: URL, environment: [String: String] = [:]) {
        // A git hook that runs the tests has pointed these at its own repository. `env` wants its options first.
        var settings = ["GIT_DIR", "GIT_WORK_TREE", "GIT_INDEX_FILE", "GIT_COMMON_DIR", "GIT_PREFIX"].flatMap {
            ["-u", $0]
        }
        settings += [
            // Not the developer's configuration: neither ~/.gitconfig and ~/.config/git/*, nor the system's.
            "HOME=\(scratch.path)",
            "GIT_CONFIG_NOSYSTEM=1",
            "GIT_CONFIG_GLOBAL=/dev/null",
            "GIT_CONFIG_COUNT=1",
            "GIT_CONFIG_KEY_0=init.defaultBranch",
            "GIT_CONFIG_VALUE_0=main",
            "GIT_AUTHOR_NAME=Test Author",
            "GIT_AUTHOR_EMAIL=author@example.com",
            "GIT_COMMITTER_NAME=Test Committer",
            "GIT_COMMITTER_EMAIL=committer@example.com",
            "GIT_TERMINAL_PROMPT=0",
        ]
        self.settings = settings + environment.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }
    }

    func run(_ tool: String, _ args: [String], in directory: URL?, timeout: Duration) async throws -> CommandResult {
        // Without a `git` there is nothing to isolate; the plain runner reports it as it would anyway.
        guard tool == "git", let git = runner.which("git") else {
            return try await runner.run(tool, args, in: directory, timeout: timeout)
        }
        return try await runner.run("/usr/bin/env", settings + [git.path] + args, in: directory, timeout: timeout)
    }

    func which(_ tool: String) -> URL? {
        runner.which(tool)
    }
}
