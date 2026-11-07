import Foundation
import FloeSimulationCore

public struct SimulationDisplacementConstraint: Codable, Equatable, Sendable, Identifiable {
    public var id: UUID
    public var selection: SimulationSelection
    public var fixedAxes: [Bool]
    public var displacementMeters: SimulationVector3
    public init(id: UUID = UUID(), selection: SimulationSelection, fixedAxes: [Bool] = [true,true,true], displacementMeters: SimulationVector3 = .zero) {
        self.id = id; self.selection = selection; self.fixedAxes = fixedAxes; self.displacementMeters = displacementMeters
    }
}

public struct SimulationBeamSection: Codable, Equatable, Sendable {
    public var areaSquareMeters: Double
    public var inertiaYFourthMeters: Double
    public var inertiaZFourthMeters: Double
    public var torsionalConstantFourthMeters: Double
    public var orientation: SimulationVector3
    public init(areaSquareMeters: Double, inertiaYFourthMeters: Double, inertiaZFourthMeters: Double, torsionalConstantFourthMeters: Double, orientation: SimulationVector3 = .init(0,1,0)) {
        self.areaSquareMeters = areaSquareMeters; self.inertiaYFourthMeters = inertiaYFourthMeters; self.inertiaZFourthMeters = inertiaZFourthMeters; self.torsionalConstantFourthMeters = torsionalConstantFourthMeters; self.orientation = orientation
    }
}

public struct SimulationShellSection: Codable, Equatable, Sendable {
    public var thicknessMeters: Double
    public var materialDirection: SimulationVector3
    public var offsetMeters: Double
    public init(thicknessMeters: Double = 0.001, materialDirection: SimulationVector3 = .init(1,0,0), offsetMeters: Double = 0) {
        self.thicknessMeters = thicknessMeters; self.materialDirection = materialDirection; self.offsetMeters = offsetMeters
    }
}

public struct SimulationContact: Codable, Equatable, Sendable, Identifiable {
    public var id: UUID
    public var primaryBoundary: String
    public var secondaryBoundary: String
    public var friction: Double
    public var penalty: Double
    public init(id: UUID = UUID(), primaryBoundary: String, secondaryBoundary: String, friction: Double = 0, penalty: Double = 1) {
        self.id = id; self.primaryBoundary = primaryBoundary; self.secondaryBoundary = secondaryBoundary; self.friction = friction; self.penalty = penalty
    }
}

public enum SimulationSolidMaterialModel: String, Codable, Sendable, CaseIterable { case linearIsotropic, orthotropic, j2Plasticity, neoHookean }

public struct SimulationConvection: Codable, Equatable, Sendable {
    public var boundaryID: String
    public var coefficientWPerSquareMeterK: Double
    public var ambientKelvin: Double
    public init(boundaryID: String, coefficientWPerSquareMeterK: Double, ambientKelvin: Double) { self.boundaryID = boundaryID; self.coefficientWPerSquareMeterK = coefficientWPerSquareMeterK; self.ambientKelvin = ambientKelvin }
}

public struct EngineeringSimulationConfiguration: Codable, Equatable, Sendable {
    public var constraints: [SimulationDisplacementConstraint] = []
    /// Total force is distributed across the selection; pressure is positive inward.
    public var forces: [SimulationVectorCondition] = []
    public var pressures: [SimulationScalarCondition] = []
    public var bodyForceNewtonsPerCubicMeter: SimulationVector3 = .zero
    public var beamSections: [String: SimulationBeamSection] = [:]
    public var shellSections: [String: SimulationShellSection] = [:]
    public var materialModel: SimulationSolidMaterialModel = .linearIsotropic
    public var largeDeformation = false
    public var contacts: [SimulationContact] = []
    public var loadSteps = 10
    public var requestedModes = 6
    public var preloadedResultID: UUID?
    public var fixedTemperatures: [SimulationScalarCondition] = []
    /// Positive values remove heat through the selected face, in W/m².
    public var faceHeatFluxes: [SimulationScalarCondition] = []
    public var volumeHeatSourcesWPerCubicMeter: [String: Double] = [:]
    public var convection: [SimulationConvection] = []
    public var initialTemperatureKelvin = 293.15
    public var referenceTemperatureKelvin = 293.15
    public var temperatureResultID: UUID?
    public var time = SimulationTimeSettings(durationSeconds: 1, stepSeconds: 0.01, outputIntervalSeconds: 0.1)
    public var relativeTolerance = 1e-8
    public init() {}

