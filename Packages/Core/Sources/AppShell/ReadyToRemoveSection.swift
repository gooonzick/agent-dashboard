import CoreModels
import Dashboard
import Safety
import SwiftUI

/// The block above the table: the worktrees that are ready to go, and what removing them frees.
///
/// The buttons are in place and do nothing yet; the sheet that they open comes with the removal.
struct ReadyToRemoveSection: View {
    let rows: [WorktreeRow]
    @Binding var selection: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
            Divider()
            ForEach(rows) { row in
                ReadyRow(row: row, isSelected: selection == row.id)
                    .contentShape(.rect)
                    .onTapGesture { selection = row.id }
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
            // Task 14 wires the three buttons of this block to the removal sheet; until then they do nothing and are off.
            Button("Remove \(rows.count)…") {}
                .buttonStyle(.borderedProminent)
                .disabled(true)
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
            Button(needsStopping ? "Stop and remove…" : "Remove") {}  // Task 14; see the header of the block.
                .disabled(true)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(isSelected ? AnyShapeStyle(.selection.opacity(0.25)) : AnyShapeStyle(.clear))
    }

    private var needsStopping: Bool {
        if case .ready(let stop) = row.eligibility { stop } else { false }
    }
}
