import Darwin
import TestSupport
import Testing

@testable import ProcessKit

/// The two questions that the rest of the module is built on: which processes are there, and has one of them exited.
@Suite struct KernelTests {
    @Test func listsTheProcessesThatRunWithoutTheKernelItself() throws {
        let p = try spawn("/bin/sleep", ["30"])
        defer { p.kill() }

        let pids = Kernel.processIDs()

        #expect(pids.contains(getpid()) && pids.contains(p.processIdentifier))
        #expect(pids.allSatisfy { $0 > 0 })  // the kernel's own entry is 0, which `kill` takes for a group
        #expect(Set(pids).count == pids.count)
    }

    @Test func aProcessThatRunsHasNotExited() throws {
        let p = try spawn("/bin/sleep", ["30"])
        defer { p.kill() }

        #expect(!Kernel.hasExited(getpid()))
        #expect(!Kernel.hasExited(p.processIdentifier))
    }

    @Test func aProcessThatIsGoneHasExited() throws {
        let p = try spawn("/bin/sleep", ["30"])
        p.kill()

        #expect(Kernel.hasExited(p.processIdentifier))
    }

    @Test func aZombieHasExited() throws {
        try withZombie { pid in
            #expect(kill(pid, 0) == 0)  // `kill` finds it, as it would a process that runs
            #expect(Kernel.hasExited(pid))
        }
    }

    @Test(.enabled(if: getuid() != 0, "the user can look at pid 1 when the user is root"))
    func aProcessThatCannotBeLookedAtHasNotExited() {
        // The kernel refuses to say anything about launchd, which belongs to root. That is not an exit.
        #expect(Kernel.basicInfo(of: 1) == nil)
        #expect(!Kernel.hasExited(1))
    }
}
