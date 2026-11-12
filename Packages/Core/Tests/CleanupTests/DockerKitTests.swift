import CoreModels
import Foundation
import Synchronization
import Testing

@testable import Cleanup
@testable import Shell

private let home = URL(filePath: "/Users/x")

/// The recorded output `name` in `Fixtures/docker`, as the tool printed it.
private func recorded(_ name: String, _ ext: String = "json") throws -> String {
    let url = try #require(Bundle.module.url(forResource: name, withExtension: ext, subdirectory: "Fixtures/docker"))
    return try String(contentsOf: url, encoding: .utf8)
}

/// The answers of a machine whose current context is `context`, with `inspect` as its `docker context inspect`.
private func answers(context: String, inspect: String, running: Bool = true) throws -> [String: CommandResult] {
    [
        "docker context show": ok(context + "\n"),
        "docker context inspect \(context)": ok(try recorded(inspect)),
        "docker info": running ? ok("Server: ok") : CommandResult(exitCode: 1, stdout: "", stderr: "Cannot connect"),
        "colima list --json": ok(try recorded("colima-list")),
    ]
}

private func controller(_ runner: FakeDocker, environment: [String: String] = [:]) -> DockerController {
    DockerController(runner: runner, home: home, environment: environment)
}

@Suite("DockerController")
struct DockerKitTests {
    @Test func colimaIsFoundFromTheContextEndpoint() async throws {
        let runner = FakeDocker(answers: try answers(context: "colima", inspect: "context-colima"))

        let status = await controller(runner).status()

        let expected = DockerRuntime(
            kind: .colima, context: "colima", profile: "default", isRunning: true,
            diskPath: "/Users/x/.colima/_lima/_disks/colima", diskLimit: 100 * 1024 * 1024 * 1024, cpus: 4,
            memory: 8 * 1024 * 1024 * 1024)
        #expect(status == .runtime(expected))
    }

