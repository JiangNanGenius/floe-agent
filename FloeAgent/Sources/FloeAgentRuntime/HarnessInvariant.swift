import Foundation
import FloeCore
import FloeModels

/// Fail-closed consistency checks at the two durable harness boundaries:
/// checkpoint persistence and provider dispatch. These checks deliberately
/// describe semantic invariants rather than one provider's wire format.
enum HarnessInvariantRegistry {
    struct Violation: Sendable, Hashable, CustomStringConvertible {
        var name: String
        var detail: String

        var description: String { "\(name): \(detail)" }
    }

    static func validateProviderBoundary(
        calls: [ToolCall],
        results: [ToolResult],
        lifecycleByCallID: [String: AgentToolLifecycleEntry]
    ) -> [Violation] {
        var violations = validateCallResultIdentity(calls: calls, results: results)
        guard violations.isEmpty else { return violations }

        for call in calls {
            guard let lifecycle = lifecycleByCallID[call.id] else {
                violations.append(Violation(
                    name: "provider.lifecycleMissing",
                    detail: "call \(call.id) has a result but no durable lifecycle entry"
                ))
                continue
            }
            if lifecycle.toolName != call.toolName {
                violations.append(Violation(
                    name: "provider.lifecycleToolMismatch",
                    detail: "call \(call.id) changed from \(lifecycle.toolName) to \(call.toolName)"
                ))
            }
            if lifecycle.phase != .resultCommitted {
                violations.append(Violation(
                    name: "provider.resultNotCommitted",
                    detail: "call \(call.id) is \(lifecycle.phase.rawValue), expected resultCommitted"
                ))
            }
        }
        return violations
    }

    static func validateCheckpoint(_ checkpoint: AgentCheckpoint) -> [Violation] {
        var violations: [Violation] = []
        switch checkpoint.state {
        case .streamingModel, .executingTool, .cancelling:
            violations.append(Violation(
                name: "checkpoint.replayUnsafeState",
                detail: "persisted state \(checkpoint.state.name) must be downgraded to preparing"
            ))
        default:
            break
        }

        let calls = checkpoint.pendingToolCalls
        let results = checkpoint.pendingToolResults
        let callIDs = calls.map(\.id)
        let resultIDs = results.map(\.callID)
        if callIDs.contains(where: { $0.isEmpty }) {
            violations.append(Violation(
                name: "checkpoint.emptyCallID",
                detail: "pending tool calls must have non-empty identifiers"
            ))
        }
        if Set(callIDs).count != callIDs.count {
            violations.append(Violation(
                name: "checkpoint.duplicateCallID",
                detail: "pending tool-call identifiers must be unique"
            ))
        }
        if Set(resultIDs).count != resultIDs.count {
            violations.append(Violation(
                name: "checkpoint.duplicateResultID",
                detail: "pending tool results must be unique per call"
            ))
        }
        let callIDSet = Set(callIDs)
        for resultID in resultIDs where !callIDSet.contains(resultID) {
            violations.append(Violation(
                name: "checkpoint.orphanResult",
                detail: "result \(resultID) has no pending provider call"
            ))
        }

        let lifecycle = Dictionary(
            (checkpoint.toolLifecycleEntries ?? []).map { ($0.callID, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        if lifecycle.count != (checkpoint.toolLifecycleEntries ?? []).count {
            violations.append(Violation(
                name: "checkpoint.duplicateLifecycleID",
                detail: "tool lifecycle identifiers must be unique"
            ))
        }
        for call in calls {
            guard let entry = lifecycle[call.id] else {
                violations.append(Violation(
                    name: "checkpoint.lifecycleMissing",
                    detail: "pending call \(call.id) has no lifecycle boundary"
                ))
                continue
            }
            if entry.toolName != call.toolName {
                violations.append(Violation(
                    name: "checkpoint.lifecycleToolMismatch",
                    detail: "pending call \(call.id) changed tool identity"
                ))
            }
            let hasResult = resultIDs.contains(call.id)
            if hasResult && entry.phase != .resultCommitted {
                violations.append(Violation(
                    name: "checkpoint.uncommittedResult",
                    detail: "pending call \(call.id) has a result while lifecycle is \(entry.phase.rawValue)"
                ))
            }
            if !hasResult && entry.phase == .resultCommitted {
                violations.append(Violation(
                    name: "checkpoint.missingCommittedResult",
                    detail: "pending call \(call.id) is resultCommitted but its paired result is absent"
                ))
            }
        }
        for entry in lifecycle.values
        where !callIDSet.contains(entry.callID) && entry.phase != .resultCommitted {
            violations.append(Violation(
                name: "checkpoint.orphanOpenLifecycle",
                detail: "open lifecycle \(entry.callID) has no pending provider call"
            ))
        }
        if let envelope = checkpoint.providerDispatchEnvelope {
            if envelope.messagesDigest.isEmpty || envelope.toolSchemasDigest.isEmpty {
                violations.append(Violation(
                    name: "checkpoint.dispatchDigestMissing",
                    detail: "provider dispatch envelope must identify messages and tool schemas"
                ))
            }
            if envelope.pendingCallIDs != envelope.pendingResultCallIDs {
                violations.append(Violation(
                    name: "checkpoint.dispatchPairingMismatch",
                    detail: "provider dispatch envelope must preserve ordered call/result pairing"
                ))
            }
        }
        return violations
    }

    static func summary(_ violations: [Violation]) -> String {
        violations.prefix(6).map(\.description).joined(separator: "; ")
    }

    private static func validateCallResultIdentity(
        calls: [ToolCall],
        results: [ToolResult]
    ) -> [Violation] {
        let callIDs = calls.map(\.id)
        let resultIDs = results.map(\.callID)
        guard callIDs.allSatisfy({ !$0.isEmpty }),
              Set(callIDs).count == callIDs.count,
              Set(resultIDs).count == resultIDs.count,
              callIDs.count == resultIDs.count,
              callIDs == resultIDs else {
            return [Violation(
                name: "provider.callResultPairing",
                detail: "provider calls and results must form one complete ordered one-to-one set"
            )]
        }
        return []
    }
}
