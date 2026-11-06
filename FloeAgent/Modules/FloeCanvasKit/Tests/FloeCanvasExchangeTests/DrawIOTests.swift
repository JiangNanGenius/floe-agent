// SPDX-License-Identifier: MPL-2.0
import XCTest
import FloeCanvasCore
@testable import FloeCanvasExchange

final class DrawIOTests: XCTestCase {
    func testRepeatedPageScopedIdentitiesKeepTheirOwnConnectionsAndGroups() async throws {
        let a = CanvasNodeSnapshot(content: .text("alpha"),
            frame: .init(center: .zero, size: .init(width: 120, height: 60)))
        let b = CanvasNodeSnapshot(content: .text("beta"),
            frame: .init(center: .init(x: 240, y: 0), size: .init(width: 120, height: 60)))
        let group = CanvasGroupRecord(name: "pair", memberNodeIDs: [a.id, b.id])
        let region = CanvasRegionRecord(name: "zone",
            frame: .init(center: .init(x: 120, y: 0), size: .init(width: 600, height: 300)))
        let edge = CanvasConnectionSnapshot(sourceNodeID: a.id, destinationNodeID: b.id,
            kind: .arrow, label: "local")
        let pages = ["first", "second", "third"].map {
            CanvasPageSnapshot(name: $0, nodes: [a, b], connections: [edge], groups: [group], regions: [region])
        }
        let snapshot = CanvasSnapshot(name: "Repeated imports", pages: pages)
        let first = try await CanvasDrawIOCodec.export(snapshot)
        let second = try await CanvasDrawIOCodec.export(snapshot)
        XCTAssertEqual(first.primary.data, second.primary.data, "stable export identity mapping")
        XCTAssertEqual(first.issues.filter { $0.code == "drawio.identities.pageScoped" }.count, 2)
        let restored = try CanvasDrawIOCodec.decode(first.primary.data).snapshot
        XCTAssertEqual(restored.pages.count, 3)
        var seen = Set<UUID>()
        for page in restored.pages {
            XCTAssertEqual(page.nodes.count, 2)
            XCTAssertEqual(page.groups.count, 1)
            XCTAssertEqual(page.regions.count, 1)
            let alpha = try XCTUnwrap(page.nodes.first { $0.title == "alpha" })
            let beta = try XCTUnwrap(page.nodes.first { $0.title == "beta" })
            XCTAssertTrue(seen.insert(alpha.id).inserted)
            XCTAssertTrue(seen.insert(beta.id).inserted)
            XCTAssertEqual(page.connections.first?.sourceNodeID, alpha.id)
            XCTAssertEqual(page.connections.first?.destinationNodeID, beta.id)
            XCTAssertEqual(Set(page.groups.first?.memberNodeIDs ?? []), Set([alpha.id, beta.id]))
            XCTAssertTrue(page.nodes.allSatisfy { $0.groupID == page.groups.first?.id })
        }
        XCTAssertEqual(snapshot.pages.map { $0.nodes.map(\.id) }, pages.map { $0.nodes.map(\.id) }, "source identities remain untouched")
    }

    func testTwoPagesFixtureImportsPagesVerticesAndEdges() throws {
        let bundle = try CanvasDrawIOCodec.decode(
            ExchangeFixtureSupport.data("two-pages.drawio"),
            options: .init(canvasID: UUID(uuidString: "55555555-5555-5555-5555-555555555555")!, canvasName: "TwoPages")
        )
        XCTAssertEqual(bundle.snapshot.pages.count, 2)

        let first = bundle.snapshot.pages[0]
        XCTAssertEqual(first.name, "资料与流程")
        XCTAssertEqual(first.nodes.count, 2)
        XCTAssertEqual(first.connections.count, 1)

        // Negative coordinates and Chinese labels survive top-left anchoring.
        let a = try XCTUnwrap(first.nodes.first(where: { $0.title == "输入资料" }))
        XCTAssertEqual(a.frame.minX, -120, accuracy: 0.001)
        XCTAssertEqual(a.frame.minY, 80, accuracy: 0.001)
        let b = try XCTUnwrap(first.nodes.first(where: { $0.title == "研究结论" }))
        guard case .shape(.ellipse, _) = b.content else { return XCTFail("ellipse expected") }

        let edge = try XCTUnwrap(first.connections.first)
        XCTAssertEqual(edge.kind, .arrow)
        XCTAssertEqual(edge.label, "依据")
        XCTAssertEqual(edge.sourceNodeID, a.id)
        XCTAssertEqual(edge.destinationNodeID, b.id)

        // Page separation and empty second page.
        XCTAssertEqual(bundle.snapshot.pages[1].name, "第二页")
        XCTAssertEqual(bundle.snapshot.pages[1].nodes.count, 0)

        // Original payload retained for the native archive.
        let source = try XCTUnwrap(bundle.originalSources.first)
        XCTAssertEqual(source.kind, .drawioOriginal)
        XCTAssertGreaterThan(source.byteCount, 0)
    }

