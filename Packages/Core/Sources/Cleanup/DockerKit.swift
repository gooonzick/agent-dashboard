import Foundation
import Shell

public enum DockerRuntimeKind: String, Sendable, Equatable { case colima, desktop, orbstack }

/// The Docker VM the current docker context talks to.
public struct DockerRuntime: Sendable, Equatable {
    public let kind: DockerRuntimeKind
    /// The name of the docker context.
    public let context: String
    /// The colima profile; `nil` for the other runtimes.
    public let profile: String?
    public let isRunning: Bool
    /// The file or folder that holds the disk of the VM on the host.
    public let diskPath: String?
    /// What the VM may use at most (colima: `disk`), in bytes.
    public let diskLimit: UInt64?
    public let cpus: Int?
    /// In bytes.
    public let memory: UInt64?

    public init(
        kind: DockerRuntimeKind, context: String, profile: String?, isRunning: Bool, diskPath: String?,
        diskLimit: UInt64?, cpus: Int?, memory: UInt64?
    ) {
        self.kind = kind
        self.context = context
        self.profile = profile
        self.isRunning = isRunning
        self.diskPath = diskPath
        self.diskLimit = diskLimit
        self.cpus = cpus
        self.memory = memory
    }
}

public enum DockerStatus: Sendable, Equatable {
    /// There is no `docker` on the search paths.
    case notInstalled
    /// The context exists, but it is not colima, Docker Desktop or OrbStack.
    case unknownContext(String)
    /// `docker context show` or `docker context inspect` failed, so there is no telling which runtime this is. The page
    /// says that Docker did not answer.
    case notAnswering
    case runtime(DockerRuntime)
}

public protocol DockerControlling: Sendable {
    func status() async -> DockerStatus
    /// What the VM holds. Only a running VM answers.
    func inventory() async throws -> DockerInventory
    /// `colima start <profile>`, `open -a Docker` or `orbctl start`. Docker Desktop is only asked to open: it may take
    /// a while to answer after this returns, so the caller reads `status()` again.
    func start(_ runtime: DockerRuntime) async throws
    /// `docker image prune -a -f`: the bytes it reclaimed.
    func removeUnusedImages() async throws -> UInt64
    /// `docker container prune -f`: the bytes it reclaimed. Volumes and the build cache are never touched.
    func removeStoppedContainers() async throws -> UInt64
}

/// What a command said when it failed: the line of its stderr that names the error (colima writes progress lines
/// before it), or else the first line there is.
public struct DockerError: Error, Equatable {
    public let message: String

    public init(message: String) { self.message = message }
}

/// Finds the Docker runtime from the docker context and drives it with the `docker` CLI and the tool of its runtime.
public struct DockerController: DockerControlling {
    private static let queryTimeout: Duration = .seconds(15)
    private static let startTimeout: Duration = .seconds(180)
    private static let pruneTimeout: Duration = .seconds(300)

    private let runner: any CommandRunning
    private let home: URL
    private let environment: [String: String]
    private let resolve: @Sendable (String) -> String?

    /// `environment` is where `DOCKER_CONTEXT` is looked up; it names the context before `docker context show` does.
    /// `resolve` gives a path as the file system resolves it, or `nil` when it cannot: a socket that is a link is
    /// followed with it.
    public init(
        runner: any CommandRunning, home: URL, environment: [String: String] = ProcessInfo.processInfo.environment,
        resolve: @escaping @Sendable (String) -> String? = DockerController.resolved
    ) {
        self.runner = runner
        self.home = home
        self.environment = environment
        self.resolve = resolve
    }

    public func status() async -> DockerStatus {
        guard runner.which("docker") != nil else { return .notInstalled }
        guard let context = await currentContext(), let endpoint = await endpoint(of: context) else {
            return .notAnswering
        }
        let root = home.path
        let (kind, disk): (DockerRuntimeKind, String)
        switch Self.socket(endpoint, under: root) ?? linkedSocket(endpoint) {
        case .colima(let profile)?:
            return .runtime(await colima(context: context, profile: profile))
        case .desktop?:
            (kind, disk) = (.desktop, "\(root)/Library/Containers/com.docker.docker/Data/vms/0/data")
        case .orbstack?:
            (kind, disk) = (.orbstack, "\(root)/Library/Group Containers/HUAB2SQ2CL.dev.kdrag0n.MacVirt/data")
        case nil:
            return .unknownContext(context)
        }
        return .runtime(
            DockerRuntime(
                kind: kind, context: context, profile: nil, isRunning: await dockerAnswers(), diskPath: disk,
                diskLimit: nil, cpus: nil, memory: nil))
    }

    public func inventory() async throws -> DockerInventory {
        async let images = output("docker", ["image", "ls", "-a", "--format", "json"], timeout: Self.queryTimeout)
        async let containers = output("docker", ["ps", "-a", "--size", "--format", "json"], timeout: Self.queryTimeout)
        async let usage = output("docker", ["system", "df", "--format", "json"], timeout: Self.queryTimeout)
        return try await DockerParsers.inventory(images: images, containers: containers, usage: usage)
    }

    public func start(_ runtime: DockerRuntime) async throws {
        switch runtime.kind {
        case .colima:
            try await output("colima", ["start", runtime.profile ?? "default"], timeout: Self.startTimeout)
        case .desktop:
            try await output("open", ["-a", "Docker"], timeout: Self.startTimeout)
        case .orbstack:
            try await output("orbctl", ["start"], timeout: Self.startTimeout)
        }
    }

