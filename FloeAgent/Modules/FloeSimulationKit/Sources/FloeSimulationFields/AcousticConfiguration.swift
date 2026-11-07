import Foundation
import FloeSimulationCore

public struct SimulationComplex: Codable, Equatable, Sendable {
    public var real: Double
    public var imaginary: Double
    public init(real: Double = 0, imaginary: Double = 0) { self.real = real; self.imaginary = imaginary }
    public var isFinite: Bool { real.isFinite && imaginary.isFinite }
    public var magnitude: Double { hypot(real, imaginary) }
    public var phaseRadians: Double { atan2(imaginary, real) }
}
public enum SimulationAcousticBoundaryKind: String, Codable, Sendable, CaseIterable { case rigidWall, pressure, normalVelocity, impedance, radiation }
public struct SimulationAcousticBoundary: Codable, Equatable, Sendable {
    public var boundaryID: String
    public var kind: SimulationAcousticBoundaryKind
    public var value: SimulationComplex
    public init(boundaryID: String, kind: SimulationAcousticBoundaryKind, value: SimulationComplex = .init()) { self.boundaryID = boundaryID; self.kind = kind; self.value = value }
}
public struct AcousticSimulationConfiguration: Codable, Equatable, Sendable {
    public var frequencies = SimulationFrequencySweep()
    public var boundaries: [SimulationAcousticBoundary] = []
    public var densityKgPerCubicMeter = 1.225
    public var soundSpeedMetersPerSecond = 343.0
    public var lossFactor = 0.0
    public var referencePressurePascal = 20e-6
    public var finiteElementOrder = 1
    public init() {}
    public func validate(for request: SimulationRequest) throws {
        try request.validate(); try frequencies.validate()
        guard let mesh = request.mesh else { throw SimulationError.invalidInput("Create an acoustic-domain mesh first.") }
        let ids = Set(mesh.boundaries.map(\.id))
        guard [densityKgPerCubicMeter,soundSpeedMetersPerSecond,referencePressurePascal].allSatisfy({ $0.isFinite && $0 > 0 }), lossFactor.isFinite, lossFactor >= 0, (1...6).contains(finiteElementOrder),
              Set(boundaries.map(\.boundaryID)).count == boundaries.count,
              boundaries.allSatisfy({ ids.contains($0.boundaryID) && $0.value.isFinite && ($0.kind != .impedance || $0.value.real >= 0) }) else { throw SimulationError.invalidInput("Invalid acoustic medium, excitation or boundary settings.") }
    }
}
