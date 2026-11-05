import Foundation
import Synchronization
import Testing
import FloeCore
import FloeModels
import FloePersistence
import FloeProviders
import FloeSecurity
import FloeTools
@testable import FloeAgentRuntime

private final class CoordinationAdapter: ProviderAdapter, Sendable {
    let protocolKind: ModelProtocol = .openAIChatCompletions
    private struct State: Sendable {
        var requests: [ProviderStreamRequest] = []
        var first: AsyncThrowingStream<AgentEvent, Error>.Continuation?
    }
    private let state = Mutex(State())
    var requests: [ProviderStreamRequest] { state.withLock { $0.requests } }
    func finishFirst() {
        let continuation = state.withLock { value in
            let result = value.first; value.first = nil; return result
        }
        continuation?.yield(.textDelta(.init(text: "Synthetic boundary")))
        continuation?.yield(.completed(.init(stopReason: .endTurn)))
        continuation?.finish()
    }
    func stream(request: ProviderStreamRequest, credentials: ProviderCredentials) -> AsyncThrowingStream<AgentEvent, Error> {
        AsyncThrowingStream { continuation in
            let first = state.withLock { value in
                value.requests.append(request)
                if value.requests.count == 1 { value.first = continuation; return true }
                return false
            }
            if !first {
                continuation.yield(.textDelta(.init(text: "Coordination received")))
                continuation.yield(.completed(.init(stopReason: .endTurn)))
                continuation.finish()
            }
        }
    }
    func listModels(provider: ProviderProfile, credentials: ProviderCredentials) async throws -> [ModelProfile] { [] }
    func testConnection(provider: ProviderProfile, credentials: ProviderCredentials) async throws {}
}

private actor CoordinationOwners {
    private var services: [UUID: ConversationRunService] = [:]
    func set(_ service: ConversationRunService) { services[service.runID] = service }
    func get(_ id: UUID) -> ConversationRunService? { services[id] }
    func remove(_ id: UUID) { services[id] = nil }
}

@available(macOS 15.4, iOS 26.0, *)
private struct CoordinationFixture {
    let conversations: SQLiteConversationStore
    let inputs: SQLiteRunningInputStore
    let sender: ConversationRunService
    let recipient: ConversationRunService
    let senderAdapter: CoordinationAdapter
    let recipientAdapter: CoordinationAdapter
    let owners: CoordinationOwners
    let ingress: ConversationCoordinationService
    static func make() async throws -> Self {
        let database = try DatabaseManager.inMemory()
        try await database.migrate()
        let conversations = SQLiteConversationStore(database: database)
        let runs = SQLiteRunStore(database: database)
        let inputs = SQLiteRunningInputStore(database: database)
        let owners = CoordinationOwners()
        func service(title: String, adapter: CoordinationAdapter) async throws -> ConversationRunService {
            let id = UUID()
            try await conversations.saveConversation(.init(id: id, title: title, createdAt: Date(), updatedAt: Date()))
            let provider = ProviderProfile(kind: .custom, wireProtocol: .openAIChatCompletions,
                baseURL: URL(string: "https://example.invalid")!, displayName: "Synthetic")
            let model = ModelProfile(providerID: provider.id, remoteModelID: "coordination-test",
                displayName: "Synthetic", limits: .init(contextTokens: 8192, maxOutputTokens: 1024), capabilities: [.text, .tools])
            return ConversationRunService(configuration: .init(conversationID: id, provider: provider,
                model: model, allowedToolNames: []), adapter: adapter, policy: HumanApprovalPolicy(),
                executor: CoordinationNoExecution(), contextEngine: nil,
                conversationStore: conversations, runStore: runs, runningInputStore: inputs)
        }
        let a = CoordinationAdapter(), b = CoordinationAdapter()
        let sender = try await service(title: "Runtime operator", adapter: a)
        let recipient = try await service(title: "Web worker", adapter: b)
        await owners.set(sender); await owners.set(recipient)
        return Self(conversations: conversations, inputs: inputs, sender: sender, recipient: recipient,
            senderAdapter: a, recipientAdapter: b, owners: owners,
            ingress: ConversationCoordinationService(conversations: conversations, runs: runs, inputs: inputs,
                liveService: { await owners.get($0) }))
    }
    func request(id: UUID = UUID(), message: String = "Please save your work and release the Linux session, then reply.") -> ConversationCoordinationRequest {
        .init(id: id, senderRunID: sender.runID, recipientRunID: recipient.runID, message: message)
    }
}

private struct CoordinationNoExecution: ToolExecutor {
    var allDescriptors: [ToolCatalog.Descriptor] { [] }
    func descriptor(named name: String) -> ToolCatalog.Descriptor? { nil }
    func execute(_ call: ToolCall, context: ToolContext) async throws -> ToolResult {
        throw FloeError.validationFailed("No tool execution belongs in this synthetic provider fixture")
    }
}

