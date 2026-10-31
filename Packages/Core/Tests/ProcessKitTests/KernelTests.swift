import Darwin
import Foundation
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

    @Test func readsArgumentsWhateverTheLengthOfThePath() throws {
        // The kernel pads the path that a program was started from to a multiple of 8 bytes, and the arguments follow.
        // The path is the one that `exec` was given, so a link to a system program with a name of 1 to 8 letters makes
        // a process for each of the eight paddings, and what runs is still the system's own program.
        let dir = try TempDir(named: "My Projects")
        var reader = Kernel.ArgumentsReader()
        for length in 1...8 {
            let link = dir.url.appending(path: String(repeating: "s", count: length)).path
            try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: "/bin/sleep")
            for argv0 in [nil, ""] as [String?] {
                try withChild(link, ["30"], argv0: argv0) { pid in
                    let arguments = reader.arguments(of: pid)
                    let named = "path of \(link.utf8.count) bytes, argv[0] \(argv0 ?? "path")"
                    #expect(arguments == [argv0 ?? link, "30"], Comment(rawValue: named))
                }
            }
        }
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
