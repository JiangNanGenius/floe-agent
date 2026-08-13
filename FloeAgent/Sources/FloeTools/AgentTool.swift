// FloeTools — Compiled tool catalog contracts.
// See docs/DEVELOPMENT_PLAN.md §3.2: "The on-device tool catalog contains
// only compiled document, image, SSH, VNC, file, and status operations."

import Foundation
import FloeCore

/// Deterministic risk classification attached to every tool. Fed to the
/// approval model and shown to the user; never derived from model output.
public enum RiskLabel: String, Sendable, Codable, Hashable, CaseIterable {
    case readsFiles
    case writesFiles
    case deletesFiles
    case executesRemoteCommand
    case modifiesRemoteSystem
    case networkAccess
    case sendsDataToProvider
    case controlsGUI
    case accessesCredentials
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

    /// Validates decoded arguments before they reach the policy engine.
    func validate(_ args: Arguments) throws
    /// Executes after policy approval. Must honor `context.cancellation`.
    func execute(_ args: Arguments, context: ToolContext) async throws -> ToolExecutionOutput
}

public extension AgentTool {
    static var toolDescription: String { name }
    static var parametersJSON: String { #"{"type":"object","additionalProperties":false}"# }
}

/// Bounded execution output; the digest covers the full pre-truncation bytes.
public struct ToolExecutionOutput: Sendable {
    public var summary: String
    public var fullOutputSHA256: String
    public var exitStatus: Int32?

    public init(summary: String, fullOutputSHA256: String, exitStatus: Int32? = nil) {
        self.summary = String(summary.prefix(4096))
        self.fullOutputSHA256 = fullOutputSHA256
        self.exitStatus = exitStatus
    }
}
