import Foundation

/// Bridges the Antigravity (`agy`) CLI to the app's agent boundary.
///
/// `agy` is **not** an ACP agent: it runs one prompt per invocation in
/// `--print` mode and emits the final answer as plain text. There is no
/// streaming, tool, permission round-trip, or safe per-conversation resume.
/// The default `eventStream` surfaces the whole reply as a single message.
/// Tool use is auto-approved with `--dangerously-skip-permissions` so print
/// mode never blocks waiting for an approval that the UI cannot answer.
actor AgyClient: HermesAgentClient {

    func send(_ request: HermesChatRequest) async throws -> HermesChatResponse {
        let text = request.promptText
        let arguments = ["agy", "--dangerously-skip-permissions", "--print", text]

        let output = try await Self.run(arguments: arguments, workingDirectory: request.workingDirectory)
        return HermesChatResponse(content: output.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    // @concurrent on both helpers: with the project's MainActor default
    // isolation these statics would otherwise run on the main actor, and the
    // blocking pipe reads / waitUntilExit would freeze the UI for the whole
    // CLI turn (Task.detached alone doesn't help — awaiting a MainActor
    // function hops right back).
    @concurrent
    private static func run(arguments: [String], workingDirectory: URL) async throws -> String {
        let processBox = AgentChildProcessBox()
        let task = Task.detached(priority: .userInitiated) {
            try await withTaskCancellationHandler {
                try await runProcess(arguments: arguments, workingDirectory: workingDirectory, processBox: processBox)
            } onCancel: {
                processBox.killTree()
            }
        }
        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
            processBox.killTree()
        }
    }

    @concurrent
    private static func runProcess(
        arguments: [String],
        workingDirectory: URL,
        processBox: AgentChildProcessBox
    ) async throws -> String {
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

        try process.run()

        let outputTask = Task { output.fileHandleForReading.readDataToEndOfFile() }
        let errorTask = Task { errorPipe.fileHandleForReading.readDataToEndOfFile() }
        let outputData = await outputTask.value
        let errorData = await errorTask.value
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            let message = String(data: errorData, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            throw HermesAgentError.rpcError(message?.isEmpty == false ? message! : "agy exited with status \(process.terminationStatus).")
        }
        return String(data: outputData, encoding: .utf8) ?? ""
    }
}
