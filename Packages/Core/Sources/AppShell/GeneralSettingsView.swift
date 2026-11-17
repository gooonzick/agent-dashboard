import SwiftUI

/// The General tab: whether the app looks for a new version by itself.
struct GeneralSettingsView: View {
    @Binding var checksForUpdatesAutomatically: Bool

    var body: some View {
        Form {
            Toggle("Check for updates automatically", isOn: $checksForUpdatesAutomatically)
        }
        .formStyle(.grouped)
    }
}
