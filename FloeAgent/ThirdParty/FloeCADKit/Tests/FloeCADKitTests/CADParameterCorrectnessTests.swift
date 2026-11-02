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
        let outcome = document.executeJSON(input)
        let result = try XCTUnwrap(outcome.isOK ? outcome : nil,
            "\(op): \(outcome.errorCode ?? "") \(outcome.message ?? "")")
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

    func testSelectingTheCurrentSweepPathAfterSourceEditCreatesNoUndo() async throws {
        let document = try await makeDocument(); defer { document.close() }
        let (feature, sketch, edge) = try makeAssociatedSweep(document)
        let service = CADParameterService(document: document)
        let changed = service.handle(action: "updateSketchEntity", args: [
            "sketch_id": sketch.raw.uuidString, "entity_id": edge.uuidString, "b": [35, 0]])
        XCTAssertEqual(changed["ok"] as? Bool, true, "\(changed)")
        let revision = document.revision, undo = document.session.undoStack.undoCommands.count
        let count = document.session.changeCount
        let same = service.handle(action: "update", args: ["feature_id": feature.id.raw.uuidString,
            "changes": ["path": ["version": 1, "segments": [["sketchID": sketch.raw.uuidString,
                "entityID": edge.uuidString, "reversed": false]]]]])
        XCTAssertEqual(same["error"] as? String, "no_change", "\(same)")
        XCTAssertEqual(document.revision, revision)
        XCTAssertEqual(document.session.changeCount, count)
        XCTAssertEqual(document.session.undoStack.undoCommands.count, undo)
        XCTAssertEqual(try volume(document), 35 * .pi, accuracy: 1e-4)
    }

    func testUnchangedLegacyHelixParameterDoesNotReplaceItsSavedRenderPath() throws {
        let helix = HelixSpec(axisPoint: .zero, axisDirection: SIMD3(0, 1, 0),
            referenceDirection: SIMD3(1, 0, 0), radius: 3.5, pitch: 2, turns: 2)
        let profile = ProfileRef(sketchID: SketchID(), entityIDs: [UUID()], holeEntityIDs: [], seedPoint: .zero)
        let legacy = FeatureKind.sweep(profile: profile, plane: PlaneRef(source: .ground),
            spine: [PointWrapper(.zero), PointWrapper(SIMD3(0, 2, 0))],
            boolean: .init(op: .newBody, resolvedTargets: []), helix: helix)
        let result = CADParameterService.updated(legacy, changes: ["helix_pitch": 2])
        guard case let .success(unchanged) = result else { return XCTFail("Current value must validate") }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        XCTAssertEqual(try encoder.encode(unchanged), try encoder.encode(legacy))
    }

    func testNativeHelixRadiusChangesTheActualBRepExtent() async throws {
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
        func radialExtent(_ target: FloeCADDocument) throws -> Double {
            let solid = try XCTUnwrap(try body(target).brep)
            let points = OCCTKernel.renderMesh(from: solid).positions
            return try XCTUnwrap(points.map { hypot(Double($0.x), Double($0.z)) }.max())
        }
        let original = try radialExtent(document)
        let viewModel = document.viewModel()
        viewModel.editFeatureScalar(feature.id, key: .helixRadius, value: 4.5)
        XCTAssertNil(viewModel.errorMessage)
        XCTAssertGreaterThan(try radialExtent(document), original + 0.8,
            "Measure tessellated actual BRep, independently of the sampled display spine")
        XCTAssertNotNil(document.session.document.features.node(feature.id))
        document.session.undo()
        XCTAssertEqual(try radialExtent(document), original, accuracy: 1e-3)
        document.session.redo()
        let grown = try radialExtent(document)
        XCTAssertGreaterThan(grown, original + 0.8)
        let saved = await document.save(); XCTAssertTrue(saved.succeeded, saved.error ?? "")
        let url = document.url; document.close()
        let reopened = try await FloeCADDocument.open(at: url); defer { reopened.close() }
        XCTAssertEqual(try radialExtent(reopened), grown, accuracy: 1e-3)
        guard let restored = reopened.session.document.features.node(feature.id),
              case let .sweep(_, _, _, _, spec?, _) = restored.kind else {
            return XCTFail("Reopen lost the edited helix")
        }
        XCTAssertNotNil(spec.profileAnchor)
        XCTAssertEqual(CADDocumentFormat.requiredFormat(document: reopened.session.document),
                       CADDocumentFormat.associativeSweepVersion)
    }

    func testHelixRadiusKeepsFullSectionOffsetAtANonzeroStartAngle() async throws {
        let document = try await makeDocument(); defer { document.close() }
        let profile = try run(document, "sketch.create", [
            "origin": [0, -0.5, -3.5], "xAxis": [1, 0, 0], "yAxis": [0, 0, -1]])
        let rawID = try XCTUnwrap(profile["sketchID"] as? String)
        try run(document, "sketch.addEntities", ["sketchID": rawID,
            "entities": [["kind": "circle", "center": [0, 0], "radius": 0.5]]])
        try run(document, "feature.sweep", ["sketchID": rawID, "seedPoint": [0, 0],
            "helix": ["axisPoint": [0, 0, 0], "axisDirection": [0, 1, 0],
                "referenceDirection": [1, 0, 0], "radius": 3.5, "pitch": 2,
                "turns": 2, "startAngle": Double.pi / 2]])
        let feature = try XCTUnwrap(document.session.document.features.nodes.last)
        let source = try XCTUnwrap(document.session.document.sketches.first { $0.id.raw.uuidString == rawID })
        let solid = try XCTUnwrap(try body(document).brep)
        let before = try XCTUnwrap(OCCTKernel.renderMesh(from: solid).positions
            .map { hypot(Double($0.x), Double($0.z)) }.max())
        let service = CADParameterService(document: document)
        let reply = service.handle(action: "update", args: ["feature_id": feature.id.raw.uuidString,
            "changes": ["helix_radius": 4.5]])
        XCTAssertEqual(reply["ok"] as? Bool, true, "\(reply)")
        guard let updated = document.session.document.features.node(feature.id),
              case let .sweep(_, ref, _, _, spec?, _) = updated.kind else {
            return XCTFail("The original helix identity was lost")
        }
        let anchor = try XCTUnwrap(spec.profileAnchor)
        XCTAssertEqual(anchor.z, 1, accuracy: 1e-9,
            "Keep the section's normal offset; a two-coordinate projection would discard it")
        XCTAssertEqual(ref, PlaneRef(source: .sketch(source.id)))
        XCTAssertEqual(document.session.document.sketches.first { $0.id == source.id }?.plane, source.plane)
        let newSolid = try XCTUnwrap(try body(document).brep)
        let after = try XCTUnwrap(OCCTKernel.renderMesh(from: newSolid).positions
            .map { hypot(Double($0.x), Double($0.z)) }.max())
        XCTAssertGreaterThan(after, before + 0.75)
        XCTAssertTrue(document.session.lastEvalErrors.isEmpty)
    }

    private func endOf(_ document: FloeCADDocument, _ id: FeatureID) throws -> ExtrudeEndDefinition {
        let node = try XCTUnwrap(document.session.document.features.node(id))
        guard case let .extrude(_, _, _, _, _, _, end?) = node.kind else {
            throw NSError(domain: "MissingAssociatedExtrusion", code: 1)
        }
        return end
    }

    private func endBody(_ document: FloeCADDocument, _ id: BodyID) throws -> Body {
        try XCTUnwrap(document.session.document.body(with: id))
    }

    private func endDistance(_ document: FloeCADDocument, _ id: FeatureID) throws -> Double {
        let node = try XCTUnwrap(document.session.document.features.node(id))
        guard case let .extrude(_, _, distance, _, _, _, _) = node.kind else {
            throw NSError(domain: "MissingExtrusion", code: 1)
        }
        return distance.value
    }

    private func makeNextFaceExtrusion(_ document: FloeCADDocument) throws -> (FeatureNode, FeatureNode, BodyID) {
        let source = try makeBox(document)
        let sourceBody = try body(document).id
        let profile = try run(document, "sketch.create", [
            "origin": [0, 20, 0], "xAxis": [1, 0, 0], "yAxis": [0, 0, -1]])
        let sketch = try XCTUnwrap(profile["sketchID"] as? String)
        try run(document, "sketch.addEntities", ["sketchID": sketch,
            "entities": [["kind": "circle", "center": [5, 5], "radius": 1]]])
        try run(document, "feature.extrude", ["sketchID": sketch, "seedPoint": [5, 5],
            "distance": -1, "end": "upToNext", "booleanTargets": [sourceBody.raw.uuidString]])
        let child = try XCTUnwrap(document.session.document.features.nodes.last)
        return (source, child, sourceBody)
    }

    func testThroughAllCutFollowsPlateThicknessInOneUndoAndReopens() async throws {
        let document = try await makeDocument(); defer { document.close() }
        let source = try makeBox(document)
        let sourceBody = try body(document).id
        let sketch = try run(document, "sketch.create", [
            "origin": [0, 0, 0], "xAxis": [1, 0, 0], "yAxis": [0, 0, -1]])
        let raw = try XCTUnwrap(sketch["sketchID"] as? String)
        try run(document, "sketch.addEntities", ["sketchID": raw,
            "entities": [["kind": "circle", "center": [20, 10], "radius": 2]]])
        try run(document, "feature.extrude", ["sketchID": raw, "seedPoint": [20, 10],
            "end": "throughAll", "boolean": "subtract", "booleanTargets": [sourceBody.raw.uuidString]])
        let cut = try XCTUnwrap(document.session.document.features.nodes.last)
        let originalEnd = try endOf(document, cut.id)
        XCTAssertEqual(originalEnd.targets.map(\.bodyID), [sourceBody])
        XCTAssertEqual(try volume(document), (800 - 4 * .pi) * 10, accuracy: 1e-3)
        let service = CADParameterService(document: document)
        let reply = service.handle(action: "update", args: ["feature_id": source.id.raw.uuidString,
            "changes": ["distance": 20]])
        XCTAssertEqual(reply["ok"] as? Bool, true, "\(reply)")
        XCTAssertEqual(try volume(document), (800 - 4 * .pi) * 20, accuracy: 1e-3,
            "A fixed-depth hole would leave material in the newly thickened plate")
        XCTAssertEqual(try body(document).id, sourceBody)
        XCTAssertNotNil(try body(document).brep)
        XCTAssertEqual(try endDistance(document, cut.id), 21, accuracy: 1e-6)
        XCTAssertEqual(try endOf(document, cut.id), originalEnd)
        document.session.undo()
        XCTAssertEqual(try volume(document), (800 - 4 * .pi) * 10, accuracy: 1e-3)
        XCTAssertEqual(try endDistance(document, cut.id), 11, accuracy: 1e-6)
        document.session.redo()
        XCTAssertEqual(try volume(document), (800 - 4 * .pi) * 20, accuracy: 1e-3)
        let saved = await document.save(); XCTAssertTrue(saved.succeeded, saved.error ?? "")
        let url = document.url; document.close()
        let reopened = try await FloeCADDocument.open(at: url); defer { reopened.close() }
        XCTAssertEqual(try volume(reopened), (800 - 4 * .pi) * 20, accuracy: 1e-3)
        XCTAssertEqual(try endDistance(reopened, cut.id), 21, accuracy: 1e-6)
        XCTAssertEqual(try endOf(reopened, cut.id), originalEnd)
    }

    func testNativeExtrusionCommitRetainsTheEndAndAnUnchangedFieldDoesNotDetachIt() async throws {
        let document = try await makeDocument(); defer { document.close() }
        let source = try makeBox(document)
        let created = try run(document, "sketch.create", [
            "origin": [0, 0, 0], "xAxis": [1, 0, 0], "yAxis": [0, 0, -1]])
        let raw = try XCTUnwrap(created["sketchID"] as? String)
        try run(document, "sketch.addEntities", ["sketchID": raw,
            "entities": [["kind": "circle", "center": [20, 10], "radius": 1]]])
        let sketch = try XCTUnwrap(document.session.document.sketches.first { $0.id.raw.uuidString == raw })
        let profile = try XCTUnwrap(ProfileDetector.detectProfiles(in: sketch).first)
        let viewModel = document.viewModel()
        viewModel.toolContext = .init(profile: profile, holes: [], plane: sketch.plane,
            sketchID: sketch.id, kind: .extrude(distance: 1))
        viewModel.mode = .extruding
        viewModel.setBooleanOverride(.subtract)
        XCTAssertEqual(try XCTUnwrap(viewModel.resolveExtrudeEnd(.throughAll)), 11, accuracy: 1e-6)
        viewModel.setExtrudeDistance(11)
        XCTAssertEqual(viewModel.toolContext?.extrudeTermination?.mode, .throughAll)
        viewModel.commitTool()
        let cut = try XCTUnwrap(document.session.document.features.nodes.last)
        XCTAssertNotEqual(cut.id, source.id)
        XCTAssertEqual(try endOf(document, cut.id).mode, .throughAll)
        XCTAssertEqual(try volume(document), (800 - .pi) * 10, accuracy: 1e-3)
        let reply = CADParameterService(document: document).handle(action: "update", args: [
            "feature_id": source.id.raw.uuidString, "changes": ["distance": 20]])
        XCTAssertEqual(reply["ok"] as? Bool, true, "\(reply)")
        XCTAssertEqual(try volume(document), (800 - .pi) * 20, accuracy: 1e-3)
    }

    func testUpToNextFollowsTheOriginalNamedMovingFaceAndReopens() async throws {
        let document = try await makeDocument(); defer { document.close() }
        let (source, child, _) = try makeNextFaceExtrusion(document)
        let childBody = try XCTUnwrap(child.outputBodyIDs.first)
        let original = try endOf(document, child.id)
        XCTAssertNotNil(original.nextFace?.elementName)
        XCTAssertEqual(OCCTKernel.volume(try XCTUnwrap(try endBody(document, childBody).brep)), 10 * .pi, accuracy: 1e-4)
        let reply = CADParameterService(document: document).handle(action: "update", args: [
            "feature_id": source.id.raw.uuidString, "changes": ["distance": 15]])
        XCTAssertEqual(reply["ok"] as? Bool, true, "\(reply)")
        let changed = try endBody(document, childBody)
        XCTAssertEqual(OCCTKernel.volume(try XCTUnwrap(changed.brep)), 5 * .pi, accuracy: 1e-4)
        XCTAssertEqual(try endDistance(document, child.id), -5, accuracy: 1e-6)
        XCTAssertEqual(try endOf(document, child.id), original, "Follow the same face rather than binding a nearer substitute")
        let points = changed.render.positions.map { changed.transform.applying(to: SIMD3<Double>($0)).y }
        XCTAssertEqual(try XCTUnwrap(points.min()), 15, accuracy: 1e-4)
        XCTAssertEqual(try XCTUnwrap(points.max()), 20, accuracy: 1e-4)
        document.session.undo()
        XCTAssertEqual(try endDistance(document, child.id), -10, accuracy: 1e-6)
        document.session.redo()
        let saved = await document.save(); XCTAssertTrue(saved.succeeded, saved.error ?? "")
        let url = document.url; document.close()
        let reopened = try await FloeCADDocument.open(at: url); defer { reopened.close() }
        XCTAssertEqual(try endOf(reopened, child.id), original)
        XCTAssertEqual(OCCTKernel.volume(try XCTUnwrap(try endBody(reopened, childBody).brep)), 5 * .pi, accuracy: 1e-4)
    }

    func testExtrusionHistoryUsesTheSameEndBindingAndExplicitDistanceDetach() async throws {
        let document = try await makeDocument(); defer { document.close() }
        let (source, child, _) = try makeNextFaceExtrusion(document)
        let service = CADParameterService(document: document)
        let unchangedCount = document.session.changeCount
        let unchanged = service.handle(action: "update", args: ["feature_id": child.id.raw.uuidString,
            "changes": ["end": "upToNext"]])
        XCTAssertEqual(unchanged["error"] as? String, "no_change")
        XCTAssertEqual(document.session.changeCount, unchangedCount)
        XCTAssertEqual(try parameter(document, feature: child.id, name: "distance")["editable"] as? Bool, false)
        let viewModel = document.viewModel()
        viewModel.setFeatureOption(child.id, key: .extrudeEnd, choice: ExtrudeEnd.blind.title)
        XCTAssertNil(viewModel.errorMessage)
        XCTAssertEqual(try endDistance(document, child.id), -10, accuracy: 1e-6)
        guard case let .extrude(_, _, _, _, _, _, detached) = document.session.document.features.node(child.id)?.kind else {
            return XCTFail("History lost the original extrusion")
        }
        XCTAssertNil(detached)
        viewModel.setFeatureOption(child.id, key: .extrudeEnd, choice: ExtrudeEnd.upToNext.title)
        XCTAssertNil(viewModel.errorMessage)
        XCTAssertNotNil(try endOf(document, child.id).nextFace)
        let detach = service.handle(action: "update", args: ["feature_id": child.id.raw.uuidString,
            "changes": ["end": "blind", "distance": -3]])
        XCTAssertEqual(detach["ok"] as? Bool, true, "\(detach)")
        let move = service.handle(action: "update", args: ["feature_id": source.id.raw.uuidString,
            "changes": ["distance": 12]])
        XCTAssertEqual(move["ok"] as? Bool, true, "\(move)")
        XCTAssertEqual(try endDistance(document, child.id), -3, accuracy: 1e-6)
    }

    func testInvalidEndEditsAndMissingSourcesPreserveGeometryAndUndo() async throws {
        let document = try await makeDocument(); defer { document.close() }
        let (source, child, _) = try makeNextFaceExtrusion(document)
        let childBody = try XCTUnwrap(child.outputBodyIDs.first)
        let service = CADParameterService(document: document)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let before = try encoder.encode(document.session.document.features)
        let oldVolume = OCCTKernel.volume(try XCTUnwrap(try endBody(document, childBody).brep))
        let count = document.session.changeCount
        let undo = document.session.undoStack.undoCommands.count
        let invalidChanges: [[String: Any]] = [
            ["distance": -3], ["symmetric": true], ["reversed": false],
            ["end_targets": [childBody.raw.uuidString]], ["end_targets": [UUID().uuidString]],
        ]
        for changes in invalidChanges {
            let reply = service.handle(action: "update", args: ["feature_id": child.id.raw.uuidString, "changes": changes])
            XCTAssertEqual(reply["ok"] as? Bool, false, "\(reply)")
            XCTAssertEqual(try encoder.encode(document.session.document.features), before)
            XCTAssertEqual(OCCTKernel.volume(try XCTUnwrap(try endBody(document, childBody).brep)), oldVolume, accuracy: 1e-6)
            XCTAssertEqual(document.session.changeCount, count)
            XCTAssertEqual(document.session.undoStack.undoCommands.count, undo)
        }
        let deletion = service.handle(action: "feature.delete", args: ["feature_id": source.id.raw.uuidString])
        XCTAssertEqual(deletion["error"] as? String, "has_dependents")
        XCTAssertEqual(document.session.changeCount, count)
        // A source that disappears during replay cannot be replaced by another
        // body's coincident/nearby face. The session rejects the entire edit.
        let suppressed = service.handle(action: "feature.suppress", args: [
            "feature_id": source.id.raw.uuidString, "suppressed": true])
        XCTAssertEqual(suppressed["ok"] as? Bool, false, "\(suppressed)")
        XCTAssertEqual(try encoder.encode(document.session.document.features), before)
        XCTAssertEqual(document.session.undoStack.undoCommands.count, undo)
    }

    func testAssociatedExtrusionFormatRejectsMalformedAndPreservesFutureAndLegacy() async throws {
        let document = try await makeDocument(); defer { document.close() }
        let (_, child, _) = try makeNextFaceExtrusion(document)
        XCTAssertEqual(CADDocumentFormat.requiredFormat(document: document.session.document), 7)
        let encoded = try JSONEncoder().encode(child.kind)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        var extrude = try XCTUnwrap(object["extrude"] as? [String: Any])
        var end = try XCTUnwrap(extrude["termination"] as? [String: Any])
        func assessment(_ value: [String: Any]) throws -> CADDocumentFormat.Assessment {
            let row = CADFeatureRecord(featureID: child.id.raw, orderIndex: 1, name: child.name,
                suppressed: false, kind: try JSONSerialization.data(withJSONObject: value),
                outputBodyIDs: try JSONEncoder().encode(child.outputBodyIDs))
            return try CADDocumentFormat.assess(planes: [], sketches: [], features: [row])
        }
        end["version"] = 999; extrude["termination"] = end; object["extrude"] = extrude
        XCTAssertTrue(try assessment(object).opaqueFeatures.contains(child.id.raw))
        XCTAssertThrowsError(try JSONDecoder().decode(FeatureKind.self, from: JSONSerialization.data(withJSONObject: object)))
        end["version"] = 1; end["nextFace"] = NSNull(); extrude["termination"] = end; object["extrude"] = extrude
        XCTAssertThrowsError(try assessment(object))
        extrude.removeValue(forKey: "termination"); object["extrude"] = extrude
        let legacy = try JSONDecoder().decode(FeatureKind.self, from: JSONSerialization.data(withJSONObject: object))
        guard case let .extrude(_, _, distance, _, _, _, legacyEnd) = legacy else { return XCTFail("Legacy extrusion lost") }
        XCTAssertNil(legacyEnd); XCTAssertEqual(distance.value, -10)
    }

    func testMergedExtrusionRemapsItsExactEndAndRebuildsAtNewPlacement() async throws {
        let document = try await makeDocument(); defer { document.close() }
        let (source, child, _) = try makeNextFaceExtrusion(document)
        let insertion = try ProjectMergeKit.insert(document.session.document, into: DesignDocument(),
            translation: SIMD3(100, 50, -20))
        let newSource = try XCTUnwrap(insertion.document.features.nodes.first)
        let newChild = try XCTUnwrap(insertion.document.features.nodes.last)
        guard case let .extrude(_, _, _, _, _, _, end?) = newChild.kind else { return XCTFail("Merge lost the end") }
        XCTAssertNotEqual(newChild.id, child.id); XCTAssertNotEqual(newSource.id, source.id)
        XCTAssertEqual(end.targets.first?.producer, newSource.id)
        XCTAssertEqual(end.nextFace?.body, end.targets.first)
        XCTAssertEqual(end.nextFace?.elementName?.creator, newSource.id)
        var revision: UInt64 = 0
        let result = insertion.document.features.evaluate(sketches: insertion.document.sketches,
            planes: insertion.document.planes, naming: SignatureNaming(), nextRevision: { revision += 1; return revision })
        XCTAssertTrue(result.errors.isEmpty, "\(result.errors)")
        XCTAssertEqual(result.resolvedExtrudeDistances[newChild.id] ?? 0, -10, accuracy: 1e-6)
        let actual = try XCTUnwrap(result.bodies.first { newChild.outputBodyIDs.contains($0.id) })
        XCTAssertEqual(OCCTKernel.volume(try XCTUnwrap(actual.brep)), 10 * .pi, accuracy: 1e-4)
    }

    private func importedBoredPlate(_ document: FloeCADDocument, twoHoles: Bool = false) async throws -> BodyID {
        var solid = try XCTUnwrap(OCCTKernel.primitiveShape(.box(width: 40, depth: 20, height: 10), placement: .identity))
        let holeLocations: [Double] = twoHoles ? [-8, 8] : [0]
        for x in holeLocations {
            let cutter = try XCTUnwrap(OCCTKernel.primitiveShape(.cylinder(radius: 2, height: 12),
                placement: Transform3D(translation: SIMD3(x, -1, 0))))
            solid = try XCTUnwrap(OCCTKernel.boolean(solid, cutter, op: 1))
        }
        let file = workDir.appendingPathComponent("bored-\(UUID().uuidString).step")
        XCTAssertTrue(OCCTKernel.writeSTEP([solid], to: file))
        let token = MeshImportCancellation()
        let plan = try await CADExactImportService.parseOffMain(data: Data(contentsOf: file),
            format: "step", fileName: "Bored plate.step", limits: .standard, cancellation: token)
        XCTAssertTrue(plan.parsedOffMain)
        let imported = try CADExactImportService.apply(plan, to: document, cancellation: token, undoMode: .singleStep)
        XCTAssertTrue(imported.outcome.isOK, imported.outcome.message ?? "")
        XCTAssertTrue(document.session.document.sketches.isEmpty)
        XCTAssertTrue(document.session.document.features.nodes.isEmpty)
        XCTAssertNotNil(try body(document).brep)
        return try body(document).id
    }

    private func boreIndex(_ document: FloeCADDocument, radius: Double, x: Double = 0) throws -> Int {
        let native = try XCTUnwrap(try body(document).brep)
        return try XCTUnwrap(OCCTKernel.faceInfo(native).first { info in
            guard let signature = info.signature, case let .cylindrical(r) = signature.kind else { return false }
            return abs(r - radius) < 1e-6 && abs(signature.centroid.x - x) < 1e-6
        }).index
    }

    func testNewPlanarEditCapturesUnownedNativeSourceInOneUndoAndReopensSameIDs() async throws {
        let document = try await makeDocument(); defer { document.close() }
        let handle = try XCTUnwrap(OCCTKernel.primitiveShape(
            .box(width: 40, depth: 20, height: 10), placement: .identity))
        let id = BodyID()
        var sourceBody = Body(id: id, name: "Imported exact box", transform: .identity,
            primitive: nil, render: RenderMesh(positions: [], normals: [], indices: []), revision: 0)
        XCTAssertTrue(sourceBody.adoptBRep(handle))
        document.session.perform(AddBodyCommand(body: sourceBody))
        let originalBytes = try XCTUnwrap(OCCTKernel.serialize(handle))
        func attachSource(_ title: String, _ bytes: Data) {
            let attachment = XCTAttachment(data: bytes, uniformTypeIdentifier: "public.plain-text")
            attachment.name = title; attachment.lifetime = .keepAlways; add(attachment)
        }
        attachSource("Unowned exact source before edit", originalBytes)
        let top = try XCTUnwrap(OCCTKernel.faceInfo(handle).first { $0.normal.y > 0.99 })
        XCTAssertEqual(OCCTKernel.serialize(handle), originalBytes, "Query must preserve the original handle")
        let undoBefore = document.session.undoStack.undoCommands.count
        try run(document, "feature.pushPull", ["bodyID": id.raw.uuidString,
            "face": [top.index], "distance": 2])
        XCTAssertEqual(document.session.document.features.nodes.count, 2)
        XCTAssertEqual(document.session.undoStack.undoCommands.count, undoBefore + 1)
        XCTAssertEqual(try volume(document), 9_600, accuracy: 1e-4)
        let nodes = document.session.document.features.nodes
        guard case let .baseSolid(source) = nodes[0].kind,
              case let .pushPull(reference, _, _) = nodes[1].kind else {
            return XCTFail("Capture and edit must share the exact source, never flatten an existing feature")
        }
        let name = try XCTUnwrap(reference.elementName)
        guard case let .immutableSourceFace(version, digest, _) = name.source else {
            return XCTFail("A new native face needs a verified immutable source identity")
        }
        XCTAssertEqual(version, 1); XCTAssertEqual(digest, source.sha256)
        XCTAssertEqual(reference.body.producer, nodes[0].id)
        XCTAssertEqual(reference.creator, nodes[0].id)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let recorded = try encoder.encode(document.session.document.features)
        let originalAfterEdit = try XCTUnwrap(OCCTKernel.serialize(handle))
        attachSource("Original handle after independent edit", originalAfterEdit)
        document.session.undo()
        XCTAssertTrue(document.session.document.features.nodes.isEmpty)
        XCTAssertEqual(try body(document).id, id)
        let restoredHandle = try XCTUnwrap(try body(document).brep)
        XCTAssertTrue(restoredHandle === handle, "Undo must restore the exact original body snapshot")
        let beforeMeasure = try XCTUnwrap(OCCTKernel.serialize(restoredHandle))
        attachSource("Undo source before measure", beforeMeasure)
        XCTAssertEqual(try volume(document), 8_000, accuracy: 1e-4)
        let afterMeasure = try XCTUnwrap(OCCTKernel.serialize(restoredHandle))
        attachSource("Undo source after measure", afterMeasure)
        XCTAssertEqual(afterMeasure, originalBytes)
        document.session.redo()
        XCTAssertEqual(try encoder.encode(document.session.document.features), recorded)
        XCTAssertEqual(try volume(document), 9_600, accuracy: 1e-4)
        let saved = await document.save(); XCTAssertTrue(saved.succeeded, saved.error ?? "")
        let url = document.url; document.close()
        let reopened = try await FloeCADDocument.open(at: url); defer { reopened.close() }
        XCTAssertEqual(try body(reopened).id, id)
        XCTAssertEqual(try encoder.encode(reopened.session.document.features), recorded)
        XCTAssertEqual(try volume(reopened), 9_600, accuracy: 1e-4)
        var replayRevision: UInt64 = 0
        let rebuilt = reopened.session.document.features.evaluate(sketches: [], planes: [],
            naming: SignatureNaming(), nextRevision: { replayRevision += 1; return replayRevision })
        XCTAssertTrue(rebuilt.errors.isEmpty, "\(rebuilt.errors)")
        XCTAssertEqual(abs(OCCTKernel.volume(try XCTUnwrap(rebuilt.bodies.first?.brep))), 9_600, accuracy: 1e-4)
    }

    func testHistoryFaceRepickUsesConsumedInputNamesAndRejectsLateSelection() async throws {
        let document = try await makeDocument(); defer { document.close() }
        let id = BodyID()
        let source = FeatureNode(name: "Box", kind: .primitive(
            spec: .box(width: 40, depth: 20, height: 10), placement: .identity), outputBodyIDs: [id])
        document.session.recordAndRebuild([source], title: "Box")
        let top = try XCTUnwrap(OCCTKernel.faceInfo(try XCTUnwrap(try body(document).brep)).first { $0.normal.y > 0.99 })
        try run(document, "feature.pushPull", ["bodyID": id.raw.uuidString,
            "face": [top.index], "distance": 2])
        let editID = try XCTUnwrap(document.session.document.features.nodes.last?.id)
        let model = document.viewModel()
        XCTAssertTrue(model.beginFeatureFaceEdit(editID), model.errorMessage ?? "")
        model.handle(.tap(ray: Ray(origin: SIMD3(0, 50, 0), direction: SIMD3(0, -1, 0))))
        guard case let .pushPull(topRef, _, _)? = document.session.document.features.node(editID)?.kind else {
            return XCTFail("Repick lost the existing feature")
        }
        XCTAssertEqual(topRef.signature.centroid.y, 10, accuracy: 1e-5,
            "History must pick the consumed cap, not the already pushed cap at y=12")
        XCTAssertTrue(try XCTUnwrap(topRef.elementName).isStableFaceIdentity)
        XCTAssertEqual(topRef.body.producer, source.id)
        XCTAssertTrue(model.beginFeatureFaceEdit(editID), model.errorMessage ?? "")
        model.handle(.tap(ray: Ray(origin: SIMD3(100, 5, 0), direction: SIMD3(-1, 0, 0))))
        XCTAssertNil(model.errorMessage)
        XCTAssertEqual(try volume(document), 8_400, accuracy: 1e-4)
        guard case let .pushPull(sideRef, _, _)? = document.session.document.features.node(editID)?.kind else {
            return XCTFail("Repick replaced the feature ID")
        }
        XCTAssertGreaterThan(sideRef.signature.normal.x, 0.99)
        XCTAssertTrue(try XCTUnwrap(sideRef.elementName).isStableFaceIdentity)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let beforeLateTap = try encoder.encode(document.session.document.features)
        XCTAssertTrue(model.beginFeatureFaceEdit(editID))
        let beforeRename = try body(document)
        document.session.perform(RenameItemCommand(item: .body(id), before: beforeRename.name, after: "Changed during pick"))
        let undo = document.session.undoStack.undoCommands.count
        model.handle(.tap(ray: Ray(origin: SIMD3(0, 50, 0), direction: SIMD3(0, -1, 0))))
        XCTAssertNotNil(model.errorMessage, "A changed generation must ask the user to reselect")
        if case .pickingFeatureFace = model.mode { XCTFail("A stale pick must release its old input snapshot") }
        XCTAssertEqual(try encoder.encode(document.session.document.features), beforeLateTap)
        XCTAssertEqual(document.session.undoStack.undoCommands.count, undo)
        XCTAssertEqual(try volume(document), 8_400, accuracy: 1e-4)
    }

    func testNewFaceEditRefusesUnqualifiedOwnedSweepWithoutFlatteningOrMutation() async throws {
        let document = try await makeDocument(); defer { document.close() }
        let sketch = Sketch(plane: .ground, entities: [.rect(id: UUID(), min: SIMD2(-2, -2), max: SIMD2(2, 2))])
        document.session.perform(AddSketchCommand(sketch: sketch))
        let id = BodyID()
        let sweep = FeatureNode(name: "Bent sweep", kind: .sweep(
            profile: ProfileRef(sketchID: sketch.id, entityIDs: [], holeEntityIDs: [], seedPoint: .zero),
            plane: PlaneRef(source: .sketch(sketch.id)),
            spine: [PointWrapper(SIMD3(0, 0, 0)), PointWrapper(SIMD3(0, 12, 0)), PointWrapper(SIMD3(12, 24, 0))],
            boolean: BooleanIntent(op: .newBody, resolvedTargets: []), helix: nil), outputBodyIDs: [id])
        document.session.recordAndRebuild([sweep], title: "Bent sweep")
        XCTAssertTrue(document.session.lastEvalErrors.isEmpty)
        let before = try body(document), brep = try XCTUnwrap(before.brep)
        let face = try XCTUnwrap(OCCTKernel.faceInfo(brep).first { candidate in
            guard let signature = candidate.signature, case .planar = signature.kind else { return false }
            return document.session.lastKernelNames[id]?[candidate.index]?.isStableFaceIdentity != true
        })
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let graph = try encoder.encode(document.session.document.features)
        let bytes = try XCTUnwrap(OCCTKernel.serialize(brep))
        let undo = document.session.undoStack.undoCommands.count
        let generation = document.session.changeCount
        let saved = await document.save(); XCTAssertTrue(saved.succeeded)
        let response = CADCommandExecutor(viewModel: document.viewModel()).run(
            .pushPull(body: id, face: face.index, distance: 1, radial: false))
        XCTAssertEqual(response.status, 409, String(decoding: response.body, as: UTF8.self))
        XCTAssertTrue(String(decoding: response.body, as: UTF8.self).contains("face_identity_unavailable"))
        XCTAssertEqual(try encoder.encode(document.session.document.features), graph)
        XCTAssertEqual(document.session.undoStack.undoCommands.count, undo)
        XCTAssertEqual(document.session.changeCount, generation)
        XCTAssertEqual(OCCTKernel.serialize(try XCTUnwrap(try body(document).brep)), bytes)
        XCTAssertFalse(document.hasUnsavedChanges)
        XCTAssertFalse(document.session.document.features.nodes.contains {
            if case .baseSolid = $0.kind { return true }; return false
        }, "An owned parametric model must never be replaced with a frozen copy to fabricate names")
    }

    func testImportedBoreRadiusEditRetainsExactSourceOneUndoAndReopen() async throws {
        let document = try await makeDocument(); defer { document.close() }
        let id = try await importedBoredPlate(document)
        let before = try XCTUnwrap(OCCTKernel.serialize(try XCTUnwrap(try body(document).brep)))
        let count = document.session.undoStack.undoCommands.count
        try run(document, "feature.pushPull", ["bodyID": id.raw.uuidString,
            "face": [try boreIndex(document, radius: 2)], "distance": 1, "mode": "cylinderRadial"])
        XCTAssertEqual(try body(document).id, id)
        XCTAssertEqual(try volume(document), 8000 - 90 * .pi, accuracy: 1e-3)
        XCTAssertGreaterThan(try boreIndex(document, radius: 3), 0)
        XCTAssertEqual(document.session.document.features.nodes.count, 2)
        XCTAssertEqual(document.session.undoStack.undoCommands.count, count + 1)
        guard case let .baseSolid(source) = document.session.document.features.nodes[0].kind else {
            return XCTFail("An imported body needs its immutable exact replay source")
        }
        let feature = try XCTUnwrap(document.session.document.features.nodes.last)
        let radialQuery = try XCTUnwrap(try rows(document, "features").first { $0["kind"] as? String == "pushPull" })
        let radialParameters = try XCTUnwrap(radialQuery["parameters"] as? [[String: Any]])
        let radialMode = try XCTUnwrap(radialParameters.first { $0["name"] as? String == "mode" })
        XCTAssertEqual(radialMode["value"] as? String, "cylinderRadial")
        XCTAssertEqual(radialMode["editable"] as? Bool, false)
        let query = try XCTUnwrap(try rows(document, "features").first { $0["kind"] as? String == "importedSolid" })
        let text = String(decoding: try JSONSerialization.data(withJSONObject: query), as: UTF8.self)
        XCTAssertFalse(text.contains("brepData"), "Original source bytes are storage, not model context")
        document.session.undo()
        XCTAssertTrue(document.session.document.features.nodes.isEmpty)
        XCTAssertEqual(try volume(document), 8000 - 40 * .pi, accuracy: 1e-3)
        XCTAssertEqual(try XCTUnwrap(OCCTKernel.serialize(try XCTUnwrap(try body(document).brep))), before)
        document.session.redo()
        let update = CADParameterService(document: document).handle(action: "update", args: [
            "feature_id": feature.id.raw.uuidString, "changes": ["distance": 2]])
        XCTAssertEqual(update["ok"] as? Bool, true, "\(update)")
        XCTAssertEqual(document.session.document.features.nodes.count, 2)
        XCTAssertEqual(try volume(document), 8000 - 160 * .pi, accuracy: 1e-3)
        document.session.undo()
        XCTAssertEqual(try volume(document), 8000 - 90 * .pi, accuracy: 1e-3)
        document.session.redo()
        let saved = await document.save(); XCTAssertTrue(saved.succeeded, saved.error ?? "")
        let url = document.url; document.close()
        let reopened = try await FloeCADDocument.open(at: url); defer { reopened.close() }
        XCTAssertEqual(try body(reopened).id, id)
        XCTAssertEqual(try volume(reopened), 8000 - 160 * .pi, accuracy: 1e-3)
        XCTAssertNotNil(try body(reopened).brep)
        guard case let .baseSolid(restored) = reopened.session.document.features.nodes[0].kind else { return XCTFail("Source lost") }
        XCTAssertEqual(restored.sha256, source.sha256)
        XCTAssertNotNil(reopened.session.document.features.node(feature.id))
    }

    func testRadialEditTargetsOnlyOneOfTwoEqualRadiusImportedBores() async throws {
        let document = try await makeDocument(); defer { document.close() }
        let id = try await importedBoredPlate(document, twoHoles: true)
        try run(document, "feature.pushPull", ["bodyID": id.raw.uuidString,
            "face": [try boreIndex(document, radius: 2, x: -8)], "distance": 1, "mode": "cylinderRadial"])
        XCTAssertGreaterThan(try boreIndex(document, radius: 3, x: -8), 0)
        XCTAssertGreaterThan(try boreIndex(document, radius: 2, x: 8), 0)
        XCTAssertEqual(try volume(document), 8000 - 130 * .pi, accuracy: 1e-3)
    }

    func testRadialChainFollowsItsVerifiedSourceAndRejectsAChangedSourceDigest() async throws {
        let document = try await makeDocument(); defer { document.close() }
        let id = try await importedBoredPlate(document)
        try run(document, "feature.pushPull", ["bodyID": id.raw.uuidString,
            "face": [try boreIndex(document, radius: 2)], "distance": 1, "mode": "cylinderRadial"])
        let first = try XCTUnwrap(document.session.document.features.nodes.last)
        try run(document, "feature.pushPull", ["bodyID": id.raw.uuidString,
            "face": [try boreIndex(document, radius: 3)], "distance": 1, "mode": "cylinderRadial"])
        XCTAssertEqual(try volume(document), 8000 - 160 * .pi, accuracy: 1e-3)
        let reply = CADParameterService(document: document).handle(action: "update", args: [
            "feature_id": first.id.raw.uuidString, "changes": ["distance": 2]])
        XCTAssertEqual(reply["ok"] as? Bool, true, "\(reply)")
        XCTAssertEqual(try volume(document), 8000 - 250 * .pi, accuracy: 1e-3)
        XCTAssertGreaterThan(try boreIndex(document, radius: 5), 0)
        document.session.undo()
        XCTAssertEqual(try volume(document), 8000 - 160 * .pi, accuracy: 1e-3)
        document.session.redo()
        var graph = document.session.document.features
        guard case let .pushPull(reference, distance, mode) = graph.nodes[1].kind,
              let identity = reference.elementName,
              case let .immutableSourceFace(version, _, index) = identity.source else { return XCTFail("Verified source identity missing") }
        XCTAssertFalse(identity.requiresExactSignature)
        XCTAssertTrue(ElementName(creator: identity.creator, source: .kernelFace(index: index)).requiresExactSignature,
            "An old unqualified ordinal still needs exact proof")
        var wrong = reference
        wrong.elementName = ElementName(creator: identity.creator,
            source: .immutableSourceFace(version: version, sha256: String(repeating: "0", count: 64), index: index))
        graph.nodes[1].kind = .pushPull(face: wrong, distance: distance, mode: mode)
        var revision: UInt64 = 0
        let refused = graph.evaluate(sketches: [], planes: [], naming: SignatureNaming(),
            nextRevision: { revision += 1; return revision })
        XCTAssertNotNil(refused.errors[first.id], "A different source must never inherit a matching face by resemblance")
        XCTAssertEqual(try volume(document), 8000 - 250 * .pi, accuracy: 1e-3)
    }

    func testNativeScaledBorePreviewAndCommitPreserveTheRestOfTheImportedBody() async throws {
        let document = try await makeDocument(); defer { document.close() }
        let id = try await importedBoredPlate(document)
        let original = try body(document)
        var scaled = original; scaled.transform.scale = 2; scaled.transform.translation.x = 5
        document.session.perform(ReplaceBodyCommand(title: "Placement", before: original, after: scaled))
        let cylinder = try XCTUnwrap(FaceTopology.enumerateFaces(in: scaled.render).cylindrical.first)
        let viewModel = document.viewModel()
        let nativeFace = try KernelOps.radialFaceIndex(body: scaled, triangles: cylinder.triangles)
        XCTAssertEqual(nativeFace, try boreIndex(document, radius: 2))
        let triangle = try XCTUnwrap(cylinder.triangles.first)
        let vertices = (0..<3).map { scaled.render.positions[Int(scaled.render.indices[triangle * 3 + $0])] }
        let localHit = (vertices[0] + vertices[1] + vertices[2]) / 3
        let hit = PickHit(bodyID: id, distance: 1,
            worldPoint: SIMD3<Float>(scaled.transform.applying(to: SIMD3<Double>(localHit))), triangleIndex: triangle)
        viewModel.chooseSelectThrough(.init(id: "imported-bore", name: "Bore", target: .face(hit)))
        _ = try XCTUnwrap(viewModel.toolContext?.cylinderFace, "The native selected bore must arm radial editing")
        viewModel.setExtrudeDistance(2) // two world mm = one local radius mm
        let preview = try XCTUnwrap(viewModel.toolContext?.preview)
        let extent = preview.render.localAABB
        XCTAssertGreaterThan(extent.max.x - extent.min.x, 79,
            "Preview must retain the plate, not replace the entire body with a cylinder")
        viewModel.commitTool()
        XCTAssertNil(viewModel.errorMessage)
        XCTAssertEqual(try body(document).id, id)
        XCTAssertEqual(try body(document).transform, scaled.transform)
        XCTAssertGreaterThan(try boreIndex(document, radius: 3), 0)
        XCTAssertEqual(try volume(document), (8000 - 90 * .pi) * 8, accuracy: 1e-2)
    }

    func testRadialCollapseAndFailedReplayPreserveImportedSourceAndHistory() async throws {
        let document = try await makeDocument(); defer { document.close() }
        let id = try await importedBoredPlate(document)
        let before = try XCTUnwrap(OCCTKernel.serialize(try XCTUnwrap(try body(document).brep)))
        let undo = document.session.undoStack.undoCommands.count
        let command = try JSONSerialization.data(withJSONObject: ["op": "feature.pushPull", "args": [
            "bodyID": id.raw.uuidString, "face": [try boreIndex(document, radius: 2)],
            "distance": -3, "mode": "cylinderRadial"]])
        let collapsed = document.executeJSON(command)
        XCTAssertFalse(collapsed.isOK)
        XCTAssertEqual(collapsed.errorCode, "bad_radial_offset", "This must reach radius validation, not fail argument parsing")
        XCTAssertTrue(document.session.document.features.nodes.isEmpty)
        XCTAssertEqual(document.session.undoStack.undoCommands.count, undo)
        XCTAssertEqual(try XCTUnwrap(OCCTKernel.serialize(try XCTUnwrap(try body(document).brep))), before)
        try run(document, "feature.pushPull", ["bodyID": id.raw.uuidString,
            "face": [try boreIndex(document, radius: 2)], "distance": 1, "mode": "cylinderRadial"])
        let feature = try XCTUnwrap(document.session.document.features.nodes.last)
        let afterUndo = document.session.undoStack.undoCommands.count
        let rejection = CADParameterService(document: document).handle(action: "update", args: [
            "feature_id": feature.id.raw.uuidString, "changes": ["distance": -3]])
        XCTAssertEqual(rejection["ok"] as? Bool, false, "\(rejection)")
        XCTAssertEqual(document.session.undoStack.undoCommands.count, afterUndo)
        XCTAssertEqual(try volume(document), 8000 - 90 * .pi, accuracy: 1e-3)
        XCTAssertGreaterThan(try boreIndex(document, radius: 3), 0)
    }

    func testNativeRadialFaceMappingAcceptsUVCornerSplitsAndRejectsChangedGeometry() async throws {
        let document = try await makeDocument(); defer { document.close() }
        _ = try await importedBoredPlate(document)
        let original = try body(document)
        let cylinder = try XCTUnwrap(FaceTopology.enumerateFaces(in: original.render).cylindrical.first)
        let index = try KernelOps.radialFaceIndex(body: original, triangles: cylinder.triangles)
        var split = original
        split.render = RenderMesh(
            positions: original.render.indices.map { original.render.positions[Int($0)] },
            normals: original.render.indices.map { original.render.normals[Int($0)] },
            indices: original.render.indices.indices.map(UInt32.init),
            texcoords: original.render.indices.indices.map { SIMD2<Float>(Float($0 % 2), Float($0 % 3)) })
        XCTAssertEqual(try KernelOps.radialFaceIndex(body: split, triangles: cylinder.triangles), index,
            "Only vertex storage changed; the exact ordered native triangles still identify the selected wall")
        split.render.positions[0].x += 0.01
        XCTAssertThrowsError(try KernelOps.radialFaceIndex(body: split, triangles: cylinder.triangles),
            "Changed triangle content must not inherit the old native face channel")
    }

    func testImportedSourceDigestFutureVersionAndFaceWitnessFenceTheReplayMemo() async throws {
        let document = try await makeDocument(); defer { document.close() }
        let id = try await importedBoredPlate(document)
        try run(document, "feature.pushPull", ["bodyID": id.raw.uuidString,
            "face": [try boreIndex(document, radius: 2)], "distance": 1, "mode": "cylinderRadial"])
        let base = document.session.document.features.nodes[0]
        guard case let .baseSolid(source) = base.kind else { return XCTFail("Source missing") }
        var payload = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(source)) as? [String: Any])
        payload["sha256"] = String(repeating: "0", count: 64)
        XCTAssertThrowsError(try JSONDecoder().decode(NativeBodySource.self,
            from: JSONSerialization.data(withJSONObject: payload)))
        payload["sha256"] = source.sha256; payload["version"] = 999
        let futureKind = try JSONSerialization.data(withJSONObject: ["baseSolid": ["source": payload]])
        let row = CADFeatureRecord(featureID: base.id.raw, orderIndex: 0, name: base.name,
            suppressed: false, kind: futureKind, outputBodyIDs: try JSONEncoder().encode([id]))
        XCTAssertTrue(try CADDocumentFormat.assess(planes: [], sketches: [], features: [row]).opaqueFeatures.contains(base.id.raw))
        payload["version"] = 1
        var witnesses = try XCTUnwrap(payload["faces"] as? [[String: Any]])
        witnesses[0]["index"] = 10000; payload["faces"] = witnesses
        let bad = try JSONDecoder().decode(NativeBodySource.self, from: JSONSerialization.data(withJSONObject: payload))
        XCTAssertNotEqual(bad.faceWitnessSHA256, source.faceWitnessSHA256)
        var graph = FeatureGraph(nodes: [base]), cache = EvalCache(), revision: UInt64 = 0
        let first = graph.evaluate(sketches: [], planes: [], naming: SignatureNaming(),
            nextRevision: { revision += 1; return revision }, cache: &cache)
        XCTAssertTrue(first.errors.isEmpty)
        graph.nodes[0].kind = .baseSolid(source: bad)
        let refused = graph.evaluate(sketches: [], planes: [], naming: SignatureNaming(),
            nextRevision: { revision += 1; return revision }, cache: &cache)
        XCTAssertNotNil(refused.errors[base.id]); XCTAssertTrue(refused.bodies.isEmpty)
        XCTAssertEqual(CADDocumentFormat.requiredFormat(document: document.session.document), 7)
    }

    func testImportedRadialSourceAndNamedFacesMergeWithoutDoubleTranslation() async throws {
        let document = try await makeDocument(); defer { document.close() }
        let id = try await importedBoredPlate(document)
        try run(document, "feature.pushPull", ["bodyID": id.raw.uuidString,
            "face": [try boreIndex(document, radius: 2)], "distance": 1, "mode": "cylinderRadial"])
        let owner = try XCTUnwrap(document.session.document.features.nodes.last)
        let move = FeatureNode(name: "Move", kind: .transform(body: BodyRef(producer: owner.id, bodyID: id),
            delta: Transform3D(translation: SIMD3(10, 0, 0))), outputBodyIDs: [id])
        document.session.recordAndRebuild([move], title: "Move")
        let insertion = try ProjectMergeKit.insert(document.session.document, into: DesignDocument(),
            translation: SIMD3(100, 50, 20))
        var revision: UInt64 = 0
        let result = insertion.document.features.evaluate(sketches: [], planes: [], naming: SignatureNaming(),
            nextRevision: { revision += 1; return revision })
        XCTAssertTrue(result.errors.isEmpty, "\(result.errors)")
        let merged = try XCTUnwrap(result.bodies.first)
        XCTAssertEqual(OCCTKernel.volume(try XCTUnwrap(merged.brep)), 8000 - 90 * .pi, accuracy: 1e-3)
        let points = merged.render.positions.map { merged.transform.applying(to: SIMD3<Double>($0)) }
        XCTAssertEqual(try XCTUnwrap(points.map(\.x).min()), 90, accuracy: 1e-4)
        XCTAssertEqual(try XCTUnwrap(points.map(\.y).min()), 50, accuracy: 1e-4)
        XCTAssertEqual(try XCTUnwrap(points.map(\.z).min()), 10, accuracy: 1e-4)
    }

    func testImportedRadialMergeTracksTheFrameBeforeAndAfterABooleanBake() async throws {
        let document = try await makeDocument(); defer { document.close() }
        let id = try await importedBoredPlate(document)
        try run(document, "feature.pushPull", ["bodyID": id.raw.uuidString,
            "face": [try boreIndex(document, radius: 2)], "distance": 1, "mode": "cylinderRadial"])
        let radial = try XCTUnwrap(document.session.document.features.nodes.last)
        let toolID = BodyID()
        let tool = FeatureNode(name: "Corner cutter", kind: .primitive(
            spec: .box(width: 4, depth: 4, height: 12), placement: Transform3D(translation: SIMD3(18,-1,8))),
            outputBodyIDs: [toolID])
        let cut = FeatureNode(name: "Corner", kind: .boolean(kind: .subtract,
            target: BodyRef(producer: radial.id, bodyID: id), tools: [BodyRef(producer: tool.id, bodyID: toolID)]),
            outputBodyIDs: [id])
        document.session.recordAndRebuild([tool, cut], title: "Corner")
        XCTAssertTrue(document.session.lastEvalErrors.isEmpty, "\(document.session.lastEvalErrors)")
        XCTAssertEqual(try volume(document), 7840 - 90 * .pi, accuracy: 1e-3)
        try run(document, "feature.pushPull", ["bodyID": id.raw.uuidString,
            "face": [try boreIndex(document, radius: 3)], "distance": 1, "mode": "cylinderRadial"])
        let insertion = try ProjectMergeKit.insert(document.session.document, into: DesignDocument(),
            translation: SIMD3(100, 50, 20))
        var revision: UInt64 = 0
        let result = insertion.document.features.evaluate(sketches: [], planes: [], naming: SignatureNaming(),
            nextRevision: { revision += 1; return revision })
        XCTAssertTrue(result.errors.isEmpty, "\(result.errors)")
        let merged = try XCTUnwrap(result.bodies.first)
        XCTAssertEqual(OCCTKernel.volume(try XCTUnwrap(merged.brep)), 7840 - 160 * .pi, accuracy: 1e-3)
        let points = merged.render.positions.map { merged.transform.applying(to: SIMD3<Double>($0)) }
        XCTAssertEqual(try XCTUnwrap(points.map(\.x).min()), 80, accuracy: 1e-4)
        XCTAssertEqual(try XCTUnwrap(points.map(\.y).min()), 50, accuracy: 1e-4)
        XCTAssertEqual(try XCTUnwrap(points.map(\.z).min()), 10, accuracy: 1e-4)
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
        let table = try XCTUnwrap(document.session.lastFaceTables[current.id])
        let top = try XCTUnwrap(table.entries.max { $0.signature.normal.y < $1.signature.normal.y })
        XCTAssertGreaterThan(top.signature.normal.y, 0.99)
        XCTAssertTrue(top.elementName?.isStableFaceIdentity == true,
                      "The authored end-section plane must identify the real mesh loft cap")
        let ref = FaceRef(body: BodyRef(producer: source.id, bodyID: current.id),
                          creator: source.id, role: top.role, signature: top.signature,
                          elementName: top.elementName)
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

/// M23: the actual command/editor -> one history transaction -> frozen target
/// resolver -> OCCT path. Analytic plane/volume checks are independent of the
/// saved fallback coordinates and of the renderer.
@MainActor
final class CADFeaturePlaneReferenceTests: XCTestCase {
    func testSingularFaceCommandsAcceptExactScalarAndLegacyArrayWithoutCoercion() throws {
        let source = UUID().uuidString, target = BodyID()
        let operations: [(String, [String: Any])] = [
            ("feature.pushPull", ["distance": 2]),
            ("feature.moveFace", ["delta": [0, 0, 2]]),
            ("feature.scaleFace", ["factor": 1.1]),
            ("feature.rotateFace", ["angleDegrees": 5]),
            ("feature.draftFace", ["angleDegrees": 5]),
            ("feature.replaceFace", ["targetOrigin": [0, 20, 0], "targetNormal": [0, 1, 0]])
        ]
        for (op, extra) in operations {
            for face in [2, [2]] as [Any] {
                var args = extra; args["bodyID"] = source; args["face"] = face
                let command: [String: Any] = ["op": op, "args": args]
                let decoded = try XCTUnwrap(JSONSerialization.jsonObject(with:
                    JSONSerialization.data(withJSONObject: command)) as? [String: Any])
                for value in [command, decoded] {
                    if case .failure(let error) = AgentExec.parse(value) {
                        XCTFail("\(op) rejected a singular scalar/array: \(error)")
                    }
                }
            }
            for invalid in [true, 0, -1, 1.5, "2", NSNull(), [true], [1.5], [], [1, 2]] as [Any] {
                var args = extra; args["bodyID"] = source; args["face"] = invalid
                if case .success = AgentExec.parse(["op": op, "args": args]) {
                    XCTFail("\(op) accepted an invalid singular face: \(invalid)")
                }
            }
        }
        for sourceFace in [1, [1]] as [Any] {
            for targetFace in [2, [2]] as [Any] {
                let args: [String: Any] = ["bodyID": source, "face": sourceFace,
                    "referencePlane": ["bodyID": target.raw.uuidString, "face": targetFace]]
                guard case let .success(.replaceFace(_, 1, _, _, _, selection)) =
                    AgentExec.parse(["op": "feature.replaceFace", "args": args]) else {
                    return XCTFail("Both face spellings must work independently")
                }
                XCTAssertEqual(selection, .face(target, 2))
            }
        }
        for faces in [[1, 2], 1] as [Any] {
            let result = AgentExec.parse(["op": "feature.deleteFace",
                "args": ["bodyID": source, "faces": faces]])
            if faces is [Int] {
                if case .failure(let error) = result { XCTFail("Legacy multi-face array: \(error)") }
            } else if case .success = result {
                XCTFail("Multi-face operations still require an explicit array")
            }
        }
    }

    private var directory: URL!
    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("CADReferencePlane-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }
    override func tearDown() async throws { try? FileManager.default.removeItem(at: directory) }
    private func document() async throws -> FloeCADDocument {
        try await FloeCADDocument.create(at: directory.appendingPathComponent("Part.floecad"), name: "Linked target")
    }
    @discardableResult
    private func box(_ document: FloeCADDocument, x: Double, height: Double) -> FeatureNode {
        let entity = UUID()
        let sketch = Sketch(name: "Profile", plane: SketchPlane(origin: SIMD3(x, 0, 0),
            xAxis: SIMD3(1, 0, 0), yAxis: SIMD3(0, 0, -1)),
            entities: [.rect(id: entity, min: .zero, max: SIMD2(40, 20))])
        let node = FeatureNode(name: "Box", kind: .extrude(
            profile: ProfileRef(sketchID: sketch.id, entityIDs: [entity], holeEntityIDs: [], seedPoint: SIMD2(5, 5)),
            plane: PlaneRef(source: .sketch(sketch.id)), distance: Expr(value: height), symmetric: false,
            boolean: BooleanIntent(op: .newBody, resolvedTargets: []), extraProfiles: []), outputBodyIDs: [BodyID()])
        document.session.recordAndRebuild([node], extra: [AddSketchCommand(sketch: sketch)], title: "Box")
        XCTAssertTrue(document.session.lastEvalErrors.isEmpty)
        return node
    }
    private func body(_ document: FloeCADDocument, _ node: FeatureNode) throws -> Body {
        try XCTUnwrap(document.session.document.body(with: try XCTUnwrap(node.outputBodyIDs.first)))
    }
    private func top(_ body: Body) throws -> Int {
        try XCTUnwrap(OCCTKernel.faceInfo(try XCTUnwrap(body.brep)).first { $0.normal.y > 0.99 }).index
    }
    private func volume(_ body: Body) throws -> Double { abs(OCCTKernel.volume(try XCTUnwrap(body.brep))) }
    private func run(_ document: FloeCADDocument, _ op: String, _ args: [String: Any]) throws {
        let value = document.executeJSON(try JSONSerialization.data(withJSONObject: ["op": op, "args": args]))
        XCTAssertTrue(value.isOK, "\(value.errorCode ?? ""): \(value.message ?? "")")
        XCTAssertTrue(document.session.lastEvalErrors.isEmpty, "\(document.session.lastEvalErrors)")
        guard value.isOK else { throw CADDocumentError(code: value.errorCode ?? "failed", message: value.message ?? "failed") }
    }
    private func height(_ document: FloeCADDocument, _ node: FeatureNode, _ value: Double) throws {
        let result = CADParameterService(document: document).handle(action: "update", args: [
            "feature_id": node.id.raw.uuidString, "changes": ["distance": value]])
        XCTAssertEqual(result["ok"] as? Bool, true, "\(result)")
        guard result["ok"] as? Bool == true else { throw CADDocumentError(code: "height", message: "\(result)") }
    }
    private func linkedReplace(_ document: FloeCADDocument, source: FeatureNode, target: FeatureNode) throws -> FeatureNode {
        let a = try body(document, source), b = try body(document, target)
        try run(document, "feature.replaceFace", ["bodyID": a.id.raw.uuidString, "face": top(a),
            "referencePlane": ["bodyID": b.id.raw.uuidString, "face": top(b)]])
        return try XCTUnwrap(document.session.document.features.nodes.last)
    }
    private func rebuilt(_ document: DesignDocument, cache: inout EvalCache) -> EvalResult {
        var revision: UInt64 = 0
        return document.features.evaluate(sketches: document.sketches, planes: document.planes,
            naming: SignatureNaming(), nextRevision: { revision += 1; return revision }, cache: &cache)
    }

    func testReplaceFollowsNamedTargetOnSameFeatureUndoRedoAndReopen() async throws {
        let document = try await document(); defer { document.close() }
        let source = box(document, x: 0, height: 10), target = box(document, x: 60, height: 20)
        let undo = document.session.undoStack.undoCommands.count
        let edit = try linkedReplace(document, source: source, target: target)
        XCTAssertEqual(document.session.undoStack.undoCommands.count, undo + 1)
        XCTAssertEqual(try volume(body(document, source)), 16_000, accuracy: 1e-3)
        let reference = try XCTUnwrap(edit.kind.operationPlaneReference)
        XCTAssertEqual(reference.writerVersion?.writer, target.id)
        XCTAssertEqual(reference.writerVersion?.bodyID, target.outputBodyIDs.first)
        try height(document, target, 25)
        XCTAssertNotNil(document.session.document.features.node(edit.id))
        XCTAssertEqual(document.session.document.features.node(edit.id)?.kind.operationPlaneReference, reference)
        XCTAssertEqual(try volume(body(document, source)), 20_000, accuracy: 1e-3)
        document.session.undo()
        XCTAssertEqual(try volume(body(document, source)), 16_000, accuracy: 1e-3)
        document.session.redo()
        XCTAssertEqual(try volume(body(document, source)), 20_000, accuracy: 1e-3)
        let saved = await document.save(); XCTAssertTrue(saved.succeeded, saved.error ?? "")
        let url = document.url; document.close()
        let opened = try await FloeCADDocument.open(at: url); defer { opened.close() }
        XCTAssertEqual(opened.session.document.features.node(edit.id)?.kind.operationPlaneReference, reference)
        XCTAssertEqual(try volume(body(opened, source)), 20_000, accuracy: 1e-3)
        try height(opened, target, 22)
        XCTAssertEqual(try volume(body(opened, source)), 17_600, accuracy: 1e-3)
        let descriptor = CADParameterService.describe(try XCTUnwrap(opened.session.document.features.node(edit.id)),
            document: opened.session.document)
        XCTAssertTrue((descriptor["parameters"] as? [[String: Any]] ?? []).contains { $0["name"] as? String == "reference_plane" })
    }

    func testMissingSuppressedAndForwardTargetCannotReuseMemoOrCachedPlane() async throws {
        let document = try await document(); defer { document.close() }
        let source = box(document, x: 0, height: 10), target = box(document, x: 60, height: 20)
        let edit = try linkedReplace(document, source: source, target: target)
        let original = document.session.document
        var cache = EvalCache()
        XCTAssertTrue(rebuilt(original, cache: &cache).errors.isEmpty)
        for mode in 0..<3 {
            var invalid = original
            switch mode {
            case 0: invalid.features.nodes.removeAll { $0.id == target.id }
            case 1:
                let index = try XCTUnwrap(invalid.features.nodes.firstIndex { $0.id == target.id })
                invalid.features.nodes[index].suppressed = true
            default:
                invalid.features.nodes.removeAll { $0.id == edit.id }
                let index = try XCTUnwrap(invalid.features.nodes.firstIndex { $0.id == target.id })
                invalid.features.nodes.insert(edit, at: index)
            }
            let result = rebuilt(invalid, cache: &cache)
            XCTAssertNotNil(result.errors[edit.id], "\(mode): \(result.errors)")
            XCTAssertNotNil(result.referenceErrors[.feature(edit.id)])
            let untouched = try XCTUnwrap(result.bodies.first { $0.id == source.outputBodyIDs.first })
            XCTAssertEqual(try volume(untouched), 8_000, accuracy: 1e-3,
                "A failed target cannot splice in the old16,000mm3 replacement")
        }
        XCTAssertEqual(try volume(body(document, source)), 16_000, accuracy: 1e-3)
    }

    func testTargetDependencyPreventsDeleteAndReorderWithoutRetargetingLaterWriters() async throws {
        let document = try await document(); defer { document.close() }
        let source = box(document, x: 0, height: 10), target = box(document, x: 60, height: 20)
        let edit = try linkedReplace(document, source: source, target: target)
        let service = CADParameterService(document: document)
        let beforeChange = document.session.changeCount
        let beforeUndo = document.session.undoStack.undoCommands.count
        let refused = service.handle(action: "feature.delete", args: ["feature_id": target.id.raw.uuidString])
        XCTAssertEqual(refused["error"] as? String, "has_dependents", "\(refused)")
        XCTAssertEqual(refused["dependent_feature_ids"] as? [String], [edit.id.raw.uuidString])
        let reordered = service.handle(action: "feature.move", args: ["feature_id": edit.id.raw.uuidString, "to_index": 1])
        XCTAssertEqual(reordered["error"] as? String, "dependency_order", "\(reordered)")
        let forced = service.handle(action: "feature.delete", args: ["feature_id": target.id.raw.uuidString, "force": true])
        XCTAssertEqual(forced["ok"] as? Bool, false, "\(forced)")
        XCTAssertNotNil(document.session.document.features.node(target.id))
        XCTAssertEqual(document.session.changeCount, beforeChange)
        XCTAssertEqual(document.session.undoStack.undoCommands.count, beforeUndo)
        XCTAssertEqual(try volume(body(document, source)), 16_000, accuracy: 1e-3)

        // A later transform must not replace the captured target writer in
        // either the evaluator or the history operations' dependency graph.
        try run(document, "feature.transform", ["bodyID": try body(document, target).id.raw.uuidString,
            "translation": [0, 7, 0]])
        let later = try XCTUnwrap(document.session.document.features.nodes.last)
        let dependencies = CADParameterService.bodyWriterDependencies(in: document.session.document.features.nodes)
        XCTAssertTrue(dependencies[edit.id]?.contains(target.id) == true)
        XCTAssertFalse(dependencies[edit.id]?.contains(later.id) == true)
        let descriptor = CADParameterService.describe(edit, document: document.session.document)
        let values = try XCTUnwrap(descriptor["dependencies"] as? [String: Any])
        XCTAssertTrue((values["body_ids"] as? [String] ?? []).contains(try body(document, target).id.raw.uuidString))
        XCTAssertTrue(descriptor["update_supported"] as? Bool == true)
        XCTAssertEqual(try volume(body(document, source)), 16_000, accuracy: 1e-3)
    }

    func testDraftTracksNeutralFaceAndAngleUpdatesKeepItsReference() async throws {
        let document = try await document(); defer { document.close() }
        let source = box(document, x: 0, height: 20), target = box(document, x: 60, height: 5)
        let a = try body(document, source), b = try body(document, target)
        let wall = try XCTUnwrap(OCCTKernel.faceInfo(try XCTUnwrap(a.brep)).first { $0.normal.x > 0.99 })
        try run(document, "feature.draftFace", ["bodyID": a.id.raw.uuidString, "face": wall.index,
            "angleDegrees": 5, "referencePlane": ["bodyID": b.id.raw.uuidString, "face": top(b)]])
        let edit = try XCTUnwrap(document.session.document.features.nodes.last)
        let reference = try XCTUnwrap(edit.kind.operationPlaneReference)
        func xAtNeutral(_ y: Double) throws -> Double {
            let solid = try XCTUnwrap(try body(document, source).brep)
            let face = try XCTUnwrap(OCCTKernel.faceInfo(solid).first {
                $0.normal.x > 0.8 && abs($0.normal.y) > 0.001 && abs($0.normal.z) < 1e-6 })
            return face.centroid.x - face.normal.y / face.normal.x * (y - face.centroid.y)
        }
        XCTAssertEqual(try xAtNeutral(5), 40, accuracy: 1e-4)
        let firstVolume = try volume(body(document, source))
        try height(document, target, 8)
        XCTAssertEqual(try xAtNeutral(8), 40, accuracy: 1e-4)
        XCTAssertGreaterThan(abs(try volume(body(document, source)) - firstVolume), 1)
        let changed = CADParameterService(document: document).handle(action: "update", args: [
            "feature_id": edit.id.raw.uuidString, "changes": ["angle": 7]])
        XCTAssertEqual(changed["ok"] as? Bool, true, "\(changed)")
        let updated = try XCTUnwrap(document.session.document.features.node(edit.id))
        XCTAssertEqual(updated.kind.operationPlaneReference, reference)
        XCTAssertEqual(try xAtNeutral(8), 40, accuracy: 1e-4)
        let withFormula = try XCTUnwrap(DocumentSession.reevaluatedKind(updated.kind, with: [:]))
        XCTAssertEqual(withFormula.operationPlaneReference, reference)
    }

    func testDatumPlaneAndTransformedTargetUseWorldFrameOnce() async throws {
        let document = try await document(); defer { document.close() }
        let source = box(document, x: 0, height: 10), target = box(document, x: 60, height: 20)
        let a = try body(document, source), b = try body(document, target)
        var placement = Transform3D.identity; placement.translation = SIMD3(0, 3, 0); placement.scale = 1.5
        let transform = FeatureNode(name: "Target placement", kind: .transform(
            body: BodyRef(producer: target.id, bodyID: b.id), delta: placement), outputBodyIDs: [b.id])
        document.session.recordAndRebuild([transform], title: "Target placement")
        let moved = try body(document, target)
        try run(document, "feature.replaceFace", ["bodyID": a.id.raw.uuidString, "face": top(a),
            "referencePlane": ["bodyID": moved.id.raw.uuidString, "face": top(moved)]])
        XCTAssertEqual(try volume(body(document, source)), 800 * 33, accuracy: 1e-3)
        let edit = try XCTUnwrap(document.session.document.features.nodes.last)
        XCTAssertEqual(edit.kind.operationPlaneReference?.writerVersion?.writer, transform.id)
        var shifted = placement; shifted.translation.y = 6
        document.session.rebuildFrom(transform.id, edit: EditFeatureCommand(featureID: transform.id,
            before: transform.kind,
            after: .transform(body: BodyRef(producer: target.id, bodyID: b.id), delta: shifted)))
        XCTAssertTrue(document.session.lastEvalErrors.isEmpty, "\(document.session.lastEvalErrors)")
        XCTAssertEqual(try volume(body(document, source)), 800 * 36, accuracy: 1e-3)
        XCTAssertEqual(document.session.document.features.node(edit.id)?.kind.operationPlaneReference,
            edit.kind.operationPlaneReference)
        document.session.undo()
        XCTAssertEqual(try volume(body(document, source)), 800 * 33, accuracy: 1e-3)
        document.session.redo()
        XCTAssertEqual(try volume(body(document, source)), 800 * 36, accuracy: 1e-3)
        document.session.undo()

        // A separate explicit datum is a stable record identity too; a new
        // operation must consume that record instead of baking its position.
        document.session.undo()
        let plane = ConstructionPlane(plane: .readable(origin: SIMD3(0, 18, 0), normal: SIMD3(0, 1, 0)), size: 100)
        document.session.perform(AddConstructionPlaneCommand(plane: plane))
        try run(document, "feature.replaceFace", ["bodyID": a.id.raw.uuidString, "face": top(try body(document, source)),
            "referencePlane": ["planeID": plane.id.raw.uuidString]])
        XCTAssertEqual(try volume(body(document, source)), 14_400, accuracy: 1e-3)
        let latest = try XCTUnwrap(document.session.document.features.nodes.last)
        XCTAssertEqual(latest.referencedConstructionPlaneIDs, [plane.id])
        var cache = EvalCache()
        XCTAssertTrue(rebuilt(document.session.document, cache: &cache).errors.isEmpty)
        var movedDatum = document.session.document
        let datumIndex = try XCTUnwrap(movedDatum.planes.firstIndex { $0.id == plane.id })
        movedDatum.planes[datumIndex].plane = .readable(origin: SIMD3(0, 24, 0), normal: SIMD3(0, 1, 0))
        let rebuiltDatum = rebuilt(movedDatum, cache: &cache)
        XCTAssertTrue(rebuiltDatum.errors.isEmpty, "\(rebuiltDatum.errors)")
        let editedBody = try XCTUnwrap(rebuiltDatum.bodies.first { $0.id == source.outputBodyIDs.first })
        XCTAssertEqual(try volume(editedBody), 19_200, accuracy: 1e-3)
    }

    func testActualReplacePickerCreatesLinkedHistoryAndRejectsChangedSelectionEpoch() async throws {
        let document = try await document(); defer { document.close() }
        let source = box(document, x: 0, height: 10), target = box(document, x: 60, height: 20)
        let model = document.viewModel(), undo = document.session.undoStack.undoCommands.count
        model.beginReplaceFace()
        model.handle(.tap(ray: Ray(origin: SIMD3(20, 100, -10), direction: SIMD3(0, -1, 0))))
        XCTAssertEqual(model.replaceFaceStage, 2)
        model.handle(.tap(ray: Ray(origin: SIMD3(80, 100, -10), direction: SIMD3(0, -1, 0))))
        XCTAssertTrue(model.canCommitReplaceFace, model.replaceFaceRefusal ?? "")
        model.commitReplaceFace()
        XCTAssertEqual(document.session.undoStack.undoCommands.count, undo + 1)
        XCTAssertEqual(try volume(body(document, source)), 16_000, accuracy: 1e-3)
        let edit = try XCTUnwrap(document.session.document.features.nodes.last)
        XCTAssertEqual(edit.kind.operationPlaneReference?.writerVersion?.writer, target.id)
        document.session.undo()
        XCTAssertEqual(try volume(body(document, source)), 8_000, accuracy: 1e-3)
        model.beginReplaceFace()
        model.handle(.tap(ray: Ray(origin: SIMD3(20, 100, -10), direction: SIMD3(0, -1, 0))))
        document.session.perform(AddSketchCommand(sketch: Sketch(name: "Concurrent edit", plane: .ground)))
        model.handle(.tap(ray: Ray(origin: SIMD3(80, 100, -10), direction: SIMD3(0, -1, 0))))
        XCTAssertEqual(document.session.document.features.nodes.count, 2)
        XCTAssertFalse(model.canCommitReplaceFace)
        XCTAssertEqual(try volume(body(document, source)), 8_000, accuracy: 1e-3)
    }

    func testImportedSameBodyDraftCapturesOneSourceAndUndoKeepsOriginalBytes() async throws {
        let document = try await document(); defer { document.close() }
        let native = try XCTUnwrap(OCCTKernel.primitiveShape(.box(width: 40, depth: 20, height: 10), placement: .identity))
        var original = Body(id: BodyID(), name: "Imported", transform: .identity, primitive: nil,
            render: RenderMesh(positions: [], normals: [], indices: []), revision: 0)
        XCTAssertTrue(original.adoptBRep(native))
        document.session.perform(AddBodyCommand(body: original))
        let bytes = try XCTUnwrap(OCCTKernel.serialize(native))
        let faces = OCCTKernel.faceInfo(native)
        let wall = try XCTUnwrap(faces.first { $0.normal.x > 0.99 })
        let bottom = try XCTUnwrap(faces.first { $0.normal.y < -0.99 })
        let undo = document.session.undoStack.undoCommands.count
        try run(document, "feature.draftFace", ["bodyID": original.id.raw.uuidString, "face": wall.index,
            "angleDegrees": 4, "referencePlane": ["bodyID": original.id.raw.uuidString, "face": bottom.index]])
        let nodes = document.session.document.features.nodes
        XCTAssertEqual(nodes.count, 2)
        XCTAssertEqual(document.session.undoStack.undoCommands.count, undo + 1)
        guard case let .baseSolid(snapshot) = nodes[0].kind,
              case let .draftFace(source, _, _, _, support) = nodes[1].kind else { return XCTFail("Expected one preserved source plus draft") }
        XCTAssertEqual(source.body.producer, nodes[0].id)
        XCTAssertEqual(support?.writerVersion?.writer, nodes[0].id)
        if case let .face(reference)? = support?.source {
            XCTAssertEqual(reference.source.body.producer, nodes[0].id)
        } else { XCTFail("Missing actual same-body reference") }
        let captured = try snapshot.restoredBody(id: original.id, revision: 1)
        XCTAssertEqual(OCCTKernel.serialize(try XCTUnwrap(captured.brep)), bytes)
        document.session.undo()
        XCTAssertTrue(document.session.document.features.nodes.isEmpty)
        let restored = try XCTUnwrap(document.session.document.body(with: original.id))
        XCTAssertEqual(OCCTKernel.serialize(try XCTUnwrap(restored.brep)), bytes)
        document.session.redo()
        XCTAssertEqual(document.session.document.features.nodes.map(\.id), nodes.map(\.id))
    }

    func testLegacyPlaneRemainsAbsoluteAndFutureReferenceIsOpaque() async throws {
        let document = try await document(); defer { document.close() }
        let source = box(document, x: 0, height: 10), target = box(document, x: 60, height: 20)
        let edit = try linkedReplace(document, source: source, target: target)
        guard case let .replaceFace(face, origin, normal, flip, _) = edit.kind else { return XCTFail("Expected replace") }
        let legacy = FeatureKind.replaceFace(face: face, targetOrigin: origin, targetNormal: normal, flip: flip)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let oldData = try encoder.encode(legacy)
        XCTAssertFalse(String(decoding: oldData, as: UTF8.self).contains("planeReference"))
        XCTAssertNil(try JSONDecoder().decode(FeatureKind.self, from: oldData).operationPlaneReference)
        let data = try encoder.encode(edit.kind)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        var payload = try XCTUnwrap(object["replaceFace"] as? [String: Any])
        var reference = try XCTUnwrap(payload["planeReference"] as? [String: Any])
        reference["version"] = 2; payload["planeReference"] = reference; object["replaceFace"] = payload
        let future = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        let row = CADFeatureRecord(featureID: edit.id.raw, orderIndex: 2, name: "Replace", suppressed: false,
            kind: future, outputBodyIDs: try encoder.encode(edit.outputBodyIDs.map(\.raw)))
        let assessment = try CADDocumentFormat.assess(planes: [], sketches: [], features: [row])
        XCTAssertEqual(assessment.requiredVersion, CADDocumentFormat.operationPlaneReferenceVersion)
        XCTAssertTrue(assessment.opaqueFeatures.contains(edit.id.raw))
        XCTAssertEqual(row.kind, future)
        reference["version"] = 1
        reference["source"] = ["futureSurface": [:]]
        payload["planeReference"] = reference; object["replaceFace"] = payload
        var unknownRow = row
        unknownRow.kind = try JSONSerialization.data(withJSONObject: object)
        XCTAssertTrue(try CADDocumentFormat.assess(planes: [], sketches: [], features: [unknownRow])
            .opaqueFeatures.contains(edit.id.raw))
        reference["version"] = true
        payload["planeReference"] = reference; object["replaceFace"] = payload
        unknownRow.kind = try JSONSerialization.data(withJSONObject: object)
        XCTAssertThrowsError(try CADDocumentFormat.assess(planes: [], sketches: [], features: [unknownRow])) {
            XCTAssertEqual($0 as? CADDocumentFormatError, .malformedAssociation("feature-plane"))
        }
        XCTAssertEqual(CADDocumentFormat.requiredFormat(document: document.session.document), 7)
        try height(document, target, 25)
        var copy = document.session.document
        let index = try XCTUnwrap(copy.features.nodes.firstIndex { $0.id == edit.id })
        copy.features.nodes[index].kind = legacy
        var cache = EvalCache(); let result = rebuilt(copy, cache: &cache)
        XCTAssertTrue(result.errors.isEmpty)
        XCTAssertEqual(try volume(XCTUnwrap(result.bodies.first { $0.id == source.outputBodyIDs.first })), 16_000, accuracy: 1e-3)
    }

    func testMergedPlaneReferencesRemapEveryIdentityAndTranslateOnlyOnce() async throws {
        let document = try await document(); defer { document.close() }
        let source = box(document, x: 0, height: 10), target = box(document, x: 60, height: 20)
        let edit = try linkedReplace(document, source: source, target: target)
        let insertion = try ProjectMergeKit.insert(document.session.document, into: DesignDocument(), translation: SIMD3(200, 30, -40))
        let mapped = try XCTUnwrap(insertion.document.features.nodes.last)
        XCTAssertNotEqual(mapped.id, edit.id)
        XCTAssertNotEqual(mapped.kind.operationPlaneReference?.writerVersion?.writer, target.id)
        XCTAssertNotEqual(mapped.kind.operationPlaneReference?.writerVersion?.bodyID, target.outputBodyIDs.first)
        var cache = EvalCache(); let result = rebuilt(insertion.document, cache: &cache)
        XCTAssertTrue(result.errors.isEmpty, "\(result.errors)")
        let output = try XCTUnwrap(result.bodies.first { $0.id == mapped.outputBodyIDs.first })
        XCTAssertEqual(try volume(output), 16_000, accuracy: 1e-3)
        let worldTop = OCCTKernel.faceInfo(try XCTUnwrap(output.brep)).filter { $0.normal.y > 0.99 }
            .map { output.transform.applying(to: $0.centroid).y }.max()
        XCTAssertEqual(try XCTUnwrap(worldTop), 50, accuracy: 1e-4)
    }

    func testTargetFaceRequiresItsOwnFreshQueryGenerationAndParserKeepsThatChoice() async throws {
        let document = try await document(); defer { document.close() }
        let source = box(document, x: 0, height: 10), target = box(document, x: 60, height: 20)
        let a = try body(document, source), b = try body(document, target)
        func token(_ id: BodyID) throws -> String {
            let query = document.nativeQueryJSON(["scope": "faces"])
            XCTAssertTrue(query.isOK)
            let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: query.payload) as? [String: Any])
            let row = try XCTUnwrap((payload["rows"] as? [[String: Any]])?.first { $0["bodyID"] as? String == id.raw.uuidString })
            return try XCTUnwrap(row["query_token"] as? String)
        }
        func input(_ targetToken: String?) throws -> String {
            var reference: [String: Any] = ["bodyID": b.id.raw.uuidString, "face": try top(body(document, target))]
            if let targetToken { reference["query_token"] = targetToken }
            let args: [String: Any] = ["bodyID": a.id.raw.uuidString, "face": try top(body(document, source)),
                "query_token": try token(a.id), "referencePlane": reference]
            if targetToken != nil {
                guard case let .success(.replaceFace(_, _, _, _, _, selection)) = AgentExec.parse(["op": "feature.replaceFace", "args": args]) else {
                    throw CADDocumentError(code: "parse", message: "The typed parser must accept current target proof fields")
                }
                XCTAssertEqual(selection, .face(b.id, try top(body(document, target))))
            }
            return String(decoding: try JSONSerialization.data(withJSONObject: ["op": "feature.replaceFace", "args": args]), as: UTF8.self)
        }
        let targetToken = try token(b.id)
        XCTAssertNoThrow(try CADStaleReferenceGuard.validate(operationJSON: input(targetToken), document: document))
        XCTAssertThrowsError(try CADStaleReferenceGuard.validate(operationJSON: input(nil), document: document)) {
            XCTAssertEqual(($0 as? CADDocumentError)?.code, "requery_required")
        }
        try height(document, target, 25)
        XCTAssertThrowsError(try CADStaleReferenceGuard.validate(operationJSON: input(targetToken), document: document)) {
            XCTAssertEqual(($0 as? CADDocumentError)?.code, "requery_required")
        }
        XCTAssertNoThrow(try CADStaleReferenceGuard.validate(operationJSON: input(token(b.id)), document: document))
        XCTAssertEqual(try volume(body(document, source)), 8_000, accuracy: 1e-3)
        XCTAssertEqual(document.session.document.features.nodes.count, 2)
    }
}
