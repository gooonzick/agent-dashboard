import CoreModels
import Foundation
import ProcessKit
import Safety
import Shell

/// What to remove, and what to stop before that.
public struct RemovalRequest: Sendable {
    /// The repository that the worktree belongs to. Git is run on it (`git -C`), and not in the folder that is removed.
    public let repo: URL
    public let worktree: Worktree
    /// Also delete the local branch of the worktree, once its folder is gone. A detached worktree has no branch to
    /// delete, and nothing happens for it.
    public let deleteBranch: Bool
    /// The processes that run in the worktree and are stopped first.
    public let stopGroups: [ProcessGroup]

    public init(repo: URL, worktree: Worktree, deleteBranch: Bool, stopGroups: [ProcessGroup]) {
        self.repo = repo
        self.worktree = worktree
        self.deleteBranch = deleteBranch
        self.stopGroups = stopGroups
    }
}

/// Why a removal did not go through, or not all the way. What is left of it is said for each case, and a case that
/// says that nothing was changed means the disk: the processes that were asked to stop have stopped by then.
public enum RemovalError: Error, Equatable {
    /// The worktree is not one that may be removed. It is the main one, or its folder is gone, which is for `prune`: a
    /// request for either is answered at once, with `.mainWorktree` or `.missing`. Or the recheck, which looks at its
    /// state once more after the processes are stopped, did not answer `.ready` or `.manual`. Nothing was changed.
    case stateChanged(RemovalEligibility)
    /// Git refused, or failed, to do what it was asked: unlock or remove the worktree, or prune. What it said, for
    /// people to read. The worktree is as it was, unless git failed halfway through deleting its folder, which it then
    /// says. A worktree that was unlocked first stays unlocked: its lock was stale.
    case gitRefused(String)
    /// The process with this id runs, and holds up the removal: it could not be stopped, or it holds the lock of the
    /// worktree and is not among those that were to be stopped. Nothing was changed.
    case processStillRunning(Int32)
    /// The worktree is removed, but git did not delete its branch. What it said. The removal is not undone: the folder
    /// is gone, and the branch is still there.
    case branchNotDeleted(String)
}

/// Removes worktrees, and stops what runs in them first.
///
/// "Never delete unsaved work" is kept by `RemovalPolicy`, which says whether a worktree may be removed, and asks again
/// right before the folder is deleted. What deletes it is `git worktree remove`, and nothing else: it refuses a
/// worktree that has changes or files that git does not know, and it deletes the files that git ignores along with the
/// folder. It is never run with `--force`, and no folder is ever deleted by anything but git.
public protocol WorktreeRemoving: Sendable {
    /// Removes the worktree of `request`. Each of these steps that fails ends the removal there.
    ///
    /// 1. The processes of `request.stopGroups` are stopped.
    /// 2. `recheck` is called, just once, and must read the state of the worktree anew. If it answers anything but
    ///    `.ready` or `.manual`, the removal ends with `RemovalError.stateChanged` and nothing is changed. The
    ///    processes of step 1 may have been stopped by then: that cannot be undone.
    /// 3. A lock that names its owner is taken off, if the owner is no more. A lock that names none is never taken off:
    ///    git refuses a locked worktree, and the removal ends with `RemovalError.gitRefused`.
    /// 4. The worktree is removed by git.
    /// 5. If `request.deleteBranch` is set and the worktree has a branch, the branch is deleted.
    ///
    /// The main worktree, and a worktree whose folder is gone, are not removed: the request is refused before step 1,
    /// as `RemovalError.stateChanged`, and nothing is stopped for it.
    ///
    /// Giving up (cancelling the task) is possible until step 3 begins, and then nothing is deleted. From there on git
    /// is let finish, so that a folder is not left half deleted.
    func remove(_ request: RemovalRequest, recheck: @Sendable () async -> RemovalEligibility) async throws

    /// Forgets all the worktrees of the repository whose folders are gone (`git worktree prune`). It does not delete
    /// their branches, which may hold commits that no remote has.
    func prune(repo: URL) async throws
}

