import CoreModels
@testable import Dashboard
import Foundation
import Testing

/// The words of the dialog that asks before processes are stopped, and of the alert when they do not all go.
@Suite struct StopConfirmationTests {
    private let helper = process(600, name: "disclaimer", cwd: "/r/PYMEP-12")
    private let claude = process(601, parent: 600, name: "claude", cwd: "/r/PYMEP-12")
    private let mcp = process(610, parent: 601, name: "node", cwd: "/r/PYMEP-12")
    private let vite = process(700, name: "node", cwd: "/r/PYMEP-12")

    private var session: ProcessGroup {
        ProcessGroup(
            kind: .agentSession, title: "Claude Code · desktop, 1 MCP server", leader: claude, members: [helper, mcp])
    }

    private var server: ProcessGroup {
        ProcessGroup(kind: .devServer, title: "vite", leader: vite, members: [])
    }

    @Test func oneGroupIsNamedByItsTitleAndEveryProcessOfItIsListed() {
        let ask = StopConfirmation([session], of: worktree(running: [session, server]))

        #expect(ask.title == "Stop Claude Code · desktop, 1 MCP server?")
        // The title names a session, and the helper that started it goes too (Ruling 39): in the order of the stop.
        #expect(ask.processes == ["node · pid 610", "claude · pid 601", "disclaimer · pid 600"])
        #expect(
            ask.message
                == "node · pid 610\nclaude · pid 601\ndisclaimer · pid 600\n\nUnsaved work in these processes is lost.")
        #expect(ask.confirmTitle == "Stop 3 processes")
    }

    @Test func everythingInAWorktreeIsNamedByTheWorktree() {
        let row = worktree(running: [session, server])

        let ask = StopConfirmation(row.groups, of: row)

        #expect(ask.title == "Stop everything running in PYMEP-12?")
        #expect(ask.processes == ["node · pid 610", "claude · pid 601", "disclaimer · pid 600", "node · pid 700"])
        #expect(ask.confirmTitle == "Stop 4 processes")
    }

    @Test func aProcessThatTwoGroupsListIsNamedOnce() {
        let again = ProcessGroup(kind: .other, title: "node", leader: mcp, members: [])

        let ask = StopConfirmation([session, again], of: worktree(running: [session, again]))

        #expect(ask.processes == ["node · pid 610", "claude · pid 601", "disclaimer · pid 600"])
    }

    @Test func oneProcessIsJustStopped() {
        let ask = StopConfirmation([server], of: worktree(running: [server]))

        #expect(ask.title == "Stop vite?")
        #expect(ask.processes == ["node · pid 700"])
        #expect(ask.confirmTitle == "Stop")
    }

    @Test func theMainWorktreeIsNamedByItsRepository() {
        let main = WorktreeRow(
            repoPath: "/r/api", repoName: "api", worktree: Worktree(path: "/r/api", branch: "main", isMain: true),
            status: nil, review: .none, hosting: nil, groups: [session, server], size: nil, eligibility: .mainWorktree)

        #expect(StopConfirmation(main.groups, of: main).title == "Stop everything running in api?")
    }

    @Test func theFailureNamesTheProcessThatSurvived() {
        #expect(RowPresenter.stopFailureTitle == "Some processes are still running")
        #expect(
            RowPresenter.stopFailureMessage(.stillRunning(600), groups: [server, session]) == "disclaimer · pid 600")
        // One that none of the groups had is named by its id alone.
        #expect(RowPresenter.stopFailureMessage(.stillRunning(4242), groups: [server]) == "pid 4242")
        #expect(
            RowPresenter.stopFailureMessage(.removalUnderWay, groups: [server])
                == "The worktree is being removed, which stops them.")
    }

    @Test func theStopButtonIsLabelledWithTheGroup() {
        #expect(RowPresenter.stopLabel(server) == "Stop vite")
    }

    private func worktree(running groups: [ProcessGroup]) -> WorktreeRow {
        WorktreeRow(
            repoPath: "/r/api", repoName: "api", worktree: Worktree(path: "/r/PYMEP-12", branch: "PYMEP-12"),
            status: nil, review: .none, hosting: nil, groups: groups, size: nil,
            eligibility: .manual(needsStopping: true))
    }
}
