// SPDX-License-Identifier: MPL-2.0
import XCTest
import FloeCanvasCore
@testable import FloeCanvasExchange

final class JSONCanvasTests: XCTestCase {
    func testMixedFixtureImportsCountsTypesAndGeometry() throws {
        let bundle = try CanvasJSONCanvasCodec.decode(
            ExchangeFixtureSupport.data("mixed.canvas"),
            options: .init(canvasID: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!, canvasName: "Mixed")
        )
        let page = try XCTUnwrap(bundle.snapshot.pages.first)
        // The fixture holds 4 nodes total: the group becomes the region,
        // leaving 3 content nodes.
        XCTAssertEqual(page.nodes.count, 3)
        XCTAssertEqual(page.regions.count, 1)
        XCTAssertEqual(page.connections.count, 2)

        // group node -> region with label and top-left -> center conversion.
        let region = try XCTUnwrap(page.regions.first)
        XCTAssertEqual(region.name, "资料与方案")
        XCTAssertEqual(region.frame.center.x, -400 + 1100 / 2, accuracy: 0.001)
        XCTAssertEqual(region.frame.center.y, -240 + 680 / 2, accuracy: 0.001)
        XCTAssertEqual(region.frame.size.width, 1100, accuracy: 0.001)

        // text node keeps markdown + emoji verbatim.
        let text = try XCTUnwrap(page.nodes.first(where: { $0.content.unknownKind == nil && ($0.title?.contains("研究问题") == true) }))
        guard case .text(let value) = text.content else { return XCTFail("text content expected") }
        XCTAssertTrue(value.contains("```swift"))
        XCTAssertTrue(value.contains("🧊"))

        // file node is a reference with the exact subpath.
        let file = try XCTUnwrap(page.nodes.first(where: { $0.content.unknownKind == "floe.jsoncanvas.file" }))
        guard case .unknown(_, let payload) = file.content else { return XCTFail() }
        XCTAssertEqual(payload["file"]?.stringValue, "assets/reference.md")
        XCTAssertEqual(payload["subpath"]?.stringValue, "#证据")

        // link node.
        let link = try XCTUnwrap(page.nodes.first(where: { node in
            if case .web = node.content { return true }
            return false
        }))
        guard case .web(let url, _) = link.content else { return XCTFail("web content expected") }
        XCTAssertEqual(url.absoluteString, "https://example.org/reference")

        // edges: sides, direction, label.
        let edge1 = try XCTUnwrap(page.connections.first(where: { ($0.label ?? "") == "引用证据" }))
        XCTAssertEqual(edge1.sourcePort, .trailing)
        XCTAssertEqual(edge1.destinationPort, .leading)
        XCTAssertEqual(edge1.kind, .arrow)
        let edge2 = try XCTUnwrap(page.connections.first(where: { ($0.label ?? "") == "双向关联" }))
        XCTAssertEqual(edge2.kind, .arrow)

        // external id mapping retained.
        XCTAssertEqual(bundle.externalIDs.count, 6)
        XCTAssertTrue(bundle.issues.contains(where: { $0.code == "jsoncanvas.file.reference" }))
    }

    func testUnsafeRelativeAssetStaysAReference() throws {
        let root = ExchangeFixtureSupport.root
        let bundle = try CanvasJSONCanvasCodec.decode(
            ExchangeFixtureSupport.data("unsafe-relative-asset.canvas"),
            options: .init(trustedAssetRoot: root, resolveAssetBytes: true)
        )
        let page = try XCTUnwrap(bundle.snapshot.pages.first)
        XCTAssertTrue(page.nodes.contains(where: { $0.content.unknownKind == "floe.jsoncanvas.file" }))
        XCTAssertTrue(bundle.issues.contains(where: { $0.code == "jsoncanvas.file.outsideRoot" }))
        XCTAssertTrue(bundle.assets.isEmpty)
    }

    func testContainedAssetResolvesInsideTrustedRoot() throws {
        let root = ExchangeFixtureSupport.root
        let bundle = try CanvasJSONCanvasCodec.decode(
            ExchangeFixtureSupport.data("mixed.canvas"),
            options: .init(trustedAssetRoot: root, resolveAssetBytes: true)
        )
        let page = try XCTUnwrap(bundle.snapshot.pages.first)
        let media = try XCTUnwrap(page.nodes.first(where: { node in
            if case .media = node.content { return true }
            return false
        }), "the file node must resolve to media; issues: \(bundle.issues)")
        guard case .media(let locator) = media.content else { return XCTFail("media expected, got \(media.content)") }
        XCTAssertEqual(locator.relativePath, "assets/reference.md")
        XCTAssertNotNil(locator.contentHash)
        XCTAssertEqual(bundle.assets[locator.id], try ExchangeFixtureSupport.data("assets/reference.md"))
    }

    func testDuplicateNodeIDIsRejected() throws {
        XCTAssertThrowsError(try CanvasJSONCanvasCodec.decode(ExchangeFixtureSupport.data("invalid-duplicate-id.canvas"))) { error in
            guard case CanvasExchangeError.invalid(let message) = error else { return XCTFail("invalid expected, got \(error)") }
            XCTAssertTrue(message.contains("duplicate JSON Canvas node id \"region\""))
        }
    }

