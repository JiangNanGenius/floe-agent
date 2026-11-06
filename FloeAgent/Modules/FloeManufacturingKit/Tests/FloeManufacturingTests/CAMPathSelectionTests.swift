import XCTest
@testable import FloeManufacturingCore

final class CAMPathSelectionTests:XCTestCase {
    private func path(_ id:String,_ points:[SIMD3<Double>?],visible:Bool = true)->CAMPathSelection.Path { .init(id:id,chapterID:"operation:"+id,points:points,visible:visible) }
    func testNearestSegmentClampsEndpointsAndUsesPointUnits() {
        let paths = [path("a",[.init(0,0,0.4),.init(100,0,0.4)]),path("b",[.init(0,30,0.2),.init(100,30,0.2)])]
        XCTAssertEqual(CAMPathSelection.nearest(to:.init(50,28),paths:paths)?.chapterID,"operation:b")
        XCTAssertEqual(CAMPathSelection.nearest(to:.init(-5,0),paths:paths)?.distance,5)
        XCTAssertNil(CAMPathSelection.nearest(to:.init(-15,0),paths:paths))
    }
    func testIndependentPathsAndClippedPointsNeverCreateConnectors() {
        let split = [path("a",[.init(0,0,0.4),.init(10,0,0.4)]),path("b",[.init(90,0,0.4),.init(100,0,0.4)])]
        XCTAssertNil(CAMPathSelection.nearest(to:.init(50,0),paths:split))
        XCTAssertNil(CAMPathSelection.nearest(to:.init(50,0),paths:[path("gap",[.init(0,0,0.4),nil,.init(100,0,0.4)])]))
        XCTAssertNil(CAMPathSelection.nearest(to:.init(50,0),paths:[path("clipped",[.init(0,0,-1),.init(100,0,0.4)])]))
    }
    func testHiddenPathsAndDepthTies() {
        let line:[SIMD3<Double>?] = [.init(0,0,0.8),.init(100,0,0.8)]
        let paths = [path("hidden",line,visible:false),path("back",line),path("front",[.init(0,0,0.2),.init(100,0,0.2)])]
        XCTAssertEqual(CAMPathSelection.nearest(to:.init(50,0),paths:paths)?.pathID,"front")
    }
    func testInvalidInputAndBudgetFailWithoutPartialSelection() {
        let paths = [path("a",[.init(0,0,0.5),.init(10,0,0.5),.init(20,0,0.5)])]
        XCTAssertNil(CAMPathSelection.nearest(to:.init(5,0),paths:paths,maxSegments:1))
        XCTAssertNil(CAMPathSelection.nearest(to:.init(.nan,0),paths:paths))
        XCTAssertNil(CAMPathSelection.nearest(to:.init(0,0),paths:paths,radius:.infinity))
        XCTAssertNil(CAMPathSelection.nearest(to:.init(0,0),paths:[]))
    }
}
