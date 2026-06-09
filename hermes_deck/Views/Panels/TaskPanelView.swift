import SwiftUI

struct TaskPanelView: View {
    @Bindable var store: ChatStore

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "checklist")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.secondary)
                Text("Task")
                    .font(.headline)
                Spacer()
                if !store.taskSubagents.isEmpty {
                    Text(taskSummary)
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }

            Divider()

            if store.taskSubagents.isEmpty {
                EmptyPanelState(title: "No sub-agent activity", systemImage: "point.3.connected.trianglepath.dotted")
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        ForEach(rootSubagents) { subagent in
                            SubagentProgressCard(
                                subagent: subagent,
                                children: children(of: subagent),
                                allSubagents: store.taskSubagents
                            )
                        }
                    }
                    .padding(.vertical, 2)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var rootSubagents: [SubagentProgress] {
        store.taskSubagents.filter { subagent in
            guard let parentID = subagent.parentID else { return true }
            return !store.taskSubagents.contains { $0.id == parentID }
        }
    }

    private var taskSummary: String {
        let running = store.taskSubagents.filter { $0.status == .running || $0.status == .queued }.count
        let done = store.taskSubagents.count - running
        return "\(running) running · \(done) done"
    }

    private func children(of subagent: SubagentProgress) -> [SubagentProgress] {
        store.taskSubagents.filter { $0.parentID == subagent.id }
    }
}

struct SubagentProgressCard: View {
    let subagent: SubagentProgress
    let children: [SubagentProgress]
    let allSubagents: [SubagentProgress]
    @State private var isExpanded = true

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                withAnimation(.smooth(duration: 0.16)) { isExpanded.toggle() }
            } label: {
                HStack(alignment: .firstTextBaseline, spacing: 7) {
                    Circle()
                        .fill(statusColor)
                        .frame(width: 7, height: 7)
                    Text(isExpanded ? "▾" : "▸")
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .frame(width: 10, alignment: .leading)
                    Text(title)
                        .font(.callout.weight(.semibold))
                        .lineLimit(2)
                    Spacer(minLength: 6)
                    Text(metaText)
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if isExpanded {
                VStack(alignment: .leading, spacing: 8) {
                    if let model = subagent.model, !model.isEmpty {
                        TaskMetaRow(title: "Model", value: model)
                    }
                    if !subagent.thinking.isEmpty {
                        TaskTextSection(title: "Thinking", rows: subagent.thinking, color: .purple)
                    }
                    if !subagent.tools.isEmpty {
                        TaskTextSection(title: "Tool calls", rows: subagent.tools, color: .accentColor)
                    }
                    if !subagent.notes.isEmpty {
                        TaskTextSection(title: "Progress", rows: subagent.notes, color: .secondary)
                    }
                    if let summary = subagent.summary, !summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        TaskTextSection(title: "Result", rows: [summary], color: resultColor)
                    }
                    if !subagent.outputTail.isEmpty {
                        TaskOutputTailSection(items: subagent.outputTail)
                    }
                    if !subagent.filesRead.isEmpty || !subagent.filesWritten.isEmpty {
                        TaskFilesSection(read: subagent.filesRead, written: subagent.filesWritten)
                    }
                    ForEach(children) { child in
                        SubagentProgressCard(
                            subagent: child,
                            children: allSubagents.filter { $0.parentID == child.id },
                            allSubagents: allSubagents
                        )
                        .padding(.leading, 14)
                    }
                }
                .padding(.leading, 17)
            }
        }
        .padding(10)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .stroke(.quaternary)
        }
    }

    private var title: String {
        let prefix = subagent.taskCount > 1 ? "[\(subagent.taskIndex + 1)/\(subagent.taskCount)] " : ""
        return prefix + subagent.goal
    }

    private var metaText: String {
        var parts = [subagent.status.rawValue]
        if let duration = subagent.durationSeconds {
            parts.append(abbreviatedDuration(duration))
        }
        if subagent.toolCount > 0 {
            parts.append("\(subagent.toolCount)t")
        }
        let tokens = (subagent.inputTokens ?? 0) + (subagent.outputTokens ?? 0)
        if tokens > 0 {
            parts.append("\(tokens / 1000)K tok")
        }
        return parts.joined(separator: " · ")
    }

    private var statusColor: Color {
        switch subagent.status {
        case .queued:
            .secondary
        case .running:
            .purple
        case .completed:
            .green
        case .failed, .error:
            .red
        case .timeout, .interrupted:
            .orange
        }
    }

    private var resultColor: Color {
        switch subagent.status {
        case .failed, .error:
            .red
        case .timeout, .interrupted:
            .orange
        default:
            .green
        }
    }
}

struct TaskTextSection: View {
    let title: String
    let rows: [String]
    let color: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label(title, systemImage: "circle.fill")
                .font(.caption.weight(.semibold))
                .foregroundStyle(color)
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                Text(row)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

struct TaskMetaRow: View {
    let title: String
    let value: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }
}

struct TaskOutputTailSection: View {
    let items: [SubagentOutputTailItem]

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label("Generated output", systemImage: "text.alignleft")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            ForEach(items) { item in
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.tool)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(item.isError ? .red : .secondary)
                    Text(item.preview)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}

struct TaskFilesSection: View {
    let read: [String]
    let written: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label("Files", systemImage: "doc.text")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            ForEach(written.prefix(6), id: \.self) { path in
                Text("wrote \(path)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            ForEach(read.prefix(6), id: \.self) { path in
                Text("read \(path)")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
    }
}
