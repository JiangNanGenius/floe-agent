import XCTest
import FloeCanvasCore
import FloeDiagramCore
@testable import FloeCanvasLayout

final class PageLayoutIndexTests: XCTestCase {
    func testBuildSortsNodesByZIndexThenSourceOrder() throws {
        let a = makeNode(zIndex: 5)
        let b = makeNode(zIndex: 1)
        let c = makeNode(zIndex: 3)
        let page = CanvasPageSnapshot(nodes: [a, b, c])
        let index = try CanvasPageLayoutIndex(page: page)
        XCTAssertEqual(index.nodes.map(\.id), [b.id, c.id, a.id])
        XCTAssertTrue(index.issues.isEmpty)
    }

    func testHitTestPrefersTopmostZIndexAtOverlap() throws {
        let under = makeNode(zIndex: 0)
        let over = makeNode(zIndex: 9)
        let page = CanvasPageSnapshot(nodes: [under, over])
        let index = try CanvasPageLayoutIndex(page: page)
        let target = index.hitTest(.init(x: 0, y: 0))
        guard case .node(let hit)? = target else {
            XCTFail("expected node hit, got \(String(describing: target))")
            return
        }
        XCTAssertEqual(hit.id, over.id)
    }

    func testHitTestTieBreaksOnSourceOrderTopmost() throws {
        let first = makeNode(zIndex: 0)
        let second = makeNode(zIndex: 0)
        let page = CanvasPageSnapshot(nodes: [first, second])
        let index = try CanvasPageLayoutIndex(page: page)
        guard case .node(let hit)? = index.hitTest(.init(x: 0, y: 0)) else {
            XCTFail("expected node hit")
            return
        }
        XCTAssertEqual(hit.id, second.id)
    }

    func testHitTestAppliesRealToleranceBeyondFrameEdge() throws {
        let node = makeNode(center: .init(x: 0, y: 0), size: .init(width: 100, height: 100))
        let page = CanvasPageSnapshot(nodes: [node])
        let index = try CanvasPageLayoutIndex(page: page)
        // The world tolerance is screenTolerance / zoom (constant screen
        // target under the actual viewport transform). Node right edge at
        // x = 50.
        // zoom 1 → tolerance 2: 1.5 units outside hits, 5 outside misses.
        guard case .node(let hit)? = index.hitTest(.init(x: 51.5, y: 0), zoom: 1, screenTolerance: 2) else {
            XCTFail("expected tolerance-expanded hit")
            return
        }
        XCTAssertEqual(hit.id, node.id)
        XCTAssertNil(index.hitTest(.init(x: 55, y: 0), zoom: 1, screenTolerance: 2))
        // zoom 2 → tolerance 1: 0.5 outside hits; 1.5 outside misses.
        XCTAssertNotNil(index.hitTest(.init(x: 50.5, y: 0), zoom: 2, screenTolerance: 2))
        XCTAssertNil(index.hitTest(.init(x: 51.5, y: 0), zoom: 2, screenTolerance: 2))
        // zoom 0.5 → tolerance 4: 3 outside hits; 5 outside misses.
        XCTAssertNotNil(index.hitTest(.init(x: 53, y: 0), zoom: 0.5, screenTolerance: 2))
        XCTAssertNil(index.hitTest(.init(x: 55, y: 0), zoom: 0.5, screenTolerance: 2))
        // zoom 8 → tolerance 0.25: 0.1 outside hits; 0.4 outside misses.
        XCTAssertNotNil(index.hitTest(.init(x: 50.1, y: 0), zoom: 8, screenTolerance: 2))
        XCTAssertNil(index.hitTest(.init(x: 50.4, y: 0), zoom: 8, screenTolerance: 2))
    }