/// Removes worktrees with the `git` command line tool, and stops processes with signals.
///
/// The processes are stopped bottom-up, each one before the process that started it: every process of every group
/// gets `SIGTERM`, and then up to `stopTimeout` to exit. Those that are still there get `SIGKILL`, and a moment to die.
/// One that does not is `RemovalError.processStillRunning`, and nothing is removed.
///
/// A process is signalled only if it is still the one that was sampled. A process id is given to another process once
/// the first has exited, and what runs under the id of a record that is minutes old may be anything. So a fresh sample
/// is taken before each of the two signals, and an id is only signalled if the sample has it with the `startDate` and
/// the `name` of the record: what does not is taken for gone. The process of the app itself is never signalled.
public struct WorktreeRemover: WorktreeRemoving {
    /// The longest that a process gets to die after `SIGKILL`, or `stopTimeout` if that is shorter: it dies at once,
    /// unless it is stuck in the kernel.
    private static let killGrace: Duration = .seconds(2)
    /// How often the processes that were told to stop are looked at.
    private static let pollInterval: Duration = .milliseconds(50)
    /// Unlocking a worktree and deleting a branch take no time.
    private static let gitTimeout: Duration = .seconds(60)
    /// Deleting a folder does: a worktree can hold a few hundred thousand files, `node_modules` and build products. A
    /// command that runs out of time is asked to stop, and git that is stopped halfway through leaves half of the
    /// folder. So this is not a limit that the work is meant to reach.
    private static let removalTimeout: Duration = .seconds(600)

    private let runner: any CommandRunning
    private let signaler: any ProcessSignaling
    private let sampler: any ProcessSampling
    private let stopTimeout: Duration

    public init(
        runner: any CommandRunning, signaler: any ProcessSignaling, sampler: any ProcessSampling,
        stopTimeout: Duration = .seconds(5)
    ) {
        self.runner = runner
        self.signaler = signaler
        self.sampler = sampler
        self.stopTimeout = stopTimeout
    }

    public func remove(_ request: RemovalRequest, recheck: @Sendable () async -> RemovalEligibility) async throws {
        try Task.checkCancellation()
        // Nothing is stopped for a request that can only fail. The main worktree is the repository itself. For a
        // worktree whose folder is gone no status can be read, so nothing says that its branch holds no work that is
        // saved nowhere else: that is for `prune`, which never deletes a branch.
        guard !request.worktree.isMain else { throw RemovalError.stateChanged(.mainWorktree) }
        guard !request.worktree.isPrunable else { throw RemovalError.stateChanged(.missing) }

        try await stop(request.stopGroups)

        let eligibility = await recheck()
        switch eligibility {
        case .ready, .manual:
            break
        case .mainWorktree, .missing, .blocked:
            throw RemovalError.stateChanged(eligibility)
        }
        // The last moment to give up. A caller who has gone does not get a folder deleted.
        try Task.checkCancellation()

        // A task of its own, which does not hear of the caller giving up: cancelling asks git to stop, and git that is
        // stopped halfway through a folder leaves half of it behind, a worktree with its files missing.
        try await Task { try await self.delete(request) }.value
    }

    public func prune(repo: URL) async throws {
        let result = try await git(["worktree", "prune"], in: repo)
        guard result.exitCode == 0 else { throw RemovalError.gitRefused(result.message) }
    }

    // MARK: Deleting

    /// Steps 3 to 5 of `remove`.
    private func delete(_ request: RemovalRequest) async throws {
        let repo = request.repo
        let path = request.worktree.path

        // The lock of a session that has ended is stale, and is the only lock that is taken off. If its owner still
        // runs, it was not stopped, and the lock is what it says it is.
        if let owner = request.worktree.lock?.ownerPID {
            guard !signaler.isAlive(owner) else { throw RemovalError.processStillRunning(owner) }
            let unlock = try await git(["worktree", "unlock", "--", path], in: repo)
            guard unlock.exitCode == 0 else { throw RemovalError.gitRefused(unlock.message) }
        }

        // `status.showUntrackedFiles=no`, which people have in their configuration, makes git take a worktree that
        // holds untracked files for a clean one and delete it. It is overruled for this command, as it is when the
        // status is read. `--` keeps a path from being taken for an option.
        let removal = try await git(
            ["worktree", "remove", "--", path], in: repo, settings: ["status.showUntrackedFiles=normal"],
            timeout: Self.removalTimeout)
        guard removal.exitCode == 0 else { throw RemovalError.gitRefused(removal.message) }

        guard request.deleteBranch, !request.worktree.isDetached, let branch = request.worktree.branch else { return }
        let deletion = try await git(["branch", "-D", "--", branch], in: repo)
        guard deletion.exitCode == 0 else { throw RemovalError.branchNotDeleted(deletion.message) }
    }

