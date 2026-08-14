// FloeApp — Conversation coordinator (app-level seam).
//
// SPDX-License-Identifier: MPL-2.0
//
// Owns the conversation list and the live ConversationRunService actors
// keyed by run ID. Views bind only to this center, never to stores or
// runtimes directly. Cancellation, retry and model switch all funnel here
// so the persisted thread and the live runtime never diverge. Secrets stay
// in Keychain: the API key is resolved via KeychainSecretStore only at the
// call site and never retained.

#if canImport(SwiftUI) && canImport(UIKit)
import Foundation
import FloeCore
import FloeModels
import FloeAgentRuntime
import FloePersistence
import FloeProviders
import FloeSecurity
import FloeTools

/// A human-decision prompt surfaced by a run in `.waitingApproval`. Wraps
/// the runtime's waiting payload with the tool descriptor's deterministic
/// risk labels so the approval card can show scope and rationale.
struct PendingApproval: Identifiable, Hashable, Sendable {
    let runID: UUID
    let conversationID: UUID
    let toolCall: ToolCall
    /// Why the policy escalated to a human.
    let reason: String
    /// Deterministic catalog risk labels (never model-derived).
    let riskLabels: Set<String>
    let isSideEffecting: Bool
    let requestedAt: Date

    var id: String { toolCall.id }

    /// Human-readable scope description for the approval card.
    var scopeDescription: String {
        switch toolCall.scope {
        case .local:
            return "local"
        case .host(let id):
            return "host \(id.uuidString)"
        case .hostPath(let hostID, let path):
            return "host \(hostID.uuidString) · \(path)"
        }
    }
}

/// Coordinates conversations and agent runs for the UI layer.
@MainActor
final class ConversationCenter: ObservableObject {

    // MARK: - Published state

    /// Conversations in deterministic recency order.
    @Published private(set) var conversations: [ConversationRecord] = []
    /// Live runs keyed by run ID, refreshed from snapshots.
    @Published private(set) var activeRuns: [UUID: RunRecord] = [:]
    /// Outstanding human approvals across all live runs.
    @Published private(set) var pendingApprovals: [PendingApproval] = []
    /// Providers, refreshed lazily so the UI can gate the composer honestly.
    @Published private(set) var providers: [ProviderProfile] = []
    /// Enabled models keyed by provider ID.
    @Published private(set) var modelsByProvider: [UUID: [ModelProfile]] = [:]

    let environment: AppEnvironment

    /// Live run services keyed by run ID. The center is the single owner;
    /// thread view-models observe through it.
    private var runServices: [UUID: ConversationRunService] = [:]
    /// Snapshot polling tasks keyed by run ID.
    private var snapshotTasks: [UUID: Task<Void, Never>] = [:]
    private let adapterFactory = ProviderAdapterFactory()

    init(environment: AppEnvironment) {
        self.environment = environment
    }

    // MARK: - Loading

    /// Reloads conversations, providers and models from the stores.
    func reload() async {
        async let loadedConversations = environment.conversationStore.conversations()
        async let loadedProviders = environment.configurationStore.providers()
        async let loadedModels = environment.configurationStore.models()
        do {
            conversations = try await loadedConversations
                .sorted { $0.updatedAt > $1.updatedAt }
            providers = try await loadedProviders.filter(\.isEnabled)
            let models = try await loadedModels.filter(\.isEnabled)
            modelsByProvider = Dictionary(grouping: models, by: \.providerID)
        } catch {
            // Honest degradation: keep prior state; the list surfaces empty.
        }
    }

    /// Creates a conversation with an optional title and refreshes the list.
    @discardableResult
    func createConversation(title: String?) async throws -> ConversationRecord {
        let record = ConversationRecord(
            id: UUID(),
            title: title ?? "",
            createdAt: Date(),
            updatedAt: Date()
        )
        try await environment.conversationStore.saveConversation(record)
        await reload()
        return record
    }

    // MARK: - Run lifecycle

