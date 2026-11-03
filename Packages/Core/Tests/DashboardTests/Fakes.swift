import CoreModels
import Dashboard
import Discovery
import DiskUsage
import Foundation
import GitKit
import Hosting
import ProcessKit
import Safety
import Shell
import Synchronization
import TestSupport
import Testing

// Stand-ins for everything the store reads, runs and writes through. None of them touches a repository, the network,
// the Keychain or a process: they answer as the test says, and note what they were asked.

let fakeError = GitError.failed(command: "git (fake)", exitCode: 128, stderr: "fake failure")

/// A commit id as git prints it.
func sha(_ character: Character) -> String { String(repeating: character, count: 40) }

// MARK: Git

final class FakeGit: GitReading {
    /// What the fake knows of one repository.
    struct Repo: Sendable {
        var worktrees: [Worktree]
        /// By worktree path. A worktree that has none has a status that cannot be read.
        var statuses: [String: WorktreeStatus] = [:]
        /// By branch, `(no branch)` for the stashes of a detached HEAD. None is 0.
        var stashes: [String: Int] = [:]
        var stashFails = false
        var remotes: [Remote] = []
        /// By worktree path. None is 0.
        var notOnRemote: [String: Int] = [:]
        var notOnRemoteFails: Set<String> = []
        /// By the commit asked about: whether HEAD is it or one of its ancestors. None is a commit that is not there.
        var ancestry: [String: Bool] = [:]
        var fetchFails = false
    }

    enum Call: Equatable, Sendable {
        case worktrees(String), status(String), stash(String, branch: String), remotes(String), notOnRemote(String)
        case ancestor(String, of: String), fetch(String)
    }

    private struct State {
        var repos: [String: Repo] = [:]
        var calls: [Call] = []
        var running = 0
        var maxRunning = 0
    }

    private let state = Mutex(State())
    /// How long each call takes. Zero answers at once.
    let callTime: Duration

    init(callTime: Duration = .zero) {
        self.callTime = callTime
    }

    func set(_ path: String, _ repo: Repo) { state.withLock { $0.repos[path] = repo } }
    func update(_ path: String, _ change: (inout Repo) -> Void) {
        state.withLock { state in
            guard var repo = state.repos[path] else { return }
            change(&repo)
            state.repos[path] = repo
        }
    }
    func forget(_ path: String) { state.withLock { $0.repos[path] = nil } }

    var calls: [Call] { state.withLock { $0.calls } }
    var maxRunning: Int { state.withLock { $0.maxRunning } }
    func count(_ isWanted: (Call) -> Bool) -> Int { calls.filter(isWanted).count }

    private func call<T>(_ call: Call, _ answer: (State) throws -> T) async throws -> T {
        state.withLock {
            $0.calls.append(call)
            $0.running += 1
            $0.maxRunning = max($0.maxRunning, $0.running)
        }
        if callTime > .zero { try? await Task.sleep(for: callTime) }
        defer { state.withLock { $0.running -= 1 } }
        return try state.withLock { try answer($0) }
    }

    private static func repo(_ path: String, in state: State) throws -> Repo {
        guard let repo = state.repos[path] else { throw fakeError }
        return repo
    }

    private static func repo(holding worktree: String, in state: State) throws -> Repo {
        guard let repo = state.repos.values.first(where: { $0.worktrees.contains { $0.path == worktree } }) else {
            throw fakeError
        }
        return repo
    }

    func worktrees(repo: URL) async throws -> [Worktree] {
        try await call(.worktrees(repo.path)) { try Self.repo(repo.path, in: $0).worktrees }
    }

    func status(worktree: URL) async throws -> WorktreeStatus {
        try await call(.status(worktree.path)) { state in
            guard let status = try Self.repo(holding: worktree.path, in: state).statuses[worktree.path] else {
                throw fakeError
            }
            return status
        }
    }

    func stashCount(repo: URL, branch: String) async throws -> Int {
        try await call(.stash(repo.path, branch: branch)) { state in
            let found = try Self.repo(repo.path, in: state)
            if found.stashFails { throw fakeError }
            return found.stashes[branch] ?? 0
        }
    }

    func remotes(repo: URL) async throws -> [Remote] {
        try await call(.remotes(repo.path)) { try Self.repo(repo.path, in: $0).remotes }
    }

    func commitsNotOnAnyRemote(worktree: URL) async throws -> Int {
        try await call(.notOnRemote(worktree.path)) { state in
            let found = try Self.repo(holding: worktree.path, in: state)
            if found.notOnRemoteFails.contains(worktree.path) { throw fakeError }
            return found.notOnRemote[worktree.path] ?? 0
        }
    }

