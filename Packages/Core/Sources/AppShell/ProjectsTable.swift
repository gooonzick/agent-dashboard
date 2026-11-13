import CoreModels
import Dashboard
import SwiftUI

/// One line of the table: a repository, as its main worktree, or a worktree that was added to it.
struct TableNode: Identifiable {
    let row: WorktreeRow
    var id: String { row.id }
}

/// The repositories, each with its worktrees under it. Arrow keys walk the rows; right and left open and close a
/// repository.
struct ProjectsTable: View {
    let projects: [ProjectRow]
    @Binding var selection: String?
    /// The repositories that are closed: a repository that has just been found is open.
    @Binding var collapsed: Set<String>
    let actions: RowActions

    var body: some View {
        Table(of: TableNode.self, selection: $selection) {
            // The name is what a row is read by: it takes the room the narrow columns leave (their `max`).
            TableColumn("Name") { node in NameCell(row: node.row) }
                .width(min: 200, ideal: 280)
            TableColumn("MR / PR") { node in ReviewChip(review: node.row.review) }
                .width(min: 70, ideal: 85, max: 110)
            TableColumn("State") { node in StateChips(row: node.row) }
                .width(min: 110, ideal: 150, max: 200)
            TableColumn("Running") { node in RunningCell(groups: node.row.groups) }
                .width(min: 120, ideal: 180)
            TableColumn("Real size") { node in
                Text(node.row.size.realSizeText).monospacedDigit().frame(maxWidth: .infinity, alignment: .trailing)
            }
            .width(min: 70, ideal: 80, max: 100)
            .alignment(.trailing)
        } rows: {
            ForEach(projects) { project in
                if project.worktrees.isEmpty {
                    TableRow(TableNode(row: project.main))
                } else {
                    DisclosureTableRow(TableNode(row: project.main), isExpanded: expansion(of: project.id)) {
                        ForEach(project.worktrees) { TableRow(TableNode(row: $0)) }
                    }
                }
            }
        }
        .contextMenu(forSelectionType: String.self) { ids in
            if ids.count == 1, let id = ids.first, let row = row(id) {
                RowContextMenu(row: row, actions: actions)
            }
        }
    }

    private func row(_ id: String) -> WorktreeRow? {
        for project in projects {
            if project.main.id == id { return project.main }
            if let row = project.worktrees.first(where: { $0.id == id }) { return row }
        }
        return nil
    }

    private func expansion(of id: String) -> Binding<Bool> {
        Binding(
            get: { !collapsed.contains(id) },
            set: { if $0 { collapsed.remove(id) } else { collapsed.insert(id) } })
    }
}

/// One line: the name, and for a repository its branch beside it in a secondary colour. A worktree shows only its name;
/// its branch is in the inspector.
private struct NameCell: View {
    let row: WorktreeRow

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: row.worktree.isMain ? "folder" : "arrow.triangle.branch")
                .foregroundStyle(row.worktree.isMain ? .blue : .secondary)
                .frame(width: 16)
            label
                .lineLimit(1)
                .truncationMode(.tail)
        }
    }

    private var label: Text {
        guard row.worktree.isMain else { return Text(row.displayName) }
        return Text(row.displayName).fontWeight(.semibold)
            + Text("  " + RowPresenter.branchLine(row.status, branch: row.worktree.branch))
            .font(.callout).foregroundStyle(.secondary)
    }
}
