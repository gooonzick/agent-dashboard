import AppKit
import CoreModels
import Dashboard
import SwiftUI

/// The window of the app: reads the store, tells it when the window is on the screen, and passes what it holds to
/// `MainView`.
public struct RootView: View {
    private let store: DashboardStore
    /// Fetch and Refresh in flight. `start()` that is running has its own flag in the store.
    @State private var working = false

    public init(store: DashboardStore) {
        self.store = store
    }

    public var body: some View {
        Group {
            if store.didOnboard {
                main
            } else {
                // Until the user says so, nothing is scanned, sampled or asked of a host (see `DashboardStore`).
                OnboardingView { Task { await store.completeOnboarding() } }
            }
        }
        .background(WindowVisibility { store.isWindowVisible = $0 })
        .onAppear { store.isAppActive = NSApplication.shared.isActive }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            store.isAppActive = true
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)) { _ in
            store.isAppActive = false
        }
    }

    private var main: some View {
        MainView(
            projects: store.projects, ready: store.readyToRemove, scanState: store.scanState,
            lastUpdated: store.lastUpdated, isBusy: working || store.isStarting, stopping: store.stopping,
            fetch: { run { await store.fetchAll() } },
            refreshSizes: { store.refreshSizes(of: $0) },
            // A scan, then git and the hosts anew for every repository: the one call that does all of it. It does
            // nothing while another `start()` runs, which is why the button is off then.
            refresh: { run { await store.start() } },
            removal: RemovalActions(
                remove: { rows, deleteBranches in
                    RowPresenter.failureLines(await store.remove(rows, deleteBranches: deleteBranches), rows: rows)
                },
                prune: { row in
                    guard let error = await store.prune(repoPath: row.repoPath) else { return [] }
                    return RowPresenter.failureLines([.failed(row.id, error)], rows: [row])
                },
                hide: { store.hide(repoPath: $0) },
                stop: { groups, row in await store.stop(groups, of: row) },
                skipsConfirmation: { store.settings.skipConfirmForMergedPushed },
                skipConfirmationFromNowOn: { store.settings.skipConfirmForMergedPushed = true }),
            disk: nil, readsDisk: true
        )
        // Once in a run of the app: the window appears again after it was closed, and that is no reason to scan the
        // disk again.
        .task { run { await store.startIfNeeded() } }
    }

    private func run(_ work: @escaping @MainActor () async -> Void) {
        guard !working, !store.isStarting else { return }
        working = true
        Task {
            await work()
            working = false
        }
    }
}

/// What the window asks of the store to remove, prune and hide, and to stop processes, and the setting that lets a
/// removal skip the sheet. Removing and pruning answer with a line for each worktree that was not removed
/// (`RowPresenter.failureLines`), stopping with what went wrong, if something did.
struct RemovalActions {
    var remove: @MainActor (_ rows: [WorktreeRow], _ deleteBranches: Bool) async -> [String]
    var prune: @MainActor (_ row: WorktreeRow) async -> [String]
    var hide: @MainActor (_ repoPath: String) -> Void
    var stop: @MainActor (_ groups: [ProcessGroup], _ row: WorktreeRow) async -> StopFailure?
    /// "Don't ask again for merged, pushed worktrees".
    var skipsConfirmation: @MainActor () -> Bool
    var skipConfirmationFromNowOn: @MainActor () -> Void

    /// Removes nothing: for the renders.
    static var inert: RemovalActions {
        RemovalActions(
            remove: { _, _ in [] }, prune: { _ in [] }, hide: { _ in }, stop: { _, _ in nil },
            skipsConfirmation: { false }, skipConfirmationFromNowOn: {})
    }
}

/// A removal that waits for the user to confirm it in the sheet.
private struct RemovalAsk: Identifiable {
    let id = UUID()
    /// The rows as they were when the user asked: what they confirm is what these say.
    let rows: [WorktreeRow]
}

/// The sidebar, the table and the inspector, from plain values: what the previews and the renders feed it.
struct MainView: View {
    let projects: [ProjectRow]
    let ready: [WorktreeRow]
    let scanState: ScanState
    let lastUpdated: Date?
    let isBusy: Bool
    /// The groups whose stop is under way (`DashboardStore.stopping`).
    let stopping: Set<Int32>
    let fetch: () -> Void
    /// Measures the worktrees at these paths again if their sizes are more than a minute old: the one that the
    /// inspector shows, and those of the sheet (`DashboardStore.refreshSizes(of:)`).
    let refreshSizes: ([String]) -> Void
    let refresh: () -> Void
    let removal: RemovalActions

