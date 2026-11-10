// SPDX-License-Identifier: MPL-2.0
import Foundation
import CoreImage
import CoreGraphics

public enum MediaNativeColor {
    public static let supportedFilterIDs=["CIPhotoEffectMono","CIPhotoEffectNoir","CIPhotoEffectChrome","CIPhotoEffectFade","CIPhotoEffectInstant","CISepiaTone"]
    public static func apply(_ adjustment: ImageLayerAdjustment, to input: CIImage) throws -> CIImage {
        guard !adjustment.isIdentity else { return input }
        var output = input
        if let temperature = adjustment.temperature, temperature.isFinite {
            let filter = CIFilter(name: "CITemperatureAndTint")!
            filter.setValue(output, forKey: kCIInputImageKey)
            filter.setValue(CIVector(x: CGFloat(max(1000, min(temperature, 40_000))), y: 0), forKey: "inputNeutral")
            filter.setValue(CIVector(x: 6500, y: 0), forKey: "inputTargetNeutral")
            output = filter.outputImage ?? output
        }
        if let hue = adjustment.hueDegrees, hue.isFinite, hue != 0 {
            let filter = CIFilter(name: "CIHueAdjust")!
            filter.setValue(output, forKey: kCIInputImageKey)
            filter.setValue(CGFloat(hue * .pi / 180), forKey: kCIInputAngleKey)
            output = filter.outputImage ?? output
        }
        if let levels = adjustment.levels {
            let black = max(0, min(levels.black, 0.99))
            let white = max(black + 0.01, min(levels.white, 1))
            let span = white - black
            let matrix = CIFilter(name: "CIColorMatrix")!
            matrix.setValue(output, forKey: kCIInputImageKey)
            matrix.setValue(CIVector(x: 1 / span, y: 0, z: 0, w: 0), forKey: "inputRVector")
            matrix.setValue(CIVector(x: 0, y: 1 / span, z: 0, w: 0), forKey: "inputGVector")
            matrix.setValue(CIVector(x: 0, y: 0, z: 1 / span, w: 0), forKey: "inputBVector")
            matrix.setValue(CIVector(x: CGFloat(-black / span), y: CGFloat(-black / span), z: CGFloat(-black / span), w: 0),
                            forKey: "inputBiasVector")
            output = matrix.outputImage ?? output
            if levels.gamma.isFinite, levels.gamma > 0, abs(levels.gamma - 1) > 0.001 {
                let gamma = CIFilter(name: "CIGammaAdjust")!
                gamma.setValue(output, forKey: kCIInputImageKey)
                gamma.setValue(CGFloat(1 / max(0.01, min(levels.gamma, 10))), forKey: "inputPower")
                output = gamma.outputImage ?? output
            }
        }
        if let saturation = adjustment.saturation
            ?? (adjustment.contrast != nil || adjustment.brightness != nil ? 1 : nil) {
            let filter = CIFilter(name: "CIColorControls")!
            filter.setValue(output, forKey: kCIInputImageKey)
            filter.setValue(saturation, forKey: "inputSaturation")
            filter.setValue(adjustment.contrast ?? 1, forKey: "inputContrast")
            filter.setValue(adjustment.brightness ?? 0, forKey: "inputBrightness")
            output = filter.outputImage ?? output
        }
        if let ev = adjustment.exposureEV {
            let filter = CIFilter(name: "CIExposureAdjust")!
            filter.setValue(output, forKey: kCIInputImageKey)
            filter.setValue(ev, forKey: "inputEV")
            output = filter.outputImage ?? output
        }
        if let radius = adjustment.blurRadius, radius > 0 {
            let filter = CIFilter(name: "CIGaussianBlur")!
            filter.setValue(output, forKey: kCIInputImageKey)
            filter.setValue(radius, forKey: "inputRadius")
            output = (filter.outputImage ?? output).cropped(to: input.extent)
        }
        if let radius = adjustment.sharpenRadius, radius > 0 {
            let filter = CIFilter(name: "CISharpenLuminance")!
            filter.setValue(output, forKey: kCIInputImageKey)
            filter.setValue(radius / 100, forKey: "inputSharpness")
            output = filter.outputImage ?? output
        }
        if let block = adjustment.mosaicBlockSize, block > 0 {
            output = try pixellate(output, blockSize: block)
        }
        if let filterID = adjustment.filterID, let applied = try builtInFilter(named: filterID, image: output) {
            output = applied
        }
        return try applyExtended(adjustment,to:output)
    }

    private static func builtInFilter(named name: String, image: CIImage) throws -> CIImage? {
        guard Self.supportedFilterIDs.contains(name), let filter = CIFilter(name: name) else { return nil }
        filter.setValue(image, forKey: kCIInputImageKey)
        return filter.outputImage
    }

