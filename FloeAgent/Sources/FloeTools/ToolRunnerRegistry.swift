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
            requiresHostScope: T.requiresHostScope
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
/// Thread-safe; registrations happen once at app startup.
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
}
