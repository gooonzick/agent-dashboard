import CoreModels
import Darwin
import Foundation
import TestSupport
import Testing

@testable import ProcessKit

@Suite struct ProcessSamplerTests {
    // Every process that is looked for here is the test's own, or a child that the test starts and ends, so what else
    // runs on the machine does not matter.

    @Test func seesChildWithCwdArgsAndMemory() throws {
        let dir = try TempDir(named: "My Projects")
        let p = try spawn("/bin/sleep", ["30"], cwd: dir.url)  // a Foundation.Process, which the defer kills
        defer { p.kill() }
        let rec = try #require(ProcessSampler().sample().first { $0.pid == p.processIdentifier })
        #expect(rec.cwd == dir.canonicalPath)
        #expect(rec.ppid == getpid() && rec.arguments == ["/bin/sleep", "30"] && rec.footprintBytes > 0)
    }

    @Test(.enabled(if: getuid() != 0, "pid 1 is the user's own when the user is root"))
    func excludesOtherUsers() {
        #expect(!ProcessSampler().sample().contains { $0.pid == 1 })
    }

    // What the brief's examples leave open: every field of a record, and the rules about whose processes are sampled
    // and which are left out.

    @Test func describesAChildInEveryField() throws {
        let started = Date()
        let p = try spawn("/bin/sleep", ["30"])
        defer { p.kill() }

        let rec = try record(of: p.processIdentifier)

        #expect(rec.pid == p.processIdentifier && rec.id == rec.pid)
        #expect(rec.name == "sleep" && rec.executablePath == "/bin/sleep")
        #expect(rec.listeningPorts.isEmpty)
        // The kernel's time, to the microsecond, of a process that started after `started` and before now.
        #expect(rec.startDate >= started.addingTimeInterval(-0.001) && rec.startDate <= Date())
    }

    @Test func readsPathsInAnyScript() throws {
        let dir = try TempDir(named: "Проекты ünï 日本 🚀")
        let p = try spawn("/bin/sleep", ["30"], cwd: dir.url)
        defer { p.kill() }

        #expect(try record(of: p.processIdentifier).cwd == dir.canonicalPath)
    }

    @Test func readsArgumentsThatAreFarBiggerThanUsual() throws {
        // A bundler or a compiler is given a command line of hundreds of kilobytes. The kernel allows a megabyte.
        let long = String(repeating: "x", count: 200_000) + "ünï"

        try withChild("/bin/sleep", ["30"], argv0: long) { pid in
            let arguments = try record(of: pid).arguments
            #expect(arguments == [long, "30"])
        }
    }

    @Test func keepsAnEmptyFirstArgumentAndStopsWhereTheArgumentsEnd() throws {
        // `exec -a "" sleep 30`: only the padding of the path says where the arguments begin, and the environment,
        // which the child has, comes right behind them.
        try withChild("/bin/sleep", ["30"], argv0: "") { pid in
            let arguments = try record(of: pid).arguments
            #expect(arguments == ["", "30"])
        }
    }

    @Test func aWorkingDirectoryThatHasBeenDeletedIsStillReportedByItsPath() throws {
        // A process that is left in a folder that was removed is still the folder's, and has to be found there.
        let dir = try TempDir(named: "My Projects")
        let p = try spawn("/bin/sleep", ["30"], cwd: dir.url)
        defer { p.kill() }
        let path = dir.canonicalPath
        try FileManager.default.removeItem(at: dir.url)

        #expect(try record(of: p.processIdentifier).cwd == path)
    }

    @Test func argumentsAreExactlyWhatTheProcessWasStartedWith() throws {
        // No path in front of them and no environment behind them: the same as the process sees itself.
        #expect(try record(of: getpid()).arguments == CommandLine.arguments)
    }

    @Test func describesTheTestProcessItself() throws {
        let rec = try record(of: getpid())

        #expect(rec.ppid == getppid())
        #expect(rec.cwd == canonicalPath(FileManager.default.currentDirectoryPath))
        #expect(rec.footprintBytes > 1 << 20)  // a test process is far more than a megabyte
        #expect(rec.startDate < Date())
    }

