//
//  CADParameterCorrectnessTests.swift
//  FloeCADKitTests
//
//  Variable fan-out and the public-degrees / persisted-radians boundary.
//  Geometry assertions use the production document/session/parameter service;
//  no renderer or fabricated result is involved.
//

import Foundation
import XCTest
import simd
@testable import FloeCAD

@MainActor
final class CADParameterCorrectnessTests: XCTestCase {
    private var workDir: URL!

    func testNativeIntegerVectorsAndJSONNumbersShareTheCommandContract() throws {
        let sketchID = UUID().uuidString
        let commands: [[String: Any]] = [
            ["op": "sketch.create", "args": ["origin": [10, 20, 0]]],
            ["op": "sketch.addEntities", "args": ["sketchID": sketchID,
                "entities": [["kind": "rect", "min": [0, 0], "max": [100, 60]]]]],
            ["op": "feature.extrude", "args": ["sketchID": sketchID, "seedPoint": [50, 30], "distance": 10]],
            ["op": "feature.extrude", "args": ["sketchID": sketchID,
                "seedPoint": [NSNumber(value: 50), 30.5] as [Any], "distance": 10.0]]
        ]
        for command in commands {
            let encoded = try JSONSerialization.data(withJSONObject: command)
            let decoded = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
            for representation in [command, decoded] {
                if case .failure(let error) = AgentExec.parse(representation) {
                    XCTFail("Equivalent native/JSON numeric input was rejected: \(error)")
                }
            }
        }
        for invalid in [[true, 0] as [Any], ["50", "30"] as [Any], [Double.infinity, 0] as [Any]] {
            let command: [String: Any] = ["op": "feature.extrude", "args": [
                "sketchID": sketchID, "seedPoint": invalid, "distance": 10]]
            if case .success = AgentExec.parse(command) {
                XCTFail("Boolean, string, or non-finite coordinates must not become a numeric vector")
            }
        }
    }

    override func setUp() async throws {
        workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("FloeCADParameterCorrectness-\(UUID().uuidString)",
                                    isDirectory: true)
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        if let workDir { try? FileManager.default.removeItem(at: workDir) }
    }

    private func makeDocument() async throws -> FloeCADDocument {
        try await FloeCADDocument.create(
            at: workDir.appendingPathComponent("\(UUID().uuidString).floecad"),
            name: "Parameter correctness")
    }

