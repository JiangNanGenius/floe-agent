import XCTest
import FloeCanvasCore
import FloeDiagramCore
@testable import FloeCanvasLayout

final class CollapseRoutingTests: XCTestCase {
    func testCollapsedRegionHidesMembersAndRoutesExternalLabeledEdges() throws {
        let region = makeRegion(
            center: .init(x: 500, y: 500),
            size: .init(width: 400, height: 400),
            collapsed: true)
        let n1 = makeNode(center: .init(x: 400, y: 400))
        let n2 = makeNode(center: .init(x: 600, y: 600))
        let n3 = makeNode(center: .init(x: 1200, y: 500))
        let internalEdge = makeConnection(from: n1.id, to: n2.id)
        let outEdge = makeConnection(from: n2.id, to: n3.id, label: "out")
        let inEdge = makeConnection(from: n3.id, to: n1.id, kind: .arrow, label: "in")
        let page = CanvasPageSnapshot(
            nodes: [n1, n2, n3],
            connections: [internalEdge, outEdge, inEdge],
            regions: [region])

        let index = try CanvasPageLayoutIndex(page: page)
        XCTAssertEqual(index.nodes.map(\.id), [n3.id])
        XCTAssertEqual(index.collapsedRegionIDs, [region.id])
        XCTAssertEqual(index.hiddenConnectionCount, 1)
        XCTAssertEqual(index.proxyEdges.count, 2)
        let out = try XCTUnwrap(index.proxyEdges.first(where: { $0.id == outEdge.id }))
        XCTAssertEqual(out.sourceID, region.id)
        XCTAssertEqual(out.destinationID, n3.id)
        XCTAssertTrue(out.isProxy)
        XCTAssertEqual(out.label, "out")
        let incoming = try XCTUnwrap(index.proxyEdges.first(where: { $0.id == inEdge.id }))
        XCTAssertEqual(incoming.sourceID, n3.id)
        XCTAssertEqual(incoming.destinationID, region.id)
        XCTAssertEqual(incoming.kind, .arrow)
        // Bounds still include the chip frame plus the visible node.
        XCTAssertEqual(index.bounds, DiagramRect(
            x: 300, y: 300, width: 400, height: 400)
            .union(DiagramRect(x: 1150, y: 450, width: 100, height: 100)))
    }

    func testVisibleSelfLoopSurvivesWhileCollapsedSelfLoopIsHidden() throws {
        // No collapse involved: a→a is a legitimate visible relation and must
        // NOT be dropped by the collapse filter.
        let a = makeNode()
        let selfLoop = makeConnection(from: a.id, to: a.id, kind: .line, label: "loop")
        let visiblePage = CanvasPageSnapshot(nodes: [a], connections: [selfLoop])
        let visibleIndex = try CanvasPageLayoutIndex(page: visiblePage)
        XCTAssertEqual(visibleIndex.proxyEdges.count, 1)
        XCTAssertEqual(visibleIndex.proxyEdges[0].sourceID, a.id)
        XCTAssertEqual(visibleIndex.proxyEdges[0].destinationID, a.id)
        XCTAssertFalse(visibleIndex.proxyEdges[0].isProxy)
        XCTAssertEqual(visibleIndex.hiddenConnectionCount, 0)

        // Collapsed: the self-loop became internal to the region proxy.
        let region = makeRegion(
            center: .init(x: 0, y: 0),
            size: .init(width: 400, height: 400),
            collapsed: true)
        let member = makeNode(center: .init(x: 0, y: 0))
        let internalLoop = makeConnection(from: member.id, to: member.id)
        let collapsedPage = CanvasPageSnapshot(
            nodes: [member], connections: [internalLoop], regions: [region])
        let collapsedIndex = try CanvasPageLayoutIndex(page: collapsedPage)
        XCTAssertTrue(collapsedIndex.proxyEdges.isEmpty)
        XCTAssertEqual(collapsedIndex.hiddenConnectionCount, 1)
    }

