// SPDX-License-Identifier: MPL-2.0
#if canImport(UIKit)
import Foundation
import SwiftUI
import UniformTypeIdentifiers
import FloeCore
import FloeModels
import FloePersistence
import FloeTools

struct ChatInlineContentScope: Sendable, Hashable {
    let conversationID: UUID
    let isTemporary: Bool
}
private struct ChatInlineContentScopeKey: EnvironmentKey {
    static let defaultValue: ChatInlineContentScope? = nil
}
extension EnvironmentValues {
    var chatInlineContentScope: ChatInlineContentScope? {
        get { self[ChatInlineContentScopeKey.self] }
        set { self[ChatInlineContentScopeKey.self] = newValue }
    }
}

enum ResolvedChatInlineContent: Sendable, Equatable {
    case artifact(ToolArtifactReference, runID: UUID, tool: String)
    case output(RunOutputFile, RunOutputReceiptContext)
    case attachment(AttachmentRef, messageID: UUID)
}
enum ChatInlineContentResolutionError: Error, Equatable { case unavailable, wrongOwner, conflictingReceipts }

/// No global attachment map or path adoption. Every open rebuilds authority
/// from the actual saved conversation, run header and completion/message.
enum ChatInlineContentResolver {
    static func resolve(_ reference: ChatContentReference, scope: ChatInlineContentScope,
                        conversations: any ConversationStore, runs: any RunStore) async throws -> ResolvedChatInlineContent {
        guard !scope.isTemporary, let conversation = try await conversations.conversation(id: scope.conversationID),
              conversation.purpose != .temporary else { throw ChatInlineContentResolutionError.wrongOwner }
        if reference.kind == .attachment {
            guard let id = UUID(uuidString: reference.contentID), let attachment = try await conversations.attachment(id: id),
                  attachment.conversationID == scope.conversationID,
                  attachment.messageID == nil || attachment.messageID == reference.ownerID else {
                throw ChatInlineContentResolutionError.wrongOwner
            }
            var cursor: ConversationMessageCursor?
            var owned = false
            repeat {
                try Task.checkCancellation()
                let page = try await conversations.messagePage(conversationID: scope.conversationID, before: cursor, limit: 100)
                if page.messages.contains(where: { $0.id == reference.ownerID && $0.conversationID == scope.conversationID }) { owned = true; break }
                guard page.hasEarlier, let next = page.earlierCursor, next != cursor else { break }
                cursor = next
            } while true
            guard owned, try await conversations.parts(messageID: reference.ownerID).contains(where: {
                $0.messageID == reference.ownerID && $0.attachmentID == id && ($0.kind == .file || $0.kind == .image)
            }) else { throw ChatInlineContentResolutionError.unavailable }
            return .attachment(attachment, messageID: reference.ownerID)
        }
        guard let run = try await runs.run(id: reference.ownerID), run.conversationID == scope.conversationID else {
            throw ChatInlineContentResolutionError.wrongOwner
        }
        var found: ResolvedChatInlineContent?
        var sequence = 0
        while true {
            try Task.checkCancellation()
            let page = try await runs.events(runID: run.id, afterSequence: sequence, limit: 100)
            guard !page.isEmpty else { break }
            for event in page where event.kind == .toolResult && event.runID == run.id {
                guard let payload = payload(event), payload["status"] == "ok",
                      let callID = payload["id"], !callID.isEmpty,
                      let tool = payload["tool"], !tool.isEmpty else { continue }
                let candidate: ResolvedChatInlineContent?
                switch reference.kind {
                case .artifact:
                    let values: [ToolArtifactReference] = decode(payload["artifactRefsJSON"])
                    let matches = values.filter { $0.id.uuidString == reference.contentID && ChatInlineContentCatalog.accepts($0, runID: run.id, tool: tool) }
                    guard matches.dropFirst().allSatisfy({ $0 == matches.first }) else { throw ChatInlineContentResolutionError.conflictingReceipts }
                    candidate = matches.first.map { .artifact($0, runID: run.id, tool: tool) }
                case .output:
                    let values: [RunOutputFile] = decode(payload["outputFilesJSON"])
                    let matches = values.filter { $0.outputID == reference.contentID && ChatInlineContentCatalog.accepts($0,
                        runID: run.id, taskID: scope.conversationID, callID: callID, tool: tool) }
                    guard matches.dropFirst().allSatisfy({ $0 == matches.first }) else { throw ChatInlineContentResolutionError.conflictingReceipts }
                    candidate = matches.first.map { .output($0, .init(runID: run.id, conversationID: scope.conversationID, callID: callID, toolName: tool)) }
                case .attachment: candidate = nil
                }
                if let candidate {
                    guard found == nil || found == candidate else { throw ChatInlineContentResolutionError.conflictingReceipts }
                    found = candidate
                }
            }
            guard let next = page.map(\.sequence).max(), next > sequence else { break }
            sequence = next
        }
        guard try await conversations.conversation(id: scope.conversationID) != nil,
              try await runs.run(id: run.id)?.conversationID == scope.conversationID,
              let found else { throw ChatInlineContentResolutionError.unavailable }
        return found
    }
    static func payload(_ event: RunEventRecord) -> [String: String]? {
        guard event.payloadJSON.utf8.count <= 2 * 1_024 * 1_024 else { return nil }
        return try? JSONDecoder().decode([String: String].self, from: Data(event.payloadJSON.utf8))
    }
    static func decode<Value: Decodable>(_ text: String?) -> [Value] {
        guard let text, text.utf8.count <= 1 * 1_024 * 1_024 else { return [] }
        return (try? JSONDecoder().decode([Value].self, from: Data(text.utf8))) ?? []
    }
}

