import AppKit
import Dashboard
import SwiftUI

/// The Scan tab: the folders that are left out, external drives, the hidden repositories, and a rescan.
struct ScanSettingsView: View {
    let model: ScanSettingsModel
    @State private var selected: String?

    var body: some View {
        Form {
            Section("Excluded folders") {
                List(model.excludedPaths, id: \.self, selection: $selected) { path in
                    Text(path).lineLimit(1).truncationMode(.middle).help(path)
                }
                .frame(height: 140)
                .accessibilityLabel("Excluded folders")
                HStack(spacing: 4) {
                    Button("Add folder", systemImage: "plus", action: addFolder)
                    Button("Remove folder", systemImage: "minus") {
                        if let selected { model.removeExclusion(selected) }
                        selected = nil
                    }
                    .disabled(selected == nil)
                }
                .labelStyle(.iconOnly)
                if model.appliesToTheNextScan {
                    Text("Applies to the next scan.").font(.caption).foregroundStyle(.secondary)
                }
            }
            Section {
                Toggle(
                    "Scan external drives",
                    isOn: Binding(get: { model.includesExternalVolumes }, set: model.setIncludesExternalVolumes))
                HStack {
                    Button("Rescan now") { Task { await model.rescan() } }
                        .disabled(!model.canRescan)
                    if model.appliesToTheNextScan { ProgressView().controlSize(.small) }
                }
            }
            Section("Hidden repositories") {
                if model.hiddenRepositories.isEmpty {
                    Text("No hidden repositories").foregroundStyle(.secondary)
                } else {
                    ForEach(model.hiddenRepositories, id: \.self) { path in
                        HStack {
                            Text(path).lineLimit(1).truncationMode(.middle).help(path)
                            Spacer()
                            Button("Show") { model.show(repoPath: path) }
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .onAppear { model.reload() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            model.reload()
        }
    }

    private func addFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.prompt = "Exclude"
        guard panel.runModal() == .OK else { return }
        for url in panel.urls { model.exclude(url.path) }
    }
}
