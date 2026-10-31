import CoreModels
import Foundation
import Shell
import Synchronization
import TestSupport
import Testing

@testable import DiskUsage

/// The size of the data files that the tests write, unless a test says otherwise.
private let mebibyte = 1 << 20

/// Whether `bytes` is `mebibytes` MiB, give or take 64 KiB. A file of 1 MiB takes 1 MiB on APFS, but the tests do not
/// depend on how the file system rounds up to its blocks.
private func isAbout(_ mebibytes: Int, _ bytes: Int64) -> Bool {
    abs(bytes - Int64(mebibytes * mebibyte)) <= 64 << 10
}

@Suite struct PrivateSizeScannerTests {
    // Every tree below is made of files whose size the test knows, because it wrote them. The temporary directory is on
    // APFS, the startup disk, so clones can be made in it. Nothing outside the `TempDir` is looked at.

    @Test func plainFileIsPrivate() throws {
        let tmp = try TempDir(named: "My Projects")
        try tmp.makeFile("inside/plain.bin")

        let size = try tmp.measure("inside")

        #expect(isAbout(1, size.apparentBytes))
        #expect(isAbout(1, size.privateBytes))
    }

    @Test func cloneOfOutsideFileFreesNothing() throws {
        let tmp = try TempDir(named: "My Projects")
        try tmp.makeFile("outside/source.bin")
        try tmp.makeClone("inside/copy.bin", of: "outside/source.bin")

        let size = try tmp.measure("inside")

        #expect(size.apparentBytes >= 1 << 20 && size.privateBytes < 64 << 10)
    }

    @Test func hardLinksCountOnce() throws {
        let tmp = try TempDir(named: "My Projects")
        try tmp.makeFile("inside/a/original.bin")
        try tmp.makeHardLink("inside/b/second.bin", to: "inside/a/original.bin")  // in another folder
        try tmp.makeHardLink("inside/a/third.bin", to: "inside/a/original.bin")

        let size = try tmp.measure("inside")

        #expect(isAbout(1, size.apparentBytes))  // not 3 MiB
        #expect(size.privateBytes == 0)
    }

    @Test func skipsExcludedSubfolders() throws {
        // The way the worktrees of a repository lie inside its main checkout, and are no part of it.
        let tmp = try TempDir(named: "My Projects")
        try tmp.makeFile("repo/own.bin")
        try tmp.makeFile("repo/wt/nested.bin")
        try tmp.makeFile("repo/wt/deeper/more.bin")

        let size = try tmp.measure("repo", excluding: [tmp.canonicalPath + "/repo/wt"])

        #expect(isAbout(1, size.apparentBytes))  // own.bin alone
        #expect(isAbout(1, size.privateBytes))
    }

    @Test func stopsWhenCancelled() throws {
        let tmp = try TempDir(named: "My Projects")
        try tmp.makeFile("inside/a/one.bin", bytes: 4096)
        try tmp.makeFile("inside/b/two.bin", bytes: 4096)
        let asked = CallCounter()

        // The first folder is looked at and the answer is no; from the second one on it is yes.
        #expect(throws: CancellationError.self) {
            try tmp.measure("inside", isCancelled: { asked.next() > 1 })
        }

