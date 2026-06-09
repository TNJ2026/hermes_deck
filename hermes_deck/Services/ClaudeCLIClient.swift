import Foundation

/// Drives the local `claude` CLI in headless stream-json mode and adapts its
/// events to the app's agent boundary. The model is pinned with
/// `--model claude-opus-4-8`; tool permissions are auto-approved
/// (`--dangerously-skip-permissions`). One process per turn; follow-up turns
/// resume the same session id (derived from the conversation id).
actor ClaudeCLIClient: HermesAgentClient {
    private let model: String
    private var seenConversations: Set<UUID> = []

    init(model: String = "claude-opus-4-8") {
        self.model = model
    }

    func send(_ request: HermesChatRequest) async throws -> HermesChatResponse {
        var final = ""
        for try await event in eventStream(for: request) {
            if case .messageDelta(_, let text) = event { final += text }
        }
        return HermesChatResponse(content: final)
    }

    nonisolated func eventStream(for request: HermesChatRequest) -> AsyncThrowingStream<HermesAgentEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                let conversationID = request.conversationID
                let sessionID = conversationID.uuidString.lowercased()
                let text = request.promptText
                do {
                    let resume = await isConversationSeen(conversationID)
                    do {
                        try await Self.run(
                            arguments: Self.arguments(text: text, model: model, sessionID: sessionID, resume: resume),
                            workingDirectory: request.workingDirectory,
                            sessionID: sessionID,
                            continuation: continuation
                        )
                    } catch let error where resume && Self.isMissingSessionError(error) {
                        // A stale `--resume` id (e.g. a failed first turn never
                        // created the session). Recreate it once with --session-id.
                        try await Self.run(
                            arguments: Self.arguments(text: text, model: model, sessionID: sessionID, resume: false),
                            workingDirectory: request.workingDirectory,
                            sessionID: sessionID,
                            continuation: continuation
                        )
                    }
                    // Mark seen only after a successful run so a failed turn does
                    // not poison the conversation into permanent resume failures.
                    await markConversationSeen(conversationID)
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func isConversationSeen(_ id: UUID) -> Bool {
        seenConversations.contains(id)
    }

    private func markConversationSeen(_ id: UUID) {
        seenConversations.insert(id)
    }

    /// True for the `claude --resume` "No conversation found with session ID"
    /// failure, which means the session id is stale and should be recreated.
    private static func isMissingSessionError(_ error: Error) -> Bool {
        if let hermes = error as? HermesAgentError, case .rpcError(let message) = hermes {
            return message.localizedCaseInsensitiveContains("no conversation found")
        }
        return false
    }

    private static func arguments(text: String, model: String, sessionID: String, resume: Bool) -> [String] {
        var arguments = [
            "claude", "-p", text,
            "--output-format", "stream-json", "--verbose",
            "--model", model,
            "--dangerously-skip-permissions",
        ]
        arguments += resume ? ["--resume", sessionID] : ["--session-id", sessionID]
        return arguments
    }

    private static func run(
        arguments: [String],
        workingDirectory: URL,
        sessionID: String,
        continuation: AsyncThrowingStream<HermesAgentEvent, Error>.Continuation
    ) async throws {
        let processBox = AgentChildProcessBox()
        try await withTaskCancellationHandler {
            let process = Process()
            processBox.set(process)
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = arguments
            process.currentDirectoryURL = workingDirectory
            process.environment = AgentLaunchEnvironment.make()

            let output = Pipe()
            let errorPipe = Pipe()
            process.standardOutput = output
            process.standardError = errorPipe

            let errorTask = Task {
                errorPipe.fileHandleForReading.readDataToEndOfFile()
            }

            do {
                try process.run()

                var inBandError: String?
                for try await line in output.fileHandleForReading.bytes.lines {
                    try Task.checkCancellation()
                    for event in ClaudeStreamParser.parse(line, sessionID: sessionID) {
                        continuation.yield(event)
                    }
                    // An API failure (usage limit, overload) arrives as a `result`
                    // event with `is_error: true` while the CLI still exits 0; the
                    // detail would otherwise be dropped as a silent empty turn.
                    if let message = ClaudeStreamParser.errorResultMessage(line) {
                        inBandError = message
                    }
                }

                process.waitUntilExit()
                let errorData = await errorTask.value
                if process.terminationStatus != 0 {
                    let message = String(data: errorData, encoding: .utf8)?
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    throw HermesAgentError.rpcError(message?.isEmpty == false ? message! : "claude exited with status \(process.terminationStatus).")
                }
                if let inBandError {
                    throw HermesAgentError.rpcError(inBandError)
                }
            } catch {
                processBox.killTree()
                _ = await errorTask.value
                throw error
            }
        } onCancel: {
            processBox.killTree()
        }
    }
}

/// Pure mapping from Claude Code stream-json lines to `HermesAgentEvent`.
enum ClaudeStreamParser {
    static func parse(_ line: String, sessionID: String) -> [HermesAgentEvent] {
        guard let data = line.data(using: .utf8),
              let object = (try? JSONDecoder().decode(TUIJSONValue.self, from: data))?.objectValue else { return [] }

        switch object["type"]?.stringValue {
        case "assistant":
            return assistantBlocks(object["message"]?["content"]?.arrayValue, sessionID: sessionID)
        case "user":
            return toolResults(object["message"]?["content"]?.arrayValue, sessionID: sessionID)
        case "result":
            // Error results are surfaced as a thrown failure by the run loop
            // (see `errorResultMessage`), not rendered as a completed turn.
            if case .bool(true)? = object["is_error"] { return [] }
            let stop = object["stop_reason"]?.stringValue ?? "end_turn"
            return [.messageComplete(sessionID: sessionID, text: "", status: stop == "end_turn" ? "complete" : stop, usage: nil)]
        default:
            return []
        }
    }

    /// The error text from a `result` event with `is_error: true`, if any. The
    /// `claude` CLI reports API failures (usage limit, overload) this way while
    /// still exiting 0, so the caller turns this into a thrown error rather than
    /// a silent empty turn.
    static func errorResultMessage(_ line: String) -> String? {
        guard let data = line.data(using: .utf8),
              let object = (try? JSONDecoder().decode(TUIJSONValue.self, from: data))?.objectValue,
              object["type"]?.stringValue == "result",
              case .bool(true)? = object["is_error"] else { return nil }
        if let text = object["result"]?.stringValue, !text.isEmpty { return text }
        if let status = object["api_error_status"]?.stringValue, !status.isEmpty {
            return "claude API error: \(status)"
        }
        if let subtype = object["subtype"]?.stringValue, !subtype.isEmpty {
            return "claude error: \(subtype)"
        }
        return "claude reported an error."
    }

    private static func assistantBlocks(_ content: [TUIJSONValue]?, sessionID: String) -> [HermesAgentEvent] {
        guard let content else { return [] }
        var events: [HermesAgentEvent] = []
        for block in content {
            switch block["type"]?.stringValue {
            case "text":
                if let text = block["text"]?.stringValue, !text.isEmpty {
                    events.append(.messageDelta(sessionID: sessionID, text: text))
                }
            case "thinking":
                if let text = block["thinking"]?.stringValue, !text.isEmpty {
                    events.append(.thinkingDelta(sessionID: sessionID, text: text))
                }
            case "tool_use":
                events.append(.toolStart(sessionID: sessionID, tool: ToolCallEvent(
                    toolID: block["id"]?.stringValue,
                    name: block["name"]?.stringValue ?? "tool",
                    state: .running,
                    context: toolContext(block["input"])
                )))
            default:
                break
            }
        }
        return events
    }

    private static func toolResults(_ content: [TUIJSONValue]?, sessionID: String) -> [HermesAgentEvent] {
        guard let content else { return [] }
        return content.compactMap { block in
            guard block["type"]?.stringValue == "tool_result" else { return nil }
            return .toolComplete(sessionID: sessionID, tool: ToolCallEvent(
                toolID: block["tool_use_id"]?.stringValue,
                name: "tool",  // result carries no name; merge keeps the tool_use name
                state: .complete,
                summary: toolResultText(block["content"])
            ))
        }
    }

    private static func toolContext(_ input: TUIJSONValue?) -> String? {
        guard let object = input?.objectValue else { return nil }
        for key in ["command", "file_path", "path", "pattern", "query", "url", "description"] {
            if let value = object[key]?.stringValue, !value.isEmpty { return value }
        }
        return nil
    }

    private static func toolResultText(_ content: TUIJSONValue?) -> String? {
        if let text = content?.stringValue { return text.isEmpty ? nil : text }
        guard let array = content?.arrayValue else { return nil }
        let joined = array.compactMap { $0["text"]?.stringValue }.joined(separator: "\n")
        return joined.isEmpty ? nil : joined
    }
}
