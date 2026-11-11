// SPDX-License-Identifier: MPL-2.0
// GIS observation artifact contracts: a project.observe result becomes the
// shared verified image artifact only when it is revision-bound, sniffed PNG
// and within the hard bound. No WK engine is claimed here.
#if canImport(UIKit) && DEBUG
import XCTest
import UIKit
import FloeCore
import FloeModels
import FloeTools
import FloeHeavyEditorSupport
@testable import FloeApp

@MainActor
final class GISAssistantVisualTests: XCTestCase {
    private func pngData() throws -> Data {
        let format = UIGraphicsImageRendererFormat(); format.scale = 1; format.opaque = true
        return UIGraphicsImageRenderer(size: .init(width: 8, height: 6), format: format).pngData { context in
            UIColor.systemTeal.setFill(); context.fill(.init(x: 0, y: 0, width: 8, height: 6))
        }
    }
    private func observationResult(revision: UInt64, baseRevision: UInt64, image: EditorJSON) -> EditorJSON {
        .object(["projectID": .string(UUID().uuidString), "baseRevision": .number(Double(baseRevision)),
            "result": .object(["revision": .number(Double(revision)), "crs": .string("EPSG:3857"),
                "extent": .array([0, 1, 2, 3].map { .number(Double($0)) }), "width": .number(800), "height": .number(600),
                "view": .object(["center": .array([.number(0), .number(20)]), "zoom": .number(2)]),
                "layers": .array([.object(["id": .string("layer-1"), "name": .string("Zones"), "kind": .string("vector"), "crs": .string("EPSG:4326"), "index": .number(0), "visible": .bool(true), "locked": .bool(false), "opacity": .number(1), "featureCount": .number(2)])]),
                "selection": .object(["layerID": .string("layer-1"), "featureIDs": .array([.string("f-1")]), "count": .number(1)]),
                "image": image]), "exports": .array([])])
    }
    private func imageJSON(_ data: Data, mediaType: String = "image/png") -> EditorJSON {
        .object(["mediaType": .string(mediaType), "base64": .string(data.base64EncodedString())])
    }
    private func withRoot(_ body: (URL) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("GISObservation-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try body(root)
    }
    func testObservationBecomesVerifiedArtifactAndTextKeepsIdentityOnly() throws {
        try withRoot { root in
            let png = try pngData(), runID = UUID(), revision: UInt64 = 7
            let result = observationResult(revision: revision, baseRevision: revision, image: imageJSON(png))
            let render = try XCTUnwrap(GISObservationArtifact.makeIfPresent(result: result, expectedRevision: revision, runID: runID, root: root))
            XCTAssertEqual(render.byteCount, png.count)
            XCTAssertEqual(render.sha256, FloeDigest.sha256Hex(png))
            XCTAssertEqual(render.reference.relativePath, "EngineeringObservations/\(runID.uuidString)/\(render.sha256).png")
            XCTAssertNoThrow(try VerifiedToolImageArtifact.load(render.reference, root: root))
            // The same revision observed twice stays one content-addressed file.
            let again = try XCTUnwrap(GISObservationArtifact.makeIfPresent(result: result, expectedRevision: revision, runID: runID, root: root))
            XCTAssertEqual(again.reference.relativePath, render.reference.relativePath)
            guard case .object(var body) = result else { return XCTFail("envelope") }
            GISObservationArtifact.rewriting(&body, render: render)
            let image = try XCTUnwrap(body["result"]?["image"])
            XCTAssertNil(image["base64"].string)
            XCTAssertEqual(image["artifact"].string, render.reference.relativePath)
            XCTAssertEqual(image["sha256"].string, render.sha256)
            XCTAssertEqual(image["byteCount"].number, Double(png.count))
            XCTAssertNotNil(image["note"].string)
        }
    }
    func testStaleOrMalformedObservationsNeverBecomeEvidence() throws {
        try withRoot { root in
            let png = try pngData(), runID = UUID(), revision: UInt64 = 7
            // Envelope revision drift and render revision drift both fail closed.
            let staleEnvelope = observationResult(revision: revision, baseRevision: revision + 1, image: imageJSON(png))
            XCTAssertThrowsError(try GISObservationArtifact.makeIfPresent(result: staleEnvelope, expectedRevision: revision, runID: runID, root: root)) { guard case HeavyEditorError.revisionConflict = $0 else { return XCTFail("Expected revisionConflict, got \($0)") } }
            let staleRender = observationResult(revision: revision - 1, baseRevision: revision, image: imageJSON(png))
            XCTAssertThrowsError(try GISObservationArtifact.makeIfPresent(result: staleRender, expectedRevision: revision, runID: runID, root: root)) { guard case HeavyEditorError.revisionConflict = $0 else { return XCTFail("Expected revisionConflict, got \($0)") } }
            // Declared PNG must be actual PNG bytes.
            let text = observationResult(revision: revision, baseRevision: revision, image: imageJSON(Data("not a png".utf8)))
            XCTAssertThrowsError(try GISObservationArtifact.makeIfPresent(result: text, expectedRevision: revision, runID: runID, root: root)) { guard case HeavyEditorError.invalidDocument = $0 else { return XCTFail("Expected invalidDocument, got \($0)") } }
            // Another declared family is rejected even with real image bytes.
            let jpeg = observationResult(revision: revision, baseRevision: revision, image: imageJSON(png, mediaType: "image/jpeg"))
            XCTAssertThrowsError(try GISObservationArtifact.makeIfPresent(result: jpeg, expectedRevision: revision, runID: runID, root: root)) { guard case HeavyEditorError.invalidDocument = $0 else { return XCTFail("Expected invalidDocument, got \($0)") } }
            // Over the hard bound fails without writing anything.
            var oversized = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
            oversized.append(Data(count: GISObservationArtifact.maximumRenderBytes))
            let big = observationResult(revision: revision, baseRevision: revision, image: imageJSON(oversized))
            XCTAssertThrowsError(try GISObservationArtifact.makeIfPresent(result: big, expectedRevision: revision, runID: runID, root: root)) { guard case HeavyEditorError.invalidDocument = $0 else { return XCTFail("Expected invalidDocument, got \($0)") } }
            XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("EngineeringObservations").path))
        }
    }
    func testOrdinaryResultsDoNotTouchArtifactStorage() throws {
        try withRoot { root in
            let ordinary: EditorJSON = .object(["projectID": .string(UUID().uuidString), "baseRevision": .number(3),
                "result": .object(["layers": .array([])]), "exports": .array([])])
            XCTAssertNil(try GISObservationArtifact.makeIfPresent(result: ordinary, expectedRevision: 3, runID: UUID(), root: root))
            XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("EngineeringObservations").path))
        }
    }
}
#endif