    /// Builds (but does not start) a run service bound to the given
    /// provider and model. Resolves the provider's API key from Keychain at
    /// this call site only; the key is passed to the runtime and discarded.
    func runService(
        for conversationID: UUID,
        provider: ProviderProfile,
        model: ModelProfile
    ) throws -> ConversationRunService {
        let credentials = resolveCredentials(for: provider)
        let configuration = FloeAgentRuntime.Configuration(
            conversationID: conversationID,
            provider: provider,
            model: model
        )
        return ConversationRunService(
            configuration: configuration,
            adapter: adapterFactory.adapter(for: provider),
            policy: HumanApprovalPolicy(),
            executor: CatalogToolExecutor(),
            credentials: credentials,
            gate: environment.catastrophicGate,
            conversationStore: environment.conversationStore,
            runStore: environment.runStore
        )
    }

    /// Starts a new run for `goal` in a conversation and tracks it.
    func send(
        goal: String,
        in conversationID: UUID,
        provider: ProviderProfile,
        model: ModelProfile
    ) async throws {
        let trimmed = goal.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw FloeError.validationFailed("Goal must not be empty")
        }
        let service = try runService(for: conversationID, provider: provider, model: model)
        runServices[service.runID] = service
        track(service)
        try await service.start(goal: trimmed)
    }

    /// Cancels a live run. The runtime owns the terminal transition.
    func cancel(runID: UUID) async {
        guard let service = runServices[runID] else { return }
        await service.cancel()
    }

    /// Retries a terminal run by starting a fresh run with the same goal,
    /// provider and model in the same conversation.
    func retry(runID: UUID) async throws {
        guard let record = try await environment.runStore.run(id: runID) else {
            throw FloeError.notFound("run \(runID.uuidString)")
        }
        let (provider, model) = try await resolveProviderAndModel()
        try await send(
            goal: record.goal,
            in: record.conversationID,
            provider: provider,
            model: model
        )
    }

    /// Starts the follow-up run of a conversation with a different model.
    /// A model switch never mutates the in-flight run; it applies to the
    /// next run, preserving the append-only thread.
    func switchModel(runID: UUID, to model: ModelProfile) async throws {
        guard let record = try await environment.runStore.run(id: runID) else {
            throw FloeError.notFound("run \(runID.uuidString)")
        }
        guard let provider = providers.first(where: { $0.id == model.providerID }) else {
            throw FloeError.notFound("provider \(model.providerID.uuidString)")
        }
        try await send(
            goal: record.goal,
            in: record.conversationID,
            provider: provider,
            model: model
        )
    }

    /// Resolves a pending human approval, then forgets it.
    func resolve(_ approval: PendingApproval, decision: ApprovalDecision) async {
        guard let service = runServices[approval.runID] else { return }
        await service.resolveApproval(decision)
        pendingApprovals.removeAll { $0.id == approval.id }
    }

    /// The live service for a run, if this center owns one.
    func service(for runID: UUID) -> ConversationRunService? {
        runServices[runID]
    }

    /// The most recent run record for a conversation, if any.
    func latestRun(conversationID: UUID) async -> RunRecord? {
        let runs = (try? await environment.runStore.runs(conversationID: conversationID)) ?? []
        return runs.first // store ordering is started_at DESC
    }

    /// Whether any provider+model pair is configured. When false the UI
    /// must show the actionable add-a-provider state, never fake messages.
    var hasConfiguredProvider: Bool {
        providers.contains { modelsByProvider[$0.id]?.isEmpty == false }
    }

    /// Persists a new or updated provider and refreshes the cached lists.
    func saveProvider(_ provider: ProviderProfile) async throws {
        try await environment.configurationStore.saveProvider(provider)
        await reload()
    }

    /// Persists a model and refreshes the cached lists.
    func saveModel(_ model: ModelProfile) async throws {
        try await environment.configurationStore.saveModel(model)
        await reload()
    }

    /// Deletes a provider (cascades to its models) and refreshes.
    func deleteProvider(id: UUID) async throws {
        try await environment.configurationStore.deleteProvider(id: id)
        await reload()
    }

    /// Deletes a model and refreshes.
    func deleteModel(id: UUID) async throws {
        try await environment.configurationStore.deleteModel(id: id)
        await reload()
    }

    /// The default provider+model pair for a new run (first enabled).
    func defaultProviderAndModel() -> (ProviderProfile, ModelProfile)? {
        for provider in providers {
            if let model = modelsByProvider[provider.id]?.first {
                return (provider, model)
            }
        }
        return nil
    }

    // MARK: - Snapshot tracking

    /// Polls a run's snapshot until it reaches a terminal state, keeping
    /// activeRuns and pendingApprovals in step with the runtime.
    private func track(_ service: ConversationRunService) {
        let runID = service.runID
        snapshotTasks[runID]?.cancel()
        snapshotTasks[runID] = Task { [weak self, weak service] in
            guard let service else { return }
            while !Task.isCancelled {
                guard let self else { return }
                let snapshot = await service.snapshot()
                self.apply(snapshot)
                if snapshot.isTerminal { break }
                try? await Task.sleep(for: .milliseconds(250))
            }
            self?.snapshotTasks[runID] = nil
        }
    }

    private func apply(_ snapshot: ConversationRunService.Snapshot) {
        let existing = activeRuns[snapshot.runID]
        activeRuns[snapshot.runID] = RunRecord(
            id: snapshot.runID,
            conversationID: snapshot.conversationID,
            state: snapshot.stateName,
            goal: existing?.goal ?? "",
            startedAt: existing?.startedAt ?? Date(),
            endedAt: snapshot.isTerminal ? (existing?.endedAt ?? Date()) : nil
        )
        if snapshot.stateName == "waitingApproval" {
            Task { await refreshApproval(for: snapshot.runID) }
        } else {
            pendingApprovals.removeAll { $0.runID == snapshot.runID }
        }
    }

    /// Rebuilds the pending approval for a run from its service's runtime
    /// state. Only called while the run reports `waitingApproval`.
    private func refreshApproval(for runID: UUID) async {
        guard let service = runServices[runID] else { return }
        // The snapshot carries only the state name; the waiting payload
        // (tool call, reason) is persisted as the latest approval event.
        let events = (try? await environment.runStore.events(runID: runID)) ?? []
        guard let approvalEvent = events.last(where: { $0.kind == .approval }) else { return }
        let payload = Self.decodePayload(approvalEvent.payloadJSON)
        let toolName = payload["tool"] ?? "tool"
        let reason = payload["reason"] ?? ""
        let descriptor = ToolCatalog.descriptor(named: toolName)
        let call = (try? ToolCall(
            id: approvalEvent.id.uuidString,
            toolName: toolName,
            argumentsJSON: Data("{}".utf8),
            scope: .local
        )) ?? nil
        guard let call else { return }
        let pending = PendingApproval(
            runID: runID,
            conversationID: service.conversationID,
            toolCall: call,
            reason: reason,
            riskLabels: Set(descriptor?.riskLabels.map(\.rawValue) ?? []),
            isSideEffecting: descriptor?.isSideEffecting ?? true,
            requestedAt: approvalEvent.createdAt
        )
        if !pendingApprovals.contains(where: { $0.id == pending.id }) {
            pendingApprovals.append(pending)
        }
    }

    // MARK: - Helpers

    /// Resolves a provider's API key from Keychain at the call site only.
    /// Exposed for the provider editor's Test connection; the key is never
    /// stored on self or in any @Published state.
    func resolveCredentials(for provider: ProviderProfile) -> ProviderCredentials {
        guard let secretRef = provider.secretRef else { return ProviderCredentials() }
        let store = KeychainStore(
            service: "org.floeagent.ios.secrets",
            synchronizable: secretRef.synchronizable
        )
        let data = try? store.read(account: secretRef.keychainAccount)
        return ProviderCredentials(apiKey: data.flatMap { String(data: $0, encoding: .utf8) })
    }

    private func resolveProviderAndModel() async throws -> (ProviderProfile, ModelProfile) {
        if let pair = defaultProviderAndModel() { return pair }
        throw FloeError.invalidConfiguration("No provider and model configured")
    }

    static func decodePayload(_ json: String) -> [String: String] {
        guard let data = json.data(using: .utf8),
              let object = try? JSONDecoder().decode([String: String].self, from: data) else {
            return [:]
        }
        return object
    }
}
#endif
