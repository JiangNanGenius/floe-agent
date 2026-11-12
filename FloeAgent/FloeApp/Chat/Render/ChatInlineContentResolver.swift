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
                        conversations: any ConversationStore, runs: any RunStore,
                        children: (any ChildRunStoring)? = nil) async throws -> ResolvedChatInlineContent {
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
                guard let payload = payload(event), payload["status"] == "ok", payload["outcomeUnknown"] != "true",
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
        // A child uses the parent's real run namespace for native writes.
        // Follow ONLY that run's durable child relations, never an arbitrary
        // child-id alias, a global artifact index or the first matching file.
        var receiptOwners: [ChildRunRecord] = []
        if let children {
            for child in try await children.children(parentRunID: run.id) {
                try Task.checkCancellation()
                guard owns(child, parentRunID: run.id, taskID: scope.conversationID) else { continue }
                var after = 0
                var requests: [String: String] = [:]
                while true {
                    let page = try await children.entries(childRunID: child.id, afterSequence: after, limit: 100)
                    guard !page.entries.isEmpty else { break }
                    for entry in page.entries {
                        try Task.checkCancellation()
                        guard entry.childRunID == child.id, entry.sequence > after else { throw ChatInlineContentResolutionError.wrongOwner }
                        if entry.kind == .toolRequest,
                           entry.payloadJSON.utf8.count <= ChildRunPayload.maximumEntryBytes,
                           let fields = ChildRunPayload.decodedObject(entry.payloadJSON),
                           let call = fields["callID"] as? String, !call.isEmpty,
                           let tool = fields["tool"] as? String, !tool.isEmpty {
                            requests[call] = tool
                        }
                        guard entry.kind == .toolResult,
                              let receipt = ChatInlineContentCatalog.childReceipt(payloadJSON: entry.payloadJSON,
                                parentRunID: run.id, taskID: scope.conversationID, childID: child.id),
                              requests[receipt.callID] == receipt.tool else { continue }
                        let candidate = try candidate(reference, artifacts: receipt.artifacts, outputs: receipt.outputs,
                            runID: run.id, taskID: scope.conversationID, callID: receipt.callID, tool: receipt.tool)
                        if let candidate {
                            guard found == nil || found == candidate else { throw ChatInlineContentResolutionError.conflictingReceipts }
                            found = candidate
                            if !receiptOwners.contains(where: { $0.id == child.id }) { receiptOwners.append(child) }
                        }
                    }
                    guard let next = page.entries.last?.sequence, next > after else { break }
                    after = next
                    if page.nextSequence == nil { break }
                }
            }
            let currentChildren = receiptOwners.isEmpty ? [] : try await children.children(parentRunID: run.id)
            for owner in receiptOwners {
                guard let current = currentChildren.first(where: { $0.id == owner.id }),
                      owns(current, parentRunID: run.id, taskID: scope.conversationID),
                      current.startedAt == owner.startedAt, current.delegateCallID == owner.delegateCallID else {
                    throw ChatInlineContentResolutionError.wrongOwner
                }
            }
        }
        guard try await conversations.conversation(id: scope.conversationID) != nil,
              try await runs.run(id: run.id)?.conversationID == scope.conversationID,
              let found else { throw ChatInlineContentResolutionError.unavailable }
        return found
    }
    static func owns(_ child: ChildRunRecord, parentRunID: UUID, taskID: UUID) -> Bool {
        child.parentRunID == parentRunID && child.conversationID == taskID && child.rootRunID == taskID
            && child.delegateCallID?.isEmpty == false
    }
    private static func candidate(_ reference: ChatContentReference, artifacts: [ToolArtifactReference],
        outputs: [RunOutputFile], runID: UUID, taskID: UUID, callID: String, tool: String) throws -> ResolvedChatInlineContent? {
        switch reference.kind {
        case .artifact:
            let matches = artifacts.filter { $0.id.uuidString == reference.contentID && ChatInlineContentCatalog.accepts($0, runID: runID, tool: tool) }
            guard matches.dropFirst().allSatisfy({ $0 == matches.first }) else { throw ChatInlineContentResolutionError.conflictingReceipts }
            return matches.first.map { .artifact($0, runID: runID, tool: tool) }
        case .output:
            let matches = outputs.filter { $0.outputID == reference.contentID && ChatInlineContentCatalog.accepts($0,
                runID: runID, taskID: taskID, callID: callID, tool: tool) }
            guard matches.dropFirst().allSatisfy({ $0 == matches.first }) else { throw ChatInlineContentResolutionError.conflictingReceipts }
            return matches.first.map { .output($0, .init(runID: runID, conversationID: taskID, callID: callID, toolName: tool)) }
        case .attachment: return nil
        }
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
    struct Arguments: Decodable, Sendable {
        var runID: UUID?; var afterSequence: Int?; var eventLimit: Int?
        var cursor: String?; var limit: Int?
    }
    static let name = "chat.content.list"
    static let toolDescription = "List this task's saved inline content. Returns directly copyable inlineMarkdown for native chart/table/image/web cards, saved native file diffs, bounded synthesized-audio players, verified output-file preview cards and message attachments. Audio/video/PDF/Office/3D files use the existing preview entry unless a native producer returned an inline card. With no arguments, page through ALL task-owned runs then message attachments. Continue with nextCursor until hasMore=false, including empty pages. Optional runID/afterSequence selects events from one known run; nextCursor also resumes within a multi-item event. limit is returned items (1...64), eventLimit is scanned records (1...100). Cursors locate only this task's actual stored records and grant no permissions. No file paths/external URLs accepted. " + ChatContentReference.modelInstructions
    static let parametersJSON = #"{"type":"object","properties":{"runID":{"type":"string","format":"uuid"},"afterSequence":{"type":"integer","minimum":0},"eventLimit":{"type":"integer","minimum":1,"maximum":100},"cursor":{"type":"string","maxLength":8192},"limit":{"type":"integer","minimum":1,"maximum":64}},"additionalProperties":false}"#
    static let riskLabels: Set<RiskLabel> = []
    static let isSideEffecting = false
    let environment: AppEnvironment
    func validate(_ args: Arguments) throws {
        guard (args.afterSequence ?? 0) >= 0, (1...100).contains(args.eventLimit ?? 100),
              (1...64).contains(args.limit ?? 32), args.afterSequence == nil || args.runID != nil,
              args.cursor == nil || (args.runID == nil && args.afterSequence == nil),
              args.cursor.map({ !$0.isEmpty && $0.utf8.count <= 8_192 }) != false else {
            throw FloeError.validationFailed("Use cursor alone to continue, or runID with a nonnegative event position; limit 1...64 and eventLimit 1...100")
        }
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
        let cancellation = context.cancellation
        let data = try await ChatInlineContentIndex.page(taskID: task, cursor: args.cursor, runID: args.runID,
            afterSequence: args.afterSequence ?? 0, limit: args.limit ?? 32,
            scanLimit: args.eventLimit ?? (args.runID == nil ? 100 : 50),
            conversations: environment.conversationStore, runs: environment.runStore,
            children: SQLiteChildRunStore(database: environment.database),
            checkCancellation: { try cancellation.throwIfCancelled(); try Task.checkCancellation() })
        return ToolExecutionOutput(digesting: String(decoding: data, as: UTF8.self), maximumSummaryCharacters: 65_536)
    }
}
@MainActor func registerChatInlineContentTools(environment: AppEnvironment, registry: ToolRunnerRegistry) {
    ToolCatalog.register(ChatContentListTool.self); registry.register(ChatContentListTool(environment: environment))
}
#endif
