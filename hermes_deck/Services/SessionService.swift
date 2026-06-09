import Foundation

actor LocalHermesSessionProvider: HermesSessionProvider {
    private let sqliteExecutableURL: URL
    private let rootURL: URL

    init(
        sqliteExecutableURL: URL = URL(fileURLWithPath: "/usr/bin/sqlite3"),
        rootURL: URL = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".hermes")
    ) {
        self.sqliteExecutableURL = sqliteExecutableURL
        self.rootURL = rootURL
    }

    private var defaultDatabaseURL: URL {
        rootURL.appendingPathComponent("state.db")
    }

    private func databaseURL(for profile: HermesProfile) -> URL {
        let id = profile.id.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let home = (id == "default" || id.isEmpty)
            ? rootURL
            : rootURL.appendingPathComponent("profiles").appendingPathComponent(id)
        return home.appendingPathComponent("state.db")
    }

    func sessions(page: SessionPageRequest) async throws -> [HermesSessionListItem] {
        try await sessions(page: page, databaseURL: defaultDatabaseURL)
    }

    func sessions(page: SessionPageRequest, profile: HermesProfile) async throws -> [HermesSessionListItem] {
        try await sessions(page: page, databaseURL: databaseURL(for: profile))
    }

    private func sessions(page: SessionPageRequest, databaseURL: URL) async throws -> [HermesSessionListItem] {
        let sqliteExecutableURL = sqliteExecutableURL

        return try await Task.detached(priority: .utility) {
            let process = Process()
            process.executableURL = sqliteExecutableURL
            process.arguments = [
                "-readonly",
                "-separator",
                "\t",
                databaseURL.path(percentEncoded: false),
                Self.query(page: page),
            ]

            let output = Pipe()
            let errorPipe = Pipe()
            process.standardOutput = output
            process.standardError = errorPipe

            try process.runTranslatingMissingCommand(named: "sqlite3")

            let outputDataTask = Task { output.fileHandleForReading.readDataToEndOfFile() }
            let errorDataTask = Task { errorPipe.fileHandleForReading.readDataToEndOfFile() }

            let outputData = await outputDataTask.value
            let errorData = await errorDataTask.value

            process.waitUntilExit()

            guard process.terminationStatus == 0 else {
                let message = String(data: errorData, encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                throw HermesAgentError.rpcError(message?.isEmpty == false ? message! : "Failed to query Hermes sessions database.")
            }

            return HermesSessionDatabaseParser.parse(outputData)
        }.value
    }

    func deleteSession(id: String) async throws {
        try await deleteSession(id: id, databaseURL: defaultDatabaseURL)
    }

    func deleteSession(id: String, profile: HermesProfile) async throws {
        try await deleteSession(id: id, databaseURL: databaseURL(for: profile))
    }

    private func deleteSession(id: String, databaseURL: URL) async throws {
        let sqliteExecutableURL = sqliteExecutableURL
        let escapedID = id.replacingOccurrences(of: "'", with: "''")

        try await Task.detached(priority: .utility) {
            let process = Process()
            process.executableURL = sqliteExecutableURL
            process.arguments = [
                databaseURL.path(percentEncoded: false),
                """
                BEGIN IMMEDIATE;
                DELETE FROM messages WHERE session_id = '\(escapedID)';
                DELETE FROM sessions WHERE id = '\(escapedID)';
                COMMIT;
                """,
            ]

            let errorPipe = Pipe()
            process.standardError = errorPipe

            try process.runTranslatingMissingCommand(named: "sqlite3")

            let errorDataTask = Task { errorPipe.fileHandleForReading.readDataToEndOfFile() }
            let errorData = await errorDataTask.value

            process.waitUntilExit()

            guard process.terminationStatus == 0 else {
                let message = String(data: errorData, encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                throw HermesAgentError.rpcError(message?.isEmpty == false ? message! : "Failed to delete Hermes session.")
            }
        }.value
    }

    func sessionThread(id: String) async throws -> ChatThread {
        try await sessionThread(id: id, databaseURL: defaultDatabaseURL)
    }

    func sessionThread(id: String, profile: HermesProfile) async throws -> ChatThread {
        try await sessionThread(id: id, databaseURL: databaseURL(for: profile))
    }

    private func sessionThread(id: String, databaseURL: URL) async throws -> ChatThread {
        let sqliteExecutableURL = sqliteExecutableURL
        let escapedID = id.replacingOccurrences(of: "'", with: "''")

        return try await Task.detached(priority: .utility) {
            let process = Process()
            process.executableURL = sqliteExecutableURL
            process.arguments = [
                "-readonly",
                "-json",
                databaseURL.path(percentEncoded: false),
                Self.threadQuery(sessionID: escapedID),
            ]

            let output = Pipe()
            let errorPipe = Pipe()
            process.standardOutput = output
            process.standardError = errorPipe

            try process.runTranslatingMissingCommand(named: "sqlite3")

            let outputDataTask = Task { output.fileHandleForReading.readDataToEndOfFile() }
            let errorDataTask = Task { errorPipe.fileHandleForReading.readDataToEndOfFile() }

            let outputData = await outputDataTask.value
            let errorData = await errorDataTask.value

            process.waitUntilExit()

            guard process.terminationStatus == 0 else {
                let message = String(data: errorData, encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                throw HermesAgentError.rpcError(message?.isEmpty == false ? message! : "Failed to load Hermes session.")
            }

            return try HermesSessionThreadParser.parse(outputData, fallbackID: id)
        }.value
    }

    private nonisolated static func query(page: SessionPageRequest) -> String {
        var whereClause = """
        WHERE (TRIM(CASE WHEN title = '—' THEN '' ELSE title END) != ''
           OR TRIM(preview) != '')
        """

        if let query = page.query, !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let escapedQuery = query.replacingOccurrences(of: "'", with: "''")
            whereClause += """
               AND (title LIKE '%\(escapedQuery)%' OR preview LIKE '%\(escapedQuery)%')
            """
        }

        return """
        WITH recent_sessions AS (
            SELECT
                s.id,
                COALESCE(REPLACE(REPLACE(REPLACE(s.title, CHAR(9), ' '), CHAR(10), ' '), CHAR(13), ' '), '') AS title,
                COALESCE(s.source, '') AS source,
                COALESCE(s.message_count, 0) AS message_count,
                COALESCE((
                    SELECT REPLACE(REPLACE(REPLACE(m.content, CHAR(9), ' '), CHAR(10), ' '), CHAR(13), ' ')
                    FROM messages m
                    WHERE m.session_id = s.id
                      AND m.active = 1
                      AND m.content IS NOT NULL
                      AND TRIM(m.content) != ''
                    ORDER BY m.timestamp ASC
                    LIMIT 1
                ), '') AS preview,
                COALESCE((
                    SELECT MAX(m.timestamp)
                    FROM messages m
                    WHERE m.session_id = s.id
                      AND m.active = 1
                ), s.ended_at, s.started_at) AS last_activity
            FROM sessions s
            WHERE COALESCE(s.archived, 0) = 0
        )
        SELECT id, title, source, message_count, preview, last_activity
        FROM recent_sessions
        \(whereClause)
        ORDER BY last_activity DESC
        LIMIT \(page.limit) OFFSET \(page.offset);
        """
    }

    private nonisolated static func threadQuery(sessionID: String) -> String {
        """
        SELECT
            s.id AS session_id,
            COALESCE(NULLIF(s.title, '—'), '') AS title,
            s.started_at AS started_at,
            COALESCE(s.ended_at, s.started_at) AS updated_at,
            m.role AS role,
            COALESCE(m.content, '') AS content,
            COALESCE(NULLIF(m.reasoning_content, ''), m.reasoning, '') AS reasoning,
            COALESCE(m.tool_calls, '') AS tool_calls,
            COALESCE(m.tool_call_id, '') AS tool_call_id,
            COALESCE(m.tool_name, '') AS tool_name,
            m.timestamp AS timestamp
        FROM sessions s
        LEFT JOIN messages m
          ON m.session_id = s.id
         AND m.active = 1
        WHERE s.id = '\(sessionID)'
        ORDER BY m.timestamp ASC;
        """
    }
}

enum HermesSessionThreadParser {
    static func parse(_ data: Data, fallbackID: String) throws -> ChatThread {
        let rows = try JSONDecoder().decode([Row].self, from: data)
        guard let first = rows.first else {
            throw HermesAgentError.missingSession
        }

        var messages: [ChatMessage] = []
        var activeAssistantIndex: Int?

        for row in rows {
            let timestamp = row.timestamp ?? first.startedAt
            switch row.normalizedRole {
            case "user":
                messages.append(row.chatMessage(role: .user, timestamp: timestamp))
                activeAssistantIndex = nil
            case "system":
                messages.append(row.chatMessage(role: .system, timestamp: timestamp))
                activeAssistantIndex = nil
            case "assistant":
                mergeOrAppendAssistant(row: row, timestamp: timestamp, messages: &messages, activeAssistantIndex: &activeAssistantIndex)
            case "tool":
                let tool = row.toolEvent()
                if updateMatchingToolResult(tool, messages: &messages) {
                    continue
                }

                let assistantIndex = activeAssistantIndex ?? appendAssistantPlaceholder(
                    timestamp: timestamp,
                    messages: &messages,
                    activeAssistantIndex: &activeAssistantIndex
                )
                messages[assistantIndex].segments.append(.tool(tool))
            default:
                continue
            }
        }

        messages.removeAll { message in
            message.role == .assistant
                && message.content.isEmpty
                && message.segments.isEmpty
                && message.reasoningText.isEmpty
                && message.attachments.isEmpty
        }

        return ChatThread(
            title: first.title?.isEmpty == false ? first.title! : fallbackID,
            createdAt: Date(timeIntervalSince1970: first.startedAt),
            updatedAt: Date(timeIntervalSince1970: first.updatedAt ?? first.startedAt),
            messages: messages,
            hermesSessionID: first.sessionID.isEmpty ? fallbackID : first.sessionID
        )
    }

    private static func mergeOrAppendAssistant(
        row: Row,
        timestamp: TimeInterval,
        messages: inout [ChatMessage],
        activeAssistantIndex: inout Int?
    ) {
        let message = row.chatMessage(role: .assistant, timestamp: timestamp)
        guard let index = activeAssistantIndex,
              messages.indices.contains(index),
              messages[index].role == .assistant,
              messages[index].content.isEmpty else {
            messages.append(message)
            activeAssistantIndex = messages.count - 1
            return
        }

        if !message.content.isEmpty {
            messages[index].content = message.content
            messages[index].completedAt = message.completedAt
        }

        if !message.reasoningText.isEmpty {
            messages[index].reasoningText = message.reasoningText
            messages[index].segments.append(contentsOf: message.segments)
        }

        if !message.toolEvents.isEmpty {
            for tool in message.toolEvents {
                upsertToolCallDeclaration(tool, in: &messages[index])
            }
        }
    }

    private static func upsertToolCallDeclaration(_ tool: ToolCallEvent, in message: inout ChatMessage) {
        guard let toolID = tool.toolID else {
            message.segments.append(.tool(tool))
            return
        }

        if message.segments.contains(where: { segment in
            if case .tool(let existing) = segment {
                existing.toolID == toolID
            } else {
                false
            }
        }) {
            return
        }

        message.segments.append(.tool(tool))
    }

    private static func updateMatchingToolResult(_ tool: ToolCallEvent, messages: inout [ChatMessage]) -> Bool {
        guard let toolID = tool.toolID else { return false }

        for messageIndex in messages.indices.reversed() {
            guard messages[messageIndex].role == .assistant else { continue }
            for segmentIndex in messages[messageIndex].segments.indices {
                guard case .tool(var existing) = messages[messageIndex].segments[segmentIndex],
                      existing.toolID == toolID else { continue }
                existing.merge(with: tool)
                messages[messageIndex].segments[segmentIndex] = .tool(existing)
                return true
            }
        }

        return false
    }

    @discardableResult
    private static func appendAssistantPlaceholder(
        timestamp: TimeInterval,
        messages: inout [ChatMessage],
        activeAssistantIndex: inout Int?
    ) -> Int {
        let message = ChatMessage(
            role: .assistant,
            content: "",
            createdAt: Date(timeIntervalSince1970: timestamp),
            isHistorical: true
        )
        messages.append(message)
        activeAssistantIndex = messages.count - 1
        return messages.count - 1
    }

    private struct Row: Decodable {
        var sessionID: String
        var title: String?
        var startedAt: TimeInterval
        var updatedAt: TimeInterval?
        var role: String?
        var content: String?
        var reasoning: String?
        var toolCalls: String?
        var toolCallID: String?
        var toolName: String?
        var timestamp: TimeInterval?

        var normalizedRole: String {
            role?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        }

        func chatMessage(role: MessageRole, timestamp: TimeInterval) -> ChatMessage {
            let reasoning = reasoning ?? ""
            var segments: [AssistantSegment] = reasoning.isEmpty ? [] : [.thinking(ThinkingSegment(text: reasoning))]
            if role == .assistant {
                segments.append(contentsOf: toolCallEvents().map(AssistantSegment.tool))
            }
            return ChatMessage(
                role: role,
                content: content ?? "",
                createdAt: Date(timeIntervalSince1970: timestamp),
                completedAt: role == .assistant ? Date(timeIntervalSince1970: timestamp) : nil,
                segments: segments,
                reasoningText: reasoning,
                isHistorical: true
            )
        }

        func toolEvent() -> ToolCallEvent {
            ToolCallEvent(
                toolID: toolCallID?.sessionTextValue,
                name: toolName?.sessionTextValue ?? "tool",
                state: .complete,
                summary: content?.sessionTextValue
            )
        }

        func toolCallEvents() -> [ToolCallEvent] {
            guard let data = toolCalls?.sessionTextValue?.data(using: .utf8),
                  let calls = try? JSONDecoder().decode([ToolCall].self, from: data) else {
                return []
            }

            return calls.map { call in
                ToolCallEvent(
                    toolID: call.callID ?? call.id,
                    name: call.function?.name ?? call.name ?? "tool",
                    state: .running,
                    context: call.function?.arguments ?? call.arguments
                )
            }
        }

        enum CodingKeys: String, CodingKey {
            case sessionID = "session_id"
            case title
            case startedAt = "started_at"
            case updatedAt = "updated_at"
            case role
            case content
            case reasoning
            case toolCalls = "tool_calls"
            case toolCallID = "tool_call_id"
            case toolName = "tool_name"
            case timestamp
        }

        private struct ToolCall: Decodable {
            var id: String?
            var callID: String?
            var name: String?
            var arguments: String?
            var function: FunctionCall?

            enum CodingKeys: String, CodingKey {
                case id
                case callID = "call_id"
                case name
                case arguments
                case function
            }
        }

        private struct FunctionCall: Decodable {
            var name: String?
            var arguments: String?
        }
    }
}

enum HermesSessionDatabaseParser {
    static func parse(_ data: Data) -> [HermesSessionListItem] {
        let text = String(data: data, encoding: .utf8) ?? ""
        return text
            .components(separatedBy: .newlines)
            .compactMap(parseLine)
    }

    private static func parseLine(_ line: String) -> HermesSessionListItem? {
        guard !line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        let columns = line.components(separatedBy: "\t")
        guard columns.count >= 6 else { return nil }

        let id = columns[0].sessionTextValue ?? ""
        let parsedTitle = columns[1].sessionTextValue
        let source = columns[2].sessionTextValue ?? ""
        let messageCount = Int(columns[3].trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
        let preview = columns[4].sessionTextValue ?? ""
        guard !id.isEmpty, parsedTitle != nil || !preview.isEmpty else { return nil }

        let lastActiveDate = lastActiveDate(for: columns[5])

        return HermesSessionListItem(
            id: id,
            title: parsedTitle ?? preview,
            preview: preview,
            source: source,
            messageCount: messageCount,
            lastActive: lastActiveDate.map { HistoryTimestampFormatter.displayText(for: $0) } ?? "",
            lastActiveDate: lastActiveDate
        )
    }

    private static func lastActiveDate(for value: String) -> Date? {
        guard let seconds = TimeInterval(value.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            return nil
        }
        return Date(timeIntervalSince1970: seconds)
    }
}

enum HermesSessionListParser {
    static func parse(_ data: Data) -> [HermesSessionListItem] {
        let text = String(data: data, encoding: .utf8) ?? ""
        let lines = text
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }

        guard let headerIndex = lines.firstIndex(where: { line in
            line.contains("Title") && line.contains("Preview") && line.contains("Last Active") && line.contains("ID")
        }) else {
            return []
        }

        return lines.dropFirst(headerIndex + 1).compactMap(parseLine)
    }

    private static func parseLine(_ line: String) -> HermesSessionListItem? {
        guard !line.isEmpty, !line.allSatisfy({ $0 == "─" }) else { return nil }

        let words = line.split(whereSeparator: \.isWhitespace)
        guard let id = words.last.map(String.init), !id.isEmpty else { return nil }

        let withoutID = line.dropLast(id.count).trimmingCharacters(in: .whitespacesAndNewlines)
        let (content, lastActive) = splitLastActive(from: withoutID)
        let columns = splitColumns(content)
        let parsedTitle = columns.first?.sessionTextValue
        let parsedPreview = columns.dropFirst().joined(separator: " ").sessionTextValue
        let preview = parsedPreview ?? placeholderPreviewFallback(from: content) ?? ""
        guard parsedTitle != nil || !preview.isEmpty else { return nil }
        let title = parsedTitle ?? preview

        return HermesSessionListItem(id: id, title: title, preview: preview, lastActive: lastActive)
    }

    private static func placeholderPreviewFallback(from content: String) -> String? {
        let words = content.split(whereSeparator: \.isWhitespace).map(String.init)
        guard words.first == "—", words.count > 1 else { return nil }
        return words.dropFirst().joined(separator: " ").sessionTextValue
    }

    private static func splitLastActive(from text: String) -> (content: String, lastActive: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let words = trimmed.split(whereSeparator: \.isWhitespace).map(String.init)
        guard let last = words.last else { return (text, "") }

        let lastActiveWordCount = last == "ago" && words.count >= 2 ? 2 : 1
        let lastActive = words.suffix(lastActiveWordCount).joined(separator: " ")
        guard trimmed.hasSuffix(lastActive) else {
            return (trimmed, lastActive)
        }
        let content = trimmed.dropLast(lastActive.count).trimmingCharacters(in: .whitespacesAndNewlines)
        return (content, lastActive)
    }

    private static func splitColumns(_ text: String) -> [String] {
        var columns: [String] = []
        var current = ""
        var spaceRun = 0

        for character in text {
            if character == " " {
                spaceRun += 1
                continue
            }

            if spaceRun >= 2 {
                columns.append(current.trimmingCharacters(in: .whitespacesAndNewlines))
                current = ""
            } else if spaceRun == 1 {
                current.append(" ")
            }

            spaceRun = 0
            current.append(character)
        }

        if !current.isEmpty || !columns.isEmpty {
            columns.append(current.trimmingCharacters(in: .whitespacesAndNewlines))
        }

        return columns.filter { !$0.isEmpty }
    }
}
