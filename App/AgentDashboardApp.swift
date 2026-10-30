import AppShell
import SwiftUI

@main
struct AgentDashboardApp: App {
    var body: some Scene {
        WindowGroup {
            RootView()
                .frame(minWidth: 900, minHeight: 560)
        }
        .defaultSize(width: 1440, height: 900)
    }
}
