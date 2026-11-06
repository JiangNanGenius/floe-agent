import XCTest
import FloeDiagramCore
@testable import FloeCanvasLayout

final class ViewportTransformTests: XCTestCase {
    private let viewSize = DiagramSize(width: 390, height: 844)

    func testWorldViewRoundTrip() throws {
        let transform = try CanvasViewportTransform(
            center: .init(x: 100, y: 50),
            scale: 2,
            viewSize: viewSize)
        let world = DiagramPoint(x: 123.5, y: -456.25)
        let roundTripped = transform.viewToWorld(transform.worldToView(world))
        XCTAssertEqual(roundTripped.x, world.x, accuracy: 1e-9)
        XCTAssertEqual(roundTripped.y, world.y, accuracy: 1e-9)
    }

    func testRejectsNonFiniteAndOutOfRangeInputs() {
        XCTAssertThrowsError(try CanvasViewportTransform(
            center: .init(x: .nan, y: 0), scale: 1, viewSize: viewSize)) { error in
            guard case CanvasLayoutError.invalidInput = error else {
                XCTFail("got \(error)")
                return
            }
        }
        XCTAssertThrowsError(try CanvasViewportTransform(
            center: .zero, scale: 0, viewSize: viewSize))
        XCTAssertThrowsError(try CanvasViewportTransform(
            center: .zero, scale: 100, viewSize: viewSize))
        XCTAssertThrowsError(try CanvasViewportTransform(
            center: .zero, scale: 1, viewSize: DiagramSize(width: 0, height: 844)))
        XCTAssertThrowsError(try CanvasViewportTransform(
            center: .zero, scale: 1, viewSize: DiagramSize(width: 390, height: .infinity)))
    }

    func testVisibleWorldRectIncludesOverscanInScreenPoints() throws {
        let transform = try CanvasViewportTransform(
            center: .zero, scale: 1, viewSize: viewSize)
        let rect = transform.visibleWorldRect(overscan: 100)
        XCTAssertEqual(rect, DiagramRect(x: -295, y: -522, width: 590, height: 1044))
        // Overscan converts through zoom: at scale 2, 100 screen points are 50
        // world units.
        let zoomed = try CanvasViewportTransform(
            center: .zero, scale: 2, viewSize: viewSize)
        let zoomedRect = zoomed.visibleWorldRect(overscan: 100)
        XCTAssertEqual(zoomedRect.width, 390 / 2 + 50 * 2, accuracy: 1e-9)
    }

    func testWorldHitToleranceConvertsConstantScreenTarget() throws {
        let transform = try CanvasViewportTransform(
            center: .zero, scale: 3, viewSize: viewSize)
        XCTAssertEqual(transform.worldHitTolerance(screenPoints: 12), 4, accuracy: 1e-9)
    }

    func testPanKeepsWorldPointUnderFingerFixed() throws {
        let transform = try CanvasViewportTransform(
            center: .init(x: 500, y: 300), scale: 1.5, viewSize: viewSize)
        let finger = DiagramPoint(x: 120, y: 400)
        let worldBefore = transform.viewToWorld(finger)
        let delta = DiagramPoint(x: 37, y: -12)
        let panned = transform.panned(byViewDelta: delta)
        // The grabbed world point must sit under the finger at its NEW view
        // position after the drag — the canvas follows the finger.
        let worldAfter = panned.viewToWorld(.init(
            x: finger.x + delta.x, y: finger.y + delta.y))
        XCTAssertEqual(worldAfter.x, worldBefore.x, accuracy: 1e-9)
        XCTAssertEqual(worldAfter.y, worldBefore.y, accuracy: 1e-9)
        // Sanity: the pan actually moved the center by -delta / scale.
        XCTAssertEqual(panned.center.x, 500 - 37 / 1.5, accuracy: 1e-9)
        XCTAssertEqual(panned.center.y, 300 + 12 / 1.5, accuracy: 1e-9)
    }

    func testZoomAtAnchorKeepsWorldPointFixed() throws {
        let transform = try CanvasViewportTransform(
            center: .init(x: -200, y: 75), scale: 1, viewSize: viewSize)
        let anchor = DiagramPoint(x: 97, y: 208)
        let worldBefore = transform.viewToWorld(anchor)
        guard let zoomed = transform.zoomed(byFactor: 2.4, anchorViewPoint: anchor) else {
            XCTFail("expected zoom to succeed")
            return
        }
        XCTAssertEqual(zoomed.scale, 2.4, accuracy: 1e-9)
        let worldAfter = zoomed.viewToWorld(anchor)
        XCTAssertEqual(worldAfter.x, worldBefore.x, accuracy: 1e-9)
        XCTAssertEqual(worldAfter.y, worldBefore.y, accuracy: 1e-9)
    }

    func testZoomClampsToScaleRange() throws {
        let transform = try CanvasViewportTransform(
            center: .zero, scale: 7, viewSize: viewSize)
        XCTAssertNil(transform.zoomed(byFactor: 2))
        XCTAssertNotNil(transform.zoomed(byFactor: 0.5))
        let small = try CanvasViewportTransform(
            center: .zero, scale: 0.1, viewSize: viewSize)
        XCTAssertNil(small.zoomed(byFactor: 0.4))
        XCTAssertNil(small.zoomed(byFactor: .nan))
        XCTAssertNil(small.zoomed(byFactor: 0))
    }

    func testFitSupports390PointViewport() throws {
        let transform = try CanvasViewportTransform(
            center: .zero, scale: 1, viewSize: viewSize)
        // Large-canvas overview: fit scale clamps to the range minimum.
        let huge = DiagramRect(x: 0, y: 0, width: 10000, height: 8000)
        guard let fittedHuge = transform.fitting(huge, padding: 32) else {
            XCTFail("expected fit to succeed")
            return
        }
        XCTAssertEqual(fittedHuge.scale, CanvasViewportTransform.scaleRange.lowerBound)
        XCTAssertEqual(fittedHuge.center, huge.center)
        // Ordinary content fits unclamped.
        let moderate = DiagramRect(x: 0, y: 0, width: 2000, height: 1000)
        guard let fitted = transform.fitting(moderate, padding: 32) else {
            XCTFail("expected fit to succeed")
            return
        }
        XCTAssertEqual(fitted.scale, min(326.0 / 2000, 780.0 / 1000), accuracy: 1e-9)
        XCTAssertEqual(fitted.center, moderate.center)
    }

    func testFitRejectsDegenerateBounds() throws {
        let transform = try CanvasViewportTransform(
            center: .zero, scale: 1, viewSize: viewSize)
        XCTAssertNil(transform.fitting(DiagramRect(x: 0, y: 0, width: 0, height: 100)))
        XCTAssertNil(transform.fitting(DiagramRect(x: 0, y: 0, width: 100, height: 0)))
        XCTAssertNil(transform.fitting(DiagramRect(x: .nan, y: 0, width: 100, height: 100)))
    }
}
