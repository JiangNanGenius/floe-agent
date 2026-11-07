import Foundation
import FloeSimulationCore

public enum SimulationCouplingKind: String, Codable, Sendable, CaseIterable { case thermalStress, conjugateHeatTransfer, fluidStructure, structuralAcoustics }
public struct SimulationInterfaceWeight: Codable, Equatable, Sendable {
    public var sourceNode: Int
    public var weight: Double
    public init(sourceNode: Int, weight: Double) { self.sourceNode = sourceNode; self.weight = weight }
}
public struct SimulationInterfaceMap: Codable, Equatable, Sendable {
    public var sourceMeshID: UUID
    public var destinationMeshID: UUID
    public var sourceNodeCount: Int
    public var destinationNodeIndices: [Int]
    /// Destination nodes in interface order; each row sums to one.
    public var rows: [[SimulationInterfaceWeight]]
    public init(sourceMeshID: UUID, destinationMeshID: UUID, sourceNodeCount: Int, rows: [[SimulationInterfaceWeight]], destinationNodeIndices: [Int]? = nil) {
        self.sourceMeshID = sourceMeshID; self.destinationMeshID = destinationMeshID; self.sourceNodeCount = sourceNodeCount; self.rows = rows; self.destinationNodeIndices = destinationNodeIndices ?? Array(rows.indices)
    }
    public func validate() throws {
        guard sourceNodeCount > 0, !rows.isEmpty, rows.count <= 200_000, destinationNodeIndices.count == rows.count, Set(destinationNodeIndices).count == rows.count, destinationNodeIndices.allSatisfy({ $0 >= 0 }),
              rows.allSatisfy({ !$0.isEmpty && $0.count <= 64 && Set($0.map(\.sourceNode)).count == $0.count && $0.allSatisfy({ (0..<sourceNodeCount).contains($0.sourceNode) && $0.weight.isFinite && $0.weight >= 0 }) && abs($0.reduce(0) { $0 + $1.weight } - 1) < 1e-10 }) else { throw SimulationError.invalidInput("Invalid interface interpolation weights or node identities.") }
    }
    public func interpolate(_ source: [SimulationVector3]) throws -> [SimulationVector3] {
        try validate()
        guard source.count == sourceNodeCount, source.allSatisfy(\.isFinite) else { throw SimulationError.invalidInput("The interface source field has an invalid shape.") }
        return rows.map { row in row.reduce(.zero) { $0 + source[$1.sourceNode] * $1.weight } }
    }
    /// Adjoint transfer preserves total interface load and virtual work.
    public func transferLoads(_ destinationLoads: [SimulationVector3]) throws -> [SimulationVector3] {
        try validate()
        guard destinationLoads.count == rows.count, destinationLoads.allSatisfy(\.isFinite) else { throw SimulationError.invalidInput("The interface load field has an invalid shape.") }
        var source = [SimulationVector3](repeating: .zero, count: sourceNodeCount)
        for (index,row) in rows.enumerated() { for entry in row { source[entry.sourceNode] = source[entry.sourceNode] + destinationLoads[index] * entry.weight } }
        return source
    }
}
public struct CoupledSimulationConfiguration: Codable, Equatable, Sendable {
    public var kind: SimulationCouplingKind
    public var firstStudyID: UUID
    public var secondStudyID: UUID
    public var firstBoundaryID: String = ""
    public var secondBoundaryID: String = ""
    public var interface: SimulationInterfaceMap
    public var time: SimulationTimeSettings
    public var maximumIterations: Int
    public var relativeTolerance: Double
    public var absoluteTolerance: Double
    public var relaxation: Double
    public init(kind: SimulationCouplingKind, firstStudyID: UUID, secondStudyID: UUID, interface: SimulationInterfaceMap, time: SimulationTimeSettings = .init(durationSeconds: 1, stepSeconds: 0.01, outputIntervalSeconds: 0.01), maximumIterations: Int = 50, relativeTolerance: Double = 1e-6, absoluteTolerance: Double = 1e-10, relaxation: Double = 0.5) {
        self.kind = kind; self.firstStudyID = firstStudyID; self.secondStudyID = secondStudyID; self.interface = interface; self.time = time; self.maximumIterations = maximumIterations; self.relativeTolerance = relativeTolerance; self.absoluteTolerance = absoluteTolerance; self.relaxation = relaxation
    }
    public func validate() throws {
        try interface.validate(); try time.validate(maximumSteps: 100_000)
        guard firstStudyID != secondStudyID, maximumIterations > 0, maximumIterations <= 10_000,
              relativeTolerance.isFinite, relativeTolerance > 0, relativeTolerance < 1,
              absoluteTolerance.isFinite, absoluteTolerance > 0, relaxation.isFinite, relaxation > 0, relaxation <= 1 else { throw SimulationError.invalidInput("Invalid coupled studies, iteration settings or relaxation.") }
    }
}