    /// Runs `git -C <repo> <arguments>` and returns the result, whatever the exit code. `settings` are for this one
    /// command (`-c`). The folder is passed with `-C` and not as the one that git is started in, so that a folder that
    /// is gone is a failure of git like any other, and not an error of the launch.
    private func git(
        _ arguments: [String], in repo: URL, settings: [String] = [], timeout: Duration = WorktreeRemover.gitTimeout
    ) async throws -> CommandResult {
        let options = settings.flatMap { ["-c", $0] } + ["-C", repo.path]
        return try await runner.run("git", options + arguments, in: nil, timeout: timeout)
    }

    // MARK: Stopping

    /// Step 1 of `remove`.
    private func stop(_ groups: [ProcessGroup]) async throws {
        let targets = Self.stopOrder(of: groups)
        guard !targets.isEmpty else { return }

        var running = send(SIGTERM, to: targets)
        try await waitUntilGone(running, within: stopTimeout)
        running = running.filter { signaler.isAlive($0.pid) }
        guard !running.isEmpty else { return }

        running = send(SIGKILL, to: running)
        try await waitUntilGone(running, within: min(stopTimeout, Self.killGrace))
        // The first of them in the order in which they are stopped: a child is named before its parent.
        if let survivor = running.first(where: { signaler.isAlive($0.pid) }) {
            throw RemovalError.processStillRunning(survivor.pid)
        }
    }

    /// Sends `sig` to those of `targets` that are still the processes they were sampled as, in the order given, and
    /// returns them. A signal that is not sent is not an error here: the process is gone, or it is not the app's to
    /// stop, and `isAlive` tells which when it is looked at again.
    private func send(_ sig: Int32, to targets: [ProcessRecord]) -> [ProcessRecord] {
        let live = Dictionary(sampler.sample().map { ($0.pid, $0) }, uniquingKeysWith: { first, _ in first })
        let own = ProcessInfo.processInfo.processIdentifier
        let same = targets.filter { target in
            guard target.pid != own, let current = live[target.pid] else { return false }
            return current.startDate == target.startDate && current.name == target.name
        }
        for target in same { _ = signaler.signal(target.pid, sig) }
        return same
    }

    /// Returns when none of `targets` is alive, or after `limit`, whichever is first.
    private func waitUntilGone(_ targets: [ProcessRecord], within limit: Duration) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: limit)
        while targets.contains(where: { signaler.isAlive($0.pid) }) {
            let remaining = clock.now.duration(to: deadline)
            guard remaining > .zero else { return }
            try await Task.sleep(for: min(remaining, Self.pollInterval))
        }
    }

    /// The processes of `groups` in the order in which they are stopped: group after group, and in each one of them
    /// every process before the one that started it. A process that is listed twice is stopped once.
    private static func stopOrder(of groups: [ProcessGroup]) -> [ProcessRecord] {
        var seen = Set<Identity>()
        return groups.flatMap(bottomUp).filter { seen.insert(Identity($0)).inserted }
    }

    /// The leader and the members of `group`, deepest first in the tree of the `ppid`s among them.
    ///
    /// Not in the order of the ids: they wrap around, and a child can have a lower one than its parent. Not leader last
    /// either: the leader of a session of the Claude app was started by a helper that is a member. Of two processes at
    /// the same depth, the one with the lower id is first.
    private static func bottomUp(_ group: ProcessGroup) -> [ProcessRecord] {
        let records = [group.leader] + group.members
        let byPID = Dictionary(records.map { ($0.pid, $0) }, uniquingKeysWith: { first, _ in first })
        /// How many parents of `record` are in the group. A chain longer than the group is a loop of parents, which
        /// samples that were taken a moment apart can make: it is cut short.
        func depth(of record: ProcessRecord) -> Int {
            var depth = 0
            var current = record
            while depth < records.count, current.ppid != current.pid, let parent = byPID[current.ppid] {
                current = parent
                depth += 1
            }
            return depth
        }
        return records.map { (record: $0, depth: depth(of: $0)) }
            .sorted { $0.depth != $1.depth ? $0.depth > $1.depth : $0.record.pid < $1.record.pid }
            .map(\.record)
    }
}

/// Who a process is, as far as a sample can tell: the id, and what it was started as and when.
private struct Identity: Hashable {
    let pid: Int32
    let startDate: Date
    let name: String

    init(_ record: ProcessRecord) {
        pid = record.pid
        startDate = record.startDate
        name = record.name
    }
}

extension CommandResult {
    /// What a command said when it failed, for people to read: its error output, or its exit status when it said
    /// nothing.
    fileprivate var message: String {
        let text = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? "git exited with \(exitCode)" : text
    }
}
