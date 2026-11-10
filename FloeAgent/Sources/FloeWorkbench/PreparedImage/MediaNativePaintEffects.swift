// SPDX-License-Identifier: MPL-2.0
import Foundation
import CoreGraphics
import CoreImage

public enum MediaNativePaintEffects {
    public enum StrokeFilter: String,Sendable { case blur,sharpen }
    private static func render(_ output:CIImage,extent:CGRect) throws -> CGImage {
        try Task.checkCancellation()
        guard let image = CIContext(options:[.cacheIntermediates:false]).createCGImage(output,from:extent) else {
            throw MediaPreparedCoreError.invalidOperation("could not render paint effect")
        }
        return image
    }
    private static func extent(_ image:CGImage) throws -> CGRect {
        guard image.width>0,image.height>0,image.width<=8192,image.height<=8192,image.width*image.height<=33_177_600 else {
            throw MediaPreparedCoreError.limitsExceeded("paint canvas")
        }
        return .init(x:0,y:0,width:image.width,height:image.height)
    }
    private static func color(_ hex:String) throws -> CIColor {
        let c = try PreparedVideoColor(hex:hex)
        return .init(red:c.red,green:c.green,blue:c.blue,alpha:c.alpha)
    }
    public static func gradient(_ image:CGImage,from start:ImageFreehandStroke.Point,to end:ImageFreehandStroke.Point,
                                firstColor:String,lastColor:String,opacity:Double = 1,radial:Bool = false) throws -> CGImage {
        let bounds = try extent(image)
        guard [start.x,start.y,end.x,end.y,opacity].allSatisfy(\.isFinite),(0...1).contains(opacity),
              [start.x,start.y,end.x,end.y].allSatisfy({(0...1).contains($0)}),hypot(end.x-start.x,end.y-start.y)>0.000_01 else {
            throw MediaPreparedCoreError.invalidOperation("gradient needs two distinct normalized points")
        }
        let a = CIVector(x:start.x*bounds.width,y:(1-start.y)*bounds.height)
        let b = CIVector(x:end.x*bounds.width,y:(1-end.y)*bounds.height)
        var c1 = try color(firstColor),c2 = try color(lastColor)
        c1 = .init(red:c1.red,green:c1.green,blue:c1.blue,alpha:c1.alpha*opacity)
        c2 = .init(red:c2.red,green:c2.green,blue:c2.blue,alpha:c2.alpha*opacity)
        let filter: CIFilter?
        if radial {
            filter = CIFilter(name:"CIRadialGradient",parameters:["inputCenter":a,"inputRadius0":0,"inputRadius1":hypot(b.x-a.x,b.y-a.y),"inputColor0":c1,"inputColor1":c2])
        } else {
            filter = CIFilter(name:"CILinearGradient",parameters:["inputPoint0":a,"inputPoint1":b,"inputColor0":c1,"inputColor1":c2])
        }
        guard let gradient = filter?.outputImage?.cropped(to:bounds) else { throw MediaPreparedCoreError.invalidOperation("gradient filter is unavailable") }
        return try render(gradient.composited(over:CIImage(cgImage:image)),extent:bounds)
    }
    public static func filteredStroke(_ image:CGImage,points:[ImageFreehandStroke.Point],width:Double,
                                      amount:Double,opacity:Double = 1,filter:StrokeFilter) throws -> CGImage {
        let bounds = try extent(image)
        guard (1...10_000).contains(points.count),points.allSatisfy({$0.x.isFinite && $0.y.isFinite && (0...1).contains($0.x) && (0...1).contains($0.y)}),
              width.isFinite,(0.1...200).contains(width),amount.isFinite,(0...200).contains(amount),opacity.isFinite,(0...1).contains(opacity) else {
            throw MediaPreparedCoreError.invalidOperation("brush settings or points are outside their limit")
        }
        guard let context = CGContext(data:nil,width:image.width,height:image.height,bitsPerComponent:8,bytesPerRow:0,
            space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw MediaPreparedCoreError.invalidOperation("could not allocate brush coverage")
        }
        context.setFillColor(CGColor(gray:1,alpha:opacity));context.setStrokeColor(CGColor(gray:1,alpha:opacity))
        context.setLineWidth(width);context.setLineCap(.round);context.setLineJoin(.round)
        let locations = points.map { CGPoint(x:$0.x*bounds.width,y:(1-$0.y)*bounds.height) }
        if locations.count == 1 { context.fillEllipse(in:.init(x:locations[0].x-width/2,y:locations[0].y-width/2,width:width,height:width)) }
        else { context.beginPath();context.addLines(between:locations);context.strokePath() }
        guard let coverage = context.makeImage() else { throw MediaPreparedCoreError.invalidOperation("could not create brush coverage") }
        let source = CIImage(cgImage:image),processed: CIImage
        switch filter {
        case .blur: processed = source.clampedToExtent().applyingFilter("CIGaussianBlur",parameters:[kCIInputRadiusKey:amount]).cropped(to:bounds)
        case .sharpen: processed = source.clampedToExtent().applyingFilter("CISharpenLuminance",parameters:[kCIInputSharpnessKey:amount/50]).cropped(to:bounds)
        }
        return try render(processed.applyingFilter("CIBlendWithAlphaMask",parameters:[kCIInputBackgroundImageKey:source,kCIInputMaskImageKey:CIImage(cgImage:coverage)]),extent:bounds)
    }
    public static func layerEffects(_ image:CGImage,outlineWidth:Double,outlineColor:String,
                                    shadowRadius:Double,shadowColor:String = "#00000080",
                                    shadowOffset:ImageFreehandStroke.Point = .init(x:8,y:8),shadowEnabled:Bool = true) throws -> CGImage {
        let bounds = try extent(image)
        guard [outlineWidth,shadowRadius,shadowOffset.x,shadowOffset.y].allSatisfy(\.isFinite),
              (0...200).contains(outlineWidth),(0...200).contains(shadowRadius),
              abs(shadowOffset.x)<=512,abs(shadowOffset.y)<=512 else {
            throw MediaPreparedCoreError.invalidOperation("layer effect is outside its pixel limit")
        }
        let source = CIImage(cgImage:image),clear = CIImage(color:.clear).cropped(to:bounds)
        let alpha = source.applyingFilter("CIColorMatrix",parameters:["inputRVector":CIVector(x:0,y:0,z:0,w:1),
            "inputGVector":CIVector(x:0,y:0,z:0,w:1),"inputBVector":CIVector(x:0,y:0,z:0,w:1),"inputAVector":CIVector(x:0,y:0,z:0,w:1)])
        var below = clear
        if shadowEnabled {
            let mask = alpha.applyingFilter("CIGaussianBlur",parameters:[kCIInputRadiusKey:shadowRadius])
                .transformed(by:.init(translationX:shadowOffset.x,y:-shadowOffset.y)).cropped(to:bounds)
            below = CIImage(color:try color(shadowColor)).cropped(to:bounds).applyingFilter("CIBlendWithAlphaMask",parameters:[kCIInputBackgroundImageKey:clear,kCIInputMaskImageKey:mask])
        }
        if outlineWidth>0 {
            let expanded = alpha.applyingFilter("CIMorphologyMaximum",parameters:[kCIInputRadiusKey:outlineWidth]).cropped(to:bounds)
            let outside = clear.applyingFilter("CIBlendWithAlphaMask",parameters:[kCIInputBackgroundImageKey:expanded,kCIInputMaskImageKey:alpha])
            let outline = CIImage(color:try color(outlineColor)).cropped(to:bounds).applyingFilter("CIBlendWithAlphaMask",parameters:[kCIInputBackgroundImageKey:clear,kCIInputMaskImageKey:outside])
            below = outline.composited(over:below)
        }
        return try render(source.composited(over:below),extent:bounds)
    }
}
