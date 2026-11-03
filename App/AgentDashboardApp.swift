import AppShell
import Dashboard
import SwiftUI

@main
struct AgentDashboardApp: App {
    @State private var store = DashboardStore(env: .live(settings: SettingsStore(defaults: .standard)))

    var body: some Scene {
        // One window: there is one store, and a second window would only show the same thing.
        Window("Agent Dashboard", id: "main") {
            RootView(store: store)
                .frame(minWidth: 900, minHeight: 560)
        }
        .defaultSize(width: 1440, height: 900)
    }
}
