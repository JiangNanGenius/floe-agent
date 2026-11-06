// SPDX-License-Identifier: MPL-2.0
import XCTest
import FloeCanvasCore
@testable import FloeCanvasExchange

final class ExcalidrawTests: XCTestCase {
    func testMixedFixtureImportsElementsAndInk() throws {
        let bundle = try CanvasExcalidrawCodec.decode(
            ExchangeFixtureSupport.data("mixed.excalidraw"),
            options: .init(canvasID: UUID(uuidString: "33333333-3333-3333-3333-333333333333")!, canvasName: "Mixed")
        )
        let page = try XCTUnwrap(bundle.snapshot.pages.first)
        // frame -> region; rectangle/ellipse/arrow -> nodes; the two text
        // elements are bound (containerId) and fold into their shapes;
        // freedraw -> stroke; arrow binding -> semantic connection.
        XCTAssertEqual(page.nodes.count, 3)
        XCTAssertEqual(page.regions.count, 1)
        XCTAssertEqual(page.strokes.count, 1)
        XCTAssertEqual(page.connections.count, 1) // arrow binding -> semantic connection

        // Frame -> region with name.
        let region = try XCTUnwrap(page.regions.first)
        XCTAssertEqual(region.name, "资料研究与方案")
        XCTAssertEqual(region.frame.minX, -400, accuracy: 0.001)
        XCTAssertEqual(region.frame.minY, -220, accuracy: 0.001)

        // Rectangle carries the unknown big literals in its sidecar.
        let rectangle = try XCTUnwrap(page.nodes.first(where: { node in
            guard case .shape(let kind, _) = node.content else { return false }
            return kind == .rectangle
        }))
        let original = try XCTUnwrap(bundle.originalNodes[rectangle.id])
        let customData = try XCTUnwrap(original["customData"]?.objectValue)
        XCTAssertEqual(customData["fixtureUnknownInteger"]?.numberLiteral, "92233720368547758081234567890")
        XCTAssertEqual(customData["fixtureUnknownDecimal"]?.numberLiteral, "0.123456789012345678901234567890")

        // Bound text folds into shape text (containerId).
        let rectangleText: String
        guard case .shape(_, let text) = rectangle.content else { return XCTFail() }
        rectangleText = text
        XCTAssertEqual(rectangleText, "输入资料 🧊")

        // Ellipse and its bound text.
        let ellipse = try XCTUnwrap(page.nodes.first(where: { node in
            guard case .shape(let kind, let text) = node.content else { return false }
            return kind == .ellipse && text == "研究结论"
        }))
        XCTAssertEqual(ellipse.frame.center.x, 100 + 200 / 2, accuracy: 0.001)

        // Arrow: shape + binding-derived connection.
        let arrow = try XCTUnwrap(page.nodes.first(where: { node in
            guard case .shape(let kind, _) = node.content else { return false }
            return kind == .arrow
        }))
        let connection = try XCTUnwrap(page.connections.first)
        XCTAssertEqual(connection.sourceNodeID, rectangle.id)
        XCTAssertEqual(connection.destinationNodeID, ellipse.id)
        XCTAssertNotEqual(arrow.id, connection.id)

        // Freedraw -> stroke with absolute points.
        let stroke = try XCTUnwrap(page.strokes.first)
        XCTAssertEqual(stroke.points.count, 5)
        let firstX = try XCTUnwrap(stroke.points.first?.x)
        let lastX = try XCTUnwrap(stroke.points.last?.x)
        XCTAssertEqual(firstX, -300, accuracy: 0.001)
        XCTAssertEqual(lastX, -150, accuracy: 0.001)
        XCTAssertEqual(stroke.width, 2, accuracy: 0.001)
    }

    func testExportImportPreservesBigLiteralsAndGeometry() throws {
        let bundle = try CanvasExcalidrawCodec.decode(
            ExchangeFixtureSupport.data("mixed.excalidraw"),
            options: .init(canvasID: UUID(uuidString: "44444444-4444-4444-4444-444444444444")!, canvasName: "Mixed")
        )
        let exported = try CanvasExcalidrawCodec.export(
            bundle.snapshot,
            options: .init(
                externalIDs: bundle.externalIDs,
                originalNodes: bundle.originalNodes,
                originalEdges: bundle.originalEdges,
                originalDocument: bundle.originalDocument
            )
        )
        let data = exported.primary.data
        let tree = try JSONFidelity.parse(data)

        // Real JSON numbers on geometry fields.
        guard let elements = tree["elements"]?.arrayValue else { return XCTFail() }
        for element in elements {
            guard let object = element.objectValue else { continue }
            for key in ["x", "y", "width", "height", "angle", "seed", "version"] {
                if let value = object[key] {
                    guard case .number = value else { return XCTFail("\(key) must be a JSON number") }
                }
            }
        }

        // Unknown big literals preserved verbatim through export.
        let rectangle = try XCTUnwrap(elements.first(where: { $0["type"]?.stringValue == "rectangle" }))
        let customData = try XCTUnwrap(rectangle["customData"]?.objectValue)
        XCTAssertEqual(customData["fixtureUnknownInteger"]?.numberLiteral, "92233720368547758081234567890")
        XCTAssertEqual(customData["fixtureUnknownDecimal"]?.numberLiteral, "0.123456789012345678901234567890")

        // Original ids recovered (not UUIDs).
        let ids = elements.compactMap { $0["id"]?.stringValue }
        XCTAssertTrue(ids.contains("shape-a"))
        XCTAssertTrue(ids.contains("arrow-a"))
        XCTAssertEqual(Set(ids).count, ids.count)

        // Re-import keeps fidelity.
        let reimported = try CanvasExcalidrawCodec.decode(data)
        let page = try XCTUnwrap(reimported.snapshot.pages.first)
        XCTAssertEqual(page.nodes.count, 3)
        XCTAssertEqual(page.strokes.count, 1)
        XCTAssertEqual(page.regions.count, 1)
        let reellipse = try XCTUnwrap(page.nodes.first(where: { node in
            guard case .shape(let kind, let text) = node.content else { return false }
            return kind == .ellipse && text == "研究结论"
        }))
        XCTAssertEqual(reellipse.frame.minX, 100, accuracy: 0.001)
    }

