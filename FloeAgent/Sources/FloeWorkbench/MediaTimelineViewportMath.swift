// SPDX-License-Identifier: MPL-2.0
import Foundation

public enum MediaTimelineViewportMath {
    public static let zoomRange=0.5...6.0
    public static func scale(zoom:Double) -> Double {35*min(zoomRange.upperBound,max(zoomRange.lowerBound,zoom.isFinite ? zoom:1))}
    public static func time(contentX:Double,zoom:Double,duration:Double) -> Double {
        guard contentX.isFinite,duration.isFinite,duration>=0 else{return 0}
        return min(duration,max(0,contentX/scale(zoom:zoom)))
    }
    public static func movedStart(_ original:Double,translation:Double,zoom:Double) -> Double {
        guard original.isFinite,translation.isFinite else{return max(0,original.isFinite ? original:0)}
        return max(0,original+translation/scale(zoom:zoom))
    }
    public static func anchoredOffset(time:Double,viewportX:Double,zoom:Double,contentWidth:Double,viewportWidth:Double) -> Double {
        guard [time,viewportX,contentWidth,viewportWidth].allSatisfy(\.isFinite) else{return 0}
        return min(max(0,contentWidth-viewportWidth),max(0,time*scale(zoom:zoom)-viewportX))
    }
    public static func trimTarget(_ proposed:Double,leading:Bool,start:Double,end:Double,sourceStart:Double,sourceEnd:Double,speed:Double,assetDuration:Double?,frameDuration:Double) -> Double {
        guard [proposed,start,end,sourceStart,sourceEnd,speed,frameDuration].allSatisfy(\.isFinite),speed>0,frameDuration>0 else{return leading ? start:end}
        let low=leading ? max(0,start-sourceStart/speed):start+frameDuration
        let high=leading ? end-frameDuration:assetDuration.flatMap{$0.isFinite ? end+max(0,$0-sourceEnd)/speed:nil} ?? max(end,proposed)
        return min(max(low,high),max(low,proposed))
    }
}
