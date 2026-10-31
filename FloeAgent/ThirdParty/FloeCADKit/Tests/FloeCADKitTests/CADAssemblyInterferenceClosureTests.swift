//
//  CADAssemblyInterferenceClosureTests.swift
//  FloeCADKitTests
//
//  E07/E08 contract: selected-instance all-pairs coverage for 50 instances,
//  service-owned progress, active cancellation with a joined worker, stale
//  generation rejection, and real triangle contact/clearance for mesh bodies
//  (including a hollow cavity that must not be mistaken for material overlap).
//
//  SPDX-License-Identifier: MPL-2.0
//

import CryptoKit
import Foundation
import XCTest
import simd
@testable import FloeCAD

@MainActor
final class CADAssemblyInterferenceClosureTests: XCTestCase {
    private var workDir: URL!
    private var document: FloeCADDocument!

    override func setUp() async throws {
        workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("FloeCADInterference-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
        document = try await FloeCADDocument.create(
            at: workDir.appendingPathComponent("interference.floecad"),
            name: "Interference")
    }

    override func tearDown() async throws {
        document?.close()
        if let workDir { try? FileManager.default.removeItem(at: workDir) }
    }

    // MARK: Helpers

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

    /// One extruded rectangular box through the typed command vocabulary; the
    /// resulting body carries a real OCCT B-rep, so the exact common path runs.
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

    private func nextRevision() -> UInt64 {
        (document.session.document.bodies.map(\.meshRevision).max() ?? 0) + 1
    }

    private func makeMeshBody(_ name: String,
                              positions: [SIMD3<Float>],
                              indices: [UInt32]) throws -> String {
        let body = Body(
            id: BodyID(), name: name, transform: .identity, primitive: nil,
            render: RenderMesh(positions: positions,
                               normals: Array(repeating: SIMD3<Float>(0, 0, 1),
                                              count: positions.count),
                               indices: indices),
            revision: nextRevision())
        document.session.perform(AddBodyCommand(body: body, title: "Test \(name)"))
        return body.id.raw.uuidString
    }

    private func addInstance(_ service: CADAssemblyService,
                             bodyID: String,
                             name: String,
                             position: [Double] = [0, 0, 0],
                             rotation: [Double]? = nil) throws -> String {
        var transform: [String: Any] = ["position": position]
        if let rotation { transform["rotation"] = rotation }
        let reply = service.handle(action: "addInstance", args: [
            "bodyID": bodyID, "name": name, "transform": transform,
        ])
        XCTAssertEqual(reply["ok"] as? Bool, true, "addInstance refused: \(reply)")
        return try XCTUnwrap(reply["id"] as? String)
    }

    private func boxMesh(min lo: SIMD3<Float>, max hi: SIMD3<Float>,
                         inward: Bool = false) -> ([SIMD3<Float>], [UInt32]) {
        let positions: [SIMD3<Float>] = [
            SIMD3(lo.x, lo.y, lo.z), SIMD3(hi.x, lo.y, lo.z),
            SIMD3(hi.x, hi.y, lo.z), SIMD3(lo.x, hi.y, lo.z),
            SIMD3(lo.x, lo.y, hi.z), SIMD3(hi.x, lo.y, hi.z),
            SIMD3(hi.x, hi.y, hi.z), SIMD3(lo.x, hi.y, hi.z),
        ]
        var faces: [(Int, Int, Int)] = [
            (0, 2, 1), (0, 3, 2), (4, 5, 6), (4, 6, 7),
            (0, 1, 5), (0, 5, 4), (3, 7, 6), (3, 6, 2),
            (0, 4, 7), (0, 7, 3), (1, 2, 6), (1, 6, 5),
        ]
        if inward { faces = faces.map { ($0.0, $0.2, $0.1) } }
        return (positions, faces.flatMap {
            [UInt32($0.0), UInt32($0.1), UInt32($0.2)]
        })
    }

    private func hollowBoxMesh(outer: Float, inner: Float) -> ([SIMD3<Float>], [UInt32]) {
        let outerMesh = boxMesh(min: SIMD3(-outer, -outer, -outer),
                                max: SIMD3(outer, outer, outer))
        let innerMesh = boxMesh(min: SIMD3(-inner, -inner, -inner),
                                max: SIMD3(inner, inner, inner), inward: true)
        var positions = outerMesh.0
        let offset = UInt32(positions.count)
        positions.append(contentsOf: innerMesh.0)
        var indices = outerMesh.1
        indices.append(contentsOf: innerMesh.1.map { $0 + offset })
        return (positions, indices)
    }

    private func rows(_ reply: [String: Any], _ key: String) -> [[String: Any]] {
        reply[key] as? [[String: Any]] ?? []
    }

    private func pairSet(_ rows: [[String: Any]]) -> Set<String> {
        Set(rows.map { row in
            let a = row["a"] as? String ?? ""
            let b = row["b"] as? String ?? ""
            return a < b ? "\(a)|\(b)" : "\(b)|\(a)"
        })
    }

    /// Same documented basis as the service: SHA-256 over each row's
    /// sorted-key JSON plus one LF, in returned order.
    private func detailDigest(_ rows: [[String: Any]]) -> String {
        var hasher = SHA256()
        for row in rows {
            let data = try! JSONSerialization.data(withJSONObject: row,
                                                   options: [.sortedKeys])
            hasher.update(data: data)
            hasher.update(data: Data([0x0A]))
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    // MARK: E07 — selected subset, all pairs, real progress

    func testFiftyInstanceSelectedSubsetProcessesEveryPairWithRealProgress() async throws {
        let mesh = boxMesh(min: SIMD3(0, 0, 0), max: SIMD3(10, 10, 10))
        let bodyID = try makeMeshBody("Shared", positions: mesh.0, indices: mesh.1)
        let service = service()
        let ids = try (0..<50).map { index -> String in
            let x = Double(index % 10) * 20
            let z = Double(index / 10) * 20
            return try addInstance(service, bodyID: bodyID,
                                   name: "I\(index)", position: [x, 0, z])
        }
        let probe = ProgressProbe()
        CADAssemblyService.testInterferencePairProbe = { snapshot in
            probe.record(snapshot)
        }
        defer { CADAssemblyService.testInterferencePairProbe = nil }

        let reply = await service.handleAsync(action: "interference", args: [
            "instanceIDs": ids,
            "toleranceMM": 1e-6,
        ])
        XCTAssertEqual(reply["ok"] as? Bool, true, "interference refused: \(reply)")
        XCTAssertEqual(reply["selectedInstanceCount"] as? Int, 50)
        XCTAssertEqual(reply["pairCount"] as? Int, 1225,
                       "50 selected instances have 1225 unordered pairs")
        XCTAssertEqual(reply["requestedPairCount"] as? Int, 1225)
        XCTAssertEqual(reply["processedPairCount"] as? Int, 1225)
        XCTAssertEqual(reply["separatedPairCount"] as? Int, 1225,
                       "every grid pair is separated")
        XCTAssertEqual(reply["interferingPairCount"] as? Int, 0)
        XCTAssertNil(reply["maxPairs"], "the old 32-pair gate must not exist")
        XCTAssertNil(reply["detailLimit"], "the intrinsic detail cap must not exist")
        XCTAssertNil(reply["clearancesTruncated"],
                     "there is no intrinsic clearance truncation flag")
        XCTAssertEqual(reply["detailsComplete"] as? Bool, true)
        XCTAssertEqual(reply["detailRowCount"] as? Int, 1225)
        XCTAssertEqual(reply["resultBudgetBytes"] as? Int,
                       CADAssemblyService.interferenceResultBudgetBytes)
        let detailBytes = try XCTUnwrap(reply["detailBytes"] as? Int)
        XCTAssertGreaterThan(detailBytes, 0)
        XCTAssertLessThanOrEqual(detailBytes,
                                 CADAssemblyService.interferenceResultBudgetBytes)
        let resultBytes = try XCTUnwrap(reply["resultBytes"] as? Int)
        XCTAssertGreaterThanOrEqual(resultBytes, detailBytes)
        XCTAssertLessThanOrEqual(resultBytes,
                                 CADAssemblyService.interferenceResultBudgetBytes)
        let clearances = rows(reply, "clearances")
        XCTAssertEqual(clearances.count, 1225,
                       "every one of the 1225 completed pair details is returned")
        let allRows = rows(reply, "interferences") + rows(reply, "contacts")
            + clearances + rows(reply, "unresolvedPairs")
        XCTAssertEqual(allRows.count, 1225)
        // The last requested pair (document occurrence order) must be present:
        // no tail was dropped.
        let lastPair = [ids[48], ids[49]].sorted().joined(separator: "|")
        XCTAssertTrue(pairSet(clearances).contains(lastPair),
                      "the final requested pair must be present")
        let digest = try XCTUnwrap(reply["detailDigest"] as? String)
        XCTAssertEqual(digest.count, 64)
        XCTAssertEqual(reply["detailDigestAlgorithm"] as? String,
                       CADAssemblyService.interferenceDetailDigestAlgorithm)
        XCTAssertEqual(digest, detailDigest(allRows),
                       "the digest covers the complete returned rows in order")
        let progress = try XCTUnwrap(reply["progress"] as? [String: Any])
        XCTAssertEqual(progress["phase"] as? String, "completed")
        XCTAssertEqual(progress["processedPairCount"] as? Int, 1225)
        XCTAssertEqual(progress["requestedPairCount"] as? Int, 1225)

        XCTAssertEqual(probe.count, 1225,
                       "the probe must observe one real progress event per requested pair")
        XCTAssertEqual(probe.firstProcessed, 1)
        XCTAssertEqual(probe.lastProcessed, 1225)
        XCTAssertTrue(probe.monotonic)
        XCTAssertTrue(probe.sawOffMain, "the pair work must run off the main actor")
    }

    // MARK: Correction — cubic volume threshold and complete details

    /// Two real OCCT boxes overlap by 0.001 mm on X with 10 x 10 mm faces,
    /// so the exact common is 0.1 mm³. The linear contact tolerance is 1.0 mm:
    /// the old `volumeMM3 > toleranceMM` comparison (0.1 > 1.0) would call
    /// this no shared volume. The cubic threshold default 0 must report real
    /// penetration.
    func testTinyPositiveExactCommonVolumeUsesCubicThresholdNotLinearTolerance() async throws {
        let bodyA = try makeBox(min: [0, 0], max: [10, 10], height: 10)
        let bodyB = try makeBox(min: [9.999, 0], max: [19.999, 10], height: 10)
        let service = service()
        let a = try addInstance(service, bodyID: bodyA, name: "A")
        let b = try addInstance(service, bodyID: bodyB, name: "B")

        let reply = await service.handleAsync(action: "interference", args: [
            "instanceIDs": [a, b],
            "toleranceMM": 1.0,
        ])
        XCTAssertEqual(reply["ok"] as? Bool, true, "\(reply)")
        XCTAssertEqual(reply["exactPairCount"] as? Int, 1)
        XCTAssertEqual(reply["interferingPairCount"] as? Int, 1,
                       "a positive exact common is penetration regardless of linear tolerance")
        XCTAssertEqual(reply["separatedPairCount"] as? Int, 0)
        XCTAssertEqual(reply["contactPairCount"] as? Int, 0)
        XCTAssertEqual(reply["volumeToleranceMM3"] as? Double, 0)
        let row = try XCTUnwrap(rows(reply, "interferences").first)
        XCTAssertEqual(row["exact"] as? Bool, true)
        XCTAssertEqual(try XCTUnwrap(row["volumeMM3"] as? Double), 0.1, accuracy: 1e-6)
        XCTAssertEqual(row["volumeThresholdMM3"] as? Double, 0)
        XCTAssertEqual(row["volumeBelowThreshold"] as? Bool, false)
        XCTAssertEqual(row["volumeClassification"] as? String,
                       "positive_common_at_or_above_threshold")
        XCTAssertEqual(reply["belowVolumeThresholdPairCount"] as? Int, 0)
    }

    func testExplicitVolumeThresholdReportsPositiveVolumeBelowThreshold() async throws {
        let bodyA = try makeBox(min: [0, 0], max: [10, 10], height: 10)
        let bodyB = try makeBox(min: [9.999, 0], max: [19.999, 10], height: 10)
        let service = service()
        let a = try addInstance(service, bodyID: bodyA, name: "A")
        let b = try addInstance(service, bodyID: bodyB, name: "B")

        let reply = await service.handleAsync(action: "interference", args: [
            "instanceIDs": [a, b],
            "toleranceMM": 1.0,
            "volumeToleranceMM3": 1.0,
        ])
        XCTAssertEqual(reply["ok"] as? Bool, true, "\(reply)")
        XCTAssertEqual(reply["interferingPairCount"] as? Int, 1,
                       "a below-threshold positive volume stays reported, not noSharedVolume")
        XCTAssertEqual(reply["separatedPairCount"] as? Int, 0)
        XCTAssertEqual(reply["unresolvedPairCount"] as? Int, 0)
        XCTAssertTrue(rows(reply, "clearances").isEmpty)
        XCTAssertEqual(reply["belowVolumeThresholdPairCount"] as? Int, 1)
        let row = try XCTUnwrap(rows(reply, "interferences").first)
        XCTAssertEqual(try XCTUnwrap(row["volumeMM3"] as? Double), 0.1, accuracy: 1e-6)
        XCTAssertEqual(row["volumeThresholdMM3"] as? Double, 1.0)
        XCTAssertEqual(row["volumeBelowThreshold"] as? Bool, true)
        XCTAssertEqual(row["volumeClassification"] as? String,
                       "positive_common_below_threshold")
    }

    func testInvalidVolumeToleranceAndLegacyDetailLimitAreRefused() async throws {
        let bodyA = try makeBox(min: [0, 0], max: [10, 10], height: 10)
        let bodyB = try makeBox(min: [9.999, 0], max: [19.999, 10], height: 10)
        let service = service()
        let a = try addInstance(service, bodyID: bodyA, name: "A")
        let b = try addInstance(service, bodyID: bodyB, name: "B")
        let badValues: [Any] = [-1.0, Double.nan, Double.infinity, "not-a-number"]
        for bad in badValues {
            let reply = await service.handleAsync(action: "interference", args: [
                "instanceIDs": [a, b],
                "volumeToleranceMM3": bad,
            ])
            XCTAssertEqual(reply["ok"] as? Bool, false)
            XCTAssertEqual(reply["error"] as? String, "bad_volume_tolerance",
                           "invalid volumeToleranceMM3 \(bad) must be refused")
            XCTAssertNil(reply["interferences"])
        }
        let legacy = await service.handleAsync(action: "interference", args: [
            "instanceIDs": [a, b],
            "detailLimit": 8,
        ])
        XCTAssertEqual(legacy["ok"] as? Bool, false)
        XCTAssertEqual(legacy["error"] as? String, "deprecated_argument")
        XCTAssertTrue((legacy["message"] as? String ?? "").contains("detailLimit was removed"))
    }

    func testResultByteCapRefusesAtomicallyWithoutPartialRows() async throws {
        let mesh = boxMesh(min: SIMD3(0, 0, 0), max: SIMD3(10, 10, 10))
        let bodyID = try makeMeshBody("Budget", positions: mesh.0, indices: mesh.1)
        let service = service()
        let ids = try (0..<20).map { index -> String in
            try addInstance(service, bodyID: bodyID, name: "B\(index)",
                            position: [Double(index) * 20, 0, 0])
        }
        CADAssemblyService.testInterferenceResultBudgetBytes = 32 * 1_024
        defer { CADAssemblyService.testInterferenceResultBudgetBytes = nil }

        let reply = await service.handleAsync(action: "interference", args: [
            "instanceIDs": ids,
            "toleranceMM": 1e-6,
        ])
        XCTAssertEqual(reply["ok"] as? Bool, false)
        XCTAssertEqual(reply["error"] as? String, "result_too_large")
        XCTAssertEqual(reply["completed"] as? Bool, false)
        XCTAssertEqual(reply["detailsComplete"] as? Bool, false)
        XCTAssertEqual(reply["resultBudgetBytes"] as? Int, 32 * 1_024)
        XCTAssertNil(reply["interferences"], "no partial rows after an envelope refusal")
        XCTAssertNil(reply["contacts"])
        XCTAssertNil(reply["clearances"])
        XCTAssertNil(reply["unresolvedPairs"])
        XCTAssertNil(reply["detailDigest"])
        let processed = try XCTUnwrap(reply["processedPairCount"] as? Int)
        XCTAssertGreaterThan(processed, 0, "the cap must be enforced during pair work")
        XCTAssertLessThan(processed, 190)
        XCTAssertTrue((reply["message"] as? String ?? "").contains("Select fewer instances"))
    }

    func testSelectedSubsetExcludesNonselectedInstancesAndRejectsUnknownIDs() async throws {
        let mesh = boxMesh(min: SIMD3(0, 0, 0), max: SIMD3(10, 10, 10))
        let bodyID = try makeMeshBody("Box", positions: mesh.0, indices: mesh.1)
        let service = service()
        let first = try addInstance(service, bodyID: bodyID, name: "First")
        let second = try addInstance(service, bodyID: bodyID, name: "Second",
                                     position: [20, 0, 0])
        let third = try addInstance(service, bodyID: bodyID, name: "Third",
                                    position: [40, 0, 0])

        let plan = service.handle(action: "interferencePlan", args: [
            "instanceIDs": [first, third],
        ])
        XCTAssertEqual(plan["ok"] as? Bool, true)
        XCTAssertEqual(plan["selectedInstanceCount"] as? Int, 2)
        XCTAssertEqual(plan["pairCount"] as? Int, 1)
        XCTAssertEqual(Set(plan["selectedInstanceIDs"] as? [String] ?? []),
                       Set([first, third]))

        let reply = await service.handleAsync(action: "interference", args: [
            "instanceIDs": [first, second],
            "toleranceMM": 1e-6,
        ])
        XCTAssertEqual(reply["ok"] as? Bool, true, "\(reply)")
        XCTAssertEqual(reply["pairCount"] as? Int, 1)
        XCTAssertEqual(reply["processedPairCount"] as? Int, 1)
        let expected = [first, second].sorted().joined(separator: "|")
        XCTAssertEqual(pairSet(rows(reply, "clearances")), Set([expected]))
        XCTAssertFalse(pairSet(rows(reply, "clearances")).contains {
            $0.contains(third)
        }, "a non-selected instance must not appear")

        let refused = await service.handleAsync(action: "interference", args: [
            "instanceIDs": ["00000000-0000-0000-0000-000000000000"],
        ])
        XCTAssertEqual(refused["ok"] as? Bool, false)
        XCTAssertEqual(refused["error"] as? String, "unknown_instance")
    }

    func testSubassemblySelectionExpandsToDrawableDescendants() async throws {
        let mesh = boxMesh(min: SIMD3(0, 0, 0), max: SIMD3(10, 10, 10))
        let bodyID = try makeMeshBody("Grouped", positions: mesh.0, indices: mesh.1)
        let service = service()
        let first = try addInstance(service, bodyID: bodyID, name: "First")
        let second = try addInstance(service, bodyID: bodyID, name: "Second",
                                     position: [20, 0, 0])
        let groupReply = service.handle(action: "addSubassembly", args: ["name": "Group"])
        XCTAssertEqual(groupReply["ok"] as? Bool, true, "\(groupReply)")
        let group = try XCTUnwrap(groupReply["id"] as? String)
        for id in [first, second] {
            let moved = service.handle(action: "moveInstance", args: [
                "id": id, "parentID": group,
            ])
            XCTAssertEqual(moved["ok"] as? Bool, true, "\(moved)")
        }

        let plan = service.handle(action: "interferencePlan", args: ["instanceIDs": [group]])
        XCTAssertEqual(plan["ok"] as? Bool, true, "\(plan)")
        XCTAssertEqual(plan["selectedInstanceCount"] as? Int, 2)
        XCTAssertEqual(plan["pairCount"] as? Int, 1)
        XCTAssertEqual(Set(plan["selectedInstanceIDs"] as? [String] ?? []),
                       Set([first, second]))

        let reply = await service.handleAsync(action: "interference", args: [
            "instanceIDs": [group], "toleranceMM": 1e-6,
        ])
        XCTAssertEqual(reply["ok"] as? Bool, true, "\(reply)")
        XCTAssertEqual(reply["pairCount"] as? Int, 1)
        XCTAssertEqual(reply["processedPairCount"] as? Int, 1)
    }

    // MARK: E07 — cancellation and stale generation

    func testCancellationJoinsWorkerAndRejectsPartialResult() async throws {
        let mesh = boxMesh(min: SIMD3(0, 0, 0), max: SIMD3(10, 10, 10))
        let bodyID = try makeMeshBody("Grid", positions: mesh.0, indices: mesh.1)
        let service = service()
        let ids = try (0..<20).map { index -> String in
            try addInstance(service, bodyID: bodyID, name: "C\(index)",
                            position: [Double(index) * 20, 0, 0])
        }
        let gate = PairGate()
        CADAssemblyService.testInterferencePairProbe = { snapshot in
            gate.observe(snapshot)
        }
        defer { CADAssemblyService.testInterferencePairProbe = nil }

        let box = ReplyBox()
        let task = Task { @MainActor in
            box.reply = await service.handleAsync(action: "interference", args: [
                "instanceIDs": ids, "toleranceMM": 1e-6,
            ])
        }
        let reached = await Task.detached { gate.waitUntilPaused() }.value
        XCTAssertTrue(reached, "the worker did not reach the first pair")
        let cancel = service.cancelInterference()
        XCTAssertEqual(cancel["cancelRequested"] as? Bool, true)
        gate.release()
        await task.value
        let reply = box.reply

        XCTAssertEqual(reply["ok"] as? Bool, false)
        XCTAssertEqual(reply["error"] as? String, "cancelled")
        XCTAssertLessThan(try XCTUnwrap(reply["processedPairCount"] as? Int), 190,
                          "cancellation must stop before all pairs")
        XCTAssertNil(reply["interferences"],
                     "no partial interference list may survive cancellation")
        XCTAssertNil(reply["clearances"], "no partial detail rows may survive cancellation")
        XCTAssertEqual(reply["detailsComplete"] as? Bool, false)
        XCTAssertEqual(reply["completed"] as? Bool, false)
        XCTAssertNil(reply["detailDigest"])
        let progress = try XCTUnwrap(reply["progress"] as? [String: Any])
        XCTAssertEqual(progress["phase"] as? String, "cancelled")
    }

    func testDocumentChangeRejectsOldResult() async throws {
        let mesh = boxMesh(min: SIMD3(0, 0, 0), max: SIMD3(10, 10, 10))
        let bodyID = try makeMeshBody("StaleGrid", positions: mesh.0, indices: mesh.1)
        let service = service()
        let ids = try (0..<20).map { index -> String in
            try addInstance(service, bodyID: bodyID, name: "S\(index)",
                            position: [Double(index) * 20, 0, 0])
        }
        let gate = PairGate()
        CADAssemblyService.testInterferencePairProbe = { snapshot in
            gate.observe(snapshot)
        }
        defer { CADAssemblyService.testInterferencePairProbe = nil }

        let box = ReplyBox()
        let task = Task { @MainActor in
            box.reply = await service.handleAsync(action: "interference", args: [
                "instanceIDs": ids, "toleranceMM": 1e-6,
            ])
        }
        let reached = await Task.detached { gate.waitUntilPaused() }.value
        XCTAssertTrue(reached)
        let extra = Body(
            id: BodyID(), name: "Changed", transform: .identity, primitive: nil,
            render: RenderMesh(positions: mesh.0,
                               normals: Array(repeating: SIMD3<Float>(0, 0, 1),
                                              count: mesh.0.count),
                               indices: mesh.1),
            revision: nextRevision())
        document.session.perform(AddBodyCommand(body: extra, title: "Change generation"))
        gate.release()
        await task.value
        let reply = box.reply

        XCTAssertEqual(reply["ok"] as? Bool, false)
        XCTAssertEqual(reply["error"] as? String, "stale")
        XCTAssertNil(reply["interferences"], "an old generation must not return a result")
        XCTAssertNil(reply["clearances"], "an old generation must not return detail rows")
        XCTAssertEqual(reply["detailsComplete"] as? Bool, false)
        XCTAssertEqual(reply["completed"] as? Bool, false)
        XCTAssertNil(reply["detailDigest"])
        let progress = try XCTUnwrap(reply["progress"] as? [String: Any])
        XCTAssertEqual(progress["phase"] as? String, "stale")
    }

    func testClosedDocumentRefusesInspectionWithoutStartingWorker() async {
        let service = service()
        document.close()
        let reply = await service.handleAsync(action: "interference", args: [:])
        XCTAssertEqual(reply["ok"] as? Bool, false)
        XCTAssertEqual(reply["error"] as? String, "closed")
        XCTAssertNil(service.interferenceProgress())
    }

    func testCloseCancelsAndJoinsWorkerWithoutAcceptingLateResults() async throws {
        let mesh = boxMesh(min: SIMD3(0, 0, 0), max: SIMD3(10, 10, 10))
        let bodyID = try makeMeshBody("Closing", positions: mesh.0, indices: mesh.1)
        let service = service()
        let ids = try (0..<20).map { index in
            try addInstance(service, bodyID: bodyID, name: "Closing\(index)",
                            position: [Double(index) * 20, 0, 0])
        }
        let gate = PairGate()
        CADAssemblyService.testInterferencePairProbe = { gate.observe($0) }
        defer { CADAssemblyService.testInterferencePairProbe = nil }
        let box = ReplyBox()
        let task = Task { @MainActor in
            box.reply = await service.handleAsync(action: "interference", args: ["instanceIDs": ids])
        }
        let reached = await Task.detached { gate.waitUntilPaused() }.value
        XCTAssertTrue(reached)
        document.close()
        gate.release()
        await task.value
        XCTAssertEqual(box.reply["ok"] as? Bool, false)
        XCTAssertEqual(box.reply["error"] as? String, "closed")
        XCTAssertEqual(box.reply["completed"] as? Bool, false)
        XCTAssertEqual(box.reply["detailsComplete"] as? Bool, false)
        XCTAssertLessThan(try XCTUnwrap(box.reply["processedPairCount"] as? Int), 190)
        XCTAssertNil(box.reply["clearances"])
        XCTAssertNil(box.reply["interferences"])
        XCTAssertNil(box.reply["detailDigest"])
        XCTAssertNil(service.interferenceProgress(), "the joined run must release its registry entry")
    }

    // MARK: E08 — real triangle contact/clearance and hollow nesting

    func testHollowNestedMeshReportsClearanceNotAABBPenetration() async throws {
        let hollow = hollowBoxMesh(outer: 10, inner: 5)
        let small = boxMesh(min: SIMD3(-2, -2, -2), max: SIMD3(2, 2, 2))
        let wall = boxMesh(min: SIMD3(-1, -1, -1), max: SIMD3(1, 1, 1))
        let iHollow = hollowBoxMesh(outer: 3, inner: 2)
        let hollowID = try makeMeshBody("Hollow", positions: hollow.0, indices: hollow.1)
        let smallID = try makeMeshBody("Small", positions: small.0, indices: small.1)
        let wallID = try makeMeshBody("Wall", positions: wall.0, indices: wall.1)
        let iHollowID = try makeMeshBody("InnerHollow", positions: iHollow.0,
                                         indices: iHollow.1)
        let service = service()
        let a = try addInstance(service, bodyID: hollowID, name: "Hollow")
        let b = try addInstance(service, bodyID: smallID, name: "InCavity")
        let c = try addInstance(service, bodyID: wallID, name: "InWall",
                                position: [7.5, 0, 0])
        let d = try addInstance(service, bodyID: iHollowID, name: "InnerHollow")

        let cavity = await service.handleAsync(action: "interference", args: [
            "instanceIDs": [a, b], "toleranceMM": 1e-6,
        ])
        XCTAssertEqual(cavity["ok"] as? Bool, true, "\(cavity)")
        XCTAssertEqual(cavity["interferingPairCount"] as? Int, 0,
                       "AABBs overlap, but the cavity is not material")
        XCTAssertEqual(cavity["separatedPairCount"] as? Int, 1)
        let cavityRow = try XCTUnwrap(rows(cavity, "clearances").first)
        XCTAssertEqual(cavityRow["classification"] as? String, "separated")
        XCTAssertEqual(try XCTUnwrap(cavityRow["minimumDistanceMM"] as? Double),
                       3.0, accuracy: 1e-5)
        XCTAssertEqual(cavityRow["containment"] as? String, "none")
        XCTAssertEqual(cavityRow["units"] as? String, "mm")
        XCTAssertGreaterThan(try XCTUnwrap(cavityRow["precisionMM"] as? Double), 0)
        let topology = try XCTUnwrap(cavityRow["meshTopologyA"] as? [String: Any])
        XCTAssertEqual(topology["watertight"] as? Bool, true)
        XCTAssertEqual(topology["components"] as? Int, 2)

        let nestedHollow = await service.handleAsync(action: "interference", args: [
            "instanceIDs": [a, d], "toleranceMM": 1e-6,
        ])
        XCTAssertEqual(nestedHollow["ok"] as? Bool, true, "\(nestedHollow)")
        XCTAssertEqual(nestedHollow["interferingPairCount"] as? Int, 0)
        let nestedRow = try XCTUnwrap(rows(nestedHollow, "clearances").first)
        XCTAssertEqual(try XCTUnwrap(nestedRow["minimumDistanceMM"] as? Double),
                       2.0, accuracy: 1e-5)
        XCTAssertEqual(nestedRow["containment"] as? String, "none")

        let embedded = await service.handleAsync(action: "interference", args: [
            "instanceIDs": [a, c], "toleranceMM": 1e-6,
        ])
        XCTAssertEqual(embedded["ok"] as? Bool, true, "\(embedded)")
        XCTAssertEqual(embedded["interferingPairCount"] as? Int, 1,
                       "a body inside the wall material is a real containment")
        let embeddedRow = try XCTUnwrap(rows(embedded, "interferences").first)
        XCTAssertEqual(embeddedRow["containment"] as? String, "bInsideA")
        XCTAssertEqual(try XCTUnwrap(embeddedRow["minimumDistanceMM"] as? Double),
                       1.5, accuracy: 1e-5)
        XCTAssertEqual(embeddedRow["exact"] as? Bool, false)
        XCTAssertNil(embeddedRow["volumeMM3"],
                     "a mesh result must never invent a B-rep volume")
    }

    func testTriangleIntersectionContactAndTransformedSeparation() async throws {
        let boxA = boxMesh(min: SIMD3(0, 0, 0), max: SIMD3(10, 10, 10))
        let boxB = boxMesh(min: SIMD3(5, 5, 5), max: SIMD3(15, 15, 15))
        let boxC = boxMesh(min: SIMD3(10, 0, 0), max: SIMD3(20, 10, 10))
        let boxD = boxMesh(min: SIMD3(11, 0, 0), max: SIMD3(21, 10, 10))
        let aID = try makeMeshBody("A", positions: boxA.0, indices: boxA.1)
        let bID = try makeMeshBody("B", positions: boxB.0, indices: boxB.1)
        let cID = try makeMeshBody("C", positions: boxC.0, indices: boxC.1)
        let dID = try makeMeshBody("D", positions: boxD.0, indices: boxD.1)
        let service = service()
        let a = try addInstance(service, bodyID: aID, name: "A")
        let b = try addInstance(service, bodyID: bID, name: "B")
        let c = try addInstance(service, bodyID: cID, name: "C")
        let d = try addInstance(service, bodyID: dID, name: "D",
                                position: [30, 0, 0],
                                rotation: [0, 0, sin(.pi / 4), cos(.pi / 4)])

        let overlap = await service.handleAsync(action: "interference", args: [
            "instanceIDs": [a, b], "toleranceMM": 1e-6,
        ])
        let overlapRow = try XCTUnwrap(rows(overlap, "interferences").first)
        XCTAssertEqual(overlapRow["classification"] as? String, "penetrating")
        XCTAssertEqual(overlapRow["surfaceCrossing"] as? Bool, true)
        XCTAssertEqual(overlapRow["minimumDistanceMM"] as? Double, 0.0)
        XCTAssertEqual(overlapRow["exact"] as? Bool, false)
        XCTAssertEqual(overlapRow["approximation"] as? String, "mesh")

        let touch = await service.handleAsync(action: "interference", args: [
            "instanceIDs": [a, c], "toleranceMM": 1e-6,
        ])
        XCTAssertEqual(touch["interferingPairCount"] as? Int, 0,
                       "a shared face is contact, not penetration")
        XCTAssertEqual(touch["contactPairCount"] as? Int, 1)

        let gap = await service.handleAsync(action: "interference", args: [
            "instanceIDs": [a, d], "toleranceMM": 1e-6,
        ])
        let gapRow = try XCTUnwrap(rows(gap, "clearances").first)
        XCTAssertEqual(gapRow["classification"] as? String, "separated")
        XCTAssertEqual(try XCTUnwrap(gapRow["minimumDistanceMM"] as? Double),
                       10.0, accuracy: 1e-4)
    }

    func testDegenerateTriangleIsHandledAsRealGeometry() async throws {
        let box = boxMesh(min: SIMD3(0, 0, 0), max: SIMD3(10, 10, 10))
        let boxID = try makeMeshBody("Box", positions: box.0, indices: box.1)
        let degenerate: ([SIMD3<Float>], [UInt32]) = (
            [SIMD3(50, 0, 0), SIMD3(51, 0, 0), SIMD3(52, 0, 0)],
            [0, 1, 2])
        let degenerateID = try makeMeshBody("Sliver", positions: degenerate.0,
                                            indices: degenerate.1)
        let service = service()
        let a = try addInstance(service, bodyID: boxID, name: "Box")
        let b = try addInstance(service, bodyID: degenerateID, name: "Sliver")

        let reply = await service.handleAsync(action: "interference", args: [
            "instanceIDs": [a, b], "toleranceMM": 1e-6,
        ])
        XCTAssertEqual(reply["ok"] as? Bool, true, "\(reply)")
        XCTAssertEqual(reply["unresolvedPairCount"] as? Int, 0)
        XCTAssertEqual(reply["separatedPairCount"] as? Int, 1)
        let row = try XCTUnwrap(rows(reply, "clearances").first)
        XCTAssertEqual(try XCTUnwrap(row["minimumDistanceMM"] as? Double),
                       40.0, accuracy: 1e-4)
    }

    func testNonFiniteMeshIsUnresolvedNotInterference() async throws {
        var mesh = boxMesh(min: SIMD3(0, 0, 0), max: SIMD3(10, 10, 10))
        mesh.0[0] = SIMD3(Float.nan, 0, 0)
        let badID = try makeMeshBody("Bad", positions: mesh.0, indices: mesh.1)
        let good = boxMesh(min: SIMD3(-5, -5, -5), max: SIMD3(5, 5, 5))
        let goodID = try makeMeshBody("Good", positions: good.0, indices: good.1)
        let service = service()
        let bad = try addInstance(service, bodyID: badID, name: "Bad")
        let goodInstance = try addInstance(service, bodyID: goodID, name: "Good")

        let reply = await service.handleAsync(action: "interference", args: [
            "instanceIDs": [bad, goodInstance], "toleranceMM": 1e-6,
        ])
        XCTAssertEqual(reply["ok"] as? Bool, true, "\(reply)")
        XCTAssertEqual(reply["interferingPairCount"] as? Int, 0)
        XCTAssertEqual(reply["unresolvedPairCount"] as? Int, 1)
        let row = try XCTUnwrap(rows(reply, "unresolvedPairs").first)
        XCTAssertTrue((row["unresolvedReason"] as? String ?? "").contains("non-finite"))
    }
}

// MARK: - Test seams

@MainActor
private final class ReplyBox {
    var reply: [String: Any] = [:]
}

private final class ProgressProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var snapshots: [CADAssemblyInterferenceProgressBox.Snapshot] = []
    private var offMain = false

    func record(_ snapshot: CADAssemblyInterferenceProgressBox.Snapshot) {
        lock.lock()
        snapshots.append(snapshot)
        if !Thread.isMainThread { offMain = true }
        lock.unlock()
    }

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return snapshots.count
    }

    var firstProcessed: Int? {
        lock.lock()
        defer { lock.unlock() }
        return snapshots.first?.processedPairCount
    }

    var lastProcessed: Int? {
        lock.lock()
        defer { lock.unlock() }
        return snapshots.last?.processedPairCount
    }

    var monotonic: Bool {
        lock.lock()
        defer { lock.unlock() }
        var previous = 0
        for snapshot in snapshots {
            if snapshot.processedPairCount != previous + 1 { return false }
            previous = snapshot.processedPairCount
        }
        return true
    }

    var sawOffMain: Bool {
        lock.lock()
        defer { lock.unlock() }
        return offMain
    }
}

private final class PairGate: @unchecked Sendable {
    private let lock = NSLock()
    private let reached = DispatchSemaphore(value: 0)
    private let resume = DispatchSemaphore(value: 0)
    private var paused = false

    func observe(_ snapshot: CADAssemblyInterferenceProgressBox.Snapshot) {
        lock.lock()
        let shouldPause = !paused && snapshot.processedPairCount == 1
        if shouldPause { paused = true }
        lock.unlock()
        if shouldPause {
            reached.signal()
            resume.wait()
        }
    }

    func waitUntilPaused() -> Bool {
        reached.wait(timeout: .now() + 10) == .success
    }

    func release() {
        resume.signal()
    }
}