private func coordinationWait(_ condition: @Sendable () -> Bool) async -> Bool {
    for _ in 0..<250 {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return condition()
}

@Suite("Independent task coordination")
struct ConversationCoordinationTests {
    @Test("A real live run consumes one durable system notice at its next provider boundary")
    @available(macOS 15.4, iOS 26.0, *)
    func liveDeliveryAndIdempotency() async throws {
        let f = try await CoordinationFixture.make()
        let a = Task { try await f.sender.start(goal: "Operate the shared runtime") }
        let b = Task { try await f.recipient.start(goal: "Keep the web work going") }
        #expect(await coordinationWait { f.senderAdapter.requests.count == 1 && f.recipientAdapter.requests.count == 1 })
        let request = f.request()
        let receipt = try await f.ingress.deliver(request, cancellation: CancellationToken())
        #expect(receipt.accepted)
        #expect(receipt.status == "queued")
        let duplicate = try await f.ingress.deliver(request, cancellation: CancellationToken())
        #expect(duplicate.accepted)
        #expect(duplicate.status == "alreadyQueued")
        let conflict = try await f.ingress.deliver(f.request(id: request.id, message: "Different content"), cancellation: CancellationToken())
        #expect(!conflict.accepted && conflict.status == "idempotencyConflict")
        f.recipientAdapter.finishFirst()
        try await b.value
        let row = try await f.inputs.input(id: request.id)
        #expect(row?.status == .consumed)
        let transcript = try await f.conversations.messages(conversationID: f.recipient.conversationID)
        let notices = transcript.filter { $0.id == request.id }
        #expect(notices.count == 1)
        #expect(notices.first?.role == "system")
        #expect(notices.first?.runID == f.recipient.runID)
        let recoveredHistory = try await ConversationHistoryAssembler(store: f.conversations)
            .build(conversationID: f.recipient.conversationID)
        let recovered = try #require(recoveredHistory.first { $0.id == request.id })
        #expect(recovered.role == "user", "Peer data must not become a system instruction on recovery")
        #expect(recovered.content.contains("untrusted task content"))
        #expect(recovered.content.contains(f.sender.runID.uuidString))
        #expect(f.recipientAdapter.requests.count == 2)
        let wire = f.recipientAdapter.requests.last?.messages.map(\.content).joined(separator: "\n") ?? ""
        #expect(wire.contains("untrusted task content"))
        #expect(wire.contains(f.sender.runID.uuidString))
        #expect(wire.contains(request.message))
        #expect(transcript.filter { $0.role == "user" }.count == 1, "Peer data must not fabricate user authority")
        await f.sender.cancel(); f.senderAdapter.finishFirst(); try await a.value
    }

    @Test("Missing or ended recipients never launch, queue or fabricate a new task")
    @available(macOS 15.4, iOS 26.0, *)
    func inactiveRecipientDoesNotRestart() async throws {
        let f = try await CoordinationFixture.make()
        let a = Task { try await f.sender.start(goal: "Operate") }
        let b = Task { try await f.recipient.start(goal: "Finish") }
        #expect(await coordinationWait { f.senderAdapter.requests.count == 1 && f.recipientAdapter.requests.count == 1 })
        f.recipientAdapter.finishFirst(); try await b.value
        let request = f.request()
        let ended = try await f.ingress.deliver(request, cancellation: CancellationToken())
        #expect(!ended.accepted && ended.status == "ended")
        #expect(try await f.inputs.input(id: request.id) == nil)
        await f.owners.remove(f.recipient.runID)
        let missing = try await f.ingress.deliver(f.request(), cancellation: CancellationToken())
        #expect(!missing.accepted && missing.status == "unavailable")
        #expect(f.recipientAdapter.requests.count == 1)
        await f.sender.cancel(); f.senderAdapter.finishFirst(); try await a.value
    }

    @Test("The message tool binds sender identity and stable retry identity to native context")
    func toolIdentityAndBounds() async throws {
        let source = UUID(), target = UUID()
        let seen = Mutex<[ConversationCoordinationRequest]>([])
        let tool = AnyAgentTool(ConversationMessageTool(messenger: { request, _ in
            seen.withLock { $0.append(request) }
            return .init(accepted: true, messageID: request.id, status: "queued")
        }))
        let body = try JSONSerialization.data(withJSONObject: ["runID": target.uuidString, "message": "Ready?", "clientMessageID": "operation-1"])
        for call in ["first", "retry"] {
            let output = try await tool.run(body, ToolContext(runID: source, toolCallID: call, cancellation: CancellationToken()))
            #expect(output.exitStatus == 0)
        }
        let requests = seen.withLock { $0 }
        #expect(requests.count == 2)
        #expect(requests[0].senderRunID == source && requests[0].recipientRunID == target)
        #expect(requests[0].id == requests[1].id)
        #expect(throws: (any Error).self) {
            try ConversationMessageTool(messenger: { _, _ in .init(accepted: false, messageID: UUID(), status: "unused") })
                .validate(.init(runID: target, message: String(repeating: "字", count: 1400)))
        }
    }
}
