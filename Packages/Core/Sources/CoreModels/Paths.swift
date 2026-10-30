import Foundation

/// `path` the way the file system itself reports it: symlinks, `.` and `..` resolved, no trailing slash.
///
/// macOS reports physical paths. Git and the process APIs say `/private/var/...` for a folder that was reached as
/// `/var/...`, while `URL.resolvingSymlinksInPath()` goes the other way and strips the `/private`. Paths that come from
/// different sources are therefore compared in this form, which is what `realpath(3)` gives.
///
/// A path that `realpath` cannot resolve (there is nothing at it, or a folder on the way cannot be searched) comes back
/// as it was given, except for trailing slashes.
public func canonicalPath(_ path: String) -> String {
    if let resolved = realpath(path, nil) {
        defer { free(resolved) }
        return String(cString: resolved)
    }
    var unresolved = Substring(path)
    while unresolved.count > 1, unresolved.hasSuffix("/") { unresolved.removeLast() }
    return String(unresolved)
}
