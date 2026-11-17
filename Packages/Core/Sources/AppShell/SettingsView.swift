import Dashboard
import Hosting
import SwiftUI

/// The Settings window: whether the app checks for updates, where the scan looks, and the accounts of the hosts.
public struct SettingsView: View {
    @State private var scan: ScanSettingsModel
    @State private var accounts: AccountsModel
    private let automaticUpdateChecks: Binding<Bool>?

    /// - Parameters:
    ///   - tokens: Where the tokens are kept. The default is the Keychain entries of the app, which are the ones that
    ///     `DashboardEnvironment.live` reads for its requests.
    ///   - automaticUpdateChecks: Whether the updater of the app checks by itself. The app passes it, as the updater
    ///     lives there; without it there is no General tab.
    public init(
        store: DashboardStore, tokens: any TokenStoring = KeychainTokenStore(),
        automaticUpdateChecks: Binding<Bool>? = nil
    ) {
        _scan = State(initialValue: ScanSettingsModel(store: store))
        _accounts = State(initialValue: AccountsModel(store: store, tokens: tokens))
        self.automaticUpdateChecks = automaticUpdateChecks
    }

    public var body: some View {
        TabView {
            if let automaticUpdateChecks {
                Tab("General", systemImage: "gearshape") {
                    GeneralSettingsView(checksForUpdatesAutomatically: automaticUpdateChecks)
                }
            }
            Tab("Scan", systemImage: "magnifyingglass") { ScanSettingsView(model: scan) }
            Tab("Accounts", systemImage: "person.crop.circle") { AccountsSettingsView(model: accounts) }
        }
        .scenePadding()
        .frame(width: 560, height: 480)
    }
}
