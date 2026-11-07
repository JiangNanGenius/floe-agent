// SPDX-License-Identifier: MPL-2.0
import Foundation

/// Perspective framing of measured coordinates. Only the camera moves; the
/// source geometry and its physical proportions are never changed.
public struct BiologyViewportFraming:Sendable {
    public let distance:Float
    public let quarterTurn:Bool
    public let near:Float
    public let far:Float

    public static func fit(points:[SIMD3<Float>],offset:SIMD3<Float> = .zero,radius:Float=0,aspect:Float,verticalFieldOfView:Float=38)->Self? {
        guard !points.isEmpty,aspect.isFinite,aspect>0,verticalFieldOfView.isFinite,
              verticalFieldOfView>0,verticalFieldOfView<180,radius.isFinite,radius>=0,
              offset.x.isFinite,offset.y.isFinite,offset.z.isFinite else{return nil}
        let vertical=verticalFieldOfView * .pi/360,horizontal=atan(tan(vertical)*aspect)
        let tanV=tan(vertical),tanH=tan(horizontal),margin:Float=1.08
        var normal:Float=0,turned:Float=0,lowZ=Float.infinity,highZ = -Float.infinity,extent:Float=0
        for point in points {
            let p=point+offset
            guard p.x.isFinite,p.y.isFinite,p.z.isFinite else{return nil}
            let x=abs(p.x),y=abs(p.y)
            normal=max(normal,p.z+margin*max(x/tanH+radius/sin(horizontal),y/tanV+radius/sin(vertical)))
            turned=max(turned,p.z+margin*max(y/tanH+radius/sin(horizontal),x/tanV+radius/sin(vertical)))
            lowZ=min(lowZ,p.z-radius);highZ=max(highZ,p.z+radius)
            extent=max(extent,sqrt(p.x*p.x+p.y*p.y+p.z*p.z)+radius)
        }
        // Avoid arbitrary flips of near-square structures. A quarter turn is
        // useful only when it gives the measured model substantially more room.
        let quarterTurn=turned<normal*0.94
        let clearance=max(0.01,(highZ-lowZ)*0.01)
        let distance=max(quarterTurn ? turned:normal,highZ+clearance)
        let near=max(0.001,min(clearance*0.01,(distance-highZ)*0.5))
        // Leave depth room for subsequent native orbit and zoom gestures.
        let far=max(near+1,distance+extent*4)
        guard distance.isFinite,near.isFinite,far.isFinite else{return nil}
        return .init(distance:distance,quarterTurn:quarterTurn,near:near,far:far)
    }
}
