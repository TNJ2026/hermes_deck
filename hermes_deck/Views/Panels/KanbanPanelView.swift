import SwiftUI

struct KanbanPanelView: View {
    @Bindable var store: ChatStore

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "rectangle.grid.2x2")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.secondary)
                Text("Kanban")
                    .font(.headline)

                Spacer(minLength: 8)

                if case .loaded(let tasks) = store.kanbanListState, !tasks.isEmpty {
                    Text("\(tasks.count) tasks")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }

                Button {
                    Task { await store.loadKanbanTasks() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Refresh")
            }

            Divider()

            content
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .task { await store.loadKanbanTasks() }
    }

    @ViewBuilder
    private var content: some View {
        switch store.kanbanListState {
        case .idle, .loading:
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .failed(let message):
            ContentUnavailableView {
                Label("Kanban unavailable", systemImage: "exclamationmark.triangle")
            } description: {
                Text(message)
            }
        case .loaded(let tasks):
            if tasks.isEmpty {
                EmptyPanelState(title: "No kanban tasks", systemImage: "rectangle.grid.2x2")
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 16) {
                        ForEach(KanbanGrouper.columns(for: tasks)) { column in
                            KanbanColumnView(column: column)
                        }
                    }
                    .padding(.vertical, 2)
                }
            }
        }
    }
}

struct KanbanColumnView: View {
    let column: KanbanColumn
    @State private var isExpanded = true

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                withAnimation(.smooth(duration: 0.18)) { isExpanded.toggle() }
            } label: {
                HStack(spacing: 6) {
                    Text(isExpanded ? "▾" : "▸")
                        .font(.system(size: 13, weight: .semibold, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .frame(width: 12, alignment: .leading)
                    Circle()
                        .fill(column.status.tint)
                        .frame(width: 7, height: 7)
                    Text(column.status.title)
                        .font(.subheadline.weight(.semibold))
                    Text("\(column.tasks.count)")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if isExpanded {
                if column.tasks.isEmpty {
                    Text("—")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                } else {
                    ForEach(column.tasks) { task in
                        KanbanTaskCard(task: task)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }
}

struct KanbanTaskCard: View {
    let task: KanbanTask

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(task.title)
                .font(.callout.weight(.medium))
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 6) {
                if let assignee = task.assignee {
                    Label(assignee, systemImage: "person")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                if task.priority > 0 {
                    Text("P\(task.priority)")
                        .font(.caption2.weight(.semibold).monospacedDigit())
                        .foregroundStyle(.orange)
                }
            }

            if let date = task.completedAt ?? task.startedAt ?? task.createdAt {
                Text(HistoryTimestampFormatter.displayText(for: date))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .stroke(.quaternary)
        }
    }
}
