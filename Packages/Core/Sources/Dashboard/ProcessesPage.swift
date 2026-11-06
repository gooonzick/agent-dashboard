import CoreModels
import Foundation

/// The Processes page as the store's rows make it: a section for each worktree that has something running, the memory
/// of all of them as one bar, and the numbers of the page's subtitle. Made of the rows alone, so that what is on the
/// page can be tested without a window.
public struct ProcessesPage: Equatable, Sendable {
    /// The most memory first; a tie goes by title.
    public let sections: [ProcessSection]
    /// The leaders and the members of every group, each pid once.
    public let processCount: Int
    public let totalMemory: UInt64
    /// The first `barLimit` sections, and the rest as one `other`.
    public let bar: [MemorySegment]

    private static let barLimit = 5

    /// Every worktree of every project is a candidate, the main one included. A worktree with no group is not listed.
    /// A `query` keeps the sections that it names, and in the others the lines that it matches (see `ProcessSection`).
    public init(projects: [ProjectRow], query: String = "") {
        let needle = query.trimmingCharacters(in: .whitespaces).lowercased()
        let rows = projects.flatMap { [$0.main] + $0.worktrees }
        sections = rows.compactMap { ProcessSection($0, matching: needle) }.sorted {
            if $0.memory != $1.memory { return $0.memory > $1.memory }
            let (a, b) = ($0.title.lowercased(), $1.title.lowercased())
            return a == b ? $0.id < $1.id : a < b
        }
        processCount = Set(sections.lazy.flatMap(\.lines).flatMap(\.groups).flatMap(ProcessSection.pids)).count
        totalMemory = sections.reduce(0) { $0.saturatingAdd($1.memory) }
        var segments = sections.prefix(Self.barLimit).map {
            MemorySegment(label: $0.barLabel, bytes: $0.memory, worktree: $0.id)
        }
        let rest = sections.dropFirst(Self.barLimit)
        if !rest.isEmpty {
            segments.append(
                MemorySegment(label: "other", bytes: rest.reduce(0) { $0.saturatingAdd($1.memory) }, worktree: nil))
        }
        bar = segments
    }
}

/// One worktree with something running in it.
public struct ProcessSection: Identifiable, Equatable, Sendable {
    /// The path of the worktree.
    public var id: String { row.id }
    public let row: WorktreeRow
    /// The name of the worktree's folder, the repository's name for the main one.
    public let title: String
    /// `12 processes`, `1 process`; for a linked worktree the repository comes first: `dashboard · 9 processes`.
    public let subtitle: String
    /// What the lines below weigh together.
    public let memory: UInt64
    public let lines: [ProcessLine]

    /// `nil` when nothing of the worktree is left to show: it runs nothing, or the query matches none of it. A query
    /// that names the title or the repository shows the whole worktree; any other keeps the lines whose title, process
    /// name, pid or port it matches.
    init?(_ row: WorktreeRow, matching needle: String) {
        var lines = ProcessLine.lines(of: row)
        let title = row.displayName
        let named = title.lowercased().contains(needle) || row.repoName.lowercased().contains(needle)
        if !needle.isEmpty, !named { lines = lines.filter { $0.matches(needle) } }
        guard !lines.isEmpty else { return nil }
        let count = Set(lines.lazy.flatMap(\.groups).flatMap(Self.pids)).count
        let noun = count == 1 ? "1 process" : "\(count) processes"
        self.row = row
        self.title = title
        subtitle = row.worktree.isMain ? noun : "\(row.repoName) · \(noun)"
        memory = lines.reduce(0) { $0.saturatingAdd($1.memory) }
        self.lines = lines
    }

    /// What the bar calls the worktree: the ticket of a branch named for one, `PYMEP-3330` for
    /// `PYMEP-3330-overdraft-drawer`, otherwise the title.
    var barLabel: String {
        guard !row.worktree.isMain, let ticket = title.range(of: "^[A-Z][A-Z0-9]+-\\d+", options: .regularExpression)
        else { return title }
        return String(title[ticket])
    }

    static func pids(_ group: ProcessGroup) -> [Int32] {
        [group.leader.pid] + group.members.map(\.pid)
    }
}

/// One row of a section: a group, or the shells and helpers that did not get a row of their own, merged.
public struct ProcessLine: Identifiable, Equatable, Sendable {
    /// `<worktree>#<leader pid>`, or `<worktree>#rest` for the merged line.
    public let id: String
    /// One group, or the several that the merged line holds.
    public let groups: [ProcessGroup]
    public let title: String
    /// `Agent session`, `Dev server`, `Daemon`, `Built here`, `Shell` or `Other`.
    public let kind: String
    /// The SF Symbol of the kind.
    public let symbol: String
    /// The leader's. `nil` for the merged line.
    public let pid: Int32?
    public let ports: [UInt16]
    public let memory: UInt64

    /// How long the group has run. `nil` for the merged line, which is no one process.
    public func uptime(now: Date) -> Uptime? {
        guard groups.count == 1, let group = groups.first else { return nil }
        return ProcessesPresenter.uptime(group.uptime(now: now), kind: group.kind)
    }

    /// The groups of the worktree by memory, then by the pid of the leader. Two shells or helpers, or more, are merged
    /// into the last line: a worktree with a dozen idle shells is not a dozen rows.
    static func lines(of row: WorktreeRow) -> [ProcessLine] {
        let ordered = row.groups.sorted {
            $0.totalFootprint == $1.totalFootprint
                ? $0.leader.pid < $1.leader.pid : $0.totalFootprint > $1.totalFootprint
        }
        let background = ordered.filter { $0.kind == .shell || $0.kind == .other }
        guard background.count > 1 else { return ordered.map { ProcessLine(row.id, $0) } }
        let rest = ordered.filter { $0.kind != .shell && $0.kind != .other }
        return rest.map { ProcessLine(row.id, $0) } + [ProcessLine(merging: background, in: row.id)]
    }

