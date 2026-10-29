// SPDX-License-Identifier: MPL-2.0
//
// G06 Notes-purpose assistant approval policy.
//
// The Notes assistant is a trusted document task: the user opened the panel and
// the editor bound one exact document to this conversation. That binding — not
// model prose, not tool output — is the edit authority. This policy therefore
// answers deterministically for the three closed Notes tools (after the
// catastrophic gate, which the runtime always runs first) and falls back to the
// ordinary human policy for anything else that somehow reached it.
//
// It deliberately has no model-review branch: a note body, a tool result or a
// proposal summary can never approve a call.
import Foundation
import FloeCore
import FloeModels
import FloeSecurity
import FloeTools

struct NotesAssistantApprovalPolicy: ApprovalPolicy, ApprovalReviewRouting {
    let authority: NotesToolAuthority

    var policyName: String { "notes-document-assistant" }

    func requiresModelReview(_ action: ProposedAction) -> Bool { false }

    func decide(_ action: ProposedAction) async throws -> ApprovalDecision {
        guard case .local = action.toolCall.scope else {
            return try await HumanApprovalPolicy().decide(action)
        }
        let name = action.toolCall.toolName
        guard NotesAssistantToolNames.closed.contains(name) else {
            return try await HumanApprovalPolicy().decide(action)
        }
        struct Target: Decodable { let documentID: String }
        guard let target = try? JSONDecoder().decode(Target.self,
                                                     from: action.toolCall.argumentsJSON),
              let documentID = UUID(uuidString: target.documentID) else {
            return .deny(reason: "Invalid Notes tool arguments")
        }
        do {
            if name == NotesAssistantToolNames.edit {
                // Editing additionally requires the live edit grant AND the
                // document's assistant-thread ownership; the native store
                // re-checks it again inside the proposal/apply transaction.
                try await authority.requireLiveEdit(documentID)
            } else {
                try await authority.requireLiveRead(documentID)
            }
        } catch {
            return .deny(reason: "This task no longer has access to that note")
        }
        return .allow(scope: ApprovalScope(toolName: name, singleUse: true),
                      expiresAt: nil)
    }
}
