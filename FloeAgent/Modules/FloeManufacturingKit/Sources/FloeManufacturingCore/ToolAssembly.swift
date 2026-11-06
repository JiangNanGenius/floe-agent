// SPDX-License-Identifier: MPL-2.0
import Foundation

/// Holder envelope in the explicit tool-tip frame, not a vendor spindle-origin
/// profile. Distances run along tip -> spindle; second component is a radius.
public struct HolderProfilePoint: Codable, Equatable, Sendable {
    public var axialMM: Double
    public var radiusMM: Double
    public init(_ axialMM:Double,_ radiusMM:Double) { self.axialMM = axialMM; self.radiusMM = radiusMM }
    public init(from decoder:Decoder) throws {
        var values = try decoder.unkeyedContainer()
        axialMM = try values.decode(Double.self); radiusMM = try values.decode(Double.self)
        guard values.isAtEnd else { throw ManufacturingError.invalid("holder point requires [distance from tip, radius]") }
    }
    public func encode(to encoder:Encoder) throws {
        var values = encoder.unkeyedContainer(); try values.encode(axialMM); try values.encode(radiusMM)
    }
}

public struct MillingToolAssembly: Codable, Equatable, Sendable {
    public var formatVersion = 1
    public var name: String
    public var shankDiameterMM: Double
    public var holderProfile: [HolderProfilePoint]
    public var clearanceMM: Double
    public init(name:String,shankDiameterMM:Double,holderProfile:[HolderProfilePoint],clearanceMM:Double) {
        self.name = name; self.shankDiameterMM = shankDiameterMM
        self.holderProfile = holderProfile; self.clearanceMM = clearanceMM
    }
    /// Explicit research example. Never infer a real holder from a cutter.
    public static func demonstration(cuttingLengthMM:Double) -> Self {
        .init(name:"Research assembly",shankDiameterMM:4,
              holderProfile:[.init(cuttingLengthMM+10,5),.init(cuttingLengthMM+16,5),.init(cuttingLengthMM+16,8),.init(cuttingLengthMM+30,8)],clearanceMM:0.2)
    }
    public func validate(cuttingLengthMM:Double) throws {
        guard formatVersion == 1, !name.isEmpty, name.utf8.count <= 512,
              shankDiameterMM.isFinite, shankDiameterMM > 0, shankDiameterMM <= 1000,
              clearanceMM.isFinite, (0...100).contains(clearanceMM),
              cuttingLengthMM.isFinite, cuttingLengthMM > 0,
              (2...32).contains(holderProfile.count) else { throw ManufacturingError.invalid("tool assembly dimensions or profile count") }
        for (i,p) in holderProfile.enumerated() {
            guard p.axialMM.isFinite, p.radiusMM.isFinite, (0...1000).contains(p.axialMM),
                  p.radiusMM > 0, p.radiusMM <= 500,
                  i == 0 || (p.axialMM >= holderProfile[i-1].axialMM && p != holderProfile[i-1]) else {
                throw ManufacturingError.invalid("holder profile requires finite ordered [distance from tip, radius] points")
            }
        }
        guard holderProfile.first!.axialMM >= cuttingLengthMM,
              holderProfile.last!.axialMM > holderProfile.first!.axialMM else {
            throw ManufacturingError.invalid("holder must start beyond the cutting edge and have positive axial extent")
        }
        var first = 0
        while first < holderProfile.count {
            var last = first
            while last+1 < holderProfile.count && holderProfile[last+1].axialMM == holderProfile[first].axialMM { last += 1 }
            let coveredRadius = max(first > 0 ? holderProfile[first].radiusMM : 0,last+1 < holderProfile.count ? holderProfile[last].radiusMM : 0)
            guard holderProfile[first...last].allSatisfy({ $0.radiusMM <= coveredRadius }) else {
                throw ManufacturingError.invalid("isolated zero-thickness holder flanges are unsupported; give the flange finite axial thickness")
            }
            first = last+1
        }
    }
}
