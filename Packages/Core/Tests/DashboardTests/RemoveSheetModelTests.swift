import CoreModels
import Dashboard
import Foundation
import Hosting
import Safety
import Testing

@Suite struct RemoveSheetModelTests {
    @Test func titlesAndTotal() {
        let m = RemoveSheetModel(rows: [
            ready(private: 200_000_000), ready(private: 300_000_000), ready(private: 300_000_000),
        ])
        #expect(m.title == "Remove 3 worktrees?" && m.removeButtonTitle == "Remove 3 worktrees" && m.totalFrees == "Frees 0.8 GB")
    }

    @Test func singular() { #expect(RemoveSheetModel(rows: [ready(private: 0)]).title == "Remove 1 worktree?") }

    @Test func needsStoppingWhenAnyRowRuns() {
        #expect(RemoveSheetModel(rows: [ready(private: 0, needsStopping: true)]).needsStopping)
    }

    // MARK: The text of the sheet

    @Test func readyRowsGetTheTextOfTheCopy() {
        let m = RemoveSheetModel(rows: [ready(private: 0), ready(private: 0)])
        #expect(m.message == "Their MRs are merged and everything is pushed, so no work will be lost.")
        #expect(m.offersDontAskAgain)
        #expect(!m.needsStopping)
        #expect(m.processesToStop.isEmpty)
        #expect(m.removeButtonTitle == "Remove 2 worktrees")
    }

    @Test func aManualRowSaysTheRequestIsNotMergedAndNeverOffersToSkipTheSheet() {
        let gitlab = RemoveSheetModel(rows: [ready(private: 0), manual(hosting: .gitlab)])
        #expect(gitlab.message == "Everything is pushed and nothing is unsaved, but the MR is not merged.")
        #expect(!gitlab.offersDontAskAgain)

        #expect(
            RemoveSheetModel(rows: [manual(hosting: .github)]).message
                == "Everything is pushed and nothing is unsaved, but the PR is not merged.")
        #expect(
            RemoveSheetModel(rows: [manual(hosting: .github), manual(hosting: .gitlab)]).message
                == "Everything is pushed and nothing is unsaved, but the MR/PR is not merged.")
        #expect(
            RemoveSheetModel(rows: [manual(hosting: nil)]).message
                == "Everything is pushed and nothing is unsaved, but the MR/PR is not merged.")
    }

    @Test func stoppingNamesEveryProcessAndTheButtonSaysSo() {
        let session = group(leader: record(501, "claude"), members: [record(502, "node"), record(503, "uv")])
        let tmux = group(leader: record(600, "zsh"), members: [record(601, "tmux")])
        let m = RemoveSheetModel(rows: [
            ready(private: 0, groups: [session]), manual(hosting: .gitlab, groups: [tmux]),
            ready(private: 0),
        ])

        #expect(m.needsStopping)
        #expect(m.removeButtonTitle == "Stop and remove 3 worktrees")
        #expect(
            m.processesToStop == ["claude · pid 501", "node · pid 502", "uv · pid 503", "zsh · pid 600", "tmux · pid 601"])
        #expect(
            RemoveSheetModel(rows: [ready(private: 0, groups: [tmux])]).removeButtonTitle
                == "Stop and remove 1 worktree")
    }

    @Test func aProcessListedTwiceIsNamedOnce() {
        let leader = record(501, "claude")
        let m = RemoveSheetModel(rows: [ready(private: 0, groups: [group(leader: leader, members: [leader])])])
        #expect(m.processesToStop == ["claude · pid 501"])
    }

    @Test func eachRowWithWhatItFrees() {
        let m = RemoveSheetModel(rows: [ready(private: 300_000_000, name: "one"), unmeasured(name: "two")])
        #expect(m.items.map(\.name) == ["one", "two"])
        #expect(m.items.map(\.size) == ["0.3 GB", "—"])
        #expect(m.totalFrees == "Frees 0.3 GB")  // what is known
        #expect(RemoveSheetModel(rows: [unmeasured(name: "two")]).totalFrees == "")  // nothing known: nothing said
    }

    // MARK: Which rows, and when the sheet is skipped

    @Test func onlyReadyAndManualRowsCanBeRemoved() {
        #expect(ready(private: 0).isRemovable)
        #expect(ready(private: 0, needsStopping: true).isRemovable)
        #expect(manual(hosting: .gitlab).isRemovable)
        for eligibility in [RemovalEligibility.mainWorktree, .missing, .blocked([.modified(1)])] {
            #expect(!row(eligibility).isRemovable)
        }
    }

    @Test func onlyTheRowButtonOfAReadyRowWithNothingRunningSkipsTheSheet() {
        let quiet = ready(private: 0)
        #expect(RemoveSheetModel.skipsSheet(for: [quiet], fromRowButton: true, skipSetting: true))

        // The setting is off.
        #expect(!RemoveSheetModel.skipsSheet(for: [quiet], fromRowButton: true, skipSetting: false))
        // Remove N…, Remove…, the inspector and the context menu.
        #expect(!RemoveSheetModel.skipsSheet(for: [quiet], fromRowButton: false, skipSetting: true))
        // Something runs in it.
        #expect(
            !RemoveSheetModel.skipsSheet(
                for: [ready(private: 0, needsStopping: true)], fromRowButton: true, skipSetting: true))
        // Not merged.
        #expect(!RemoveSheetModel.skipsSheet(for: [manual(hosting: .gitlab)], fromRowButton: true, skipSetting: true))
        // More than one.
        #expect(!RemoveSheetModel.skipsSheet(for: [quiet, quiet], fromRowButton: true, skipSetting: true))
        #expect(!RemoveSheetModel.skipsSheet(for: [], fromRowButton: true, skipSetting: true))
    }
}

// MARK: Fixtures

private func ready(
    private bytes: Int64, needsStopping: Bool = false, groups: [ProcessGroup] = [], name: String = "wt"
) -> WorktreeRow {
    row(
        .ready(needsStopping: needsStopping || !groups.isEmpty), groups: groups, name: name,
        size: SizeInfo(apparentBytes: bytes * 4, privateBytes: bytes, computedAt: .distantPast))
}

private func manual(hosting: HostingKind?, groups: [ProcessGroup] = []) -> WorktreeRow {
    row(.manual(needsStopping: !groups.isEmpty), groups: groups, hosting: hosting)
}

private func unmeasured(name: String) -> WorktreeRow {
    row(.ready(needsStopping: false), name: name)
}

private func row(
    _ eligibility: RemovalEligibility, groups: [ProcessGroup] = [], name: String = "wt", hosting: HostingKind? = .gitlab,
    size: SizeInfo? = nil
) -> WorktreeRow {
    WorktreeRow(
        repoPath: "/r", repoName: "r", worktree: Worktree(path: "/r-worktrees/" + name, branch: name), status: nil,
        review: .none, hosting: hosting, groups: groups, size: size, eligibility: eligibility)
}

private func record(_ pid: Int32, _ name: String) -> ProcessRecord {
    ProcessRecord(
        pid: pid, ppid: 1, name: name, executablePath: nil, arguments: [], cwd: nil, footprintBytes: 0,
        startDate: Date(timeIntervalSince1970: 0), listeningPorts: [])
}

private func group(leader: ProcessRecord, members: [ProcessRecord]) -> ProcessGroup {
    ProcessGroup(kind: .other, title: leader.name, leader: leader, members: members)
}