        #expect(asked.total == 2)  // told to stop, it does not ask again
    }

    // What the brief's examples leave open: the rules it states in prose, and the decisions of the controller.

    @Test func countsFilesAtEveryDepthAndInHiddenAndOddlyNamedFolders() throws {
        let tmp = try TempDir(named: "My Projects")
        try tmp.makeFile("inside/top.bin")
        try tmp.makeFile("inside/a/b/c/deep.bin")
        try tmp.makeFile("inside/.hidden/.dot file.bin")
        try tmp.makeFile("inside/Prøjëct 日本語 🚀/\"quoted\" & spaced.bin")
        try tmp.makeDirectory("inside/empty/folders/only")

        let size = try tmp.measure("inside")

        #expect(isAbout(4, size.apparentBytes))
        #expect(isAbout(4, size.privateBytes))
    }

    @Test func countsTheBlocksAFileTakesNotItsLength() throws {
        // `du` counts what is allocated: a small file takes a whole block, a hole in a file takes nothing.
        let tmp = try TempDir(named: "My Projects")
        let tiny = try tmp.makeFile("inside/tiny.bin", bytes: 5)
        let sparse = try tmp.makeFile("inside/sparse.bin", bytes: 0)
        try posix(truncate(sparse, 1 << 30))  // a gigabyte long, with nothing written to it

        let expected = try allocatedBytes(ofFileAt: tiny) + allocatedBytes(ofFileAt: sparse)

        let size = try tmp.measure("inside")

        #expect(size.apparentBytes == expected)
        #expect(size.apparentBytes < mebibyte)
        #expect(size.privateBytes <= size.apparentBytes)
    }

    @Test func aFolderWithoutFilesIsEmpty() throws {
        let tmp = try TempDir(named: "My Projects")
        try tmp.makeDirectory("inside/a/b")

        let size = try tmp.measure("inside")

        #expect(size.apparentBytes == 0)
        #expect(size.privateBytes == 0)
    }

    @Test func aFileWhoseOtherLinkIsOutsideFreesNothing() throws {
        // Removing the folder removes one name of the file only, so none of its data is freed.
        let tmp = try TempDir(named: "My Projects")
        try tmp.makeFile("outside/original.bin")
        try tmp.makeHardLink("inside/linked.bin", to: "outside/original.bin")

        let size = try tmp.measure("inside")

        #expect(isAbout(1, size.apparentBytes))
        #expect(size.privateBytes == 0)
    }

    @Test func aFileThatIsClonedOutsideFreesNothing() throws {
        // The clone that lies outside keeps the data of the file alive, whichever of the two is the original.
        let tmp = try TempDir(named: "My Projects")
        try tmp.makeFile("inside/source.bin")
        try tmp.makeClone("outside/copy.bin", of: "inside/source.bin")

        let size = try tmp.measure("inside")

        #expect(isAbout(1, size.apparentBytes))
        #expect(size.privateBytes < 64 << 10)
    }

    @Test func clonesInsideTheFolderNeverMakeTheNumberTooHigh() throws {
        // Removing the folder frees the data of the two files, 1 MiB. Neither file frees any of it alone, so it counts
        // as shared. That is too low, and allowed to be, but it must not be too high.
        let tmp = try TempDir(named: "My Projects")
        try tmp.makeFile("inside/original.bin")
        try tmp.makeClone("inside/clone.bin", of: "inside/original.bin")

        let size = try tmp.measure("inside")

        #expect(isAbout(2, size.apparentBytes))
        #expect(size.privateBytes <= Int64(mebibyte))
    }

    @Test func excludesAFolderAsAWholeNotByNamePrefixOrName() throws {
        let tmp = try TempDir(named: "My Projects")
        try tmp.makeFile("repo/wt/excluded.bin")
        try tmp.makeFile("repo/wt-2/counted.bin")  // starts with the same letters
        try tmp.makeFile("repo/wtf/counted.bin")
        try tmp.makeFile("repo/sub/wt/counted.bin")  // has the same name, but is another folder

        let size = try tmp.measure("repo", excluding: [tmp.canonicalPath + "/repo/wt"])

        #expect(isAbout(3, size.apparentBytes))
        #expect(isAbout(3, size.privateBytes))
    }

    @Test func anExcludedFolderIsFoundWhicheverWayItsPathIsWritten() throws {
        let tmp = try TempDir(named: "My Projects")
        try tmp.makeFile("repo/own.bin")
        try tmp.makeFile("repo/wt/excluded.bin")
        try tmp.makeFile("repo/linked/excluded.bin")
        try tmp.makeSymlink("repo-link", to: "repo")
        // The root and the entries all differ from the canonical form: /var instead of /private/var, a symlink on the
        // way, a trailing slash.
        let excluding: Set = [tmp.url.path + "/repo/wt/", tmp.url.path + "/repo-link/linked"]

        let size = try tmp.measure("repo-link", excluding: excluding)

        #expect(isAbout(1, size.apparentBytes))
        #expect(isAbout(1, size.privateBytes))
    }

    @Test func anExcludedFolderThatIsNotBelowTheRootChangesNothing() throws {
        let tmp = try TempDir(named: "My Projects")
        try tmp.makeFile("repo/own.bin")
        try tmp.makeFile("other/elsewhere.bin")

        let size = try tmp.measure(
            "repo", excluding: [tmp.canonicalPath + "/other", tmp.canonicalPath + "/missing", tmp.canonicalPath, ""])

        #expect(isAbout(1, size.apparentBytes))
    }

    @Test func aRootThatIsExcludedItselfHasNothingLeftToMeasure() throws {
        let tmp = try TempDir(named: "My Projects")
        try tmp.makeFile("repo/own.bin")

        let size = try tmp.measure("repo", excluding: [tmp.canonicalPath + "/repo"])

        #expect(size.apparentBytes == 0)
        #expect(size.privateBytes == 0)
    }

    @Test(.timeLimit(.minutes(2)))
    func doesNotLookInsideAVolumeThatIsMountedInTheFolder() async throws {
        // Removing a folder does not remove what is mounted on it, and such a volume may be a network share, or a disk
        // that is slow. Xcode mounts its simulator runtimes this way, under /Library/Developer.
        let tmp = try TempDir(named: "My Projects")
        try tmp.makeFile("inside/own.bin")

        let (folder, onTheVolume) = try await tmp.withMountedVolume(at: "inside/mounted") {
            try tmp.makeFile("inside/mounted/folder/on-the-volume.bin")
            let folderDevice = try device(ofItemAt: tmp.url.appending(path: "inside").path)
            let volumeDevice = try device(ofItemAt: tmp.url.appending(path: "inside/mounted").path)
            try #require(volumeDevice != folderDevice, "the disk image is not on a device of its own")
            // The same walk, started on the other volume, is on one volume all the way.
            return (try tmp.measure("inside"), try tmp.measure("inside/mounted/folder"))
        }

        #expect(isAbout(1, folder.apparentBytes))  // own.bin, and nothing of what is on the volume
        #expect(isAbout(1, folder.privateBytes))
        #expect(isAbout(1, onTheVolume.apparentBytes))  // the file on the volume, the walk's own volume
        #expect(isAbout(1, onTheVolume.privateBytes))  // a local volume that is not APFS: no clones, all of it is freed
    }

    @Test(.timeLimit(.minutes(1)))
    func doesNotFollowSymlinks() throws {
        let tmp = try TempDir(named: "My Projects")
        try tmp.makeFile("elsewhere/folder/big.bin")
        try tmp.makeFile("elsewhere/big.bin")
        try tmp.makeDirectory("inside")
        try tmp.makeSymlink("inside/folder-link", to: "../elsewhere/folder")  // a way out to a folder
        try tmp.makeSymlink("inside/file-link", to: "../elsewhere/big.bin")  // a file that lies elsewhere
        try tmp.makeSymlink("inside/loop", to: ".")  // leads back to the folder that holds it
        try tmp.makeSymlink("inside/broken", to: "no-such-file")

        let size = try tmp.measure("inside")

        #expect(size.apparentBytes == 0)
        #expect(size.privateBytes == 0)
    }

    @Test func measuresWhatARootThatIsASymlinkPointsTo() throws {
        let tmp = try TempDir(named: "My Projects")
        try tmp.makeFile("real/data.bin")
        try tmp.makeSymlink("link", to: "real")

        let size = try tmp.measure("link")

        #expect(isAbout(1, size.apparentBytes))
    }

    @Test func aRootThatDoesNotExistThrows() throws {
        let tmp = try TempDir(named: "My Projects")

        let error = try #require(throws: POSIXError.self) { try tmp.measure("missing") }

        #expect(error.code == .ENOENT)
    }

    @Test func aRootThatIsNotAFolderThrows() throws {
        let tmp = try TempDir(named: "My Projects")
        try tmp.makeFile("file.bin")

        let error = try #require(throws: POSIXError.self) { try tmp.measure("file.bin") }

        #expect(error.code == .ENOTDIR)
    }

    @Test(.disabled(if: getuid() == 0, "root can read any folder, so none of them is unreadable"))
    func aRootThatCannotBeReadThrows() throws {
        let tmp = try TempDir(named: "My Projects")
        try tmp.makeFile("locked/data.bin")
        try posix(chmod(tmp.url.appending(path: "locked").path, 0o000))
        defer { chmod(tmp.url.appending(path: "locked").path, 0o755) }  // so that the TempDir can delete it again

        let error = try #require(throws: POSIXError.self) { try tmp.measure("locked") }

        #expect(error.code == .EACCES)
    }

    @Test(.disabled(if: getuid() == 0, "root can read any folder, so none of them is unreadable"))
    func skipsWhatCannotBeReadAndCountsTheRest() throws {
        let tmp = try TempDir(named: "My Projects")
        try tmp.makeFile("inside/open/counted.bin")
        try tmp.makeFile("inside/locked/skipped.bin")  // a folder that can neither be listed nor entered
        try tmp.makeFile("inside/listed/skipped.bin")  // one that can be listed but not entered
        try tmp.makeFile("inside/z/counted.bin")
        for (folder, mode) in [("locked", mode_t(0o000)), ("listed", mode_t(0o444))] {
            try posix(chmod(tmp.url.appending(path: "inside/\(folder)").path, mode))
        }
        defer {  // so that the TempDir can delete the folders again
            for folder in ["locked", "listed"] { chmod(tmp.url.appending(path: "inside/\(folder)").path, 0o755) }
        }

        let size = try tmp.measure("inside")

        #expect(isAbout(2, size.apparentBytes))
        #expect(isAbout(2, size.privateBytes))
    }

    @Test(.timeLimit(.minutes(1)))
    func stopsWhenTheTaskIsCancelled() async throws {
        let tmp = try TempDir(named: "My Projects")
        try tmp.makeFile("inside/data.bin", bytes: 4096)
        let task = Task {
            while !Task.isCancelled { await Task.yield() }  // the walk only starts once its task has been cancelled
            return try tmp.measure("inside")  // and the isCancelled it is given still says no
        }

        task.cancel()

        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(try tmp.measure("inside").apparentBytes > 0)  // the same walk, not cancelled, measures the file
    }

    @Test func doesNothingWhenCancelledFromTheStart() throws {
        let tmp = try TempDir(named: "My Projects")
        try tmp.makeFile("inside/data.bin", bytes: 4096)
        let asked = CallCounter()

        #expect(throws: CancellationError.self) {
            try tmp.measure("inside", isCancelled: { asked.next() > 0 })
        }

        #expect(asked.total == 1)
    }

    @Test func saysWhenItWasMeasured() throws {
        let tmp = try TempDir(named: "My Projects")
        try tmp.makeFile("inside/data.bin")

        let before = Date()
        let size = try tmp.measure("inside")
        let after = Date()

        #expect(before <= size.computedAt && size.computedAt <= after)
    }

    // What a volume says about a file, and what a file then frees. A file of 8192 bytes stands for the file.

    @Test func takesThePrivateSizeThatAVolumeGives() {
        for mayShare in [true, false] {
            #expect(freed(.bytes(4096), mayShare: mayShare) == 4096)
            #expect(freed(.bytes(0), mayShare: mayShare) == 0)
        }
    }

    @Test(arguments: [ENOTSUP, EINVAL])
    func aVolumeThatIsNotAPFSAndHasNoPrivateSizesFreesAllItAllocated(code: Int32) {
        // Only APFS has clones, so on anything else a file frees all that it takes. HFS+ and exFAT, tried on disk
        // images, refuse the request with EINVAL. ENOTSUP is what getattrlist documents for a volume that cannot
        // answer.
        #expect(freed(.failed(code), mayShare: false) == 8192)
    }

    @Test(arguments: [ENOTSUP, EINVAL])
    func anAPFSVolumeThatHasNoPrivateSizesFreesNothingSoThatTheNumberIsNeverTooHigh(code: Int32) {
        // It should not happen, but the attribute is in a part of the system headers that is marked unstable. If a
        // later macOS stopped answering, the numbers must not turn into those of du, which this exists to avoid.
        #expect(freed(.failed(code), mayShare: true) == 0)
    }

    @Test(arguments: [EACCES, EPERM, EIO, ENAMETOOLONG, ELOOP, ERANGE, EFAULT, ENOMEM], [true, false])
    func anyOtherFailureFreesNothingSoThatTheNumberIsNeverTooHigh(code: Int32, mayShare: Bool) {
        #expect(freed(.failed(code), mayShare: mayShare) == 0)
    }

    @Test(arguments: [ENOENT, ENOTDIR], [true, false])
    func aFileThatIsGoneIsLeftOut(code: Int32, mayShare: Bool) {
        #expect(freed(.failed(code), mayShare: mayShare) == nil)
    }

    @Test func asksWhatKindOfVolumeItIsOnlyWhenTheVolumeRefusedToAnswer() {
        let asked = CallCounter()

        _ = freed(.bytes(4096), mayShare: asked.askedAndTrue())
        _ = freed(.failed(EACCES), mayShare: asked.askedAndTrue())
        _ = freed(.failed(ENOENT), mayShare: asked.askedAndTrue())
        #expect(asked.total == 0)  // on APFS every file is answered, and a statfs for each of them would be a waste

        _ = freed(.failed(EINVAL), mayShare: asked.askedAndTrue())
        #expect(asked.total == 1)
    }

    @Test func aVolumeMayShareDataUnlessItSaysItIsNotAPFS() throws {
        let tmp = try TempDir(named: "My Projects")

        #expect(PrivateSizeScanner.volumeMayShareData(at: tmp.url.path))  // the startup disk is APFS
        #expect(!PrivateSizeScanner.volumeMayShareData(at: "/dev"))  // devfs is on every Mac, and is not APFS
        #expect(PrivateSizeScanner.volumeMayShareData(at: "/no/such/place"))  // it cannot be asked: not ruled out
    }

    @Test(arguments: [
        // A volume that is on this computer and not APFS is the only one that is known not to share data.
        ("hfs", true, false), ("exfat", true, false), ("msdos", true, false), ("devfs", true, false),
        // APFS, and anything that is not on this computer, may: a network volume can be an APFS volume of the server,
        // with clones that this Mac cannot see.
        ("apfs", true, true), ("apfs", false, true), ("smbfs", false, true), ("nfs", false, true),
        ("afpfs", false, true), ("autofs", false, true), ("hfs", false, true),
    ])
    func onlyALocalVolumeThatIsNotAPFSIsKnownNotToShareData(fileSystem: String, isLocal: Bool, mayShare: Bool) {
        #expect(PrivateSizeScanner.mayShareData(volume: statfs(fileSystem: fileSystem, isLocal: isLocal)) == mayShare)
    }

    @Test func askingAboutASymlinkIsAskingAboutTheSymlinkNotWhatItPointsTo() throws {
        // A file that is replaced by a symlink while the walk runs must not be measured as the file that it points
        // to: that one could lie anywhere, and be large.
        let tmp = try TempDir(named: "My Projects")
        let target = try tmp.makeFile("outside/big.bin")
        try tmp.makeDirectory("inside")
        try tmp.makeSymlink("inside/link.bin", to: "../outside/big.bin")

        let answer = PrivateSizeScanner.privateSize(ofFileAt: tmp.url.appending(path: "inside/link.bin").path)

        #expect(answer == .bytes(0))
        #expect(PrivateSizeScanner.privateSize(ofFileAt: target) != .bytes(0))  // the target does have a private size
    }
}

