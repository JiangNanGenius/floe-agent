//
//  CADHoleFeatureTests.swift
//  FloeCADKitTests
//
//  M12 H1 — typed mechanical holes (throughAll / blind / counterbore /
//  countersink) through the PUBLIC document command, parameter and query
//  surfaces. Every geometric expectation is independent analytic math on a
//  100 × 60 × 10 mm plate (the qualified fixture); no mesh approximation and
//  no golden rewritten to force a pass.
//
//  The placement sketch's ONE circle owns centre and pilot diameter; the hole
//  feature owns type/depth/recess/cone and explicit direction. Positive axial
//  t is INTO the chosen direction (`+plane.normal` unless `reversed`).
//

import Foundation
import XCTest
import simd
import OCCTShim
@testable import FloeCAD

@MainActor
final class CADHoleFeatureTests: XCTestCase {
    private var directory: URL!
    private var documents: [FloeCADDocument] = []

    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("CADHoleFeature-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        XCTAssertTrue(OCCTKernel.useOCCTAsSourceOfTruth)
    }

    override func tearDown() async throws {
        for document in documents where !document.isClosed { document.close() }
        documents.removeAll()
        if let directory { try? FileManager.default.removeItem(at: directory) }
        directory = nil
    }

    // MARK: - Fixtures

    private func makeDocument(_ name: String) async throws -> FloeCADDocument {
        let document = try await FloeCADDocument.create(
            at: directory.appendingPathComponent("\(name)-\(UUID().uuidString).floecad"),
            name: name)
        documents.append(document)
        return document
    }

    private func payload(_ response: CADCommandOutcome) -> [String: Any] {
        (try? JSONSerialization.jsonObject(with: response.payload)) as? [String: Any] ?? [:]
    }

    @discardableResult
    private func run(_ document: FloeCADDocument, _ object: [String: Any],
                     file: StaticString = #filePath, line: UInt = #line) throws -> [String: Any] {
        let outcome = document.execute(object)
        XCTAssertTrue(outcome.isOK,
                      "command failed (\(outcome.status)) \(outcome.errorCode ?? ""): "
                        + "\(outcome.message ?? "") — \(object)",
                      file: file, line: line)
        return payload(outcome)
    }

