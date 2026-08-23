// FloeTools — Compile-time tool registry.

import Foundation
import FloeCore

/// Registry of every tool the agent may invoke. Tools are compiled in;
/// there is no dynamic loading, download, or plugin mechanism.
public enum ToolCatalog {
    /// Type-erased tool descriptor for catalog operations that don't need
    /// the concrete `Arguments` type.
    public struct Descriptor: Sendable {
        public var name: String
        public var toolDescription: String
        public var parametersJSON: String
        public var riskLabels: Set<RiskLabel>
        public var isSideEffecting: Bool
        public var effect: ToolEffect
        public var requiresHostScope: Bool

        public init(
            name: String,
            toolDescription: String? = nil,
            parametersJSON: String = #"{"type":"object","additionalProperties":false}"#,
            riskLabels: Set<RiskLabel>,
            isSideEffecting: Bool,
            effect: ToolEffect? = nil,
            requiresHostScope: Bool? = nil
        ) {
            self.name = name
            self.toolDescription = toolDescription ?? name
            self.parametersJSON = Self.validatedSchema(parametersJSON, toolName: name)
            self.riskLabels = riskLabels
            self.isSideEffecting = isSideEffecting
            self.effect = effect ?? (isSideEffecting ? .mutating : .readOnly)
            self.requiresHostScope = requiresHostScope
                ?? !riskLabels.isDisjoint(with: [.executesRemoteCommand, .modifiesRemoteSystem])
        }

        /// A malformed tool schema must never make every provider request
        /// fail during JSON encoding. Keep the tool available with a safe,
        /// permissive object schema and leave an actionable local diagnostic.
        private static func validatedSchema(_ schema: String, toolName: String) -> String {
            guard let data = schema.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data),
                  object is [String: Any]
            else {
                FloeLogger(category: .tools).error(
                    "toolSchemaInvalid tool=\(toolName) fallback=permissiveObject"
                )
                return #"{"type":"object","additionalProperties":true}"#
            }
            return schema
        }
    }

    /// All registered descriptors. Concrete tools register themselves in
    /// their respective modules (FloeDocuments, FloeImages, FloeSSH, FloeVNC)
    /// during app startup via `register(_:)`.
    private static let registry = RegistryStorage()

    private final class RegistryStorage: @unchecked Sendable {
        private var descriptors: [String: Descriptor] = [:]
        private let lock = NSLock()

        func register(_ descriptor: Descriptor) {
            lock.lock()
            descriptors[descriptor.name] = descriptor
            lock.unlock()
        }

        func descriptor(named name: String) -> Descriptor? {
            lock.lock()
            defer { lock.unlock() }
            return descriptors[name]
        }

        func all() -> [Descriptor] {
            lock.lock()
            defer { lock.unlock() }
            return Array(descriptors.values).sorted { $0.name < $1.name }
        }
    }

    /// Registers a tool type. Called once at app startup per tool module.
    public static func register<T: AgentTool>(_ type: T.Type) {
        registry.register(Descriptor(
            name: T.name,
            toolDescription: T.toolDescription,
            parametersJSON: T.parametersJSON,
            riskLabels: T.riskLabels,
            isSideEffecting: T.isSideEffecting,
            effect: T.toolEffect,
            requiresHostScope: T.requiresHostScope
        ))
    }

    /// Looks up a tool descriptor by name. Absent names are rejected before
    /// reaching the policy engine.
    public static func descriptor(named name: String) -> Descriptor? {
        registry.descriptor(named: name)
    }

    /// Every registered descriptor, sorted by name.
    public static var allDescriptors: [Descriptor] {
        registry.all()
    }
}
