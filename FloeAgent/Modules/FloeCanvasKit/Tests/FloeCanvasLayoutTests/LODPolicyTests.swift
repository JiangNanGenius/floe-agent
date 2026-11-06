import XCTest
import FloeCanvasCore
import FloeDiagramCore
@testable import FloeCanvasLayout

final class LODPolicyTests: XCTestCase {
    func testLevelThresholds() {
        XCTAssertEqual(CanvasLODPolicy.level(forZoom: 0.05), .overview)
        XCTAssertEqual(CanvasLODPolicy.level(forZoom: 0.119), .overview)
        XCTAssertEqual(CanvasLODPolicy.level(forZoom: 0.12), .preview)
        XCTAssertEqual(CanvasLODPolicy.level(forZoom: 0.349), .preview)
        XCTAssertEqual(CanvasLODPolicy.level(forZoom: 0.35), .standard)
        XCTAssertEqual(CanvasLODPolicy.level(forZoom: 0.749), .standard)
        XCTAssertEqual(CanvasLODPolicy.level(forZoom: 0.75), .full)
        XCTAssertEqual(CanvasLODPolicy.level(forZoom: 4), .full)
        // Non-finite zoom degrades to the safest level instead of trapping.
        XCTAssertEqual(CanvasLODPolicy.level(forZoom: .nan), .overview)
        XCTAssertEqual(CanvasLODPolicy.level(forZoom: .infinity), .full)
    }

    func testHeavyweightContentAllowedFromStandardUp() {
        XCTAssertFalse(CanvasLODLevel.overview.allowsHeavyweightContent)
        XCTAssertFalse(CanvasLODLevel.preview.allowsHeavyweightContent)
        XCTAssertTrue(CanvasLODLevel.standard.allowsHeavyweightContent)
        XCTAssertTrue(CanvasLODLevel.full.allowsHeavyweightContent)
    }

    func testDemandListsHeavyweightOnlyWhenDisallowed() throws {
        let heavy = makeNode(
            kind: .scene3D,
            content: .media(.init(id: UUID(), mimeType: "video/mp4")))
        let light = makeNode(content: .text("note"))
        let nodes = [
            CanvasPreparedNode(
                id: heavy.id, frame: .init(), unrotatedFrame: .init(),
                rotationDegrees: 0, zIndex: 0, isLocked: false, kind: heavy.kind,
                groupID: nil, regionID: nil, visibility: .visible,
                representativeID: heavy.id, order: 0, isHeavyweight: true),
            CanvasPreparedNode(
                id: light.id, frame: .init(), unrotatedFrame: .init(),
                rotationDegrees: 0, zIndex: 1, isLocked: false, kind: light.kind,
                groupID: nil, regionID: nil, visibility: .visible,
                representativeID: light.id, order: 1, isHeavyweight: false),
        ]
        let previewDemand = CanvasLODPolicy.demand(for: nodes, zoom: 0.2)
        XCTAssertEqual(previewDemand.previewDemandIDs, [heavy.id])
        let fullDemand = CanvasLODPolicy.demand(for: nodes, zoom: 2)
        XCTAssertTrue(fullDemand.previewDemandIDs.isEmpty)
        XCTAssertTrue(fullDemand.allowsHeavyweightContent)
    }

    func testRepresentativeSampleIsBoundedDeterministicAndOrdered() {
        var ids: [UUID] = []
        var nodes: [CanvasPreparedNode] = []
        for index in 0..<1000 {
            let id = UUID()
            ids.append(id)
            nodes.append(CanvasPreparedNode(
                id: id, frame: .init(), unrotatedFrame: .init(),
                rotationDegrees: 0, zIndex: index, isLocked: false,
                kind: .content, groupID: nil, regionID: nil,
                visibility: .visible, representativeID: id, order: index,
                isHeavyweight: false))
        }
        let demand = CanvasLODPolicy.demand(for: nodes, zoom: 0.05)
        XCTAssertEqual(demand.representativeNodeIDs.count,
                       CanvasLODPolicy.representativeCap)
        XCTAssertEqual(demand.representativeNodeIDs.first, ids.first)
        XCTAssertEqual(Set(demand.representativeNodeIDs).count,
                       CanvasLODPolicy.representativeCap)
        // Render order preserved.
        let orders = demand.representativeNodeIDs.compactMap { id in
            nodes.first(where: { $0.id == id })?.order
        }
        XCTAssertEqual(orders, orders.sorted())
        // At or below the cap everything is included, in order.
        let smallDemand = CanvasLODPolicy.demand(for: Array(nodes[0..<100]), zoom: 0.05)
        XCTAssertEqual(smallDemand.representativeNodeIDs, Array(ids[0..<100]))
    }
}
