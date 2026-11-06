import AppKit
import CoreModels
import Dashboard
import Foundation
import Hosting
import Safety
import SwiftUI
import Testing

@testable import AppShell

/// These tests open a borderless window far off every screen, which needs a logged-in session and takes some seconds,
/// so they are off unless the environment has `AD_RENDER_TESTS=1`:
///
///     AD_RENDER_TESTS=1 RENDER_DIR=/some/folder swift test --package-path Packages/Core --filter AppShellTests
///
/// Draws the window off screen with fixture rows, in light and in dark, and writes the pictures to the folder in
/// `RENDER_DIR` (a temporary folder when it is not set). Nothing is put on the screen and nothing is recorded.
@MainActor @Suite(.enabled(if: ProcessInfo.processInfo.environment["AD_RENDER_TESTS"] == "1")) struct RenderTests {
    @Test(arguments: [false, true]) func theWindowDraws(dark: Bool) throws {
        let image = try render(dark: dark, selection: Fixtures.selected)
        #expect(image.size.width > 100)
        let url = try write(image, name: "projects-\(dark ? "dark" : "light").png")
        #expect(FileManager.default.fileExists(atPath: url.path))
        #expect(try distinctColours(of: image) > 20, "the picture is blank")
    }

    @Test(arguments: [false, true]) func thePanesDraw(dark: Bool) throws {
        let image = try renderPanes(dark: dark)
        _ = try write(image, name: "panes-\(dark ? "dark" : "light").png")
        #expect(try distinctColours(of: image) > 20)
    }

    @Test func theSidebarsReadyToRemoveDraws() throws {
        let image = try render(dark: false, sidebar: .readyToRemove, selection: Fixtures.selected)
        _ = try write(image, name: "ready-light.png")
        #expect(try distinctColours(of: image) > 20)
    }

    /// Twelve rows that are ready: the block shows four and `Show all 12`, and the table is still on the screen.
    @Test func theReadyBlockWithManyRowsDraws() throws {
        let image = try render(dark: false, selection: Fixtures.selected, ready: Fixtures.manyReady)
        _ = try write(image, name: "ready-many-light.png")
        #expect(try distinctColours(of: image) > 20)
    }

    /// The sheet of the mockup ("Remove sheet — light"), and the sheet of a worktree whose request is not merged and in
    /// which something runs.
    @Test func theRemoveSheetDraws() throws {
        let sheet = RemoveSheet(model: RemoveSheetModel(rows: Fixtures.sheetRows), cancel: {}, confirm: { _, _ in })
        let image = try snapshot(sheet.background(Color(nsColor: .windowBackgroundColor)), dark: false)
        _ = try write(image, name: "remove-sheet-light.png")
        #expect(try distinctColours(of: image) > 10)

        let stopping = RemoveSheet(
            model: RemoveSheetModel(rows: [Fixtures.manualRunning]), cancel: {}, confirm: { _, _ in })
        let other = try snapshot(stopping.background(Color(nsColor: .windowBackgroundColor)), dark: false)
        _ = try write(other, name: "remove-sheet-stopping-light.png")
        #expect(try distinctColours(of: other) > 10)
    }

    /// The Processes page of the mockup, with the inspector closed as there.
    @Test(arguments: [false, true]) func theProcessesPageDraws(dark: Bool) throws {
        let main = MainView(
            projects: Fixtures.running, ready: [], scanState: .idle, lastUpdated: Date(), isBusy: false,
            memoryInUse: 16_320_875_725, processesSampledAt: Date(), fetch: {}, refresh: {}, removal: .inert,
            sidebar: .processes, showsInspector: false, disk: Fixtures.disk, readsDisk: false)
        let image = try snapshot(main, size: NSSize(width: 1440, height: 900), dark: dark)
        _ = try write(image, name: "processes-\(dark ? "dark" : "light").png")
        #expect(try distinctColours(of: image) > 20)
    }

    /// The first-run window.
    @Test(arguments: [false, true]) func theOnboardingDraws(dark: Bool) throws {
        let view = OnboardingView(start: {}).frame(width: 900, height: 560)
            .background(Color(nsColor: .windowBackgroundColor))
        let image = try snapshot(view, dark: dark)
        _ = try write(image, name: "onboarding-\(dark ? "dark" : "light").png")
        #expect(try distinctColours(of: image) > 10)
    }

    // MARK: Drawing

    private func render(
        dark: Bool, sidebar: SidebarItem = .projects, selection: String?, ready: [WorktreeRow] = Fixtures.ready
    ) throws -> NSImage {
        let size = NSSize(width: 1440, height: 900)
        let main = MainView(
            projects: Fixtures.projects, ready: ready, scanState: .idle,
            lastUpdated: Date().addingTimeInterval(-120), isBusy: false, fetch: {}, refresh: {}, removal: .inert,
            sidebar: sidebar,
            selection: selection, disk: Fixtures.disk, readsDisk: false)
        return try snapshot(main, size: size, dark: dark)
    }

    /// The same three panes side by side with no split view: the split view's translucent sidebar and inspector are
    /// drawn by the window server, which an off-screen copy of the view does not get, so this is how the colours of
    /// the panes themselves are seen in dark.
    private func renderPanes(dark: Bool) throws -> NSImage {
        try snapshot(PanesFixture(), size: NSSize(width: 1440, height: 900), dark: dark)
    }

    /// Draws `content` at `size`, or at the size that it wants when there is none.
    private func snapshot<Content: View>(_ content: Content, size: NSSize? = nil, dark: Bool) throws -> NSImage {
        let host = NSHostingView(
            rootView: content.frame(width: size?.width, height: size?.height)
                .preferredColorScheme(dark ? .dark : .light))
        let size = size ?? host.fittingSize
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
        let appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        // The appearance of this process only; the system's is not touched.
        NSApplication.shared.appearance = appearance
        defer { NSApplication.shared.appearance = nil }
        window.appearance = appearance
        host.appearance = appearance
        window.contentView = host
        window.setFrame(NSRect(origin: NSPoint(x: -4000, y: -4000), size: size), display: false)
        // Far off every screen, and a borderless window is not pulled back onto one: it is never seen, but it is "on
        // screen" for the views that only draw then.
        window.orderFrontRegardless()
        defer { window.orderOut(nil) }
        // Lets the table and the split view lay themselves out, which takes a few turns of the run loop.
        for _ in 0..<20 {
            host.layoutSubtreeIfNeeded()
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        host.layoutSubtreeIfNeeded()
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else {
            throw RenderError.noBitmap
        }
        host.cacheDisplay(in: host.bounds, to: rep)
        let image = NSImage(size: host.bounds.size)
        image.addRepresentation(rep)
        return image
    }

    private func write(_ image: NSImage, name: String) throws -> URL {
        let folder = ProcessInfo.processInfo.environment["RENDER_DIR"].map { URL(filePath: $0) }
            ?? FileManager.default.temporaryDirectory.appending(path: "agent-dashboard-renders")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appending(path: name)
        guard let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
            let png = rep.representation(using: .png, properties: [:])
        else { throw RenderError.noBitmap }
        try png.write(to: url)
        return url
    }

    private func distinctColours(of image: NSImage) throws -> Int {
        guard let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) else {
            throw RenderError.noBitmap
        }
        var seen = Set<UInt32>()
        for x in stride(from: 0, to: rep.pixelsWide, by: 7) {
            for y in stride(from: 0, to: rep.pixelsHigh, by: 7) {
                guard let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
                seen.insert(
                    UInt32(c.redComponent * 255) << 16 | UInt32(c.greenComponent * 255) << 8 | UInt32(c.blueComponent * 255))
            }
        }
        return seen.count
    }

    enum RenderError: Error { case noBitmap }
}

