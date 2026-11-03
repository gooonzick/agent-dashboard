import SwiftUI

/// The first-run window: what the scan is about to do, and the button that starts it. Nothing is read from the disk
/// before the button is pressed.
struct OnboardingView: View {
    let start: () -> Void

    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "externaldrive.badge.magnifyingglass")
                .font(.system(size: 44))
                .foregroundStyle(.tint)
                .accessibilityHidden(true)
            Text(
                "Agent Dashboard looks for git projects on your whole Mac. macOS will ask for access to Desktop, Documents and Downloads — allow it so projects there are found too."
            )
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: 420)
            Button("Start scan", action: start)
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .keyboardShortcut(.defaultAction)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
