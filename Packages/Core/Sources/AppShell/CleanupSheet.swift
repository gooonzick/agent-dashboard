import AppKit
import Cleanup
import CoreModels
import Dashboard
import SwiftUI

/// What a clean on Caches and Docker acts on, as it was when the user asked: what they confirm is what this says.
enum CleanupTarget: Equatable {
    case cache(CacheEntry)
    case output(BuildOutput)
    case unusedImages([DockerImage])
    case stoppedContainers([DockerContainer])
}

/// A clean that waits for the user to confirm it in the sheet.
struct CleanupAsk: Identifiable {
    let id = UUID()
    let target: CleanupTarget
    /// Whether Xcode ran when the sheet opened, asked only for DerivedData (Ruling 11). Xcode belongs to no worktree,
    /// so the process sample of the store does not have it, and the page does not read the sample anyway.
    let xcodeIsRunning: Bool

    /// `xcodeIsRunning` is asked here, as the sheet opens.
    @MainActor init(_ target: CleanupTarget, xcodeIsRunning: @MainActor () -> Bool = CleanupAsk.xcodeRuns) {
        self.target = target
        if case .cache(let entry) = target, entry.id == CleanupSheetModel.derivedDataID {
            self.xcodeIsRunning = xcodeIsRunning()
        } else {
            self.xcodeIsRunning = false
        }
    }

    @MainActor static func xcodeRuns() -> Bool {
        NSWorkspace.shared.runningApplications.contains { $0.bundleIdentifier == "com.apple.dt.Xcode" }
    }
}

/// The words of the sheet that confirms a clean, and of the alert when it fails.
struct CleanupSheetModel: Equatable {
    static let derivedDataID = "derived-data"

    /// `Clean Homebrew?`, `Remove unused images?`.
    let title: String
    /// What happens next, the first line under the title: `Packages are downloaded again when a project needs them.`
    let consequence: String
    /// `Xcode is running; builds in progress may fail.`
    let warning: String?
    /// What goes: the folders, with `~` for the home folder, or the images or containers.
    let items: [String]
    /// Whether `items` are paths, which are set in a monospaced font.
    let itemsArePaths: Bool
    /// The command that cleans a cache its tool owns: `pnpm store prune`.
    let command: String?
    /// `Clean` or `Remove`.
    let confirmTitle: String
    /// The title of the alert when the clean fails: `Could not clean Homebrew`.
    let failureTitle: String

    init(_ ask: CleanupAsk, home: String = FileManager.default.homeDirectoryForCurrentUser.path) {
        func tilde(_ paths: [String]) -> [String] { paths.map { CachesPresenter.abbreviated($0, home: home) } }
        var warning: String?
        var command: String?
        switch ask.target {
        case .cache(let entry):
            title = "Clean \(entry.title)?"
            failureTitle = "Could not clean \(entry.title)"
            confirmTitle = "Clean"
            itemsArePaths = true
            switch entry.clean {
            case .deleteContents(let folder): items = tilde([folder])
            case .deleteFolders(let folders): items = tilde(folders)
            case .command(let tool, let args):
                items = tilde(entry.paths)
                command = ([tool] + args).joined(separator: " ")
            case nil: items = tilde(entry.paths)
            }
            switch entry.id {
            case Self.derivedDataID:
                consequence = "Xcode rebuilds what it needs."
                if ask.xcodeIsRunning { warning = "Xcode is running; builds in progress may fail." }
            case "simulators":
                consequence = "Only simulators whose runtime is no longer installed are deleted."
            default:
                consequence = "Packages are downloaded again when a project needs them."
            }
        case .output(let output):
            title = "Clean \(output.title)?"
            failureTitle = "Could not clean \(output.title)"
            confirmTitle = "Clean"
            consequence = "The next build creates it again."
            items = tilde([output.path])
            itemsArePaths = true
        case .unusedImages(let images):
            title = "Remove unused images?"
            failureTitle = "Could not remove unused images"
            confirmTitle = "Remove"
            consequence = "Images are pulled again when a container needs them."
            items = images.map { "\($0.name) · \(SizeFormat.disk(Int64(clamping: $0.size)))" }
            itemsArePaths = false
        case .stoppedContainers(let containers):
            title = "Remove stopped containers?"
            failureTitle = "Could not remove stopped containers"
            confirmTitle = "Remove"
            consequence = "Images are pulled again when a container needs them."
            items = containers.map { "\($0.name) · \($0.image)" }
            itemsArePaths = false
        }
        self.warning = warning
        self.command = command
    }
}

/// The sheet that confirms a clean: what goes, the command that cleans it if a tool does, and what follows.
///
/// The Clean button is not the default one: Return does not delete folders. Escape cancels.
struct CleanupSheet: View {
    let model: CleanupSheetModel
    let cancel: () -> Void
    let confirm: () -> Void

    private static let itemHeight: CGFloat = 28

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            if !model.items.isEmpty { items }
            if let command = model.command {
                // Labelled, or it reads as one more folder.
                VStack(alignment: .leading, spacing: 6) {
                    Text("Cleaned with this command:").font(.callout).foregroundStyle(.secondary)
                    Text(command)
                        .font(.callout.monospaced())
                        .textSelection(.enabled)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(.background.secondary, in: .rect(cornerRadius: 8))
                }
                .accessibilityElement(children: .combine)
            }
            if let warning = model.warning {
                Label(warning, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .symbolRenderingMode(.multicolor)
                    .fixedSize(horizontal: false, vertical: true)
            }
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
                .background(.orange.quaternary, in: .rect(cornerRadius: 8))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(model.title).font(.headline)
                Text(model.consequence)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// The folders, images or containers. Past six of them the list scrolls.
    private var items: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(model.items.enumerated()), id: \.offset) { index, item in
                    Text(item)
                        .font(model.itemsArePaths ? .callout.monospaced() : .callout)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .padding(.horizontal, 12)
                        .frame(maxWidth: .infinity, minHeight: Self.itemHeight, alignment: .leading)
                    if index < model.items.count - 1 { Divider() }
                }
            }
        }
        .scrollBounceBehavior(.basedOnSize)
        .frame(height: min(CGFloat(model.items.count), 6.5) * Self.itemHeight)
        .background(.background.secondary, in: .rect(cornerRadius: 8))
    }

    private var footer: some View {
        HStack {
            Spacer()
            Button("Cancel", role: .cancel, action: cancel)
                .keyboardShortcut(.cancelAction)
            Button(model.confirmTitle, role: .destructive, action: confirm)
                .buttonStyle(.borderedProminent)
                .tint(.red)
        }
    }
}
