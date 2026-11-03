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
    let actions: RowActions

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if !ready.isEmpty {
                ReadyToRemoveSection(rows: ready, selection: $selection, actions: actions)
                    .padding(.horizontal, Self.margin)
                    .padding(.bottom, 24)
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
            .padding(.horizontal, Self.margin)
            .padding(.bottom, 10)
            ProjectsTable(projects: projects, selection: $selection, collapsed: $collapsed, actions: actions)
                .contentMargins(.horizontal, Self.margin, for: .scrollContent)
        }
        .padding(.top, Self.margin)
    }

    private static let margin: CGFloat = 20
}
