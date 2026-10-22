// SPDX-License-Identifier: MPL-2.0
//
// FloeApp — real Notes/Canvas importer seams for system document intake
// (S5 P3).
//
// Notes and Canvas keep their existing ownership, limits and integrity:
// * `.floenote`, PDF, Office, text, image and engineering files go through
//   `NotesArchive` / `NoteFileImporter` into the real `NotesStore`.
// * `.floecanvas` goes through the real `WorkspaceCanvasRegistry` package
//   importer (staged ZIP verifier and legacy JSON path).
//
// The only addition is identity: every import is committed with an exact
// pre-allocated destination UUID, so a restart can prove whether the
// transaction committed without comparing titles or content. Notes uses the
// planned root document id; Canvas threads the planned id through the real
// backup restore so `WorkspaceCanvasRegistry.exists(canvasID:)` is the proof.
// An interrupted canvas import whose payload committed but whose registry
// write did not is recovered by removing only this attempt's owned partial
// payload and re-queuing — never by matching a title or hash.

#if canImport(SwiftUI) && canImport(UIKit)
import Foundation
import FloeCore
import FloeNotes

struct NotesImportOutcome: Sendable, Equatable {
    var rootDocumentID: UUID
    var documentIDs: [UUID]
    var title: String
}

protocol NotesDocumentImporting: Sendable {
    /// Returns the live stored document, nil only when the store is readable
    /// and the identity does not exist. A store failure throws.
    func existingDocument(id: UUID) async throws -> NoteDocument?
    func documentIDs(inBundle rootID: UUID) async throws -> [UUID]
    func importNotes(
        from url: URL,
        kind: DocumentIntakeKind,
        plannedRootID: UUID,
        displayName: String
    ) async throws -> NotesImportOutcome
}

struct LiveNotesDocumentImporter: NotesDocumentImporting {
    let storeProvider: @Sendable () async throws -> NotesStore

    static let live = LiveNotesDocumentImporter(
        storeProvider: { try await NotesRepository.shared.store() }
    )

    func existingDocument(id: UUID) async throws -> NoteDocument? {
        let store = try await storeProvider()
        do { return try await store.document(id) }
        catch NoteError.notFound { return nil }
    }

    func documentIDs(inBundle rootID: UUID) async throws -> [UUID] {
        let store = try await storeProvider()
        let root = try await store.document(rootID)
        return [rootID] + (root.linkedMindMaps ?? []).map(\.documentID)
    }

    func importNotes(
        from url: URL,
        kind: DocumentIntakeKind,
        plannedRootID: UUID,
        displayName: String
    ) async throws -> NotesImportOutcome {
        let store = try await storeProvider()
        switch kind {
        case .floeNote:
            let documents = try await NotesArchive.importDocuments(
                from: url,
                notebookID: nil,
                store: store
            )
            guard let importedRoot = documents.first else {
                throw DocumentIntakeError.damaged
            }
            guard !documents.dropFirst().contains(where: { $0.id == plannedRootID }) else {
                throw DocumentIntakeError.importFailed
            }
            let originalRootID = importedRoot.id
            var remapped = documents
            for index in remapped.indices {
                if remapped[index].id == originalRootID {
                    remapped[index].id = plannedRootID
                }
                Self.remapSources(in: &remapped[index], from: originalRootID, to: plannedRootID)
                try remapped[index].validate()
            }
            let created = try await store.createBundle(remapped)
            guard let createdRoot = created.first(where: { $0.id == plannedRootID }) else {
                throw DocumentIntakeError.importFailed
            }
            return NotesImportOutcome(
                rootDocumentID: createdRoot.id,
                documentIDs: created.map(\.id),
                title: createdRoot.title
            )
        default:
            var document = try await NoteFileImporter.importFile(
                url,
                notebookID: nil,
                store: store
            )
            document.id = plannedRootID
            // The staged copy intentionally has a generated name; the real
            // importer derives the title and Office/engineering file name from
            // it. Restore the user-visible identity without touching content.
            let base = (displayName as NSString).deletingPathExtension
                .trimmingCharacters(in: .whitespacesAndNewlines)
            document.title = base.isEmpty ? displayName : base
            let ext = url.pathExtension.lowercased()
            switch kind {
            case .office:
                document.officeFileName = Self.boundedFileName(stem: base, extension: ext)
            case .engineering:
                document.engineeringFileName = Self.boundedFileName(stem: base, extension: ext)
            default:
                break
            }
            try document.validate()
            let created = try await store.create(document)
            return NotesImportOutcome(
                rootDocumentID: created.id,
                documentIDs: [created.id],
                title: created.title
            )
        }
    }