/// Counts calls, for a closure that has to be `Sendable`.
private final class CallCounter: Sendable {
    private let calls = Mutex(0)

    /// Counts one more call and returns how many there have been so far.
    func next() -> Int {
        calls.withLock {
            $0 += 1
            return $0
        }
    }

    /// Counts one more call, for an argument whose value is only worked out when it is needed.
    func askedAndTrue() -> Bool {
        _ = next()
        return true
    }

    var total: Int { calls.withLock { $0 } }
}

/// What deleting a file that takes 8192 bytes frees, if its volume gave `answer`. `mayShare` says whether files on
/// that volume can share data; like the argument of `freedBytes` it is only worked out when it is needed.
private func freed(_ answer: PrivateSizeScanner.Answer, mayShare: @autoclosure () -> Bool) -> Int64? {
    PrivateSizeScanner.freedBytes(allocated: 8192, answer: answer, volumeMayShareData: mayShare())
}

extension statfs {
    /// What `statfs` says about a volume with the file system `fileSystem`, which is on this computer or not. `statfs`
    /// marks the volumes that are with MNT_LOCAL; no other flag may matter, so some are set.
    fileprivate init(fileSystem: String, isLocal: Bool) {
        self.init()
        withUnsafeMutableBytes(of: &f_fstypename) { name in
            _ = strlcpy(name.baseAddress!.assumingMemoryBound(to: CChar.self), fileSystem, name.count)
        }
        f_flags = UInt32(MNT_RDONLY | MNT_NOSUID) | (isLocal ? UInt32(MNT_LOCAL) : 0)
    }
}

