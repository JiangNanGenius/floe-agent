// SPDX-License-Identifier: MPL-2.0

import Combine
import FloeCore
import FloeMacSelfCore
import FloePersistence
import FloeProviders
import FloeSecurity
import Foundation
#if FLOE_MAC_HOST_SMOKE
import FloeModels
#endif

struct HostAgentProvider: Codable {
    var profile: ProviderProfile
    var model: ModelProfile
    /// This record is encoded only for the app's device-bound Keychain.
    let apiKey: String

    /// The label shown in the provider list: the user-chosen name when set,
    /// otherwise the model ID (the 1.3.0 single-profile behavior).
    var displayTitle: String { profile.displayName ?? model.displayName }

    @MainActor
    init(displayName: String? = nil, endpoint: String, protocolKind: ModelProtocol, modelID: String, apiKey: String) throws {
        guard let endpointURL = URL(string: endpoint.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            throw InvalidConfiguration.endpoint
        }
        let modelID = modelID.trimmingCharacters(in: .whitespacesAndNewlines)
        let apiKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedName = displayName?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !apiKey.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            throw InvalidConfiguration.key
        }
        profile = ProviderProfile(kind: .custom, wireProtocol: protocolKind, baseURL: endpointURL,
                                  displayName: trimmedName?.isEmpty == false ? trimmedName : nil)
        model = ModelProfile(providerID: profile.id, remoteModelID: modelID, displayName: modelID,
                             limits: ModelLimits(contextTokens: 32_768, maxOutputTokens: 0))
        self.apiKey = apiKey
        try validate()
    }

    func validate() throws {
        try ProviderConfigurationValidation.validate(profile)
        try ProviderConfigurationValidation.validate(model)
    }

    func binding() -> FloeMacSelfProviderBinding {
        FloeMacSelfProviderBinding(provider: profile, model: model,
            adapter: ProviderAdapterFactory().adapter(for: profile),
            credentials: ProviderCredentials(apiKey: apiKey.isEmpty ? nil : apiKey))
    }

    private enum InvalidConfiguration: Error {
        case endpoint, key
    }
}

/// Durable multi-provider record persisted in the existing chat Keychain
/// namespace (service `<bundle>.chat`). Version 1 is the first list-capable
/// format; a record written by a newer build fails closed on read so its
/// extra fields are never dropped by an older one. The legacy
/// single-profile account stays in place as a mirror of the selected record
/// so a downgrade to the 1.3.0 layout keeps working.
private struct ProviderListEnvelope: Codable {
    var version: Int
    var providers: [HostAgentProvider]
    var selectedProviderID: UUID?
}

private enum ProviderStoreError: Error {
    case missingRecord
}

@MainActor
final class HostAgentWorkspace: ObservableObject {
    typealias ReleaseWork = @MainActor () -> Void
    typealias AdmitWork = @MainActor () throws -> ReleaseWork
    @Published private(set) var isReady = false
    @Published private(set) var isPreparing = false
    @Published private(set) var isSending = false
    @Published private(set) var isStopping = false
    @Published private(set) var isTerminating = false
    @Published private(set) var modelName: String?
    @Published private(set) var conversations: [ConversationRecord] = []
    @Published private(set) var recentTaskRuns: [UUID: RunRecord] = [:]
    @Published private(set) var taskRunLookupFailed = false
    @Published private(set) var selectedID: UUID?
    @Published private(set) var messages: [PersistedMessage] = []
    @Published private(set) var pendingPrompt: String?
    @Published private(set) var streamedText = ""
    @Published var notice: String?
    private(set) var storageErrorKind: String?

    /// Saved provider records (list order). Records are validated on load;
    /// corrupt entries are dropped and the cleaned list is written back.
    @Published private(set) var providers: [HostAgentProvider] = []
    /// The provider `send` uses for new runs. Nil only when no provider
    /// exists or the Keychain is unavailable.
    @Published private(set) var selectedProviderID: UUID?

    private let supportDirectory: URL
    private let namespace: String
    private let vault: KeychainStore?
    private let admitWork: AdmitWork
    private var runtime: FloeMacSelfRuntime?
    private var activeRun: FloeMacSelfSessionHandle?
    private var taskRunLookup = UUID()
    private static let settingsAccount = "selected-chat-provider.v1"
    private static let providerListAccount = "chat-providers.v2"
    private static let currentProviderListVersion = 1

