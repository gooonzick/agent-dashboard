import Combine
import Sparkle
import SwiftUI

/// Sparkle's updater, for the menu and for Settings. It lives in the app target alone: the Core package does not know
/// about Sparkle, and Settings gets the switch as a binding.
///
/// An `ObservableObject` rather than `@Observable`: what it shows comes from Sparkle's KVO properties, which Combine
/// bridges.
@MainActor
final class Updater: ObservableObject {
    private let controller: SPUStandardUpdaterController

    /// Off while a check or an update is under way, so the menu item cannot start a second one.
    @Published private(set) var canCheckForUpdates = false

    /// Sparkle keeps this in the app's user defaults itself, so there is no setting of our own to keep in step.
    var automaticallyChecksForUpdates: Bool {
        get { controller.updater.automaticallyChecksForUpdates }
        set {
            objectWillChange.send()
            controller.updater.automaticallyChecksForUpdates = newValue
        }
    }

    init() {
        // Sparkle refuses to start with a key it cannot decode and says so in an alert on every launch. Until the
        // project has its real key, the updater is left off: no alert, and Check for Updates… stays disabled, as
        // `canCheckForUpdates` turns true only once the updater has started.
        let startsUpdater = Self.hasRealKey(Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey"))
        controller = SPUStandardUpdaterController(
            startingUpdater: startsUpdater, updaterDelegate: nil, userDriverDelegate: nil)
        controller.updater.publisher(for: \.canCheckForUpdates).assign(to: &$canCheckForUpdates)
    }

    /// Whether the `SUPublicEDKey` of the Info.plist is a key: present, and not the placeholder that project.yml has
    /// until Sparkle's generate_keys is run.
    nonisolated static func hasRealKey(_ value: Any?) -> Bool {
        guard let key = (value as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) else { return false }
        return !key.isEmpty && key != "REPLACE_WITH_PUBLIC_ED_KEY"
    }

    func checkForUpdates() {
        controller.checkForUpdates(nil)
    }
}

/// The "Check for Updates…" item of the app menu.
struct CheckForUpdatesView: View {
    @ObservedObject var updater: Updater

    var body: some View {
        Button("Check for Updates…", action: updater.checkForUpdates)
            .disabled(!updater.canCheckForUpdates)
    }
}
