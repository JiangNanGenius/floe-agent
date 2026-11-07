import Testing
import UIKit
@testable import FloeCAD

@Suite("Explicit CAD drawing input")
@MainActor
struct CADDrawingInputPolicyTests {
    private final class Spy: ViewportGestureDelegate {
        var fingerDrawing = false
        var sources: [CADViewportInputSource] = []
        var pressures: [Double] = []
        var changes = 0
        var cancellations = 0
        func gestureDragBegan(at point: CGPoint, source: CADViewportInputSource, pressure: Double, gestureID: UUID) -> Bool {
            sources.append(source); pressures.append(pressure)
            return source.editsDrawing(fingerDrawingEnabled: fingerDrawing)
        }
        func gestureDragBegan(at point: CGPoint, isPencil: Bool) -> Bool {
            Issue.record("A source-aware viewport must not lose pointer identity")
            return false
        }
        func gestureDragChanged(at point: CGPoint) { changes += 1 }
        func gestureDragEnded(at point: CGPoint) {}
        func gestureDragCancelled(at point: CGPoint) { cancellations += 1 }
        func gestureTapped(at point: CGPoint) {}
        func gestureDoubleTapped(at point: CGPoint) {}
        func gestureLongPressed(at point: CGPoint) {}
        func gestureHovered(at point: CGPoint?) {}
        func gesturePencilDoubleTapped() {}
    }

    @Test func pencilThenMouseKeepEditingAndFingerChoiceReachesTheSameOwnedController() {
        let controller = ViewportGestureController(), spy = Spy()
        controller.delegate = spy
        #expect(controller.claimDrag(at: .zero, source: CADViewportInputSource(.pencil), pressure: 0.3))
        controller.finishClaimedDrag(at: .zero, cancelled: false)
        #expect(controller.claimDrag(at: .zero, source: CADViewportInputSource(.indirectPointer)))
        controller.changeClaimedDrag(at: CGPoint(x: 12, y: 0))
        controller.finishClaimedDrag(at: .zero, cancelled: true)
        controller.changeClaimedDrag(at: CGPoint(x: 24, y: 0))
        #expect(spy.changes == 1 && spy.cancellations == 1)
        #expect(!controller.claimDrag(at: .zero, source: CADViewportInputSource(.direct)))
        spy.fingerDrawing = true
        #expect(controller.claimDrag(at: .zero, source: CADViewportInputSource(.direct)))
        controller.finishClaimedDrag(at: .zero, cancelled: false)
        #expect(spy.sources == [.pencil, .pointer, .finger, .finger])
        #expect(spy.pressures == [0.3, 1, 1, 1])
    }
}