/// The device that the item at `path` is on, the way `st_dev` says. Each mounted volume has its own.
private func device(ofItemAt path: String) throws -> dev_t {
    var info = stat()
    try posix(lstat(path, &info))
    return info.st_dev
}

/// A command that did not exit with 0.
private struct CommandFailure: Error, CustomStringConvertible {
    let command: String
    let exitCode: Int32
    let output: String

    var description: String { "\(command) exited with \(exitCode): \(output)" }
}

/// Runs `hdiutil <arguments>`, and throws what it printed if it fails.
private func hdiutil(_ arguments: String...) async throws {
    let result = try await CommandRunner().run("hdiutil", arguments, in: nil, timeout: .seconds(60))
    guard result.exitCode == 0 else {
        throw CommandFailure(
            command: "hdiutil " + arguments.joined(separator: " "), exitCode: result.exitCode,
            output: result.stdout + result.stderr)
    }
}

/// Fails the test, with the reason, if a system call that returns 0 when it works did not.
private func posix(_ call: @autoclosure () -> Int32) throws {
    guard call() == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
}

/// The bytes that the file at `path` takes on disk, as `du` counts them.
private func allocatedBytes(ofFileAt path: String) throws -> Int64 {
    var info = stat()
    try posix(lstat(path, &info))
    return Int64(info.st_blocks) * 512
}

