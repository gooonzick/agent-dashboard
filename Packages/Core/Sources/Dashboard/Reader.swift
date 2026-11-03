import CoreModels
import Foundation
import GitKit
import Hosting
import ProcessKit
import Safety

/// What git says about a worktree, besides the entry of `git worktree list`: the facts that `RemovalPolicy` decides on.
struct GitFacts: Sendable, Equatable {
    var status: WorktreeStatus?
    /// `nil` when the stash list could not be read.
    var stashCount: Int?
    /// Only counted when the branch has no live upstream. `nil` when it was not counted, or could not be.
    var commitsNotOnAnyRemote: Int?
    /// Only found out when the request is merged and the branch has no live upstream.
    var headContainedInReview: Bool?

    /// The facts for the policy. A stash list that could not be read leaves the facts without a status: that blocks,
    /// and never with a made-up count.
    func removalFacts(
        of worktree: Worktree, review: ReviewInfo, runningGroups: Int, signaler: any ProcessSignaling
    ) -> RemovalFacts {
        RemovalFacts(
            worktree: worktree, status: stashCount == nil ? nil : status, review: review, stashCount: stashCount ?? 0,
            commitsNotOnAnyRemote: commitsNotOnAnyRemote, headContainedInReview: headContainedInReview,
            runningGroups: runningGroups,
            lockOwnerAlive: worktree.lock?.ownerPID.map(signaler.isAlive) ?? false)
    }
}

/// The request of a branch, as it was found for a worktree when it was on that branch.
struct KnownReview: Sendable, Equatable {
    let branch: String
    let info: ReviewInfo
}

/// A repository as git describes it.
struct RepositorySnapshot: Sendable {
    /// `nil` when git could not list them.
    let worktrees: [Worktree]?
    let remote: RemoteURL?
    let facts: [String: GitFacts]
    /// The worktree that each folder in `.git/worktrees` belongs to, by the folder's name.
    let adminNames: [String: String]
}

/// Reads git and the hosting service for the store, and for the recheck before a removal. Every git command and every
/// request goes through one of the two limiters, which all readers of a store share.
struct Reader: Sendable {
    let git: any GitReading
    let reviews: any ReviewLooking
    let hosting: any HostingDetecting
    let gitLimit: Limiter
    let networkLimit: Limiter

    // MARK: Git

    @concurrent
    func repository(at path: String, reviews known: [String: KnownReview]) async -> RepositorySnapshot {
        let url = URL(filePath: path, directoryHint: .isDirectory)
        guard let worktrees = try? await gitLimit.run({ try await git.worktrees(repo: url) }) else {
            return RepositorySnapshot(worktrees: nil, remote: nil, facts: [:], adminNames: [:])
        }
        let remotes = (try? await gitLimit.run { try await git.remotes(repo: url) }) ?? []
        var facts: [String: GitFacts] = [:]
        for worktree in worktrees {
            facts[worktree.path] = await self.facts(of: worktree, in: path, review: known.review(of: worktree))
        }
        return RepositorySnapshot(
            worktrees: worktrees, remote: Self.origin(of: remotes), facts: facts,
            adminNames: Self.adminNames(of: worktrees, in: path))
    }

    /// The facts of one worktree. For the main worktree only the status is read: it is never removed. For a worktree
    /// whose folder is gone nothing is read (Ruling 20).
    @concurrent
    func facts(of worktree: Worktree, in repo: String, review: ReviewInfo) async -> GitFacts {
        guard !worktree.isPrunable else { return GitFacts() }
        let folder = URL(filePath: worktree.path, directoryHint: .isDirectory)
        let status = try? await gitLimit.run { try await git.status(worktree: folder) }
        guard !worktree.isMain, let status else { return GitFacts(status: status) }

        let repoURL = URL(filePath: repo, directoryHint: .isDirectory)
        // Git cannot tell which detached worktree made a stash on `(no branch)`: it counts for each of them.
        let stashBranch = worktree.isDetached ? nil : worktree.branch
        let stashes = try? await gitLimit.run {
            try await git.stashCount(repo: repoURL, branch: stashBranch ?? "(no branch)")
        }
        let commits =
            status.hasLiveUpstream
            ? nil : try? await gitLimit.run { try await git.commitsNotOnAnyRemote(worktree: folder) }
        return GitFacts(
            status: status, stashCount: stashes, commitsNotOnAnyRemote: commits,
            headContainedInReview: await headContained(worktree, in: repo, status: status, review: review))
    }

    /// Whether HEAD is in the merged request, when the policy asks: the request is merged and the branch has no live
    /// upstream. Only a full commit id is handed to git (Ruling 27): a short one could name a branch or a tag.
    private func headContained(
        _ worktree: Worktree, in repo: String, status: WorktreeStatus, review: ReviewInfo
    ) async -> Bool? {
        guard review.state == .merged, !status.hasLiveUpstream, let head = worktree.head,
            let merged = review.headSHA, Self.isFullCommitID(merged)
        else { return nil }
        let repoURL = URL(filePath: repo, directoryHint: .isDirectory)
        let answer = try? await gitLimit.run { try await git.isAncestorOrEqual(head, of: merged, repo: repoURL) }
        return answer ?? nil
    }

