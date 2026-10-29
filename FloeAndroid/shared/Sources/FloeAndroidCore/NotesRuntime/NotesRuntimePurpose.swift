// SPDX-License-Identifier: MPL-2.0
//
// G06 Notes-purpose run identity and the narrow domain accessors the assistant
// coordinator needs.
//
// A Notes launch reuses the SAME accepted-epoch `FacadeRunDomain`,
// `ConversationRunService`, `FloeAgentRuntime`, provider adapter, catastrophic
// gate, credential resolver and durable stores. Only three things differ:
//   * the execution identity is `.notes` (the conversation row's purpose is
//     `notes`, never retagged from ordinary),
//   * the persistence bundle disables intelligence/discovery/taskChecklist and
//     the child graph (no delegation, no Linux/environment/job role),
//   * the tool ceiling is the closed `notes.read/search/edit` set on an
//     isolated registry.
// Nothing here relaxes an ordinary guard: the ordinary entry keeps calling
// `ordinaryExists` and the same expected-purpose writer check.
import Foundation
import FloeCore
import FloeModels
import FloePersistence
import FloeAgentRuntime

// MARK: - Identity ↔ purpose

public extension RunExecutionIdentity {
    /// The durable `conversations.purpose` value this execution identity is
    /// allowed to run. A row of another purpose is NEVER retagged.
    var conversationPurpose: ConversationPurpose {
        switch self {
        case .ordinary: return .ordinary
        case .temporary: return .temporary
        case .notes: return .notes
        }
    }

    /// The exact row `purpose` string used by the original launch writer's
    /// existing-row check.
    var launchRowPurpose: String { conversationPurpose.rawValue }
}

// MARK: - Notes persistence bundle

public extension RunPersistenceBundle {
    /// The Notes bundle over the SAME original durable store instances. The
    /// assistant is chat-only: no goal/plan intelligence, no discovery
    /// projection, no ordinary checklist, no durable child graph.
    static func notesBundle(from durable: RunPersistenceBundle) -> RunPersistenceBundle {
        RunPersistenceBundle(
            identity: .notes,
            conversations: durable.conversations,
            runs: durable.runs,
            runningInputs: durable.runningInputs,
            launches: durable.launches,
            childRuns: nil,
            intelligence: nil,
            discovery: nil,
            taskChecklist: nil)
    }
}

// MARK: - Domain accessors for the Notes coordinator

extension FacadeRunDomain {
    func notesConversationStore() -> any ConversationStore { components.durable.conversations }
    func notesRunningInputStore() -> any RunningInputStore { components.durable.runningInputs }
    func notesWorkspaceStore() -> SQLiteWorkspaceStore { components.workspaceStore }
    func notesModelStore() -> ModelConfigurationStore { components.modelStore }

    /// Current opaque conversation-row digest (the SAME
    /// `floe.conversation-row.v1` value the ordinary CAS uses).
    func notesConversationRevision(conversationID: UUID) async -> String? {
        try? await components.conversationRevisions.digest(conversationID: conversationID)
    }

    /// Accepted Notes runs owned by THIS generation (optionally one
    /// conversation). A retired run is not live.
    func notesLiveRunIDs(conversationID: UUID?) -> [UUID] {
        owners.values
            .filter { ownership in
                ownership.identity == .notes
                    && ownership.phase != .retired
                    && (conversationID == nil || ownership.conversationID == conversationID)
            }
            .map(\.runID)
            .sorted { $0.uuidString < $1.uuidString }
    }

    /// Exact owned-token projection for the drain proof.
    func notesOwnedRunTokens(conversationIDs: Set<UUID>?) -> [(
        runID: UUID, conversationID: UUID, phase: RunLaunchPhase,
        tokens: [RuntimeOwnedWorkToken]
    )] {
        owners.values
            .filter { ownership in
                ownership.identity == .notes
                    && (conversationIDs == nil || conversationIDs!.contains(ownership.conversationID))
            }
            .map { ownership in
                (runID: ownership.runID,
                 conversationID: ownership.conversationID,
                 phase: ownership.phase,
                 tokens: Array(ownership.ownedTokens.values))
            }
            .sorted { $0.runID.uuidString < $1.runID.uuidString }
    }

    /// Latest evidence for one Notes conversation: a live owner first, then the
    /// newest durable run row.
    func notesLatestRunID(conversationID: UUID) async -> UUID? {
        if let live = notesLiveRunIDs(conversationID: conversationID).first { return live }
        let runs = (try? await components.durable.runs.runs(conversationID: conversationID))
            ?? []
        return runs.sorted {
            ($0.startedAt, $0.id.uuidString) > ($1.startedAt, $1.id.uuidString)
        }.first?.id
    }

    func notesRunState(conversationID: UUID) async -> String? {
        if let live = notesLiveRunIDs(conversationID: conversationID).first,
           let ownership = owners[live] {
            switch ownership.phase {
            case .admitting: return "preparing"
            case .prepared: return "preparing"
            case .handedOff: return "running"
            case .terminating: return "cancelling"
            case .retired: break
            }
        }
        guard let runID = await notesLatestRunID(conversationID: conversationID) else {
            return nil
        }
        if let ownership = owners[runID] {
            switch ownership.phase {
            case .admitting, .prepared: return "preparing"
            case .handedOff: return "running"
            case .terminating: return "cancelling"
            case .retired: break
            }
        }
        return (try? await components.durable.runs.run(id: runID))??.state
    }

