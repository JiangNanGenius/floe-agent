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
import simd
@testable import FloeCAD
@testable import FloeApp
import FloePersistence
import FloeCore

@MainActor
final class NativeCADCanvasBackupTests: XCTestCase {

    private var canvasID: UUID!
    private var importedCanvasID: UUID?
    private var workDir: URL!
    private var openedCADURLs = Set<URL>()

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
        for url in openedCADURLs {
            await FloeCAD3DBridge.shared.releaseDocument(at: url)
        }
        openedCADURLs.removeAll()
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
        openedCADURLs.insert(packageURL)

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
        openedCADURLs.insert(restoredURL)
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

    /// Exercise every native document payload that the Canvas archive must
    /// carry. A valid cube alone cannot detect losing a material resource,
    /// an instance target, a drawing view or an animation during rebinding.
    func testBackupRestoresAssemblyTexturesDrawingAndAnimationAndRemainsEditable() async throws {
        let database = try DatabaseManager.inMemory()
        try await database.migrate()
        let assetStore = CreativeAssetStore(database: database)
        let project = try WorkspaceCanvasRegistry.project(canvasID: canvasID)
        let documentID = try XCTUnwrap(project.documents.first?.id)
        let created = await CADCanvasActionBridge.newCADDocumentInCanvas(
            canvasID: canvasID, documentID: documentID,
            position: CanvasPoint(x: 40, y: 40), assetStore: assetStore)
        _ = try XCTUnwrap(created.nodeID, created.message)
        let canvas = try WorkspaceCanvasRegistry.project(canvasID: canvasID)
        let node = try XCTUnwrap(canvas.documents.flatMap(\.nodes)
            .first { CADCanvasNodePlanner.isNativeCADNode($0) })
        let sourceKey = try XCTUnwrap(node.metadata[CADCanvasNodePlanner.MetadataKeys.sourcePath])
        let sourceURL = try XCTUnwrap(CADCanvasActionBridge.packageURL(forSourceKey: sourceKey))
        openedCADURLs.insert(sourceURL)
        let document = try await FloeCAD3DBridge.shared.openDocument(at: sourceURL)

        func run(_ object: [String: Any]) throws -> [String: Any] {
            let result = document.executeJSON(try JSONSerialization.data(withJSONObject: object))
            XCTAssertTrue(result.isOK, result.message ?? "")
            return try XCTUnwrap(JSONSerialization.jsonObject(with: result.payload) as? [String: Any])
        }
        let sketch = try run(["op": "sketch.create", "args": ["name": "Backup part"]])
        let sketchID = try XCTUnwrap(sketch["sketchID"] as? String)
        _ = try run(["op": "sketch.addEntities", "args": [
            "sketchID": sketchID,
            "entities": [["kind": "rect", "min": [0, 0], "max": [10, 10]]],
        ]])
        _ = try run(["op": "feature.extrude", "args": [
            "sketchID": sketchID, "seedPoint": [5, 5], "distance": 10,
        ]])
        let sourceBody = try XCTUnwrap(document.session.document.bodies.first)
        let bodyID = sourceBody.id.raw
        let featureID = try XCTUnwrap(document.session.document.features.nodes.last?.id.raw)
        let initialVolume = MeasureKit.volume(of: sourceBody)
        XCTAssertGreaterThan(initialVolume, 0)

        let texture = try XCTUnwrap(Data(base64Encoded:
            "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII="))
        let materials = CADMaterialService(document: document)
        let material = materials.handle(action: "create", args: [
            "name": "Backup copper", "color": [0.82, 0.45, 0.2, 1.0],
            "metallic": 1.0, "roughness": 0.25,
            "textures": [["slot": "baseColor", "base64": texture.base64EncodedString()]],
            "uv_mapping": ["source": "boxProjection", "axis": "y",
                           "scale_mm": [10.0, 10.0], "offset": [0.1, -0.2]],
        ])
        XCTAssertEqual(material["ok"] as? Bool, true, "\(material)")
        let materialID = try XCTUnwrap(material["id"] as? String)
        let applied = materials.handle(action: "apply", args: [
            "material_id": materialID, "bodyID": bodyID.uuidString,
        ])
        XCTAssertEqual(applied["ok"] as? Bool, true, "\(applied)")

        let instances = (0..<3).map { index in
            CADAssemblyInstance(name: "Part \(index + 1)", bodyID: bodyID,
                transform: CADTransform(position: SIMD3(Double(index * 20), 0, 0)))
        }
        let assembly = CADAssembly(instances: instances)
        document.session.perform(SetAssemblyDataCommand(
            before: document.session.document.assemblyData, after: try assembly.encoded()))
        let movingInstanceID = try XCTUnwrap(instances.last?.id)

        let drawing = CADDrawingService(document: document).handle(action: "multiViewSheet", args: [
            "assemblyMode": true, "title": "Backup assembly", "paper": "a3",
            "sectionOrigin": [5.0, 5.0, 5.0], "sectionNormal": [0.0, 1.0, 0.0],
        ])
        XCTAssertEqual(drawing["ok"] as? Bool, true, "\(drawing)")
        let page = try XCTUnwrap(drawing["page"] as? [String: Any])
        let pageID = try XCTUnwrap(page["id"] as? String)
        XCTAssertEqual(page["viewCount"] as? Int, 4)
        let frontViewID = try XCTUnwrap((page["views"] as? [[String: Any]])?
            .first { $0["kind"] as? String == "front" }?["id"] as? String)

        let clip = try document.createAnimationClip(name: "Backup motion", duration: 3)
        let track = try document.addAnimationTrack(
            clipID: clip.id, target: .instance(movingInstanceID, sourceBodyID: bodyID))
        _ = try document.setAnimationKeyframe(clipID: clip.id, trackID: track.id, time: 0,
            instance: CADAnimationInstanceValue(translationMM: SIMD3(40, 0, 0)))
        _ = try document.setAnimationKeyframe(clipID: clip.id, trackID: track.id, time: 3,
            instance: CADAnimationInstanceValue(translationMM: SIMD3(40, 30, 0)))
        let expectedAssembly = try XCTUnwrap(document.session.document.assemblyData)
        let expectedDrawings = try XCTUnwrap(document.session.document.drawingsData)
        let expectedAnimation = try XCTUnwrap(document.session.document.animationData)
        let expectedLibrary = try XCTUnwrap(document.session.document.materialLibraryData)
        let save = await document.save()
        XCTAssertTrue(save.succeeded, save.error ?? "")
        await FloeCAD3DBridge.shared.releaseDocument(at: sourceURL)

        let backup = workDir.appendingPathComponent("complete.floeCanvas")
        try WorkspaceCanvasRegistry.exportPackage(canvasID: canvasID, to: backup)
        try WorkspaceCanvasRegistry.delete(canvasID: canvasID)
        CanvasCADStorage.removePackages(canvasID: canvasID)
        XCTAssertFalse(FileManager.default.fileExists(atPath: sourceURL.path))

        let restoredID = try WorkspaceCanvasRegistry.importPackage(from: backup)
        importedCanvasID = restoredID
        let restoredCanvas = try WorkspaceCanvasRegistry.project(canvasID: restoredID)
        let restoredNode = try XCTUnwrap(restoredCanvas.documents.flatMap(\.nodes)
            .first { CADCanvasNodePlanner.isNativeCADNode($0) })
        let restoredKey = try XCTUnwrap(restoredNode.metadata[CADCanvasNodePlanner.MetadataKeys.sourcePath])
        XCTAssertNotEqual(restoredKey, sourceKey)
        XCTAssertEqual(CanvasCADStorage.parse(key: restoredKey)?.canvasID, restoredID)
        let restoredURL = try XCTUnwrap(CADCanvasActionBridge.packageURL(forSourceKey: restoredKey))
        openedCADURLs.insert(restoredURL)
        let reopened = try await FloeCAD3DBridge.shared.openDocument(at: restoredURL)
        XCTAssertEqual(reopened.session.document.assemblyData, expectedAssembly)
        XCTAssertEqual(reopened.session.document.drawingsData, expectedDrawings)
        XCTAssertEqual(reopened.session.document.animationData, expectedAnimation)
        XCTAssertEqual(reopened.session.document.materialLibraryData, expectedLibrary)
        let restoredBody = try XCTUnwrap(reopened.session.document.bodies.first { $0.id.raw == bodyID })
        XCTAssertEqual(restoredBody.material?.baseColorTexture, texture)
        XCTAssertEqual(restoredBody.material?.materialID, materialID)
        XCTAssertEqual(MeasureKit.volume(of: restoredBody), initialVolume, accuracy: 1e-6)
        let restoredAssembly = try CADAssembly.decode(from: reopened.session.document.assemblyData)
        XCTAssertEqual(restoredAssembly.instances.map(\.id), instances.map(\.id))
        XCTAssertEqual(restoredAssembly.instances.map(\.bodyID), [bodyID, bodyID, bodyID])
        XCTAssertEqual(reopened.animationDocument.clip(withID: clip.id)?.tracks.first?.id, track.id)
        XCTAssertEqual(reopened.animationDocument.clip(withID: clip.id)?.tracks.first?.keyframes.count, 2)
        XCTAssertEqual(reopened.summary().drawingPageCount, 1)
        let restoredClip = try XCTUnwrap(reopened.animationDocument.clip(withID: clip.id))
        let motion = CADAnimationEvaluator.evaluate(clip: restoredClip, at: 1.5,
            context: reopened.animationSceneContext())
        XCTAssertTrue(motion.issues.isEmpty, "\(motion.issues)")
        XCTAssertEqual(motion.instances[movingInstanceID]?.translationMM.y ?? -1,
                       15, accuracy: 1e-9)

        // Continue editing each restored authority, then save and open AGAIN.
        let changed = CADParameterService(document: reopened).handle(action: "update", args: [
            "feature_id": featureID.uuidString, "changes": ["distance": 12.0],
        ])
        XCTAssertEqual(changed["ok"] as? Bool, true, "\(changed)")
        let annotation = CADDrawingService(document: reopened).handle(action: "addAnnotation", args: [
            "pageID": pageID, "viewID": frontViewID,
            "text": "Restored drawing", "position": [10.0, 10.0],
        ])
        XCTAssertEqual(annotation["ok"] as? Bool, true, "\(annotation)")
        _ = try reopened.setAnimationKeyframe(clipID: clip.id, trackID: track.id, time: 1.5,
            instance: CADAnimationInstanceValue(translationMM: SIMD3(40, 15, 0)))
        let restoredSave = await reopened.save()
        XCTAssertTrue(restoredSave.succeeded, restoredSave.error ?? "")
        await FloeCAD3DBridge.shared.releaseDocument(at: restoredURL)
        let edited = try await FloeCAD3DBridge.shared.openDocument(at: restoredURL)
        let editedBody = try XCTUnwrap(edited.session.document.bodies.first { $0.id.raw == bodyID })
        XCTAssertEqual(MeasureKit.volume(of: editedBody), initialVolume * 1.2, accuracy: 1e-6)
        XCTAssertEqual(editedBody.material?.baseColorTexture, texture)
        XCTAssertEqual(edited.animationDocument.clip(withID: clip.id)?.tracks.first?.keyframes.count, 3)
        XCTAssertEqual(try CADAssembly.decode(from: edited.session.document.assemblyData)
            .instances.map(\.id), instances.map(\.id))
        XCTAssertEqual(edited.summary().drawingPageCount, 1)
        let editedDrawings = try CADDrawingSet.decode(from: edited.session.document.drawingsData)
        XCTAssertTrue(editedDrawings.pages.first?.annotations.contains {
            $0.text == "Restored drawing"
        } == true)
        await FloeCAD3DBridge.shared.releaseDocument(at: restoredURL)
    }
}
#endif
