import XCTest
import FloeCanvasCore
import FloeDiagramCore
@testable import FloeCanvasLayout

final class GeometryAdapterTests: XCTestCase {
    func testCenterFrameToRectRoundTripsWithNegativeCoordinates() {
        let frame = CanvasGeometry.Frame(
            center: .init(x: -100, y: -50),
            size: .init(width: 200, height: 100))
        let rect = CanvasLayoutGeometry.rect(from: frame)
        XCTAssertEqual(rect.x, -200)
        XCTAssertEqual(rect.y, -100)
        XCTAssertEqual(rect.width, 200)
        XCTAssertEqual(rect.height, 100)
        let back = CanvasLayoutGeometry.frame(from: rect)
        XCTAssertEqual(back, frame)
    }

    func testZeroRotationKeepsBoundsIdentical() {
        let frame = CanvasGeometry.Frame(
            center: .init(x: 40, y: -30),
            size: .init(width: 120, height: 80))
        let bounds = CanvasLayoutGeometry.rotatedBounds(frame, rotationDegrees: 0)
        XCTAssertEqual(bounds, CanvasLayoutGeometry.rect(from: frame))
    }

    func testNinetyDegreeRotationSwapsExtents() {
        let frame = CanvasGeometry.Frame(
            center: .init(x: 10, y: 20),
            size: .init(width: 200, height: 100))
        let bounds = CanvasLayoutGeometry.rotatedBounds(frame, rotationDegrees: 90)
        XCTAssertEqual(bounds.width, 100, accuracy: 1e-9)
        XCTAssertEqual(bounds.height, 200, accuracy: 1e-9)
        XCTAssertEqual(bounds.center.x, 10, accuracy: 1e-9)
        XCTAssertEqual(bounds.center.y, 20, accuracy: 1e-9)
    }

    func testNegativeCoordinateRotationPreservesCenter() {
        let frame = CanvasGeometry.Frame(
            center: .init(x: -400, y: 250),
            size: .init(width: 100, height: 50))
        let bounds = CanvasLayoutGeometry.rotatedBounds(frame, rotationDegrees: 33)
        XCTAssertEqual(bounds.center.x, -400, accuracy: 1e-9)
        XCTAssertEqual(bounds.center.y, 250, accuracy: 1e-9)
        XCTAssertTrue(bounds.isValid)
    }

    func testInnermostRegionPrefersSmallestAreaThenID() {
        let big = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        let smallHighID = UUID(uuidString: "00000000-0000-0000-0000-0000000000FF")!
        let smallLowID = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
        let point = DiagramPoint(x: 0, y: 0)
        let candidates = [
            (id: big, rect: DiagramRect(x: -100, y: -100, width: 200, height: 200)),
            (id: smallHighID, rect: DiagramRect(x: -50, y: -50, width: 100, height: 100)),
            (id: smallLowID, rect: DiagramRect(x: -50, y: -50, width: 100, height: 100)),
        ]
        // Equal-area overlap breaks on the smaller UUID.
        XCTAssertEqual(
            CanvasLayoutGeometry.innermostRegion(containing: point, among: candidates),
            smallLowID)
        // Remove the smaller-ID twin: the larger area loses to the smaller one.
        let withoutTwin = candidates.filter { $0.id != smallLowID }
        XCTAssertEqual(
            CanvasLayoutGeometry.innermostRegion(containing: point, among: withoutTwin),
            smallHighID)
    }

    func testSafeWorldRectGuardsHugeCoordinates() {
        XCTAssertTrue(CanvasLayoutGeometry.isSafeWorldRect(
            DiagramRect(x: -1e6, y: -1e6, width: 2e6, height: 2e6)))
        XCTAssertFalse(CanvasLayoutGeometry.isSafeWorldRect(
            DiagramRect(x: 1e300, y: 0, width: 100, height: 100)))
        XCTAssertFalse(CanvasLayoutGeometry.isSafeWorldRect(
            DiagramRect(x: .nan, y: 0, width: 100, height: 100)))
        XCTAssertFalse(CanvasLayoutGeometry.isSafeWorldRect(
            DiagramRect(x: 0, y: 0, width: -1, height: 100)))
        // A huge but finite SIZE is not a valid diagram rect either.
        XCTAssertFalse(CanvasLayoutGeometry.isSafeWorldRect(
            DiagramRect(x: 0, y: 0, width: 1e300, height: 100)))
        // A finite but oversized SPAN (corners in range) is rejected before
        // the cell-count multiplication can overflow Int.
        XCTAssertFalse(CanvasLayoutGeometry.isSafeWorldRect(
            DiagramRect(x: 0, y: 0, width: 1e12, height: 1e12)))
        // Largest diagram-valid frame (origin < 1e9, span just under the cap)
        // is accepted; the safe-extent guard still applies to its far corner.
        XCTAssertTrue(CanvasLayoutGeometry.isSafeWorldRect(
            DiagramRect(x: -999_999_999, y: 0, width: 9_999_999, height: 100)))
    }

    func testSafeQueryRectCapsQuerySize() {
        // Within world extent but too large for the cell-count math.
        XCTAssertFalse(CanvasLayoutGeometry.isSafeQueryRect(
            DiagramRect(x: 0, y: 0, width: 1e8, height: 1e8)))
        // Valid origin and size passes.
        XCTAssertTrue(CanvasLayoutGeometry.isSafeQueryRect(
            DiagramRect(x: -999_999_999, y: -999_999_999, width: 2, height: 2)))
        XCTAssertFalse(CanvasLayoutGeometry.isSafeQueryRect(
            DiagramRect(x: -1e16, y: 0, width: 2, height: 2)))
    }
}
