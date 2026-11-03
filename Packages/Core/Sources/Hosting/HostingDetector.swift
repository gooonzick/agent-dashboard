import Foundation

/// What a host runs, and so how it is asked about merge requests.
public enum HostingKind: String, Sendable, Codable {
    case github
    case gitlab
    /// Neither, or a host that cannot be told: there is no status of merge or pull requests for it.
    case unsupported
}

/// Tells what a host runs.
public protocol HostingDetecting: Sendable {
    /// What `host` runs: `.unsupported` if it is neither GitHub nor GitLab, or if that cannot be told for now.
    func kind(for host: String) async -> HostingKind
}

/// Finds out what a host runs: GitHub, GitLab (on any address) or neither.
///
/// `github.com` and `gitlab.com` are known. For any other host the user's override counts first, and without one the
/// host is asked: GitLab answers `GET /api/v4/version` with 200, or with 401 when it wants a token, and a GitHub
/// Enterprise server answers `GET /api/v3/meta` with 200. The first of these that fits decides, and what is decided is
/// remembered for the host.
///
/// The hosts are those of the remotes of repositories that happen to be on the disk, and nobody has vouched for them,
/// so a probe is careful. It is a plain HTTPS GET that carries no token and sends no cookie; it is not sent on to
/// another address, however the host redirects; it takes the status and leaves the body, and it is given up after
/// `probeTimeout`.
public actor HostingDetector: HostingDetecting {
    private static let wellKnown: [String: HostingKind] = ["github.com": .github, "gitlab.com": .gitlab]

    private let session: URLSession
    private let probeTimeout: Duration
    private var overrides: [String: HostingKind]
    /// What probes have found out. Only answers that a host gave are kept, and none that failed to come.
    private var detected: [String: HostingKind] = [:]
    /// The probes under way. Callers that ask about a host while one is out wait for it instead of starting another.
    private var probes: [String: Task<HostingKind, Never>] = [:]

    /// - Parameters:
    ///   - overrides: The kind that the user has set for a host, by host. A host is not case sensitive.
    ///   - session: What the probes are sent with. A probe sets what it needs on its own request, and it cannot
    ///     remove what the session adds by itself: headers that its configuration holds, or credentials in its
    ///     storage. So this is a session that has none, such as an ephemeral one.
    ///   - probeTimeout: How long one request of a probe may take altogether. At most two are sent for a host.
    public init(overrides: [String: HostingKind], session: URLSession, probeTimeout: Duration = .seconds(5)) {
        self.overrides = Dictionary(
            overrides.map { ($0.key.lowercased(), $0.value) }, uniquingKeysWith: { _, latest in latest })
        self.session = session
        self.probeTimeout = probeTimeout
    }

    /// What `host` runs, which is `.unsupported` if it is neither, and also if it could not be told for now: a host
    /// that cannot be reached, or one that does not answer right, is `.unsupported` for this call, and is asked again
    /// at the next.
    ///
    /// A name that is no host name is `.unsupported` and is not asked at all.
    public func kind(for host: String) async -> HostingKind {
        let host = host.lowercased()
        if let known = known(host) { return known }
        guard RemoteURL.isValidHost(host) else { return .unsupported }
        let probe = probes[host] ?? startProbe(of: host)
        let found = await probe.value
        // Other calls ran while this one waited, and one of them may have set an override.
        return overrides[host] ?? found
    }

    /// Sets the kind of `host` for good, or with `nil` takes the override away. Either way what was found out about the
    /// host is forgotten, so that without an override the host is asked again.
    public func setOverride(_ kind: HostingKind?, for host: String) {
        let host = host.lowercased()
        overrides[host] = kind
        detected[host] = nil
    }

    private func known(_ host: String) -> HostingKind? {
        Self.wellKnown[host] ?? overrides[host] ?? detected[host]
    }

    // MARK: Probes

    private func startProbe(of host: String) -> Task<HostingKind, Never> {
        let (session, timeout) = (self.session, probeTimeout)
        let probe = Task {
            let detection = await Self.detect(host, using: session, within: timeout)
            self.finishProbe(of: host, with: detection)
            return detection.kind
        }
        probes[host] = probe
        return probe
    }

    private func finishProbe(of host: String, with detection: Detection) {
        probes[host] = nil
        if detection.isFinal { detected[host] = detection.kind }
    }

    private struct Detection {
        let kind: HostingKind
        /// Whether the host has said what it is, or what it is not. If not, the kind is only the best that could be
        /// told, and the next call asks again.
        let isFinal: Bool
    }

    private static func detect(_ host: String, using session: URLSession, within limit: Duration) async -> Detection {
        // A host that cannot be reached is not asked a second question.
        guard let gitlab = await statusOf("/api/v4/version", on: host, using: session, within: limit) else {
            return Detection(kind: .unsupported, isFinal: false)
        }
        if gitlab == 200 || gitlab == 401 { return Detection(kind: .gitlab, isFinal: true) }

        guard let github = await statusOf("/api/v3/meta", on: host, using: session, within: limit) else {
            return Detection(kind: .unsupported, isFinal: false)
        }
        if github == 200 { return Detection(kind: .github, isFinal: true) }

        // Neither, as far as the host says. A server that is down for a moment says that too, in its own way.
        return Detection(kind: .unsupported, isFinal: !isTemporary(gitlab) && !isTemporary(github))
    }

    private static func isTemporary(_ status: Int) -> Bool {
        status >= 500 || status == 408 || status == 429
    }

    /// The HTTP status that `host` gives to a GET of `path`, or `nil` if it gives none within `limit`.
    private static func statusOf(
        _ path: String, on host: String, using session: URLSession, within limit: Duration
    ) async -> Int? {
        guard let url = URL(string: "https://\(host)\(path)") else { return nil }
        let request = probeRequest(to: url, timeout: limit)
        // The timeout of a request counts only the time in which nothing arrives, and it does not run at all while a
        // session waits for the network. So the time is limited here too, whatever the host does.
        return await withTaskGroup(of: Int?.self) { group in
            group.addTask { await send(request, using: session) }
            group.addTask {
                try? await Task.sleep(for: limit)
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
    }

    /// A GET that asks for no stored answer and sends no cookie. It has no headers of its own: no token, and no
    /// `Authorization`.
    private static func probeRequest(to url: URL, timeout: Duration) -> URLRequest {
        var request = URLRequest(
            url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: timeout.timeInterval)
        request.httpShouldHandleCookies = false
        return request
    }

    private static func send(_ request: URLRequest, using session: URLSession) async -> Int? {
        do {
            let (bytes, response) = try await session.bytes(for: request, delegate: RefuseRedirects())
            // Only the status is wanted. Cancelling is how what the host sends along is never downloaded.
            bytes.task.cancel()
            return (response as? HTTPURLResponse)?.statusCode
        } catch {
            return nil
        }
    }
}

/// Answers every redirect with "no". A host's answer is the one that the host gives, and not the one of a page that it
/// points to, such as a sign-in page that says 200 to any request. A redirect may also lead off HTTPS, or off the host,
/// and take with it the token that a request carries in a header of its own.
final class RefuseRedirects: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(
        _ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest
    ) async -> URLRequest? {
        nil
    }
}

extension Duration {
    fileprivate var timeInterval: TimeInterval {
        Double(components.seconds) + Double(components.attoseconds) / 1e18
    }
}
