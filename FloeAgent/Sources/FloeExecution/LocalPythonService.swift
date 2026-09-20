// FloeExecution — on-device Python execution seam (Linux guest backend).
//
// Phase 2 (TinyEMU migration): local Python runs inside the task
// environment's TinyEMU Linux guest (shared venv, real python3/pip). The
// bundled in-process CPython left the app; this actor keeps the stable
// `LocalPythonService`/`ScriptExecutionService` surface while the app injects
// the guest-routing runner. A request without a Linux-owned environment fails
// honestly instead of falling back to a host interpreter.

import Foundation
import FloeCore
import FloeTools

/// The guest bridge lives in FloeApp so SwiftPM can still build and test
/// FloeExecution on macOS. This actor provides the stable execution and
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

    /// Live manifest through the injected runner. Without a Linux-owned
    /// environment in the request context there is no interpreter to probe;
    /// the runner then answers with the honest unavailable outcome.
    public func runtimeManifest(environmentID: String? = nil) async -> String {
        if environmentID == nil, let cachedRuntimeManifest { return cachedRuntimeManifest }
        let request = ScriptExecutionRequest(
            script: LocalPythonCapabilityProbe.manifestScript,
            timeout: 15,
            maxOutputBytes: 4096,
            pythonContext: environmentID.map { .init(environmentID: $0) }
        )
        let result = await runner(request, nil)
        if case .ok(_, let stdout, _, false, _, _) = result,
           let object = try? JSONSerialization.jsonObject(with: Data(stdout.utf8)) as? [String: Any], object["python"] is String {
            let manifest = stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            if environmentID == nil { cachedRuntimeManifest = manifest }
            return manifest
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

/// Honest settings probe for the Linux-guest Python backend. Availability
/// means the backend exists and the guest component (image) is installed and
/// verified; the runtime manifest is a live guest probe when a Linux
/// environment is running, otherwise a static truthful statement.
public struct LocalPythonCapabilityProbe: CapabilityProbe {
    /// Backend/component state for the honest probe.
    public struct BackendStatus: Sendable, Equatable {
        public var backendPresent: Bool
        public var componentInstalled: Bool
        public var detail: String?

        public init(backendPresent: Bool, componentInstalled: Bool, detail: String? = nil) {
            self.backendPresent = backendPresent
            self.componentInstalled = componentInstalled
            self.detail = detail
        }
    }

    public let name = "python.local"
    private let service: LocalPythonService?
    private let backendStatus: @Sendable () async -> BackendStatus
    /// A currently running Linux environment usable for a live probe, when
    /// one exists. The manifest never starts a guest just to answer.
    private let liveProbeEnvironment: @Sendable () async -> String?

    public init(
        service: LocalPythonService?,
        backendStatus: (@Sendable () async -> BackendStatus)? = nil,
        liveProbeEnvironment: (@Sendable () async -> String?)? = nil
    ) {
        self.service = service
        self.backendStatus = backendStatus ?? { BackendStatus(backendPresent: service != nil, componentInstalled: service != nil) }
        self.liveProbeEnvironment = liveProbeEnvironment ?? { nil }
    }

    public func probe() async -> CapabilityState {
        guard let service else {
            return .unavailable(reason: "Local Python runs in the Linux guest component, which is not part of this build")
        }
        let status = await backendStatus()
        guard status.backendPresent else {
            return .unavailable(reason: "Local Python runs in the Linux guest component, which is not part of this build")
        }
        guard status.componentInstalled else {
            let detail = status.detail.map { " (\($0))" } ?? ""
            return .unavailable(reason: "Install the Linux component (Settings → Execution → Environments) to run Python on this device" + detail)
        }
        return .available(version: service.version)
    }

    public func runtimeManifest() async -> String {
        guard let service else {
            return "Local Python is unavailable in this build: it runs inside the per-environment Linux guest."
        }
        if let environmentID = await liveProbeEnvironment() {
            let probe = ScriptExecutionRequest(
                script: Self.manifestScript,
                timeout: 15,
                maxOutputBytes: 4096,
                pythonContext: .init(environmentID: environmentID)
            )
            let result = await service.run(probe, cancellation: nil)
            if case .ok(_, let stdout, _, false, _, _) = result,
               let object = try? JSONSerialization.jsonObject(with: Data(stdout.utf8)) as? [String: Any],
               object["python"] is String {
                return stdout.trimmingCharacters(in: .whitespacesAndNewlines)
                    + "\n(backend: Linux guest, environment \(environmentID))"
            }
            return "Linux guest probe did not complete; do not claim library availability."
        }
        return "Python runs inside each Linux environment's guest (Debian python3 with the environment's shared venv; pip installs per environment). Start a Linux environment to probe exact versions."
    }

    /// Live manifest script for a running guest: interpreter version plus the
    /// import state of the libraries skills commonly ask about.
    static let manifestScript = """
    import sys, json, importlib
    libraries = {}
    for name in ('numpy', 'PIL', 'lxml.etree', 'docx', 'pptx', 'pandas', 'scipy', 'matplotlib', 'regex', 'yaml', 'markupsafe', 'orjson', 'pydantic_core', 'zstandard', 'brotli', 'greenlet', 'frozenlist', 'multidict'):
        try:
            module = importlib.import_module(name)
            libraries[name] = {'available': True, 'version': getattr(module, '__version__', 'unknown')}
        except Exception as error:
            libraries[name] = {'available': False, 'errorType': type(error).__name__}
    print(json.dumps({'python': sys.version.split()[0], 'backend': 'linux-guest', 'libraries': libraries}, sort_keys=True))
    """
}

/// Honest settings probe for the Linux-guest Node.js backend. Availability
/// means the backend exists and the guest component (image) is installed and
/// verified; the guest's own apt provides nodejs/npm on first use.
public struct LocalNodeCapabilityProbe: CapabilityProbe {
    public let name = "node.local"
    private let backendStatus: @Sendable () async -> LocalPythonCapabilityProbe.BackendStatus

    public init(backendStatus: (@Sendable () async -> LocalPythonCapabilityProbe.BackendStatus)? = nil) {
        self.backendStatus = backendStatus ?? { .init(backendPresent: false, componentInstalled: false) }
    }

    public func probe() async -> CapabilityState {
        let status = await backendStatus()
        guard status.backendPresent else {
            return .unavailable(reason: "Local Node.js runs in the Linux guest component, which is not part of this build")
        }
        guard status.componentInstalled else {
            let detail = status.detail.map { " (\($0))" } ?? ""
            return .unavailable(reason: "Install the Linux component (Settings → Execution → Environments) to run Node.js on this device" + detail)
        }
        return .available(version: "Node.js (Linux guest, apt nodejs/npm per environment)")
    }
}
