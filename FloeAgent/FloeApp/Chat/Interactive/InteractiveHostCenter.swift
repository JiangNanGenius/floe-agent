// SPDX-License-Identifier: MPL-2.0
#if canImport(UIKit)
import Foundation
import Combine
import CryptoKit
import GRDB
import FloeCore
import FloeModels
import FloePersistence
import FloeTools
import FloeInteractiveContentCore
import FloeInteractiveContentWebKit

nonisolated enum InteractiveHostCodec {
    static func id(_ value: String) -> UUID {
        let b = Array(SHA256.hash(data: Data(value.utf8)).prefix(16))
        return UUID(uuid: (b[0],b[1],b[2],b[3],b[4],b[5],b[6],b[7],b[8],b[9],b[10],b[11],b[12],b[13],b[14],b[15]))
    }
    static func record(_ document: InteractiveDocument, _ state: InteractiveState) throws -> ConversationPresentationState {
        try state.validate(for: document)
        return .init(key: document.owner.storageKey, conversationID: document.owner.conversationID,
            runID: document.owner.runID, sourceID: document.owner.messageID, digest: document.digest,
            revision: state.revision, document: try JSONEncoder().encode(document), state: try JSONEncoder().encode(state))
    }
}

actor InteractiveHostRepository: InteractiveStateRepository {
    let database: DatabaseManager
    init(database: DatabaseManager) { self.database = database }
    func load(document: InteractiveDocument) async throws -> InteractiveState {
        try await database.writer { db in try ConversationPresentationSQL.prepare(db) }
        let value = try await database.reader { db in try ConversationPresentationSQL.read(document.owner.storageKey, db: db) }
        guard let value else { return InteractiveState(document: document) }
        guard value.digest == document.digest, value.conversationID == document.owner.conversationID,
              value.runID == document.owner.runID, value.sourceID == document.owner.messageID else { throw InteractiveError.ownershipMismatch }
        let state = try JSONDecoder().decode(InteractiveState.self, from: value.state)
        try state.validate(for: document); return state
    }
    func compareAndSwap(document: InteractiveDocument, expectedRevision: UInt64,
                        modelContent: FloeInteractiveContentCore.JSONValue, privateContent: FloeInteractiveContentCore.JSONValue) async throws -> InteractiveState {
        guard expectedRevision < UInt64(Int64.max) - 1 else { throw InteractiveError.limitExceeded }
        try InteractiveLimits.checkState(modelContent); try InteractiveLimits.checkState(privateContent)
        let next = InteractiveState(document: document, revision: expectedRevision + 1, modelContent: modelContent, privateContent: privateContent)
        let value = try InteractiveHostCodec.record(document, next)
        try await database.writer { db in try ConversationPresentationSQL.write(value, expectedRevision: expectedRevision, db: db) }
        return next
    }
    func remove(document: InteractiveDocument) async throws {
        try await database.writer { db in
            try ConversationPresentationSQL.prepare(db)
            try db.execute(sql: "DELETE FROM conversation_presentations WHERE content_key=? AND conversation_id=?",
                arguments: [document.owner.storageKey, document.owner.conversationID.uuidString])
        }
    }
}

