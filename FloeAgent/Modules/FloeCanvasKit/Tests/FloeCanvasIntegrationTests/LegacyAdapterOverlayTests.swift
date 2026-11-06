import XCTest
@testable import FloeCanvasCore
@testable import FloeCanvasIntegration

final class LegacyAdapterOverlayTests: XCTestCase {
    private let baseJSON = """
    {
      "id": "5F7A1B2C-3D4E-4F50-A1B2-C3D4E5F60718",
      "schemaVersion": 5,
      "name": "Board",
      "revision": 12,
      "createdAt": 752266496,
      "documents": [
        {
          "id": "9E8D7C6B-5A49-4837-9F0E-1D2C3B4A5960",
          "name": "Main",
          "pencilDrawingData": "AQID",
          "nodes": [
            { "id": "11111111-2222-3333-4444-555555555501",
              "kind": "text", "text": "hello",
              "x": 120, "y": 240, "width": 300, "height": 160,
              "groupID": "77777777-2222-3333-4444-555555555501",
              "metadata": { "priority": 3, "config": { "nested": true } } },
            { "id": "11111111-2222-3333-4444-555555555502",
              "kind": "text", "text": "lonely",
              "x": 0, "y": 0, "width": 10, "height": 10 }
          ],
          "connections": [
            { "id": "22222222-3333-4444-5555-666666666601",
              "sourceNodeID": "11111111-2222-3333-4444-555555555501",
              "destinationNodeID": "11111111-2222-3333-4444-555555555502",
              "kind": "arrow", "label": "ref",
              "sourcePort": "top", "destinationPort": "bottom",
              "style": { "dash": "4,2" } }
          ],
          "strokes": [
            { "id": "33333333-4444-5555-6666-777777777701",
              "points": [{ "x": 0, "y": 0 }, { "x": 5, "y": 5 }],
              "width": 3, "color": "primary", "isEraser": false,
              "pressure": [0.1, 0.5] }
          ]
        }
      ]
    }
    """

    private func reparse(_ data: Data) throws -> JSONValue {
        try JSONFidelity.parse(data)
    }

    func testExportPreservesConnectionLabelPortsAndUnknownFields() throws {
        let result = try LegacyCanvasAdapter.import(Data(baseJSON.utf8))
        let report = try LegacyCanvasAdapter.exportPreservingLegacyWithReport(result)
        let exported = try reparse(report.data)
        let connection = exported["documents"]?.arrayValue?[0]["connections"]?
            .arrayValue?[0].objectValue
        XCTAssertEqual(connection?["label"], .string("ref"))
        XCTAssertEqual(connection?["sourcePort"], .string("top"))
        XCTAssertEqual(connection?["destinationPort"], .string("bottom"))
        XCTAssertEqual(
            connection?["style"],
            .object(["dash": .string("4,2")]))
    }

    func testExportAppliesStrokeEditsAndRemovalsAndKeepsUnknownFields() throws {
        var result = try LegacyCanvasAdapter.import(Data(baseJSON.utf8))
        // Edit width + color, drop the pressure-carrying unknown field? No:
        // unknown fields must SURVIVE. Remove the stroke entirely instead.
        result.snapshot.pages[0].strokes[0].width = 9
        result.snapshot.pages[0].strokes[0].color = "accent"
        let edited = try LegacyCanvasAdapter.exportPreservingLegacy(result)
        let editedTree = try reparse(edited)
        let stroke = editedTree["documents"]?.arrayValue?[0]["strokes"]?
            .arrayValue?[0].objectValue
        XCTAssertEqual(stroke?["width"], .number("9.0"))
        XCTAssertEqual(stroke?["color"], .string("accent"))
        XCTAssertEqual(
            stroke?["pressure"],
            .array([.number("0.1"), .number("0.5")]))

        // Removing the stroke from the snapshot removes it on write-back.
        result.snapshot.pages[0].strokes = []
        let removed = try LegacyCanvasAdapter.exportPreservingLegacy(result)
        let removedTree = try reparse(removed)
        XCTAssertEqual(
            removedTree["documents"]?.arrayValue?[0]["strokes"],
            .array([]))
    }

