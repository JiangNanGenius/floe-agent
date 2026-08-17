// FloeTools — Compiled tool catalog contracts.
// See docs/DEVELOPMENT_PLAN.md §3.2: "The on-device tool catalog contains
// only compiled document, image, SSH, VNC, file, and status operations."

import Foundation
import FloeCore
import FloeModels

/// Deterministic risk classification attached to every tool. Fed to the
/// approval model and shown to the user; never derived from model output.
public enum RiskLabel: String, Sendable, Codable, Hashable, CaseIterable {
    case readsFiles
    case writesFiles
    case deletesFiles
    /// Executes code inside Floe's on-device application sandbox.
    case executesLocalCode
    case executesRemoteCommand
    case modifiesRemoteSystem
    case networkAccess
    case sendsDataToProvider
    case controlsGUI
    case accessesCredentials
}

/// Deterministic description of the externally observable effect of a
/// compiled tool. Unlike risk labels this is intentionally small and is
/// suitable for runtime capability filtering (notably Plan mode).
public enum ToolEffect: String, Sendable, Codable, Hashable, CaseIterable {
    /// Reads state without changing the target environment.
    case readOnly
    /// Writes Floe-owned draft/checkpoint state only.
    case internalState
    /// Changes files, a host, a browser session, or another external system.
    case mutating

    public var isAllowedInPlanMode: Bool {
        self == .readOnly
    }
}

/// A compiled, catalog-registered operation the agent may invoke.
public protocol AgentTool: Sendable {
    associatedtype Arguments: Decodable & Sendable

    /// Unique catalog name (e.g. "ssh.execute", "document.replaceText").
    static var name: String { get }
    /// Human-readable purpose supplied to the model and approval UI.
    static var toolDescription: String { get }
    /// JSON Schema object supplied to provider tool APIs.
    static var parametersJSON: String { get }
    /// Deterministic risk labels for policy decisions.
    static var riskLabels: Set<RiskLabel> { get }
    /// Side-effecting tools require approval under Human and Model policies.
    static var isSideEffecting: Bool { get }
    /// Effect used for capability filtering and executor-side enforcement.
    static var toolEffect: ToolEffect { get }
    /// Whether execution requires a concrete remote host scope. GUI control
    /// alone does not imply this: an in-app browser is a local GUI target.
    static var requiresHostScope: Bool { get }

    /// Validates decoded arguments before they reach the policy engine.
    func validate(_ args: Arguments) throws
    /// Executes after policy approval. Must honor `context.cancellation`.
    func execute(_ args: Arguments, context: ToolContext) async throws -> ToolExecutionOutput
}

public extension AgentTool {
    static var toolDescription: String { name }
    static var parametersJSON: String { #"{"type":"object","additionalProperties":false}"# }
    static var toolEffect: ToolEffect { isSideEffecting ? .mutating : .readOnly }
    static var requiresHostScope: Bool {
        !riskLabels.isDisjoint(with: [.executesRemoteCommand, .modifiesRemoteSystem])
    }
}

/// Bounded execution output; the digest covers the full pre-truncation bytes.
public struct ToolExecutionOutput: Sendable {
    public var summary: String
    public var fullOutputSHA256: String
    public var exitStatus: Int32?
    public var artifacts: [ToolArtifactReference]

    public init(
        summary: String,
        fullOutputSHA256: String,
        exitStatus: Int32? = nil,
        artifacts: [ToolArtifactReference] = []
    ) {
        self.summary = String(summary.prefix(4096))
        self.fullOutputSHA256 = fullOutputSHA256
        self.exitStatus = exitStatus
        self.artifacts = artifacts
    }
}
