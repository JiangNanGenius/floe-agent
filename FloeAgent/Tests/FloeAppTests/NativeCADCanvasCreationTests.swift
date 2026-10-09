// FloeAppTests — ordinary (workspace-less) Canvas native CAD creation.
//
// The production bug this test locks down: creating a CAD model from a
// default Canvas failed because the node preview was rasterized from a
// DRAWING page, and a brand-new package has none. The preview now comes from
// the VIEWPORT (bodies + assembly instances), independent of drawings, with
// an explicit placeholder fallback — and the editable package still commits.
//
// The test drives the exact production entry point
// (`CADCanvasActionBridge.newCADDocumentInCanvas`) against a default canvas
// in the app container (no file workspace, no chat task), then verifies the
// node binding, the on-device package (still editable, ZERO drawing pages),
// and the rendered asset bytes.
//
// SPDX-License-Identifier: MPL-2.0

#if canImport(SwiftUI) && canImport(UIKit)
import XCTest
import FloeCAD
@testable import FloeApp
import FloePersistence
import FloeCore

@MainActor
final class NativeCADCanvasCreationTests: XCTestCase {

    private var canvasID: UUID!

    override func setUp() async throws {
        canvasID = UUID()
        try WorkspaceCanvasRegistry.createIfNeeded(canvasID: canvasID,
                                                   name: "Ordinary Canvas",
                                                   workspaceID: nil)
    }

    override func tearDown() async throws {
        if let canvasID {
            try? WorkspaceCanvasRegistry.delete(canvasID: canvasID)
            CanvasCADStorage.removePackages(canvasID: canvasID)
        }
    }