    @State private var sidebar: SidebarItem?
    @State private var selection: String?
    @State private var filter = ProjectFilter.all
    @State private var query = ""
    @State private var collapsed: Set<String> = []
    @State private var showsInspector: Bool
    @State private var disk: StartupDisk?
    /// Whether the disk is read, now and every 30 seconds. Renders turn it off and pass a disk of their own.
    private let readsDisk: Bool
    @State private var now = Date()
    @State private var ask: RemovalAsk?
    /// The worktrees whose removal is under way.
    @State private var removing: Set<String> = []
    /// A line for each worktree that was not removed, for the alert.
    @State private var failures: [String] = []
    /// A stop that waits for the user to confirm it.
    @State private var stopAsk: StopConfirmation?
    /// What the last stop that did not go through left running, for its alert.
    @State private var stopFailure: (title: String, message: String)?
    @FocusState private var searchIsFocused: Bool

    init(
        projects: [ProjectRow], ready: [WorktreeRow], scanState: ScanState, lastUpdated: Date?, isBusy: Bool,
        stopping: Set<Int32> = [], fetch: @escaping () -> Void, refreshSizes: @escaping ([String]) -> Void = { _ in },
        refresh: @escaping () -> Void, removal: RemovalActions,
        sidebar: SidebarItem = .projects, selection: String? = nil, showsInspector: Bool = true, disk: StartupDisk?,
        readsDisk: Bool
    ) {
        self.projects = projects
        self.ready = ready
        self.scanState = scanState
        self.lastUpdated = lastUpdated
        self.isBusy = isBusy
        self.stopping = stopping
        self.fetch = fetch
        self.refreshSizes = refreshSizes
        self.refresh = refresh
        self.removal = removal
        _sidebar = State(initialValue: sidebar)
        _selection = State(initialValue: selection)
        _showsInspector = State(initialValue: showsInspector)
        _disk = State(initialValue: disk)
        self.readsDisk = readsDisk
    }

    var body: some View {
        NavigationSplitView {
            SidebarView(projects: projects, readyCount: ready.count, disk: disk, selection: $sidebar)
                .navigationSplitViewColumnWidth(min: 200, ideal: 240, max: 320)
        } detail: {
            detail
                .navigationTitle(sidebar == .readyToRemove ? "Ready to remove" : "Projects")
                .navigationSubtitle(sidebar == .readyToRemove ? "" : subtitle)
                .searchable(text: $query, prompt: "Search")
                .searchFocused($searchIsFocused)
                .toolbar { toolbar }
                .inspector(isPresented: $showsInspector) {
                    Group {
                        if let row = selectedRow {
                            WorktreeInspector(row: row, actions: rowActions)
                                // When the inspector shows a worktree: on appearing, and for each other one selected.
                                .task(id: row.id) { refreshSizes([row.id]) }
                        } else {
                            Color.clear
                        }
                    }
                    .inspectorColumnWidth(min: 280, ideal: 320, max: 420)
                }
        }
        .focusedSceneValue(\.windowCommands, commands)
        .sheet(item: $ask) { ask in
            RemoveSheet(
                model: RemoveSheetModel(rows: ask.rows, sizes: currentSizes(of: ask.rows)), cancel: { self.ask = nil },
                confirm: { deleteBranches, dontAskAgain in
                    self.ask = nil
                    // Only once the user confirms: Cancel leaves the setting as it was.
                    if dontAskAgain { removal.skipConfirmationFromNowOn() }
                    perform(ask.rows, deleteBranches: deleteBranches)
                })
                .task { refreshSizes(ask.rows.map(\.id)) }
        }
        .alert(
            "Some worktrees were not removed",
            isPresented: Binding(get: { !failures.isEmpty }, set: { if !$0 { failures = [] } })
        ) {
        } message: {
            Text(failures.joined(separator: "\n"))
        }
        // Always asked: what is stopped may hold work that is saved nowhere, and nothing brings it back.
        .confirmationDialog(
            stopAsk?.title ?? "", isPresented: Binding(get: { stopAsk != nil }, set: { if !$0 { stopAsk = nil } }),
            titleVisibility: .visible, presenting: stopAsk
        ) { ask in
            Button(ask.confirmTitle, role: .destructive) { performStop(ask) }
            Button("Cancel", role: .cancel) {}
        } message: { ask in
            Text(ask.message)
        }
        .alert(
            stopFailure?.title ?? "",
            isPresented: Binding(get: { stopFailure != nil }, set: { if !$0 { stopFailure = nil } })
        ) {
        } message: {
            Text(stopFailure?.message ?? "")
        }
        .onChange(of: projects) { _, projects in
            if case .repository(let path) = sidebar, !projects.contains(where: { $0.path == path }) {
                sidebar = .projects
            }
        }
        .task {
            while !Task.isCancelled {
                now = Date()
                if readsDisk {
                    // Off the main actor: asking a volume for its capacity can wait on the disk.
                    disk = await Task.detached(priority: .utility) { StartupDisk.read() }.value
                }
                try? await Task.sleep(for: .seconds(30))
            }
        }
    }