    private static func pixellate(_ image: CIImage, blockSize: Int) throws -> CIImage {
        let filter = CIFilter(name: "CIPixellate")!
        filter.setValue(image, forKey: kCIInputImageKey)
        filter.setValue(CGFloat(max(2, min(blockSize, 512))), forKey: "inputScale")
        guard let output = filter.outputImage else { return image }
        return output.cropped(to: image.extent)
    }


    public static func validateExtended(_ a:ImageLayerAdjustment) throws {
        if let curve=a.toneCurve{guard curve.count==5,curve.allSatisfy({$0.x.isFinite && $0.y.isFinite && (0...1).contains($0.x) && (0...1).contains($0.y)}),zip(curve,curve.dropFirst()).allSatisfy({$0.x<$1.x}) else{throw MediaPreparedCoreError.invalidOperation("tone curve needs five ordered normalized control points")}}
        if let balance=a.colorBalance{for range in [balance.shadows,balance.midtones,balance.highlights]{guard [range.red,range.green,range.blue].allSatisfy({$0.isFinite && (-1...1).contains($0)}) else{throw MediaPreparedCoreError.invalidOperation("color balance channels must be -1...1")}}}
        if let lut=a.colorLUT{try lut.validate()}
        if let amount=a.noiseReduction{guard amount.isFinite,(0...1).contains(amount) else{throw MediaPreparedCoreError.invalidOperation("noise reduction must be 0...1")}}
    }
    public static func applyExtended(_ a:ImageLayerAdjustment,to input:CIImage) throws -> CIImage {
        try validateExtended(a);try Task.checkCancellation()
        var result=input
        if let curve=a.toneCurve{
            var parameters:[String:Any]=[:];for (i,p) in curve.enumerated(){parameters["inputPoint\(i)"]=CIVector(x:p.x,y:p.y)}
            result=result.applyingFilter("CIToneCurve",parameters:parameters)
        }
        if let balance=a.colorBalance{
            let lut=try balanceLUT(balance)
            result=result.applyingFilter("CIColorCube",parameters:["inputCubeDimension":lut.dimension,"inputCubeData":lut.rgba])
        }
        if let lut=a.colorLUT{
            let spans=zip(lut.domainMin,lut.domainMax).map{$1-$0}
            result=result.applyingFilter("CIColorMatrix",parameters:["inputRVector":CIVector(x:1/spans[0],y:0,z:0,w:0),"inputGVector":CIVector(x:0,y:1/spans[1],z:0,w:0),"inputBVector":CIVector(x:0,y:0,z:1/spans[2],w:0),"inputBiasVector":CIVector(x:-lut.domainMin[0]/spans[0],y:-lut.domainMin[1]/spans[1],z:-lut.domainMin[2]/spans[2],w:0)])
            result=result.applyingFilter("CIColorCube",parameters:["inputCubeDimension":lut.dimension,"inputCubeData":lut.rgba])
        }
        if let amount=a.noiseReduction,amount>0{result=result.applyingFilter("CINoiseReduction",parameters:["inputNoiseLevel":amount*0.1,"inputSharpness":0.4])}
        if let region=a.effectRegion,let mask=ImageSelectionRasterizer.maskImage(for:region,canvas:input.extent.size){result=result.applyingFilter("CIBlendWithAlphaMask",parameters:[kCIInputBackgroundImageKey:input,kCIInputMaskImageKey:mask])}
        try Task.checkCancellation();return result.cropped(to:input.extent)
    }
    private static func balanceLUT(_ settings:ImageColorBalance) throws -> ImageColorLUT {
        let size=16;var values:[Float]=[];values.reserveCapacity(size*size*size*4)
        for b in 0..<size{for g in 0..<size{for r in 0..<size{
            let rgb=[Double(r),Double(g),Double(b)].map{$0/Double(size-1)},l=rgb[0]*0.2126+rgb[1]*0.7152+rgb[2]*0.0722
            let shadow=(1-l)*(1-l),highlight=l*l,mid=max(0,1-shadow-highlight)
            let shifts=[settings.shadows,settings.midtones,settings.highlights],weights=[shadow,mid,highlight]
            var output=rgb
            for i in 0..<3{let channels=shifts.map{i==0 ? $0.red:i==1 ? $0.green:$0.blue};output[i]+=zip(channels,weights).reduce(0){$0+$1.0*$1.1}*0.5}
            if settings.preserveLuminance{let difference=l-(output[0]*0.2126+output[1]*0.7152+output[2]*0.0722);output=output.map{$0+difference}}
            values += output.map{Float(min(1,max(0,$0)))}+[1]
        }}}
        return try .init(dimension:size,rgba:values.withUnsafeBytes{Data($0)})
    }
}
