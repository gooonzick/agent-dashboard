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
    /// What the worktree was when the user asked for it to go, and so the least that the recheck has to find. It has
    /// no default: a request that is made without saying it would be taken for one that was confirmed as something.
    public let confirmedAs: RemovalConfirmation

    public init(
        repo: URL, worktree: Worktree, deleteBranch: Bool, stopGroups: [ProcessGroup], confirmedAs: RemovalConfirmation
    ) {
        self.repo = repo
        self.worktree = worktree
        self.deleteBranch = deleteBranch
        self.stopGroups = stopGroups
        self.confirmedAs = confirmedAs
    }
}

/// What the user confirmed that a worktree is, when they asked for it to be removed: the eligibility that it had then,
/// as far as it matters for the recheck.
public enum RemovalConfirmation: Sendable, Equatable {
    /// `.ready`: its request is merged. The user may not have seen a sheet ("Don't ask again"), and was told, if
    /// they were, that the request is merged. A recheck that says `.manual` does not do for it.
    case ready
    /// `.manual`: the user removed it knowing that its request is not merged, or that nobody can say.
    case manual
}

/// Why a removal did not go through, or not all the way. What is left of it is said for each case, and a case that
/// says that nothing was changed means the disk: the processes that were asked to stop have stopped by then.
public enum RemovalError: Error, Equatable {
    /// The worktree is not one that may be removed. It is the main one, or its folder is gone, which is for `prune`: a
    /// request for either is answered at once, with `.mainWorktree` or `.missing`, and so is one whose folder turns out
    /// to be gone when the removal looks at it again. Or the recheck, which looks at its state once more after the
    /// processes are stopped, did not answer `.ready`, or `.manual` for a request that was confirmed as manual, with
    /// nothing left to stop. Or the fetch before anything was stopped failed, which is `.blocked([.cantVerify])`, as
    /// the recheck says of a fetch that fails: what is on the remote is not known. Nothing was changed.
    case stateChanged(RemovalEligibility)
    /// Git refused, or failed, to do what it was asked: list the worktrees, unlock or remove the worktree, or prune.
    /// What it said, for people to read. The worktree is as it was, unless git failed halfway through deleting its
    /// folder, which it then says. A worktree that was unlocked first stays unlocked: its lock was stale.
    case gitRefused(String)
    /// The process with this id runs, and holds up the removal: it could not be stopped, or it holds the lock of the
    /// worktree and is not among those that were to be stopped. Nothing was changed.
    case processStillRunning(Int32)
    /// The worktree is removed, but its branch was not deleted: git said no (what it said), or the branch is not at the
    /// commit that the worktree had, because it has moved on since or is not to be found (what is wrong). The removal
    /// is not undone: the folder is gone, and the branch is still there.
    case branchNotDeleted(String)
    /// The worktree is not the one that the request was made for: since then it has been locked or unlocked, or the
    /// lock has been replaced, it is on another branch or commit, or git does not list it any more. Nothing was
    /// changed.
    case worktreeChanged
    /// The folder holds work that git does not show, and that `git worktree remove` deletes without a word: another
    /// worktree inside it, or tracked files that git is told not to look at (`assume-unchanged`, `skip-worktree`). A
    /// short reason, for people to read. Nothing was changed.
    case hiddenWork(String)
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
    /// 0. If there is a process to stop, what can refuse the removal without stopping anything is asked first: `git
    ///    fetch --prune` (a fetch that fails is `stateChanged(.blocked([.cantVerify]))`), then steps 3 and 4. A process
    ///    that is stopped cannot be started again, and one stopped for a removal that git or the folder refuses
    ///    anyway is lost for nothing. Steps 3 and 4 are still taken after step 2: the worktree may change while its
    ///    processes stop.
    /// 1. The processes of `request.stopGroups` are stopped.
    /// 2. `recheck` is called, just once, and must read the state of the worktree anew. It has to be at least what
    ///    the user confirmed (`request.confirmedAs`): `.ready` with nothing running goes on whatever was confirmed, and
    ///    `.manual` with nothing running goes on only for a request that was confirmed as `.manual`. Any other answer,
    ///    one that says that something still runs (`needsStopping`) included, ends the removal with
    ///    `RemovalError.stateChanged` and nothing is changed. The processes of step 1 may have been stopped by then:
    ///    that cannot be undone.
    /// 3. The worktree is looked at once more, as git lists it and as it is on the disk: it has to be the one that the
    ///    request was made for. Its folder is there, and its lock, branch, detachment and commit are those of the
    ///    request. A folder that is gone is `stateChanged(.missing)`, and anything else that is different is
    ///    `worktreeChanged`: nothing is unlocked or deleted on the word of a request that is minutes old.
    /// 4. The folder is looked at for work that git does not show: another worktree inside it, and files that git is
    ///    told not to look at. That is `hiddenWork`, for `git worktree remove` would delete it.
    /// 5. A lock that names its owner is taken off, if the owner is no more. A lock that names none is never taken off:
    ///    git refuses a locked worktree, and the removal ends with `RemovalError.gitRefused`.
    /// 6. The worktree is removed by git.
    /// 7. If `request.deleteBranch` is set and the worktree has a branch, the branch is deleted, provided that it is
    ///    still at the commit that the worktree had: deleting a branch takes its reflog with it. Otherwise the removal
    ///    ends with `RemovalError.branchNotDeleted`, with the folder gone.
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
    /// Reading from git, unlocking a worktree and deleting a branch take no time.
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

