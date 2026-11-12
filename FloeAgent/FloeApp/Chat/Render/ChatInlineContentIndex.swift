// SPDX-License-Identifier: MPL-2.0
#if canImport(UIKit)
import Foundation
import UniformTypeIdentifiers
import FloeCore
import FloeModels
import FloePersistence
import FloeTools

/// Stateless positions, never authority: resumed records are owner-checked.
@MainActor
enum ChatInlineContentIndex {
    private nonisolated enum Phase: String, Codable, Sendable { case runs, children, messages, done }
    private nonisolated struct ActiveRun: Codable, Sendable {
        var id: UUID
        var startedAt: Date
        var after: Int
        var upper: Int
        var event: Int?
        var item = 0
    }
    private nonisolated struct ActiveMessage: Codable, Sendable {
        var id: UUID
        var createdAt: Date
        var item = 0
    }
    private nonisolated struct ActiveChild: Codable, Sendable {
        var id: UUID
        var startedAt: Date
        var after = 0
        var event: Int?
        var item = 0
        var requested: [String]?
    }
    private nonisolated struct Cursor: Codable, Sendable {
        var version = 1
        var task: UUID
        var phase = Phase.runs
        var beforeRun: ConversationRunCursor?
        var run: ActiveRun?
        var beforeMessage: ConversationMessageCursor?
        var message: ActiveMessage?
        var child: ActiveChild?
        var finishedChild: UUID?
        var selectedRun: UUID?
        var selectedStart = 0
        var selectedAfter = 0
    }
    private nonisolated struct Step: Sendable {
        var next: Cursor
        var content: ChatContentDescriptor?
    }

    static func page(taskID: UUID, cursor: String? = nil, runID: UUID? = nil,
                     afterSequence: Int = 0, limit: Int = 32, scanLimit: Int = 100,
                     conversations: any ConversationStore, runs: any RunStore,
                     children: (any ChildRunStoring)? = nil,
                     maximumBytes: Int = 60 * 1_024,
                     checkCancellation: @Sendable () throws -> Void = { try Task.checkCancellation() }) async throws -> Data {
        guard (1...64).contains(limit), (1...100).contains(scanLimit), afterSequence >= 0,
              cursor == nil || (runID == nil && afterSequence == 0),
              let task = try await conversations.conversation(id: taskID), task.purpose != .temporary else { throw FloeError.unauthorized }
        var state: Cursor
        if let cursor { state = try decode(cursor, taskID: taskID) }
        else if let runID {
            guard let run = try await runs.run(id: runID), run.conversationID == taskID else { throw FloeError.unauthorized }
            let upper = try await runs.recentEvents(runID: run.id, limit: 1).last?.sequence ?? 0
            state = Cursor(task: taskID, run: .init(id: run.id, startedAt: run.startedAt, after: afterSequence, upper: upper),
                           selectedRun: runID, selectedStart: afterSequence, selectedAfter: afterSequence)
        } else { state = Cursor(task: taskID) }
        if let selected = state.selectedRun {
            guard try await runs.run(id: selected)?.conversationID == taskID else { throw FloeError.unauthorized }
        }
        var contents: [ChatContentDescriptor] = []
        var seen: Set<ChatContentReference> = []
        for _ in 0..<scanLimit {
            try checkCancellation()
            guard state.phase != .done, contents.count < limit else { break }
            let step = try await next(state, conversations: conversations, runs: runs, children: children)
            if let content = step.content, !seen.contains(content.reference) {
                // Serialize WITH the item's precise continuation. A dropped
                // item never advances the cursor beyond that item.
                let trial = try encode(contents + [content], state: step.next)
                guard trial.count <= maximumBytes else {
                    guard !contents.isEmpty else { throw FloeError.validationFailed("One content reference exceeds the page budget") }
                    break
                }
                contents.append(content); seen.insert(content.reference)
            }
            state = step.next
        }
        try checkCancellation()
        guard let current = try await conversations.conversation(id: taskID), current.purpose != .temporary else { throw FloeError.unauthorized }
        let data = try encode(contents, state: state)
        guard data.count <= maximumBytes else { throw FloeError.validationFailed("Content cursor exceeds the page budget") }
        return data
    }

