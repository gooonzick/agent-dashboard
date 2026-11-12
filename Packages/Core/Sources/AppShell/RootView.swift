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
            // A read, not the values: they move with every sample, and only the subtitle and the memory line of
            // Processes show them. Read here, they would have the whole window built again every 3 seconds.
            processSample: { (store.processesSampledAt, store.memoryInUse) },
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
            // A read as well: sizes arrive one by one while the page is open, and only that page shows them.
            cleanup: CleanupActions(
                read: { (store.cleanup, store.buildOutputUsers) },
                load: { await store.loadCleanup(force: $0) },
                startDocker: { await store.startDocker() },
                clean: { target in
                    switch target {
                    case .cache(let entry): await store.clean(cache: entry)
                    case .output(let output): await store.clean(output: output)
                    case .unusedImages: await store.removeUnusedImages()
                    case .stoppedContainers: await store.removeStoppedContainers()
                    }
                }),
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

/// When the processes were last sampled, and the bytes of memory in use on the Mac then.
typealias ProcessSample = (sampledAt: Date?, memoryInUse: UInt64?)

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
    /// When the processes were last sampled and the memory in use on the Mac (`DashboardStore.processesSampledAt`,
    /// `memoryInUse`). Called only by the views that show them, so that a sample redraws those alone.
    let processSample: () -> ProcessSample
    let fetch: () -> Void
    /// Measures the worktrees at these paths again if their sizes are more than a minute old: the one that the
    /// inspector shows, and those of the sheet (`DashboardStore.refreshSizes(of:)`).
    let refreshSizes: ([String]) -> Void
    let refresh: () -> Void
    let removal: RemovalActions
    /// What Caches and Docker reads and asks of the store. Only the views of that page call `read`.
    let cleanup: CleanupActions

    @State private var sidebar: SidebarItem?
    @State private var selection: String?
    @State private var filter = ProjectFilter.all
    @State private var query = ""
    @State private var collapsed: Set<String> = []
    /// The sections of Processes that are open, for as long as the app runs.
    @State private var expanded: Set<String> = []
    /// The sections of Processes that have been on the page: only one that is new there is opened on its own.
    @State private var metSections: Set<String> = []
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
    /// What the last stop that did not go through left running, or why the last clean or start of Docker failed, for
    /// its alert.
    @State private var failure: (title: String, message: String)?
    /// A clean on Caches and Docker that waits for the user to confirm it.
    @State private var cleanupAsk: CleanupAsk?
    /// Whether Caches and Docker has been shown: the first time, it loads; after that only Refresh does.
    @State private var loadedCaches = false
    @FocusState private var searchIsFocused: Bool

    init(
        projects: [ProjectRow], ready: [WorktreeRow], scanState: ScanState, lastUpdated: Date?, isBusy: Bool,
        stopping: Set<Int32> = [], processSample: @escaping () -> ProcessSample = { (nil, nil) },
        fetch: @escaping () -> Void, refreshSizes: @escaping ([String]) -> Void = { _ in },
        refresh: @escaping () -> Void, removal: RemovalActions, cleanup: CleanupActions = .inert,
        sidebar: SidebarItem = .projects, selection: String? = nil, showsInspector: Bool = true, disk: StartupDisk?,
        readsDisk: Bool
    ) {
        self.projects = projects
        self.ready = ready
        self.scanState = scanState
        self.lastUpdated = lastUpdated
        self.isBusy = isBusy
        self.stopping = stopping
        self.processSample = processSample
        self.fetch = fetch
        self.refreshSizes = refreshSizes
        self.refresh = refresh
        self.removal = removal
        self.cleanup = cleanup
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
            // The whole of Processes, for its subtitle and for whether anything runs at all, once.
            let processes = sidebar == .processes ? ProcessesPage(projects: projects) : nil
            detail(processes)
                .navigationTitle(title)
                .modifier(
                    WindowSubtitle(text: subtitle, processes: processes, sampledAt: { processSample().sampledAt }))
                .searchable(text: $query, prompt: searchPrompt)
                .searchFocused($searchIsFocused)
                .toolbar { toolbar }
                .inspector(isPresented: inspectorIsShown) {
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
        .sheet(item: $cleanupAsk) { ask in
            CleanupSheet(
                model: CleanupSheetModel(ask), cancel: { cleanupAsk = nil }, confirm: { performCleanup(ask) })
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
            failure?.title ?? "",
            isPresented: Binding(get: { failure != nil }, set: { if !$0 { failure = nil } })
        ) {
        } message: {
            Text(failure?.message ?? "")
        }
        .onChange(of: projects) { _, projects in
            if case .repository(let path) = sidebar, !projects.contains(where: { $0.path == path }) {
                sidebar = .projects
            }
        }
        .onChange(of: sidebar, initial: true) { _, item in
            guard item == .caches, !loadedCaches else { return }
            loadedCaches = true
            Task { await cleanup.load(false) }
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

    /// `processes` is the whole of Processes when that is the page, `nil` otherwise.
    @ViewBuilder private func detail(_ processes: ProcessesPage?) -> some View {
        switch sidebar ?? .projects {
        case .readyToRemove:
            ScrollView {
                if !ready.isEmpty {
                    ReadyToRemoveSection(rows: ready, selection: $selection, actions: rowActions, capped: false).padding(20)
                }
            }
        case .processes:
            processesView(all: processes ?? ProcessesPage(projects: projects))
        case .caches:
            CachesView(
                actions: cleanup, query: query, ask: { cleanupAsk = CleanupAsk($0) }, startDocker: startDocker)
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

    /// The page for the search, or why there is nothing on it: nothing runs (or nothing was looked for yet), or the
    /// search matches none of it. `all` is the page with no search.
    @ViewBuilder private func processesView(all: ProcessesPage) -> some View {
        let page = query.isEmpty ? all : ProcessesPage(projects: projects, query: query)
        if !page.sections.isEmpty {
            ProcessesView(
                page: page, memoryInUse: { processSample().memoryInUse }, selection: $selection, expanded: $expanded,
                actions: rowActions
            )
            .onChange(of: page.sections.map(\.id), initial: true) { _, _ in meet(page.sections) }
        } else if all.sections.isEmpty {
            NothingRuns(sampledAt: { processSample().sampledAt })
        } else {
            ContentUnavailableView.search(text: query)
        }
    }

    /// Opens a section that the page has not shown before if it is among the first two; one that the user has opened
    /// or closed stays as they left it.
    private func meet(_ sections: [ProcessSection]) {
        let new = Set(sections.map(\.id)).subtracting(metSections)
        guard !new.isEmpty else { return }
        expanded.formUnion(sections.prefix(2).map(\.id).filter(new.contains))
        metSections.formUnion(new)
    }

    /// `showsInspector` as the page has it: the column stays away on a page without worktrees, and the setting stays as
    /// the user left it for the others.
    private var inspectorIsShown: Binding<Bool> {
        Binding(
            get: { SidebarItem.showsInspector(showsInspector, on: sidebar) },
            set: { showsInspector = SidebarItem.inspectorSetting(showsInspector, shown: $0, on: sidebar) })
    }

    /// The worktree that the inspector shows and Remove… acts on; none on a page without worktrees.
    private var selectedRow: WorktreeRow? {
        guard (sidebar ?? .projects).showsWorktrees else { return nil }
        return selection.flatMap(currentRow)
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
            self.failure = (
                RowPresenter.stopFailureTitle(failure), RowPresenter.stopFailureMessage(failure, groups: ask.groups)
            )
        }
    }

    // MARK: Cleaning

    private func performCleanup(_ ask: CleanupAsk) {
        cleanupAsk = nil
        let title = CleanupSheetModel(ask).failureTitle
        Task {
            guard let message = await cleanup.clean(ask.target) else { return }
            failure = (title, message)
        }
    }

    /// "Start and inspect", which asks nothing first: starting a VM deletes nothing.
    private func startDocker() {
        Task {
            guard let message = await cleanup.startDocker() else { return }
            failure = ("Could not start Docker", message)
        }
    }

    /// Refresh on Caches and Docker: everything listed and measured again.
    private func refreshCaches() {
        Task { await cleanup.load(true) }
    }

    // MARK: Commands

    private var commands: WindowCommands {
        let sidebar = $sidebar
        var commands = WindowCommands(
            showProjects: { sidebar.wrappedValue = .projects },
            showReadyToRemove: { sidebar.wrappedValue = .readyToRemove })
        let sheetIsOpen = ask != nil || cleanupAsk != nil
        if WindowCommands.offersRefresh(isBusy: isBusy, isScanning: scanState.isScanning, sheetIsOpen: sheetIsOpen) {
            commands.refresh = refresh
            commands.fetchAll = fetch
        }
        // Refresh there lists and measures the caches, which a scan or a fetch does not stand in the way of. A second
        // one while a load runs does nothing (`DashboardStore.loadCleanup`).
        if self.sidebar == .caches {
            commands.refresh = sheetIsOpen ? nil : { refreshCaches() }
        }
        if let row = selectedRow,
            WindowCommands.offersRemove(
                selectionIsRemovable: rowActions.canRemove(row), searchIsFocused: searchIsFocused,
                sheetIsOpen: sheetIsOpen, onProcesses: self.sidebar == .processes, onCaches: self.sidebar == .caches)
        {
            commands.removeSelection = { requestRemoval([row], fromRowButton: false) }
        }
        return commands
    }

    // MARK: Toolbar

    private var title: String {
        switch sidebar {
        case .readyToRemove: "Ready to remove"
        case .processes: "Processes"
        case .caches: "Caches and Docker"
        default: "Projects"
        }
    }

    private var searchPrompt: String {
        switch sidebar {
        case .processes: "Search processes"
        case .caches: "Search caches"
        default: "Search"
        }
    }

    /// Nothing on Ready to remove; on Processes `WindowSubtitle` says what runs instead.
    private var subtitle: String {
        if sidebar == .readyToRemove { return "" }
        if sidebar == .caches { return "Everything heavy that lives outside your project folders" }
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
            if sidebar == .caches {
                CachesRefreshButton(actions: cleanup, refresh: refreshCaches)
            } else {
                Button("Refresh", systemImage: "arrow.clockwise", action: refresh)
                    .help("Refresh")
                    .disabled(isBusy || scanState.isScanning)
            }
        }
        // A page without worktrees has no inspector to show.
        if (sidebar ?? .projects).showsWorktrees {
            ToolbarItem {
                Button("Inspector", systemImage: "sidebar.right") { showsInspector.toggle() }
                    .help("Inspector")
            }
        }
    }
}

/// What the Processes page says when it has no process to list: that nothing runs, but only once the processes were
/// sampled, and that they are being looked for until then.
///
/// The time of the sample is read here alone, as in `WindowSubtitle`: the first sample draws this view, not the page.
private struct NothingRuns: View {
    let sampledAt: () -> Date?

    var body: some View {
        if sampledAt() == nil {
            ProgressView("Looking for processes…")
        } else {
            ContentUnavailableView(
                "Nothing runs in your projects", systemImage: "waveform.path.ecg",
                description: Text("Processes that run in a project folder, or were started from one, show up here."))
        }
    }
}

/// The subtitle of the page: `text`, or on Processes the counts of `processes` and how long ago the processes were
/// sampled.
///
/// The time of the sample is read here alone, and the ten-second timeline that ages "updated just now" runs here: a
/// sample, or a tick, draws the subtitle again and leaves the page under it as it was.
private struct WindowSubtitle: ViewModifier {
    let text: String
    let processes: ProcessesPage?
    let sampledAt: () -> Date?

    func body(content: Content) -> some View {
        TimelineView(.periodic(from: .now, by: 10)) { context in
            content.navigationSubtitle(
                processes.map { ProcessesPresenter.subtitle($0, updated: sampledAt(), now: context.date) } ?? text)
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