    func isAncestorOrEqual(_ commit: String, of other: String, repo: URL) async throws -> Bool? {
        try await call(.ancestor(commit, of: other)) { try Self.repo(repo.path, in: $0).ancestry[other] }
    }

    func fetchPrune(repo: URL) async throws {
        try await call(.fetch(repo.path)) { state in
            if try Self.repo(repo.path, in: state).fetchFails { throw fakeError }
        }
    }
}

// MARK: Hosting

final class FakeReviews: ReviewLooking {
    struct Lookup: Equatable, Sendable {
        let host: String
        let project: String
        let branch: String
    }

    private struct State {
        var answers: [String: ReviewInfo] = [:]
        var lookups: [Lookup] = []
        var invalidations = 0
        var running = 0
        var maxRunning = 0
    }

    private let state = Mutex(State())
    let lookupTime: Duration

    init(lookupTime: Duration = .zero) {
        self.lookupTime = lookupTime
    }

    /// From now on, `branch` has `info`. A branch without an answer has no request (`.none`).
    func answer(_ branch: String, _ info: ReviewInfo) { state.withLock { $0.answers[branch] = info } }

    var lookups: [Lookup] { state.withLock { $0.lookups } }
    var invalidations: Int { state.withLock { $0.invalidations } }
    var maxRunning: Int { state.withLock { $0.maxRunning } }

    func review(remote: RemoteURL, branch: String) async -> ReviewInfo {
        state.withLock {
            $0.lookups.append(Lookup(host: remote.host, project: remote.projectPath, branch: branch))
            $0.running += 1
            $0.maxRunning = max($0.maxRunning, $0.running)
        }
        if lookupTime > .zero { try? await Task.sleep(for: lookupTime) }
        return state.withLock {
            $0.running -= 1
            return $0.answers[branch] ?? .none
        }
    }

    func lastError(host: String) async -> String? { nil }

    func invalidate() async { state.withLock { $0.invalidations += 1 } }
}

final class FakeHosting: HostingDetecting {
    private let asked = Mutex<[String]>([])
    private let chosen = Mutex<[String: HostingKind]>([:])
    private let kinds: [String: HostingKind]

    /// Every host runs GitLab, but those that `kinds` names.
    init(_ kinds: [String: HostingKind] = [:]) {
        self.kinds = kinds
    }

    var hostsAsked: [String] { asked.withLock { $0 } }
    /// What the user has set, by host, as the model told this detector.
    var overrides: [String: HostingKind] { chosen.withLock { $0 } }

    func kind(for host: String) async -> HostingKind {
        asked.withLock { $0.append(host) }
        return chosen.withLock { $0[host] } ?? kinds[host] ?? .gitlab
    }

    func setOverride(_ kind: HostingKind?, for host: String) async {
        chosen.withLock { $0[host] = kind }
    }
}

/// No token for any host, and the Keychain is never asked.
struct NoTokens: TokenStoring {
    func token(for host: String) throws -> String? { nil }
    func setToken(_ token: String?, for host: String) throws {}
}

