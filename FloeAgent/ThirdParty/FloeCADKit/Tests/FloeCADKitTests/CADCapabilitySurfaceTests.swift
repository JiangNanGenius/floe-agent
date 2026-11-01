// SPDX-License-Identifier: MPL-2.0
import Foundation
import XCTest
@testable import FloeCAD

final class CADCapabilitySurfaceTests: XCTestCase {
    func testUnimplementedModelTargetsAreNotOfferedByCommandSearch() {
        let registry = CommandRegistry()
        for id in ["model.wrap", "model.offsetFace", "model.offsetEdge"] {
            XCTAssertNil(registry.command(id: id), "A reserved name is not an executable command")
            XCTAssertFalse(CommandRegistry.all.contains { $0.id == id })
        }
        for id in ["model.extrude", "model.revolve", "model.sweep", "model.loft", "model.deleteFace", "model.replaceFace"] {
            XCTAssertNotNil(registry.command(id: id))
        }
        XCTAssertFalse(registry.search("wrap").contains { $0.id == "model.wrap" })
    }

    @MainActor
    func testLongNativeFeatureQueryCanReadEveryPageWithoutChangingTheDocument() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("NativeQueryPages-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("Paged.floecad", isDirectory: true)
        let document = try await FloeCADDocument.create(at: url, name: "Paged native query")
        defer { document.close(); try? FileManager.default.removeItem(at: directory) }
        // Cross the actual 500-row ceiling; long names also make the first
        // page exceed a 64 KiB textual excerpt. These are real feature nodes
        // and native bodies, not a mocked query response.
        let nodes = (0..<507).map { index in
            FeatureNode(name: "Part \(index) " + String(repeating: "p", count: 180),
                        kind: .primitive(spec: .box(width: 2, depth: 3, height: 4),
                                         placement: .identity),
                        outputBodyIDs: [BodyID()])
        }
        document.session.recordAndRebuild(nodes, title: "Create paged model")
        XCTAssertTrue(document.session.lastEvalErrors.isEmpty)
        _ = try await document.save()
        let stored = await FloeCADDocument.storedIdentity(at: url)
        let identity = try XCTUnwrap(stored)
        let changeCount = document.session.changeCount
        func page(offset: Int, limit: Int) throws -> (rows: [[String: Any]], bytes: Int) {
            let outcome = document.nativeQueryJSON([
                "scope": "features", "offset": offset, "limit": limit])
            XCTAssertTrue(outcome.isOK, outcome.message ?? "Native query failed")
            let object = try XCTUnwrap(JSONSerialization.jsonObject(
                with: outcome.payload) as? [String: Any])
            XCTAssertEqual(object["total"] as? Int, nodes.count)
            return (try XCTUnwrap(object["rows"] as? [[String: Any]]), outcome.payload.count)
        }
        let first = try page(offset: 0, limit: 500)
        XCTAssertEqual(first.rows.count, 500)
        XCTAssertGreaterThan(first.bytes, 64 * 1024)
        XCTAssertEqual(try page(offset: 500, limit: 500).rows.count, 7)
        XCTAssertTrue(try page(offset: nodes.count, limit: 500).rows.isEmpty)
        var ids: [String] = []
        for offset in stride(from: 0, to: nodes.count, by: 73) {
            let rows = try page(offset: offset, limit: 73).rows
            ids += try rows.map { try XCTUnwrap($0["id"] as? String) }
        }
        XCTAssertEqual(ids, nodes.map { $0.id.raw.uuidString })
        XCTAssertEqual(Set(ids).count, nodes.count)
        XCTAssertEqual(document.session.changeCount, changeCount)
        let storedAfter = await FloeCADDocument.storedIdentity(at: url)
        let after = try XCTUnwrap(storedAfter)
        XCTAssertEqual(after.revision, identity.revision)
        XCTAssertEqual(after.contentSHA256, identity.contentSHA256)
        XCTAssertEqual(after.modelSHA256, identity.modelSHA256)
        let attachment = XCTAttachment(string:
            "actualFeatures=\(nodes.count); firstPageRows=\(first.rows.count); "
                + "firstPageBytes=\(first.bytes); pagedIDs=\(ids.count); "
                + "sameStoredIdentity=\(after.contentSHA256 == identity.contentSHA256)")
        attachment.name = "native-long-query-page-witness.txt"
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
