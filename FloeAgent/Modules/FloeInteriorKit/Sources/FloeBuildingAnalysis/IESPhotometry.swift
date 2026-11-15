// SPDX-License-Identifier: MIT
// Field layout and symmetry adapted from three.js IESLoader, revision
// 00e83040432badf3e9b0dccf90ae57da65033d21. Copyright three.js authors.
// See ThirdParty/three-IES/LICENSE and NOTICE.md. Absolute candela is retained.
import Foundation

public struct IESPhotometry: Codable, Equatable, Sendable {
    public let sourceSHA256: String
    public let format: String
    public let lampCount: Int
    public let lumensPerLamp: Double
    public let inputWatts: Double
    public let declaredDimensionsM: AnalysisVector3
    public let verticalAngles: [Double]
    public let horizontalAngles: [Double]
    /// Row-major C-plane (horizontal), then vertical angle. Absolute cd.
    public let candela: [[Double]]
    public var peakCandela: Double { candela.lazy.flatMap { $0 }.max() ?? 0 }

    public func validate() throws {
        guard !sourceSHA256.isEmpty, (1...10_000).contains(lampCount),
              lumensPerLamp.isFinite, lumensPerLamp == -1 || lumensPerLamp>=0,
              inputWatts.isFinite, inputWatts>=0, declaredDimensionsM.isFinite,
              (2...2048).contains(verticalAngles.count), (1...2048).contains(horizontalAngles.count),
              verticalAngles.count<=1_000_000/horizontalAngles.count,
              candela.count==horizontalAngles.count,
              candela.allSatisfy({$0.count==verticalAngles.count && $0.allSatisfy{$0.isFinite && $0>=0 && $0<=1e12}}),
              verticalAngles.allSatisfy({$0.isFinite && $0>=0 && $0<=180}),
              horizontalAngles.allSatisfy({$0.isFinite && $0>=0 && $0<=360}),
              zip(verticalAngles,verticalAngles.dropFirst()).allSatisfy({$0<$1}),
              zip(horizontalAngles,horizontalAngles.dropFirst()).allSatisfy({$0<$1}) else {
            throw BuildingAnalysisError.malformedPhotometry("profile bounds or samples")
        }
        let first=horizontalAngles[0], last=horizontalAngles[horizontalAngles.count-1]
        let supported = (horizontalAngles.count==1 && first==0) ||
            (first==0 && (last==90 || last==180 || last==360)) || (first==90 && last==270)
        guard supported else { throw BuildingAnalysisError.unsupportedPhotometry("horizontal symmetry range") }
    }

    public func intensityCD(verticalDegrees: Double, horizontalDegrees: Double) throws -> Double {
        try validate()
        guard verticalDegrees.isFinite, horizontalDegrees.isFinite else {
            throw BuildingAnalysisError.invalidInput("sample angle")
        }
        return sample(verticalDegrees:verticalDegrees,horizontalDegrees:horizontalDegrees)
    }

    // Called after one complete validation by the point/grid solver.
    func sample(verticalDegrees v: Double, horizontalDegrees h: Double) -> Double {
        guard v>=verticalAngles[0], v<=verticalAngles[verticalAngles.count-1] else { return 0 }
        let vertical=interval(verticalAngles,v)
        if horizontalAngles.count==1 { return interpolate(candela[0],vertical) }
        var angle=h.truncatingRemainder(dividingBy:360)
        if angle<0 { angle+=360 }
        let first=horizontalAngles[0],last=horizontalAngles[horizontalAngles.count-1]
        if first==0 && last==90 {
            if angle>180 { angle=360-angle }
            if angle>90 { angle=180-angle }
        } else if first==0 && last==180 {
            if angle>180 { angle=360-angle }
        } else if first==90 && last==270 {
            if angle<90 { angle=180-angle }
            else if angle>270 { angle=540-angle }
        }
        let plane=interval(horizontalAngles,angle)
        let a=interpolate(candela[plane.0],vertical)
        let b=interpolate(candela[plane.1],vertical)
        return a+(b-a)*plane.2
    }

    private func interval(_ angles: [Double],_ value: Double)->(Int,Int,Double) {
        if value<=angles[0] { return (0,0,0) }
        let last=angles.count-1
        if value>=angles[last] { return (last,last,0) }
        var lower=0,upper=last
        while upper-lower>1 {
            let middle=(lower+upper)/2
            if angles[middle]<=value { lower=middle } else { upper=middle }
        }
        return (lower,upper,(value-angles[lower])/(angles[upper]-angles[lower]))
    }
    private func interpolate(_ row:[Double],_ value:(Int,Int,Double))->Double {
        row[value.0]+(row[value.1]-row[value.0])*value.2
    }
}

