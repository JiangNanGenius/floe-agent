// FloeExecution — bundled, on-device CPython execution seam.

import Foundation
import FloeCore
import FloeTools

/// The XCFramework bridge lives in FloeApp so SwiftPM can still build and
/// test FloeExecution on macOS. This actor provides the stable execution and
/// capability-probe surface while the iOS app injects the concrete runner.
public actor LocalPythonService: ScriptExecutionService {
    public typealias Runner = @Sendable (
        _ request: ScriptExecutionRequest,
        _ cancellation: CancellationToken?
    ) async -> ScriptExecutionOutcome

    private let runtimeVersion: String
    private let runner: Runner

    public init(version: String, runner: @escaping Runner) {
        self.runtimeVersion = version
        self.runner = runner
    }

    public nonisolated var version: String { runtimeVersion }

    public func run(
        _ request: ScriptExecutionRequest,
        cancellation: CancellationToken?
    ) async -> ScriptExecutionOutcome {
        if cancellation?.isCancelled == true { return .cancelled }
        return await runner(request, cancellation)
    }
}

/// Honest settings probe backed by the same service registered as a tool.
public struct LocalPythonCapabilityProbe: CapabilityProbe {
    public let name = "python.local"
    private let service: LocalPythonService?

    public init(service: LocalPythonService?) {
        self.service = service
    }

    public func probe() async -> CapabilityState {
        guard let service else {
            return .unavailable(reason: "Bundled CPython runtime is not installed in this build")
        }
        return .available(version: service.version)
    }
}
