// FloeDocuments — Office open-mode memory contract tests.
//
// SPDX-License-Identifier: MPL-2.0

import Foundation
import Testing
@testable import FloeDocuments

@Suite("Office document open-mode memory")
struct OfficeDocumentModeMemoryTests {
    @Test("A document never entered opens in preview")
    func firstEntryDefaultsToPreview() {
        let memory = OfficeDocumentModeMemory()
        let key = OfficeDocumentModeMemory.scopedKey(scope: "notes-doc-1", document: "report.docx")
        #expect(!memory.hasOpened(forKey: key))
        #expect(memory.resolvedMode(forKey: key) == .preview)
    }

    @Test("From the second entry onwards the document opens in the editor, even when the first visit only previewed")
    func secondEntryDefaultsToEdit() {
        let key = OfficeDocumentModeMemory.scopedKey(scope: "notes-doc-1", document: "report.docx")
        var memory = OfficeDocumentModeMemory()
        // First entry: preview.
        #expect(memory.resolvedMode(forKey: key) == .preview)
        // The preview completed; the user never tapped Edit.
        memory.markOpened(forKey: key)
        // Second entry: editor, by entry count alone.
        #expect(memory.hasOpened(forKey: key))
        #expect(memory.resolvedMode(forKey: key) == .edit)
    }

    @Test("The remembered entry survives an encode/decode round trip")
    func openedRoundTrips() throws {
        let key = OfficeDocumentModeMemory.scopedKey(scope: "notes-doc-1", document: "report.docx")
        var memory = OfficeDocumentModeMemory()
        memory.markOpened(forKey: key)

        // Persist exactly as the App does, then read it back through the
        // untrusted-data initializer.
        let data = try #require(memory.snapshotData)
        let reloaded = OfficeDocumentModeMemory(data: data)
        #expect(reloaded.hasOpened(forKey: key))
        #expect(reloaded.resolvedMode(forKey: key) == .edit)
        // A different document in the same scope still previews first.
        let other = OfficeDocumentModeMemory.scopedKey(scope: "notes-doc-1", document: "budget.xlsx")
        #expect(reloaded.resolvedMode(forKey: other) == .preview)
    }

    @Test("Corrupt or unknown persisted payloads degrade to an empty memory")
    func corruptPayloadIsIgnored() {
        #expect(OfficeDocumentModeMemory(data: Data("not json".utf8)).isEmpty)
        #expect(OfficeDocumentModeMemory(data: nil).isEmpty)
        // A future/unknown version is not misread as the current shape.
        let future = Data(#"{"version":2,"seen":["mode-abc"]}"#.utf8)
        #expect(OfficeDocumentModeMemory(data: future).isEmpty)
        // A blank entry inside an otherwise valid payload is dropped, not
        // kept as a catch-all.
        let partial = Data(#"{"version":1,"seen":["mode-abc","   "]}"#.utf8)
        let decoded = OfficeDocumentModeMemory(data: partial)
        #expect(decoded.hasOpened(forKey: "mode-abc"))
        #expect(!decoded.hasOpened(forKey: " "))
    }

    @Test("Same scope and document fold to one stable key; different scopes do not")
    func keyIsStableAndScoped() {
        let a = OfficeDocumentModeMemory.scopedKey(scope: "notes-doc-1", document: "report.docx")
        let aRepeat = OfficeDocumentModeMemory.scopedKey(scope: "notes-doc-1", document: "report.docx")
        let b = OfficeDocumentModeMemory.scopedKey(scope: "notes-doc-2", document: "report.docx")
        let unscoped = OfficeDocumentModeMemory.scopedKey(scope: nil, document: "report.docx")
        #expect(a == aRepeat)
        #expect(a != b)
        #expect(a != unscoped)
        #expect(!a.contains("report.docx"))
        #expect(!a.contains("notes-doc-1"))
        #expect(a.count <= 32)
    }

    @Test("Per-document entries stay isolated and a blank key is never written")
    func entriesAreIsolatedPerDocument() {
        let first = OfficeDocumentModeMemory.scopedKey(scope: "notes-doc-1", document: "report.docx")
        let second = OfficeDocumentModeMemory.scopedKey(scope: "notes-doc-1", document: "budget.xlsx")
        var memory = OfficeDocumentModeMemory()
        memory.markOpened(forKey: first)
        #expect(memory.resolvedMode(forKey: first) == .edit)
        #expect(memory.resolvedMode(forKey: second) == .preview)

        let before = memory.snapshotData
        memory.markOpened(forKey: "   ")
        #expect(memory.snapshotData == before)
        #expect(!String(decoding: memory.snapshotData ?? Data(), as: UTF8.self).contains("untitled"))
    }

    @Test("A draft-copy directory cannot rebind a Notes document")
    func draftCopyDirectoryDoesNotRebind() {
        // Notes stages every open into a fresh UUID folder; the memory key is
        // derived from the Notes document identity, not that transient path.
        var memory = OfficeDocumentModeMemory()
        let key = OfficeDocumentModeMemory.scopedKey(scope: "notes-doc-9", document: "notes.docx")
        memory.markOpened(forKey: key)
        let otherDraftKey = OfficeDocumentModeMemory.scopedKey(
            scope: "notes-doc-9", document: "/tmp/drafts/\(UUID().uuidString)/notes.docx")
        #expect(otherDraftKey != key)
        #expect(memory.resolvedMode(forKey: key) == .edit)
        #expect(memory.resolvedMode(forKey: otherDraftKey) == .preview)
    }
}
