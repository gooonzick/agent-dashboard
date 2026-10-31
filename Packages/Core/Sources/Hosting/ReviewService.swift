import CoreModels
import Foundation

/// Looks up the merge request or pull request of a branch, and always has an answer.
public protocol ReviewLooking: Sendable {
    /// How the request of `branch` in the project of `remote` stands. Whatever goes wrong, the answer is `.unknown`,
    /// which is never a merge: `lastError(host:)` says what went wrong.
    func review(remote: RemoteURL, branch: String) async -> ReviewInfo

    /// What went wrong the last time that `host` was asked, or `nil` if nothing has, or if the host has answered well
    /// since. It is made for people to read, and holds neither a token nor anything that the host sent.
    func lastError(host: String) async -> String?

    /// Forgets every answer that was kept, and those that are on their way, so that what is asked for next is asked of
    /// the host. It is for a caller that needs to know how things stand now, and not as they stood a while ago.
    func invalidate() async
}

/// Finds out which service a host runs, takes its token from where it is kept, and asks it for the request of a branch.
///
/// An answer that is sure (`open`, `draft`, `merged`, `closed` or `none`) is kept for the `ttl`. `.unknown` is not: it
/// is the answer to a host that could not be reached, that refused, or that said what is not understood, and the next
/// call is to ask again, so that a host that is back is seen as soon as it is. Callers that ask for the same branch
/// while it is being asked for share the one request, and a host that is slow does not hold up another.
public actor ReviewService: ReviewLooking {
    private struct Key: Hashable {
        let remote: RemoteURL
        let branch: String
    }

    private struct Kept {
        let info: ReviewInfo
        let until: ContinuousClock.Instant
    }

    /// A request that is on its way, and the generation of `invalidate()` it was made in.
    private struct Pending {
        let generation: Int
        let task: Task<ReviewInfo, Never>
    }

    private let detector: HostingDetector
    private let tokens: any TokenStoring
    private let session: URLSession
    private let ttl: Duration
    /// How long finding out how one branch stands may take altogether.
    private let deadline: Duration

    private var kept: [Key: Kept] = [:]
    private var pending: [Key: Pending] = [:]
    /// By host in lowercase.
    private var errors: [String: String] = [:]
    /// Counts the calls of `invalidate()`: a request that was made before one is not the one that is needed after it.
    private var generation = 0

    /// - Parameters:
    ///   - detector: Tells which service a host runs.
    ///   - tokens: Where the token of each host is kept. A host that has none is asked without one.
    ///   - session: What the requests are sent with. It should have no headers or credentials of its own, such as an
    ///     ephemeral one has (see `GitLabClient` and `GitHubClient`).
    ///   - ttl: How long an answer that is sure is kept.
    public init(
        detector: HostingDetector, tokens: any TokenStoring, session: URLSession, ttl: Duration = .seconds(300)
    ) {
        self.init(detector: detector, tokens: tokens, session: session, ttl: ttl, deadline: .seconds(60))
    }

    /// `deadline` is how long finding out how one branch stands may take, from asking what the host runs to the answer.
    /// The timeout of a request is for the time in which nothing arrives, so a host that sends a little now and then
    /// never runs out of it. Callers that ask for the same branch all wait for the one request, so a request that never
    /// ended would be the answer to every call that came after it.
    init(detector: HostingDetector, tokens: any TokenStoring, session: URLSession, ttl: Duration, deadline: Duration) {
        self.detector = detector
        self.tokens = tokens
        self.session = session
        self.ttl = ttl
        self.deadline = deadline
    }

    public func review(remote: RemoteURL, branch: String) async -> ReviewInfo {
        let key = Key(remote: remote, branch: branch)
        if let answer = kept[key] {
            if ContinuousClock.now < answer.until { return answer.info }
            kept[key] = nil
        }
        if let running = pending[key] { return await running.task.value }

        // The request is a task of its own, so that callers that come while it is out can wait for it, and so that
        // while it is, this actor is free: it is not held for the network, and not for the host of one request.
        let (detector, tokens, session, deadline) = (self.detector, self.tokens, self.session, self.deadline)
        let started = generation
        let task = Task {
            let outcome = await Self.lookUp(branch, of: remote, detector, tokens, session, within: deadline)
            return self.finish(outcome, of: key, startedIn: started)
        }
        pending[key] = Pending(generation: started, task: task)
        return await task.value
    }

    public func lastError(host: String) -> String? {
        errors[host.lowercased()]
    }

    public func invalidate() {
        generation += 1
        kept.removeAll()
        // Whoever asks next does not join a request that is out, since it is not the one that they need. Its own
        // callers still get its answer, and it is not kept (see `finish`).
        pending.removeAll()
    }

    /// Takes in what a request has come to, and gives the answer that its callers get.
    private func finish(_ outcome: Result<ReviewInfo, any Error>, of key: Key, startedIn started: Int) -> ReviewInfo {
        // The entry is this request's, unless `invalidate()` took it away and a later request put its own there.
        if pending[key]?.generation == started { pending[key] = nil }
        switch outcome {
        case .success(let info) where info.state != .unknown:
            errors[key.remote.host] = nil
            // An answer to a request that was made before `invalidate()` is the one that was meant to be forgotten.
            if started == generation { kept[key] = Kept(info: info, until: .now + ttl) }
            return info
        case .success:
            return .unknown
        case .failure(let error):
            errors[key.remote.host] = error.localizedDescription
            return .unknown
        }
    }

    // MARK: Asking

    /// The request of `branch` in the project of `remote`, or what went wrong, within `deadline`. It does not use the
    /// state of the actor: it runs apart from it, and what it finds is put in by `finish`.
    private static func lookUp(
        _ branch: String, of remote: RemoteURL, _ detector: HostingDetector, _ tokens: any TokenStoring,
        _ session: URLSession, within deadline: Duration
    ) async -> Result<ReviewInfo, any Error> {
        await withTaskGroup(of: Result<ReviewInfo, any Error>.self) { group in
            group.addTask { await ask(for: branch, of: remote, detector, tokens, session) }
            group.addTask {
                try? await Task.sleep(for: deadline)
                return .failure(URLError(.timedOut))
            }
            defer { group.cancelAll() }  // whichever came second is not waited for
            return await group.next() ?? .failure(URLError(.timedOut))
        }
    }

    private static func ask(
        for branch: String, of remote: RemoteURL, _ detector: HostingDetector, _ tokens: any TokenStoring,
        _ session: URLSession
    ) async -> Result<ReviewInfo, any Error> {
        do {
            let kind = await detector.kind(for: remote.host)
            guard kind != .unsupported else { throw ReviewError.hostNotRecognized }
            // A store that cannot be read is not one without a token: asking without would read a private project as
            // if it were not one, and say what is not so. (It also blocks until the Keychain answers, and so it is not
            // done on the actor.)
            let token: String?
            do {
                token = try tokens.token(for: remote.host)
            } catch {
                throw ReviewError.tokenUnreadable(error.localizedDescription)
            }
            let client: any ReviewProviding =
                kind == .gitlab
                ? GitLabClient(host: remote.host, token: token, session: session)
                : GitHubClient(host: remote.host, token: token, session: session)
            return .success(try await client.review(remote: remote, branch: branch))
        } catch {
            return .failure(error)
        }
    }
}
