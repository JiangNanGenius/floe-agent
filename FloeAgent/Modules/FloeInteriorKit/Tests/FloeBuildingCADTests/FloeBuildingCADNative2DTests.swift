// SPDX-License-Identifier: MPL-2.0
// SOURCE_ONLY_UNTIL_COORDINATOR_NATIVE_WINDOW
#if os(iOS)
import XCTest
import Foundation
import FloeCAD
import FloeInteriorCore
@testable import FloeBuildingCAD

final class FloeBuildingCADNative2DTests: XCTestCase {
    func testProjectedPolylineRetainsStraightCornersAndClosedSeam() throws {
        let p:[SIMD2<Double>]=[.init(0,0),.init(100,0),.init(100,50),.init(0,50)]
        let result=try FloeBuildingCADNativePolyline.segments(points:p,closed:true,maximumCount:4)
        XCTAssertEqual(result,[.init(a:p[0],b:p[1]),.init(a:p[1],b:p[2]),.init(a:p[2],b:p[3]),.init(a:p[3],b:p[0])])
        let repeated=try FloeBuildingCADNativePolyline.segments(points:p+[p[0]],closed:true,maximumCount:4)
        XCTAssertEqual(repeated,result)
    }
    func testProjectedPolylineRejectsInvalidVerticesAndExpandedBudget() throws {
        XCTAssertThrowsError(try FloeBuildingCADNativePolyline.segments(points:[.zero,.init(.nan,1),.init(2,2)],closed:false,maximumCount:4))
        XCTAssertThrowsError(try FloeBuildingCADNativePolyline.segments(points:[.zero,.init(1,0),.init(1,1)],closed:true,maximumCount:2))
    }
    @MainActor
    func testNative2DDocumentIsNonEmptyEditableReopensAndDoesNotWriteSource() async throws {
        let (session, root) = try await FloeBuildingCADTestSupport.makeSession("native2d")
        defer { session.close(); try? FileManager.default.removeItem(at: root) }
        let cabinet = try await session.createCabinet(FloeBuildingCADTestSupport.cabinetRecipe())
        let sheet = try await session.makeCombinationSheet(cabinet: cabinet)
        let sourceIdentity = try session.currentIdentity()
        let url = root.appendingPathComponent("Cabinet-2D.floecad", isDirectory: true)
        let receipt = try await session.createNative2DProject(
            pageDocument: session.document, pageID: sheet.pageID,
            sourcePageIdentity: sourceIdentity, at: url)
        XCTAssertEqual(receipt.sourcePageID, sheet.pageID)
        XCTAssertEqual(receipt.sourcePageIdentity.modelSHA256, sourceIdentity.modelSHA256)
        XCTAssertGreaterThan(receipt.entityCount, 0,
                             "A real native 2D deliverable cannot be empty.")
        XCTAssertFalse(receipt.sketchIDs.isEmpty)
        XCTAssertFalse(receipt.layers.isEmpty)
        XCTAssertFalse(receipt.losses.isEmpty)

        let reopened = try await FloeCADDocument.open(at: url)
        XCTAssertEqual(reopened.summary().sketchCount, receipt.sketchIDs.count)
        let outcome = reopened.nativeQueryJSON([
            "scope": "sketches", "sketchLimit": 512, "entityLimit": 1,
        ])
        XCTAssertTrue(outcome.isOK, outcome.message ?? "")
        let object = try XCTUnwrap(FloeBuildingCADGeometry.object(outcome))
        let rows = try XCTUnwrap(object["rows"] as? [[String: Any]])
        XCTAssertEqual(Set(rows.compactMap { FloeBuildingCADGeometry.uuid($0["id"]) }),
                       Set(receipt.sketchIDs))
        let total = rows.reduce(0) {
            $0 + (FloeBuildingCADGeometry.integer($1["entityTotal"]) ?? 0)
        }
        XCTAssertEqual(total, receipt.entityCount)
        let firstSketch = try XCTUnwrap(receipt.sketchIDs.first)
        let firstRow = try XCTUnwrap(rows.first {
            FloeBuildingCADGeometry.uuid($0["id"]) == firstSketch
        })
        let firstSketchCountBefore = try XCTUnwrap(
            FloeBuildingCADGeometry.integer(firstRow["entityTotal"]))

        // The native document is editable: append one line, save and reopen.
        let added = reopened.execute([
            "op": "sketch.addEntities",
            "args": [
                "sketchID": firstSketch.uuidString,
                "entities": [["kind": "line", "a": [0, 0], "b": [5, 0]]],
            ],
        ])
        XCTAssertTrue(added.isOK, added.message ?? "")
        let saved = await reopened.save()
        XCTAssertTrue(saved.succeeded)
        reopened.close()

        let edited = try await FloeCADDocument.open(at: url)
        defer { edited.close() }
        let editedOutcome = edited.nativeQueryJSON([
            "scope": "sketches", "sketchLimit": 512, "entityLimit": 1,
        ])
        let editedObject = try XCTUnwrap(FloeBuildingCADGeometry.object(editedOutcome))
        let editedRows = try XCTUnwrap(editedObject["rows"] as? [[String: Any]])
        let editedFirst = try XCTUnwrap(editedRows.first {
            FloeBuildingCADGeometry.uuid($0["id"]) == firstSketch
        })
        XCTAssertEqual(try XCTUnwrap(
            FloeBuildingCADGeometry.integer(editedFirst["entityTotal"])),
                       firstSketchCountBefore + 1)
        XCTAssertEqual(try session.currentIdentity().modelSHA256,
                       sourceIdentity.modelSHA256,
                       "Editing the independent native 2D document must not write the source page.")
    }

    @MainActor
    func testUnknownOrEmptyPageIsRefusedWithoutCreatingAFile() async throws {
        let (session, root) = try await FloeBuildingCADTestSupport.makeSession("native2d-empty")
        defer { session.close(); try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("Empty-2D.floecad", isDirectory: true)
        do {
            _ = try await session.createNative2DProject(
                pageID: UUID(), at: url)
            XCTFail("An unknown/empty drawing page must not become a native 2D document.")
        } catch let error as FloeBuildingCADError {
            guard case .projectionIncomplete = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    @MainActor
    func testAnnotationTextOptOutRecordsTheLossInsteadOfClaimingIt() async throws {
        let (session, root) = try await FloeBuildingCADTestSupport.makeSession("native2d-text-loss")
        defer { session.close(); try? FileManager.default.removeItem(at: root) }
        let cabinet = try await session.createCabinet(FloeBuildingCADTestSupport.cabinetRecipe())
        let sheet = try await session.makeCombinationSheet(cabinet: cabinet)
        let identity = try session.currentIdentity()
        var options = FloeBuildingCADNative2DOptions()
        options.includeAnnotationText = false
        let url = root.appendingPathComponent("Cabinet-2D-no-text.floecad", isDirectory: true)
        let receipt = try await session.createNative2DProject(
            pageDocument: session.document, pageID: sheet.pageID,
            sourcePageIdentity: identity, at: url, options: options)
        XCTAssertEqual(receipt.textCount, 0)
        XCTAssertTrue(receipt.losses.contains {
            $0.contains("deliberately omitted")
        }, "Opting out of text must produce an explicit loss, got: \(receipt.losses)")
        XCTAssertGreaterThan(receipt.entityCount, 0)
    }
}
#endif
