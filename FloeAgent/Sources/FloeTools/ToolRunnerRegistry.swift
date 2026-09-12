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
    /// Decode + validate without executing. Used by background job submission
    /// so malformed arguments fail fast at the call site, not asynchronously.
    public var validateArguments: @Sendable (Data) throws -> Void

    public init(
        descriptor: ToolCatalog.Descriptor,
        run: @escaping @Sendable (Data, ToolContext) async throws -> ToolExecutionOutput,
        validateArguments: @escaping @Sendable (Data) throws -> Void = { _ in }
    ) {
        self.descriptor = descriptor
        self.run = run
        self.validateArguments = validateArguments
    }

    /// Renders a decoding failure as an actionable message naming the exact
    /// argument, instead of the platform's opaque "data is missing" text.
    static func describeDecodingError(_ error: DecodingError, toolName: String) -> String {
        func path(_ context: DecodingError.Context) -> String {
            context.codingPath.map(\.stringValue).joined(separator: ".")
        }
        switch error {
        case .keyNotFound(let key, _):
            return "missing required argument '\(key.stringValue)' for tool '\(toolName)'"
        case .typeMismatch(_, let context):
            return "argument '\(path(context))' for tool '\(toolName)' has the wrong type (\(context.debugDescription))"
        case .valueNotFound(_, let context):
            return "argument '\(path(context))' for tool '\(toolName)' is null but a value is required"
        case .dataCorrupted(let context):
            return "malformed arguments for tool '\(toolName)': \(context.debugDescription)"
        @unknown default:
            return "invalid arguments for tool '\(toolName)'"
        }
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
        self.validateArguments = { argumentsJSON in
            let arguments: T.Arguments
            do {
                arguments = try JSONDecoder().decode(T.Arguments.self, from: argumentsJSON)
            } catch let error as DecodingError {
                throw FloeError.validationFailed(AnyAgentTool.describeDecodingError(error, toolName: T.name))
            } catch {
                throw FloeError.validationFailed("Invalid arguments for tool '\(T.name)': \(error.localizedDescription)")
            }
            try tool.validate(arguments)
        }
        self.run = { argumentsJSON, context in
            let arguments: T.Arguments
            do {
                arguments = try JSONDecoder().decode(T.Arguments.self, from: argumentsJSON)
            } catch let error as DecodingError {
                throw FloeError.validationFailed(AnyAgentTool.describeDecodingError(error, toolName: T.name))
            } catch {
                throw FloeError.validationFailed("Invalid arguments for tool '\(T.name)': \(error.localizedDescription)")
            }
            try tool.validate(arguments)
            return try await tool.execute(arguments, context: context)
        }
    }

    /// Executes the tool with JSON-encoded arguments.
    public func execute(argumentsJSON: Data, context: ToolContext) async throws -> ToolExecutionOutput {
        let lease = try await ToolEnvironmentRouting.shared.acquire(context)
        do {
            let output = try await run(argumentsJSON, lease.context)
            await lease.finish()
            return output
        } catch {
            await lease.finish()
            throw error
        }
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
    private var compatibilityNames = Set<String>()

    public init() {}

    /// Registers (or replaces) the runner for `tool.descriptor.name`.
    public func register(_ tool: AnyAgentTool, compatibilityOnly: Bool = false) {
        lock.lock()
        runners[tool.descriptor.name] = tool
        if compatibilityOnly { compatibilityNames.insert(tool.descriptor.name) } else { compatibilityNames.remove(tool.descriptor.name) }
        lock.unlock()
    }

    /// Type-erases and registers a concrete `AgentTool` in one call.
    public func register<T: AgentTool>(_ tool: T, compatibilityOnly: Bool = false) {
        register(AnyAgentTool(tool), compatibilityOnly: compatibilityOnly)
    }

    /// Looks up a runner by catalog name. Absent names surface as the
    /// structured "No runner registered" failure in `CatalogToolExecutor`.
    public func runner(named name: String) -> AnyAgentTool? {
        lock.lock()
        defer { lock.unlock() }
        return runners[ToolAliasTable.canonical(name)]
    }

    /// Returns the executable descriptor for a runtime-provided tool.
    public func descriptor(named name: String) -> ToolCatalog.Descriptor? {
        lock.lock()
        defer { lock.unlock() }
        return runners[ToolAliasTable.canonical(name)]?.descriptor
    }

    /// All currently executable runtime descriptors, sorted for deterministic
    /// provider requests and diagnostics.
    public var allDescriptors: [ToolCatalog.Descriptor] {
        lock.lock()
        defer { lock.unlock() }
        return runners.values.map(\.descriptor).filter { !compatibilityNames.contains($0.name) }.sorted { $0.name < $1.name }
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
