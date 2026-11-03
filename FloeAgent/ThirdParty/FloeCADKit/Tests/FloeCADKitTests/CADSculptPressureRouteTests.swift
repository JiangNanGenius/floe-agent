// SPDX-License-Identifier: MPL-2.0
#if canImport(UIKit)
import XCTest
import UIKit
@testable import FloeCAD

/// Component delivery through the SAME controller claim/change/cancel methods
/// called by UIPan. This verifies normalized values and gesture ownership; it
/// does not stand in for a physical UITouch/Pencil force acceptance run.
@MainActor final class CADSculptPressureRouteTests:XCTestCase {
    private final class Spy:ViewportGestureDelegate {
        var pressures:[Double]=[]
        var id:UUID?
        var changes=0
        var cancellations=0
        func gestureDragBegan(at point:CGPoint,isPencil:Bool,pressure:Double,gestureID:UUID) -> Bool { pressures.append(pressure);id=gestureID;return true }
        func gestureDragPressureChanged(_ pressure:Double,gestureID:UUID) { if id==gestureID { pressures.append(pressure) } }
        func gestureDragBegan(at point:CGPoint,isPencil:Bool) -> Bool { true }
        func gestureDragChanged(at point:CGPoint) { changes+=1 }
        func gestureDragEnded(at point:CGPoint) {}
        func gestureDragCancelled(at point:CGPoint) { cancellations+=1 }
        func gestureTapped(at point:CGPoint) {}
        func gestureDoubleTapped(at point:CGPoint) {}
        func gestureLongPressed(at point:CGPoint) {}
        func gestureHovered(at point:CGPoint?) {}
        func gesturePencilDoubleTapped() {}
    }
    func testPressureReachesOwnedDragAndCancelledIdentityCannotAppendSamples() {
        let controller=ViewportGestureController(),spy=Spy();controller.delegate=spy
        XCTAssertTrue(controller.claimDrag(at:.zero,isPencil:true,pressure:0.2))
        controller.changeClaimedDrag(at:CGPoint(x:10,y:0),pressure:0.8)
        XCTAssertEqual(spy.pressures,[0.2,0.8]);XCTAssertEqual(spy.changes,1)
        controller.finishClaimedDrag(at:CGPoint(x:10,y:0),cancelled:true)
        controller.changeClaimedDrag(at:CGPoint(x:20,y:0),pressure:1)
        XCTAssertEqual(spy.cancellations,1);XCTAssertEqual(spy.pressures,[0.2,0.8]);XCTAssertEqual(spy.changes,1)
        XCTAssertTrue(controller.claimDrag(at:.zero,isPencil:false))
        XCTAssertEqual(spy.pressures.last,1,"Existing finger delivery retains unit pressure")
    }
}
#endif
