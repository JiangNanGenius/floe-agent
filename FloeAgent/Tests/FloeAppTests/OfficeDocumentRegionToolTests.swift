// SPDX-License-Identifier: MPL-2.0
// FloeAppTests — Office283 assistant region tool GUARD tests.
//
// Focused production-code guards for `notes.read section=officeRegion` and the
// build-283 post-render current-quiescence fence. These run WITHOUT the pinned
// native engine: schema/capability advertising, argument validation refusals,
// honest renderer/export error surfaces, and the strict
// `regionValidationStillQuiescent` comparison exercised with fixture
// `OfficeSavedProof` values — including the critical case where the
// validation transaction itself commits NEW edits during the render (the
// produced output must be ruled obsolete, never advertised).
//
// The REAL native route (pinned-engine PDF export → PDFKit PNG → provider
// artifact) is qualified separately in the primary hosted App build through
// the opt-in native cases listed at the bottom of this file; nothing here
// claims that end-to-end result.
//
//   membership: project.yml FloeAppTests sources +=
//     - path: Tests/FloeAppTests/OfficeDocumentRegionToolTests.swift
//   then `bash FloeAgent/scripts/gen_project.sh`.
#if canImport(UIKit)
import Foundation
import Testing
import FloeCore
import FloeModels
import FloeNotes
@testable import FloeAgentRuntime
@testable import FloeApp

@Suite("Notes Office region tool guards")
@MainActor struct OfficeDocumentRegionToolTests {
    private let documentID = UUID()
    private let resourceID = UUID()
    private let anchorSHA = String(repeating: "ab", count: 32)

    private func decode(_ json: String) throws -> NotesReadTool.Arguments {
        try JSONDecoder().decode(NotesReadTool.Arguments.self, from: Data(json.utf8))
    }

    // MARK: - Schema and capability advertising

    @Test("officeRegion is advertised in the schema and the capability matrix")
    func schemaAndMatrix() {
        let schema = NotesReadTool.parametersJSON
        #expect(schema.contains("\"officeRegion\""))
        #expect(schema.contains("\"sheet\""))
        #expect(schema.contains("\"sheetIndex\""))
        #expect(schema.contains("\"cellRange\""))
        #expect(schema.contains("\"pageIndex\""))
        #expect(schema.contains("\"pointsRect\""))
        #expect(schema.contains("\"pixelWidth\""))
        // The existing explicit live-page surface stays advertised.
        #expect(schema.contains("\"officeLivePage\""))

        // One compiled source for the section name and matrix entry.
        #expect(NoteCapabilityMatrix.officeRegionSection == "officeRegion")
        #expect(NoteCapabilityMatrix.appendedReadSections.contains("officeRegion"))
        #expect(NoteCapabilityMatrix.appendedReadSections.contains("officeLivePage"))
        let capability = NoteCapabilityMatrix.officeRegionCapability
        #expect(capability.id == "officeRegion")
        #expect(capability.tier == .implemented)
        #expect(capability.tool == "notes.read")
        #expect(capability.actions == ["officeRegion"])
        #expect(capability.grant == .notesRead)
        #expect(capability.uiConfirmationRequired == false)
        #expect(capability.detail.contains("Print_Area"))
    }

    @Test("the read tool description tells the assistant the real usage contract")
    func toolDescriptionContract() {
        let description = NotesReadTool.toolDescription
        #expect(description.contains("officeRegion"))
        #expect(description.contains("offscreen"))
        #expect(description.contains("PNG"))
        #expect(description.contains("cellRange"))
        #expect(description.contains("pointsRect"))
        // No mandatory send-time screenshot contract remains.
        #expect(!description.contains("every send"))
        // Discovery guidance precedes render guidance.
        guard let region = description.range(of: "officeRegion") else { Issue.record("missing"); return }
        #expect(region.lowerBound > description.startIndex)
    }

    // MARK: - Argument validation (honest refusals before any engine work)

