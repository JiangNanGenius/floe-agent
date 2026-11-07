import FloeSimulationCore

public enum SimulationFieldDomain: String, Sendable, CaseIterable {
    case flow, acoustics, electromagnetics
    public var studies: Set<SimulationStudyKind> {
        switch self {
        case .flow: [.incompressibleFlow,.compressibleFlow,.turbulentFlow]
        case .acoustics: [.pressureAcoustics]
        case .electromagnetics: [.electrostatic,.magnetostatic,.eddyCurrent,.radioFrequency,.electromagneticModes,.antenna]
        }
    }
    public var library: String { switch self { case .flow: "SU2"; case .acoustics: "MFEM"; case .electromagnetics: "MFEM/Palace" } }
}

public struct NativeFieldsSimulationBackend: SimulationBackend {
    public var domain: SimulationFieldDomain
    private let driver: (any SimulationNativeDriver)?
    public init(domain: SimulationFieldDomain, driver: (any SimulationNativeDriver)? = nil) { self.domain = domain; self.driver = driver }
    public var descriptor: SimulationBackendDescriptor {
        driver?.descriptor ?? .init(id: "floe.fields." + domain.rawValue, version: "1", supportedStudies: domain.studies, isAvailable: false, unavailableReason: "The \(domain.library) native artifact is not linked in this host.")
    }
    public func validate(_ request: SimulationRequest) throws {
        guard domain.studies.contains(request.study.kind) else { throw SimulationError.unsupported(request.study.kind.rawValue) }
        switch domain {
        case .flow: try request.study.configuration(as: FlowSimulationConfiguration.self).validate(for: request)
        case .acoustics: try request.study.configuration(as: AcousticSimulationConfiguration.self).validate(for: request)
        case .electromagnetics: try request.study.configuration(as: ElectromagneticSimulationConfiguration.self).validate(for: request)
        }
        guard descriptor.isAvailable else { throw SimulationError.backendUnavailable(descriptor.unavailableReason ?? descriptor.id) }
        guard descriptor.supportedStudies.contains(request.study.kind) else { throw SimulationError.unsupported(request.study.kind.rawValue) }
    }
    public func solve(_ request: SimulationRequest, progress: @escaping SimulationProgressHandler) async throws -> SimulationResult {
        try validate(request); try Task.checkCancellation()
        guard let driver else { throw SimulationError.backendUnavailable(descriptor.id) }
        let result = try await driver.execute(request, progress: progress)
        try Task.checkCancellation(); try result.validate(for: request); return result
    }
}
