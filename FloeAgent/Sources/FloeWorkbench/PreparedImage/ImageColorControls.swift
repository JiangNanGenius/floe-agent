// SPDX-License-Identifier: MPL-2.0
import Foundation

public struct ImageRGBBalance: Codable, Sendable, Hashable {
    public var red:Double
    public var green:Double
    public var blue:Double
    public init(red:Double=0,green:Double=0,blue:Double=0){self.red=red;self.green=green;self.blue=blue}
    private enum Keys:String,CodingKey{case red,green,blue}
    public init(from decoder:any Decoder) throws{let c=try decoder.container(keyedBy:Keys.self);red=try c.decodeIfPresent(Double.self,forKey:.red) ?? 0;green=try c.decodeIfPresent(Double.self,forKey:.green) ?? 0;blue=try c.decodeIfPresent(Double.self,forKey:.blue) ?? 0}
}
public struct ImageColorBalance: Codable, Sendable, Hashable {
    public var shadows:ImageRGBBalance
    public var midtones:ImageRGBBalance
    public var highlights:ImageRGBBalance
    public var preserveLuminance:Bool
    public init(shadows:ImageRGBBalance = .init(),midtones:ImageRGBBalance = .init(),highlights:ImageRGBBalance = .init(),preserveLuminance:Bool=true){self.shadows=shadows;self.midtones=midtones;self.highlights=highlights;self.preserveLuminance=preserveLuminance}
    private enum Keys:String,CodingKey{case shadows,midtones,highlights,preserveLuminance}
    public init(from decoder:any Decoder) throws{let c=try decoder.container(keyedBy:Keys.self);shadows=try c.decodeIfPresent(ImageRGBBalance.self,forKey:.shadows) ?? .init();midtones=try c.decodeIfPresent(ImageRGBBalance.self,forKey:.midtones) ?? .init();highlights=try c.decodeIfPresent(ImageRGBBalance.self,forKey:.highlights) ?? .init();preserveLuminance=try c.decodeIfPresent(Bool.self,forKey:.preserveLuminance) ?? true}
}
public struct ImageColorLUT: Codable, Sendable, Hashable {
    public let dimension:Int
    /// Native little-endian Float32 RGBA, red index changes fastest (.cube convention).
    public let rgba:Data
    public let domainMin:[Double]
    public let domainMax:[Double]
    public init(dimension:Int,rgba:Data,domainMin:[Double]=[0,0,0],domainMax:[Double]=[1,1,1]) throws {
        self.dimension=dimension;self.rgba=rgba;self.domainMin=domainMin;self.domainMax=domainMax
        try validate()
    }
    public func validate() throws {
        guard (2...33).contains(dimension),rgba.count==dimension*dimension*dimension*16,domainMin.count==3,domainMax.count==3,
              zip(domainMin,domainMax).allSatisfy({$0.isFinite && $1.isFinite && $0 < $1 && ($1-$0).isFinite}) else{throw MediaPreparedCoreError.invalidOperation("3D LUT requires 2...33 samples per edge, finite domains and exact Float32 RGBA data")}
        try rgba.withUnsafeBytes{bytes in for offset in stride(from:0,to:bytes.count,by:4){let value=bytes.loadUnaligned(fromByteOffset:offset,as:Float.self);guard value.isFinite,abs(value)<=16 else{throw MediaPreparedCoreError.invalidOperation("LUT has invalid output values")}}}
    }
    public static func parseCube(_ text:String) throws -> Self {
        guard text.utf8.count<=2_097_152 else{throw MediaPreparedCoreError.limitsExceeded("LUT text exceeds 2 MiB")}
        var dimension:Int?,minimum=[0.0,0,0],maximum=[1.0,1,1],values:[Float]=[]
        for raw in text.split(whereSeparator:\.isNewline){
            let line=raw.split(separator:"#",maxSplits:1).first?.trimmingCharacters(in:.whitespaces) ?? ""
            if line.isEmpty || line.hasPrefix("TITLE"){continue}
            let parts=line.split(whereSeparator:\.isWhitespace).map(String.init)
            switch parts[0]{
            case "LUT_3D_SIZE":guard dimension==nil,parts.count==2,let size=Int(parts[1]),(2...33).contains(size) else{throw MediaPreparedCoreError.invalidOperation("LUT_3D_SIZE must be 2...33")};dimension=size
            case "DOMAIN_MIN","DOMAIN_MAX":guard parts.count==4 else{throw MediaPreparedCoreError.invalidOperation("LUT domain needs three values")};let numbers=parts.dropFirst().compactMap(Double.init);guard numbers.count==3,numbers.allSatisfy(\.isFinite) else{throw MediaPreparedCoreError.invalidOperation("invalid LUT domain")};if parts[0]=="DOMAIN_MIN"{minimum=numbers}else{maximum=numbers}
            default:guard parts.count==3,let size=dimension,values.count<size*size*size*4 else{throw MediaPreparedCoreError.invalidOperation("unsupported or excess LUT rows")};let numbers=parts.compactMap(Float.init);guard numbers.count==3,numbers.allSatisfy({$0.isFinite && abs($0)<=16}) else{throw MediaPreparedCoreError.invalidOperation("invalid LUT sample")};values += numbers+[1]
            }
        }
        guard let size=dimension,values.count==size*size*size*4 else{throw MediaPreparedCoreError.invalidOperation("LUT sample count does not match its dimension")}
        return try .init(dimension:size,rgba:values.withUnsafeBytes{Data($0)},domainMin:minimum,domainMax:maximum)
    }
}
