import Dashboard
import Foundation
import Synchronization
import TestSupport
import Testing

/// The FSEvents watcher, on a folder of the test's own.
@Suite(.timeLimit(.minutes(1))) struct FileWatcherTests {
    private final class Reported: Sendable {
        private let paths = Mutex<[String]>([])
        var all: [String] { paths.withLock { $0 } }
        func add(_ new: [String]) { paths.withLock { $0 += new } }
    }

    @Test func reportsTheFolderInWhichSomethingChanged() async throws {
        let folder = try TempDir(named: "Watched Folder")
        let reported = Reported()
        let token = FileWatcher().watch(paths: [folder.canonicalPath], latency: .milliseconds(100)) { reported.add($0) }

        try FileManager.default.createDirectory(
            atPath: folder.canonicalPath + "/repo/.git", withIntermediateDirectories: true)

        #expect(await poll(timeout: .seconds(20)) { reported.all.contains(folder.canonicalPath + "/repo") })
        #expect(reported.all.allSatisfy { $0.hasPrefix(folder.canonicalPath) && !$0.hasSuffix("/") })
        withExtendedLifetime(token) {}
    }

    @Test func stopsOnceTheTokenIsReleased() async throws {
        let folder = try TempDir(named: "Watched Folder")
        let reported = Reported()
        var token: AnyObject? = FileWatcher().watch(paths: [folder.canonicalPath], latency: .milliseconds(100)) {
            reported.add($0)
        }
        try Data().write(to: folder.url.appending(path: "first"))
        #expect(await poll(timeout: .seconds(20)) { !reported.all.isEmpty })
        withExtendedLifetime(token) {}

        token = nil
        try await Task.sleep(for: .milliseconds(300))  // anything that was on its way has arrived
        let before = reported.all.count
        try FileManager.default.createDirectory(
            atPath: folder.canonicalPath + "/second", withIntermediateDirectories: true)
        try await Task.sleep(for: .seconds(1))

        #expect(reported.all.count == before)
    }
}