    func testCompressedPayloadRoundTrips() async throws {
        let bundle = try CanvasDrawIOCodec.decode(
            ExchangeFixtureSupport.data("two-pages.drawio"),
            options: .init(canvasID: UUID(uuidString: "66666666-6666-6666-6666-666666666666")!, canvasName: "TwoPages")
        )
        let exported = try await CanvasDrawIOCodec.export(
            bundle.snapshot,
            options: .init(compressed: true)
        )
        let xml = String(data: exported.primary.data, encoding: .utf8) ?? ""
        XCTAssertTrue(xml.hasPrefix("<?xml"))
        XCTAssertTrue(xml.contains("<diagram"))
        // Compressed pages are base64, not inline XML.
        XCTAssertFalse(xml.contains("<mxGraphModel><root><mxCell id=\"0\"/><mxCell id=\"1\" parent=\"0\"/><mxCell id=\""))

        // Re-import the compressed form.
        let reimported = try CanvasDrawIOCodec.decode(exported.primary.data)
        XCTAssertEqual(reimported.snapshot.pages.count, 2)
        XCTAssertEqual(reimported.snapshot.pages[0].nodes.count, 2)
        XCTAssertEqual(reimported.snapshot.pages[0].connections.count, 1)
    }

    func testFlowCardsExportAsVisualProjectionOnly() async throws {
        var node = CanvasNodeSnapshot(
            kind: .generationTask,
            title: "generate",
            content: .text("run the flow"),
            frame: .init(center: .init(x: 0, y: 0), size: .init(width: 200, height: 80))
        )
        node.metadata[CanvasExchangeFlowKey.graphID] = UUID(uuidString: "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa")!.uuidString
        node.metadata[CanvasExchangeFlowKey.nodeID] = UUID(uuidString: "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb")!.uuidString
        var page = CanvasPageSnapshot(name: "P1", nodes: [node])
        page.flowGraphs = [FlowGraph(id: UUID(uuidString: "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa")!)]
        let snapshot = CanvasSnapshot(name: "Flow", pages: [page])
        let exported = try await CanvasDrawIOCodec.export(snapshot)
        XCTAssertTrue(exported.issues.contains(where: { $0.code == "drawio.flowCard.visualOnly" }))
        XCTAssertTrue(exported.issues.contains(where: { $0.code == "drawio.flowGraphs.notRepresentable" }))
        let xml = String(data: exported.primary.data, encoding: .utf8) ?? ""
        // The card renders as an ordinary editable shape carrying its real
        // label; the flow binding ids are never written into open output.
        XCTAssertTrue(xml.contains("run the flow"))
        XCTAssertFalse(xml.contains("aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"))
        XCTAssertFalse(xml.contains("bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb"))
        XCTAssertFalse(xml.contains("floe.flow.graphID="))
    }

