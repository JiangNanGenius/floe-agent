// SPDX-License-Identifier: MPL-2.0
import Foundation
import FloeNotes

extension NotesEngine {
    /// Trusted host projection of the existing durable mapping, not a model tool.
    func assistantThreadProjection(_ value: NotesJSONValue?) async throws -> Data {
        let payload = try NotesPayload(value)
        let documentID = try payload.uuid("documentID")
        let store = try requireStore()
        let document = try await store.document(documentID)
        guard document.deletedAt == nil else { throw NoteError.notFound }
        let conversation = try await store.assistantConversation(documentID: documentID)
        var fields: [String: Any] = ["documentID": documentID.uuidString]
        if let conversation {
            fields["conversationID"] = conversation.uuidString
        } else {
            fields["conversationID"] = NSNull()
        }
        return success(fields)
    }
}
