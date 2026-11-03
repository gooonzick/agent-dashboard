import CoreModels
import Dashboard
import Safety
import AppKit
import SwiftUI

/// The block above the table: the worktrees that are ready to go, and what removing them frees.
///
/// `Remove N…` and `Stop and remove…` always open the sheet. The per-row `Remove` skips it when the user has said
/// "Don't ask again" (`RowActions.remove` decides).
struct ReadyToRemoveSection: View {
    let rows: [WorktreeRow]
    @Binding var selection: String?
    let actions: RowActions

    /// Whether every row is shown rather than the first few (Ruling 66).
    @State private var expanded = false

    private var listing: ReadyListing { ReadyListing(rows, expanded: expanded) }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // The header and `Remove N…` count and act on every row, shown or not.
            header
            VStack(alignment: .leading, spacing: 0) {
                ForEach(listing.shown) { row in
                    ReadyRow(row: row, isSelected: selection == row.id, actions: actions)
                        .contentShape(.rect)
                        .onTapGesture { selection = row.id }
                        .contextMenu { RowContextMenu(row: row, actions: actions) }
                        .accessibilityAddTraits(selection == row.id ? [.isButton, .isSelected] : .isButton)
                    if row.id != listing.shown.last?.id || listing.toggleTitle != nil { Divider() }
                }
                if let title = listing.toggleTitle {
                    Button { expanded.toggle() } label: {
                        HStack(spacing: 6) {
                            Text(title)
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
            .background(.background.secondary, in: .rect(cornerRadius: 10))
            .overlay { RoundedRectangle(cornerRadius: 10).strokeBorder(.separator) }
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Ready to remove").font(.headline)
                Text(hint).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button(listing.removeTitle) { actions.remove(rows, false) }
                .buttonStyle(.borderedProminent)
                .disabled(rows.isEmpty || !rows.allSatisfy(actions.canRemove))
        }
    }

    private var hint: String {
        let base = "MR merged, everything pushed, nothing unsaved"
        let measured = rows.compactMap(\.size)
        guard !measured.isEmpty else { return base }
        return base + " · frees " + SizeFormat.disk(measured.reduce(0) { $0 + $1.privateBytes })
    }
}

private struct ReadyRow: View {
    let row: WorktreeRow
    let isSelected: Bool
    let actions: RowActions

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "arrow.triangle.branch").foregroundStyle(.secondary).frame(width: 18)
            VStack(alignment: .leading, spacing: 1) {
                Text(row.displayName).lineLimit(1)
                Text(row.repoName + " · " + RowPresenter.branchLine(row.status, branch: row.worktree.branch))
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 12)
            ReviewChip(review: row.review)
            if let text = RowPresenter.runningText(row.groups) {
                RunningCell(groups: row.groups).help(text).foregroundStyle(.secondary)
            }
            Text(row.size.realSizeText).monospacedDigit().foregroundStyle(.secondary)
                .frame(minWidth: 56, alignment: .trailing)
            Group {
                if needsStopping {
                    Button("Stop and remove…") { actions.remove([row], false) }
                } else {
                    Button("Remove") { actions.remove([row], true) }
                }
            }
            .controlSize(.small)
            .disabled(!actions.canRemove(row))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        // Opaque, so that it reads the same in light and in dark.
        .background(isSelected ? Color(nsColor: .unemphasizedSelectedContentBackgroundColor) : .clear)
    }

    private var needsStopping: Bool {
        if case .ready(let stop) = row.eligibility { stop } else { false }
    }
}
