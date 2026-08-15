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
    /// Workspace identity captured when the approval first became visible.
    /// An allowed workspace action is denied if the user switches roots.
    let workspaceID: UUID?

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
    static let onboardingSkippedDefaultsKey = "org.floeagent.onboarding.skipped"

    /// Writes the launch-critical skip marker synchronously. Interactive
    /// sheet dismissal can be followed immediately by process termination;
    /// forcing the preferences flush prevents the first-run sheet from
    /// resurrecting before the async database write completes.
    static func persistOnboardingSkippedMarker(_ skipped: Bool) {
        if skipped {
            UserDefaults.standard.set(true, forKey: onboardingSkippedDefaultsKey)
        } else {
            UserDefaults.standard.removeObject(forKey: onboardingSkippedDefaultsKey)
        }
        UserDefaults.standard.synchronize()
    }

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
    /// Secret-free onboarding and model-routing choices.
    @Published private(set) var modelPreferences = ModelSelectionPreferences()

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
        async let loadedPreferences = environment.configurationStore.preferences()
        do {
            conversations = try await loadedConversations
                .sorted { $0.updatedAt > $1.updatedAt }
            providers = try await loadedProviders.filter(\.isEnabled)
            let models = try await loadedModels
            modelsByProvider = Dictionary(grouping: models, by: \.providerID)
            modelPreferences = try await loadedPreferences
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
            policy: approvalPolicy(),
            executor: CatalogToolExecutor(),
            credentials: credentials,
            gate: environment.catastrophicGate,
            conversationStore: environment.conversationStore,
            runStore: environment.runStore
        )
    }

    /// Constructs the approval policy from the persisted `agent.defaultMode`
    /// setting, published by SettingsCenter. Defaults to human approval when
    /// the settings center has not loaded yet. `approvalModel` has no
    /// configured backend in P2 and `fullControl` is only meaningful as a
    /// per-host grant minted by the UI layer after Face ID / passcode plus
    /// risk acknowledgement — both fail closed to human approval here.
    private func approvalPolicy() -> any ApprovalPolicy {
        let mode = environment.settingsCenter.defaultAgentMode
        switch mode {
        case .human, .approvalModel, .fullControl:
            // P2: only the human policy has a real decision channel.
            // approvalModel lacks a backend; fullControl requires a per-host
            // grant the conversation flow does not hold. Neither is faked.
            return HumanApprovalPolicy()
        }
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
        let resolvedDecision: ApprovalDecision
        if decision.permitsExecution,
           approval.toolCall.toolName.hasPrefix("workspace."),
           approval.workspaceID != environment.workspaceCenter.currentWorkspace?.id {
            resolvedDecision = .deny(reason: "workspace changed after approval was requested")
        } else {
            resolvedDecision = decision
        }
        await service.resolveApproval(resolvedDecision)
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
    var hasConfiguredProvider: Bool { defaultProviderAndModel() != nil }

    var availableAgentModels: [ModelProfile] {
        let enabledProviderIDs = Set(providers.map(\.id))
        return modelsByProvider.values.flatMap { $0 }
            .filter {
                $0.isEnabled && $0.capabilities.contains(.text)
                    && enabledProviderIDs.contains($0.providerID)
            }
            .sorted {
                $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
            }
    }

    var imageModels: [ModelProfile] {
        let enabledProviderIDs = Set(providers.map(\.id))
        return modelsByProvider.values.flatMap { $0 }
            .filter {
                $0.isEnabled && ($0.capabilities.contains(.imageGeneration)
                    || $0.capabilities.contains(.imageEditing))
                    && enabledProviderIDs.contains($0.providerID)
            }
            .sorted {
                $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
            }
    }

    /// Persists a new or updated provider and refreshes the cached lists.
    func saveProvider(_ provider: ProviderProfile) async throws {
        try await environment.configurationSync.saveProvider(provider)
        await reload()
    }

    /// Persists a model and refreshes the cached lists.
    func saveModel(_ model: ModelProfile) async throws {
        try await environment.configurationSync.saveModel(model)
        await reload()
    }

    @discardableResult
    func saveProviderBundle(
        provider: ProviderProfile,
        models: [ModelProfile]
    ) async throws -> [ModelProfile] {
        let previousChatIDs = Set((modelsByProvider[provider.id] ?? [])
            .filter { $0.capabilities.contains(.text) }
            .map(\.id))
        let saved = try await environment.configurationStore.saveProviderBundle(
            provider: provider,
            models: models
        )
        try await environment.configurationSync.saveProvider(provider)
        for model in saved {
            try await environment.configurationSync.saveModel(model)
        }
        let savedIDs = Set(saved.map(\.id))
        for removedID in previousChatIDs.subtracting(savedIDs) {
            try await environment.configurationSync.deleteModel(id: removedID)
        }
        await reload()
        return saved
    }

    func saveModelPreferences(_ preferences: ModelSelectionPreferences) async throws {
        var updated = preferences
        updated.updatedAt = Date()
        updated.syncRevision += 1
        try await environment.configurationSync.savePreferences(updated)
        switch updated.onboardingStatus {
        case .skipped:
            Self.persistOnboardingSkippedMarker(true)
        case .completed, .unseen:
            Self.persistOnboardingSkippedMarker(false)
        }
        await reload()
    }

    /// On the first launch only, an already-synced text model completes the
    /// wizard automatically. A skipped wizard is never shown again.
    func reconcileOnboardingForLaunch() async {
        await reload()
        guard modelPreferences.onboardingStatus == .unseen,
              let first = availableAgentModels.first else { return }
        var preferences = modelPreferences
        preferences.defaultAgentModelID = first.id
        preferences.onboardingStatus = .completed
        try? await saveModelPreferences(preferences)
    }

    /// Deletes a provider (cascades to its models) and refreshes.
    func deleteProvider(id: UUID) async throws {
        try await environment.configurationSync.deleteProvider(id: id)
        await reload()
    }

    /// Deletes a model and refreshes.
    func deleteModel(id: UUID) async throws {
        try await environment.configurationSync.deleteModel(id: id)
        await reload()
    }

    /// The explicitly selected default provider+model pair for a new run.
    func defaultProviderAndModel() -> (ProviderProfile, ModelProfile)? {
        guard let modelID = modelPreferences.defaultAgentModelID,
              let model = availableAgentModels.first(where: { $0.id == modelID }),
              let provider = providers.first(where: { $0.id == model.providerID })
        else { return nil }
        return (provider, model)
    }

    func providerAndModel(modelID: UUID?) -> (ProviderProfile, ModelProfile)? {
        guard let modelID else { return defaultProviderAndModel() }
        guard let model = availableAgentModels.first(where: { $0.id == modelID }),
              let provider = providers.first(where: { $0.id == model.providerID })
        else { return nil }
        return (provider, model)
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
        if let waiting = snapshot.pendingApproval {
            let descriptor = ToolCatalog.descriptor(named: waiting.toolCall.toolName)
            let pending = PendingApproval(
                runID: snapshot.runID,
                conversationID: snapshot.conversationID,
                toolCall: waiting.toolCall,
                reason: waiting.reason,
                riskLabels: Set(descriptor?.riskLabels.map(\.rawValue) ?? []),
                isSideEffecting: descriptor?.isSideEffecting ?? true,
                requestedAt: waiting.requestedAt,
                workspaceID: waiting.toolCall.toolName.hasPrefix("workspace.")
                    ? environment.workspaceCenter.currentWorkspace?.id
                    : nil
            )
            pendingApprovals.removeAll { $0.runID == snapshot.runID }
            pendingApprovals.append(pending)
        } else {
            pendingApprovals.removeAll { $0.runID == snapshot.runID }
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
