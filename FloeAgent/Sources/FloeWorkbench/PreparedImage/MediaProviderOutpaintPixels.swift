// SPDX-License-Identifier: MPL-2.0
import Foundation
import CoreGraphics
import CoreImage

/// Integer placement keeps every original pixel on its existing sampling grid,
/// including transparent original pixels. This is a canvas expansion, never a
/// subject resize or a flattened replacement of the original layer graph.
public struct MediaOutpaintLayout: Sendable,Hashable {
    public let sourceWidth:Int
    public let sourceHeight:Int
    public let width:Int
    public let height:Int
    public let originX:Int
    public let originY:Int
    public init(sourceWidth:Int,sourceHeight:Int,width:Int,height:Int,anchor:ImageFreehandStroke.Point) throws {
        guard sourceWidth>0,sourceHeight>0,width>=sourceWidth,height>=sourceHeight,
              width>sourceWidth || height>sourceHeight,width<=8192,height<=8192,
              width*height<=8_388_608,anchor.x.isFinite,anchor.y.isFinite,
              (0...1).contains(anchor.x),(0...1).contains(anchor.y) else {
            throw MediaPreparedCoreError.invalidOperation("Expand at least one edge without shrinking the original, up to 8 megapixels")
        }
        self.sourceWidth=sourceWidth;self.sourceHeight=sourceHeight;self.width=width;self.height=height
        originX=Int((Double(width-sourceWidth)*anchor.x).rounded())
        originY=Int((Double(height-sourceHeight)*anchor.y).rounded())
    }
    /// Reuses the canonical canvas transaction with the exact integer offset.
    public var effectiveAnchor:ImageFreehandStroke.Point {
        .init(x:width==sourceWidth ? 0:Double(originX)/Double(width-sourceWidth),
              y:height==sourceHeight ? 0:Double(originY)/Double(height-sourceHeight))
    }
    public var originalRect:CGRect { .init(x:originX,y:height-originY-sourceHeight,width:sourceWidth,height:sourceHeight) }
}

/// Bounded local pixels only. Network authority, source revalidation, staged
/// assets and the single undoable canvas/layer transaction remain App-owned.
public enum MediaProviderOutpaintPixels {
    public static func prepare(_ source:CGImage,layout:MediaOutpaintLayout,maxEdge:Int=1536) throws -> MediaProviderImageInput {
        guard source.width==layout.sourceWidth,source.height==layout.sourceHeight,(256...2048).contains(maxEdge) else {
            throw MediaPreparedCoreError.invalidOperation("Image source or provider reference dimensions changed")
        }
        try Task.checkCancellation()
        let scale=min(1,Double(maxEdge)/Double(max(layout.width,layout.height)))
        let width=max(1,Int(Double(layout.width)*scale)),height=max(1,Int(Double(layout.height)*scale))
        let canvas=CGRect(x:0,y:0,width:layout.width,height:layout.height)
        let clear=CIImage(color:.clear).cropped(to:canvas)
        let placed=CIImage(cgImage:source).transformed(by:.init(translationX:layout.originalRect.minX,y:layout.originalRect.minY)).composited(over:clear)
        // Protect the whole original rectangle, not its visible alpha. A hole
        // in an original layer must not turn into permission to replace it.
        let protected=CIImage(color:.white).cropped(to:layout.originalRect).composited(over:clear)
        let transform=CGAffineTransform(scaleX:Double(width)/Double(layout.width),y:Double(height)/Double(layout.height))
        let extent=CGRect(x:0,y:0,width:width,height:height),context=context()
        guard let reference=context.createCGImage(placed.transformed(by:transform),from:extent,format:.RGBA8,colorSpace:space()),
              let mask=context.createCGImage(protected.transformed(by:transform),from:extent,format:.RGBA8,colorSpace:space()),
              let png=WorkbenchPNG.encode(reference),let maskPNG=WorkbenchPNG.encode(mask),
              png.count<=32*1024*1024,maskPNG.count<=32*1024*1024 else {
            throw MediaPreparedCoreError.limitsExceeded("Could not prepare the bounded expansion reference")
        }
        try Task.checkCancellation()
        return .init(sourcePNG:png,maskPNG:maskPNG,width:width,height:height)
    }
    /// Returns only newly generated margins. The original rectangle is fully
    /// transparent in this new bottom layer, preserving original editable
    /// content, alpha, masks, text, groups and every source asset above it.
    public static func margins(_ generated:Data,layout:MediaOutpaintLayout) throws -> CGImage {
        let decoded=try MediaProviderEditPixels.decode(generated),extent=CGRect(x:0,y:0,width:layout.width,height:layout.height)
        // A provider resolution may quantize one output pixel. Accept only
        // that rounding error; never stretch a square result into a landscape
        // expansion or silently crop a materially different composition.
        let cross=abs(Double(decoded.width)*Double(layout.height)-Double(decoded.height)*Double(layout.width))
        guard cross<=Double(max(layout.width,layout.height)) else {
            throw MediaPreparedCoreError.invalidOperation("The image service returned a different canvas shape. Choose a model supporting this aspect ratio")
        }
        let scale=max(Double(layout.width)/Double(decoded.width),Double(layout.height)/Double(decoded.height))
        let dx=(Double(layout.width)-Double(decoded.width)*scale)/2,dy=(Double(layout.height)-Double(decoded.height)*scale)/2
        let resized=CIImage(cgImage:decoded).transformed(by:.init(scaleX:scale,y:scale)).transformed(by:.init(translationX:dx,y:dy))
        guard let image=context().createCGImage(resized,from:extent,format:.RGBA8,colorSpace:space()) else {
            throw MediaPreparedCoreError.invalidOperation("Could not prepare generated margins")
        }
        var pixels=try MediaNativeSelection.rgba(image,maxEdge:max(layout.width,layout.height),colorSpace:space()).pixels
        for y in layout.originY..<layout.originY+layout.sourceHeight {
            if y%32==0 { try Task.checkCancellation() }
            let start=(y*layout.width+layout.originX)*4,end=start+layout.sourceWidth*4
            pixels.replaceSubrange(start..<end,with:repeatElement(UInt8(0),count:end-start))
        }
        try Task.checkCancellation()
        guard let provider=CGDataProvider(data:Data(pixels) as CFData),let output=CGImage(width:layout.width,height:layout.height,bitsPerComponent:8,bitsPerPixel:32,bytesPerRow:layout.width*4,space:space(),bitmapInfo:.init(rawValue:CGImageAlphaInfo.premultipliedLast.rawValue),provider:provider,decode:nil,shouldInterpolate:false,intent:.defaultIntent) else {
            throw MediaPreparedCoreError.invalidOperation("Could not preserve the original expansion boundary")
        }
        return output
    }
    private static func space() -> CGColorSpace { CGColorSpace(name:CGColorSpace.sRGB)! }
    private static func context() -> CIContext { .init(options:[.workingColorSpace:space(),.outputColorSpace:space(),.cacheIntermediates:false]) }
}
