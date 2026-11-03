import Discovery
import Foundation
import Hosting

/// What the user has set, kept in `UserDefaults`. Every property reads and writes the defaults directly, so two stores
/// on the same defaults agree, and nothing is cached here.
///
/// A value that cannot be read, because it is missing or was written by something else, reads as the default of a
/// fresh install: the exclusions of `ExclusionRules.defaults(home:)` with external disks off, no hosting overrides,
/// confirmation asked for every removal, onboarding not done, no repository hidden.
///
/// `@unchecked Sendable`: the only state is `UserDefaults`, which is safe to use from any thread.
public final class SettingsStore: @unchecked Sendable {
    private enum Key {
        static let rules = "exclusionRules"
        static let hostingOverrides = "hostingOverrides"
        static let skipConfirm = "skipConfirmForMergedPushed"
        static let didOnboard = "didOnboard"
        static let hiddenRepos = "hiddenRepos"
    }

    private let defaults: UserDefaults

    public init(defaults: UserDefaults) {
        self.defaults = defaults
    }

    /// Where the scan does not look.
    public var rules: ExclusionRules {
        get {
            defaults.data(forKey: Key.rules).flatMap { try? JSONDecoder().decode(ExclusionRules.self, from: $0) }
                ?? .defaults(home: FileManager.default.homeDirectoryForCurrentUser)
        }
        set { defaults.set(try? JSONEncoder().encode(newValue), forKey: Key.rules) }
    }

    /// The kind of hosting that the user has set for a host, by host.
    public var hostingOverrides: [String: HostingKind] {
        get {
            (defaults.dictionary(forKey: Key.hostingOverrides) as? [String: String] ?? [:])
                .compactMapValues(HostingKind.init(rawValue:))
        }
        set { defaults.set(newValue.mapValues(\.rawValue), forKey: Key.hostingOverrides) }
    }

    /// "Don't ask again for merged, pushed worktrees".
    public var skipConfirmForMergedPushed: Bool {
        get { defaults.bool(forKey: Key.skipConfirm) }
        set { defaults.set(newValue, forKey: Key.skipConfirm) }
    }

    /// Whether the first-run window has been through, and the scan may start.
    public var didOnboard: Bool {
        get { defaults.bool(forKey: Key.didOnboard) }
        set { defaults.set(newValue, forKey: Key.didOnboard) }
    }

    /// The canonical paths of the repositories that are not shown.
    public var hiddenRepos: Set<String> {
        get { Set(defaults.stringArray(forKey: Key.hiddenRepos) ?? []) }
        set { defaults.set(newValue.sorted(), forKey: Key.hiddenRepos) }
    }
}