    /// The hit radius must be a constant number of screen points at every
    /// zoom: offsets are generated in VIEW space through the real
    /// `CanvasViewportTransform` (view = (world - center) * scale +
    /// viewCenter) and converted to world points before hit testing.
    func testHitTestScreenRadiusInvariantAcrossZoom() throws {
        let node = makeNode(center: .init(x: 0, y: 0), size: .init(width: 100, height: 100))
        let page = CanvasPageSnapshot(nodes: [node])
        let index = try CanvasPageLayoutIndex(page: page)
        let viewSize = DiagramSize(width: 400, height: 300)
        let screenTolerance = 2.0
        for zoom in [0.25, 1.0, 2.0, 8.0] {
            let transform = try CanvasViewportTransform(
                center: .init(x: 0, y: 0), scale: zoom, viewSize: viewSize)
            let viewCenter = DiagramPoint(x: viewSize.width / 2, y: viewSize.height / 2)
            // 1.5 screen points off the right edge (edge sits 50*zoom
            // points from the view center): strictly inside the 2pt target.
            let insideView = DiagramPoint(
                x: viewCenter.x + 50 * zoom + 1.5, y: viewCenter.y)
            let insideWorld = transform.viewToWorld(insideView)
            guard case .node(let hit)? = index.hitTest(
                insideWorld, zoom: zoom, screenTolerance: screenTolerance) else {
                XCTFail("expected hit inside screen radius at zoom \(zoom)")
                continue
            }
            XCTAssertEqual(hit.id, node.id)
            // 2.5 screen points off the edge: outside the 2pt target.
            let outsideView = DiagramPoint(
                x: viewCenter.x + 50 * zoom + 2.5, y: viewCenter.y)
            let outsideWorld = transform.viewToWorld(outsideView)
            XCTAssertNil(index.hitTest(
                outsideWorld, zoom: zoom, screenTolerance: screenTolerance),
                "expected miss outside screen radius at zoom \(zoom)")
        }
    }

    func testHitTestZeroToleranceIsExactPointHit() throws {
        let node = makeNode(center: .init(x: 0, y: 0), size: .init(width: 100, height: 100))
        let page = CanvasPageSnapshot(nodes: [node])
        let index = try CanvasPageLayoutIndex(page: page)
        // Exact containment hits, just-outside misses — with a non-zero
        // spatial probe so deep-interior points still reach the index.
        guard case .node(let hit)? = index.hitTest(
            .init(x: 10, y: -20), zoom: 1, screenTolerance: 0) else {
            return XCTFail("expected exact interior hit")
        }
        XCTAssertEqual(hit.id, node.id)
        XCTAssertNil(index.hitTest(.init(x: 50.5, y: 0), zoom: 1, screenTolerance: 0))
        XCTAssertNil(index.hitTest(.init(x: 51.5, y: 0), zoom: 1, screenTolerance: 0))
        // Zero tolerance zooms with the viewport scale just like any other
        // exact geometric query (0 stays 0 at any zoom).
        XCTAssertNotNil(index.hitTest(.init(x: 10, y: 0), zoom: 8, screenTolerance: 0))
        XCTAssertNil(index.hitTest(.init(x: 50.1, y: 0), zoom: 8, screenTolerance: 0))
        // Regions answer exact hits too.
        let region = makeRegion(
            center: .init(x: 1000, y: 1000), size: .init(width: 200, height: 200))
        let regional = try CanvasPageLayoutIndex(
            page: CanvasPageSnapshot(nodes: [], regions: [region]))
        guard case .region(let regionHit)? = regional.hitTest(
            .init(x: 1000, y: 1000), zoom: 1, screenTolerance: 0) else {
            return XCTFail("expected exact region hit")
        }
        XCTAssertEqual(regionHit.id, region.id)
        XCTAssertNil(regional.hitTest(.init(x: 1100.5, y: 1000), zoom: 1, screenTolerance: 0))
    }

    func testHitTestRefusesNonFiniteAndDegenerateInputs() throws {
        let node = makeNode(center: .init(x: 0, y: 0), size: .init(width: 100, height: 100))
        let index = try CanvasPageLayoutIndex(page: CanvasPageSnapshot(nodes: [node]))
        XCTAssertNil(index.hitTest(.init(x: .nan, y: 0)))
        XCTAssertNil(index.hitTest(.init(x: 0, y: .infinity)))
        XCTAssertNil(index.hitTest(.init(x: 0, y: 0), zoom: .nan))
        XCTAssertNil(index.hitTest(.init(x: 0, y: 0), zoom: .infinity))
        XCTAssertNil(index.hitTest(.init(x: 0, y: 0), zoom: 0))
        XCTAssertNil(index.hitTest(.init(x: 0, y: 0), zoom: -2))
        XCTAssertNil(index.hitTest(.init(x: 0, y: 0), screenTolerance: .nan))
        XCTAssertNil(index.hitTest(.init(x: 0, y: 0), screenTolerance: -1))
        // Valid call still works after the refused inputs above.
        XCTAssertNotNil(index.hitTest(.init(x: 0, y: 0)))
    }

