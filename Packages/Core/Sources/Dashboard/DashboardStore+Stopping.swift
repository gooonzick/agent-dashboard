import CoreModels
import Foundation
import ProcessKit

/// Why the processes that the user asked to stop are not all gone.
public enum StopFailure: Error, Equatable, Sendable {
    /// The process with this id still runs: it did not die of `SIGKILL`. The others may be gone.
    case stillRunning(Int32)
    /// The worktree is being removed, and the removal stops what runs in it: nothing was signalled.
    case removalUnderWay
}

extension DashboardStore {
    /// Stops the processes of `groups`, which run in the worktree of `row`, as the removal stops them
    /// (`ProcessStopper`): bottom-up, `SIGTERM`, a few seconds, then `SIGKILL` for what is still there, and only what
    /// is still the process that was sampled. Then the processes are sampled again, so that the rows show at once what
    /// is left. Says what went wrong, if something did.
    ///
    /// While it runs, the leaders of `groups` are in `stopping`. A group that is in it already is left out, and nothing
    /// is stopped in a worktree that `remove(_:deleteBranches:)` is removing: `.removalUnderWay`. The app and what it
    /// started are never in a group (Ruling 40), and the stopper never signals the app.
    public func stop(_ groups: [ProcessGroup], of row: WorktreeRow) async -> StopFailure? {
        guard !removingWorktrees.contains(row.id) else { return .removalUnderWay }
        let groups = groups.filter { !stopping.contains($0.id) }
        guard !groups.isEmpty else { return nil }
        let leaders = Set(groups.map(\.id))
        stopping.formUnion(leaders)
        let stopper = ProcessStopper(signaler: env.signaler, sampler: env.sampler, stopTimeout: env.stopTimeout)
        let failure = await Stopping.stop(groups, with: stopper)
        // The rows lose what is gone before the buttons come back: a button of a group that is gone stops nothing.
        await sampleProcesses()
        stopping.subtract(leaders)
        return failure
    }
}

/// Calls the stopper away from the main actor, for it samples the processes, and turns what it throws into a
/// `StopFailure`.
enum Stopping {
    @concurrent
    static func stop(_ groups: [ProcessGroup], with stopper: ProcessStopper) async -> StopFailure? {
        do {
            try await stopper.stop(groups)
            return nil
        } catch ProcessStopError.stillRunning(let pid) {
            return .stillRunning(pid)
        } catch {
            // Only a task that was cancelled ends otherwise. The window does not cancel one, and what was signalled
            // stays signalled: the sample that follows shows what is left.
            return nil
        }
    }
}