/// Sidebar, detail and inspector in one row, on the colour of a window.
private struct PanesFixture: View {
    @State private var selection: String? = Fixtures.selected
    @State private var filter = ProjectFilter.all
    @State private var collapsed: Set<String> = []
    @State private var sidebar: SidebarItem? = .projects

    var body: some View {
        HStack(spacing: 0) {
            SidebarView(projects: Fixtures.projects, readyCount: Fixtures.ready.count, disk: Fixtures.disk, selection: $sidebar)
                .frame(width: 240)
            Divider()
            ProjectsView(
                projects: Fixtures.projects, ready: Fixtures.ready, filter: $filter, selection: $selection,
                collapsed: $collapsed, actions: .inert)
            Divider()
            WorktreeInspector(row: Fixtures.projects[0].worktrees[0], actions: .inert).frame(width: 320)
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

/// Rows like those of the mockup.
enum Fixtures {
    static let disk = StartupDisk(name: "Macintosh HD", free: 412_300_000_000, total: 994_700_000_000)

    static let selected = "/Users/me/Development/dashboard-worktrees/PYMEP-5000"

    static let ready: [WorktreeRow] = projects.flatMap(\.worktrees).filter {
        if case .ready = $0.eligibility { true } else { false }
    }

    /// The three worktrees of the mockup of the sheet.
    static let sheetRows: [WorktreeRow] = [
        ("PYMEP-3191-statements-analytics-events", 200_000_000), ("PYMEP-1907-team-employee-analytics-events", 300_000_000),
        ("PYMEP-3231-events-for-ahorro-accounts", 300_000_000),
    ].map { name, bytes in
        worktree(
            "dashboard", "/Users/me/Development/dashboard-worktrees/" + name, branch: "feat/" + name,
            review: .init(state: .merged, number: 1), status: .init(upstream: "origin/feat/" + name), groups: [],
            size: .init(apparentBytes: bytes * 10, privateBytes: bytes, computedAt: .now),
            eligibility: .ready(needsStopping: false))
    }

    /// Twelve worktrees that are ready, as in the window that showed the block filling the screen.
    static let manyReady: [WorktreeRow] = (1...12).map { n in
        let name = "PYMEP-\(3000 + n)-some-merged-feature-\(n)"
        return worktree(
            "dashboard", "/Users/me/Development/dashboard-worktrees/" + name, branch: "feat/" + name,
            review: .init(state: .merged, number: n), status: .init(upstream: "origin/feat/" + name), groups: [],
            size: .init(apparentBytes: 2_000_000_000, privateBytes: 200_000_000 + Int64(n) * 10_000_000, computedAt: .now),
            eligibility: .ready(needsStopping: false))
    }

    /// A worktree whose request is open, with a session of Claude Code and a tmux server in it.
    static let manualRunning: WorktreeRow = {
        let claude = record(36136, "claude", 154 << 20)
        let session = ProcessGroup(
            kind: .agentSession, title: "Claude Code · CLI, 2 MCP servers", leader: claude,
            members: [record(36140, "node", 120 << 20), record(36141, "uv", 107 << 20)])
        let tmux = ProcessGroup(kind: .shell, title: "zsh", leader: record(4100, "zsh", 3 << 20), members: [record(4101, "tmux", 2 << 20)])
        return worktree(
            "dashboard", "/Users/me/Development/dashboard-worktrees/PYMEP-3330-overdraft-drawer-agreement-caratula",
            branch: "feat/PYMEP-3330", review: .init(state: .open, number: 8200),
            status: .init(upstream: "origin/feat/PYMEP-3330"), groups: [session, tmux],
            size: .init(apparentBytes: 3_100_000_000, privateBytes: 300_000_000, computedAt: .now),
            eligibility: .manual(needsStopping: true))
    }()

    /// What runs in the mockup of Processes: dashboard with a dev server on 4200 and a session of almost a day, minuta
    /// with a session of almost a week, an app built there and shells and helpers, three worktrees of dashboard, and
    /// meetily.
    static let running: [ProjectRow] = [
        project(
            "dashboard", branch: "main",
            groups: [
                group(
                    .devServer, "vite · nx serve web", process(50123, "node", 412 << 20, age: 18 * 60, ports: [4200])),
                group(
                    .agentSession, "Claude Code · desktop, 6 MCP servers",
                    process(95670, "claude", 272 << 20, age: 86_160)),
                group(.daemon, "codex app-server", process(21642, "codex", 25 << 20, age: 15 * 86_400)),
                group(.daemon, "herdr server", process(44478, "herdr", 2 << 20, age: 15 * 86_400)),
            ] + (6001...6004).map { group(.shell, "zsh", process($0, "zsh", 5_767_168, age: 7_200)) },
            [
                ("PYMEP-3330-overdraft-drawer-agreement-caratula", Int32(31001), UInt64(386)),
                ("PYMEP-3098-overdraft-details-operfeed", 32001, 222),
                ("PYMEP-3282-update-cashback-permissions", 33001, 190),
            ].map { name, pid, megabytes in
                let members = (1...8).map { process(pid + Int32($0), "node", 10 << 20, age: 3_600) }
                return worktree(
                    "dashboard", "/Users/me/Development/dashboard-worktrees/" + name, branch: "feat/" + name,
                    review: .init(state: .open, number: 8200), status: .init(upstream: "origin/feat/" + name),
                    groups: [
                        group(
                            .agentSession, "Claude Code · CLI, 4 MCP servers",
                            process(pid, "claude", (megabytes - 80) << 20, age: 5_400), members: members)
                    ],
                    size: nil, eligibility: .manual(needsStopping: true))
            }),
        project(
            "minuta", branch: "main",
            groups: [
                group(
                    .agentSession, "Claude Code · CLI, 5 MCP servers",
                    process(29055, "claude", 210 << 20, age: 597_600)),
                group(
                    .agentSession, "Claude Code · desktop, 6 MCP servers",
                    process(21919, "claude", 314 << 20, age: 13 * 60)),
                group(.builtHere, "Minuta.app", process(8490, "Minuta", 11 << 20, age: 72 * 60)),
            ] + (7001...7003).map { group(.shell, "zsh", process($0, "zsh", 3 << 20, age: 3_600)) }
                + (7101...7102).map { group(.other, "esbuild", process($0, "esbuild", 45 << 20, age: 3_600)) },
            []),
        project(
            "meetily", branch: "main",
            groups: [
                group(.daemon, "meetily-backend", process(9120, "meetily-backend", 18 << 20, age: 2 * 86_400))
            ], []),
    ]

    private static func process(
        _ pid: Int32, _ name: String, _ bytes: UInt64, age: TimeInterval, ports: [UInt16] = []
    ) -> ProcessRecord {
        ProcessRecord(
            pid: pid, ppid: 1, name: name, executablePath: nil, arguments: [], cwd: nil, footprintBytes: bytes,
            startDate: Date(timeIntervalSinceNow: -age), listeningPorts: ports)
    }

    private static func group(
        _ kind: ProcessKind, _ title: String, _ leader: ProcessRecord, members: [ProcessRecord] = []
    ) -> ProcessGroup {
        ProcessGroup(kind: kind, title: title, leader: leader, members: members)
    }

    private static func record(_ pid: Int32, _ name: String, _ bytes: UInt64) -> ProcessRecord {
        ProcessRecord(
            pid: pid, ppid: 1, name: name, executablePath: nil, arguments: [], cwd: nil, footprintBytes: bytes,
            startDate: Date(timeIntervalSinceNow: -1_500), listeningPorts: [])
    }

    static let projects: [ProjectRow] = [
        project(
            "dashboard", branch: "main", behind: 30,
            [
                worktree(
                    "dashboard", "/Users/me/Development/dashboard-worktrees/PYMEP-5000", branch: "feat/PYMEP-5000",
                    review: .init(state: .merged, number: 8123, webURL: URL(string: "https://gitlab.example.test/mr/8123")),
                    status: .init(upstream: "origin/feat/PYMEP-5000", ahead: 0, lastCommitDate: Date().addingTimeInterval(-86_400 * 3)),
                    groups: [group(.agentSession, "Claude Code · CLI, 2 MCP servers", "claude", 314 << 20), group(.agentSession, "Claude Code · desktop", "claude", 210 << 20), group(.builtHere, "Minuta", "Minuta", 11 << 20), group(.shell, "zsh", "zsh", 99 << 20)],
                    size: .init(apparentBytes: 3_100_000_000, privateBytes: 300_000_000, computedAt: .now),
                    eligibility: .ready(needsStopping: true)),
                worktree(
                    "dashboard", "/Users/me/Development/dashboard-worktrees/PYMEP-5001", branch: "feat/PYMEP-5001",
                    review: .init(state: .merged, number: 8124),
                    status: .init(upstream: "origin/feat/PYMEP-5001", upstreamGone: true),
                    groups: [],
                    size: .init(apparentBytes: 2_800_000_000, privateBytes: 1_900_000_000, computedAt: .now),
                    eligibility: .ready(needsStopping: false)),
                worktree(
                    "dashboard", "/Users/me/Development/dashboard-worktrees/PYMEP-5002", branch: "fix/PYMEP-5002",
                    review: .init(state: .open, number: 8130),
                    status: .init(upstream: "origin/fix/PYMEP-5002", ahead: 2, modified: 11, untracked: 0),
                    groups: [group(.devServer, "node", "node", 640 << 20)],
                    size: .init(apparentBytes: 2_780_000_000, privateBytes: 31_000_000, computedAt: .now),
                    eligibility: .blocked([.modified(11), .stash(1)])),
                worktree(
                    "dashboard", "/Users/me/Development/dashboard-worktrees/PYMEP-4990", branch: "feat/PYMEP-4990",
                    review: .none, status: nil, groups: [], size: nil, eligibility: .missing, prunable: true),
            ]),
        project(
            "minuta", branch: "main", ahead: 69,
            [
                worktree(
                    "minuta", "/Users/me/Development/minuta/.claude/worktrees/agent-a1", branch: "agent/a1",
                    review: .init(state: .draft, number: 12), status: .init(upstream: "origin/agent/a1", untracked: 3),
                    groups: [], size: .init(apparentBytes: 900_000_000, privateBytes: 850_000_000, computedAt: .now),
                    eligibility: .blocked([.untracked(3), .notOnRemote(2)]))
            ]),
        project("expense-tracker", branch: "main", []),
    ]

    private static func project(
        _ name: String, branch: String, behind: Int = 0, ahead: Int = 0, groups: [ProcessGroup] = [],
        _ worktrees: [WorktreeRow]
    ) -> ProjectRow {
        let path = "/Users/me/Development/" + name
        let main = WorktreeRow(
            repoPath: path, repoName: name, worktree: Worktree(path: path, branch: branch, isMain: true),
            status: .init(upstream: "origin/" + branch, ahead: ahead, behind: behind), review: .none, hosting: .gitlab,
            groups: groups, size: .init(apparentBytes: 1_200_000_000, privateBytes: 1_100_000_000, computedAt: .now),
            eligibility: .mainWorktree)
        let linked = worktrees.map {
            WorktreeRow(
                repoPath: path, repoName: name, worktree: $0.worktree, status: $0.status, review: $0.review,
                hosting: .gitlab, groups: $0.groups, size: $0.size, eligibility: $0.eligibility)
        }
        return ProjectRow(path: path, name: name, main: main, worktrees: linked)
    }

    private static func worktree(
        _ repo: String, _ path: String, branch: String, review: ReviewInfo, status: WorktreeStatus?,
        groups: [ProcessGroup], size: SizeInfo?, eligibility: RemovalEligibility, prunable: Bool = false
    ) -> WorktreeRow {
        WorktreeRow(
            repoPath: "", repoName: repo, worktree: Worktree(path: path, branch: branch, isPrunable: prunable),
            status: status, review: review, hosting: .gitlab, groups: groups, size: size, eligibility: eligibility)
    }

    private static func group(_ kind: ProcessKind, _ title: String, _ name: String, _ bytes: UInt64) -> ProcessGroup {
        let leader = ProcessRecord(
            pid: Int32(truncatingIfNeeded: bytes >> 10) + Int32(title.utf8.count), ppid: 1, name: name, executablePath: nil, arguments: [], cwd: nil,
            footprintBytes: bytes, startDate: Date(timeIntervalSinceNow: -3_600), listeningPorts: [])
        return ProcessGroup(kind: kind, title: title, leader: leader, members: [])
    }
}