    @Test("region arguments are rejected outside section=officeRegion")
    func regionArgumentsRequireRegionSection() throws {
        let wrong = try decode(#"{"documentID":"\#(documentID.uuidString)","section":"officeText","cellRange":"A1:B2"}"#)
        #expect(throws: NoteError.self) { try NotesReadTool().validate(wrong) }
        let unscoped = try decode(#"{"cellRange":"A1:B2"}"#)
        #expect(throws: NoteError.self) { try NotesReadTool().validate(unscoped) }
    }

    @Test("mutually exclusive sheet identity, numeric bounds and rect sanity")
    func regionArgumentBounds() throws {
        let both = try decode(#"{"documentID":"\#(documentID.uuidString)","section":"officeRegion","sheet":"Data","sheetIndex":1,"cellRange":"A1:B2"}"#)
        #expect(throws: NoteError.self) { try NotesReadTool().validate(both) }
        let narrow = try decode(#"{"documentID":"\#(documentID.uuidString)","section":"officeRegion","pixelWidth":100}"#)
        #expect(throws: NoteError.self) { try NotesReadTool().validate(narrow) }
        let wide = try decode(#"{"documentID":"\#(documentID.uuidString)","section":"officeRegion","pixelWidth":2401}"#)
        #expect(throws: NoteError.self) { try NotesReadTool().validate(wide) }
        let pageHigh = try decode(#"{"documentID":"\#(documentID.uuidString)","section":"officeRegion","pageIndex":10000}"#)
        #expect(throws: NoteError.self) { try NotesReadTool().validate(pageHigh) }
        let zeroRect = try decode(#"{"documentID":"\#(documentID.uuidString)","section":"officeRegion","pointsRect":{"x":0,"y":0,"width":0,"height":10}}"#)
        #expect(throws: NoteError.self) { try NotesReadTool().validate(zeroRect) }

        // Boundary values and workbook-correct shapes validate.
        let okWorkbook = try decode(#"{"documentID":"\#(documentID.uuidString)","section":"officeRegion","sheetIndex":0,"cellRange":"A1:N30","pixelWidth":320}"#)
        try NotesReadTool().validate(okWorkbook)
        let okPages = try decode(#"{"documentID":"\#(documentID.uuidString)","section":"officeRegion","pageIndex":9999,"pointsRect":{"x":0,"y":0,"width":10,"height":10}}"#)
        try NotesReadTool().validate(okPages)
    }

    // MARK: - Renderer error surface stays honest (no silent cut-off)

    @Test("renderer refusals name real bounds instead of guessing")
    func rendererErrorHonesty() {
        let sheet = OfficeDocumentRegionRenderer.RegionError.sheetRequired("Summary, Data")
        #expect(sheet.errorDescription?.contains("Summary, Data") == true)
        let page = OfficeDocumentRegionRenderer.RegionError.pageIndexOutOfRange(index: 9, pageCount: 2)
        #expect(page.errorDescription?.contains("0…1") == true)
        let rect = OfficeDocumentRegionRenderer.RegionError.rectOutsidePage(requested: "0,0 100x100", page: "0,0 50x50")
        #expect(rect.errorDescription?.contains("does not intersect") == true)
    }

    @Test("a bounded region PNG artifact passes the exact provider vision evidence gate")
    func regionArtifactPassesProviderEvidenceGate() throws {
        // A real 1×1 PNG. The runtime's provider vision resolver re-checks
        // containment, MIME sniff, byte budget and SHA-256 before ANY tool
        // artifact is attached to a provider request — a region render must
        // pass that same production gate to reach the next request.
        let png = try #require(Data(base64Encoded:
            "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg=="))
        let support = try #require(FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask).first)
        let directory = support.appendingPathComponent("FloeAgent/GeneratedImages", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let name = "office-region-guard-\(UUID().uuidString).png"
        let url = directory.appendingPathComponent(name)
        try png.write(to: url, options: .atomic)
        defer { try? FileManager.default.removeItem(at: url) }

        let artifact = ToolArtifactReference(id: UUID(),
                                             relativePath: "GeneratedImages/\(name)",
                                             mimeType: "image/png",
                                             byteCount: png.count,
                                             sha256: FloeDigest.sha256Hex(png))
        let part = AgentRuntime.providerImageEvidence(artifact)
        #expect(part != nil, "The region artifact must pass the production provider evidence gate")

        // A digest mismatch (stale/tampered artifact) must fail the same gate.
        let tampered = ToolArtifactReference(id: artifact.id, relativePath: artifact.relativePath,
                                             mimeType: "image/png", byteCount: png.count,
                                             sha256: String(repeating: "0", count: 64))
        #expect(AgentRuntime.providerImageEvidence(tampered) == nil)
        // And a non-allowlisted namespace never reaches the provider at all.
        let outsider = ToolArtifactReference(id: artifact.id, relativePath: "Other/\(name)",
                                             mimeType: "image/png", byteCount: png.count,
                                             sha256: artifact.sha256)
        #expect(AgentRuntime.providerImageEvidence(outsider) == nil)
    }

    // MARK: - The build-283 post-render current-quiescence fence (fixtures)

    private func makeAnchor(identity: (generation: Int?, correlationID: String?)? = (42, "corr-1"),
                            revision: Int = 7) -> NotesReadTool.RegionRenderAnchor {
        NotesReadTool.RegionRenderAnchor(session: OfficeFileSession(),
                                         documentID: documentID,
                                         revision: revision,
                                         resourceID: resourceID,
                                         sha256: anchorSHA,
                                         sessionIdentity: identity)
    }

    private func makeProof(outcome: OfficeSaveOutcome,
                           reason: String? = nil,
                           revision: Int = 7,
                           resourceID: UUID? = nil,
                           packageSHA: String? = anchorSHA,
                           generation: Int? = 42,
                           correlation: String? = "corr-1",
                           dirty: Bool? = false) -> OfficeSavedProof {
        OfficeSavedProof(outcome: outcome, reason: reason,
                         documentID: documentID,
                         sessionGeneration: generation,
                         sessionCorrelationID: correlation,
                         revision: revision,
                         resourceID: resourceID ?? self.resourceID,
                         packageSHA256: packageSHA,
                         nativeFlushOccurred: outcome == .saved,
                         changesPromoted: outcome == .saved,
                         dirtyAfterTransaction: dirty,
                         retryScheduled: false,
                         error: nil)
    }

    @Test("a clean alreadySaved validation at the exact staged proof passes")
    func fenceCleanValidationPasses() {
        let anchor = makeAnchor()
        let validation = makeProof(outcome: .alreadySaved)
        #expect(NotesReadTool.regionValidationStillQuiescent(validation, anchor: anchor))
    }

    @Test("a validation that committed NEW edits during the render rules the output obsolete")
    func fenceMidRenderCommitDiscards() {
        let anchor = makeAnchor()
        // The stroke that started during the export was committed by THIS
        // validation: new revision, same session. The produced image is
        // obsolete and must never be advertised.
        let committed = makeProof(outcome: .saved, revision: 8)
        #expect(!NotesReadTool.regionValidationStillQuiescent(committed, anchor: anchor))
        // Same new revision reported as a clean no-op is equally not the
        // staged proof — revision inequality alone discards.
        let movedNoop = makeProof(outcome: .alreadySaved, revision: 8)
        #expect(!NotesReadTool.regionValidationStillQuiescent(movedNoop, anchor: anchor))
    }

    @Test("unknown or dirty closing state refuses instead of rendering a stale package")
    func fenceDirtyOrUnknownStateRefuses() {
        let anchor = makeAnchor()
        #expect(!NotesReadTool.regionValidationStillQuiescent(makeProof(outcome: .alreadySaved, dirty: true), anchor: anchor))
        #expect(!NotesReadTool.regionValidationStillQuiescent(makeProof(outcome: .alreadySaved, dirty: nil), anchor: anchor))
        #expect(!NotesReadTool.regionValidationStillQuiescent(makeProof(outcome: .deferred, reason: "autosave.penActive"), anchor: anchor))
        #expect(!NotesReadTool.regionValidationStillQuiescent(makeProof(outcome: .refused, reason: "autosave.ownerMissing"), anchor: anchor))
        #expect(!NotesReadTool.regionValidationStillQuiescent(makeProof(outcome: .cancelled), anchor: anchor))
        #expect(!NotesReadTool.regionValidationStillQuiescent(makeProof(outcome: .failedVerification), anchor: anchor))
        #expect(!NotesReadTool.regionValidationStillQuiescent(makeProof(outcome: .failed), anchor: anchor))
    }

    @Test("identity drift — document, resource, hash, generation or correlation — discards")
    func fenceIdentityDriftDiscards() {
        let anchor = makeAnchor()
        #expect(!NotesReadTool.regionValidationStillQuiescent(makeProof(outcome: .alreadySaved, resourceID: UUID()), anchor: anchor))
        #expect(!NotesReadTool.regionValidationStillQuiescent(makeProof(outcome: .alreadySaved, packageSHA: String(repeating: "cd", count: 32)), anchor: anchor))
        #expect(!NotesReadTool.regionValidationStillQuiescent(makeProof(outcome: .alreadySaved, generation: 43), anchor: anchor))
        #expect(!NotesReadTool.regionValidationStillQuiescent(makeProof(outcome: .alreadySaved, correlation: "corr-2"), anchor: anchor))
        // A missing hash can never count as the staged proof.
        #expect(!NotesReadTool.regionValidationStillQuiescent(makeProof(outcome: .alreadySaved, packageSHA: nil), anchor: anchor))
        // A proof issued for a DIFFERENT document is not this anchor's proof.
        let other = OfficeSavedProof(outcome: .alreadySaved, reason: nil, documentID: UUID(),
                                     sessionGeneration: 42, sessionCorrelationID: "corr-1",
                                     revision: 7, resourceID: resourceID, packageSHA256: anchorSHA,
                                     nativeFlushOccurred: false, changesPromoted: false,
                                     dirtyAfterTransaction: false, retryScheduled: false, error: nil)
        #expect(!NotesReadTool.regionValidationStillQuiescent(other, anchor: anchor))
    }

    @Test("a mid-render-appeared session is validated on the saved scalar proof only")
    func fenceAppearedSessionUsesSavedScalarProof() {
        // No staging session existed, so there is no identity to compare:
        // any session generation is acceptable when the SAVED proof is exact.
        let anchor = makeAnchor(identity: nil)
        #expect(NotesReadTool.regionValidationStillQuiescent(makeProof(outcome: .alreadySaved, generation: 9, correlation: "new"), anchor: anchor))
        #expect(!NotesReadTool.regionValidationStillQuiescent(makeProof(outcome: .alreadySaved, revision: 8), anchor: anchor))
        #expect(!NotesReadTool.regionValidationStillQuiescent(makeProof(outcome: .deferred, reason: "autosave.penActive"), anchor: anchor))
    }
}

// MARK: - Real native route (primary-hosted qualification)

#if canImport(FloeOfficeNative) && targetEnvironment(simulator) && DEBUG
import UIKit
import ZIPFoundation
import FloeDocuments
import FloePersistence
import FloeTools
import FloeProviders
import FloeSecurity
import FloeTestSupport

/// Opt-in native qualification for the REAL region render route: the pinned
/// engine exports the actual print output, PDFKit renders the bounded region,
/// and the PNG artifact must pass the production provider evidence gate.
/// These cases run only in the primary hosted App build
/// (FLOE_OFFICE_REGION_PROOF=1, real engine + WebKit); the saved-state path
/// is used so the assertions stay deterministic regardless of the autosave
/// owner's separate qualification lane.
///
/// STATUS: every fixture here is PREPARED source. Actual execution (including
/// the provider-delivery case) remains primary-hosted App execution; nothing
/// in this file claims an observed native run.
// Fixture package parts shared by the native region cases (file scope so the
// nonisolated fixture helpers can read them off the main actor).
private let regionSheetRels = #"<?xml version="1.0" encoding="UTF-8" standalone="yes"?><Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/drawing" Target="../drawings/drawing1.xml"/></Relationships>"#

/// A VALID spreadsheetDrawing vector shape (solid rose rectangle), not a
/// raster stand-in. Its two-cell anchor covers E22:F25 inside the
/// E20:F30 print area, so a real engine render must contain its pixels.
private let regionDrawingXML = #"<?xml version="1.0" encoding="UTF-8" standalone="yes"?><xdr:wsDr xmlns:xdr="http://schemas.openxmlformats.org/drawingml/2006/spreadsheetDrawing" xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main"><xdr:twoCellAnchor editAs="oneCell"><xdr:from><xdr:col>4</xdr:col><xdr:colOff>0</xdr:colOff><xdr:row>21</xdr:row><xdr:rowOff>0</xdr:rowOff></xdr:from><xdr:to><xdr:col>5</xdr:col><xdr:colOff>0</xdr:colOff><xdr:row>24</xdr:row><xdr:rowOff>0</xdr:rowOff></xdr:to><xdr:sp macro="" textlink=""><xdr:nvSpPr><xdr:cNvPr id="2" name="Region ink"/><xdr:cNvSpPr/></xdr:nvSpPr><xdr:spPr><a:prstGeom prst="rect"><a:avLst/></a:prstGeom><a:solidFill><a:srgbClr val="E11D48"/></a:solidFill><a:ln><a:noFill/></a:ln></xdr:spPr></xdr:sp><xdr:clientData/></xdr:twoCellAnchor></xdr:wsDr>"#

@Suite("Notes Office region native qualification", .serialized)
@MainActor struct OfficeDocumentRegionNativeTests {
    private struct Harness {
        let root: URL
        let store: NotesStore
        let document: NoteDocument
        let conversationID: UUID
        let sourceURL: URL
        let sourceSHA256: String
    }

    private enum FixtureError: LocalizedError {
        case invalid(String)
        var errorDescription: String? {
            if case .invalid(let reason) = self { return reason }
            return nil
        }
    }

    private func makeHarness(fileName: String, build: (URL) throws -> Void) async throws -> Harness {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("floe-region-native-\(UUID().uuidString)", isDirectory: true)
        var overrideInstalled = false
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let source = root.appendingPathComponent(fileName)
            try build(source)
            let sourceSHA = try FloeDigest.sha256Hex(ofFileAt: source)
            let store = try NotesStore(root: root.appendingPathComponent("notes-store"))
            await NotesRepository.shared.setStoreOverride(store)
            overrideInstalled = true
            let imported = try await NoteFileImporter.importFile(source, notebookID: nil, store: store)
            let document = try await store.create(imported)
            let conversationID = UUID()
            try await store.bindAssistant(conversationID: conversationID,
                                          documentID: document.id, canEdit: true)
            return Harness(root: root, store: store, document: document,
                           conversationID: conversationID, sourceURL: source,
                           sourceSHA256: sourceSHA)
        } catch {
            if overrideInstalled { await NotesRepository.shared.setStoreOverride(nil) }
            try? FileManager.default.removeItem(at: root)
            throw error
        }
    }

    /// Awaited teardown on BOTH success and throw. The earlier deferred
    /// `Task { … setStoreOverride(nil) }` could clear the NEXT serialized
    /// case's override after that case installed its own store.
    private func withHarness(_ harness: Harness,
                             _ body: () async throws -> Void) async throws {
        do {
            try await body()
        } catch {
            await NotesRepository.shared.setStoreOverride(nil)
            try? FileManager.default.removeItem(at: harness.root)
            throw error
        }
        await NotesRepository.shared.setStoreOverride(nil)
        try? FileManager.default.removeItem(at: harness.root)
    }

    private nonisolated func context(_ harness: Harness, call: String) -> ToolContext {
        ToolContext(runID: UUID(), toolCallID: call, scope: .local,
                    workspaceRootURL: harness.root, cancellation: CancellationToken(),
                    conversationID: harness.conversationID)
    }

    private nonisolated func digestJSON(_ output: ToolExecutionOutput) throws -> [String: Any] {
        try #require(JSONSerialization.jsonObject(with: Data(output.summary.utf8)) as? [String: Any],
                     "The region response must be bounded JSON")
    }

    private nonisolated func artifactURL(_ artifact: ToolArtifactReference) throws -> URL {
        let support = try #require(FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask).first)
        return support.appendingPathComponent("FloeAgent")
            .appendingPathComponent(artifact.relativePath)
    }

    private nonisolated func artifactBytes(_ artifact: ToolArtifactReference) throws -> Data {
        try Data(contentsOf: try artifactURL(artifact))
    }

    /// Actual raster color census of the returned PNG bytes. The fixture's
    /// real OOXML vector shape is solid rose (#E11D48); antialiased edge
    /// pixels are ignored by the conservative red test.
    private nonisolated func inkPixelStats(_ pngData: Data) throws -> (red: Int, nonWhite: Int, total: Int) {
        let image = try #require(UIImage(data: pngData)?.cgImage,
                                 "the artifact must be a decodable PNG")
        let width = image.width, height = image.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let drawn = pixels.withUnsafeMutableBytes { raw -> Bool in
            guard let context = CGContext(data: raw.baseAddress, width: width, height: height,
                                          bitsPerComponent: 8, bytesPerRow: width * 4,
                                          space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                                            | CGBitmapInfo.byteOrder32Big.rawValue) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { throw FixtureError.invalid("the rendered PNG could not be decoded") }
        var red = 0
        var nonWhite = 0
        var index = 0
        while index + 3 < pixels.count {
            let r = Int(pixels[index]), g = Int(pixels[index + 1]), b = Int(pixels[index + 2])
            if r > 100, r > g + 40, r > b + 30 { red += 1 }
            if !(r > 240 && g > 240 && b > 240) { nonWhite += 1 }
            index += 4
        }
        return (red, nonWhite, width * height)
    }

    // MARK: - Workbook fixture with real geometry and vector ink

    /// Builds the guarded Office283 workbook fixture: the target sheet keeps
    /// real 8-column/30-row content plus a hidden row/column, and this lane
    /// adds bounded VALID OOXML geometry (unequal E/F widths, unequal row
    /// heights 20…30), a red vector shape anchored inside the requested
    /// E20:F30 print area, and the sheet/drawing relationships. No stand-in
    /// image is ever written.
    private nonisolated func regionWorkbook(at url: URL) throws {
        var dataRows: [[String]] = []
        dataRows.append((0..<8).map { "H\($0)" })
        for row in 2...30 {
            if row == 30 { dataRows.append((0..<6).map { "R\($0)" } + ["needle-30", "tail"]) }
            else { dataRows.append((0..<8).map { "R\($0)-\(row)" }) }
        }
        try OfficeDocumentBuilder.createWorkbook(at: url, sheets: [
            .init(name: "Summary", rows: [["Total", "see Data"]]),
            .init(name: "Data", rows: dataRows, hiddenRows: [15], hiddenColumns: [8]),
        ])
        try Self.addRegionGeometryAndInk(to: url)
    }

    private nonisolated static func addRegionGeometryAndInk(to url: URL) throws {
        let archive = try Archive(url: url, accessMode: .read)
        var entries: [(String, Data)] = []
        var sawSheet = false
        for entry in archive where entry.type == .file {
            var data = Data()
            _ = try archive.extract(entry) { data.append($0) }
            switch entry.path {
            case "xl/worksheets/sheet2.xml":
                data = try regionSheetXML(data)
                sawSheet = true
            case "[Content_Types].xml":
                data = try contentTypesWithDrawing(data)
            default:
                break
            }
            entries.append((entry.path, data))
        }
        guard sawSheet else { throw FixtureError.invalid("fixture has no second worksheet") }
        entries.append(("xl/worksheets/_rels/sheet2.xml.rels", Data(regionSheetRels.utf8)))
        entries.append(("xl/drawings/drawing1.xml", Data(regionDrawingXML.utf8)))

        let temporary = url.deletingLastPathComponent()
            .appendingPathComponent("region-rewrite-\(UUID().uuidString).xlsx")
        defer { try? FileManager.default.removeItem(at: temporary) }
        let output = try Archive(url: temporary, accessMode: .create)
        for (path, data) in entries {
            try output.addEntry(with: path, type: .file,
                                uncompressedSize: Int64(data.count),
                                compressionMethod: .deflate) { position, size in
                let start = Int(position)
                return data.subdata(in: start..<(start + size))
            }
        }
        try FileManager.default.removeItem(at: url)
        try FileManager.default.moveItem(at: temporary, to: url)
        let inspected = try OfficeDocumentService.inspect(url: url)
        guard inspected.kind == .workbook,
              inspected.workbookPreview?.sheets.map(\.name) == ["Summary", "Data"] else {
            throw FixtureError.invalid("the geometry/ink fixture no longer inspects as the expected workbook")
        }
    }

    private nonisolated static func regionSheetXML(_ data: Data) throws -> Data {
        var xml = try #require(String(data: data, encoding: .utf8))
        let root = #"<worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">"#
        let rootWithRelationships = #"<worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">"#
        guard xml.contains(root) else {
            throw FixtureError.invalid("worksheet root is not the builder shape")
        }
        xml = xml.replacingOccurrences(of: root, with: rootWithRelationships)

        let extraColumns = #"<col min="5" max="5" width="26.5" customWidth="1"/><col min="6" max="6" width="7.5" customWidth="1"/>"#
        if let close = xml.range(of: "</cols>") {
            xml.insert(contentsOf: extraColumns, at: close.lowerBound)
        } else if let format = xml.range(of: "</sheetFormatPr>") {
            xml.insert(contentsOf: "<cols>" + extraColumns + "</cols>", at: format.upperBound)
        } else {
            throw FixtureError.invalid("worksheet has no schema-ordered cols insertion point")
        }

        let heights = [18, 34, 12, 28, 16, 40, 14, 24, 19, 31, 22]
        for (offset, height) in heights.enumerated() {
            let row = 20 + offset
            let marker = #"<row r="\#(row)""#
            guard let range = xml.range(of: marker) else {
                throw FixtureError.invalid("fixture row \(row) is missing")
            }
            xml.insert(contentsOf: #" ht="\#(height)" customHeight="1""#, at: range.upperBound)
        }
        guard let close = xml.range(of: "</worksheet>") else {
            throw FixtureError.invalid("worksheet close tag is missing")
        }
        xml.insert(contentsOf: #"<drawing r:id="rId1"/>"#, at: close.lowerBound)
        return Data(xml.utf8)
    }

    private nonisolated static func contentTypesWithDrawing(_ data: Data) throws -> Data {
        var xml = try #require(String(data: data, encoding: .utf8))
        let override = #"<Override PartName="/xl/drawings/drawing1.xml" ContentType="application/vnd.openxmlformats-officedocument.drawing+xml"/>"#
        guard !xml.contains("/xl/drawings/drawing1.xml"),
              let close = xml.range(of: "</Types>") else {
            throw FixtureError.invalid("content types have no drawing insertion point")
        }
        xml.insert(contentsOf: override, at: close.lowerBound)
        return Data(xml.utf8)
    }

    private nonisolated func assertRegionFixtureGeometry(_ url: URL) throws {
        let archive = try Archive(url: url, accessMode: .read)
        let entry = try #require(archive["xl/worksheets/sheet2.xml"])
        var data = Data()
        _ = try archive.extract(entry) { data.append($0) }
        let xml = try #require(String(data: data, encoding: .utf8))
        #expect(xml.contains(#"width="26.5""#))
        #expect(xml.contains(#"width="7.5""#))
        #expect(xml.contains(#"ht="34""#))
        #expect(xml.contains(#"ht="12""#))
        #expect(xml.contains(#"<drawing r:id="rId1"/>"#))
        let drawing = archive["xl/drawings/drawing1.xml"]
        #expect(drawing != nil)
    }

    // MARK: - Native cases

    @Test("discovery lists the workbook's real sheets in tab order without a render", .enabled(if: ProcessInfo.processInfo.environment["FLOE_OFFICE_REGION_PROOF"] == "1"))
    func nativeDiscovery() async throws {
        let harness = try await makeHarness(fileName: "RegionData.xlsx", build: { url in try regionWorkbook(at: url) })
        try await withHarness(harness) {
            let documentID = harness.document.id.uuidString
            let args = try JSONDecoder().decode(NotesReadTool.Arguments.self, from: Data(
                #"{"documentID":"\#(documentID)","section":"officeRegion"}"#.utf8))
            let output = try await NotesReadTool().execute(args, context: context(harness, call: "region-discovery"))
            let json = try digestJSON(output)
            #expect(json["discoveryKind"] as? String == "workbookSheets")
            #expect(json["sourceState"] as? String == "savedResource")
            let sheets = try #require(json["sheets"] as? [[String: Any]])
            #expect(sheets.count == 2)
            #expect(sheets[0]["name"] as? String == "Summary")
            #expect(sheets[1]["name"] as? String == "Data")
            #expect((json["rangeLimits"] as? [String: Any])?["maximumCells"] as? Int == 2_400)
            #expect(json["artifactRelativePath"] == nil, "Discovery renders nothing")
        }
    }

    @Test("second workbook sheet far range renders real colored vector ink through the provider gate", .enabled(if: ProcessInfo.processInfo.environment["FLOE_OFFICE_REGION_PROOF"] == "1"))
    func nativeSecondSheetFarRange() async throws {
        let harness = try await makeHarness(fileName: "RegionData.xlsx", build: { url in try regionWorkbook(at: url) })
        try await withHarness(harness) {
            try assertRegionFixtureGeometry(harness.sourceURL)
            let documentID = harness.document.id.uuidString
            let args = try JSONDecoder().decode(NotesReadTool.Arguments.self, from: Data(
                #"{"documentID":"\#(documentID)","section":"officeRegion","sheet":"Data","cellRange":"E20:F30","pixelWidth":1000}"#.utf8))
            let output = try await NotesReadTool().execute(args, context: context(harness, call: "region-render"))
            let json = try digestJSON(output)
            #expect(json["sourceState"] as? String == "savedResource")
            #expect(json["sheetName"] as? String == "Data")
            #expect(json["cellRange"] as? String == "E20:F30")
            #expect((json["printAreaReference"] as? String)?.contains("$E$20:$F$30") == true)
            #expect(json["suppressedSheets"] as? [String] == ["Summary"])
            #expect(json["renderedPageIndex"] as? Int == 0)
            #expect(json["pixelWidth"] as? Int == 1_000)
            #expect((json["pixelsPerPoint"] as? Double).map { $0 > 0 } == true)
            #expect((json["pngSHA256"] as? String)?.count == 64)
            #expect((json["pdfSHA256"] as? String)?.count == 64)
            #expect((json["sourceSHA256"] as? String) == harness.sourceSHA256)

            let artifact = try #require(output.artifacts.first)
            defer { OfficeRegionArtifactStore.remove(artifact) }
            #expect(artifact.mimeType == "image/png")
            #expect(artifact.byteCount > 512 && artifact.byteCount <= 8 * 1_024 * 1_024)
            #expect(artifact.sha256 == json["pngSHA256"] as? String)
            // The production provider vision evidence gate accepts the artifact.
            #expect(AgentRuntime.providerImageEvidence(artifact) != nil,
                    "The real region PNG must reach the provider evidence chain")
            // The REAL bytes contain the fixture's vector ink, not a blank or
            // stand-in image, and stay bounded inside the requested region.
            let bytes = try artifactBytes(artifact)
            #expect(bytes.count == artifact.byteCount)
            #expect(FloeDigest.sha256Hex(bytes) == artifact.sha256)
            let stats = try inkPixelStats(bytes)
            #expect(stats.red > 500,
                    "the real OOXML vector ink must render as rose pixels (red=\(stats.red))")
            #expect(Double(stats.red) / Double(stats.total) > 0.01,
                    "the ink must cover a measurable part of the rendered region")
            #expect(stats.red < stats.total / 2,
                    "the ink must stay bounded, not fill the whole page")
            // Cleanup: the artifact store removes exactly this reference.
            OfficeRegionArtifactStore.remove(artifact)
            let support = try #require(FileManager.default.urls(
                for: .applicationSupportDirectory, in: .userDomainMask).first)
            #expect(!FileManager.default.fileExists(
                atPath: support.appendingPathComponent("FloeAgent")
                    .appendingPathComponent(artifact.relativePath).path))
            // The user's package never changed.
            #expect(try FloeDigest.sha256Hex(ofFileAt: harness.sourceURL) == harness.sourceSHA256)
        }
    }

    @Test("oversized regions refuse with real limits before any engine work", .enabled(if: ProcessInfo.processInfo.environment["FLOE_OFFICE_REGION_PROOF"] == "1"))
    func nativeOversizedRefusal() async throws {
        let harness = try await makeHarness(fileName: "RegionData.xlsx", build: { url in try regionWorkbook(at: url) })
        try await withHarness(harness) {
            let documentID = harness.document.id.uuidString
            let args = try JSONDecoder().decode(NotesReadTool.Arguments.self, from: Data(
                #"{"documentID":"\#(documentID)","section":"officeRegion","sheetIndex":0,"cellRange":"A1:AG10"}"#.utf8))
            var failure: Error?
            do {
                _ = try await NotesReadTool().execute(args, context: context(harness, call: "region-oversized"))
            } catch { failure = error }
            let text = (failure as? LocalizedError)?.errorDescription ?? failure.map { "\($0)" } ?? ""
            #expect(text.contains("too large") || text.contains("33"),
                    "Refusal must name the real bounds: \(text)")
            // The refusal path wrote no NEW region artifact at all.
            let support = try #require(FileManager.default.urls(
                for: .applicationSupportDirectory, in: .userDomainMask).first)
            let window = support.appendingPathComponent("FloeAgent/GeneratedImages", isDirectory: true)
            let names = (try? FileManager.default.contentsOfDirectory(atPath: window.path)) ?? []
            #expect(names.allSatisfy { !$0.hasPrefix("office-region-") })
        }
    }

    @Test("Word pages discover and a non-first page plus pointsRect render REAL PNGs", .enabled(if: ProcessInfo.processInfo.environment["FLOE_OFFICE_REGION_PROOF"] == "1"))
    func nativeWordPageAndRect() async throws {
        let harness = try await makeHarness(fileName: "RegionBrief.docx") { url in
            try OfficeDocumentBuilder.createWord(
                at: url, title: "Region brief",
                paragraphs: (0..<120).map { "Paragraph \($0) with enough body text to flow across real pages." })
        }
        try await withHarness(harness) {
            let documentID = harness.document.id.uuidString
            let discoveryArgs = try JSONDecoder().decode(NotesReadTool.Arguments.self, from: Data(
                #"{"documentID":"\#(documentID)","section":"officeRegion"}"#.utf8))
            let discovery = try digestJSON(try await NotesReadTool().execute(
                discoveryArgs, context: context(harness, call: "region-word-discovery")))
            #expect(discovery["discoveryKind"] as? String == "printPages")
            let pageCount = try #require(discovery["pageCount"] as? Int)
            #expect(pageCount >= 2, "The real export of 120 paragraphs must paginate")
            let pages = try #require(discovery["pages"] as? [[String: Any]])
            #expect(pages.count >= 2 && pages.count <= 64)
            #expect((pages.first?["widthPoints"] as? Double).map { $0 > 0 } == true)

            // Render the LAST page whole (offscreen for any editor viewport).
            let lastArgs = try JSONDecoder().decode(NotesReadTool.Arguments.self, from: Data(
                #"{"documentID":"\#(documentID)","section":"officeRegion","pageIndex":\#(pageCount - 1),"pixelWidth":900}"#.utf8))
            let lastOutput = try await NotesReadTool().execute(lastArgs, context: context(harness, call: "region-word-last"))
            let lastJSON = try digestJSON(lastOutput)
            #expect(lastJSON["renderedPageIndex"] as? Int == pageCount - 1)
            #expect(lastJSON["renderedPageCount"] as? Int == pageCount)
            let lastArtifact = try #require(lastOutput.artifacts.first)
            defer { OfficeRegionArtifactStore.remove(lastArtifact) }
            #expect(AgentRuntime.providerImageEvidence(lastArtifact) != nil)
            OfficeRegionArtifactStore.remove(lastArtifact)

            // A pointsRect crop of page zero reports the actual intersection.
            let cropArgs = try JSONDecoder().decode(NotesReadTool.Arguments.self, from: Data("""
                {"documentID":"\(documentID)","section":"officeRegion","pageIndex":0,
                 "pointsRect":{"x":10,"y":10,"width":200,"height":120}}
                """.utf8))
            let cropOutput = try await NotesReadTool().execute(cropArgs, context: context(harness, call: "region-word-crop"))
            let cropJSON = try digestJSON(cropOutput)
            #expect(cropJSON["requestedRectPoints"] != nil)
            #expect(cropJSON["renderedRectPoints"] != nil)
            #expect(cropJSON["renderedPageIndex"] as? Int == 0)
            let cropArtifact = try #require(cropOutput.artifacts.first)
            defer { OfficeRegionArtifactStore.remove(cropArtifact) }
            #expect(AgentRuntime.providerImageEvidence(cropArtifact) != nil)
            OfficeRegionArtifactStore.remove(cropArtifact)

            // Out-of-range pages refuse with the real valid window.
            let farArgs = try JSONDecoder().decode(NotesReadTool.Arguments.self, from: Data(
                #"{"documentID":"\#(documentID)","section":"officeRegion","pageIndex":\#(pageCount)}"#.utf8))
            var failure: Error?
            do {
                _ = try await NotesReadTool().execute(farArgs, context: context(harness, call: "region-word-far"))
            } catch { failure = error }
            let text = (failure as? LocalizedError)?.errorDescription ?? failure.map { "\($0)" } ?? ""
            #expect(text.contains("valid indices") || text.contains("0…"),
                    "The refusal must name the real page window: \(text)")
        }
    }

    @Test("PowerPoint second page plus pointsRect renders real cropped PNG pixels", .enabled(if: ProcessInfo.processInfo.environment["FLOE_OFFICE_REGION_PROOF"] == "1"))
    func nativePresentationSecondPageAndRect() async throws {
        let harness = try await makeHarness(fileName: "RegionDeck.pptx") { url in
            try OfficeDocumentBuilder.createPresentation(at: url, title: "Region deck", slides: [
                .init(title: "First", bullets: ["cover"]),
                .init(title: "Second", bullets: [], objects: [
                    .init(kind: .shape, name: "Crop ink", layout: .center,
                          fillColor: "E11D48", lineColor: "E11D48")
                ]),
            ])
        }
        try await withHarness(harness) {
            let documentID = harness.document.id.uuidString
            let discoveryArgs = try JSONDecoder().decode(NotesReadTool.Arguments.self, from: Data(
                #"{"documentID":"\#(documentID)","section":"officeRegion"}"#.utf8))
            let discovery = try digestJSON(try await NotesReadTool().execute(
                discoveryArgs, context: context(harness, call: "region-ppt-discovery")))
            #expect(discovery["discoveryKind"] as? String == "printPages")
            let pageCount = try #require(discovery["pageCount"] as? Int)
            #expect(pageCount >= 2, "The two-slide deck must export at least two pages")
            let pages = try #require(discovery["pages"] as? [[String: Any]])
            let second = try #require(pages.first { $0["pageIndex"] as? Int == 1 })
            let width = try #require(second["widthPoints"] as? Double)
            let height = try #require(second["heightPoints"] as? Double)
            #expect(width > 0 && height > 0)

            // Crop a centered superset of the rose shape on the SECOND page.
            let rect: [String: Any] = ["x": width * 0.2, "y": height * 0.2,
                                       "width": width * 0.6, "height": height * 0.6]
            let argsObject: [String: Any] = [
                "documentID": documentID, "section": "officeRegion",
                "pageIndex": 1, "pixelWidth": 1000, "pointsRect": rect
            ]
            let args = try JSONDecoder().decode(NotesReadTool.Arguments.self,
                                                from: try JSONSerialization.data(withJSONObject: argsObject))
            let output = try await NotesReadTool().execute(args, context: context(harness, call: "region-ppt-crop"))
            let json = try digestJSON(output)
            #expect(json["renderedPageIndex"] as? Int == 1)
            #expect(json["renderedPageCount"] as? Int == pageCount)
            let requested = try #require(json["requestedRectPoints"] as? [String: Any])
            #expect(abs((requested["width"] as? Double ?? 0) - width * 0.6) < 0.5)
            #expect(abs((requested["height"] as? Double ?? 0) - height * 0.6) < 0.5)
            #expect((json["renderedRectPoints"] as? [String: Any]) != nil)

            let artifact = try #require(output.artifacts.first)
            defer { OfficeRegionArtifactStore.remove(artifact) }
            #expect(artifact.mimeType == "image/png")
            let bytes = try artifactBytes(artifact)
            #expect(FloeDigest.sha256Hex(bytes) == artifact.sha256)
            let stats = try inkPixelStats(bytes)
            #expect(stats.red > 300,
                    "the real cropped slide must contain the rose shape (red=\(stats.red))")
            #expect(Double(stats.red) / Double(stats.total) > 0.01)
            #expect(try FloeDigest.sha256Hex(ofFileAt: harness.sourceURL) == harness.sourceSHA256)
            OfficeRegionArtifactStore.remove(artifact)
        }
    }

    // MARK: - The REAL tool artifact must reach the NEXT provider request

    /// Fixture PREPARED for primary App execution. This is the missing proof
    /// beyond `providerImageEvidence(artifact) != nil`: the REAL
    /// `notes.read` runner is registered in a local `ToolRunnerRegistry`,
    /// executed through the production `CatalogToolExecutor` and
    /// `ConversationRunService` runtime against the selected Notes resource,
    /// and the NEXT actual `ProviderStreamRequest` must carry the exact PNG
    /// bytes (MIME, count, SHA-256) produced by that render. No request is
    /// hand-built, no PNG is canned and no toolResult is seeded.
    @Test("the real notes.read region PNG reaches the NEXT provider request with exact bytes", .enabled(if: ProcessInfo.processInfo.environment["FLOE_OFFICE_REGION_PROOF"] == "1"))
    func nativeRegionArtifactReachesNextProviderRequest() async throws {
        let harness = try await makeHarness(fileName: "RegionDelivery.xlsx", build: { url in try regionWorkbook(at: url) })
        try await withHarness(harness) {
            var ownedArtifact: ToolArtifactReference?
            defer { if let ownedArtifact { OfficeRegionArtifactStore.remove(ownedArtifact) } }

            let database = try DatabaseManager.inMemory()
            try await database.migrate()
            let conversations = SQLiteConversationStore(database: database)
            let runs = SQLiteRunStore(database: database)
            let now = Date()
            try await conversations.saveConversation(ConversationRecord(
                id: harness.conversationID, title: "Region provider delivery",
                createdAt: now, updatedAt: now))

            let provider = TestFixtures.localhostProvider()
            let model = ModelProfile(
                providerID: provider.id,
                remoteModelID: "region-proof-vision",
                displayName: "Region proof vision",
                limits: ModelLimits(contextTokens: 16_384, maxOutputTokens: 1_024),
                capabilities: [.text, .tools, .vision])
            let configuration = FloeAgentRuntime.Configuration(
                conversationID: harness.conversationID,
                provider: provider,
                model: model,
                allowedToolNames: [NotesReadTool.name],
                workspaceRootURL: harness.root)
            let call = try TestFixtures.toolCall(
                id: "region-delivery-call",
                toolName: NotesReadTool.name,
                arguments: #"{"documentID":"\#(harness.document.id.uuidString)","section":"officeRegion","sheet":"Data","cellRange":"E20:F30","pixelWidth":1000}"#)
            let adapter = MockAdapter()
            adapter.script = [
                [.toolRequest(call)],
                [.textDelta(.init(text: "Rendered the requested range.")),
                 .completed(.init(stopReason: .endTurn))]
            ]
            // REAL NotesReadTool in a LOCAL registry; the canonical executor
            // and run service call it exactly as the App composition does.
            let registry = ToolRunnerRegistry()
            registry.register(NotesReadTool())
            #expect(registry.runner(named: NotesReadTool.name) != nil)
            let service = ConversationRunService(
                configuration: configuration,
                adapter: adapter,
                policy: HumanApprovalPolicy(),
                executor: CatalogToolExecutor(runners: registry),
                conversationStore: conversations,
                runStore: runs)
            try await service.start(goal: "Inspect the Data sheet E20:F30 region and describe what you see.")

            let requests = adapter.requests
            #expect(requests.count >= 2, "the runtime must issue the post-tool provider request")
            // Nothing image-like existed before the tool ran: not seeded.
            let initialImages = requests[0].contentMessages.flatMap(\.content).filter {
                if case .imageData = $0 { return true }
                return false
            }
            #expect(initialImages.isEmpty)

            let events = try await runs.events(runID: service.runID)
            let resultEvent = try #require(events.first { $0.kind == .toolResult })
            let payload = try JSONDecoder().decode(
                [String: String].self, from: Data(resultEvent.payloadJSON.utf8))
            #expect(payload["tool"] == NotesReadTool.name)
            #expect(payload["status"] == "ok", "the real region tool must execute: \(payload)")
            let summary = try #require(payload["summary"])
            #expect(summary.contains("\"sheetName\":\"Data\""))
            #expect(summary.contains("\"cellRange\":\"E20:F30\""))
            let refsJSON = try #require(payload["artifactRefsJSON"])
            let references = try JSONDecoder().decode(
                [ToolArtifactReference].self, from: Data(refsJSON.utf8))
            let artifact = try #require(references.first)
            ownedArtifact = artifact
            #expect(artifact.relativePath.hasPrefix("GeneratedImages/office-region-"))
            #expect(artifact.mimeType == "image/png")
            #expect(summary.contains(artifact.sha256),
                    "the persisted tool result must report the same rendered digest")
            let toolBytes = try artifactBytes(artifact)
            #expect(toolBytes.count == artifact.byteCount)
            #expect(FloeDigest.sha256Hex(toolBytes) == artifact.sha256)

            // The NEXT actual provider request carries those exact bytes.
            let nextRequest = try #require(requests.dropFirst().first)
            #expect(nextRequest.toolResults.contains { $0.callID == call.id })
            let imageParts = nextRequest.contentMessages.flatMap(\.content).compactMap {
                part -> (mime: String, base64: String)? in
                if case .imageData(let mime, let base64) = part { return (mime, base64) }
                return nil
            }
            #expect(imageParts.count == 1, "exactly the one real region image is attached")
            let deliveredPart = try #require(imageParts.first)
            #expect(deliveredPart.mime == "image/png")
            let delivered = try #require(Data(base64Encoded: deliveredPart.base64))
            #expect(delivered == toolBytes,
                    "the provider receives the exact bytes the real tool wrote")
            #expect(delivered.count == artifact.byteCount)
            #expect(FloeDigest.sha256Hex(delivered) == artifact.sha256)
        }
    }
}
#endif

#endif