    @discardableResult
    private func run(_ document: FloeCADDocument, _ op: String,
                     _ args: [String: Any]) throws -> [String: Any] {
        let input = try JSONSerialization.data(withJSONObject: ["op": op, "args": args])
        let result = document.executeJSON(input)
        XCTAssertTrue(result.isOK, "\(op): \(result.errorCode ?? "") \(result.message ?? "")")
        let payload = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: result.payload) as? [String: Any])
        XCTAssertNotEqual(payload["failed"] as? Bool, true, "\(op): \(payload)")
        XCTAssertTrue(document.session.lastEvalErrors.isEmpty,
                      "\(op): \(document.session.lastEvalErrors)")
        return payload
    }

    private func rows(_ document: FloeCADDocument, _ scope: String) throws -> [[String: Any]] {
        let result = document.nativeQueryJSON(["scope": scope])
        XCTAssertTrue(result.isOK, "\(scope): \(result.message ?? "")")
        let payload = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: result.payload) as? [String: Any])
        return try XCTUnwrap(payload["rows"] as? [[String: Any]])
    }

    private func addRectangleSketch(_ document: FloeCADDocument, y: Double = 0,
                                    withHole: Bool = false) throws -> String {
        let created = try run(document, "sketch.create", [
            "origin": [0, y, 0], "xAxis": [1, 0, 0], "yAxis": [0, 0, -1],
        ])
        let id = try XCTUnwrap(created["sketchID"] as? String)
        var entities: [[String: Any]] = [
            ["kind": "rect", "min": [0, 0], "max": [40, 20]],
        ]
        if withHole {
            entities.append(["kind": "rect", "min": [10, 5], "max": [30, 15]])
        }
        try run(document, "sketch.addEntities", ["sketchID": id, "entities": entities])
        return id
    }

    private func makeBox(_ document: FloeCADDocument,
                         distance: Double = 10, taper: Double = 0) throws -> FeatureNode {
        let sketch = try addRectangleSketch(document)
        try run(document, "feature.extrude", [
            "sketchID": sketch, "seedPoint": [5, 5], "distance": distance,
            "taperDegrees": taper,
        ])
        return try XCTUnwrap(document.session.document.features.nodes.last)
    }

    private func body(_ document: FloeCADDocument) throws -> Body {
        try XCTUnwrap(document.session.document.bodies.first)
    }

    private func volume(_ document: FloeCADDocument) throws -> Double {
        let current = try body(document)
        let result = document.measureJSON(["kind": "body", "bodyID": current.id.raw.uuidString])
        XCTAssertTrue(result.isOK)
        let payload = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: result.payload) as? [String: Any])
        return try XCTUnwrap(payload["volumeMM3"] as? Double)
    }

    private func makeAssociatedSweep(_ document: FloeCADDocument) throws -> (FeatureNode, SketchID, UUID) {
        let profile = try run(document, "sketch.create", [
            "origin": [0, 0, 0], "xAxis": [1, 0, 0], "yAxis": [0, 0, -1]])
        let profileID = try XCTUnwrap(profile["sketchID"] as? String)
        try run(document, "sketch.addEntities", ["sketchID": profileID,
            "entities": [["kind": "circle", "center": [0, 0], "radius": 1]]])
        let path = try run(document, "sketch.create", [
            "origin": [0, 0, 0], "xAxis": [0, 1, 0], "yAxis": [0, 0, 1]])
        let pathID = try XCTUnwrap(path["sketchID"] as? String)
        try run(document, "sketch.addEntities", ["sketchID": pathID,
            "entities": [["kind": "line", "a": [0, 0], "b": [20, 0]]]])
        let sketch = try XCTUnwrap(document.session.document.sketches.first { $0.id.raw.uuidString == pathID })
        let entity = try XCTUnwrap(sketch.entities.first).id
        try run(document, "feature.sweep", ["sketchID": profileID, "seedPoint": [0, 0],
            "path": ["version": 1, "segments": [["sketchID": pathID,
                "entityID": entity.uuidString, "reversed": false]]]])
        return (try XCTUnwrap(document.session.document.features.nodes.last), sketch.id, entity)
    }

    func testSweepFollowsOriginalSketchEdgeAndRetainsIdentityThroughUndoAndReopen() async throws {
        let document = try await makeDocument()
        defer { document.close() }
        let (feature, sketch, edge) = try makeAssociatedSweep(document)
        let originalBody = try body(document).id
        XCTAssertNotNil(try body(document).brep)
        XCTAssertEqual(try volume(document), 20 * .pi, accuracy: 1e-4)
        XCTAssertTrue(feature.referencedSketchIDs.contains(sketch))
        let service = CADParameterService(document: document)
        let reply = service.handle(action: "updateSketchEntity", args: [
            "sketch_id": sketch.raw.uuidString, "entity_id": edge.uuidString, "b": [30, 0]])
        XCTAssertEqual(reply["ok"] as? Bool, true, "\(reply)")
        XCTAssertEqual(try volume(document), 30 * .pi, accuracy: 1e-4)
        XCTAssertEqual(try body(document).id, originalBody)
        XCTAssertNotNil(try body(document).brep)
        let points = try parameter(document, feature: feature.id, name: "spine_points")["value"] as? [[Double]]
        XCTAssertEqual(points?.last, [0, 30, 0])
        document.session.undo()
        XCTAssertEqual(try volume(document), 20 * .pi, accuracy: 1e-4)
        document.session.redo()
        XCTAssertEqual(try volume(document), 30 * .pi, accuracy: 1e-4)
        let saved = await document.save()
        XCTAssertTrue(saved.succeeded, saved.error ?? "")
        let url = document.url; document.close()
        let reopened = try await FloeCADDocument.open(at: url)
        defer { reopened.close() }
        XCTAssertNotNil(reopened.session.document.features.node(feature.id))
        XCTAssertEqual(try body(reopened).id, originalBody)
        XCTAssertEqual(try volume(reopened), 30 * .pi, accuracy: 1e-4)
        XCTAssertNotNil(try body(reopened).brep)
    }

    func testSweepPathReplacementAndExplicitDetachUseCurrentGeometry() async throws {
        let document = try await makeDocument(); defer { document.close() }
        let (feature, sketchID, oldEdge) = try makeAssociatedSweep(document)
        try run(document, "sketch.addEntities", ["sketchID": sketchID.raw.uuidString,
            "entities": [["kind": "line", "a": [0, 0], "b": [40, 0]]]])
        let sketch = try XCTUnwrap(document.session.document.sketches.first { $0.id == sketchID })
        let newEdge = try XCTUnwrap(sketch.entities.first { $0.id != oldEdge }).id
        let service = CADParameterService(document: document)
        let replacement = service.handle(action: "update", args: ["feature_id": feature.id.raw.uuidString,
            "changes": ["path": ["version": 1, "segments": [["sketchID": sketchID.raw.uuidString,
                "entityID": newEdge.uuidString, "reversed": false]]]]])
        XCTAssertEqual(replacement["ok"] as? Bool, true, "\(replacement)")
        XCTAssertEqual(try volume(document), 40 * .pi, accuracy: 1e-4)
        let editedSource = service.handle(action: "updateSketchEntity", args: [
            "sketch_id": sketchID.raw.uuidString, "entity_id": newEdge.uuidString, "b": [50, 0]])
        XCTAssertEqual(editedSource["ok"] as? Bool, true, "\(editedSource)")
        XCTAssertEqual(try volume(document), 50 * .pi, accuracy: 1e-4)
        let detached = service.handle(action: "update", args: ["feature_id": feature.id.raw.uuidString,
            "changes": ["path": NSNull()]])
        XCTAssertEqual(detached["ok"] as? Bool, true, "\(detached)")
        XCTAssertEqual(try volume(document), 50 * .pi, accuracy: 1e-4,
            "Detach must freeze the current resolved path, not its old20mm cache")
        let later = service.handle(action: "updateSketchEntity", args: [
            "sketch_id": sketchID.raw.uuidString, "entity_id": newEdge.uuidString, "b": [60, 0]])
        XCTAssertEqual(later["ok"] as? Bool, true, "\(later)")
        XCTAssertEqual(try volume(document), 50 * .pi, accuracy: 1e-4)
        XCTAssertNotNil(document.session.document.features.node(feature.id))
    }

    func testSweepMissingEdgeAndCollapsedPathKeepGeometryAndUndoHistory() async throws {
        let document = try await makeDocument(); defer { document.close() }
        let (feature, sketch, edge) = try makeAssociatedSweep(document)
        let beforeVolume = try volume(document), beforeID = try body(document).id
        let revision = document.revision, changes = document.session.changeCount
        let undo = document.session.undoStack.undoCommands.count
        let service = CADParameterService(document: document)
        let rejected = service.handle(action: "update", args: ["feature_id": feature.id.raw.uuidString,
            "changes": ["path": ["version": 1, "segments": [["sketchID": sketch.raw.uuidString,
                "entityID": UUID().uuidString, "reversed": false]]]]])
        XCTAssertEqual(rejected["ok"] as? Bool, false)
        XCTAssertEqual(rejected["error"] as? String, "invalid_sweep_path")
        XCTAssertEqual(document.revision, revision)
        XCTAssertEqual(document.session.changeCount, changes)
        XCTAssertEqual(document.session.undoStack.undoCommands.count, undo)
        let collapsed = service.handle(action: "updateSketchEntity", args: [
            "sketch_id": sketch.raw.uuidString, "entity_id": edge.uuidString, "b": [0, 0]])
        XCTAssertEqual(collapsed["ok"] as? Bool, false, "\(collapsed)")
        XCTAssertEqual(try volume(document), beforeVolume, accuracy: 1e-4)
        XCTAssertEqual(try body(document).id, beforeID)
        XCTAssertNotNil(try body(document).brep)
        XCTAssertEqual(document.session.undoStack.undoCommands.count, undo)
        XCTAssertTrue(document.session.lastEvalErrors.isEmpty)
    }

    func testNativeHelixFieldsEditTheSameFeatureAndRejectUnsafeValues() async throws {
        let document = try await makeDocument(); defer { document.close() }
        let profile = try run(document, "sketch.create", [
            "origin": [3.5, 0, 0], "xAxis": [1, 0, 0], "yAxis": [0, 0, -1]])
        let sketchID = try XCTUnwrap(profile["sketchID"] as? String)
        try run(document, "sketch.addEntities", ["sketchID": sketchID,
            "entities": [["kind": "circle", "center": [0, 0], "radius": 0.5]]])
        try run(document, "feature.sweep", ["sketchID": sketchID, "seedPoint": [0, 0],
            "helix": ["axisPoint": [0, 0, 0], "axisDirection": [0, 1, 0],
                "referenceDirection": [1, 0, 0], "radius": 3.5, "pitch": 2, "turns": 2]])
        let feature = try XCTUnwrap(document.session.document.features.nodes.last)
        let bodyID = try body(document).id
        let originalMax = try body(document).render.localAABB.max.y
        let viewModel = document.viewModel()
        XCTAssertEqual(EditorViewModel.scalars(of: feature.kind).map(\.key), [.helixRadius, .helixPitch, .helixTurns])
        viewModel.editFeatureScalar(feature.id, key: .helixPitch, value: 3)
        XCTAssertNil(viewModel.errorMessage)
        viewModel.editFeatureScalar(feature.id, key: .helixTurns, value: 3)
        XCTAssertNil(viewModel.errorMessage)
        let current = try XCTUnwrap(document.session.document.features.node(feature.id))
        guard case let .sweep(_, _, spine, _, helix?, path) = current.kind else {
            return XCTFail("Same feature lost its helix")
        }
        XCTAssertEqual(helix.pitch, 3); XCTAssertEqual(helix.turns, 3); XCTAssertNil(path)
        XCTAssertEqual(spine.map(\.point), try helix.checkedSampledSpine())
        XCTAssertEqual(try body(document).id, bodyID); XCTAssertNotNil(try body(document).brep)
        XCTAssertGreaterThan(try body(document).render.localAABB.max.y, originalMax + 4)
        let revision = document.revision, undo = document.session.undoStack.undoCommands.count
        viewModel.editFeatureScalar(feature.id, key: .helixPitch, value: 0)
        XCTAssertNotNil(viewModel.errorMessage)
        XCTAssertEqual(document.revision, revision)
        XCTAssertEqual(document.session.undoStack.undoCommands.count, undo)
        document.session.undo()
        guard let restoredFeature = document.session.document.features.node(feature.id),
              case let .sweep(_, _, _, _, restored?, _) = restoredFeature.kind else {
            return XCTFail("Undo lost the original feature")
        }
        XCTAssertEqual(restored.pitch, 3); XCTAssertEqual(restored.turns, 2)
        document.session.redo()
        let saved = await document.save(); XCTAssertTrue(saved.succeeded, saved.error ?? "")
        let url = document.url; document.close()
        let reopened = try await FloeCADDocument.open(at: url); defer { reopened.close() }
        guard let reopenedFeature = reopened.session.document.features.node(feature.id),
              case let .sweep(_, _, reopenedSpine, _, reopenedHelix?, _) = reopenedFeature.kind else {
            return XCTFail("Reopen lost the original feature")
        }
        XCTAssertEqual(reopenedHelix.pitch, 3); XCTAssertEqual(reopenedHelix.turns, 3)
        XCTAssertEqual(reopenedSpine.map(\.point), try reopenedHelix.checkedSampledSpine())
        XCTAssertNotNil(try body(reopened).brep)
    }

    func testSweepPathVersionFloorAndLegacyDecodePreserveIntent() async throws {
        let document = try await makeDocument(); defer { document.close() }
        let (feature, _, _) = try makeAssociatedSweep(document)
        XCTAssertEqual(CADDocumentFormat.requiredFormat(document: document.session.document),
                       CADDocumentFormat.associativeSweepVersion)
        var object = try XCTUnwrap(try JSONSerialization.jsonObject(
            with: JSONEncoder().encode(feature.kind)) as? [String: Any])
        var sweep = try XCTUnwrap(object["sweep"] as? [String: Any])
        var path = try XCTUnwrap(sweep["path"] as? [String: Any])
        path["version"] = 2; sweep["path"] = path; object["sweep"] = sweep
        let futureData = try JSONSerialization.data(withJSONObject: object)
        let row = CADFeatureRecord(featureID: feature.id.raw, orderIndex: 0, name: feature.name,
            suppressed: false, kind: futureData, outputBodyIDs: try JSONEncoder().encode(feature.outputBodyIDs))
        let assessment = try CADDocumentFormat.assess(planes: [], sketches: [], features: [row])
        XCTAssertTrue(assessment.isOpaqueReadOnly)
        XCTAssertTrue(assessment.opaqueFeatures.contains(feature.id.raw))
        XCTAssertThrowsError(try JSONDecoder().decode(FeatureKind.self, from: futureData))
        sweep.removeValue(forKey: "path"); object["sweep"] = sweep
        let legacy = try JSONDecoder().decode(FeatureKind.self,
            from: JSONSerialization.data(withJSONObject: object))
        guard case let .sweep(_, _, _, _, _, decodedPath) = legacy else { return XCTFail("Legacy sweep did not decode") }
        XCTAssertNil(decodedPath)
    }

    private func parameter(_ document: FloeCADDocument, feature: FeatureID,
                           name: String) throws -> [String: Any] {
        let featureRow = try XCTUnwrap(try rows(document, "features").first {
            ($0["id"] as? String) == feature.raw.uuidString
        })
        let parameters = try XCTUnwrap(featureRow["parameters"] as? [[String: Any]])
        return try XCTUnwrap(parameters.first { ($0["name"] as? String) == name })
    }

    private func addVariable(_ document: FloeCADDocument, name: String,
                             value: Double) -> Variable {
        let variable = Variable(name: name, expression: String(value))
        document.session.perform(AddVariableCommand(variable: variable))
        document.session.variablesDidChange()
        return variable
    }

    private func changeVariable(_ document: FloeCADDocument, _ variable: Variable,
                                value: Double) {
        var after = variable
        after.expression = String(value)
        document.session.perform(EditVariableCommand(before: variable, after: after))
        document.session.variablesDidChange()
        XCTAssertTrue(document.session.lastEvalErrors.isEmpty,
                      "\(document.session.lastEvalErrors)")
    }

    private func blend(_ document: FloeCADDocument, kind: String) throws -> FeatureNode {
        let current = try body(document)
        let edgeRow = try XCTUnwrap(try rows(document, "edges").first {
            ($0["bodyID"] as? String) == current.id.raw.uuidString
        })
        let edges = try XCTUnwrap(edgeRow["edges"] as? [[String: Any]])
        let edge = try XCTUnwrap(edges.min { lhs, rhs in
            func distance(_ row: [String: Any]) -> Double {
                guard let p = row["midpoint"] as? [Double], p.count == 3 else {
                    return .greatestFiniteMagnitude
                }
                return simd_length(SIMD3(p[0], p[1], p[2]) - SIMD3<Double>(0, 5, 0))
            }
            return distance(lhs) < distance(rhs)
        })
        let index = try XCTUnwrap(edge["index"] as? Int)
        let token = try XCTUnwrap(edgeRow["query_token"] as? String)
        try run(document, "feature.\(kind)", [
            "bodyID": current.id.raw.uuidString, "edges": [index],
            kind == "fillet" ? "radius" : "setback": 1,
            "query_token": token,
        ])
        return try XCTUnwrap(document.session.document.features.nodes.last)
    }

    private func scalar(_ node: FeatureNode) throws -> Expr {
        switch node.kind {
        case let .fillet(_, _, value), let .chamfer(_, _, value),
             let .shell(_, _, value):
            return value
        default:
            XCTFail("Unexpected scalar feature \(node.name)")
            throw NSError(domain: "CADParameterCorrectness", code: 1)
        }
    }

    // The variable change must reach actual kernel geometry, not just a query
    // label. Each independent fixture exercises one of the formerly omitted
    // Expr kinds, including undo/redo and a real package round-trip.
    func testBlendAndShellVariableFanOutChangesGeometryAndPersists() async throws {
        for kind in ["fillet", "chamfer", "shell"] {
            let document = try await makeDocument()
            defer { document.close() }
            _ = try makeBox(document)
            let variable = addVariable(document, name: "size", value: 1)
            let feature: FeatureNode
            if kind == "shell" {
                try run(document, "feature.shell", [
                    "bodyID": try body(document).id.raw.uuidString, "thickness": 1,
                ])
                feature = try XCTUnwrap(document.session.document.features.nodes.last)
            } else {
                feature = try blend(document, kind: kind)
            }
            let expression = Expr(value: 1, formula: "size")
            let driven: FeatureKind
            switch feature.kind {
            case let .fillet(body, edges, _):
                driven = .fillet(body: body, edges: edges, radius: expression)
            case let .chamfer(body, edges, _):
                driven = .chamfer(body: body, edges: edges, setback: expression)
            case let .shell(body, faces, _):
                driven = .shell(body: body, openFaces: faces, thickness: expression)
            default:
                return XCTFail("Unexpected feature for \(kind)")
            }
            document.session.editFeature(feature.id, to: driven)
            let before = try volume(document)
            changeVariable(document, variable, value: 2)
            let changedNode = try XCTUnwrap(document.session.document.features.node(feature.id))
            XCTAssertEqual(try scalar(changedNode), Expr(value: 2, formula: "size"), kind)
            let expected: Double
            switch kind {
            case "fillet": expected = 8_000 - 10 * 4 * (1 - .pi / 4)
            case "chamfer": expected = 8_000 - 10 * 4 / 2
            default: expected = 8_000 - 36 * 16 * 6
            }
            XCTAssertEqual(try volume(document), expected, accuracy: 0.1, kind)
            XCTAssertNotEqual(try volume(document), before, kind)
            XCTAssertNotNil(try body(document).brep, kind)

            document.session.undo()
            XCTAssertEqual(try volume(document), before, accuracy: 0.1, kind)
            document.session.redo()
            XCTAssertEqual(try volume(document), expected, accuracy: 0.1, kind)

            let saved = await document.save()
            XCTAssertTrue(saved.succeeded, saved.error ?? "")
            let url = document.url
            document.close()
            let reopened = try await FloeCADDocument.open(at: url)
            defer { reopened.close() }
            XCTAssertEqual(try scalar(try XCTUnwrap(
                reopened.session.document.features.node(feature.id))),
                Expr(value: 2, formula: "size"), kind)
            XCTAssertEqual(try volume(reopened), expected, accuracy: 0.1, kind)
        }
    }

    func testDraftExtrudeReevaluatesDistanceAndTaperTogether() async throws {
        let document = try await makeDocument()
        defer { document.close() }
        let feature = try makeBox(document, distance: 10, taper: 2)
        let height = addVariable(document, name: "height", value: 10)
        let taper = addVariable(document, name: "taper", value: 2)
        guard case let .draftExtrude(profile, plane, _, _, symmetric, boolean) = feature.kind else {
            return XCTFail("Fixture did not create draft extrude")
        }
        document.session.editFeature(feature.id, to: .draftExtrude(
            profile: profile, plane: plane, distance: Expr(value: 10, formula: "height"),
            taperAngle: Expr(value: 2, formula: "taper"),
            symmetric: symmetric, boolean: boolean))
        var newHeight = height
        newHeight.expression = "20"
        var newTaper = taper
        newTaper.expression = "5"
        document.session.perform(CompositeCommand(title: "Change dimensions", commands: [
            EditVariableCommand(before: height, after: newHeight),
            EditVariableCommand(before: taper, after: newTaper),
        ]))
        document.session.variablesDidChange()
        XCTAssertTrue(document.session.lastEvalErrors.isEmpty,
                      "\(document.session.lastEvalErrors)")
        let changed = try XCTUnwrap(document.session.document.features.node(feature.id))
        guard case let .draftExtrude(_, _, distance, angle, _, _) = changed.kind else {
            return XCTFail("Draft feature was replaced by another kind")
        }
        XCTAssertEqual(distance, Expr(value: 20, formula: "height"))
        XCTAssertEqual(angle, Expr(value: 5, formula: "taper"))
        XCTAssertEqual(try parameter(document, feature: feature.id, name: "distance")["value"]
                       as? Double, 20)
        XCTAssertEqual(try parameter(document, feature: feature.id, name: "taper_angle")["value"]
                       as? Double, 5)

        let reference = try await makeDocument()
        defer { reference.close() }
        _ = try makeBox(reference, distance: 20, taper: 5)
        XCTAssertEqual(try volume(document), try volume(reference), accuracy: 0.1)
        let result = try body(document).render.localAABB
        let expected = try body(reference).render.localAABB
        XCTAssertLessThan(simd_length(result.min - expected.min), 1e-3)
        XCTAssertLessThan(simd_length(result.max - expected.max), 1e-3)
    }

    // A holed loft is deliberately a mesh-only production feature. Face
    // rotation remains supported there even when exact-body deformation is
    // correctly refused instead of silently degrading BRep.
    private func makeMeshRotation(_ document: FloeCADDocument,
                                  degrees: Double) throws -> FeatureID {
        let first = try addRectangleSketch(document, withHole: true)
        let last = try addRectangleSketch(document, y: 10, withHole: true)
        try run(document, "feature.loft", ["sections": [
            ["sketchID": first, "seedPoint": [5, 5]],
            ["sketchID": last, "seedPoint": [5, 5]],
        ]])
        let source = try XCTUnwrap(document.session.document.features.nodes.last)
        let current = try body(document)
        XCTAssertNil(current.brep, "Fixture must exercise the supported mesh-only path")
        let table = document.session.naming.faceTable(
            for: current, createdBy: source.id, scheme: .generic)
        let top = try XCTUnwrap(table.entries.max { $0.signature.normal.y < $1.signature.normal.y })
        XCTAssertGreaterThan(top.signature.normal.y, 0.99)
        let ref = FaceRef(body: BodyRef(producer: source.id, bodyID: current.id),
                          creator: source.id, role: top.role, signature: top.signature)
        let node = FeatureNode(
            name: "Rotate Face",
            kind: .rotateFace(face: ref, angle: Expr(value: degrees * .pi / 180),
                              axis: PointWrapper(SIMD3(1, 0, 0))),
            outputBodyIDs: [current.id])
        document.session.recordAndRebuild([node], title: "Rotate Face")
        XCTAssertTrue(document.session.lastEvalErrors.isEmpty,
                      "\(document.session.lastEvalErrors)")
        return node.id
    }

    func testRotateFaceParameterUsesDegreesAndPersistsRadiansWithRealGeometry() async throws {
        let document = try await makeDocument()
        defer { document.close() }
        let feature = try makeMeshRotation(document, degrees: 10)
        let initial = try parameter(document, feature: feature, name: "angle")
        XCTAssertEqual(initial["unit"] as? String, "deg")
        XCTAssertEqual(initial["value"] as? Double ?? -1, 10, accuracy: 1e-10)

        let before = try body(document).render.localAABB
        let reply = CADParameterService(document: document).handle(action: "update", args: [
            "feature_id": feature.raw.uuidString, "changes": ["angle": 15],
        ])
        XCTAssertEqual(reply["ok"] as? Bool, true, "\(reply)")
        let queried = try parameter(document, feature: feature, name: "angle")
        XCTAssertEqual(queried["value"] as? Double ?? -1, 15, accuracy: 1e-10)
        let updated = try XCTUnwrap(document.session.document.features.node(feature))
        guard case let .rotateFace(_, angle, _) = updated.kind else {
            return XCTFail("Expected rotation feature")
        }
        XCTAssertEqual(angle.value, .pi / 12, accuracy: 1e-12)

        let reference = try await makeDocument()
        defer { reference.close() }
        _ = try makeMeshRotation(reference, degrees: 15)
        let actualBounds = try body(document).render.localAABB
        let referenceBounds = try body(reference).render.localAABB
        XCTAssertGreaterThan(simd_length(actualBounds.max - before.max), 0.01)
        XCTAssertLessThan(simd_length(actualBounds.min - referenceBounds.min), 1e-3)
        XCTAssertLessThan(simd_length(actualBounds.max - referenceBounds.max), 1e-3)
        XCTAssertEqual(try volume(document), try volume(reference), accuracy: 0.1)

        document.session.undo()
        XCTAssertEqual(try parameter(document, feature: feature, name: "angle")["value"]
                       as? Double ?? -1, 10, accuracy: 1e-10)
        document.session.redo()
        let saved = await document.save()
        XCTAssertTrue(saved.succeeded, saved.error ?? "")
        let url = document.url
        document.close()
        let reopened = try await FloeCADDocument.open(at: url)
        defer { reopened.close() }
        XCTAssertEqual(try parameter(reopened, feature: feature, name: "angle")["value"]
                       as? Double ?? -1, 15, accuracy: 1e-10)
        guard case let .rotateFace(_, stored, _) = try XCTUnwrap(
            reopened.session.document.features.node(feature)).kind else {
            return XCTFail("Reopened rotation missing")
        }
        XCTAssertEqual(stored.value, .pi / 12, accuracy: 1e-12)
    }

    func testRotateFaceThirtyToFortyFiveDegreesAndContinuedSameFeature() async throws {
        let document = try await makeDocument()
        defer { document.close() }
        let feature = try makeMeshRotation(document, degrees: 30)
        let initial = try parameter(document, feature: feature, name: "angle")
        XCTAssertEqual(initial["unit"] as? String, "deg")
        XCTAssertEqual(initial["value"] as? Double ?? -1, 30, accuracy: 1e-10)

        let before = try body(document).render.localAABB
        let reply = CADParameterService(document: document).handle(action: "update", args: [
            "feature_id": feature.raw.uuidString, "changes": ["angle": 45],
        ])
        XCTAssertEqual(reply["ok"] as? Bool, true, "\(reply)")
        let queried = try parameter(document, feature: feature, name: "angle")
        XCTAssertEqual(queried["value"] as? Double ?? -1, 45, accuracy: 1e-10)
        let updated = try XCTUnwrap(document.session.document.features.node(feature))
        guard case let .rotateFace(_, angle, _) = updated.kind else {
            return XCTFail("Expected rotation feature")
        }
        XCTAssertEqual(angle.value, .pi / 4, accuracy: 1e-12)

        let reference = try await makeDocument()
        defer { reference.close() }
        _ = try makeMeshRotation(reference, degrees: 45)
        let actualBounds = try body(document).render.localAABB
        let referenceBounds = try body(reference).render.localAABB
        XCTAssertGreaterThan(simd_length(actualBounds.max - before.max), 0.01)
        XCTAssertLessThan(simd_length(actualBounds.min - referenceBounds.min), 1e-3)
        XCTAssertLessThan(simd_length(actualBounds.max - referenceBounds.max), 1e-3)
        XCTAssertEqual(try volume(document), try volume(reference), accuracy: 0.1)

        document.session.undo()
        XCTAssertEqual(try parameter(document, feature: feature, name: "angle")["value"]
                       as? Double ?? -1, 30, accuracy: 1e-10)
        document.session.redo()
        let saved = await document.save()
        XCTAssertTrue(saved.succeeded, saved.error ?? "")
        let url = document.url
        document.close()
        let reopened = try await FloeCADDocument.open(at: url)
        defer { reopened.close() }
        XCTAssertEqual(try parameter(reopened, feature: feature, name: "angle")["value"]
                       as? Double ?? -1, 45, accuracy: 1e-10)
        guard case let .rotateFace(_, stored, _) = try XCTUnwrap(
            reopened.session.document.features.node(feature)).kind else {
            return XCTFail("Reopened rotation missing")
        }
        XCTAssertEqual(stored.value, .pi / 4, accuracy: 1e-12)
    }

    func testInPlaceBodyDependenciesUseProducerIdentityForReorderAndDelete() async throws {
        let document = try await makeDocument()
        defer { document.close() }
        let base = try makeBox(document)
        let bodyID = try body(document).id.raw.uuidString
        try run(document, "feature.transform", ["bodyID": bodyID, "translation": [5, 0, 0]])
        let firstEdit = try XCTUnwrap(document.session.document.features.nodes.last)
        try run(document, "feature.transform", ["bodyID": bodyID, "translation": [0, 0, 3]])
        let leafEdit = try XCTUnwrap(document.session.document.features.nodes.last)
        let beforeBounds = try body(document).render.localAABB
        let independent = try makeBox(document)
        let service = CADParameterService(document: document)
        let descriptor = CADParameterService.describe(
            leafEdit, document: document.session.document)
        let dependencies = try XCTUnwrap(descriptor["dependencies"] as? [String: Any])
        XCTAssertEqual(dependencies["feature_ids"] as? [String],
                       [firstEdit.id.raw.uuidString])
        guard case let .transform(storedRef, _) = leafEdit.kind else {
            return XCTFail("Expected the native transform fixture")
        }
        // Legacy refs can still name the initial creator. Queries expose that
        // provenance separately rather than relabelling it as the input version.
        XCTAssertEqual(dependencies["reference_producer_ids"] as? [String],
                       [storedRef.producer.raw.uuidString])

        // An unrelated feature may move across an in-place edit chain. A map
        // keyed only by the reused BodyID wrongly calls the last edit the
        // producer of its own predecessors and refuses this legal ordering.
        let allowed = service.handle(action: "feature.move", args: [
            "feature_id": independent.id.raw.uuidString, "to_index": 2,
        ])
        XCTAssertEqual(allowed["ok"] as? Bool, true, "\(allowed)")
        XCTAssertEqual(document.session.document.features.nodes.map(\.id),
                       [base.id, firstEdit.id, independent.id, leafEdit.id])
        let changeCount = document.session.changeCount
        let invalid = service.handle(action: "feature.move", args: [
            "feature_id": leafEdit.id.raw.uuidString, "to_index": 1,
        ])
        XCTAssertEqual(invalid["error"] as? String, "dependency_order", "\(invalid)")
        XCTAssertEqual(document.session.changeCount, changeCount)

        let refused = service.handle(action: "feature.delete", args: [
            "feature_id": firstEdit.id.raw.uuidString,
        ])
        XCTAssertEqual(refused["error"] as? String, "has_dependents", "\(refused)")
        XCTAssertEqual(refused["dependent_feature_ids"] as? [String],
                       [leafEdit.id.raw.uuidString])
        XCTAssertEqual(document.session.changeCount, changeCount)

        // Earlier modifiers share this BodyID but do not depend on a later
        // modifier. Deleting the leaf must remain legal and undoable.
        let deleted = service.handle(action: "feature.delete", args: [
            "feature_id": leafEdit.id.raw.uuidString,
        ])
        XCTAssertEqual(deleted["ok"] as? Bool, true, "\(deleted)")
        XCTAssertNil(document.session.document.features.node(leafEdit.id))
        document.session.undo()
        XCTAssertNotNil(document.session.document.features.node(leafEdit.id))
        let restored = try XCTUnwrap(document.session.document.bodies.first {
            $0.id.raw.uuidString == bodyID
        }).render.localAABB
        XCTAssertLessThan(simd_length(restored.min - beforeBounds.min), 1e-3)
        XCTAssertLessThan(simd_length(restored.max - beforeBounds.max), 1e-3)
    }

    func testBooleanIntentTargetsAppearInEveryComposedFeatureDependencyDescriptor() throws {
        let target = BodyRef(producer: FeatureID(), bodyID: BodyID())
        let profile = ProfileRef(sketchID: SketchID(), entityIDs: [UUID()],
                                 holeEntityIDs: [], seedPoint: SIMD2(1, 1))
        let plane = PlaneRef(source: .ground)
        let intent = BooleanIntent(op: .subtract, resolvedTargets: [target])
        let cases: [FeatureKind] = [
            .extrude(profile: profile, plane: plane, distance: Expr(value: 2),
                     symmetric: false, boolean: intent, extraProfiles: []),
            .draftExtrude(profile: profile, plane: plane, distance: Expr(value: 2),
                          taperAngle: Expr(value: 3), symmetric: false, boolean: intent),
            .revolve(profile: profile, plane: plane,
                     axis: AxisRef(source: .explicit(RevolveAxis(point: .zero,
                                                               direction: SIMD2(1, 0)))),
                     angle: Expr(value: 90), boolean: intent),
            .sweep(profile: profile, plane: plane,
                   spine: [PointWrapper(.zero), PointWrapper(SIMD3(0, 10, 0))],
                   boolean: intent, helix: nil),
            .loft(sections: [profile, profile], boolean: intent),
        ]
        for kind in cases {
            let node = FeatureNode(name: "Composed", kind: kind, outputBodyIDs: [BodyID()])
            let row = CADParameterService.describe(node, document: DesignDocument())
            let dependencies = try XCTUnwrap(row["dependencies"] as? [String: Any])
            XCTAssertEqual(dependencies["feature_ids"] as? [String],
                           [target.producer.raw.uuidString])
            XCTAssertTrue((dependencies["body_ids"] as? [String] ?? [])
                .contains(target.bodyID.raw.uuidString))
        }
    }

    func testStoredRotationRadiansRoundTripAndTypedDegreeConversion() throws {
        let source = BodyRef(producer: FeatureID(), bodyID: BodyID())
        let face = FaceRef(
            body: source, creator: source.producer, role: .extrudeEndCap,
            signature: FaceSignature(kind: .planar, normal: SIMD3(0, 1, 0),
                                     centroid: .zero, area: 40, planeOffset: 0))
        let original = FeatureKind.rotateFace(
            face: face, angle: Expr(value: .pi / 6, formula: "radians(30)"),
            axis: PointWrapper(SIMD3(1, 0, 0)))
        // Decode the existing on-disk unit contract; no schema or migration is
        // involved in changing the public descriptor's unit conversion.
        let restored = try JSONDecoder().decode(
            FeatureKind.self, from: JSONEncoder().encode(original))
        let descriptor = CADParameterService.describe(
            FeatureNode(name: "Rotate", kind: restored, outputBodyIDs: [source.bodyID]),
            document: DesignDocument())
        let angle = try XCTUnwrap((descriptor["parameters"] as? [[String: Any]])?.first {
            ($0["name"] as? String) == "angle"
        })
        XCTAssertEqual(angle["unit"] as? String, "deg")
        XCTAssertEqual(angle["value"] as? Double ?? -1, 30, accuracy: 1e-10)
        let changed = try CADParameterService.updated(restored, changes: ["angle": -45]).get()
        guard case let .rotateFace(changedFace, value, axis) = changed else {
            return XCTFail("Expected rotation")
        }
        XCTAssertEqual(changedFace, face)
        XCTAssertEqual(axis.point, SIMD3(1, 0, 0))
        XCTAssertEqual(value.value, -.pi / 4, accuracy: 1e-12)
        XCTAssertNil(value.formula, "An explicit numeric edit replaces the previous formula")
    }

    func testEveryExprKindPreservesFormulaAndReferencesDuringReevaluation() throws {
        let profile = ProfileRef(sketchID: SketchID(), entityIDs: [UUID()],
                                 holeEntityIDs: [], seedPoint: SIMD2(1, 1))
        let plane = PlaneRef(source: .ground)
        let body = BodyRef(producer: FeatureID(), bodyID: BodyID())
        let signature = FaceSignature(kind: .planar, normal: SIMD3(0, 1, 0),
                                      centroid: .zero, area: 40, planeOffset: 0)
        let face = FaceRef(body: body, creator: body.producer,
                           role: .extrudeEndCap, signature: signature)
        let edge = EdgeRef(body: body, signature: EdgeSignature(
            midpoint: .zero, direction: SIMD3(1, 0, 0), length: 10,
            normalA: SIMD3(0, 1, 0), normalB: SIMD3(0, 0, 1)))
        let intent = BooleanIntent(op: .newBody, resolvedTargets: [])
        let old = Expr(value: 1, formula: "size / 2")
        let new = Expr(value: 3, formula: "size / 2")
        let axis = PointWrapper(SIMD3<Double>(1, 0, 0))
        let neutral = PointWrapper(SIMD3<Double>(0, 1, 0))
        let cases: [(String, FeatureKind, FeatureKind)] = [
            ("extrude",
             .extrude(profile: profile, plane: plane, distance: old,
                      symmetric: true, boolean: intent, extraProfiles: [profile]),
             .extrude(profile: profile, plane: plane, distance: new,
                      symmetric: true, boolean: intent, extraProfiles: [profile])),
            ("draft distance and angle",
             .draftExtrude(profile: profile, plane: plane, distance: old,
                           taperAngle: old, symmetric: false, boolean: intent),
             .draftExtrude(profile: profile, plane: plane, distance: new,
                           taperAngle: new, symmetric: false, boolean: intent)),
            ("revolve degrees",
             .revolve(profile: profile, plane: plane,
                      axis: AxisRef(source: .explicit(RevolveAxis(point: .zero, direction: SIMD2(1, 0)))),
                      angle: old, boolean: intent),
             .revolve(profile: profile, plane: plane,
                      axis: AxisRef(source: .explicit(RevolveAxis(point: .zero, direction: SIMD2(1, 0)))),
                      angle: new, boolean: intent)),
            ("push pull", .pushPull(face: face, distance: old, mode: .planarAxial),
             .pushPull(face: face, distance: new, mode: .planarAxial)),
            ("scale face", .scaleFace(face: face, factor: old), .scaleFace(face: face, factor: new)),
            ("rotate radians", .rotateFace(face: face, angle: old, axis: axis),
             .rotateFace(face: face, angle: new, axis: axis)),
            ("draft face degrees",
             .draftFace(face: face, neutralOrigin: axis, neutralNormal: neutral, angle: old),
             .draftFace(face: face, neutralOrigin: axis, neutralNormal: neutral, angle: new)),
            ("chamfer", .chamfer(body: body, edges: [edge], setback: old),
             .chamfer(body: body, edges: [edge], setback: new)),
            ("fillet", .fillet(body: body, edges: [edge], radius: old),
             .fillet(body: body, edges: [edge], radius: new)),
            ("shell", .shell(body: body, openFaces: [face], thickness: old),
             .shell(body: body, openFaces: [face], thickness: new)),
        ]
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        for (name, original, expected) in cases {
            let actual = try XCTUnwrap(
                DocumentSession.reevaluatedKind(original, with: ["size": 6]), name)
            // Whole typed definitions must agree, including ids/references,
            // formula text and each feature's stored unit.
            XCTAssertEqual(try encoder.encode(actual), try encoder.encode(expected), name)
            XCTAssertNil(DocumentSession.reevaluatedKind(expected, with: ["size": 6]), name)
        }

        // A change to just one draft scalar must leave the other expression
        // and its formula untouched, rather than replacing it with a number.
        let oneChanged = FeatureKind.draftExtrude(
            profile: profile, plane: plane, distance: old,
            taperAngle: Expr(value: 7, formula: "constant"),
            symmetric: false, boolean: intent)
        let oneResult = try XCTUnwrap(DocumentSession.reevaluatedKind(
            oneChanged, with: ["size": 6, "constant": 7]))
        guard case let .draftExtrude(_, _, distance, taper, _, _) = oneResult else {
            return XCTFail("Expected draft")
        }
        XCTAssertEqual(distance, new)
        XCTAssertEqual(taper, Expr(value: 7, formula: "constant"))

        // Missing variables retain the existing error-to-zero convention and
        // keep the formula available for repair.
        let broken = try XCTUnwrap(DocumentSession.reevaluatedKind(
            .fillet(body: body, edges: [edge], radius: old), with: [:]))
        guard case let .fillet(_, _, radius) = broken else { return XCTFail("Expected fillet") }
        XCTAssertEqual(radius, Expr(value: 0, formula: "size / 2"))
    }
}
