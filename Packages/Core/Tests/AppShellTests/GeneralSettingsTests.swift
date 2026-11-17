import AppKit
import SwiftUI
import Testing

@testable import AppShell

/// The switch of the General tab, drawn in a view that is in no window: nothing is put on the screen. The updater is
/// the app's, so the tab gets a binding and these tests give it one over a local value.
@MainActor @Suite struct GeneralSettingsTests {
    @Test(arguments: [true, false]) func theSwitchShowsTheValueItIsGiven(_ on: Bool) throws {
        let control = try automaticChecksSwitch(in: GeneralSettingsView(checksForUpdatesAutomatically: .constant(on)))
        #expect(control.state == (on ? .on : .off))
    }

    @Test func turningTheSwitchWritesTheValueBack() throws {
        var checks = true
        let binding = Binding(get: { checks }, set: { checks = $0 })
        let control = try automaticChecksSwitch(in: GeneralSettingsView(checksForUpdatesAutomatically: binding))

        control.performClick(nil)
        #expect(!checks)
        control.performClick(nil)
        #expect(checks)
    }

    /// The `NSSwitch` that SwiftUI puts in for the toggle, once the view is laid out.
    private func automaticChecksSwitch(in view: GeneralSettingsView) throws -> NSSwitch {
        let host = NSHostingView(rootView: view)
        host.frame = NSRect(x: 0, y: 0, width: 500, height: 200)
        host.layoutSubtreeIfNeeded()
        func find(_ view: NSView) -> NSSwitch? {
            (view as? NSSwitch) ?? view.subviews.lazy.compactMap(find).first
        }
        return try #require(find(host))
    }
}
