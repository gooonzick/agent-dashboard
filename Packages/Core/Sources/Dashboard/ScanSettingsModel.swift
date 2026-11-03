import Discovery
import Foundation
import Observation

/// The Scan tab: where the scan does not look, whether it covers external drives, which repositories are hidden, and a
/// rescan.
///
/// Edits are saved at once and apply from the next scan; the scan that may be running was started with the settings of
/// its own time. The paths follow `ExclusionRules`: a folder and everything below it, never a folder above it.
@MainActor @Observable public final class ScanSettingsModel {
    /// As they are kept: the user's, in the order in which they were added.
    public private(set) var excludedPaths: [String] = []
    public private(set) var includesExternalVolumes = false
    /// The paths of the hidden repositories, in order.
    public private(set) var hiddenRepositories: [String] = []

    @ObservationIgnored private let store: DashboardStore

    public init(store: DashboardStore) {
        self.store = store
        reload()
    }

    /// Whether a scan is under way: what is edited now is for the next one.
    public var appliesToTheNextScan: Bool { store.isStarting }

    /// Whether "Rescan now" is on. It is off while a scan runs, which would drop a second one, and before the first run
    /// is through.
    public var canRescan: Bool { store.didOnboard && !store.isStarting }

    /// Reads the settings again: a repository may have been hidden since.
    public func reload() {
        let rules = store.settings.rules
        excludedPaths = rules.excludedPaths
        includesExternalVolumes = rules.includeExternalVolumes
        hiddenRepositories = store.settings.hiddenRepos.sorted()
    }

    /// Leaves `path` out of the scan, with everything in it. Anything that is not the path of a folder, and the root of
    /// the disk, which would leave out everything, is ignored; so is a folder that is left out already.
    public func exclude(_ path: String) {
        let path = Self.normalized(path)
        guard let path, !excludedPaths.contains(path) else { return }
        var rules = store.settings.rules
        rules.excludedPaths.append(path)
        store.settings.rules = rules
        reload()
    }

    public func removeExclusion(_ path: String) {
        var rules = store.settings.rules
        rules.excludedPaths.removeAll { $0 == path }
        store.settings.rules = rules
        reload()
    }

    public func setIncludesExternalVolumes(_ include: Bool) {
        var rules = store.settings.rules
        rules.includeExternalVolumes = include
        store.settings.rules = rules
        reload()
    }

    /// Takes the repository at `repoPath` off the hidden ones. It comes back with the next scan.
    public func show(repoPath: String) {
        store.settings.hiddenRepos.remove(repoPath)
        reload()
    }

    /// "Rescan now". Nothing happens while a scan runs, or before the first run is through.
    public func rescan() async {
        guard canRescan else { return }
        await store.start()
    }

    /// An absolute path without a trailing slash or `.`/`..` parts, or `nil` for one that is not, or is `/`.
    private static func normalized(_ path: String) -> String? {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("/") else { return nil }
        let clean = URL(filePath: trimmed).standardizedFileURL.path
        return clean == "/" ? nil : clean
    }
}
