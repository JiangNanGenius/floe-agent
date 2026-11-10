import Foundation
import FloeModels

/// Adapts native receipts into the separate procedure-learning model. The
/// owning service must check durable run/conversation identity before use.
public enum ExecutionExperienceObservationBuilder {
    public static func observation(
        runID: UUID,
        conversationID: UUID,
        workspaceID: UUID?,
        isTemporary: Bool,
        sourceRunCompleted: Bool,
        events: [RunEventRecord],
        outcomes: [ToolOutcomeClassification],
        observedAt: Date
    ) -> ExecutionSequenceObservation? {
        // Keep rejection visible for mixed runs even if a foreign event is
        // not a tool event. Assistant prose is never used as evidence.
        guard events.allSatisfy({ $0.runID == runID }) else { return nil }
        let lifecycle = events.compactMap { event -> ExecutionExperienceEvidenceCollector.Event? in
            let kind: ExecutionExperienceEvidenceCollector.Event.Kind
            switch event.kind {
            case .toolRequest: kind = .request
            case .toolResult: kind = .result
            default: return nil
            }
            return .init(id: event.id, runID: event.runID, sequence: event.sequence,
                         kind: kind, payloadJSON: event.payloadJSON, createdAt: event.createdAt)
        }
        let collected = ExecutionExperienceEvidenceCollector.collect(
            runID: runID, isTemporary: isTemporary, sourceRunCompleted: sourceRunCompleted,
            events: lifecycle,
            outcomes: outcomes.map {
                .init(callID: $0.callID, toolName: $0.toolName, status: $0.status,
                      kind: $0.kind.rawValue, recovery: $0.recovery.rawValue)
            },
            availableToolNames: Set(outcomes.map(\.toolName))
        )
        guard collected.rejection == nil, !collected.calls.isEmpty else { return nil }
        let calls = collected.calls
        var steps: [ExecutionStepObservation] = []
        for (index, call) in calls.enumerated() {
            guard let outcome = ExecutionOutcomeKind(rawValue: call.outcomeKind),
                  let recovery = ExecutionToolRecovery(rawValue: call.recovery) else { return nil }
            steps.append(.init(
                toolName: call.toolName, callID: call.callID, outcome: outcome,
                recovery: recovery, dispatched: true, captureRef: nil,
                settledAt: call.settledAt,
                orderAttestedBeforeNext: index + 1 < calls.count
                    && call.wasObservedBefore(calls[index + 1])
            ))
        }
        let observation = ExecutionSequenceObservation(
            conversationID: conversationID, runID: runID, workspaceID: workspaceID,
            isTemporaryConversation: isTemporary, steps: steps,
            runConclusion: .completed, observedAt: observedAt
        )
        return observation.structuralValidationIssue() == nil ? observation : nil
    }
}
