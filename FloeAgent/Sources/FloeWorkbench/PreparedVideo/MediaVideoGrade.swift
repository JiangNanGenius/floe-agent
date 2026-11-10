// SPDX-License-Identifier: MPL-2.0
import Foundation
import CoreImage

private struct GradeField: CodingKey {
    var stringValue: String
    var intValue: Int? { nil }
    init?(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { return nil }
}
private func checkGradeFields(_ decoder: any Decoder, allowed: Set<String>) throws {
    let c = try decoder.container(keyedBy: GradeField.self)
    if let unknown = c.allKeys.first(where: { !allowed.contains($0.stringValue) }) {
        throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath + [unknown], debugDescription: "Unknown video color field"))
    }
}

/// HSL qualifier and correction. Hue distance is circular, so a red qualifier
/// includes both sides of 0 degrees. Saturation/lightness qualify independently.
public struct MediaHSLSecondary: Sendable, Codable, Hashable {
    public var hueCenter: Double
    public var hueWidth: Double
    public var hueFeather: Double
    public var saturationMin: Double
    public var saturationMax: Double
    public var lightnessMin: Double
    public var lightnessMax: Double
    public var rangeFeather: Double
    public var hueShift: Double
    public var saturationScale: Double
    public var lightnessShift: Double
    public var mix: Double
    public init(hueCenter: Double = 0, hueWidth: Double = 25, hueFeather: Double = 15,
                saturationMin: Double = 0.15, saturationMax: Double = 1,
                lightnessMin: Double = 0, lightnessMax: Double = 1, rangeFeather: Double = 0.05,
                hueShift: Double = 0, saturationScale: Double = 1, lightnessShift: Double = 0, mix: Double = 1) {
        self.hueCenter = hueCenter; self.hueWidth = hueWidth; self.hueFeather = hueFeather
        self.saturationMin = saturationMin; self.saturationMax = saturationMax
        self.lightnessMin = lightnessMin; self.lightnessMax = lightnessMax; self.rangeFeather = rangeFeather
        self.hueShift = hueShift; self.saturationScale = saturationScale; self.lightnessShift = lightnessShift; self.mix = mix
    }
    private enum CodingKeys: String, CodingKey, CaseIterable {
        case hueCenter,hueWidth,hueFeather,saturationMin,saturationMax,lightnessMin,lightnessMax,rangeFeather,hueShift,saturationScale,lightnessShift,mix
    }
    public init(from decoder: any Decoder) throws {
        try checkGradeFields(decoder, allowed: Set(CodingKeys.allCases.map(\.rawValue)))
        self.init(); let c = try decoder.container(keyedBy: CodingKeys.self)
        hueCenter = try c.decodeIfPresent(Double.self, forKey: .hueCenter) ?? hueCenter
        hueWidth = try c.decodeIfPresent(Double.self, forKey: .hueWidth) ?? hueWidth
        hueFeather = try c.decodeIfPresent(Double.self, forKey: .hueFeather) ?? hueFeather
        saturationMin = try c.decodeIfPresent(Double.self, forKey: .saturationMin) ?? saturationMin
        saturationMax = try c.decodeIfPresent(Double.self, forKey: .saturationMax) ?? saturationMax
        lightnessMin = try c.decodeIfPresent(Double.self, forKey: .lightnessMin) ?? lightnessMin
        lightnessMax = try c.decodeIfPresent(Double.self, forKey: .lightnessMax) ?? lightnessMax
        rangeFeather = try c.decodeIfPresent(Double.self, forKey: .rangeFeather) ?? rangeFeather
        hueShift = try c.decodeIfPresent(Double.self, forKey: .hueShift) ?? hueShift
        saturationScale = try c.decodeIfPresent(Double.self, forKey: .saturationScale) ?? saturationScale
        lightnessShift = try c.decodeIfPresent(Double.self, forKey: .lightnessShift) ?? lightnessShift
        mix = try c.decodeIfPresent(Double.self, forKey: .mix) ?? mix
    }
    public func validate() throws {
        let values = [hueCenter,hueWidth,hueFeather,saturationMin,saturationMax,lightnessMin,lightnessMax,rangeFeather,hueShift,saturationScale,lightnessShift,mix]
        guard values.allSatisfy(\.isFinite), (0...360).contains(hueCenter), (0...180).contains(hueWidth),
              (0...180).contains(hueFeather), (0...1).contains(saturationMin), (saturationMin...1).contains(saturationMax),
              (0...1).contains(lightnessMin), (lightnessMin...1).contains(lightnessMax), (0...1).contains(rangeFeather),
              (-180...180).contains(hueShift), (0...2).contains(saturationScale), (-1...1).contains(lightnessShift), (0...1).contains(mix) else {
            throw MediaPreparedCoreError.invalidOperation("HSL qualifier or correction is outside its finite range")
        }
    }
    public func cubeData() throws -> Data {
        try validate(); let size = 32
        var values = [Float](); values.reserveCapacity(size*size*size*4)
        for b in 0..<size {
            try Task.checkCancellation()
            for g in 0..<size { for r in 0..<size {
                let rgb = [Double(r)/31,Double(g)/31,Double(b)/31], hsl = Self.hsl(rgb)
                let delta = abs(hsl.0-hueCenter), distance = min(delta,360-delta)
                let hueWeight = hueWidth == 180 ? 1 : Self.falloff(distance, edge: hueWidth, feather: hueFeather)
                let rangeWeight = Self.rangeWeight(hsl.1, lower: saturationMin, upper: saturationMax, feather: rangeFeather)
                    * Self.rangeWeight(hsl.2, lower: lightnessMin, upper: lightnessMax, feather: rangeFeather)
                let weight = hueWeight * rangeWeight * mix
                let corrected = Self.rgb(hue: hsl.0+hueShift, saturation: min(1,max(0,hsl.1*saturationScale)), lightness: min(1,max(0,hsl.2+lightnessShift)))
                values += zip(rgb,corrected).map { Float($0 + ($1-$0)*weight) } + [1]
            } }
        }
        return values.withUnsafeBytes { Data($0) }
    }
    private static func smooth(_ t: Double) -> Double { let v = min(1,max(0,t)); return v*v*(3-2*v) }
    private static func falloff(_ x: Double, edge: Double, feather: Double) -> Double {
        x <= edge ? 1 : feather > 0 ? 1-smooth((x-edge)/feather) : 0
    }
    private static func rangeWeight(_ value: Double, lower: Double, upper: Double, feather: Double) -> Double {
        if value < lower { return feather > 0 ? 1-smooth((lower-value)/feather) : 0 }
        if value > upper { return feather > 0 ? 1-smooth((value-upper)/feather) : 0 }
        return 1
    }
    private static func hsl(_ rgb: [Double]) -> (Double,Double,Double) {
        let r = rgb[0],g = rgb[1],b = rgb[2],hi = max(r,max(g,b)),lo = min(r,min(g,b)),d = hi-lo,l = (hi+lo)/2
        guard d > 0.000_001 else { return (0,0,l) }
        let s = d / max(0.000_001,1-abs(2*l-1))
        var h = hi == r ? (g-b)/d : hi == g ? (b-r)/d+2 : (r-g)/d+4
        h = (h*60).truncatingRemainder(dividingBy:360);if h<0 { h += 360 }
        return (h,s,l)
    }
    private static func rgb(hue: Double,saturation: Double,lightness: Double) -> [Double] {
        var h = hue.truncatingRemainder(dividingBy:360);if h<0 { h += 360 }; h /= 60
        let c = (1-abs(2*lightness-1))*saturation,x = c*(1-abs(h.truncatingRemainder(dividingBy:2)-1)),m = lightness-c/2
        let channels: [Double]
        switch h { case ..<1: channels=[c,x,0];case ..<2: channels=[x,c,0];case ..<3: channels=[0,c,x];case ..<4: channels=[0,x,c];case ..<5: channels=[x,0,c];default: channels=[c,0,x] }
        return channels.map { $0+m }
    }
}