    func testOrdinaryCanvasCreatesBlankCADNodeWithoutFileWorkspaceOrDrawingPage() async throws {
        let database = try DatabaseManager.inMemory()
        try await database.migrate()
        let assetStore = CreativeAssetStore(database: database)

        let project = try WorkspaceCanvasRegistry.project(canvasID: canvasID)
        let documentID = try XCTUnwrap(project.documents.first?.id,
                                       "a default canvas carries at least one document")

        let result = await CADCanvasActionBridge.newCADDocumentInCanvas(
            canvasID: canvasID,
            documentID: documentID,
            position: CanvasPoint(x: 100, y: 100),
            assetStore: assetStore)
        let nodeID = try XCTUnwrap(result.nodeID,
                                   "blank CAD creation failed: \(result.message)")

        // The node binds a canvas-owned package key.
        let updated = try WorkspaceCanvasRegistry.project(canvasID: canvasID)
        let node = try XCTUnwrap(updated.documents.flatMap(\.nodes).first { $0.id == nodeID })
        XCTAssertTrue(CADCanvasNodePlanner.isNativeCADNode(node))
        let key = try XCTUnwrap(node.metadata[CADCanvasNodePlanner.MetadataKeys.sourcePath])
        XCTAssertTrue(CanvasCADStorage.isCanvasOwnedKey(key),
                      "the node must bind the app-owned canvas storage, got \(key)")
        let packageURL = try XCTUnwrap(CADCanvasActionBridge.packageURL(forSourceKey: key))

        // The rendered asset is real PNG bytes (viewport render or the
        // explicit placeholder — never a missing file).
        let renderPath = try XCTUnwrap(node.asset?.localRelativePath)
        guard renderPath.hasPrefix("Materials/") else {
            return XCTFail("the node asset must live in the material library, got \(renderPath)")
        }
        let support = try FileManager.default.url(for: .applicationSupportDirectory,
                                                  in: .userDomainMask,
                                                  appropriateFor: nil, create: false)
        let renderURL = support.appendingPathComponent("FloeAgent")
            .appendingPathComponent(renderPath)
        let renderData = try Data(contentsOf: renderURL)
        XCTAssertFalse(renderData.isEmpty, "the canvas node must carry a rendered preview")
        XCTAssertEqual(renderData.prefix(2), Data([0x89, 0x50]),
                       "the preview must be PNG bytes")
        XCTAssertNotNil(node.asset?.contentHash)
        XCTAssertEqual(node.metadata["preview"], "viewport",
                       "on a Metal-capable device the preview is the real viewport render")

        // The EDITABLE package exists and — the regression — has ZERO drawing
        // pages: creation must not require a sheet.
        XCTAssertTrue(FileManager.default.fileExists(atPath: packageURL.path))
        let document = try await FloeCADDocument.open(at: packageURL)
        defer { document.close() }
        XCTAssertEqual(document.summary().drawingPageCount, 0,
                       "a blank CAD document has no drawing page")
        // It is editable through the typed vocabulary.
        let sketch = document.executeJSON(
            Data(#"{"op":"sketch.create","args":{"name":"First"}}"#.utf8))
        XCTAssertTrue(sketch.isOK, sketch.message ?? "sketch.create failed")
        let save = await document.save()
        XCTAssertTrue(save.succeeded, save.error ?? "")

        // Retrying the same creation must NOT create a second orphan: the
        // pending record was cleared on success and a second node refuses
        // only if a binding already exists — here we assert the first bind
        // left exactly ONE node for the package.
        let nodes = updated.documents.flatMap(\.nodes).filter {
            CanvasCADStorage.isCanvasOwnedKey(
                $0.metadata[CADCanvasNodePlanner.MetadataKeys.sourcePath])
        }
        XCTAssertEqual(nodes.count, 1)
    }

    /// The node display title follows the UI language while the bound
    /// package's file-name identity stays the stable English stem — a device
    /// language switch must never break the `canvas-cad:` binding.
    func testNodeTitleIsLocalizedDefaultButPackageIdentityStaysStable() async throws {
        let database = try DatabaseManager.inMemory()
        try await database.migrate()
        let assetStore = CreativeAssetStore(database: database)

        let project = try WorkspaceCanvasRegistry.project(canvasID: canvasID)
        let documentID = try XCTUnwrap(project.documents.first?.id)

        let result = await CADCanvasActionBridge.newCADDocumentInCanvas(
            canvasID: canvasID,
            documentID: documentID,
            position: CanvasPoint(x: 200, y: 200),
            assetStore: assetStore)
        let nodeID = try XCTUnwrap(result.nodeID, result.message)
        let updated = try WorkspaceCanvasRegistry.project(canvasID: canvasID)
        let node = try XCTUnwrap(updated.documents.flatMap(\.nodes).first { $0.id == nodeID })

        XCTAssertEqual(node.text, CADCanvasNodePlanner.defaultDisplayName())
        // The test host runs English: the default title is "CAD Model".
        XCTAssertEqual(node.text, "CAD Model")

        let key = try XCTUnwrap(node.metadata[CADCanvasNodePlanner.MetadataKeys.sourcePath])
        let packageURL = try XCTUnwrap(CADCanvasActionBridge.packageURL(forSourceKey: key))
        // The on-disk identity keeps the stable English stem regardless of
        // the localized display title.
        XCTAssertTrue(packageURL.lastPathComponent.hasPrefix("CAD Model"),
                      "package file name must keep the stable stem, got \(packageURL.lastPathComponent)")
        XCTAssertTrue(packageURL.lastPathComponent.hasSuffix(".floecad"))
    }

    /// The preview pipeline must refuse an uncommitted/conflicted draft BEFORE
    /// any canvas publish (review 2026-10-10): a failed save throws, keeps the
    /// draft alive, and produces no bytes for a node.
    func testExportPreviewRefusesWhenSaveFails() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("floe-cad-save-guard-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("ReadOnly.floecad")
        let document = try await FloeCADDocument.create(at: url, name: "ReadOnly")
        defer { document.close() }

        // Real geometry so a preview would otherwise be produced.
        let sketch = document.executeJSON(
            Data(#"{"op":"sketch.create","args":{"name":"S"}}"#.utf8))
        XCTAssertTrue(sketch.isOK, sketch.message ?? "")
        let sketchID = try XCTUnwrap(
            ((try? JSONSerialization.jsonObject(with: sketch.payload)) as? [String: Any])?["sketchID"] as? String)
        _ = document.executeJSON(Data("""
        {"op":"sketch.addEntities","args":{"sketchID":"\(sketchID)",
         "entities":[{"kind":"rect","min":[0,0],"max":[10,10]}]}}
        """.utf8))
        _ = document.executeJSON(Data("""
        {"op":"feature.extrude","args":{"sketchID":"\(sketchID)","seedPoint":[5,5],"distance":10}}
        """.utf8))
        XCTAssertTrue(document.hasUnsavedChanges)

        // Force the next save to fail: the package and its parent are
        // read-only, so neither an in-package write nor a swap can commit.
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: url.path)
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: directory.path)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
        }

        do {
            let exported = try await CADCanvasActionBridge.exportPNG(document: document, url: url)
            XCTFail("a failed save must refuse the preview (got \(exported.data.count) bytes)")
        } catch let error as CADDocumentError {
            XCTAssertEqual(error.code, "save_failed",
                           "the refusal must be an explicit save failure, got \(error.code)")
        }
        // The draft is preserved for retry, never discarded.
        XCTAssertTrue(document.hasUnsavedChanges)
    }
}
#endif
