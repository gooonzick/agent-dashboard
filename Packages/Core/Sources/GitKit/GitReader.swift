import CoreModels
import Foundation
import Shell

/// A `git` command that failed.
///
/// A non-zero exit is not always a failure: `merge-base --is-ancestor` exits with 1 to say no, and that is an answer.
/// Every other exit that is not 0 is thrown, with what git said, so that no failure reads as an empty list or a zero.
public enum GitError: Error, Equatable, LocalizedError {
    /// git exited with `exitCode`, as it does in a folder that is no repository. `stderr` is what it printed, in the
    /// language of the user: it is for people to read, and nothing reads a value from it.
    case failed(command: String, exitCode: Int32, stderr: String)
    /// git exited with 0 but printed something that is not what the command prints: nothing can be read from it.
    case unexpectedOutput(command: String, output: String)

    public var errorDescription: String? {
        switch self {
        case .failed(let command, let exitCode, let stderr):
            return "\(command) failed with exit code \(exitCode)" + (stderr.isEmpty ? "" : ": \(stderr)")
        case .unexpectedOutput(let command, let output):
            return "\(command) printed something unexpected: \(output)"
        }
    }
}

/// Reads what git knows about a repository and its worktrees.
///
/// Every call runs git as a child process. It throws `CommandError` if there is no git, or if git runs out of time, and
/// `GitError` if git fails. No call turns a failure into an empty or a zero answer: what is decided from these answers,
/// whether a worktree can be removed, must not rest on a guess.
public protocol GitReading: Sendable {
    /// The worktrees of the repository that `repo` belongs to, the main one first. `repo` may be any of its worktrees.
    /// Paths are canonical (`canonicalPath`), except for those of worktrees whose folder is gone: they are as git
    /// printed them.
    func worktrees(repo: URL) async throws -> [Worktree]

    /// The status of the worktree at `worktree`. Untracked files and changes in submodules count, whatever the
    /// configuration of git says about showing them.
    func status(worktree: URL) async throws -> WorktreeStatus

    /// How many stashes were made on `branch` in the repository at `repo`. The stashes of a repository are shared by
    /// all its worktrees; each one says on which branch it was made.
    func stashCount(repo: URL, branch: String) async throws -> Int

    /// The remotes of the repository at `repo`.
    func remotes(repo: URL) async throws -> [Remote]

    /// How many commits of the worktree's HEAD no remote branch has: `git rev-list --count HEAD --not --remotes`.
    /// All of them if there is no remote, and none if the branch does not exist yet. A branch whose ref is damaged has
    /// commits that git cannot count: that is an error, and not none.
    func commitsNotOnAnyRemote(worktree: URL) async throws -> Int

    /// Whether `commit` is `other` or one of its ancestors. `nil` when `other` is not a commit that the repository at
    /// `repo` has, as with the head of a merge request that was never fetched. `commit` has to be one that it has.
    func isAncestorOrEqual(_ commit: String, of other: String, repo: URL) async throws -> Bool?

    /// Brings the remote branches of the repository at `repo` up to date and forgets those that are gone
    /// (`git fetch --prune`). Unlike the others it writes to the repository, and it uses the network.
    func fetchPrune(repo: URL) async throws
}

/// Reads git through the `git` command line tool.
public struct GitReader: GitReading {
    /// A big repository on a cold disk takes a while to read, a slow network to fetch from.
    private static let readTimeout: Duration = .seconds(60)
    private static let fetchTimeout: Duration = .seconds(120)

    private let runner: any CommandRunning

    public init(runner: any CommandRunning) {
        self.runner = runner
    }

    public func worktrees(repo: URL) async throws -> [Worktree] {
        let porcelain = try await output(of: ["worktree", "list", "--porcelain"], in: repo)
        return GitParsers.worktrees(porcelain: porcelain).map { worktree in
            Worktree(
                path: canonicalPath(worktree.path), head: worktree.head, branch: worktree.branch,
                isMain: worktree.isMain, isDetached: worktree.isDetached, lock: worktree.lock,
                isPrunable: worktree.isPrunable)
        }
    }

    public func status(worktree: URL) async throws -> WorktreeStatus {
        // Which files `git status` shows is a matter of the user's configuration (`status.showUntrackedFiles`, and
        // `submodule.<name>.ignore` in a project), and a setting that hides some would make a worktree that holds work
        // look clean. Not even `git worktree remove` makes up for that: with untracked files hidden, it removes a
        // worktree that has some. So both are asked for, whatever is set.
        let arguments = ["status", "--porcelain=v2", "--branch", "--untracked-files=normal", "--ignore-submodules=none"]
        let porcelain = try await output(of: arguments, in: worktree)
        // A branch that has no commit has no date of one, and `git log` fails on it.
        guard GitParsers.hasCommits(porcelainV2: porcelain) else {
            return GitParsers.status(porcelainV2: porcelain, lastCommit: nil)
        }
        // The date is for display only: if it is not a time, there is none, and that is no error.
        let seconds = try await output(of: ["log", "-1", "--format=%ct"], in: worktree)
        let lastCommit = TimeInterval(seconds.trimmingCharacters(in: .whitespacesAndNewlines))
        return GitParsers.status(
            porcelainV2: porcelain, lastCommit: lastCommit.map(Date.init(timeIntervalSince1970:)))
    }

    public func stashCount(repo: URL, branch: String) async throws -> Int {
        let subjects = try await output(of: ["stash", "list", "--format=%gs"], in: repo)
        return GitParsers.stashCount(subjects: subjects, branch: branch)
    }

