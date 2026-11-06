// SPDX-License-Identifier: MPL-2.0
import XCTest
import Foundation
import simd
@testable import FloeCAD

@MainActor final class CADSketchTransferTests: XCTestCase {
    private func source(unit: Double? = 1, omissions: Bool = false) throws -> CADSketchTransferEnvelope {
        let bytes = Data("0\nSECTION\n2\nENTITIES\n0\nLINE\n5\nA\n8\nWALLS\n10\n10\n20\n20\n11\n20\n21\n20\n0\nENDSEC\n0\nEOF\n".utf8)
        let ocs: [String: Any] = ["normal": [0,0,1], "elevation": 0]
        var object: [String: Any] = ["schemaVersion": 1, "format": "dxf", "drawingVersion": "AC1015",
            "draftRevision": 2, "insertionUnits": unit == nil ? 0 : (unit == 25.4 ? 1 : 4), "unitName": unit == nil ? "unitless drawing units" : (unit == 25.4 ? "inches" : "millimeters"),
            "selectedHandles": omissions ? ["A","B","C"] : ["A","B"], "selectedLayers": ["WALLS"],
            "sourcePlane": ["origin": [0,0,0], "xAxis": [1,0,0], "yAxis": [0,1,0]],
            "curves": [
                ["kind": "line", "handle": "A", "layer": "WALLS", "sourceEntityType": "Line", "ocs": ocs, "start": [10,20], "end": [20,20]],
                ["kind": "arc", "handle": "B", "layer": "WALLS", "sourceEntityType": "LwPolyline", "ocs": ocs, "center": [10,10], "radius": 5, "startAngle": 0, "sweepAngle": -Double.pi/2]
            ],
            "omissions": omissions ? [["handle": "C", "layer": "WALLS", "entityType": "Text", "reason": "Not a sketch curve"]] : []]
        if let unit { object["unitScaleMM"] = unit }
        let snapshot = try CADSketchTransferSnapshot.decodeValidated(JSONSerialization.data(withJSONObject: object))
        return try CADSketchTransferEnvelope(purpose: .modelSketch, sourceName: "plan.dxf",
            sourceSHA256: CADSketchTransferEnvelope.digest(bytes), sourceIdentity: "fixture|plan.dxf",
            sourceBytes: bytes, snapshot: snapshot)
    }
    private func fixture() async throws -> (URL, FloeCADDocument) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("SketchTransfer-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return (directory, try await FloeCADDocument.create(at: directory.appendingPathComponent("Model.floecad"), name: "Transfer"))
    }
    func testSelectedPlaneImportIsOneUndoAndRetainsSourceOnReopen() async throws {
        let (directory, document) = try await fixture()
        defer { document.close(); try? FileManager.default.removeItem(at: directory) }
        let plane = ConstructionPlane(plane: SketchPlane(origin: SIMD3(7,8,9), xAxis: SIMD3(0,0,-1), yAxis: SIMD3(0,1,0)), size: 200)
        document.session.perform(AddConstructionPlaneCommand(plane: plane))
        let model = document.viewModel(); model.selectedPlaneID = plane.id
        let input = try source(unit: 25.4)
        let placement = CADSketchTransferPlacement(target: .selected, sourceAnchor: [10,20], offsetMM: [3,4], rotationDegrees: 90)
        try model.importDrawingTransfer(input, placement: placement)
        let imported = try XCTUnwrap(document.session.document.sketches.last)
        XCTAssertEqual(imported.plane, plane.plane)
        XCTAssertEqual(imported.support?.source, .construction(plane.id))
        guard case let .line(_, a, b) = imported.entities[0] else { return XCTFail("exact line missing") }
        XCTAssertEqual(a.x, 3, accuracy: 1e-8); XCTAssertEqual(a.y, 4, accuracy: 1e-8)
        XCTAssertEqual(b.x, 3, accuracy: 1e-8); XCTAssertEqual(b.y, 258, accuracy: 1e-8)
        guard case let .arc(_, _, radius, start, end) = imported.entities[1] else { return XCTFail("bulge arc was flattened") }
        XCTAssertEqual(radius, 127, accuracy: 1e-8)
        XCTAssertEqual(SketchEntity.arcSweep(startAngle: start, endAngle: end), .pi/2, accuracy: 1e-8)
        document.session.undo(); XCTAssertTrue(document.session.document.sketches.isEmpty)
        document.session.redo(); XCTAssertEqual(document.session.document.sketches.count, 1)
        let saved = await document.save(); XCTAssertTrue(saved.succeeded, saved.error ?? "")
        let reopened = try await FloeCADDocument.open(at: document.url)
        defer { reopened.close() }
        let restored = try XCTUnwrap(reopened.session.document.sketches.first?.drawingSource)
        XCTAssertEqual(restored.sourceBytes, input.sourceBytes); XCTAssertEqual(restored.sourceSHA256, input.sourceSHA256)
        XCTAssertEqual(restored.snapshot, input.snapshot); XCTAssertEqual(restored.placement, placement)
    }
    func testFrontTopSideGroupsAlignWithoutAutomaticReconstruction() async throws {
        let (directory, document) = try await fixture()
        defer { document.close(); try? FileManager.default.removeItem(at: directory) }
        for target in [CADSketchTransferPlacement.Target.front, .top, .right] {
            try document.viewModel().importDrawingTransfer(source(), placement: CADSketchTransferPlacement(target: target, sourceAnchor: [10,20]))
        }
        let sketches = document.session.document.sketches
        XCTAssertEqual(sketches.count, 3); XCTAssertTrue(document.session.document.bodies.isEmpty)
        XCTAssertEqual(sketches[0].plane, .worldXY); XCTAssertEqual(sketches[1].plane, .ground); XCTAssertEqual(sketches[2].plane, .worldYZ)
        for sketch in sketches { guard case let .line(_, a, _) = sketch.entities[0] else { return XCTFail() }; XCTAssertEqual(sketch.plane.toWorld(a), .zero) }
    }
    func testUnknownUnitsAndPartialSelectionRequireExplicitChoices() async throws {
        let (directory, document) = try await fixture()
        defer { document.close(); try? FileManager.default.removeItem(at: directory) }
        let model = document.viewModel(), input = try source(unit: nil, omissions: true)
        XCTAssertThrowsError(try model.importDrawingTransfer(input, placement: .init(target: .front)))
        XCTAssertThrowsError(try model.importDrawingTransfer(input, placement: .init(target: .front, unitScaleMM: 1)))
        XCTAssertTrue(document.session.document.sketches.isEmpty)
        try model.importDrawingTransfer(input, placement: .init(target: .front, unitScaleMM: 1, acceptOmissions: true))
        XCTAssertEqual(document.session.document.sketches.count, 1)
    }
    func testUnknownNestedFieldsAndCorruptSourceCannotRoundTripAsKnown() throws {
        let input = try source()
        var raw = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(input)) as? [String: Any])
        try CADSketchTransferEnvelope.validateStoredJSONObject(raw)
        var snapshot = try XCTUnwrap(raw["snapshot"] as? [String: Any]); var curves = try XCTUnwrap(snapshot["curves"] as? [[String: Any]])
        curves[0]["futureCurve"] = ["kind": "spline"]; snapshot["curves"] = curves; raw["snapshot"] = snapshot
        XCTAssertThrowsError(try CADSketchTransferEnvelope.validateStoredJSONObject(raw))
        var corrupt = input; corrupt.sourceBytes.append(0)
        XCTAssertThrowsError(try corrupt.validate())
    }
}
