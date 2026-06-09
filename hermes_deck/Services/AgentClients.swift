import Foundation

final class AgentChildProcessBox: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?

    func set(_ process: Process) {
        lock.withLock {
            self.process = process
        }
    }

    func killTree() {
        let currentProcess = lock.withLock { self.process }
        guard let currentProcess, currentProcess.isRunning else { return }
        ACPConnection.killTree(pid: currentProcess.processIdentifier)
    }
}

actor LocalHermesAgentClient: HermesAgentClient {
    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    func send(_ request: HermesChatRequest) async throws -> HermesChatResponse {
        var urlRequest = URLRequest(url: request.profile.endpoint)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.httpBody = try JSONEncoder().encode(Payload(request: request))

        let (data, response) = try await session.data(for: urlRequest)
        guard let httpResponse = response as? HTTPURLResponse, 200..<300 ~= httpResponse.statusCode else {
            throw HermesAgentError.invalidResponse
        }
        return try JSONDecoder().decode(HermesChatResponse.self, from: data)
    }
}

struct StubHermesAgentClient: HermesAgentClient {
    var reply: String

    func send(_ request: HermesChatRequest) async throws -> HermesChatResponse {
        HermesChatResponse(content: reply)
    }
}

struct StubStreamingHermesAgentClient: HermesAgentClient {
    var events: [HermesAgentEvent]

    func send(_ request: HermesChatRequest) async throws -> HermesChatResponse {
        let final = events.compactMap { event -> String? in
            if case .messageComplete(_, let text, _, _) = event { return text }
            return nil
        }.last ?? ""
        return HermesChatResponse(content: final)
    }

    func eventStream(for request: HermesChatRequest) -> AsyncThrowingStream<HermesAgentEvent, Error> {
        AsyncThrowingStream { continuation in
            for event in events {
                continuation.yield(event)
            }
            continuation.finish()
        }
    }
}


private struct Payload: Encodable {
    var profileID: String
    var messages: [MessagePayload]
    var attachments: [AttachmentPayload]

    nonisolated init(request: HermesChatRequest) {
        profileID = request.profile.id
        messages = request.messages.map(MessagePayload.init)
        attachments = request.attachments.map(AttachmentPayload.init)
    }
}

private struct MessagePayload: Encodable {
    var role: String
    var content: String

    nonisolated init(message: ChatMessage) {
        role = message.role.rawValue
        content = message.content
    }
}

private struct AttachmentPayload: Encodable {
    var name: String
    var path: String
    var contentType: String

    nonisolated init(attachment: Attachment) {
        name = attachment.name
        path = attachment.url.path(percentEncoded: false)
        contentType = attachment.contentType
    }
}
