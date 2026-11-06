// SPDX-License-Identifier: MPL-2.0
import Foundation

/// Explicit process inputs; kc is supplied for the actual material/chip condition.
/// These estimates do not alter paths, stock geometry or machine commands.
public struct TurningProcessRequirements: Codable, Equatable, Sendable {
    public var radiusMM: Double
    public var depthMM: Double
    public var specificCuttingForceNPerMM2: Double
    public var efficiency: Double
    public var availableInputPowerKW: Double?
    public var availableTorqueNM: Double?
    public var maximumIdealCuspUM: Double?
    public init(radiusMM:Double = 10,depthMM:Double = 1,specificCuttingForceNPerMM2:Double = 2000,efficiency:Double = 0.8,
                availableInputPowerKW:Double? = nil,availableTorqueNM:Double? = nil,maximumIdealCuspUM:Double? = nil) {
        self.radiusMM = radiusMM; self.depthMM = depthMM; self.specificCuttingForceNPerMM2 = specificCuttingForceNPerMM2
        self.efficiency = efficiency; self.availableInputPowerKW = availableInputPowerKW
        self.availableTorqueNM = availableTorqueNM; self.maximumIdealCuspUM = maximumIdealCuspUM
    }
    public func validate() throws {
        let values = [radiusMM,depthMM,specificCuttingForceNPerMM2,efficiency]+[availableInputPowerKW,availableTorqueNM,maximumIdealCuspUM].compactMap { $0 }
        guard values.allSatisfy({ $0.isFinite && $0 > 0 && $0 <= 1e9 }), depthMM <= radiusMM,
              efficiency <= 1 else { throw ManufacturingError.invalid("process assessment units/ranges") }
    }
}

public struct TurningProcessAssessment: Codable, Equatable, Sendable {
    public var rpm: Double
    public var feedMMPerRevolution: Double
    public var surfaceSpeedMPerMinute: Double
    public var idealCuspHeightUM: Double
    public var materialRemovalCM3PerMinute: Double
    public var tangentialForceN: Double
    public var netCuttingPowerKW: Double
    public var requiredInputPowerKW: Double
    public var torqueNM: Double
    public var exceededLimits: [String]
    public var assumptions: [String]
    public var sources: [String]

    public static func evaluate(study:ManufacturingStudy,requirements r:TurningProcessRequirements) throws -> Self {
        try r.validate()
        guard study.turning.enabled, let cutting = study.turningCutting else {
            throw ManufacturingError.invalid("process assessment requires active turning speed/feed settings")
        }
        try cutting.validate()
        let rpm:Double
        switch cutting.spindleMode {
        case .fixedRPM: rpm = min(cutting.spindleRPM,cutting.maxSpindleRPM)
        case .constantSurfaceSpeed: rpm = min(cutting.maxSpindleRPM,1000*cutting.surfaceSpeedMPerMinute/(2*Double.pi*r.radiusMM))
        }
        let f = cutting.feedMode == .mmPerRevolution ? cutting.feedMMPerRevolution : study.turning.feedMMPerMinute/rpm
        let nose = study.turning.toolNoseRadiusMM
        guard nose.isFinite && nose > 0, f.isFinite && f > 0 && f < 2*nose else {
            throw ManufacturingError.invalid("ideal circular-nose surface estimate requires 0 < feed/rev < nose diameter")
        }
        // Exact intersection height of equal circular noses separated by feed f.
        // Rationalized expression avoids cancellation for small feeds.
        let half = f/2, cusp = 1000*half*half/(nose+sqrt(nose*nose-half*half))
        let vc = 2*Double.pi*r.radiusMM*rpm/1000
        let force = r.depthMM*f*r.specificCuttingForceNPerMM2
        let power = force*vc/60_000, torque = force*r.radiusMM/1000
        var limits = [String]()
        if let max = r.availableInputPowerKW, power/r.efficiency > max { limits.append("inputPowerKW") }
        if let max = r.availableTorqueNM, torque > max { limits.append("torqueNM") }
        if let max = r.maximumIdealCuspUM, cusp > max { limits.append("idealCuspUM") }
        let numbers = [rpm,f,vc,cusp,force,power,torque,power/r.efficiency,vc*r.depthMM*f]
        guard numbers.allSatisfy({ $0.isFinite }) else { throw ManufacturingError.invalid("process assessment overflow") }
        return .init(rpm:rpm,feedMMPerRevolution:f,surfaceSpeedMPerMinute:vc,idealCuspHeightUM:cusp,
                     materialRemovalCM3PerMinute:vc*r.depthMM*f,tangentialForceN:force,netCuttingPowerKW:power,
                     requiredInputPowerKW:power/r.efficiency,torqueNM:torque,exceededLimits:limits,
                     assumptions:["Nominal steady external turning at the supplied radius and radial depth.",
                                  "Ideal circular nose; no wear, built-up edge, vibration, wiper or material deformation. Cusp height is not measured Ra/Rz.",
                                  "Specific cutting force must match the actual chip/material condition. No automatic material or speed recommendation.",
                                  "Voxel/display faceting and dimensional approximation are separate from theoretical feed marks."],
                     sources:["https://www.sandvik.coromant.com/en-gb/knowledge/machining-formulas-definitions/general-turning-formulas-definitions",
                              "https://www.keyence.com/ss/products/measure-sys/machining/formula/cutting.jsp",
                              "Exact circular-nose intersection geometry; local derivation, mm to micrometres"])
    }
}
