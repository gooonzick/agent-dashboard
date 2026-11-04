import CoreModels
import Foundation
import GitKit
import ProcessKit
import Safety
import Shell
import Synchronization
import TestSupport
import Testing

// What the tests of `WorktreeRemover` are made of: a repository with a worktree to remove, a runner that can be told
// what to answer, and processes that stop, or do not, as the test says.

/// The branch of most tests, as in the tests of the reader: a name with a slash and non-ASCII letters, which git has to
/// hand back unharmed.
let removalBranch = "feature/ünï"

/// The answer of a recheck that finds nothing wrong.
let stillReady: @Sendable () async -> RemovalEligibility = { .ready(needsStopping: false) }

// MARK: A repository to remove from

/// A repository in which `tmp` is ignored, and a clean worktree of it in `worktrees/feature wt`.
struct RemovalScene: Sendable {
    enum Failure: Error {
        case notListed(String)
    }

    let sandbox: GitSandbox
    let repo: URL
    /// The folder of the worktree, as the test addresses it.
    let folder: URL
    /// The path under which git lists the worktree.
    let path: String
    /// `nil` for a worktree that is detached.
    let branch: String?

    var folderExists: Bool { FileManager.default.fileExists(atPath: folder.path) }

    /// The worktree as `GitReader` reads it now, with its lock if it has one.
    func worktree() async throws -> Worktree {
        let listed = try await GitReader(runner: sandbox.runner).worktrees(repo: repo)
        guard let found = listed.first(where: { $0.path == path }) else { throw Failure.notListed(path) }
        return found
    }

    func request(
        deleteBranch: Bool = true, stopping groups: [ProcessGroup] = [], confirmedAs: RemovalConfirmation = .ready
    ) async throws -> RemovalRequest {
        RemovalRequest(
            repo: repo, worktree: try await worktree(), deleteBranch: deleteBranch, stopGroups: groups,
            confirmedAs: confirmedAs)
    }

    /// The paths of all the worktrees that git lists, the main one included.
    func listedPaths() async throws -> [String] {
        try await GitReader(runner: sandbox.runner).worktrees(repo: repo).map(\.path)
    }

    func branchExists(_ name: String? = nil) async throws -> Bool {
        let name = try #require(name ?? branch)
        return try await !sandbox.git(["branch", "--list", name], in: repo).stdout.isEmpty
    }

    /// Locks the worktree, as `claude` does for a session: with `reason`, or without one if it is empty.
    func lock(reason: String) async throws {
        let options = reason.isEmpty ? [] : ["--reason", reason]
        try await sandbox.git(["worktree", "lock"] + options + [folder.path], in: repo)
    }
}

extension GitSandbox {
    /// A repository with one commit on `main`, and a worktree of it. It has no remote: the removal reads nothing from
    /// one, and four git commands make it where ten would. The tests of this suite make a few dozen of them, and git
    /// that runs in that many places at once leaves little of the machine to the tests of other suites that have a
    /// deadline.
    func makeRemovalScene(branch: String? = removalBranch) async throws -> RemovalScene {
        let repo = try await initRepository(named: "repo")
        try write("# Project\n", to: "README.md", in: repo)
        try write("tmp\n", to: ".gitignore", in: repo)
        try await git(["add", "README.md", ".gitignore"], in: repo)
        try await git(["commit", "--message", "Initial commit"], in: repo)
        let folder: URL
        if let branch {
            folder = try await addWorktree(of: repo, branch: branch, in: "worktrees/feature wt", from: "main")
        } else {
            folder = url.appending(path: "worktrees/feature wt", directoryHint: .isDirectory)
            try await git(["worktree", "add", "--detach", folder.path, "main"], in: repo)
        }
        return RemovalScene(
            sandbox: self, repo: repo, folder: folder, path: canonicalPath + "/worktrees/feature wt", branch: branch)
    }

    /// A remover that stops real processes. It runs the real git of the sandbox, unless it is given a `runner` to go
    /// through, which may pass the commands on to that git.
    func makeRemover(
        through runner: (any CommandRunning)? = nil, stopTimeout: Duration = .seconds(2)
    ) -> WorktreeRemover {
        WorktreeRemover(
            runner: runner ?? self.runner, signaler: ProcessSignaler(), sampler: ProcessSampler(),
            stopTimeout: stopTimeout)
    }
}

// MARK: Runners

/// A thread-safe list.
final class Recorder<Element: Sendable>: Sendable {
    private let storage = Mutex<[Element]>([])

    var all: [Element] { storage.withLock { $0 } }

    func append(_ element: Element) {
        storage.withLock { $0.append(element) }
    }
}

/// What a stand-in for git says about a repository that does not exist, for the tests that run no git: the worktrees
/// that it lists, the commit that the branch of the worktree is at, and the files that it tracks. The folder of the
/// worktree is a real one (`PretendScene`): the remover looks at the disk too.
struct PretendRepository: Sendable {
    var worktrees: [Worktree]
    /// What `git rev-parse` prints for the branch, or `nil` if there is no such branch: it then exits with 1.
    var tip: String?
    /// What `git ls-files -v -z` prints.
    var tracked = ""

    /// What `git worktree list --porcelain` prints.
    var listing: String {
        worktrees.map { worktree in
            var lines = ["worktree \(worktree.path)", "HEAD \(worktree.head ?? String(repeating: "0", count: 40))"]
            if let branch = worktree.branch { lines.append("branch refs/heads/\(branch)") }
            if worktree.isDetached { lines.append("detached") }
            if let lock = worktree.lock { lines.append(lock.reason.isEmpty ? "locked" : "locked \(lock.reason)") }
            if worktree.isPrunable { lines.append("prunable gitdir file points to non-existent location") }
            return lines.joined(separator: "\n") + "\n"
        }.joined(separator: "\n")
    }

