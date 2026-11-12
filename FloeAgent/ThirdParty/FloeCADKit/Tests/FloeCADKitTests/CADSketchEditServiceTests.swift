//
//  CADSketchEditServiceTests.swift
//  FloeCADKitTests
//
//  Focused product-surface tests for the 2D assistant wiring: symbolic
//  constraint add/update/remove, bounded sketch/entity queries, native
//  measurement and an authorized drawing transfer appended into one sketch.
//
//  SPDX-License-Identifier: MPL-2.0
//

import XCTest
@testable import FloeCAD

@MainActor
final class CADSketchEditServiceTests: XCTestCase {
    private var directory: URL!

    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("FloeCADSketchEdit-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }
    override func tearDown() async throws {
        if let directory { try? FileManager.default.removeItem(at: directory) }
    }

    private func document() async throws -> FloeCADDocument {
        try await FloeCADDocument.create(at: directory.appendingPathComponent("test.floecad"), name: "test")
    }
    private func sketch(_ document: FloeCADDocument, name: String = "Sketch") throws -> String {
        let outcome = document.execute(["op": "sketch.create", "args": ["name": name]])
        XCTAssertTrue(outcome.isOK)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: outcome.payload) as? [String: Any])
        return try XCTUnwrap(object["sketchID"] as? String)
    }
    private func addLine(_ document: FloeCADDocument, _ sketchID: String,
                         a: [Double] = [0, 0], b: [Double] = [10, 0]) throws -> String {
        let outcome = document.execute(["op": "sketch.addEntities", "args": [
            "sketchID": sketchID, "entities": [["kind": "line", "a": a, "b": b]],
        ]])
        XCTAssertTrue(outcome.isOK)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: outcome.payload) as? [String: Any])
        return try XCTUnwrap((object["entityIDs"] as? [String])?.first)
    }

    func testConstraintAddUpdateRemoveUseTheRealUndoStack() async throws {
        let document = try await document()
        let sketchID = try sketch(document)
        let lineID = try addLine(document, sketchID)
        let service = CADSketchEditService(document: document)
        let added = service.handle(action: "addSketchConstraint", args: [
            "sketch_id": sketchID, "kind": "horizontal",
            "refs": [["entity_id": lineID, "role": "whole"]],
        ])
        let addReply = added
        XCTAssertEqual(addReply["ok"] as? Bool, true)
        XCTAssertEqual(addReply["mutated"] as? Bool, true)
        let constraint = try XCTUnwrap(addReply["constraint"] as? [String: Any])
        let constraintID = try XCTUnwrap(constraint["id"] as? String)
        XCTAssertEqual(document.session.document.sketches.first?.constraints.count, 1)

        let updated = service.handle(action: "updateSketchConstraint", args: [
            "sketch_id": sketchID, "constraint_id": constraintID, "kind": "vertical",
        ])
        XCTAssertEqual(updated["ok"] as? Bool, true)
        XCTAssertEqual(document.session.document.sketches.first?.constraints.first?.kind.rawValue, "vertical")

        let removed = service.handle(action: "removeSketchConstraint", args: [
            "sketch_id": sketchID, "constraint_id": constraintID,
        ])
        XCTAssertEqual(removed["ok"] as? Bool, true)
        XCTAssertEqual(document.session.document.sketches.first?.constraints.count, 0)

        let undo = CADParameterService(document: document).handle(action: "undo", args: [:])
        XCTAssertEqual(undo["ok"] as? Bool, true)
        XCTAssertEqual(document.session.document.sketches.first?.constraints.count, 1)
        XCTAssertEqual(document.session.document.sketches.first?.constraints.first?.kind.rawValue, "vertical")
        let redo = CADParameterService(document: document).handle(action: "redo", args: [:])
        XCTAssertEqual(redo["ok"] as? Bool, true)
        XCTAssertEqual(document.session.document.sketches.first?.constraints.count, 0)
    }

    func testBoundedSketchQueryAndNativeMeasurementsReadTheLiveGraph() async throws {
        let document = try await document()
        let sketchID = try sketch(document, name: "Measured")
        let lineID = try addLine(document, sketchID)
        let _ = document.execute(["op": "sketch.addEntities", "args": [
            "sketchID": sketchID, "entities": [["kind": "circle", "center": [30, 0], "radius": 5]],
        ]])
        let page = document.nativeQueryJSON(["scope": "sketches", "sketchOffset": 0, "sketchLimit": 1,
                                             "entityOffset": 0, "entityLimit": 1])
        XCTAssertTrue(page.isOK)
        let pageObject = try XCTUnwrap(JSONSerialization.jsonObject(with: page.payload) as? [String: Any])
        XCTAssertEqual(pageObject["total"] as? Int, 1)
        XCTAssertEqual(pageObject["sketchesComplete"] as? Bool, true)
        let row = try XCTUnwrap((pageObject["rows"] as? [[String: Any]])?.first)
        XCTAssertEqual(row["entityTotal"] as? Int, 2)
        XCTAssertEqual(row["entityRowsComplete"] as? Bool, false)
        XCTAssertEqual((row["entityRows"] as? [[String: Any]])?.count, 1)

        let entityMeasure = document.nativeQueryJSON(["scope": "measure", "kind": "entity",
                                                     "sketchID": sketchID, "entityID": lineID])
        XCTAssertTrue(entityMeasure.isOK)
        let entityObject = try XCTUnwrap(JSONSerialization.jsonObject(with: entityMeasure.payload) as? [String: Any])
        XCTAssertEqual(entityObject["lengthMM"] as? Double, 10)
        XCTAssertEqual(entityObject["entityKind"] as? String, "line")

        let area = document.nativeQueryJSON(["scope": "measure", "kind": "area", "sketchID": sketchID])
        XCTAssertTrue(area.isOK)
        let areaObject = try XCTUnwrap(JSONSerialization.jsonObject(with: area.payload) as? [String: Any])
        let areaRows = try XCTUnwrap(areaObject["rows"] as? [[String: Any]])
        XCTAssertTrue(areaRows.contains { abs(($0["areaMM2"] as? Double ?? 0) - .pi * 25) < 1e-9 })

        let check = document.nativeQueryJSON(["scope": "measure", "kind": "check"])
        XCTAssertTrue(check.isOK)
        let checkObject = try XCTUnwrap(JSONSerialization.jsonObject(with: check.payload) as? [String: Any])
        XCTAssertEqual(checkObject["ok"] as? Bool, true)
    }

    func testDrawingTransferAppendsRealEntitiesAndUndoRestoresTheSketch() async throws {
        let document = try await document()
        let sketchID = try sketch(document, name: "Imported")
        let sourceBytes = Data("dxf-source".utf8)
        let digest = CADSketchTransferEnvelope.digest(sourceBytes)
        let snapshot = CADSketchTransferSnapshot(
            schemaVersion: 1, format: "dxf", drawingVersion: "AC1027", draftRevision: 0,
            insertionUnits: 4, unitName: "mm", unitScaleMM: 1,
            selectedHandles: ["L1"], selectedLayers: ["0"],
            sourcePlane: CADSketchTransferPlane(origin: [0, 0, 0], xAxis: [1, 0, 0], yAxis: [0, 1, 0]),
            curves: [CADSketchTransferCurve(
                kind: .line, handle: "L1", layer: "0", sourceEntityType: "LINE",
                ocs: CADSketchTransferOCS(normal: [0, 0, 1], elevation: 0),
                start: [0, 0], end: [25, 0], center: nil, radius: nil,
                startAngle: nil, sweepAngle: nil)],
            omissions: [])
        let envelope = try CADSketchTransferEnvelope(
            purpose: .modelSketch, sourceName: "test.dxf", sourceSHA256: digest,
            sourceBytes: sourceBytes, snapshot: snapshot)
        let receipt = try CADSketchEditService(document: document).importDrawingSketch(
            envelope, into: UUID(uuidString: sketchID)!, placement: .init(target: .selected, unitScaleMM: 1))
        XCTAssertEqual(receipt.entityIDs.count, 1)
        XCTAssertEqual(document.session.document.sketches.first?.entities.count, 1)
        let undo = CADParameterService(document: document).handle(action: "undo", args: [:])
        XCTAssertEqual(undo["ok"] as? Bool, true)
        XCTAssertEqual(document.session.document.sketches.first?.entities.count, 0)
    }
}
