import Foundation
import FloeSimulationCore

public enum SimulationEMBoundaryKind: String, Codable, Sendable, CaseIterable { case perfectElectric, perfectMagnetic, radiation, absorbingLayer, electricPotential, surfaceCurrent }
public struct SimulationEMBoundary: Codable, Equatable, Sendable {
    public var boundaryID: String
    public var kind: SimulationEMBoundaryKind
    public var value: SimulationComplex
    public init(boundaryID: String, kind: SimulationEMBoundaryKind, value: SimulationComplex = .init()) { self.boundaryID = boundaryID; self.kind = kind; self.value = value }
}
public enum SimulationRFPortKind: String, Codable, Sendable, CaseIterable { case lumped, wave }
public struct SimulationRFPort: Codable, Equatable, Sendable, Identifiable {
    public var id: Int
    public var boundaryID: String
    public var kind: SimulationRFPortKind
    public var mode: Int
    public var impedanceOhms: Double
    public var direction: SimulationVector3
    public var excitation: SimulationComplex
    public var referenceOffsetMeters: Double
    public init(id: Int, boundaryID: String, kind: SimulationRFPortKind = .lumped, mode: Int = 1, impedanceOhms: Double = 50, direction: SimulationVector3 = .init(1,0,0), excitation: SimulationComplex = .init(real: 1), referenceOffsetMeters: Double = 0) {
        self.id = id; self.boundaryID = boundaryID; self.kind = kind; self.mode = mode; self.impedanceOhms = impedanceOhms; self.direction = direction; self.excitation = excitation; self.referenceOffsetMeters = referenceOffsetMeters
    }
}
public struct SimulationCoil: Codable, Equatable, Sendable {
    public var regionID: String
    public var currentAmperes: SimulationComplex
    public var turns: Int
    public var direction: SimulationVector3
    public init(regionID: String, currentAmperes: SimulationComplex, turns: Int = 1, direction: SimulationVector3 = .init(0,0,1)) { self.regionID = regionID; self.currentAmperes = currentAmperes; self.turns = turns; self.direction = direction }
}
public struct ElectromagneticSimulationConfiguration: Codable, Equatable, Sendable {
    public var frequencies = SimulationFrequencySweep(frequenciesHz: [1e9])
    public var boundaries: [SimulationEMBoundary] = []
    public var ports: [SimulationRFPort] = []
    public var coils: [SimulationCoil] = []
    public var finiteElementOrder = 1
    public var requestedModes = 6
    public var relativeTolerance = 1e-8
    public var farFieldThetaRadians = stride(from: 0.0, through: Double.pi, by: Double.pi / 18).map { $0 }
    public var farFieldPhiRadians = stride(from: 0.0, to: Double.pi * 2, by: Double.pi / 18).map { $0 }
    public init() {}
    public func validate(for request: SimulationRequest) throws {
        try request.validate()
        guard let mesh = request.mesh else { throw SimulationError.invalidInput("Create an electromagnetic-domain mesh first.") }
        let ids = Set(mesh.boundaries.map(\.id)), regions = Set(mesh.elements.map(\.regionID))
        guard (1...6).contains(finiteElementOrder), requestedModes > 0, requestedModes <= 1000, relativeTolerance.isFinite, relativeTolerance > 0, relativeTolerance < 1,
              Set(ports.map(\.id)).count == ports.count, Set(ports.map(\.boundaryID)).count == ports.count,
              Set(boundaries.map(\.boundaryID)).count == boundaries.count,
              boundaries.allSatisfy({ ids.contains($0.boundaryID) && $0.value.isFinite }),
              ports.allSatisfy({ $0.id > 0 && ids.contains($0.boundaryID) && $0.mode > 0 && $0.impedanceOhms.isFinite && $0.impedanceOhms > 0 && $0.direction.isFinite && $0.direction.length > 0 && $0.excitation.isFinite && $0.referenceOffsetMeters.isFinite }),
              coils.allSatisfy({ regions.contains($0.regionID) && $0.turns > 0 && $0.currentAmperes.isFinite && $0.direction.isFinite && $0.direction.length > 0 }) else { throw SimulationError.invalidInput("Invalid electromagnetic boundary, coil or RF port.") }
        if [.eddyCurrent,.radioFrequency,.electromagneticModes,.antenna].contains(request.study.kind) { try frequencies.validate() }
        if [.radioFrequency,.antenna].contains(request.study.kind), !ports.contains(where: { $0.excitation.magnitude > 0 }) { throw SimulationError.invalidInput("Select an excited RF port.") }
        if request.study.kind == .antenna {
            guard !farFieldThetaRadians.isEmpty, !farFieldPhiRadians.isEmpty, farFieldThetaRadians.count * farFieldPhiRadians.count <= 100_000,
                  farFieldThetaRadians.allSatisfy({ $0.isFinite && (0...Double.pi).contains($0) }), farFieldPhiRadians.allSatisfy({ $0.isFinite && (0...(Double.pi*2)).contains($0) }) else { throw SimulationError.invalidInput("Invalid far-field angular sampling.") }
        }
        guard Set(request.study.materialAssignments.keys) == regions else { throw SimulationError.invalidInput("Assign electromagnetic materials to all regions.") }
    }
}
