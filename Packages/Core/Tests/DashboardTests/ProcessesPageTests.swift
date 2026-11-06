import CoreModels
import Foundation
import Testing

@testable import Dashboard

/// The Processes page as the store's rows make it: which worktrees it lists, in what order, and the words on it.
@Suite struct ProcessesPageTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    @Test func sectionsAreWorktreesWithSomethingRunningByMemory() {
        let main = worktree("/r/dashboard", main: true, [group(100, kind: .agentSession, members: 11, mib: 30)])
        let big = worktree("/r/dashboard-worktrees/PYMEP-1", [group(200, kind: .devServer, members: 8, mib: 50)])
        let one = worktree("/r/dashboard-worktrees/PYMEP-2", [group(300, kind: .daemon, mib: 100)])
        let idle = worktree("/r/dashboard-worktrees/PYMEP-3", [])

        let page = ProcessesPage(projects: [project(main, [one, idle, big])])

        #expect(page.sections.map(\.id) == [big.id, main.id, one.id])
        #expect(page.sections.map(\.title) == ["PYMEP-1", "dashboard", "PYMEP-2"])
        #expect(page.sections.map(\.subtitle) == ["dashboard · 9 processes", "12 processes", "dashboard · 1 process"])
        #expect(page.sections.map(\.memory) == [450 << 20, 360 << 20, 100 << 20])
    }

    @Test func sectionsOfEqualMemoryGoByTitle() {
        let b = worktree("/r/b", [group(1, kind: .other, mib: 10)])
        let a = worktree("/r/a", [group(2, kind: .other, mib: 10)])

        let page = ProcessesPage(projects: [project(worktree("/r/main", main: true, []), [b, a])])

        #expect(page.sections.map(\.title) == ["a", "b"])
    }

    @Test func linesAreGroupsByMemoryWithShellsAndHelpersLast() {
        let small = group(10, kind: .devServer, mib: 10)
        let big = group(20, kind: .agentSession, mib: 90)
        let shells = (30...33).map { group(Int32($0), kind: .shell, mib: 500) }
        let helpers = [group(40, kind: .other, mib: 7), group(41, kind: .other, mib: 8)]

        func lines(_ groups: [ProcessGroup]) -> [ProcessLine] {
            ProcessesPage(projects: [project(worktree("/r/main", main: true, groups), [])]).sections[0].lines
        }

        let shellsOnly = lines([small, big] + shells)
        #expect(shellsOnly.map(\.title) == [big.title, small.title, "4 shells"])
        let merged = shellsOnly[2]
        #expect(merged.id == "/r/main#rest")
        #expect(merged.kind == "Shell")
        #expect(merged.pid == nil)
        #expect(merged.uptime(now: now) == nil)
        #expect(merged.memory == 2000 << 20)
        #expect(merged.groups == shells)

        let helpersOnly = lines([small] + helpers)
        #expect(helpersOnly.last?.title == "2 helpers")
        #expect(helpersOnly.last?.kind == "Other")

        let mixed = lines([small] + Array(shells.prefix(3)) + helpers)
        #expect(mixed.last?.title == "3 shells, 2 helpers")
        #expect(mixed.last?.kind == "Other")
        #expect(mixed.last?.groups.count == 5)

        // One such group is an ordinary line, ordered by its memory like any other.
        let single = lines([small, shells[0], big])
        #expect(single.map(\.title) == [shells[0].title, big.title, small.title])
        #expect(single[0].id == "/r/main#30")
        #expect(single[0].pid == 30)
    }

    @Test func linesOfEqualMemoryGoByTheLeadersPid() {
        let first = group(5, kind: .devServer, mib: 10)
        let second = group(9, kind: .devServer, mib: 10)

        let page = ProcessesPage(projects: [project(worktree("/r/main", main: true, [second, first]), [])])

        #expect(page.sections[0].lines.map(\.pid) == [5, 9])
    }

    @Test func aLineCarriesThePortsAndTheMemoryOfItsGroup() {
        let server = ProcessGroup(
            kind: .devServer, title: "vite", leader: record(7, mib: 40, ports: [4200]),
            members: [record(8, mib: 2, ports: [4201, 4200])])

        let line = ProcessesPage(projects: [project(worktree("/r/main", main: true, [server]), [])]).sections[0].lines[
            0]

        #expect(line.ports == [4200, 4201])
        #expect(line.memory == 42 << 20)
        #expect(line.groups == [server])
    }

    @Test func kindLabelsAndSymbols() {
        let kinds: [(ProcessKind, String, String)] = [
            (.agentSession, "Agent session", "sparkle"), (.devServer, "Dev server", "globe"),
            (.daemon, "Daemon", "gearshape"), (.builtHere, "Built here", "macwindow"),
            (.shell, "Shell", "apple.terminal"), (.other, "Other", "ellipsis"),
        ]

        for (kind, label, symbol) in kinds {
            let line = ProcessesPage(
                projects: [project(worktree("/r/main", main: true, [group(1, kind: kind, mib: 1)]), [])]
            ).sections[0].lines[0]
            #expect(line.kind == label)
            #expect(line.symbol == symbol)
        }
    }

    @Test func uptimeTexts() {
        let minute: TimeInterval = 60
        let hour = 60 * minute
        let day = 24 * hour

        #expect(ProcessesPresenter.uptime(30, kind: .devServer) == Uptime(text: "<1m", isLong: false))
        #expect(ProcessesPresenter.uptime(18 * minute, kind: .devServer) == Uptime(text: "18m", isLong: false))
        #expect(
            ProcessesPresenter.uptime(hour + 12 * minute, kind: .devServer) == Uptime(text: "1h 12m", isLong: false))
        #expect(
            ProcessesPresenter.uptime(23 * hour + 56 * minute, kind: .shell) == Uptime(text: "23h 56m", isLong: false))
        #expect(ProcessesPresenter.uptime(15 * day, kind: .daemon) == Uptime(text: "15d", isLong: false))
        #expect(
            ProcessesPresenter.uptime(6 * day + 22 * hour, kind: .agentSession) == Uptime(text: "6d 22h", isLong: true))
        #expect(ProcessesPresenter.uptime(day, kind: .agentSession) == Uptime(text: "1d 0h", isLong: true))
        #expect(!ProcessesPresenter.uptime(23 * hour + 59 * minute, kind: .agentSession).isLong)
    }

    @Test func aLineTakesItsUptimeFromItsGroup() {
        let session = group(1, kind: .agentSession, mib: 1, started: now.addingTimeInterval(-(2 * 86_400 + 3 * 3_600)))

        let line = ProcessesPage(projects: [project(worktree("/r/main", main: true, [session]), [])]).sections[0].lines[
            0]

        #expect(line.uptime(now: now) == Uptime(text: "2d 3h", isLong: true))
    }

    @Test func uptimeIsNeverNegative() {
        let ahead = group(1, kind: .devServer, mib: 1, started: now.addingTimeInterval(5))

        let line = ProcessesPage(projects: [project(worktree("/r/main", main: true, [ahead]), [])]).sections[0].lines[0]

        #expect(line.uptime(now: now) == Uptime(text: "<1m", isLong: false))
    }

    @Test func theBarShowsFiveAndOther() {
        let main = worktree("/r/api", main: true, [group(1, kind: .other, mib: 70)])
        let linkedOnes = [
            worktree("/r/w/PYMEP-3330-overdraft-drawer", [group(2, kind: .other, mib: 60)]),
            worktree("/r/w/feature", [group(3, kind: .other, mib: 50)]),
            worktree("/r/w/c", [group(4, kind: .other, mib: 40)]),
            worktree("/r/w/d", [group(5, kind: .other, mib: 30)]),
            worktree("/r/w/e", [group(6, kind: .other, mib: 20)]),
            worktree("/r/w/f", [group(7, kind: .other, mib: 10)]),
        ]

        let page = ProcessesPage(projects: [project(main, linkedOnes)])

        #expect(
            page.bar == [
                MemorySegment(label: "api", bytes: 70 << 20, worktree: "/r/api"),
                MemorySegment(label: "PYMEP-3330", bytes: 60 << 20, worktree: "/r/w/PYMEP-3330-overdraft-drawer"),
                MemorySegment(label: "feature", bytes: 50 << 20, worktree: "/r/w/feature"),
                MemorySegment(label: "c", bytes: 40 << 20, worktree: "/r/w/c"),
                MemorySegment(label: "d", bytes: 30 << 20, worktree: "/r/w/d"),
                MemorySegment(label: "other", bytes: 30 << 20, worktree: nil),
            ])

        let five = ProcessesPage(projects: [project(main, Array(linkedOnes.prefix(4)))])
        #expect(five.bar.count == 5)
        #expect(five.bar.allSatisfy { $0.worktree != nil })
    }

    @Test func totalsCountEveryProcessOnce() {
        let shared = record(9, mib: 5)
        let first = ProcessGroup(
            kind: .agentSession, title: "a", leader: record(1, mib: 10), members: [record(2, mib: 20), shared])
        let second = ProcessGroup(kind: .other, title: "b", leader: shared, members: [])
        let other = group(30, kind: .devServer, mib: 100)

        let page = ProcessesPage(projects: [
            project(
                worktree("/r/main", main: true, [first, second]), [worktree("/r/w/x", [other])])
        ])

        #expect(page.processCount == 4)
        #expect(page.totalMemory == page.sections.reduce(0) { $0 + $1.memory })
        #expect(page.totalMemory == (35 + 5 + 100) << 20)
    }

    @Test func aProcessWithoutMemoryOrPorts() {
        let quiet = ProcessGroup(kind: .other, title: "x", leader: record(1, mib: 0), members: [])

        let page = ProcessesPage(projects: [project(worktree("/r/main", main: true, [quiet]), [])])

        #expect(page.sections[0].memory == 0)
        #expect(page.sections[0].lines[0].memory == 0)
        #expect(page.sections[0].lines[0].ports == [])
    }

    @Test func queryMatchesWorktreeRepoTitleNamePidAndPort() {
        let server = ProcessGroup(
            kind: .devServer, title: "vite", leader: record(4100, mib: 10, ports: [4200], name: "node"),
            members: [record(4101, mib: 1, name: "esbuild")])
        let session = ProcessGroup(
            kind: .agentSession, title: "Claude Code · CLI", leader: record(5, mib: 20), members: [])
        let main = worktree("/r/api", main: true, [server, session])
        let linkedRow = worktree("/r/w/PYMEP-7", repo: "dashboard", [server, session])
        let projects = [project(main, [linkedRow])]

        func titles(_ query: String) -> [[String]] {
            ProcessesPage(projects: projects, query: query).sections.map { $0.lines.map(\.title) }
        }

        // The title or the repository of a section keeps all of it, whatever the case.
        #expect(titles("pymep-7") == [["Claude Code · CLI", "vite"]])
        #expect(titles("DASHBOARD") == [["Claude Code · CLI", "vite"]])
        #expect(titles("api") == [["Claude Code · CLI", "vite"]])
        // Otherwise only the lines that match stay.
        #expect(titles("claude") == [["Claude Code · CLI"], ["Claude Code · CLI"]])
        #expect(titles("esbuild") == [["vite"], ["vite"]])
        #expect(titles("4100") == [["vite"], ["vite"]])
        #expect(titles("4101") == [["vite"], ["vite"]])
        #expect(titles("410") == [])
        #expect(titles("4200") == [["vite"], ["vite"]])
        #expect(titles(":4200") == [["vite"], ["vite"]])
        #expect(titles("420") == [])
        #expect(titles("") == [["Claude Code · CLI", "vite"], ["Claude Code · CLI", "vite"]])
    }

    @Test func aFilteredSectionCountsOnlyWhatItShows() {
        let server = group(1, kind: .devServer, title: "vite", members: 2, mib: 10)
        let session = group(10, kind: .agentSession, title: "Claude Code", mib: 20)

        let page = ProcessesPage(
            projects: [project(worktree("/r/api", main: true, [server, session]), [])], query: "vite")

        #expect(page.sections[0].subtitle == "3 processes")
        #expect(page.sections[0].memory == 30 << 20)
        #expect(page.processCount == 3)
        #expect(page.totalMemory == 30 << 20)
    }

    @Test func aQueryThatMatchesNothingLeavesNoSection() {
        let projects = [project(worktree("/r/api", main: true, [group(1, kind: .other, mib: 10)]), [])]

        let page = ProcessesPage(projects: projects, query: "zzz")

        #expect(page.sections == [])
        #expect(page.bar == [])
        #expect(page.processCount == 0)
        #expect(page.totalMemory == 0)
    }

    @Test func aGroupThatIsGoneLeavesTheSection() {
        let gone = group(1, kind: .devServer, mib: 10)
        let before = project(worktree("/r/api", main: true, [gone]), [])
        let after = project(worktree("/r/api", main: true, []), [])

        #expect(ProcessesPage(projects: [before]).sections.count == 1)
        #expect(ProcessesPage(projects: [after]).sections == [])
    }

    @Test func subtitleAndInUse() {
        let nine = (0..<9).map { i in
            let members = i == 8 ? 2 : 4
            return worktree(
                "/r/w/p\(i)", [group(Int32(i * 10 + 1), kind: .devServer, members: members, mib: 250, memberMib: 0)])
        }
        let page = ProcessesPage(projects: [project(worktree("/r/main", main: true, []), nine)])

        #expect(page.processCount == 43)
        #expect(
            ProcessesPresenter.subtitle(page, updated: now.addingTimeInterval(-10), now: now)
                == "43 processes in 9 projects · 2.2 GB memory · updated just now")
        #expect(
            ProcessesPresenter.subtitle(page, updated: now.addingTimeInterval(-120), now: now)
                == "43 processes in 9 projects · 2.2 GB memory · updated 2 minutes ago")
        #expect(
            ProcessesPresenter.subtitle(page, updated: nil, now: now) == "43 processes in 9 projects · 2.2 GB memory")
        #expect(ProcessesPresenter.inUse(page, of: 16_320_875_725) == "2.2 GB of 15.2 GB in use on this Mac")
        #expect(ProcessesPresenter.inUse(page, of: nil) == nil)

        let single = ProcessesPage(projects: [
            project(worktree("/r/main", main: true, [group(1, kind: .other, mib: 386)]), [])
        ])
        #expect(
            ProcessesPresenter.subtitle(single, updated: now, now: now)
                == "1 process in 1 project · 386 MB memory · updated just now")
    }

    // MARK: Rows

    private func record(
        _ pid: Int32, mib: UInt64, ports: [UInt16] = [], name: String = "node", started: Date? = nil
    ) -> ProcessRecord {
        ProcessRecord(
            pid: pid, ppid: 1, name: name, executablePath: nil, arguments: [], cwd: nil, footprintBytes: mib << 20,
            startDate: started ?? now.addingTimeInterval(-3_600), listeningPorts: ports)
    }

    /// A group of a leader that weighs `mib` and `members` processes that weigh `memberMib`, by default the same.
    private func group(
        _ pid: Int32, kind: ProcessKind, title: String? = nil, members: Int = 0, mib: UInt64, memberMib: UInt64? = nil,
        started: Date? = nil
    ) -> ProcessGroup {
        ProcessGroup(
            kind: kind, title: title ?? "\(kind)-\(pid)", leader: record(pid, mib: mib, started: started),
            members: (0..<members).map { record(pid + 1 + Int32($0), mib: memberMib ?? mib) })
    }

    private func worktree(
        _ path: String, main: Bool = false, repo: String? = nil, _ groups: [ProcessGroup]
    ) -> WorktreeRow {
        let repoName = repo ?? (main ? (path as NSString).lastPathComponent : "dashboard")
        return WorktreeRow(
            repoPath: "/r/" + repoName, repoName: repoName, worktree: Worktree(path: path, isMain: main), status: nil,
            review: .none, hosting: nil, groups: groups, size: nil,
            eligibility: main ? .mainWorktree : .ready(needsStopping: false))
    }

    private func project(_ main: WorktreeRow, _ worktrees: [WorktreeRow]) -> ProjectRow {
        ProjectRow(path: main.repoPath, name: main.repoName, main: main, worktrees: worktrees)
    }
}
