import CoreModels
import Dashboard
import SwiftUI

/// The detail of Projects: the block of what is ready to remove, then every repository with its worktrees.
struct ProjectsView: View {
    let projects: [ProjectRow]
    let ready: [WorktreeRow]
    @Binding var filter: ProjectFilter
    @Binding var selection: String?
    @Binding var collapsed: Set<String>

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if !ready.isEmpty {
                ReadyToRemoveSection(rows: ready, selection: $selection)
                    .padding(.horizontal, 16)
                    .padding(.top, 12)
            }
            HStack {
                Text("All projects").font(.headline)
                Spacer()
                Picker("Filter", selection: $filter) {
                    ForEach(ProjectFilter.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
            }
            .padding(.horizontal, 16)
            .padding(.top, ready.isEmpty ? 12 : 0)
            ProjectsTable(projects: projects, selection: $selection, collapsed: $collapsed)
        }
    }
}
