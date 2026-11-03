import CoreModels
@testable import Dashboard
import Foundation
import Safety
import Testing

@Suite struct RowPresenterTests {
    @Test func reviewChips() {
        #expect(RowPresenter.reviewChip(ReviewInfo(state: .merged, number: 7)) == "Merged")
        #expect(RowPresenter.reviewChip(ReviewInfo(state: .open)) == "Open")
        #expect(RowPresenter.reviewChip(ReviewInfo(state: .draft)) == "Draft")
        #expect(RowPresenter.reviewChip(ReviewInfo(state: .closed)) == "Closed")
        #expect(RowPresenter.reviewChip(.none) == "—")
        #expect(RowPresenter.reviewChip(.unknown) == "—")
    }

    @Test func stateChipsFromReasons() {
        #expect(
            RowPresenter.stateChips(row(.blocked([.modified(11), .stash(1)])))
                == [StateChip(text: "11 changes", warning: true), StateChip(text: "stash", warning: true)])
        #expect(RowPresenter.stateChips(row(.ready(needsStopping: false))) == [StateChip(text: "Clean", warning: false)])
        #expect(RowPresenter.stateChips(row(.missing)) == [StateChip(text: "Missing", warning: true)])
        #expect(RowPresenter.stateChips(row(.blocked([.cantVerify]))) == [StateChip(text: "Can't verify", warning: true)])
    }

    @Test func everyReasonHasItsOwnWording() {
        let reasons: [UnsavedReason] = [
            .modified(2), .untracked(3), .stash(4), .unpushed(5), .notOnRemote(6), .lockedManually, .statusUnavailable,
        ]
        #expect(
            RowPresenter.stateChips(row(.blocked(reasons))).map(\.text) == [
                "2 changes", "3 untracked", "4 stashes", "5 unpushed", "Not on remote", "Locked", "Can't verify",
            ])
    }

    @Test func countsAreSingularAtOne() {
        #expect(
            RowPresenter.stateChips(row(.blocked([.modified(1), .untracked(1), .stash(1), .unpushed(1)]))).map(\.text)
                == ["1 change", "1 untracked", "stash", "1 unpushed"])
        #expect(
            RowPresenter.stateChips(row(.blocked([.modified(2), .stash(2)]))).map(\.text) == ["2 changes", "2 stashes"])
        #expect(RowPresenter.stateChips(row(.mainWorktree, status: WorktreeStatus(modified: 1))).map(\.text) == ["1 change"])
    }

    @Test func theChangesLineSaysWhatTheChipsSay() {
        #expect(RowPresenter.changesLine(row(.ready(needsStopping: false))) == "Clean")
        #expect(RowPresenter.changesLine(row(.blocked([.stash(1)]))) == "stash")
        #expect(RowPresenter.changesLine(row(.blocked([.modified(1), .untracked(4)]))) == "1 change, 4 untracked")
        #expect(RowPresenter.changesLine(row(.missing)) == "Missing")
    }

    @Test func aMainWorktreeShowsWhatGitSays() {
        let dirty = WorktreeStatus(modified: 2, untracked: 1)
        #expect(
            RowPresenter.stateChips(row(.mainWorktree, status: dirty)).map(\.text) == ["2 changes", "1 untracked"])
        #expect(RowPresenter.stateChips(row(.mainWorktree, status: WorktreeStatus())).map(\.text) == ["Clean"])
    }

    @Test func runningText() {
        #expect(RowPresenter.runningText([claudeGroup(footprint: 404_750_336)]) == "Claude · 386 MB")
        #expect(
            RowPresenter.runningText([
                claudeGroup(footprint: 314 << 20), claudeGroup(footprint: 210 << 20),
                builtHere("Minuta", footprint: 11 << 20), shell(footprint: 99 << 20),
            ]) == "Claude ×2, Minuta · 634 MB")
        #expect(RowPresenter.runningText([shell(footprint: 3 << 20)]) == nil)
        #expect(RowPresenter.runningText([]) == nil)
    }

    @Test func runningTextOrdersByMemoryAndNamesCodex() {
        #expect(
            RowPresenter.runningText([
                builtHere("api", footprint: 10 << 20), codexGroup(footprint: 50 << 20),
                builtHere("api", footprint: 20 << 20),
            ]) == "Codex, api ×2 · 80 MB")
    }

    @Test func branchLine() {
        #expect(RowPresenter.branchLine(status(ahead: 0, behind: 30), branch: "main") == "main ↓30")
        #expect(RowPresenter.branchLine(status(ahead: 69, behind: 0), branch: "main") == "main ↑69")
        #expect(RowPresenter.branchLine(status(ahead: 2, behind: 3), branch: "main") == "main ↑2 ↓3")
        #expect(RowPresenter.branchLine(status(ahead: 0, behind: 0), branch: "main") == "main")
        #expect(RowPresenter.branchLine(nil, branch: "main") == "main")
    }

    @Test func diskNoteOnlyWhenMostlyShared() {
        #expect(
            RowPresenter.diskNote(SizeInfo(apparentBytes: 3_100_000_000, privateBytes: 300_000_000, computedAt: .now))
                == "Most of this folder is shared with other files (APFS clones), so removing it frees only 0.3 GB.")
        #expect(
            RowPresenter.diskNote(SizeInfo(apparentBytes: 1_000_000_000, privateBytes: 900_000_000, computedAt: .now))
                == nil)
        #expect(
            RowPresenter.diskNote(SizeInfo(apparentBytes: 1_000_000_000, privateBytes: 250_000_000, computedAt: .now))
                == nil)
    }
}