    // MARK: Detail

    @ViewBuilder private var detail: some View {
        switch sidebar ?? .projects {
        case .readyToRemove:
            ScrollView {
                if !ready.isEmpty {
                    ReadyToRemoveSection(rows: ready, selection: $selection, actions: rowActions, capped: false).padding(20)
                }
            }
        case .projects:
            projectsView(repoPath: nil)
        case .repository(let path):
            projectsView(repoPath: path)
        }
    }

    private func projectsView(repoPath: String?) -> some View {
        ProjectsView(
            projects: ProjectFilter.visible(projects, filter: filter, query: query, repoPath: repoPath),
            ready: repoPath == nil ? ready : ready.filter { $0.repoPath == repoPath },
            filter: $filter, selection: $selection, collapsed: $collapsed, actions: rowActions)
    }

    private var selectedRow: WorktreeRow? {
        selection.flatMap(currentRow)
    }

    /// The row of the worktree at `path` as the store shows it now.
    private func currentRow(_ path: String) -> WorktreeRow? {
        for project in projects {
            if project.main.id == path { return project.main }
            if let row = project.worktrees.first(where: { $0.id == path }) { return row }
        }
        return nil
    }

    /// The sizes that the store has now for `rows`, which the sheet shows in place of theirs.
    private func currentSizes(of rows: [WorktreeRow]) -> [String: SizeInfo] {
        rows.reduce(into: [:]) { sizes, row in sizes[row.id] = currentRow(row.id)?.size }
    }

    // MARK: Removal

    private var rowActions: RowActions {
        RowActions(
            removing: removing, remove: { rows, fromRowButton in requestRemoval(rows, fromRowButton: fromRowButton) },
            prune: { row in
                Task { failures += await removal.prune(row) }
            },
            hide: { removal.hide($0) }, stopping: stopping, stop: { groups, row in requestStop(groups, of: row) })
    }

    /// The sheet for `rows`, or the removal at once for the per-row Remove when "Don't ask again" lets it skip the
    /// sheet. Rows that cannot be removed, or are already on their way, are left out.
    private func requestRemoval(_ rows: [WorktreeRow], fromRowButton: Bool) {
        let rows = rows.filter(rowActions.canRemove)
        guard !rows.isEmpty else { return }
        if RemoveSheetModel.skipsSheet(
            for: rows, fromRowButton: fromRowButton, skipSetting: removal.skipsConfirmation())
        {
            // As the sheet would have it: "Also delete the local branches" is on there.
            perform(rows, deleteBranches: true)
        } else {
            ask = RemovalAsk(rows: rows)
        }
    }

    private func perform(_ rows: [WorktreeRow], deleteBranches: Bool) {
        // A second confirm of rows that are on their way already starts nothing, and reports nothing.
        let rows = rows.filter { !removing.contains($0.id) }
        guard !rows.isEmpty else { return }
        let ids = rows.map(\.id)
        removing.formUnion(ids)
        Task {
            let lines = await removal.remove(rows, deleteBranches)
            removing.subtract(ids)
            failures += lines
        }
    }

    // MARK: Stopping

