// SPDX-License-Identifier: MPL-2.0
//
// Exact-run approval commands. The UI must echo the conversation, run and
// workspace identities it observed, plus the exact pending call. The session
// validates every field against its own immutable identity and the live
// pending approval before forwarding to the existing runtime.

import Foundation
import FloeSecurity

public struct FloeMacSelfApprovalCommand: Sendable, Hashable {
    public let conversationID: UUID
    public let runID: UUID
    public let workspaceID: UUID
    public let callID: String
    public let toolName: String
    public let decision: ApprovalDecision
    public let requestedAt: Date?

    public init(
        conversationID: UUID,
        runID: UUID,
        workspaceID: UUID,
        callID: String,
        toolName: String,
        decision: ApprovalDecision,
        requestedAt: Date? = nil
    ) {
        self.conversationID = conversationID
        self.runID = runID
        self.workspaceID = workspaceID
        self.callID = callID
        self.toolName = toolName
        self.decision = decision
        self.requestedAt = requestedAt
    }
}

public enum FloeMacSelfApprovalResolution: Sendable, Hashable {
    /// The runtime accepted the decision for the exact pending call.
    case accepted
    /// The runtime no longer had that call pending (raced with cancel/finish).
    case notPending
    case rejected(FloeMacSelfApprovalRejection)
}
