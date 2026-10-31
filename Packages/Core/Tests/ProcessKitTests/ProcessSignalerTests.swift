import Darwin
import Foundation
import TestSupport
import Testing

@testable import ProcessKit

@Suite struct ProcessSignalerTests {
    let signaler = ProcessSignaler()

    @Test func signalerStopsProcess() throws {  // SIGTERM, and isAlive turns false within 2 s
        let p = try spawn("/bin/sleep", ["30"])
        defer { p.kill() }
        #expect(signaler.isAlive(p.processIdentifier))

        #expect(signaler.signal(p.processIdentifier, SIGTERM))

        #expect(eventually(within: .seconds(2)) { !signaler.isAlive(p.processIdentifier) })
    }

    @Test func aProcessThatIsGoneIsNotAliveAndCannotBeSignaled() throws {
        let p = try spawn("/bin/sleep", ["30"])
        p.kill()  // returns when the process has been collected: nothing of it is left

        #expect(!signaler.isAlive(p.processIdentifier))
        #expect(!signaler.signal(p.processIdentifier, SIGTERM))
    }

    @Test func aZombieIsNotAlive() throws {
        // Dead, and only waiting for its parent to collect it, which `kill` cannot tell from a process that runs.
        try withZombie { pid in
            #expect(kill(pid, 0) == 0)
            #expect(!signaler.isAlive(pid))
        }
    }

    @Test(.enabled(if: getuid() != 0, "the user can signal pid 1 when the user is root"))
    func aProcessOfAnotherUserExistsButCannotBeSignaled() {
        // launchd runs as root. Signal 0 only asks whether the signal could be sent, and sends nothing.
        #expect(signaler.isAlive(1))
        #expect(!signaler.signal(1, 0))
    }

    @Test func aSignalThatDoesNotExistFailsAndLeavesTheProcessAlone() throws {
        let p = try spawn("/bin/sleep", ["30"])
        defer { p.kill() }

        #expect(!signaler.signal(p.processIdentifier, 9999))
        #expect(signaler.isAlive(p.processIdentifier))
    }

    @Test func neverSignalsAGroupOfProcesses() {
        // `kill` sends to the caller's own group for 0, to every process of the user for -1, and to a group for a
        // negative number. All use signal 0, which sends nothing, so a signaler that let them through would answer
        // `true` here and kill nothing.
        for pid in [0, -1, -2, Int32.min] as [Int32] {
            #expect(!signaler.signal(pid, 0), "signal(\(pid), 0)")
            #expect(!signaler.isAlive(pid), "isAlive(\(pid))")
        }
    }

    /// Whether `condition` becomes true within `limit`: it is asked every 10 ms.
    private func eventually(within limit: Duration, _ condition: () -> Bool) -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now + limit
        while !condition() {
            if clock.now >= deadline { return false }
            usleep(10_000)
        }
        return true
    }
}
