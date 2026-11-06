import AppKit
import CoreModels
import Dashboard
import SwiftUI

/// The detail of Processes: the memory of the worktrees as one bar, then each worktree that runs something with its
/// processes under it.
struct ProcessesView: View {
    let page: ProcessesPage
    /// The memory in use on the whole Mac, `nil` while it is not known. A read that only the memory line calls: it
    /// changes with every sample, and the table need not be built again for it.
    let memoryInUse: () -> UInt64?
    @Binding var selection: String?
    /// The sections that are open (`MainView` opens the first two it meets).
    @Binding var expanded: Set<String>
    let actions: RowActions

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            MemoryByProject(page: page, memoryInUse: memoryInUse, selection: $selection)
                .padding(.horizontal, Self.margin)
                .padding(.bottom, 16)
            ProcessesTable(page: page, selection: $selection, expanded: $expanded, actions: actions)
                .contentMargins(.horizontal, Self.margin, for: .scrollContent)
        }
        .padding(.top, Self.margin)
    }

    private static let margin: CGFloat = 20

    /// The colour of the segment at `index` of the bar: the worktrees in turn, and grey for `other`.
    static func colour(of segment: MemorySegment, at index: Int) -> Color {
        guard segment.worktree != nil else { return .gray }
        let colours: [Color] = [.blue, .indigo, .teal, .purple, .pink]
        return colours[index % colours.count]
    }
}

// MARK: Memory by project

/// The heading, the bar and its legend. A segment or a name of the legend selects its worktree.
private struct MemoryByProject: View {
    let page: ProcessesPage
    let memoryInUse: () -> UInt64?
    @Binding var selection: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text("Memory by project").font(.headline)
                Spacer()
                if let inUse = ProcessesPresenter.inUse(page, of: memoryInUse()) {
                    Text(inUse).font(.callout).foregroundStyle(.secondary)
                }
            }
            bar
            legend
        }
    }

    private var bar: some View {
        GeometryReader { proxy in
            let total = page.bar.reduce(0.0) { $0 + Double($1.bytes) }
            let room = max(0, proxy.size.width - Self.gap * CGFloat(max(page.bar.count - 1, 0)))
            HStack(spacing: Self.gap) {
                ForEach(Array(page.bar.enumerated()), id: \.offset) { index, segment in
                    Button {
                        if let worktree = segment.worktree { selection = worktree }
                    } label: {
                        RoundedRectangle(cornerRadius: 3)
                            .fill(ProcessesView.colour(of: segment, at: index))
                            .frame(width: total > 0 ? room * Double(segment.bytes) / total : 0)
                    }
                    .buttonStyle(.plain)
                    .disabled(segment.worktree == nil)
                }
            }
        }
        .frame(height: 8)
        // The legend says the same, in words and as buttons.
        .accessibilityHidden(true)
    }

    private var legend: some View {
        HStack(spacing: 16) {
            ForEach(Array(page.bar.enumerated()), id: \.offset) { index, segment in
                let entry = HStack(spacing: 5) {
                    Circle().fill(ProcessesView.colour(of: segment, at: index)).frame(width: 8, height: 8)
                    Text(segment.label)
                    Text(SizeFormat.memory(segment.bytes)).monospacedDigit().foregroundStyle(.secondary)
                }
                .lineLimit(1)
                if let worktree = segment.worktree {
                    Button { selection = worktree } label: { entry.contentShape(.rect) }
                        .buttonStyle(.plain)
                } else {
                    entry.accessibilityElement(children: .combine)
                }
            }
        }
        .font(.callout)
    }

    private static let gap: CGFloat = 2
}

// MARK: Table

/// One line of the table: the head of a section, or one of its processes.
private struct ProcessNode: Identifiable {
    let section: ProcessSection
    /// `nil` for the head of the section.
    let line: ProcessLine?
    var id: String { line?.id ?? section.id }
}

/// The worktrees, each with its processes under it. A line selects its worktree, which the inspector then shows.
private struct ProcessesTable: View {
    let page: ProcessesPage
    @Binding var selection: String?
    @Binding var expanded: Set<String>
    let actions: RowActions
    /// The line that is selected in the table; `selection` is its worktree.
    @State private var selected: String?

    init(page: ProcessesPage, selection: Binding<String?>, expanded: Binding<Set<String>>, actions: RowActions) {
        self.page = page
        _selection = selection
        _expanded = expanded
        self.actions = actions
        _selected = State(initialValue: selection.wrappedValue)
    }

