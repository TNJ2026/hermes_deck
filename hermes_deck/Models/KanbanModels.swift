import Foundation
import SwiftUI

/// The nine board states a Hermes kanban task can occupy, in column order.
/// Mirrors `VALID_STATUSES` in hermes_cli/kanban_db.py.
enum KanbanStatus: String, CaseIterable, Identifiable, Sendable {
    case triage
    case todo
    case scheduled
    case ready
    case running
    case blocked
    case review
    case done
    case archived

    var id: String { rawValue }

    var title: String {
        switch self {
        case .triage: "Triage"
        case .todo: "To Do"
        case .scheduled: "Scheduled"
        case .ready: "Ready"
        case .running: "Running"
        case .blocked: "Blocked"
        case .review: "Review"
        case .done: "Done"
        case .archived: "Archived"
        }
    }

    var tint: Color {
        switch self {
        case .triage: .gray
        case .todo: .secondary
        case .scheduled: .teal
        case .ready: .blue
        case .running: .purple
        case .blocked: .red
        case .review: .orange
        case .done: .green
        case .archived: .secondary
        }
    }
}

struct KanbanTask: Identifiable, Hashable, Sendable {
    var id: String
    var title: String
    var body: String?
    var assignee: String?
    var status: String
    var priority: Int
    var createdBy: String?
    var createdAt: Date?
    var startedAt: Date?
    var completedAt: Date?
    var sessionID: String?

    /// The recognised board column, or `nil` for an unknown status string.
    var kanbanStatus: KanbanStatus? {
        KanbanStatus(rawValue: status.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
    }
}

struct KanbanColumn: Identifiable, Sendable {
    var status: KanbanStatus
    var tasks: [KanbanTask]

    var id: String { status.id }
}

enum KanbanGrouper {
    /// Groups tasks into one column per status in canonical order. Every status
    /// is returned even when empty so the board shows all section headers.
    /// Tasks with an unrecognised status land in `.triage` so nothing is
    /// silently dropped.
    static func columns(for tasks: [KanbanTask]) -> [KanbanColumn] {
        var byStatus: [KanbanStatus: [KanbanTask]] = [:]
        for task in tasks {
            byStatus[task.kanbanStatus ?? .triage, default: []].append(task)
        }
        return KanbanStatus.allCases.map { status in
            KanbanColumn(status: status, tasks: byStatus[status] ?? [])
        }
    }
}

enum HermesKanbanListState: Equatable, Sendable {
    case idle
    case loading
    case loaded([KanbanTask])
    case failed(String)

    var tasks: [KanbanTask] {
        if case .loaded(let tasks) = self { return tasks }
        return []
    }
}
