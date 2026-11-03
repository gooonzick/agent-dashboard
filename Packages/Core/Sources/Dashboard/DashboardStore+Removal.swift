import CoreModels
import Foundation
import GitKit
import Safety
import Shell

extension DashboardStore {
    /// Removes the worktrees of `rows`, one after the other, and their local branches if `deleteBranches` is set, and
    /// says what became of each, in the order of `rows`.
    ///
    /// Each goes to `WorktreeRemoving.remove` with the processes that the row shows, confirmed as what the row says it
    /// is (`.ready` or `.manual`: the recheck has to find at least that), and with a recheck that reads everything anew
    /// once they are stopped: `git fetch --prune`, then git, the host (its answers forgotten first) and a fresh sample
    /// of the processes. So `rows` are to be the rows as the user saw them when they confirmed, not as they are now. A
    /// row that is blocked is refused here, and nothing is stopped for it. Two removals in one repository never run at
    /// once, whoever asks for them. The repository is read again after every one, whatever came of it. A worktree whose
    /// folder is gone never has its branch deleted: it is only pruned (`prune`).
    public func remove(_ rows: [WorktreeRow], deleteBranches: Bool) async -> [RemovalOutcome] {
        var outcomes: [RemovalOutcome] = []
        for row in rows {
            let error = await removeOne(row, deleteBranch: deleteBranches && !row.worktree.isPrunable)
            outcomes.append(error.map { .failed(row.id, $0) } ?? .removed(row.id))
            await load([row.repoPath])
            saveCache()
        }
        return outcomes
    }

    /// Forgets the worktrees of the repository whose folders are gone (`git worktree prune`), then reads it again.
    /// Returns what went wrong, if something did.
    @discardableResult
    public func prune(repoPath: String) async -> RemovalError? {
        let (remover, repo) = (env.remover, URL(filePath: repoPath, directoryHint: .isDirectory))
        let error = await removalLock(for: repoPath).run { await Removal.prune(repo, with: remover) }
        await load([repoPath])
        saveCache()
        return error
    }

    private func removeOne(_ row: WorktreeRow, deleteBranch: Bool) async -> RemovalError? {
        let confirmedAs: RemovalConfirmation
        switch row.eligibility {
        case .ready: confirmedAs = .ready
        case .manual: confirmedAs = .manual
        // Nothing that could be removed was confirmed: nothing is stopped for it, and the remover is not asked.
        case .blocked: return .stateChanged(row.eligibility)
        // The remover refuses these at once, before it stops anything. `.ready` asks the most of a recheck.
        case .mainWorktree, .missing: confirmedAs = .ready
        }
        let request = RemovalRequest(
            repo: URL(filePath: row.repoPath, directoryHint: .isDirectory), worktree: row.worktree,
            deleteBranch: deleteBranch, stopGroups: row.groups, confirmedAs: confirmedAs)
        let repo = repositories[row.repoPath]
        let (reader, sampler, signaler, roots) = (reader, env.sampler, env.signaler, worktreeRoots)
        let (remote, kind) = (repo?.remote, repo?.kind)
        let recheck: @Sendable () async -> RemovalEligibility = {
            await reader.recheck(
                row.worktree, in: row.repoPath, remote: remote, kind: kind, roots: roots, sampler: sampler,
                signaler: signaler)
        }
        let remover = env.remover
        return await removalLock(for: row.repoPath).run {
            await Removal.remove(request, recheck: recheck, with: remover)
        }
    }

    /// The lock that keeps removals in one repository apart: git's own locks (`packed-refs.lock`, the `worktrees`
    /// folder) can fail a second one that runs beside the first.
    private func removalLock(for repo: String) -> Limiter {
        if let lock = removalLocks[repo] { return lock }
        let lock = Limiter(limit: 1)
        removalLocks[repo] = lock
        return lock
    }
}

/// Calls the remover away from the main actor, and turns whatever it throws into a `RemovalError`.
enum Removal {
    @concurrent
    static func remove(
        _ request: RemovalRequest, recheck: @escaping @Sendable () async -> RemovalEligibility,
        with remover: any WorktreeRemoving
    ) async -> RemovalError? {
        do {
            try await remover.remove(request, recheck: recheck)
            return nil
        } catch {
            return removalError(error)
        }
    }

    @concurrent
    static func prune(_ repo: URL, with remover: any WorktreeRemoving) async -> RemovalError? {
        do {
            try await remover.prune(repo: repo)
            return nil
        } catch {
            return removalError(error)
        }
    }

    /// A failure that is no `RemovalError` comes from running git, and is told as git failing.
    private static func removalError(_ error: any Error) -> RemovalError {
        switch error {
        case let error as RemovalError: error
        case CommandError.notFound(let tool): .gitRefused("\(tool) was not found")
        case CommandError.timedOut(let tool): .gitRefused("\(tool) did not finish in time")
        case is CancellationError: .gitRefused("The removal was given up before anything was deleted.")
        default: .gitRefused((error as? any LocalizedError)?.errorDescription ?? String(describing: error))
        }
    }
}
