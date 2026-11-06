// SPDX-License-Identifier: MPL-2.0
import Foundation

/// Coordinates are projected by the active renderer. Nil/invalid/clipped points
/// break a polyline; independent paths are never joined for selection.
public enum CAMPathSelection {
    public struct Path:Sendable {
        public var id:String
        public var chapterID:String
        public var points:[SIMD3<Double>?]
        public var visible:Bool
        public init(id:String,chapterID:String,points:[SIMD3<Double>?],visible:Bool = true) {
            self.id = id;self.chapterID = chapterID;self.points = points;self.visible = visible
        }
    }
    public struct Hit:Sendable,Equatable {
        public var pathID:String
        public var chapterID:String
        public var distance:Double
        public var depth:Double
    }
    /// Screen units are UIKit points, not model millimetres. Exceeding the
    /// explicit budget yields no selection rather than a misleading partial hit.
    public static func nearest(to point:SIMD2<Double>,paths:[Path],radius:Double = 14,maxSegments:Int = 200_000)->Hit? {
        guard point.x.isFinite,point.y.isFinite,radius.isFinite,radius>0,maxSegments>0 else { return nil }
        var count = 0,best:Hit?
        for path in paths where path.visible {
            count += max(0,path.points.count-1)
            guard count<=maxSegments else { return nil }
        }
        func valid(_ p:SIMD3<Double>?)->SIMD3<Double>? {
            guard let p,p.x.isFinite,p.y.isFinite,p.z.isFinite,(0...1).contains(p.z) else { return nil };return p
        }
        for path in paths where path.visible && path.points.count>1 {
            for i in 1..<path.points.count {
                guard let a = valid(path.points[i-1]),let b = valid(path.points[i]) else { continue }
                let dx = b.x-a.x,dy = b.y-a.y,length = dx*dx+dy*dy
                let t = length>1e-16 ? max(0,min(1,((point.x-a.x)*dx+(point.y-a.y)*dy)/length)):0
                let distance = hypot(point.x-a.x-t*dx,point.y-a.y-t*dy),depth = a.z+t*(b.z-a.z)
                guard distance.isFinite,depth.isFinite,distance<=radius else { continue }
                if let old = best,distance>old.distance+1e-6 || (abs(distance-old.distance)<=1e-6 && depth>=old.depth) { continue }
                best = .init(pathID:path.id,chapterID:path.chapterID,distance:distance,depth:depth)
            }
        }
        return best
    }
}
