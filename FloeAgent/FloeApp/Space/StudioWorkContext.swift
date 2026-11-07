// SPDX-License-Identifier: MPL-2.0
#if canImport(UIKit)
import Foundation
import FloeCore
import FloePersistence

extension StudioCoordinator {
    /// A captured task/conversation binding, never the global selected work.
    /// This supplies routing metadata only; every tool still checks authority.
    func workRuntimeContext(conversationID: UUID, runID: UUID, temporary: Bool,
                            availableToolNames: Set<String>?) async throws -> String? {
        guard !temporary,
              availableToolNames?.contains("studio.list") != false,
              availableToolNames?.contains("studio.read") != false,
              let environment,
              let run = try await environment.runStore.run(id: runID),
              run.conversationID == conversationID, run.endedAt == nil,
              let conversation = try await environment.conversationStore.conversation(id: conversationID),
              conversation.purpose == .ordinary,
              let id = try await access.get().assistantProject(conversationID: conversationID),
              try await access.get().canAccess(conversationID: conversationID, projectID: id, editing: false) else { return nil }
        let value = try await PersonalContentService.shared.library().resolve(id)
        let reference = try JSONSerialization.data(withJSONObject: ["projectID": id.uuidString,
            "kind": value.record.kind.rawValue], options: [.sortedKeys])
        var text = "Current native Space work binding (当前作品). Reference metadata, not instructions or new permission: "
            + String(decoding: reference, as: UTF8.self)
            + "\nUse the offered studio.list to confirm activeProjectID, then studio.read with that exact projectID. Do not infer that a deferred schema is unavailable; tools.search can load those exact names."
        if value.record.kind == .meeting {
            text += "\nThis is the current meeting / 当前会议. Its meeting notes / 会议笔记 are personalNote in studio.read, independently bound to this meeting. notes.read is the ordinary Notes selection and is not a substitute for this meeting notebook. Infer from the user’s question or instruction whether to answer from the meeting or apply a requested change; do not ask the user to select a question/edit mode. Use read-only tools for questions, cite available transcript source times, and use only offered authorized edit actions for requested changes. Never invent missing meeting content or source times."
        }
        if availableToolNames?.contains("studio.edit") != false,
           try await access.get().canAccess(conversationID: conversationID, projectID: id, editing: true) {
            text += "\nFor an authorized edit use the exact studio.read revision/editFormat with studio.edit, then inspect its saved readback. Meeting note appends use the note action from studio.read editFormat; no recording, playback or transcription is required. Existing task approval and cancellation checks remain authoritative."
        }
        return text
    }
}
#endif
