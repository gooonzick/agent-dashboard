import CoreModels
import Dashboard
import SwiftUI

/// A State chip: orange for what may be lost, grey for work that is here, plain text when all is well.
struct StateChipView: View {
    let chip: StateChip

    var body: some View {
        switch chip.tone {
        case .quiet:
            Text(chip.text).font(.caption).foregroundStyle(.secondary).lineLimit(1)
        case .neutral, .warning:
            Text(chip.text)
                .font(.caption)
                .lineLimit(1)
                .padding(.horizontal, 7)
                .padding(.vertical, 2)
                .foregroundStyle(chip.tone == .warning ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
                .background(
                    chip.tone == .warning ? AnyShapeStyle(Color.orange.opacity(0.22)) : AnyShapeStyle(.quaternary),
                    in: .capsule)
        }
    }
}

/// The State cell: the first chip, a warning first, and `+2` for the others, which the help names.
struct StateChips: View {
    let row: WorktreeRow

    var body: some View {
        let summary = RowPresenter.stateSummary(row)
        HStack(spacing: 4) {
            StateChipView(chip: summary.chip)
            if summary.more > 0 {
                Text("+\(summary.more)").font(.caption).foregroundStyle(.secondary).monospacedDigit()
            }
        }
        .help(summary.more > 0 ? summary.help : "")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(summary.help)
    }
}

/// The MR / PR cell: the state with its symbol, or nothing.
struct ReviewChip: View {
    let review: ReviewInfo

    var body: some View {
        let text = RowPresenter.reviewChip(review)
        if let symbol {
            Label(text, systemImage: symbol.name)
                .font(.callout)
                .foregroundStyle(symbol.tint)
                .lineLimit(1)
        }
        // No review: the cell is empty rather than a dash on nearly every row.
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

/// The Running cell: what runs, with the memory, or nothing.
struct RunningCell: View {
    let groups: [ProcessGroup]

    var body: some View {
        if let text = RowPresenter.runningText(groups) {
            Label(text, systemImage: "sparkle")
                .labelStyle(RunningLabelStyle(showsSymbol: groups.contains { $0.kind == .agentSession }))
                .font(.callout)
                .lineLimit(1)
                .truncationMode(.tail)
        }
        // Nothing runs: the cell is empty rather than a dash on nearly every row.
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
