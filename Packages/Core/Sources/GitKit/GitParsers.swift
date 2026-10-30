import CoreModels
import Foundation

/// Reads the output of git commands into the types of `CoreModels`.
///
/// Later tasks decide from these values what can be deleted, so they are read exactly, and only by the keywords that
/// git itself writes. Nothing here looks at the messages that git translates, so what is read is the same in any
/// language.
public enum GitParsers {
    // MARK: Worktrees

    /// The worktrees of `git worktree list --porcelain`. Git lists the repository's own folder first: that one is the
    /// main worktree.
    ///
    /// A `locked` line makes a lock, with or without a reason, and a `prunable` line makes the worktree prunable. The
    /// branch is read without `refs/heads/`. A `HEAD` that is the null id belongs to a branch that has no commit yet,
    /// so it has no head. What this does not know it skips.
    ///
    /// Paths and reasons are kept as git printed them. A reason with a quote, a backslash or a control character in it
    /// is printed as a C string, in double quotes. A path with a newline in it cannot be read from this format.
    public static func worktrees(porcelain: String) -> [Worktree] {
        struct Entry {
            var path: String
            var head: String?
            var branch: String?
            var isDetached = false
            var lock: WorktreeLock?
            var isPrunable = false
        }

        var entries: [Entry] = []
        for line in Line.all(in: porcelain) {
            if let path = line.value(after: "worktree ") {
                entries.append(Entry(path: path))
            } else if !entries.isEmpty {
                let last = entries.count - 1
                if let id = line.value(after: "HEAD ") {
                    entries[last].head = id.unicodeScalars.allSatisfy { $0 == "0" } ? nil : id
                } else if let name = line.value(after: "branch refs/heads/") ?? line.value(after: "branch ") {
                    entries[last].branch = name
                } else if line.isKeyword("detached") {
                    entries[last].isDetached = true
                } else if line.isKeyword("locked") {
                    entries[last].lock = WorktreeLock(reason: line.value(after: "locked ") ?? "")
                } else if line.isKeyword("prunable") {
                    entries[last].isPrunable = true
                }
            }
        }
        return entries.enumerated().map { index, entry in
            Worktree(
                path: entry.path, head: entry.head, branch: entry.branch, isMain: index == 0,
                isDetached: entry.isDetached, lock: entry.lock, isPrunable: entry.isPrunable)
        }
    }

    // MARK: Status

    /// The status in the output of `git status --porcelain=v2 --branch`, and `lastCommit`, which `git log` has to say.
    ///
    /// `upstreamGone` is an upstream that is named (`# branch.upstream`) without ahead and behind counts
    /// (`# branch.ab`): git has them only for an upstream that exists. `modified` counts the entries that begin with
    /// `1 `, `2 ` or `u `: changes, renames and copies, and merge conflicts. `untracked` counts the ones that begin
    /// with `? `. Ignored files are listed only when they are asked for, and are not counted then.
    public static func status(porcelainV2: String, lastCommit: Date?) -> WorktreeStatus {
        var upstream: String?
        var hasCounts = false
        var ahead = 0
        var behind = 0
        var modified = 0
        var untracked = 0
        for line in Line.all(in: porcelainV2) {
            if let name = line.value(after: "# branch.upstream ") {
                upstream = name
            } else if let counts = line.value(after: "# branch.ab ") {
                hasCounts = true
                (ahead, behind) = aheadBehind(counts) ?? (0, 0)
            } else if line.hasPrefix("1 ") || line.hasPrefix("2 ") || line.hasPrefix("u ") {
                modified += 1
            } else if line.hasPrefix("? ") {
                untracked += 1
            }
        }
        return WorktreeStatus(
            upstream: upstream, upstreamGone: upstream != nil && !hasCounts, ahead: ahead, behind: behind,
            modified: modified, untracked: untracked, lastCommitDate: lastCommit)
    }

    /// Whether the branch has a commit. `git status --branch` says `(initial)` where it would give the commit of a
    /// branch that is new. Nothing in the output that says so means there is one.
    public static func hasCommits(porcelainV2: String) -> Bool {
        !Line.all(in: porcelainV2).contains { $0.value(after: "# branch.oid ") == "(initial)" }
    }

