import CoreModels
import Dashboard
import SwiftUI

/// A bar of segments in proportion to their bytes, 8 points high with 2 points between them, and under it a legend that
/// names each segment and says its size: the memory of the worktrees on Processes, what takes the disk on Caches and
/// Docker.
///
/// A segment with a worktree, and its name in the legend, select that worktree when there is `select`; the others are
/// only drawn.
struct SegmentBar: View {
    let segments: [MemorySegment]
    let colour: (MemorySegment, Int) -> Color
    /// `386 MB` for memory, `15.4 GB` for disk.
    let size: (UInt64) -> String
    var select: ((String) -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            bar
            legend
        }
    }

    private var bar: some View {
        GeometryReader { proxy in
            let total = segments.reduce(0.0) { $0 + Double($1.bytes) }
            let room = max(0, proxy.size.width - Self.gap * CGFloat(max(segments.count - 1, 0)))
            HStack(spacing: Self.gap) {
                ForEach(Array(segments.enumerated()), id: \.offset) { index, segment in
                    let shape = RoundedRectangle(cornerRadius: 3)
                        .fill(colour(segment, index))
                        .frame(width: total > 0 ? room * Double(segment.bytes) / total : 0)
                    if let select, let worktree = segment.worktree {
                        Button { select(worktree) } label: { shape }
                            .buttonStyle(.plain)
                    } else {
                        shape
                    }
                }
            }
        }
        .frame(height: 8)
        // The legend says the same, in words and as buttons.
        .accessibilityHidden(true)
    }

    private var legend: some View {
        LegendLayout(spacing: 16, lineSpacing: 6) {
            ForEach(Array(segments.enumerated()), id: \.offset) { index, segment in
                let entry = HStack(spacing: 5) {
                    Circle().fill(colour(segment, index)).frame(width: 8, height: 8)
                    Text(segment.label)
                    Text(size(segment.bytes)).monospacedDigit().foregroundStyle(.secondary)
                }
                .lineLimit(1)
                if let select, let worktree = segment.worktree {
                    Button { select(worktree) } label: { entry.contentShape(.rect) }
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

/// The entries of a legend side by side, and on a new line those that no longer fit: Caches and Docker has eight, more
/// than a narrow window has room for in one line.
private struct LegendLayout: Layout {
    let spacing: CGFloat
    let lineSpacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let frames = frames(of: subviews, width: proposal.width ?? .infinity)
        return CGSize(
            width: frames.map(\.maxX).max() ?? 0, height: frames.map(\.maxY).max() ?? 0)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for (subview, frame) in zip(subviews, frames(of: subviews, width: bounds.width)) {
            subview.place(
                at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY), anchor: .topLeading,
                proposal: ProposedViewSize(frame.size))
        }
    }

    /// Where each entry goes, at the size it wants, within `width`.
    private func frames(of subviews: Subviews, width: CGFloat) -> [CGRect] {
        var frames: [CGRect] = []
        var origin = CGPoint.zero
        var lineHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if origin.x > 0, origin.x + size.width > width {
                origin = CGPoint(x: 0, y: origin.y + lineHeight + lineSpacing)
                lineHeight = 0
            }
            frames.append(CGRect(origin: origin, size: size))
            origin.x += size.width + spacing
            lineHeight = max(lineHeight, size.height)
        }
        return frames
    }
}
