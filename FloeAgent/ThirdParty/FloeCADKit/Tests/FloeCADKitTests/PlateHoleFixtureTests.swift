//
//  PlateHoleFixtureTests.swift
//  FloeCADKitTests
//
//  The shared critical-exactness fixture from the task acceptance:
//    100 × 60 × 10 mm rectangular plate with a fully internal Ø10 mm
//    through-hole. Volume must be 60000 − 250π mm³; changing the plate
//    thickness to 20 mm must give 120000 − 500π mm³ with the hole diameter
//    unchanged. The fixture is driven through the same typed command
//    vocabulary the AI tool uses, saved, reopened, and exported to STEP.
//

import XCTest
import simd
@testable import FloeCAD

final class PlateHoleFixtureTests: XCTestCase {

    private var workDir: URL!

    override func setUpWithError() throws {
        workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("FloeCADFixture-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let workDir { try? FileManager.default.removeItem(at: workDir) }
    }

    // MARK: Helpers

    private func run(_ document: FloeCADDocument, _ json: String,
                     file: StaticString = #filePath, line: UInt = #line) -> [String: Any] {
        let outcome = document.executeJSON(Data(json.utf8))
        XCTAssertTrue(outcome.isOK,
                      "command failed (\(outcome.status)) \(outcome.errorCode ?? ""): "
                        + "\(outcome.message ?? "") — \(json)",
                      file: file, line: line)
        let object = (try? JSONSerialization.jsonObject(with: outcome.payload)) as? [String: Any]
        return object ?? [:]
    }

    private func measureBody(_ document: FloeCADDocument, _ bodyID: String,
                             file: StaticString = #filePath, line: UInt = #line) -> [String: Any] {
        let outcome = document.measureJSON(["kind": "body", "bodyID": bodyID])
        if !outcome.isOK {
            let snap = String(data: document.snapshotJSON(), encoding: .utf8) ?? "?"
            XCTFail("measure failed for \(bodyID): \(outcome.message ?? "") snapshot=\(snap)",
                    file: file, line: line)
        }
        return (try? JSONSerialization.jsonObject(with: outcome.payload)) as? [String: Any] ?? [:]
    }

    private func liveBodyID(_ document: FloeCADDocument) throws -> String {
        let snapshot = try XCTUnwrap(
            (try? JSONSerialization.jsonObject(with: document.snapshotJSON())) as? [String: Any])
        let bodies = try XCTUnwrap(snapshot["bodies"] as? [[String: Any]])
        return try XCTUnwrap(bodies.first?["id"] as? String)
    }

    private func firstBodyID(_ response: [String: Any]) -> String? {
        if let produced = (response["producedBodyIDs"] as? [String])?.first { return produced }
        return (response["changedBodyIDs"] as? [String])?.first
    }

    // MARK: Fixture

    func testPlateWithInternalThroughHoleVolumeAndParameterEdit() async throws {
        let url = workDir.appendingPathComponent("plate.floecad")
        let document = try await FloeCADDocument.create(at: url, name: "PlateHole")

        // 1. Plate sketch: 100 × 60 rectangle on the ground plane.
        let plateSketch = run(document,
            #"{"op":"sketch.create","args":{"name":"Plate"}}"#)["sketchID"] as? String
        let plateSketchID = try XCTUnwrap(plateSketch)
        _ = run(document, """
        {"op":"sketch.addEntities","args":{"sketchID":"\(plateSketchID)",
         "entities":[{"kind":"rect","min":[0,0],"max":[100,60]}]}}
        """)

        // 2. Extrude 10 mm.
        let plateExtrude = run(document, """
        {"op":"feature.extrude","args":{"sketchID":"\(plateSketchID)","seedPoint":[50,30],
         "distance":10}}
        """)
        let plateBodyID = try XCTUnwrap(firstBodyID(plateExtrude))

        // 3. Hole sketch: Ø10 circle centered at (50, 30) — fully internal.
        let holeSketch = run(document,
            #"{"op":"sketch.create","args":{"name":"Hole"}}"#)["sketchID"] as? String
        let holeSketchID = try XCTUnwrap(holeSketch)
        _ = run(document, """
        {"op":"sketch.addEntities","args":{"sketchID":"\(holeSketchID)",
         "entities":[{"kind":"circle","center":[50,30],"radius":5}]}}
        """)

        // 4. Symmetric extrude of the circle and subtract from the plate.
        let holeCut = run(document, """
        {"op":"feature.extrude","args":{"sketchID":"\(holeSketchID)","seedPoint":[50,30],
         "distance":40,"symmetric":true,"boolean":"subtract","booleanTargets":["\(plateBodyID)"]}}
        """)
        XCTAssertNotEqual(holeCut["failed"] as? Bool, true,
                          "the subtract feature reported evaluation errors: \(holeCut)")
        // The document now has exactly one body (the subtract replaces the
        // target in place) and it must still be analytic.
        let afterCut = document.snapshotJSON()
        let snapshot = try XCTUnwrap(
            (try? JSONSerialization.jsonObject(with: afterCut)) as? [String: Any])
        let bodies = try XCTUnwrap(snapshot["bodies"] as? [[String: Any]])
        XCTAssertEqual(bodies.count, 1)
        XCTAssertEqual(bodies.first?["brep"] as? Bool, true,
                       "the plate+hole body lost its analytic B-rep")
        // A boolean replaces its target in place; always measure the LIVE body
        // id from the post-cut snapshot rather than assuming id stability.
        let cutBodyID = try XCTUnwrap(bodies.first?["id"] as? String,
                                      "post-cut snapshot body rows: \(bodies)")

        // 5. Exact volume: 60000 − 250π mm³.
        let expected = 60_000.0 - 250.0 * Double.pi
        let measured = measureBody(document, cutBodyID)
        let volume = try XCTUnwrap(measured["volumeMM3"] as? Double)
        XCTAssertEqual(volume, expected, accuracy: 1e-3,
                       "volume must be the analytic 60000−250π mm³")

        // Bounds stay the plate envelope, not the hole.
        let bounds = try XCTUnwrap(measured["bounds"] as? [[Double]])
        // The ground plane is XZ with +Y up: the 100×60 rectangle maps to
        // x ∈ [0,100], z ∈ [-60,0], and the 10 mm thickness is along +Y.
        XCTAssertEqual(bounds[0][0], 0, accuracy: 1e-6)
        XCTAssertEqual(bounds[0][1], 0, accuracy: 1e-6)
        XCTAssertEqual(bounds[0][2], -60, accuracy: 1e-6)
        XCTAssertEqual(bounds[1][0], 100, accuracy: 1e-6)
        XCTAssertEqual(bounds[1][1], 10, accuracy: 1e-6)
        XCTAssertEqual(bounds[1][2], 0, accuracy: 1e-6)

        // 6. Save, reopen, and verify the SAME analytic volume.
        let save = await document.save()
        XCTAssertTrue(save.succeeded, "save failed: \(save.error ?? "")")
        XCTAssertGreaterThan(save.revision, 0)
        XCTAssertEqual(save.contentSHA256.count, 64)
        document.close()

        let reopened = try await FloeCADDocument.open(at: url)
        XCTAssertFalse(reopened.isReadOnly)
        let reopenedBodies = try XCTUnwrap(
            ((try? JSONSerialization.jsonObject(with: reopened.snapshotJSON())) as? [String: Any])?["bodies"] as? [[String: Any]])
        XCTAssertEqual(reopenedBodies.count, 1)
        XCTAssertEqual(reopenedBodies.first?["brep"] as? Bool, true,
                       "reopened body must keep analytic geometry")
        let reopenedBodyID = try liveBodyID(reopened)
        let reopenedVolume = try XCTUnwrap(measureBody(reopened, reopenedBodyID)["volumeMM3"] as? Double)
        XCTAssertEqual(reopenedVolume, expected, accuracy: 1e-3,
                       "reopened volume must match the saved analytic solid")

        // 7. STEP export, then an independent bytes-level read-back.
        let step = try XCTUnwrap(reopened.viewModel().exportSTEP(),
                                 "STEP export returned nothing")
        // Also leave the bytes on disk for the host-side independent STEP
        // reader (scripts/verify_step_independent.py); the simulator's
        // temporary directory is host-readable under CoreSimulator.
        let evidenceDir = try XCTUnwrap(FileManager.default.urls(
            for: .documentDirectory, in: .userDomainMask).first)
            .appendingPathComponent("floe-cad-evidence", isDirectory: true)
        try FileManager.default.createDirectory(at: evidenceDir, withIntermediateDirectories: true)
        let evidenceURL = evidenceDir.appendingPathComponent("plate-10mm.step")
        try step.write(to: evidenceURL)
        print("FLOE_STEP_EVIDENCE \(evidenceURL.path)")
        let stepText = try XCTUnwrap(String(data: step, encoding: .utf8))
        XCTAssertTrue(stepText.contains("ISO-10303-21"), "not a STEP part 21 file")
        XCTAssertTrue(stepText.contains("MILLI"), "STEP units must be millimetres")
        XCTAssertTrue(stepText.contains("CYLINDRICAL_SURFACE"),
                      "the hole must export as an analytic cylinder, not facets")
        // The same bytes read back through the kernel produce the same volume
        // and bounds (file-level round-trip).
        let solids = STEPKit.solids(from: step)
        XCTAssertEqual(solids.count, 1, "STEP must hold exactly one solid")
        if let solid = solids.first {
            XCTAssertEqual(OCCTKernel.volume(solid), expected, accuracy: 1e-3)
        }

        // 8. Parameter edit: plate thickness 10 → 20. The hole diameter must
        //    be unchanged, so the volume becomes 120000 − 500π mm³ and the
        //    bounding box grows only in Z.
        let session = reopened.session
        let plateNode = try XCTUnwrap(session.document.features.nodes.first { node in
            guard case let .extrude(_, _, distance, symmetric, _, _) = node.kind else { return false }
            return !symmetric && abs(distance.value - 10) < 1e-9
        })
        guard case let .extrude(profile, plane, _, symmetric, boolean, extra) = plateNode.kind else {
            return XCTFail("plate node changed kind")
        }
        let edited = FeatureKind.extrude(profile: profile, plane: plane,
                                         distance: Expr(value: 20),
                                         symmetric: symmetric, boolean: boolean,
                                         extraProfiles: extra)
        session.rebuildFrom(plateNode.id,
                            edit: EditFeatureCommand(featureID: plateNode.id,
                                                     before: plateNode.kind, after: edited))
        try XCTUnwrap(reopened.viewModel().errorMessage == nil ? true : nil,
                      "rebuild reported: \(reopened.viewModel().errorMessage ?? "")")

        let thickBodyID = try liveBodyID(reopened)
        let thickVolume = try XCTUnwrap(measureBody(reopened, thickBodyID)["volumeMM3"] as? Double)
        XCTAssertEqual(thickVolume, 120_000.0 - 500.0 * Double.pi, accuracy: 2e-3,
                       "20 mm plate volume must be 120000−500π mm³ (hole Ø unchanged)")
        let thickBounds = try XCTUnwrap(measureBody(reopened, thickBodyID)["bounds"] as? [[Double]])
        XCTAssertEqual(thickBounds[0][1], 0, accuracy: 1e-6)
        XCTAssertEqual(thickBounds[1][1], 20, accuracy: 1e-6)
        XCTAssertEqual(thickBounds[1][0], 100, accuracy: 1e-6)
        XCTAssertEqual(thickBounds[0][2], -60, accuracy: 1e-6)
        XCTAssertEqual(thickBounds[1][2], 0, accuracy: 1e-6)

        // The rebuild must be undoable: one undo restores 10 mm.
        session.undo()
        let undoneVolume = try XCTUnwrap(measureBody(reopened, try liveBodyID(reopened))["volumeMM3"] as? Double)
        XCTAssertEqual(undoneVolume, expected, accuracy: 1e-3)
        session.redo()
        let redoneVolume = try XCTUnwrap(measureBody(reopened, try liveBodyID(reopened))["volumeMM3"] as? Double)
        XCTAssertEqual(redoneVolume, 120_000.0 - 500.0 * Double.pi, accuracy: 2e-3)

        // 9. Write the 20 mm STEP evidence from the rebuilt analytic solids,
        //    and verify the file re-reads through the kernel as one solid.
        switch STEPKit.export(bodies: reopened.session.document.bodies) {
        case let .success(thickStep, _):
            let evidenceURL = evidenceDir.appendingPathComponent("plate-20mm.step")
            try thickStep.write(to: evidenceURL)
            print("FLOE_STEP_EVIDENCE_20 \(evidenceURL.path)")
            let thickSolids = STEPKit.solids(from: thickStep)
            XCTAssertEqual(thickSolids.count, 1, "20 mm STEP must hold exactly one solid")
            if let solid = thickSolids.first {
                XCTAssertEqual(OCCTKernel.volume(solid), 120_000.0 - 500.0 * Double.pi,
                               accuracy: 2e-3)
            }
        case .nothingAnalytic(let skipped):
            XCTFail("20 mm STEP export had no analytic body (skipped: \(skipped))")
        case .failed:
            XCTFail("20 mm STEP export failed")
        }

        // 10. Saving after the parameter edit keeps CAS identity moving.
        let secondSave = await reopened.save()
        XCTAssertTrue(secondSave.succeeded)
        XCTAssertGreaterThan(secondSave.revision, save.revision)
        XCTAssertNotEqual(secondSave.contentSHA256, save.contentSHA256)
        reopened.close()
    }
}