    func testRichContentProjectsIntoEditableLabels() async throws {
        let code = CanvasNodeSnapshot(
            content: .code(language: "swift", source: "let x = 42"),
            frame: .init(center: .init(x: 0, y: 0), size: .init(width: 220, height: 90))
        )
        let table = CanvasNodeSnapshot(
            content: .table(header: ["name", "value"], rows: [["a", "1"], ["b", "2"]]),
            frame: .init(center: .init(x: 300, y: 0), size: .init(width: 220, height: 110))
        )
        let formula = CanvasNodeSnapshot(
            content: .formula(source: "e^{i\\pi}+1=0", renderedAssetID: nil),
            frame: .init(center: .init(x: 600, y: 0), size: .init(width: 220, height: 80))
        )
        let media = CanvasNodeSnapshot(
            content: .media(CanvasAssetLocator(id: UUID(uuidString: "12121212-1212-1212-1212-121212121212")!, relativePath: "images/photo.png")),
            frame: .init(center: .init(x: 900, y: 0), size: .init(width: 220, height: 120))
        )
        let snapshot = CanvasSnapshot(name: "Rich", pages: [CanvasPageSnapshot(name: "P1", nodes: [code, table, formula, media])])
        let exported = try await CanvasDrawIOCodec.export(snapshot)
        let xml = String(data: exported.primary.data, encoding: .utf8) ?? ""
        XCTAssertTrue(xml.contains("let x = 42"), "code source must be visible in the label")
        XCTAssertTrue(xml.contains("name | value"), "table header must be visible in the label")
        XCTAssertTrue(xml.contains("e^{i\\pi}+1=0"), "formula source must be visible in the label")
        XCTAssertTrue(xml.contains("images/photo.png"), "media card must carry its reference")
        XCTAssertTrue(exported.issues.contains(where: { $0.code == "drawio.code.projected" }))
        XCTAssertTrue(exported.issues.contains(where: { $0.code == "drawio.table.projected" }))
        XCTAssertTrue(exported.issues.contains(where: { $0.code == "drawio.formula.projected" }))
        XCTAssertTrue(exported.issues.contains(where: { $0.code == "drawio.media.notEmbeddable" }))
        // No empty cards: every emitted vertex carries a non-empty label.
        XCTAssertFalse(xml.contains("label=\"\""))

        // The projections re-import as editable text (never blank cards).
        let reimported = try CanvasDrawIOCodec.decode(exported.primary.data)
        let page = try XCTUnwrap(reimported.snapshot.pages.first)
        let labels = page.nodes.map { CanvasExchangeContent.plainText(of: $0.content) }
        XCTAssertTrue(labels.contains("let x = 42"))
        XCTAssertTrue(labels.contains(where: { $0.contains("name | value") }))
        XCTAssertTrue(labels.contains("e^{i\\pi}+1=0"))
    }

    func testGroupsRoundTripWithoutRegionConflation() async throws {
        let groupID = UUID(uuidString: "34343434-3434-3434-3434-343434343434")!
        let regionID = UUID(uuidString: "35353535-3535-3535-3535-353535353535")!
        let a = CanvasNodeSnapshot(
            content: .text("alpha"),
            frame: .init(center: .init(x: 100, y: 100), size: .init(width: 120, height: 60))
        )
        let b = CanvasNodeSnapshot(
            content: .text("beta"),
            frame: .init(center: .init(x: 260, y: 100), size: .init(width: 120, height: 60))
        )
        let group = CanvasGroupRecord(id: groupID, name: "pair", memberNodeIDs: [a.id, b.id])
        let region = CanvasRegionRecord(
            id: regionID,
            name: "zone",
            frame: .init(center: .init(x: 180, y: 100), size: .init(width: 400, height: 200)),
            isCollapsed: false
        )
        let snapshot = CanvasSnapshot(
            name: "Grouped",
            pages: [CanvasPageSnapshot(name: "P1", nodes: [a, b], groups: [group], regions: [region])]
        )
        let exported = try await CanvasDrawIOCodec.export(snapshot)
        let reimported = try CanvasDrawIOCodec.decode(exported.primary.data)
        let page = try XCTUnwrap(reimported.snapshot.pages.first)
        // Region and group survive as distinct records.
        XCTAssertEqual(page.regions.map(\.id), [regionID])
        XCTAssertEqual(page.regions.first?.name, "zone")
        XCTAssertEqual(page.groups.count, 1)
        XCTAssertEqual(page.groups.first?.id, groupID)
        XCTAssertEqual(page.groups.first?.name, "pair")
        XCTAssertEqual(Set(page.groups.first?.memberNodeIDs ?? []), Set([a.id, b.id]))
        // Membership landed on the group, region containment re-derived.
        for node in page.nodes {
            XCTAssertEqual(node.groupID, groupID)
            XCTAssertEqual(node.regionID, regionID)
        }
    }

    func testDTDRefused() {
        let malicious = """
        <?xml version="1.0"?><!DOCTYPE mxfile [<!ENTITY x SYSTEM "file:///etc/passwd">]><mxfile><diagram id="p" name="p"><mxGraphModel><root><mxCell id="0"/><mxCell id="1" parent="0"/><mxCell id="a" value="&x;" vertex="1" parent="1"><mxGeometry x="0" y="0" width="10" height="10" as="geometry"/></mxCell></root></mxGraphModel></diagram></mxfile>
        """.data(using: .utf8)!
        XCTAssertThrowsError(try CanvasDrawIOCodec.decode(malicious)) { error in
            guard case CanvasExchangeError.invalid(let message) = error else { return XCTFail(" DiagramKit maps to invalid, got \(error)") }
            XCTAssertTrue(message.contains("draw.io"))
        }
    }
}
