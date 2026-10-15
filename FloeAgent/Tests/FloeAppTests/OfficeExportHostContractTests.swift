// FloeAppTests — the Office export host contract (K4 F5).
//
// `document.office.edit` `export` promises that "an existing different file is
// never overwritten". These tests pin that promise at the REAL App host
// (`OfficeCommandCenter.export`): a new output is committed atomically, an
// existing file with different bytes is preserved and the export is refused,
// and an already byte-identical output is an idempotent receipt without a
// rewrite. No engine, UI or simulator interaction is required.
//
// Resource provenance: `office-native-real-budget.xlsx` is the synthetic Floe
// promo fixture already bundled for FloeAppTests (same fixture as
// `OfficeNativeAutomaticExecutionTests`; sha256
// d528d356a062065d0d626927ca78403f1ed492796810e73934db91f3362f40a7, generic
// English budget labels only).

#if canImport(UIKit)
import Foundation
import Testing
import FloeCore
import FloeDocuments
@testable import FloeApp

private final class OfficeExportHostTestBundleToken {}

@Suite("FloeApp.OfficeExportHostContract")
struct OfficeExportHostContractTests {
    private func fixtureData() throws -> Data {
        let bundle = Bundle(for: OfficeExportHostTestBundleToken.self)
        guard let url = bundle.url(forResource: "office-native-real-budget",
                                   withExtension: "xlsx") else {
            throw FloeError.notFound("bundled Office fixture office-native-real-budget.xlsx")
        }
        return try Data(contentsOf: url)
    }

    private func makeRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("office-export-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func access(root: URL) -> OfficeCommandAccess {
        OfficeCommandAccess(environmentID: "test", workspacePath: root.path,
                            ownerKind: "workspace", ownerID: nil, conversationID: nil)
    }

    @Test("a new export is committed and the source is unchanged")
    func newExportCommits() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let original = try fixtureData()
        let source = root.appendingPathComponent("report.xlsx")
        try original.write(to: source)

        let center = OfficeCommandCenter()
        let receipt = try await center.export(documentID: "report.xlsx",
                                              relativeOutput: "out/report-copy.xlsx",
                                              access: access(root: root))
        #expect(receipt.relativePath == "out/report-copy.xlsx")
        #expect(receipt.sha256 == FloeDigest.sha256Hex(original))
        #expect(try Data(contentsOf: root.appendingPathComponent("out/report-copy.xlsx")) == original)
        #expect(try Data(contentsOf: source) == original,
                "the source document is never modified by an export")
    }

    @Test("an existing file with different bytes is preserved and the export is refused")
    func existingDifferentFilePreserved() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let original = try fixtureData()
        try original.write(to: root.appendingPathComponent("report.xlsx"))
        let existing = root.appendingPathComponent("out.xlsx")
        let userBytes = Data("existing user bytes".utf8)
        try userBytes.write(to: existing)

        let center = OfficeCommandCenter()
        do {
            _ = try await center.export(documentID: "report.xlsx",
                                        relativeOutput: "out.xlsx",
                                        access: access(root: root))
            Issue.record("an existing different file must never be replaced by an export")
        } catch {
            #expect(error.localizedDescription.contains("never overwrites"),
                    "the refusal must state the no-overwrite contract: \(error)")
        }
        #expect(try Data(contentsOf: existing) == userBytes,
                "the existing file must be preserved byte-for-byte")
    }

    @Test("an already byte-identical output is an idempotent receipt, not a rewrite")
    func identicalOutputIsIdempotent() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let original = try fixtureData()
        try original.write(to: root.appendingPathComponent("report.xlsx"))
        let existing = root.appendingPathComponent("out.xlsx")
        try original.write(to: existing)

        let center = OfficeCommandCenter()
        let receipt = try await center.export(documentID: "report.xlsx",
                                              relativeOutput: "out.xlsx",
                                              access: access(root: root))
        #expect(receipt.sha256 == FloeDigest.sha256Hex(original))
        #expect(receipt.note?.contains("already exported") == true,
                "an identical existing copy is reported as an idempotent completion")
        #expect(try Data(contentsOf: existing) == original)
    }
}
#endif
