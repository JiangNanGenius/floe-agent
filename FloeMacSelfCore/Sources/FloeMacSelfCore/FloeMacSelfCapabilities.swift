// SPDX-License-Identifier: MPL-2.0
//
// Host-injected capability bindings. Production sessions require a real
// provider adapter and, only when tools are enabled, a real catastrophic
// gate, approval policy, executor and an explicit native task boundary.
// There is no default inference adapter, no default tool catalog and no
// implicit tool permission.

import Foundation
import FloeCore
import FloeModels
import FloeProviders
import FloeTools
import FloeSecurity
import FloeAgentRuntime

/// Exact provider binding supplied by the Mac host. Credentials stay in this
/// value only for the lifetime of the run; nothing here is persisted by the
/// composition layer and `description` never prints the key.
public struct FloeMacSelfProviderBinding: Sendable, CustomStringConvertible {
    public let provider: ProviderProfile
    public let model: ModelProfile
    public let adapter: any ProviderAdapter
    public let credentials: ProviderCredentials

    public init(
        provider: ProviderProfile,
        model: ModelProfile,
        adapter: any ProviderAdapter,
        credentials: ProviderCredentials
    ) {
        self.provider = provider
        self.model = model
        self.adapter = adapter
        self.credentials = credentials
    }

    public var description: String {
        "FloeMacSelfProviderBinding(provider: \(provider.id.uuidString), "
            + "model: \(model.id.uuidString), protocol: \(adapter.protocolKind.rawValue))"
    }
}

/// Explicit execution ownership for a task. Only `.nativeHost` is wired in
/// this stage. `.environment` is a typed, fail-closed placeholder so the host
/// cannot mistake an unverified guest/remote path for native ownership.
public enum FloeMacSelfExecutionOwnership: Sendable, Hashable {
    case nativeHost
    case environment(id: String, binding: TaskExecutionBinding?, localLinuxGuest: Bool)
}

/// The exact task workspace and write ceiling handed to the runtime. The
/// workspace identifier is matched against the durable prepared workspace;
/// the root is host-verified and must already exist.
public struct FloeMacSelfTaskBoundary: Sendable, Hashable {
    public let workspaceID: UUID
    public let workspaceRootURL: URL
    /// Workspace-relative ceiling passed to the runtime. Empty means the whole
    /// task workspace, which is the existing Floe task semantics.
    public let allowedWorkspacePaths: [String]
    public let ownership: FloeMacSelfExecutionOwnership

    public init(
        workspaceID: UUID,
        workspaceRootURL: URL,
        allowedWorkspacePaths: [String] = [],
        ownership: FloeMacSelfExecutionOwnership = .nativeHost
    ) {
        self.workspaceID = workspaceID
        self.workspaceRootURL = workspaceRootURL
        self.allowedWorkspacePaths = allowedWorkspacePaths
        self.ownership = ownership
    }
}

/// Host-injected tool execution capability. `gate` is non-optional by design:
/// a tool-enabled session cannot be assembled without the existing Floe
/// catastrophic gate. `policy` is the existing Floe approval policy, never a
/// second permission model created here.
public struct FloeMacSelfToolBinding: Sendable, CustomStringConvertible {
    public let executor: any ToolExecutor
    public let policy: any ApprovalPolicy
    public let gate: CatastrophicActionGate
    public let auditSink: (any AuditSink)?
    public let boundary: FloeMacSelfTaskBoundary
    /// Exact names this Mac host can actually execute. The composition layer
    /// requires this set to be non-empty, verifies every descriptor and uses
    /// it as the runtime ceiling; it never falls back to the compiled catalog.
    public let allowedToolNames: Set<String>
    /// Explicit host declaration that a real workspace authorization, approval
    /// source and tool corpus exist. The composition verifies consistency only;
    /// it does not authenticate the host (see `FloeMacSelfHostGate`).
    public let hostGate: FloeMacSelfHostGate

    public init(
        executor: any ToolExecutor,
        policy: any ApprovalPolicy,
        gate: CatastrophicActionGate,
        auditSink: (any AuditSink)? = nil,
        boundary: FloeMacSelfTaskBoundary,
        allowedToolNames: Set<String>,
        hostGate: FloeMacSelfHostGate
    ) {
        self.executor = executor
        self.policy = policy
        self.gate = gate
        self.auditSink = auditSink
        self.boundary = boundary
        self.allowedToolNames = allowedToolNames
        self.hostGate = hostGate
    }

    public var description: String {
        "FloeMacSelfToolBinding(tools: \(allowedToolNames.sorted().joined(separator: ",")), "
            + "policy: \(policy.policyName), workspace: \(boundary.workspaceID.uuidString), "
            + "issuer: \(hostGate.issuer))"
    }
}