    /// The dialog for `groups`, without those that cannot be stopped now: on their way already, or in a worktree that
    /// is being removed.
    private func requestStop(_ groups: [ProcessGroup], of row: WorktreeRow) {
        let actions = rowActions
        let groups = groups.filter { actions.canStop($0, of: row) }
        guard !groups.isEmpty else { return }
        stopAsk = StopConfirmation(groups, of: row)
    }

    private func performStop(_ ask: StopConfirmation) {
        stopAsk = nil
        Task {
            guard let failure = await removal.stop(ask.groups, ask.row) else { return }
            stopFailure = (
                RowPresenter.stopFailureTitle(failure), RowPresenter.stopFailureMessage(failure, groups: ask.groups)
            )
        }
    }

    // MARK: Commands

    private var commands: WindowCommands {
        let sidebar = $sidebar
        var commands = WindowCommands(
            showProjects: { sidebar.wrappedValue = .projects },
            showReadyToRemove: { sidebar.wrappedValue = .readyToRemove })
        let sheetIsOpen = ask != nil
        if WindowCommands.offersRefresh(isBusy: isBusy, isScanning: scanState.isScanning, sheetIsOpen: sheetIsOpen) {
            commands.refresh = refresh
            commands.fetchAll = fetch
        }
        if let row = selectedRow,
            WindowCommands.offersRemove(
                selectionIsRemovable: rowActions.canRemove(row), searchIsFocused: searchIsFocused,
                sheetIsOpen: sheetIsOpen)
        {
            commands.removeSelection = { requestRemoval([row], fromRowButton: false) }
        }
        return commands
    }

    // MARK: Toolbar

    private var subtitle: String {
        let worktrees = projects.reduce(0) { $0 + $1.worktrees.count }
        var text = "\(projects.count) repositories · \(worktrees) worktrees"
        if let lastUpdated {
            let formatter = RelativeDateTimeFormatter()
            formatter.dateTimeStyle = .named
            formatter.unitsStyle = .full
            text += " · updated " + formatter.localizedString(for: min(lastUpdated, now), relativeTo: now)
        }
        return text
    }

    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        // The spinner stands on its own, outside the buttons' shared background, where it has room to breathe.
        if isBusy || scanState.isScanning {
            ToolbarItem {
                ProgressView().controlSize(.small).padding(.horizontal, 4)
            }
            .sharedBackgroundVisibility(.hidden)
        }
        ToolbarItemGroup {
            Button("Fetch", systemImage: "arrow.down.circle", action: fetch)
                .help("Fetch")
                .disabled(isBusy || scanState.isScanning)
            Button("Refresh", systemImage: "arrow.clockwise", action: refresh)
                .help("Refresh")
                .disabled(isBusy || scanState.isScanning)
        }
        ToolbarItem {
            Button("Inspector", systemImage: "sidebar.right") { showsInspector.toggle() }
                .help("Inspector")
        }
    }
}

extension ScanState {
    fileprivate var isScanning: Bool {
        if case .scanning = self { true } else { false }
    }
}

/// Tells whether the window is on the screen: not hidden behind others, not in the Dock, not closed.
private struct WindowVisibility: NSViewRepresentable {
    let changed: @MainActor (Bool) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = ObservingView()
        view.changed = changed
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        (view as? ObservingView)?.changed = changed
    }

    final class ObservingView: NSView {
        var changed: @MainActor (Bool) -> Void = { _ in }
        private var tokens: [any NSObjectProtocol] = []

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            tokens.forEach(NotificationCenter.default.removeObserver)
            tokens = []
            guard let window else {
                changed(false)
                return
            }
            let names: [Notification.Name] = [
                NSWindow.didChangeOcclusionStateNotification, NSWindow.didMiniaturizeNotification,
                NSWindow.didDeminiaturizeNotification, NSWindow.willCloseNotification,
            ]
            tokens = names.map { name in
                NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.report(closing: name == NSWindow.willCloseNotification) }
                }
            }
            report(closing: false)
        }

        private func report(closing: Bool) {
            guard !closing, let window else { return changed(false) }
            changed(window.occlusionState.contains(.visible) && !window.isMiniaturized)
        }

        isolated deinit {
            tokens.forEach(NotificationCenter.default.removeObserver)
        }
    }
}
