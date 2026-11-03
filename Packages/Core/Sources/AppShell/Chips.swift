import CoreModels
import Dashboard
import SwiftUI

/// A State chip: warm for what stands in the way of removing, plain for what does not.
struct StateChipView: View {
    let chip: StateChip

    var body: some View {
        Text(chip.text)
            .font(.caption)
            .lineLimit(1)
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .foregroundStyle(chip.warning ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
            .background(
                chip.warning ? AnyShapeStyle(Color.orange.opacity(0.22)) : AnyShapeStyle(.quaternary), in: .capsule)
    }
}

/// The chips of a row, side by side.
struct StateChips: View {
    let row: WorktreeRow

    var body: some View {
        HStack(spacing: 4) {
            ForEach(Array(RowPresenter.stateChips(row).enumerated()), id: \.offset) { _, chip in
                StateChipView(chip: chip)
            }
        }
    }
}

/// The MR / PR cell: the state with its symbol, or `—`.
struct ReviewChip: View {
    let review: ReviewInfo

    var body: some View {
        let text = RowPresenter.reviewChip(review)
        if let symbol {
            Label(text, systemImage: symbol.name)
                .font(.callout)
                .foregroundStyle(symbol.tint)
                .lineLimit(1)
        } else {
            Text(text).foregroundStyle(.secondary)
        }
    }

    private var symbol: (name: String, tint: Color)? {
        switch review.state {
        case .open: ("arrow.triangle.pull", .green)
        case .draft: ("arrow.triangle.pull", .secondary)
        case .merged: ("arrow.triangle.merge", .purple)
        case .closed: ("arrow.triangle.pull", .red)
        case .none, .unknown: nil
        }
    }
}

/// The Running cell: what runs, with the memory, or `—`.
struct RunningCell: View {
    let groups: [ProcessGroup]

    var body: some View {
        if let text = RowPresenter.runningText(groups) {
            Label(text, systemImage: "sparkle")
                .labelStyle(RunningLabelStyle(showsSymbol: groups.contains { $0.kind == .agentSession }))
                .font(.callout)
                .lineLimit(1)
                .truncationMode(.tail)
        } else {
            Text("—").foregroundStyle(.secondary)
        }
    }
}

/// The symbol of an agent session, when there is one among the groups; the text alone otherwise.
private struct RunningLabelStyle: LabelStyle {
    let showsSymbol: Bool

    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 4) {
            if showsSymbol { configuration.icon.foregroundStyle(.orange).imageScale(.small) }
            configuration.title
        }
    }
}

extension SizeInfo? {
    /// What removing the folder frees, as the Real size column shows it; `—` until it has been measured.
    var realSizeText: String {
        map { SizeFormat.disk($0.privateBytes) } ?? "—"
    }
}