public enum IESPhotometryParser {
    public static func parse(_ text:String,maximumBytes:Int=4*1024*1024) throws -> IESPhotometry {
        guard maximumBytes>0,text.utf8.count<=maximumBytes else {
            throw BuildingAnalysisError.budgetExceeded(text.utf8.count)
        }
        let lines=text.replacingOccurrences(of:"\r\n",with:"\n").replacingOccurrences(of:"\r",with:"\n").components(separatedBy:"\n")
        let format=(lines.first ?? "").trimmingCharacters(in:.whitespacesAndNewlines).replacingOccurrences(of:"\u{FEFF}",with:"")
        guard ["IESNA:LM-63-1995","IESNA:LM-63-2002","IES:LM-63-2019","IESNA91"].contains(format.uppercased()) else {
            throw BuildingAnalysisError.unsupportedPhotometry("LM-63 version header")
        }
        guard let tiltIndex=lines.firstIndex(where:{$0.trimmingCharacters(in:.whitespaces).uppercased().hasPrefix("TILT=")}) else {
            throw BuildingAnalysisError.malformedPhotometry("missing TILT record")
        }
        let tilt=lines[tiltIndex].trimmingCharacters(in:.whitespaces).uppercased()
        guard tilt=="TILT=NONE" else { throw BuildingAnalysisError.unsupportedPhotometry("only TILT=NONE is supported") }
        let tokens=lines.dropFirst(tiltIndex+1).joined(separator:" ").split(whereSeparator:{$0.isWhitespace || $0==","})
        var cursor=0
        func number(_ name:String) throws -> Double {
            guard cursor<tokens.count,let value=Double(tokens[cursor]),value.isFinite else {
                throw BuildingAnalysisError.malformedPhotometry(name)
            }
            cursor+=1;return value
        }
        func integer(_ name:String,_ range:ClosedRange<Int>) throws -> Int {
            let value=try number(name)
            guard value.rounded(.towardZero)==value,value>=Double(range.lowerBound),value<=Double(range.upperBound) else {
                throw BuildingAnalysisError.malformedPhotometry(name)
            }
            return Int(value)
        }
        let lamps=try integer("lamp count",1...10_000)
        let lumens=try number("lumens per lamp"),multiplier=try number("candela multiplier")
        let nv=try integer("vertical count",2...2048),nh=try integer("horizontal count",1...2048)
        guard nv<=1_000_000/nh else { throw BuildingAnalysisError.budgetExceeded(nv*nh) }
        let gonio=try integer("photometric type",1...3),units=try integer("units",1...2)
        guard gonio==1 else { throw BuildingAnalysisError.unsupportedPhotometry("only Type C photometry is supported") }
        let width=try number("width"),length=try number("length"),height=try number("height")
        let ballast=try number("ballast factor"),legacyFactor=try number("legacy photometric factor"),watts=try number("input watts")
        guard multiplier>=0,ballast>=0,legacyFactor>=0 else {
            throw BuildingAnalysisError.malformedPhotometry("negative multiplier")
        }
        let expected=13+nv+nh+nv*nh
        guard tokens.count==expected else { throw BuildingAnalysisError.malformedPhotometry("numeric field count") }
        let vertical=try (0..<nv).map{_ in try number("vertical angle")}
        var horizontal=try (0..<nh).map{_ in try number("horizontal angle")}
        // LM-63 >=1995 uses field12 as reserved/source-generation metadata,
        // not intensity. Semantics checked against Radiance ies2rad dosource.
        let photometricFactor = format.uppercased()=="IESNA91" ? legacyFactor:1
        var cd=try (0..<nh).map{_ in try (0..<nv).map{_ in
            let raw=try number("candela")
            guard raw>=0 else{throw BuildingAnalysisError.malformedPhotometry("negative candela")}
            return raw * multiplier * ballast * photometricFactor
        }}
        // Same explicit wrap completion as the fixed upstream loader, retaining cd.
        if horizontal.first==0,let end=horizontal.last,end>180,end<360 {
            horizontal.append(360);cd.append(cd[0])
        }
        let scale=units==1 ? 0.3048:1.0
        let profile=IESPhotometry(sourceSHA256:BuildingAnalysisFingerprint.dataHash(Data(text.utf8)),
            format:format,
            lampCount:lamps,lumensPerLamp:lumens,inputWatts:watts,
            declaredDimensionsM:.init(width*scale,length*scale,height*scale),
            verticalAngles:vertical,horizontalAngles:horizontal,candela:cd)
        try profile.validate();return profile
    }
}
