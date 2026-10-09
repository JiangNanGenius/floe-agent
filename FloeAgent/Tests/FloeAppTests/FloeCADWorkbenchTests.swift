// FloeAppTests — native FloeCAD workbench document smoke.
//
// Verifies the app target links FloeCADKit and that the public facade drives a
// document through create → edit → save → reopen off-main. The full geometric
// fixture (plate + through-hole volume, STEP export) lives in the package's
// focused suite (FloeCADKitTests/PlateHoleFixtureTests); this test proves the
// app-side integration surface works inside the app process.
//
// SPDX-License-Identifier: MPL-2.0

#if canImport(SwiftUI) && canImport(UIKit)
import XCTest
import FloeCAD

@MainActor
final class FloeCADWorkbenchTests: XCTestCase {

    func testCreateEditSaveReopenThroughAppFacade() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("floe-cad-app-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("part.floecad")

        let document = try await FloeCADDocument.create(at: url, name: "Part")
        let summary = document.summary()
        XCTAssertEqual(summary.name, "Part")
        XCTAssertGreaterThan(summary.revision, 0)
        XCTAssertEqual(summary.contentSHA256.count, 64)

        let sketch = document.executeJSON(Data(#"{"op":"sketch.create","args":{"name":"Base"}}"#.utf8))
        XCTAssertTrue(sketch.isOK, sketch.message ?? "")
        let sketchID = try XCTUnwrap(
            ((try? JSONSerialization.jsonObject(with: sketch.payload)) as? [String: Any])?["sketchID"] as? String)
        XCTAssertTrue(document.executeJSON(Data("""
        {"op":"sketch.addEntities","args":{"sketchID":"\(sketchID)",
         "entities":[{"kind":"rect","min":[0,0],"max":[40,20]}]}}
        """.utf8)).isOK)
        let extrude = document.executeJSON(Data("""
        {"op":"feature.extrude","args":{"sketchID":"\(sketchID)","seedPoint":[1,1],"distance":6}}
        """.utf8))
        XCTAssertTrue(extrude.isOK, extrude.message ?? "")

        let measure = document.measureJSON(["kind": "body",
                                            "bodyID": try liveBodyID(document)])
        XCTAssertTrue(measure.isOK, measure.message ?? "")
        let measured = (try? JSONSerialization.jsonObject(with: measure.payload)) as? [String: Any]
        XCTAssertEqual((measured?["volumeMM3"] as? Double) ?? 0, 40 * 20 * 6, accuracy: 1e-3)
        XCTAssertEqual(measured?["analyticBRep"] as? Bool, true)

        let save = await document.save()
        XCTAssertTrue(save.succeeded, save.error ?? "")
        XCTAssertGreaterThan(save.revision, summary.revision)
        document.close()

        let reopened = try await FloeCADDocument.open(at: url)
        let reopenedMeasure = reopened.measureJSON(["kind": "body",
                                                    "bodyID": try liveBodyID(reopened)])
        let reopenedObject = (try? JSONSerialization.jsonObject(with: reopenedMeasure.payload)) as? [String: Any]
        XCTAssertEqual((reopenedObject?["volumeMM3"] as? Double) ?? 0, 40 * 20 * 6, accuracy: 1e-3)
        reopened.close()
    }

    private func liveBodyID(_ document: FloeCADDocument) throws -> String {
        let snapshot = try XCTUnwrap(
            (try? JSONSerialization.jsonObject(with: document.snapshotJSON())) as? [String: Any])
        let bodies = try XCTUnwrap(snapshot["bodies"] as? [[String: Any]])
        return try XCTUnwrap(bodies.first?["id"] as? String)
    }
}
#endif
