import Dashboard
import Hosting
import SwiftUI

/// The Accounts tab: one row for each host that the repositories are on.
struct AccountsSettingsView: View {
    let model: AccountsModel

    var body: some View {
        Form {
            if model.items.isEmpty {
                Text("No hosts yet. They are read from the remotes of your repositories.")
                    .foregroundStyle(.secondary)
            }
            ForEach(model.items) { item in
                AccountRow(item: item, model: model)
            }
        }
        .formStyle(.grouped)
        .task { await model.reload() }
    }
}

private struct AccountRow: View {
    let item: AccountItem
    let model: AccountsModel
    /// What is typed in the field. It is cleared as soon as it is handed over, and it is the only place in the app where
    /// a token is held, for as long as the user types.
    @State private var typed = ""

    var body: some View {
        Section {
            Picker("Type", selection: kind) {
                Text("Detected: \(Self.name(item.kind))").tag(HostingKind?.none)
                Text("GitHub").tag(HostingKind?.some(.github))
                Text("GitLab").tag(HostingKind?.some(.gitlab))
                Text("Other").tag(HostingKind?.some(.unsupported))
            }
            HStack {
                SecureField("Token", text: $typed, prompt: Text(item.hasToken ? "Token saved" : "Paste a token"))
                    .onSubmit(save)
                Button("Save", action: save).disabled(typed.isEmpty)
                if item.hasToken {
                    Button("Remove", role: .destructive) { hand(over: "") }
                }
            }
            if let tool = item.importTool {
                Button("Import from \(tool)") { Task { await model.importToken(host: item.host) } }
            }
            if let error = item.lastError {
                Text("Last error: \(error)").font(.caption).foregroundStyle(.secondary)
            }
        } header: {
            HStack {
                Text(item.host)
                if item.hasToken { Image(systemName: "key.fill").foregroundStyle(.secondary).help("Has a token") }
            }
        }
    }

    /// `nil` is "left to be found out".
    private var kind: Binding<HostingKind?> {
        Binding(
            get: { item.isManual ? item.kind : nil },
            set: { new in Task { await model.setKind(new, host: item.host) } })
    }

    private func save() {
        guard !typed.isEmpty else { return }
        hand(over: typed)
    }

    private func hand(over token: String) {
        typed = ""
        Task { await model.setToken(token, host: item.host) }
    }

    private static func name(_ kind: HostingKind) -> String {
        switch kind {
        case .github: "GitHub"
        case .gitlab: "GitLab"
        case .unsupported: "Other"
        }
    }
}
