#if canImport(UIKit)
import Foundation
import Testing
@testable import FloeApp

@Suite("FloeApp.CanvasTouchInteraction")
struct CanvasTouchInteractionTests {
    @Test("Pinch zoom keeps the content under the gesture centroid fixed")
    func anchorPreservingZoom() {
        let anchor = CGPoint(x: 420, y: 260)
        let initial = CanvasViewportTransform(
            scale: 0.8,
            pan: CGSize(width: -130, height: 75)
        )
        let contentBefore = CGPoint(
            x: (anchor.x - initial.pan.width) / CGFloat(initial.scale),
            y: (anchor.y - initial.pan.height) / CGFloat(initial.scale)
        )

        let zoomed = initial.zoomed(by: 1.75, around: anchor)
        let contentAfter = CGPoint(
            x: (anchor.x - zoomed.pan.width) / CGFloat(zoomed.scale),
            y: (anchor.y - zoomed.pan.height) / CGFloat(zoomed.scale)
        )

        #expect(abs(contentAfter.x - contentBefore.x) < 0.0001)
        #expect(abs(contentAfter.y - contentBefore.y) < 0.0001)
    }

    @Test("Repeated pinch updates clamp without shifting the anchor")
    func zoomLimits() {
        let anchor = CGPoint(x: 180, y: 120)
        let initial = CanvasViewportTransform(
            scale: 1,
            pan: CGSize(width: 20, height: -40)
        )

        let maximum = initial.zoomed(by: 20, around: anchor)
        let minimum = maximum.zoomed(by: 0.001, around: anchor)

        #expect(maximum.scale == 3)
        #expect(minimum.scale == 0.3)
        let point = CGPoint(
            x: (anchor.x - initial.pan.width) / CGFloat(initial.scale),
            y: (anchor.y - initial.pan.height) / CGFloat(initial.scale)
        )
        #expect(abs((anchor.x - minimum.pan.width) / CGFloat(minimum.scale) - point.x) < 0.0001)
        #expect(abs((anchor.y - minimum.pan.height) / CGFloat(minimum.scale) - point.y) < 0.0001)
    }

    @Test("Two-finger pan applies incremental translation")
    func incrementalPan() {
        let initial = CanvasViewportTransform(
            scale: 1.25,
            pan: CGSize(width: -20, height: 50)
        )
        let moved = initial
            .panned(by: CGSize(width: 18, height: -6))
            .panned(by: CGSize(width: -3, height: 11))

        #expect(moved.scale == initial.scale)
        #expect(moved.pan == CGSize(width: -5, height: 55))
    }
}
#endif