@MainActor final class InteractiveHostCenter: ObservableObject {
    @Published private(set) var generation = 0
    private weak var environment: AppEnvironment?
    private var controllers: [String: InteractiveWebController] = [:]
    private var blocked: Set<UUID> = []
    private var keeping: Set<UUID> = []
    private let repository: InteractiveHostRepository
    init(environment: AppEnvironment) {
        self.environment = environment; repository = InteractiveHostRepository(database: environment.database)
    }
    func controller(for document: InteractiveDocument) async throws -> InteractiveWebController {
        try document.validate()
        guard let environment, !blocked.contains(document.owner.conversationID),
              !keeping.contains(document.owner.conversationID) else { throw InteractiveError.closed }
        let owner = document.owner
        let center = environment.conversationCenter
        let runStore = center.runStore(for: owner.conversationID)
        guard let run = try await runStore.run(id: owner.runID), run.conversationID == owner.conversationID,
              !blocked.contains(owner.conversationID) else { throw InteractiveError.ownershipMismatch }
        if let existing = controllers[owner.storageKey] {
            guard existing.document == document else { throw InteractiveError.contentChanged }
            return existing
        }
        guard controllers.count < 64 else { throw InteractiveError.limitExceeded }
        let temporary = center.isTemporaryConversation(owner.conversationID)
        let session = try InteractiveSession(document: document, expectedOwner: owner,
            persistence: temporary ? .temporary : .durable, durableRepository: temporary ? nil : repository)
        let value = InteractiveWebController(document: document, session: session)
        controllers[owner.storageKey] = value
        return value
    }
    func discard(conversationID: UUID) {
        blocked.insert(conversationID)
        let keys = controllers.filter { $0.value.document.owner.conversationID == conversationID }.map(\.key)
        for key in keys { controllers.removeValue(forKey: key)?.invalidate() }
        generation += 1
    }
    func freezeForKeep(conversationID: UUID) async throws -> [ConversationPresentationState] {
        keeping.insert(conversationID)
        var values: [ConversationPresentationState] = []
        for controller in controllers.values.filter({ $0.document.owner.conversationID == conversationID }) {
            await controller.suspend()
            let state = try await controller.session.snapshot()
            values.append(try InteractiveHostCodec.record(controller.document, state))
        }
        guard !blocked.contains(conversationID) else { throw CancellationError() }
        return values
    }
    func didKeep(conversationID: UUID) {
        let keys = controllers.filter { $0.value.document.owner.conversationID == conversationID }.map(\.key)
        for key in keys { controllers.removeValue(forKey: key)?.invalidate() }
        keeping.remove(conversationID); generation += 1
    }
    func keepFailed(conversationID: UUID) { keeping.remove(conversationID); generation += 1 }
    func allowAfterDeletion(conversationID: UUID) { blocked.remove(conversationID); generation += 1 }
    func isTemporary(_ id: UUID) -> Bool { environment?.conversationCenter.isTemporaryConversation(id) == true }
    func allowsInteraction(_ document: InteractiveDocument) -> Bool {
        !blocked.contains(document.owner.conversationID) && !keeping.contains(document.owner.conversationID)
            && controllers[document.owner.storageKey]?.document == document
    }
    func saveHTML(_ data: Data, title: String, conversationID: UUID) async throws {
        guard let environment, !isTemporary(conversationID), !blocked.contains(conversationID),
              try await environment.conversationStore.conversation(id: conversationID) != nil else { throw FloeError.unauthorized }
        let directory = try FileManager.default.url(for: .cachesDirectory, in: .userDomainMask,
            appropriateFor: nil, create: true).appendingPathComponent("FloeInteractiveExports", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent(UUID().uuidString + ".html")
        defer { try? FileManager.default.removeItem(at: file) }
        try data.write(to: file, options: .atomic)
        let record = try await PersonalContentService.shared.importFile(file, folders: [])
        try await PersonalContentService.shared.library().markChanged(record.id, title: title.isEmpty ? IDELanguageRunText.t("交互内容", "Interactive content") : title)
        NotificationCenter.default.post(name: .floeStudioDocumentDidChange, object: record.id)
    }
}

/// Pure adoption of ordered presentation data. It creates no permission and
/// never interprets an imported document as a tool or approval request.
nonisolated enum InteractiveMessageProjection {
    struct Part: Identifiable { let id: String; let text: String?; let document: InteractiveDocument? }
    struct Input: Codable, Sendable {
        var type: String
        var text: String?
        var title: String?
        var html: String?
        var fallback: String?
        var modelContent: FloeInteractiveContentCore.JSONValue?
    }
    static func parts(message: PersistedMessage, displayedText: String? = nil) -> [Part] {
        if message.parts.contains(where: { $0.kind == .interactive }) {
            return message.parts.sorted { $0.partIndex < $1.partIndex }.compactMap { part in
                if part.kind == .interactive, let text = part.text, let data = text.data(using: .utf8),
                   let document = try? JSONDecoder().decode(InteractiveDocument.self, from: data),
                   document.owner.conversationID == message.conversationID,
                   document.owner.messageID == message.id, document.owner.runID == message.runID {
                    return Part(id: part.id.uuidString, text: nil, document: document)
                }
                return part.kind == .text ? Part(id: part.id.uuidString, text: part.text ?? "", document: nil) : nil
            }
        }
        let text = displayedText ?? message.content
        guard let runID = message.runID, text.utf8.count <= 768 * 1_024 else { return [.init(id: "text", text: text, document: nil)] }
        let marker = "```floe-interactive\n"
        var result: [Part] = [], remaining = text[...], index = 0
        while result.count < 24, let start = remaining.range(of: marker),
              let end = remaining[start.upperBound...].range(of: "\n```") {
            let prefix = String(remaining[..<start.lowerBound])
            if !prefix.isEmpty { result.append(.init(id: "text/\(index)", text: prefix, document: nil)) }
            let raw = String(remaining[start.upperBound..<end.lowerBound])
            let owner = ContentOwner(conversationID: message.conversationID, runID: runID, messageID: message.id,
                contentID: InteractiveHostCodec.id("\(message.id)/\(index)/\(InteractiveDigest.sha256(Data(raw.utf8)))"))
            if let input = try? JSONDecoder().decode(Input.self, from: Data(raw.utf8)),
               let document = try? make(input, owner: owner) {
                result.append(.init(id: document.owner.storageKey, text: nil, document: document))
            } else { result.append(.init(id: "invalid/\(index)", text: String(remaining[start.lowerBound..<end.upperBound]), document: nil)) }
            remaining = remaining[end.upperBound...]; index += 1
        }
        if !remaining.isEmpty { result.append(.init(id: "tail", text: String(remaining), document: nil)) }
        return result
    }
    static func make(_ input: Input, owner: ContentOwner) throws -> InteractiveDocument {
        guard input.type == "interactive", let html = input.html, let fallback = input.fallback else { throw InteractiveError.invalidDocument }
        return try InteractiveDocument(owner: owner, kind: "html", title: input.title ?? "", html: html,
            fallbackText: fallback, initialModelContent: input.modelContent ?? .null)
    }
}

private struct ChatPresentTool: AgentTool {
    struct Arguments: Decodable, Sendable { let parts: [InteractiveMessageProjection.Input] }
    static let name = "chat.present"
    static let toolDescription = "Present ordered text and sandboxed interactive charts, calculators or explanations inline in this chat. parts type=text uses text; type=interactive requires html and concise fallback, optional title and modelContent. HTML has no network, native tools, permissions, forms or external navigation. Use floeInteractive.ready(callback), getState(), setState({modelContent,privateContent}) for local interaction state; never replace the host bridge. Existing user.ask remains the only question/answer authority. Results become an actual assistant message with native expand/save controls."
    static let parametersJSON = #"{"type":"object","properties":{"parts":{"type":"array","minItems":1,"maxItems":12,"items":{"type":"object","properties":{"type":{"type":"string","enum":["text","interactive"]},"text":{"type":"string"},"title":{"type":"string"},"html":{"type":"string"},"fallback":{"type":"string"},"modelContent":{}},"required":["type"],"additionalProperties":false}}},"required":["parts"],"additionalProperties":false}"#
    static let riskLabels: Set<RiskLabel> = [.persistsPersonalData]
    static let isSideEffecting = true
    static let toolEffect: ToolEffect = .internalState
    let environment: AppEnvironment
    func validate(_ args: Arguments) throws {
        guard (1...12).contains(args.parts.count), try JSONEncoder().encode(args.parts).count <= 768 * 1_024 else { throw InteractiveError.limitExceeded }
    }
    @MainActor func execute(_ args: Arguments, context: ToolContext) async throws -> ToolExecutionOutput {
        guard context.executionToolName == Self.name, !context.temporaryReadOnly, !context.publicWebOnly,
              context.allowedToolNames?.contains(Self.name) != false,
              context.frozenEffectiveCatalogNames?.contains(Self.name) != false,
              let conversationID = context.conversationID,
              let run = try await environment.runStore.run(id: context.runID),
              run.conversationID == conversationID, run.endedAt == nil else { throw FloeError.unauthorized }
        try context.cancellation.throwIfCancelled()
        let id = InteractiveHostCodec.id("chat.present/\(context.runID)/\(context.toolCallID ?? context.toolIdempotencyKey)")
        let store = environment.conversationStore
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let requestDigest = InteractiveDigest.sha256(try encoder.encode(args.parts))
        if let existing = try await store.messages(conversationID: conversationID).first(where: { $0.id == id }) {
            guard existing.parts.first?.metadata["requestDigest"] == requestDigest else { throw InteractiveError.contentChanged }
            return try StudioToolOutput.make(["messageID": existing.id.uuidString, "status": "presented"])
        }
        var parts: [MessagePart] = [], fallback: [String] = []
        for (index, input) in args.parts.enumerated() {
            if input.type == "text", let text = input.text, text.utf8.count <= 128 * 1_024 {
                parts.append(.init(messageID: id, partIndex: index, kind: .text, text: text)); fallback.append(text)
            } else {
                let owner = ContentOwner(conversationID: conversationID, runID: context.runID, messageID: id,
                    contentID: InteractiveHostCodec.id("\(id)/\(index)"))
                let document = try InteractiveMessageProjection.make(input, owner: owner)
                parts.append(.init(messageID: id, partIndex: index, kind: .interactive,
                    text: String(decoding: try JSONEncoder().encode(document), as: UTF8.self)))
                fallback.append(document.fallbackText)
            }
        }
        if !parts.isEmpty { parts[0].metadata["requestDigest"] = requestDigest }
        try await store.appendMessage(.init(id: id, conversationID: conversationID, role: "assistant",
            content: fallback.joined(separator: "\n\n"), createdAt: Date(), parts: parts, runID: context.runID))
        NotificationCenter.default.post(name: .floeInteractiveMessageDidChange, object: conversationID)
        return try StudioToolOutput.make(["messageID": id.uuidString, "status": "presented"])
    }
}

extension Notification.Name { static let floeInteractiveMessageDidChange = Notification.Name("floe.interactive.message.changed") }
@MainActor func registerInteractiveHostTools(environment: AppEnvironment, registry: ToolRunnerRegistry = .shared) {
    ToolCatalog.register(ChatPresentTool.self); registry.register(ChatPresentTool(environment: environment))
    registerChatInlineContentTools(environment: environment, registry: registry)
}
#endif