enum FloeMacSelfCapabilityResolver {
    static let maximumToolNameBytes = 128
    static let maximumAllowedPathCount = 64
    static let maximumAllowedPathBytes = 1_024

    static func resolveProvider(
        _ binding: FloeMacSelfProviderBinding
    ) throws -> (provider: ProviderProfile, model: ModelProfile, adapter: any ProviderAdapter, credentials: ProviderCredentials) {
        guard binding.provider.isEnabled else {
            throw FloeMacSelfCoreError.providerUnavailable("the provider is disabled")
        }
        guard binding.model.isEnabled else {
            throw FloeMacSelfCoreError.providerUnavailable("the model is disabled")
        }
        guard binding.model.providerID == binding.provider.id else {
            throw FloeMacSelfCoreError.providerUnavailable("the model belongs to a different provider")
        }
        guard binding.model.capabilities.contains(.text) else {
            throw FloeMacSelfCoreError.providerUnavailable("the model does not declare text output")
        }
        guard binding.provider.wireProtocol == binding.adapter.protocolKind else {
            throw FloeMacSelfCoreError.adapterProtocolMismatch(
                expected: binding.provider.wireProtocol.rawValue,
                actual: binding.adapter.protocolKind.rawValue
            )
        }
        do {
            try binding.provider.validate()
        } catch {
            throw FloeMacSelfCoreError.providerUnavailable("the provider profile is invalid")
        }
        return (binding.provider, binding.model, binding.adapter, binding.credentials)
    }

    static func resolveTools(
        _ binding: FloeMacSelfToolBinding?,
        model: ModelProfile
    ) throws -> (
        enabled: Bool,
        executor: any ToolExecutor,
        policy: any ApprovalPolicy,
        gate: CatastrophicActionGate?,
        auditSink: (any AuditSink)?,
        boundary: FloeMacSelfTaskBoundary?,
        allowedToolNames: Set<String>,
        hostGate: FloeMacSelfHostGate?
    ) {
        guard let binding else {
            return (
                false,
                FloeMacSelfDeniedToolExecutor(),
                FloeMacSelfToolsDisabledPolicy(),
                nil,
                nil,
                nil,
                [],
                nil
            )
        }
        guard model.capabilities.contains(.tools) else {
            throw FloeMacSelfCoreError.modelDoesNotSupportTools
        }
        guard !binding.allowedToolNames.isEmpty else {
            throw FloeMacSelfCoreError.toolCapabilityUnavailable("the allowed tool set is empty")
        }
        guard binding.allowedToolNames.count <= FloeMacSelfHostGate.maximumToolCount else {
            throw FloeMacSelfCoreError.toolCapabilityUnavailable("the allowed tool set is unbounded")
        }
        var descriptors: [String: ToolCatalog.Descriptor] = [:]
        for descriptor in binding.executor.allDescriptors {
            guard descriptors.updateValue(descriptor, forKey: descriptor.name) == nil else {
                throw FloeMacSelfCoreError.toolCapabilityUnavailable(
                    "the executor catalog contains duplicate tool names"
                )
            }
        }
        for name in binding.allowedToolNames {
            guard !name.isEmpty, name.utf8.count <= maximumToolNameBytes else {
                throw FloeMacSelfCoreError.toolCapabilityUnavailable("a tool name is invalid")
            }
            // A project binding must never supply a substitute question runner.
            // The runtime adds the app-owned descriptor after validating this binding.
            guard name != UserAskTool.name else {
                throw FloeMacSelfCoreError.toolCapabilityUnavailable("user.ask is supplied by the app")
            }
            guard let descriptor = binding.executor.descriptor(named: name) else {
                throw FloeMacSelfCoreError.toolCapabilityUnavailable(
                    "the executor has no descriptor for \(name)"
                )
            }
            guard descriptors[name] != nil else {
                throw FloeMacSelfCoreError.toolCapabilityUnavailable(
                    "\(name) is not in the executor's visible catalog"
                )
            }
            guard !descriptor.requiresHostScope else {
                throw FloeMacSelfCoreError.toolCapabilityUnavailable(
                    "\(name) requires a host scope that this native task boundary does not own"
                )
            }
            guard descriptor.executionBoundary != .childOnly else {
                throw FloeMacSelfCoreError.toolCapabilityUnavailable(
                    "\(name) is only valid inside a delegated child run"
                )
            }
        }

        switch binding.boundary.ownership {
        case .nativeHost:
            break
        case .environment:
            throw FloeMacSelfCoreError.executionEnvironmentUnsupported
        }
        try validateBoundary(binding.boundary)
        try validateHostGate(binding)
        return (
            true,
            binding.executor,
            binding.policy,
            binding.gate,
            binding.auditSink,
            binding.boundary,
            binding.allowedToolNames,
            binding.hostGate
        )
    }

