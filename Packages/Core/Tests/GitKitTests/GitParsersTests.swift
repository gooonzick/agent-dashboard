import CoreModels
import Foundation
import GitKit
import Testing

@Suite struct GitParsersTests {
    @Test func parsesWorktreesIncludingClaudeLockPrunableAndDetached() {
        let out = """
            worktree /r/aura
            HEAD 1111
            branch refs/heads/main

            worktree /r/aura/.claude/worktrees/test-perf
            HEAD 2222
            branch refs/heads/test-perf
            locked claude session test-perf (pid 68374 start Fri Oct 30 14:39:21 2026)

            worktree /r/wt-gone
            HEAD 3333
            detached
            prunable gitdir file points to non-existent location

            """
        let w = GitParsers.worktrees(porcelain: out)
        #expect(w.map(\.isMain) == [true, false, false])
        #expect(w[1].lock?.ownerPID == 68374)
        #expect(w[2].isDetached && w[2].isPrunable && w[2].branch == nil)
    }

    @Test func detectsGoneUpstream() {
        let s = GitParsers.status(
            porcelainV2: "# branch.oid 1\n# branch.head f\n# branch.upstream origin/f\n", lastCommit: nil)
        #expect(s.upstreamGone && s.ahead == 0)
    }

    @Test func countsChangesAheadBehind() {
        let s = GitParsers.status(
            porcelainV2:
                "# branch.upstream origin/main\n# branch.ab +2 -30\n1 .M N... 1 1 1 a b f.txt\n? new.txt\n? n2.txt\n",
            lastCommit: nil)
        #expect(s.ahead == 2 && s.behind == 30 && s.modified == 1 && s.untracked == 2 && !s.upstreamGone)
    }

