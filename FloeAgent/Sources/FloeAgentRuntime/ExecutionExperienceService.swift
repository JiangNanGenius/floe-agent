import Foundation
import FloeCore
import FloeModels
import FloePersistence

/// Service-owned, bounded learning from native execution receipts. No model
/// call, task replay, user-profile extraction or executable skill is created.
public actor ExecutionExperienceService {
    private let store: ExecutionExperienceStore
    private let runs: any RunStore
    private let conversations: any ConversationStore
    private let workspaces: any WorkspaceStore
    private let policy = ExecutionExperiencePolicy()
    private var lastRetention = Date.distantPast

    public init(database: DatabaseManager, runs: any RunStore,
                conversations: any ConversationStore, workspaces: any WorkspaceStore) {
        self.store = ExecutionExperienceStore(database: database)
        self.runs = runs
        self.conversations = conversations
        self.workspaces = workspaces
    }

    public func guidance(
        workspaceID: UUID?, isTemporary: Bool,
        availableToolNames: Set<String>, activatedToolNames: Set<String>
    ) async throws -> String? {
        guard !isTemporary else { return nil }
        try Task.checkCancellation()
        let activated = activatedToolNames.intersection(availableToolNames)
        guard !activated.isEmpty else { return nil }
        let now = Date()
        let context = ExecutionExperienceRecallContext(
            workspaceID: workspaceID, availableToolNames: availableToolNames,
            activatedToolNames: activated, now: now
        )
        let records = try await store.recall(.init(
            workspaceID: workspaceID, availableToolNames: context.availableToolNames,
            activatedToolNames: activated,
            notOlderThan: now.addingTimeInterval(-90 * 86_400), maxRecords: 3
        ))
        try Task.checkCancellation()
        guard let rendered = policy.render(records, context: context) else { return nil }
        // Historical scripts cannot become a standing preference when the
        // current app offers a fitting native capability.
        return "Current capabilities and the user's chosen route take precedence over historical methods. Try a currently usable native operation for supported work before an equivalent script; inspect real results and follow the existing fallback rules.\n" + rendered
    }

    /// Called with facts from the completed service's own final snapshot, before its
    /// temporary authority is cleared. The native store is checked again;
    /// assistant prose and a successful invocation are insufficient.
    @discardableResult
    public func recordCompletedRun(
        runID: UUID, conversationID: UUID, stateName: String,
        outcomes: [ToolOutcomeClassification],
        isTemporary: Bool
    ) async throws -> ExecutionExperienceStore.UpsertOutcome? {
        guard !isTemporary, stateName == "completed" else { return nil }
        try Task.checkCancellation()
        guard let run = try await runs.run(id: runID),
              run.conversationID == conversationID,
              run.state == "completed", let endedAt = run.endedAt,
              let conversation = try await conversations.conversation(id: run.conversationID),
              conversation.purpose != .temporary else { return nil }
        let workspaceID = try await workspaces.workspaceID(conversationID: run.conversationID)
        let events = try await runs.recentEvents(
            runID: run.id, limit: ExecutionExperienceEvidenceCollector.maximumEvents
        )
        guard let observation = ExecutionExperienceObservationBuilder.observation(
            runID: run.id, conversationID: run.conversationID, workspaceID: workspaceID,
            isTemporary: false, sourceRunCompleted: true, events: events,
            outcomes: outcomes, observedAt: endedAt
        ) else { return nil }
        // This derivation accepts only typed procedure structure. There is
        // no content or project-specific detail to promote across tasks.
        let record = try policy.derive(observation, scopeChoice: .generic)
        // Keep a bounded sample of receipt identities; the observation ID
        // binds the complete collected sequence and the run ledger remains
        // authoritative for the other receipts.
        let anchors = observation.steps.prefix(ExecutionExperienceLimits.maximumEvidenceAnchors).map {
            ExecutionExperienceEvidenceAnchor(runID: run.id, callID: $0.callID, captureRef: nil)
        }
        try Task.checkCancellation()
        let runs = self.runs
        let conversations = self.conversations
        let result = try await store.ingest(guarded: .init(
            record: record, observationID: observation.id, evidenceAnchors: anchors,
            observedAt: observation.observedAt,
            sourceRunID: run.id, sourceConversationID: run.conversationID,
            originIsLive: {
                guard !Task.isCancelled,
                      let current = try? await runs.run(id: run.id),
                      current.conversationID == run.conversationID,
                      current.state == "completed", current.endedAt != nil,
                      let owner = try? await conversations.conversation(id: run.conversationID)
                else { return false }
                return owner.purpose != .temporary
            }
        ))
        let now = Date()
        if now.timeIntervalSince(lastRetention) >= 86_400 {
            _ = try await store.enforceRetention(now: now, retentionInterval: 180 * 86_400)
            lastRetention = now
        }
        return result
    }
}
