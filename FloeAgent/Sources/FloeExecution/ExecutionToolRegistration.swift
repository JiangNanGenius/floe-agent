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
    cloudWorkspaceService: CloudWorkspaceService? = nil,
    remoteHostStore: RemoteHostStore? = nil,
    vncPasswordWriter: VNCPasswordWriter? = nil,
    vncPasswordDeleter: VNCPasswordDeleter? = nil,
    remoteHostUpdateObserver: RemoteHostUpdateObserver? = nil,
    bluetoothSerialService: (any BluetoothSerialServicing)? = nil,
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
        ToolCatalog.register(SSHRemoteTaskStatusTool.self)
        ToolCatalog.register(SSHInspectTargetTool.self)
        ToolCatalog.register(SSHBootstrapExecutionHostTool.self)
        ToolCatalog.register(SSHBootstrapRemoteAgentTool.self)
        ToolCatalog.register(CloudWorkspaceListTool.self)
        ToolCatalog.register(CloudWorkspaceReadTool.self)
        ToolCatalog.register(CloudWorkspaceWriteTool.self)
        ToolCatalog.register(CloudWorkspaceCreateDirectoryTool.self)
        ToolCatalog.register(CloudWorkspaceProvisionTool.self)
        ToolCatalog.register(CloudWorkspaceCatalogTool.self)
        ToolCatalog.register(CloudWorkspaceGitStatusTool.self)
        ToolCatalog.register(CloudWorkspaceGitDiffTool.self)
        ToolCatalog.register(CloudWorkspaceGitLogTool.self)
        ToolCatalog.register(CloudWorkspaceGitInitializeTool.self)
        ToolCatalog.register(CloudWorkspaceGitStageTool.self)
        ToolCatalog.register(CloudWorkspaceGitCommitTool.self)
        ToolCatalog.register(CloudWorkspaceGitFetchTool.self)
        ToolCatalog.register(CloudWorkspaceGitPullTool.self)
        ToolCatalog.register(CloudWorkspaceGitPushTool.self)
        ToolCatalog.register(CloudWorkspaceGitBranchTool.self)
        ToolCatalog.register(RemoteHostingInspectTool.self)
        ToolCatalog.register(RemoteHostingManageTool.self)
    }
    if remoteHostStore != nil {
        ToolCatalog.register(SSHListHostsTool.self)
        ToolCatalog.register(SSHUpdateHostTool.self)
        ToolCatalog.register(RemoteConnectionOpenTool.self)
        ToolCatalog.register(RemoteConnectionExchangeTool.self)
        ToolCatalog.register(RemoteConnectionCloseTool.self)
    }
    if bluetoothSerialService != nil, remoteHostStore != nil {
        ToolCatalog.register(BluetoothSerialScanTool.self)
        ToolCatalog.register(BluetoothSerialOpenTool.self)
        ToolCatalog.register(BluetoothSerialExchangeTool.self)
        ToolCatalog.register(BluetoothSerialCloseTool.self)
    }
    ToolCatalog.register(HTTPRequestTool.self)
    ToolCatalog.register(WebSearchTool.self)
    ToolCatalog.register(BochaAISearchTool.self)
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
        let cloudWorkspaceService = cloudWorkspaceService ?? CloudWorkspaceService(
            ssh: sshCommandService,
            readiness: RemoteAgentReadinessCoordinator(
                manager: RemoteAgentInstaller(service: sshCommandService)
            )
        )
        let remoteAgent = RemoteAgentTaskService(client: cloudWorkspaceService)
        registry.register(SSHExecTool(
            service: sshCommandService,
            remoteAgent: remoteAgent
        ))
        registry.register(SSHRemoteTaskStatusTool(remoteAgent: remoteAgent))
        registry.register(SSHInspectTargetTool(service: sshCommandService))
        registry.register(SSHBootstrapExecutionHostTool(service: sshCommandService))
        registry.register(SSHBootstrapRemoteAgentTool(service: sshCommandService))
        registry.register(CloudWorkspaceListTool(service: cloudWorkspaceService))
        registry.register(CloudWorkspaceReadTool(service: cloudWorkspaceService))
        registry.register(CloudWorkspaceWriteTool(service: cloudWorkspaceService))
        registry.register(CloudWorkspaceCreateDirectoryTool(service: cloudWorkspaceService))
        registry.register(CloudWorkspaceProvisionTool(service: cloudWorkspaceService))
        registry.register(CloudWorkspaceCatalogTool(service: cloudWorkspaceService))
        registry.register(CloudWorkspaceGitStatusTool(service: cloudWorkspaceService))
        registry.register(CloudWorkspaceGitDiffTool(service: cloudWorkspaceService))
        registry.register(CloudWorkspaceGitLogTool(service: cloudWorkspaceService))
        registry.register(CloudWorkspaceGitInitializeTool(service: cloudWorkspaceService))
        registry.register(CloudWorkspaceGitStageTool(service: cloudWorkspaceService))
        registry.register(CloudWorkspaceGitCommitTool(service: cloudWorkspaceService))
        registry.register(CloudWorkspaceGitFetchTool(service: cloudWorkspaceService))
        registry.register(CloudWorkspaceGitPullTool(service: cloudWorkspaceService))
        registry.register(CloudWorkspaceGitPushTool(service: cloudWorkspaceService))
        registry.register(CloudWorkspaceGitBranchTool(service: cloudWorkspaceService))
        registry.register(RemoteHostingInspectTool(service: cloudWorkspaceService))
        registry.register(RemoteHostingManageTool(service: cloudWorkspaceService))
    }
    if let remoteHostStore {
        registry.register(SSHListHostsTool(store: remoteHostStore))
        registry.register(SSHUpdateHostTool(
            store: remoteHostStore,
            passwordWriter: vncPasswordWriter,
            passwordDeleter: vncPasswordDeleter,
            updateObserver: remoteHostUpdateObserver
        ))
        let rawConnections = RawRemoteConnectionService()
        registry.register(RemoteConnectionOpenTool(service: rawConnections, store: remoteHostStore))
        registry.register(RemoteConnectionExchangeTool(service: rawConnections))
        registry.register(RemoteConnectionCloseTool(service: rawConnections))
    }
    if let bluetoothSerialService, let remoteHostStore {
        registry.register(BluetoothSerialScanTool(service: bluetoothSerialService))
        registry.register(BluetoothSerialOpenTool(service: bluetoothSerialService, store: remoteHostStore))
        registry.register(BluetoothSerialExchangeTool(service: bluetoothSerialService))
        registry.register(BluetoothSerialCloseTool(service: bluetoothSerialService))
    }
    registry.register(HTTPRequestTool(service: httpRequestService))
    registry.register(WebSearchTool(service: webSearchService))
    registry.register(BochaAISearchTool(service: webSearchService))
    registry.register(WebFetchTool(service: httpRequestService))
    registry.register(NetworkScanLANTool(service: LANDiscoveryService()))
    registry.register(OCRTool())
    registry.register(BarcodeScanTool())
    registry.register(SVGDocumentTool())
    registry.register(LocalNumericalCompatibilityTool())
    registry.register(PresentationArtifactTool())
    return service
}
