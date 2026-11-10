// SPDX-License-Identifier: MPL-2.0
import Foundation
import CoreGraphics

/// Bounded sampled-pixel painting. Smudge advects the preceding footprint;
/// clone samples the immutable source with the chosen anchor offset.
public enum MediaNativeSampleBrush {
    public enum Mode: Sendable { case smudge,clone(source:ImageFreehandStroke.Point) }
    private struct Stamp { let x:Double;let y:Double }
    public static func render(_ image:CGImage,points:[ImageFreehandStroke.Point],width:Double,strength:Double = 0.7,
                              hardness:Double = 0.8,mode:Mode) throws -> CGImage {
        guard image.width<=8192,image.height<=8192,image.width*image.height<=8_388_608,
              (1...10_000).contains(points.count),width.isFinite,(1...200).contains(width),
              strength.isFinite,(0...1).contains(strength),hardness.isFinite,(0...1).contains(hardness),
              points.allSatisfy({$0.x.isFinite && $0.y.isFinite && (0...1).contains($0.x) && (0...1).contains($0.y)}) else {
            throw MediaPreparedCoreError.invalidOperation("sampled brush exceeds its canvas, point or settings limit")
        }
        let anchor: ImageFreehandStroke.Point?
        switch mode {
        case .clone(let source):
            guard source.x.isFinite,source.y.isFinite,(-1...2).contains(source.x),(-1...2).contains(source.y) else {
                throw MediaPreparedCoreError.invalidOperation("clone source must lie within the bounded source offset")
            }
            anchor = source
        case .smudge:
            guard points.count>=2 else { throw MediaPreparedCoreError.invalidOperation("smudge needs a stroke") }
            anchor = nil
        }
        try Task.checkCancellation()
        if strength == 0 { return image }
        let w = image.width,h = image.height,radius = width/2,step = max(1,radius/3)
        let path = points.map { Stamp(x:$0.x*Double(w-1),y:$0.y*Double(h-1)) }
        var stamps = [path[0]]
        for index in 1..<path.count {
            if index%256 == 0 { try Task.checkCancellation() }
            let previous = path[index-1],current = path[index]
            let count = max(1,Int(ceil(hypot(current.x-previous.x,current.y-previous.y)/step)))
            guard count<=65_536-stamps.count else { throw MediaPreparedCoreError.limitsExceeded("sampled brush stroke length") }
            for i in 1...count {
                let t = Double(i)/Double(count)
                stamps.append(.init(x:previous.x+(current.x-previous.x)*t,y:previous.y+(current.y-previous.y)*t))
            }
        }
        guard Double(stamps.count)*Double.pi*pow(radius+1,2)<=80_000_000 else {
            throw MediaPreparedCoreError.limitsExceeded("sampled brush work; use a shorter stroke or smaller brush")
        }
        let raster = try MediaNativeSelection.rgba(image,maxEdge:8192),original = raster.pixels
        var output = original,previous = stamps[0]
        for (stampIndex,center) in stamps.enumerated() {
            try Task.checkCancellation()
            if anchor == nil && stampIndex == 0 { continue }
            let left = max(0,Int(floor(center.x-radius))),right = min(w-1,Int(ceil(center.x+radius)))
            let top = max(0,Int(floor(center.y-radius))),bottom = min(h-1,Int(ceil(center.y+radius)))
            guard left<=right,top<=bottom else { previous = center;continue }
            let patchWidth = right-left+1,patchHeight = bottom-top+1
            var patch = [UInt8](repeating:0,count:patchWidth*patchHeight*4)
            var valid = [Bool](repeating:false,count:patchWidth*patchHeight)
            let sourceCenter: Stamp
            if let anchor { sourceCenter = .init(x:anchor.x*Double(w-1)+center.x-stamps[0].x,y:anchor.y*Double(h-1)+center.y-stamps[0].y) }
            else { sourceCenter = previous }
            // Capture only a small footprint before writing. Reading the
            // current smudge buffer never copies the whole image per stamp.
            for y in top...bottom { for x in left...right {
                let sx = Int((sourceCenter.x+Double(x)-center.x).rounded()),sy = Int((sourceCenter.y+Double(y)-center.y).rounded())
                guard sx>=0,sx<w,sy>=0,sy<h else { continue }
                let target = (y-top)*patchWidth+x-left,source = (sy*w+sx)*4
                valid[target] = true
                for channel in 0..<4 { patch[target*4+channel] = anchor != nil ? original[source+channel] : output[source+channel] }
            } }
            for y in top...bottom { for x in left...right {
                let distance = hypot(Double(x)-center.x,Double(y)-center.y)/radius
                let p = (y-top)*patchWidth+x-left
                guard distance<=1,valid[p] else { continue }
                let falloff = distance<=hardness ? 1 : (1-distance)/max(0.000_001,1-hardness)
                let weight = strength*falloff,index = (y*w+x)*4
                let alpha = Double(patch[p*4+3])/255
                for channel in 0..<4 {
                    let value:Double
                    if anchor != nil {
                        // Premultiplied source-over: transparent clone
                        // samples cannot erase unrelated existing pixels.
                        value = Double(patch[p*4+channel])*weight+Double(output[index+channel])*(1-alpha*weight)
                    } else {
                        value = Double(patch[p*4+channel])*weight+Double(output[index+channel])*(1-weight)
                    }
                    output[index+channel] = UInt8(max(0,min(255,value.rounded())))
                }
            } }
            previous = center
        }
        try Task.checkCancellation()
        guard let provider = CGDataProvider(data:Data(output) as CFData),
              let result = CGImage(width:w,height:h,bitsPerComponent:8,bitsPerPixel:32,bytesPerRow:w*4,
                space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:.init(rawValue:CGImageAlphaInfo.premultipliedLast.rawValue),
                provider:provider,decode:nil,shouldInterpolate:false,intent:.defaultIntent) else {
            throw MediaPreparedCoreError.invalidOperation("could not create sampled brush image")
        }
        return result
    }
}