private extension TempDir {
    /// Writes a file of `bytes` random bytes at `path`, relative to this folder, and the folders on the way to it.
    /// Returns the path of the file. The bytes are random so that nothing can store them in less space.
    @discardableResult
    func makeFile(_ path: String, bytes: Int = mebibyte) throws -> String {
        let file = url.appending(path: path)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        var content = Data(count: bytes)
        if bytes > 0 { content.withUnsafeMutableBytes { arc4random_buf($0.baseAddress, bytes) } }
        try content.write(to: file)
        return file.path
    }

    func makeDirectory(_ path: String) throws {
        try FileManager.default.createDirectory(at: url.appending(path: path), withIntermediateDirectories: true)
    }

    /// Creates a symlink at `path`, relative to this folder, that points to `destination` (relative to the link).
    func makeSymlink(_ path: String, to destination: String) throws {
        try FileManager.default.createSymbolicLink(
            atPath: url.appending(path: path).path, withDestinationPath: destination)
    }

    /// Makes `path` another name of the file at `existing`, both relative to this folder.
    func makeHardLink(_ path: String, to existing: String) throws {
        let link = url.appending(path: path)
        try FileManager.default.createDirectory(at: link.deletingLastPathComponent(), withIntermediateDirectories: true)
        try posix(Darwin.link(url.appending(path: existing).path, link.path))
    }