    private static func next(_ state: Cursor, conversations: any ConversationStore, runs: any RunStore,
                             children: (any ChildRunStoring)?) async throws -> Step {
        var next = state
        switch state.phase {
        case .runs:
            guard var active = state.run else {
                let page = try await runs.runPage(conversationID: state.task, before: state.beforeRun, limit: 1)
                if let run = page.runs.first {
                    guard run.conversationID == state.task else { throw FloeError.unauthorized }
                    let upper = try await runs.recentEvents(runID: run.id, limit: 1).last?.sequence ?? 0
                    next.run = .init(id: run.id, startedAt: run.startedAt, after: 0, upper: upper)
                } else { next.phase = state.selectedRun == nil ? .messages : .done }
                return .init(next: next)
            }
            guard let owner = try await runs.run(id: active.id), owner.conversationID == state.task,
                  owner.startedAt == active.startedAt else { throw FloeError.unauthorized }
            let after = active.event.map { $0 - 1 } ?? active.after
            let events = try await runs.events(runID: active.id, afterSequence: after, limit: 1)
            guard let event = events.first, event.sequence <= active.upper else {
                if children != nil { next.phase = .children }
                else {
                    next.beforeRun = .init(startedAt: active.startedAt, runID: active.id); next.run = nil
                    if state.selectedRun != nil { next.phase = .done }
                }
                return .init(next: next)
            }
            guard event.runID == active.id, active.event == nil || active.event == event.sequence else {
                throw FloeError.validationFailed("Saved content page changed; restart the listing")
            }
            let items: [ChatContentDescriptor]
            if event.kind == .toolResult, let payload = ChatInlineContentResolver.payload(event), payload["status"] == "ok", payload["outcomeUnknown"] != "true",
               let call = payload["id"], let tool = payload["tool"] {
                items = ChatInlineContentCatalog.descriptors(artifacts: ChatInlineContentResolver.decode(payload["artifactRefsJSON"]),
                    outputs: ChatInlineContentResolver.decode(payload["outputFilesJSON"]), runID: active.id, taskID: state.task, callID: call, tool: tool)
            } else { items = [] }
            guard active.item <= items.count else { throw FloeError.validationFailed("Invalid content item cursor") }
            let content = active.item < items.count ? items[active.item] : nil
            active.item += content == nil ? 0 : 1
            if active.item >= items.count {
                active.after = event.sequence; active.event = nil; active.item = 0
                if state.selectedRun != nil { next.selectedAfter = event.sequence }
            } else { active.event = event.sequence }
            next.run = active
            return .init(next: next, content: content)
        case .children:
            guard let parent = state.run, let current = try await runs.run(id: parent.id),
                  current.conversationID == state.task, current.startedAt == parent.startedAt else { throw FloeError.unauthorized }
            guard let children else { throw FloeError.unauthorized }
            guard var active = state.child else {
                let records = try await children.children(parentRunID: parent.id)
                let child = records.filter {
                    ChatInlineContentResolver.owns($0, parentRunID: parent.id, taskID: state.task)
                        && (state.finishedChild == nil || $0.id.uuidString > state.finishedChild!.uuidString)
                }.min { $0.id.uuidString < $1.id.uuidString }
                if let child { next.child = .init(id: child.id, startedAt: child.startedAt) }
                else {
                    next.beforeRun = .init(startedAt: parent.startedAt, runID: parent.id)
                    next.run = nil; next.finishedChild = nil
                    next.phase = state.selectedRun == nil ? .runs : .done
                }
                return .init(next: next)
            }
            guard let owner = try await children.children(parentRunID: parent.id).first(where: { $0.id == active.id }),
                  ChatInlineContentResolver.owns(owner, parentRunID: parent.id, taskID: state.task),
                  owner.startedAt == active.startedAt else { throw FloeError.unauthorized }
            let page = try await children.entries(childRunID: active.id,
                afterSequence: active.event.map { $0 - 1 } ?? active.after, limit: 1)
            guard let entry = page.entries.first else {
                next.finishedChild = active.id; next.child = nil
                return .init(next: next)
            }
            guard entry.childRunID == active.id, entry.sequence > active.after,
                  active.event == nil || active.event == entry.sequence else { throw FloeError.unauthorized }
            let fields = ChildRunPayload.decodedObject(entry.payloadJSON)
            let requestKey: String?
            if let call = fields?["callID"] as? String, !call.isEmpty,
               let tool = fields?["tool"] as? String, !tool.isEmpty {
                requestKey = FloeDigest.sha256Hex(try JSONEncoder().encode([call, tool]))
            } else { requestKey = nil }
            if entry.kind == .toolRequest, let requestKey {
                var requested = Set(active.requested ?? []); requested.insert(requestKey)
                guard requested.count <= 64 else { throw FloeError.validationFailed("Too many unmatched child tool requests") }
                active.requested = requested.sorted()
            }
            let items: [ChatContentDescriptor]
            if entry.kind == .toolResult,
               let requestKey, active.requested?.contains(requestKey) == true,
               let receipt = ChatInlineContentCatalog.childReceipt(payloadJSON: entry.payloadJSON,
                    parentRunID: parent.id, taskID: state.task, childID: active.id) {
                items = receipt.descriptors
            } else { items = [] }
            guard active.item <= items.count else { throw FloeError.validationFailed("Invalid child content cursor") }
            let content = active.item < items.count ? items[active.item] : nil
            active.item += content == nil ? 0 : 1
            if active.item >= items.count {
                active.after = entry.sequence; active.event = nil; active.item = 0
                if entry.kind == .toolResult, let requestKey { active.requested?.removeAll { $0 == requestKey } }
            }
            else { active.event = entry.sequence }
            next.child = active
            return .init(next: next, content: content)
        case .messages:
            guard let active = state.message else {
                let page = try await conversations.messagePage(conversationID: state.task, before: state.beforeMessage, limit: 1)
                if let message = page.messages.first {
                    guard message.conversationID == state.task else { throw FloeError.unauthorized }
                    next.message = .init(id: message.id, createdAt: message.createdAt)
                } else { next.phase = .done }
                return .init(next: next)
            }
            guard let message = try await conversations.message(id: active.id, conversationID: state.task),
                  message.conversationID == state.task, message.createdAt == active.createdAt else { throw FloeError.unauthorized }
            // Each scan step reads at most one attachment. Rebuilding every
            // attachment for every item would bypass the scan budget and
            // repeat database reads quadratically within a large message.
            guard active.item <= message.parts.count else { throw FloeError.validationFailed("Invalid attachment item cursor") }
            guard active.item < message.parts.count else {
                next.beforeMessage = .init(createdAt: active.createdAt, messageID: active.id); next.message = nil
                return .init(next: next)
            }
            let part = message.parts[active.item]
            if active.item + 1 == message.parts.count {
                next.beforeMessage = .init(createdAt: active.createdAt, messageID: active.id); next.message = nil
            } else { next.message?.item += 1 }
            guard part.messageID == message.id, part.kind == .file || part.kind == .image,
                  let id = part.attachmentID else { return .init(next: next) }
            // The first matching part represents this message's reference.
            // Inspect only already-loaded metadata; no growing cursor set or
            // repeated attachment queries are needed across pages.
            guard !message.parts.prefix(active.item).contains(where: {
                $0.messageID == message.id && ($0.kind == .file || $0.kind == .image) && $0.attachmentID == id
            }) else { return .init(next: next) }
            guard let attachment = try await conversations.attachment(id: id), attachment.conversationID == state.task,
                  attachment.messageID == nil || attachment.messageID == message.id,
                  let reference = ChatContentReference(kind: .attachment, ownerID: message.id, contentID: id.uuidString) else {
                return .init(next: next)
            }
            return .init(next: next, content: .init(reference: reference,
                mimeType: UTType(attachment.uti)?.preferredMIMEType ?? "application/octet-stream", title: attachment.displayName))
        case .done: return .init(next: next)
        }
    }

