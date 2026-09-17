// SPDX-License-Identifier: MPL-2.0
import Foundation
import Testing
import FloeNotes

/// Focused model coverage for the engineering/CAD note kind. These tests do not
/// start a viewer and do not require a device.
@Suite("Notes engineering documents")
struct NoteEngineeringModelTests {
    @Test func existingKindRawValuesArePreserved() {
        #expect(NoteDocument.Kind(rawValue: "notebook") == .notebook)
        #expect(NoteDocument.Kind(rawValue: "mindMap") == .mindMap)
        #expect(NoteDocument.Kind(rawValue: "office") == .office)
        #expect(NoteDocument.Kind(rawValue: "engineering") == .engineering)
    }

    @Test func legacyDocumentWithoutEngineeringKeysStillDecodes() throws {
        var value = NoteDocument(title: "旧手记")
        value.revision = 1
        var data = try JSONEncoder().encode(value)
        var object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        object.removeValue(forKey: "engineeringResourceID")
        object.removeValue(forKey: "engineeringFileName")
        data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        let decoded = try JSONDecoder().decode(NoteDocument.self, from: data)
        try decoded.validate()
        #expect(decoded.kind == .notebook)
        #expect(decoded.engineeringResourceID == nil)
        #expect(decoded.engineeringFileName == nil)
    }

    @Test func engineeringDocumentValidatesAndRetainsResource() throws {
        let resource = UUID()
        var value = NoteDocument(kind: .engineering, title: "零件")
        value.revision = 1
        value.engineeringResourceID = resource
        value.engineeringFileName = "part.dxf"
        try value.validate()
        #expect(value.resourceIDs.contains(resource))
        let round = try JSONDecoder().decode(NoteDocument.self, from: JSONEncoder().encode(value))
        try round.validate()
        #expect(round.kind == .engineering)
        #expect(round.engineeringResourceID == resource)
        #expect(round.engineeringFileName == "part.dxf")
    }

    @Test func engineeringValidationRejectsUnsupportedOrUnsafeNames() {
        func make(_ name: String?) -> NoteDocument {
            var value = NoteDocument(kind: .engineering, title: "x")
            value.revision = 1
            value.engineeringResourceID = UUID()
            value.engineeringFileName = name
            return value
        }
        #expect(throws: NoteError.self) { try make(nil).validate() }
        #expect(throws: NoteError.self) { try make("drawing.kicad_pcb").validate() }
        #expect(throws: NoteError.self) { try make("part.exe").validate() }
        #expect(throws: NoteError.self) { try make("../part.dxf").validate() }
        #expect(throws: NoteError.self) { try make("folder/part.dxf").validate() }
        #expect(throws: NoteError.self) { try make("part.dxf ").validate() }
    }

    @Test func engineeringFormatAllowListMatchesSupportedViewers() {
        #expect(NoteDocument.isSupportedEngineeringFileName("BOARD.DXF"))
        #expect(NoteDocument.isSupportedEngineeringFileName("model.stl"))
        #expect(NoteDocument.isSupportedEngineeringFileName("plate.step"))
        #expect(!NoteDocument.isSupportedEngineeringFileName("board.kicad_pcb"))
        #expect(!NoteDocument.isSupportedEngineeringFileName("report.pdf"))
        #expect(!NoteDocument.isSupportedEngineeringFileName(""))
    }

    @Test func nonEngineeringKindsRejectEngineeringFields() {
        var value = NoteDocument(title: "n")
        value.revision = 1
        value.engineeringResourceID = UUID()
        value.engineeringFileName = "part.dxf"
        #expect(throws: NoteError.self) { try value.validate() }
    }

    /// Real archive roundtrip: the imported document must reference the copied
    /// resource, not the source resource ID, and the bytes must stay readable.
    @Test func engineeringArchiveRoundTripRestoresReadableResource() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("notes-engineering-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = try NotesStore(root: root.appendingPathComponent("source"))
        let bytes = Data("ISO-10303-21; HEADER; engineering fixture 24680".utf8)
        let fixture = root.appendingPathComponent("part.step")
        try bytes.write(to: fixture)
        let resource = try await source.importResource(from: fixture, mediaType: "application/octet-stream")
        var value = NoteDocument(kind: .engineering, title: "零件")
        value.engineeringResourceID = resource
        value.engineeringFileName = "part.step"
        let saved = try await source.create(value)

        let archive = root.appendingPathComponent("part.floenote")
        try await NotesArchive.export(document: saved, store: source, to: archive)

        let destination = try NotesStore(root: root.appendingPathComponent("destination"))
        let draft = try await NotesArchive.importDocument(from: archive, notebookID: nil, store: destination)
        let imported = try await destination.create(draft)
        #expect(imported.id != saved.id)
        #expect(imported.kind == .engineering)
        #expect(imported.engineeringFileName == "part.step")
        let restored = try #require(imported.engineeringResourceID)
        #expect(restored != resource)
        #expect(imported.resourceIDs == [restored])
        let restoredURL = try await destination.resourceURL(restored)
        #expect(try Data(contentsOf: restoredURL) == bytes)
    }

    /// An archive written before engineering existed (no engineering keys) still
    /// imports as a plain notebook document.
    @Test func legacyNotebookArchiveStillImportsWithoutEngineeringFields() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("notes-engineering-legacy-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = try NotesStore(root: root.appendingPathComponent("source"))
        let saved = try await source.create(NoteDocument(title: "旧手记"))
        let archive = root.appendingPathComponent("legacy.floenote")
        try await NotesArchive.export(document: saved, store: source, to: archive)
        let destination = try NotesStore(root: root.appendingPathComponent("destination"))
        let imported = try await NotesArchive.importDocument(from: archive, notebookID: nil, store: destination)
        #expect(imported.kind == .notebook)
        #expect(imported.engineeringResourceID == nil)
        #expect(imported.engineeringFileName == nil)
    }
}
