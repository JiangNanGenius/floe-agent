// SPDX-License-Identifier: MPL-2.0
import Foundation
import FloeManufacturingParameters

/// Parameters implemented by the isolated LibLathe native research component.
/// Insert edge length is not the inscribed-circle diameter. No nose compensation
/// is inferred from this geometry; the existing nominal nose remains 0.4 mm.
public struct TurningSetup: Codable, Equatable, Sendable {
    public var formatVersion = 1
    public var faceEnabled = true
    public var roughEnabled = true
    public var profileEnabled = true
    public var clearanceMM = 3.0
    public var horizontalFeedMMPerMinute = 120.0
    public var verticalFeedMMPerMinute = 120.0
    public var leadinAngleDegrees = 270.0
    public var leadoutAngleDegrees = 315.0
    public var allowGrooving = false
    public var insertShape = "D"
    public var insertEdgeLengthMM = 6.35
    public var insertRotationDegrees = 0.0
    public init() {}
    private enum CodingKeys:String,CodingKey { case formatVersion,faceEnabled,roughEnabled,profileEnabled,clearanceMM,horizontalFeedMMPerMinute,verticalFeedMMPerMinute,leadinAngleDegrees,leadoutAngleDegrees,allowGrooving,insertShape,insertEdgeLengthMM,insertRotationDegrees }
    public init(from decoder:Decoder) throws {
        let c = try decoder.container(keyedBy:CodingKeys.self)
        formatVersion = try c.defaulted(Int.self,forKey:.formatVersion,to:1)
        faceEnabled = try c.defaulted(Bool.self,forKey:.faceEnabled,to:true)
        roughEnabled = try c.defaulted(Bool.self,forKey:.roughEnabled,to:true)
        profileEnabled = try c.defaulted(Bool.self,forKey:.profileEnabled,to:true)
        clearanceMM = try c.defaulted(Double.self,forKey:.clearanceMM,to:3)
        horizontalFeedMMPerMinute = try c.defaulted(Double.self,forKey:.horizontalFeedMMPerMinute,to:120)
        verticalFeedMMPerMinute = try c.defaulted(Double.self,forKey:.verticalFeedMMPerMinute,to:120)
        leadinAngleDegrees = try c.defaulted(Double.self,forKey:.leadinAngleDegrees,to:270)
        leadoutAngleDegrees = try c.defaulted(Double.self,forKey:.leadoutAngleDegrees,to:315)
        allowGrooving = try c.defaulted(Bool.self,forKey:.allowGrooving,to:false)
        insertShape = try c.defaulted(String.self,forKey:.insertShape,to:"D")
        insertEdgeLengthMM = try c.defaulted(Double.self,forKey:.insertEdgeLengthMM,to:6.35)
        insertRotationDegrees = try c.defaulted(Double.self,forKey:.insertRotationDegrees,to:0)
    }
    public func validate(requireOperations:Bool = true) throws {
        try CAMCheck.require(formatVersion == 1,"turning setup version")
        if requireOperations { try CAMCheck.require(faceEnabled || roughEnabled || profileEnabled,"select at least one turning operation") }
        try CAMCheck.require(clearanceMM.isFinite && (0...10_000).contains(clearanceMM),"turning clearance")
        try CAMCheck.positive(horizontalFeedMMPerMinute,max:1_000_000,name:"X feed")
        try CAMCheck.positive(verticalFeedMMPerMinute,max:1_000_000,name:"Z feed")
        try CAMCheck.positive(insertEdgeLengthMM,max:1000,name:"insert edge length")
        try CAMCheck.require(horizontalFeedMMPerMinute >= 1e-6 && verticalFeedMMPerMinute >= 1e-6 && insertEdgeLengthMM >= 1e-6,"turning field lower bound is 1e-6")
        try CAMCheck.require([leadinAngleDegrees,leadoutAngleDegrees,insertRotationDegrees].allSatisfy { $0.isFinite && $0 >= 0 && $0 < 360 },"insert/entry/exit angles")
        try CAMCheck.require(["D","C","V","S","T","R"].contains(insertShape),"unsupported turning insert shape")
    }
    public struct Receipt: Codable, Equatable, Sendable {
        public var formatVersion: Int
        public var applied: TurningSetup
        public var toolProfile: [[Double]]
        public var backend: String
        public func validate(expected:TurningSetup) throws {
            guard formatVersion == 1, applied == expected, !backend.isEmpty,
                  (3...256).contains(toolProfile.count), toolProfile.allSatisfy(CAMCheck.pair) else {
                throw ManufacturingError.native("turning setup was not applied by this native component")
            }
        }
    }
}

public extension ManufacturingStudy {
    var configuredTurningSetup:TurningSetup {
        if let turningSetup { return turningSetup }
        var value = TurningSetup()
        for d in ManufacturingParameterCatalog.standard.parameters {
            if let binding = d.binding, binding.hasPrefix("turningSetup."), let stored = parameters?.value(d.id),
               let updated = try? ParameterProjection.setting(value,path:String(binding.dropFirst("turningSetup.".count)),value:stored) { value = updated }
        }
        return value
    }
    func applyingTurningSetup(_ value:TurningSetup,enabled:Bool) throws -> Self {
        try value.validate(requireOperations:enabled && turning.enabled)
        var draft = self, stored = parameters ?? .init()
        draft.turningSetup = enabled ? value : nil
        for d in ManufacturingParameterCatalog.standard.parameters {
            if let binding = d.binding, binding.hasPrefix("turningSetup.") {
                if enabled { stored.remove(d.id) }
                else if let setting = ParameterProjection.get(value,path:String(binding.dropFirst("turningSetup.".count))) { stored.set(d.id,setting) }
            }
        }
        draft.parameters = stored; try draft.validate(requireOperations:false); return draft
    }
}