    /// `+2 -30`.
    private static func aheadBehind(_ counts: String) -> (ahead: Int, behind: Int)? {
        let words = counts.split(separator: " ")
        guard words.count == 2, words[0].hasPrefix("+"), words[1].hasPrefix("-"),
            let ahead = Int(words[0].dropFirst()), let behind = Int(words[1].dropFirst())
        else { return nil }
        return (ahead, behind)
    }

    // MARK: Stashes

    /// How many of the stashes in `subjects`, the lines of `git stash list --format=%gs`, were made on `branch`.
    ///
    /// Git words the subject of a stash as `WIP on <branch>: <commit> <message>` or, when it was given a message,
    /// `On <branch>: <message>`. A subject belongs to the branch when it begins with one of these, up to and
    /// including the colon: that is the whole name, and not the beginning of the name of another branch. A branch that
    /// is mentioned in a message does not count. The stash of a detached HEAD is made on `(no branch)`.
    public static func stashCount(subjects: String, branch: String) -> Int {
        let prefixes = ["WIP on \(branch):", "On \(branch):"]
        return subjects.split(separator: "\n").count { subject in prefixes.contains { subject.hasPrefix($0) } }
    }

    // MARK: Remotes

    /// The remotes of `git remote -v`, in the order git lists them, each of them once, with the URL that it is fetched
    /// from. Git lists a remote that has a separate push URL a second time for that.
    public static func remotes(verbose: String) -> [Remote] {
        var names: [String] = []
        var fetchURLs: [String: String] = [:]
        var pushURLs: [String: String] = [:]
        for line in Line.all(in: verbose) {
            guard let (name, rest) = line.split(at: "\t") else { continue }
            if let url = rest.value(removingSuffix: " (fetch)") {
                if fetchURLs[name] == nil { fetchURLs[name] = url }
            } else if let url = rest.value(removingSuffix: " (push)") {
                if pushURLs[name] == nil { pushURLs[name] = url }
            } else {
                continue
            }
            if !names.contains(name) { names.append(name) }
        }
        return names.compactMap { name in
            (fetchURLs[name] ?? pushURLs[name]).map { Remote(name: name, url: $0) }
        }
    }
}

/// A line of git's output, looked at as Unicode scalars.
///
/// As `Character`s, the space after a keyword and a combining mark that a file name starts with make a single
/// `Character`, and a line that does start with the keyword would not look as if it did. A file named that way is rare,
/// but a file that goes uncounted is one that a worktree can be removed with.
private struct Line {
    private let scalars: Substring.UnicodeScalarView

    private init(_ scalars: Substring.UnicodeScalarView) {
        self.scalars = scalars
    }

    /// The lines of `text` that are not empty.
    static func all(in text: String) -> [Line] {
        text.unicodeScalars.split(separator: "\n").map(Line.init)
    }

    func hasPrefix(_ prefix: String) -> Bool {
        scalars.starts(with: prefix.unicodeScalars)
    }

    /// What follows `prefix`, when the line begins with it.
    func value(after prefix: String) -> String? {
        hasPrefix(prefix) ? String(scalars.dropFirst(prefix.unicodeScalars.count)) : nil
    }

    /// The line without `suffix`, when it ends with it.
    func value(removingSuffix suffix: String) -> String? {
        let length = suffix.unicodeScalars.count
        return scalars.suffix(length).elementsEqual(suffix.unicodeScalars)
            ? String(scalars.dropLast(length)) : nil
    }

    /// The line is `keyword`, with a value after it or without.
    func isKeyword(_ keyword: String) -> Bool {
        scalars.elementsEqual(keyword.unicodeScalars) || hasPrefix(keyword + " ")
    }

    /// The parts of the line before and after the first `separator`.
    func split(at separator: Unicode.Scalar) -> (String, Line)? {
        guard let index = scalars.firstIndex(of: separator) else { return nil }
        return (String(scalars[..<index]), Line(scalars[scalars.index(after: index)...]))
    }
}
