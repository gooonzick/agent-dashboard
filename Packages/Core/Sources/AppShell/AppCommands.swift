import SwiftUI

/// The menu commands of the window: Refresh ⌘R, Fetch All ⇧⌘R, Remove… ⌘⌫, Projects ⌘1, Ready to remove ⌘2.
///
/// They act on the window that is in front, through what it publishes (`WindowCommands`). With no window, or while
/// the window cannot do what a command asks, the command is off.
public struct AppCommands: Commands {
    @FocusedValue(\.windowCommands) private var window

    public init() {}

    public var body: some Commands {
        CommandGroup(after: .newItem) {
            Button("Remove…") { window?.removeSelection?() }
                .keyboardShortcut(.delete, modifiers: .command)
                .disabled(window?.removeSelection == nil)
        }
        CommandGroup(before: .toolbar) {
            Button("Refresh") { window?.refresh?() }
                .keyboardShortcut("r", modifiers: .command)
                .disabled(window?.refresh == nil)
            Button("Fetch All") { window?.fetchAll?() }
                .keyboardShortcut("r", modifiers: [.command, .shift])
                .disabled(window?.fetchAll == nil)
            Divider()
            Button("Projects") { window?.showProjects() }
                .keyboardShortcut("1", modifiers: .command)
                .disabled(window == nil)
            Button("Ready to remove") { window?.showReadyToRemove() }
                .keyboardShortcut("2", modifiers: .command)
                .disabled(window == nil)
            Divider()
        }
    }
}

/// What the window offers the menu. A command that is `nil` is off: Refresh and Fetch All while a scan, a refresh or
/// a fetch runs, as their toolbar buttons are; Remove… when the selected row cannot be removed.
struct WindowCommands {
    var refresh: (() -> Void)?
    var fetchAll: (() -> Void)?
    /// Opens the removal sheet for the selected row. Always the sheet, whatever "Don't ask again" says.
    var removeSelection: (() -> Void)?
    var showProjects: () -> Void
    var showReadyToRemove: () -> Void

    /// Whether Remove… is offered: the selected row can be removed, the search field does not have the keys (⌘⌫ there
    /// deletes to the start of the line, and the menu sees the key first), no sheet is open (it would swap the rows of
    /// the sheet under the user), and the page is not Processes, where a line of a process selects its worktree and
    /// ⌘⌫ is not meant for that, nor Caches and Docker, which shows no worktree and deletes only through its own sheet.
    static func offersRemove(
        selectionIsRemovable: Bool, searchIsFocused: Bool, sheetIsOpen: Bool, onProcesses: Bool = false,
        onCaches: Bool = false
    ) -> Bool {
        selectionIsRemovable && !searchIsFocused && !sheetIsOpen && !onProcesses && !onCaches
    }

    /// Whether Refresh and Fetch All are offered: as their toolbar buttons are, and not while a sheet is open.
    static func offersRefresh(isBusy: Bool, isScanning: Bool, sheetIsOpen: Bool) -> Bool {
        !isBusy && !isScanning && !sheetIsOpen
    }
}

extension FocusedValues {
    @Entry var windowCommands: WindowCommands?
}