    func testNestedCollapseResolvesToOutermostVisibleChip() throws {
        // Outer O (collapsed) contains inner I (also collapsed); node n sits
        // inside I. The inner chip is hidden and must NOT stay visible or
        // carry connections: n's representative is O.
        let outer = makeRegion(
            id: UUID(uuidString: "00000000-0000-0000-0000-0000000000A0")!,
            center: .init(x: 500, y: 500),
            size: .init(width: 800, height: 800),   // 100...900 both axes
            collapsed: true)
        // Small enough that the OUTER center (500,500) stays outside it, so
        // the nesting test (center containment) marks only INNER hidden.
        let inner = makeRegion(
            id: UUID(uuidString: "00000000-0000-0000-0000-0000000000A1")!,
            center: .init(x: 350, y: 350),
            size: .init(width: 200, height: 200),   // 250...450 both axes
            collapsed: true)
        let n = makeNode(center: .init(x: 350, y: 350))
        let m = makeNode(center: .init(x: 2000, y: 500))
        let edge = makeConnection(from: n.id, to: m.id, label: "cross")
        let page = CanvasPageSnapshot(
            nodes: [n, m],
            connections: [edge],
            regions: [outer, inner])

        let index = try CanvasPageLayoutIndex(page: page)
        // Inner region is hidden entirely: not exposed, not a proxy.
        XCTAssertNil(index.region(id: inner.id))
        XCTAssertNil(index.regionFrames[inner.id])
        XCTAssertFalse(index.collapsedRegionIDs.contains(inner.id))
        XCTAssertEqual(index.collapsedRegionIDs, [outer.id])
        // Only the outer chip and the free node are visible.
        XCTAssertEqual(index.regions.map(\.id), [outer.id])
        XCTAssertEqual(index.nodes.map(\.id), [m.id])
        // The connection re-pointed at the OUTER chip, never the hidden inner.
        XCTAssertEqual(index.proxyEdges.count, 1)
        XCTAssertEqual(index.proxyEdges[0].sourceID, outer.id)
        XCTAssertEqual(index.proxyEdges[0].destinationID, m.id)
        XCTAssertTrue(index.proxyEdges[0].isProxy)
        XCTAssertEqual(index.bounds, DiagramRect(x: 100, y: 100, width: 800, height: 800)
            .union(DiagramRect(x: 1950, y: 450, width: 100, height: 100)))
    }

    func testNestedBothCollapsedBothMembersInternalEdgesHidden() throws {
        // Outer center must stay outside the inner frame so the
        // center-containment nesting test marks only INNER hidden.
        let outer = makeRegion(
            center: .init(x: 500, y: 500),
            size: .init(width: 800, height: 800),   // 100...900
            collapsed: true)
        let inner = makeRegion(
            center: .init(x: 300, y: 300),
            size: .init(width: 200, height: 200),   // 200...400
            collapsed: true)
        let a = makeNode(center: .init(x: 300, y: 300))   // inside inner
        let b = makeNode(center: .init(x: 700, y: 700))   // inside outer, outside inner
        let internalA = makeConnection(from: a.id, to: b.id)
        let internalB = makeConnection(from: b.id, to: a.id)
        let page = CanvasPageSnapshot(
            nodes: [a, b],
            connections: [internalA, internalB],
            regions: [outer, inner])

        let index = try CanvasPageLayoutIndex(page: page)
        XCTAssertTrue(index.nodes.isEmpty)
        XCTAssertEqual(index.hiddenConnectionCount, 2)
        XCTAssertTrue(index.proxyEdges.isEmpty)
        XCTAssertEqual(index.collapsedRegionIDs, [outer.id])
    }

