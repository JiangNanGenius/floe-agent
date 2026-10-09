//
//  CADAssemblyTests.swift
//  FloeCADKitTests
//
//  Contract tests for `CADAssemblyService`: shared vs independent copies,
//  solver projections (coaxial, distance, conflicts), invalid-reference
//  refusal, approximate DOF, interference exactness, source-revision tracking
//  and package persistence. All geometry is built through the typed command
//  vocabulary the AI tool uses (see PlateHoleFixtureTests).
//

import XCTest
import simd
@testable import FloeCAD

final class CADAssemblyTests: XCTestCase {

    private var workDir: URL!
    private var document: FloeCADDocument!

    override func setUp() async throws {
        workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("FloeCADAssembly-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
        document = try await FloeCADDocument.create(
            at: workDir.appendingPathComponent("assembly.floecad"), name: "Assembly")
    }

    override func tearDown() async throws {
        document?.close()
        if let workDir { try? FileManager.default.removeItem(at: workDir) }
    }

    // MARK: - Helpers

    private func service() -> CADAssemblyService {
        CADAssemblyService(document: document)
    }

    @discardableResult
    private func run(_ json: String, file: StaticString = #filePath,
                     line: UInt = #line) -> [String: Any] {
        let outcome = document.executeJSON(Data(json.utf8))
        XCTAssertTrue(outcome.isOK,
                      "command failed (\(outcome.status)) \(outcome.errorCode ?? ""): "
                        + "\(outcome.message ?? "") — \(json)",
                      file: file, line: line)
        return (try? JSONSerialization.jsonObject(with: outcome.payload)) as? [String: Any] ?? [:]
    }

    /// One extruded rectangular box: rect [min..max] on the ground plane,
    /// extruded +Y by `height`. Returns the live body UUID. Ground-plane rect
    /// (u,v) maps to world (x=u, z=-v), so overlaps in rect space overlap in
    /// world XZ.
    private func makeBox(min: [Double], max: [Double], height: Double) throws -> String {
        let sketch = try XCTUnwrap(
            run(#"{"op":"sketch.create","args":{"name":"Box"}}"#)["sketchID"] as? String)
        _ = run("""
        {"op":"sketch.addEntities","args":{"sketchID":"\(sketch)",
         "entities":[{"kind":"rect","min":[\(min[0]),\(min[1])],"max":[\(max[0]),\(max[1])]}]}}
        """)
        let seedX = (min[0] + max[0]) / 2
        let seedY = (min[1] + max[1]) / 2
        let response = run("""
        {"op":"feature.extrude","args":{"sketchID":"\(sketch)","seedPoint":[\(seedX),\(seedY)],
         "distance":\(height)}}
        """)
        let produced = (response["producedBodyIDs"] as? [String])?.first
        let changed = (response["changedBodyIDs"] as? [String])?.first
        return try XCTUnwrap(produced ?? changed, "extrude returned no body: \(response)")
    }

    private func addInstance(_ service: CADAssemblyService, bodyID: String,
                             name: String? = nil,
                             position: [Double]? = nil,
                             rotation: [Double]? = nil,
                             independentCopy: Bool = false) throws -> String {
        var args: [String: Any] = ["bodyID": bodyID]
        if let name { args["name"] = name }
        if position != nil || rotation != nil {
            var transform: [String: Any] = [:]
            if let position { transform["position"] = position }
            if let rotation { transform["rotation"] = rotation }
            args["transform"] = transform
        }
        if independentCopy { args["independentCopy"] = true }
        let response = service.handle(action: "addInstance", args: args)
        XCTAssertEqual(response["ok"] as? Bool, true, "addInstance refused: \(response)")
        return try XCTUnwrap(response["id"] as? String)
    }

    private func position(of entry: [String: Any]) throws -> SIMD3<Double> {
        let transform = try XCTUnwrap(entry["transform"] as? [String: Any])
        let values = try XCTUnwrap(transform["position"] as? [Double])
        XCTAssertEqual(values.count, 3)
        return SIMD3(values[0], values[1], values[2])
    }

    /// World direction of an instance's local +Z reference axis.
    private func direction(of entry: [String: Any]) throws -> SIMD3<Double> {
        let transform = try XCTUnwrap(entry["transform"] as? [String: Any])
        let rotation = try XCTUnwrap(transform["rotation"] as? [Double])
        XCTAssertEqual(rotation.count, 4)
        let quaternion = simd_quatd(ix: rotation[0], iy: rotation[1],
                                    iz: rotation[2], r: rotation[3])
        return quaternion.act(SIMD3<Double>(0, 0, 1))
    }

    private func instanceEntry(_ report: [String: Any], id: String,
                               file: StaticString = #filePath, line: UInt = #line)
        throws -> [String: Any] {
        let instances = try XCTUnwrap(report["instances"] as? [[String: Any]],
                                      file: file, line: line)
        return try XCTUnwrap(instances.first { $0["id"] as? String == id },
                             "instance \(id) missing from report", file: file, line: line)
    }

    /// Replace a body's geometry with a B-rep-less copy of the same render
    /// mesh, through the document's own lifecycle command (the same path every
    /// geometry edit uses). This is the honest way to obtain a mesh-only body.
    private func stripBrep(from bodyID: String) throws {
        let uuid = try XCTUnwrap(UUID(uuidString: bodyID))
        let body = try XCTUnwrap(document.session.document.bodies.first { $0.id.raw == uuid })
        var meshOnly = Body(id: body.id, name: body.name, transform: body.transform,
                            primitive: body.primitive, render: body.render,
                            revision: body.meshRevision)
        meshOnly.material = body.material
        meshOnly.isHidden = body.isHidden
        document.session.perform(ReplaceBodyCommand(title: "Test Mesh Only",
                                                    before: body, after: meshOnly))
    }

    // MARK: - Tests

    func testAddInstanceSharedAndIndependentCopy() throws {
        let bodyID = try makeBox(min: [0, 0], max: [10, 10], height: 10)
        let service = service()
        let bodiesBefore = document.session.document.bodies.count

        let shared = service.handle(action: "addInstance",
                                    args: ["bodyID": bodyID, "name": "Shared"])
        XCTAssertEqual(shared["ok"] as? Bool, true)
        XCTAssertEqual(shared["mutated"] as? Bool, true)
        XCTAssertNil(shared["copiedBodyID"],
                     "a shared instance must not record a copied body")
        XCTAssertEqual(document.session.document.bodies.count, bodiesBefore,
                       "a shared instance must reference the existing body, not duplicate it")

        let copy = service.handle(action: "addInstance",
                                  args: ["bodyID": bodyID, "name": "Copy",
                                         "independentCopy": true])
        XCTAssertEqual(copy["ok"] as? Bool, true)
        XCTAssertEqual(document.session.document.bodies.count, bodiesBefore + 1,
                       "an independent copy must create a distinct body")
        let copiedBodyID = try XCTUnwrap(copy["copiedBodyID"] as? String)
        XCTAssertNotEqual(copiedBodyID, bodyID)
        let copiedUUID = try XCTUnwrap(UUID(uuidString: copiedBodyID))
        let copiedBody = document.session.document.bodies.first { $0.id.raw == copiedUUID }
        XCTAssertNotNil(copiedBody)
        XCTAssertNotNil(copiedBody?.brep, "the independent copy must keep the analytic B-rep")

        // Both instances place the shared definition for a shared instance and
        // the owned copy for an independent one.
        XCTAssertEqual(shared["bodyID"] as? String, bodyID)
        XCTAssertEqual(copy["bodyID"] as? String, bodyID)
    }

    func testCoaxialSolveMakesAxesCollinear() throws {
        let bodyA = try makeBox(min: [0, 0], max: [10, 10], height: 10)
        let bodyB = try makeBox(min: [0, 0], max: [10, 10], height: 10)
        let service = service()
        let a = try addInstance(service, bodyID: bodyA, name: "A")
        // B starts offset AND tilted (90° about X), so the solve must rotate
        // its axis as well as translate it onto A's line.
        let b = try addInstance(service, bodyID: bodyB, name: "B",
                                position: [5, 2, 0],
                                rotation: [0.7071067811865476, 0, 0, 0.7071067811865476])

        let added = service.handle(action: "addConstraint", args: [
            "kind": "coaxial", "instanceA": a, "instanceB": b,
            "directionA": [0.0, 0.0, 1.0], "directionB": [0.0, 0.0, 1.0],
        ])
        XCTAssertEqual(added["ok"] as? Bool, true)

        let solved = service.handle(action: "solve", args: [:])
        XCTAssertEqual(solved["ok"] as? Bool, true)
        XCTAssertEqual(solved["solved"] as? Bool, true)

        let report = service.handle(action: "report", args: [:])
        let entryA = try instanceEntry(report, id: a)
        let entryB = try instanceEntry(report, id: b)
        let axisA = try direction(of: entryA)
        let axisB = try direction(of: entryB)
        XCTAssertEqual(simd_length(simd_cross(axisA, axisB)), 0, accuracy: 1e-6,
                       "coaxial solve must make the axes parallel")
        let pinA = try position(of: entryA)
        let pinB = try position(of: entryB)
        let offset = pinB - pinA
        let perpendicular = offset - simd_dot(offset, axisA) * axisA
        XCTAssertEqual(simd_length(perpendicular), 0, accuracy: 1e-6,
                       "coaxial solve must remove the point-axis distance")
    }

    func testDistanceConstraintSetsPointDistance() throws {
        let bodyA = try makeBox(min: [0, 0], max: [10, 10], height: 10)
        let bodyB = try makeBox(min: [0, 0], max: [10, 10], height: 10)
        let service = service()
        let a = try addInstance(service, bodyID: bodyA, name: "A")
        let b = try addInstance(service, bodyID: bodyB, name: "B", position: [5, 0, 0])

        let added = service.handle(action: "addConstraint", args: [
            "kind": "distance", "instanceA": a, "instanceB": b, "value": 25.0,
        ])
        XCTAssertEqual(added["ok"] as? Bool, true)

        let solved = service.handle(action: "solve", args: [:])
        XCTAssertEqual(solved["solved"] as? Bool, true)

        let report = service.handle(action: "report", args: [:])
        let pinA = try position(of: instanceEntry(report, id: a))
        let pinB = try position(of: instanceEntry(report, id: b))
        let separation = pinB - pinA
        XCTAssertEqual(simd_length(separation), 25.0, accuracy: 1e-6,
                       "distance constraint must set |pB - pA| to the requested value")
    }

    func testConflictingDistanceConstraintsReportedWithoutCorruption() throws {
        let bodyA = try makeBox(min: [0, 0], max: [10, 10], height: 10)
        let bodyB = try makeBox(min: [0, 0], max: [10, 10], height: 10)
        let service = service()
        let a = try addInstance(service, bodyID: bodyA, name: "A")
        let b = try addInstance(service, bodyID: bodyB, name: "B", position: [5, 0, 0])

        let first = service.handle(action: "addConstraint", args: [
            "kind": "distance", "instanceA": a, "instanceB": b, "value": 10.0,
        ])
        let second = service.handle(action: "addConstraint", args: [
            "kind": "distance", "instanceA": a, "instanceB": b, "value": 20.0,
        ])
        let firstID = try XCTUnwrap(first["id"] as? String)
        let secondID = try XCTUnwrap(second["id"] as? String)

        let solved = service.handle(action: "solve", args: [:])
        XCTAssertEqual(solved["ok"] as? Bool, true)
        XCTAssertEqual(solved["solved"] as? Bool, false,
                       "contradictory distances cannot solve")
        let conflicting = try XCTUnwrap(solved["conflicting"] as? [String])
        XCTAssertFalse(conflicting.isEmpty)
        XCTAssertTrue(conflicting.contains(firstID) || conflicting.contains(secondID))

        // "As close as it got", not half-written: the persisted assembly still
        // decodes and every placement is a finite transform.
        let stored = try CADAssembly.decode(from: document.session.document.assemblyData)
        XCTAssertEqual(stored.instances.count, 2)
        for instance in stored.instances {
            XCTAssertTrue(instance.transform.position.x.isFinite)
            XCTAssertTrue(instance.transform.position.y.isFinite)
            XCTAssertTrue(instance.transform.position.z.isFinite)
            XCTAssertTrue(instance.transform.rotation.x.isFinite)
        }
    }

    func testInvalidInstanceReferenceRefusedWithoutMutation() throws {
        let bodyA = try makeBox(min: [0, 0], max: [10, 10], height: 10)
        let service = service()
        let a = try addInstance(service, bodyID: bodyA, name: "A")
        let before = document.session.document.assemblyData

        let unknownInstance = service.handle(action: "addConstraint", args: [
            "kind": "coaxial", "instanceA": a, "instanceB": UUID().uuidString,
            "directionA": [0.0, 0.0, 1.0], "directionB": [0.0, 0.0, 1.0],
        ])
        XCTAssertEqual(unknownInstance["ok"] as? Bool, false)
        XCTAssertEqual(unknownInstance["error"] as? String, "unknown_instance")

        let zeroDirection = service.handle(action: "addConstraint", args: [
            "kind": "coaxial", "instanceA": a, "instanceB": a,
            "directionA": [0.0, 0.0, 1.0], "directionB": [0.0, 0.0, 0.0],
        ])
        XCTAssertEqual(zeroDirection["ok"] as? Bool, false)
        XCTAssertEqual(zeroDirection["error"] as? String, "zero_direction")

        let negativeDistance = service.handle(action: "addConstraint", args: [
            "kind": "distance", "instanceA": a, "instanceB": a, "value": -1.0,
        ])
        XCTAssertEqual(negativeDistance["ok"] as? Bool, false)
        XCTAssertEqual(negativeDistance["error"] as? String, "bad_value")

        XCTAssertEqual(document.session.document.assemblyData, before,
                       "a refused constraint must not touch the persisted assembly")
        let stored = try CADAssembly.decode(from: document.session.document.assemblyData)
        XCTAssertTrue(stored.constraints.isEmpty)
    }

    func testDegreesOfFreedomFixedAndFree() throws {
        let bodyA = try makeBox(min: [0, 0], max: [10, 10], height: 10)
        let bodyB = try makeBox(min: [20, 20], max: [30, 30], height: 10)
        let service = service()
        let a = try addInstance(service, bodyID: bodyA, name: "A")
        let b = try addInstance(service, bodyID: bodyB, name: "B", position: [20, 0, 0])

        let free = service.handle(action: "dof", args: [:])
        XCTAssertEqual(free["ok"] as? Bool, true)
        XCTAssertEqual(free["dofModel"] as? String, "approximate")
        XCTAssertEqual(free["assemblyDOF"] as? Int, 12, "two free instances report 6 DOF each")

        let fixed = service.handle(action: "addConstraint",
                                   args: ["kind": "fixed", "instanceA": a])
        XCTAssertEqual(fixed["ok"] as? Bool, true)

        let report = service.handle(action: "dof", args: [:])
        XCTAssertEqual(report["assemblyDOF"] as? Int, 6)
        let rows = try XCTUnwrap(report["instances"] as? [[String: Any]])
        XCTAssertEqual(rows.first { $0["id"] as? String == a }?["dof"] as? Int, 0,
                       "a fixed instance reports 0 DOF")
        XCTAssertEqual(rows.first { $0["id"] as? String == b }?["dof"] as? Int, 6,
                       "an unconstrained non-fixed instance reports 6 DOF")
        let unconstrained = try XCTUnwrap(report["unconstrainedInstances"] as? [String])
        XCTAssertTrue(unconstrained.contains(b))
        XCTAssertFalse(unconstrained.contains(a))
    }

    func testInterferenceOverlapDisjointAndMeshOnly() async throws {
        let bodyA = try makeBox(min: [0, 0], max: [10, 10], height: 10)
        let bodyB = try makeBox(min: [5, 5], max: [15, 15], height: 10)
        let bodyC = try makeBox(min: [40, 40], max: [50, 50], height: 10)
        let service = service()
        let a = try addInstance(service, bodyID: bodyA, name: "A")
        let b = try addInstance(service, bodyID: bodyB, name: "B")
        let c = try addInstance(service, bodyID: bodyC, name: "C")

        // The exact worker must run the OCCT common off the main actor, on
        // owned deserialized copies; the probe records the observed thread.
        let probe = AssemblyOffMainProbe()
        CADAssemblyService.testOffMainProbe = { probe.record() }
        defer { CADAssemblyService.testOffMainProbe = nil }

        let exact = await service.handleAsync(action: "interference", args: ["toleranceMM": 1e-6])
        XCTAssertEqual(exact["ok"] as? Bool, true)
        XCTAssertGreaterThan(probe.calls, 0, "the exact worker must have run")
        XCTAssertTrue(probe.ranOffMain,
                      "exact OCCT interference must not execute on the main actor")
        let exactEntries = try XCTUnwrap(exact["interferences"] as? [[String: Any]])
        let overlap = try XCTUnwrap(exactEntries.first { entry in
            Set([entry["a"] as? String ?? "", entry["b"] as? String ?? ""]) == Set([a, b])
        }, "overlapping boxes must be reported: \(exactEntries)")
        XCTAssertEqual(overlap["exact"] as? Bool, true)
        // 5 (x) × 10 (y) × 5 (z) mm common volume.
        XCTAssertEqual(try XCTUnwrap(overlap["volumeMM3"] as? Double), 250.0, accuracy: 1e-6)
        XCTAssertFalse(exactEntries.contains { entry in
            (entry["a"] as? String) == c || (entry["b"] as? String) == c
        }, "the disjoint instance must not be reported")

        // Mesh-only body: the pair downgrades to an AABB approximation and
        // must never claim exactness.
        try stripBrep(from: bodyB)
        let approximate = await service.handleAsync(action: "interference", args: ["toleranceMM": 1e-6])
        let approximateEntries = try XCTUnwrap(approximate["interferences"] as? [[String: Any]])
        let meshPair = try XCTUnwrap(approximateEntries.first { entry in
            Set([entry["a"] as? String ?? "", entry["b"] as? String ?? ""]) == Set([a, b])
        }, "mesh-only AABB overlap must still be reported: \(approximateEntries)")
        XCTAssertEqual(meshPair["exact"] as? Bool, false)
        XCTAssertEqual(meshPair["approximation"] as? String, "mesh")
    }

    func testSourceUpdateDetectsAndClearsStaleRevision() throws {
        let bodyID = try makeBox(min: [0, 0], max: [10, 10], height: 10)
        let service = service()
        let a = try addInstance(service, bodyID: bodyID, name: "A")

        let clean = service.handle(action: "sourceUpdate", args: [:])
        XCTAssertEqual(clean["ok"] as? Bool, true)
        XCTAssertEqual((clean["stale"] as? [String])?.isEmpty, true)

        // Edit the source body through the document's own geometry-swap
        // command; it re-mints meshRevision exactly like a rebuild does.
        let uuid = try XCTUnwrap(UUID(uuidString: bodyID))
        let body = try XCTUnwrap(document.session.document.bodies.first { $0.id.raw == uuid })
        var edited = Body(id: body.id, name: body.name, transform: body.transform,
                          primitive: body.primitive, render: body.render,
                          revision: body.meshRevision)
        edited.brep = body.brep
        document.session.perform(ReplaceBodyCommand(title: "Source Edit",
                                                    before: body, after: edited))

        let stale = service.handle(action: "sourceUpdate", args: [:])
        XCTAssertEqual(stale["mutated"] as? Bool, false)
        XCTAssertEqual(stale["stale"] as? [String], [a],
                       "the edited source body must be detected as stale")

        let applied = service.handle(action: "sourceUpdate", args: ["apply": true])
        XCTAssertEqual(applied["ok"] as? Bool, true)
        XCTAssertEqual(applied["mutated"] as? Bool, true)
        XCTAssertEqual((applied["stale"] as? [String])?.isEmpty, true,
                       "apply:true refreshes the recorded revision")

        let after = service.handle(action: "sourceUpdate", args: [:])
        XCTAssertEqual((after["stale"] as? [String])?.isEmpty, true)
    }

    func testAssemblyPersistsAcrossSaveAndReopen() async throws {
        let bodyA = try makeBox(min: [0, 0], max: [10, 10], height: 10)
        let bodyB = try makeBox(min: [20, 20], max: [30, 30], height: 10)
        let service = service()
        let a = try addInstance(service, bodyID: bodyA, name: "Base")
        let b = try addInstance(service, bodyID: bodyB, name: "Moved", position: [20, 0, 0])
        let added = service.handle(action: "addConstraint", args: [
            "kind": "distance", "instanceA": a, "instanceB": b, "value": 42.0,
        ])
        XCTAssertEqual(added["ok"] as? Bool, true)
        _ = service.handle(action: "solve", args: [:])

        let save = await document.save()
        XCTAssertTrue(save.succeeded, "save failed: \(save.error ?? "")")
        document.close()

        let reopened = try await FloeCADDocument.open(
            at: workDir.appendingPathComponent("assembly.floecad"))
        let reopenedService = CADAssemblyService(document: reopened)
        let report = reopenedService.handle(action: "report", args: [:])
        XCTAssertEqual(report["ok"] as? Bool, true)
        XCTAssertEqual(report["instanceCount"] as? Int, 2)
        XCTAssertEqual(report["constraintCount"] as? Int, 1)
        let constraints = try XCTUnwrap(report["constraints"] as? [[String: Any]])
        XCTAssertEqual(constraints.first?["kind"] as? String, "distance")
        XCTAssertEqual(constraints.first?["value"] as? Double, 42.0)
        reopened.close()
    }
}

/// Records whether the in-worker probe observed a non-main thread. Test-only.
private final class AssemblyOffMainProbe: @unchecked Sendable {
    private let lock = NSLock()
    private(set) var calls = 0
    private(set) var ranOffMain = false

    func record() {
        lock.lock()
        calls += 1
        if !Thread.isMainThread { ranOffMain = true }
        lock.unlock()
    }
}
