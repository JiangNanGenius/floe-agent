// SPDX-License-Identifier: MPL-2.0
import Foundation
import CoreGraphics
import CoreImage

/// Gradient-domain repair. Texture gradients come from the sampled source;
/// the selected target boundary supplies the local illumination/color.
public enum MediaNativePatchBlend {
    public static func patch(_ image:CGImage,selection:ImageSelection,sourceCenter:ImageFreehandStroke.Point,
                             iterations:Int = 160) throws -> CGImage {
        try Task.checkCancellation()
        guard image.width<=8192,image.height<=8192,image.width*image.height<=8_388_608,
              sourceCenter.x.isFinite,sourceCenter.y.isFinite,(0...1).contains(sourceCenter.x),(0...1).contains(sourceCenter.y),
              let mask = ImageSelectionRasterizer.maskImage(for:selection,canvas:.init(width:image.width,height:image.height)),
              let coverage = CIContext(options:[.cacheIntermediates:false]).createCGImage(mask,from:.init(x:0,y:0,width:image.width,height:image.height)) else {
            throw MediaPreparedCoreError.invalidOperation("patch needs a selected target and a source point")
        }
        return try solve(image,coverage:coverage,sourceCenter:sourceCenter,sourceOffset:nil,iterations:iterations)
    }
    public static func patchDragging(_ image:CGImage,selection:ImageSelection,from start:ImageFreehandStroke.Point,
                                     to end:ImageFreehandStroke.Point,iterations:Int = 160) throws -> CGImage {
        try Task.checkCancellation()
        guard image.width<=8192,image.height<=8192,image.width*image.height<=8_388_608,
              [start.x,start.y,end.x,end.y].allSatisfy({$0.isFinite && (0...1).contains($0)}),
              let mask = ImageSelectionRasterizer.maskImage(for:selection,canvas:.init(width:image.width,height:image.height)),
              let coverage = CIContext(options:[.cacheIntermediates:false]).createCGImage(mask,from:.init(x:0,y:0,width:image.width,height:image.height)) else {
            throw MediaPreparedCoreError.invalidOperation("patch needs a selected target and a valid drag")
        }
        return try solve(image,coverage:coverage,sourceCenter:nil,
            sourceOffset:.init(x:(end.x-start.x)*Double(image.width),y:(end.y-start.y)*Double(image.height)),iterations:iterations)
    }
    public static func healStroke(_ image:CGImage,points:[ImageFreehandStroke.Point],width:Double,
                                  sourceAnchor:ImageFreehandStroke.Point,iterations:Int = 160) throws -> CGImage {
        try Task.checkCancellation()
        guard image.width<=8192,image.height<=8192,image.width*image.height<=8_388_608,
              (1...10_000).contains(points.count),width.isFinite,(1...200).contains(width),
              points.allSatisfy({$0.x.isFinite && $0.y.isFinite && (0...1).contains($0.x) && (0...1).contains($0.y)}),
              sourceAnchor.x.isFinite,sourceAnchor.y.isFinite,(-1...2).contains(sourceAnchor.x),(-1...2).contains(sourceAnchor.y),
              let context = CGContext(data:nil,width:image.width,height:image.height,bitsPerComponent:8,bytesPerRow:0,
                space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw MediaPreparedCoreError.invalidOperation("healing brush needs valid source and stroke points")
        }
        context.setFillColor(CGColor(gray:1,alpha:1));context.setStrokeColor(CGColor(gray:1,alpha:1));context.setLineWidth(width)
        context.setLineCap(.round);context.setLineJoin(.round)
        let path = points.map { CGPoint(x:$0.x*Double(image.width),y:(1-$0.y)*Double(image.height)) }
        if path.count == 1 { context.fillEllipse(in:.init(x:path[0].x-width/2,y:path[0].y-width/2,width:width,height:width)) }
        else { context.beginPath();context.addLines(between:path);context.strokePath() }
        guard let coverage = context.makeImage() else { throw MediaPreparedCoreError.invalidOperation("could not draw healing coverage") }
        let offset = ImageFreehandStroke.Point(x:(sourceAnchor.x-points[0].x)*Double(image.width),y:(sourceAnchor.y-points[0].y)*Double(image.height))
        return try solve(image,coverage:coverage,sourceCenter:nil,sourceOffset:offset,iterations:iterations)
    }
    private static func solve(_ image:CGImage,coverage:CGImage,sourceCenter:ImageFreehandStroke.Point?,
                              sourceOffset:ImageFreehandStroke.Point?,iterations:Int) throws -> CGImage {
        guard image.width<=8192,image.height<=8192,image.width*image.height<=8_388_608,
              (1...512).contains(iterations) else { throw MediaPreparedCoreError.limitsExceeded("healing canvas or iteration count") }
        try Task.checkCancellation()
        let raster = try MediaNativeSelection.rgba(image,maxEdge:8192),mask = try MediaNativeSelection.rgba(coverage,maxEdge:8192)
        let w = image.width,h = image.height,pixels = raster.pixels
        var minX = w,minY = h,maxX = -1,maxY = -1,activeCount = 0
        for y in 0..<h { for x in 0..<w where mask.pixels[(y*w+x)*4+3]>0 {
            minX = min(minX,x);maxX = max(maxX,x);minY = min(minY,y);maxY = max(maxY,y);activeCount += 1
        } }
        guard activeCount>0 else { throw MediaPreparedCoreError.invalidOperation("select a target area first") }
        guard maxX-minX<512,maxY-minY<512,activeCount*iterations<=24_000_000 else {
            throw MediaPreparedCoreError.limitsExceeded("healing area is too large; use a smaller area")
        }
        let dx:Int,dy:Int
        if let sourceOffset { dx = Int(sourceOffset.x.rounded());dy = Int(sourceOffset.y.rounded()) }
        else if let sourceCenter { dx = Int((sourceCenter.x*Double(w)-Double(minX+maxX)/2).rounded());dy = Int((sourceCenter.y*Double(h)-Double(minY+maxY)/2).rounded()) }
        else { throw MediaPreparedCoreError.invalidOperation("repair source is missing") }
        guard minX+dx>=1,maxX+dx<w-1,minY+dy>=1,maxY+dy<h-1 else {
            throw MediaPreparedCoreError.invalidOperation("source area is outside the image; choose a point farther from the edge")
        }
        minX = max(0,minX-1);maxX = min(w-1,maxX+1);minY = max(0,minY-1);maxY = min(h-1,maxY+1)
        let rw = maxX-minX+1,rh = maxY-minY+1,n = rw*rh
        func rgb(_ global:Int) -> SIMD3<Double> {
            let alpha = Double(pixels[global*4+3])
            if alpha == 0 { return .zero }
            return .init(Double(pixels[global*4])/alpha,Double(pixels[global*4+1])/alpha,Double(pixels[global*4+2])/alpha)
        }
        var values = [SIMD3<Double>](repeating:.zero,count:n),gradients = values
        var active = [Bool](repeating:false,count:n)
        for y in 0..<rh { for x in 0..<rw {
            let local = y*rw+x,gx = minX+x,gy = minY+y,global = gy*w+gx
            values[local] = rgb(global)
            if mask.pixels[global*4+3] == 0 { continue }
            let source = (gy+dy)*w+gx+dx
            guard pixels[source*4+3]>=250 else { throw MediaPreparedCoreError.invalidOperation("choose an opaque source area for healing") }
            gradients[local] = rgb(source)*4-rgb(source-1)-rgb(source+1)-rgb(source-w)-rgb(source+w)
            active[local] = true
        } }
        for iteration in 0..<iterations {
            try Task.checkCancellation()
            var delta = 0.0
            for y in 0..<rh { for x in 0..<rw where active[y*rw+x] {
                let local = y*rw+x,gx = minX+x,gy = minY+y
                let left = x>0 ? values[local-1] : rgb(gy*w+max(0,gx-1))
                let right = x+1<rw ? values[local+1] : rgb(gy*w+min(w-1,gx+1))
                let top = y>0 ? values[local-rw] : rgb(max(0,gy-1)*w+gx)
                let bottom = y+1<rh ? values[local+rw] : rgb(min(h-1,gy+1)*w+gx)
                let value = (left+right+top+bottom+gradients[local])*0.25,difference = value-values[local]
                delta = max(delta,max(abs(difference.x),max(abs(difference.y),abs(difference.z))))
                values[local] = value
            } }
            if iteration>=12,delta<0.000_01 { break }
        }
        var output = pixels
        for y in 0..<rh { for x in 0..<rw where active[y*rw+x] {
            let global = (minY+y)*w+minX+x,amount = Double(mask.pixels[global*4+3])/255,alpha = Double(pixels[global*4+3])
            let value = values[y*rw+x]
            for channel in 0..<3 {
                let repaired = max(0,min(1,value[channel]))*alpha
                output[global*4+channel] = UInt8(max(0,min(255,(repaired*amount+Double(pixels[global*4+channel])*(1-amount)).rounded())))
            }
        } }
        try Task.checkCancellation()
        guard let provider = CGDataProvider(data:Data(output) as CFData),let result = CGImage(width:w,height:h,bitsPerComponent:8,bitsPerPixel:32,
            bytesPerRow:w*4,space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:.init(rawValue:CGImageAlphaInfo.premultipliedLast.rawValue),
            provider:provider,decode:nil,shouldInterpolate:false,intent:.defaultIntent) else { throw MediaPreparedCoreError.invalidOperation("could not create repaired image") }
        return result
    }
}