    func testVisibleNodesLassoAndNearbyRespectOverscan() throws {
        let n1 = makeNode(center: .init(x: 0, y: 0))
        let n2 = makeNode(center: .init(x: 500, y: 0))
        let n3 = makeNode(center: .init(x: 0, y: 500))
        let page = CanvasPageSnapshot(nodes: [n1, n2, n3])
        let index = try CanvasPageLayoutIndex(page: page)

        XCTAssertEqual(index.visibleNodes(
            in: DiagramRect(x: 0, y: 0, width: 60, height: 60),
            overscan: 0).map(\.id), [n1.id])
        // Overscan reaches the 500pt-away nodes' 100pt frames at ±50…
        XCTAssertEqual(Set(index.visibleNodes(
            in: DiagramRect(x: 0, y: 0, width: 60, height: 60),
            overscan: 450).map(\.id)),
            Set([n1.id, n2.id, n3.id]))
        // Lasso intersect semantics: rect overlapping n1 and n2 only.
        XCTAssertEqual(Set(index.lasso(DiagramRect(
            x: 40, y: 40, width: 460, height: 20)).map(\.id)),
            Set([n1.id, n2.id]))
        // Nearby orders by center distance (n2 is 460 away, n3 ~502).
        XCTAssertEqual(index.nearby(to: .init(x: 40, y: 0), radius: 500).map(\.id),
                       [n1.id, n2.id])
    }

    func testDuplicateDegenerateAndDanglingInputsFailGracefully() throws {
        let duplicate = makeNode(id: UUID(uuidString: "00000000-0000-0000-0000-0000000000AA")!)
        let twin = CanvasNodeSnapshot(
            id: duplicate.id,
            content: .text("twin"),
            frame: CanvasGeometry.Frame(
                center: .init(x: 5000, y: 5000),
                size: .init(width: 100, height: 100)))
        let degenerate = CanvasNodeSnapshot(
            content: .text("bad"),
            frame: CanvasGeometry.Frame(
                center: .init(x: .nan, y: 0),
                size: .init(width: 100, height: 100)))
        let huge = CanvasNodeSnapshot(
            content: .text("huge"),
            frame: CanvasGeometry.Frame(
                center: .init(x: 1e300, y: 0),
                size: .init(width: 100, height: 100)))
        let good = makeNode()
        let dangling = makeConnection(from: good.id, to: UUID())
        let dupConnection = makeConnection(
            id: UUID(uuidString: "00000000-0000-0000-0000-0000000000CC")!,
            from: good.id, to: good.id)
        let dupConnectionTwin = CanvasConnectionSnapshot(
            id: dupConnection.id,
            sourceNodeID: good.id,
            destinationNodeID: good.id,
            kind: .line)
        let page = CanvasPageSnapshot(
            nodes: [duplicate, twin, degenerate, huge, good],
            connections: [dangling, dupConnection, dupConnectionTwin])
        let index = try CanvasPageLayoutIndex(page: page)

        XCTAssertEqual(Set(index.issues.map(\.code)), [
            .duplicateNodeID, .degenerateNodeFrame, .coordinatesOutOfRange,
            .danglingConnection, .duplicateConnectionID])
        XCTAssertEqual(index.nodes.map(\.id), [duplicate.id, good.id])
        XCTAssertFalse(index.containsNode(id: degenerate.id))
        XCTAssertFalse(index.containsNode(id: huge.id))
    }

