// SPDX-License-Identifier: MPL-2.0
#if canImport(UIKit)
import Foundation
import FloeMeetings
import FloeNotes
import FloeTools

/// A meeting's native link is checked again at the existing Notes writer.
/// This is never resolved from the ordinary Notes selection or conversation.
private struct MeetingNotebookBinding: Sendable {
    let meetingID: UUID
    let root: URL
    let noteID: UUID
    let linkBytes: Data

    static func load(meetingID: UUID, root: URL) throws -> Self {
        let root = root.standardizedFileURL
        guard root.resolvingSymlinksInPath() == root else { throw PersonalContentError.changedDocument }
        let link = root.appendingPathComponent("personal-note.json")
        let values = try link.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true,
              let size = values.fileSize, (1..<1_024).contains(size) else { throw PersonalContentError.missingDocument }
        let data = try Data(contentsOf: link)
        guard data.count < 1_024 else { throw PersonalContentError.invalidProject }
        return Self(meetingID: meetingID, root: root,
                    noteID: try JSONDecoder().decode(UUID.self, from: data), linkBytes: data)
    }
    func validate() throws {
        let current = try Self.load(meetingID: meetingID, root: root)
        guard current.noteID == noteID, current.linkBytes == linkBytes else { throw PersonalContentError.changedDocument }
    }
}

/// Uses the already-authorized current meeting and its actual durable notebook.
/// No new notebook, assistant, capture, playback or transcription is created.
@MainActor enum StudioMeetingNotesContract {
    private struct State: Decodable { let personalNote: NoteDocument? }

    static func expectedNotebook(inState data: Data) throws -> NoteDocument {
        guard let note = try JSONDecoder().decode(State.self, from: data).personalNote,
              note.deletedAt == nil, note.kind == .notebook else { throw PersonalContentError.missingDocument }
        return note
    }
    private static func binding(_ session: MeetingProjectSession) throws -> MeetingNotebookBinding {
        guard session.meeting.id.rawValue == session.id else { throw PersonalContentError.changedDocument }
        let value = try MeetingNotebookBinding.load(meetingID: session.id, root: session.root)
        if let selected = session.notebook.document, selected.id != value.noteID {
            throw PersonalContentError.changedDocument
        }
        return value
    }
    static func read(session: MeetingProjectSession, cancellation: CancellationToken) async throws -> NoteDocument {
        try Task.checkCancellation(); try cancellation.throwIfCancelled()
        let source = try binding(session)
        let meeting = try await session.service.meeting(MeetingID(session.id))
        guard meeting.id.rawValue == source.meetingID,
              let store = try await NotesRepository.shared.existingStore() else { throw PersonalContentError.missingDocument }
        let note = try await store.document(source.noteID)
        try Task.checkCancellation(); try cancellation.throwIfCancelled(); try source.validate()
        guard note.id == source.noteID, note.deletedAt == nil, note.kind == .notebook else {
            throw PersonalContentError.missingDocument
        }
        return note
    }
    static func append(session: MeetingProjectSession, expected: NoteDocument, text: String,
                       requestID: UUID, cancellation: CancellationToken) async throws {
        try Task.checkCancellation(); try cancellation.throwIfCancelled()
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              text.utf8.count <= 128_000, session.notebook.pendingWrites == 0,
              !session.notebook.unsavedDocumentIDs.contains(expected.id) else { throw PersonalContentError.changedDocument }
        let source = try binding(session)
        guard expected.id == source.noteID,
              let store = try await NotesRepository.shared.existingStore() else { throw PersonalContentError.changedDocument }
        let persisted = try await read(session: session, cancellation: cancellation)
        guard persisted == expected else { throw PersonalContentError.changedDocument }
        var pages = NotesTextLayout.pages(text: text, source: nil)
        for i in pages.indices {
            for j in pages[i].elements.indices { pages[i].elements[j].isAIGenerated = true }
        }
        let batch = NoteEditBatch(documentID: expected.id, expectedRevision: expected.revision,
            title: IDELanguageRunText.t("添加会议笔记", "Append meeting notes"),
            edits: pages.enumerated().map { .insertPage($0.element, at: expected.pages.count + $0.offset) },
            requestID: requestID.uuidString)
        try Task.checkCancellation(); try cancellation.throwIfCancelled(); try source.validate()
        let saved = try await store.applyStudioMeetingNote(batch, expected: expected,
                                                         source: source, cancellation: cancellation)
        // The existing SQLite transaction is the save. Return only after a fresh
        // durable read proves the same original and committed revision.
        let readback = try await store.document(source.noteID)
        try source.validate()
        guard readback == saved else { throw PersonalContentError.changedDocument }
        if session.notebook.store != nil { try await session.notebook.reload() }
    }
}

private extension NotesStore {
    /// Synchronous at the existing actor's writer boundary: cancellation and
    /// source checks cannot be separated from apply by an actor suspension.
    func applyStudioMeetingNote(_ batch: NoteEditBatch, expected: NoteDocument,
                                source: MeetingNotebookBinding, cancellation: CancellationToken) throws -> NoteDocument {
        try Task.checkCancellation(); try cancellation.throwIfCancelled(); try source.validate()
        guard try document(batch.documentID) == expected else { throw PersonalContentError.changedDocument }
        return try apply(batch)
    }
}
#endif