    /// Plan-mode admission ceiling: every admitted tool must be offered by
    /// the existing plan tool access and pass the existing `PlanToolPolicy`.
    /// This fails closed at composition time so a host-declared mutating tool
    /// can never enter a plan run, independent of the runtime's own filter.
    static func validatePlanCeiling(
        allowedToolNames: Set<String>,
        executor: any ToolExecutor
    ) throws {
        let access = ConversationToolAccess.plan
        let policy = PlanToolPolicy()
        for name in allowedToolNames {
            guard let descriptor = executor.descriptor(named: name) else {
                throw FloeMacSelfCoreError.toolCapabilityUnavailable(
                    "the executor has no descriptor for \(name)"
                )
            }
            guard access.allows(descriptor) else {
                throw FloeMacSelfCoreError.toolCapabilityUnavailable(
                    "\(name) is outside the read-only plan-investigation ceiling"
                )
            }
            if case .failure = policy.decision(for: descriptor) {
                throw FloeMacSelfCoreError.toolCapabilityUnavailable(
                    "\(name) is rejected by the existing plan tool policy"
                )
            }
        }
    }

    /// Verifies only internal consistency of the host's declaration. Passing
    /// this check does not prove that the workspace authorization or approval
    /// source is genuine.
    static func validateHostGate(_ binding: FloeMacSelfToolBinding) throws {
        let gate = binding.hostGate
        guard gate.isStructurallyValid else {
            throw FloeMacSelfCoreError.hostGateUnavailable("the host gate is missing bounded provenance")
        }
        guard gate.workspaceID == binding.boundary.workspaceID else {
            throw FloeMacSelfCoreError.hostGateMismatch("the gate workspace differs from the task boundary")
        }
        let boundaryRoot = binding.boundary.workspaceRootURL
            .resolvingSymlinksInPath()
            .standardizedFileURL
            .path
        guard gate.workspaceRootPath == boundaryRoot else {
            throw FloeMacSelfCoreError.hostGateMismatch("the gate workspace root differs from the verified task root")
        }
        guard gate.approvedToolNames == binding.allowedToolNames else {
            throw FloeMacSelfCoreError.hostGateMismatch("the gate tool set differs from the executor ceiling")
        }
        guard gate.approvalPolicySource.utf8.count > 0,
              gate.toolCorpusIdentifier.utf8.count > 0 else {
            throw FloeMacSelfCoreError.hostGateUnavailable("the gate has no approval source or tool corpus identity")
        }
    }

    static func validateBoundary(_ boundary: FloeMacSelfTaskBoundary) throws {
        guard boundary.workspaceRootURL.isFileURL else {
            throw FloeMacSelfCoreError.invalidTaskBoundary("the workspace root must be a file URL")
        }
        let resolved = boundary.workspaceRootURL.resolvingSymlinksInPath().standardizedFileURL
        let path = resolved.path
        guard !path.isEmpty, path != "/" else {
            throw FloeMacSelfCoreError.invalidTaskBoundary("the filesystem root cannot be a task workspace")
        }
        let home = FileManager.default.homeDirectoryForCurrentUser.resolvingSymlinksInPath().standardizedFileURL.path
        guard path != home else {
            throw FloeMacSelfCoreError.invalidTaskBoundary("the user home directory cannot be a task workspace root")
        }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            throw FloeMacSelfCoreError.invalidTaskBoundary("the workspace root is not an existing directory")
        }
        guard boundary.allowedWorkspacePaths.count <= maximumAllowedPathCount else {
            throw FloeMacSelfCoreError.invalidTaskBoundary("too many allowed workspace paths")
        }
        for relative in boundary.allowedWorkspacePaths {
            guard !relative.isEmpty,
                  relative.utf8.count <= maximumAllowedPathBytes,
                  !relative.hasPrefix("/"),
                  !relative.unicodeScalars.contains(where: { $0.value == 0 }) else {
                throw FloeMacSelfCoreError.invalidTaskBoundary(
                    "allowed workspace paths must be bounded, non-empty and relative"
                )
            }
            let components = relative.split(separator: "/", omittingEmptySubsequences: false)
            guard !components.contains(where: { $0 == ".." || $0 == "." || $0.isEmpty }) else {
                throw FloeMacSelfCoreError.invalidTaskBoundary(
                    "allowed workspace paths must not contain empty, '.' or '..' components"
                )
            }
        }
    }
}