    func testOutOfRangeQueriesReturnEmptyWithoutTrapping() throws {
        let node = makeNode()
        let page = CanvasPageSnapshot(nodes: [node])
        let index = try CanvasPageLayoutIndex(page: page)
        // Query rects beyond the safe extent or degenerate sizes fail soft.
        XCTAssertTrue(index.visibleNodes(in: DiagramRect(
            x: 1e300, y: 0, width: 100, height: 100)).isEmpty)
        XCTAssertTrue(index.visibleNodes(in: DiagramRect(
            x: 0, y: 0, width: 1e9, height: 1e9)).isEmpty)
        XCTAssertTrue(index.lasso(DiagramRect(
            x: -1e16, y: 0, width: 2, height: 2)).isEmpty)
        XCTAssertNil(index.hitTest(.init(x: 1e300, y: 0)))
        // A 2e12-unit probe exceeds the query size cap and fails soft.
        XCTAssertTrue(index.nearby(to: .init(x: 0, y: 0), radius: 1e12).isEmpty)
    }

    func testHugeFiniteExtentFrameIsRejectedWithoutTrapping() throws {
        // Corners stay inside the world extent but the SPAN (1e12) would blow
        // the spatial index cell-count multiplication: must be excluded with
        // a diagnostic, not inserted.
        let hugeExtent = CanvasNodeSnapshot(
            content: .text("extent"),
            frame: CanvasGeometry.Frame(
                center: .init(x: 0, y: 0),
                size: .init(width: 1e12, height: 1e12)))
        let page = CanvasPageSnapshot(nodes: [hugeExtent])
        let index = try CanvasPageLayoutIndex(page: page)
        XCTAssertTrue(index.nodes.isEmpty)
        XCTAssertFalse(index.containsNode(id: hugeExtent.id))
        XCTAssertTrue(index.issues.contains { $0.code == .coordinatesOutOfRange })
        // Queries against the remaining (empty) index stay safe.
        XCTAssertTrue(index.visibleNodes(in: DiagramRect(
            x: -5e11, y: -5e11, width: 1e12, height: 1e12)).isEmpty)
    }

    func testEmptyPageProducesOriginBounds() throws {
        let page = CanvasPageSnapshot()
        let index = try CanvasPageLayoutIndex(page: page)
        XCTAssertEqual(index.bounds, DiagramRect(x: 0, y: 0, width: 1, height: 1))
        XCTAssertTrue(index.nodes.isEmpty)
        XCTAssertTrue(index.regions.isEmpty)
        XCTAssertTrue(index.proxyEdges.isEmpty)
    }

    func testBoundsIncludeVisibleRegionFrames() throws {
        // A single collapsed region with one member: the member is hidden,
        // so the chip frame alone determines the bounds (never the 1×1
        // origin fallback) and is hit-testable.
        let region = makeRegion(
            center: .init(x: 1000, y: 1000),
            size: .init(width: 400, height: 400),
            collapsed: true)
        let member = makeNode(center: .init(x: 1000, y: 1000))
        let page = CanvasPageSnapshot(nodes: [member], regions: [region])
        let index = try CanvasPageLayoutIndex(page: page)

        XCTAssertTrue(index.nodes.isEmpty)
        XCTAssertEqual(index.bounds, DiagramRect(x: 800, y: 800, width: 400, height: 400))
        XCTAssertEqual(index.regionFrames[region.id], index.bounds)
        guard case .region(let hit)? = index.hitTest(.init(x: 1000, y: 1000)) else {
            XCTFail("expected region chip hit")
            return
        }
        XCTAssertEqual(hit.id, region.id)
        XCTAssertTrue(hit.isCollapsed)
    }

    func testIndexBuildDoesNotMutateInputPage() throws {
        let region = makeRegion(
            center: .init(x: 0, y: 0),
            size: .init(width: 500, height: 500),
            collapsed: true)
        let inside = makeNode(center: .init(x: 0, y: 0))
        let outside = makeNode(center: .init(x: 2000, y: 0))
        let page = CanvasPageSnapshot(
            nodes: [inside, outside],
            connections: [makeConnection(from: inside.id, to: outside.id, label: "keep")],
            regions: [region])
        let pageBefore = page
        _ = try CanvasPageLayoutIndex(page: page)
        XCTAssertEqual(page, pageBefore)
        XCTAssertTrue(page.regions[0].isCollapsed)
        XCTAssertEqual(page.nodes.count, 2)
    }
}
