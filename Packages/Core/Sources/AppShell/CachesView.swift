import Cleanup
import CoreModels
import Dashboard
import SwiftUI

/// What the window asks of the store for Caches and Docker.
///
/// `read` is called only by the views of that page (`CachesView`, and the Refresh it puts in the toolbar): a size that
/// arrives, or a clean that ends, draws them and leaves the window, Projects and Processes as they were.
struct CleanupActions {
    /// The store's `cleanup` and `buildOutputUsers`.
    var read: @MainActor () -> (state: CleanupState, users: [String: String])
    /// `DashboardStore.loadCleanup(force:)`.
    var load: @MainActor (_ force: Bool) async -> Void
    /// "Start and inspect": what went wrong, or `nil`.
    var startDocker: @MainActor () async -> String?
    /// What the sheet confirmed: what went wrong, or `nil`.
    var clean: @MainActor (_ target: CleanupTarget) async -> String?

    /// Shows `state` and does nothing: for the renders.
    static func showing(_ state: CleanupState, users: [String: String] = [:]) -> CleanupActions {
        CleanupActions(read: { (state, users) }, load: { _ in }, startDocker: { nil }, clean: { _ in nil })
    }

    static var inert: CleanupActions { showing(CleanupState()) }
}

/// The detail of Caches and Docker: how much the caches, the build outputs and the Docker VM take, the bar of what
/// takes it, and the four lists with a button to clean each row, which asks first (`CleanupSheet`).
///
/// Until the first load is through, a spinner: a total of nothing would say the disk is clean.
struct CachesView: View {
    let actions: CleanupActions
    let query: String
    /// Opens the sheet that confirms a clean.
    let ask: (CleanupTarget) -> Void
    let startDocker: () -> Void

    var body: some View {
        let (state, users) = actions.read()
        if state.loadedAt == nil {
            ProgressView("Looking for caches…").frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            let page = CachesPage(state: state, users: users, query: query)
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    VStack(alignment: .leading, spacing: 10) {
                        Headline(page: page)
                        SegmentBar(segments: page.bar, colour: Self.colour, size: Self.disk)
                    }
                    HStack(alignment: .top, spacing: 20) {
                        VStack(alignment: .leading, spacing: 24) {
                            DockerBlock(docker: page.docker, start: startDocker) { id in
                                switch id {
                                case CleanupState.unusedImagesID: ask(.unusedImages(page.docker.unusedImages))
                                case CleanupState.stoppedContainersID:
                                    ask(.stoppedContainers(page.docker.stoppedContainers))
                                default: break
                                }
                            }
                            BuildOutputsBlock(rows: page.outputs, query: query) { row in
                                if let output = state.buildOutputs.first(where: { $0.path == row.id }) {
                                    ask(.output(output))
                                }
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                        VStack(alignment: .leading, spacing: 24) {
                            CachesBlock(
                                title: "Package caches",
                                caption: "Safe to clear: packages are downloaded again when needed.",
                                rows: page.packages, query: query, clean: cleanCache(in: state))
                            if !page.xcode.isEmpty || !query.isEmpty {
                                CachesBlock(
                                    title: "Xcode", caption: nil, rows: page.xcode, query: query,
                                    clean: cleanCache(in: state))
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                    }
                }
                .padding(20)
            }
        }
    }

    private func cleanCache(in state: CleanupState) -> (CleanupRow) -> Void {
        { row in
            if let entry = state.caches.first(where: { $0.id == row.id }) { ask(.cache(entry)) }
        }
    }

    /// The categories in turn, and grey for `Other`, which is always last.
    static func colour(of segment: MemorySegment, at index: Int) -> Color {
        guard segment.label != "Other" else { return .gray }
        let colours: [Color] = [.blue, .teal, .indigo, .purple, .orange, .green, .pink]
        return colours[index % colours.count]
    }

    static func disk(_ bytes: UInt64) -> String { SizeFormat.disk(Int64(clamping: bytes)) }
}

// MARK: Headline

/// `113 GB in caches, toolchains and VMs · about 70 GB can be cleaned safely`; a spinner for the amount while a row is
/// still to be measured, since a part of the total would read as all of it.
private struct Headline: View {
    let page: CachesPage

    var body: some View {
        let headline = CachesPresenter.headline(page)
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            if page.isMeasured {
                Text(headline.total).font(.largeTitle).monospacedDigit()
            } else {
                ProgressView().controlSize(.small).accessibilityLabel("Measuring")
            }
            Text(headline.detail).foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }
}

// MARK: Blocks

/// A heading with a line under it that says what the rows are, and the rows on a card.
private struct Block<Rows: View>: View {
    let title: String
    let caption: String?
    @ViewBuilder let rows: Rows

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                if let caption {
                    Text(caption).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            VStack(alignment: .leading, spacing: 0) { rows }
                .background(.background.secondary, in: .rect(cornerRadius: 10))
                .overlay { RoundedRectangle(cornerRadius: 10).strokeBorder(.separator) }
        }
    }
}

/// The line of a block that has no row: nothing was found, or nothing matches the search.
private struct NoRows: View {
    let text: String