    func testExportImportFidelityWithSidecars() throws {
        let bundle = try CanvasJSONCanvasCodec.decode(
            ExchangeFixtureSupport.data("mixed.canvas"),
            options: .init(canvasID: UUID(uuidString: "22222222-2222-2222-2222-222222222222")!, canvasName: "Mixed")
        )
        let exported = try CanvasJSONCanvasCodec.export(
            bundle.snapshot,
            options: .init(
                externalIDs: bundle.externalIDs,
                originalNodes: bundle.originalNodes,
                originalEdges: bundle.originalEdges,
                originalDocument: bundle.originalDocument
            )
        )
        XCTAssertEqual(exported.files.count, 1)
        let data = exported.primary.data

        // Output numbers are real JSON numbers, not strings or tagged objects.
        let tree = try JSONFidelity.parse(data)
        let nodes = try XCTUnwrap(tree["nodes"]?.arrayValue)
        for node in nodes {
            guard let object = node.objectValue, let x = object["x"] else { continue }
            guard case .number = x else { return XCTFail("x must be a JSON number") }
        }

        // Unknown fields re-injected verbatim, including exact literals.
        let group = try XCTUnwrap(nodes.first(where: { $0["type"]?.stringValue == "group" }))
        let preserved = try XCTUnwrap(group["floeUnknownFixture"]?["preserve"]?.arrayValue)
        XCTAssertEqual(preserved.count, 3)
        XCTAssertEqual(tree["fixtureExtension"]?["version"]?.numberLiteral, "1")
        // Edge color re-injected.
        let edges = try XCTUnwrap(tree["edges"]?.arrayValue)
        XCTAssertEqual(edges.first(where: { $0["id"]?.stringValue == "edge-1" })?["color"]?.stringValue, "4")
        // Per-end arrowheads preserved verbatim (edge-2 is double-headed).
        let edge2 = try XCTUnwrap(edges.first(where: { $0["id"]?.stringValue == "edge-2" }))
        XCTAssertEqual(edge2["fromEnd"]?.stringValue, "arrow")
        XCTAssertEqual(edge2["toEnd"]?.stringValue, "arrow")

        // Re-import: ids, geometry and labels stable.
        let reimported = try CanvasJSONCanvasCodec.decode(
            data,
            options: .init(canvasID: UUID(uuidString: "22222222-2222-2222-2222-222222222222")!, canvasName: "Mixed")
        )
        XCTAssertEqual(reimported.snapshot.pages.first?.nodes.count, 3)
        XCTAssertEqual(reimported.snapshot.pages.first?.connections.count, 2)
        let reedge = try XCTUnwrap(reimported.snapshot.pages.first?.connections.first(where: { ($0.label ?? "") == "引用证据" }))
        XCTAssertEqual(reedge.sourcePort, .trailing)
        let retext = try XCTUnwrap(reimported.snapshot.pages.first?.nodes.first(where: { $0.title?.contains("研究问题") == true }))
        XCTAssertEqual(retext.id, try XCTUnwrap(bundle.snapshot.pages.first?.nodes.first(where: { $0.title?.contains("研究问题") == true })).id)
    }

    func testMultipageExportNeverSilentlyDrops() throws {
        let pageA = CanvasPageSnapshot(id: UUID(), name: "A")
        let pageB = CanvasPageSnapshot(id: UUID(), name: "B")
        var snapshot = CanvasSnapshot(name: "Two", pages: [pageA, pageB], selectedPageID: pageA.id)
        snapshot.selectedPageID = pageA.id

        let single = try CanvasJSONCanvasCodec.export(snapshot)
        XCTAssertEqual(single.files.count, 1)
        XCTAssertTrue(single.issues.contains(where: { $0.code == "jsoncanvas.multipage" && $0.detail.contains("\"B\"") }))

        let package = try CanvasJSONCanvasCodec.export(snapshot, options: .init(multiPageStrategy: .oneFilePerPage))
        XCTAssertEqual(package.files.count, 2)
        XCTAssertFalse(package.issues.contains(where: { $0.code == "jsoncanvas.multipage" }))
    }

    func testNonFiniteAndNegativeInputsAreGraceful() throws {
        let json = """
        {"nodes":[
          {"id":"nan","type":"text","x":"NaN","y":0,"width":100,"height":40,"text":"bad"},
          {"id":"neg","type":"text","x":10,"y":10,"width":-50,"height":40,"text":"neg"},
          {"id":"ok","type":"text","x":0,"y":0,"width":100,"height":40,"text":"ok"}
        ]}
        """.data(using: .utf8)!
        let bundle = try CanvasJSONCanvasCodec.decode(json)
        let page = try XCTUnwrap(bundle.snapshot.pages.first)
        XCTAssertEqual(page.nodes.count, 2) // NaN-position node skipped
        XCTAssertTrue(bundle.issues.contains(where: { $0.code == "jsoncanvas.node.badPosition" }))
        XCTAssertTrue(bundle.issues.contains(where: { $0.code == "jsoncanvas.node.nonPositiveSize" }))
    }
}
