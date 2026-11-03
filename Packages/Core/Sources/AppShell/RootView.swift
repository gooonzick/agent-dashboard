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
        MainView(
            projects: store.projects, ready: store.readyToRemove, scanState: store.scanState,
            lastUpdated: store.lastUpdated, isBusy: working || store.isStarting,
            fetch: { run { await store.fetchAll() } },
            // A scan, then git and the hosts anew for every repository: the one call that does all of it. It does
            // nothing while another `start()` runs, which is why the button is off then.
            refresh: { run { await store.start() } }
        )
        .background(WindowVisibility { store.isWindowVisible = $0 })
        .task { run { await store.start() } }
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

/// The sidebar, the table and the inspector, from plain values: what the previews and the renders feed it.
struct MainView: View {
    let projects: [ProjectRow]
    let ready: [WorktreeRow]
    let scanState: ScanState
    let lastUpdated: Date?
    let isBusy: Bool
    let fetch: () -> Void
    let refresh: () -> Void

    @State private var sidebar: SidebarItem?
    @State private var selection: String?
    @State private var filter = ProjectFilter.all
    @State private var query = ""
    @State private var collapsed: Set<String> = []
    @State private var showsInspector: Bool
    @State private var disk: StartupDisk?
    @State private var now = Date()

    init(
        projects: [ProjectRow], ready: [WorktreeRow], scanState: ScanState, lastUpdated: Date?, isBusy: Bool,
        fetch: @escaping () -> Void, refresh: @escaping () -> Void, sidebar: SidebarItem = .projects,
        selection: String? = nil, showsInspector: Bool = true, disk: StartupDisk? = StartupDisk.read()
    ) {
        self.projects = projects
        self.ready = ready
        self.scanState = scanState
        self.lastUpdated = lastUpdated
        self.isBusy = isBusy
        self.fetch = fetch
        self.refresh = refresh
        _sidebar = State(initialValue: sidebar)
        _selection = State(initialValue: selection)
        _showsInspector = State(initialValue: showsInspector)
        _disk = State(initialValue: disk)
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
                .toolbar { toolbar }
                .inspector(isPresented: $showsInspector) {
                    Group {
                        if let row = selectedRow { WorktreeInspector(row: row) } else { Color.clear }
                    }
                    .inspectorColumnWidth(min: 280, ideal: 320, max: 420)
                }
        }
        .onChange(of: projects) { _, projects in
            if case .repository(let path) = sidebar, !projects.contains(where: { $0.path == path }) {
                sidebar = .projects
            }
        }
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(30))
                now = Date()
                disk = StartupDisk.read()
            }
        }
    }

    // MARK: Detail

    @ViewBuilder private var detail: some View {
        switch sidebar ?? .projects {
        case .readyToRemove:
            ScrollView {
                if !ready.isEmpty {
                    ReadyToRemoveSection(rows: ready, selection: $selection).padding(16)
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
            filter: $filter, selection: $selection, collapsed: $collapsed)
    }

    private var selectedRow: WorktreeRow? {
        guard let selection else { return nil }
        for project in projects {
            if project.main.id == selection { return project.main }
            if let row = project.worktrees.first(where: { $0.id == selection }) { return row }
        }
        return nil
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
        ToolbarItemGroup {
            if isBusy || scanState.isScanning { ProgressView().controlSize(.small) }
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
