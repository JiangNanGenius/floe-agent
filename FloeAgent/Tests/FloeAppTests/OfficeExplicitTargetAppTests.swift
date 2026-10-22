#if canImport(UIKit)
import Foundation
import Testing
import FloeCore
import FloeDocuments
@testable import FloeApp

@Suite("FloeApp.OfficeExplicitTargets")
@MainActor
struct OfficeExplicitTargetAppTests {
    @Test("exact sheet/range bridge sends native part selection before the range and engine operation")
    func bridgePlan() throws {
        let target = OfficeExplicitTarget(baseSHA256: String(repeating: "a", count: 64), member: "xl/worksheets/sheet7.xml", sheetName: "Actual Sheet", sheetIndex: 2)
        let raw = try OfficeCommandBridge.requestJSON([.explicit(.excelAutoFilter(target, range: "B2:C5"))])
        let object = try JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any]
        let commands = object?["commands"] as? [[String: Any]], steps = commands?.first?["steps"] as? [[String: Any]]
        #expect(steps?.first?["kind"] as? String == "selectPart")
        #expect(steps?.first?["index"] as? Int == 2)
        #expect(steps?[1]["name"] as? String == ".uno:GoToCell")
        #expect(steps?[2]["name"] as? String == ".uno:DataFilterAutoFilter")
    }
    @Test("package-prepared exact paragraph edits cannot masquerade as an empty successful native dispatch")
    func rejectUnpreparedDispatch() {
        let target = OfficeExplicitTarget(baseSHA256: String(repeating: "a", count: 64), member: "word/document.xml", paragraphIndex: 0)
        #expect(throws: (any Error).self) { try OfficeCommandBridge.requestJSON([.explicit(.wordAlignment(target, .left))]) }
    }
    @Test("saved-package proposal supports an exact range plus workbook recalculation without a visible editor")
    func savedProposal() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("office-proposal-\(UUID())")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let source = dir.appendingPathComponent("data.xlsx")
        try OfficeDocumentBuilder.createWorkbook(at: source, sheets: [.init(name: "First", rows: [["999"]]), .init(name: "Target", rows: [["2", "20"], ["1", "10"]])])
        let manifest = try OfficeExplicitTargets.read(url: source)
        let commands: [OfficeEngineCommand] = [.explicit(.excelSort(manifest.sheets[1], range: "A1:B2", ascending: true)), .excelRecalculate]
        let center = OfficeCommandCenter()
        let access = OfficeCommandAccess(environmentID: nil, workspacePath: dir.path, ownerKind: "workspace", ownerID: nil)
        let proposal = try await center.prepareProposal(documentID: "data.xlsx", baseSHA256: manifest.baseSHA256, summary: "Exact target", commandsJSON: OfficeCommandCodec.encode(commands), access: access)
        try await center.storeProposal(proposal)
        #expect(proposal.selectionFingerprint == nil)
        #expect(try await center.loadProposal(id: proposal.id, access: access) == proposal)
        await #expect(throws: (any Error).self) { try await center.apply(proposal: proposal, grantID: "invented", requestID: "wrong-route", access: access) }
    }
}
#endif
