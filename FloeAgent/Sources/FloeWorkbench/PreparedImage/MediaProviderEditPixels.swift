// SPDX-License-Identifier: MPL-2.0
import Foundation
import CoreGraphics
import CoreImage
import ImageIO

public struct MediaProviderImageInput: Sendable {
    public let sourcePNG: Data
    /// Transparent=editable; opaque=protected, including partially soft edges.
    public let maskPNG: Data
    public let width: Int
    public let height: Int
}
/// Pure bounded pixels for the App's already-authorized provider bridge. This
/// type performs no network, credential discovery, persistence or UI action.
public enum MediaProviderEditPixels {
    public static func prepareInpaint(_ source: CGImage,selection: ImageSelection,maxEdge: Int = 1536) throws -> MediaProviderImageInput {
        try check(source);try Task.checkCancellation()
        guard (256...2048).contains(maxEdge) else { throw MediaPreparedCoreError.invalidOperation("invalid provider reference size") }
        let raster = try MediaNativeSelection.rgba(source,maxEdge:maxEdge,colorSpace:CGColorSpace(name:CGColorSpace.sRGB))
        let selected = try MediaNativeSelection.flattened(selection,width:raster.width,height:raster.height)
        let alpha = [UInt8](selected.alpha);guard alpha.contains(where:{$0>0}) else { throw MediaPreparedCoreError.invalidOperation("select an editable area first") }
        var mask = [UInt8](repeating:0,count:raster.width*raster.height*4)
        for index in alpha.indices {
            if index%4096 == 0 { try Task.checkCancellation() }
            let protected = 255-alpha[index]
            for channel in 0..<4 { mask[index*4+channel] = protected }
        }
        let image = try cgImage(raster.pixels,width:raster.width,height:raster.height),maskImage = try cgImage(mask,width:raster.width,height:raster.height)
        guard let png = WorkbenchPNG.encode(image),let maskPNG = WorkbenchPNG.encode(maskImage) else { throw MediaPreparedCoreError.invalidOperation("could not prepare image editing reference") }
        return .init(sourcePNG:png,maskPNG:maskPNG,width:raster.width,height:raster.height)
    }
    public static func compositeInpaint(_ generated: Data,over original: CGImage,selection: ImageSelection) throws -> CGImage {
        try check(original);let decoded = try decode(generated)
        let extent = CGRect(x:0,y:0,width:original.width,height:original.height)
        let cross=abs(Double(decoded.width)*Double(original.height)-Double(decoded.height)*Double(original.width))
        guard cross<=Double(max(original.width,original.height)) else {
            throw MediaPreparedCoreError.invalidOperation("The image service returned a different canvas shape. Choose a model supporting this aspect ratio")
        }
        // Only a one-pixel provider resolution rounding error may be cropped;
        // never stretch a differently shaped result into the selected area.
        let scale=max(Double(original.width)/Double(decoded.width),Double(original.height)/Double(decoded.height))
        let dx=(Double(original.width)-Double(decoded.width)*scale)/2,dy=(Double(original.height)-Double(decoded.height)*scale)/2
        let resized=CIImage(cgImage:decoded).transformed(by:.init(scaleX:scale,y:scale)).transformed(by:.init(translationX:dx,y:dy))
        guard let mask = ImageSelectionRasterizer.maskImage(for:selection,canvas:extent.size) else { throw MediaPreparedCoreError.invalidOperation("select an editable area first") }
        let blended = resized.applyingFilter("CIBlendWithAlphaMask",parameters:[kCIInputBackgroundImageKey:CIImage(cgImage:original),kCIInputMaskImageKey:mask])
        try Task.checkCancellation()
        guard let result = context().createCGImage(blended,from:extent,format:.RGBA8,colorSpace:CGColorSpace(name:CGColorSpace.sRGB)) else { throw MediaPreparedCoreError.invalidOperation("could not composite edited pixels") }
        return result
    }
    public static func pixelDigestInput(_ source: CGImage) throws -> Data {
        try check(source);let raster = try MediaNativeSelection.rgba(source,maxEdge:max(source.width,source.height),colorSpace:CGColorSpace(name:CGColorSpace.sRGB))
        var data = Data("\(source.width)x\(source.height):".utf8);data.append(contentsOf:raster.pixels);return data
    }
    public static func decode(_ data: Data) throws -> CGImage {
        guard !data.isEmpty,data.count<=32*1024*1024,
              let source = CGImageSourceCreateWithData(data as CFData,nil),CGImageSourceGetCount(source)==1,
              let properties = CGImageSourceCopyPropertiesAtIndex(source,0,nil) as? [CFString:Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,let height = properties[kCGImagePropertyPixelHeight] as? Int,
              width>0,height>0,width<=8192,height<=8192,width*height<=16_777_216,
              let image = CGImageSourceCreateImageAtIndex(source,0,[kCGImageSourceShouldCacheImmediately:true] as CFDictionary) else {
            throw MediaPreparedCoreError.invalidOperation("provider returned an invalid or oversized image")
        }
        try Task.checkCancellation()
        if let orientation = properties[kCGImagePropertyOrientation] as? Int,orientation != 1 {
            guard (1...8).contains(orientation) else { throw MediaPreparedCoreError.invalidOperation("provider returned invalid image orientation") }
            let oriented = CIImage(cgImage:image).oriented(forExifOrientation:Int32(orientation))
            guard let normalized = context().createCGImage(oriented,from:oriented.extent,format:.RGBA8,colorSpace:CGColorSpace(name:CGColorSpace.sRGB)) else { throw MediaPreparedCoreError.invalidOperation("could not orient provider image") }
            return normalized
        }
        return image
    }
    private static func check(_ source: CGImage) throws {
        guard source.width>0,source.height>0,source.width<=8192,source.height<=8192,source.width*source.height<=8_388_608 else {
            throw MediaPreparedCoreError.limitsExceeded("image editing supports up to 8 megapixels")
        }
    }
    private static func context() -> CIContext {
        CIContext(options:[.workingColorSpace:CGColorSpace(name:CGColorSpace.sRGB)!, .outputColorSpace:CGColorSpace(name:CGColorSpace.sRGB)!, .cacheIntermediates:false])
    }
    private static func cgImage(_ bytes:[UInt8],width:Int,height:Int) throws -> CGImage {
        guard let provider = CGDataProvider(data:Data(bytes) as CFData),let image = CGImage(width:width,height:height,bitsPerComponent:8,bitsPerPixel:32,bytesPerRow:width*4,space:CGColorSpace(name:CGColorSpace.sRGB)!,bitmapInfo:.init(rawValue:CGImageAlphaInfo.premultipliedLast.rawValue),provider:provider,decode:nil,shouldInterpolate:false,intent:.defaultIntent) else { throw MediaPreparedCoreError.invalidOperation("could not prepare pixels") }
        return image
    }
}
