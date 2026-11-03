// SPDX-License-Identifier: MPL-2.0
import XCTest
import Foundation
import simd
@testable import FloeCAD
#if canImport(UIKit)
import UIKit
#endif

/// Actual document/service/feature/assembly/save paths. These are test sources;
/// the private packet does not claim they were compiled or executed.
@MainActor
final class CADSceneObjectHierarchyTests: XCTestCase {
    private var directory: URL!
    private var owned: [FloeCADDocument] = []
    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("SceneObjects-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }
    override func tearDown() async throws {
        owned.forEach { $0.close() }; owned = []
        if let directory { try? FileManager.default.removeItem(at: directory) }
    }

    private func fixture() async throws -> (FloeCADDocument, FeatureNode, BodyID) {
        let document = try await FloeCADDocument.create(at: directory.appendingPathComponent("\(UUID()).floecad"), name: "Objects")
        owned.append(document)
        let id = BodyID()
        let base = FeatureNode(name: "Base", kind: .primitive(spec: .box(width: 10, depth: 8, height: 6), placement: .identity), outputBodyIDs: [id])
        document.session.recordAndRebuild([base], title: "Fixture")
        XCTAssertTrue(document.session.lastEvalErrors.isEmpty)
        return (document, base, id)
    }
    @discardableResult
    private func run(_ document: FloeCADDocument, _ action: String, _ args: [String: Any] = [:],
                     file: StaticString = #filePath, line: UInt = #line) -> [String: Any] {
        let reply = CADViewOverlayService(document: document).handle(action: action, args: args)
        XCTAssertEqual(reply["ok"] as? Bool, true, "\(reply)", file: file, line: line)
        return reply
    }
    private func group(_ document: FloeCADDocument, _ name: String) throws -> String {
        try XCTUnwrap(run(document, "object.createGroup", ["name": name])["id"] as? String)
    }
    private func pose(_ x: Double, yaw: Double = 0) -> CADTransform {
        CADTransform(position: SIMD3(x, 0, 0), rotation: simd_quatd(angle: yaw, axis: SIMD3(0, 1, 0)).vector)
    }
    private func move(_ document: FloeCADDocument, _ id: String, _ value: CADTransform) {
        run(document, "object.transform", ["id": id, "frame": "world", "transform": CADSceneObjectCodec.transformJSON(value)])
    }
    private func row(_ document: FloeCADDocument, _ id: UUID) throws -> [String: Any] {
        let rows = run(document, "objects")["objects"] as? [[String: Any]] ?? []
        return try XCTUnwrap(rows.first { $0["id"] as? String == id.uuidString })
    }
    private func x(_ row: [String: Any], _ key: String) throws -> Double {
        try XCTUnwrap((row[key] as? [String: Any])?["position"] as? [Double]).first ?? .nan
    }

    func testKeepWorldManagedFeatureUpstreamRebuildUndoAndReopen() async throws {
        let (document, base, bodyID) = try await fixture()
        let a = try group(document, "A"), b = try group(document, "B")
        run(document, "object.reparent", ["id": bodyID.raw.uuidString, "parent_id": a])
        move(document, a, pose(10, yaw: .pi / 2))
        let managed = CADSceneObjectCodec.placementID(bodyID.raw)
        let firstIDs = document.session.document.features.nodes.map(\.id)
        XCTAssertEqual(firstIDs.filter { $0 == managed }.count, 1)
        XCTAssertEqual(try XCTUnwrap(document.session.document.body(with: bodyID)).transform.translation.x, 10, accuracy: 1e-8)
        move(document, a, pose(20, yaw: .pi / 2))
        XCTAssertEqual(document.session.document.features.nodes.map(\.id), firstIDs, "Group motion edits one stable transform feature instead of appending a chain")
        move(document, b, pose(100))
        let before = try XCTUnwrap(document.session.document.body(with: bodyID)).transform
        run(document, "object.reparent", ["id": bodyID.raw.uuidString, "parent_id": b, "keep_world": true])
        XCTAssertEqual(document.session.document.body(with: bodyID)?.transform, before)
        XCTAssertEqual(try x(row(document, bodyID.raw), "local"), -80, accuracy: 1e-8)
        move(document, b, pose(110))
        XCTAssertEqual(try x(row(document, bodyID.raw), "world"), 30, accuracy: 1e-8)
        let edit = EditFeatureCommand(featureID: base.id, before: base.kind,
            after: .primitive(spec: .box(width: 12, depth: 8, height: 6), placement: .identity))
        document.session.rebuildFrom(base.id, edit: edit)
        XCTAssertTrue(document.session.lastEvalErrors.isEmpty)
        XCTAssertEqual(try x(row(document, bodyID.raw), "world"), 30, accuracy: 1e-8)
        XCTAssertEqual(document.session.document.features.nodes.map(\.id), firstIDs)
        document.session.undo() // only upstream size edit
        document.session.undo() // one group move restores both group and body
        XCTAssertEqual(try x(row(document, bodyID.raw), "world"), 20, accuracy: 1e-8)
        XCTAssertEqual(try x(row(document, try XCTUnwrap(UUID(uuidString: b))), "world"), 100, accuracy: 1e-8)
        document.session.redo()
        let scene = document.sceneSnapshot(includeExplodedPreview: false)
        let rendered = try XCTUnwrap(scene.bodies.first { $0.id == bodyID.raw })
        XCTAssertEqual(rendered.transform[12], 30, accuracy: 1e-8, "The actual renderer snapshot uses the same moved body pose")
        let saved = await document.save(); XCTAssertTrue(saved.succeeded, saved.error ?? "")
        let url = document.url; document.close()
        let reopened = try await FloeCADDocument.open(at: url); owned.append(reopened)
        XCTAssertEqual(try x(row(reopened, bodyID.raw), "world"), 30, accuracy: 1e-8)
        XCTAssertEqual(try row(reopened, bodyID.raw)["parent_id"] as? String, b)
        XCTAssertEqual(reopened.session.document.features.nodes.filter { $0.id == managed }.count, 1)
        XCTAssertEqual(CADDocumentFormat.requiredFormat(document: reopened.session.document), 7)
        let refusedDelete = CADViewOverlayService(document: reopened).handle(action: "object.remove", args: ["id": b])
        XCTAssertEqual(refusedDelete["error"] as? String, "scene_object_referenced")
        run(reopened, "object.remove", ["id": b, "promote_children": true])
        XCTAssertEqual(try row(reopened, bodyID.raw)["parent_id"] as? String, "")
        XCTAssertEqual(try x(row(reopened, bodyID.raw), "world"), 30, accuracy: 1e-8)
        reopened.session.undo()
        XCTAssertEqual(try row(reopened, bodyID.raw)["parent_id"] as? String, b)
        let c = try group(reopened, "C"); move(reopened, c, pose(200))
        run(reopened, "object.reparent", ["id": bodyID.raw.uuidString, "parent_id": c, "keep_world": false])
        XCTAssertEqual(try x(row(reopened, bodyID.raw), "local"), -80, accuracy: 1e-8)
        XCTAssertEqual(try x(row(reopened, bodyID.raw), "world"), 120, accuracy: 1e-8)
        XCTAssertEqual(reopened.session.document.features.nodes.filter { $0.id == managed }.count, 1)
    }

    func testAssemblyOccurrenceScopePreventsDefinitionAndParentChildDoubleTransform() async throws {
        let (document, base, bodyID) = try await fixture()
        document.session.rebuildFrom(base.id, edit: EditFeatureCommand(featureID: base.id, before: base.kind,
            after: .primitive(spec: .box(width: 10, depth: 8, height: 6), placement: Transform3D(translation: SIMD3(3, 0, 0)))))
        let subassemblyID = UUID()
        let parent = CADAssemblyInstance(name: "Subassembly", bodyID: subassemblyID, transform: pose(10), subassemblyID: subassemblyID, children: [
            CADAssemblyInstance(name: "Part", bodyID: bodyID.raw, transform: pose(5))])
        let assembly = CADAssembly(instances: [parent])
        document.session.perform(SetAssemblyDataCommand(before: nil, after: try assembly.encoded()))
        let groupID = try group(document, "Placed products")
        run(document, "object.reparent", ["id": parent.id.uuidString, "parent_id": groupID])
        move(document, groupID, pose(7))
        let after = try CADAssembly.decode(from: document.session.document.assemblyData)
        XCTAssertEqual(after.instance(parent.id)?.transform.position.x, 17)
        let child = try XCTUnwrap(parent.children.first)
        XCTAssertEqual(after.instance(child.id)?.transform.position.x, 5, "Child local placement is never multiplied by the parent delta twice")
        XCTAssertEqual(try x(row(document, child.id), "world"), 22, accuracy: 1e-8)
        // Primitive placement is baked into its real mesh/BRep by the
        // existing evaluator; Body.transform stays identity. A second +3
        // matrix translation would double-apply that same geometry placement.
        XCTAssertEqual(try x(row(document, child.id), "geometry_world"), 22, accuracy: 1e-8)
        XCTAssertEqual(document.session.document.body(with: bodyID)?.transform.translation.x, 0)
        let rendered = try XCTUnwrap(document.sceneSnapshot(includeExplodedPreview: false).bodies.first { $0.id == child.id })
        XCTAssertEqual(rendered.transform[12], 22, accuracy: 1e-8)
        let minX = try XCTUnwrap(rendered.mesh.positions.map(\.x).min())
        let maxX = try XCTUnwrap(rendered.mesh.positions.map(\.x).max())
        XCTAssertEqual(Double(minX + maxX) / 2, 3, accuracy: 1e-8, "Actual definition geometry retains its baked placement")
        XCTAssertEqual(rendered.transform[12] + Double(minX + maxX) / 2, 25, accuracy: 1e-8,
                       "17 parent + 5 child + 3 baked geometry, each exactly once")
        run(document, "object.reparent", ["id": bodyID.raw.uuidString, "parent_id": groupID])
        let beforeScene = document.session.document.sceneSettingsData, beforeAssembly = document.session.document.assemblyData
        let count = document.session.changeCount, undo = document.session.undoStack.undoCommands.count
        let refused = CADViewOverlayService(document: document).handle(action: "object.transform", args: ["id": groupID, "frame": "world", "transform": CADSceneObjectCodec.transformJSON(pose(20))])
        XCTAssertEqual(refused["error"] as? String, "definition_placement_scope")
        XCTAssertEqual(document.session.document.sceneSettingsData, beforeScene)
        XCTAssertEqual(document.session.document.assemblyData, beforeAssembly)
        XCTAssertEqual(document.session.changeCount, count); XCTAssertEqual(document.session.undoStack.undoCommands.count, undo)
        let deletion = CADAssemblyService(document: document).handle(action: "removeInstance", args: ["id": parent.id.uuidString])
        XCTAssertEqual(deletion["ok"] as? Bool, false)
        XCTAssertEqual(document.session.document.assemblyData, beforeAssembly)
        document.session.perform(DeleteBodiesCommand(ids: [bodyID], document: document.session.document))
        XCTAssertNotNil(document.session.document.body(with: bodyID))
        XCTAssertEqual(document.session.lastSceneObjectFailure, .referenced)
    }

    #if canImport(UIKit)
    func testLightCameraResourceAuthorityAndWholeTransactionRefusal() async throws {
        let (document, _, texturedBodyID) = try await fixture()
        let bytes = UIGraphicsImageRenderer(size: CGSize(width: 32, height: 16)).pngData { context in
            UIColor.red.setFill(); context.fill(CGRect(x: 0, y: 0, width: 32, height: 16))
        }
        let map = try CADEnvironmentMap.imported(data: bytes, name: "Own synthetic panorama.png")
        var material = BodyMaterialSpec.default; material.materialID = "own-resource"; material.baseColorTexture = bytes
        document.session.perform(SetMaterialCommand(bodyIDs: [texturedBodyID], material: material, document: document.session.document))
        var appearance = document.viewAppearance
        var light = CADSceneLight(name: "Key", kind: .spot)
        light.positionMM = [1, 2, 3]; light.direction = [0, 0, -1]
        appearance.sceneLights = [light]; appearance.environmentMap = map
        XCTAssertTrue(document.applyViewAppearance(appearance))
        let camera = CADSavedCamera(name: "Shot", targetMM: .zero, distanceMM: 100, azimuthRadians: 0, elevationRadians: 0)
        _ = try document.saveCamera(camera)
        let groupID = try group(document, "Rig")
        for id in [light.id, camera.id] { run(document, "object.reparent", ["id": id.uuidString, "parent_id": groupID]) }
        let resourceBefore = run(document, "object.resources")["resources"] as? [[String: Any]] ?? []
        move(document, groupID, pose(10, yaw: .pi / 2))
        let actualLight = try XCTUnwrap(document.viewAppearance.sceneLights?.first)
        XCTAssertEqual(actualLight.positionMM[0], 13, accuracy: 1e-8)
        XCTAssertEqual(actualLight.positionMM[1], 2, accuracy: 1e-8)
        XCTAssertEqual(actualLight.positionMM[2], -1, accuracy: 1e-8)
        XCTAssertEqual(actualLight.direction[0], -1, accuracy: 1e-8)
        let actualCamera = try XCTUnwrap(document.savedCameras.first { $0.id == camera.id })
        XCTAssertEqual(actualCamera.targetMM.x, 10, accuracy: 1e-8)
        XCTAssertEqual(actualCamera.azimuthRadians, .pi / 2, accuracy: 1e-8)
        XCTAssertEqual(try x(row(document, camera.id), "world"), 110, accuracy: 1e-8)
        XCTAssertEqual(try document.viewAppearance.environmentMap?.checkedBytes(), bytes)
        let resourceAfter = run(document, "object.resources")["resources"] as? [[String: Any]] ?? []
        XCTAssertEqual(resourceAfter.first { $0["kind"] as? String == "texture" }?["sha256"] as? String, CADMaterialTexture.digest(bytes))
        XCTAssertEqual(document.session.document.body(with: texturedBodyID)?.material?.baseColorTexture, bytes)
        XCTAssertEqual(resourceBefore.first { $0["kind"] as? String == "environment" }?["sha256"] as? String,
                       resourceAfter.first { $0["kind"] as? String == "environment" }?["sha256"] as? String)
        let before = document.session.document.sceneSettingsData, undo = document.session.undoStack.undoCommands.count
        var withRoll = pose(10); withRoll.rotation = simd_quatd(angle: .pi / 4, axis: SIMD3(0, 0, 1)).vector
        let refused = CADViewOverlayService(document: document).handle(action: "object.transform", args: ["id": groupID, "frame": "world", "transform": CADSceneObjectCodec.transformJSON(withRoll)])
        XCTAssertEqual(refused["ok"] as? Bool, false)
        XCTAssertEqual(document.session.document.sceneSettingsData, before)
        XCTAssertEqual(document.session.undoStack.undoCommands.count, undo)
        var deletingLight = document.viewAppearance; deletingLight.sceneLights = []
        XCTAssertFalse(document.applyViewAppearance(deletingLight))
        XCTAssertThrowsError(try document.deleteCamera(id: camera.id))
        XCTAssertEqual(document.session.document.sceneSettingsData, before)
        let saved = await document.save(); XCTAssertTrue(saved.succeeded, saved.error ?? "")
        let url = document.url; document.close()
        let reopened = try await FloeCADDocument.open(at: url); owned.append(reopened)
        XCTAssertEqual(try reopened.viewAppearance.environmentMap?.checkedBytes(), bytes)
        XCTAssertEqual(reopened.savedCameras.first?.id, camera.id)
        XCTAssertEqual(reopened.viewAppearance.sceneLights?.first?.id, light.id)
        XCTAssertEqual(try row(reopened, light.id)["parent_id"] as? String, groupID)
    }
    #endif

    func testCycleCancellationStalePinAndDownstreamDependencyPreserveUndo() async throws {
        let (document, _, bodyID) = try await fixture()
        let a = try group(document, "A"), b = try group(document, "B")
        run(document, "object.reparent", ["id": b, "parent_id": a])
        let before = document.session.document.sceneSettingsData, undo = document.session.undoStack.undoCommands.count
        let cycle = CADViewOverlayService(document: document).handle(action: "object.reparent", args: ["id": a, "parent_id": b])
        XCTAssertEqual(cycle["ok"] as? Bool, false)
        XCTAssertEqual(document.session.document.sceneSettingsData, before)
        let cancelled = Task { @MainActor in
            await Task.yield()
            let reply = CADViewOverlayService(document: document).handle(action: "object.createGroup", args: ["name": "Cancelled"])
            return (try? JSONSerialization.data(withJSONObject: reply)) ?? Data()
        }
        cancelled.cancel()
        let cancelledBytes = await cancelled.value
        let cancelledReply = try XCTUnwrap(try JSONSerialization.jsonObject(with: cancelledBytes) as? [String: Any])
        XCTAssertEqual(cancelledReply["error"] as? String, "scene_edit_cancelled")
        let stale = CADViewOverlayService(document: document).handle(action: "object.createGroup", args: ["name": "Stale", "expected_change_count": document.session.changeCount + 1])
        XCTAssertEqual(stale["error"] as? String, "concurrent_edit")
        XCTAssertEqual(document.session.document.sceneSettingsData, before)
        XCTAssertEqual(document.session.undoStack.undoCommands.count, undo)
        run(document, "object.reparent", ["id": bodyID.raw.uuidString, "parent_id": a])
        move(document, a, pose(5))
        let managed = CADSceneObjectCodec.placementID(bodyID.raw)
        let downstream = FeatureNode(name: "Later model edit", kind: .transform(body: BodyRef(producer: managed, bodyID: bodyID), delta: Transform3D(translation: SIMD3(2, 0, 0))), outputBodyIDs: [BodyID()])
        document.session.recordAndRebuild([downstream], title: "Model edit")
        let history = document.session.document.features.nodes.map(\.id)
        let oldPose = document.session.document.body(with: bodyID)?.transform
        let refused = CADViewOverlayService(document: document).handle(action: "object.transform", args: ["id": a, "frame": "world", "transform": CADSceneObjectCodec.transformJSON(pose(9))])
        XCTAssertEqual(refused["error"] as? String, "scene_placement_dependency")
        XCTAssertEqual(document.session.document.features.nodes.map(\.id), history)
        XCTAssertEqual(document.session.document.body(with: bodyID)?.transform, oldPose)
    }

    func testUnknownHierarchyIntentOpensReadOnlyAndOriginalBytesRemain() async throws {
        let (document, _, _) = try await fixture()
        _ = try group(document, "Retained")
        let save = await document.save(); XCTAssertTrue(save.succeeded, save.error ?? "")
        let url = document.url; document.close()
        try CADAssociativeFormatFixture.rewrite(url, schema: 7) { record in
            var root = try XCTUnwrap(try JSONSerialization.jsonObject(with: XCTUnwrap(record.sceneSettings)) as? [String: Any])
            var graph = try XCTUnwrap(root["sceneObjects"] as? [String: Any]); graph["version"] = 99
            root["sceneObjects"] = graph; record.sceneSettings = try JSONSerialization.data(withJSONObject: root)
        }
        let original = try CADAssociativeFormatFixture.bytes(url)
        let reopened = try await FloeCADDocument.open(at: url); owned.append(reopened)
        XCTAssertTrue(reopened.isReadOnly)
        for action in CADSceneObjectService.mutations {
            let result = CADViewOverlayService(document: reopened).handle(action: action, args: [:])
            XCTAssertEqual(result["error"] as? String, "read_only")
            XCTAssertEqual(result["mutated"] as? Bool, false)
        }
        XCTAssertEqual(try CADAssociativeFormatFixture.bytes(url), original)
    }
}