    func testOverlappingNonNestedRegionsUseDeterministicSmallestRule() throws {
        // Two expanded overlapping regions: membership goes to the smallest
        // containing region, ties to the smaller ID.
        let big = makeRegion(
            id: UUID(uuidString: "00000000-0000-0000-0000-0000000000B0")!,
            center: .init(x: 0, y: 0),
            size: .init(width: 400, height: 400))
        let small = makeRegion(
            id: UUID(uuidString: "00000000-0000-0000-0000-0000000000B1")!,
            center: .init(x: 100, y: 0),
            size: .init(width: 200, height: 200))
        let inBoth = makeNode(center: .init(x: 100, y: 0))
        let onlyBig = makeNode(center: .init(x: -150, y: 0))
        let page = CanvasPageSnapshot(
            nodes: [inBoth, onlyBig],
            regions: [big, small])

        let index = try CanvasPageLayoutIndex(page: page)
        XCTAssertEqual(index.node(id: inBoth.id)?.regionID, small.id)
        XCTAssertEqual(index.node(id: onlyBig.id)?.regionID, big.id)
        XCTAssertEqual(Set(index.nodeIDs(innermostInRegion: small.id)), [inBoth.id])
        XCTAssertEqual(Set(index.nodeIDs(innermostInRegion: big.id)), [onlyBig.id])
    }

    func testCollapsedOverlappingNonNestedRegionsBothVisibleAndDeterministic() throws {
        // Overlapping (not nested) collapsed regions: both chips stay
        // visible. Frames are offset far enough that neither center lies
        // inside the other (center-containment nesting test).
        let first = makeRegion(
            id: UUID(uuidString: "00000000-0000-0000-0000-0000000000C0")!,
            center: .init(x: 0, y: 0),
            size: .init(width: 400, height: 400),   // x -200...200
            collapsed: true)
        let second = makeRegion(
            id: UUID(uuidString: "00000000-0000-0000-0000-0000000000C1")!,
            center: .init(x: 300, y: 0),
            size: .init(width: 400, height: 400),   // x 100...500
            collapsed: true)
        let a = makeNode(center: .init(x: 150, y: 0))  // overlap: both contain it
        let b = makeNode(center: .init(x: 450, y: 0))  // only second
        let cross = makeConnection(from: b.id, to: a.id)
        let page = CanvasPageSnapshot(
            nodes: [a, b],
            connections: [cross],
            regions: [first, second])

        let index = try CanvasPageLayoutIndex(page: page)
        XCTAssertEqual(index.collapsedRegionIDs, [first.id, second.id])
        XCTAssertEqual(index.regions.count, 2)
        // Equal-area overlap: deterministic winner = smaller UUID.
        let expected: UUID = first.id.uuidString < second.id.uuidString ? first.id : second.id
        XCTAssertEqual(index.proxyEdges.count, 1)
        XCTAssertEqual(index.proxyEdges[0].destinationID, expected)
        XCTAssertEqual(index.proxyEdges[0].sourceID, second.id)
        XCTAssertTrue(index.proxyEdges[0].isProxy)
    }

    func testMembershipDistinguishesInnermostFromContained() throws {
        // Outer region with a nested inner region; nodes in the inner region
        // must appear in the OUTER region's contained set (arrange coverage)
        // but not in its innermost set.
        let outer = makeRegion(
            center: .init(x: 0, y: 0),
            size: .init(width: 900, height: 900))
        let inner = makeRegion(
            center: .init(x: 0, y: 0),
            size: .init(width: 400, height: 400))
        let direct = makeNode(center: .init(x: 300, y: 300))  // outer only
        let nested = makeNode(center: .init(x: 0, y: 0))      // inner
        let page = CanvasPageSnapshot(
            nodes: [direct, nested],
            regions: [outer, inner])

        let index = try CanvasPageLayoutIndex(page: page)
        XCTAssertEqual(index.nodeIDs(innermostInRegion: outer.id), [direct.id])
        XCTAssertEqual(index.nodeIDs(innermostInRegion: inner.id), [nested.id])
        // containedIn covers nested members in source order.
        XCTAssertEqual(index.nodeIDs(containedInRegion: outer.id),
                       [direct.id, nested.id])
        XCTAssertEqual(index.nodeIDs(containedInRegion: inner.id), [nested.id])
        XCTAssertEqual(index.nestedRegionIDs(of: outer.id), [inner.id])
        XCTAssertEqual(index.descendantRegionIDs(of: outer.id), [inner.id])
        XCTAssertTrue(index.nestedRegionIDs(of: inner.id).isEmpty)
        XCTAssertEqual(Set(index.nodeIDs(containedInRegion: UUID())) , [])
    }
}