    private static func encode(_ contents: [ChatContentDescriptor], state: Cursor) throws -> Data {
        let cursor: Any
        if state.phase == .done { cursor = NSNull() }
        else {
            cursor = try JSONEncoder().encode(state).base64EncodedString()
                .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
                .replacingOccurrences(of: "=", with: "")
        }
        let pages: [[String: String]] = state.selectedRun.map { id in
            [["runID": id.uuidString, "startAfterSequence": String(state.selectedStart),
              "nextAfterSequence": String(state.selectedAfter), "hasMore": state.phase == .done ? "false" : "true"]]
        } ?? []
        return try JSONSerialization.data(withJSONObject: ["contents": ChatInlineContentCatalog.wireItems(contents),
            "nextCursor": cursor, "hasMore": state.phase != .done, "truncated": false, "pages": pages,
            "instructions": "Copy inlineMarkdown verbatim on standalone lines. Continue with nextCursor (even after an empty contents page) until hasMore=false. A cursor resumes the exact next item; do not replace it with an event sequence. " + ChatContentReference.modelInstructions], options: [.sortedKeys])
    }

    private static func decode(_ text: String, taskID: UUID) throws -> Cursor {
        guard text.utf8.count <= 8_192, !text.isEmpty,
              text.utf8.allSatisfy({ (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 45 || $0 == 95 }) else { throw FloeError.validationFailed("Invalid content cursor") }
        var encoded = text.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        encoded += String(repeating: "=", count: (4 - encoded.count % 4) % 4)
        guard let bytes = Data(base64Encoded: encoded), let value = try? JSONDecoder().decode(Cursor.self, from: bytes),
              value.version == 1, value.task == taskID, value.selectedStart >= 0, value.selectedAfter >= 0,
              value.run == nil || value.phase == .runs || value.phase == .children, value.message == nil || value.phase == .messages,
              value.child == nil || (value.phase == .children && value.run != nil),
              value.finishedChild == nil || value.phase == .children,
              value.selectedRun == nil || (value.phase != .messages && value.beforeMessage == nil && value.message == nil),
              value.selectedRun == nil || value.phase == .done || value.run?.id == value.selectedRun,
              value.beforeRun?.startedAt.timeIntervalSince1970.isFinite != false,
              value.beforeMessage?.createdAt.timeIntervalSince1970.isFinite != false else { throw FloeError.unauthorized }
        if let active = value.run {
            guard active.startedAt.timeIntervalSince1970.isFinite, active.after >= 0, active.upper >= 0,
                  (0...64).contains(active.item), active.event == nil || (active.event! > active.after && active.event! <= active.upper),
                  active.event != nil || active.item == 0,
                  value.selectedRun == nil || value.selectedRun == active.id else { throw FloeError.validationFailed("Invalid run content cursor") }
        }
        if let active = value.message {
            guard active.createdAt.timeIntervalSince1970.isFinite, active.item >= 0 else { throw FloeError.validationFailed("Invalid message content cursor") }
        }
        if let active = value.child {
            guard active.startedAt.timeIntervalSince1970.isFinite, active.after >= 0,
                  (0...64).contains(active.item), active.event == nil || active.event! > active.after,
                  active.event != nil || active.item == 0 else { throw FloeError.validationFailed("Invalid child content cursor") }
            if let requested = active.requested {
                guard requested.count <= 64, Set(requested).count == requested.count,
                      requested.allSatisfy({ RunOutputFile.isValidSHA256Hex($0) }) else { throw FloeError.validationFailed("Invalid child request cursor") }
            }
        }
        return value
    }
}
#endif
