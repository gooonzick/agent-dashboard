import CoreModels
import Foundation
import ProcessKit

/// The words of the dialog that asks before processes are stopped, and what it stops: one group (its Stop button in
/// the inspector), or all that run in a worktree (Stop All, and Stop Processes… of the context menu).
///
/// Every process that is stopped is named, each member of each group, and not just the group: a title can name another
/// process than the leader (Ruling 39). The groups are those that the row showed when the user asked, and they are what
/// is stopped if the user confirms: the stopper looks at each process again before it signals it.
public struct StopConfirmation: Equatable, Identifiable, Sendable {
    public let id = UUID()
    /// The worktree that the groups run in.
    public let row: WorktreeRow
    public let groups: [ProcessGroup]
    /// `Stop Claude Code · CLI?` for one group, `Stop everything running in PYMEP-12?` for more.
    public let title: String
    /// `name · pid N` for every process that is stopped, each once, in the order in which they are stopped.
    public let processes: [String]
    /// `Stop` for one process, `Stop 4 processes` for more.
    public let confirmTitle: String

    public init(_ groups: [ProcessGroup], of row: WorktreeRow) {
        self.row = row
        self.groups = groups
        if groups.count == 1, let group = groups.first {
            title = "Stop \(group.title)?"
        } else {
            title = "Stop everything running in \(row.displayName)?"
        }
        var seen = Set<Int32>()
        processes = ProcessStopper.stopOrder(of: groups).filter { seen.insert($0.pid).inserted }
            .map(RowPresenter.processLine)
        confirmTitle = processes.count == 1 ? "Stop" : "Stop \(processes.count) processes"
    }

    /// What the dialog says under its title: the processes, one a line, and what stopping them costs.
    public var message: String {
        (processes + ["", "Unsaved work in these processes is lost."]).joined(separator: "\n")
    }
}