    public func remotes(repo: URL) async throws -> [Remote] {
        GitParsers.remotes(verbose: try await output(of: ["remote", "-v"], in: repo))
    }

    public func commitsNotOnAnyRemote(worktree: URL) async throws -> Int {
        let arguments = ["rev-list", "--count", "HEAD", "--not", "--remotes"]
        let result = try await run(arguments, in: worktree)
        guard result.exitCode == 0 else {
            // On a branch that has no commit yet, `HEAD` names nothing and git cannot count. No commit is then missing
            // from a remote. Anything else that makes git fail stands as the failure that it is.
            if try await headIsUnbornBranch(in: worktree) { return 0 }
            throw failure(of: arguments, in: worktree, result)
        }
        // A count that cannot be read must not become "nothing is missing".
        guard let count = Int(result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            throw unexpectedOutput(of: arguments, in: worktree, result)
        }
        return count
    }

    public func isAncestorOrEqual(_ commit: String, of other: String, repo: URL) async throws -> Bool? {
        // `cat-file -e <id>^{commit}` cannot tell a missing commit from an error: it exits with 128 for both.
        // `rev-parse --verify --quiet` exits with 1 for a missing one and with 128 for an error. `--end-of-options`
        // keeps an id that looks like an option from being taken for one.
        let lookup = ["rev-parse", "--verify", "--quiet", "--end-of-options", "\(other)^{commit}"]
        let found = try await run(lookup, in: repo)
        switch found.exitCode {
        case 0: break
        case 1: return nil
        default: throw failure(of: lookup, in: repo, found)
        }
        let arguments = ["merge-base", "--is-ancestor", "--end-of-options", commit, other]
        let result = try await run(arguments, in: repo)
        switch result.exitCode {
        case 0: return true
        case 1: return false
        default: throw failure(of: arguments, in: repo, result)
        }
    }

    public func fetchPrune(repo: URL) async throws {
        _ = try await output(of: ["fetch", "--prune"], in: repo, readOnly: false, timeout: Self.fetchTimeout)
    }

    // MARK: Running git

    /// Whether HEAD is on a branch that does not exist yet, as it is in a repository that has no commit, or in a
    /// worktree that was made with `--orphan`.
    ///
    /// `rev-list` fails in the same way for a branch that does not exist and for one whose ref is damaged, and so does
    /// `rev-parse --verify --quiet HEAD`: it exits with 1 for both, a ref that a crash left empty included. So the ref
    /// is asked for by its name. `show-ref --exists` exits with 2 for a ref that is not there, and only that is an
    /// unborn branch: 0 is a ref that is there, so something else is wrong, and 1 one that is there and cannot be
    /// read. `symbolic-ref` is as strict: it exits with 1 for a detached HEAD, which is on no branch, and with 128
    /// when HEAD, or the ref that it names, cannot be read. `show-ref --exists` is from git 2.43. With an older git
    /// this is never true, and the failure that the caller has stands.
    private func headIsUnbornBranch(in directory: URL) async throws -> Bool {
        let head = try await run(["symbolic-ref", "--quiet", "HEAD"], in: directory)
        guard head.exitCode == 0 else { return false }
        let ref = head.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        return try await run(["show-ref", "--exists", ref], in: directory).exitCode == 2
    }

    /// Runs `git <arguments>` in `directory` and returns the result, whatever the exit code.
    ///
    /// The folder is passed with `-C`, and not as the folder that git is started in, so that a folder that is gone is a
    /// failure of git like any other, and not an error of the launch.
    ///
    /// A command that only reads runs with `--no-optional-locks`. Git takes some locks for what it was not asked to do,
    /// as it writes the index to bring it up to date when it shows the status, and a scan of all the worktrees of the
    /// user must not get in the way of what the user does in them.
    ///
    /// Non-ASCII names and lock reasons are printed as they are, and not as octal escapes (`core.quotepath`). No
    /// signature is verified in front of what `git log` prints (`log.showSignature`).
    private func run(
        _ arguments: [String], in directory: URL, readOnly: Bool = true, timeout: Duration = Self.readTimeout
    ) async throws -> CommandResult {
        let options = ["-c", "core.quotepath=false", "-c", "log.showSignature=false", "-C", directory.path]
        return try await runner.run(
            "git", (readOnly ? ["--no-optional-locks"] : []) + options + arguments, in: nil, timeout: timeout)
    }

    /// What `git <arguments>` printed, if it exited with 0.
    private func output(
        of arguments: [String], in directory: URL, readOnly: Bool = true, timeout: Duration = Self.readTimeout
    ) async throws -> String {
        let result = try await run(arguments, in: directory, readOnly: readOnly, timeout: timeout)
        guard result.exitCode == 0 else { throw failure(of: arguments, in: directory, result) }
        return result.stdout
    }

    private func failure(of arguments: [String], in directory: URL, _ result: CommandResult) -> GitError {
        .failed(
            command: Self.description(of: arguments, in: directory), exitCode: result.exitCode,
            stderr: result.stderr.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private func unexpectedOutput(of arguments: [String], in directory: URL, _ result: CommandResult) -> GitError {
        .unexpectedOutput(
            command: Self.description(of: arguments, in: directory),
            output: result.stdout.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// The command as an error names it, without the options that every command gets.
    private static func description(of arguments: [String], in directory: URL) -> String {
        (["git", "-C", directory.path] + arguments).joined(separator: " ")
    }
}
