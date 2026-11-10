// SPDX-License-Identifier: MPL-2.0
import Foundation
import CoreImage

public enum MediaVideoBlendMode: String,Sendable,Codable,Hashable,CaseIterable {
    case normal,multiply,screen,overlay,darken,lighten,add,difference
    public var filterName: String? {
        switch self {
        case .normal: nil
        case .multiply: "CIMultiplyBlendMode"
        case .screen: "CIScreenBlendMode"
        case .overlay: "CIOverlayBlendMode"
        case .darken: "CIDarkenBlendMode"
        case .lighten: "CILightenBlendMode"
        case .add: "CIAdditionCompositing"
        case .difference: "CIDifferenceBlendMode"
        }
    }
}

public struct MediaVideoChromaKey: Sendable,Codable,Hashable {
    public var colorHex: String
    public var tolerance: Double
    public var softness: Double
    public var spillSuppression: Double
    public init(colorHex:String = "#00FF00",tolerance:Double = 0.18,softness:Double = 0.12,spillSuppression:Double = 0.5) {
        self.colorHex = colorHex;self.tolerance = tolerance;self.softness = softness;self.spillSuppression = spillSuppression
    }
    private enum CodingKeys:String,CodingKey { case colorHex,tolerance,softness,spillSuppression }
    private struct Field:CodingKey {
        var stringValue:String
        var intValue:Int? { nil }
        init?(stringValue:String) { self.stringValue = stringValue }
        init?(intValue:Int) { return nil }
    }
    public init(from decoder:any Decoder) throws {
        let fields = try decoder.container(keyedBy:Field.self)
        let allowed:Set<String> = ["colorHex","tolerance","softness","spillSuppression"]
        if let unknown = fields.allKeys.first(where:{ !allowed.contains($0.stringValue) }) {
            throw DecodingError.dataCorrupted(.init(codingPath:decoder.codingPath+[unknown],debugDescription:"Unknown chroma-key field"))
        }
        let values = try decoder.container(keyedBy:CodingKeys.self)
        colorHex = try values.decodeIfPresent(String.self,forKey:.colorHex) ?? "#00FF00"
        tolerance = try values.decodeIfPresent(Double.self,forKey:.tolerance) ?? 0.18
        softness = try values.decodeIfPresent(Double.self,forKey:.softness) ?? 0.12
        spillSuppression = try values.decodeIfPresent(Double.self,forKey:.spillSuppression) ?? 0.5
    }
    public func validate() throws {
        _ = try PreparedVideoColor(hex:colorHex)
        guard [tolerance,softness,spillSuppression].allSatisfy({$0.isFinite && (0...1).contains($0)}) else {
            throw MediaPreparedCoreError.invalidOperation("chroma-key controls must lie in 0...1")
        }
    }
    /// Premultiplied RGBA lookup table in the renderer's sRGB working space.
    /// Keying is based on chroma distance; RGB spill is suppressed at edges.
    public func cubeData() throws -> Data {
        try validate();let key = try PreparedVideoColor(hex:colorHex)
        func chroma(_ r:Double,_ g:Double,_ b:Double) -> (Double,Double) {
            let y = 0.2126*r+0.7152*g+0.0722*b
            return ((b-y)/1.8556,(r-y)/1.5748)
        }
        let target = chroma(key.red,key.green,key.blue),dimension = 32
        let keyRGB = [key.red,key.green,key.blue],dominant = keyRGB.indices.max { keyRGB[$0]<keyRGB[$1] } ?? 1
        var values = [Float]();values.reserveCapacity(dimension*dimension*dimension*4)
        for b in 0..<dimension {
            try Task.checkCancellation()
            for g in 0..<dimension { for r in 0..<dimension {
                var rgb = [Double(r)/31,Double(g)/31,Double(b)/31]
                let c = chroma(rgb[0],rgb[1],rgb[2]),distance = hypot(c.0-target.0,c.1-target.1)
                let t = max(0,min(1,(distance-tolerance)/max(0.000_01,softness))),alpha = t*t*(3-2*t)
                let other = rgb.indices.filter {$0 != dominant}.map {rgb[$0]}.max() ?? 0
                rgb[dominant] -= max(0,rgb[dominant]-other)*spillSuppression*(1-alpha)
                values.append(contentsOf:[Float(rgb[0]*alpha),Float(rgb[1]*alpha),Float(rgb[2]*alpha),Float(alpha)])
            } }
        }
        return values.withUnsafeBytes { Data($0) }
    }
}
