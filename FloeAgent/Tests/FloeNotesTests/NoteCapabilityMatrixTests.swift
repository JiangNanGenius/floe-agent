// FloeNotesTests — truthful capability matrix and export selection (Build265).
import Foundation
import Testing
@testable import FloeNotes

@Suite("Notes capability matrix")
struct NoteCapabilityMatrixTests {
    @Test("every tier and tool claim is internally truthful")
    func matrixTruthfulness() throws {
        let snapshot = NoteCapabilityMatrix.snapshot()
        #expect(snapshot.kind == "notes")
        #expect(Set(snapshot.tiers.keys) == Set(NoteCapabilityMatrix.Tier.allCases.map(\.rawValue)))
        #expect(Set(snapshot.readSections) == Set(NoteCapabilityMatrix.readSections))
        #expect(snapshot.readSections.contains("capabilities"))
        #expect(Set(snapshot.editActions) == Set(NoteCapabilityMatrix.editActions))

        let ids = snapshot.capabilities.map(\.id)
        #expect(Set(ids).count == ids.count, "capability ids are unique")
        for capability in snapshot.capabilities {
            switch capability.tier {
            case .implemented:
                #expect(capability.tool != nil || capability.path == "editor-ui" || capability.path == "native-index",
                        "\(capability.id) must name its tool")
            case .delegated:
                #expect(capability.tool?.hasPrefix("document.pdf.") == true,
                        "\(capability.id) must delegate to a workspace PDF tool")
            case .unavailable:
                #expect(capability.tool == nil && capability.actions == nil,
                        "\(capability.id) claims a tool for an unavailable capability")
            }
            #expect(!capability.detail.isEmpty)
        }

        let implementedTools = Set(snapshot.capabilities.filter { $0.tier == .implemented }.compactMap(\.tool))
        #expect(implementedTools == [
            "notes.search", "notes.read", "notes.edit", "notes.export", "notes.attachFile", "notes.stageAttachment"
        ])
        let delegatedTools = Set(snapshot.capabilities.filter { $0.tier == .delegated }.compactMap(\.tool))
        #expect(delegatedTools == [
            "document.pdf.inspect", "document.pdf.render", "document.pdf.edit",
            "document.pdf.export", "document.pdf.fillForm"
        ])
        #expect(snapshot.capabilities.first { $0.id == "applyProposal" }?.uiConfirmationRequired == true)
        #expect(snapshot.capabilities.first { $0.id == "pdfOriginalTextEdit" }?.tier == .unavailable)

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let json = String(decoding: try encoder.encode(snapshot), as: UTF8.self)
        #expect(json.contains("\"unavailable\""))
        #expect(json.contains("notes.export"))
        #expect(json.contains("ui-accept-grant"))
    }
}

@Suite("Notes export selection")
struct NoteExportSelectionTests {
    @Test("pages follow the requested order and default to the whole document")
    func selectionOrderAndDefault() throws {
        var document = NoteDocument(title: "导出")
        var second = NotePage()
        var third = NotePage()
        try NoteEdit.insertPage(second, at: 1).apply(to: &document)
        try NoteEdit.insertPage(third, at: 2).apply(to: &document)
        second = document.pages[1]
        third = document.pages[2]

        #expect(try NoteExportSelection.pages(of: document, pageIDs: nil).map(\.id) == document.pages.map(\.id))
        #expect(try NoteExportSelection.pages(of: document, pageIDs: [third.id, document.pages[0].id]).map(\.id)
            == [third.id, document.pages[0].id])
        #expect(try NoteExportSelection.pages(of: document, pageIDs: []).count == 3)
    }

    @Test("duplicates, unknown pages, non-notebooks and oversized requests fail closed")
    func selectionRejectsInvalidRequests() throws {
        let document = NoteDocument(title: "导出")
        let pageID = document.pages[0].id
        #expect(throws: (any Error).self) {
            try NoteExportSelection.pages(of: document, pageIDs: [pageID, pageID])
        }
        #expect(throws: (any Error).self) {
            try NoteExportSelection.pages(of: document, pageIDs: [UUID()])
        }
        #expect(throws: (any Error).self) {
            try NoteExportSelection.pages(of: NoteDocument(kind: .office, title: "表格"), pageIDs: nil)
        }
        var large = NoteDocument(title: "大文档")
        let extra = (1...NoteExportSelection.maximumPages).map { _ in NotePage() }
        large.pages.append(contentsOf: extra)
        #expect(throws: (any Error).self) {
            try NoteExportSelection.pages(of: large, pageIDs: large.pages.map(\.id))
        }
    }
}