    /// 40 or 64 hexadecimal digits of ASCII.
    static func isFullCommitID(_ id: String) -> Bool {
        (id.utf8.count == 40 || id.utf8.count == 64)
            && id.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) || (65...70).contains($0) }
    }

    /// `git fetch --prune`, and whether it went through.
    @concurrent
    func fetch(_ repo: String) async -> Bool {
        let url = URL(filePath: repo, directoryHint: .isDirectory)
        return (try? await gitLimit.run { try await git.fetchPrune(repo: url) }) != nil
    }

    // MARK: Hosting

    /// What each of `hosts` runs, each asked once.
    @concurrent
    func kinds(of hosts: Set<String>) async -> [String: HostingKind] {
        // The limiter holds the requests to four; there are a handful of hosts.
        await withTaskGroup(of: (String, HostingKind).self) { group in
            for host in hosts {
                group.addTask { [hosting, networkLimit] in
                    (host, await networkLimit.run { await hosting.kind(for: host) })
                }
            }
            var kinds: [String: HostingKind] = [:]
            for await (host, kind) in group { kinds[host] = kind }
            return kinds
        }
    }

    /// The request of the worktree's branch. A worktree without a branch is never asked about (Ruling 28), nor one
    /// whose folder is gone, nor one on a host that runs neither GitHub nor GitLab.
    @concurrent
    func review(of worktree: Worktree, remote: RemoteURL?, kind: HostingKind?) async -> ReviewInfo {
        guard !worktree.isDetached, !worktree.isPrunable, let branch = worktree.branch, let remote,
            kind == .github || kind == .gitlab
        else { return .unknown }
        return await networkLimit.run { await reviews.review(remote: remote, branch: branch) }
    }

    // MARK: The recheck

    /// The state of the worktree right before it is deleted, read anew from the remote, git, the host and the
    /// processes that run now. A fetch that fails is a refusal (Ruling 43): what is on the remote is not known then.
    @concurrent
    func recheck(
        _ worktree: Worktree, in repo: String, remote: RemoteURL?, kind: HostingKind?, roots: [String],
        sampler: any ProcessSampling, signaler: any ProcessSignaling
    ) async -> RemovalEligibility {
        guard await fetch(repo) else { return .blocked([.cantVerify]) }
        await reviews.invalidate()
        let review = await self.review(of: worktree, remote: remote, kind: kind)
        let facts = await self.facts(of: worktree, in: repo, review: review)
        // What runs now, after the processes of the request were stopped (Ruling 47).
        let groups = ProcessGroups.attribute(sampler.sample(), to: roots)
        let running = groups[worktree.path]?.count ?? 0
        return RemovalPolicy.evaluate(
            facts.removalFacts(of: worktree, review: review, runningGroups: running, signaler: signaler))
    }

    // MARK: Helpers

    /// The remote of `origin`, or the first one if there is no `origin`, read as an address on a hosting service. The
    /// URL itself is not kept: it can hold a token.
    private static func origin(of remotes: [Remote]) -> RemoteURL? {
        (remotes.first { $0.name == "origin" } ?? remotes.first).flatMap { RemoteURL($0.url) }
    }

    /// Reads the `.git` file of each linked worktree: `gitdir: <repo>/.git/worktrees/<name>`.
    private static func adminNames(of worktrees: [Worktree], in repo: String) -> [String: String] {
        let admin = repo + "/.git/worktrees"
        var names: [String: String] = [:]
        for worktree in worktrees where !worktree.isMain && !worktree.isPrunable {
            guard let text = try? String(contentsOfFile: worktree.path + "/.git", encoding: .utf8),
                let line = text.split(separator: "\n").first, line.hasPrefix("gitdir: ")
            else { continue }
            var gitdir = String(line.dropFirst("gitdir: ".count)).trimmingCharacters(in: .whitespaces)
            if !gitdir.hasPrefix("/") { gitdir = worktree.path + "/" + gitdir }  // `worktree.useRelativePaths`
            // `canonicalPath`, and not `standardizedFileURL`, which turns `/private/var` into `/var`.
            let resolved = canonicalPath(gitdir)
            let parent = (resolved as NSString).deletingLastPathComponent
            if parent == admin { names[(resolved as NSString).lastPathComponent] = worktree.path }
        }
        return names
    }
}

extension WorktreeStatus {
    /// The branch tracks a remote branch that is still there.
    var hasLiveUpstream: Bool { upstream != nil && !upstreamGone }
}

extension [String: KnownReview] {
    /// The request that was found for `worktree`, if it is still on the branch that it was found for.
    func review(of worktree: Worktree) -> ReviewInfo {
        guard !worktree.isDetached, let branch = worktree.branch, let known = self[worktree.path],
            known.branch == branch
        else { return .unknown }
        return known.info
    }
}

/// What runs in each worktree.
enum ProcessGroups {
    /// The groups of `processes` in each of `roots`, without this app and the processes that it started (Ruling 40):
    /// the app never shows itself, nor stops itself.
    static func attribute(
        _ processes: [ProcessRecord], to roots: [String], ownPID: Int32 = ProcessInfo.processInfo.processIdentifier
    ) -> [String: [ProcessGroup]] {
        let childrenOf = Dictionary(grouping: processes, by: \.ppid)
        var own: Set<Int32> = [ownPID]
        var pending = [ownPID]
        while let parent = pending.popLast() {
            for child in childrenOf[parent] ?? [] where own.insert(child.pid).inserted { pending.append(child.pid) }
        }
        return ProcessAttributor(roots: roots).attribute(processes.filter { !own.contains($0.pid) })
    }

    /// A sample of the processes, attributed: off the main actor, for both take a while.
    @concurrent
    static func sample(_ sampler: any ProcessSampling, roots: [String]) async -> [String: [ProcessGroup]] {
        attribute(sampler.sample(), to: roots)
    }
}
