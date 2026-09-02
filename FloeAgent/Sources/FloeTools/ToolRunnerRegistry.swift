// FloeTools — Runtime tool runner registry (type-erased execution).
// See docs/ARCHITECTURE_AGENT_WORKSPACE.md §3/§6: descriptors register at
// compile time via `ToolCatalog`; concrete runners register at app startup
// via this registry. `CatalogToolExecutor` bridges the two so runtime
// modules never import tool implementation modules.

import Foundation
import FloeCore

/// Type-erased executable tool: pairs the compile-time `Descriptor` with a
/// closure that decodes validated JSON arguments and runs the concrete
/// `AgentTool` implementation.
public struct AnyAgentTool: Sendable {
    public var descriptor: ToolCatalog.Descriptor
    public var run: @Sendable (Data, ToolContext) async throws -> ToolExecutionOutput

    public init(
        descriptor: ToolCatalog.Descriptor,
        run: @escaping @Sendable (Data, ToolContext) async throws -> ToolExecutionOutput
    ) {
        self.descriptor = descriptor
        self.run = run
    }

    /// Type-erases a concrete `AgentTool`: decodes `argumentsJSON` into the
    /// tool's `Arguments`, validates them, then executes.
    public init<T: AgentTool>(_ tool: T) {
        self.descriptor = ToolCatalog.Descriptor(
            name: T.name,
            toolDescription: T.toolDescription,
            parametersJSON: T.parametersJSON,
            riskLabels: T.riskLabels,
            isSideEffecting: T.isSideEffecting,
            effect: T.toolEffect,
            requiresHostScope: T.requiresHostScope,
            prerequisites: T.prerequisites
        )
        self.run = { argumentsJSON, context in
            let arguments: T.Arguments
            do {
                arguments = try JSONDecoder().decode(T.Arguments.self, from: argumentsJSON)
            } catch {
                throw FloeError.validationFailed(
                    "Invalid arguments for tool '\(T.name)': \(error.localizedDescription)"
                )
            }
            try tool.validate(arguments)
            return try await tool.execute(arguments, context: context)
        }
    }

    /// Executes the tool with JSON-encoded arguments.
    public func execute(argumentsJSON: Data, context: ToolContext) async throws -> ToolExecutionOutput {
        try await run(argumentsJSON, context)
    }
}

/// Runtime registry of executable tool runners, keyed by catalog name.
/// Thread-safe. Native tools register at app startup; bounded external tool
/// sources such as MCP may replace their own namespaced entries at runtime.
public final class ToolRunnerRegistry: @unchecked Sendable {
    /// Shared process-wide registry used by `CatalogToolExecutor`.
    public static let shared = ToolRunnerRegistry()

    private var runners: [String: AnyAgentTool] = [:]
    private let lock = NSLock()

    public init() {}

    /// Registers (or replaces) the runner for `tool.descriptor.name`.
    public func register(_ tool: AnyAgentTool) {
        lock.lock()
        runners[tool.descriptor.name] = tool
        lock.unlock()
    }

    /// Type-erases and registers a concrete `AgentTool` in one call.
    public func register<T: AgentTool>(_ tool: T) {
        register(AnyAgentTool(tool))
    }

    /// Looks up a runner by catalog name. Absent names surface as the
    /// structured "No runner registered" failure in `CatalogToolExecutor`.
    public func runner(named name: String) -> AnyAgentTool? {
        lock.lock()
        defer { lock.unlock() }
        return runners[name]
    }

    /// Returns the executable descriptor for a runtime-provided tool.
    public func descriptor(named name: String) -> ToolCatalog.Descriptor? {
        lock.lock()
        defer { lock.unlock() }
        return runners[name]?.descriptor
    }

    /// All currently executable runtime descriptors, sorted for deterministic
    /// provider requests and diagnostics.
    public var allDescriptors: [ToolCatalog.Descriptor] {
        lock.lock()
        defer { lock.unlock() }
        return runners.values.map(\.descriptor).sorted { $0.name < $1.name }
    }

    /// Removes runtime entries owned by one dynamic source. Native callers do
    /// not use this; MCP refresh/disconnect uses a stable namespaced prefix so
    /// one server cannot remove another server's tools.
    public func unregister(where shouldRemove: (String) -> Bool) {
        lock.lock()
        runners = runners.filter { !shouldRemove($0.key) }
        lock.unlock()
    }
}
