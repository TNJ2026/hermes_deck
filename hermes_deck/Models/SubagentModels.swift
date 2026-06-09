import Foundation

enum SubagentStatus: String, Codable, Sendable {
    case queued
    case running
    case completed
    case failed
    case error
    case timeout
    case interrupted

    init(_ rawValue: String?) {
        switch rawValue?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "queued":
            self = .queued
        case "running":
            self = .running
        case "failed":
            self = .failed
        case "error":
            self = .error
        case "timeout":
            self = .timeout
        case "interrupted":
            self = .interrupted
        case "completed", "complete":
            self = .completed
        default:
            self = .completed
        }
    }
}

struct SubagentOutputTailItem: Identifiable, Hashable, Codable, Sendable {
    let id: UUID
    var tool: String
    var preview: String
    var isError: Bool

    init(id: UUID = UUID(), tool: String, preview: String, isError: Bool = false) {
        self.id = id
        self.tool = tool
        self.preview = preview
        self.isError = isError
    }
}

struct SubagentProgress: Identifiable, Hashable, Codable, Sendable {
    var id: String
    var parentID: String?
    var taskIndex: Int
    var taskCount: Int
    var depth: Int
    var goal: String
    var status: SubagentStatus
    var model: String?
    var toolCount: Int
    var thinking: [String]
    var tools: [String]
    var notes: [String]
    var summary: String?
    var durationSeconds: Double?
    var inputTokens: Int?
    var outputTokens: Int?
    var reasoningTokens: Int?
    var apiCalls: Int?
    var costUSD: Double?
    var filesRead: [String]
    var filesWritten: [String]
    var outputTail: [SubagentOutputTailItem]
    var startedAt: Date

    init(
        id: String,
        parentID: String? = nil,
        taskIndex: Int,
        taskCount: Int = 1,
        depth: Int = 0,
        goal: String,
        status: SubagentStatus,
        model: String? = nil,
        toolCount: Int = 0,
        thinking: [String] = [],
        tools: [String] = [],
        notes: [String] = [],
        summary: String? = nil,
        durationSeconds: Double? = nil,
        inputTokens: Int? = nil,
        outputTokens: Int? = nil,
        reasoningTokens: Int? = nil,
        apiCalls: Int? = nil,
        costUSD: Double? = nil,
        filesRead: [String] = [],
        filesWritten: [String] = [],
        outputTail: [SubagentOutputTailItem] = [],
        startedAt: Date = .now
    ) {
        self.id = id
        self.parentID = parentID
        self.taskIndex = taskIndex
        self.taskCount = taskCount
        self.depth = depth
        self.goal = goal
        self.status = status
        self.model = model
        self.toolCount = toolCount
        self.thinking = thinking
        self.tools = tools
        self.notes = notes
        self.summary = summary
        self.durationSeconds = durationSeconds
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.reasoningTokens = reasoningTokens
        self.apiCalls = apiCalls
        self.costUSD = costUSD
        self.filesRead = filesRead
        self.filesWritten = filesWritten
        self.outputTail = outputTail
        self.startedAt = startedAt
    }
}

struct SubagentProgressEvent: Equatable, Sendable {
    var id: String
    var parentID: String?
    var taskIndex: Int
    var taskCount: Int
    var depth: Int
    var goal: String
    var status: SubagentStatus?
    var model: String?
    var toolName: String?
    var text: String?
    var summary: String?
    var durationSeconds: Double?
    var toolCount: Int?
    var inputTokens: Int?
    var outputTokens: Int?
    var reasoningTokens: Int?
    var apiCalls: Int?
    var costUSD: Double?
    var filesRead: [String]
    var filesWritten: [String]
    var outputTail: [SubagentOutputTailItem]
}
