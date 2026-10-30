import Foundation

/// A scratch folder for tests that is removed again when the value is released.
///
/// `url` is `<unique folder in the system temporary directory>/<name>`: the unique parent keeps parallel tests apart,
/// and `name` lets a test check that code copes with spaces (or other odd characters) in a path.
/// The folder goes away with the value, so keep the `TempDir` around for as long as the folder is in use.
public final class TempDir: Sendable {
    public let url: URL
    private let root: URL

    public init(named name: String) throws {
        root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        url = root.appending(path: name, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    /// `url` as the file system itself reports it.
    ///
    /// The system temporary directory is under `/var`, a symlink to `/private/var`, and git and the process APIs
    /// report the `/private/var` form. Paths read back from them are compared with this, not with `url.path`.
    ///
    /// It calls `realpath` itself rather than `CoreModels.canonicalPath`, because the tests of that function take this
    /// as their reference.
    public var canonicalPath: String {
        guard let resolved = realpath(url.path, nil) else { return url.path }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    deinit {
        try? FileManager.default.removeItem(at: root)
    }
}
