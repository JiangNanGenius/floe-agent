import Foundation
import Testing
import ZIPFoundation
@testable import FloeDocuments

@Suite("FloeDocuments.NativeSaveValidation")
struct OfficeNativeSaveValidationTests {
    private func fixture(_ url: URL, dataLink: Bool = true, payload: Bool = true,
                         formula: String = "Sheet1!$A$1", prefix: String = "r") throws {
        let book = url.deletingLastPathComponent().appendingPathComponent(UUID().uuidString + ".xlsx")
        defer { try? FileManager.default.removeItem(at: book) }
        try OfficeDocumentBuilder.createWorkbook(at: book, sheets: [.init(name: "Sheet1", rows: [["12"]])])
        let archive = try Archive(url: url, accessMode: .create)
        let external = dataLink ? "<c:externalData \(prefix):id=\"data\"/>" : ""
        let chart = "<c:chartSpace xmlns:c=\"http://schemas.openxmlformats.org/drawingml/2006/chart\" xmlns:\(prefix)=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships\"><c:chart><c:numRef><c:f>\(formula)</c:f></c:numRef></c:chart>\(external)</c:chartSpace>"
        try archive.addFloeEntry(path: "ppt/charts/chart1.xml", data: Data(chart.utf8))
        let relationships = "<Relationships xmlns=\"http://schemas.openxmlformats.org/package/2006/relationships\"><Relationship Id=\"data\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/package\" Target=\"../embeddings/data.xlsx\"/></Relationships>"
        try archive.addFloeEntry(path: "ppt/charts/_rels/chart1.xml.rels", data: Data(relationships.utf8))
        if payload { try archive.addFloeEntry(path: "ppt/embeddings/data.xlsx", data: Data(contentsOf: book)) }
    }

    @Test("embedded chart data and namespace aliases remain saveable")
    func validData() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        for prefix in ["r", "relationship"] {
            let file = root.appendingPathComponent(prefix + ".pptx")
            try fixture(file, prefix: prefix)
            try OfficeNativeSaveValidation.validate(file)
        }
    }

    @Test("lost workbook and internal model references are rejected")
    func failedData() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        for (index, options) in [(false, true, "Sheet1!$A$1"), (true, false, "Sheet1!$A$1"),
                                  (true, true, "0"), (true, true, "label 0")].enumerated() {
            let file = root.appendingPathComponent("bad-\(index).pptx")
            try fixture(file, dataLink: options.0, payload: options.1, formula: options.2)
            #expect(throws: (any Error).self) { try OfficeNativeSaveValidation.validate(file) }
        }
    }

    #if canImport(Darwin)
    @Test("failed native export preserves original and recovery and cannot be exported as saved")
    func failedSavePreservesFiles() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let original = root.appendingPathComponent("original.pptx")
        try fixture(original)
        let originalBytes = try Data(contentsOf: original)
        let workspace = try SecurityScopedDocumentWorkspace(root: root.appendingPathComponent("sessions"))
        let session = try await workspace.open(securityScopedURL: original)
        let broken = root.appendingPathComponent("broken.pptx")
        try fixture(broken, dataLink: false)
        let brokenBytes = try Data(contentsOf: broken)
        try brokenBytes.write(to: session.workingURL, options: .atomic)
        await #expect(throws: (any Error).self) { try await workspace.save(session) }
        #expect(try Data(contentsOf: original) == originalBytes)
        #expect(try Data(contentsOf: session.recoveryURL) == brokenBytes)
        await #expect(throws: (any Error).self) { try await workspace.prepareExport(session) }
    }
    #endif
}