/// Persistent, non-destructive clip grading. Each inspector updates one field;
/// other grades remain intact and the same value is frozen into export plans.
public struct MediaVideoGrade: Sendable, Codable, Hashable {
    public var toneCurve: [ImageFreehandStroke.Point]?
    public var colorBalance: ImageColorBalance?
    public var secondary: MediaHSLSecondary?
    public var colorLUT: ImageColorLUT?
    public var filterID: String?
    public var lutName: String?
    public var colorMatch: MediaVideoColorMatch?
    public init(toneCurve: [ImageFreehandStroke.Point]? = nil,colorBalance: ImageColorBalance? = nil,
                secondary: MediaHSLSecondary? = nil,colorLUT: ImageColorLUT? = nil,filterID: String? = nil,lutName: String? = nil,colorMatch: MediaVideoColorMatch? = nil) {
        self.toneCurve=toneCurve;self.colorBalance=colorBalance;self.secondary=secondary;self.colorLUT=colorLUT;self.filterID=filterID;self.lutName=lutName;self.colorMatch=colorMatch
    }
    private enum CodingKeys: String,CodingKey,CaseIterable { case toneCurve,colorBalance,secondary,colorLUT,filterID,lutName,colorMatch }
    public init(from decoder: any Decoder) throws {
        try checkGradeFields(decoder,allowed:Set(CodingKeys.allCases.map(\.rawValue)))
        let c = try decoder.container(keyedBy:CodingKeys.self)
        toneCurve = try c.decodeIfPresent([ImageFreehandStroke.Point].self,forKey:.toneCurve)
        colorBalance = try c.decodeIfPresent(ImageColorBalance.self,forKey:.colorBalance)
        secondary = try c.decodeIfPresent(MediaHSLSecondary.self,forKey:.secondary)
        colorLUT = try c.decodeIfPresent(ImageColorLUT.self,forKey:.colorLUT)
        filterID = try c.decodeIfPresent(String.self,forKey:.filterID);lutName = try c.decodeIfPresent(String.self,forKey:.lutName)
        colorMatch = try c.decodeIfPresent(MediaVideoColorMatch.self,forKey:.colorMatch)
    }
    public var isEmpty: Bool { toneCurve == nil && colorBalance == nil && secondary == nil && colorLUT == nil && filterID == nil && colorMatch == nil }
    public var imageAdjustment: ImageLayerAdjustment {
        var a = ImageLayerAdjustment();a.toneCurve=toneCurve;a.colorBalance=colorBalance;a.colorLUT=colorLUT;a.filterID=filterID;return a
    }
    public func validate() throws {
        try MediaNativeColor.validateExtended(imageAdjustment);try secondary?.validate();try colorMatch?.validate()
        guard filterID.map(MediaNativeColor.supportedFilterIDs.contains) ?? true,
              !(filterID != nil && colorLUT != nil),lutName.map({$0.utf8.count<=256}) ?? true else {
            throw MediaPreparedCoreError.invalidOperation("video LUT needs one supported filter or one bounded 3D LUT")
        }
    }
    public func apply(to image: CIImage,secondaryCube: Data? = nil,matchCube: Data? = nil) throws -> CIImage {
        var result = try MediaNativeColor.apply(imageAdjustment,to: image)
        if let secondary {
            let cube = try secondaryCube ?? secondary.cubeData()
            result = result.applyingFilter("CIColorCube",parameters: ["inputCubeDimension":32,"inputCubeData":cube])
        }
        if let colorMatch { result = try colorMatch.apply(to: result,cubeData: matchCube) }
        return result
    }

}
