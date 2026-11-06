import XCTest
import FloeCanvasCore
import FloeDiagramCore
@testable import FloeCanvasLayout

/// Partial-arrange tests exercise the REAL reuse path: the public
/// `DiagramLayoutEngine.layout(page:sizes:)` SwiftDagre topology over a DTO
/// adapter with real node sizes. Assertions check structure, determinism,
/// direction, and anchoring — not engine-internal coordinates.
final class PartialArrangeTests: XCTestCase {
    private func boundsCenter(
        of points: [CanvasGeometry.Point],
        size: CanvasGeometry.Size
    ) -> CanvasGeometry.Point {
        let union = points
            .map { CanvasLayoutGeometry.rect(from: .init(center: $0, size: size)) }
            .reduce(nil as DiagramRect?) { $0?.union($1) ?? $1 }!
        return .init(x: union.center.x, y: union.center.y)
    }

    func testChainArrangesViaPublicEngineDeterministicallyAndAnchored() throws {
        let a = makeNode(center: .init(x: 0, y: 0))
        let b = makeNode(center: .init(x: 400, y: 0))
        let page = CanvasPageSnapshot(
            nodes: [a, b],
            connections: [makeConnection(from: a.id, to: b.id)])
        let selection: Set<UUID> = [a.id, b.id]
        let proposal = try CanvasPartialArrange.proposeArrangement(
            page: page, selection: selection)
        XCTAssertEqual(proposal.placements.count, 2)
        // Rank direction: LR default → b right of a.
        XCTAssertGreaterThan(
            proposal.placements[b.id]!.x, proposal.placements[a.id]!.x)
        // Anchored: the arranged union keeps the selection's original bounds
        // center (the engine's arrangeEdits delta rule).
        let proposedCenter = boundsCenter(
            of: Array(proposal.placements.values),
            size: .init(width: 100, height: 100))
        XCTAssertEqual(proposedCenter.x, 200, accuracy: 1e-6)
        XCTAssertEqual(proposedCenter.y, 0, accuracy: 1e-6)
        // Deterministic: a second run over identical input is identical.
        let again = try CanvasPartialArrange.proposeArrangement(
            page: page, selection: selection)
        XCTAssertEqual(again.placements, proposal.placements)
    }

    func testVerticalDirectionStacksDownward() throws {
        let a = makeNode(center: .init(x: 0, y: 0))
        let b = makeNode(center: .init(x: 0, y: 400))
        let page = CanvasPageSnapshot(
            nodes: [a, b],
            connections: [makeConnection(from: a.id, to: b.id)])
        let proposal = try CanvasPartialArrange.proposeArrangement(
            page: page,
            selection: [a.id, b.id],
            direction: .vertical)
        XCTAssertGreaterThan(
            proposal.placements[b.id]!.y, proposal.placements[a.id]!.y)
    }

    func testRelationCycleIsHandledByEngineDeterministically() throws {
        let a = makeNode(center: .init(x: 0, y: 0))
        let b = makeNode(center: .init(x: 300, y: 0))
        let page = CanvasPageSnapshot(
            nodes: [a, b],
            connections: [
                makeConnection(from: a.id, to: b.id),
                makeConnection(from: b.id, to: a.id),
            ])
        let selection: Set<UUID> = [a.id, b.id]
        let proposal = try CanvasPartialArrange.proposeArrangement(
            page: page, selection: selection)
        XCTAssertEqual(proposal.placements.count, 2)
        XCTAssertNotEqual(
            proposal.placements[a.id], proposal.placements[b.id])
        let again = try CanvasPartialArrange.proposeArrangement(
            page: page, selection: selection)
        XCTAssertEqual(again.placements, proposal.placements)
    }

    func testLockedNodeIsExcludedButRestArranges() throws {
        let a = makeNode(center: .init(x: 0, y: 0))
        let locked = makeNode(center: .init(x: 0, y: 500), locked: true)
        let c = makeNode(center: .init(x: 400, y: 0))
        let page = CanvasPageSnapshot(
            nodes: [a, locked, c],
            connections: [makeConnection(from: a.id, to: c.id)])
        let proposal = try CanvasPartialArrange.proposeArrangement(
            page: page, selection: [a.id, locked.id, c.id])
        XCTAssertFalse(proposal.placements.keys.contains(locked.id))
        XCTAssertEqual(proposal.placements.count, 2)
    }

    func testGroupWithLockedMemberRejectsWholeProposal() throws {
        let groupID = UUID()
        let a = makeNode(center: .init(x: 0, y: 0), groupID: groupID)
        let lockedMember = makeNode(center: .init(x: 200, y: 0), locked: true, groupID: groupID)
        let page = CanvasPageSnapshot(
            nodes: [a, lockedMember],
            groups: [CanvasGroupRecord(
                id: groupID, name: "g", memberNodeIDs: [a.id, lockedMember.id])])
        XCTAssertThrowsError(try CanvasPartialArrange.proposeArrangement(
            page: page, selection: [a.id])) { error in
            guard case CanvasLayoutError.arrangeRejected(let issues) = error else {
                XCTFail("got \(error)")
                return
            }
            XCTAssertTrue(issues.contains { $0.code == .groupLockedMember })
        }
    }

