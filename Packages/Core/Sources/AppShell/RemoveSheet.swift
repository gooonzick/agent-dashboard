import CoreModels
import Dashboard
import SwiftUI

/// The sheet that confirms a removal: what goes, what it frees, what is stopped first, and whether the branches go too.
///
/// The Remove button is not the default one: Return does not delete folders. Escape cancels.
struct RemoveSheet: View {
    let model: RemoveSheetModel
    let cancel: () -> Void
    /// Called with "Also delete the local branches", and with "Don't ask again" (always `false` when it is not
    /// offered).
    let confirm: (_ deleteBranches: Bool, _ dontAskAgain: Bool) -> Void

    @State private var deleteBranches = true
    @State private var dontAskAgain = false

    private static let itemHeight: CGFloat = 32
    private static let processLineHeight: CGFloat = 18

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            header
            items
            if model.stopsProcesses { processes }
            VStack(alignment: .leading, spacing: 8) {
                Toggle("Also delete the local branches", isOn: $deleteBranches)
                if model.offersDontAskAgain {
                    Toggle("Don't ask again for merged, pushed worktrees", isOn: $dontAskAgain)
                }
            }
            .toggleStyle(.checkbox)
            Text("Folders are deleted right away, including ignored files like tmp/. Nothing goes to the Trash.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            footer
        }
        .padding(22)
        .frame(width: 460)
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "trash")
                .font(.title3)
                .foregroundStyle(.orange)
                .frame(width: 36, height: 36)
                .background(.orange.opacity(0.15), in: .rect(cornerRadius: 8))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(model.title).font(.headline)
                Text(model.message)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// The worktrees, each with what it frees. Past five of them the list scrolls.
    private var items: some View {
        ScrollView {
            VStack(spacing: 0) {
                ForEach(model.items) { item in
                    HStack(spacing: 8) {
                        Image(systemName: "arrow.triangle.branch").foregroundStyle(.secondary).frame(width: 16)
                        Text(item.name).lineLimit(1).truncationMode(.middle)
                        Spacer(minLength: 8)
                        Text(item.size).monospacedDigit().foregroundStyle(.secondary)
                    }
                    .font(.callout)
                    .padding(.horizontal, 12)
                    .frame(height: Self.itemHeight)
                    if item.id != model.items.last?.id { Divider() }
                }
            }
        }
        .scrollBounceBehavior(.basedOnSize)
        .frame(height: min(CGFloat(model.items.count), 5.5) * Self.itemHeight)
        .background(.background.secondary, in: .rect(cornerRadius: 8))
    }

    /// Every process that is stopped first, by name and pid (Ruling 39). Past eight of them the list scrolls.
    private var processes: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("These processes will be stopped first:").font(.callout)
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(model.processesToStop, id: \.self) { line in
                        Text(line)
                            .font(.callout)
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .frame(height: Self.processLineHeight)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .scrollBounceBehavior(.basedOnSize)
            .frame(height: min(CGFloat(model.processesToStop.count), 8.5) * Self.processLineHeight)
        }
    }

    private var footer: some View {
        HStack {
            if !model.totalFrees.isEmpty { Text(model.totalFrees).font(.callout) }
            Spacer()
            Button("Cancel", role: .cancel, action: cancel)
                .keyboardShortcut(.cancelAction)
            Button(model.removeButtonTitle, role: .destructive) {
                confirm(deleteBranches, model.offersDontAskAgain && dontAskAgain)
            }
            .buttonStyle(.borderedProminent)
            .tint(.red)
        }
    }
}