    init(supportDirectory: URL, namespace: String, useKeychain: Bool = true,
         admitWork: @escaping AdmitWork = { {} }) {
        self.supportDirectory = supportDirectory
        self.namespace = namespace
        self.vault = useKeychain ? KeychainStore(service: namespace + ".chat",
            synchronizable: false, accessibility: .whenUnlockedThisDeviceOnly) : nil
        self.admitWork = admitWork
    }

    func prepare() async {
        guard !isReady, !isPreparing, !isTerminating else { return }
        guard let release = admit() else { return }
        isPreparing = true
        storageErrorKind = nil
        notice = nil
        defer { isPreparing = false; release() }
        do {
            if runtime == nil {
                runtime = try HostAgentDatabase.open(applicationSupport: supportDirectory, namespace: namespace)
            }
            guard let runtime else { return }
            try await runtime.bootstrap()
            conversations = try await runtime.conversations()
            if let recent = conversations.first {
                selectedID = recent.id
                messages = try await runtime.conversationMessages(conversationID: recent.id)
            }
            isReady = true
            reloadProviders()
        } catch {
            if let error = error as? HostAgentDatabase.StorageError {
                storageErrorKind = error.rawValue
            } else if let error = error as? FloeMacSelfCoreError {
                storageErrorKind = error.code
            } else {
                storageErrorKind = "historyUnavailable"
            }
            notice = String(localized: "host.chat.storageUnavailable")
        }
    }

    /// Single-profile form used by the nonunified host. Keeps the 1.3.0
    /// behavior in list terms: update the selected provider when one exists,
    /// otherwise create it and make it the selected provider.
    func saveProvider(endpoint: String, protocolKind: ModelProtocol, modelID: String, key: String) -> Bool {
        updateProviderStore { store in
            var record = try HostAgentProvider(endpoint: endpoint, protocolKind: protocolKind,
                                               modelID: modelID, apiKey: key)
            if let selected = store.selectedProviderID,
               let index = store.providers.firstIndex(where: { $0.profile.id == selected }) {
                record.profile.id = selected
                record.model.id = store.providers[index].model.id
                record.model.providerID = selected
                store.providers[index] = record
            } else if !store.providers.isEmpty {
                let existing = store.providers[0].profile.id
                record.profile.id = existing
                record.model.id = store.providers[0].model.id
                record.model.providerID = existing
                store.providers[0] = record
                store.selectedProviderID = existing
            } else {
                store.providers = [record]
                store.selectedProviderID = record.profile.id
            }
        }
    }

    /// Adds a provider and makes it the selected one for chat.
    @discardableResult
    func addProvider(name: String?, endpoint: String, protocolKind: ModelProtocol,
                     modelID: String, key: String) -> Bool {
        updateProviderStore { store in
            let record = try HostAgentProvider(displayName: name, endpoint: endpoint,
                                               protocolKind: protocolKind, modelID: modelID, apiKey: key)
            store.providers.append(record)
            store.selectedProviderID = record.profile.id
        }
    }

    /// Replaces the record at `id`, keeping its identity so existing
    /// selections and conversations stay bound to the same provider.
    @discardableResult
    func updateProvider(id: UUID, name: String?, endpoint: String, protocolKind: ModelProtocol,
                        modelID: String, key: String) -> Bool {
        updateProviderStore { store in
            guard let index = store.providers.firstIndex(where: { $0.profile.id == id }) else {
                throw ProviderStoreError.missingRecord
            }
            var record = try HostAgentProvider(displayName: name, endpoint: endpoint,
                                               protocolKind: protocolKind, modelID: modelID, apiKey: key)
            record.profile.id = id
            record.model.id = store.providers[index].model.id
            record.model.providerID = id
            store.providers[index] = record
        }
    }

    /// Removes the record and its stored key. Chat history is kept; when the
    /// removed provider was selected, the first remaining one takes over.
    @discardableResult
    func removeProvider(id: UUID) -> Bool {
        updateProviderStore { store in
            store.providers.removeAll { $0.profile.id == id }
            if store.selectedProviderID == id {
                store.selectedProviderID = store.providers.first?.profile.id
            }
        }
    }

