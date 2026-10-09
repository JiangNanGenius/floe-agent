//
//  CADAssemblyRenderTests.swift
//  FloeCADKitTests
//
//  Deterministic rendering-data tests for assembly instances: the viewport
//  scene must draw each placement from the SHARED source mesh with the
//  instance's own transform, honor hide/selection, and refresh for
//  solve/update/undo/reopen. No GPU is involved — the scene is the value the
//  renderer consumes.
//
//  SPDX-License-Identifier: MPL-2.0
//

import XCTest
import simd
import Euclid
import OCCTShim
@testable import FloeCAD

final class CADAssemblyRenderTests: XCTestCase {

    private var workDir: URL!
    private var document: FloeCADDocument!

    override func setUp() async throws {
        workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("FloeCADAssemblyRender-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
        document = try await FloeCADDocument.create(
            at: workDir.appendingPathComponent("render.floecad"), name: "Render")
    }

    override func tearDown() async throws {
        document?.close()
        if let workDir { try? FileManager.default.removeItem(at: workDir) }
    }

    private func addCube(name: String) -> Body {
        let body = Body(name: name, transform: .identity, primitive: nil,
                        euclidMesh: .cube(center: Vector(0, 0, 0), size: Vector(10, 10, 10)),
                        revision: 1)
        document.session.perform(AddBodyCommand(body: body, title: "Test \(name)"))
        return body
    }

    private func instances(in scene: ViewportScene) -> [BodyDrawable] {
        scene.bodies.filter { $0.assemblyInstanceID != nil }
    }

    func testInstancesRenderWithOwnTransformsAndSharedMesh() throws {
        let source = addCube(name: "Part")
        let service = CADAssemblyService(document: document)
        let first = service.handle(action: "addInstance", args: [
            "bodyID": source.id.raw.uuidString,
            "name": "A",
            "transform": ["position": [0.0, 0.0, 0.0]],
        ])
        let second = service.handle(action: "addInstance", args: [
            "bodyID": source.id.raw.uuidString,
            "name": "B",
            "transform": ["position": [40.0, 0.0, 0.0]],
        ])
        XCTAssertEqual(first["ok"] as? Bool, true, first["message"] as? String ?? "")
        XCTAssertEqual(second["ok"] as? Bool, true, second["message"] as? String ?? "")
        let firstID = try XCTUnwrap(UUID(uuidString: first["id"] as? String ?? ""))
        let secondID = try XCTUnwrap(UUID(uuidString: second["id"] as? String ?? ""))

        let viewModel = document.viewModel()
        let scene = viewModel.scene
        let drawables = instances(in: scene)
        XCTAssertEqual(drawables.count, 2, "two placed instances must render")
        let byID = Dictionary(uniqueKeysWithValues: drawables.map { ($0.assemblyInstanceID!, $0) })
        let drawableA = try XCTUnwrap(byID[firstID])
        let drawableB = try XCTUnwrap(byID[secondID])
        XCTAssertEqual(drawableA.modelMatrix.columns.3.x, 0, accuracy: 1e-5)
        XCTAssertEqual(drawableB.modelMatrix.columns.3.x, 40, accuracy: 1e-5,
                       "the instance transform must place the drawable")

        // The SHARED source mesh is referenced, not duplicated: same triangle
        // count and the source revision, and the document still has one body.
        XCTAssertEqual(drawableA.renderMesh.triangleCount, source.render.triangleCount)
        XCTAssertEqual(drawableB.renderMesh.positions.count, source.render.positions.count)
        XCTAssertEqual(drawableA.edges?.segments.count, source.edges.segments.count)
        XCTAssertEqual(document.session.document.bodies.count, 1,
                       "shared instances must not duplicate the source body")
        XCTAssertEqual(drawableA.meshRevision, source.meshRevision)
    }

    func testHideSelectUpdateUndoAndReopenRefreshVisiblePlacements() async throws {
        let source = addCube(name: "Part")
        let service = CADAssemblyService(document: document)
        let placed = service.handle(action: "addInstance", args: [
            "bodyID": source.id.raw.uuidString,
            "name": "A",
            "transform": ["position": [30.0, 0.0, 0.0]],
        ])
        let instanceID = try XCTUnwrap(UUID(uuidString: placed["id"] as? String ?? ""))
        let viewModel = document.viewModel()
        XCTAssertEqual(instances(in: viewModel.scene).count, 1)
        XCTAssertEqual(instances(in: viewModel.scene).first?.modelMatrix.columns.3.x ?? -1,
                       30, accuracy: 1e-5)

        // Selection highlights the instance drawable.
        viewModel.selectedAssemblyInstances = [instanceID]
        XCTAssertEqual(instances(in: viewModel.scene).first?.selectionState,
                       SelectionStateSelected.rawValue)
        viewModel.selectedAssemblyInstances = []
        XCTAssertEqual(instances(in: viewModel.scene).first?.selectionState,
                       SelectionStateNone.rawValue)

        // Hide removes the drawable but keeps the instance record.
        _ = service.handle(action: "setVisible", args: ["id": instanceID.uuidString, "hidden": true])
        XCTAssertTrue(instances(in: viewModel.scene).isEmpty,
                      "a hidden instance must not render")
        XCTAssertEqual(document.session.document.assemblyData.flatMap {
            try? CADAssembly.decode(from: $0).instances.count
        }, 1, "hide keeps the instance in the persisted assembly")

        // Unhide again so the placement updates below are visible.
        _ = service.handle(action: "setVisible", args: ["id": instanceID.uuidString, "hidden": false])
        XCTAssertEqual(instances(in: viewModel.scene).count, 1)

        // Update placement → the visible matrix follows.
        _ = service.handle(action: "setTransform", args: [
            "id": instanceID.uuidString,
            "transform": ["position": [70.0, 5.0, 0.0]],
        ])
        XCTAssertEqual(instances(in: viewModel.scene).first?.modelMatrix.columns.3.x ?? -1,
                       70, accuracy: 1e-5)

        // Undo → the previous placement returns (the transform edit was one
        // undoable command).
        viewModel.undo()
        XCTAssertEqual(instances(in: viewModel.scene).first?.modelMatrix.columns.3.x ?? -1,
                       30, accuracy: 1e-5)

        // Reopen → placements render from the persisted assembly.
        _ = service.handle(action: "setVisible", args: ["id": instanceID.uuidString, "hidden": false])
        let save = await document.save()
        XCTAssertTrue(save.succeeded, save.error ?? "")
        document.close()
        let reopened = try await FloeCADDocument.open(
            at: workDir.appendingPathComponent("render.floecad"))
        defer { reopened.close() }
        let reopenedScene = reopened.viewModel().scene
        let reopenedInstances = reopenedScene.bodies.filter { $0.assemblyInstanceID == instanceID }
        XCTAssertEqual(reopenedInstances.count, 1,
                       "a reopened document must render its persisted instances")
        XCTAssertEqual(reopenedInstances.first?.modelMatrix.columns.3.x ?? -1, 30, accuracy: 1e-5)
    }

    func testIndependentCopyInstanceRendersItsOwnBodyTransform() throws {
        let source = addCube(name: "Part")
        let service = CADAssemblyService(document: document)
        let placed = service.handle(action: "addInstance", args: [
            "bodyID": source.id.raw.uuidString,
            "name": "Copy",
            "transform": ["position": [25.0, 0.0, 0.0]],
            "independentCopy": true,
        ])
        XCTAssertEqual(placed["ok"] as? Bool, true, placed["message"] as? String ?? "")
        let copiedBodyID = try XCTUnwrap(UUID(uuidString: placed["copiedBodyID"] as? String ?? ""))
        XCTAssertEqual(document.session.document.bodies.count, 2,
                       "an independent copy owns a distinct body")
        XCTAssertTrue(document.session.document.bodies.contains { $0.id.raw == copiedBodyID })
        let scene = document.viewModel().scene
        let drawable = try XCTUnwrap(scene.bodies.first { $0.assemblyInstanceID != nil })
        XCTAssertEqual(drawable.modelMatrix.columns.3.x, 25, accuracy: 1e-5)
        XCTAssertNotEqual(drawable.id.raw, source.id.raw)
        XCTAssertEqual(drawable.id.raw,
                       try XCTUnwrap(UUID(uuidString: placed["id"] as? String ?? "")),
                       "an instance drawable carries the INSTANCE identity for hit routing")
    }
}