    public func removeUnusedImages() async throws -> UInt64 {
        reclaimed(in: try await output("docker", ["image", "prune", "-a", "-f"], timeout: Self.pruneTimeout))
    }

    public func removeStoppedContainers() async throws -> UInt64 {
        reclaimed(in: try await output("docker", ["container", "prune", "-f"], timeout: Self.pruneTimeout))
    }

    // MARK: - Runtime

    /// The socket of a runtime that this knows, and the colima profile it belongs to.
    private enum KnownSocket: Equatable {
        case colima(profile: String)
        case desktop, orbstack
    }

    /// Which runtime `endpoint` is the socket of, for a home at `root`; `nil` for any other endpoint.
    private static func socket(_ endpoint: String, under root: String) -> KnownSocket? {
        let colima = "unix://\(root)/.colima/"
        if endpoint.hasPrefix(colima), endpoint.hasSuffix("/docker.sock") {
            return .colima(profile: String(endpoint.dropFirst(colima.count).dropLast("/docker.sock".count)))
        }
        switch endpoint {
        case "unix://\(root)/.docker/run/docker.sock": return .desktop
        case "unix://\(root)/.orbstack/run/docker.sock": return .orbstack
        default: return nil
        }
    }

    /// The runtime whose socket `endpoint` is a link to. The `default` context talks to `/var/run/docker.sock`, which
    /// Docker Desktop and OrbStack link to their own socket in home. The home is tried resolved too, since the link
    /// leads to the resolved path.
    private func linkedSocket(_ endpoint: String) -> KnownSocket? {
        guard endpoint.hasPrefix("unix://"), let target = resolve(String(endpoint.dropFirst("unix://".count))) else {
            return nil
        }
        let roots = [home.path] + [resolve(home.path)].compactMap { $0 }.filter { $0 != home.path }
        return roots.lazy.compactMap { Self.socket("unix://" + target, under: $0) }.first
    }

    /// `path` as `realpath` resolves it, or `nil` when it does not exist.
    public static func resolved(_ path: String) -> String? {
        guard let resolved = realpath(path, nil) else { return nil }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    private func currentContext() async -> String? {
        if let named = environment["DOCKER_CONTEXT"], !named.isEmpty { return named }
        guard let shown = try? await output("docker", ["context", "show"], timeout: Self.queryTimeout) else {
            return nil
        }
        let name = shown.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? nil : name
    }

    /// The `Host` of the docker endpoint of `context`.
    private func endpoint(of context: String) async -> String? {
        guard let json = try? await output("docker", ["context", "inspect", context], timeout: Self.queryTimeout),
            let contexts = (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [[String: Any]],
            let endpoints = contexts.first?["Endpoints"] as? [String: Any],
            let docker = endpoints["docker"] as? [String: Any]
        else { return nil }
        return docker["Host"] as? String
    }

    private func dockerAnswers() async -> Bool {
        (try? await output("docker", ["info"], timeout: Self.queryTimeout)) != nil
    }

    /// `colima list` knows the profile's limits and whether it runs. Without `colima`, or when it does not list the
    /// profile, only `docker info` can say whether the VM runs.
    private func colima(context: String, profile: String) async -> DockerRuntime {
        // Lima names the disk of the default profile `colima` and the disk of any other `colima-<profile>`.
        let disk = "\(home.path)/.colima/_lima/_disks/" + (profile == "default" ? "colima" : "colima-\(profile)")
        var listed: [String: Any]?
        if runner.which("colima") != nil,
            let list = try? await output("colima", ["list", "--json"], timeout: Self.queryTimeout)
        {
            listed = DockerParsers.lines(list).first { $0["name"] as? String == profile }
        }
        let isRunning: Bool
        if let listed {
            isRunning = listed["status"] as? String == "Running"
        } else {
            isRunning = await dockerAnswers()
        }
        return DockerRuntime(
            kind: .colima, context: context, profile: profile, isRunning: isRunning, diskPath: disk,
            diskLimit: (listed?["disk"] as? NSNumber)?.uint64Value, cpus: (listed?["cpus"] as? NSNumber)?.intValue,
            memory: (listed?["memory"] as? NSNumber)?.uint64Value)
    }

    // MARK: - Commands

    /// The stdout of `tool` when it exits with 0; otherwise a `DockerError` that holds the first line of its stderr.
    @discardableResult
    private func output(_ tool: String, _ args: [String], timeout: Duration) async throws -> String {
        let result: CommandResult
        do {
            result = try await runner.run(tool, args, in: nil, timeout: timeout)
        } catch CommandError.notFound(let missing) {
            throw DockerError(message: "\(missing) is not installed")
        } catch CommandError.timedOut(let slow) {
            throw DockerError(message: "\(slow) did not answer in time")
        }
        guard result.exitCode == 0 else {
            let line = firstErrorLine(in: result.stderr)
            throw DockerError(message: line ?? "\(tool) failed with exit code \(result.exitCode)")
        }
        return result.stdout
    }

    /// The number after `Total reclaimed space:`, or 0 when the output has none.
    private func reclaimed(in output: String) -> UInt64 {
        let marker = "Total reclaimed space:"
        let line = output.split(whereSeparator: \.isNewline).first { $0.hasPrefix(marker) }
        return line.flatMap { DockerSize.bytes(String($0.dropFirst(marker.count))) } ?? 0
    }
}