    /// Chooses which provider `send` uses for new runs.
    @discardableResult
    func selectChatProvider(id: UUID?) -> Bool {
        updateProviderStore { store in
            if let id {
                guard store.providers.contains(where: { $0.profile.id == id }) else {
                    throw ProviderStoreError.missingRecord
                }
            }
            store.selectedProviderID = id
        }
    }

    func select(_ id: UUID?) async {
        guard isReady, !isSending, !isTerminating, let runtime else { return }
        guard let release = admit() else { return }
        defer { release() }
        selectedID = id
        messages = []
        notice = nil
        guard let id else { return }
        do {
            let history = try await runtime.conversationMessages(conversationID: id)
            if selectedID == id && !isSending { messages = history }
        } catch {
            if selectedID == id && !isSending { notice = String(localized: "host.chat.historyUnavailable") }
        }
    }

    /// Renames or pins a saved conversation through the runtime and reloads
    /// the list on success. False means the change was not applied; callers
    /// surface their own message.
    @discardableResult
    func changeConversationMetadata(id: UUID,
                                    change: FloeMacSelfRuntime.ConversationMetadataChange) async -> Bool {
        guard let runtime, isReady, !isSending, !isTerminating,
              let release = admit() else { return false }
        defer { release() }
        do {
            try await runtime.changeConversationMetadata(id: id, change: change)
            conversations = try await runtime.conversations()
            return true
        } catch {
            return false
        }
    }

    func loadTaskRuns() async {
        guard let runtime, isReady, let release = admit() else { return }
        defer { release() }
        let lookup = UUID()
        taskRunLookup = lookup
        var records: [UUID: RunRecord] = [:]
        do {
            for conversation in conversations.lazy.filter(\.isVisibleInOrdinaryList).prefix(60) {
                guard !Task.isCancelled, lookup == taskRunLookup else { return }
                records[conversation.id] = try await runtime.recentRuns(conversationID: conversation.id, limit: 1).first
            }
            guard !Task.isCancelled, lookup == taskRunLookup else { return }
            recentTaskRuns = records
            taskRunLookupFailed = false
        } catch {
            if !Task.isCancelled, lookup == taskRunLookup { taskRunLookupFailed = true }
        }
    }

    @discardableResult
    func send(_ goal: String) -> Bool {
        let text = goal.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let runtime, isReady, !isSending, !isTerminating, !text.isEmpty else { return false }
        do {
            guard let config = try configuration() else {
                notice = String(localized: "host.chat.configureFirst")
                return false
            }
            return beginSend(text, runtime: runtime, provider: config.binding())
        } catch {
            notice = String(localized: "host.chat.keychainUnavailable")
            return false
        }
    }

    private func beginSend(_ text: String, runtime: FloeMacSelfRuntime,
                           provider: FloeMacSelfProviderBinding) -> Bool {
        guard let release = admit() else { return false }
        isSending = true
        notice = nil
        pendingPrompt = text
        let currentID = selectedID
        Task {
            defer {
                isSending = false
                activeRun = nil
                release()
            }
            do {
                let handle = try await runtime.startSession(
                    FloeMacSelfSessionRequest(conversationID: currentID, goal: text), provider: provider
                )
                activeRun = handle
                selectedID = handle.identity.conversationID
                let events = handle.events()
                streamedText = await handle.snapshot()?.streamedText ?? ""
                for await _ in events {
                    streamedText = await handle.snapshot()?.streamedText ?? ""
                }
                let terminal = await handle.waitForTerminal()
                messages = try await handle.durableMessages()
                conversations = try await runtime.conversations()
                pendingPrompt = nil
                streamedText = ""
                guard let terminal, terminal.confirmed else {
                    notice = String(localized: "host.chat.unconfirmed")
                    return
                }
                _ = try await handle.close()
                if terminal.outcome == .failed || terminal.outcome == .blocked {
                    notice = String(localized: "host.chat.runFailed")
                }
            } catch {
                // User input and provider errors can contain private material.
                // Show the action that failed and preserve the draft for retry.
                notice = String(localized: "host.chat.runFailed")
            }
        }
        return true
    }

    func stop() {
        guard let activeRun, !isStopping else { return }
        guard let release = admit() else { return }
        isStopping = true
        Task {
            defer { isStopping = false; release() }
            let cancellation = await activeRun.cancelAndWait()
            if cancellation.terminal?.confirmed != true {
                notice = String(localized: "host.chat.unconfirmed")
            }
        }
    }

