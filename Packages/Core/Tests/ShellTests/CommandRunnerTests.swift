import Foundation
import Shell
import TestSupport
import Testing

@Suite struct CommandRunnerTests {
    let r = CommandRunner()

    @Test func passesArgumentsWithSpaces() async throws {
        let res = try await r.run("echo", ["a b", "ü"], in: nil, timeout: .seconds(5))
        #expect(res.exitCode == 0 && res.stdout == "a b ü\n")
    }

    @Test func nonZeroExitIsAResultNotAnError() async throws {
        let res = try await r.run("sh", ["-c", "echo oops >&2; exit 3"], in: nil, timeout: .seconds(5))
        #expect(res.exitCode == 3 && res.stderr == "oops\n")
    }

    @Test func timesOut() async {
        await #expect(throws: CommandError.timedOut("sleep")) {
            try await r.run("sleep", ["5"], in: nil, timeout: .milliseconds(200))
        }
    }

    @Test func reportsMissingTool() async {
        await #expect(throws: CommandError.notFound("no-such-tool-xyz")) {
            try await r.run("no-such-tool-xyz", [], in: nil, timeout: .seconds(1))
        }
    }

    @Test func runsInDirectory() async throws {
        let dir = try TempDir(named: "My Projects")
        let res = try await r.run("pwd", [], in: dir.url, timeout: .seconds(5))
        #expect(res.stdout.trimmingCharacters(in: .newlines) == dir.url.resolvingSymlinksInPath().path)
    }

    // What the brief's examples leave open: the requirements it states in prose, and what an app that calls the
    // runner all day depends on (no deadlock on big output, no hang, no leaked child or descriptor).

    @Test func childGetsPathFromSearchPaths() async throws {
        let runner = CommandRunner(searchPaths: ["/usr/bin", "/bin"])
        let res = try await runner.run("sh", ["-c", "echo $PATH"], in: nil, timeout: .seconds(5))
        #expect(res.stdout == "/usr/bin:/bin\n")
    }

    @Test func runsToolsFromSearchPathsInOrder() async throws {
        let first = try TempDir(named: "My Tools")
        let second = try TempDir(named: "Other Tools")
        let greeter = try makeTool("greet", printing: "first", in: first)
        try makeTool("greet", printing: "second", in: second)
        try makeTool("only-second", printing: "found", in: second)
        let runner = CommandRunner(searchPaths: [first.url.path, second.url.path])

        let greeting = try await runner.run("greet", [], in: nil, timeout: .seconds(5))
        let other = try await runner.run("only-second", [], in: nil, timeout: .seconds(5))
        #expect(runner.which("greet")?.path == greeter.path)
        #expect(greeting.stdout == "first\n" && other.stdout == "found\n")
    }

    @Test func runsAnAbsolutePathWithoutSearchPaths() async throws {
        let res = try await CommandRunner(searchPaths: []).run("/bin/echo", ["hi"], in: nil, timeout: .seconds(5))
        #expect(res.stdout == "hi\n")
    }

    @Test func whichOnlyAcceptsExecutableFiles() {
        #expect(CommandRunner(searchPaths: ["/bin"]).which("echo")?.path == "/bin/echo")
        #expect(CommandRunner(searchPaths: []).which("echo") == nil)  // the inherited PATH is not consulted
        #expect(CommandRunner(searchPaths: []).which("/bin/echo")?.path == "/bin/echo")
        #expect(CommandRunner(searchPaths: []).which("/bin/no-such-tool-xyz") == nil)
        #expect(CommandRunner(searchPaths: []).which("/bin") == nil)  // a folder is not a tool
        #expect(CommandRunner(searchPaths: ["/usr"]).which("bin") == nil)  // nor is a folder found by name
        #expect(r.which("") == nil)
    }

    @Test func readsLargeOutputOnBothStreams() async throws {
        // Far more than a pipe holds: a runner that reads only once the child has exited would wait forever.
        let script = "yes | head -c 300000 >&2; yes | head -c 300000"
        let res = try await r.run("sh", ["-c", script], in: nil, timeout: .seconds(10))
        let expected = String(repeating: "y\n", count: 150_000)
        #expect(res.exitCode == 0 && res.stdout == expected && res.stderr == expected)
    }

    @Test func waitsForTheEndOfTheOutputNotJustTheExit() async throws {
        // The shell is gone at once, but the background job it leaves behind keeps the output open for a while.
        let res = try await r.run("sh", ["-c", "(sleep 0.3; echo late) & echo now"], in: nil, timeout: .seconds(5))
        #expect(res.exitCode == 0 && res.stdout == "now\nlate\n")
    }

    @Test func doesNotWaitForOutputThatOutlivesTheTimeout() async {
        // Same, but the background job runs for much longer than the timeout: the call has to give up, not wait it out.
        let start = ContinuousClock.now
        await #expect(throws: CommandError.timedOut("sh")) {
            try await r.run("sh", ["-c", "sleep 5 & echo started"], in: nil, timeout: .milliseconds(200))
        }
        #expect(ContinuousClock.now - start < .seconds(3))
    }

    @Test func failedLaunchesDoNotPileUpDescriptors() async {
        // Each failed launch used to leave four descriptors open for a while, so a quick loop of them piled up many.
        let before = openDescriptorCount()
        for _ in 0..<150 {
            _ = try? await r.run("echo", [], in: URL(filePath: "/no/such/folder"), timeout: .seconds(5))
        }
        // Generous, since tests running in parallel open descriptors of their own; unfixed, the loop adds about 600.
        #expect(openDescriptorCount() - before < 300)
    }

    @Test func childInputIsEmpty() async throws {
        // A tool that asks for input then gets end-of-file, instead of waiting on whatever the parent's stdin is.
        let script = "[ /dev/fd/0 -ef /dev/null ] && echo yes"
        let res = try await r.run("sh", ["-c", script], in: nil, timeout: .seconds(5))
        #expect(res.stdout == "yes\n")
    }

    @Test func cancellingTheCallerTerminatesTheChild() async throws {
        let dir = try TempDir(named: "Children")
        let pidFile = dir.url.appending(path: "pid")
        let script = "echo $$ > \"$1\"; exec sleep 30"
        let task = Task {
            try await r.run("sh", ["-c", script, "sh", pidFile.path], in: nil, timeout: .seconds(60))
        }
        let pid = try #require(await waitForPID(in: pidFile))

        task.cancel()

        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(await eventually { !isAlive(pid) })
    }

    @Test func timeoutAsksTheChildToStop() async throws {
        let dir = try TempDir(named: "Children")
        let marker = dir.url.appending(path: "marker")
        // The child cleans up when asked to stop, as git does with its lock files, and the call waits until it has.
        let script = "trap 'echo stopped > \"$1\"; exit 0' TERM; \(idle)"

        await #expect(throws: CommandError.timedOut("sh")) {
            try await r.run("sh", ["-c", script, "sh", marker.path], in: nil, timeout: .seconds(1))
        }

        #expect(try String(contentsOf: marker, encoding: .utf8) == "stopped\n")
    }

    @Test func stopsWaitingForAChildThatWontStop() async throws {
        let dir = try TempDir(named: "Children")
        let pidFile = dir.url.appending(path: "pid")
        let requests = dir.url.appending(path: "requests")
        // The child notes each request to stop and carries on regardless. It does so before it writes its pid, and the
        // timeout leaves it ample time to get that far.
        let script = "trap 'echo asked >> \"$2\"' TERM; echo $$ > \"$1\"; \(idle)"
        let start = ContinuousClock.now
        let task = Task {
            try await r.run("sh", ["-c", script, "sh", pidFile.path, requests.path], in: nil, timeout: .seconds(1))
        }
        let pid = try #require(await waitForPID(in: pidFile))
        defer { kill(pid, SIGKILL) }  // the runner leaves the child running, so the test has to stop it itself

        await #expect(throws: CommandError.timedOut("sh")) { try await task.value }
        #expect(ContinuousClock.now - start < .seconds(4))  // the timeout and the grace period add up to about 2 s

        // Long enough for a second request, or a kill, to show: the child was asked once, and was left alone.
        try await Task.sleep(for: .milliseconds(300))
        #expect(isAlive(pid))
        #expect(try String(contentsOf: requests, encoding: .utf8) == "asked\n")
    }
}

/// A shell loop that idles for ten seconds at most, so that a test that fails cannot leave its child behind for long.
private let idle = "n=0; while [ $n -lt 100 ]; do sleep 0.1; n=$((n+1)); done"

/// An executable shell script `name` in `dir` that prints `output`.
@discardableResult
private func makeTool(_ name: String, printing output: String, in dir: TempDir) throws -> URL {
    let url = dir.url.appending(path: name)
    try "#!/bin/sh\necho \(output)\n".write(to: url, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    return url
}

/// The pid a test script wrote to `file`, once it has.
private func waitForPID(in file: URL) async -> Int32? {
    var pid: Int32?
    _ = await eventually {
        let text = try? String(contentsOf: file, encoding: .utf8)
        pid = text.flatMap { Int32($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
        return pid != nil
    }
    return pid
}

private func isAlive(_ pid: Int32) -> Bool {
    kill(pid, 0) == 0
}

private func openDescriptorCount() -> Int {
    (try? FileManager.default.contentsOfDirectory(atPath: "/dev/fd").count) ?? 0
}

/// Polls `condition` for up to five seconds.
private func eventually(_ condition: () -> Bool) async -> Bool {
    for _ in 0..<100 {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(50))
    }
    return false
}