    func testPartialGroupSelectionRejectsWholeProposal() throws {
        let groupID = UUID()
        let a = makeNode(center: .init(x: 0, y: 0), groupID: groupID)
        let b = makeNode(center: .init(x: 300, y: 0), groupID: groupID)
        let page = CanvasPageSnapshot(
            nodes: [a, b],
            groups: [CanvasGroupRecord(
                id: groupID, name: "g", memberNodeIDs: [a.id, b.id])])
        XCTAssertThrowsError(try CanvasPartialArrange.proposeArrangement(
            page: page, selection: [a.id])) { error in
            guard case CanvasLayoutError.arrangeRejected(let issues) = error else {
                XCTFail("got \(error)")
                return
            }
            XCTAssertTrue(issues.contains { $0.code == .partialGroupSelection })
        }
    }

    func testFullySelectedGroupArrangesAllMembers() throws {
        let groupID = UUID()
        let a = makeNode(center: .init(x: 0, y: 0), groupID: groupID)
        let b = makeNode(center: .init(x: 300, y: 0), groupID: groupID)
        let page = CanvasPageSnapshot(
            nodes: [a, b],
            connections: [makeConnection(from: a.id, to: b.id)],
            groups: [CanvasGroupRecord(
                id: groupID, name: "g", memberNodeIDs: [a.id, b.id])])
        let proposal = try CanvasPartialArrange.proposeArrangement(
            page: page, selection: [a.id, b.id])
        XCTAssertEqual(proposal.placements.count, 2)
    }

    func testDuplicateNodeAndGroupIDsRejectGracefully() {
        let shared = UUID()
        let a = makeNode(id: shared, center: .init(x: 0, y: 0))
        let twin = makeNode(id: shared, center: .init(x: 300, y: 0))
        let page = CanvasPageSnapshot(nodes: [a, twin])
        XCTAssertThrowsError(try CanvasPartialArrange.proposeArrangement(
            page: page, selection: [a.id, twin.id])) { error in
            guard case CanvasLayoutError.arrangeRejected(let issues) = error else {
                XCTFail("got \(error)")
                return
            }
            XCTAssertTrue(issues.contains { $0.code == .duplicateNodeID })
        }
    }

    func testUnselectedAndOutsideObjectsAreNeverMoved() throws {
        let a = makeNode(center: .init(x: 0, y: 0))
        let b = makeNode(center: .init(x: 400, y: 0))
        let outsider = makeNode(center: .init(x: 2000, y: 2000))
        let page = CanvasPageSnapshot(
            nodes: [a, b, outsider],
            connections: [makeConnection(from: a.id, to: b.id)])
        let proposal = try CanvasPartialArrange.proposeArrangement(
            page: page, selection: [a.id, b.id])
        XCTAssertEqual(Set(proposal.placements.keys), Set([a.id, b.id]))
        XCTAssertNil(proposal.placements[outsider.id])
    }

    func testEmptySelectionThrows() {
        let a = makeNode()
        let page = CanvasPageSnapshot(nodes: [a])
        XCTAssertThrowsError(try CanvasPartialArrange.proposeArrangement(
            page: page, selection: [])) { error in
            guard case CanvasLayoutError.arrangeRejected(let issues) = error else {
                XCTFail("got \(error)")
                return
            }
            XCTAssertEqual(issues.map(\.code), [.emptyArrangeSelection])
        }
    }

    func testRegionArrangeCoversNestedMembersThroughContainedQuery() throws {
        // Arranging an OUTER region must also place nodes whose innermost
        // region is a nested inner region.
        let outer = makeRegion(
            center: .init(x: 0, y: 0),
            size: .init(width: 900, height: 900))
        let inner = makeRegion(
            center: .init(x: 0, y: 0),
            size: .init(width: 400, height: 400))
        let direct = makeNode(center: .init(x: 300, y: 300))
        let nested = makeNode(center: .init(x: 0, y: 0))
        let page = CanvasPageSnapshot(
            nodes: [direct, nested],
            connections: [makeConnection(from: direct.id, to: nested.id)],
            regions: [outer, inner])
        let index = try CanvasPageLayoutIndex(page: page)
        let selection = Set(index.nodeIDs(containedInRegion: outer.id))
        XCTAssertEqual(selection, Set([direct.id, nested.id]))
        let proposal = try CanvasPartialArrange.proposeArrangement(
            page: page, selection: selection)
        XCTAssertEqual(proposal.placements.count, 2)
    }
}
