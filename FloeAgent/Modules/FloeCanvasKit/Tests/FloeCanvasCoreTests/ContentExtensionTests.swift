import XCTest
@testable import FloeCanvasCore

final class ContentExtensionTests: XCTestCase {
    // MARK: Rich text

    func testRichTextRoundTripThroughNativeArchive() throws {
        let document = CanvasRichTextDocument(runs: [
            CanvasRichTextRun(
                text: "Bold red ", bold: true,
                foregroundColor: "#FF0000"),
            CanvasRichTextRun(
                text: "linked", underline: true,
                link: URL(string: "https://example.com")!),
            CanvasRichTextRun(
                text: " struck", italic: true, strikethrough: true),
        ])
        let node = CanvasNodeSnapshot(
            content: .richText(document: document),
            frame: CanvasGeometry.Frame(
                center: .zero, size: .init(width: 10, height: 10)))
        let snapshot = CanvasSnapshot(
            name: "RT", pages: [CanvasPageSnapshot(nodes: [node])])
        let decoded = try JSONDecoder().decode(
            CanvasSnapshot.self, from: JSONEncoder().encode(snapshot))
        guard case .richText(let decodedDocument) =
            decoded.pages[0].nodes[0].content else {
            XCTFail("rich text lost")
            return
        }
        XCTAssertEqual(decodedDocument, document)
        XCTAssertEqual(decodedDocument.plainText, "Bold red linked struck")
    }

    func testAttributedStringUsesCanonicalAttributeKeys() {
        let document = CanvasRichTextDocument(runs: [
            CanvasRichTextRun(
                text: "x", bold: true, link: URL(string: "https://a.b")!,
                foregroundColor: "primary")
        ])
        let attributed = document.makeAttributedString()
        XCTAssertEqual(attributed.length, 1)
        XCTAssertEqual(attributed.attribute(
            CanvasRichTextAttribute.bold, at: 0, effectiveRange: nil) as? Bool,
            true)
        XCTAssertNotNil(attributed.attribute(
            CanvasRichTextAttribute.link, at: 0, effectiveRange: nil))
        XCTAssertEqual(attributed.attribute(
            CanvasRichTextAttribute.foregroundColor, at: 0,
            effectiveRange: nil) as? String, "primary")
    }

    // MARK: Shapes

    func testShapeRoundTripAndMissingFieldCompatibility() throws {
        let node = CanvasNodeSnapshot(
            content: .shape(kind: .diamond, text: "Decision"),
            frame: CanvasGeometry.Frame(
                center: .zero, size: .init(width: 10, height: 10)))
        let snapshot = CanvasSnapshot(
            name: "S", pages: [CanvasPageSnapshot(nodes: [node])])
        let decoded = try JSONDecoder().decode(
            CanvasSnapshot.self, from: JSONEncoder().encode(snapshot))
        guard case .shape(let kind, let text) =
            decoded.pages[0].nodes[0].content else {
            XCTFail("shape lost")
            return
        }
        XCTAssertEqual(kind, .diamond)
        XCTAssertEqual(text, "Decision")

        // Shape with missing text decodes as empty string.
        let json = """
        {
          "kind": "shape",
          "shapeKind": "arrow"
        }
        """.data(using: .utf8)!
        let content = try JSONDecoder().decode(CanvasContent.self, from: json)
        XCTAssertEqual(content, .shape(kind: .arrow, text: ""))
    }

    func testVisualStyleValidation() {
        XCTAssertTrue(CanvasVisualStyle.isValidColorString("#FF0000"))
        XCTAssertTrue(CanvasVisualStyle.isValidColorString("#f00"))
        XCTAssertTrue(CanvasVisualStyle.isValidColorString("#FF000080"))
        XCTAssertTrue(CanvasVisualStyle.isValidColorString("primary"))
        XCTAssertFalse(CanvasVisualStyle.isValidColorString("#FF00"))
        XCTAssertFalse(CanvasVisualStyle.isValidColorString(""))
        XCTAssertFalse(CanvasVisualStyle.isValidColorString("Not A Color"))
        XCTAssertTrue(CanvasVisualStyle.isValidStrokeWidth(0))
        XCTAssertTrue(CanvasVisualStyle.isValidStrokeWidth(2.5))
        XCTAssertFalse(CanvasVisualStyle.isValidStrokeWidth(-1))
        XCTAssertFalse(CanvasVisualStyle.isValidStrokeWidth(.nan))

        let style = CanvasVisualStyle(
            fillColor: "#00FF00", strokeWidth: 1.5)
        XCTAssertTrue(style.isValid)
        var metadata: [String: String] = [:]
        style.applied(to: &metadata)
        XCTAssertEqual(metadata[CanvasVisualMetadataKeys.fillColor], "#00FF00")
        XCTAssertEqual(metadata[CanvasVisualMetadataKeys.strokeWidth], "1.5")
        XCTAssertEqual(
            CanvasVisualStyle(metadata: metadata)?.strokeColor, nil)
    }

    // MARK: PDF range validation