    var canStop: Bool { activeRun != nil && !isStopping }

    func beginTermination() -> Bool {
        guard !isSending, !isPreparing, !isStopping else { return false }
        isTerminating = true
        return true
    }

    func cancelTermination() {
        isTerminating = false
    }

    func finishTermination() async throws {
        if let runtime { _ = try await runtime.shutdown(cancelActive: false) }
        runtime = nil
        isReady = false
    }

    func removeSmokeStoreAfterTermination() {
        guard vault == nil, isTerminating, runtime == nil else { return }
        try? FileManager.default.removeItem(at: supportDirectory)
    }

    private func configuration() throws -> HostAgentProvider? {
        guard let vault else { return nil }
        let store = try loadProviderStore()
        return store.providers.first(where: { $0.profile.id == store.selectedProviderID })
            ?? store.providers.first
    }

    // MARK: - Provider store

    /// Reads the persisted list, migrating the 1.3.0 single-profile account
    /// on first use. Reads are non-destructive: invalid or duplicate records
    /// fail closed (surfaced as the existing Keychain-unavailable notice)
    /// and the stored bytes are never rewritten by a read.
    private func loadProviderStore() throws -> ProviderListEnvelope {
        guard let vault else { return Self.emptyProviderStore() }
        let envelope: ProviderListEnvelope
        do {
            let encoded = try vault.read(account: Self.providerListAccount)
            let decoded = try JSONDecoder().decode(ProviderListEnvelope.self, from: encoded)
            guard decoded.version <= Self.currentProviderListVersion else {
                throw DecodingError.dataCorrupted(.init(
                    codingPath: [], debugDescription: "newer provider list version \(decoded.version)"))
            }
            envelope = decoded
        } catch KeychainStoreError.itemNotFound {
            return try migrateLegacyProviderStore()
        }
        try validateProviderEnvelope(envelope)
        return recoverLegacySelectionIfNeeded(envelope)
    }

    /// Imports the legacy single-profile record without deleting it: the
    /// envelope is written so later launches read the list directly, while
    /// the legacy account remains as the downgrade mirror and as the
    /// recovery source when the list has no selected profile.
    private func migrateLegacyProviderStore() throws -> ProviderListEnvelope {
        guard let vault else { return Self.emptyProviderStore() }
        do {
            let encoded = try vault.read(account: Self.settingsAccount)
            let record = try JSONDecoder().decode(HostAgentProvider.self, from: encoded)
            try record.validate()
            let envelope = ProviderListEnvelope(version: Self.currentProviderListVersion,
                                                providers: [record], selectedProviderID: record.profile.id)
            try persistProviderStore(envelope)
            return envelope
        } catch KeychainStoreError.itemNotFound {
            return Self.emptyProviderStore()
        }
    }

    /// Every record must validate and IDs must be unique. A violation makes
    /// the whole list unreadable on purpose: the bytes stay untouched for
    /// repair instead of being silently rewritten under changed validation
    /// rules or dropped by a read.
    private func validateProviderEnvelope(_ envelope: ProviderListEnvelope) throws {
        var seen = Set<UUID>()
        for record in envelope.providers {
            try record.validate()
            guard seen.insert(record.profile.id).inserted,
                  record.model.providerID == record.profile.id else {
                throw DecodingError.dataCorrupted(.init(
                    codingPath: [], debugDescription: "duplicate or inconsistent provider record"))
            }
        }
    }

    /// Read-only recovery: when the persisted list names no selected
    /// profile, the legacy 1.3.0 account may still hold one. The envelope
    /// bytes stay untouched; the recovery lives only in memory until the
    /// next successful save.
    private func recoverLegacySelectionIfNeeded(_ envelope: ProviderListEnvelope) -> ProviderListEnvelope {
        guard envelope.selectedProviderID == nil else { return envelope }
        guard let vault,
              let encoded = try? vault.read(account: Self.settingsAccount),
              let record = try? JSONDecoder().decode(HostAgentProvider.self, from: encoded),
              (try? record.validate()) != nil else { return envelope }
        var recovered = envelope
        if !recovered.providers.contains(where: { $0.profile.id == record.profile.id }) {
            recovered.providers.append(record)
        }
        recovered.selectedProviderID = record.profile.id
        return recovered
    }