    public func validate(for request: SimulationRequest) throws {
        try request.validate()
        guard let mesh = request.mesh else { throw SimulationError.invalidInput("An analysis mesh is required.") }
        guard loadSteps > 0, loadSteps <= request.budget.maximumIterations, requestedModes > 0, requestedModes <= 1000,
              relativeTolerance.isFinite, relativeTolerance > 0, relativeTolerance < 1,
              bodyForceNewtonsPerCubicMeter.isFinite, initialTemperatureKelvin.isFinite, initialTemperatureKelvin >= 0,
              referenceTemperatureKelvin.isFinite, referenceTemperatureKelvin >= 0 else { throw SimulationError.invalidInput("Invalid structural, thermal or spectral settings.") }
        for constraint in constraints {
            _ = try constraint.selection.resolveNodes(in: mesh)
            guard constraint.fixedAxes.count == 3, constraint.fixedAxes.contains(true), constraint.displacementMeters.isFinite else { throw SimulationError.invalidInput("A support needs three valid axis flags and displacements.") }
        }
        for force in forces { _ = try force.selection.resolveNodes(in: mesh); guard force.value.isFinite else { throw SimulationError.invalidInput("A force is not finite.") } }
        for value in pressures + fixedTemperatures + faceHeatFluxes { _ = try value.selection.resolveNodes(in: mesh); guard value.value.isFinite else { throw SimulationError.invalidInput("A boundary value is not finite.") } }
        guard fixedTemperatures.allSatisfy({ $0.value >= 0 }), volumeHeatSourcesWPerCubicMeter.values.allSatisfy(\.isFinite) else { throw SimulationError.invalidInput("Invalid temperature or heat source.") }
        let regions = Set(mesh.elements.map(\.regionID)), boundaryIDs = Set(mesh.boundaries.map(\.id))
        guard Set(request.study.materialAssignments.keys) == regions else { throw SimulationError.invalidInput("Assign an engineering material to every mesh region.") }
        guard Set(volumeHeatSourcesWPerCubicMeter.keys).isSubset(of: regions) else { throw SimulationError.invalidInput("A heat source refers to a missing region.") }
        for section in beamSections.values {
            guard [section.areaSquareMeters, section.inertiaYFourthMeters, section.inertiaZFourthMeters, section.torsionalConstantFourthMeters].allSatisfy({ $0.isFinite && $0 > 0 }), section.orientation.isFinite, section.orientation.length > 0 else { throw SimulationError.invalidInput("Invalid beam section or orientation.") }
        }
        for section in shellSections.values {
            guard section.thicknessMeters.isFinite, section.thicknessMeters > 0, section.offsetMeters.isFinite, section.materialDirection.isFinite, section.materialDirection.length > 0 else { throw SimulationError.invalidInput("Invalid shell thickness or direction.") }
        }
        for contact in contacts {
            guard boundaryIDs.contains(contact.primaryBoundary), boundaryIDs.contains(contact.secondaryBoundary), contact.primaryBoundary != contact.secondaryBoundary,
                  contact.friction.isFinite, contact.friction >= 0, contact.penalty.isFinite, contact.penalty > 0 else { throw SimulationError.invalidInput("Invalid contact surfaces, friction or penalty.") }
        }
        for boundary in convection { guard boundaryIDs.contains(boundary.boundaryID), boundary.coefficientWPerSquareMeterK.isFinite, boundary.coefficientWPerSquareMeterK > 0, boundary.ambientKelvin.isFinite, boundary.ambientKelvin >= 0 else { throw SimulationError.invalidInput("Invalid convection condition.") } }
        if request.study.kind == .thermalTransient { try time.validate(maximumSteps: request.budget.maximumIterations) }
        if request.study.kind == .buckling, preloadedResultID == nil { throw SimulationError.invalidInput("Buckling requires a compatible preloaded structural result.") }
        if request.study.kind == .thermalStress, temperatureResultID == nil { throw SimulationError.invalidInput("Thermal stress requires a compatible temperature result.") }
        if request.study.kind == .laminate, !request.materials.contains(where: { !$0.layers.isEmpty }) { throw SimulationError.invalidInput("Define the laminate plies and material directions.") }
    }
}
