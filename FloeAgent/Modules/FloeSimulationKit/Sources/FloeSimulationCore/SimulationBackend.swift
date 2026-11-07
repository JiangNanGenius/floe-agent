import Foundation

/// A live host can fence native work against edits or closure of its source.
public typealias SimulationSourceValidator = @Sendable (SimulationSourceRef) async throws -> Void

public struct SimulationBackendDescriptor: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var version: String
    public var supportedStudies: Set<SimulationStudyKind>
    public var isAvailable: Bool
    public var unavailableReason: String?
    public init(id: String, version: String, supportedStudies: Set<SimulationStudyKind>, isAvailable: Bool, unavailableReason: String? = nil) {
        self.id = id; self.version = version; self.supportedStudies = supportedStudies; self.isAvailable = isAvailable; self.unavailableReason = unavailableReason
    }
}

public struct SimulationProgress: Codable, Equatable, Sendable {
    public var stage: String
    public var completed: Int?
    public var total: Int?
    public var residual: Double?
    public init(stage: String, completed: Int? = nil, total: Int? = nil, residual: Double? = nil) {
        self.stage = stage; self.completed = completed; self.total = total; self.residual = residual
    }
    public var fraction: Double? {
        guard let completed, let total, total > 0 else { return nil }
        return min(1, max(0, Double(completed) / Double(total)))
    }
}

public enum SimulationFieldLocation: String, Codable, Sendable { case node, element, integrationPoint, global }
public struct SimulationResultField: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var name: String
    public var unit: String
    public var location: SimulationFieldLocation
    public var components: Int
    public var values: [Double]
    /// Imaginary components use the same shape as values; nil denotes a real field.
    public var imaginaryValues: [Double]?
    public init(id: String, name: String, unit: String, location: SimulationFieldLocation, components: Int, values: [Double], imaginaryValues: [Double]? = nil) {
        self.id = id; self.name = name; self.unit = unit; self.location = location; self.components = components; self.values = values; self.imaginaryValues = imaginaryValues
    }
    public func validate() throws {
        guard !id.isEmpty, components > 0, !values.isEmpty, values.count % components == 0, values.allSatisfy(\.isFinite),
              imaginaryValues.map({ $0.count == values.count && $0.allSatisfy(\.isFinite) }) ?? true else { throw SimulationError.solverFailure("The backend returned an invalid result field.") }
    }
}

public struct SimulationResultFrame: Codable, Equatable, Sendable, Identifiable {
    public var id: Int
    public var timeSeconds: Double?
    public var frequencyHz: Double?
    public var fields: [SimulationResultField]
    public init(id: Int, timeSeconds: Double? = nil, frequencyHz: Double? = nil, fields: [SimulationResultField]) {
        self.id = id; self.timeSeconds = timeSeconds; self.frequencyHz = frequencyHz; self.fields = fields
    }
}

public struct SimulationResult: Codable, Equatable, Sendable, Identifiable {
    public var id: UUID
    public var requestID: UUID
    public var source: SimulationSourceRef
    public var studyID: UUID
    public var studyRevision: UInt64
    public var backend: SimulationBackendDescriptor
    public var mesh: SimulationMesh?
    public var frames: [SimulationResultFrame]
    public var diagnostics: [String: String]
    public init(id: UUID = UUID(), requestID: UUID, source: SimulationSourceRef, studyID: UUID, studyRevision: UInt64 = 0, backend: SimulationBackendDescriptor, mesh: SimulationMesh? = nil, frames: [SimulationResultFrame], diagnostics: [String: String] = [:]) {
        self.id = id; self.requestID = requestID; self.source = source; self.studyID = studyID; self.studyRevision = studyRevision; self.backend = backend; self.mesh = mesh; self.frames = frames; self.diagnostics = diagnostics
    }
    public func validate(for request: SimulationRequest) throws {
        guard requestID == request.id, source == request.source, studyID == request.study.id, studyRevision == request.study.revision else { throw SimulationError.staleSource }
        guard backend.isAvailable, backend.supportedStudies.contains(request.study.kind), !frames.isEmpty else { throw SimulationError.solverFailure("The result has no executable backend or frames.") }
        guard Set(frames.map(\.id)).count == frames.count else { throw SimulationError.solverFailure("Result frame identities must be unique.") }
        if let mesh {
            try mesh.validate(); guard mesh.source == source else { throw SimulationError.staleSource }
        }
        var valueCount = 0
        for frame in frames {
            guard frame.timeSeconds.map({ $0.isFinite && $0 >= 0 }) ?? true, frame.frequencyHz.map({ $0.isFinite && $0 >= 0 }) ?? true,
                  !frame.fields.isEmpty, Set(frame.fields.map(\.id)).count == frame.fields.count else { throw SimulationError.solverFailure("A result frame is invalid.") }
            for field in frame.fields {
                try field.validate()
                if let mesh = mesh ?? request.mesh {
                    if field.location == .node, field.values.count / field.components != mesh.nodes.count { throw SimulationError.solverFailure("A nodal result has the wrong shape.") }
                    if field.location == .element, field.values.count / field.components != mesh.elements.count { throw SimulationError.solverFailure("An element result has the wrong shape.") }
                }
                let (count, overflow) = valueCount.addingReportingOverflow(field.values.count)
                guard !overflow, count <= request.budget.maximumResultValues else { throw SimulationError.resourceLimit("The result exceeds this study's resource budget.") }
                valueCount = count
                if let imaginary = field.imaginaryValues {
                    let (count, overflow) = valueCount.addingReportingOverflow(imaginary.count)
                    guard !overflow, count <= request.budget.maximumResultValues else { throw SimulationError.resourceLimit("The complex result exceeds this study's resource budget.") }
                    valueCount = count
                }
            }
        }
    }
}

public typealias SimulationProgressHandler = @Sendable (SimulationProgress) async -> Void

public protocol SimulationBackend: Sendable {
    var descriptor: SimulationBackendDescriptor { get }
    func validate(_ request: SimulationRequest) throws
    func solve(_ request: SimulationRequest, progress: @escaping SimulationProgressHandler) async throws -> SimulationResult
}

public extension SimulationBackend {
    func validate(_ request: SimulationRequest) throws {
        try request.validate()
        guard descriptor.isAvailable else { throw SimulationError.backendUnavailable(descriptor.unavailableReason ?? descriptor.id) }
        guard descriptor.supportedStudies.contains(request.study.kind) else { throw SimulationError.unsupported(request.study.kind.rawValue) }
    }
}
