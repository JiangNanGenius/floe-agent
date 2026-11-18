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
    let profile: ProviderProfile
    let model: ModelProfile
    /// This record is encoded only for the app's device-bound Keychain.
    let apiKey: String

    @MainActor
    init(endpoint: String, protocolKind: ModelProtocol, modelID: String, apiKey: String) throws {
        guard let endpointURL = URL(string: endpoint.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            throw InvalidConfiguration.endpoint
        }
        let modelID = modelID.trimmingCharacters(in: .whitespacesAndNewlines)
        let apiKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !apiKey.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            throw InvalidConfiguration.key
        }
        profile = ProviderProfile(kind: .custom, wireProtocol: protocolKind, baseURL: endpointURL)
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

    private let supportDirectory: URL
    private let namespace: String
    private let vault: KeychainStore?
    private let admitWork: AdmitWork
    private var runtime: FloeMacSelfRuntime?
    private var activeRun: FloeMacSelfSessionHandle?
    private var taskRunLookup = UUID()
    private static let settingsAccount = "selected-chat-provider.v1"

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
            do {
                modelName = try configuration()?.model.displayName
            } catch {
                notice = String(localized: "host.chat.keychainUnavailable")
            }
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

    func saveProvider(endpoint: String, protocolKind: ModelProtocol, modelID: String, key: String) -> Bool {
        guard let vault, !isSending, !isTerminating else { return false }
        guard let release = admit() else { return false }
        defer { release() }
        do {
            let config = try HostAgentProvider(endpoint: endpoint, protocolKind: protocolKind, modelID: modelID, apiKey: key)
            try vault.store(account: Self.settingsAccount, secret: JSONEncoder().encode(config))
            modelName = config.model.displayName
            notice = nil
            return true
        } catch {
            notice = String(localized: "host.chat.providerSaveFailed")
            return false
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
        do {
            let encoded = try vault.read(account: Self.settingsAccount)
            let config = try JSONDecoder().decode(HostAgentProvider.self, from: encoded)
            try config.validate()
            return config
        } catch KeychainStoreError.itemNotFound {
            return nil
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
