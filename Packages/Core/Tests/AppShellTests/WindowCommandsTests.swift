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

    @Test func removeIsNotOfferedOnTheCachesPage() {
        // The page shows no worktree; what it deletes goes through its own sheet.
        #expect(
            !WindowCommands.offersRemove(
                selectionIsRemovable: true, searchIsFocused: false, sheetIsOpen: false, onCaches: true))
    }

    @Test func theCachesPageInspectsNoWorktree() {
        // A worktree selected on Projects must not bring its Remove and Stop to Caches and Docker (Ruling 13).
        #expect(!SidebarItem.caches.showsWorktrees)
        #expect(SidebarItem.projects.showsWorktrees)
        #expect(SidebarItem.readyToRemove.showsWorktrees)
        #expect(SidebarItem.processes.showsWorktrees)
        #expect(SidebarItem.repository("/Users/me/Development/dashboard").showsWorktrees)
    }

    @Test func theCachesPageHasNoInspectorColumnAndKeepsTheSetting() {
        #expect(!SidebarItem.showsInspector(true, on: .caches))
        #expect(SidebarItem.showsInspector(true, on: .projects))
        #expect(SidebarItem.showsInspector(true, on: .processes))
        #expect(SidebarItem.showsInspector(true, on: nil))
        #expect(!SidebarItem.showsInspector(false, on: .projects))
        // Closed or opened on Caches, the setting the other pages use is what it was.
        #expect(SidebarItem.inspectorSetting(true, shown: false, on: .caches))
        #expect(!SidebarItem.inspectorSetting(false, shown: true, on: .caches))
        #expect(!SidebarItem.inspectorSetting(true, shown: false, on: .projects))
        #expect(SidebarItem.inspectorSetting(false, shown: true, on: .readyToRemove))
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
