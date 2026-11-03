import CoreModels
import Foundation
import GitKit
import Safety

/// One chip of the State column.
public struct StateChip: Equatable, Sendable {
    public let text: String
    /// Whether it names something that stands in the way of removing the worktree.
    public let warning: Bool

    public init(text: String, warning: Bool) {
        self.text = text
        self.warning = warning
    }
}

/// The words of the table and the inspector, made of what the rows hold.
public enum RowPresenter {
    /// The MR / PR column: `—` for none and for unknown.
    public static func reviewChip(_ r: ReviewInfo) -> String {
        switch r.state {
        case .open: "Open"
        case .draft: "Draft"
        case .merged: "Merged"
        case .closed: "Closed"
        case .none, .unknown: "—"
        }
    }

    /// The State column. A worktree that the policy blocks shows each reason; a main worktree, which the policy never
    /// weighs, shows what git says of it; the others are clean.
    public static func stateChips(_ row: WorktreeRow) -> [StateChip] {
        switch row.eligibility {
        case .missing:
            return [StateChip(text: "Missing", warning: true)]
        case .blocked(let reasons):
            return reasons.map { StateChip(text: text(of: $0), warning: true) }
        case .mainWorktree:
            guard let status = row.status else { return [StateChip(text: "Can't verify", warning: true)] }
            var chips: [StateChip] = []
            if status.modified > 0 { chips.append(StateChip(text: changes(status.modified), warning: true)) }
            if status.untracked > 0 { chips.append(StateChip(text: "\(status.untracked) untracked", warning: true)) }
            return chips.isEmpty ? [StateChip(text: "Clean", warning: false)] : chips
        case .ready, .manual:
            return [StateChip(text: "Clean", warning: false)]
        }
    }

    private static func text(of reason: UnsavedReason) -> String {
        switch reason {
        case .modified(let n): changes(n)
        case .untracked(let n): "\(n) untracked"
        case .stash(let n): n == 1 ? "stash" : "\(n) stashes"
        case .unpushed(let n): "\(n) unpushed"
        // The commits that came after the merge are on no remote branch that the merge holds.
        case .notOnRemote, .commitsAfterMerge: "Not on remote"
        case .lockedManually: "Locked"
        case .cantVerify, .statusUnavailable: "Can't verify"
        }
    }

    private static func changes(_ n: Int) -> String { n == 1 ? "1 change" : "\(n) changes" }

    /// The Changes line of the inspector: what the chips of the State column say, in one line.
    public static func changesLine(_ row: WorktreeRow) -> String {
        stateChips(row).map(\.text).joined(separator: ", ")
    }

    /// What runs in a worktree, for the Running column: the groups without the shells, the most memory first, the same
    /// name once with `×N`, then the memory of all the groups, shells included. `nil` when there is nothing but shells.
    public static func runningText(_ groups: [ProcessGroup]) -> String? {
        let shown = groups.filter { $0.kind != .shell }
            .sorted { ($1.totalFootprint, $0.leader.pid) < ($0.totalFootprint, $1.leader.pid) }
        guard !shown.isEmpty else { return nil }
        var order: [String] = []
        var counts: [String: Int] = [:]
        for group in shown {
            let name = label(of: group)
            if counts[name] == nil { order.append(name) }
            counts[name, default: 0] += 1
        }
        let names = order.map { counts[$0] == 1 ? $0 : "\($0) ×\(counts[$0] ?? 0)" }.joined(separator: ", ")
        return names + " · " + memory(of: groups)
    }

    /// The memory of all the groups, as the inspector and the table show it.
    public static func memory(of groups: [ProcessGroup]) -> String {
        let total = groups.reduce(UInt64(0)) { sum, group in
            let (next, overflow) = sum.addingReportingOverflow(group.totalFootprint)
            return overflow ? .max : next
        }
        return SizeFormat.memory(total)
    }

    private static func label(of group: ProcessGroup) -> String {
        guard group.kind == .agentSession else { return group.leader.name }
        if group.title.hasPrefix("Claude Code") { return "Claude" }
        if group.title.hasPrefix("Codex") { return "Codex" }
        return group.leader.name
    }

    /// The branch under the name of a worktree, with how far it is from its upstream: `main ↑2 ↓3`.
    public static func branchLine(_ s: WorktreeStatus?, branch: String?) -> String {
        var parts = [branch ?? "detached"]
        if let s {
            if s.ahead > 0 { parts.append("↑\(s.ahead)") }
            if s.behind > 0 { parts.append("↓\(s.behind)") }
        }
        return parts.joined(separator: " ")
    }

    /// Why removing a folder frees little, when it does: most of it is shared with other files. `nil` when private is
    /// a quarter or more of what is on disk.
    public static func diskNote(_ s: SizeInfo) -> String? {
        guard s.apparentBytes > 0, s.privateBytes >= 0, Double(s.privateBytes) < Double(s.apparentBytes) * 0.25
        else { return nil }
        return "Most of this folder is shared with other files (APFS clones), so removing it frees only "
            + SizeFormat.disk(s.privateBytes) + "."
    }