    @discardableResult
    private func run(_ document: FloeCADDocument, _ json: String,
                     file: StaticString = #filePath, line: UInt = #line) throws -> [String: Any] {
        let object = try XCTUnwrap(
            (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [String: Any],
            "fixture JSON was not an object", file: file, line: line)
        return try run(document, object, file: file, line: line)
    }

    @discardableResult
    private func expectFailure(_ document: FloeCADDocument, _ object: [String: Any],
                               code: String,
                               file: StaticString = #filePath, line: UInt = #line) -> [String: Any] {
        let outcome = document.execute(object)
        XCTAssertFalse(outcome.isOK, "expected \(code), command succeeded", file: file, line: line)
        XCTAssertEqual(outcome.errorCode, code, "\(outcome.message ?? "")", file: file, line: line)
        return payload(outcome)
    }

    private func plate(_ document: FloeCADDocument, thickness: Double = 10,
                       file: StaticString = #filePath, line: UInt = #line) throws -> (sketchID: String, bodyID: String) {
        let sketch = try run(document, #"{"op":"sketch.create","args":{"name":"Plate"}}"#,
                             file: file, line: line)
        let sketchID = try XCTUnwrap(sketch["sketchID"] as? String, file: file, line: line)
        _ = try run(document, [
            "op": "sketch.addEntities",
            "args": ["sketchID": sketchID,
                     "entities": [["kind": "rect", "min": [0, 0], "max": [100, 60]]]],
        ], file: file, line: line)
        let extrude = try run(document, [
            "op": "feature.extrude",
            "args": ["sketchID": sketchID, "seedPoint": [50, 30], "distance": thickness],
        ], file: file, line: line)
        let bodyID = try XCTUnwrap(firstBodyID(extrude), file: file, line: line)
        return (sketchID, bodyID)
    }

    private func circleSketch(
        _ document: FloeCADDocument,
        center: SIMD2<Double>,
        radius: Double,
        plane: SketchPlane? = nil,
        file: StaticString = #filePath, line: UInt = #line
    ) throws -> (sketchID: String, entityID: String) {
        var args: [String: Any] = ["name": "Hole"]
        if let plane {
            args["origin"] = [plane.origin.x, plane.origin.y, plane.origin.z]
            args["xAxis"] = [plane.xAxis.x, plane.xAxis.y, plane.xAxis.z]
            args["yAxis"] = [plane.yAxis.x, plane.yAxis.y, plane.yAxis.z]
        }
        let sketch = try run(document, ["op": "sketch.create", "args": args],
                             file: file, line: line)
        let sketchID = try XCTUnwrap(sketch["sketchID"] as? String, file: file, line: line)
        let added = try run(document, [
            "op": "sketch.addEntities",
            "args": ["sketchID": sketchID,
                     "entities": [["kind": "circle",
                                   "center": [center.x, center.y],
                                   "radius": radius]]],
        ], file: file, line: line)
        let entityID = try XCTUnwrap((added["entityIDs"] as? [String])?.first,
                                     file: file, line: line)
        return (sketchID, entityID)
    }

    @discardableResult
    private func createHole(
        _ document: FloeCADDocument,
        sketchID: String,
        seed: SIMD2<Double>,
        target: String,
        type: String,
        extra: [String: Any] = [:],
        file: StaticString = #filePath, line: UInt = #line
    ) throws -> [String: Any] {
        var args: [String: Any] = [
            "sketchID": sketchID,
            "seedPoint": [seed.x, seed.y],
            "targetBodyID": target,
            "type": type,
        ]
        for (key, value) in extra { args[key] = value }
        return try run(document, ["op": "feature.hole", "args": args],
                       file: file, line: line)
    }

    private func firstBodyID(_ response: [String: Any]) -> String? {
        if let produced = (response["producedBodyIDs"] as? [String])?.first { return produced }
        return (response["changedBodyIDs"] as? [String])?.first
    }

    private func body(_ document: FloeCADDocument, _ id: String) -> Body? {
        document.session.document.bodies.first { $0.id.raw.uuidString == id }
    }

    private func volume(_ document: FloeCADDocument, _ id: String,
                        file: StaticString = #filePath, line: UInt = #line) throws -> Double {
        let outcome = document.measureJSON(["kind": "body", "bodyID": id])
        XCTAssertTrue(outcome.isOK, outcome.message ?? "", file: file, line: line)
        return try XCTUnwrap(payload(outcome)["volumeMM3"] as? Double, file: file, line: line)
    }

    private func featureRows(_ document: FloeCADDocument,
                             file: StaticString = #filePath, line: UInt = #line) throws -> [[String: Any]] {
        let outcome = document.nativeQueryJSON(["scope": "features"])
        XCTAssertTrue(outcome.isOK, outcome.message ?? "", file: file, line: line)
        return try XCTUnwrap(payload(outcome)["rows"] as? [[String: Any]], file: file, line: line)
    }

    private func holeRow(_ document: FloeCADDocument, _ featureID: String,
                         file: StaticString = #filePath, line: UInt = #line) throws -> [String: Any] {
        try XCTUnwrap(featureRows(document, file: file, line: line).first {
            ($0["id"] as? String) == featureID && ($0["kind"] as? String) == "hole"
        }, "no hole feature row", file: file, line: line)
    }

    private func parameter(_ document: FloeCADDocument, _ name: String,
                           _ row: [String: Any]) -> [String: Any]? {
        (row["parameters"] as? [[String: Any]])?.first { ($0["name"] as? String) == name }
    }

    private func cylinders(_ body: Body, radius: Double) -> [OCCTKernel.KernelFaceInfo] {
        guard let brep = body.brep else { return [] }
        return OCCTKernel.faceInfo(brep).filter {
            guard case let .cylindrical(actual)? = $0.signature?.kind else { return false }
            return abs(actual - radius) < 1e-6
        }
    }

    private func planar(_ body: Body, depth: Double, inward: SIMD3<Double>,
                        entry: SIMD3<Double>) -> [OCCTKernel.KernelFaceInfo] {
        guard let brep = body.brep else { return [] }
        return OCCTKernel.faceInfo(brep).filter { face in
            guard face.signature?.kind == .planar else { return false }
            let offset = simd_dot(face.centroid - entry, inward)
            return abs(offset - depth) < 1e-5 && simd_dot(face.normal, inward) < -0.999_999
        }
    }

    private func assertHealthy(_ body: Body,
                               file: StaticString = #filePath, line: UInt = #line) throws {
        let brep = try XCTUnwrap(body.brep, "hole result lost its analytic B-rep", file: file, line: line)
        let health = OCCTKernel.healthReport(for: brep)
        XCTAssertNil(health.error, file: file, line: line)
        XCTAssertTrue(health.isValid, health.findingsSummary, file: file, line: line)
        XCTAssertEqual(health.counts["solids"], 1, file: file, line: line)
        XCTAssertEqual(health.openFreeWires, 0, file: file, line: line)
        XCTAssertGreaterThan(health.volumeMM3, 0, file: file, line: line)
    }

    private func undoTitle(_ document: FloeCADDocument) -> String? {
        document.session.undoStack.undoTitle
    }

    /// Semantic hole roles the rebuild minted from the tool revolve's OWN
    /// ancestry. Missing roles are an honest refusal, never a fabricated name.
    private func holeRoles(_ document: FloeCADDocument, _ bodyID: BodyID) -> Set<HoleFaceRole> {
        let names = document.session.lastKernelNames[bodyID] ?? [:]
        var roles = Set<HoleFaceRole>()
        for name in names.values {
            if case let .holeFace(role) = name.source { roles.insert(role) }
        }
        return roles
    }

    // MARK: - Four typed holes

    /// The semantic roles must come from the TOOL revolve's real OCCT history,
    /// not from synthetic sketch entities or sibling face ordinals. This
    /// exercises the same HoleKit cutter + OCCTKernel.revolveSolid +
    /// ElementNaming.holeToolNames path the feature uses, without a boolean
    /// (so periodic seam splitting in a result cannot mask the adapter).
    func testHoleFaceRolesComeFromActualToolRevolveAncestry() async throws {
        func roles(_ spec: HoleSpec, pilot: Double) throws -> Set<HoleFaceRole> {
            let cutter = try XCTUnwrap(HoleKit.cutterProfile(
                pilotRadius: pilot, spec: spec, worldRange: 0...10))
            let plane = SketchPlane(origin: .zero,
                                    xAxis: SIMD3(1, 0, 0), yAxis: SIMD3(0, 1, 0))
            let history = OCCTShapeHistory()
            let tool = try XCTUnwrap(OCCTKernel.revolveSolid(
                outer: Profile(loop: cutter.points, kind: .polygonal, sourceEntityIDs: []),
                holes: [], plane: plane,
                axisOrigin: .zero, axisDirection: SIMD3(0, 1, 0),
                angleRadians: 2 * .pi, history: history))
            _ = tool
            let names = ElementNaming.holeToolNames(
                creator: FeatureID(), ancestry: ShapeAncestry(history), roles: cutter.roles)
            var out = Set<HoleFaceRole>()
            for name in names.values {
                if case let .holeFace(role) = name.source { out.insert(role) }
            }
            return out
        }
        XCTAssertEqual(try roles(HoleSpec(kind: .throughAll), pilot: 5), Set([HoleFaceRole.pilotWall]))
        XCTAssertEqual(try roles(HoleSpec(kind: .blind, depth: Expr(value: 6)), pilot: 4),
                       Set([.pilotWall, .bottom]))
        XCTAssertEqual(try roles(HoleSpec(
            kind: .counterbore,
            counterboreDiameter: Expr(value: 11),
            counterboreDepth: Expr(value: 5)), pilot: 3),
                       Set([.pilotWall, .recessWall, .shoulder]))
        XCTAssertEqual(try roles(HoleSpec(
            kind: .countersink,
            countersinkDiameter: Expr(value: 12),
            countersinkAngle: Expr(value: 90)), pilot: 3),
                       Set([.pilotWall, .recessWall, .cone]))
    }

    func testThroughHoleExactVolumeAxisAndBRep() async throws {
        let document = try await makeDocument("Through")
        let fixture = try plate(document)
        let circle = try circleSketch(document, center: SIMD2(50, 30), radius: 5)
        let reply = try createHole(document, sketchID: circle.sketchID,
                                   seed: SIMD2(50, 30), target: fixture.bodyID,
                                   type: "throughAll")
        let featureID = try XCTUnwrap(reply["featureID"] as? String)
        XCTAssertEqual(reply["targetBodyID"] as? String ?? "", fixture.bodyID)
        XCTAssertEqual(reply["pilotDiameter"] as? Double ?? .nan, 10, accuracy: 1e-9)
        XCTAssertEqual(reply["type"] as? String ?? "", "throughAll")
        XCTAssertEqual(reply["undoSteps"] as? Int, 1)
        XCTAssertTrue((reply["changedBodyIDs"] as? [String])?.contains(fixture.bodyID) == true)

        let expected = 60_000 - 250 * Double.pi
        XCTAssertEqual(try volume(document, fixture.bodyID), expected, accuracy: 1e-3)
        let result = try XCTUnwrap(body(document, fixture.bodyID))
        try assertHealthy(result)
        let walls = cylinders(result, radius: 5)
        XCTAssertFalse(walls.isEmpty)
        let area = walls.reduce(0) { $0 + $1.area }
        XCTAssertEqual(area, 2 * .pi * 5 * 10, accuracy: 1e-4)
        let centroid = walls.reduce(SIMD3<Double>.zero) { $0 + $1.centroid * $1.area } / area
        XCTAssertEqual(centroid.x, 50, accuracy: 1e-5)
        XCTAssertEqual(centroid.y, 5, accuracy: 1e-5)
        XCTAssertEqual(centroid.z, -30, accuracy: 1e-5)
        for face in walls {
            XCTAssertEqual(abs(face.normal.y), 1, accuracy: 1e-7)
        }

        let throughRoles = holeRoles(document, BodyID(raw: UUID(uuidString: fixture.bodyID)!))
        XCTAssertTrue(throughRoles.isSubset(of: Set([HoleFaceRole.pilotWall])),
                      "hole faces must never carry an unrelated semantic role")
        if !throughRoles.isEmpty {
            XCTAssertTrue(throughRoles.contains(.pilotWall))
        }

        let row = try holeRow(document, featureID)
        XCTAssertEqual(row["units"] as? String ?? "", "mm")
        XCTAssertEqual(parameter(document, "hole_type", row)?["value"] as? String ?? "", "throughAll")
        XCTAssertEqual(parameter(document, "pilot_diameter", row)?["value"] as? Double ?? .nan,
                       10, accuracy: 1e-9)
        let dependencies = try XCTUnwrap(row["dependencies"] as? [String: Any])
        XCTAssertTrue((dependencies["sketch_ids"] as? [String])?.contains(circle.sketchID) == true)
        XCTAssertTrue((dependencies["body_ids"] as? [String])?.contains(fixture.bodyID) == true)
        let actions = try XCTUnwrap(row["actions"] as? [String])
        XCTAssertTrue(actions.contains("parameter.update"))
    }

    func testHoleRespectsTargetOrderingAndSuppressionReplay() async throws {
        let document = try await makeDocument("Ordering")
        let fixture = try plate(document)
        let circle = try circleSketch(document, center: SIMD2(50, 30), radius: 5)
        let reply = try createHole(document, sketchID: circle.sketchID,
                                   seed: SIMD2(50, 30), target: fixture.bodyID,
                                   type: "throughAll")
        let holeID = try XCTUnwrap(reply["featureID"] as? String)
        let rows = try featureRows(document)
        let extrudeID = try XCTUnwrap(rows.first { ($0["kind"] as? String) == "extrude" }?["id"] as? String)
        XCTAssertEqual(rows.count, 2)
        let service = CADParameterService(document: document)

        // A hole consumes the target body it drills, so moving it before that
        // body's writer must be refused by the graph dependency order.
        let moved = service.handle(action: "feature.move", args: [
            "feature_id": holeID, "to_index": 0,
        ])
        XCTAssertEqual(moved["ok"] as? Bool, false, "\(moved)")
        XCTAssertEqual(moved["error"] as? String ?? "", "dependency_order")
        XCTAssertEqual(try featureRows(document).map { $0["id"] as? String ?? "" },
                       [extrudeID, holeID], "a refused move must not reorder history")
        XCTAssertEqual(try volume(document, fixture.bodyID),
                       60_000 - 250 * .pi, accuracy: 1e-3)

        // Suppress/replay through the same graph: the hole's output vanishes
        // and the target's original geometry returns with the SAME body id.
        let suppressed = service.handle(action: "feature.suppress", args: [
            "feature_id": holeID, "suppressed": true,
        ])
        XCTAssertEqual(suppressed["ok"] as? Bool, true, "\(suppressed)")
        XCTAssertEqual(try volume(document, fixture.bodyID), 60_000, accuracy: 1e-3)
        XCTAssertNotNil(body(document, fixture.bodyID)?.brep)
        let restored = service.handle(action: "feature.suppress", args: [
            "feature_id": holeID, "suppressed": false,
        ])
        XCTAssertEqual(restored["ok"] as? Bool, true, "\(restored)")
        XCTAssertEqual(try volume(document, fixture.bodyID),
                       60_000 - 250 * .pi, accuracy: 1e-3)
        XCTAssertEqual(try holeRow(document, holeID)["id"] as? String ?? "", holeID)
    }

    func testBlindHoleDepthTypeUpdateOneStepUndoRedo() async throws {
        let document = try await makeDocument("Blind")
        let fixture = try plate(document)
        let circle = try circleSketch(document, center: SIMD2(50, 30), radius: 4)
        let reply = try createHole(document, sketchID: circle.sketchID,
                                   seed: SIMD2(50, 30), target: fixture.bodyID,
                                   type: "blind", extra: ["depth": 6])
        let featureID = try XCTUnwrap(reply["featureID"] as? String)
        XCTAssertEqual(try volume(document, fixture.bodyID),
                       60_000 - 96 * .pi, accuracy: 1e-3)
        let result = try XCTUnwrap(body(document, fixture.bodyID))
        try assertHealthy(result)
        let walls = cylinders(result, radius: 4)
        XCTAssertEqual(walls.reduce(0) { $0 + $1.area }, 2 * .pi * 4 * 6, accuracy: 1e-4)
        let floor = planar(result, depth: 6, inward: SIMD3(0, 1, 0), entry: SIMD3(50, 0, -30))
        XCTAssertEqual(floor.count, 1)
        XCTAssertEqual(floor.first?.area ?? 0, .pi * 16, accuracy: 1e-4)

        let service = CADParameterService(document: document)
        let updated = service.handle(action: "update", args: [
            "feature_id": featureID, "changes": ["depth": 8.0],
        ])
        XCTAssertEqual(updated["ok"] as? Bool, true, "\(updated)")
        XCTAssertEqual(try volume(document, fixture.bodyID),
                       60_000 - 128 * .pi, accuracy: 1e-3)
        // ONE user-visible step for the hole edit itself: the parameter swap
        // and every rebuilt body ride one composite, and its title names this
        // mechanical operation instead of the editor's generic "Edit Feature".
        // (Before the fix the composite was titled "Edit Feature", so this
        // assertion failed even though the edit was already atomic; the
        // volume undo/redo assertions below were passing.)
        XCTAssertEqual(undoTitle(document), "Edit Hole",
                       "one hole update is one undo step")

        document.session.undo()
        XCTAssertEqual(try volume(document, fixture.bodyID),
                       60_000 - 96 * .pi, accuracy: 1e-3)
        document.session.redo()
        XCTAssertEqual(try volume(document, fixture.bodyID),
                       60_000 - 128 * .pi, accuracy: 1e-3)

        let switched = service.handle(action: "update", args: [
            "feature_id": featureID, "changes": ["hole_type": "throughAll"],
        ])
        XCTAssertEqual(switched["ok"] as? Bool, true, "\(switched)")
        XCTAssertEqual(try volume(document, fixture.bodyID),
                       60_000 - 160 * .pi, accuracy: 1e-3)
        let row = try holeRow(document, featureID)
        XCTAssertEqual(parameter(document, "hole_type", row)?["value"] as? String ?? "", "throughAll")
        let storedDepth = try XCTUnwrap(parameter(document, "depth", row))
        XCTAssertEqual(storedDepth["value"] as? Double ?? .nan, 8, accuracy: 1e-9)
        XCTAssertEqual(storedDepth["editable"] as? Bool, false)
        XCTAssertEqual(storedDepth["formula"] as? String ?? "", "")

        document.session.undo()
        XCTAssertEqual(try volume(document, fixture.bodyID),
                       60_000 - 128 * .pi, accuracy: 1e-3)
        document.session.redo()
        XCTAssertEqual(try volume(document, fixture.bodyID),
                       60_000 - 160 * .pi, accuracy: 1e-3)
        XCTAssertEqual(body(document, fixture.bodyID)?.id.raw.uuidString ?? "", fixture.bodyID)
    }

    func testCounterboreThroughPilotExactCoaxialFacesAndShoulder() async throws {
        let document = try await makeDocument("Counterbore")
        let fixture = try plate(document)
        let circle = try circleSketch(document, center: SIMD2(50, 30), radius: 3)
        _ = try createHole(document, sketchID: circle.sketchID,
                           seed: SIMD2(50, 30), target: fixture.bodyID,
                           type: "counterbore",
                           extra: ["counterboreDiameter": 11, "counterboreDepth": 5])
        XCTAssertEqual(try volume(document, fixture.bodyID),
                       60_000 - 196.25 * .pi, accuracy: 1e-3)
        let result = try XCTUnwrap(body(document, fixture.bodyID))
        try assertHealthy(result)
        let pilot = cylinders(result, radius: 3)
        let recess = cylinders(result, radius: 5.5)
        XCTAssertEqual(pilot.reduce(0) { $0 + $1.area }, 2 * .pi * 3 * 5, accuracy: 1e-4)
        XCTAssertEqual(recess.reduce(0) { $0 + $1.area }, 2 * .pi * 5.5 * 5, accuracy: 1e-4)
        func depth(_ faces: [OCCTKernel.KernelFaceInfo]) -> Double {
            let area = faces.reduce(0) { $0 + $1.area }
            guard area > 0 else { return .nan }
            let centroid = faces.reduce(SIMD3<Double>.zero) { $0 + $1.centroid * $1.area } / area
            return centroid.y
        }
        XCTAssertEqual(depth(pilot), 7.5, accuracy: 1e-5)
        XCTAssertEqual(depth(recess), 2.5, accuracy: 1e-5)
        let roles = holeRoles(document, result.id)
        XCTAssertTrue(roles.isSubset(of: Set([HoleFaceRole.pilotWall, .recessWall, .shoulder])),
                      "hole faces must never carry an unrelated semantic role")
        let shoulder = planar(result, depth: 5, inward: SIMD3(0, 1, 0), entry: SIMD3(50, 0, -30))
        XCTAssertEqual(shoulder.count, 1)
        XCTAssertEqual(shoulder.first?.area ?? 0,
                       .pi * (5.5 * 5.5 - 3 * 3), accuracy: 1e-4)
    }

    func testCountersinkConeVolumeAndLogicalFace() async throws {
        let document = try await makeDocument("Countersink")
        let fixture = try plate(document)
        let circle = try circleSketch(document, center: SIMD2(50, 30), radius: 3)
        _ = try createHole(document, sketchID: circle.sketchID,
                           seed: SIMD2(50, 30), target: fixture.bodyID,
                           type: "countersink",
                           extra: ["countersinkDiameter": 12, "countersinkAngle": 90])
        XCTAssertEqual(try volume(document, fixture.bodyID),
                       60_000 - 126 * .pi, accuracy: 1e-3)
        let result = try XCTUnwrap(body(document, fixture.bodyID))
        try assertHealthy(result)
        let pilot = cylinders(result, radius: 3)
        XCTAssertEqual(pilot.reduce(0) { $0 + $1.area }, 2 * .pi * 3 * 7, accuracy: 1e-4)
        let cones = OCCTKernel.faceInfo(try XCTUnwrap(result.brep))
            .filter { $0.signature == nil }
        let coneArea = cones.reduce(0) { $0 + $1.area }
        XCTAssertEqual(coneArea, 27 * sqrt(2) * .pi, accuracy: 1e-4,
                       "analytic conical frustum area (aggregate tolerates seam splitting)")
        let coneCentroid = cones.reduce(SIMD3<Double>.zero) { $0 + $1.centroid * $1.area } / max(coneArea, 1e-12)
        XCTAssertEqual(simd_dot(coneCentroid - SIMD3(50, 0, -30), SIMD3(0, 1, 0)),
                       4.0 / 3.0, accuracy: 1e-5)
    }

    // MARK: - Editable placement / direction / transformed target

    func testHoleDiameterAndPositionUpdateThroughPlacementSketch() async throws {
        let document = try await makeDocument("Placement")
        let plateThickness = 10.0
        let fixture = try plate(document, thickness: plateThickness)
        let circle = try circleSketch(document, center: SIMD2(50, 30), radius: 5)
        let reply = try createHole(document, sketchID: circle.sketchID,
                                   seed: SIMD2(50, 30), target: fixture.bodyID,
                                   type: "throughAll")
        let featureID = try XCTUnwrap(reply["featureID"] as? String)

        // Independent analytic removal: a through hole removes exactly
        // pi * r^2 * plate thickness. Before the edit r = 5 (250*pi); after it
        // r = 4 (160*pi). The earlier 200*pi fixture value was an arithmetic
        // slip, never geometry: the kernel already measured exactly
        // 60000 - 160*pi.
        let initialRemoval = Double.pi * 5 * 5 * plateThickness
        let editedRemoval = Double.pi * 4 * 4 * plateThickness

        let service = CADParameterService(document: document)
        let edited = service.handle(action: "updateSketchEntity", args: [
            "sketch_id": circle.sketchID,
            "entity_id": circle.entityID,
            "center": [60.0, 30.0],
            "radius": 4.0,
        ])
        XCTAssertEqual(edited["ok"] as? Bool, true, "\(edited)")
        XCTAssertEqual(try volume(document, fixture.bodyID),
                       60_000 - editedRemoval, accuracy: 1e-3)
        let result = try XCTUnwrap(body(document, fixture.bodyID))
        let walls = cylinders(result, radius: 4)
        XCTAssertFalse(walls.isEmpty)
        let area = walls.reduce(0) { $0 + $1.area }
        let centroid = walls.reduce(SIMD3<Double>.zero) { $0 + $1.centroid * $1.area } / area
        XCTAssertEqual(centroid.x, 60, accuracy: 1e-5)
        XCTAssertEqual(centroid.z, -30, accuracy: 1e-5)
        XCTAssertEqual(try holeRow(document, featureID)["id"] as? String ?? "", featureID,
                       "circle edit must preserve the hole feature identity")

        document.session.undo()
        XCTAssertEqual(try volume(document, fixture.bodyID),
                       60_000 - initialRemoval, accuracy: 1e-3)
        document.session.redo()
        XCTAssertEqual(try volume(document, fixture.bodyID),
                       60_000 - editedRemoval, accuracy: 1e-3)
    }

    func testRotatedScaledTargetKeepsWorldMillimetreHoleAndAxis() async throws {
        let document = try await makeDocument("Transformed")
        let fixture = try plate(document)
        let pivot = SIMD3<Double>(50, 0, -30)
        let rotation = simd_quatd(angle: 0.5,
                                  axis: simd_normalize(SIMD3(1, 1, 0.5)))
        let scale = 1.5
        let centre = pivot
        let moved = try run(document, [
            "op": "feature.transform",
            "args": ["bodyID": fixture.bodyID,
                     "rotationDegrees": 0.5 * 180 / .pi,
                     "rotationAxis": [rotation.imag.x, rotation.imag.y, rotation.imag.z],
                     "rotationCenter": [centre.x, centre.y, centre.z],
                     "scale": scale],
        ])
        XCTAssertNotEqual(moved["failed"] as? Bool, true)
        let initial = try volume(document, fixture.bodyID)
        XCTAssertEqual(initial, 60_000 * pow(scale, 3), accuracy: 1e-2)

        let inward = simd_normalize(rotation.act(SIMD3(0, 1, 0)))
        let plane = SketchPlane(origin: pivot,
                                xAxis: simd_normalize(rotation.act(SIMD3(1, 0, 0))),
                                yAxis: simd_normalize(rotation.act(SIMD3(0, 0, -1))))
        let circle = try circleSketch(document, center: SIMD2(0, 0), radius: 4, plane: plane)
        _ = try createHole(document, sketchID: circle.sketchID,
                           seed: SIMD2(0, 0), target: fixture.bodyID,
                           type: "blind", extra: ["depth": 6])
        XCTAssertEqual(try volume(document, fixture.bodyID),
                       60_000 * pow(scale, 3) - 96 * .pi, accuracy: 1e-2)
        let result = try XCTUnwrap(body(document, fixture.bodyID))
        try assertHealthy(result)
        let walls = cylinders(result, radius: 4)
        XCTAssertEqual(walls.reduce(0) { $0 + $1.area }, 2 * .pi * 4 * 6, accuracy: 1e-4)
        let area = walls.reduce(0) { $0 + $1.area }
        let centroid = walls.reduce(SIMD3<Double>.zero) { $0 + $1.centroid * $1.area } / area
        XCTAssertLessThan(simd_length(centroid - (pivot + 3 * inward)), 1e-4)
        for face in walls {
            XCTAssertEqual(abs(simd_dot(simd_normalize(face.normal), inward)), 1,
                           accuracy: 1e-7)
        }
    }

    func testReversedDirectionIsExplicitAndNoMaterialCutIsRefused() async throws {
        let document = try await makeDocument("Reversed")
        let fixture = try plate(document)
        let top = SketchPlane.offsetGround(y: 10)
        let circle = try circleSketch(document, center: SIMD2(50, 30), radius: 5, plane: top)
        _ = try createHole(document, sketchID: circle.sketchID,
                           seed: SIMD2(50, 30), target: fixture.bodyID,
                           type: "throughAll", extra: ["reversed": true])
        XCTAssertEqual(try volume(document, fixture.bodyID),
                       60_000 - 250 * .pi, accuracy: 1e-3)

        // The same top sketch drilled along +normal is outside the material and
        // must be refused, not silently recorded as a no-op feature.
        let outer = try circleSketch(document, center: SIMD2(20, 20), radius: 4, plane: top)
        let beforeVolume = try volume(document, fixture.bodyID)
        let beforeFeatures = try featureRows(document).count
        let noCut = expectFailure(document, [
            "op": "feature.hole",
            "args": ["sketchID": outer.sketchID,
                     "seedPoint": [20, 20],
                     "targetBodyID": fixture.bodyID,
                     "type": "blind",
                     "depth": 6],
        ], code: "feature_failed")
        XCTAssertEqual(noCut["failed"] as? Bool, true)
        XCTAssertEqual(try volume(document, fixture.bodyID), beforeVolume, accuracy: 1e-9)
        XCTAssertEqual(try featureRows(document).count, beforeFeatures)
    }

    // MARK: - Failure preservation / one-step undo

    func testInvalidHoleSpecsPreserveDocumentAndRedo() async throws {
        let document = try await makeDocument("Failures")
        let fixture = try plate(document)
        let circle = try circleSketch(document, center: SIMD2(50, 30), radius: 4)
        let reply = try createHole(document, sketchID: circle.sketchID,
                                   seed: SIMD2(50, 30), target: fixture.bodyID,
                                   type: "blind", extra: ["depth": 6])
        let featureID = try XCTUnwrap(reply["featureID"] as? String)
        let service = CADParameterService(document: document)
        XCTAssertEqual(service.handle(action: "update", args: [
            "feature_id": featureID, "changes": ["depth": 8.0],
        ])["ok"] as? Bool, true)
        document.session.undo()
        XCTAssertTrue(document.session.undoStack.canRedo)

        let before = try volume(document, fixture.bodyID)
        let beforeFeatures = try featureRows(document).count
        // Recess smaller than the Ø8 pilot: refused by the executor BEFORE any
        // mutation, and the existing redo history must survive.
        let refused = expectFailure(document, [
            "op": "feature.hole",
            "args": ["sketchID": circle.sketchID,
                     "seedPoint": [50, 30],
                     "targetBodyID": fixture.bodyID,
                     "type": "counterbore",
                     "counterboreDiameter": 3,
                     "counterboreDepth": 5],
        ], code: "invalid_hole")
        XCTAssertEqual(refused["ok"] as? Bool, false)
        XCTAssertEqual(try volume(document, fixture.bodyID), before, accuracy: 1e-9)
        XCTAssertEqual(try featureRows(document).count, beforeFeatures)
        XCTAssertTrue(document.session.undoStack.canRedo,
                      "a refused creation must not destroy redo")
        document.session.redo()
        XCTAssertEqual(try volume(document, fixture.bodyID),
                       60_000 - 128 * .pi, accuracy: 1e-3)

        // A parameter edit is validated at the SERVICE preflight against the
        // SAME structural bounds creation and evaluation use. A Ø4 counterbore
        // on the Ø8 pilot is invalid regardless of rebuild, so the documented
        // preflight contract refuses it as `bad_parameter` BEFORE any mutation
        // (the rebuild path still owns failures only the geometry can reveal).
        // Names here are the query kind=features vocabulary
        // (`counterbore_diameter`, not the create-time camelCase spelling).
        let rejected = service.handle(action: "update", args: [
            "feature_id": featureID,
            "changes": ["hole_type": "counterbore",
                        "counterbore_diameter": 4.0,
                        "counterbore_depth": 5.0],
        ])
        XCTAssertEqual(rejected["ok"] as? Bool, false, "\(rejected)")
        XCTAssertEqual(rejected["error"] as? String ?? "", "bad_parameter")
        XCTAssertTrue((rejected["message"] as? String ?? "").contains("pilot diameter"),
                      "the refusal must name the actual pilot relation: \(rejected)")
        XCTAssertEqual(try volume(document, fixture.bodyID),
                       60_000 - 128 * .pi, accuracy: 1e-3)
        XCTAssertFalse(document.session.undoStack.canRedo)
        document.session.undo()
        XCTAssertEqual(try volume(document, fixture.bodyID),
                       60_000 - 96 * .pi, accuracy: 1e-3,
                       "the failed edit must not have added an undo step")

        // Non-circle placement.
        let rect = try run(document, #"{"op":"sketch.create","args":{"name":"NotACircle"}}"#)
        let rectID = try XCTUnwrap(rect["sketchID"] as? String)
        _ = try run(document, [
            "op": "sketch.addEntities",
            "args": ["sketchID": rectID,
                     "entities": [["kind": "rect", "min": [10, 10], "max": [20, 20]]]],
        ])
        _ = expectFailure(document, [
            "op": "feature.hole",
            "args": ["sketchID": rectID, "seedPoint": [15, 15],
                     "targetBodyID": fixture.bodyID, "type": "blind", "depth": 5],
        ], code: "not_circle")
        XCTAssertEqual(try volume(document, fixture.bodyID),
                       60_000 - 96 * .pi, accuracy: 1e-3)

        // Mesh-only target.
        var meshOnly = Body(name: "MeshOnly",
                            euclidMesh: .primitive(.box(width: 10, depth: 10, height: 10)),
                            revision: 0)
        meshOnly.brep = nil
        document.session.perform(AddBodyCommand(body: meshOnly, title: "Mesh fixture"))
        _ = expectFailure(document, [
            "op": "feature.hole",
            "args": ["sketchID": circle.sketchID, "seedPoint": [50, 30],
                     "targetBodyID": meshOnly.id.raw.uuidString,
                     "type": "throughAll"],
        ], code: "hole_requires_brep")
    }

    // MARK: - Variables / expressions

    func testHoleDepthFormulaParticipatesInVariableFanOutRenameAndDeleteGuard() async throws {
        let document = try await makeDocument("Variables")
        let fixture = try plate(document)
        let circle = try circleSketch(document, center: SIMD2(50, 30), radius: 4)
        let reply = try createHole(document, sketchID: circle.sketchID,
                                   seed: SIMD2(50, 30), target: fixture.bodyID,
                                   type: "blind", extra: ["depth": 6])
        let featureID = try XCTUnwrap(reply["featureID"] as? String)
        let service = CADParameterService(document: document)

        let created = service.handle(action: "variable.create", args: [
            "name": "boreDepth", "expression": "6",
        ])
        XCTAssertEqual(created["ok"] as? Bool, true, "\(created)")
        let variable = try XCTUnwrap(created["variable"] as? [String: Any])
        let variableID = try XCTUnwrap(variable["id"] as? String)

        let bound = service.handle(action: "feature.setExpression", args: [
            "feature_id": featureID, "parameter": "depth", "expression": "boreDepth",
        ])
        XCTAssertEqual(bound["ok"] as? Bool, true, "\(bound)")
        var row = try holeRow(document, featureID)
        XCTAssertEqual(parameter(document, "depth", row)?["formula"] as? String ?? "", "boreDepth")

        let widened = service.handle(action: "variable.update", args: [
            "variable_id": variableID, "expression": "8",
        ])
        XCTAssertEqual(widened["ok"] as? Bool, true, "\(widened)")
        XCTAssertEqual(try volume(document, fixture.bodyID),
                       60_000 - 128 * .pi, accuracy: 1e-3)
        row = try holeRow(document, featureID)
        XCTAssertEqual(parameter(document, "depth", row)?["value"] as? Double ?? .nan, 8, accuracy: 1e-9)
        document.session.undo()
        XCTAssertEqual(try volume(document, fixture.bodyID),
                       60_000 - 96 * .pi, accuracy: 1e-3)
        document.session.redo()
        XCTAssertEqual(try volume(document, fixture.bodyID),
                       60_000 - 128 * .pi, accuracy: 1e-3)

        let renamed = service.handle(action: "variable.update", args: [
            "variable_id": variableID, "name": "holeDepth",
        ])
        XCTAssertEqual(renamed["ok"] as? Bool, true, "\(renamed)")
        row = try holeRow(document, featureID)
        XCTAssertEqual(parameter(document, "depth", row)?["formula"] as? String ?? "", "holeDepth")
        XCTAssertEqual(try volume(document, fixture.bodyID),
                       60_000 - 128 * .pi, accuracy: 1e-3)

        let refusedDelete = service.handle(action: "variable.delete", args: [
            "variable_id": variableID,
        ])
        XCTAssertEqual(refusedDelete["ok"] as? Bool, false)
        XCTAssertEqual(refusedDelete["error"] as? String ?? "", "variable_in_use")
        XCTAssertEqual(parameter(document, "depth", try holeRow(document, featureID))?["formula"] as? String ?? "",
                       "holeDepth")
    }

    // MARK: - Persistence / format gate

    func testSaveReopenFormatThreeAndOrdinaryFormatsUnchanged() async throws {
        let holeURL = directory.appendingPathComponent("hole-format.floecad")
        let holeDocument = try await FloeCADDocument.create(at: holeURL, name: "HoleFormat")
        documents.append(holeDocument)
        let fixture = try plate(holeDocument)
        let circle = try circleSketch(holeDocument, center: SIMD2(50, 30), radius: 4)
        let reply = try createHole(holeDocument, sketchID: circle.sketchID,
                                   seed: SIMD2(50, 30), target: fixture.bodyID,
                                   type: "blind", extra: ["depth": 6])
        let featureID = try XCTUnwrap(reply["featureID"] as? String)
        let saved = await holeDocument.save()
        XCTAssertTrue(saved.succeeded, saved.error ?? "")
        XCTAssertEqual(holeDocument.summary().schemaVersion, 3)
        XCTAssertEqual(holeDocument.project.formatVersion, 3)
        holeDocument.close()

        let reopened = try await FloeCADDocument.open(at: holeURL)
        documents.append(reopened)
        XCTAssertFalse(reopened.isReadOnly)
        XCTAssertEqual(reopened.summary().schemaVersion, 3)
        let bodies = try XCTUnwrap(snapshotBodies(reopened))
        XCTAssertEqual(bodies.count, 1)
        let bodyID = try XCTUnwrap(bodies.first?["id"] as? String)
        XCTAssertEqual(bodyID, fixture.bodyID, "save/reopen must preserve the body identity")
        XCTAssertEqual(try volume(reopened, bodyID), 60_000 - 96 * .pi, accuracy: 1e-3)
        let row = try holeRow(reopened, featureID)
        XCTAssertEqual(parameter(reopened, "depth", row)?["value"] as? Double ?? .nan, 6, accuracy: 1e-9)
        XCTAssertEqual(parameter(reopened, "hole_type", row)?["value"] as? String ?? "", "blind")

        // A no-hole document keeps format 1.
        let plainURL = directory.appendingPathComponent("plain-format.floecad")
        let plain = try await FloeCADDocument.create(at: plainURL, name: "Plain")
        documents.append(plain)
        _ = try plate(plain)
        let plainSave = await plain.save()
        XCTAssertTrue(plainSave.succeeded)
        XCTAssertEqual(plain.summary().schemaVersion, 1)
        plain.close()

        // An associative document keeps format 2 (no hole present).
        let assocURL = directory.appendingPathComponent("assoc-format.floecad")
        let assoc = try await FloeCADDocument.create(at: assocURL, name: "Assoc")
        documents.append(assoc)
        assoc.session.perform(AddConstructionPlaneCommand(plane: try CADAssociativeFormatFixture.plane()))
        let assocSave = await assoc.save()
        XCTAssertTrue(assocSave.succeeded)
        XCTAssertEqual(assoc.summary().schemaVersion, 2)
    }

    func testFutureHoleDefinitionIsOpaqueReadOnlyAndRawPreserved() async throws {
        let url = directory.appendingPathComponent("future-hole.floecad")
        let document = try await FloeCADDocument.create(at: url, name: "FutureHole")
        documents.append(document)
        let fixture = try plate(document)
        let circle = try circleSketch(document, center: SIMD2(50, 30), radius: 5)
        _ = try createHole(document, sketchID: circle.sketchID,
                           seed: SIMD2(50, 30), target: fixture.bodyID,
                           type: "throughAll")
        let initialSave = await document.save()
        XCTAssertTrue(initialSave.succeeded)
        document.close()

        try CADAssociativeFormatFixture.rewrite(url, schema: 3) { record in
            let index = try XCTUnwrap(record.features.firstIndex(where: { row in
                guard let object = (try? JSONSerialization.jsonObject(with: row.kind)) as? [String: Any]
                else { return false }
                return object["hole"] != nil
            }))
            var kind = try XCTUnwrap(
                JSONSerialization.jsonObject(with: record.features[index].kind) as? [String: Any])
            var hole = try XCTUnwrap(kind["hole"] as? [String: Any])
            var spec = try XCTUnwrap(hole["spec"] as? [String: Any])
            spec["version"] = 2
            hole["spec"] = spec
            kind["hole"] = hole
            record.features[index].kind = try JSONSerialization.data(withJSONObject: kind)
        }
        let raw = try CADAssociativeFormatFixture.record(url)
        let assessment = try CADDocumentFormat.assess(raw)
        XCTAssertTrue(assessment.isOpaqueReadOnly)
        XCTAssertEqual(assessment.requiredVersion, 3)
        XCTAssertEqual(assessment.opaqueFeatures.count, 1)

        let before = try CADAssociativeFormatFixture.bytes(url)
        let future = try await FloeCADDocument.open(at: url)
        documents.append(future)
        XCTAssertTrue(future.isReadOnly)
        XCTAssertNotNil(future.session.loadWarning)
        XCTAssertFalse(future.session.document.features.nodes.contains {
            if case .hole = $0.kind { return true }
            return false
        }, "a future hole definition must not be replayed or silently reinterpreted")
        let bodies = try XCTUnwrap(snapshotBodies(future))
        let bodyID = try XCTUnwrap(bodies.first?["id"] as? String)
        XCTAssertEqual(try volume(future, bodyID), 60_000 - 250 * .pi, accuracy: 1e-3,
                       "cached geometry must remain visible")
        let attempt = await future.save()
        XCTAssertFalse(attempt.succeeded)
        XCTAssertEqual(try CADAssociativeFormatFixture.bytes(url), before,
                       "an opaque read-only save must not rewrite a byte")

        // Malformed KNOWN semantics are distinguished from a future version:
        // they are reported as malformed and never replayed either. The raw
        // record above deliberately carries version 2 so it opens read-only as
        // a FUTURE definition; this corruption fixture must therefore restore
        // the supported version, otherwise `assess` would still take the
        // future-version opaque branch instead of validating known fields.
        var malformed = raw
        let holeIndex = try XCTUnwrap(malformed.features.firstIndex(where: { row in
            guard let object = (try? JSONSerialization.jsonObject(with: row.kind)) as? [String: Any]
            else { return false }
            return object["hole"] != nil
        }))
        var kind = try XCTUnwrap(
            JSONSerialization.jsonObject(with: malformed.features[holeIndex].kind) as? [String: Any])
        var hole = try XCTUnwrap(kind["hole"] as? [String: Any])
        var spec = try XCTUnwrap(hole["spec"] as? [String: Any])
        spec["version"] = HoleSpec.supportedVersion
        spec["kind"] = "blind"
        spec.removeValue(forKey: "depth")
        hole["spec"] = spec
        kind["hole"] = hole
        malformed.features[holeIndex].kind = try JSONSerialization.data(withJSONObject: kind)
        XCTAssertThrowsError(try CADDocumentFormat.assess(malformed)) { error in
            guard let format = error as? CADDocumentFormatError,
                  case let .malformedAssociation(record) = format else {
                return XCTFail("unexpected error \(error)")
            }
            XCTAssertTrue(record.contains("hole"))
        }

        // An unknown FUTURE kind is opaque (not malformed) at a KNOWN version,
        // so the fixture must also restore the supported version here; the
        // `threaded` kind alone is what makes it future/opaque.
        var futureKind = raw
        var kind2 = try XCTUnwrap(
            JSONSerialization.jsonObject(with: futureKind.features[holeIndex].kind) as? [String: Any])
        var hole2 = try XCTUnwrap(kind2["hole"] as? [String: Any])
        var spec2 = try XCTUnwrap(hole2["spec"] as? [String: Any])
        spec2["version"] = HoleSpec.supportedVersion
        spec2["kind"] = "threaded"
        hole2["spec"] = spec2
        kind2["hole"] = hole2
        futureKind.features[holeIndex].kind = try JSONSerialization.data(withJSONObject: kind2)
        let futureAssessment = try CADDocumentFormat.assess(futureKind)
        XCTAssertTrue(futureAssessment.isOpaqueReadOnly)
    }

    func testFixedSchemaTwoReaderCannotRepresentHoleKindAndGateRefusesThree() async throws {
        let url = directory.appendingPathComponent("schema2-reader.floecad")
        let document = try await FloeCADDocument.create(at: url, name: "SchemaTwo")
        documents.append(document)
        let fixture = try plate(document)
        let circle = try circleSketch(document, center: SIMD2(50, 30), radius: 5)
        _ = try createHole(document, sketchID: circle.sketchID,
                           seed: SIMD2(50, 30), target: fixture.bodyID,
                           type: "throughAll")
        let kindBytes = try JSONEncoder().encode(
            try XCTUnwrap(document.session.document.features.nodes.first {
                if case .hole = $0.kind { return true }
                return false
            }).kind)
        XCTAssertFalse(SchemaTwoKindNameReader.supports(kindBytes))

        let saved = await document.save()
        XCTAssertTrue(saved.succeeded)
        document.close()

        let data = try Data(contentsOf: url.appendingPathComponent("document.json"))
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let features = try XCTUnwrap(root["features"] as? [[String: Any]])
        let row = try XCTUnwrap(features.first)
        let fixed = try JSONDecoder().decode(SchemaTwoFeatureRowReader.self,
                                             from: JSONSerialization.data(withJSONObject: row))
        XCTAssertFalse(fixed.name.isEmpty)
        XCTAssertFalse(SchemaTwoFeatureRowReader.sessionAllowsWrite(schema: 3),
                       "a fixed schema-2 reader must refuse format 3 rather than ignore it")
        XCTAssertTrue(SchemaTwoFeatureRowReader.sessionAllowsWrite(schema: 2))

    }

    // MARK: - Merge / legacy compatibility

    func testMergeRemapsHoleReferencesAndReplaysExactVolume() async throws {
        let document = try await makeDocument("MergeGuest")
        let fixture = try plate(document)
        let circle = try circleSketch(document, center: SIMD2(50, 30), radius: 5)
        _ = try createHole(document, sketchID: circle.sketchID,
                           seed: SIMD2(50, 30), target: fixture.bodyID,
                           type: "throughAll")
        let guest = document.session.document
        let guestHole = try XCTUnwrap(guest.features.nodes.first {
            if case .hole = $0.kind { return true }
            return false
        })
        let insertion = try ProjectMergeKit.insert(
            guest, into: DesignDocument(), translation: SIMD3(200, 0, 0))
        let mergedHole = try XCTUnwrap(insertion.document.features.nodes.first {
            if case .hole = $0.kind { return true }
            return false
        })
        guard case let .hole(target, profile, plane, spec) = mergedHole.kind,
              case let .hole(originalTarget, originalProfile, _, originalSpec) = guestHole.kind
        else { return XCTFail("merged node lost its hole kind") }
        XCTAssertNotEqual(target.bodyID, originalTarget.bodyID)
        XCTAssertNotEqual(profile.sketchID, originalProfile.sketchID)
        guard case let .sketch(planeSketch) = plane.source else {
            return XCTFail("hole plane must stay a sketch plane")
        }
        XCTAssertEqual(planeSketch, profile.sketchID)
        XCTAssertEqual(spec, originalSpec)
        XCTAssertNotEqual(mergedHole.id, guestHole.id)

        var revision: UInt64 = 0
        let result = insertion.document.features.evaluate(
            sketches: insertion.document.sketches,
            planes: insertion.document.planes,
            naming: SignatureNaming(),
            nextRevision: { revision &+= 1; return revision })
        XCTAssertTrue(result.errors.isEmpty, "\(result.errors)")
        XCTAssertTrue(result.bodies.contains {
            abs(MeasureKit.volume(of: $0) - (60_000 - 250 * .pi)) < 1e-3
        }, "merged hole must replay to the exact translated volume")
        let translated = insertion.document.sketches.compactMap {
            $0.entities.compactMap { entity -> SIMD2<Double>? in
                if case let .circle(_, center, _) = entity { return center }
                return nil
            }.first
        }.first
        XCTAssertNotNil(translated)
    }

    func testLegacyCircleExtrudeSubtractRemainsExact() async throws {
        let document = try await makeDocument("Legacy")
        let fixture = try plate(document)
        let circle = try circleSketch(document, center: SIMD2(50, 30), radius: 5)
        let cut = try run(document, [
            "op": "feature.extrude",
            "args": ["sketchID": circle.sketchID, "seedPoint": [50, 30],
                     "distance": 40, "symmetric": true,
                     "boolean": "subtract", "booleanTargets": [fixture.bodyID]],
        ])
        XCTAssertNotEqual(cut["failed"] as? Bool, true)
        XCTAssertEqual(try volume(document, fixture.bodyID),
                       60_000 - 250 * .pi, accuracy: 1e-3)
        XCTAssertNotNil(body(document, fixture.bodyID)?.brep,
                        "legacy circle+extrude cut must stay analytic")
    }

    // MARK: - Post-creation edits and source-face following

    /// Counterbore created once, then edited in place through the real
    /// parameter and sketch-entity services: position, recess diameter,
    /// recess depth and finally the hole TYPE. Every step keeps the SAME
    /// feature id and the SAME placement sketch/entity, and the measured B-rep
    /// matches independent analytic removal from a 100 × 60 × 10 mm plate.
    func testCounterborePostCreationPositionDiameterDepthAndTypeEditsKeepIdentity() async throws {
        let document = try await makeDocument("CounterboreEdits")
        let fixture = try plate(document)
        let circle = try circleSketch(document, center: SIMD2(50, 30), radius: 3)
        let reply = try createHole(document, sketchID: circle.sketchID,
                                   seed: SIMD2(50, 30), target: fixture.bodyID,
                                   type: "counterbore",
                                   extra: ["counterboreDiameter": 11, "counterboreDepth": 5])
        let featureID = try XCTUnwrap(reply["featureID"] as? String)
        let service = CADParameterService(document: document)
        // Recess radius R over `depth`, pilot radius 3 through the remainder.
        func removal(_ diameter: Double, _ depth: Double) -> Double {
            .pi * (diameter / 2) * (diameter / 2) * depth + .pi * 3 * 3 * (10 - depth)
        }
        XCTAssertEqual(try volume(document, fixture.bodyID),
                       60_000 - removal(11, 5), accuracy: 1e-3)
        try assertHoleIdentity(document, featureID, sketchID: circle.sketchID,
                               entityID: circle.entityID)
        let created = try holeRow(document, featureID)
        XCTAssertEqual(parameter(document, "hole_type", created)?["value"] as? String ?? "",
                       "counterbore")
        XCTAssertEqual(parameter(document, "counterbore_diameter", created)?["value"] as? Double ?? .nan,
                       11, accuracy: 1e-9)
        XCTAssertEqual(parameter(document, "counterbore_depth", created)?["value"] as? Double ?? .nan,
                       5, accuracy: 1e-9)

        // 1) Position edit through the placement circle, same entity id.
        let moved = service.handle(action: "updateSketchEntity", args: [
            "sketch_id": circle.sketchID,
            "entity_id": circle.entityID,
            "center": [58.0, 30.0],
        ])
        XCTAssertEqual(moved["ok"] as? Bool, true, "\(moved)")
        XCTAssertEqual(try volume(document, fixture.bodyID),
                       60_000 - removal(11, 5), accuracy: 1e-3)
        let placed = try XCTUnwrap(body(document, fixture.bodyID))
        XCTAssertEqual(centroidX(cylinders(placed, radius: 5.5)), 58, accuracy: 1e-5)
        let movedShoulder = planar(placed, depth: 5, inward: SIMD3(0, 1, 0),
                                   entry: SIMD3(58, 0, -30))
        XCTAssertEqual(movedShoulder.count, 1)
        XCTAssertEqual(centroidX(movedShoulder), 58, accuracy: 1e-5)
        try assertHoleIdentity(document, featureID, sketchID: circle.sketchID,
                               entityID: circle.entityID)

        // 2) Recess diameter edit; one undo step, same hole.
        let widened = service.handle(action: "update", args: [
            "feature_id": featureID, "changes": ["counterbore_diameter": 13.0],
        ])
        XCTAssertEqual(widened["ok"] as? Bool, true, "\(widened)")
        XCTAssertEqual(try volume(document, fixture.bodyID),
                       60_000 - removal(13, 5), accuracy: 1e-3)
        let wide = try XCTUnwrap(body(document, fixture.bodyID))
        XCTAssertEqual(cylinders(wide, radius: 6.5).reduce(0) { $0 + $1.area },
                       2 * .pi * 6.5 * 5, accuracy: 1e-4)
        let wideShoulder = planar(wide, depth: 5, inward: SIMD3(0, 1, 0),
                                  entry: SIMD3(58, 0, -30))
        XCTAssertEqual(wideShoulder.count, 1)
        XCTAssertEqual(wideShoulder.first?.area ?? 0,
                       .pi * (6.5 * 6.5 - 3 * 3), accuracy: 1e-4)
        document.session.undo()
        XCTAssertEqual(try volume(document, fixture.bodyID),
                       60_000 - removal(11, 5), accuracy: 1e-3)
        document.session.redo()
        XCTAssertEqual(try volume(document, fixture.bodyID),
                       60_000 - removal(13, 5), accuracy: 1e-3)

        // 3) Recess depth edit, same feature.
        let shallow = service.handle(action: "update", args: [
            "feature_id": featureID, "changes": ["counterbore_depth": 3.0],
        ])
        XCTAssertEqual(shallow["ok"] as? Bool, true, "\(shallow)")
        XCTAssertEqual(try volume(document, fixture.bodyID),
                       60_000 - removal(13, 3), accuracy: 1e-3)
        let shallowBody = try XCTUnwrap(body(document, fixture.bodyID))
        XCTAssertEqual(cylinders(shallowBody, radius: 6.5).reduce(0) { $0 + $1.area },
                       2 * .pi * 6.5 * 3, accuracy: 1e-4)
        XCTAssertEqual(cylinders(shallowBody, radius: 3).reduce(0) { $0 + $1.area },
                       2 * .pi * 3 * 7, accuracy: 1e-4)
        let shallowShoulder = planar(shallowBody, depth: 3, inward: SIMD3(0, 1, 0),
                                     entry: SIMD3(58, 0, -30))
        XCTAssertEqual(shallowShoulder.count, 1)
        XCTAssertEqual(shallowShoulder.first?.area ?? 0,
                       .pi * (6.5 * 6.5 - 3 * 3), accuracy: 1e-4)
        try assertHoleIdentity(document, featureID, sketchID: circle.sketchID,
                               entityID: circle.entityID)

        // 4) Counterbore -> countersink on the SAME feature, one update.
        let sunk = service.handle(action: "update", args: [
            "feature_id": featureID,
            "changes": ["hole_type": "countersink",
                        "countersink_diameter": 12.0,
                        "countersink_angle": 90.0],
        ])
        XCTAssertEqual(sunk["ok"] as? Bool, true, "\(sunk)")
        XCTAssertEqual(try volume(document, fixture.bodyID),
                       60_000 - 126 * .pi, accuracy: 1e-3)
        let sunkBody = try XCTUnwrap(body(document, fixture.bodyID))
        let cones = OCCTKernel.faceInfo(try XCTUnwrap(sunkBody.brep))
            .filter { $0.signature == nil }
        XCTAssertEqual(cones.reduce(0) { $0 + $1.area },
                       27 * sqrt(2) * .pi, accuracy: 1e-4)
        XCTAssertEqual(cylinders(sunkBody, radius: 3).reduce(0) { $0 + $1.area },
                       2 * .pi * 3 * 7, accuracy: 1e-4)
        let sunkRow = try holeRow(document, featureID)
        XCTAssertEqual(parameter(document, "hole_type", sunkRow)?["value"] as? String ?? "",
                       "countersink")
        XCTAssertEqual(parameter(document, "countersink_diameter", sunkRow)?["value"] as? Double ?? .nan,
                       12, accuracy: 1e-9)
        XCTAssertEqual(parameter(document, "countersink_angle", sunkRow)?["value"] as? Double ?? .nan,
                       90, accuracy: 1e-9)
        XCTAssertEqual(parameter(document, "counterbore_diameter", sunkRow)?["editable"] as? Bool, false,
                       "a stored recess value stops being editable once the type no longer uses it")
        try assertHoleIdentity(document, featureID, sketchID: circle.sketchID,
                               entityID: circle.entityID)
        document.session.undo()
        XCTAssertEqual(try volume(document, fixture.bodyID),
                       60_000 - removal(13, 3), accuracy: 1e-3)
        document.session.redo()
        XCTAssertEqual(try volume(document, fixture.bodyID),
                       60_000 - 126 * .pi, accuracy: 1e-3)
        XCTAssertEqual(body(document, fixture.bodyID)?.id.raw.uuidString ?? "", fixture.bodyID)
    }

    /// Countersink created once, then edited in place: recess diameter,
    /// position, then TYPE transitions into the flat-bottom and recess shapes
    /// (each supplying the new type's own dimensions in the same update).
    func testCountersinkPostCreationDiameterAndRecessTypeTransitionsKeepIdentity() async throws {
        let document = try await makeDocument("CountersinkEdits")
        let fixture = try plate(document)
        let circle = try circleSketch(document, center: SIMD2(50, 30), radius: 3)
        let reply = try createHole(document, sketchID: circle.sketchID,
                                   seed: SIMD2(50, 30), target: fixture.bodyID,
                                   type: "countersink",
                                   extra: ["countersinkDiameter": 12, "countersinkAngle": 90])
        let featureID = try XCTUnwrap(reply["featureID"] as? String)
        let service = CADParameterService(document: document)
        XCTAssertEqual(try volume(document, fixture.bodyID),
                       60_000 - 126 * .pi, accuracy: 1e-3)
        try assertHoleIdentity(document, featureID, sketchID: circle.sketchID,
                               entityID: circle.entityID)

        // 1) Recess diameter 12 -> 14 at the same 90° included angle.
        //    Frustum: R = 7 at the entry, r = 3 at depth 4; pilot to 10.
        let widened = service.handle(action: "update", args: [
            "feature_id": featureID, "changes": ["countersink_diameter": 14.0],
        ])
        XCTAssertEqual(widened["ok"] as? Bool, true, "\(widened)")
        XCTAssertEqual(try volume(document, fixture.bodyID),
                       60_000 - 478 * .pi / 3, accuracy: 1e-3)
        let wide = try XCTUnwrap(body(document, fixture.bodyID))
        let wideCones = OCCTKernel.faceInfo(try XCTUnwrap(wide.brep))
            .filter { $0.signature == nil }
        let wideConeArea = wideCones.reduce(0) { $0 + $1.area }
        XCTAssertEqual(wideConeArea, 40 * sqrt(2) * .pi, accuracy: 1e-4)
        let wideConeCentroid = wideCones.reduce(SIMD3<Double>.zero) {
            $0 + $1.centroid * $1.area
        } / wideConeArea
        XCTAssertEqual(simd_dot(wideConeCentroid - SIMD3(50, 0, -30), SIMD3(0, 1, 0)),
                       26.0 / 15.0, accuracy: 1e-5,
                       "lateral frustum centroid h(R+2r)/(3(R+r))")

        // 2) Position edit through the placement circle, same entity id.
        let moved = service.handle(action: "updateSketchEntity", args: [
            "sketch_id": circle.sketchID,
            "entity_id": circle.entityID,
            "center": [44.0, 30.0],
        ])
        XCTAssertEqual(moved["ok"] as? Bool, true, "\(moved)")
        XCTAssertEqual(try volume(document, fixture.bodyID),
                       60_000 - 478 * .pi / 3, accuracy: 1e-3)
        let placed = try XCTUnwrap(body(document, fixture.bodyID))
        XCTAssertEqual(centroidX(OCCTKernel.faceInfo(try XCTUnwrap(placed.brep))
            .filter { $0.signature == nil }), 44, accuracy: 1e-5)
        try assertHoleIdentity(document, featureID, sketchID: circle.sketchID,
                               entityID: circle.entityID)

        // 3) Countersink -> blind needs a depth. A type-only update must be
        //    refused BEFORE mutation and must not damage the hole.
        let beforeRejection = document.session.changeCount
        let rejected = service.handle(action: "update", args: [
            "feature_id": featureID, "changes": ["hole_type": "blind"],
        ])
        XCTAssertEqual(rejected["ok"] as? Bool, false, "\(rejected)")
        XCTAssertEqual(rejected["error"] as? String ?? "", "bad_parameter")
        XCTAssertTrue((rejected["message"] as? String ?? "").contains("blind"),
                      "\(rejected)")
        XCTAssertEqual(document.session.changeCount, beforeRejection)
        XCTAssertEqual(try volume(document, fixture.bodyID),
                       60_000 - 478 * .pi / 3, accuracy: 1e-3)

        // 4) The documented SINGLE update that changes the type AND supplies
        //    its depth must be accepted (the pre-fix order checked the stored
        //    spec before reading the depth from this same update).
        let blind = service.handle(action: "update", args: [
            "feature_id": featureID, "changes": ["hole_type": "blind", "depth": 7.0],
        ])
        XCTAssertEqual(blind["ok"] as? Bool, true, "\(blind)")
        XCTAssertEqual(try volume(document, fixture.bodyID),
                       60_000 - 63 * .pi, accuracy: 1e-3)
        let blindBody = try XCTUnwrap(body(document, fixture.bodyID))
        try assertHealthy(blindBody)
        XCTAssertEqual(cylinders(blindBody, radius: 3).reduce(0) { $0 + $1.area },
                       2 * .pi * 3 * 7, accuracy: 1e-4)
        XCTAssertEqual(planar(blindBody, depth: 7, inward: SIMD3(0, 1, 0),
                              entry: SIMD3(44, 0, -30)).count, 1)
        let blindRow = try holeRow(document, featureID)
        XCTAssertEqual(parameter(document, "hole_type", blindRow)?["value"] as? String ?? "", "blind")
        XCTAssertEqual(parameter(document, "depth", blindRow)?["value"] as? Double ?? .nan,
                       7, accuracy: 1e-9)
        try assertHoleIdentity(document, featureID, sketchID: circle.sketchID,
                               entityID: circle.entityID)

        // 5) Depth edit on the converted blind hole; one undo step.
        let deeper = service.handle(action: "update", args: [
            "feature_id": featureID, "changes": ["depth": 9.0],
        ])
        XCTAssertEqual(deeper["ok"] as? Bool, true, "\(deeper)")
        XCTAssertEqual(try volume(document, fixture.bodyID),
                       60_000 - 81 * .pi, accuracy: 1e-3)
        XCTAssertEqual(planar(try XCTUnwrap(body(document, fixture.bodyID)),
                              depth: 9, inward: SIMD3(0, 1, 0),
                              entry: SIMD3(44, 0, -30)).count, 1)
        document.session.undo()
        XCTAssertEqual(try volume(document, fixture.bodyID),
                       60_000 - 63 * .pi, accuracy: 1e-3)
        document.session.redo()
        XCTAssertEqual(try volume(document, fixture.bodyID),
                       60_000 - 81 * .pi, accuracy: 1e-3)

        // 6) Blind -> counterbore on the same feature, dimensions supplied.
        let bored = service.handle(action: "update", args: [
            "feature_id": featureID,
            "changes": ["hole_type": "counterbore",
                        "counterbore_diameter": 12.0,
                        "counterbore_depth": 4.0],
        ])
        XCTAssertEqual(bored["ok"] as? Bool, true, "\(bored)")
        XCTAssertEqual(try volume(document, fixture.bodyID),
                       60_000 - 198 * .pi, accuracy: 1e-3)
        let boredBody = try XCTUnwrap(body(document, fixture.bodyID))
        try assertHealthy(boredBody)
        XCTAssertEqual(cylinders(boredBody, radius: 6).reduce(0) { $0 + $1.area },
                       2 * .pi * 6 * 4, accuracy: 1e-4)
        XCTAssertEqual(cylinders(boredBody, radius: 3).reduce(0) { $0 + $1.area },
                       2 * .pi * 3 * 6, accuracy: 1e-4)
        let boredShoulder = planar(boredBody, depth: 4, inward: SIMD3(0, 1, 0),
                                   entry: SIMD3(44, 0, -30))
        XCTAssertEqual(boredShoulder.count, 1)
        XCTAssertEqual(boredShoulder.first?.area ?? 0,
                       .pi * (6 * 6 - 3 * 3), accuracy: 1e-4)
        try assertHoleIdentity(document, featureID, sketchID: circle.sketchID,
                               entityID: circle.entityID)
        XCTAssertEqual(body(document, fixture.bodyID)?.id.raw.uuidString ?? "", fixture.bodyID)
    }

    /// The M12 gap that the transformed-target case did NOT prove: its body was
    /// moved BEFORE the hole existed. Here a real named top face supplies an
    /// associative construction plane and the hole's placement sketch, the hole
    /// is created FIRST, and only then does the defining extrude move that face
    /// from y = 10 to y = 16. The same hole must re-cut from the NEW face
    /// (walls 10…16, floor at 10) instead of staying behind as a buried cavity.
    func testHoleRebuildsFromPostCreationSourceFaceChangeAndSurvivesSaveReopen() async throws {
        let url = directory.appendingPathComponent("postcreation-face.floecad")
        let document = try await FloeCADDocument.create(at: url, name: "PostCreationFace")
        documents.append(document)
        let fixture = try plate(document)
        let extrudeID = try XCTUnwrap(featureRows(document).first {
            ($0["kind"] as? String) == "extrude"
        }?["id"] as? String)
        let top = try faceRow(document, bodyID: fixture.bodyID, normal: SIMD3(0, 1, 0))
        XCTAssertEqual(top["datum_source_supported"] as? Bool, true, "\(top)")
        XCTAssertEqual(top["kind"] as? String, "planar")

        let service = CADParameterService(document: document)
        let plane = service.handle(action: "datum.offsetPlane.create", args: [
            "body_id": fixture.bodyID,
            "face_index": try XCTUnwrap(top["index"]),
            "query_token": try XCTUnwrap(top["query_token"]),
            "expression": "0",
        ])
        XCTAssertEqual(plane["ok"] as? Bool, true, "\(plane)")
        let planeID = try XCTUnwrap(plane["plane_id"] as? String)
        let planeUUID = try XCTUnwrap(UUID(uuidString: planeID))

        // The placement sketch starts on the ground like the native sketch
        // tool, then is hosted on the derived face plane. Its local circle at
        // (0, 0) therefore sits exactly at the current face centroid.
        let circle = try circleSketch(document, center: SIMD2(0, 0), radius: 4)
        let support = service.handle(action: "sketch.setSupport", args: [
            "sketch_id": circle.sketchID, "plane_id": planeID,
        ])
        XCTAssertEqual(support["ok"] as? Bool, true, "\(support)")
        let supported = try XCTUnwrap(document.session.document.sketches.first {
            $0.id.raw.uuidString == circle.sketchID
        })
        XCTAssertEqual(supported.support,
                       PlaneRef(source: .construction(ConstructionPlaneID(raw: planeUUID))))
        XCTAssertEqual(supported.plane.origin.y, 10, accuracy: 1e-6)

        let reply = try createHole(document, sketchID: circle.sketchID, seed: SIMD2(0, 0),
                                   target: fixture.bodyID, type: "blind",
                                   extra: ["depth": 6, "reversed": true])
        let featureID = try XCTUnwrap(reply["featureID"] as? String)
        XCTAssertEqual(try volume(document, fixture.bodyID),
                       60_000 - 96 * .pi, accuracy: 1e-3)
        try assertHoleIdentity(document, featureID, sketchID: circle.sketchID,
                               entityID: circle.entityID)
        let initial = try XCTUnwrap(body(document, fixture.bodyID))
        try assertHealthy(initial)
        let initialWalls = cylinders(initial, radius: 4)
        let initialWallArea = initialWalls.reduce(0) { $0 + $1.area }
        XCTAssertEqual(initialWallArea, 2 * .pi * 4 * 6, accuracy: 1e-4)
        let initialWallCentroid = initialWalls.reduce(SIMD3<Double>.zero) {
            $0 + $1.centroid * $1.area
        } / initialWallArea
        XCTAssertEqual(initialWallCentroid.y, 7, accuracy: 1e-5,
                       "the hole must start at the source face y = 10")
        XCTAssertEqual(planar(initial, depth: 6, inward: SIMD3(0, -1, 0),
                              entry: SIMD3(50, 10, -30)).count, 1)

        // The REAL post-creation source-face modification: the SAME defining
        // extrude now ends 6 mm higher. Nothing on the hole is touched.
        let grown = service.handle(action: "update", args: [
            "feature_id": extrudeID, "changes": ["distance": 16.0],
        ])
        XCTAssertEqual(grown["ok"] as? Bool, true, "\(grown)")
        XCTAssertEqual(try volume(document, fixture.bodyID),
                       96_000 - 96 * .pi, accuracy: 1e-3)
        XCTAssertEqual(try XCTUnwrap(document.session.document.planes.first {
            $0.id.raw.uuidString == planeID
        }).plane.origin.y, 16, accuracy: 1e-6)
        XCTAssertEqual(try XCTUnwrap(document.session.document.sketches.first {
            $0.id.raw.uuidString == circle.sketchID
        }).plane.origin.y, 16, accuracy: 1e-6)

        let followed = try XCTUnwrap(body(document, fixture.bodyID))
        try assertHealthy(followed)
        XCTAssertEqual(followed.id.raw.uuidString, fixture.bodyID)
        let walls = cylinders(followed, radius: 4)
        let wallArea = walls.reduce(0) { $0 + $1.area }
        XCTAssertEqual(wallArea, 2 * .pi * 4 * 6, accuracy: 1e-4)
        let wallCentroid = walls.reduce(SIMD3<Double>.zero) {
            $0 + $1.centroid * $1.area
        } / wallArea
        XCTAssertEqual(wallCentroid.y, 13, accuracy: 1e-5, "walls must now run 10…16")
        let floor = planar(followed, depth: 6, inward: SIMD3(0, -1, 0),
                           entry: SIMD3(50, 16, -30))
        XCTAssertEqual(floor.count, 1)
        XCTAssertEqual(floor.first?.area ?? 0, .pi * 16, accuracy: 1e-4)
        try assertHoleIdentity(document, featureID, sketchID: circle.sketchID,
                               entityID: circle.entityID)

        // One undo step for the source edit and its dependent hole rebuild.
        document.session.undo()
        XCTAssertEqual(try volume(document, fixture.bodyID),
                       60_000 - 96 * .pi, accuracy: 1e-3)
        document.session.redo()
        XCTAssertEqual(try volume(document, fixture.bodyID),
                       96_000 - 96 * .pi, accuracy: 1e-3)

        let saved = await document.save()
        XCTAssertTrue(saved.succeeded, saved.error ?? "")
        document.close()
        let reopened = try await FloeCADDocument.open(at: url)
        documents.append(reopened)
        let bodies = try XCTUnwrap(snapshotBodies(reopened))
        XCTAssertEqual(bodies.count, 1)
        let bodyID = try XCTUnwrap(bodies.first?["id"] as? String)
        XCTAssertEqual(bodyID, fixture.bodyID)
        XCTAssertEqual(try volume(reopened, bodyID), 96_000 - 96 * .pi, accuracy: 1e-3)
        try assertHoleIdentity(reopened, featureID, sketchID: circle.sketchID,
                               entityID: circle.entityID)
        XCTAssertEqual(try XCTUnwrap(reopened.session.document.planes.first {
            $0.id.raw.uuidString == planeID
        }).plane.origin.y, 16, accuracy: 1e-6)
        let reopenedFloor = planar(try XCTUnwrap(body(reopened, bodyID)),
                                   depth: 6, inward: SIMD3(0, -1, 0),
                                   entry: SIMD3(50, 16, -30))
        XCTAssertEqual(reopenedFloor.count, 1)
    }

    // MARK: - Small helpers

    /// The hole node behind a query/command id. Its typed kind is the identity
    /// the M12 clause means; the display row alone is not enough.
    private func holeNode(_ document: FloeCADDocument, _ featureID: String) -> FeatureNode? {
        guard let uuid = UUID(uuidString: featureID) else { return nil }
        return document.session.document.features.node(FeatureID(raw: uuid))
    }

    /// Every continued edit must keep the hole feature, its placement profile
    /// and its placement plane. These assertions name the same IDs the graph
    /// replays, not a re-derived row.
    private func assertHoleIdentity(
        _ document: FloeCADDocument, _ featureID: String,
        sketchID: String, entityID: String,
        file: StaticString = #filePath, line: UInt = #line
    ) throws {
        let node = try XCTUnwrap(holeNode(document, featureID), file: file, line: line)
        guard case let .hole(_, profile, plane, _) = node.kind else {
            return XCTFail("feature \(featureID) lost its hole kind", file: file, line: line)
        }
        XCTAssertEqual(profile.sketchID.raw.uuidString, sketchID, file: file, line: line)
        XCTAssertEqual(profile.entityIDs.map(\.uuidString), [entityID], file: file, line: line)
        let sketchUUID = try XCTUnwrap(UUID(uuidString: sketchID), file: file, line: line)
        XCTAssertEqual(plane, PlaneRef(source: .sketch(SketchID(raw: sketchUUID))),
                       "the hole must stay on its original placement sketch",
                       file: file, line: line)
    }

    private func centroidX(_ faces: [OCCTKernel.KernelFaceInfo]) -> Double {
        let area = faces.reduce(0) { $0 + $1.area }
        guard area > 0 else { return .nan }
        return faces.reduce(0) { $0 + $1.centroid.x * $1.area } / area
    }

    /// A real discovery row for the named planar face; `datum.offsetPlane.create`
    /// needs its current 1-based kernel index and generation token.
    private func faceRow(
        _ document: FloeCADDocument, bodyID: String, normal: SIMD3<Double>,
        file: StaticString = #filePath, line: UInt = #line
    ) throws -> [String: Any] {
        let outcome = document.nativeQueryJSON(["scope": "faces", "limit": 500])
        XCTAssertTrue(outcome.isOK, outcome.message ?? "", file: file, line: line)
        let rows = try XCTUnwrap(payload(outcome)["rows"] as? [[String: Any]],
                                 file: file, line: line)
        return try XCTUnwrap(rows.first { row in
            guard (row["bodyID"] as? String) == bodyID,
                  let vector = row["normal"] as? [Double], vector.count == 3 else { return false }
            return simd_dot(SIMD3(vector[0], vector[1], vector[2]), normal) > 0.999
        }, "no planar face with the requested outward normal", file: file, line: line)
    }

    private func snapshotBodies(_ document: FloeCADDocument) -> [[String: Any]]? {
        guard let object = (try? JSONSerialization.jsonObject(with: document.snapshotJSON()))
                as? [String: Any] else { return nil }
        return object["bodies"] as? [[String: Any]]
    }

    /// A fixed schema-2 reader: it has no hole kind and no format-3 gate. It
    /// deliberately does NOT decode `kind` at all, matching a pre-hole build
    /// that preserved the raw feature bytes it could not understand.
    private struct SchemaTwoFeatureRowReader: Decodable {
        let featureID: UUID
        let orderIndex: Int
        let name: String
        let suppressed: Bool
        private enum CodingKeys: String, CodingKey {
            case featureID, orderIndex, name, suppressed
        }
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            featureID = try c.decode(UUID.self, forKey: .featureID)
            orderIndex = try c.decode(Int.self, forKey: .orderIndex)
            name = try c.decode(String.self, forKey: .name)
            suppressed = try c.decode(Bool.self, forKey: .suppressed)
        }
        static func sessionAllowsWrite(schema: Int) -> Bool { schema <= 2 }
    }

    private enum SchemaTwoKindNameReader {
        static let known: Set<String> = [
            "primitive", "extrude", "draftExtrude", "revolve", "sweep", "loft",
            "boolean", "transform", "mirror", "pattern", "pushPull", "moveFace",
            "scaleFace", "rotateFace", "draftFace", "chamfer", "fillet", "shell",
            "deleteFace", "replaceFace",
        ]
        static func supports(_ data: Data) -> Bool {
            guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  object.count == 1, let name = object.keys.first else { return false }
            return known.contains(name)
        }
    }
}