    private init(_ worktree: String, _ group: ProcessGroup) {
        id = "\(worktree)#\(group.leader.pid)"
        groups = [group]
        title = group.title
        (kind, symbol) = Self.words(of: group.kind)
        pid = group.leader.pid
        ports = group.ports
        memory = group.totalFootprint
    }

    private init(merging groups: [ProcessGroup], in worktree: String) {
        let shells = groups.filter { $0.kind == .shell }.count
        let helpers = groups.count - shells
        id = "\(worktree)#rest"
        self.groups = groups
        title = [
            shells > 0 ? (shells == 1 ? "1 shell" : "\(shells) shells") : nil,
            helpers > 0 ? (helpers == 1 ? "1 helper" : "\(helpers) helpers") : nil,
        ].compactMap { $0 }.joined(separator: ", ")
        (kind, symbol) = Self.words(of: helpers == 0 ? .shell : .other)
        pid = nil
        ports = Array(Set(groups.flatMap(\.ports))).sorted()
        memory = groups.reduce(0) { $0.saturatingAdd($1.totalFootprint) }
    }

    private static func words(of kind: ProcessKind) -> (label: String, symbol: String) {
        switch kind {
        case .agentSession: ("Agent session", "sparkle")
        case .devServer: ("Dev server", "globe")
        case .daemon: ("Daemon", "gearshape")
        case .builtHere: ("Built here", "macwindow")
        case .shell: ("Shell", "apple.terminal")
        case .other: ("Other", "ellipsis")
        }
    }

    /// `needle` is lowercase. A pid has to match whole, and a port with or without its colon: `4200` and `:4200`.
    func matches(_ needle: String) -> Bool {
        if title.lowercased().contains(needle) { return true }
        let number = Int32(needle)
        let port = UInt16(needle.hasPrefix(":") ? String(needle.dropFirst()) : needle)
        return groups.contains { group in
            let processes = [group.leader] + group.members
            return processes.contains { $0.name.lowercased().contains(needle) || $0.pid == number }
                || port.map(group.ports.contains) == true
        }
    }
}

/// How long a process has run, as the page shows it.
public struct Uptime: Equatable, Sendable {
    public let text: String
    /// A session that has run for a day or more: the page marks it, as it is probably forgotten.
    public let isLong: Bool
}

/// A slice of the memory bar: one worktree, or `other` for the ones that did not fit.
public struct MemorySegment: Equatable, Sendable {
    public let label: String
    public let bytes: UInt64
    /// The path of the worktree; `nil` for `other`.
    public let worktree: String?
}

/// The words of the Processes page that are not a row's own.
public enum ProcessesPresenter {
    /// How recent an update has to be to read `just now`.
    private static let justNow: TimeInterval = 10

    /// `43 processes in 9 projects · 2.2 GB memory · updated just now`. The projects are the sections, the worktrees
    /// that run something. Without `updated`, which is `nil` before the first sample, the last part is left out.
    public static func subtitle(_ page: ProcessesPage, updated: Date?, now: Date) -> String {
        let processes = page.processCount == 1 ? "1 process" : "\(page.processCount) processes"
        let projects = page.sections.count == 1 ? "1 project" : "\(page.sections.count) projects"
        var parts = ["\(processes) in \(projects)", "\(SizeFormat.memory(page.totalMemory)) memory"]
        if let updated {
            parts.append(
                "updated " + (now.timeIntervalSince(updated) <= justNow ? "just now" : relative(updated, to: now)))
        }
        return parts.joined(separator: " · ")
    }

    /// `2.2 GB of 15.2 GB in use on this Mac`. `nil` while the memory of the Mac is not known.
    public static func inUse(_ page: ProcessesPage, of used: UInt64?) -> String? {
        used.map { "\(SizeFormat.memory(page.totalMemory)) of \(SizeFormat.memory($0)) in use on this Mac" }
    }

    /// `<1m`, `18m`, `1h 12m`. From a day on, `15d`; for a session, which the page flags, `6d 22h`, as a session that
    /// has run for days is what one wants to look at.
    public static func uptime(_ seconds: TimeInterval, kind: ProcessKind) -> Uptime {
        let minutes = Int(max(0, seconds) / 60)
        let (days, hours) = (minutes / 1_440, minutes / 60 % 24)
        switch minutes {
        case ..<1: return Uptime(text: "<1m", isLong: false)
        case ..<60: return Uptime(text: "\(minutes)m", isLong: false)
        case ..<1_440: return Uptime(text: "\(hours)h \(minutes % 60)m", isLong: false)
        default:
            return kind == .agentSession
                ? Uptime(text: "\(days)d \(hours)h", isLong: true) : Uptime(text: "\(days)d", isLong: false)
        }
    }

    private static func relative(_ date: Date, to now: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateTimeStyle = .named
        return formatter.localizedString(for: date, relativeTo: now)
    }
}

extension UInt64 {
    /// The sum, or the largest number when it would not fit.
    fileprivate func saturatingAdd(_ other: UInt64) -> UInt64 {
        let (sum, overflow) = addingReportingOverflow(other)
        return overflow ? .max : sum
    }
}