        if !Self.stopOrder(of: request.stopGroups).isEmpty { try await refuseBeforeStopping(request) }
        try await stop(request.stopGroups)

        // Once the processes are stopped nothing is left to stop. A recheck that still sees something run, or run
        // again, is not looking at the worktree that was to be removed. And it has to be at least as good as what the
        // user confirmed: a worktree that was removed as merged, perhaps without a sheet, whose request the host does
        // not call merged now, was never confirmed as anything else.
        let eligibility = await recheck()
        switch (eligibility, request.confirmedAs) {
        case (.ready(needsStopping: false), _), (.manual(needsStopping: false), .manual):
            break
        case (.ready, _), (.manual, _), (.mainWorktree, _), (.missing, _), (.blocked, _):
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

    /// Step 0 of `remove`: everything that may refuse the removal and changes nothing, read before a process is
    /// stopped for it. The lock is left to step 5, after the stop: its owner may be one of the processes to stop.
    private func refuseBeforeStopping(_ request: RemovalRequest) async throws {
        do {
            try await GitReader(runner: runner).fetchPrune(repo: request.repo)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw RemovalError.stateChanged(.blocked([.cantVerify]))
        }
        try Task.checkCancellation()
        let listing = try await currentWorktrees(of: request.repo)
        try Self.verify(request.worktree, in: listing)
        try await refuseHiddenWork(in: request.worktree, among: listing)
    }

    /// Steps 3 to 7 of `remove`.
    private func delete(_ request: RemovalRequest) async throws {
        let repo = request.repo
        let worktree = request.worktree
        let path = worktree.path

        // The request is as old as the list that it was made from, and what is done now is done to the worktree as it
        // is now: with another lock, branch or commit, or without a folder, it is not what was asked to be removed.
        let listing = try await currentWorktrees(of: repo)
        try Self.verify(worktree, in: listing)

        // The lock of a session that has ended is stale, and is the only lock that is taken off. If its owner still
        // runs, it was not stopped, and the lock is what it says it is.
        let owner = worktree.lock?.ownerPID
        if let owner, signaler.isAlive(owner) { throw RemovalError.processStillRunning(owner) }

        try await refuseHiddenWork(in: worktree, among: listing)

        if owner != nil {
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

        guard request.deleteBranch, !worktree.isDetached, let branch = worktree.branch else { return }
        try await requireBranch(branch, at: worktree.head, in: repo)
        let deletion = try await git(["branch", "-D", "--", branch], in: repo)
        guard deletion.exitCode == 0 else { throw RemovalError.branchNotDeleted(deletion.message) }
    }

    /// The worktrees of the repository as git lists them now.
    private func currentWorktrees(of repo: URL) async throws -> [Worktree] {
        do {
            return try await GitReader(runner: runner).worktrees(repo: repo)
        } catch let error as GitError {
            throw RemovalError.gitRefused(error.errorDescription ?? "git could not list the worktrees")
        }
    }

    /// Checks that `snapshot` is what `listing` says of the worktree now, and that its folder is there.
    ///
    /// Git says `prunable` of a worktree whose folder is gone, but not of one that is locked: the disk is looked at
    /// too.
    private static func verify(_ snapshot: Worktree, in listing: [Worktree]) throws {
        guard let current = listing.first(where: { $0.path == snapshot.path }) else {
            throw RemovalError.worktreeChanged
        }
        guard !current.isMain else { throw RemovalError.stateChanged(.mainWorktree) }
        var isDirectory: ObjCBool = false
        let folderIsThere =
            FileManager.default.fileExists(atPath: current.path, isDirectory: &isDirectory) && isDirectory.boolValue
        guard !current.isPrunable, folderIsThere else { throw RemovalError.stateChanged(.missing) }
        guard
            current.lock == snapshot.lock, current.branch == snapshot.branch,
            current.isDetached == snapshot.isDetached, current.head == snapshot.head
        else { throw RemovalError.worktreeChanged }
    }

    /// Refuses a folder that holds work that `git worktree remove` would delete, though it does not show it. Git
    /// shows nothing of another worktree that lies in a folder that is ignored, as a session of Claude Code makes in
    /// `.claude/worktrees/`, and nothing of a change to a file that it is told not to look at.
    ///
    /// Of the files that are told not to be looked at, those marked `assume-unchanged` all count: their tag in
    /// `git ls-files -v` is a lowercase letter, and an edit to one is invisible. Those marked `skip-worktree` (tag `S`)
    /// count if the file is on the disk, for then it may be edited. A sparse checkout leaves such files out, and a file
    /// that is not there holds nothing.
    ///
    /// Paths and entries are looked at as Unicode scalars, as git's output is in `GitParsers`: as `Character`s, the
    /// `/` or the space before a name that starts with a combining mark makes one `Character` with it, and the name
    /// would neither start with the folder nor come after its tag.
    private func refuseHiddenWork(in worktree: Worktree, among listing: [Worktree]) async throws {
        let prefix = (worktree.path + "/").unicodeScalars
        if let inner = listing.first(where: { $0.path.unicodeScalars.starts(with: prefix) }) {
            let name = String(inner.path.unicodeScalars.dropFirst(prefix.count))
            throw RemovalError.hiddenWork("another worktree is inside this one: \(name)")
        }

        let tracked = try await git(["ls-files", "-v", "-z"], in: URL(filePath: worktree.path))
        guard tracked.exitCode == 0 else { throw RemovalError.gitRefused(tracked.message) }
        // `<tag> <path>`, each ended by a NUL.
        let hidden = tracked.stdout.unicodeScalars.split(separator: "\0").compactMap { entry -> String? in
            guard let tag = entry.first else { return nil }
            let file = String(entry.dropFirst(2))
            if tag.properties.isLowercase { return file }
            return tag == "S" && Self.mayBeOnDisk(worktree.path + "/" + file) ? file : nil
        }
        if let first = hidden.first {
            let others = hidden.count > 1 ? " and \(hidden.count - 1) more" : ""
            throw RemovalError.hiddenWork("git is told not to look for changes in \(first)\(others)")
        }
    }

    /// Whether something may be at `path`. Only `lstat` saying that there is no such file, or that a folder on the way
    /// is none, says that nothing is there: a folder that cannot be looked into may hold the file all the same, and
    /// what cannot be looked at is not taken for nothing.
    private static func mayBeOnDisk(_ path: String) -> Bool {
        var info = stat()
        guard lstat(path, &info) != 0 else { return true }
        return errno != ENOENT && errno != ENOTDIR
    }

    /// Checks that `branch` is still at `commit`, the commit that the worktree had. `git branch -D` takes the reflog of
    /// the branch with it: if the branch has moved on since the request, what it has gained cannot be recovered.
    private func requireBranch(_ branch: String, at commit: String?, in repo: URL) async throws {
        let result = try await git(
            ["rev-parse", "--verify", "--quiet", "--end-of-options", "refs/heads/\(branch)"], in: repo)
        guard result.exitCode == 0 else {
            throw RemovalError.branchNotDeleted("the branch '\(branch)' could not be read: \(result.message)")
        }
        let tip = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        guard tip == commit else {
            let was = commit.map { String($0.prefix(7)) } ?? "no commit"
            throw RemovalError.branchNotDeleted(
                "the branch '\(branch)' is at \(tip.prefix(7)) now, not at \(was), the commit that the worktree had: "
                    + "it was kept")
        }
    }

    /// Runs `git -C <directory> <arguments>` and returns the result, whatever the exit code. `settings` are for this
    /// one command (`-c`). The folder is passed with `-C` and not as the one that git is started in, so that a folder
    /// that is gone is a failure of git like any other, and not an error of the launch.
    private func git(
        _ arguments: [String], in directory: URL, settings: [String] = [],
        timeout: Duration = WorktreeRemover.gitTimeout
    ) async throws -> CommandResult {
        let options = settings.flatMap { ["-c", $0] } + ["-C", directory.path]
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

    /// The processes of all the groups in the order in which they are stopped: one tree of the `ppid`s among all of
    /// them, deepest first, so that every process comes before the one that started it, whichever group each is in. A
    /// process that is listed twice is stopped once.
    ///
    /// Not in the order of the ids: they wrap around, and a child can have a lower one than its parent. Not group after
    /// group either: a server that leads a group of its own is the child of a shell that leads another. Not leader
    /// last: the leader of a session of the Claude app was started by a helper that is a member. Of two processes at
    /// the same depth, the one with the lower id is first.
    private static func stopOrder(of groups: [ProcessGroup]) -> [ProcessRecord] {
        var seen = Set<Identity>()
        let records = groups.flatMap { [$0.leader] + $0.members }.filter { seen.insert(Identity($0)).inserted }
        let byPID = Dictionary(records.map { ($0.pid, $0) }, uniquingKeysWith: { first, _ in first })
        /// How many parents of `record` are among the processes. A chain longer than that is a loop of parents, which
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