    // MARK: Removal

    /// Why a worktree was not removed, or not all the way, in a sentence. What git said, and what the remover found in
    /// the folder, is passed on as it is.
    public static func failureReason(_ error: RemovalError) -> String {
        switch error {
        // A fetch that fails makes the recheck answer this (Ruling 43).
        case .stateChanged(.blocked([.cantVerify])):
            "Could not reach the remote to confirm everything is pushed."
        case .stateChanged:
            "Something changed since you looked, so it was left alone."
        case .worktreeChanged:
            "The worktree changed since you looked, so it was left alone."
        case .processStillRunning(let pid):
            "A process (pid \(pid)) is still running, so it was left alone."
        case .branchNotDeleted(let message):
            "The folder is gone, but the branch was kept: " + message
        // A removal that was given up reaches the window as this too, with a sentence of the store's.
        case .gitRefused(let message), .hiddenWork(let message):
            message
        }
    }

    /// `<worktree name>: <reason>` for every outcome that failed, in order. `rows` are those that were to be removed.
    public static func failureLines(_ outcomes: [RemovalOutcome], rows: [WorktreeRow]) -> [String] {
        outcomes.compactMap { outcome in
            guard case .failed(let id, let error) = outcome else { return nil }
            let name = rows.first { $0.id == id }?.displayName ?? (id as NSString).lastPathComponent
            return name + ": " + failureReason(error)
        }
    }
}

/// The rows of the Ready to remove block that are on screen. Past `collapsedLimit` rows the block shows the first few and
/// a last row that expands it; the header and the `Remove N…` button still count every row (Ruling 66).
public struct ReadyListing: Equatable, Sendable {
    public static let collapsedLimit = 4

    /// Every row that is ready: what the header counts and what `Remove N…` acts on.
    public let all: [WorktreeRow]
    public let expanded: Bool
    /// `false` on the Ready to remove page, which lists every row; only the block on Projects is capped.
    public let capped: Bool

    public init(_ all: [WorktreeRow], expanded: Bool, capped: Bool = true) {
        self.all = all
        self.expanded = expanded
        self.capped = capped
    }

    public var total: Int { all.count }

    /// The rows that have a line of their own.
    public var shown: [WorktreeRow] { expanded || !capped ? all : Array(all.prefix(Self.collapsedLimit)) }

    /// The words of the last row: `Show all N` while some rows are hidden, `Show less` once all are shown; `nil` when
    /// there are no more rows than fit.
    public var toggleTitle: String? {
        guard capped, total > Self.collapsedLimit else { return nil }
        return expanded ? "Show less" : "Show all \(total)"
    }

    public var removeTitle: String { "Remove \(total)…" }
}

/// The filter above the table.
public enum ProjectFilter: String, CaseIterable, Sendable, Identifiable {
    case all = "All"
    case running = "Running"
    case needsAttention = "Needs attention"

    public var id: String { rawValue }

    /// Whether `row` passes: `Running` holds the rows that have a process group, `Needs attention` those that are
    /// blocked or whose folder is missing.
    public func admits(_ row: WorktreeRow) -> Bool {
        switch self {
        case .all: true
        case .running: !row.groups.isEmpty
        case .needsAttention:
            switch row.eligibility {
            case .blocked, .missing: true
            case .mainWorktree, .ready, .manual: false
            }
        }
    }

    /// The repositories that the table shows, with the worktrees that pass `filter` and match `query` (by the name of
    /// the repository, of the folder, or of the branch). A repository stays as the parent of a worktree that
    /// passes; a repository whose name matches keeps all the worktrees that pass the filter. `repoPath` limits it to
    /// one repository.
    public static func visible(
        _ projects: [ProjectRow], filter: ProjectFilter, query: String, repoPath: String? = nil
    ) -> [ProjectRow] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return projects.compactMap { project in
            if let repoPath, project.path != repoPath { return nil }
            let repoHit = needle.isEmpty || project.name.lowercased().contains(needle)
            let children = project.worktrees.filter { row in
                filter.admits(row) && (repoHit || Self.name(of: row, contains: needle))
            }
            guard (repoHit && filter.admits(project.main)) || !children.isEmpty else { return nil }
            return ProjectRow(path: project.path, name: project.name, main: project.main, worktrees: children)
        }
    }

    private static func name(of row: WorktreeRow, contains needle: String) -> Bool {
        row.displayName.lowercased().contains(needle) || (row.worktree.branch?.lowercased().contains(needle) == true)
    }
}

extension WorktreeRow {
    /// The name of the worktree's folder; the repository's name for the main worktree.
    public var displayName: String {
        worktree.isMain ? repoName : (worktree.path as NSString).lastPathComponent
    }
}
