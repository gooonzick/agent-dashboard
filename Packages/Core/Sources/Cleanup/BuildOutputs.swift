import Foundation
import Shell

/// A folder that a build left inside a worktree, which git ignores and holds no file of: deleting it loses nothing that
/// the next build does not make again.
public struct BuildOutput: Sendable, Equatable, Identifiable {
    public var id: String { path }
    /// The canonical path of the folder.
    public let path: String
    /// The canonical path of the worktree it is in.
    public let worktree: String
    /// The name of the worktree's folder and the path inside it: `meetily/target`, `dashboard/apps/web/dist`.
    public let title: String
    /// `Rust build`, `Xcode DerivedData copy`, `Build output`, `Next.js build`, `Swift build` or `Turbo cache`.
    public let kind: String

    /// What `delete` is given is checked anew from the disk and git, so a value made up elsewhere cannot have it delete
    /// anything that `find` would not offer.
    public init(path: String, worktree: String, title: String, kind: String) {
        self.path = path
        self.worktree = worktree
        self.title = title
        self.kind = kind
    }
}

public protocol BuildOutputFinding: Sendable {
    /// The build outputs in `worktrees`, which are canonical paths, in that order and by path within each.
    func find(in worktrees: [String]) async -> [BuildOutput]
    /// Checks `output` again, right before acting, and then deletes its folder.
    func delete(_ output: BuildOutput) async throws
}

/// Finds build outputs by their names, a few levels below the root of each worktree, and asks git of each whether it
/// ignores the folder and tracks nothing in it.
///
/// A folder is a build output only when all of this holds, and `delete` asks all of it again:
/// - it is named like one, at most `maxDepth` folders below the worktree, and not inside `.git` or `node_modules`;
/// - neither it nor a folder on the way is a symlink: the path resolves to itself;
/// - neither it nor a folder on the way below the worktree holds a `.git`: another repository, a nested worktree or a
///   checkout of a `gh-pages` branch, has an index and a `.gitignore` of its own that the worktree's git does not see;
/// - git ignores it (`check-ignore`) and has no file of it in the index (`ls-files`). A folder git cannot answer for
///   is not one.
///
/// `@unchecked Sendable`: `FileManager` is the only stored value that is not, and it has no delegate here, which makes
/// its methods safe to call from any thread.
public struct BuildOutputFinder: BuildOutputFinding, @unchecked Sendable {
    private static let gitTimeout: Duration = .seconds(15)
    /// How many folders below the worktree a build output may be: `apps/web/dist` is 3.
    private static let maxDepth = 4
    private static let kinds = [
        "target": "Rust build",
        "DerivedData": "Xcode DerivedData copy",
        ".next": "Next.js build",
        ".build": "Swift build",
        ".turbo": "Turbo cache",
        "build": "Build output",
        "dist": "Build output",
    ]
    /// Folders that are never entered: git's own, and the packages of a JavaScript project, which hold `dist` folders
    /// by the thousand that belong to their packages.
    private static let skipped: Set<String> = [".git", "node_modules"]

    private let runner: any CommandRunning
    private let fileManager: FileManager

    public init(runner: any CommandRunning) {
        self.runner = runner
        fileManager = .default
    }

    public func find(in worktrees: [String]) async -> [BuildOutput] {
        var outputs: [BuildOutput] = []
        for worktree in worktrees {
            // A worktree that is gone, or is no repository, has nothing to offer.
            guard let root = Self.resolved(worktree), isRepository(root) else { continue }
            let name = (root as NSString).lastPathComponent
            for relative in candidates(in: root) {
                let path = root + "/" + relative
                guard Self.resolved(path) == path, await state(of: relative, in: root) == .eligible else { continue }
                outputs.append(
                    BuildOutput(
                        path: path, worktree: root, title: name + "/" + relative,
                        kind: Self.kinds[(relative as NSString).lastPathComponent] ?? "Build output"))
            }
        }
        return outputs
    }

    /// The disk is checked before git is asked, and again after it, right before the delete, so that what git takes
    /// to answer is not part of the window. The folder is deleted through its resolved path, which the checks found
    /// to be the path itself, and the delete is partial when it stops half way: what was deleted stays deleted, which
    /// is fine for a build output. A symlink or a repository swapped in between the last check and the delete is a
    /// window that stays open, accepted for a tool that one person runs on their own machine.
    public func delete(_ output: BuildOutput) async throws {
        let relative = try check(output)
        switch await state(of: relative, in: output.worktree) {
        case .eligible: break
        case .notEligible: throw CleanupError.notEligible(output.path)
        case .unknown(let reason): throw CleanupError.failed(reason)
        }
        let target = output.worktree + "/" + (try check(output))
        do {
            try fileManager.removeItem(atPath: target)
        } catch {
            throw CleanupError.failed(error.localizedDescription)
        }
    }

    // MARK: - The folders