/// Answers every request with 401, as a host does that wants a token. Only the sessions of `Unauthorized.session()` use
/// it, so no request can leave the test.
final class Unauthorized: URLProtocol {
    static func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [Unauthorized.self]
        return URLSession(configuration: configuration)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url,
            let response = HTTPURLResponse(url: url, statusCode: 401, httpVersion: "HTTP/1.1", headerFields: [:])
        else { return client?.urlProtocol(self, didFailWithError: URLError(.badURL)) ?? () }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(#"{"message":"401 Unauthorized"}"#.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

// MARK: Disk

final class FakeScanner: RepoScanning {
    private struct State {
        var found: [URL]
        var scans = 0
    }

    private let state: Mutex<State>
    private let roots: [URL]
    private let hangs: Bool

    /// A scan of `roots` that finds `found`, or that never ends until it is cancelled.
    init(roots: [URL] = [URL(filePath: "/")], found: [String] = [], hangs: Bool = false) {
        self.roots = roots
        self.hangs = hangs
        state = Mutex(State(found: found.map { URL(filePath: $0, directoryHint: .isDirectory) }))
    }

    var scans: Int { state.withLock { $0.scans } }
    var found: [String] { state.withLock { $0.found.map(\.path) } }
    func willFind(_ paths: [String]) { state.withLock { $0.found = paths.map { URL(filePath: $0) } } }

    func scan(roots: [URL], rules: ExclusionRules, isCancelled: @Sendable () -> Bool) async -> [URL] {
        state.withLock { $0.scans += 1 }
        if hangs {
            while !Task.isCancelled, !isCancelled() { try? await Task.sleep(for: .milliseconds(5)) }
            return []
        }
        return state.withLock { $0.found }
    }

    func defaultRoots(rules: ExclusionRules) -> [URL] { roots }
}

final class FakeSizes: SizeMeasuring {
    struct Measurement: Equatable, Sendable {
        let path: String
        let excluding: Set<String>
    }

    private struct State {
        var sizes: [String: SizeInfo] = [:]
        var measured: [Measurement] = []
    }

    private let state = Mutex(State())

    /// Every folder takes 1 GB and frees 0.1 GB, but those that are given a size here.
    func set(_ path: String, _ size: SizeInfo) { state.withLock { $0.sizes[path] = size } }
    var measured: [Measurement] { state.withLock { $0.measured } }

    func measure(_ root: URL, excluding: Set<String>, isCancelled: @Sendable () -> Bool) throws -> SizeInfo {
        state.withLock { state in
            state.measured.append(Measurement(path: root.path, excluding: excluding))
            return state.sizes[root.path]
                ?? SizeInfo(apparentBytes: 1_000_000_000, privateBytes: 100_000_000, computedAt: .distantPast)
        }
    }
}

final class FakeWatcher: FileWatching {
    final class Token {}

    struct Watch: Sendable {
        let paths: [String]
        let latency: Duration
        let onChange: @Sendable ([String]) -> Void
        nonisolated(unsafe) weak var token: Token?
    }

    private let watches = Mutex<[Watch]>([])

    var all: [Watch] { watches.withLock { $0 } }
    /// The watches that are on: their token has not been released.
    var live: [Watch] { all.filter { $0.token != nil } }

    func watch(paths: [String], latency: Duration, onChange: @escaping @Sendable ([String]) -> Void) -> AnyObject {
        let token = Token()
        watches.withLock { $0.append(Watch(paths: paths, latency: latency, onChange: onChange, token: token)) }
        return token
    }

    /// Reports `changed` to the latest watch that is on and watches `path`, as FSEvents would. Returns whether there
    /// was one.
    @discardableResult
    func send(_ changed: [String], toWatchOf path: String) -> Bool {
        guard let watch = live.last(where: { $0.paths.contains(path) }) else { return false }
        watch.onChange(changed)
        return true
    }
}

// MARK: Processes

final class FakeSampler: ProcessSampling {
    private let state = Mutex<(processes: [ProcessRecord], samples: Int)>(([], 0))

    var samples: Int { state.withLock { $0.samples } }
    func set(_ processes: [ProcessRecord]) { state.withLock { $0.processes = processes } }

    func sample() -> [ProcessRecord] {
        state.withLock {
            $0.samples += 1
            return $0.processes
        }
    }
}

final class FakeSignaler: ProcessSignaling {
    private let alive: Mutex<Set<Int32>>

    init(alive: Set<Int32> = []) {
        self.alive = Mutex(alive)
    }

    func signal(_ pid: Int32, _ sig: Int32) -> Bool { false }
    func isAlive(_ pid: Int32) -> Bool { alive.withLock { $0.contains(pid) } }
}

/// A process for a sample: it runs in `cwd`, and nothing else about it matters.
func process(_ pid: Int32, parent: Int32 = 1, name: String = "node", cwd: String) -> ProcessRecord {
    ProcessRecord(
        pid: pid, ppid: parent, name: name, executablePath: "/usr/bin/\(name)", arguments: [name], cwd: cwd,
        footprintBytes: 1 << 20, startDate: Date(timeIntervalSince1970: 1_800_000_000), listeningPorts: [])
}

/// Removes worktrees as `WorktreeRemoving` promises: the main worktree and a missing one are refused, then `recheck`
/// is asked once, and only `.ready`, or `.manual` for a request that was confirmed as manual, with nothing running goes
/// on, to `removal`.
final class FakeRemover: WorktreeRemoving {
    private struct State {
        var requests: [RemovalRequest] = []
        var rechecks: [RemovalEligibility] = []
        var pruned: [String] = []
        var running: [String: Int] = [:]
        var maxRunningInOneRepo = 0
        var runningRepos: Set<String> = []
        var removal: @Sendable (RemovalRequest) async throws -> Void = { _ in }
        var prune: @Sendable (String) async throws -> Void = { _ in }
    }

    private let state = Mutex(State())

    var requests: [RemovalRequest] { state.withLock { $0.requests } }
    var rechecks: [RemovalEligibility] { state.withLock { $0.rechecks } }
    var pruned: [String] { state.withLock { $0.pruned } }
    var maxRunningInOneRepo: Int { state.withLock { $0.maxRunningInOneRepo } }
    /// The repositories in which a removal is under way now.
    var runningRepos: Set<String> { state.withLock { $0.runningRepos } }

    /// What deleting the worktree does, once the recheck has let it through.
    func onRemoval(_ removal: @escaping @Sendable (RemovalRequest) async throws -> Void) {
        state.withLock { $0.removal = removal }
    }

    func onPrune(_ prune: @escaping @Sendable (String) async throws -> Void) {
        state.withLock { $0.prune = prune }
    }

    func remove(_ request: RemovalRequest, recheck: @Sendable () async -> RemovalEligibility) async throws {
        let repo = request.repo.path
        let removal = state.withLock { state in
            state.requests.append(request)
            state.running[repo, default: 0] += 1
            state.runningRepos.insert(repo)
            state.maxRunningInOneRepo = max(state.maxRunningInOneRepo, state.running[repo] ?? 0)
            return state.removal
        }
        defer {
            state.withLock { state in
                state.running[repo, default: 1] -= 1
                if state.running[repo] == 0 { state.runningRepos.remove(repo) }
            }
        }
        guard !request.worktree.isMain else { throw RemovalError.stateChanged(.mainWorktree) }
        guard !request.worktree.isPrunable else { throw RemovalError.stateChanged(.missing) }
        let eligibility = await recheck()
        state.withLock { $0.rechecks.append(eligibility) }
        switch (eligibility, request.confirmedAs) {
        case (.ready(needsStopping: false), _), (.manual(needsStopping: false), .manual): break
        default: throw RemovalError.stateChanged(eligibility)
        }
        try await removal(request)
    }

    func prune(repo: URL) async throws {
        let prune = state.withLock { state in
            state.pruned.append(repo.path)
            return state.prune
        }
        try await prune(repo.path)
    }
}

// MARK: Accounts

/// Tokens in memory, so that no test reads or writes the Keychain. It remembers every write.
final class FakeTokens: TokenStoring {
    private struct State {
        var tokens: [String: String]
        var writes: [String] = []
        var readError: (any Error)?
        var writeError: (any Error)?
    }

    private let state: Mutex<State>

    init(_ tokens: [String: String] = [:]) {
        state = Mutex(State(tokens: tokens))
    }

    /// The hosts whose token was written or removed, in order.
    var writes: [String] { state.withLock { $0.writes } }
    func failReads(with error: any Error) { state.withLock { $0.readError = error } }
    func failWrites(with error: (any Error)?) { state.withLock { $0.writeError = error } }

    func token(for host: String) throws -> String? {
        try state.withLock { state in
            if let error = state.readError { throw error }
            return state.tokens[host.lowercased()]
        }
    }

    func setToken(_ token: String?, for host: String) throws {
        try state.withLock { state in
            if let error = state.writeError { throw error }
            state.writes.append(host.lowercased())
            state.tokens[host.lowercased()] = (token?.isEmpty ?? true) ? nil : token
        }
    }
}

/// `glab` and `gh` as stand-ins: each is there or not, and prints what the test says. The real tools are never run, so
/// no real token is read.
final class FakeTools: CommandRunning {
    private let installed: Set<String>
    private let printed: [String: String]
    private let ran = Mutex<[String]>([])

    /// `printed` is by tool: what it prints as a token.
    init(installed: Set<String> = ["glab", "gh"], printed: [String: String] = [:]) {
        self.installed = installed
        self.printed = printed
    }

    var commands: [String] { ran.withLock { $0 } }

    func run(_ tool: String, _ args: [String], in directory: URL?, timeout: Duration) async throws -> CommandResult {
        ran.withLock { $0.append(([tool] + args).joined(separator: " ")) }
        guard installed.contains(tool) else { throw CommandError.notFound(tool) }
        guard let output = printed[tool] else { return CommandResult(exitCode: 1, stdout: "", stderr: "no token") }
        return CommandResult(exitCode: 0, stdout: output + "\n", stderr: "")
    }

    func which(_ tool: String) -> URL? {
        installed.contains(tool) ? URL(filePath: "/opt/fake/bin/\(tool)") : nil
    }
}
