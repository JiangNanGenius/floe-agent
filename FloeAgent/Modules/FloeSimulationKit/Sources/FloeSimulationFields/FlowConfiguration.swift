import Foundation
import FloeSimulationCore

public enum SimulationFlowRegime: String, Codable, CaseIterable, Sendable { case incompressible, compressible }
public enum SimulationTurbulenceModel: String, Codable, CaseIterable, Sendable { case laminar, spalartAllmaras, sst }
public enum SimulationFlowBoundaryKind: String, Codable, CaseIterable, Sendable { case velocityInlet, pressureOutlet, wall, symmetry, farField }

public struct SimulationFlowBoundary: Codable, Equatable, Sendable, Identifiable {
    public var id: UUID
    public var boundaryID: String
    public var kind: SimulationFlowBoundaryKind
    public var velocityMetersPerSecond: SimulationVector3
    public var pressurePascal: Double
    public var temperatureKelvin: Double
    public var heatFluxWPerSquareMeter: Double?
    public var noSlip: Bool
    public init(id: UUID = UUID(), boundaryID: String, kind: SimulationFlowBoundaryKind, velocityMetersPerSecond: SimulationVector3 = .zero, pressurePascal: Double = 101325, temperatureKelvin: Double = 293.15, heatFluxWPerSquareMeter: Double? = nil, noSlip: Bool = true) {
        self.id = id; self.boundaryID = boundaryID; self.kind = kind; self.velocityMetersPerSecond = velocityMetersPerSecond; self.pressurePascal = pressurePascal; self.temperatureKelvin = temperatureKelvin; self.heatFluxWPerSquareMeter = heatFluxWPerSquareMeter; self.noSlip = noSlip
    }
}

public struct FlowSimulationConfiguration: Codable, Equatable, Sendable {
    public var regime: SimulationFlowRegime = .incompressible
    public var turbulence: SimulationTurbulenceModel = .laminar
    public var boundaries: [SimulationFlowBoundary] = []
    public var freestreamVelocity = SimulationVector3(1,0,0)
    public var freestreamPressurePascal = 101325.0
    public var freestreamTemperatureKelvin = 293.15
    public var machNumber = 0.1
    public var reynoldsNumber = 1000.0
    public var turbulenceIntensity = 0.05
    public var turbulentViscosityRatio = 10.0
    public var cfl = 1.0
    public var relativeTolerance = 1e-8
    public var transient = false
    public var time = SimulationTimeSettings(durationSeconds: 1, stepSeconds: 0.001, outputIntervalSeconds: 0.01)
    public init() {}
    public func validate(for request: SimulationRequest) throws {
        try request.validate()
        guard let mesh = request.mesh else { throw SimulationError.invalidInput("Create a fluid-domain mesh first.") }
        let ids = Set(mesh.boundaries.map(\.id))
        guard !boundaries.isEmpty, Set(boundaries.map(\.boundaryID)).count == boundaries.count,
              boundaries.allSatisfy({ ids.contains($0.boundaryID) && $0.velocityMetersPerSecond.isFinite && $0.pressurePascal.isFinite && $0.pressurePascal > 0 && $0.temperatureKelvin.isFinite && $0.temperatureKelvin > 0 && ($0.heatFluxWPerSquareMeter?.isFinite ?? true) }),
              freestreamVelocity.isFinite,
              [freestreamPressurePascal,freestreamTemperatureKelvin,reynoldsNumber,turbulentViscosityRatio,cfl,relativeTolerance].allSatisfy({ $0.isFinite && $0 > 0 }),
              machNumber.isFinite, machNumber > 0, turbulenceIntensity.isFinite, turbulenceIntensity > 0, turbulenceIntensity < 1, relativeTolerance < 1 else { throw SimulationError.invalidInput("Invalid flow boundary, medium or solver settings.") }
        guard Set(boundaries.map(\.boundaryID)) == ids else { throw SimulationError.invalidInput("Set a boundary condition on every fluid-domain boundary.") }
        if request.study.kind == .incompressibleFlow, regime != .incompressible { throw SimulationError.invalidInput("This study requires incompressible flow settings.") }
        if request.study.kind == .compressibleFlow, regime != .compressible { throw SimulationError.invalidInput("This study requires compressible flow settings.") }
        if request.study.kind == .turbulentFlow, turbulence == .laminar { throw SimulationError.invalidInput("Select SA or SST for a turbulence study.") }
        if transient { try time.validate(maximumSteps: request.budget.maximumIterations) }
        guard !request.materials.isEmpty else { throw SimulationError.invalidInput("Assign the fluid's physical properties.") }
    }
}