    @Test func aStoppedColimaProfileIsNotRunning() async throws {
        var answers = try answers(context: "colima", inspect: "context-colima")
        answers["colima list --json"] = ok(
            #"{"name":"default","status":"Stopped","arch":"aarch64","cpus":2,"memory":4294967296,"disk":53687091200}"#)
        let status = await controller(FakeDocker(answers: answers)).status()

        guard case .runtime(let runtime) = status else {
            Issue.record("not a runtime: \(status)")
            return
        }
        #expect(!runtime.isRunning)
        #expect(runtime.cpus == 2)
    }

    @Test func aColimaProfileOtherThanTheDefaultKeepsItsOwnDisk() async throws {
        var answers = try answers(context: "colima-work", inspect: "context-colima")
        answers["docker context inspect colima-work"] = ok(
            try recorded("context-colima").replacingOccurrences(of: "default/docker.sock", with: "work/docker.sock"))
        let status = await controller(FakeDocker(answers: answers)).status()

        guard case .runtime(let runtime) = status else {
            Issue.record("not a runtime: \(status)")
            return
        }
        #expect(runtime.profile == "work")
        #expect(runtime.diskPath == "/Users/x/.colima/_lima/_disks/colima-work")
        #expect(!runtime.isRunning)
        #expect(runtime.cpus == 2)
    }

    @Test func colimaWithoutTheToolStillReportsWhetherDockerAnswers() async throws {
        let runner = FakeDocker(
            installed: ["docker"], answers: try answers(context: "colima", inspect: "context-colima"))

        let status = await controller(runner).status()

        guard case .runtime(let runtime) = status else {
            Issue.record("not a runtime: \(status)")
            return
        }
        #expect(runtime.kind == .colima)
        #expect(runtime.isRunning)
        #expect(runtime.cpus == nil && runtime.memory == nil && runtime.diskLimit == nil)
    }

    @Test func desktopIsFoundFromTheContextEndpoint() async throws {
        let runner = FakeDocker(answers: try answers(context: "desktop-linux", inspect: "context-desktop"))

        let status = await controller(runner).status()

        let expected = DockerRuntime(
            kind: .desktop, context: "desktop-linux", profile: nil, isRunning: true,
            diskPath: "/Users/x/Library/Containers/com.docker.docker/Data/vms/0/data", diskLimit: nil, cpus: nil,
            memory: nil)
        #expect(status == .runtime(expected))
    }

    @Test func desktopThatDoesNotAnswerIsNotRunning() async throws {
        let runner = FakeDocker(
            answers: try answers(context: "desktop-linux", inspect: "context-desktop", running: false))

        guard case .runtime(let runtime) = await controller(runner).status() else {
            Issue.record("not a runtime")
            return
        }
        #expect(!runtime.isRunning)
    }

    @Test func orbstackIsFoundFromTheContextEndpoint() async throws {
        let runner = FakeDocker(answers: try answers(context: "orbstack", inspect: "context-orbstack"))

        let status = await controller(runner).status()

        let expected = DockerRuntime(
            kind: .orbstack, context: "orbstack", profile: nil, isRunning: true,
            diskPath: "/Users/x/Library/Group Containers/HUAB2SQ2CL.dev.kdrag0n.MacVirt/data", diskLimit: nil,
            cpus: nil, memory: nil)
        #expect(status == .runtime(expected))
    }

    @Test func anUnknownContextIsNamed() async throws {
        let runner = FakeDocker(answers: try answers(context: "remote", inspect: "context-remote"))

        #expect(await controller(runner).status() == .unknownContext("remote"))
    }

    @Test func noDockerCLI() async throws {
        let runner = FakeDocker(installed: [], answers: [:])

        #expect(await controller(runner).status() == .notInstalled)
        #expect(runner.calls.isEmpty)
    }

    @Test func theEnvironmentNamesTheContextBeforeDockerDoes() async throws {
        let runner = FakeDocker(answers: try answers(context: "orbstack", inspect: "context-orbstack"))

        _ = await controller(runner, environment: ["DOCKER_CONTEXT": "orbstack"]).status()

        #expect(!runner.calls.contains { $0.line == "docker context show" })
        #expect(runner.calls.contains { $0.line == "docker context inspect orbstack" })
    }

    @Test func statusGivesEachCommandFifteenSeconds() async throws {
        let runner = FakeDocker(answers: try answers(context: "colima", inspect: "context-colima"))

        _ = await controller(runner).status()

        #expect(!runner.calls.isEmpty)
        #expect(runner.calls.allSatisfy { $0.timeout == .seconds(15) })
    }

    @Test func inventoryReadsImagesContainersAndProjects() async throws {
        let runner = FakeDocker(answers: [
            "docker image ls -a --format json": ok(try recorded("image-ls")),
            "docker ps -a --size --format json": ok(try recorded("ps")),
            "docker system df --format json": ok(try recorded("system-df")),
        ])

        let inventory = try await controller(runner).inventory()

        #expect(inventory.images.map(\.name) == ["minuta-api:latest", "postgres:16", "node:20", "dddddddddddd"])
        #expect(inventory.images.map(\.isUnused) == [false, false, true, true])
        #expect(inventory.images.map(\.size) == [1_200_000_000, 719_000_000, 1_100_000_000, 24_580])
        #expect(inventory.containers.map(\.name) == ["minuta-api-1", "scratch-db"])
        #expect(inventory.containers.map(\.isRunning) == [true, false])
        #expect(inventory.containers.map(\.size) == [24_600, 63])
        #expect(inventory.containers.map(\.project) == ["/Users/x/Development/minuta", nil])
        #expect(inventory.volumesSize == 310_500_000)
        #expect(inventory.buildCacheSize == 1_500_000_000)
        #expect(runner.calls.allSatisfy { $0.timeout == .seconds(15) })
    }

    @Test func anImageThatAContainerNamesByItsIDIsUsed() async throws {
        let runner = FakeDocker(answers: [
            "docker image ls -a --format json": ok(
                #"{"ID":"sha256:aaaaaaaaaaaaffff","Repository":"node","Tag":"20","Size":"1.1GB"}"#),
            "docker ps -a --size --format json": ok(
                #"{"ID":"1","Image":"aaaaaaaaaaaa","Names":"n","State":"exited","Size":"0B (virtual 1.1GB)"}"#),
            "docker system df --format json": ok(""),
        ])

        let inventory = try await controller(runner).inventory()

        #expect(inventory.images.map(\.isUnused) == [false])
        #expect(inventory.volumesSize == 0 && inventory.buildCacheSize == 0)
    }

    @Test func anImageIsInUseWhenAnyTagOfItsIDIs() async throws {
        let runner = FakeDocker(answers: [
            "docker image ls -a --format json": ok(
                """
                {"ID":"aaaaaaaaaaaa","Repository":"app","Tag":"1.2","Size":"1GB"}
                {"ID":"aaaaaaaaaaaa","Repository":"app","Tag":"latest","Size":"1GB"}
                {"ID":"bbbbbbbbbbbb","Repository":"app","Tag":"1.1","Size":"1GB"}
                """),
            "docker ps -a --size --format json": ok(
                #"{"ID":"1","Image":"app:1.2","Names":"n","State":"running","Size":"0B (virtual 1GB)"}"#),
            "docker system df --format json": ok(""),
        ])

        let inventory = try await controller(runner).inventory()

        #expect(inventory.images.map(\.name) == ["app:1.2", "app:latest", "app:1.1"])
        #expect(inventory.images.map(\.isUnused) == [false, false, true])
    }

    @Test func aContextThatDockerCannotNameIsNotAnswering() async throws {
        var answers = try answers(context: "colima", inspect: "context-colima")
        answers["docker context show"] = CommandResult(exitCode: 1, stdout: "", stderr: "Cannot connect")

        #expect(await controller(FakeDocker(answers: answers)).status() == .notAnswering)
    }

    @Test func aFailedInventoryCommandSaysWhatDockerSaid() async throws {
        let runner = FakeDocker(answers: [:])

        await #expect(throws: DockerError(message: "unexpected: docker image ls -a --format json")) {
            try await controller(runner).inventory()
        }
    }

    @Test func aFailedStartSaysWhatColimaSaid() async throws {
        var answers = try answers(context: "colima", inspect: "context-colima", running: false)
        answers["colima start default"] = CommandResult(
            exitCode: 1, stdout: "", stderr: "INFO[0000] starting colima\nFATA[0001] error starting vm\nmore")
        let docker = controller(FakeDocker(answers: answers))
        guard case .runtime(let runtime) = await docker.status() else {
            Issue.record("not a runtime")
            return
        }

        await #expect(throws: DockerError(message: "FATA[0001] error starting vm")) {
            try await docker.start(runtime)
        }
    }

    @Test(arguments: [
        (DockerRuntimeKind.colima, "colima start default"),
        (.desktop, "open -a Docker"),
        (.orbstack, "orbctl start"),
    ])
    func startRunsTheToolOfTheRuntimeForThreeMinutes(kind: DockerRuntimeKind, line: String) async throws {
        let runner = FakeDocker(answers: [line: ok("")])
        let runtime = DockerRuntime(
            kind: kind, context: "c", profile: kind == .colima ? "default" : nil, isRunning: false, diskPath: nil,
            diskLimit: nil, cpus: nil, memory: nil)

        try await controller(runner).start(runtime)

        #expect(runner.calls == [Call(line: line, timeout: .seconds(180))])
    }

    @Test func pruneCommandsAreExactlyThese() async throws {
        let runner = FakeDocker(answers: [
            "docker image prune -a -f": ok(try recorded("prune-images", "txt")),
            "docker container prune -f": ok(try recorded("prune-containers", "txt")),
        ])
        let docker = controller(runner)

        let images = try await docker.removeUnusedImages()
        let containers = try await docker.removeStoppedContainers()

        #expect(images == 5_393_000_000)
        #expect(containers == 63)
        #expect(
            runner.calls == [
                Call(line: "docker image prune -a -f", timeout: .seconds(300)),
                Call(line: "docker container prune -f", timeout: .seconds(300)),
            ])
    }

    @Test func aPruneThatReclaimedNothingSaysSo() async throws {
        let runner = FakeDocker(answers: ["docker container prune -f": ok("Total reclaimed space: 0B\n")])

        #expect(try await controller(runner).removeStoppedContainers() == 0)
    }

    @Test func dockerSizesAreDecimal() {
        #expect(DockerSize.bytes("5.393GB") == 5_393_000_000)
        #expect(DockerSize.bytes("719MB") == 719_000_000)
        #expect(DockerSize.bytes("24.58kB") == 24_580)
        #expect(DockerSize.bytes("0B") == 0)
        #expect(DockerSize.bytes("1.5TB") == 1_500_000_000_000)
        #expect(DockerSize.bytes("63B") == 63)
        #expect(DockerSize.bytes("N/A") == nil)
        #expect(DockerSize.bytes("") == nil)
    }
}
