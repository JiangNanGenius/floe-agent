// SPDX-License-Identifier: MPL-2.0
//
// Explicit host tool gate and the task-epoch/stop-checking executor wrapper.
//
// The gate is a host declaration, not an authentication proof. The
// composition layer verifies only internal consistency (workspace id + root,
// exact allowed tool set, bounded non-empty issuer/policy/corpus labels). It
// cannot verify that the host really obtained workspace authorization or that
// the approval policy/corpus are trustworthy. The host must construct the gate
// only from its trusted authorization path; this stage is not a user-facing
// tool capability and no real tools are enabled by default.

import Foundation
import FloeModels
import FloeTools
import FloeAgentRuntime

public struct FloeMacSelfHostGate: Sendable, Hashable {
    static let maximumLabelBytes = 200
    static let maximumRootPathBytes = 4_096
    static let maximumToolCount = 64
    static let maximumToolNameBytes = 128

    /// The exact durable workspace this gate authorizes.
    public let workspaceID: UUID
    /// The host-verified workspace root, already resolved by the host.
    public let workspaceRootPath: String
    /// Stable host label for the approval-policy source (for example a host
    /// policy bundle identity). Not a secret.
    public let approvalPolicySource: String
    /// Stable label for the tool corpus/version the host verified.
    public let toolCorpusIdentifier: String
    /// Exact executable tool names the host authorizes for this task.
    public let approvedToolNames: Set<String>
    /// Stable label for the issuing host component. This is provenance only;
    /// it is not authenticated by the composition layer.
    public let issuer: String

    public init(
        workspaceID: UUID,
        workspaceRootPath: String,
        approvalPolicySource: String,
        toolCorpusIdentifier: String,
        approvedToolNames: Set<String>,
        issuer: String
    ) {
        self.workspaceID = workspaceID
        self.workspaceRootPath = workspaceRootPath
        self.approvalPolicySource = approvalPolicySource
        self.toolCorpusIdentifier = toolCorpusIdentifier
        self.approvedToolNames = approvedToolNames
        self.issuer = issuer
    }

    public var isStructurallyValid: Bool {
        guard !workspaceRootPath.isEmpty,
              workspaceRootPath.utf8.count <= Self.maximumRootPathBytes,
              !approvalPolicySource.isEmpty,
              approvalPolicySource.utf8.count <= Self.maximumLabelBytes,
              !toolCorpusIdentifier.isEmpty,
              toolCorpusIdentifier.utf8.count <= Self.maximumLabelBytes,
              !issuer.isEmpty,
              issuer.utf8.count <= Self.maximumLabelBytes,
              !approvedToolNames.isEmpty,
              approvedToolNames.count <= Self.maximumToolCount else {
            return false
        }
        return approvedToolNames.allSatisfy {
            !$0.isEmpty && $0.utf8.count <= Self.maximumToolNameBytes
        }
    }
}

/// Wraps the host executor. It never changes the descriptor catalog and never
/// invents a permission decision; it only refuses to begin execution when the
/// exact admitted task epoch is no longer live or a stop/settlement happened.
struct FloeMacSelfFencedToolExecutor: ToolExecutor {
    private let wrapped: any ToolExecutor
    private let allowedToolNames: Set<String>
    private let fence: FloeMacSelfRunFence
    private let epoch: FloeMacSelfTaskEpoch

    init(
        wrapping wrapped: any ToolExecutor,
        allowedToolNames: Set<String>,
        fence: FloeMacSelfRunFence,
        epoch: FloeMacSelfTaskEpoch
    ) {
        self.wrapped = wrapped
        self.allowedToolNames = allowedToolNames
        self.fence = fence
        self.epoch = epoch
    }

    var allDescriptors: [ToolCatalog.Descriptor] {
        wrapped.allDescriptors
    }

    func descriptor(named name: String) -> ToolCatalog.Descriptor? {
        wrapped.descriptor(named: name)
    }

    func execute(_ call: ToolCall, context: ToolContext) async throws -> ToolResult {
        try await execute(call, expectedAuthorizationIdentity: nil, context: context)
    }

    func execute(
        _ call: ToolCall,
        expectedAuthorizationIdentity: String?,
        context: ToolContext
    ) async throws -> ToolResult {
        guard fence.isCurrentEpoch(epoch),
              allowedToolNames.contains(call.toolName),
              let descriptor = wrapped.descriptor(named: call.toolName) else {
            return denied(call, "The tool is outside this Mac task's admitted capability set")
        }
        // This is the actual task-epoch + stop check. It runs immediately
        // before the host executor can begin, and the runtime's own
        // cancellation token is checked as well. A stop recorded after this
        // point is still handled by the runtime/executor cancellation path.
        guard fence.permitsSideEffectExecution else {
            return denied(call, "The Mac task is stopping or no longer owns this run")
        }
        if let expectedAuthorizationIdentity,
           descriptor.authorizationIdentity != expectedAuthorizationIdentity {
            return denied(
                call,
                "Tool authority changed after approval; review the updated tool before retrying"
            )
        }
        try context.cancellation.throwIfCancelled()
        return try await wrapped.execute(
            call,
            expectedAuthorizationIdentity: expectedAuthorizationIdentity,
            context: context
        )
    }

    private func denied(_ call: ToolCall, _ summary: String) -> ToolResult {
        ToolResult(
            callID: call.id,
            status: .denied,
            outputSummary: summary,
            outputDigest: ""
        )
    }
}
