// SPDX-License-Identifier: MPL-2.0
//
// Fail-closed capability adapters for tool-disabled Mac sessions. These are
// not a permission model: the deny-only policy never allows anything, and the
// executor has no descriptors and denies every call. They exist so a run that
// was started without a real host tool binding cannot accidentally inherit
// the compiled catalog or an implicit approval decision.

import Foundation
import FloeModels
import FloeTools
import FloeSecurity

/// Deny-only policy used only when the host explicitly started a session with
/// no tool capability. It is not registered as a user-selectable mode.
public struct FloeMacSelfToolsDisabledPolicy: ApprovalPolicy {
    public let policyName = "mac-tools-disabled"

    public init() {}

    public func decide(_ action: ProposedAction) async throws -> ApprovalDecision {
        .deny(reason: "Tools are disabled for this Mac session")
    }
}

/// Executor with no visible descriptors. Any unexpected dispatch is recorded
/// as a denied tool result instead of reaching a host effect.
public struct FloeMacSelfDeniedToolExecutor: ToolExecutor {
    public init() {}

    public var allDescriptors: [ToolCatalog.Descriptor] { [] }

    public func descriptor(named name: String) -> ToolCatalog.Descriptor? { nil }

    public func execute(_ call: ToolCall, context: ToolContext) async throws -> ToolResult {
        ToolResult(
            callID: call.id,
            status: .denied,
            outputSummary: "Tools are disabled for this Mac session",
            outputDigest: ""
        )
    }
}
