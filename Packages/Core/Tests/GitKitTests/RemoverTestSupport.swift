import CoreModels
import Darwin
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

/// A repository with a remote, in which `tmp` is ignored, and a clean worktree of it in `worktrees/feature wt`.
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

    func request(deleteBranch: Bool = true, stopping groups: [ProcessGroup] = []) async throws -> RemovalRequest {
        RemovalRequest(repo: repo, worktree: try await worktree(), deleteBranch: deleteBranch, stopGroups: groups)
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
    func makeRemovalScene(branch: String? = removalBranch) async throws -> RemovalScene {
        let (repo, _) = try await makeRepository()
        try write("tmp\n", to: ".gitignore", in: repo)
        try await git(["add", ".gitignore"], in: repo)
        try await git(["commit", "--message", "Ignore tmp"], in: repo)
        try await git(["push"], in: repo)
        let folder: URL
        if let branch {
            folder = try await addWorktree(of: repo, branch: branch, in: "worktrees/feature wt")
        } else {
            folder = url.appending(path: "worktrees/feature wt", directoryHint: .isDirectory)
            try await git(["worktree", "add", "--detach", folder.path, "origin/main"], in: repo)
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

/// A runner that notes every command. It answers with `answer` if that gives a result, and otherwise lets `base` run
/// it, or says that the command went well when there is no `base`.
final class WatchedRunner: CommandRunning {
    struct Call: Sendable {
        let args: [String]
        /// Whether the task that ran the command had been cancelled by then.
        let cancelled: Bool

        /// What was asked of git, without the options that every command gets: `["worktree", "remove", "--", "/x"]`.
        var subcommand: [String] {
            guard let option = args.firstIndex(of: "-C") else { return args }
            return Array(args.dropFirst(option + 2))
        }
    }

    private let base: (any CommandRunning)?
    private let answer: @Sendable ([String]) async -> CommandResult?
    private let log = Recorder<Call>()

    init(
        wrapping base: (any CommandRunning)? = nil,
        answer: @escaping @Sendable ([String]) async -> CommandResult? = { _ in nil }
    ) {
        self.base = base
        self.answer = answer
    }

    var calls: [Call] { log.all }

    func run(_ tool: String, _ args: [String], in directory: URL?, timeout: Duration) async throws -> CommandResult {
        log.append(Call(args: args, cancelled: Task.isCancelled))
        if let result = await answer(args) { return result }
        guard let base else { return CommandResult(exitCode: 0, stdout: "", stderr: "") }
        return try await base.run(tool, args, in: directory, timeout: timeout)
    }

    func which(_ tool: String) -> URL? {
        base?.which(tool)
    }
}

// MARK: Processes

/// A signaler for processes that exist only here: they stop, or do not, when they are sent a signal, as the test says.
final class ScriptedSignaler: ProcessSignaling {
    struct Sent: Equatable, Sendable {
        let pid: Int32
        let sig: Int32
        let at: ContinuousClock.Instant
    }

    private struct Processes {
        var alive: Set<Int32>
        var exitsAt: [Int32: ContinuousClock.Instant] = [:]
        var sent: [Sent] = []

        /// A process that was given a time to exit is gone once it has passed.
        mutating func settle(at now: ContinuousClock.Instant) {
            for (pid, time) in exitsAt where time <= now {
                alive.remove(pid)
                exitsAt[pid] = nil
            }
        }
    }

    private let store: Mutex<Processes>
    private let ignoringTerm: Set<Int32>
    private let unkillable: Set<Int32>
    private let lingering: [Int32: Duration]

    /// - Parameters:
    ///   - alive: The processes that run. All the others are gone.
    ///   - ignoringTerm: The processes that stay as they are when they are sent `SIGTERM`.
    ///   - unkillable: The processes that stay as they are even when they are sent `SIGKILL`.
    ///   - lingering: The processes that take that long to exit after `SIGTERM`.
    init(
        alive: [Int32], ignoringTerm: Set<Int32> = [], unkillable: Set<Int32> = [], lingering: [Int32: Duration] = [:]
    ) {
        store = Mutex(Processes(alive: Set(alive)))
        self.ignoringTerm = ignoringTerm
        self.unkillable = unkillable
        self.lingering = lingering
    }

    var sent: [Sent] { store.withLock { $0.sent } }

    /// Who was sent which signal, in order, without the times.
    var signals: [[Int32]] { sent.map { [$0.pid, $0.sig] } }

    func firstTime(of sig: Int32) -> ContinuousClock.Instant? {
        sent.first { $0.sig == sig }?.at
    }

    func signal(_ pid: Int32, _ sig: Int32) -> Bool {
        let now = ContinuousClock.now
        return store.withLock { processes in
            processes.settle(at: now)
            processes.sent.append(Sent(pid: pid, sig: sig, at: now))
            guard processes.alive.contains(pid) else { return false }
            switch sig {
            case SIGKILL where !unkillable.contains(pid):
                processes.alive.remove(pid)
            case SIGTERM where !ignoringTerm.contains(pid):
                if let delay = lingering[pid] {
                    processes.exitsAt[pid] = now + delay
                } else {
                    processes.alive.remove(pid)
                }
            default:
                break
            }
            return true
        }
    }

    func isAlive(_ pid: Int32) -> Bool {
        let now = ContinuousClock.now
        return store.withLock { processes in
            processes.settle(at: now)
            return processes.alive.contains(pid)
        }
    }
}

/// A sampler that answers from a script: the first call gets the first snapshot, the next call the next one, and every
/// call after the last gets the last.
final class ScriptedSampler: ProcessSampling {
    private let snapshots: [[ProcessRecord]]
    private let calls = Mutex<Int>(0)

    init(successive snapshots: [[ProcessRecord]]) {
        precondition(!snapshots.isEmpty)
        self.snapshots = snapshots
    }

    convenience init(always records: [ProcessRecord]) {
        self.init(successive: [records])
    }

    var sampleCount: Int { calls.withLock { $0 } }

    func sample() -> [ProcessRecord] {
        let call = calls.withLock { count in
            defer { count += 1 }
            return count
        }
        return snapshots[min(call, snapshots.count - 1)]
    }
}

extension Process {
    /// Ends the process with `SIGKILL`, and does not wait for it. For a test that awaits while the process runs:
    /// `kill()` of `TestSupport` waits with `waitUntilExit`, which in async tests that ran beside each other was seen
    /// not to return in ten minutes, with each of three threads of Swift concurrency parked in it. The process is a
    /// zombie for a moment, until Foundation collects it, which `ProcessSignaling.isAlive` does not count as alive.
    func killWithoutWaiting() {
        guard isRunning else { return }
        Darwin.kill(processIdentifier, SIGKILL)
    }
}

/// A process that was started a given number of seconds after a fixed moment. What a test leaves out is true of any
/// process: it has no working directory, no memory and listens on no port.
func processRecord(_ pid: Int32, parent: Int32 = 1, name: String = "node", started: Double = 0) -> ProcessRecord {
    ProcessRecord(
        pid: pid, ppid: parent, name: name, executablePath: nil, arguments: [], cwd: nil, footprintBytes: 0,
        startDate: Date(timeIntervalSince1970: 1_800_000_000 + started), listeningPorts: [])
}

func processGroup(_ leader: ProcessRecord, _ members: ProcessRecord...) -> ProcessGroup {
    ProcessGroup(kind: .other, title: leader.name, leader: leader, members: members)
}

extension ProcessRecord {
    /// The same process as the kernel could have it at another time: it has another name, or began later.
    func replacing(name: String? = nil, startDate: Date? = nil) -> ProcessRecord {
        ProcessRecord(
            pid: pid, ppid: ppid, name: name ?? self.name, executablePath: executablePath, arguments: arguments,
            cwd: cwd, footprintBytes: footprintBytes, startDate: startDate ?? self.startDate,
            listeningPorts: listeningPorts)
    }
}

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