    /// The engineering validator bounds the file name in UTF-8 bytes, not
    /// characters. Truncate the display stem so a long CJK name cannot fail
    /// validation after a successful content import.
    private static func boundedFileName(
        stem: String,
        extension ext: String,
        maximumBytes: Int = 240
    ) -> String {
        var value = stem
        while value.utf8.count + ext.utf8.count + 1 > maximumBytes, !value.isEmpty {
            value.removeLast()
        }
        value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.isEmpty { value = "Document" }
        return value + "." + ext
    }

    /// Rewrites only references to the exact root identity. Linked-map ids and
    /// resource ids from the real archive importer stay unchanged.
    private static func remapSources(
        in document: inout NoteDocument,
        from oldID: UUID,
        to newID: UUID
    ) {
        for pageIndex in document.pages.indices {
            for elementIndex in document.pages[pageIndex].elements.indices {
                guard var source = document.pages[pageIndex].elements[elementIndex].source,
                      source.documentID == oldID else { continue }
                source.documentID = newID
                document.pages[pageIndex].elements[elementIndex].source = source
            }
        }
        for nodeIndex in document.nodes.indices {
            if var source = document.nodes[nodeIndex].source, source.documentID == oldID {
                source.documentID = newID
                document.nodes[nodeIndex].source = source
            }
            guard var attachments = document.nodes[nodeIndex].attachments else { continue }
            for attachmentIndex in attachments.indices {
                guard var source = attachments[attachmentIndex].source,
                      source.documentID == oldID else { continue }
                source.documentID = newID
                attachments[attachmentIndex].source = source
            }
            document.nodes[nodeIndex].attachments = attachments
        }
    }
}

struct CanvasImportOutcome: Sendable, Equatable {
    var canvasID: UUID
    var name: String
}

protocol CanvasDocumentImporting: Sendable {
    /// Imports under the exact pre-allocated identity. A retry with the same
    /// planned id is idempotent by construction, never title/hash matching.
    func importCanvas(from url: URL, plannedCanvasID: UUID) async throws -> CanvasImportOutcome
    /// True when the durable registry project for this exact identity exists,
    /// i.e. the staged restore finalized. This is the crash-recovery proof.
    func canvasExists(id: UUID) async -> Bool
    /// Removes only the payload namespaces owned by an interrupted restore
    /// for this exact identity (native CAD folder, unapplied CAD drafts).
    /// Returns true when an owned partial payload existed and was removed.
    func removePartialRestoreArtifacts(canvasID: UUID) async -> Bool
}

struct LiveCanvasDocumentImporter: CanvasDocumentImporting {
    func importCanvas(from url: URL, plannedCanvasID: UUID) async throws -> CanvasImportOutcome {
        try await Task.detached(priority: .userInitiated) {
            let canvasID: UUID
            do {
                canvasID = try WorkspaceCanvasRegistry.importPackage(
                    from: url,
                    canvasID: plannedCanvasID
                )
            } catch let error as DocumentIntakeError {
                throw error
            } catch {
                throw DocumentIntakeError.importFailed
            }
            let name = WorkspaceCanvasRegistry.summaries()
                .first(where: { $0.id == canvasID })?.name ?? ""
            // Refresh the canvas library, exactly like an in-app change. This
            // is an observation signal, never an editor or project write.
            NotificationCenter.default.post(
                name: .floeCanvasProjectDidChange,
                object: nil,
                userInfo: ["canvasID": canvasID]
            )
            return CanvasImportOutcome(canvasID: canvasID, name: name)
        }.value
    }

    func canvasExists(id: UUID) async -> Bool {
        WorkspaceCanvasRegistry.exists(canvasID: id)
    }

    func removePartialRestoreArtifacts(canvasID: UUID) async -> Bool {
        WorkspaceCanvasRegistry.removePartialRestoreArtifacts(canvasID: canvasID)
    }
}
#endif
