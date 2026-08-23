// FloeExecution — Execution tool registration entry point.
// See docs/ARCHITECTURE_EXECUTION.md §4/§10: same dual-registration seam
// as the workspace tools — the compile-time Descriptor goes to
// ToolCatalog, the runtime runner to ToolRunnerRegistry. Both are required
// for a call to execute; the runtime module never imports FloeExecution.

import Foundation
import FloeTools
import FloePersistence

/// Registers the compiled execution tools. Local JavaScript remains opt-in;
/// local Python is registered only when the app has supplied the bundled
/// CPython service. Remote Python is intentionally absent — `ssh.execute`
/// covers it (run `python3 -c "..."` or pipe a script via stdin).
///
/// - Parameters:
///   - registry: Runner registry to register into (defaults to the shared
///     process-wide registry used by `CatalogToolExecutor`).
///   - service: The JS execution backend (defaults to the real
///     JavaScriptCore service; tests inject fakes).
///   - localPythonService: Bundled on-device CPython. Nil leaves
///     `exec.localPython` honestly absent from the catalog.
///   - sshCommandService: SSH command execution backend. Nil leaves
///     `ssh.execute` unregistered.
///   - includeStandaloneWasmTool: Internal/testing escape hatch for the raw
///     WASM runner. Production keeps this false: installed plugins should
///     expose concrete capabilities instead of teaching the main model to
///     fabricate or compile modules.
@discardableResult
public func registerExecutionTools(
    registry: ToolRunnerRegistry = .shared,
    service: any ScriptExecutionService = JavaScriptExecutionService(),
    localPythonService: LocalPythonService? = nil,
    sshCommandService: SSHCommandService? = nil,
    remoteHostStore: RemoteHostStore? = nil,
    httpRequestService: HTTPRequestService = HTTPRequestService(),
    webSearchService: WebSearchService = WebSearchService(),
    includeOnDeviceJavaScript: Bool = false,
    includeStandaloneWasmTool: Bool = false
) -> any ScriptExecutionService {
    // Compile-time catalog descriptors.
    if includeOnDeviceJavaScript {
        ToolCatalog.register(JavaScriptExecutionTool.self)
    }
    if includeStandaloneWasmTool {
        ToolCatalog.register(WasmExecutionTool.self)
    }
    if localPythonService != nil {
        ToolCatalog.register(LocalPythonTool.self)
    }
    if sshCommandService != nil {
        ToolCatalog.register(SSHExecTool.self)
        ToolCatalog.register(SSHInspectTargetTool.self)
        ToolCatalog.register(SSHBootstrapExecutionHostTool.self)
    }
    if remoteHostStore != nil {
        ToolCatalog.register(SSHListHostsTool.self)
        ToolCatalog.register(SSHUpdateHostTool.self)
    }
    ToolCatalog.register(HTTPRequestTool.self)
    ToolCatalog.register(WebSearchTool.self)
    ToolCatalog.register(WebFetchTool.self)
    ToolCatalog.register(NetworkScanLANTool.self)
    ToolCatalog.register(OCRTool.self)
    ToolCatalog.register(BarcodeScanTool.self)
    ToolCatalog.register(SVGDocumentTool.self)
    ToolCatalog.register(LocalNumericalCompatibilityTool.self)
    ToolCatalog.register(PresentationArtifactTool.self)
    // Runtime runners.
    if includeOnDeviceJavaScript {
        registry.register(JavaScriptExecutionTool(service: service))
    }
    if includeStandaloneWasmTool {
        registry.register(WasmExecutionTool(service: service))
    }
    if let localPythonService {
        registry.register(LocalPythonTool(service: localPythonService))
    }
    if let sshCommandService {
        registry.register(SSHExecTool(service: sshCommandService))
        registry.register(SSHInspectTargetTool(service: sshCommandService))
        registry.register(SSHBootstrapExecutionHostTool(service: sshCommandService))
    }
    if let remoteHostStore {
        registry.register(SSHListHostsTool(store: remoteHostStore))
        registry.register(SSHUpdateHostTool(store: remoteHostStore))
    }
    registry.register(HTTPRequestTool(service: httpRequestService))
    registry.register(WebSearchTool(service: webSearchService))
    registry.register(WebFetchTool(service: httpRequestService))
    registry.register(NetworkScanLANTool(service: LANDiscoveryService()))
    registry.register(OCRTool())
    registry.register(BarcodeScanTool())
    registry.register(SVGDocumentTool())
    registry.register(LocalNumericalCompatibilityTool())
    registry.register(PresentationArtifactTool())
    return service
}
