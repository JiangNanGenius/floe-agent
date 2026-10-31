//
//  CADAssemblyConstraintEditingTests.swift
//  FloeCADKitTests
//
//  Contract tests for editing an EXISTING assembly constraint in place:
//  stable ConstraintID/instance pair/geometry references, exact mm/degree
//  units, one-step undo/redo, save/reopen, nested local scopes, transactional
//  conflict rollback, and credible rank/solver DOF at the 64/128 boundary.
//

import XCTest
import simd
@testable import FloeCAD

@MainActor
final class CADAssemblyConstraintEditingTests: XCTestCase {

    private var workDir: URL!
    private var document: FloeCADDocument!

    override func setUp() async throws {
        workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("FloeCADConstraintEditing-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
        document = try await FloeCADDocument.create(
            at: workDir.appendingPathComponent("editing.floecad"), name: "Editing")
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

    /// One extruded rectangular box, same deterministic geometry path used by
    /// the existing assembly contract tests.
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
                             name: String, position: [Double] = [0, 0, 0],
                             parentID: String? = nil) throws -> String {
        var args: [String: Any] = [
            "bodyID": bodyID,
            "name": name,
            "transform": ["position": position],
        ]
        if let parentID { args["parentID"] = parentID }
        let response = service.handle(action: "addInstance", args: args)
        XCTAssertEqual(response["ok"] as? Bool, true, "addInstance refused: \(response)")
        return try XCTUnwrap(response["id"] as? String)
    }

    private func addSubassembly(_ service: CADAssemblyService, name: String,
                                parentID: String? = nil) throws -> String {
        var args: [String: Any] = ["name": name]
        if let parentID { args["parentID"] = parentID }
        let response = service.handle(action: "addSubassembly", args: args)
        XCTAssertEqual(response["ok"] as? Bool, true, "addSubassembly refused: \(response)")
        return try XCTUnwrap(response["id"] as? String)
    }

    private func assembly() throws -> CADAssembly {
        try CADAssembly.decode(from: document.session.document.assemblyData)
    }

    private func constraintRow(_ report: [String: Any], id: String,
                               file: StaticString = #filePath,
                               line: UInt = #line) throws -> [String: Any] {
        let rows = try XCTUnwrap(report["constraints"] as? [[String: Any]],
                                 file: file, line: line)
        return try XCTUnwrap(rows.first { $0["id"] as? String == id },
                             "constraint \(id) missing from report", file: file, line: line)
    }

    private func instanceRow(_ report: [String: Any], id: String,
                             file: StaticString = #filePath,
                             line: UInt = #line) throws -> [String: Any] {
        let rows = try XCTUnwrap(report["instances"] as? [[String: Any]],
                                 file: file, line: line)
        return try XCTUnwrap(rows.first { $0["id"] as? String == id },
                             "instance \(id) missing from report", file: file, line: line)
    }

    private func position(_ row: [String: Any]) throws -> SIMD3<Double> {
        let transform = try XCTUnwrap(row["transform"] as? [String: Any])
        let values = try XCTUnwrap(transform["position"] as? [Double])
        XCTAssertEqual(values.count, 3)
        return SIMD3(values[0], values[1], values[2])
    }

    private func direction(_ row: [String: Any]) throws -> SIMD3<Double> {
        let transform = try XCTUnwrap(row["transform"] as? [String: Any])
        let values = try XCTUnwrap(transform["rotation"] as? [Double])
        XCTAssertEqual(values.count, 4)
        let quaternion = simd_quatd(ix: values[0], iy: values[1],
                                    iz: values[2], r: values[3])
        return quaternion.act(SIMD3<Double>(0, 0, 1))
    }

    private func separation(_ report: [String: Any], _ a: String, _ b: String) throws -> Double {
        simd_length(try position(instanceRow(report, id: b))
                    - position(instanceRow(report, id: a)))
    }

    private func vector(_ value: Any?) -> SIMD3<Double>? {
        guard let values = value as? [Double], values.count == 3 else { return nil }
        return SIMD3(values[0], values[1], values[2])
    }

    private func revision(_ value: Any?) -> UInt64? {
        if let value = value as? UInt64 { return value }
        if let value = value as? NSNumber { return value.uint64Value }
        if let value = value as? Int, value >= 0 { return UInt64(value) }
        return nil
    }

    // MARK: - E05: edit an existing distance

    func testBooleanArgumentsCannotBecomeDimensionsOrReferenceCoordinates() async throws {
        let bodyA = try makeBox(min: [0, 0], max: [10, 10], height: 10)
        let bodyB = try makeBox(min: [20, 20], max: [30, 30], height: 10)
        let service = service()
        let a = try addInstance(service, bodyID: bodyA, name: "A")
        let b = try addInstance(service, bodyID: bodyB, name: "B", position: [10, 0, 0])
        let added = service.handle(action: "addConstraint", args: [
            "kind": "distance", "instanceA": a, "instanceB": b, "value": 10.0,
        ])
        XCTAssertEqual(added["ok"] as? Bool, true)
        let id = try XCTUnwrap(added["id"] as? String)
        let saved = await document.save()
        XCTAssertTrue(saved.succeeded, saved.error ?? "")
        let packageJSON = workDir.appendingPathComponent("editing.floecad/document.json")
        let stored = try Data(contentsOf: packageJSON)
        let before = document.session.document.assemblyData
        let changeCount = document.session.changeCount
        let malformed = [
            (#"{"value":true}"#, "bad_value"),
            (#"{"expectedValue":true,"value":15}"#, "bad_expected_value"),
            (#"{"pointA":[true,0,0]}"#, "bad_vector"),
        ]
        for (json, code) in malformed {
            var args = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
            args["id"] = id
            let reply = service.handle(action: "updateConstraint", args: args)
            XCTAssertEqual(reply["ok"] as? Bool, false, "\(reply)")
            XCTAssertEqual(reply["error"] as? String, code, "\(reply)")
            XCTAssertEqual(document.session.document.assemblyData, before)
            XCTAssertEqual(document.session.changeCount, changeCount)
            XCTAssertEqual(try Data(contentsOf: packageJSON), stored)
        }
    }

    func testEditExistingDistancePreservesIDReferencesUndoRedoAndReopen() async throws {
        let bodyA = try makeBox(min: [0, 0], max: [10, 10], height: 10)
        let bodyB = try makeBox(min: [20, 20], max: [30, 30], height: 10)
        let service = service()
        let a = try addInstance(service, bodyID: bodyA, name: "A")
        let b = try addInstance(service, bodyID: bodyB, name: "B", position: [10, 0, 0])

        let added = service.handle(action: "addConstraint", args: [
            "kind": "distance", "instanceA": a, "instanceB": b, "value": 10.0,
        ])
        XCTAssertEqual(added["ok"] as? Bool, true, "\(added)")
        let constraintID = try XCTUnwrap(added["id"] as? String)
        XCTAssertEqual(service.handle(action: "solve", args: [:])["solved"] as? Bool, true)

        let before = service.handle(action: "report", args: [:])
        let beforeRow = try constraintRow(before, id: constraintID)
        let pointABefore = try XCTUnwrap(vector(beforeRow["pointA"]))
        let directionABefore = try XCTUnwrap(vector(beforeRow["directionA"]))
        let pointBBefore = try XCTUnwrap(vector(beforeRow["pointB"]))
        let directionBBefore = try XCTUnwrap(vector(beforeRow["directionB"]))
        let revisionABefore = revision(beforeRow["sourceRevisionA"])
        let revisionBBefore = revision(beforeRow["sourceRevisionB"])
        XCTAssertEqual(try separation(before, a, b), 10.0, accuracy: 1e-6)

        // A stale query fence must refuse before any write.
        let changesBeforeStale = document.session.changeCount
        let stale = service.handle(action: "updateConstraint", args: [
            "id": constraintID, "value": 17.0, "expectedValue": 11.0,
        ])
        XCTAssertEqual(stale["ok"] as? Bool, false)
        XCTAssertEqual(stale["error"] as? String, "stale_constraint")
        XCTAssertEqual(document.session.changeCount, changesBeforeStale)

        let changesBefore = document.session.changeCount
        let updated = service.handle(action: "updateConstraint", args: [
            "id": constraintID, "value": 15.0, "expectedValue": 10.0,
        ])
        XCTAssertEqual(updated["ok"] as? Bool, true, "\(updated)")
        XCTAssertEqual(updated["mutated"] as? Bool, true)
        XCTAssertEqual(updated["solved"] as? Bool, true)
        XCTAssertEqual(updated["constraintID"] as? String, constraintID)
        XCTAssertEqual(updated["value"] as? Double, 15.0)
        XCTAssertEqual(updated["valueUnit"] as? String, "mm")
        XCTAssertEqual(document.session.changeCount, changesBefore + 1,
                       "the edit and solved placement must be exactly one undo step")

        let after = service.handle(action: "report", args: [:])
        let afterRow = try constraintRow(after, id: constraintID)
        XCTAssertEqual(afterRow["id"] as? String, constraintID)
        XCTAssertEqual(afterRow["value"] as? Double, 15.0)
        XCTAssertEqual(try XCTUnwrap(vector(afterRow["pointA"])), pointABefore)
        XCTAssertEqual(try XCTUnwrap(vector(afterRow["directionA"])), directionABefore)
        XCTAssertEqual(try XCTUnwrap(vector(afterRow["pointB"])), pointBBefore)
        XCTAssertEqual(try XCTUnwrap(vector(afterRow["directionB"])), directionBBefore)
        XCTAssertEqual(revision(afterRow["sourceRevisionA"]), revisionABefore)
        XCTAssertEqual(revision(afterRow["sourceRevisionB"]), revisionBBefore)
        XCTAssertEqual(try separation(after, a, b), 15.0, accuracy: 1e-6)

        document.session.undo()
        let undone = service.handle(action: "report", args: [:])
        let undoneRow = try constraintRow(undone, id: constraintID)
        XCTAssertEqual(undoneRow["value"] as? Double, 10.0)
        XCTAssertEqual(try separation(undone, a, b), 10.0, accuracy: 1e-6)
        XCTAssertEqual(undoneRow["pointA"] as? [Double], beforeRow["pointA"] as? [Double])

        document.session.redo()
        let redone = service.handle(action: "report", args: [:])
        XCTAssertEqual(try constraintRow(redone, id: constraintID)["value"] as? Double, 15.0)
        XCTAssertEqual(try separation(redone, a, b), 15.0, accuracy: 1e-6)

        let save = await document.save()
        XCTAssertTrue(save.succeeded, save.error ?? "")
        document.close()
        document = try await FloeCADDocument.open(
            at: workDir.appendingPathComponent("editing.floecad"))
        let reopened = service().handle(action: "report", args: [:])
        let reopenedRow = try constraintRow(reopened, id: constraintID)
        XCTAssertEqual(reopenedRow["value"] as? Double, 15.0)
        XCTAssertEqual(reopenedRow["pointA"] as? [Double], beforeRow["pointA"] as? [Double])
        XCTAssertEqual(try separation(reopened, a, b), 15.0, accuracy: 1e-6)
    }

    // MARK: - E06: contradiction leaves file/undo/geometry untouched

    func testConflictingEditIsTransactionalThenSolveAndDOFAgree() throws {
        let bodyA = try makeBox(min: [0, 0], max: [10, 10], height: 10)
        let bodyB = try makeBox(min: [20, 20], max: [30, 30], height: 10)
        let service = service()
        let a = try addInstance(service, bodyID: bodyA, name: "A")
        let b = try addInstance(service, bodyID: bodyB, name: "B", position: [10, 0, 0])

        let first = service.handle(action: "addConstraint", args: [
            "kind": "distance", "instanceA": a, "instanceB": b, "value": 10.0,
        ])
        let second = service.handle(action: "addConstraint", args: [
            "kind": "distance", "instanceA": a, "instanceB": b, "value": 20.0,
        ])
        let firstID = try XCTUnwrap(first["id"] as? String)
        let secondID = try XCTUnwrap(second["id"] as? String)

        let beforeData = try XCTUnwrap(document.session.document.assemblyData)
        let beforeChanges = document.session.changeCount
        let beforeRevision = document.store.revision
        let beforeUndo = document.session.undoStack.undoCommands.count

        let refused = service.handle(action: "updateConstraint", args: [
            "id": firstID, "value": 15.0, "expectedValue": 10.0,
        ])
        XCTAssertEqual(refused["ok"] as? Bool, false)
        XCTAssertEqual(refused["error"] as? String, "constraint_failed")
        XCTAssertEqual(refused["mutated"] as? Bool, false)
        XCTAssertEqual(refused["solved"] as? Bool, false)
        XCTAssertNotNil(refused["previewInstances"])
        let refusedConflicts = try XCTUnwrap(refused["conflicting"] as? [String])
        XCTAssertFalse(refusedConflicts.isEmpty)

        XCTAssertEqual(document.session.document.assemblyData, beforeData,
                       "a contradictory edit must not touch the persisted assembly")
        XCTAssertEqual(document.session.changeCount, beforeChanges,
                       "a contradictory edit must not add an undo entry")
        XCTAssertEqual(document.store.revision, beforeRevision,
                       "a contradictory edit must not bump the document revision")
        XCTAssertEqual(document.session.undoStack.undoCommands.count, beforeUndo)

        let unresolvedDOF = service.handle(action: "dof", args: [:])
        XCTAssertEqual(unresolvedDOF["solved"] as? Bool, false)
        XCTAssertEqual(unresolvedDOF["dofCredible"] as? Bool, false)
        XCTAssertEqual(unresolvedDOF["fullyConstrained"] as? Bool, false)
        XCTAssertFalse((unresolvedDOF["conflicting"] as? [String] ?? []).isEmpty)

        // Resolve the conflict explicitly, then edit the surviving mate.
        let suppressed = service.handle(action: "suppressConstraint", args: [
            "id": secondID, "suppressed": true,
        ])
        XCTAssertEqual(suppressed["ok"] as? Bool, true, "\(suppressed)")

        let changesBeforeEdit = document.session.changeCount
        let resolved = service.handle(action: "updateConstraint", args: [
            "id": firstID, "value": 15.0, "expectedValue": 10.0,
        ])
        XCTAssertEqual(resolved["ok"] as? Bool, true, "\(resolved)")
        XCTAssertEqual(resolved["solved"] as? Bool, true)
        XCTAssertEqual(document.session.changeCount, changesBeforeEdit + 1)

        let solved = service.handle(action: "solve", args: [:])
        XCTAssertEqual(solved["ok"] as? Bool, true, "\(solved)")
        XCTAssertEqual(solved["solved"] as? Bool, true)
        XCTAssertEqual(solved["fullyConstrained"] as? Bool, false)

        let dof = service.handle(action: "dof", args: [:])
        XCTAssertEqual(dof["solved"] as? Bool, true)
        XCTAssertEqual(dof["dofCredible"] as? Bool, true)
        XCTAssertEqual(dof["fullyConstrained"] as? Bool, false)
        XCTAssertEqual(dof["conflicting"] as? [String] ?? [], [])
        XCTAssertEqual(dof["assemblyDOF"] as? Int, solved["assemblyDOF"] as? Int,
                       "after resolving the conflict, solve total mobility and DOF must agree")
        XCTAssertEqual(dof["relativeDOF"] as? Int, solved["relativeDOF"] as? Int,
                       "after resolving the conflict, solve relative mobility and DOF must agree")
        XCTAssertEqual(dof["relativeDOF"] as? Int, 5,
                       "one free distance removes one of six relative modes")
    }

    func testLockedInstancesRefuseContradictoryEditWithoutMutation() throws {
        let bodyA = try makeBox(min: [0, 0], max: [10, 10], height: 10)
        let bodyB = try makeBox(min: [20, 20], max: [30, 30], height: 10)
        let service = service()
        let a = try addInstance(service, bodyID: bodyA, name: "A")
        let b = try addInstance(service, bodyID: bodyB, name: "B", position: [10, 0, 0])
        _ = service.handle(action: "addConstraint", args: ["kind": "fixed", "instanceA": a])
        let fixedB = service.handle(action: "addConstraint", args: ["kind": "fixed", "instanceA": b])
        let distance = service.handle(action: "addConstraint", args: [
            "kind": "distance", "instanceA": a, "instanceB": b, "value": 10.0,
        ])
        let fixedBID = try XCTUnwrap(fixedB["id"] as? String)
        let distanceID = try XCTUnwrap(distance["id"] as? String)
        XCTAssertEqual(service.handle(action: "solve", args: [:])["solved"] as? Bool, true)

        let beforeData = try XCTUnwrap(document.session.document.assemblyData)
        let beforeChanges = document.session.changeCount
        let refused = service.handle(action: "updateConstraint", args: [
            "id": distanceID, "value": 15.0, "expectedValue": 10.0,
        ])
        XCTAssertEqual(refused["ok"] as? Bool, false)
        XCTAssertEqual(refused["error"] as? String, "constraint_failed")
        XCTAssertEqual(refused["mutated"] as? Bool, false)
        let conflicts = try XCTUnwrap(refused["conflicting"] as? [String])
        XCTAssertTrue(conflicts.contains(distanceID))
        XCTAssertEqual(document.session.document.assemblyData, beforeData)
        XCTAssertEqual(document.session.changeCount, beforeChanges)

        // Unlocking one side makes the same edit legal and still one step.
        XCTAssertEqual(service.handle(action: "suppressConstraint",
                                      args: ["id": fixedBID, "suppressed": true])["mutated"] as? Bool,
                       true)
        let changesBeforeEdit = document.session.changeCount
        let accepted = service.handle(action: "updateConstraint", args: [
            "id": distanceID, "value": 15.0, "expectedValue": 10.0,
        ])
        XCTAssertEqual(accepted["ok"] as? Bool, true, "\(accepted)")
        XCTAssertEqual(accepted["solved"] as? Bool, true)
        XCTAssertEqual(document.session.changeCount, changesBeforeEdit + 1)
        XCTAssertEqual(service.handle(action: "solve", args: [:])["solved"] as? Bool, true)
        let dof = service.handle(action: "dof", args: [:])
        XCTAssertEqual(dof["solved"] as? Bool, true)
        XCTAssertEqual(dof["dofCredible"] as? Bool, true)
        XCTAssertEqual(dof["relativeDOF"] as? Int, 5)
    }

    // MARK: - Nested local scopes

    func testEditNestedLocalDistanceKeepsScopeIDAndUndo() async throws {
        let bodyA = try makeBox(min: [0, 0], max: [10, 10], height: 10)
        let bodyB = try makeBox(min: [20, 20], max: [30, 30], height: 10)
        let service = service()
        let parent = try addSubassembly(service, name: "Pair")
        let a = try addInstance(service, bodyID: bodyA, name: "A", parentID: parent)
        let b = try addInstance(service, bodyID: bodyB, name: "B", position: [10, 0, 0],
                                parentID: parent)
        let added = service.handle(action: "addConstraint", args: [
            "kind": "distance", "instanceA": a, "instanceB": b,
            "parentID": parent, "value": 10.0,
        ])
        XCTAssertEqual(added["ok"] as? Bool, true, "\(added)")
        let constraintID = try XCTUnwrap(added["id"] as? String)
        XCTAssertEqual(service.handle(action: "solve", args: [:])["solved"] as? Bool, true)

        let changesBefore = document.session.changeCount
        let updated = service.handle(action: "updateConstraint", args: [
            "id": constraintID, "value": 15.0, "expectedValue": 10.0,
        ])
        XCTAssertEqual(updated["ok"] as? Bool, true, "\(updated)")
        XCTAssertEqual(updated["scope"] as? String, "subassembly")
        XCTAssertEqual(updated["parentID"] as? String, parent)
        XCTAssertEqual(updated["constraintID"] as? String, constraintID)
        XCTAssertEqual((updated["nestedSolved"] as? [[String: Any]])?.count, 1)
        XCTAssertEqual(document.session.changeCount, changesBefore + 1)

        let stored = try assembly()
        let container = try XCTUnwrap(stored.instance(UUID(uuidString: parent)!))
        let local = try XCTUnwrap(container.constraints.first { $0.id.uuidString == constraintID })
        XCTAssertEqual(local.value, 15.0)
        let localA = try XCTUnwrap(container.children.first { $0.id.uuidString == a })
        let localB = try XCTUnwrap(container.children.first { $0.id.uuidString == b })
        XCTAssertEqual(simd_length(localB.transform.position - localA.transform.position),
                       15.0, accuracy: 1e-6)

        document.session.undo()
        let undone = try assembly()
        let undoneContainer = try XCTUnwrap(undone.instance(UUID(uuidString: parent)!))
        XCTAssertEqual(undoneContainer.constraints.first { $0.id.uuidString == constraintID }?.value,
                       10.0)
        document.session.redo()
        let redone = try assembly()
        let redoneContainer = try XCTUnwrap(redone.instance(UUID(uuidString: parent)!))
        XCTAssertEqual(redoneContainer.constraints.first { $0.id.uuidString == constraintID }?.value,
                       15.0)

        let save = await document.save()
        XCTAssertTrue(save.succeeded, save.error ?? "")
        document.close()
        document = try await FloeCADDocument.open(
            at: workDir.appendingPathComponent("editing.floecad"))
        let reopened = try assembly()
        let reopenedContainer = try XCTUnwrap(reopened.instance(UUID(uuidString: parent)!))
        XCTAssertEqual(reopenedContainer.constraints.first { $0.id.uuidString == constraintID }?.value,
                       15.0)
    }

    // MARK: - Angle units and reference edits

    func testAngleEditUsesDegreesAndKeepsID() throws {
        let bodyA = try makeBox(min: [0, 0], max: [10, 10], height: 10)
        let bodyB = try makeBox(min: [20, 20], max: [30, 30], height: 10)
        let service = service()
        let a = try addInstance(service, bodyID: bodyA, name: "A")
        let b = try addInstance(service, bodyID: bodyB, name: "B")
        let added = service.handle(action: "addConstraint", args: [
            "kind": "angle", "instanceA": a, "instanceB": b,
            "directionA": [0.0, 0.0, 1.0], "directionB": [0.0, 0.0, 1.0],
            "value": 30.0,
        ])
        XCTAssertEqual(added["ok"] as? Bool, true, "\(added)")
        let constraintID = try XCTUnwrap(added["id"] as? String)
        XCTAssertEqual(service.handle(action: "solve", args: [:])["solved"] as? Bool, true)

        let updated = service.handle(action: "updateConstraint", args: [
            "id": constraintID, "value": 45.0, "expectedValue": 30.0,
        ])
        XCTAssertEqual(updated["ok"] as? Bool, true, "\(updated)")
        XCTAssertEqual(updated["value"] as? Double, 45.0)
        XCTAssertEqual(updated["valueUnit"] as? String, "degrees")
        XCTAssertEqual(updated["constraintID"] as? String, constraintID)
        XCTAssertEqual(service.handle(action: "solve", args: [:])["solved"] as? Bool, true)

        let report = service.handle(action: "report", args: [:])
        let axisA = try direction(instanceRow(report, id: a))
        let axisB = try direction(instanceRow(report, id: b))
        let degrees = acos(min(1, max(-1, simd_dot(axisA, axisB)))) * 180 / .pi
        XCTAssertEqual(degrees, 45.0, accuracy: 1e-4,
                       "the stored angle is degrees and the solved axes agree")
    }

    func testReferenceEditKeepsConstraintIDAndChangesOnlyThatReference() throws {
        let bodyA = try makeBox(min: [0, 0], max: [10, 10], height: 10)
        let bodyB = try makeBox(min: [20, 20], max: [30, 30], height: 10)
        let service = service()
        let a = try addInstance(service, bodyID: bodyA, name: "A")
        let b = try addInstance(service, bodyID: bodyB, name: "B")
        let added = service.handle(action: "addConstraint", args: [
            "kind": "distance", "instanceA": a, "instanceB": b,
            "pointA": [0.0, 0.0, 0.0], "pointB": [10.0, 0.0, 0.0], "value": 10.0,
        ])
        XCTAssertEqual(added["ok"] as? Bool, true, "\(added)")
        let constraintID = try XCTUnwrap(added["id"] as? String)
        XCTAssertEqual(service.handle(action: "solve", args: [:])["solved"] as? Bool, true)
        let before = try constraintRow(service.handle(action: "report", args: [:]), id: constraintID)
        let pointABefore = try XCTUnwrap(vector(before["pointA"]))
        let revisionABefore = revision(before["sourceRevisionA"])

        let updated = service.handle(action: "updateConstraint", args: [
            "id": constraintID,
            "pointB": [20.0, 0.0, 0.0],
            "value": 20.0,
        ])
        XCTAssertEqual(updated["ok"] as? Bool, true, "\(updated)")
        XCTAssertEqual(updated["constraintID"] as? String, constraintID)
        let after = try constraintRow(service.handle(action: "report", args: [:]), id: constraintID)
        XCTAssertEqual(try XCTUnwrap(vector(after["pointB"])), SIMD3<Double>(20, 0, 0))
        XCTAssertEqual(try XCTUnwrap(vector(after["pointA"])), pointABefore)
        XCTAssertEqual(revision(after["sourceRevisionA"]), revisionABefore)

        // The constraint's reference distance (not merely the instance-origin
        // distance) is what the edited pointB/value define.
        let report = service.handle(action: "report", args: [:])
        let worldA = try position(instanceRow(report, id: a)) + pointABefore
        let worldB = try position(instanceRow(report, id: b)) + SIMD3<Double>(20, 0, 0)
        XCTAssertEqual(simd_length(worldB - worldA), 20.0, accuracy: 1e-6)
    }

    // MARK: - Boundary, loop and redundancy

    func testDOFAt64InstancesAnd128ConstraintsIsExactAndRedundant() throws {
        let count = 64
        var instances: [CADAssemblyInstance] = []
        var positions: [SIMD3<Double>] = []
        let bodyID = UUID()
        for index in 0..<count {
            let angle = 2 * Double.pi * Double(index) / Double(count)
            let position = SIMD3(100 * cos(angle), 100 * sin(angle), 0)
            positions.append(position)
            instances.append(CADAssemblyInstance(
                id: UUID(), name: "Ring \(index + 1)", bodyID: bodyID,
                transform: CADTransform(position: position)))
        }

        var constraints: [CADAssemblyConstraint] = []
        var duplicateIDs: [String] = []
        for index in 0..<count {
            let next = (index + 1) % count
            let value = simd_length(positions[next] - positions[index])
            let first = CADAssemblyConstraint(
                kind: .distance,
                instanceA: instances[index].id,
                instanceB: instances[next].id,
                pointA: .zero, directionA: SIMD3(0, 0, 1),
                pointB: .zero, directionB: SIMD3(0, 0, 1),
                value: value)
            let duplicate = CADAssemblyConstraint(
                kind: .distance,
                instanceA: instances[index].id,
                instanceB: instances[next].id,
                pointA: .zero, directionA: SIMD3(0, 0, 1),
                pointB: .zero, directionB: SIMD3(0, 0, 1),
                value: value)
            constraints.append(first)
            constraints.append(duplicate)
            duplicateIDs.append(duplicate.id.uuidString)
        }
        XCTAssertEqual(instances.count, 64)
        XCTAssertEqual(constraints.count, 128)

        let ring = CADAssembly(instances: instances, constraints: constraints)
        document.session.perform(SetAssemblyDataCommand(
            before: document.session.document.assemblyData, after: try ring.encoded()))

        let service = service()
        let dof = service.handle(action: "dof", args: [:])
        XCTAssertEqual(dof["ok"] as? Bool, true, "\(dof)")
        XCTAssertEqual(dof["exact"] as? Bool, true)
        XCTAssertEqual(dof["solved"] as? Bool, true)
        XCTAssertEqual(dof["dofCredible"] as? Bool, true)
        XCTAssertEqual(dof["assemblyDOF"] as? Int, 320,
                       "64 unique distance rows remove 64 of 384 coordinates")
        XCTAssertEqual(dof["relativeDOF"] as? Int, 314)
        XCTAssertEqual(dof["globalRigidDOF"] as? Int, 6)
        XCTAssertEqual((dof["instances"] as? [[String: Any]])?.count, 64)
        let redundant = Set(try XCTUnwrap(dof["redundantConstraints"] as? [String]))
        XCTAssertEqual(redundant, Set(duplicateIDs),
                       "each later duplicate is reported, never counted as a new equation")

        let solved = service.handle(action: "solve", args: [:])
        XCTAssertEqual(solved["ok"] as? Bool, true, "\(solved)")
        XCTAssertEqual(solved["solved"] as? Bool, true)
    }

    func testLoopDuplicateAndFullyLockedDOFAreSemantic() throws {
        let bodyID = try makeBox(min: [0, 0], max: [10, 10], height: 10)
        let service = service()
        let a = try addInstance(service, bodyID: bodyID, name: "A")
        let b = try addInstance(service, bodyID: bodyID, name: "B", position: [10, 0, 0])
        let c = try addInstance(service, bodyID: bodyID, name: "C", position: [0, 10, 0])
        let abValue = 10.0
        let bcValue = simd_length(SIMD3<Double>(0, 10, 0) - SIMD3<Double>(10, 0, 0))
        let caValue = 10.0
        let ab = service.handle(action: "addConstraint", args: [
            "kind": "distance", "instanceA": a, "instanceB": b, "value": abValue,
        ])
        _ = service.handle(action: "addConstraint", args: [
            "kind": "distance", "instanceA": b, "instanceB": c, "value": bcValue,
        ])
        _ = service.handle(action: "addConstraint", args: [
            "kind": "distance", "instanceA": c, "instanceB": a, "value": caValue,
        ])
        let duplicate = service.handle(action: "addConstraint", args: [
            "kind": "distance", "instanceA": a, "instanceB": b, "value": abValue,
        ])
        let duplicateID = try XCTUnwrap(duplicate["id"] as? String)
        XCTAssertNotEqual(ab["id"] as? String, duplicateID)

        let loop = service.handle(action: "dof", args: [:])
        XCTAssertEqual(loop["solved"] as? Bool, true)
        XCTAssertEqual(loop["assemblyDOF"] as? Int, 15,
                       "three independent triangle distances leave 15 of 18 modes")
        XCTAssertEqual(loop["relativeDOF"] as? Int, 9)
        XCTAssertEqual(loop["redundantConstraints"] as? [String] ?? [], [duplicateID],
                       "only the repeated closure row is redundant")

        _ = service.handle(action: "addConstraint", args: ["kind": "fixed", "instanceA": a])
        _ = service.handle(action: "addConstraint", args: ["kind": "fixed", "instanceA": b])
        _ = service.handle(action: "addConstraint", args: ["kind": "fixed", "instanceA": c])
        let locked = service.handle(action: "dof", args: [:])
        XCTAssertEqual(locked["solved"] as? Bool, true)
        XCTAssertEqual(locked["assemblyDOF"] as? Int, 0)
        XCTAssertEqual(locked["fullyConstrained"] as? Bool, true)
        XCTAssertEqual(locked["dofCredible"] as? Bool, true)
        XCTAssertEqual(Set(locked["redundantConstraints"] as? [String] ?? []), Set([duplicateID]))
        XCTAssertEqual(service.handle(action: "solve", args: [:])["solved"] as? Bool, true)
    }

    // MARK: - E06 review: nested scope freedom is reported honestly

    /// The four diagnostic carriers must agree on the scope-honest fields;
    /// `assemblyDOF`/`relativeDOF`/`globalRigidDOF` always describe the root
    /// scope only.
    private func assertScopeDiagnosticsConsistent(
        _ payloads: [String: [String: Any]],
        rootFullyConstrained: Bool,
        nestedFullyConstrained: Bool,
        fullyConstrained: Bool,
        dofCredible: Bool,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        for (name, payload) in payloads {
            XCTAssertEqual(payload["assemblyDOFScope"] as? String, "root",
                           "\(name) must label its count as root-scope", file: file, line: line)
            XCTAssertEqual(payload["rootFullyConstrained"] as? Bool, rootFullyConstrained,
                           "\(name) root verdict", file: file, line: line)
            XCTAssertEqual(payload["nestedFullyConstrained"] as? Bool, nestedFullyConstrained,
                           "\(name) nested verdict", file: file, line: line)
            XCTAssertEqual(payload["fullyConstrained"] as? Bool, fullyConstrained,
                           "\(name) global verdict", file: file, line: line)
            XCTAssertEqual(payload["dofCredible"] as? Bool, dofCredible,
                           "\(name) credibility", file: file, line: line)
        }
    }

    func testFixedContainerWithMovableChildrenNeverClaimsFullyConstrained() throws {
        let bodyA = try makeBox(min: [0, 0], max: [10, 10], height: 10)
        let bodyB = try makeBox(min: [20, 20], max: [30, 30], height: 10)
        let service = service()
        let container = try addSubassembly(service, name: "Pair")
        let a = try addInstance(service, bodyID: bodyA, name: "A", parentID: container)
        let b = try addInstance(service, bodyID: bodyB, name: "B", position: [10, 0, 0],
                                parentID: container)
        // Ground the container at the root scope: the root scope then has
        // zero remaining mobility.
        let anchor = service.handle(action: "addConstraint", args: [
            "kind": "fixed", "instanceA": container,
        ])
        XCTAssertEqual(anchor["ok"] as? Bool, true, "\(anchor)")
        // One local distance: solvable, exact and credible — yet the children
        // keep 11 of 12 local modes, so internal motion is real.
        let local = service.handle(action: "addConstraint", args: [
            "kind": "distance", "instanceA": a, "instanceB": b,
            "parentID": container, "value": 10.0,
        ])
        XCTAssertEqual(local["ok"] as? Bool, true, "\(local)")
        let localID = try XCTUnwrap(local["id"] as? String)
        XCTAssertEqual(service.handle(action: "solve", args: [:])["solved"] as? Bool, true)

        // Internal movement is genuinely permitted: a child can still be
        // placed locally. This is exactly what the global claim must not
        // deny while reporting "fully constrained".
        let moved = service.handle(action: "setTransform", args: [
            "id": b, "transform": ["position": [12.0, 0.0, 0.0]],
        ])
        XCTAssertEqual(moved["ok"] as? Bool, true, "\(moved)")
        _ = service.handle(action: "setTransform", args: [
            "id": b, "transform": ["position": [10.0, 0.0, 0.0]],
        ])

        let report = service.handle(action: "report", args: [:])
        let dof = service.handle(action: "dof", args: [:])
        let solved = service.handle(action: "solve", args: [:])
        XCTAssertEqual(report["assemblyDOF"] as? Int, 0,
                       "the root scope holds only the pinned container")
        XCTAssertEqual(dof["assemblyDOF"] as? Int, 0)
        XCTAssertEqual(solved["assemblyDOF"] as? Int, 0)
        XCTAssertEqual(report["solved"] as? Bool, true)
        XCTAssertEqual(dof["solved"] as? Bool, true)
        XCTAssertEqual(solved["solved"] as? Bool, true)
        try assertScopeDiagnosticsConsistent(
            ["report": report, "dof": dof, "solve": solved],
            rootFullyConstrained: true,
            nestedFullyConstrained: false,
            fullyConstrained: false,
            dofCredible: true)

        let scopes = try XCTUnwrap(dof["scopes"] as? [[String: Any]])
        XCTAssertEqual(scopes.count, 1)
        XCTAssertEqual(scopes[0]["assemblyDOF"] as? Int, 11,
                       "two children sharing one distance keep 11 local modes")
        XCTAssertEqual(scopes[0]["fullyConstrained"] as? Bool, false)
        XCTAssertEqual(scopes[0]["dofCredible"] as? Bool, true)

        // Editing the local mate keeps the same honest contract.
        let edited = service.handle(action: "updateConstraint", args: [
            "id": localID, "value": 12.0, "expectedValue": 10.0,
        ])
        XCTAssertEqual(edited["ok"] as? Bool, true, "\(edited)")
        XCTAssertEqual(edited["assemblyDOFScope"] as? String, "root")
        XCTAssertEqual(edited["rootFullyConstrained"] as? Bool, true)
        XCTAssertEqual(edited["nestedFullyConstrained"] as? Bool, false)
        XCTAssertEqual(edited["fullyConstrained"] as? Bool, false)
        XCTAssertEqual(edited["dofCredible"] as? Bool, true)
    }

    func testSameTreeBecomesFullyConstrainedOnlyWhenInternalScopesLock() throws {
        let bodyA = try makeBox(min: [0, 0], max: [10, 10], height: 10)
        let bodyB = try makeBox(min: [20, 20], max: [30, 30], height: 10)
        let service = service()
        let container = try addSubassembly(service, name: "Pair")
        let a = try addInstance(service, bodyID: bodyA, name: "A", parentID: container)
        let b = try addInstance(service, bodyID: bodyB, name: "B", position: [10, 0, 0],
                                parentID: container)
        _ = service.handle(action: "addConstraint", args: [
            "kind": "fixed", "instanceA": container,
        ])
        _ = service.handle(action: "addConstraint", args: [
            "kind": "distance", "instanceA": a, "instanceB": b,
            "parentID": container, "value": 10.0,
        ])
        XCTAssertEqual(service.handle(action: "solve", args: [:])["solved"] as? Bool, true)

        // Pin both children inside the container frame; the local distance
        // stays satisfied at the current placement.
        _ = service.handle(action: "addConstraint", args: [
            "kind": "fixed", "instanceA": a, "parentID": container,
        ])
        _ = service.handle(action: "addConstraint", args: [
            "kind": "fixed", "instanceA": b, "parentID": container,
        ])
        let report = service.handle(action: "report", args: [:])
        let dof = service.handle(action: "dof", args: [:])
        let solved = service.handle(action: "solve", args: [:])
        XCTAssertEqual(report["assemblyDOF"] as? Int, 0)
        XCTAssertEqual(dof["assemblyDOF"] as? Int, 0)
        XCTAssertEqual(solved["assemblyDOF"] as? Int, 0)
        try assertScopeDiagnosticsConsistent(
            ["report": report, "dof": dof, "solve": solved],
            rootFullyConstrained: true,
            nestedFullyConstrained: true,
            fullyConstrained: true,
            dofCredible: true)
        let scopes = try XCTUnwrap(dof["scopes"] as? [[String: Any]])
        XCTAssertEqual(scopes.count, 1)
        XCTAssertEqual(scopes[0]["assemblyDOF"] as? Int, 0)
        XCTAssertEqual(scopes[0]["fullyConstrained"] as? Bool, true)
    }

    func testTwoNestedLevelsReportFreedomPerScope() throws {
        let bodyA = try makeBox(min: [0, 0], max: [10, 10], height: 10)
        let bodyB = try makeBox(min: [20, 20], max: [30, 30], height: 10)
        let service = service()
        let outer = try addSubassembly(service, name: "Outer")
        let inner = try addSubassembly(service, name: "Inner", parentID: outer)
        let a = try addInstance(service, bodyID: bodyA, name: "A", parentID: inner)
        let b = try addInstance(service, bodyID: bodyB, name: "B", position: [10, 0, 0],
                                parentID: inner)
        _ = service.handle(action: "addConstraint", args: [
            "kind": "fixed", "instanceA": outer,
        ])
        XCTAssertEqual(service.handle(action: "solve", args: [:])["solved"] as? Bool, true)

        let dof = service.handle(action: "dof", args: [:])
        try assertScopeDiagnosticsConsistent(
            ["dof": dof],
            rootFullyConstrained: true,
            nestedFullyConstrained: false,
            fullyConstrained: false,
            dofCredible: true)
        var scopes = try XCTUnwrap(dof["scopes"] as? [[String: Any]])
        XCTAssertEqual(scopes.count, 2)
        XCTAssertEqual(Set(scopes.compactMap { $0["name"] as? String }), Set(["Outer", "Inner"]))
        for scope in scopes {
            XCTAssertEqual(scope["fullyConstrained"] as? Bool, false)
        }

        // Lock the leaves inside the inner scope: the inner scope becomes
        // fully constrained, but the inner container still moves inside the
        // outer scope, so the whole assembly is still not fully constrained.
        _ = service.handle(action: "addConstraint", args: [
            "kind": "fixed", "instanceA": a, "parentID": inner,
        ])
        _ = service.handle(action: "addConstraint", args: [
            "kind": "fixed", "instanceA": b, "parentID": inner,
        ])
        XCTAssertEqual(service.handle(action: "solve", args: [:])["solved"] as? Bool, true)
        let partial = service.handle(action: "dof", args: [:])
        try assertScopeDiagnosticsConsistent(
            ["dof": partial],
            rootFullyConstrained: true,
            nestedFullyConstrained: false,
            fullyConstrained: false,
            dofCredible: true)
        scopes = try XCTUnwrap(partial["scopes"] as? [[String: Any]])
        let innerScope = try XCTUnwrap(scopes.first { $0["name"] as? String == "Inner" })
        let outerScope = try XCTUnwrap(scopes.first { $0["name"] as? String == "Outer" })
        XCTAssertEqual(innerScope["fullyConstrained"] as? Bool, true)
        XCTAssertEqual(outerScope["fullyConstrained"] as? Bool, false)

        // Pin the inner container inside the outer scope as well.
        _ = service.handle(action: "addConstraint", args: [
            "kind": "fixed", "instanceA": inner, "parentID": outer,
        ])
        let report = service.handle(action: "report", args: [:])
        let locked = service.handle(action: "dof", args: [:])
        let solved = service.handle(action: "solve", args: [:])
        try assertScopeDiagnosticsConsistent(
            ["report": report, "dof": locked, "solve": solved],
            rootFullyConstrained: true,
            nestedFullyConstrained: true,
            fullyConstrained: true,
            dofCredible: true)
        scopes = try XCTUnwrap(locked["scopes"] as? [[String: Any]])
        for scope in scopes {
            XCTAssertEqual(scope["fullyConstrained"] as? Bool, true)
            XCTAssertEqual(scope["assemblyDOF"] as? Int, 0)
        }
    }

    func testUnsolvableLocalScopeRefusesSolveEditAndStaysNonCredible() throws {
        let bodyA = try makeBox(min: [0, 0], max: [10, 10], height: 10)
        let bodyB = try makeBox(min: [20, 20], max: [30, 30], height: 10)
        let service = service()
        let container = try addSubassembly(service, name: "Pair")
        let a = try addInstance(service, bodyID: bodyA, name: "A", parentID: container)
        let b = try addInstance(service, bodyID: bodyB, name: "B", position: [10, 0, 0],
                                parentID: container)
        _ = service.handle(action: "addConstraint", args: [
            "kind": "fixed", "instanceA": container,
        ])
        let first = service.handle(action: "addConstraint", args: [
            "kind": "distance", "instanceA": a, "instanceB": b,
            "parentID": container, "value": 10.0,
        ])
        _ = service.handle(action: "addConstraint", args: [
            "kind": "distance", "instanceA": a, "instanceB": b,
            "parentID": container, "value": 20.0,
        ])
        let firstID = try XCTUnwrap(first["id"] as? String)

        let beforeData = try XCTUnwrap(document.session.document.assemblyData)
        let beforeChanges = document.session.changeCount
        let refusedSolve = service.handle(action: "solve", args: [:])
        XCTAssertEqual(refusedSolve["ok"] as? Bool, false)
        XCTAssertEqual(refusedSolve["error"] as? String, "constraint_failed")
        XCTAssertEqual(refusedSolve["mutated"] as? Bool, false)
        XCTAssertEqual(refusedSolve["solved"] as? Bool, false)
        XCTAssertEqual(refusedSolve["scope"] as? String, "subassembly")
        XCTAssertEqual(refusedSolve["parentID"] as? String, container)

        let refusedEdit = service.handle(action: "updateConstraint", args: [
            "id": firstID, "value": 15.0, "expectedValue": 10.0,
        ])
        XCTAssertEqual(refusedEdit["ok"] as? Bool, false)
        XCTAssertEqual(refusedEdit["error"] as? String, "constraint_failed")
        XCTAssertEqual(refusedEdit["mutated"] as? Bool, false)
        XCTAssertEqual(document.session.document.assemblyData, beforeData,
                       "an unsolvable nested scope must not touch the persisted assembly")
        XCTAssertEqual(document.session.changeCount, beforeChanges,
                       "an unsolvable nested scope must not add an undo entry")

        let report = service.handle(action: "report", args: [:])
        let dof = service.handle(action: "dof", args: [:])
        XCTAssertEqual(report["solved"] as? Bool, false)
        XCTAssertEqual(report["dofCredible"] as? Bool, false)
        XCTAssertEqual(report["fullyConstrained"] as? Bool, false)
        XCTAssertEqual(dof["solved"] as? Bool, false)
        XCTAssertEqual(dof["dofCredible"] as? Bool, false)
        XCTAssertEqual(dof["fullyConstrained"] as? Bool, false)
        XCTAssertEqual(dof["rootFullyConstrained"] as? Bool, true,
                       "the root scope itself is still pinned and exact")
        XCTAssertEqual(dof["nestedFullyConstrained"] as? Bool, false)
        let scopes = try XCTUnwrap(dof["scopes"] as? [[String: Any]])
        XCTAssertEqual(scopes.count, 1)
        XCTAssertEqual(scopes[0]["solved"] as? Bool, false)
        XCTAssertEqual(scopes[0]["dofCredible"] as? Bool, false)
        XCTAssertFalse((scopes[0]["conflicting"] as? [String] ?? []).isEmpty)
    }

    func testFlatAssemblyKeepsHistoricalFullyConstrainedSemantics() throws {
        let bodyA = try makeBox(min: [0, 0], max: [10, 10], height: 10)
        let bodyB = try makeBox(min: [20, 20], max: [30, 30], height: 10)
        let service = service()
        let a = try addInstance(service, bodyID: bodyA, name: "A")
        let b = try addInstance(service, bodyID: bodyB, name: "B", position: [10, 0, 0])
        _ = service.handle(action: "addConstraint", args: ["kind": "fixed", "instanceA": a])
        _ = service.handle(action: "addConstraint", args: ["kind": "fixed", "instanceA": b])
        _ = service.handle(action: "addConstraint", args: [
            "kind": "distance", "instanceA": a, "instanceB": b, "value": 10.0,
        ])
        let report = service.handle(action: "report", args: [:])
        let dof = service.handle(action: "dof", args: [:])
        let solved = service.handle(action: "solve", args: [:])
        XCTAssertEqual(report["assemblyDOFScope"] as? String, "root")
        XCTAssertEqual(dof["assemblyDOFScope"] as? String, "root")
        XCTAssertEqual(solved["assemblyDOFScope"] as? String, "root")
        // No subassemblies: the nested verdict is vacuously true and the
        // global verdict equals the historical root-only claim.
        XCTAssertEqual(report["nestedFullyConstrained"] as? Bool, true)
        XCTAssertEqual(dof["nestedFullyConstrained"] as? Bool, true)
        XCTAssertEqual(solved["nestedFullyConstrained"] as? Bool, true)
        try assertScopeDiagnosticsConsistent(
            ["report": report, "dof": dof, "solve": solved],
            rootFullyConstrained: true,
            nestedFullyConstrained: true,
            fullyConstrained: true,
            dofCredible: true)
        XCTAssertEqual((dof["scopes"] as? [[String: Any]] ?? []).count, 0)
    }
}
