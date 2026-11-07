import FloeSimulationCore

public struct NativeEngineeringSimulationBackend: SimulationBackend {
    private let driver: (any SimulationNativeDriver)?
    public static let studies: Set<SimulationStudyKind> = [.structuralStatic,.beamShell,.laminate,.modal,.buckling,.nonlinearContact,.thermalSteady,.thermalTransient,.thermalStress]
    public init(driver: (any SimulationNativeDriver)? = nil) { self.driver = driver }
    public var descriptor: SimulationBackendDescriptor {
        driver?.descriptor ?? .init(id: "floe.engineering.native", version: "1", supportedStudies: Self.studies, isAvailable: false, unavailableReason: "The FEBio/Chrono native artifacts are not linked in this host.")
    }
    public func validate(_ request: SimulationRequest) throws {
        try request.study.configuration(as: EngineeringSimulationConfiguration.self).validate(for: request)
        guard descriptor.isAvailable else { throw SimulationError.backendUnavailable(descriptor.unavailableReason ?? descriptor.id) }
        guard Self.studies.contains(request.study.kind), descriptor.supportedStudies.contains(request.study.kind) else { throw SimulationError.unsupported(request.study.kind.rawValue) }
    }
    public func solve(_ request: SimulationRequest, progress: @escaping SimulationProgressHandler) async throws -> SimulationResult {
        try validate(request); try Task.checkCancellation()
        guard let driver else { throw SimulationError.backendUnavailable(descriptor.id) }
        let result = try await driver.execute(request, progress: progress)
        try Task.checkCancellation(); try result.validate(for: request); return result
    }
}