    func testPdfReversedAndNegativeRangesThrowInsteadOfTrapping() {
        let reversed = """
        {"kind": "pdf", "pageLower": 5, "pageUpper": 2}
        """.data(using: .utf8)!
        XCTAssertThrowsError(
            try JSONDecoder().decode(CanvasContent.self, from: reversed)) { error in
            guard case DecodingError.dataCorrupted = error else {
                XCTFail("expected dataCorrupted, got \(error)")
                return
            }
        }
        let negative = """
        {"kind": "pdf", "pageLower": -1, "pageUpper": 3}
        """.data(using: .utf8)!
        XCTAssertThrowsError(
            try JSONDecoder().decode(CanvasContent.self, from: negative))

        let valid = CanvasContent.pdf(
            documentAssetID: nil, pageRange: 2...5)
        let decoded = try! JSONDecoder().decode(
            CanvasContent.self, from: JSONEncoder().encode(valid))
        XCTAssertEqual(decoded, valid)
    }

    // MARK: Future kinds

    func testFutureContentKindDecodesAsUnknownWithPayloadPreserved() throws {
        let payload = JSONValue.object([
            "custom": .number("123"),
            "nested": .object(["flag": .bool(true)]),
        ])
        let future = CanvasContent.unknown(kind: "futureKind", payload: payload)
        let data = try JSONEncoder().encode(
            ["content": future] as [String: CanvasContent])
        // Hand-modify the kind to something this build does not know.
        var object = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        var content = object["content"] as! [String: Any]
        content["kind"] = "hologramDeck"
        object["content"] = content
        let foreign = try JSONSerialization.data(withJSONObject: object)
        let decoded = try JSONDecoder().decode(
            [String: CanvasContent].self, from: foreign)
        guard case .unknown(let kind, let decodedPayload) = decoded["content"] else {
            XCTFail("future kind did not degrade to unknown")
            return
        }
        XCTAssertEqual(kind, "hologramDeck")
        XCTAssertEqual(decodedPayload, payload)
    }

    func testUnknownContentWithoutPayloadDecodesAsEmptyObject() throws {
        let json = """
        {"kind": "mystery", "unknownKind": "mystery"}
        """.data(using: .utf8)!
        let content = try JSONDecoder().decode(CanvasContent.self, from: json)
        guard case .unknown(let kind, let payload) = content else {
            XCTFail("expected unknown")
            return
        }
        XCTAssertEqual(kind, "mystery")
        XCTAssertEqual(payload, .object([:]))
    }

    // MARK: Pencil drawing

    func testPencilDrawingRoundTripAndEditOperation() throws {
        let strokes = Data([0x01, 0x02, 0x03])
        var page = CanvasPageSnapshot()
        page.pencilDrawingData = strokes
        let snapshot = CanvasSnapshot(name: "P", pages: [page])
        let decoded = try JSONDecoder().decode(
            CanvasSnapshot.self, from: JSONEncoder().encode(snapshot))
        XCTAssertEqual(decoded.pages[0].pencilDrawingData, strokes)

        let replaced = try CanvasEditEngine.apply(CanvasEditBatch(
            pageID: page.id,
            operations: [.setPencilDrawingData(Data([0x09]))]
        ), to: CanvasSnapshot(name: "P", pages: [CanvasPageSnapshot(id: page.id)]))
        XCTAssertEqual(replaced.snapshot.pages[0].pencilDrawingData, Data([0x09]))

        let cleared = try CanvasEditEngine.apply(CanvasEditBatch(
            pageID: page.id,
            operations: [.setPencilDrawingData(nil)]
        ), to: snapshot)
        XCTAssertNil(cleared.snapshot.pages[0].pencilDrawingData)
    }

    func testPencilDrawingRequiresWholeDocumentScopeAndByteCap() throws {
        let page = CanvasPageSnapshot()
        let snapshot = CanvasSnapshot(name: "P", pages: [page])
        let node = CanvasNodeSnapshot(
            content: .text("x"),
            frame: CanvasGeometry.Frame(
                center: .zero, size: .init(width: 5, height: 5)))
        var scoped = snapshot
        scoped.pages[0].nodes = [node]

        XCTAssertThrowsError(try CanvasEditEngine.apply(CanvasEditBatch(
            pageID: page.id,
            scope: .selectedNodes([node.id]),
            operations: [.setPencilDrawingData(Data([1]))]
        ), to: scoped)) { error in
            guard case CanvasKitError.editScopeViolations(let violations) = error,
                  violations.first?.reason == .outsideScope else {
                XCTFail("expected outsideScope, got \(error)")
                return
            }
        }

        let tooLarge = Data(count: CanvasPageSnapshot.maxPencilDrawingByteCount + 1)
        XCTAssertThrowsError(try CanvasEditEngine.apply(CanvasEditBatch(
            pageID: page.id,
            operations: [.setPencilDrawingData(tooLarge)]
        ), to: snapshot)) { error in
            guard case CanvasKitError.editScopeViolations(let violations) = error,
                  violations.first?.reason == .dataTooLarge else {
                XCTFail("expected dataTooLarge, got \(error)")
                return
            }
        }
    }
}
