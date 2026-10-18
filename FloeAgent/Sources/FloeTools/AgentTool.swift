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
    /// Persists user or conversation information across runs.
    case persistsPersonalData
    /// Installs or changes instructions that influence future agent behavior.
    case changesAgentBehavior
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

/// Where a compiled tool may execute. Enforced in schema composition (a
/// child's tool directory never advertises `delegate`) and again in the
/// canonical dispatcher (execution, not just discovery).
public enum ToolExecutionBoundary: String, Sendable, Codable, Hashable {
    /// Ordinary tool: main run and delegated children.
    case any
    /// Only the main (user-visible) run may invoke this tool. Delegated
    /// children are refused in discovery and at dispatch, which is what keeps
    /// delegation main-only across batch/jobs/skill wrappers: a child cannot
    /// spawn another child, directly or through a wrapper.
    case mainRunOnly
    /// Only a delegated child may invoke this tool (sibling collaboration).
    case childOnly
}

/// A deterministic lifecycle dependency that must be satisfied before a
/// tool can produce a meaningful result. This metadata is compiled into the
/// catalog so providers and the harness can explain the required predecessor
/// without inferring it from prose or silently performing a side effect.
public struct ToolPrerequisite: Sendable, Codable, Hashable {
    public var state: String
    public var resolverToolName: String?
    public var mayResolveAutomatically: Bool

    public init(
        state: String,
        resolverToolName: String? = nil,
        mayResolveAutomatically: Bool = false
    ) {
        self.state = state
        self.resolverToolName = resolverToolName
        self.mayResolveAutomatically = mayResolveAutomatically
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
    /// Explicit lifecycle dependencies. The default is stateless.
    static var prerequisites: [ToolPrerequisite] { get }
    /// Where this tool may run. Default `.any`; `delegate` is `.mainRunOnly`
    /// and peer collaboration tools are `.childOnly`.
    static var executionBoundary: ToolExecutionBoundary { get }
    /// See `ToolCatalog.Descriptor.supportsConcurrentBatchDispatch`.
    static var supportsConcurrentBatchDispatch: Bool { get }

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
    static var prerequisites: [ToolPrerequisite] { [] }
    static var executionBoundary: ToolExecutionBoundary { .any }
    static var supportsConcurrentBatchDispatch: Bool { false }
}

/// Bounded execution output; the digest covers the full pre-truncation bytes.
public struct ToolExecutionOutput: Sendable {
    public var summary: String
    public var fullOutputSHA256: String
    public var exitStatus: Int32?
    public var artifacts: [ToolArtifactReference]
    /// Declared final deliverables captured as immutable per-run snapshots.
    /// These are distinct from ordinary `artifacts`: evidence, screenshots and
    /// input references stay in `artifacts` and are never promoted here, and
    /// nothing is added to `outputFiles` without the tool deliberately
    /// snapshotting the exact bytes into the run-output store. The runtime
    /// persists this list on the exact-run `toolResult` event so the owning
    /// conversation and later callers can reopen the files after the original
    /// workspace file has changed.
    public var outputFiles: [ToolArtifactReference]
    /// The tool reached a stable boundary that requires the user to interact
    /// with a visible system surface before the same run can continue.
    public var requiresUserAction: Bool

    public init(
        summary: String,
        fullOutputSHA256: String,
        exitStatus: Int32? = nil,
        artifacts: [ToolArtifactReference] = [],
        outputFiles: [ToolArtifactReference] = [],
        requiresUserAction: Bool = false,
        maximumSummaryCharacters: Int = 4096
    ) {
        self.summary = String(summary.prefix(min(262_144, max(0, maximumSummaryCharacters))))
        self.fullOutputSHA256 = fullOutputSHA256
        self.exitStatus = exitStatus
        self.artifacts = artifacts
        self.outputFiles = outputFiles
        self.requiresUserAction = requiresUserAction
    }

    /// Convenience factory for the common "digest the summary" case, so tools
    /// stop re-implementing the same two lines.
    public init(
        digesting summary: String,
        exitStatus: Int32? = nil,
        artifacts: [ToolArtifactReference] = [],
        outputFiles: [ToolArtifactReference] = [],
        requiresUserAction: Bool = false,
        maximumSummaryCharacters: Int = 4096
    ) {
        self.init(
            summary: summary,
            fullOutputSHA256: FloeDigest.sha256Hex(Data(summary.utf8)),
            exitStatus: exitStatus,
            artifacts: artifacts,
            outputFiles: outputFiles,
            requiresUserAction: requiresUserAction,
            maximumSummaryCharacters: maximumSummaryCharacters
        )
    }
}
