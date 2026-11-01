//
//  CADDatumAxisPointEditorTests.swift
//  FloeCADKitTests
//
//  M08 native editor source: the shared reference picker creates/reselects an
//  associative axis, the sheet wrappers use the SAME datum service as the
//  assistant, and the pattern panel persists the axis IDENTITY in its spec.
//
//  Root owns the actual iPad run; these tests drive the real
//  EditorViewModel + document + service in-process.
//

import Foundation
import XCTest
import simd
@testable import FloeCAD

@MainActor
final class CADDatumAxisPointEditorTests: XCTestCase {
    private func fixture() async throws -> (directory: URL, document: FloeCADDocument,
                                            source: FeatureNode, body: BodyID) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("DatumAxisPointEditor-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let document = try await FloeCADDocument.create(
            at: directory.appendingPathComponent("Editor.floecad"), name: "Editor")
        let sketch = Sketch(name: "Plate", plane: .ground, entities: [
            .rect(id: UUID(), min: SIMD2(0, 0), max: SIMD2(60, 40)),
        ])
        let body = BodyID()
        let source = FeatureNode(name: "Plate", kind: .extrude(
            profile: ProfileRef(sketchID: sketch.id, entityIDs: sketch.entities.map(\.id),
                                holeEntityIDs: [], seedPoint: SIMD2(30, 20)),
            plane: PlaneRef(source: .sketch(sketch.id)), distance: Expr(value: 10),
            symmetric: false, boolean: BooleanIntent(op: .newBody, resolvedTargets: []),
            extraProfiles: []), outputBodyIDs: [body])
        document.session.recordAndRebuild([source], extra: [AddSketchCommand(sketch: sketch)],
                                          title: "Plate")
        XCTAssertTrue(document.session.lastEvalErrors.isEmpty,
                      "\(document.session.lastEvalErrors)")
        return (directory, document, source, body)
    }

    private func tapFromAbove(_ model: EditorViewModel, at point: SIMD2<Double>) {
        model.handle(.tap(ray: Ray(
            origin: SIMD3<Float>(SketchPlane.ground.toWorld(point)) + SIMD3(0, 100, 0),
            direction: SIMD3(0, -1, 0))))
    }

    private func tapFromBelow(_ model: EditorViewModel, at point: SIMD2<Double>) {
        model.handle(.tap(ray: Ray(
            origin: SIMD3<Float>(SketchPlane.ground.toWorld(point)) - SIMD3(0, 100, 0),
            direction: SIMD3(0, 1, 0))))
    }

    private func onlyAxis(_ document: FloeCADDocument) throws -> ConstructionAxis {
        try XCTUnwrap(document.session.document.axes.first)
    }

    // MARK: - Picker → associative axis

    func testAxisToolCommitsAssociativeFaceAxisAndSheetEditsIt() async throws {
        let f = try await fixture()
        defer {
            f.document.close()
            try? FileManager.default.removeItem(at: f.directory)
        }
        let model = f.document.viewModel()
        model.beginAxisTool()
        tapFromAbove(model, at: SIMD2(30, 20))
        XCTAssertEqual(model.axisPicks.count, 1)
        XCTAssertNotNil(model.axisPickSources.first ?? nil,
                        "the tap must capture the exact kernel face identity")
        XCTAssertEqual(model.axisConstructionLabel, "Perpendicular to Face")
        XCTAssertTrue(model.canCommitAxis)
        model.commitAxis()
        XCTAssertNil(model.errorMessage, model.errorMessage ?? "")

        let axis = try onlyAxis(f.document)
        guard case let .face(definition)? = axis.definition else {
            return XCTFail("a tapped planar face must create an associative face axis")
        }
        XCTAssertEqual(definition.sourceVersion.writer, f.source.id)
        XCTAssertEqual(axis.origin.y, 10, accuracy: 1e-6)
        XCTAssertEqual(model.datumAxisKindLabel(axis.id),
                       FloeCADStrings.text("cad.datum.kind.axisFace", "From Face"))

        // The sheet's offset/length edits go through the datum service. The
        // face axis starts at the CURRENT face centroid, so the offset moves
        // the line from THAT origin (it is not the world origin).
        let baseOrigin = axis.origin
        XCTAssertTrue(model.updateDatumAxisOffset(axis.id, offset: "15", expectedOffset: ""))
        XCTAssertEqual(try onlyAxis(f.document).origin.x, baseOrigin.x + 15, accuracy: 1e-6)
        XCTAssertTrue(model.updateDatumAxisLength(axis.id, length: 42))
        XCTAssertEqual(try onlyAxis(f.document).length, 42, accuracy: 1e-9)
        XCTAssertEqual(model.datumAxisOffsetText(axis.id), "15")

        // Undo restores the axis frame; redo re-applies it.
        f.document.session.undo()
        XCTAssertEqual(try onlyAxis(f.document).origin.x, baseOrigin.x, accuracy: 1e-6)
        f.document.session.redo()
        XCTAssertEqual(try onlyAxis(f.document).origin.x, baseOrigin.x + 15, accuracy: 1e-6)
    }

    func testSharedPickerReselectsTheAxisSource() async throws {
        let f = try await fixture()
        defer {
            f.document.close()
            try? FileManager.default.removeItem(at: f.directory)
        }
        let model = f.document.viewModel()
        model.beginAxisTool()
        tapFromAbove(model, at: SIMD2(30, 20))
        model.commitAxis()
        let axis = try onlyAxis(f.document)
        XCTAssertEqual(axis.origin.y, 10, accuracy: 1e-6)

        XCTAssertTrue(model.beginDatumAxisReselect(axis.id))
        XCTAssertEqual(model.datumPickIntent, .axisReselect(axis.id))
        tapFromBelow(model, at: SIMD2(30, 20))
        model.commitAxis()
        XCTAssertNil(model.errorMessage, model.errorMessage ?? "")
        XCTAssertEqual(try onlyAxis(f.document).origin.y, 0, accuracy: 1e-6)
        XCTAssertEqual(model.datumPickIntent, .axisCreate)
    }

    // MARK: - Pattern identity

    func testPatternPanelPersistsTheAxisIdentityInTheSpec() async throws {
        let f = try await fixture()
        defer {
            f.document.close()
            try? FileManager.default.removeItem(at: f.directory)
        }
        let model = f.document.viewModel()
        model.beginAxisTool()
        tapFromAbove(model, at: SIMD2(30, 20))
        model.commitAxis()
        let axis = try onlyAxis(f.document)

        model.selection = [f.body]
        model.beginPattern()
        XCTAssertEqual(model.patternState?.bodyID, f.body)
        model.patternState?.kind = .circular
        model.patternState?.constructionAxisID = axis.id
        model.patternState?.count = 3
        model.patternState?.totalAngle = 360
        model.commitPattern()
        XCTAssertNil(model.errorMessage, model.errorMessage ?? "")

        let node = try XCTUnwrap(f.document.session.document.features.nodes.first {
            if case .pattern = $0.kind { return true }
            return false
        })
        guard case let .pattern(_, spec) = node.kind else {
            return XCTFail("the pattern node was not recorded")
        }
        XCTAssertEqual(spec.axisRef?.axisID, axis,
                       "the spec must store the axis IDENTITY, not a baked line")
        XCTAssertEqual(spec.kind, .circular)
        XCTAssertEqual(spec.count, 3)
        XCTAssertEqual(node.outputBodyIDs.count, 2)

        // Editing the axis offset carries the recorded pattern copies.
        let before = node.outputBodyIDs.compactMap {
            f.document.session.document.body(with: $0)?.transform.translation
        }
        XCTAssertEqual(before.count, 2)
        XCTAssertTrue(model.updateDatumAxisOffset(axis.id, offset: "12", expectedOffset: ""))
        let after = node.outputBodyIDs.compactMap {
            f.document.session.document.body(with: $0)?.transform.translation
        }
        XCTAssertNotEqual(after, before)

        // The pattern follows the axis for the parameter-service route too.
        // Clearing now FREEZES the axis's current resolved line (M08 R2), so
        // the copies keep the geometry they had and a later source edit no
        // longer moves them.
        let currentLine = try onlyAxis(f.document).resolvedLine
        let reassign = CADParameterService(document: f.document).handle(
            action: "update", args: ["feature_id": node.id.raw.uuidString,
                                     "changes": ["axis_id": NSNull()]])
        XCTAssertEqual(reassign["ok"] as? Bool, true, "\(reassign)")
        guard case let .pattern(_, cleared) = f.document.session.document.features
            .node(node.id)?.kind else {
            return XCTFail("pattern node disappeared")
        }
        XCTAssertNil(cleared.axisRef)
        XCTAssertEqual(cleared.center.x, currentLine.origin.x, accuracy: 1e-9)
        XCTAssertEqual(cleared.center.y, currentLine.origin.y, accuracy: 1e-9)
        XCTAssertEqual(cleared.center.z, currentLine.origin.z, accuracy: 1e-9)
        XCTAssertEqual(cleared.axis, currentLine.direction)
    }

    // MARK: - Datum point sheet path

    func testDatumPointSheetUsesTheServiceAndReportsConsumers() async throws {
        let f = try await fixture()
        defer {
            f.document.close()
            try? FileManager.default.removeItem(at: f.directory)
        }
        let model = f.document.viewModel()
        model.beginAxisTool()
        tapFromAbove(model, at: SIMD2(30, 20))
        model.commitAxis()
        let axis = try onlyAxis(f.document)

        model.openDatumAxisSheet(axis.id)
        XCTAssertTrue(model.showDatumAxisSheet)
        XCTAssertEqual(model.datumAxisSheetID, axis.id)
        model.closeDatumAxisSheet()
        XCTAssertNil(model.datumAxisSheetID)

        XCTAssertTrue(model.createDatumPointFromAxis(axis.id, offset: "4"))
        let point = try XCTUnwrap(f.document.session.document.datumPoints.first)
        XCTAssertEqual(point.position.y, 14, accuracy: 1e-6)
        XCTAssertEqual(point.definition?.kind, .axisPoint)
        XCTAssertEqual(model.datumPointKindLabel(point.id),
                       FloeCADStrings.text("cad.datum.kind.onAxis", "On Axis"))
        XCTAssertTrue(model.showDatumPointSheet)
        XCTAssertEqual(model.datumPointSheetID, point.id)

        // The axis is now consumed: deleting it refuses with the consumer id.
        XCTAssertFalse(model.deleteDatumAxis(axis.id))
        XCTAssertNotNil(model.errorMessage)
        model.errorMessage = nil

        // The point offset edits through the same service and follows the axis.
        XCTAssertTrue(model.updateDatumPointOffset(point.id, offset: "9",
                                                  expectedOffset: "4"))
        XCTAssertEqual(f.document.session.document.datumPoints.first?.position.y, 19,
                       accuracy: 1e-6)

        // Deleting the point frees the axis.
        XCTAssertTrue(model.deleteDatumPoint(point.id))
        XCTAssertTrue(f.document.session.document.datumPoints.isEmpty)
        XCTAssertTrue(model.deleteDatumAxis(axis.id))
        XCTAssertTrue(f.document.session.document.axes.isEmpty)
    }

    func testDatumPointCreationIntentArmsTheSharedPicker() async throws {
        let f = try await fixture()
        defer {
            f.document.close()
            try? FileManager.default.removeItem(at: f.directory)
        }
        let model = f.document.viewModel()
        XCTAssertTrue(model.beginDatumPointFromPick(face: true))
        if case let .pointCreate(kind) = model.datumPickIntent {
            XCTAssertEqual(kind, DatumPointDefinition.Kind.faceCenter.rawValue)
        } else {
            XCTFail("the face-centre intent must arm the shared picker")
        }
        tapFromAbove(model, at: SIMD2(30, 20))
        model.commitAxis()
        XCTAssertNil(model.errorMessage, model.errorMessage ?? "")
        let point = try XCTUnwrap(f.document.session.document.datumPoints.first)
        XCTAssertEqual(point.definition?.kind, .faceCenter)
        XCTAssertEqual(point.position.y, 10, accuracy: 1e-6)
        XCTAssertTrue(f.document.session.document.axes.isEmpty,
                      "a point pick must not also create an axis")

        // Every point identity a two-point axis can name is offered, including
        // the new datum point; no coordinate-only option exists.
        XCTAssertTrue(model.datumPointChoices.contains { choice in
            if case let .datumPoint(id) = choice.source { return id == point.id }
            return false
        })
        XCTAssertTrue(model.constructionPlaneChoices.isEmpty
                      || model.constructionPlaneChoices.count == f.document.session.document.planes.count)
    }
}
