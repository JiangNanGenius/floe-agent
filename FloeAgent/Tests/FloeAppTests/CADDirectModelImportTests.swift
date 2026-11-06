// SPDX-License-Identifier: MPL-2.0
// App integration: real native writers -> guarded workspace exchange files ->
// production direct-open coordinator -> shared workbench document -> cold open.
#if canImport(SwiftUI) && canImport(UIKit)
import Foundation
import XCTest
import simd
import FloeWorkspace
@testable import FloeCAD
@testable import FloeApp

@MainActor
final class CADDirectModelImportTests: XCTestCase {
    private var workspace: URL!
    private var service: WorkspaceFileService!
    private var bridgeDocuments: [FloeCADDocument] = []
    private var standaloneDocuments: [FloeCADDocument] = []

    override func setUp() async throws {
        workspace = FileManager.default.temporaryDirectory
            .appendingPathComponent("CADDirectImport-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        service = WorkspaceFileService(guard: WorkspacePathGuard(rootURL: workspace))
    }

    override func tearDown() async throws {
        // A failed assertion must not delete a package still owned by the
        // shared App bridge. UUID-owned roots never overlap another test/user.
        var mayRemoveWorkspace = true
        for document in bridgeDocuments.reversed() where !document.isClosed {
            let receipt = await FloeCAD3DBridge.shared.releaseDocumentOutcome(
                at: document.url, expected: document)
            if let receipt { XCTAssertTrue(receipt.succeeded, receipt.error ?? "") }
            if !document.isClosed {
                mayRemoveWorkspace = false
                XCTFail("The direct-import document remained open; its test workspace was retained: \(document.url.path)")
            }
        }
        for document in standaloneDocuments { document.close() }
        bridgeDocuments = []; standaloneDocuments = []; service = nil
        if mayRemoveWorkspace, let workspace {
            try FileManager.default.removeItem(at: workspace)
        }
    }

    func testSTLDirectOpenUsesExplicitMillimetresAndPersistsMesh() async throws {
        try await exercise(format: "stl", unitScale: 1, unitTag: "mm", expectsExactSolid: false)
    }

    func testIGESDirectOpenPreservesClosedExactSolidAndSourceUnits() async throws {
        try await exercise(format: "igs", unitScale: nil, unitTag: "source-units", expectsExactSolid: true)
    }

    func testSTEPDirectOpenPreservesClosedExactSolidAndSourceUnits() async throws {
        try await exercise(format: "step", unitScale: nil, unitTag: "source-units", expectsExactSolid: true)
    }

    private func exercise(format: String, unitScale: Double?, unitTag: String,
                          expectsExactSolid: Bool) async throws {
        let sourcePath = "part.\(format)"
        let sourceBytes = try await exportRealBox(format: format)
        XCTAssertFalse(sourceBytes.isEmpty, "The production native writer must produce real exchange bytes")
        let created = try service.createBinaryFile(sourcePath, data: sourceBytes)
        XCTAssertEqual(created.bytesWritten, sourceBytes.count)
        let sourceURL = try service.guardResolver.resolve(sourcePath)

        let imported = try await CADUnifiedModelImport.open(
            sourcePath: sourcePath, service: service, unitScale: unitScale, unitTag: unitTag)
        bridgeDocuments.append(imported.document)
        let packageURL = try service.guardResolver.resolve(imported.path)
        XCTAssertEqual(imported.document.url.standardizedFileURL, packageURL.standardizedFileURL)
        XCTAssertEqual(packageURL.pathExtension, "floecad")
        XCTAssertNotEqual(packageURL.standardizedFileURL, sourceURL.standardizedFileURL)
        XCTAssertTrue(packageURL.path.hasPrefix(service.guardResolver.rootURL.path + "/"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: packageURL.appendingPathComponent("manifest.json").path))
        XCTAssertEqual(try Data(contentsOf: sourceURL), sourceBytes,
                       "Opening for editing must preserve the complete original exchange file")

        // FilePreview and assistant tools must share one live session, rather
        // than editing separately opened/cached snapshots of the same package.
        let shared = try await FloeCAD3DBridge.shared.openDocument(at: packageURL)
        XCTAssertTrue(shared === imported.document)
        let repeated = try await CADUnifiedModelImport.open(
            sourcePath: sourcePath, service: service, unitScale: unitScale, unitTag: unitTag)
        XCTAssertEqual(repeated.path, imported.path)
        XCTAssertTrue(repeated.document === imported.document,
                      "An unchanged source and units must resolve to its existing working copy")

        let body = try assertBox(document: imported.document, expectsExactSolid: expectsExactSolid)
        let bodyID = body.id
        let render = body.render
        let saved = await imported.document.save()
        XCTAssertTrue(saved.succeeded, saved.error ?? "")
        let release = await FloeCAD3DBridge.shared.releaseDocumentOutcome(
            at: packageURL, expected: imported.document)
        XCTAssertTrue(try XCTUnwrap(release).succeeded)
        XCTAssertTrue(imported.document.isClosed)
        let storedIdentity = await FloeCADDocument.storedIdentity(at: packageURL)
        let stored = try XCTUnwrap(storedIdentity)

        // Release has removed the live owner. This second bridge open must
        // deserialize the actual saved package and construct a fresh session.
        let reopened = try await FloeCAD3DBridge.shared.openDocument(at: packageURL)
        bridgeDocuments.append(reopened)
        XCTAssertFalse(reopened === imported.document)
        XCTAssertEqual(reopened.contentSHA256, stored.contentSHA256)
        XCTAssertEqual(reopened.modelSHA256, stored.modelSHA256)
        let coldBody = try assertBox(document: reopened, expectsExactSolid: expectsExactSolid)
        XCTAssertEqual(coldBody.id, bodyID)
        XCTAssertEqual(coldBody.render, render, "Cold open must preserve the imported render buffers")
        XCTAssertEqual(try Data(contentsOf: sourceURL), sourceBytes)

        let finalRelease = await FloeCAD3DBridge.shared.releaseDocumentOutcome(at: packageURL, expected: reopened)
        XCTAssertTrue(try XCTUnwrap(finalRelease).succeeded)
        XCTAssertTrue(reopened.isClosed)
        let siblings = try FileManager.default.contentsOfDirectory(atPath: service.guardResolver.rootURL.path)
        XCTAssertFalse(siblings.contains { $0.hasPrefix(".floe-model-import-") },
                       "A successful import must not leave an unpublished staging package")
    }

    /// Build through the real native feature evaluator, then ask the actual
    /// STL/IGES/STEP writers for bytes. No handwritten exchange fixtures,
    /// parser mocks, alternate geometry kernel or manufacturing codec.
    private func exportRealBox(format: String) async throws -> Data {
        let url = try service.guardResolver.resolve("source-box.floecad", for: .createNew)
        let document = try await FloeCADDocument.create(at: url, name: "Direct import source")
        standaloneDocuments.append(document)
        let id = BodyID()
        let node = FeatureNode(name: "20 × 10 × 5 mm box",
            kind: .primitive(spec: .box(width: 20, depth: 10, height: 5), placement: .identity),
            outputBodyIDs: [id])
        document.session.recordAndRebuild([node], title: "Create exact source box")
        XCTAssertTrue(document.session.lastEvalErrors.isEmpty)
        let body = try XCTUnwrap(document.session.document.body(with: id))
        XCTAssertTrue(body.brep?.containsSolid == true)
        XCTAssertNil(body.surfaceBRep)
        let exported = try document.nativeExportData(format: format, pageID: nil).get()
        let saved = await document.save()
        XCTAssertTrue(saved.succeeded, saved.error ?? "")
        document.close()
        return exported.data
    }

    @discardableResult
    private func assertBox(document: FloeCADDocument, expectsExactSolid: Bool) throws -> Body {
        XCTAssertFalse(document.isClosed)
        XCTAssertFalse(document.isReadOnly)
        XCTAssertEqual(document.summary().bodyCount, 1)
        let body = try XCTUnwrap(document.session.document.bodies.first)
        XCTAssertEqual(body.brep?.containsSolid == true, expectsExactSolid)
        XCTAssertNil(body.surfaceBRep, "A closed IGES/STEP box must not become a sheet")
        XCTAssertGreaterThan(body.render.triangleCount, 0)
        let first = try XCTUnwrap(body.render.positions.first)
        var minimum = body.transform.applying(to: SIMD3<Double>(first))
        var maximum = minimum
        for point in body.render.positions {
            let world = body.transform.applying(to: SIMD3<Double>(point))
            minimum = simd_min(minimum, world); maximum = simd_max(maximum, world)
        }
        let extent = maximum - minimum
        // CAD primitives are Y-up: box width/depth/height -> X/Z/Y.
        XCTAssertEqual(extent.x, 20, accuracy: 1e-4)
        XCTAssertEqual(extent.y, 5, accuracy: 1e-4)
        XCTAssertEqual(extent.z, 10, accuracy: 1e-4)
        return body
    }
}
#endif
