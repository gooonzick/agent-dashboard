import Foundation
import Hosting
import Observation
import Shell

/// One host in the Accounts tab.
public struct AccountItem: Equatable, Identifiable, Sendable {
    public var id: String { host }
    /// In lowercase.
    public let host: String
    /// What the host runs: what the user chose, or else what was found out.
    public let kind: HostingKind
    /// Whether the user chose `kind`, and it was not found out.
    public let isManual: Bool
    /// Whether the Keychain holds a token for the host. It is all that is known of the token here.
    public let hasToken: Bool
    /// `"glab"` or `"gh"` when the host runs what that tool is for and the tool is installed: the tool whose token
    /// "Import from …" would take over. `nil` when there is no button to show.
    public let importTool: String?
    /// What went wrong the last time that the host was asked, or in the last thing done here. Not how the host stands
    /// now: a late failure can overwrite a good answer, and the answer may differ from one project to another.
    public let lastError: String?
}

/// The Accounts tab: the hosts of the remotes of all repositories, what each runs, and the token for it.
///
/// A token goes straight to the Keychain through `TokenStoring` and is not kept here: it is not a property, it is not
/// in `items`, it is not logged and it is not in an error message. `hasToken` is all that the screen can show. After a
/// token or a kind changes, the requests of that host are asked again.
@MainActor @Observable public final class AccountsModel {
    public private(set) var items: [AccountItem] = []

    @ObservationIgnored private let hosts: @MainActor () -> [String]
    @ObservationIgnored private let settings: SettingsStore
    @ObservationIgnored private let detector: any HostingDetecting
    @ObservationIgnored private let tokens: any TokenStoring
    @ObservationIgnored private let importer: TokenImporter
    @ObservationIgnored private let tools: any CommandRunning
    @ObservationIgnored private let reviews: any ReviewLooking
    @ObservationIgnored private let refreshReviews: @MainActor (String) async -> Void
    /// What went wrong in the last thing done for a host, by host. It shows in place of what the hosts said.
    @ObservationIgnored private var problems: [String: String] = [:]
    @ObservationIgnored private var reloads = 0

    /// - Parameters:
    ///   - hosts: The hosts to list, asked at each `reload()`.
    ///   - detector: The one that the store asks (`DashboardEnvironment.hosting`), so that a kind that is chosen here
    ///     is the one that the store sees.
    ///   - importer: Takes a token over from `glab` or `gh`.
    ///   - tools: Tells whether `glab` and `gh` are installed (`which`).
    ///   - reviews: The one that the store asks, for the last error of a host.
    ///   - refreshReviews: Asks the host's requests again, after its token or its kind changed.
    public init(
        hosts: @escaping @MainActor () -> [String], settings: SettingsStore, detector: any HostingDetecting,
        tokens: any TokenStoring, importer: TokenImporter, tools: any CommandRunning, reviews: any ReviewLooking,
        refreshReviews: @escaping @MainActor (String) async -> Void
    ) {
        self.hosts = hosts
        self.settings = settings
        self.detector = detector
        self.tokens = tokens
        self.importer = importer
        self.tools = tools
        self.reviews = reviews
        self.refreshReviews = refreshReviews
    }

    /// The model of the app: the hosts, the detector and the review service of `store`, and the real tools.
    public convenience init(
        store: DashboardStore, tokens: any TokenStoring = KeychainTokenStore(), tools: any CommandRunning = CommandRunner()
    ) {
        self.init(
            hosts: { store.hosts }, settings: store.settings, detector: store.env.hosting, tokens: tokens,
            importer: TokenImporter(runner: tools), tools: tools, reviews: store.env.reviews,
            refreshReviews: { await store.refreshReviews(host: $0) })
    }

    // MARK: Reading

