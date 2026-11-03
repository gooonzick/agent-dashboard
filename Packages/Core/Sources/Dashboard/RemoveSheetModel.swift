import CoreModels
import Foundation
import Hosting
import Safety

/// The words of the sheet that confirms a removal, made of the rows that are to go.
///
/// The rows are those that the user asked to remove, as they were then: `.ready` or `.manual` (`isRemovable`). The
/// text of the Copy holds for rows that are all `.ready`; one `.manual` row among them changes it to say that a request
/// is not merged, and takes away "Don't ask again" (Ruling 58). Every process that is stopped first is named, each
/// member of each group, and not just the group (Ruling 39).
public struct RemoveSheetModel: Equatable {
    /// One worktree that goes, with what removing it frees.
    public struct Item: Equatable, Identifiable {
        /// The path of the worktree.
        public let id: String
        public let name: String
        /// What removing it frees, `—` until it has been measured.
        public let size: String
    }

    /// `Remove 3 worktrees?`
    public let title: String
    /// What the sheet says of the worktrees: that nothing will be lost, or that a request is not merged.
    public let message: String
    public let items: [Item]
    /// Whether something runs in one of the worktrees, as their eligibility says: a group of processes, or the live
    /// owner of a lock, which no group may hold.
    public let needsStopping: Bool
    /// `name · pid N` for every process that is stopped first, each once, in the order of the rows and their groups.
    public let processesToStop: [String]
    /// Whether any process is stopped first: the section that names them is shown, and the button says so.
    public var stopsProcesses: Bool { !processesToStop.isEmpty }
    /// Whether "Don't ask again for merged, pushed worktrees" is offered: only when every row is `.ready`.
    public let offersDontAskAgain: Bool
    /// `Frees 0.8 GB`: what the worktrees that have been measured free. Empty when none of them has been.
    public let totalFrees: String
    /// `Remove 3 worktrees`, or `Stop and remove 3 worktrees` when a process is stopped first.
    public let removeButtonTitle: String

    public init(rows: [WorktreeRow]) {
        let count = rows.count == 1 ? "1 worktree" : "\(rows.count) worktrees"
        title = "Remove \(count)?"
        items = rows.map { Item(id: $0.id, name: $0.displayName, size: $0.size.map { SizeFormat.disk($0.privateBytes) } ?? "—") }

        let manual = rows.filter { if case .manual = $0.eligibility { true } else { false } }
        if manual.isEmpty {
            message = "Their MRs are merged and everything is pushed, so no work will be lost."
        } else {
            message = "Everything is pushed and nothing is unsaved, but the \(Self.reviewNoun(of: manual)) is not merged."
        }
        offersDontAskAgain = manual.isEmpty && !rows.isEmpty

        needsStopping = rows.contains {
            switch $0.eligibility {
            case .ready(let stop), .manual(let stop): stop
            case .mainWorktree, .missing, .blocked: false
            }
        }
        var seen = Set<Int32>()
        processesToStop = rows.flatMap(\.groups).flatMap { [$0.leader] + $0.members }
            .filter { seen.insert($0.pid).inserted }
            .map { "\($0.name) · pid \($0.pid)" }

        let measured = rows.compactMap(\.size)
        totalFrees = measured.isEmpty ? "" : "Frees " + SizeFormat.disk(measured.reduce(0) { $0 + $1.privateBytes })
        removeButtonTitle = (processesToStop.isEmpty ? "Remove " : "Stop and remove ") + count
    }

    /// Whether the per-row Remove button removes `rows` without the sheet: only when the user has said "Don't ask
    /// again", and only for one row that is `.ready` with nothing running. `Remove N…`, `Stop and remove…`, `Remove…`
    /// and the inspector always show the sheet (`fromRowButton` is `false` for them).
    public static func skipsSheet(for rows: [WorktreeRow], fromRowButton: Bool, skipSetting: Bool) -> Bool {
        guard fromRowButton, skipSetting, rows.count == 1, let row = rows.first else { return false }
        return row.eligibility == .ready(needsStopping: false)
    }

    /// `PR` on GitHub, `MR` on GitLab, `MR/PR` for both or for a host that is not known.
    private static func reviewNoun(of rows: [WorktreeRow]) -> String {
        switch Set(rows.map(\.hosting)) {
        case [.github]: "PR"
        case [.gitlab]: "MR"
        default: "MR/PR"
        }
    }
}

extension WorktreeRow {
    /// Whether the app offers to remove it: `.ready` or `.manual`. Never the main worktree, one whose folder is gone
    /// (that is for Prune), or one that holds unsaved work.
    public var isRemovable: Bool {
        switch eligibility {
        case .ready, .manual: true
        case .mainWorktree, .missing, .blocked: false
        }
    }
}
