import CoreModels
import Dashboard
import Foundation
import SwiftUI

/// What the sidebar selects.
enum SidebarItem: Hashable {
    case projects
    case readyToRemove
    case repository(String)
}

/// The startup disk, as the foot of the sidebar shows it.
struct StartupDisk: Equatable {
    let name: String
    let free: Int64
    let total: Int64

    static func read() -> StartupDisk? {
        let keys: Set<URLResourceKey> = [
            .volumeLocalizedNameKey, .volumeAvailableCapacityForImportantUsageKey, .volumeTotalCapacityKey,
        ]
        guard let values = try? URL(filePath: "/").resourceValues(forKeys: keys),
            let free = values.volumeAvailableCapacityForImportantUsage, let total = values.volumeTotalCapacity
        else { return nil }
        return StartupDisk(name: values.volumeLocalizedName ?? "Macintosh HD", free: free, total: Int64(total))
    }
}

struct SidebarView: View {
    let projects: [ProjectRow]
    let readyCount: Int
    let disk: StartupDisk?
    @Binding var selection: SidebarItem?

    var body: some View {
        List(selection: $selection) {
            Label("Projects", systemImage: "list.bullet.indent")
                .tag(SidebarItem.projects)
            Label("Ready to remove", systemImage: "sparkles")
                .badge(readyCount)
                .tag(SidebarItem.readyToRemove)
            Section("Repositories") {
                ForEach(projects) { project in
                    Label(project.name, systemImage: "folder")
                        .badge(project.worktrees.count)
                        .tag(SidebarItem.repository(project.path))
                }
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if let disk { DiskFooter(disk: disk) }
        }
        .background { ShortcutButtons(selection: $selection) }
    }
}

private struct DiskFooter: View {
    let disk: StartupDisk

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "internaldrive").foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text(disk.name).font(.callout).lineLimit(1)
                Text("\(SizeFormat.disk(disk.free)) free of \(SizeFormat.disk(disk.total))")
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .accessibilityElement(children: .combine)
    }
}

/// ⌘1 and ⌘2, which pick the two sections of the sidebar.
private struct ShortcutButtons: View {
    @Binding var selection: SidebarItem?

    var body: some View {
        VStack {
            Button("Projects") { selection = .projects }.keyboardShortcut("1")
            Button("Ready to remove") { selection = .readyToRemove }.keyboardShortcut("2")
        }
        .opacity(0)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}
