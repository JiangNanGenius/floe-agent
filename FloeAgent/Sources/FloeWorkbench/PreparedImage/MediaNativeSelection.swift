// SPDX-License-Identifier: MPL-2.0
import Foundation
import CoreGraphics
import CoreImage

public enum MediaNativeSelection {
    public enum Refinement: String, Sendable { case refine, expand, smooth }
    static func rgba(_ image:CGImage,maxEdge:Int = 2048,colorSpace:CGColorSpace? = nil) throws -> (pixels:[UInt8],width:Int,height:Int) {
        let scale=min(1,Double(maxEdge)/Double(max(image.width,image.height)))
        let width=max(1,Int(Double(image.width)*scale)),height=max(1,Int(Double(image.height)*scale))
        var bytes=[UInt8](repeating:0,count:width*height*4)
        let success=bytes.withUnsafeMutableBytes{buffer -> Bool in
            guard let context=CGContext(data:buffer.baseAddress,width:width,height:height,bitsPerComponent:8,bytesPerRow:width*4,space:colorSpace ?? CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue) else{return false}
            context.interpolationQuality = .high;context.draw(image,in:.init(x:0,y:0,width:width,height:height));return true
        }
        guard success else{throw MediaPreparedCoreError.invalidOperation("could not read selection pixels")}
        return(bytes,width,height)
    }
    /// RGB/alpha tolerance with an optional connected-component flood. No
    /// bounding-box approximation: disconnected pixels and holes remain exact.
    public static func wand(image:CGImage,point:ImageFreehandStroke.Point,tolerance:Double = 0.1,contiguous:Bool = true) throws -> ImageSelectionBitmap {
        try Task.checkCancellation()
        guard point.x.isFinite,point.y.isFinite,(0...1).contains(point.x),(0...1).contains(point.y),tolerance.isFinite,(0...1).contains(tolerance) else{throw MediaPreparedCoreError.invalidOperation("wand needs a normalized point and tolerance in 0...1")}
        let raster=try rgba(image),w=raster.width,h=raster.height,seed=min(h-1,Int(point.y*Double(h)))*w+min(w-1,Int(point.x*Double(w)))
        let pixels=raster.pixels,base=seed*4,threshold=tolerance*255
        func matches(_ index:Int)->Bool{let i=index*4;return (0..<4).allSatisfy{abs(Double(pixels[i+$0])-Double(pixels[base+$0]))<=threshold}}
        var alpha=[UInt8](repeating:0,count:w*h),seen=[Bool](repeating:false,count:w*h)
        if contiguous {
            var queue=[seed],cursor=0;seen[seed]=true
            while cursor<queue.count {
                if cursor%4096==0{try Task.checkCancellation()}
                let index=queue[cursor];cursor+=1;guard matches(index) else{continue};alpha[index]=255
                let x=index%w,y=index/w
                for next in [x>0 ? index-1:nil,x+1<w ? index+1:nil,y>0 ? index-w:nil,y+1<h ? index+w:nil].compactMap({$0}) where !seen[next]{seen[next]=true;queue.append(next)}
            }
        }else{for i in alpha.indices{if i%4096==0{try Task.checkCancellation()};if matches(i){alpha[i]=255}}}
        return try .init(width:w,height:h,alpha:Data(alpha))
    }
    public static func flattened(_ selection:ImageSelection,width:Int,height:Int) throws -> ImageSelectionBitmap {
        let scale=min(1,2048/Double(max(width,height))),w=max(1,Int(Double(width)*scale)),h=max(1,Int(Double(height)*scale))
        guard let image=ImageSelectionRasterizer.maskImage(for:selection,canvas:.init(width:w,height:h)),let cg=CIContext(options:[.cacheIntermediates:false]).createCGImage(image,from:.init(x:0,y:0,width:w,height:h)) else{throw MediaPreparedCoreError.invalidOperation("select an area first")}
        return try coverage(cg)
    }
    public static func refine(_ selection:ImageSelection,width:Int,height:Int,mode:Refinement,amount:Double) throws -> ImageSelectionBitmap {
        try Task.checkCancellation()
        guard amount.isFinite,abs(amount)<=200 else{throw MediaPreparedCoreError.invalidOperation("selection radius must be within 200 pixels")}
        let original=try flattened(selection,width:width,height:height),image=try original.cgImage.unwrapSelectionImage()
        if amount == 0{return original}
        let extent=CGRect(x:0,y:0,width:original.width,height:original.height),radius=max(0.5,abs(amount)*Double(original.width)/Double(width))
        var result=CIImage(cgImage:image)
        switch mode {
        case .expand:result=result.applyingFilter(amount>=0 ? "CIMorphologyMaximum":"CIMorphologyMinimum",parameters:[kCIInputRadiusKey:radius])
        case .smooth:result=result.applyingFilter("CIMedianFilter").applyingFilter("CIGaussianBlur",parameters:[kCIInputRadiusKey:radius*0.35])
        case .refine:result=result.applyingFilter("CIMorphologyMaximum",parameters:[kCIInputRadiusKey:radius]).applyingFilter("CIMorphologyMinimum",parameters:[kCIInputRadiusKey:radius])
        }
        guard let cg=CIContext(options:[.cacheIntermediates:false]).createCGImage(result.cropped(to:extent),from:extent) else{throw MediaPreparedCoreError.invalidOperation("selection refinement failed")}
        try Task.checkCancellation();return try coverage(cg)
    }
    public static func combine(_ incoming:ImageSelectionBitmap,with selection:ImageSelection?,operation:ImageSelectionOperation) throws -> ImageSelection {
        if operation == .replace || selection == nil{return .init(bitmap:incoming)}
        let old=try flattened(selection!,width:incoming.width,height:incoming.height)
        let a=[UInt8](old.alpha),b=[UInt8](incoming.alpha)
        let values=zip(a,b).map{pair in operation == .add ? max(pair.0,pair.1):UInt8(max(0,Int(pair.0)-Int(pair.1)))}
        return .init(bitmap:try .init(width:incoming.width,height:incoming.height,alpha:Data(values)))
    }
    static func coverage(_ image:CGImage) throws -> ImageSelectionBitmap {
        let raster=try rgba(image)
        return try .init(width:raster.width,height:raster.height,alpha:Data(stride(from:3,to:raster.pixels.count,by:4).map{raster.pixels[$0]}))
    }
}
private extension Optional where Wrapped == CGImage {
    func unwrapSelectionImage() throws -> CGImage {guard let self else{throw MediaPreparedCoreError.invalidOperation("invalid selection image")};return self}
}