    /// Canonical list commit first; the 1.3.0 legacy mirror is best-effort
    /// afterwards so a mirror failure cannot fail an already-committed save.
    private func persistProviderStore(_ store: ProviderListEnvelope) throws {
        guard let vault else { return }
        let encoder = JSONEncoder()
        try vault.store(account: Self.providerListAccount, secret: encoder.encode(store))
        if let selected = store.providers.first(where: { $0.profile.id == store.selectedProviderID }) {
            try? vault.store(account: Self.settingsAccount, secret: encoder.encode(selected))
        } else {
            // No selected profile (e.g. the last provider was removed):
            // clear the mirror so the legacy recovery path cannot resurrect
            // a record the user deleted.
            try? vault.delete(account: Self.settingsAccount)
        }
    }

    private static func emptyProviderStore() -> ProviderListEnvelope {
        ProviderListEnvelope(version: currentProviderListVersion, providers: [], selectedProviderID: nil)
    }

    private func reloadProviders() {
        guard let vault else {
            providers = []
            selectedProviderID = nil
            modelName = nil
            return
        }
        do {
            applyProviderStore(try loadProviderStore())
        } catch {
            notice = String(localized: "host.chat.keychainUnavailable")
        }
    }

    private func applyProviderStore(_ store: ProviderListEnvelope) {
        providers = store.providers
        selectedProviderID = store.selectedProviderID
        modelName = store.providers.first { $0.profile.id == store.selectedProviderID }
            .map { $0.profile.displayName ?? $0.model.displayName }
    }

    /// Serialized list mutation: load, mutate, persist, then republish. Any
    /// Keychain read/write or decode failure leaves the stored bytes
    /// untouched and reports the existing local error notices.
    @discardableResult
    private func updateProviderStore(_ mutation: (inout ProviderListEnvelope) throws -> Void) -> Bool {
        guard let vault, !isSending, !isTerminating else { return false }
        guard let release = admit() else { return false }
        defer { release() }
        do {
            var store = try loadProviderStore()
            try mutation(&store)
            try persistProviderStore(store)
            applyProviderStore(store)
            notice = nil
            return true
        } catch is KeychainStoreError, is DecodingError {
            notice = String(localized: "host.chat.keychainUnavailable")
            return false
        } catch {
            notice = String(localized: "host.chat.providerSaveFailed")
            return false
        }
    }

    private func admit() -> ReleaseWork? {
        do {
            return try admitWork()
        } catch {
            notice = String(localized: "host.chat.endingSession")
            return nil
        }
    }

    #if FLOE_MAC_HOST_SMOKE
    // Used only by the packaged App smoke command with its temporary
    // database and Keychain disabled. The adapter never creates a request.
    func verifyChatSmoke(admissionIsClosedToInstall: () -> Bool = { true }) async -> Bool {
        guard vault == nil, isReady, let runtime, !isSending, conversations.isEmpty,
              let config = try? HostAgentProvider(endpoint: "https://example.invalid/v1",
                  protocolKind: .openAIChatCompletions, modelID: "mac-smoke", apiKey: "") else { return false }
        guard beginSend("Synthetic Mac chat", runtime: runtime,
                  provider: .init(provider: config.profile, model: config.model,
                                  adapter: SmokeChatAdapter(), credentials: .init())) else { return false }
        let heldAdmission = admissionIsClosedToInstall()
        let deadline = ContinuousClock.now + .seconds(8)
        while isSending && ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(50))
        }
        guard !isSending, notice == nil, let conversationID = selectedID,
              messages.map(\.role) == ["user", "assistant"] else { return false }
        await select(conversationID)
        return heldAdmission && messages.map(\.content) == ["Synthetic Mac chat", "Synthetic persisted reply."]
    }

    private struct SmokeChatAdapter: ProviderAdapter {
        let protocolKind: ModelProtocol = .openAIChatCompletions

        func stream(request: ProviderStreamRequest,
                    credentials: ProviderCredentials) -> AsyncThrowingStream<AgentEvent, Error> {
            AsyncThrowingStream { continuation in
                continuation.yield(.textDelta(.init(text: "Synthetic persisted reply.")))
                continuation.yield(.completed(.init(stopReason: .endTurn)))
                continuation.finish()
            }
        }

        func listModels(provider: ProviderProfile, credentials: ProviderCredentials) async throws -> [ModelProfile] {
            []
        }
    }
    #endif
}