    func answer(to subcommand: [String]) -> CommandResult {
        switch subcommand.first {
        case "worktree" where subcommand.dropFirst().first == "list":
            return CommandResult(exitCode: 0, stdout: listing, stderr: "")
        case "ls-files":
            return CommandResult(exitCode: 0, stdout: tracked, stderr: "")
        case "rev-parse":
            return tip.map { CommandResult(exitCode: 0, stdout: $0 + "\n", stderr: "") }
                ?? CommandResult(exitCode: 1, stdout: "", stderr: "")
        default:
            return CommandResult(exitCode: 0, stdout: "", stderr: "")
        }
    }
}

/// A runner that notes every command. It answers with `answer` if that gives a result. Otherwise `base` runs it. With
/// no `base` it is a stand-in for git: it answers as `pretending` does, or says that the command went well.
final class WatchedRunner: CommandRunning {
    struct Call: Sendable {
        let args: [String]
        /// Whether the task that ran the command had been cancelled by then.
        let cancelled: Bool

        /// What was asked of git, without the options that every command gets: `["worktree", "remove", "--", "/x"]`.
        var subcommand: [String] { WatchedRunner.subcommand(of: args) }

        /// Whether the command can change the repository: unlock, remove or prune a worktree, or delete a branch.
        var isWrite: Bool {
            switch subcommand.first {
            case "branch": true
            case "worktree": ["unlock", "remove", "prune"].contains(subcommand.dropFirst().first)
            default: false
            }
        }
    }

    private let base: (any CommandRunning)?
    private let pretense: PretendRepository?
    private let answer: @Sendable ([String]) async -> CommandResult?
    private let log = Recorder<Call>()

    init(
        wrapping base: (any CommandRunning)? = nil, pretending pretense: PretendRepository? = nil,
        answer: @escaping @Sendable ([String]) async -> CommandResult? = { _ in nil }
    ) {
        self.base = base
        self.pretense = pretense
        self.answer = answer
    }

    var calls: [Call] { log.all }

    /// The subcommands of the calls that can change something, in order.
    var writes: [[String]] { calls.filter(\.isWrite).map(\.subcommand) }

    static func subcommand(of args: [String]) -> [String] {
        guard let option = args.firstIndex(of: "-C") else { return args }
        return Array(args.dropFirst(option + 2))
    }

    func run(_ tool: String, _ args: [String], in directory: URL?, timeout: Duration) async throws -> CommandResult {
        log.append(Call(args: args, cancelled: Task.isCancelled))
        if let result = await answer(args) { return result }
        if let base { return try await base.run(tool, args, in: directory, timeout: timeout) }
        return pretense?.answer(to: Self.subcommand(of: args)) ?? CommandResult(exitCode: 0, stdout: "", stderr: "")
    }

    func which(_ tool: String) -> URL? {
        base?.which(tool)
    }
}

/// A worktree that git is pretended to list: the folder is a real one, in which the remover finds it, and the branch is
/// `b`, at `pretendHead`. The repository does not exist, so nothing here runs git.
struct PretendScene {
    let folder: TempDir
    let worktree: Worktree
    let runner: WatchedRunner

    static let repo = URL(filePath: "/work/repo")

    /// `listed` says how git lists the worktree if that is not how it is requested: it has changed since. `inside` are
    /// the names of other worktrees that git lists in the folder of this one.
    init(
        lock: WorktreeLock? = nil, isDetached: Bool = false, tip: String? = pretendHead, tracked: String = "",
        inside: [String] = [], listed: (Worktree) -> Worktree = { $0 },
        answer: @escaping @Sendable ([String]) async -> CommandResult? = { _ in nil }
    ) throws {
        folder = try TempDir(named: "My Projects")
        worktree = Worktree(
            path: folder.canonicalPath, head: pretendHead, branch: "b", isDetached: isDetached, lock: lock)
        let main = Worktree(path: "/work/repo", head: pretendHead, branch: "main", isMain: true)
        let path = folder.canonicalPath
        let inner = inside.map { Worktree(path: path + "/" + $0, head: pretendHead, branch: $0) }
        runner = WatchedRunner(
            pretending: PretendRepository(worktrees: [main, listed(worktree)] + inner, tip: tip, tracked: tracked),
            answer: answer)
    }

    func request(
        deleteBranch: Bool = false, stopping groups: [ProcessGroup] = [], confirmedAs: RemovalConfirmation = .ready
    ) -> RemovalRequest {
        RemovalRequest(
            repo: Self.repo, worktree: worktree, deleteBranch: deleteBranch, stopGroups: groups,
            confirmedAs: confirmedAs)
    }
}

/// The commit that the worktrees of the tests that run no git are at.
let pretendHead = String(repeating: "a", count: 40)

// MARK: Processes

/// The record that the real sampler has of the process `pid` right now.
func liveRecord(of pid: Int32) throws -> ProcessRecord {
    try #require(ProcessSampler().sample().first { $0.pid == pid }, "no process \(pid)")
}

/// Whether `condition` holds within `limit`: it is asked every 10 ms.
func eventually(within limit: Duration, _ condition: @Sendable () -> Bool) async -> Bool {
    let clock = ContinuousClock()
    let deadline = clock.now + limit
    while !condition() {
        if clock.now >= deadline { return false }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return true
}