    @Test func countsStashesOfOneBranch() {
        #expect(
            GitParsers.stashCount(
                subjects: "WIP on feature/ünï: 1 x\nOn main: y\nOn feature/ünï: z\n", branch: "feature/ünï") == 2)
    }

    // What the brief's examples leave open: the rest of what `git worktree list --porcelain` can say, and the care that
    // the values need that later tasks decide what is safe to delete from.

    // MARK: Worktrees

    @Test func readsPathsWithSpacesAndBranchesWithSlashesAndNonASCII() {
        let out = """
            worktree /Users/me/My Projects/repo
            HEAD aaaa
            branch refs/heads/main

            worktree /Users/me/My Projects/wt feature
            HEAD bbbb
            branch refs/heads/feature/ünï/deep

            """

        #expect(
            GitParsers.worktrees(porcelain: out) == [
                Worktree(path: "/Users/me/My Projects/repo", head: "aaaa", branch: "main", isMain: true),
                Worktree(path: "/Users/me/My Projects/wt feature", head: "bbbb", branch: "feature/ünï/deep"),
            ])
    }

    @Test func onlyTheFirstEntryIsTheMainWorktree() {
        let out = "worktree /a\nHEAD 1\nbranch refs/heads/a\n\nworktree /b\nHEAD 2\ndetached\n\nworktree /c\nHEAD 3\n"
        #expect(GitParsers.worktrees(porcelain: out).map(\.isMain) == [true, false, false])
    }

    @Test func aLockWithoutAReasonIsStillALock() {
        // `git worktree lock` with no `--reason` prints a bare `locked`. Reading it as no lock would offer the worktree
        // for removal.
        let out = "worktree /a\nHEAD 1\nbranch refs/heads/a\n\nworktree /b\nHEAD 2\nbranch refs/heads/b\nlocked\n"

        let worktrees = GitParsers.worktrees(porcelain: out)

        #expect(worktrees.map(\.lock) == [nil, WorktreeLock(reason: "", ownerPID: nil)])
    }

    @Test func aLockTypedByHandHasAReasonAndNoOwner() {
        let out = "worktree /a\nHEAD 1\nbranch refs/heads/a\nlocked on usb drive\n"
        #expect(
            GitParsers.worktrees(porcelain: out).map(\.lock) == [WorktreeLock(reason: "on usb drive", ownerPID: nil)])
    }

    @Test func aLockKeepsTheWholeReasonAndTheOwnerOutOfIt() {
        let reason = "claude session test-perf (pid 68374 start Fri Oct 30 14:39:21 2026)"
        let out = "worktree /a\nHEAD 1\nbranch refs/heads/a\nlocked \(reason)\n"
        #expect(GitParsers.worktrees(porcelain: out).map(\.lock) == [WorktreeLock(reason: reason, ownerPID: 68374)])
    }

    @Test func readsPrunableWithAndWithoutAReason() {
        let out = """
            worktree /a
            HEAD 1
            branch refs/heads/a

            worktree /b
            HEAD 2
            branch refs/heads/b
            prunable gitdir file points to non-existent location

            worktree /c
            HEAD 3
            detached
            prunable

            """
        #expect(GitParsers.worktrees(porcelain: out).map(\.isPrunable) == [false, true, true])
    }

    @Test func aDetachedWorktreeHasAHeadAndNoBranch() {
        let out = "worktree /a\nHEAD 1\nbranch refs/heads/a\n\nworktree /b\nHEAD 2222\ndetached\n"
        #expect(
            GitParsers.worktrees(porcelain: out).last
                == Worktree(path: "/b", head: "2222", branch: nil, isMain: false, isDetached: true))
    }

    @Test func aBranchWithoutCommitsHasNoHead() {
        // Git writes the null id for an unborn branch, in a repository that is new or a worktree made with --orphan.
        let nullID = String(repeating: "0", count: 40)
        let out = "worktree /a\nHEAD \(nullID)\nbranch refs/heads/new\n"
        #expect(GitParsers.worktrees(porcelain: out) == [Worktree(path: "/a", head: nil, branch: "new", isMain: true)])
    }

    @Test func aBareRepositoryHasNeitherHeadNorBranch() {
        #expect(
            GitParsers.worktrees(porcelain: "worktree /srv/project.git\nbare\n\n") == [
                Worktree(path: "/srv/project.git", isMain: true)
            ])
    }

    @Test func skipsWhatItDoesNotKnow() {
        let out = "worktree /a\nHEAD 1\nfuture-attribute with a value\nbranch refs/heads/a\n\n"
        #expect(GitParsers.worktrees(porcelain: out) == [Worktree(path: "/a", head: "1", branch: "a", isMain: true)])
    }

    @Test func findsNoWorktreesInNothing() {
        #expect(GitParsers.worktrees(porcelain: "").isEmpty)
        #expect(GitParsers.worktrees(porcelain: "\n\n\n").isEmpty)
    }

    @Test func readsAPathThatStartsWithACombiningMark() {
        // The space after `worktree` and a combining mark that follows it make up one Character. Read as Characters the
        // line would not start with `worktree `.
        let out = "worktree \u{301}/odd\nHEAD 1\nbranch refs/heads/a\n"
        #expect(GitParsers.worktrees(porcelain: out).map(\.path) == ["\u{301}/odd"])
    }

    // MARK: Status

    @Test func aBranchWithoutUpstreamHasNothingToCompareWith() {
        let s = GitParsers.status(porcelainV2: "# branch.oid abc\n# branch.head topic\n", lastCommit: nil)
        #expect(s == WorktreeStatus())
    }

    @Test func aDetachedHeadHasNoUpstream() {
        let s = GitParsers.status(porcelainV2: "# branch.oid abc\n# branch.head (detached)\n", lastCommit: nil)
        #expect(s == WorktreeStatus())
    }

    @Test func anUpstreamThatIsInSyncIsNotGone() {
        let s = GitParsers.status(
            porcelainV2: "# branch.upstream origin/main\n# branch.ab +0 -0\n", lastCommit: nil)
        #expect(s == WorktreeStatus(upstream: "origin/main"))
    }

    @Test func aGoneUpstreamKeepsItsNameAndHasNothingToCount() {
        let s = GitParsers.status(
            porcelainV2: "# branch.oid 1\n# branch.head f\n# branch.upstream origin/feature/ünï\n", lastCommit: nil)
        #expect(s == WorktreeStatus(upstream: "origin/feature/ünï", upstreamGone: true))
    }

    @Test func countsRenamesAndConflictsAsChangesAndLeavesOutIgnoredFiles() {
        let out = """
            # branch.oid 1
            1 .M N... 100644 100644 100644 h1 h2 changed.txt
            1 A. N... 000000 100644 100644 h1 h2 added.txt
            2 R. N... 100644 100644 100644 h1 h2 R100 new.txt\told.txt
            u UU N... 100644 100644 100644 100644 h1 h2 h3 conflict.txt
            ! ignored.log
            ? loose.txt

            """

        let s = GitParsers.status(porcelainV2: out, lastCommit: nil)

        #expect(s.modified == 4)
        #expect(s.untracked == 1)
    }

    @Test func countsALineByItsMarkerNotByWhatItContains() {
        // A tracked file may have a name that looks like a marker. Only the start of a line counts.
        let s = GitParsers.status(porcelainV2: "1 .M N... 100644 100644 100644 h1 h2 ? odd name.txt\n", lastCommit: nil)
        #expect(s.modified == 1 && s.untracked == 0)
    }

    @Test func countsAnUntrackedFileThatStartsWithACombiningMark() {
        // The space after `?` and a combining mark that follows it make up one Character. Read as Characters the line
        // would not start with `? `, and the file would not be counted.
        let s = GitParsers.status(porcelainV2: "? \u{301}accent.txt\n", lastCommit: nil)
        #expect(s.untracked == 1)
    }

    @Test func keepsTheLastCommitDateItIsGiven() {
        let date = Date(timeIntervalSince1970: 1_793_361_600)
        #expect(GitParsers.status(porcelainV2: "# branch.oid 1\n", lastCommit: date).lastCommitDate == date)
    }

    @Test func aBranchWithoutCommitsIsTold() {
        #expect(!GitParsers.hasCommits(porcelainV2: "# branch.oid (initial)\n# branch.head main\n"))
        #expect(GitParsers.hasCommits(porcelainV2: "# branch.oid 06017b18b5094bd2fb2411d37c9f5373aecf862f\n"))
        #expect(GitParsers.hasCommits(porcelainV2: ""))  // nothing says there are none
    }

    @Test func aBranchThatGitCouldNotNameIsTold() {
        // Where git cannot say which branch HEAD is on, because the ref of the branch is damaged, it says `(unknown)`.
        #expect(GitParsers.hasUnknownBranch(porcelainV2: "# branch.oid (initial)\n# branch.head (unknown)\n"))
        #expect(!GitParsers.hasUnknownBranch(porcelainV2: "# branch.oid (initial)\n# branch.head main\n"))  // unborn
        #expect(!GitParsers.hasUnknownBranch(porcelainV2: "# branch.oid 1\n# branch.head (detached)\n"))
        #expect(!GitParsers.hasUnknownBranch(porcelainV2: "# branch.oid 1\n# branch.head (unknown)-fix\n"))  // a name
        #expect(!GitParsers.hasUnknownBranch(porcelainV2: ""))
    }

    @Test func aFileNamedLikeTheHeaderIsNoHeader() {
        // Entries begin with their marker, so the name of a file cannot pass for a line of the header.
        let out = "# branch.oid 1\n# branch.head main\n? # branch.head (unknown)\n"
        #expect(!GitParsers.hasUnknownBranch(porcelainV2: out))
    }

    // MARK: Stashes

    @Test func aStashBelongsToTheBranchWithTheWholeName() {
        let subjects = "WIP on main-fix: 1 a\nOn ma: b\nWIP on main: 2 c\nOn main: d\nOn feature/main: e\n"
        #expect(GitParsers.stashCount(subjects: subjects, branch: "main") == 2)
    }

    @Test func aBranchNamedInTheMessageIsNotTheBranch() {
        let subjects = "On dev: On main: not on main\nWIP on dev: 1 On main: nor this\n"
        #expect(GitParsers.stashCount(subjects: subjects, branch: "main") == 0)
        #expect(GitParsers.stashCount(subjects: subjects, branch: "dev") == 2)
    }

    @Test func takesTheBranchNameLiterally() {
        let subjects = "On feature/a+b (x): m\nOn feature/aab (x): m\nOn feature/.*: m\n"
        #expect(GitParsers.stashCount(subjects: subjects, branch: "feature/a+b (x)") == 1)
        #expect(GitParsers.stashCount(subjects: subjects, branch: "feature/.*") == 1)
    }

    @Test func aBranchNameMatchesHoweverItsLettersAreComposed() {
        // `ü` is one scalar, or a `u` and a combining diaeresis. A Mac treats the two as the same name, and so does
        // Swift. A stash must not go uncounted because one source writes the name the one way and another the other.
        let composed = "feature/\u{FC}n\u{EF}"
        let decomposed = "feature/u\u{308}ni\u{308}"
        #expect(GitParsers.stashCount(subjects: "On \(composed): x\n", branch: decomposed) == 1)
        #expect(GitParsers.stashCount(subjects: "WIP on \(decomposed): 1 x\n", branch: composed) == 1)
    }

    @Test func countsTheLastLineWithoutANewline() {
        #expect(GitParsers.stashCount(subjects: "On main: x", branch: "main") == 1)
    }

    @Test func countsNothingInNoStashes() {
        #expect(GitParsers.stashCount(subjects: "", branch: "main") == 0)
    }

    @Test func aStashOfADetachedHeadBelongsToNoBranch() {
        // Git names it `(no branch)`. No branch has that name, so it is found only when it is asked for by that name.
        let subjects = "WIP on (no branch): 1 x\n"
        #expect(GitParsers.stashCount(subjects: subjects, branch: "main") == 0)
        #expect(GitParsers.stashCount(subjects: subjects, branch: "(no branch)") == 1)
    }

    // MARK: Remotes

    @Test func readsEachRemoteOnceWithItsFetchURL() {
        let out = """
            origin\t/Users/me/My Projects/remote.git (fetch)
            origin\t/Users/me/My Projects/remote.git (push)
            upstream\tgit@gitlab.example.com:group/sub/project.git (fetch)
            upstream\tssh://git@push.example.com/project.git (push)

            """

        #expect(
            GitParsers.remotes(verbose: out) == [
                Remote(name: "origin", url: "/Users/me/My Projects/remote.git"),
                Remote(name: "upstream", url: "git@gitlab.example.com:group/sub/project.git"),
            ])
    }

    @Test func aRemoteWithSeveralPushURLsStillHasOneFetchURL() {
        let out = "r\ta.git (fetch)\nr\ta.git (push)\nr\tb.git (push)\n"
        #expect(GitParsers.remotes(verbose: out) == [Remote(name: "r", url: "a.git")])
    }

    @Test func aRepositoryWithoutRemotesHasNone() {
        #expect(GitParsers.remotes(verbose: "").isEmpty)
    }
}
