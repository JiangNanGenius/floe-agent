// FloeExecution — Execution tool registration entry point.
// See docs/ARCHITECTURE_EXECUTION.md §4/§10: same dual-registration seam
// as the workspace tools — the compile-time Descriptor goes to
// ToolCatalog, the runtime runner to ToolRunnerRegistry. Both are required
// for a call to execute; the runtime module never imports FloeExecution.

import Foundation
import FloeTools

/// Registers the execution tools (currently `exec.javascript`; T14 adds
/// `exec.remotePython` here).
///
/// - Parameters:
///   - registry: Runner registry to register into (defaults to the shared
///     process-wide registry used by `CatalogToolExecutor`).
///   - service: The JS execution backend (defaults to the real
///     JavaScriptCore service; tests inject fakes).
@discardableResult
public func registerExecutionTools(
    registry: ToolRunnerRegistry = .shared,
    service: any ScriptExecutionService = JavaScriptExecutionService()
) -> any ScriptExecutionService {
    // Compile-time catalog descriptor.
    ToolCatalog.register(JavaScriptExecutionTool.self)
    // Runtime runner.
    registry.register(JavaScriptExecutionTool(service: service))
    return service
}
