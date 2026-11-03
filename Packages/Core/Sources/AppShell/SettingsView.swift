import Dashboard
import Hosting
import SwiftUI

/// The Settings window: where the scan looks, and the accounts of the hosts.
public struct SettingsView: View {
    @State private var scan: ScanSettingsModel
    @State private var accounts: AccountsModel

    /// - Parameter tokens: Where the tokens are kept. The default is the Keychain entries of the app, which are the ones
    ///   that `DashboardEnvironment.live` reads for its requests.
    public init(store: DashboardStore, tokens: any TokenStoring = KeychainTokenStore()) {
        _scan = State(initialValue: ScanSettingsModel(store: store))
        _accounts = State(initialValue: AccountsModel(store: store, tokens: tokens))
    }

    public var body: some View {
        TabView {
            Tab("Scan", systemImage: "magnifyingglass") { ScanSettingsView(model: scan) }
            Tab("Accounts", systemImage: "person.crop.circle") { AccountsSettingsView(model: accounts) }
        }
        .scenePadding()
        .frame(width: 560, height: 480)
    }
}
