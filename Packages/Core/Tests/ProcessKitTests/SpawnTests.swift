import Foundation
import ProcessKit
import TestSupport
import Testing

/// The helpers of `TestSupport` that start the child processes of tests, and end them.
@Suite struct SpawnTests {
    @Test func killReturnsOnlyOnceTheProcessIsGone() throws {
        let p = try spawn("/bin/sleep", ["30"])
        #expect(p.isRunning)

        p.kill()

        #expect(!p.isRunning)
        #expect(!ProcessSignaler().isAlive(p.processIdentifier))
    }

    @Test func killDoesNothingForAProcessThatHasEnded() throws {
        let p = try spawn("/bin/sleep", ["30"])
        p.kill()

        // No second signal: the id of a process that has ended can be another process by now.
        p.kill()
        p.killWithoutWaiting()

        #expect(!p.isRunning)
    }

    @Test func killWithoutWaitingEndsTheProcessSoon() async throws {
        let p = try spawn("/bin/sleep", ["30"])

        p.killWithoutWaiting()

        let clock = ContinuousClock()
        let deadline = clock.now + .seconds(10)
        while p.isRunning, clock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
        #expect(!p.isRunning)
    }

    @Test(arguments: 0..<12)
    func killReturnsInATestThatHasAwaited(round: Int) async throws {
        // The thread that ends the process is often not the one that started it, as it is in an async test. A `kill()`
        // that waited with `waitUntilExit` was seen to wait for ever then.
        let p = try spawn("/bin/sleep", ["30"])
        defer { p.kill() }

        try await Task.sleep(for: .milliseconds(20))

        #expect(p.isRunning)
    }
}
