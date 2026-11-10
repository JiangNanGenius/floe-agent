import Foundation
import Testing
@testable import FloeWorkbench

@Suite("RQ45 timeline viewport and edit boundaries")
struct MediaTimelineInteractionTests {
    @Test func rulerMappingUsesScrolledContentCoordinatesAndClamps() {
        for zoom in [0.5,1.0,3,6]{let scale=MediaTimelineViewportMath.scale(zoom:zoom);#expect(MediaTimelineViewportMath.time(contentX:12.5*scale,zoom:zoom,duration:60)==12.5)}
        #expect(MediaTimelineViewportMath.time(contentX:-20,zoom:1,duration:60)==0)
        #expect(MediaTimelineViewportMath.time(contentX:5000,zoom:1,duration:60)==60)
        #expect(MediaTimelineViewportMath.time(contentX:.nan,zoom:1,duration:60)==0)
    }
    @Test func pinchRetainsTimeUnderFingersAndBoundsScroll() {
        let time=15.0,x=120.0
        let offset=MediaTimelineViewportMath.anchoredOffset(time:time,viewportX:x,zoom:3,contentWidth:6000,viewportWidth:400)
        #expect((offset+x)/MediaTimelineViewportMath.scale(zoom:3)==time)
        #expect(MediaTimelineViewportMath.anchoredOffset(time:0,viewportX:120,zoom:6,contentWidth:1000,viewportWidth:400)==0)
        #expect(MediaTimelineViewportMath.anchoredOffset(time:100,viewportX:120,zoom:6,contentWidth:1000,viewportWidth:400)==600)
    }
    @Test func movesAndRetimedTrimBoundsRespectSourceHandlesAndMinimumFrame() {
        #expect(MediaTimelineViewportMath.movedStart(10,translation:70,zoom:2)==11)
        #expect(MediaTimelineViewportMath.movedStart(1,translation:-1000,zoom:1)==0)
        let lower=MediaTimelineViewportMath.trimTarget(-10,leading:true,start:5,end:10,sourceStart:4,sourceEnd:14,speed:2,assetDuration:20,frameDuration:1/30)
        #expect(lower==3)
        let upper=MediaTimelineViewportMath.trimTarget(100,leading:false,start:5,end:10,sourceStart:4,sourceEnd:14,speed:2,assetDuration:20,frameDuration:1/30)
        #expect(upper==13)
        #expect(MediaTimelineViewportMath.trimTarget(100,leading:true,start:5,end:10,sourceStart:4,sourceEnd:14,speed:2,assetDuration:20,frameDuration:1/30)==10.0-1.0/30.0)
    }
}
