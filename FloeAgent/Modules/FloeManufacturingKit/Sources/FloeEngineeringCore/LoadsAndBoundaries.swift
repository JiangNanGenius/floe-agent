// SPDX-License-Identifier: MPL-2.0
import Foundation

/// Concentrated force at a node, components in N.
public struct ConcentratedLoad: Codable, Sendable, Equatable {
    public var node: Int
    public var components: Vector3
    public var label: String?
    public init(node: Int, components: Vector3, label: String? = nil) {
        self.node = node
        self.components = components
        self.label = label
    }
}

/// Uniform body force per unit volume, components in N/mm^3 (e.g. gravity from a
/// material density: rho * g, with g = 9810 mm/s^2).
public struct BodyLoad: Codable, Sendable, Equatable {
    public var componentsPerVolume: Vector3
    public var label: String?
    public init(componentsPerVolume: Vector3, label: String? = nil) {
        self.componentsPerVolume = componentsPerVolume
        self.label = label
    }
}

/// Uniform pressure traction on one element face, MPa (N/mm^2).
/// Positive pressure acts along the face outward normal (tensile away from the
/// element interior); negative values are suction.
public struct PressureLoad: Codable, Sendable, Equatable {
    /// Element index.
    public var element: Int
    /// Face index 0...3, opposite node `face` of the element.
    public var face: Int
    public var pressureMPa: Double
    public var label: String?
    public init(element: Int, face: Int, pressureMPa: Double, label: String? = nil) {
        self.element = element
        self.face = face
        self.pressureMPa = pressureMPa
        self.label = label
    }
}

/// Dirichlet displacement constraint at a node, per component. Prescribed values
/// may be zero or nonzero; constrained components are eliminated exactly.
public struct DisplacementBC: Codable, Sendable, Equatable {
    public var node: Int
    /// Which of x/y/z are constrained.
    public var constrained: [Bool]
    /// Prescribed displacement in mm for each constrained component.
    public var prescribedMM: [Double]
    public var label: String?
    public init(node: Int, constrained: [Bool], prescribedMM: [Double], label: String? = nil) {
        self.node = node
        self.constrained = constrained
        self.prescribedMM = prescribedMM
        self.label = label
    }
}

/// Dirichlet (fixed) temperature constraint, degrees Celsius. Nonzero values are
/// first-class; they are not shifted to zero internally.
public struct FixedTemperatureBC: Codable, Sendable, Equatable {
    public var node: Int
    public var temperatureCelsius: Double
    public init(node: Int, temperatureCelsius: Double) {
        self.node = node
        self.temperatureCelsius = temperatureCelsius
    }
}

/// Uniform volumetric heat source on one element, W/mm^3.
public struct ThermalSource: Codable, Sendable, Equatable {
    public var element: Int
    public var powerPerVolume: Double
    public init(element: Int, powerPerVolume: Double) {
        self.element = element
        self.powerPerVolume = powerPerVolume
    }
}

/// Uniform outward heat flux on one element face, W/mm^2.
public struct ThermalFlux: Codable, Sendable, Equatable {
    public var element: Int
    public var face: Int
    public var fluxWPerMM2: Double
    public init(element: Int, face: Int, fluxWPerMM2: Double) {
        self.element = element
        self.face = face
        self.fluxWPerMM2 = fluxWPerMM2
    }
}

/// Synchronous solve control: cancellation and external bookkeeping.
/// Not Codable; keep out of archived request payloads.
public struct EngineeringSolveControl: Sendable {
    /// Checked frequently during assembly and every CG iteration.
    public var isCancelled: (@Sendable () -> Bool)?
    public init(isCancelled: (@Sendable () -> Bool)? = nil) {
        self.isCancelled = isCancelled
    }

    func checkCancelled() throws {
        if isCancelled?() == true { throw EngineeringError.cancelled }
    }
}
