// FloeExecution — Execution tool registration entry point.
// See docs/ARCHITECTURE_EXECUTION.md §4/§10: same dual-registration seam
// as the workspace tools — the compile-time Descriptor goes to
// ToolCatalog, the runtime runner to ToolRunnerRegistry. Both are required
// for a call to execute; the runtime module never imports FloeExecution.

import Foundation
import FloeTools

/// Registers the execution tools: `exec.javascript` always, plus
/// `exec.remotePython` when a `RemotePythonService` is supplied (the App
/// wires it once hosts/credentials are available; tests pass a fake).
///
/// - Parameters:
///   - registry: Runner registry to register into (defaults to the shared
///     process-wide registry used by `CatalogToolExecutor`).
///   - service: The JS execution backend (defaults to the real
///     JavaScriptCore service; tests inject fakes).
///   - pythonService: The remote Python backend. Nil leaves
///     `exec.remotePython` unregistered (honest absence: no runner).
@discardableResult
public func registerExecutionTools(
    registry: ToolRunnerRegistry = .shared,
    service: any ScriptExecutionService = JavaScriptExecutionService(),
    pythonService: RemotePythonService? = nil
) -> any ScriptExecutionService {
    // Compile-time catalog descriptors.
    ToolCatalog.register(JavaScriptExecutionTool.self)
    if pythonService != nil {
        ToolCatalog.register(RemotePythonTool.self)
    }
    // Runtime runners.
    registry.register(JavaScriptExecutionTool(service: service))
    if let pythonService {
        registry.register(RemotePythonTool(service: pythonService))
    }
    return service
}
