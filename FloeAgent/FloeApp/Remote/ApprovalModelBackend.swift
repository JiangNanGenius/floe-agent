#if canImport(SwiftUI) && canImport(UIKit)
import Foundation
import FloeCore
import FloeModels
import FloeProviders
import FloeSecurity

/// Tool-free, bounded approval-model call. Only a strict three-value JSON
/// decision is accepted; every other outcome fails closed in the policy.
struct ApprovalModelBackend: ModelApprovalPolicy.DecisionBackend {
    private struct WireDecision: Decodable {
        let decision: String
        let reason: String?
    }

    let adapter: any ProviderAdapter
    let provider: ProviderProfile
    let model: ModelProfile
    let credentials: ProviderCredentials

    func decide(_ action: ProposedAction) async throws -> ApprovalDecision {
        try await withThrowingTaskGroup(of: ApprovalDecision.self) { group in
            group.addTask { try await requestDecision(action) }
            group.addTask {
                try await Task.sleep(for: .seconds(15))
                throw FloeError.syncUnavailable("Approval model timed out")
            }
            guard let first = try await group.next() else {
                throw FloeError.syncUnavailable("Approval model returned no decision")
            }
            group.cancelAll()
            return first
        }
    }

    private func requestDecision(_ action: ProposedAction) async throws -> ApprovalDecision {
        let encoded = try JSONEncoder().encode(action)
        let actionJSON = String(decoding: encoded, as: UTF8.self)
        let prompt = """
            You are a security approval classifier. Return exactly one JSON object and no markdown:
            {"decision":"allow|deny|ask","reason":"short explanation"}
            Never modify the action. Prefer ask when authority or intent is ambiguous.
            Proposed action: \(actionJSON)
            """
        let request = ProviderStreamRequest(
            provider: provider,
            model: model,
            messages: [(role: "user", content: prompt)],
            toolSchemas: []
        )
        var text = ""
        for try await event in adapter.stream(request: request, credentials: credentials) {
            if case .textDelta(let delta) = event {
                text += delta.text
                guard text.utf8.count <= 4_096 else {
                    throw FloeError.validationFailed("Approval response exceeded limit")
                }
            }
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.first == "{", trimmed.last == "}",
              let data = trimmed.data(using: .utf8) else {
            throw FloeError.validationFailed("Approval response was not strict JSON")
        }
        let decision = try JSONDecoder().decode(WireDecision.self, from: data)
        switch decision.decision {
        case "allow": return .allow(scope: scope(for: action.toolCall), expiresAt: nil)
        case "deny": return .deny(reason: decision.reason ?? "Approval model denied the action")
        case "ask": return .escalateToHuman(reason: decision.reason ?? "Approval model requested user review")
        default: throw FloeError.validationFailed("Unknown approval decision")
        }
    }

    private func scope(for call: ToolCall) -> ApprovalScope {
        switch call.scope {
        case .local: ApprovalScope(toolName: call.toolName, singleUse: true)
        case .host(let id): ApprovalScope(toolName: call.toolName, hostID: id, singleUse: true)
        case .hostPath(let id, let path): ApprovalScope(toolName: call.toolName, hostID: id, paths: [path], singleUse: true)
        }
    }
}
#endif
