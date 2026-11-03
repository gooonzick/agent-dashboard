import CoreModels
import Dashboard
import Safety
import SwiftUI

/// The block above the table: the worktrees that are ready to go, and what removing them frees.
///
/// `Remove N…` and `Stop and remove…` always open the sheet. The per-row `Remove` skips it when the user has said
/// "Don't ask again" (`RowActions.remove` decides).
struct ReadyToRemoveSection: View {
    let rows: [WorktreeRow]
    @Binding var selection: String?
    let actions: RowActions

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
            Divider()
            ForEach(rows) { row in
                ReadyRow(row: row, isSelected: selection == row.id, actions: actions)
                    .contentShape(.rect)
                    .onTapGesture { selection = row.id }
                    .contextMenu { RowContextMenu(row: row, actions: actions) }
                    .accessibilityAddTraits(selection == row.id ? [.isButton, .isSelected] : .isButton)
                if row.id != rows.last?.id { Divider().padding(.leading, 38) }
            }
        }
        .background(.background.secondary, in: .rect(cornerRadius: 10))
        .overlay { RoundedRectangle(cornerRadius: 10).strokeBorder(.separator) }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "sparkles").foregroundStyle(.green).imageScale(.large)
            VStack(alignment: .leading, spacing: 1) {
                Text("Ready to remove").font(.headline)
                Text(hint).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button("Remove \(rows.count)…") { actions.remove(rows, false) }
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
        HStack(spacing: 10) {
            Image(systemName: "arrow.triangle.branch").foregroundStyle(.secondary).frame(width: 18)
            VStack(alignment: .leading, spacing: 1) {
                Text(row.displayName).lineLimit(1)
                Text(row.repoName + " · " + RowPresenter.branchLine(row.status, branch: row.worktree.branch))
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            ReviewChip(review: row.review)
            if let text = RowPresenter.runningText(row.groups) {
                RunningCell(groups: row.groups).help(text).foregroundStyle(.secondary)
            }
            Text(row.size.realSizeText).monospacedDigit().foregroundStyle(.secondary)
                .frame(minWidth: 70, alignment: .trailing)
            Group {
                if needsStopping {
                    Button("Stop and remove…") { actions.remove([row], false) }
                } else {
                    Button("Remove") { actions.remove([row], true) }
                }
            }
            .disabled(!actions.canRemove(row))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(isSelected ? AnyShapeStyle(.selection.opacity(0.25)) : AnyShapeStyle(.clear))
    }

    private var needsStopping: Bool {
        if case .ready(let stop) = row.eligibility { stop } else { false }
    }
}