public struct SimulationCouplingExchange: Sendable {
    public var sourceMeshID: UUID
    public var values: [SimulationVector3]
    public var unit: String
    public var nodeIndices: [Int]
    public init(sourceMeshID: UUID, values: [SimulationVector3], unit: String, nodeIndices: [Int]? = nil) { self.sourceMeshID = sourceMeshID; self.values = values; self.unit = unit; self.nodeIndices = nodeIndices ?? Array(values.indices) }
}
public protocol SimulationCoupledParticipant: Sendable {
    var source: SimulationSourceRef { get }
    /// A trial restores the participant's current step checkpoint before solving;
    /// iteration never advances physical time more than once.
    func trial(timeSeconds: Double, stepSeconds: Double, input: SimulationCouplingExchange) async throws -> SimulationCouplingExchange
    func commitStep() async throws
    func rollbackStep() async
}
public struct SimulationCouplingStep: Sendable {
    public var timeSeconds: Double
    public var iterations: Int
    public var residual: Double
    public var displacements: [SimulationVector3]
    public var interfaceLoads: [SimulationVector3]
}

/// Strong partitioned displacement/force coupling. Heat and acoustic adapters
/// supply their own typed exchange laws rather than reusing mechanical units.
public enum SimulationFluidStructureCoupler {
    public static func run(configuration: CoupledSimulationConfiguration, structure: any SimulationCoupledParticipant, fluid: any SimulationCoupledParticipant, initialDisplacements: [SimulationVector3], progress: @escaping SimulationProgressHandler) async throws -> [SimulationCouplingStep] {
        try configuration.validate()
        guard configuration.kind == .fluidStructure, structure.source == fluid.source, initialDisplacements.count == configuration.interface.sourceNodeCount else { throw SimulationError.invalidInput("The fluid/structure source or interface is incompatible.") }
        let mapping = configuration.interface
        let count = Int(ceil(configuration.time.durationSeconds / configuration.time.stepSeconds))
        var displacement = initialDisplacements, completed: [SimulationCouplingStep] = []
        for step in 0..<count {
            try Task.checkCancellation()
            let time = min(Double(step+1) * configuration.time.stepSeconds, configuration.time.durationSeconds)
            let dt = time - Double(step) * configuration.time.stepSeconds
            do {
                var converged: SimulationCouplingStep?
                for iteration in 0..<configuration.maximumIterations {
                    try Task.checkCancellation()
                    let moved = try mapping.interpolate(displacement)
                    let fluidResult = try await fluid.trial(timeSeconds: time, stepSeconds: dt, input: .init(sourceMeshID: mapping.destinationMeshID, values: moved, unit: "m", nodeIndices:mapping.destinationNodeIndices))
                    guard fluidResult.sourceMeshID == mapping.destinationMeshID, fluidResult.unit == "N", fluidResult.nodeIndices == mapping.destinationNodeIndices else { throw SimulationError.solverFailure("Fluid interface forces have invalid units or mesh identity.") }
                    let loads = try mapping.transferLoads(fluidResult.values)
                    let structuralResult = try await structure.trial(timeSeconds: time, stepSeconds: dt, input: .init(sourceMeshID: mapping.sourceMeshID, values: loads, unit: "N"))
                    guard structuralResult.sourceMeshID == mapping.sourceMeshID, structuralResult.unit == "m", structuralResult.values.count == displacement.count, structuralResult.values.allSatisfy(\.isFinite) else { throw SimulationError.solverFailure("Structural interface displacements have invalid units, values or mesh identity.") }
                    let difference = zip(structuralResult.values,displacement).map(-)
                    let norm = sqrt(difference.reduce(0) { $0 + $1.dot($1) })
                    let reference = sqrt(structuralResult.values.reduce(0) { $0 + $1.dot($1) })
                    await progress(.init(stage: "coupling", completed: step, total: count, residual: norm))
                    if norm <= max(configuration.absoluteTolerance, configuration.relativeTolerance * reference) {
                        displacement = structuralResult.values
                        converged = .init(timeSeconds: time, iterations: iteration+1, residual: norm, displacements: displacement, interfaceLoads: loads)
                        break
                    }
                    displacement = zip(displacement,structuralResult.values).map { $0 + ($1-$0) * configuration.relaxation }
                }
                guard let result = converged else { throw SimulationError.solverFailure("The fluid/structure interface did not converge at time \(time).") }
                try Task.checkCancellation()
                try await structure.commitStep(); try await fluid.commitStep(); completed.append(result)
            } catch { await structure.rollbackStep(); await fluid.rollbackStep(); throw error }
        }
        return completed
    }
}