    /// Exact ownership proof for one live Notes run (id only; no service or
    /// store escapes). Used by the trusted review step to prove the run that
    /// received a tool call is still the owner.
    func notesRunOwnership(runID: UUID) -> (conversationID: UUID,
                                            phase: RunLaunchPhase,
                                            cancelRequested: Bool)? {
        guard let ownership = owners[runID], ownership.identity == .notes else {
            return nil
        }
        return (ownership.conversationID, ownership.phase, ownership.cancelRequested)
    }

    /// The optional persisted default-agent route, resolved through the SAME
    /// `RunModelAssembly` the ordinary composer uses. Never a first-provider
    /// guess. nil = honestly unconfigured.
    func notesResolvePreferred(modelID: UUID?) async throws
        -> RunModelAssembly.ResolvedPair? {
        try await assembly.resolvePreferred(modelID: modelID)
    }

    /// Chat capability admission for the resolved pair (the ORIGINAL
    /// `RunModelAssembly.admit`; no parallel capability rule).
    func notesAdmitChat(model: ModelProfile) async throws {
        try await assembly.admit(mode: .chat, model: model, hasImages: false)
    }

    /// Terminals of one run, newest last: `(state, stopReason)` where
    /// `stopReason` is the DURABLE terminal event payload when one exists.
    func notesRunOutcome(runID: UUID) async -> (state: String?, stopReason: String?) {
        let state = (try? await components.durable.runs.run(id: runID))??.state
        let events = (try? await components.durable.runs.recentEvents(runID: runID, limit: 64))
            ?? []
        var stopReason: String?
        for event in events.reversed() where event.kind == .terminal {
            if let data = event.payloadJSON.data(using: .utf8),
               let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                stopReason = object["stopReason"] as? String
                    ?? object["terminal"] as? String
            }
            break
        }
        return (state, stopReason)
    }

    /// Requests the ORIGINAL `ConversationRunService.cancel()` for one owned
    /// Notes run. Returns false for a foreign/unknown identity (this never
    /// pretends to cancel another surface's run).
    func notesCancel(runID: UUID) async -> Bool {
        guard var ownership = owners[runID], ownership.identity == .notes else {
            return false
        }
        switch ownership.phase {
        case .admitting:
            ownership.cancelRequested = true
            register(ownership)
            return true
        case .prepared:
            ownership.cancelRequested = true
            ownership.phase = .terminating
            let bundle = ownership.bundle
            register(ownership)
            await markCommittedLaunchAbandoned(runID: runID,
                                               reason: "cancelledDuringPrepare",
                                               bundle: bundle)
            await retire(runID: runID, terminalSucceeded: false, feedTerminal: false)
            return true
        case .handedOff:
            ownership.phase = .terminating
            register(ownership)
            if let service = liveServices[runID] {
                await service.cancel()
            }
            return true
        case .terminating, .retired:
            return true
        }
    }

    // MARK: - Notes launch

    /// Trusted-internal Notes launch. NEVER reachable from the ordinary wire
    /// grammars: `run.start`/`run.startTask` still prove `ordinaryExists` and
    /// refuse a `notes` row exactly like absence.
    public func startNotes(conversationID: UUID,
                           goal: String,
                           providerID: UUID,
                           modelID: UUID,
                           expectedRevision: String,
                           binding: NotesRunBinding,
                           capturedLaunch: RunModelAssembly.ResolvedPair? = nil) async
        -> RunDomainReply {
        guard components.notesRuntime != nil else {
            return RunDomainReply(.rejected(RunDomainError(.needsConfiguration,
                                                           .notesRuntimeUnbound)))
        }
        if retirementFenced {
            return RunDomainReply(.rejected(RunDomainError(.sessionFenced,
                                                           .generationRetired)))
        }
        guard binding.conversationID == conversationID else {
            return RunDomainReply(.rejected(RunDomainError(.invalidState, .payloadInvalid)))
        }
        // Exact purpose proof BEFORE any effect: a notes row only, never an
        // ordinary/temporary row and never a guessed identity.
        do {
            let purpose = try await components.conversationRevisions
                .purpose(of: conversationID)
            guard purpose == .notes else {
                throw RunDomainError(.notFound, .conversationMissing)
            }
        } catch let error as RunDomainError {
            return RunDomainReply(.rejected(error.addingPhase(.conversationProof)))
        } catch {
            return RunDomainReply(.rejected(RunDomainError(
                .persistenceUnavailable, .storeReadFailed, phase: .conversationProof)))
        }
        // One assistant turn per conversation: a live Notes run or an in-flight
        // Notes admission refuses honestly instead of interleaving content.
        guard notesLiveRunIDs(conversationID: conversationID).isEmpty else {
            return RunDomainReply(.rejected(RunDomainError(.invalidState,
                                                           .conversationActive)))
        }
        guard notesAdmissions.insert(conversationID).inserted else {
            return RunDomainReply(.rejected(RunDomainError(.duplicateInFlight,
                                                           .launchAlreadyInFlight)))
        }
        defer { notesAdmissions.remove(conversationID) }
        let query = RunStartQuery(
            conversationID: conversationID,
            goal: goal,
            mode: .chat,
            providerID: providerID,
            modelID: modelID,
            stagedAttachmentHandles: [],
            hostToolCeiling: NotesAssistantToolNames.all,
            policy: DraftTaskPolicy(approvalMode: .ask,
                                    recoveryPolicy: .safePoint,
                                    notificationPolicy: .off),
            requestedEnvironmentID: nil,
            requestedJobID: nil,
            goalDefinition: nil)
        let bundle = RunPersistenceBundle.notesBundle(from: durable)
        return await start(query: query,
                           receipt: nil,
                           conversationID: conversationID,
                           bundleOverride: bundle,
                           expectedConversationRevision: expectedRevision,
                           capturedLaunch: capturedLaunch,
                           notesBinding: binding)
    }
}