@Suite struct ProjectFilterTests {
    @Test func filtersKeepTheParentOfWhatPasses() {
        let projects = [
            project("api", main: .mainWorktree, children: [
                ("api-a", .ready(needsStopping: false), []), ("api-b", .blocked([.modified(1)]), []),
            ]),
            project("web", main: .mainWorktree, children: [("web-a", .manual(needsStopping: true), [runningGroup()])]),
        ]
        let attention = ProjectFilter.visible(projects, filter: .needsAttention, query: "")
        #expect(attention.map(\.name) == ["api"])
        #expect(attention[0].worktrees.map(\.displayName) == ["api-b"])
        let running = ProjectFilter.visible(projects, filter: .running, query: "")
        #expect(running.map(\.name) == ["web"])
        #expect(ProjectFilter.visible(projects, filter: .all, query: "").count == 2)
    }

    @Test func missingCountsAsNeedingAttention() {
        let projects = [project("api", main: .mainWorktree, children: [("gone", .missing, [])])]
        #expect(ProjectFilter.visible(projects, filter: .needsAttention, query: "")[0].worktrees.count == 1)
    }

    @Test func searchMatchesRepositoryFolderAndBranch() {
        let projects = [
            project("api", main: .mainWorktree, children: [("one", .ready(needsStopping: false), []), ("two", .manual(needsStopping: false), [])]),
            project("web", main: .mainWorktree, children: [("three", .manual(needsStopping: false), [])]),
        ]
        // The repository's name keeps all its worktrees.
        #expect(ProjectFilter.visible(projects, filter: .all, query: "API")[0].worktrees.count == 2)
        // A folder's name keeps its repository as the parent, and only that worktree.
        let byFolder = ProjectFilter.visible(projects, filter: .all, query: "thr")
        #expect(byFolder.map(\.name) == ["web"])
        #expect(byFolder[0].worktrees.map(\.displayName) == ["three"])
        // So does the branch's name ("x" is the branch of every fixture worktree).
        #expect(ProjectFilter.visible(projects, filter: .all, query: "x").count == 2)
        #expect(ProjectFilter.visible(projects, filter: .all, query: "nothing").isEmpty)
    }

    @Test func oneRepositoryOnly() {
        let projects = [project("api", main: .mainWorktree, children: []), project("web", main: .mainWorktree, children: [])]
        #expect(ProjectFilter.visible(projects, filter: .all, query: "", repoPath: "/web").map(\.name) == ["web"])
    }
}

private func runningGroup() -> ProcessGroup { shell(footprint: 1 << 20) }

private func project(
    _ name: String, main: RemovalEligibility, children: [(String, RemovalEligibility, [ProcessGroup])]
) -> ProjectRow {
    let mainRow = WorktreeRow(
        repoPath: "/" + name, repoName: name, worktree: Worktree(path: "/" + name, branch: "main", isMain: true),
        status: nil, review: .none, hosting: nil, groups: [], size: nil, eligibility: main)
    let rows = children.map { folder, eligibility, groups in
        WorktreeRow(
            repoPath: "/" + name, repoName: name, worktree: Worktree(path: "/wt/" + folder, branch: "x"), status: nil,
            review: .none, hosting: nil, groups: groups, size: nil, eligibility: eligibility)
    }
    return ProjectRow(path: "/" + name, name: name, main: mainRow, worktrees: rows)
}

private func status(ahead: Int, behind: Int) -> WorktreeStatus {
    WorktreeStatus(upstream: "origin/main", ahead: ahead, behind: behind)
}

private func row(_ eligibility: RemovalEligibility, status: WorktreeStatus? = nil) -> WorktreeRow {
    WorktreeRow(
        repoPath: "/r", repoName: "r", worktree: Worktree(path: "/r/w", branch: "x"), status: status, review: .none,
        hosting: nil, groups: [], size: nil, eligibility: eligibility)
}

private func group(_ kind: ProcessKind, _ title: String, name: String, footprint: UInt64) -> ProcessGroup {
    let leader = ProcessRecord(
        pid: 1, ppid: 1, name: name, executablePath: nil, arguments: [], cwd: "/r/w", footprintBytes: footprint,
        startDate: Date(timeIntervalSince1970: 0), listeningPorts: [])
    return ProcessGroup(kind: kind, title: title, leader: leader, members: [])
}

private func claudeGroup(footprint: UInt64) -> ProcessGroup {
    group(.agentSession, "Claude Code · CLI, 2 MCP servers", name: "claude", footprint: footprint)
}

private func codexGroup(footprint: UInt64) -> ProcessGroup {
    group(.agentSession, "Codex CLI", name: "codex", footprint: footprint)
}

private func builtHere(_ name: String, footprint: UInt64) -> ProcessGroup {
    group(.builtHere, name, name: name, footprint: footprint)
}

private func shell(footprint: UInt64) -> ProcessGroup {
    group(.shell, "zsh", name: "zsh", footprint: footprint)
}