    var body: some View {
        Table(of: ProcessNode.self, selection: $selected) {
            TableColumn("Process") { node in ProcessNameCell(node: node) }
                .width(min: 220, ideal: 560)
            TableColumn("Kind") { node in Text(node.line?.kind ?? "").foregroundStyle(.secondary).lineLimit(1) }
                .width(min: 80, ideal: 100)
            TableColumn("PID") { node in
                if let line = node.line {
                    Text(line.pid.map(String.init) ?? "–").monospaced().foregroundStyle(.secondary)
                }
            }
            .width(min: 50, ideal: 60)
            TableColumn("Port") { node in
                if let line = node.line { PortCell(ports: line.ports) }
            }
            .width(min: 60, ideal: 80)
            TableColumn("Uptime") { node in
                if let line = node.line { UptimeCell(line: line) }
            }
            .width(min: 60, ideal: 80)
            TableColumn("Memory") { node in
                Text(SizeFormat.memory(node.line?.memory ?? node.section.memory))
                    .font(node.line == nil ? .headline : nil)
                    .monospacedDigit()
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .width(min: 60, ideal: 70)
            .alignment(.trailing)
            TableColumn("") { node in StopCell(node: node, actions: actions) }
                .width(20)
        } rows: {
            ForEach(page.sections) { section in
                DisclosureTableRow(ProcessNode(section: section, line: nil), isExpanded: expansion(of: section.id)) {
                    ForEach(section.lines) { TableRow(ProcessNode(section: section, line: $0)) }
                }
            }
        }
        .onChange(of: selected) { _, id in
            let worktree = id.flatMap(worktree(of:))
            if worktree != selection { selection = worktree }
        }
        // A worktree selected from the bar, or on another page: its section, unless a line of it is selected already.
        .onChange(of: selection) { _, path in
            if selected.flatMap(worktree(of:)) != path { selected = path }
        }
    }

    /// The worktree of the section or line `id`.
    private func worktree(of id: String) -> String? {
        page.sections.first { $0.id == id || $0.lines.contains { $0.id == id } }?.id
    }

    private func expansion(of id: String) -> Binding<Bool> {
        Binding(
            get: { expanded.contains(id) },
            set: { if $0 { expanded.insert(id) } else { expanded.remove(id) } })
    }
}

/// The head of a section, its folder, name and count; or a process with the symbol of its kind.
private struct ProcessNameCell: View {
    let node: ProcessNode

    var body: some View {
        HStack(spacing: 6) {
            if let line = node.line {
                Image(systemName: line.symbol)
                    .foregroundStyle(line.groups.first?.kind == .agentSession ? Color.orange : Color.secondary)
                    .frame(width: 16)
                Text(line.title).lineLimit(1).truncationMode(.tail)
            } else {
                Image(systemName: "folder").foregroundStyle(.blue).frame(width: 16)
                Text(node.section.title).font(.headline).lineLimit(1).truncationMode(.middle).layoutPriority(1)
                Text(node.section.subtitle).foregroundStyle(.secondary).lineLimit(1)
            }
        }
    }
}

/// The first port as a capsule that opens it in the browser, with how many more there are; `—` for none.
private struct PortCell: View {
    let ports: [UInt16]

    var body: some View {
        if let port = ports.first, let url = URL(string: "http://localhost:\(port)") {
            // Verbatim: a port is not a number to group, `:4.200`.
            let text = ports.count > 1 ? ":\(port) +\(ports.count - 1)" : ":\(port)"
            Button { NSWorkspace.shared.open(url) } label: {
                Label { Text(verbatim: text) } icon: { Image(systemName: "arrow.up.right.square") }
                    .font(.callout.monospaced())
                    .lineLimit(1)
                    .foregroundStyle(.blue)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(.blue.quaternary, in: .capsule)
            }
            .buttonStyle(.plain)
            .help("Open \(url.absoluteString)")
            .accessibilityLabel("Open localhost:\(port)")
        } else {
            Text("—").foregroundStyle(.secondary)
        }
    }
}

/// How long the process has run, anew every minute; a session that has run for days stands out. `—` for the merged
/// line.
private struct UptimeCell: View {
    let line: ProcessLine

    var body: some View {
        // From now rather than `.everyMinute`, whose first date is the start of the minute: a process would read a
        // minute younger than it is.
        TimelineView(.periodic(from: .now, by: 60)) { context in
            if let uptime = line.uptime(now: context.date) {
                if uptime.isLong {
                    Label(uptime.text, systemImage: "timer")
                        .font(.callout)
                        .lineLimit(1)
                        .foregroundStyle(.orange)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2)
                        .background(.orange.quaternary, in: .capsule)
                } else {
                    Text(uptime.text).lineLimit(1)
                }
            } else {
                Text("—").foregroundStyle(.secondary)
            }
        }
    }
}

/// The Stop of a line, or of the whole worktree on the head of its section; a spinner in its place while all that it
/// would stop is being stopped. The same dialog and the same rules as in the inspector.
private struct StopCell: View {
    let node: ProcessNode
    let actions: RowActions

    var body: some View {
        let row = node.section.row
        let groups = node.line?.groups ?? row.groups
        let title = node.line?.title ?? node.section.title
        Group {
            if !groups.isEmpty, groups.allSatisfy({ actions.stopping.contains($0.id) }) {
                ProgressView().controlSize(.small).accessibilityLabel("Stopping \(title)")
            } else {
                let label = node.line == nil ? "Stop all processes in \(title)" : "Stop \(title)"
                Button("Stop", systemImage: "stop.circle") { actions.stop(groups, row) }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
                    .help(label)
                    .accessibilityLabel(label)
                    .disabled(!groups.contains { actions.canStop($0, of: row) })
            }
        }
        .frame(width: 16, height: 16)
    }
}
