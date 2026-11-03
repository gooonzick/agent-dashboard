import AppKit
import CoreModels
import Dashboard
import Hosting
import SwiftUI

/// The right side: what is known of the selected worktree.
struct WorktreeInspector: View {
    let row: WorktreeRow
    let actions: RowActions

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                titleBlock
                openButtons
                gitSection
                if !row.groups.isEmpty { runningSection }
                if let size = row.size { diskSection(size) }
                if !row.worktree.isMain {
                    // Always the sheet: a worktree removed from here may be `.manual`, whose request is not merged.
                    Button("Remove worktree…", systemImage: "trash", role: .destructive) { actions.remove([row], false) }
                        .disabled(!actions.canRemove(row))
                        .controlSize(.large)
                        .frame(maxWidth: .infinity)
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: Head

    private var titleBlock: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(row.displayName).font(.title3.weight(.semibold)).lineLimit(2)
            if !row.worktree.isMain {
                Text("Worktree of \(row.repoName)").font(.callout).foregroundStyle(.secondary)
            }
            Text(row.worktree.path)
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .truncationMode(.middle)
                .textSelection(.enabled)
            HStack(spacing: 4) { StateChips(row: row) }.padding(.top, 2)
        }
    }

    private var openButtons: some View {
        HStack {
            Button("Terminal", systemImage: "terminal") { WorktreeOpener.openInTerminal(row) }
                .disabled(folderIsGone)
            Button("Finder", systemImage: "folder") { WorktreeOpener.revealInFinder(row) }
                .disabled(folderIsGone)
            if let url = row.review.webURL {
                Button(WorktreeOpener.openReviewTitle(row), systemImage: "arrow.up.right.square") {
                    NSWorkspace.shared.open(url)
                }
            }
        }
        .labelStyle(.titleAndIcon)
        .controlSize(.regular)
    }

    /// A worktree that git lists but whose folder is gone has nowhere to open.
    private var folderIsGone: Bool { row.eligibility == .missing }

    // MARK: Sections

    private var gitSection: some View {
        InspectorSection("Git") {
            InspectorLine("Upstream") {
                Text(row.status?.upstream ?? "—").lineLimit(1).truncationMode(.middle)
            }
            InspectorLine("Changes") { Text(RowPresenter.changesLine(row)) }
            InspectorLine("Last commit") {
                Text(row.status?.lastCommitDate.map(Self.relative) ?? "—")
            }
            InspectorLine(row.hosting == .github ? "Pull request" : "Merge request") {
                HStack(spacing: 6) {
                    ReviewChip(review: row.review)
                    if let number = row.review.number {
                        Text((row.hosting == .github ? "#" : "!") + String(number)).foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private var runningSection: some View {
        InspectorSection("Running", trailing: RowPresenter.memory(of: row.groups)) {
            ForEach(row.groups) { group in
                HStack(spacing: 6) {
                    Image(systemName: group.kind == .agentSession ? "sparkle" : "circle.fill")
                        .imageScale(group.kind == .agentSession ? .medium : .small)
                        .foregroundStyle(group.kind == .agentSession ? Color.orange : Color.secondary)
                        .frame(width: 14)
                    Text(group.title).lineLimit(1)
                    Spacer()
                    Text(SizeFormat.memory(group.totalFootprint)).monospacedDigit().foregroundStyle(.secondary)
                }
                .font(.callout)
            }
        }
    }

    private func diskSection(_ size: SizeInfo) -> some View {
        InspectorSection("Disk") {
            Text("\(SizeFormat.disk(size.privateBytes)) frees on removal, of \(SizeFormat.disk(size.apparentBytes)) on disk")
                .font(.callout)
            if let note = RowPresenter.diskNote(size) {
                Text(note).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private static func relative(_ date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.dateTimeStyle = .named
        formatter.unitsStyle = .full
        return formatter.localizedString(for: date, relativeTo: Date())
    }
}

private struct InspectorSection<Content: View>: View {
    let title: String
    var trailing: String?
    @ViewBuilder let content: Content

    init(_ title: String, trailing: String? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.trailing = trailing
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(title).font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
                Spacer()
                if let trailing { Text(trailing).font(.subheadline).monospacedDigit().foregroundStyle(.secondary) }
            }
            content
        }
    }
}

private struct InspectorLine<Value: View>: View {
    let label: String
    @ViewBuilder let value: Value

    init(_ label: String, @ViewBuilder value: () -> Value) {
        self.label = label
        self.value = value()
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label).foregroundStyle(.secondary)
            Spacer(minLength: 12)
            value
        }
        .font(.callout)
    }
}
