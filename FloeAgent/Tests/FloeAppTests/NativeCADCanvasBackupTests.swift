// FloeAppTests — canvas ZIP backup carries the EDITABLE native CAD package.
//
// Production path end to end: create a canvas-owned CAD document from an
// ordinary canvas (the same bridge the toolbar uses), edit it into real
// geometry, export the canvas backup, delete the canvas AND its on-device
// package, import the backup, and REOPEN the restored package to prove the
// document (not just its PNG render) survived with its geometry intact and
// its node binding rewritten onto the restored canvas identity.
//
// SPDX-License-Identifier: MPL-2.0

#if canImport(SwiftUI) && canImport(UIKit)
import XCTest
import FloeCAD
@testable import FloeApp
import FloePersistence
import FloeCore

@MainActor
final class NativeCADCanvasBackupTests: XCTestCase {

    private var canvasID: UUID!
    private var importedCanvasID: UUID?
    private var workDir: URL!

    override func setUp() async throws {
        canvasID = UUID()
        workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("floe-cad-backup-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
        try WorkspaceCanvasRegistry.createIfNeeded(canvasID: canvasID,
                                                   name: "Backup Canvas",
                                                   workspaceID: nil)
    }

    override func tearDown() async throws {
        try? WorkspaceCanvasRegistry.delete(canvasID: canvasID)
        CanvasCADStorage.removePackages(canvasID: canvasID)
        if let importedCanvasID {
            try? WorkspaceCanvasRegistry.delete(canvasID: importedCanvasID)
            CanvasCADStorage.removePackages(canvasID: importedCanvasID)
        }
        if let workDir { try? FileManager.default.removeItem(at: workDir) }
    }

    func testExportImportReopensEditableGeometryUnderNewCanvasIdentity() async throws {
        let database = try DatabaseManager.inMemory()
        try await database.migrate()
        let assetStore = CreativeAssetStore(database: database)

        let project = try WorkspaceCanvasRegistry.project(canvasID: canvasID)
        let documentID = try XCTUnwrap(project.documents.first?.id)

        // 1. Create the CAD node the production toolbar creates.
        let created = await CADCanvasActionBridge.newCADDocumentInCanvas(
            canvasID: canvasID, documentID: documentID,
            position: CanvasPoint(x: 40, y: 40), assetStore: assetStore)
        _ = try XCTUnwrap(created.nodeID, created.message)
        let canvasProject = try WorkspaceCanvasRegistry.project(canvasID: canvasID)
        let node = try XCTUnwrap(canvasProject.documents.flatMap(\.nodes)
            .first { CADCanvasNodePlanner.isNativeCADNode($0) })
        let originalKey = try XCTUnwrap(
            node.metadata[CADCanvasNodePlanner.MetadataKeys.sourcePath])
        let packageURL = try XCTUnwrap(CADCanvasActionBridge.packageURL(forSourceKey: originalKey))
        let name = try XCTUnwrap(CanvasCADStorage.parse(key: originalKey)).packageFileName

        // 2. Give the package REAL geometry (a 10 mm cube through the typed
        // vocabulary), so the reopen can prove more than bytes.
        let document = try await FloeCAD3DBridge.shared.openDocument(at: packageURL)
        let sketch = document.executeJSON(
            Data(#"{"op":"sketch.create","args":{"name":"Cube"}}"#.utf8))
        XCTAssertTrue(sketch.isOK, sketch.message ?? "")
        let sketchID = try XCTUnwrap(
            ((try? JSONSerialization.jsonObject(with: sketch.payload)) as? [String: Any])?["sketchID"] as? String)
        let rect = document.executeJSON(Data("""
        {"op":"sketch.addEntities","args":{"sketchID":"\(sketchID)",
         "entities":[{"kind":"rect","min":[0,0],"max":[10,10]}]}}
        """.utf8))
        XCTAssertTrue(rect.isOK, rect.message ?? "")
        let extrude = document.executeJSON(Data("""
        {"op":"feature.extrude","args":{"sketchID":"\(sketchID)","seedPoint":[5,5],"distance":10}}
        """.utf8))
        XCTAssertTrue(extrude.isOK, extrude.message ?? "")
        let save = await document.save()
        XCTAssertTrue(save.succeeded, save.error ?? "")
        XCTAssertEqual(document.summary().bodyCount, 1)
        await FloeCAD3DBridge.shared.releaseDocument(at: packageURL)

        // 3. Export the canvas backup (must carry the editable package).
        let destination = workDir.appendingPathComponent("backup.floeCanvas")
        try WorkspaceCanvasRegistry.exportPackage(canvasID: canvasID, to: destination)
        let archiveSize = try FileManager.default
            .attributesOfItem(atPath: destination.path)[.size] as? Int64 ?? 0
        XCTAssertGreaterThan(archiveSize, 0)

        // 4. Destroy the source: canvas JSON and the on-device package. The
        // backup alone must restore both.
        try WorkspaceCanvasRegistry.delete(canvasID: canvasID)
        CanvasCADStorage.removePackages(canvasID: canvasID)
        XCTAssertFalse(FileManager.default.fileExists(atPath: packageURL.path))

        // 5. Import into a fresh canvas identity.
        let restoredCanvasID = try WorkspaceCanvasRegistry.importPackage(from: destination)
        importedCanvasID = restoredCanvasID
        XCTAssertNotEqual(restoredCanvasID, canvasID)

        let restoredProject = try WorkspaceCanvasRegistry.project(canvasID: restoredCanvasID)
        let restoredNode = try XCTUnwrap(restoredProject.documents.flatMap(\.nodes)
            .first { CADCanvasNodePlanner.isNativeCADNode($0) })
        let restoredKey = try XCTUnwrap(
            restoredNode.metadata[CADCanvasNodePlanner.MetadataKeys.sourcePath])
        let binding = try XCTUnwrap(CanvasCADStorage.parse(key: restoredKey))
        XCTAssertEqual(binding.canvasID, restoredCanvasID,
                       "the restored node must bind the RESTORED canvas identity")
        XCTAssertEqual(binding.packageFileName, name,
                       "the package name is preserved verbatim")
        let restoredURL = try XCTUnwrap(CADCanvasActionBridge.packageURL(forSourceKey: restoredKey))
        XCTAssertTrue(FileManager.default.fileExists(atPath: restoredURL.path))

        // 6. Reopen the restored package: the geometry is really there.
        let reopened = try await FloeCAD3DBridge.shared.openDocument(at: restoredURL)
        XCTAssertEqual(reopened.summary().bodyCount, 1,
                       "the editable BODY must survive the backup round trip")
        XCTAssertEqual(reopened.summary().drawingPageCount, 0)
        let snapshot = reopened.snapshotJSON()
        XCTAssertTrue(String(decoding: snapshot, as: UTF8.self).contains("\"bodies\""))
        await FloeCAD3DBridge.shared.releaseDocument(at: restoredURL)
    }
}
#endif