private struct ChatContentListTool: AgentTool {
    struct Arguments: Decodable, Sendable { var runID: UUID?; var afterSequence: Int?; var eventLimit: Int? }
    static let name = "chat.content.list"
    static let toolDescription = "List saved native content references from this task. Returns directly copyable inlineMarkdown for charts, tables, images, audio/video/document output previews and message attachments; unsupported types retain file previews. Optional runID selects an older run from this task only. Without runID, scan the latest 20 runs; use conversation.read for older run IDs. For a selected run, afterSequence/eventLimit page its events; nextAfterSequence continues. No file paths or external URLs are accepted. " + ChatContentReference.modelInstructions
    static let parametersJSON = #"{"type":"object","properties":{"runID":{"type":"string","format":"uuid"},"afterSequence":{"type":"integer","minimum":0},"eventLimit":{"type":"integer","minimum":1,"maximum":100}},"additionalProperties":false}"#
    static let riskLabels: Set<RiskLabel> = []
    static let isSideEffecting = false
    let environment: AppEnvironment
    func validate(_ args: Arguments) throws {
        guard (args.afterSequence ?? 0) >= 0, (1...100).contains(args.eventLimit ?? 50),
              args.afterSequence == nil || args.runID != nil else { throw FloeError.validationFailed("Use a nonnegative event cursor with runID and eventLimit 1...100") }
    }
    @MainActor func execute(_ args: Arguments, context: ToolContext) async throws -> ToolExecutionOutput {
        guard context.executionToolName == Self.name, !context.temporaryReadOnly, !context.publicWebOnly,
              context.allowedToolNames?.contains(Self.name) != false,
              context.frozenEffectiveCatalogNames?.contains(Self.name) != false,
              let task = context.conversationID,
              let caller = try await environment.runStore.run(id: context.runID), caller.conversationID == task,
              let conversation = try await environment.conversationStore.conversation(id: task),
              conversation.purpose != .temporary else { throw FloeError.unauthorized }
        try context.cancellation.throwIfCancelled()
        let headers: [RunRecord]
        if let id = args.runID {
            guard let run = try await environment.runStore.run(id: id), run.conversationID == task else { throw FloeError.unauthorized }
            headers = [run]
        } else { headers = try await environment.runStore.recentRuns(conversationID: task, limit: 20) }
        var items: [ChatContentDescriptor] = [], pages: [[String: String]] = []
        for run in headers {
            try context.cancellation.throwIfCancelled()
            let events = if args.runID != nil {
                try await environment.runStore.events(runID: run.id, afterSequence: args.afterSequence ?? 0, limit: args.eventLimit ?? 50)
            } else { try await environment.runStore.recentEvents(runID: run.id, limit: 50) }
            for event in events where event.kind == .toolResult {
                guard let payload = ChatInlineContentResolver.payload(event), payload["status"] == "ok",
                      let call = payload["id"], let tool = payload["tool"] else { continue }
                items += ChatInlineContentCatalog.descriptors(artifacts: ChatInlineContentResolver.decode(payload["artifactRefsJSON"]),
                    outputs: ChatInlineContentResolver.decode(payload["outputFilesJSON"]), runID: run.id, taskID: task, callID: call, tool: tool)
            }
            pages.append(["runID": run.id.uuidString,
                "startAfterSequence": String(args.afterSequence ?? 0),
                "mode": args.runID == nil ? "recent; select this runID with afterSequence=0 for earlier events" : "forward",
                "nextAfterSequence": String(events.map(\.sequence).max() ?? (args.afterSequence ?? 0)),
                "hasMore": args.runID != nil && events.count == (args.eventLimit ?? 50) ? "true" : "false"])
        }
        let messages = try await environment.conversationStore.recentMessages(conversationID: task, limit: 100)
        for message in messages {
            let parts = try await environment.conversationStore.parts(messageID: message.id)
            for part in parts where part.kind == .file || part.kind == .image {
                guard let id = part.attachmentID, let attachment = try await environment.conversationStore.attachment(id: id),
                      attachment.conversationID == task,
                      attachment.messageID == nil || attachment.messageID == message.id,
                      let reference = ChatContentReference(kind: .attachment, ownerID: message.id, contentID: id.uuidString) else { continue }
                items.append(.init(reference: reference, mimeType: UTType(attachment.uti)?.preferredMIMEType ?? "application/octet-stream", title: attachment.displayName))
            }
        }
        var seen: Set<ChatContentReference> = []
        let unique = items.filter { seen.insert($0.reference).inserted }
        let data = try ChatInlineContentCatalog.listingData(unique, pages: pages)
        return ToolExecutionOutput(digesting: String(decoding: data, as: UTF8.self), maximumSummaryCharacters: 65_536)
    }
}
@MainActor func registerChatInlineContentTools(environment: AppEnvironment, registry: ToolRunnerRegistry) {
    ToolCatalog.register(ChatContentListTool.self); registry.register(ChatContentListTool(environment: environment))
}
#endif