    /// The path of `output` relative to its worktree, when the disk still shows a build output there that `find`
    /// could offer; throws otherwise.
    private func check(_ output: BuildOutput) throws -> String {
        let root = output.worktree
        // The worktree is taken as it is and not resolved: one that turned into a link, or is gone, is not the
        // worktree the output was found in.
        guard Self.resolved(root) == root else { throw CleanupError.pathEscapes(root) }
        guard output.path.hasPrefix(root + "/") else { throw CleanupError.pathEscapes(output.path) }
        let relative = String(output.path.dropFirst(root.count + 1))
        guard Self.isCandidate(relative) else { throw CleanupError.notEligible(output.path) }
        // Exactly the path, so a link anywhere below the worktree, the folder itself included, leads somewhere else;
        // and a folder that cannot be resolved is not deleted on a guess.
        guard Self.resolved(output.path) == root + "/" + relative else { throw CleanupError.pathEscapes(output.path) }
        guard isFolder(output.path), isRepository(root), !holdsRepository(relative, in: root) else {
            throw CleanupError.notEligible(output.path)
        }
        return relative
    }

    /// The paths, relative to `root`, of the folders named like build outputs, sorted. Symlinks are neither entered nor
    /// offered, and neither is a folder that holds a repository; a build output is not entered either, for whatever is
    /// in it goes with it.
    private func candidates(in root: String) -> [String] {
        guard let enumerator = fileManager.enumerator(atPath: root) else { return [] }
        var found: [String] = []
        while let relative = enumerator.nextObject() as? String {
            // The enumerator does not follow links; a link to a folder is a link here, not a folder.
            guard enumerator.fileAttributes?[.type] as? FileAttributeType == .typeDirectory else { continue }
            let name = (relative as NSString).lastPathComponent
            if Self.skipped.contains(name) || isRepository(root + "/" + relative) {
                enumerator.skipDescendants()
                continue
            }
            if Self.kinds[name] != nil {
                found.append(relative)
                enumerator.skipDescendants()
            } else if enumerator.level >= Self.maxDepth {
                enumerator.skipDescendants()
            }
        }
        return found.sorted()
    }

    /// Whether `relative` is a path `find` could have offered: plain names only (no `..`, no empty part), at most
    /// `maxDepth` deep, the last one that of a build output, and none of them a folder that is never entered.
    private static func isCandidate(_ relative: String) -> Bool {
        let parts = relative.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        return (1...maxDepth).contains(parts.count)
            && parts.allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." && !skipped.contains($0) }
            && kinds[parts[parts.count - 1]] != nil
    }

    /// Whether a folder from the first one below `root` down to `relative` itself holds a `.git`.
    private func holdsRepository(_ relative: String, in root: String) -> Bool {
        var path = root
        for part in relative.split(separator: "/") {
            path += "/" + part
            if isRepository(path) { return true }
        }
        return false
    }

    /// Whether `path` holds a `.git` of any kind: a folder, a file that points at one, or a link.
    private func isRepository(_ path: String) -> Bool {
        (try? fileManager.attributesOfItem(atPath: path + "/.git")) != nil
    }

    /// Whether `path` is a folder, and not a link to one.
    private func isFolder(_ path: String) -> Bool {
        (try? fileManager.attributesOfItem(atPath: path))?[.type] as? FileAttributeType == .typeDirectory
    }

    private static func resolved(_ path: String) -> String? {
        guard let resolved = realpath(path, nil) else { return nil }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    // MARK: - Git

    private enum State: Equatable {
        /// Ignored, with nothing of it in the index.
        case eligible
        /// Not ignored, or a file in it is tracked.
        case notEligible
        /// Git could not say; what stopped it.
        case unknown(String)
    }

    /// What git says of `relative` in the worktree at `root`.
    private func state(of relative: String, in root: String) async -> State {
        // `check-ignore` exits with 1 for a path that is not ignored, and with 128 for an error.
        let ignored: CommandResult
        do {
            ignored = try await git(["check-ignore", "-q", relative], in: root)
        } catch {
            return .unknown(Self.message(of: error))
        }
        switch ignored.exitCode {
        case 0: break
        case 1: return .notEligible
        default: return .unknown(Self.message(of: ignored))
        }
        // `--literal-pathspecs`: a folder on the way named like `:(glob)*` is a name, not a pattern.
        let tracked: CommandResult
        do {
            tracked = try await git(["--literal-pathspecs", "ls-files", "--", relative], in: root)
        } catch {
            return .unknown(Self.message(of: error))
        }
        guard tracked.exitCode == 0 else { return .unknown(Self.message(of: tracked)) }
        return tracked.stdout.allSatisfy(\.isWhitespace) ? .eligible : .notEligible
    }

    /// Reads only, so with `--no-optional-locks`, as `GitReader` does.
    private func git(_ arguments: [String], in root: String) async throws -> CommandResult {
        try await runner.run(
            "git", ["--no-optional-locks", "-C", root] + arguments, in: nil, timeout: Self.gitTimeout)
    }

    private static func message(of result: CommandResult) -> String {
        firstErrorLine(in: result.stderr) ?? "git failed with exit code \(result.exitCode)"
    }

    private static func message(of error: any Error) -> String {
        switch error {
        case CommandError.notFound: "git is not installed"
        case CommandError.timedOut: "git did not finish in time"
        default: error.localizedDescription
        }
    }
}