    func testConnectionMergesIntoOriginArrowAndLabelRoundTrips() throws {
        let bundle = try CanvasExcalidrawCodec.decode(
            ExchangeFixtureSupport.data("mixed.excalidraw"),
            options: .init(canvasID: UUID(uuidString: "44444444-4444-4444-4444-444444444444")!, canvasName: "Mixed")
        )
        var snapshot = bundle.snapshot
        snapshot.pages[0].connections[0].label = "依据"
        let exported = try CanvasExcalidrawCodec.export(
            snapshot,
            options: .init(
                externalIDs: bundle.externalIDs,
                originalNodes: bundle.originalNodes,
                originalEdges: bundle.originalEdges,
                originalDocument: bundle.originalDocument
            )
        )
        let tree = try JSONFidelity.parse(exported.primary.data)
        let elements = try XCTUnwrap(tree["elements"]?.arrayValue)
        // Exactly ONE binding-carrying arrow: the connection merged back
        // into its origin element instead of duplicating a second arrow.
        let bindingArrows = elements.filter {
            $0["startBinding"]?.objectValue?["elementId"]?.stringValue != nil
        }
        XCTAssertEqual(bindingArrows.count, 1)
        // The label traveled as bound text on that arrow.
        let arrow = try XCTUnwrap(bindingArrows.first)
        let boundID = try XCTUnwrap(arrow["boundElements"]?.arrayValue?.first?["id"]?.stringValue)
        let labelText = try XCTUnwrap(elements.first(where: { $0["id"]?.stringValue == boundID }))
        XCTAssertEqual(labelText["text"]?.stringValue, "依据")

        let reimported = try CanvasExcalidrawCodec.decode(exported.primary.data)
        let page = try XCTUnwrap(reimported.snapshot.pages.first)
        XCTAssertEqual(page.nodes.count, 3, "no duplicated arrow node")
        let connection = try XCTUnwrap(page.connections.first)
        XCTAssertEqual(connection.label, "依据")
    }

    func testDuplicateElementIDRejected() throws {
        let json = """
        {"type":"excalidraw","version":2,"elements":[
          {"id":"a","type":"rectangle","x":0,"y":0,"width":10,"height":10},
          {"id":"a","type":"ellipse","x":20,"y":20,"width":10,"height":10}
        ]}
        """.data(using: .utf8)!
        XCTAssertThrowsError(try CanvasExcalidrawCodec.decode(json)) { error in
            guard case CanvasExchangeError.invalid(let message) = error else { return XCTFail() }
            XCTAssertTrue(message.contains("duplicate Excalidraw element id \"a\""))
        }
    }

    func testDeletedTombstonesDroppedAndCounted() throws {
        let json = """
        {"type":"excalidraw","version":2,"elements":[
          {"id":"live","type":"rectangle","x":0,"y":0,"width":10,"height":10,"isDeleted":false},
          {"id":"dead","type":"rectangle","x":0,"y":0,"width":10,"height":10,"isDeleted":true}
        ]}
        """.data(using: .utf8)!
        let bundle = try CanvasExcalidrawCodec.decode(json)
        XCTAssertEqual(bundle.snapshot.pages.first?.nodes.count, 1)
        XCTAssertTrue(bundle.issues.contains(where: { $0.code == "excalidraw.tombstones" && $0.detail.contains("1") }))
    }

    func testNonFiniteElementClampedWithIssue() throws {
        let json = """
        {"type":"excalidraw","version":2,"elements":[
          {"id":"bad","type":"rectangle","x":"NaN","y":0,"width":10,"height":10}
        ]}
        """.data(using: .utf8)!
        let bundle = try CanvasExcalidrawCodec.decode(json)
        XCTAssertEqual(bundle.snapshot.pages.first?.nodes.count, 1)
        XCTAssertTrue(bundle.issues.contains(where: { $0.code == "excalidraw.element.badPosition" }))
    }
}