    @Test func knowsTheFileThatTheTestProcessRunsAndItsName() throws {
        // The file as the system itself says it, with the symlinks on the way resolved.
        let file = canonicalPath(try #require(Bundle.main.executablePath))
        // The name is the name of the file, cut off after 31 bytes. `swiftpm-testing-helper`, which runs the tests of a
        // package, is longer than the 15 characters that the short name keeps.
        let name = String(decoding: URL(filePath: file).lastPathComponent.utf8.prefix(31), as: UTF8.self)

        let rec = try record(of: getpid())

        #expect(rec.executablePath == file)
        #expect(rec.name == name)
    }

    @Test func samplesAreInOrderOfPidWithoutDuplicates() {
        let pids = ProcessSampler().sample().map(\.pid)

        #expect(pids.allSatisfy { $0 > 0 })  // 0 is the kernel, never a process to stop
        #expect(pids == pids.sorted() && Set(pids).count == pids.count)
    }

    @Test func theUidDecidesWhoseProcessesAreSampled() {
        let own = ProcessSampler(uid: getuid()).sample().map(\.pid)
        let nobodys = ProcessSampler(uid: 987_654_321).sample().map(\.pid)

        #expect(own.contains(getpid()))
        #expect(nobodys.isEmpty)  // no process runs as that user, whoever runs the test
    }

    @Test func skipsAZombie() throws {
        try withZombie { pid in
            // The system still has the process, which `kill` shows, but nothing of it runs.
            #expect(kill(pid, 0) == 0)
            #expect(!ProcessSampler().sample().contains { $0.pid == pid })
        }
    }

    @Test func skipsAProcessThatExitedWhileItWasRead() throws {
        let p = try spawn("/bin/sleep", ["30"])
        defer { p.kill() }
        let gone = p.processIdentifier

        // The process is read, and then it is asked if it is still there: it says no.
        let pids = ProcessSampler(uid: getuid(), stillRunning: { $0 != gone }).sample().map(\.pid)

        #expect(!pids.contains(gone) && pids.contains(getpid()))
    }

}

/// The record of `pid` in a fresh sample.
private func record(of pid: Int32) throws -> ProcessRecord {
    try #require(ProcessSampler().sample().first { $0.pid == pid })
}

extension ProcessSamplerTests {
    // The sockets of the test process are what the tests of ports are about, so they run one at a time: a socket of
    // another test would be among the ones looked at.
    @Suite(.serialized) struct ListeningPorts {
        @Test func seesOwnListeningPort() throws {  // socket, bind to 127.0.0.1:0, listen
            let socket = try LoopbackSocket.listening()
            defer { socket.close() }
            let rec = try #require(ProcessSampler().sample().first { $0.pid == getpid() })
            #expect(rec.listeningPorts.contains(socket.port))
        }

        @Test func seesAnIPv6Listener() throws {
            let socket = try LoopbackSocket.listening(.ipv6)
            defer { socket.close() }

            #expect(try record(of: getpid()).listeningPorts.contains(socket.port))
        }

        @Test func seesTheListeningPortsOfAChild() throws {
            let socket = try LoopbackSocket.listening()
            defer { socket.close() }

            // The child is given the socket and nothing else, so its one port is the one that the socket has.
            try withChild("/bin/sleep", ["30"], inheriting: [socket.descriptor]) { pid in
                let ports = try record(of: pid).listeningPorts
                #expect(ports == [socket.port])
            }
        }

        @Test func ignoresSocketsThatDoNotListen() throws {
            let listener = try LoopbackSocket.listening()
            let bound = try LoopbackSocket(.tcp)  // has a port, and does not listen on it
            let client = try LoopbackSocket(.tcp)  // connected to the listener: a port in use, but not offered
            try client.connect(to: listener.port)
            let datagrams = try LoopbackSocket(.udp)  // no connections to wait for
            defer {
                for socket in [listener, bound, client, datagrams] { socket.close() }
            }

            let ports = try record(of: getpid()).listeningPorts

            #expect(ports.contains(listener.port))
            #expect(!ports.contains(bound.port))
            #expect(!ports.contains(client.port))
            #expect(!ports.contains(datagrams.port))
        }

        @Test func listsEachPortOnceInAscendingOrder() throws {
            // The system hands out ports at random, so eight of them are not in order by chance.
            let listeners = try (0..<8).map { _ in try LoopbackSocket.listening() }
            // A server that listens on `localhost` often does so over IPv4 and IPv6, on the same port.
            let (ipv4, ipv6) = try listenersOnTheSamePort()
            defer {
                for socket in listeners + [ipv4, ipv6] { socket.close() }
            }

            let ports = try record(of: getpid()).listeningPorts

            #expect(Set(listeners.map(\.port) + [ipv4.port]).isSubset(of: ports))
            #expect(ports == Array(Set(ports)).sorted())
            #expect(ports.filter { $0 == ipv4.port }.count == 1)
        }

        /// An IPv4 and an IPv6 socket that listen on one port. Another socket may have the port on the other family,
        /// so a port that is taken is replaced by the next that the system gives.
        private func listenersOnTheSamePort() throws -> (LoopbackSocket, LoopbackSocket) {
            for _ in 0..<20 {
                let ipv4 = try LoopbackSocket.listening()
                if let ipv6 = try? LoopbackSocket.listening(.ipv6, port: ipv4.port) { return (ipv4, ipv6) }
                ipv4.close()
            }
            throw POSIXError(.EADDRINUSE)
        }
    }
}