    func testExportPreservesNonStringMetadataAndRemovesClearedGroupID() throws {
        var result = try LegacyCanvasAdapter.import(Data(baseJSON.utf8))
        var node = result.snapshot.pages[0].nodes[0]
        // A DTO-level metadata edit (string-only) overlays; original
        // non-string values underneath must survive.
        node.metadata["priority"] = "5"
        node.metadata["customFlag"] = "on"
        node.groupID = nil // cleared in the app
        result.snapshot.pages[0].nodes[0] = node

        let exported = try LegacyCanvasAdapter.exportPreservingLegacy(result)
        let tree = try reparse(exported)
        let legacyNode = tree["documents"]?.arrayValue?[0]["nodes"]?
            .arrayValue?[0].objectValue
        let metadata = legacyNode?["metadata"]?.objectValue
        XCTAssertEqual(metadata?["priority"], .string("5"))
        XCTAssertEqual(metadata?["customFlag"], .string("on"))
        // Original nested object payload preserved (not stringified).
        XCTAssertEqual(
            metadata?["config"],
            .object(["nested": .bool(true)]))
        // groupID was cleared: the original key must be gone.
        XCTAssertNil(legacyNode?["groupID"])
    }

    func testLossesReportedForStructuredContent() throws {
        var result = try LegacyCanvasAdapter.import(Data(baseJSON.utf8))
        result.snapshot.pages[0].nodes[0].content = .table(
            header: ["a"], rows: [["b"]])
        result.snapshot.pages[0].nodes[1].content = .richText(
            document: CanvasRichTextDocument(runs: [
                CanvasRichTextRun(text: "styled", bold: true)
            ]))
        let report = try LegacyCanvasAdapter.exportPreservingLegacyWithReport(result)
        XCTAssertTrue(report.losses.contains {
            $0.contains("content kind text is not representable")
        })
        XCTAssertTrue(report.losses.contains {
            $0.contains("rich-text runs/styles")
        })
    }

    func testMissingNodeIDDerivesDeterministicallyAcrossReopen() throws {
        var tree = try JSONFidelity.parse(Data(baseJSON.utf8)).objectValue!
        var document = tree["documents"]!.arrayValue![0].objectValue!
        var nodes = document["nodes"]!.arrayValue!
        var node = nodes[0].objectValue!
        node["id"] = nil
        nodes[0] = .object(node)
        document["nodes"] = .array(nodes)
        tree["documents"] = .array([.object(document)])
        let bytes = try JSONFidelity.serialize(.object(tree))

        let first = try LegacyCanvasAdapter.import(bytes)
        let second = try LegacyCanvasAdapter.import(bytes)
        XCTAssertEqual(
            first.snapshot.pages[0].nodes[0].id,
            second.snapshot.pages[0].nodes[0].id)
        XCTAssertTrue(first.plan.warnings.contains {
            $0.code == .missingIdentity && $0.path.contains("nodes[0]")
        })
    }

    func testDatesUseReferenceDateSemantics() throws {
        let result = try LegacyCanvasAdapter.import(Data(baseJSON.utf8))
        // 752266496 seconds after 2001-01-01 ≈ 2024-11-01.
        let expected = Date(timeIntervalSinceReferenceDate: 752266496)
        XCTAssertEqual(
            result.snapshot.createdAt.timeIntervalSinceReferenceDate,
            expected.timeIntervalSinceReferenceDate,
            accuracy: 0.001)
        // Sanity: NOT 1970 semantics (that would be ~1993-11-02).
        XCTAssertNotEqual(
            result.snapshot.createdAt.timeIntervalSince1970,
            752266496,
            accuracy: 1)
    }

    func testPencilDrawingRoundTripsThroughLegacyField() throws {
        let result = try LegacyCanvasAdapter.import(Data(baseJSON.utf8))
        XCTAssertEqual(
            result.snapshot.pages[0].pencilDrawingData, Data([1, 2, 3]))
        let exported = try LegacyCanvasAdapter.exportPreservingLegacy(result)
        let tree = try reparse(exported)
        XCTAssertEqual(
            tree["documents"]?.arrayValue?[0]["pencilDrawingData"],
            .string("AQID"))
    }
}
