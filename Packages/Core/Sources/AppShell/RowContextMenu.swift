import AppKit
import CoreModels
import Dashboard
import Hosting
import SwiftUI

/// What the window does with rows, for the buttons and the menus that offer it. The renders get `.inert`.
struct RowActions {
    /// The worktrees whose removal is under way: they are offered nothing more until it is through.
    var removing: Set<String> = []
    /// Asks to remove `rows`: the sheet, or straight away for the per-row Remove of a worktree that is ready with
    /// nothing running, once the user has said "Don't ask again". `fromRowButton` is `true` only for that button.
    var remove: @MainActor (_ rows: [WorktreeRow], _ fromRowButton: Bool) -> Void = { _, _ in }
    /// Forgets the worktrees of the row's repository whose folders are gone.
    var prune: @MainActor (_ row: WorktreeRow) -> Void = { _ in }
    var hide: @MainActor (_ repoPath: String) -> Void = { _ in }
    /// The groups whose stop is under way, by the pid of their leader (`DashboardStore.stopping`).
    var stopping: Set<Int32> = []
    /// Asks to stop `groups`, which run in the worktree of `row`: always the dialog first.
    var stop: @MainActor (_ groups: [ProcessGroup], _ row: WorktreeRow) -> Void = { _, _ in }

    static var inert: RowActions { RowActions() }

    /// Whether `row` may be offered for removal now: it is `.ready` or `.manual`, and not already on its way.
    func canRemove(_ row: WorktreeRow) -> Bool {
        row.isRemovable && !removing.contains(row.id)
    }

    /// Whether `group`, which runs in the worktree of `row`, may be offered a stop now: it is not being stopped, and
    /// the worktree is not being removed, which stops it anyway.
    func canStop(_ group: ProcessGroup, of row: WorktreeRow) -> Bool {
        !stopping.contains(group.id) && !removing.contains(row.id)
    }
}

/// The context menu of a row, in the table and in the block of what is ready to remove.
struct RowContextMenu: View {
    let row: WorktreeRow
    let actions: RowActions

    var body: some View {
        if row.eligibility == .missing {
            Button("Prune") { actions.prune(row) }
        } else {
            Button("Remove…") { actions.remove([row], false) }
                .disabled(!actions.canRemove(row))
        }
        // The main worktree too: what runs in it is the user's to stop, though the worktree is never removed.
        if !row.groups.isEmpty {
            Button("Stop Processes…") { actions.stop(row.groups, row) }
                .disabled(!row.groups.contains { actions.canStop($0, of: row) })
        }
        Divider()
        Button("Reveal in Finder") { WorktreeOpener.revealInFinder(row) }
            .disabled(row.eligibility == .missing)
        Button("Open in Terminal") { WorktreeOpener.openInTerminal(row) }
            .disabled(row.eligibility == .missing)
        if let url = row.review.webURL {
            Button(WorktreeOpener.openReviewTitle(row)) { NSWorkspace.shared.open(url) }
        }
        Button("Copy Path") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(row.worktree.path, forType: .string)
        }
        Divider()
        Button("Hide Repository") { actions.hide(row.repoPath) }
    }
}

/// Opens a worktree elsewhere: in Finder, in Terminal, or its request in the browser.
enum WorktreeOpener {
    @MainActor static func revealInFinder(_ row: WorktreeRow) {
        NSWorkspace.shared.activateFileViewerSelecting([URL(filePath: row.worktree.path)])
    }

    @MainActor static func openInTerminal(_ row: WorktreeRow) {
        guard let terminal = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Terminal") else {
            return
        }
        NSWorkspace.shared.open(
            [URL(filePath: row.worktree.path)], withApplicationAt: terminal,
            configuration: NSWorkspace.OpenConfiguration())
    }

    /// `Open PR` on GitHub, `Open MR` everywhere else.
    static func openReviewTitle(_ row: WorktreeRow) -> String {
        row.hosting == .github ? "Open PR" : "Open MR"
    }
}