    var body: some View {
        Text(text)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// The package caches, or Xcode.
private struct CachesBlock: View {
    let title: String
    let caption: String?
    let rows: [CleanupRow]
    let query: String
    let clean: (CleanupRow) -> Void

    var body: some View {
        Block(title: title, caption: caption) {
            if rows.isEmpty {
                NoRows(text: query.isEmpty ? "None on this Mac" : "No match for “\(query)”")
            }
            ForEach(rows) { row in
                CleanupRowView(row: row, symbol: Self.symbol(of: row)) { clean(row) }
                if row.id != rows.last?.id { Divider() }
            }
        }
    }

    /// Xcode's two rows tell themselves apart by their symbol. The package caches would all have the same box, which
    /// says nothing and takes width from the path, so they have none.
    private static func symbol(of row: CleanupRow) -> String? {
        switch row.id {
        case CleanupSheetModel.derivedDataID: "hammer"
        case "simulators": "iphone"
        default: nil
        }
    }
}

/// The build outputs in the worktrees: the first five, and the others on `Show all N`.
private struct BuildOutputsBlock: View {
    let rows: [CleanupRow]
    let query: String
    let clean: (CleanupRow) -> Void

    @State private var expanded = false

    private static let collapsedLimit = 5

    var body: some View {
        let shown = expanded ? rows : Array(rows.prefix(Self.collapsedLimit))
        let toggle = rows.count > Self.collapsedLimit ? (expanded ? "Show less" : "Show all \(rows.count)") : nil
        Block(
            title: "Build outputs in projects",
            caption: "Rebuilt on the next build. Folders with uncommitted work are never touched."
        ) {
            if rows.isEmpty {
                NoRows(text: query.isEmpty ? "No build outputs in your projects" : "No match for “\(query)”")
            }
            ForEach(shown) { row in
                // Every build output is a folder: the same symbol on each says nothing.
                CleanupRowView(row: row, symbol: nil) { clean(row) }
                if row.id != shown.last?.id || toggle != nil { Divider() }
            }
            if let toggle {
                Button { expanded.toggle() } label: {
                    HStack(spacing: 6) {
                        Text(toggle)
                        Image(systemName: expanded ? "chevron.up" : "chevron.down").imageScale(.small)
                        Spacer(minLength: 0)
                    }
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
            }
        }
    }
}

/// A build output or a cache: what it is, where, what it takes, and its button.
private struct CleanupRowView: View {
    let row: CleanupRow
    let symbol: String?
    let clean: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            if let symbol {
                Image(systemName: symbol).foregroundStyle(.secondary).frame(width: 18).accessibilityHidden(true)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(row.title).lineLimit(1).truncationMode(.middle)
                Text(row.subtitle)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            // The path before the reason: the reason is in the help as well, the path nowhere else.
            .layoutPriority(1)
            Spacer(minLength: 12)
            if let note = row.note { StateChipView(chip: StateChip(text: note, tone: .neutral)) }
            // Said in the row, not only in the help: a button that is off for no visible reason looks broken. Whole or
            // not at all: in a narrow column `Non…` says nothing, and the help still has it.
            if !row.isWorking, let reason = row.disabledReason {
                ViewThatFits(in: .horizontal) {
                    Text(reason).font(.caption).foregroundStyle(.secondary).lineLimit(1).fixedSize()
                    Color.clear.frame(width: 0, height: 0)
                }
            }
            SizeText(bytes: row.size)
            ActionButton(
                title: row.action, isEnabled: row.isEnabled, isWorking: row.isWorking, help: row.disabledReason,
                label: "\(row.action) \(row.title)", action: clean)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }
}

/// A size, or a small spinner in its place while it is measured.
private struct SizeText: View {
    let bytes: UInt64?

    var body: some View {
        Group {
            if let bytes {
                Text(CachesView.disk(bytes)).monospacedDigit()
            } else {
                ProgressView().controlSize(.mini).accessibilityLabel("Measuring")
            }
        }
        .frame(minWidth: 56, alignment: .trailing)
    }
}

/// The button of a row, a spinner in its place while what it does is under way, and when it is off, the reason in its
/// help.
private struct ActionButton: View {
    let title: String
    let isEnabled: Bool
    let isWorking: Bool
    let help: String?
    /// What VoiceOver reads: `Clean Homebrew`.
    let label: String
    let action: () -> Void

    var body: some View {
        if isWorking {
            ProgressView().controlSize(.small).accessibilityLabel("\(label), under way")
        } else {
            // A button is never cut: `Delete Un…` says nothing. The reason beside it gives way instead.
            let button = Button(title, action: action)
                .controlSize(.small)
                .fixedSize()
                .disabled(!isEnabled)
                .accessibilityLabel(label)
            // No tooltip at all rather than an empty one.
            if let help { button.help(help) } else { button }
        }
    }
}

// MARK: Docker

/// The Docker card: the VM and whether it runs, its disk, and while it runs, what it holds and the containers.
private struct DockerBlock: View {
    let docker: DockerSection
    let start: () -> Void
    /// Asks to remove what the row of `id` names (`CleanupState.unusedImagesID`, `stoppedContainersID`).
    let remove: (String) -> Void

    var body: some View {
        Block(title: "Docker", caption: caption) {
            if let message = docker.message {
                problem(message)
            } else if let title = docker.title {
                runtime(title)
                ForEach(docker.rows) { row in
                    Divider()
                    DockerRowView(row: row) { remove(row.id) }
                }
                if !docker.containers.isEmpty {
                    Divider()
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(docker.containers) { ContainerLine(container: $0) }
                    }
                    .padding(.leading, Self.indent)
                    .padding(.trailing, 12)
                    .padding(.vertical, 8)
                }
            } else {
                // Docker has not been asked yet.
                ProgressView().controlSize(.small).padding(12).frame(maxWidth: .infinity)
            }
        }
    }

    /// Where the text of the card starts: past the symbol of the VM.
    static let indent: CGFloat = 12 + 18 + 12

    private var caption: String? {
        guard let runtime = docker.runtime else { return nil }
        let name =
            switch runtime.kind {
            case .colima: "colima"
            case .desktop: "Docker Desktop"
            case .orbstack: "OrbStack"
            }
        return "\(name) runs Docker inside a VM, so images and volumes are only visible while it runs."
    }

    private func runtime(_ title: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "shippingbox").foregroundStyle(.secondary).frame(width: 18).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(title).lineLimit(1)
                    RunningCapsule(isRunning: docker.isRunning)
                }
                HStack(spacing: 4) {
                    Text(docker.line ?? "").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    if docker.diskSize == nil {
                        ProgressView().controlSize(.mini).accessibilityLabel("Measuring the disk")
                    }
                }
            }
            Spacer(minLength: 12)
            if docker.isStarting {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("Starting…").foregroundStyle(.secondary)
                }
            } else if !docker.isRunning {
                Button("Start and inspect", action: start).controlSize(.small)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private func problem(_ message: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "shippingbox").foregroundStyle(.secondary).frame(width: 18).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text(message)
                if let explanation {
                    Text(explanation).font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .accessibilityElement(children: .combine)
    }

    /// Why there is nothing to show, under what is wrong.
    private var explanation: String? {
        switch docker.status {
        case .notInstalled: "There is no docker command on this Mac."
        case .unknownContext: "Only colima, Docker Desktop and OrbStack can be inspected."
        case .notAnswering: "It may be busy; Refresh asks again."
        case .runtime, nil: nil
        }
    }
}

/// `Running` or `Stopped`, with a dot.
private struct RunningCapsule: View {
    let isRunning: Bool

