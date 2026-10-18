// SPDX-License-Identifier: MPL-2.0
import Foundation
import Testing
@testable import FloeNotes

@Suite("Office generated preview ownership")
struct OfficeGeneratedPreviewTests {
    private static let png = Data(base64Encoded:
        "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==")!

    private func fixture() async throws -> (NotesStore, URL, NoteDocument, UUID) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("office-preview-\(UUID())")
        let store = try NotesStore(root: root)
        let source = try await asset(Data("Synthetic Office resource A".utf8), store: store, root: root)
        let preview = try await asset(Self.png, type: "image/png", store: store, root: root)
        var document = NoteDocument(kind: .office, title: "Synthetic Office note")
        document.officeResourceID = source; document.officeFileName = "Synthetic.docx"
        return (store, root, try await store.create(document), preview)
    }

    private func asset(_ data: Data, type: String = "application/octet-stream",
                       store: NotesStore, root: URL) async throws -> UUID {
        let url = root.appendingPathComponent(UUID().uuidString)
        try data.write(to: url); defer { try? FileManager.default.removeItem(at: url) }
        return try await store.importResource(from: url, mediaType: type)
    }

    @Test func previewPersistsWithoutChangingContentOrHistory() async throws {
        let (store, root, document, preview) = try await fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let history = try await store.historyState(document.id)
        let value = try await store.cacheOfficePreview(documentID: document.id,
            sourceResourceID: document.officeResourceID!, previewResourceID: preview, expectedRevision: document.revision)
        #expect(value.revision == document.revision)
        #expect(value.updatedAt == document.updatedAt)
        #expect(value.matchingOfficePreviewResourceID == preview)
        #expect(value.resourceIDs.contains(preview))
        #expect(value.coverCacheToken != document.coverCacheToken)
        let after = try await store.historyState(document.id)
        #expect(after.canUndo == history.canUndo && after.canRedo == history.canRedo)
        let reopened = try await NotesStore(root: root).document(document.id)
        #expect(reopened.matchingOfficePreviewResourceID == preview)
        #expect(reopened.officePreviewSourceID == document.officeResourceID)
    }

    @Test func changedOfficeBytesInvalidateAndRejectLatePreview() async throws {
        let (store, root, document, preview) = try await fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try await store.cacheOfficePreview(documentID: document.id,
            sourceResourceID: document.officeResourceID!, previewResourceID: preview, expectedRevision: document.revision)
        let replacement = try await asset(Data("Synthetic Office resource B".utf8), store: store, root: root)
        let changed = try await store.apply(.init(documentID: document.id, expectedRevision: document.revision,
            title: "Replace source", edits: [.replaceOfficeResource(replacement)]))
        #expect(changed.matchingOfficePreviewResourceID == nil)
        #expect(changed.officePreviewSourceID == nil && changed.officePreviewResourceID == nil)
        do {
            _ = try await store.cacheOfficePreview(documentID: document.id,
                sourceResourceID: document.officeResourceID!, previewResourceID: preview, expectedRevision: changed.revision)
            Issue.record("A late render must not attach to other Office bytes")
        } catch NoteError.conflict { }
        let final = try await store.document(document.id)
        #expect(final.officeResourceID == replacement && final.matchingOfficePreviewResourceID == nil)
    }

    @Test func customCoverWinsAndRestoringAutomaticUsesSavedPreview() async throws {
        let (store, root, document, preview) = try await fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        var customBytes = Self.png; customBytes.append(0)
        let custom = try await asset(customBytes, type: "image/png", store: store, root: root)
        let chosen = try await store.applyCoverCommand(.useResource(custom), documentID: document.id,
            expectedRevision: document.revision, expectedCoverRevision: 0)
        let cached = try await store.cacheOfficePreview(documentID: document.id,
            sourceResourceID: document.officeResourceID!, previewResourceID: preview, expectedRevision: chosen.revision)
        #expect(cached.coverMode == .custom(custom))
        #expect(cached.coverCacheToken == chosen.coverCacheToken)
        #expect(cached.coverRevision == chosen.coverRevision)
        let restored = try await store.applyCoverCommand(.restoreAutomatic, documentID: document.id,
            expectedRevision: cached.revision, expectedCoverRevision: cached.normalizedCoverRevision)
        #expect(restored.coverMode == .automatic && restored.matchingOfficePreviewResourceID == preview)
        #expect(restored.coverCacheToken.contains(preview.uuidString))
    }

    @Test func staleRevisionAndNonImageCannotReplacePreview() async throws {
        let (store, root, document, preview) = try await fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        do {
            _ = try await store.cacheOfficePreview(documentID: document.id,
                sourceResourceID: document.officeResourceID!, previewResourceID: preview, expectedRevision: document.revision + 1)
            Issue.record("Stale metadata writer must conflict")
        } catch NoteError.conflict { }
        do {
            _ = try await store.cacheOfficePreview(documentID: document.id,
                sourceResourceID: document.officeResourceID!, previewResourceID: document.officeResourceID!, expectedRevision: document.revision)
            Issue.record("A document resource is not an image preview")
        } catch NoteError.resourceUnavailable { }
        let final = try await store.document(document.id)
        #expect(final.matchingOfficePreviewResourceID == nil && final.revision == document.revision)
    }

    @Test func contentUndoDoesNotLoseNewerPreviewOfSameBytes() async throws {
        let (store, root, document, preview) = try await fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let renamed = try await store.apply(.init(documentID: document.id, expectedRevision: document.revision,
            title: "Rename", edits: [.rename("New title")]))
        _ = try await store.cacheOfficePreview(documentID: document.id,
            sourceResourceID: document.officeResourceID!, previewResourceID: preview, expectedRevision: renamed.revision)
        let undone = try await store.undo(document.id, expectedRevision: renamed.revision)
        #expect(undone.title == document.title)
        #expect(undone.matchingOfficePreviewResourceID == preview)
        #expect(undone.resourceIDs.contains(preview))
    }

    @Test func legacyDecodeAndMismatchedCacheStayAutomatic() throws {
        var document = NoteDocument(kind: .office, title: "Legacy")
        document.officeResourceID = UUID(); document.officeFileName = "Legacy.docx"
        let data = try JSONEncoder().encode(document)
        #expect(try JSONDecoder().decode(NoteDocument.self, from: data).matchingOfficePreviewResourceID == nil)
        document.officePreviewSourceID = UUID(); document.officePreviewResourceID = UUID()
        #expect(document.matchingOfficePreviewResourceID == nil)
        #expect(document.coverCacheToken == "auto@0")
        #expect(!document.resourceIDs.contains(document.officePreviewResourceID!))
    }

    @Test func archiveRemapsPreviewAndItsSourceTogether() async throws {
        let (store, root, document, preview) = try await fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let cached = try await store.cacheOfficePreview(documentID: document.id,
            sourceResourceID: document.officeResourceID!, previewResourceID: preview, expectedRevision: document.revision)
        let archive = root.appendingPathComponent("preview.floenote")
        try await NotesArchive.export(document: cached, store: store, to: archive)
        let other = try NotesStore(root: root.appendingPathComponent("other"))
        let restored = try await NotesArchive.importDocument(from: archive, notebookID: nil, store: other)
        #expect(restored.officeResourceID != cached.officeResourceID)
        #expect(restored.officePreviewSourceID == restored.officeResourceID)
        let imageID = try #require(restored.matchingOfficePreviewResourceID)
        let bytes = try Data(contentsOf: await other.resourceURL(imageID))
        #expect(bytes == Self.png)
    }
}
