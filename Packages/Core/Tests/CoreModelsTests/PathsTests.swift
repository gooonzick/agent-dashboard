import CoreModels
import Foundation
import TestSupport
import Testing

@Suite struct PathsTests {
    @Test func resolvesTheSystemSymlinksToTheirPhysicalPaths() {
        // /var, /tmp and /etc are symlinks into /private on every Mac.
        #expect(canonicalPath("/var") == "/private/var")
        #expect(canonicalPath("/tmp") == "/private/tmp")
        #expect(canonicalPath("/etc/hosts") == "/private/etc/hosts")
    }

    @Test func agreesWithWhatTheFileSystemReportsForAScratchFolder() throws {
        // The scratch folder is under the temporary directory, which is under /var, so git reports it as /private/var.
        let dir = try TempDir(named: "My Projects")
        #expect(canonicalPath(dir.url.path) == dir.canonicalPath)
    }

    @Test func resolvesSymlinksDotsAndExtraSlashes() throws {
        let dir = try TempDir(named: "My Projects")
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: dir.url.appending(path: "real/inner"), withIntermediateDirectories: true)
        try fileManager.createSymbolicLink(atPath: dir.url.appending(path: "link").path, withDestinationPath: "real")

        let expected = dir.canonicalPath + "/real/inner"
        #expect(canonicalPath(dir.url.path + "/link/inner") == expected)
        #expect(canonicalPath(dir.url.path + "//real/./inner/../inner/") == expected)
    }

    @Test func aPathThatDoesNotExistComesBackAsItWas() {
        #expect(canonicalPath("/no/such/folder") == "/no/such/folder")
    }

    @Test func dropsATrailingSlashWhetherOrNotThePathExists() {
        #expect(canonicalPath("/no/such/folder/") == "/no/such/folder")
        #expect(canonicalPath("/usr/") == "/usr")
        #expect(canonicalPath("/") == "/")
    }
}
