import CoreModels
import Dashboard
import Foundation
import SwiftUI

/// What the sidebar selects.
enum SidebarItem: Hashable {
    case projects
    case readyToRemove
    case processes
    case caches
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
            // The worktrees that run something, whatever the search says.
            Label("Processes", systemImage: "waveform.path.ecg")
                .badge(ProcessesPage(projects: projects).sections.count)
                .tag(SidebarItem.processes)
            Label("Caches and Docker", systemImage: "cylinder.split.1x2")
                .tag(SidebarItem.caches)
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
        // The list scrolls under the footer: without a background of its own the rows show through its text.
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
        .accessibilityElement(children: .combine)
    }
}
