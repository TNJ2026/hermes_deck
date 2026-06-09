import Foundation

protocol HermesKanbanProvider: Sendable {
    func tasks() async throws -> [KanbanTask]
}

actor LocalHermesKanbanProvider: HermesKanbanProvider {
    private let sqliteExecutableURL: URL
    private let databaseURL: URL

    init(
        sqliteExecutableURL: URL = URL(fileURLWithPath: "/usr/bin/sqlite3"),
        databaseURL: URL = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".hermes/kanban.db")
    ) {
        self.sqliteExecutableURL = sqliteExecutableURL
        self.databaseURL = databaseURL
    }

    func tasks() async throws -> [KanbanTask] {
        let sqliteExecutableURL = sqliteExecutableURL
        let databaseURL = databaseURL

        return try await Task.detached(priority: .utility) {
            guard FileManager.default.fileExists(atPath: databaseURL.path(percentEncoded: false)) else {
                return []
            }

            let process = Process()
            process.executableURL = sqliteExecutableURL
            // Open the database immutable: a lock-free read-only snapshot that
            // succeeds even while a kanban worker holds the WAL. Plain
            // `-readonly` fails with "unable to open database file" in that case.
            process.arguments = [
                "-json",
                "file:\(databaseURL.path(percentEncoded: false))?immutable=1",
                Self.query,
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
                throw HermesAgentError.rpcError(message?.isEmpty == false ? message! : "Failed to query Hermes kanban database.")
            }

            return HermesKanbanTaskParser.parse(outputData)
        }.value
    }

    private static let query = """
    SELECT id, title, body, assignee, status,
           COALESCE(priority, 0) AS priority,
           created_by, created_at, started_at, completed_at, session_id
    FROM tasks
    ORDER BY priority DESC, created_at DESC;
    """
}

enum HermesKanbanTaskParser {
    static func parse(_ data: Data) -> [KanbanTask] {
        guard let rows = try? JSONDecoder().decode([Row].self, from: data) else { return [] }
        return rows.map { row in
            KanbanTask(
                id: row.id,
                title: row.title,
                body: row.body.nilIfBlank,
                assignee: row.assignee.nilIfBlank,
                status: row.status,
                priority: row.priority ?? 0,
                createdBy: row.createdBy.nilIfBlank,
                createdAt: row.createdAt.map { Date(timeIntervalSince1970: $0) },
                startedAt: row.startedAt.map { Date(timeIntervalSince1970: $0) },
                completedAt: row.completedAt.map { Date(timeIntervalSince1970: $0) },
                sessionID: row.sessionID.nilIfBlank
            )
        }
    }

    private struct Row: Decodable {
        var id: String
        var title: String
        var body: String?
        var assignee: String?
        var status: String
        var priority: Int?
        var createdBy: String?
        var createdAt: Double?
        var startedAt: Double?
        var completedAt: Double?
        var sessionID: String?

        enum CodingKeys: String, CodingKey {
            case id, title, body, assignee, status, priority
            case createdBy = "created_by"
            case createdAt = "created_at"
            case startedAt = "started_at"
            case completedAt = "completed_at"
            case sessionID = "session_id"
        }
    }
}

private extension Optional where Wrapped == String {
    var nilIfBlank: String? {
        guard let self, !self.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return self
    }
}
