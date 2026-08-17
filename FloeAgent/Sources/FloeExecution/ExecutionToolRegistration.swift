// FloeExecution — Execution tool registration entry point.
// See docs/ARCHITECTURE_EXECUTION.md §4/§10: same dual-registration seam
// as the workspace tools — the compile-time Descriptor goes to
// ToolCatalog, the runtime runner to ToolRunnerRegistry. Both are required
// for a call to execute; the runtime module never imports FloeExecution.

import Foundation
import FloeTools

/// Registers the compiled execution tools. Local JavaScript remains opt-in;
/// local Python is registered only when the app has supplied the bundled
/// CPython service.
///
/// - Parameters:
///   - registry: Runner registry to register into (defaults to the shared
///     process-wide registry used by `CatalogToolExecutor`).
///   - service: The JS execution backend (defaults to the real
///     JavaScriptCore service; tests inject fakes).
///   - pythonService: The remote Python backend. Nil leaves
///     `exec.remotePython` unregistered (honest absence: no runner).
///   - localPythonService: Bundled on-device CPython. Nil leaves
///     `exec.localPython` honestly absent from the catalog.
@discardableResult
public func registerExecutionTools(
    registry: ToolRunnerRegistry = .shared,
    service: any ScriptExecutionService = JavaScriptExecutionService(),
    pythonService: RemotePythonService? = nil,
    localPythonService: LocalPythonService? = nil,
    includeOnDeviceJavaScript: Bool = false
) -> any ScriptExecutionService {
    // Compile-time catalog descriptors.
    if includeOnDeviceJavaScript {
        ToolCatalog.register(JavaScriptExecutionTool.self)
    }
    if pythonService != nil {
        ToolCatalog.register(RemotePythonTool.self)
    }
    if localPythonService != nil {
        ToolCatalog.register(LocalPythonTool.self)
    }
    // Runtime runners.
    if includeOnDeviceJavaScript {
        registry.register(JavaScriptExecutionTool(service: service))
    }
    if let pythonService {
        registry.register(RemotePythonTool(service: pythonService))
    }
    if let localPythonService {
        registry.register(LocalPythonTool(service: localPythonService))
    }
    return service
}
