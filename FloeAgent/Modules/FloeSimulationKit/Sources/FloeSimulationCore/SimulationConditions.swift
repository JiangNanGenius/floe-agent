import Foundation

public enum SimulationSelection: Codable, Equatable, Sendable {
    case nodes([Int]), boundary(String), region(String)
    public func resolveNodes(in mesh: SimulationMesh) throws -> [Int] {
        let indices: [Int]
        switch self {
        case .nodes(let values): indices = values
        case .boundary(let id):
            guard let boundary = mesh.boundaries.first(where: { $0.id == id }) else { throw SimulationError.invalidInput("The selected boundary is missing.") }
            indices = boundary.nodeIndices
        case .region(let id): indices = mesh.elements.filter { $0.regionID == id }.flatMap(\.nodes)
        }
        guard !indices.isEmpty, indices.allSatisfy({ mesh.nodes.indices.contains($0) }) else { throw SimulationError.invalidInput("The selection has no valid mesh nodes.") }
        return Set(indices).sorted()
    }
}

public struct SimulationScalarCondition: Codable, Equatable, Sendable, Identifiable {
    public var id: UUID
    public var selection: SimulationSelection
    public var value: Double
    public init(id: UUID = UUID(), selection: SimulationSelection, value: Double) { self.id = id; self.selection = selection; self.value = value }
}

public struct SimulationVectorCondition: Codable, Equatable, Sendable, Identifiable {
    public var id: UUID
    public var selection: SimulationSelection
    public var value: SimulationVector3
    public init(id: UUID = UUID(), selection: SimulationSelection, value: SimulationVector3) { self.id = id; self.selection = selection; self.value = value }
}

public struct SimulationTimeSettings: Codable, Equatable, Sendable {
    public var durationSeconds: Double
    public var stepSeconds: Double
    public var outputIntervalSeconds: Double
    public init(durationSeconds: Double = 1, stepSeconds: Double = 1.0 / 240, outputIntervalSeconds: Double = 1.0 / 30) {
        self.durationSeconds = durationSeconds; self.stepSeconds = stepSeconds; self.outputIntervalSeconds = outputIntervalSeconds
    }
    public func validate(maximumSteps: Int) throws {
        guard durationSeconds.isFinite, durationSeconds > 0, stepSeconds.isFinite, stepSeconds > 0,
              outputIntervalSeconds.isFinite, outputIntervalSeconds >= stepSeconds,
              ceil(durationSeconds / stepSeconds) <= Double(maximumSteps) else { throw SimulationError.invalidInput("Invalid simulation time range, step, output interval, or step budget.") }
    }
}

public struct SimulationFrequencySweep: Codable, Equatable, Sendable {
    public var frequenciesHz: [Double]
    public init(frequenciesHz: [Double] = [1000]) { self.frequenciesHz = frequenciesHz }
    public func validate(maximumPoints: Int = 1000, allowsZero: Bool = false) throws {
        guard !frequenciesHz.isEmpty, frequenciesHz.count <= maximumPoints,
              frequenciesHz.allSatisfy({ $0.isFinite && (allowsZero ? $0 >= 0 : $0 > 0) }),
              zip(frequenciesHz, frequenciesHz.dropFirst()).allSatisfy({ $0 < $1 }) else { throw SimulationError.invalidInput("Frequencies must be finite, positive, unique and increasing within the sweep budget.") }
    }
}

/// Native implementations are injected only after linking their fixed artifacts.
/// Domain adapters validate full configuration before passing it to this driver.
public protocol SimulationNativeDriver: Sendable {
    var descriptor: SimulationBackendDescriptor { get }
    func execute(_ request: SimulationRequest, progress: @escaping SimulationProgressHandler) async throws -> SimulationResult
}
