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
    private var cachedRuntimeManifest: String?

    public init(version: String, runner: @escaping Runner) {
        self.runtimeVersion = version
        self.runner = runner
    }

    public nonisolated var version: String { runtimeVersion }

    public func runtimeManifest() async -> String {
        if let cachedRuntimeManifest { return cachedRuntimeManifest }
        let request = ScriptExecutionRequest(script: """
        import sys, json, importlib
        libraries = {}
        for name in ('numpy', 'PIL'):
            try:
                module = importlib.import_module(name)
                libraries[name] = {'available': True, 'version': getattr(module, '__version__', 'unknown')}
            except ImportError:
                libraries[name] = {'available': False}
        print(json.dumps({'python': sys.version.split()[0], 'libraries': libraries}, sort_keys=True))
        """, timeout: 10, maxOutputBytes: 4096)
        let result = await runner(request, nil)
        if case .ok(_, let stdout, _, false, _, _) = result,
           let object = try? JSONSerialization.jsonObject(with: Data(stdout.utf8)) as? [String: Any], object["python"] is String {
            cachedRuntimeManifest = stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            return cachedRuntimeManifest!
        }
        return "Runtime probe did not complete; do not claim library availability."
    }

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

    public func runtimeManifest() async -> String {
        guard let service else { return "Bundled Python runtime unavailable in this build." }
        return await service.runtimeManifest()
    }
}