    /// Makes `path` a clone of the file at `existing`, both relative to this folder: a file of its own that shares the
    /// data of the other until one of them is changed.
    func makeClone(_ path: String, of existing: String) throws {
        let copy = url.appending(path: path)
        try FileManager.default.createDirectory(at: copy.deletingLastPathComponent(), withIntermediateDirectories: true)
        try posix(clonefile(url.appending(path: existing).path, copy.path, 0))
    }

    /// Runs `body` while a volume of its own is mounted on the folder `path`, relative to this one: a disk image of 10
    /// MB with an HFS+ volume on it. It is unmounted again however `body` ends, before this returns, so that the folder
    /// can be deleted (what is mounted on it would be deleted with it). Where a disk image cannot be made or mounted,
    /// the test is skipped, with the reason.
    func withMountedVolume<Result>(at path: String, _ body: () throws -> Result) async throws -> Result {
        try makeDirectory(path)
        let image = url.appending(path: "volume.dmg").path
        let mountPoint = url.appending(path: path).path
        do {
            try await hdiutil("create", "-size", "10m", "-fs", "HFS+", "-volname", "Nested", image)
            try await hdiutil("attach", "-nobrowse", "-noverify", "-noautofsck", "-mountpoint", mountPoint, image)
        } catch {
            try Test.cancel("A disk image cannot be mounted here: \(error)")
        }
        let outcome = Swift.Result { try body() }
        do {
            try await hdiutil("detach", mountPoint)
        } catch {
            try await hdiutil("detach", "-force", mountPoint)
        }
        return try outcome.get()
    }

    /// Measures `path`, relative to this folder, with a `PrivateSizeScanner`. A method of the `TempDir`, so that the
    /// folder is there for as long as the walk runs.
    func measure(
        _ path: String, excluding excluded: Set<String> = [], isCancelled: @Sendable () -> Bool = { false }
    ) throws -> SizeInfo {
        try PrivateSizeScanner().measure(url.appending(path: path), excluding: excluded, isCancelled: isCancelled)
    }
}