    /// Lists the hosts anew. Each shows as soon as it is known, in order: what a host runs may have to be asked of it,
    /// and a host that does not answer holds up the others for no longer than its own probe.
    public func reload() async {
        reloads += 1
        let mine = reloads
        let hosts = Set(hosts().map { $0.lowercased() }).sorted()
        let overrides = settings.hostingOverrides
        let (detector, tokens, tools, reviews) = (self.detector, self.tokens, self.tools, self.reviews)
        var found: [String: AccountItem] = [:]
        await withTaskGroup(of: AccountItem.self) { group in
            for host in hosts {
                let override = overrides[host]
                group.addTask {
                    await Self.item(host, override: override, detector, tokens, tools, reviews)
                }
            }
            for await item in group {
                // A newer reload has taken over: this one's answer is older.
                guard mine == reloads else { return }
                found[item.host] = item
                items = hosts.compactMap { found[$0] }.map(withProblem)
            }
        }
        if mine == reloads { items = hosts.compactMap { found[$0] }.map(withProblem) }
    }

    @concurrent
    private static func item(
        _ host: String, override: HostingKind?, _ detector: any HostingDetecting, _ tokens: any TokenStoring,
        _ tools: any CommandRunning, _ reviews: any ReviewLooking
    ) async -> AccountItem {
        let kind: HostingKind
        if let override { kind = override } else { kind = await detector.kind(for: host) }
        // The token is read to see that it is there, and dropped. A store that cannot be read is not an empty one.
        var storeError: String?
        var hasToken = false
        do { hasToken = try tokens.token(for: host) != nil } catch { storeError = "The Keychain could not be read." }
        let tool: String? =
            switch kind {
            case .gitlab: "glab"
            case .github: "gh"
            case .unsupported: nil
            }
        let reviewError = await reviews.lastError(host: host)
        return AccountItem(
            host: host, kind: kind, isManual: override != nil, hasToken: hasToken,
            importTool: tool.flatMap { tools.which($0) == nil ? nil : $0 }, lastError: storeError ?? reviewError)
    }

    private func withProblem(_ item: AccountItem) -> AccountItem {
        guard let problem = problems[item.host] else { return item }
        return AccountItem(
            host: item.host, kind: item.kind, isManual: item.isManual, hasToken: item.hasToken,
            importTool: item.importTool, lastError: problem)
    }

    // MARK: Changing

    /// Saves `token` for `host`. Leading and trailing white space is dropped (a pasted token often has a newline), and
    /// a field that is empty then removes the token.
    public func setToken(_ token: String, host: String) async {
        await save(token.trimmingCharacters(in: .whitespacesAndNewlines), host: host.lowercased())
    }

    /// Takes over the token that `glab` or `gh` has for `host`, whichever the host runs.
    public func importToken(host: String) async {
        let host = host.lowercased()
        var kind = items.first { $0.host == host }?.kind ?? settings.hostingOverrides[host]
        if kind == nil { kind = await detector.kind(for: host) }
        let known = kind ?? .unsupported
        guard let token = await importer.importToken(host: host, kind: known) else {
            let tool = known == .github ? "gh" : "glab"
            problems[host] = "\(tool) has no token for \(host)."
            items = items.map(withProblem)
            return
        }
        await save(token, host: host)
    }

    /// Sets what `host` runs, or with `nil` leaves it to be found out. It takes effect at once, in the detector that
    /// the store asks too, and the host's requests are asked again.
    public func setKind(_ kind: HostingKind?, host: String) async {
        let host = host.lowercased()
        var overrides = settings.hostingOverrides
        overrides[host] = kind
        settings.hostingOverrides = overrides
        await detector.setOverride(kind, for: host)
        problems[host] = nil
        await refreshReviews(host)
        await reload()
    }

    private func save(_ token: String, host: String) async {
        do {
            try await Self.write(token, host: host, to: tokens)
        } catch {
            problems[host] = "The token could not be saved: \(error.localizedDescription)"
            await reload()
            return
        }
        problems[host] = nil
        await refreshReviews(host)
        await reload()
    }

    /// The Keychain is asked off the main actor, which it may have to wait for. An empty token removes the entry.
    @concurrent
    private static func write(_ token: String, host: String, to tokens: any TokenStoring) async throws {
        try tokens.setToken(token.isEmpty ? nil : token, for: host)
    }
}