    var body: some View {
        HStack(spacing: 4) {
            Circle()
                .fill(isRunning ? AnyShapeStyle(.green) : AnyShapeStyle(.secondary))
                .frame(width: 6, height: 6)
            Text(isRunning ? "Running" : "Stopped")
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 7)
        .padding(.vertical, 2)
        .background(.quaternary, in: .capsule)
        .accessibilityElement(children: .combine)
    }
}

/// Images, Containers, Volumes or Build cache.
private struct DockerRowView: View {
    let row: DockerRow
    let remove: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Text(row.title).frame(minWidth: 84, alignment: .leading)
            Text(row.detail).monospacedDigit().foregroundStyle(.secondary).lineLimit(1)
            Spacer(minLength: 12)
            if let note = row.note { StateChipView(chip: StateChip(text: note, tone: .neutral)) }
            // Said in the row, not only in the help: why an image a stopped container has is not unused is not obvious.
            if !row.isWorking, let reason = row.disabledReason {
                Text(reason).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }
            if let action = row.action {
                ActionButton(
                    title: action, isEnabled: row.isEnabled, isWorking: row.isWorking, help: row.disabledReason,
                    label: action, action: remove)
            }
        }
        .padding(.leading, DockerBlock.indent)
        .padding(.trailing, 12)
        .padding(.vertical, 8)
    }
}

/// A container: whether it runs, its name, its image, and the folder of its compose project or `—`.
private struct ContainerLine: View {
    let container: DockerContainerLine

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(container.isRunning ? AnyShapeStyle(.green) : AnyShapeStyle(.tertiary))
                .frame(width: 6, height: 6)
                .accessibilityLabel(container.isRunning ? "Running" : "Stopped")
            Text(container.name).lineLimit(1).truncationMode(.middle)
            Text(container.image)
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 8)
            Text(container.project).font(.caption).foregroundStyle(.secondary).lineLimit(1)
        }
        .font(.callout)
        .accessibilityElement(children: .combine)
    }
}

// MARK: Toolbar

/// Refresh on Caches and Docker: lists everything again and measures it all anew. Off while a load runs. The one view
/// of the toolbar that reads the cleanup state, so the toolbar around it is not built again with every size.
struct CachesRefreshButton: View {
    let actions: CleanupActions
    let refresh: () -> Void

    var body: some View {
        Button("Refresh", systemImage: "arrow.clockwise", action: refresh)
            .help("Refresh")
            .disabled(actions.read().state.isLoading)
    }
}
