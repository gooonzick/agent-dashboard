import Testing

@testable import AppShell

/// When the window offers its commands to the menu. These open no window.
@Suite struct WindowCommandsTests {
    @Test func removeIsOfferedForARemovableSelectionAlone() {
        #expect(WindowCommands.offersRemove(selectionIsRemovable: true, searchIsFocused: false, sheetIsOpen: false))
        #expect(!WindowCommands.offersRemove(selectionIsRemovable: false, searchIsFocused: false, sheetIsOpen: false))
    }

    @Test func removeIsNotOfferedWhileTheSearchFieldHasTheKeys() {
        // ⌘⌫ there deletes to the start of the line, and the menu would take it first.
        #expect(!WindowCommands.offersRemove(selectionIsRemovable: true, searchIsFocused: true, sheetIsOpen: false))
    }

    @Test func removeIsNotOfferedOnTheProcessesPage() {
        // A line of a process selects its worktree; ⌘⌫ there would open the removal of the worktree.
        #expect(
            !WindowCommands.offersRemove(
                selectionIsRemovable: true, searchIsFocused: false, sheetIsOpen: false, onProcesses: true))
    }

    @Test func nothingThatChangesTheRowsIsOfferedWhileTheSheetIsOpen() {
        #expect(!WindowCommands.offersRemove(selectionIsRemovable: true, searchIsFocused: false, sheetIsOpen: true))
        #expect(!WindowCommands.offersRefresh(isBusy: false, isScanning: false, sheetIsOpen: true))
    }

    @Test func refreshIsOfferedWhenNothingRuns() {
        #expect(WindowCommands.offersRefresh(isBusy: false, isScanning: false, sheetIsOpen: false))
        #expect(!WindowCommands.offersRefresh(isBusy: true, isScanning: false, sheetIsOpen: false))
        #expect(!WindowCommands.offersRefresh(isBusy: false, isScanning: true, sheetIsOpen: false))
    }
}
