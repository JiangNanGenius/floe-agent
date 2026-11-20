// SPDX-License-Identifier: MPL-2.0

import Combine
import FloeAgentRuntime
import FloeCore
import FloeMacSelfCore
import FloeModels
import FloePersistence
import FloeProviders
import FloeSecurity
import Foundation
import UniformTypeIdentifiers

/// One staged file attachment prepared for the next send. The draft carries
/// a read-only security-scoped bookmark created at pick time plus verified
/// size and digest metadata; it grants no tool or permission authority.
/// The runtime verifies eligible attachments again before sending any bytes.
struct HostAgentAttachmentDraft: Hashable, Identifiable, Sendable {
    enum Kind: String, Hashable, Sendable {
        case image
        case document
    }

    let id: UUID
    let kind: Kind
    let url: URL
    let bookmark: Data
    let displayName: String
    let byteCount: Int
    let sha256: String
    let uti: String
    var createdAt = Date()

    var reference: AttachmentRef {
        AttachmentRef(id: id, kind: kind == .image ? .image : .document,
                      displayName: displayName, uti: uti, byteCount: byteCount, sha256: sha256,
                      storage: .securityScopedBookmark, urlBookmark: bookmark, createdAt: createdAt)
    }
}

struct HostAgentProvider: Codable {
    var profile: ProviderProfile
    var model: ModelProfile
    /// This record is encoded only for the app's device-bound Keychain.
    let apiKey: String
    /// Optional preset identity (`ProviderTemplateID.rawValue`) this record
    /// was created from. Records written before presets existed decode this
    /// as nil and keep working; the effective preset is still resolvable
    /// from the endpoint when needed.
    var presetID: String?

    /// The label shown in the provider list: the user-chosen name when set,
    /// otherwise the model ID (the 1.3.0 single-profile behavior).
    var displayTitle: String { profile.displayName ?? model.displayName }

    @MainActor
    init(displayName: String? = nil, endpoint: String, protocolKind: ModelProtocol, modelID: String, apiKey: String,
         supportsImages: Bool = false, supportsTools: Bool = false, presetID: String? = nil,
         limits: ModelLimits = .init(contextTokens: 32_768, maxOutputTokens: 0), allowsPlainHTTP: Bool = false) throws {
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
                                  displayName: trimmedName?.isEmpty == false ? trimmedName : nil,
                                  presetID: presetID)
        profile.allowsPlainHTTP = allowsPlainHTTP
        var capabilities: ModelCapabilities = [.text]
        if supportsImages { capabilities.insert(.vision) }
        if supportsTools { capabilities.insert(.tools) }
        model = ModelProfile(providerID: profile.id, remoteModelID: modelID, displayName: modelID,
                             limits: limits,
                             capabilities: capabilities)
        self.apiKey = apiKey
        self.presetID = presetID
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

enum HostAgentMode: String, CaseIterable {
    case chat, agent, plan, goal

    var runtimeMode: ConversationMode {
        switch self {
        case .chat, .agent: .chat
        case .plan: .plan
        case .goal: .goal
        }
    }
}

struct HostAgentApproval: Equatable {
    let conversationID: UUID
    let runID: UUID
    let workspaceID: UUID
    let requestedAt: Date
    let toolCall: ToolCall
    let reason: String
    let path: String?
    let text: String?
    let previousText: String?
    var callID: String { toolCall.id }
    var toolName: String { toolCall.toolName }
    var canAllow: Bool { path?.isEmpty == false && text != nil }

    #if FLOE_UNIFIED_MAC
    var cardRequest: PendingApproval {
        let writesFiles = MacAgentWorkspaceTools.writeToolNames.contains(toolName)
        return PendingApproval(runID: runID, conversationID: conversationID, toolCall: toolCall,
                               reason: reason, riskLabels: writesFiles ? ["writesFiles"] : [],
                               isSideEffecting: writesFiles, requestedAt: requestedAt, workspaceID: workspaceID)
    }
    #endif
}

#if FLOE_UNIFIED_MAC
struct HostAgentToolActivity: Identifiable, Equatable {
    let id: String
    let toolName: String
    var state: String
    var summary: String?
}
#endif

@MainActor
final class HostAgentWorkspace: ObservableObject {
    typealias ReleaseWork = @MainActor () -> Void
    typealias AdmitWork = @MainActor () throws -> ReleaseWork

    private struct LiveRun {
        let prompt: String?
        let mode: HostAgentMode
        let startedAt = Date()
        var handle: FloeMacSelfSessionHandle?
        var phase: FloeMacSelfSessionPhase?
        var streamedText = ""
        var approval: HostAgentApproval?
        var stopping = false
        var resolvingApproval = false
    }

    @Published private(set) var isReady = false
    @Published private(set) var isPreparing = false
    @Published private(set) var isTerminating = false
    @Published private var liveRuns: [UUID: LiveRun] = [:]
    private var newDraftRunID: UUID?
    private var liveSnapshotVersions: [UUID: Int] = [:]

    private var visibleRun: LiveRun? {
        guard let id = selectedID ?? newDraftRunID else { return nil }
        return liveRuns[id]
    }

    private var activeRun: FloeMacSelfSessionHandle? { visibleRun?.handle }
    var isSending: Bool { visibleRun != nil }
    var isStopping: Bool { visibleRun?.stopping == true }
    var activeRunCount: Int { liveRuns.count }
    var pendingApproval: HostAgentApproval? { visibleRun?.approval }
    var isResolvingApproval: Bool { visibleRun?.resolvingApproval == true }
    var runPhase: FloeMacSelfSessionPhase? { visibleRun?.phase }
    var streamedText: String { visibleRun?.streamedText ?? "" }
    var pendingPrompt: String? {
        guard let run = visibleRun else { return nil }
        if let id = run.handle?.identity.userMessageID, messages.contains(where: { $0.id == id }) { return nil }
        return run.prompt
    }

    var backgroundTaskIDs: [UUID] {
        liveRuns.filter { $0.key != selectedID && $0.key != newDraftRunID }
            .sorted { $0.value.startedAt < $1.value.startedAt }
            .map(\.key)
    }

    func isTaskRunning(_ id: UUID) -> Bool { liveRuns[id] != nil }
    func hasPendingApproval(in id: UUID) -> Bool { liveRuns[id]?.approval != nil }
    #if FLOE_UNIFIED_MAC
    enum WindowAction {
        case newTask, findTask, findTaskTitles, stopTask, toggleFiles
        case openSpace(MacSpacePage)
    }
    struct WindowCommand {
        let id = UUID()
        let action: WindowAction
    }
    @Published var windowCommand: WindowCommand?
    @Published var isSettingsPresented = false
    var windowShowsTask = false
    var draftSelectionID: UUID { historySelection }
    #if FLOE_MAC_HOST_SMOKE
    var smokeTaskSearchMounted = false
    var smokeTaskFindInvocations = 0
    var smokeConversationSearchMounted = false
    var smokeApprovalFrames: [Bool: CGRect] = [:]
    var smokePlanExecuteFrame: CGRect?
    var smokeProjectNewTaskFrames: [UUID: CGRect] = [:]
    var smokeProjectNameFrames: [UUID: CGRect] = [:]
    var smokeSpacePage: MacSpacePage?
    var smokeSpaceFrame: CGRect?
    var smokeSpacePickerFrame: CGRect?
    var smokeInspectorShown = false
    var smokeFilesTakeDetail = false
    #endif
    @Published var allowsWorkspaceWrites: Bool { didSet { preferences.set(allowsWorkspaceWrites, forKey: "floe.mac.workspace.allowWrites") } }
    @Published var verifyAgentAnswers: Bool { didSet { preferences.set(verifyAgentAnswers, forKey: "floe.mac.agent.verifyAnswers") } }
    @Published var defaultMode: HostAgentMode { didSet { preferences.set(defaultMode.rawValue, forKey: "floe.mac.agent.defaultMode") } }
    @Published private var draftMode: HostAgentMode?
    @Published private var taskModes: [String: String] = [:]
    private static let taskModesKey = "floe.mac.agent.taskModes"

    var composerMode: HostAgentMode {
        get {
            if let visibleRun { return visibleRun.mode }
            guard let id = selectedID else { return draftMode ?? defaultMode }
            if let raw = taskModes[id.uuidString], let mode = HostAgentMode(rawValue: raw) { return mode }
            if goal?.status.isTerminal == false { return .goal }
            if plan?.status == .accepted { return .agent }
            if plan != nil { return .plan }
            return defaultMode
        }
        set {
            guard !isSending else { return }
            if let id = selectedID { saveTaskMode(newValue, for: id) }
            else { draftMode = newValue }
        }
    }

    private func saveTaskMode(_ mode: HostAgentMode?, for id: UUID) {
        taskModes[id.uuidString] = mode?.rawValue
        preferences.set(taskModes, forKey: Self.taskModesKey)
    }
    private let preferences: UserDefaults
    @Published private var taskProviderID: UUID?
    @Published private var failedRunID: UUID?
    @Published private var changingGoals = Set<UUID>()
    @Published private(set) var runToolActivity: [UUID: [HostAgentToolActivity]] = [:]

    var liveToolActivity: [HostAgentToolActivity] {
        guard let runID = activeRun?.identity.runID else { return [] }
        return runToolActivity[runID] ?? []
    }

    var composerProvider: HostAgentProvider? {
        providers.first { $0.profile.id == taskProviderID }
            ?? providers.first { $0.profile.id == selectedProviderID }
            ?? providers.first
    }

    var failedUserMessage: PersistedMessage? {
        guard let failedRunID else { return nil }
        return messages.last {
            $0.runID == failedRunID && $0.role == "user"
                && PlanConfirmationSnapshot.from(message: $0) == nil
        }
    }

    func selectComposerProvider(_ id: UUID) {
        guard !isSending, !isLoadingHistory, !isTerminating,
              providers.contains(where: { $0.profile.id == id }) else { return }
        taskProviderID = id
    }
    #endif
    @Published private(set) var modelName: String?
    @Published private(set) var conversations: [ConversationRecord] = []
    @Published private(set) var recentTaskRuns: [UUID: RunRecord] = [:]
    @Published private(set) var taskRunLookupFailed = false
    @Published private(set) var selectedID: UUID?
    #if FLOE_UNIFIED_MAC
    @Published private(set) var admittedDraftID: UUID?
    #endif
    @Published private(set) var messages: [PersistedMessage] = []
    @Published private(set) var hasEarlierMessages = false
    @Published private(set) var isLoadingHistory = false
    @Published private(set) var isLoadingEarlierMessages = false
    @Published private(set) var historyLoadFailed = false
    /// Projects the user can choose for a new task.
    @Published private(set) var workspaces: [WorkspaceRecord] = []
    @Published private(set) var projectTaskMembership: [UUID: Set<UUID>]?
    @Published private(set) var projectTasksUnavailable = false
    @Published private(set) var selectedWorkspaceID: UUID?
    @Published private(set) var selectedConversationWorkspace: WorkspaceRecord?
    /// Files staged for the next send; cleared once a run starts.
    @Published private(set) var stagedAttachments: [HostAgentAttachmentDraft] = []
    @Published private(set) var workspaceRevision = UUID()
    @Published private(set) var rejectedPrompt: String?
    @Published private(set) var plan: PlanDraft?
    @Published private(set) var goal: ConversationGoal?
    @Published private(set) var isAcceptingPlan = false
    @Published var notice: String?
    private(set) var storageErrorKind: String?

    /// Staged file ceiling. Inline content has narrower runtime limits.
    static let maximumAttachmentBytes = 32 * 1_024 * 1_024
    /// Mirrors the runtime's per-run attachment ceiling.
    static let maximumStagedAttachmentCount = 8
    /// Inline images above this size never reach the model; staging matches
    /// the runtime's image inlining bound instead of staging a file that
    /// would silently degrade.
    static let maximumInlineImageBytes = 8 * 1_024 * 1_024
    /// Key material and certificate exports are never staged: they are
    /// reference secrets, not model or task content.
    static let blockedAttachmentExtensions: Set<String> = [
        "pem", "key", "p12", "pfx", "der", "cer", "crt", "keystore",
        "jks", "asc", "gpg", "kdbx", "ppk", "mobileprovision"
    ]

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
    var loadAttachmentDraft: ((UUID?) -> [AttachmentRef])?
    var saveAttachmentDraft: ((UUID?, [AttachmentRef]) -> Void)?
    private var runtime: FloeMacSelfRuntime?
    private var conversationListReload = UUID()
    private var projectMembershipLoad = UUID()
    private var changingTasks = Set<UUID>()
    #if FLOE_UNIFIED_MAC
    private var isSynchronizingCloudModels = false
    var hasPendingWorkspaceFileChanges = false
    #endif
    #if FLOE_MAC_HOST_SMOKE
    private(set) var smokeRunDiagnostics: [String] = []
    #endif
    private var taskRunLookup = UUID()
    private var historySelection = UUID()
    private var earlierMessageCursor: ConversationMessageCursor?
    private static let settingsAccount = "selected-chat-provider.v1"
    private static let providerListAccount = "chat-providers.v2"
    private static let currentProviderListVersion = 1

    init(supportDirectory: URL, namespace: String, useKeychain: Bool = true, preferences: UserDefaults = .standard,
         admitWork: @escaping AdmitWork = { {} }) {
        self.supportDirectory = supportDirectory
        self.namespace = namespace
        self.vault = useKeychain ? KeychainStore(service: namespace + ".chat",
            synchronizable: false, accessibility: .whenUnlockedThisDeviceOnly) : nil
        self.admitWork = admitWork
        #if FLOE_UNIFIED_MAC
        self.preferences = preferences
        self.allowsWorkspaceWrites = preferences.object(forKey: "floe.mac.workspace.allowWrites") as? Bool ?? true
        self.verifyAgentAnswers = preferences.bool(forKey: "floe.mac.agent.verifyAnswers")
        self.defaultMode = preferences.string(forKey: "floe.mac.agent.defaultMode").flatMap(HostAgentMode.init(rawValue:)) ?? .chat
        self.taskModes = preferences.dictionary(forKey: Self.taskModesKey) as? [String: String] ?? [:]
        #endif
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
            // Archived tasks stay out of the workspace; they are only
            // reachable again after an explicit restore.
            conversations = try await runtime.conversations(includeArchived: true)
            workspaces = try await runtime.workspaces()
            await reloadProjectTasks(using: runtime)
            if let recent = conversations.first(where: { $0.isVisibleInOrdinaryList }) {
                selectedID = recent.id
                applyHistory(try await runtime.conversationMessagePage(conversationID: recent.id))
                selectedConversationWorkspace = try? await runtime.workspaceForConversation(recent.id)
                #if FLOE_UNIFIED_MAC
                let run = try? await runtime.recentRuns(conversationID: recent.id, limit: 1).first
                applyComposerRun(run)
                if let run { await loadToolActivity(runID: run.id, conversationID: recent.id, runtime: runtime) }
                #endif
                await loadPlanning(conversationID: recent.id, runtime: runtime)
            }
            isReady = true
            restoreStagedAttachments(for: selectedID)
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
                record.model.capabilities = store.providers[index].model.capabilities
                store.providers[index] = record
            } else if !store.providers.isEmpty {
                let existing = store.providers[0].profile.id
                record.profile.id = existing
                record.model.id = store.providers[0].model.id
                record.model.providerID = existing
                record.model.capabilities = store.providers[0].model.capabilities
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
                     modelID: String, key: String, supportsImages: Bool = false, supportsTools: Bool = false,
                     presetID: String? = nil, limits: ModelLimits = .init(contextTokens: 32_768, maxOutputTokens: 0),
                     allowsPlainHTTP: Bool = false) -> Bool {
        updateProviderStore { store in
            let record = try HostAgentProvider(displayName: name, endpoint: endpoint,
                                               protocolKind: protocolKind, modelID: modelID, apiKey: key,
                                               supportsImages: supportsImages, supportsTools: supportsTools,
                                               presetID: presetID, limits: limits, allowsPlainHTTP: allowsPlainHTTP)
            store.providers.append(record)
            store.selectedProviderID = record.profile.id
        }
    }

    /// Replaces the record at `id`, keeping its identity so existing
    /// selections and conversations stay bound to the same provider.
    @discardableResult
    func updateProvider(id: UUID, name: String?, endpoint: String, protocolKind: ModelProtocol,
                        modelID: String, key: String, supportsImages: Bool = false, supportsTools: Bool = false,
                        presetID: String? = nil, limits: ModelLimits? = nil, allowsPlainHTTP: Bool = false) -> Bool {
        updateProviderStore { store in
            guard let index = store.providers.firstIndex(where: { $0.profile.id == id }) else {
                throw ProviderStoreError.missingRecord
            }
            let previous = store.providers[index]
            var record = try HostAgentProvider(displayName: name, endpoint: endpoint,
                                               protocolKind: protocolKind, modelID: modelID, apiKey: key,
                                               supportsImages: supportsImages, supportsTools: supportsTools,
                                               presetID: presetID, limits: limits ?? previous.model.limits,
                                               allowsPlainHTTP: allowsPlainHTTP)
            record.profile.id = id
            if previous.profile.baseURL == record.profile.baseURL && previous.profile.wireProtocol == protocolKind {
                record.profile.kind = previous.profile.kind
                record.profile.region = previous.profile.region
                record.profile.nonSecretHeaders = previous.profile.nonSecretHeaders
                record.profile.toolNameCompatibility = previous.profile.toolNameCompatibility
                if previous.model.remoteModelID == record.model.remoteModelID {
                    let editable: ModelCapabilities = [.vision, .tools]
                    let selectedCapabilities = record.model.capabilities.intersection(editable)
                    var model = previous.model
                    model.limits = record.model.limits
                    let changed = model.capabilities.intersection(editable).symmetricDifference(selectedCapabilities)
                    model.capabilities.subtract(editable)
                    model.capabilities.formUnion(selectedCapabilities)
                    if !changed.isEmpty {
                        model.explicitCapabilities = (model.explicitCapabilities ?? []).union(changed)
                    }
                    record.model = model
                }
            }
            record.model.id = previous.model.id
            record.model.providerID = id
            store.providers[index] = record
        }
    }

    #if FLOE_UNIFIED_MAC
    func synchronizeCloudModels(publishing providerID: UUID? = nil) async throws -> [MacCloudModelEntry] {
        guard vault != nil, isReady, !isSending, !isTerminating, !isSynchronizingCloudModels,
              let release = admit() else { throw MacICloudModelError.temporarilyUnavailable }
        isSynchronizingCloudModels = true
        defer { isSynchronizingCloudModels = false; release() }
        let entry: MacCloudModelEntry?
        if let providerID {
            guard let record = providers.first(where: { $0.profile.id == providerID }),
                  record.apiKey.isEmpty || !record.profile.baseURL.absoluteString.contains(record.apiKey),
                  MacCloudModelEntry.accepts(record.profile, model: record.model) else {
                throw MacICloudModelError.invalidProvider
            }
            var profile = record.profile
            profile.presetID = record.presetID ?? profile.presetID
            entry = .init(provider: profile, model: record.model)
        } else {
            entry = nil
        }
        let service = MacICloudModelSync(applicationSupport: supportDirectory, namespace: namespace)
        return try await service.synchronize(publishing: entry)
    }

    func importCloudModel(_ entry: MacCloudModelEntry) -> Bool {
        guard !isSynchronizingCloudModels, MacCloudModelEntry.accepts(entry.provider, model: entry.model) else {
            return false
        }
        return updateProviderStore { store in
            var base = entry.provider
            base.secretRef = nil
            let index = store.providers.firstIndex { $0.profile.id == base.id }
            let previous = index.map { store.providers[$0] }
            let sameConnection = previous?.profile.baseURL == base.baseURL
                && previous?.profile.wireProtocol == base.wireProtocol && previous?.profile.kind == base.kind
            var record = try HostAgentProvider(displayName: base.displayName, endpoint: base.baseURL.absoluteString,
                                              protocolKind: base.wireProtocol, modelID: entry.model.remoteModelID,
                                              apiKey: sameConnection ? previous?.apiKey ?? "" : "",
                                              presetID: base.presetID)
            record.profile = base
            record.model = entry.model
            if let index {
                store.providers[index] = record
            } else {
                store.providers.append(record)
            }
        }
    }
    #endif

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
        guard isReady, !isTerminating, !isAcceptingPlan, let runtime else { return }
        guard let release = admit() else { return }
        defer { release() }
        let selection = resetTaskSelection(to: id)
        guard let id else { return }
        defer {
            if historySelection == selection { isLoadingHistory = false }
        }
        do {
            let page = try await runtime.conversationMessagePage(conversationID: id)
            guard historySelection == selection, !Task.isCancelled else { return }
            applyHistory(page)
            let owner = try? await runtime.workspaceForConversation(id)
            guard historySelection == selection, !Task.isCancelled else { return }
            selectedConversationWorkspace = owner
            #if FLOE_UNIFIED_MAC
            let run = try? await runtime.recentRuns(conversationID: id, limit: 1).first
            guard historySelection == selection, !Task.isCancelled else { return }
            applyComposerRun(run)
            if let run { await loadToolActivity(runID: run.id, conversationID: id, runtime: runtime) }
            #endif
            await loadPlanning(conversationID: id, runtime: runtime)
        } catch {
            if historySelection == selection, !Task.isCancelled { historyLoadFailed = true }
        }
    }

    #if FLOE_UNIFIED_MAC
    func selectNewDraft(in projectID: UUID?) -> Bool {
        guard isReady, !isTerminating, !isAcceptingPlan, let release = admit() else { return false }
        defer { release() }
        selectedWorkspaceID = projectID
        if selectedID != nil { clearStagedAttachments() }
        _ = resetTaskSelection(to: nil)
        return true
    }
    #endif

    private func resetTaskSelection(to id: UUID?) -> UUID {
        let selection = UUID()
        historySelection = selection
        isLoadingHistory = id != nil
        isLoadingEarlierMessages = false
        historyLoadFailed = false
        applyHistory(.init(messages: [], earlierCursor: nil, hasEarlier: false))
        selectedID = id
        selectedConversationWorkspace = nil
        #if FLOE_UNIFIED_MAC
        applyComposerRun(nil)
        let liveIDs = Set(liveRuns.values.compactMap { $0.handle?.identity.runID })
        runToolActivity = runToolActivity.filter { liveIDs.contains($0.key) }
        #endif
        plan = nil
        goal = nil
        notice = nil
        restoreStagedAttachments(for: id)
        return selection
    }

    func loadEarlierMessages() async {
        guard let id = selectedID, let cursor = earlierMessageCursor, hasEarlierMessages,
              !isLoadingHistory, !isLoadingEarlierMessages, !isTerminating,
              let runtime, let release = admit() else { return }
        let selection = historySelection
        isLoadingEarlierMessages = true
        defer {
            if historySelection == selection { isLoadingEarlierMessages = false }
            release()
        }
        do {
            let page = try await runtime.conversationMessagePage(conversationID: id, before: cursor)
            guard historySelection == selection, earlierMessageCursor == cursor, !Task.isCancelled else { return }
            messages.insert(contentsOf: page.messages, at: 0)
            earlierMessageCursor = page.earlierCursor
            hasEarlierMessages = page.hasEarlier
        } catch {
            if historySelection == selection, !Task.isCancelled {
                notice = String(localized: "host.chat.historyUnavailable")
            }
        }
    }

    #if FLOE_UNIFIED_MAC
    var loadedMessageWindow: (messages: [PersistedMessage], earlierCursor: ConversationMessageCursor?, hasEarlier: Bool) {
        (messages, earlierMessageCursor, hasEarlierMessages)
    }

    func searchMessagePage(conversationID: UUID, before cursor: ConversationMessageCursor?) async throws -> ConversationMessagePage {
        guard selectedID == conversationID, !isTerminating, let runtime, let release = admit() else {
            throw CancellationError()
        }
        let selection = historySelection
        defer { release() }
        let page = try await runtime.conversationMessagePage(conversationID: conversationID, before: cursor)
        guard selection == historySelection, !Task.isCancelled else { throw CancellationError() }
        return page
    }

    func revealMessage(_ messageID: UUID, in conversationID: UUID) async -> Bool {
        let selection = historySelection
        for _ in 0...MacConversationSearchModel.maximumPagesPerSearch {
            guard selectedID == conversationID, selection == historySelection, !Task.isCancelled else { return false }
            if messages.contains(where: { $0.id == messageID }) { return true }
            guard let cursor = earlierMessageCursor, hasEarlierMessages, !isLoadingEarlierMessages else { return false }
            await loadEarlierMessages()
            if earlierMessageCursor == cursor { return false }
        }
        return false
    }
    #endif

    func transcript(conversationID: UUID) async throws -> [PersistedMessage] {
        guard let runtime, isReady, !isSending, !isTerminating,
              conversations.contains(where: { $0.id == conversationID && $0.isVisibleInOrdinaryList }),
              let release = admit() else { throw CancellationError() }
        defer { release() }
        return try await runtime.conversationTranscript(conversationID: conversationID)
    }

    func withSavedAttachment(id: UUID, conversationID: UUID, use: (URL) -> Void) async {
        guard let runtime, selectedID == conversationID, !isTerminating,
              let release = admit() else { return }
        let selection = historySelection
        defer { release() }
        do {
            guard let attachment = try await runtime.conversationAttachment(id: id, conversationID: conversationID),
                  attachment.storage == .securityScopedBookmark, let bookmark = attachment.urlBookmark else {
                throw CocoaError(.fileNoSuchFile)
            }
            guard historySelection == selection, selectedID == conversationID, !Task.isCancelled else { return }
            var stale = false
            let url = try URL(resolvingBookmarkData: bookmark,
                              options: [.withSecurityScope, .withoutUI, .withoutMounting],
                              relativeTo: nil, bookmarkDataIsStale: &stale)
            let accessed = url.startAccessingSecurityScopedResource()
            defer { if accessed { url.stopAccessingSecurityScopedResource() } }
            guard url.isFileURL, try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else {
                throw CocoaError(.fileNoSuchFile)
            }
            use(url)
        } catch {
            if historySelection == selection, !Task.isCancelled {
                notice = String(localized: "mac.workspace.attachmentUnavailable")
            }
        }
    }

    private func applyHistory(_ page: ConversationMessagePage, retainingVisibleHistory: Bool = false) {
        if retainingVisibleHistory, let first = page.messages.first,
           let overlap = messages.firstIndex(where: { $0.id == first.id }) {
            messages = Array(messages.prefix(upTo: overlap)) + page.messages
            return
        }
        messages = page.messages
        earlierMessageCursor = page.earlierCursor
        hasEarlierMessages = page.hasEarlier
    }

    /// Sets the project for the next draft submission. Existing tasks keep
    /// the workspace captured when their run was admitted.
    func selectWorkspace(_ id: UUID?) {
        guard isReady, !isSending, !isTerminating else { return }
        selectedWorkspaceID = id
    }

    /// Registers a project workspace for an explicitly picked local folder.
    /// The runtime is idempotent per resolved root path: re-adding the same
    /// folder returns the existing record instead of creating a duplicate.
    @discardableResult
    func addWorkspace(name: String, rootURL: URL, selectForNewTask: Bool = true) async -> WorkspaceRecord? {
        guard let runtime, isReady, !isTerminating, let release = admit() else { return nil }
        defer { release() }
        do {
            let bookmark = try rootURL.bookmarkData(options: [
                .withSecurityScope, .securityScopeAllowOnlyReadAccess
            ])
            let record = try await runtime.registerWorkspace(name: name, rootBookmark: bookmark)
            workspaces = try await runtime.workspaces()
            if selectForNewTask, !isSending { selectedWorkspaceID = record.id }
            return record
        } catch {
            notice = String(
                localized: "host.chat.workspaceSaveFailed",
                defaultValue: "The workspace could not be saved."
            )
            return nil
        }
    }

    /// Stages picked files for the next send. Only regular files that open
    /// for reading, produce a read-only security-scoped bookmark, and pass
    /// the bounded size/type rules are staged; duplicates of an already
    /// staged path are ignored. The bounded read fetches at most the ceiling
    /// plus one byte so an oversized file is rejected without being fully
    /// loaded. The returned array lists exactly what was staged.
    @discardableResult
    func stageAttachments(_ urls: [URL]) -> [HostAgentAttachmentDraft] {
        guard isReady, !isSending, !isTerminating else { return [] }
        var staged: [HostAgentAttachmentDraft] = []
        var stagedPaths = Set(stagedAttachments.map {
            $0.url.resolvingSymlinksInPath().standardizedFileURL
        })
        for url in urls {
            guard stagedAttachments.count + staged.count < Self.maximumStagedAttachmentCount else { break }
            let pathExtension = url.pathExtension.lowercased()
            guard !pathExtension.isEmpty,
                  !Self.blockedAttachmentExtensions.contains(pathExtension) else { continue }
            guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey]),
                  values.isRegularFile == true else { continue }
            guard let bookmark = try? url.bookmarkData(options: [
                .withSecurityScope, .securityScopeAllowOnlyReadAccess
            ]) else { continue }
            var stale = false
            guard let resolved = try? URL(
                resolvingBookmarkData: bookmark,
                options: [],
                relativeTo: nil,
                bookmarkDataIsStale: &stale
            ), !stale else { continue }
            let standardized = resolved.resolvingSymlinksInPath().standardizedFileURL
            guard stagedPaths.insert(standardized).inserted else { continue }
            // Read at most the document ceiling plus one byte; anything
            // larger is skipped before the image classification read.
            guard let head = Self.boundedContents(of: resolved, limit: Self.maximumAttachmentBytes),
                  !head.isEmpty else { continue }
            let rasterMIME = Self.rasterImageMIME(head)
            let kind: HostAgentAttachmentDraft.Kind = rasterMIME == nil ? .document : .image
            // Images must satisfy the stricter inline bound or they would
            // stage as model-visible drafts that the runtime then drops.
            if kind == .image, head.count > Self.maximumInlineImageBytes { continue }
            staged.append(HostAgentAttachmentDraft(
                id: UUID(),
                kind: kind,
                url: resolved,
                bookmark: bookmark,
                displayName: url.lastPathComponent,
                byteCount: head.count,
                sha256: FloeDigest.sha256Hex(head),
                uti: UTType(filenameExtension: url.pathExtension)?.identifier ?? "public.data"
            ))
        }
        guard !staged.isEmpty else { return [] }
        stagedAttachments.append(contentsOf: staged)
        saveAttachmentDraft?(selectedID, stagedAttachments.map(\.reference))
        return staged
    }

    /// Reads at most `limit` bytes from one exact path. The descriptor is
    /// opened `O_NOFOLLOW | O_NONBLOCK` (a swapped-in symlink or FIFO can
    /// neither redirect the read nor block the staging UI) and `fstat` must
    /// confirm a regular file before any byte is read.
    private static func boundedContents(of url: URL, limit: Int) -> Data? {
        let fd = open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var status = stat()
        guard fstat(fd, &status) == 0, (status.st_mode & S_IFMT) == S_IFREG else { return nil }
        var data = Data()
        data.reserveCapacity(min(limit, max(0, Int(status.st_size))))
        var buffer = [UInt8](repeating: 0, count: 64 * 1_024)
        while data.count <= limit {
            let readCount = read(fd, &buffer, buffer.count)
            guard readCount > 0 else { break }
            data.append(contentsOf: buffer[0..<readCount])
        }
        guard !data.isEmpty, data.count <= limit else { return nil }
        return data
    }

    func unstageAttachment(_ id: UUID) {
        stagedAttachments.removeAll { $0.id == id }
        saveAttachmentDraft?(selectedID, stagedAttachments.map(\.reference))
    }

    func clearStagedAttachments() {
        stagedAttachments.removeAll()
    }

    private func restoreStagedAttachments(for conversationID: UUID?) {
        guard let references = loadAttachmentDraft?(conversationID) else { return }
        stagedAttachments = references.prefix(Self.maximumStagedAttachmentCount).compactMap { reference in
            guard reference.storage == .securityScopedBookmark, let bookmark = reference.urlBookmark,
                  reference.kind == .image || reference.kind == .document,
                  reference.byteCount > 0, reference.byteCount <= Self.maximumAttachmentBytes else { return nil }
            var stale = false
            guard let url = try? URL(resolvingBookmarkData: bookmark, options: [.withoutUI],
                                     relativeTo: nil, bookmarkDataIsStale: &stale), !stale else { return nil }
            return .init(id: reference.id, kind: reference.kind == .image ? .image : .document,
                         url: url, bookmark: bookmark, displayName: reference.displayName,
                         byteCount: reference.byteCount, sha256: reference.sha256, uti: reference.uti,
                         createdAt: reference.createdAt)
        }
        if stagedAttachments.count != references.count {
            notice = String(localized: "mac.workspace.attachmentUnavailable")
        }
    }

    /// Raster signatures accepted by the runtime's image inlining. Kept in
    /// sync with the upstream normalizer; non-raster files stage as
    /// durable-only documents.
    private static func rasterImageMIME(_ data: Data) -> String? {
        if data.count >= 3, data.starts(with: [0xFF, 0xD8, 0xFF]) { return "image/jpeg" }
        if data.count >= 8, data.starts(with: [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]) { return "image/png" }
        if data.count >= 6, data.starts(with: Array("GIF8".utf8)) { return "image/gif" }
        if data.count >= 12,
           data.prefix(4) == Data("RIFF".utf8),
           data.dropFirst(8).prefix(4) == Data("WEBP".utf8) { return "image/webp" }
        return nil
    }

    /// Renames or pins a saved conversation through the runtime and reloads
    /// the list on success. False means the change was not applied; callers
    /// surface their own message.
    @discardableResult
    func changeConversationMetadata(id: UUID,
                                    change: FloeMacSelfRuntime.ConversationMetadataChange) async -> Bool {
        guard let runtime, isReady, !isTaskRunning(id), !changingTasks.contains(id), !isTerminating,
              let release = admit() else { return false }
        changingTasks.insert(id)
        defer { changingTasks.remove(id); release() }
        do {
            try await runtime.changeConversationMetadata(id: id, change: change)
            #if FLOE_UNIFIED_MAC
            if case .delete = change { saveTaskMode(nil, for: id) }
            #endif
            try await reloadConversations(using: runtime)
            return true
        } catch {
            return false
        }
    }

    #if FLOE_UNIFIED_MAC
    func retryProjectTasks() async {
        guard isReady, !isTerminating, let runtime, let release = admit() else { return }
        defer { release() }
        await reloadProjectTasks(using: runtime)
    }

    func moveTask(_ id: UUID, to workspaceID: UUID?) async -> Bool {
        guard let runtime, isReady, !isTaskRunning(id), !changingTasks.contains(id), !isTerminating,
              !isAcceptingPlan, let release = admit() else { return false }
        changingTasks.insert(id)
        defer { changingTasks.remove(id); release() }
        do {
            let owner = try await runtime.moveConversation(id: id, toWorkspaceID: workspaceID)
            if selectedID == id { selectedConversationWorkspace = owner }
            if let latest = try? await runtime.workspaces() { workspaces = latest }
            await reloadProjectTasks(using: runtime)
            return true
        } catch {
            return false
        }
    }
    #endif

    private func reloadConversations(using runtime: FloeMacSelfRuntime) async throws {
        let generation = UUID()
        conversationListReload = generation
        let records = try await runtime.conversations(includeArchived: true)
        if conversationListReload == generation {
            conversations = records
            await reloadProjectTasks(using: runtime)
        }
    }

    private func reloadProjectTasks(using runtime: FloeMacSelfRuntime) async {
        let generation = UUID()
        projectMembershipLoad = generation
        do {
            let members = try await runtime.projectConversationIDs()
            guard !Task.isCancelled, generation == projectMembershipLoad else { return }
            projectTaskMembership = members
            projectTasksUnavailable = false
        } catch {
            guard !Task.isCancelled, generation == projectMembershipLoad else { return }
            projectTasksUnavailable = true
        }
    }

    func loadTaskRuns() async {
        guard let runtime, isReady, let release = admit() else { return }
        defer { release() }
        let lookup = UUID()
        taskRunLookup = lookup
        let ids = conversations.filter {
            $0.purpose == .ordinary && $0.visibility == .normal && $0.editorOwnership == nil
        }.map(\.id)
        do {
            let records = try await runtime.latestRuns(conversationIDs: ids)
            guard !Task.isCancelled, lookup == taskRunLookup else { return }
            recentTaskRuns = records
            taskRunLookupFailed = false
        } catch {
            if !Task.isCancelled, lookup == taskRunLookup { taskRunLookupFailed = true }
        }
    }

    /// A new task can bind to a project before its first run. An existing
    /// task keeps its original workspace when the sidebar selection changes.
    @discardableResult
    func send(_ goal: String, workspaceID: UUID? = nil, mode: HostAgentMode = .chat,
              criterion: String = "", onAdmitted: (() -> Void)? = nil) -> Bool {
        let text = goal.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let runtime, isReady, !isSending, !isTerminating, !isAcceptingPlan,
              !isLoadingHistory, !historyLoadFailed, !text.isEmpty else { return false }
        do {
            guard let config = try configuration() else {
                notice = String(localized: "host.chat.configureFirst")
                return false
            }
            guard config.model.capabilities.contains(.vision) || !stagedAttachments.contains(where: { $0.kind == .image }) else {
                notice = String(localized: "mac.workspace.selectVisionModel")
                return false
            }
            guard mode == .chat || config.model.capabilities.contains(.tools) else {
                notice = String(localized: "mac.agent.toolsModelRequired")
                return false
            }
            return beginSend(text, runtime: runtime, provider: config.binding(), workspaceID: workspaceID,
                             mode: mode, criterion: criterion.trimmingCharacters(in: .whitespacesAndNewlines),
                             onAdmitted: onAdmitted)
        } catch {
            notice = String(localized: "host.chat.keychainUnavailable")
            return false
        }
    }

    private static func initialTaskTitle(_ prompt: String, provider: FloeMacSelfProviderBinding) -> String {
        let firstLine = prompt.split(maxSplits: 1, whereSeparator: \.isNewline).first ?? ""
        let safeText = SecretRedactor.redact(String(firstLine), secret: provider.credentials.apiKey)
        guard !safeText.contains(SecretRedactor.replacement) else { return "" }
        let words = safeText.split(whereSeparator: \.isWhitespace).prefix(8)
        return String(words.joined(separator: " ").prefix(48))
    }

    private func beginSend(_ text: String, runtime: FloeMacSelfRuntime,
                           provider: FloeMacSelfProviderBinding,
                           workspaceID: UUID? = nil, mode: HostAgentMode = .chat, criterion: String = "",
                           acceptedPlan: PlanConfirmationSnapshot? = nil, resumingGoal: Bool = false,
                           onAdmitted: (() -> Void)? = nil) -> Bool {
        let currentID = selectedID
        let taskID = currentID ?? UUID()
        let originSelection = historySelection
        guard !isSending, !changingTasks.contains(taskID) else { return false }
        let currentGoal = mode == .goal && criterion.isEmpty && goal?.conversationID == currentID ? goal : nil
        let selectedProject = workspaces.first { $0.id == workspaceID && $0.kind == .project }
        let requiresProject = mode == .agent || mode == .plan
        if requiresProject && currentID == nil && selectedProject == nil {
            notice = String(localized: "mac.agent.projectRequired")
            return false
        }
        guard let release = admit() else { return false }
        if currentID == nil { newDraftRunID = taskID }
        liveRuns[taskID] = LiveRun(prompt: acceptedPlan == nil ? text : nil, mode: mode)
        notice = nil
        rejectedPrompt = nil
        let drafts = resumingGoal || acceptedPlan != nil ? [] : stagedAttachments
        #if FLOE_UNIFIED_MAC
        let readOnly = mode == .plan || !allowsWorkspaceWrites
        let finalReview = mode != .chat && mode != .plan && verifyAgentAnswers
        #else
        let finalReview = false
        #endif
        Task {
            var admitted = false
            defer {
                if newDraftRunID == taskID { newDraftRunID = nil }
                liveSnapshotVersions.removeValue(forKey: taskID)
                liveRuns.removeValue(forKey: taskID)
                release()
            }
            do {
                let tools: FloeMacSelfToolBinding?
                #if FLOE_UNIFIED_MAC
                let project: WorkspaceRecord?
                if mode != .chat, let currentID {
                    let owner = try await runtime.workspaceForConversation(currentID)
                    project = owner?.kind == .project ? owner : nil
                } else {
                    project = selectedProject
                }
                if requiresProject && project == nil {
                    if selectedID == currentID && historySelection == originSelection {
                        rejectedPrompt = text
                        notice = String(localized: "mac.agent.projectRequired")
                    }
                    return
                }
                if let project, mode != .chat {
                    tools = try MacAgentWorkspaceTools.binding(workspace: project, readOnly: readOnly)
                } else {
                    tools = nil
                }
                #else
                let project = selectedProject
                tools = nil
                #endif
                let acceptedExecution: FloeMacSelfAcceptedPlanExecution?
                if let acceptedPlan, let currentID {
                    acceptedExecution = try await runtime.prepareAcceptedPlanExecution(acceptedPlan, conversationID: currentID)
                } else {
                    acceptedExecution = nil
                }
                let expectedGoal: FloeMacSelfExpectedGoal?
                if let goalID = acceptedExecution?.goalID, let revision = acceptedExecution?.goalRevision {
                    expectedGoal = .init(id: goalID, revision: revision)
                } else if let currentGoal {
                    expectedGoal = .init(id: currentGoal.id, revision: currentGoal.revision ?? 1)
                } else {
                    expectedGoal = nil
                }
                let request = FloeMacSelfSessionRequest(
                    conversationID: currentID,
                    newConversationID: currentID == nil ? taskID : nil,
                    workspaceID: tools == nil ? workspaceID : project?.id,
                    conversationTitle: currentID == nil ? Self.initialTaskTitle(text, provider: provider) : "",
                    goal: acceptedExecution?.goal ?? text,
                    mode: acceptedExecution?.conversationMode ?? mode.runtimeMode,
                    runID: acceptedExecution?.runID,
                    context: FloeMacSelfRunContext(workspaceName: project?.name),
                    attachments: drafts.map {
                        FloeMacSelfSessionAttachment(
                            id: $0.id,
                            kind: $0.kind == .image ? .image : .document,
                            displayName: $0.displayName,
                            uti: $0.uti,
                            byteCount: $0.byteCount,
                            sha256: $0.sha256,
                            bookmark: $0.bookmark
                        )
                    },
                    chatFastMode: mode == .chat,
                    verifyFinalAnswer: finalReview,
                    goalCriteria: mode == .goal && !criterion.isEmpty ? [criterion] : [],
                    reusingUserMessageID: acceptedExecution?.userMessageID,
                    expectedGoal: expectedGoal
                )
                guard liveRuns[taskID]?.stopping == false else { return }
                let handle: FloeMacSelfSessionHandle
                if resumingGoal {
                    handle = try await runtime.resumeGoalSession(request, provider: provider, tools: tools)
                } else {
                    handle = try await runtime.startSession(request, provider: provider, tools: tools)
                }
                admitted = true
                let events = handle.events()
                let hasOriginSelection = selectedID == currentID && historySelection == originSelection
                #if FLOE_UNIFIED_MAC
                saveTaskMode(mode, for: taskID)
                if currentID == nil, hasOriginSelection { draftMode = nil }
                #endif
                if !drafts.isEmpty,
                   loadAttachmentDraft.map({ $0(currentID).map(\.id) == drafts.map(\.id) }) ?? true {
                    saveAttachmentDraft?(currentID, [])
                    if hasOriginSelection, stagedAttachments == drafts { stagedAttachments = [] }
                }
                onAdmitted?()
                liveRuns[taskID]?.handle = handle
                if liveRuns[taskID]?.stopping == true { cancelRun(handle, taskID: taskID) }
                if hasOriginSelection && currentID == nil {
                    selectedConversationWorkspace = project
                    selectedID = handle.identity.conversationID
                    #if FLOE_UNIFIED_MAC
                    admittedDraftID = handle.identity.conversationID
                    #endif
                }
                if newDraftRunID == taskID { newDraftRunID = nil }
                #if FLOE_UNIFIED_MAC
                if selectedID == taskID {
                    taskProviderID = provider.provider.id
                    failedRunID = nil
                }
                #endif
                let initialPhase = await handle.phase()
                liveRuns[taskID]?.phase = initialPhase
                try? await reloadConversations(using: runtime)
                await updateLiveRun(handle)
                for await event in events {
                    await updateLiveRun(handle)
                    let phase = await handle.phase()
                    if liveRuns[taskID]?.phase != phase { liveRuns[taskID]?.phase = phase }
                    switch event {
                    case .harness(.planChanged), .harness(.goalChanged):
                        await loadPlanning(conversationID: handle.identity.conversationID, runtime: runtime)
                    #if FLOE_UNIFIED_MAC
                    case .harness(.toolLifecycle(let event)):
                        updateToolActivity(event, runID: handle.identity.runID)
                    #endif
                    default:
                        break
                    }
                }
                let terminal = await handle.waitForTerminal()
                #if FLOE_UNIFIED_MAC
                await loadToolActivity(runID: handle.identity.runID, conversationID: handle.identity.conversationID,
                                       runtime: runtime)
                #endif
                #if FLOE_MAC_HOST_SMOKE
                if vault == nil {
                    smokeRunDiagnostics.append("\(mode.rawValue): \(String(describing: terminal?.outcome))")
                    if terminal?.confirmed != true {
                        smokeRunDiagnostics.append("Unconfirmed terminal \(terminal?.durableRunState ?? "-"): \(terminal?.unconfirmedReason ?? "-")")
                    }
                    if terminal?.outcome == .failed || terminal?.outcome == .blocked,
                       let events = try? await handle.durableEvents(limit: 100) {
                        smokeRunDiagnostics.append(contentsOf: events.suffix(8).map(\.payloadJSON))
                    }
                }
                #endif
                if selectedID == taskID {
                    let selection = historySelection
                    if let page = try? await runtime.conversationMessagePage(conversationID: taskID),
                       selectedID == taskID, selection == historySelection {
                        applyHistory(page, retainingVisibleHistory: true)
                    }
                    if mode == .plan || mode == .goal {
                        await loadPlanning(conversationID: taskID, runtime: runtime)
                    }
                }
                try? await reloadConversations(using: runtime)
                if tools != nil, let records = try? await runtime.workspaces() {
                    workspaces = records
                    workspaceRevision = UUID()
                }
                liveRuns[taskID]?.streamedText = ""
                guard let terminal, terminal.confirmed else {
                    if selectedID == taskID { notice = String(localized: "host.chat.unconfirmed") }
                    return
                }
                _ = try await handle.close()
                if selectedID == taskID && (terminal.outcome == .failed || terminal.outcome == .blocked) {
                    #if FLOE_UNIFIED_MAC
                    failedRunID = handle.identity.runID
                    #endif
                    notice = String(localized: "host.chat.runFailed")
                }
            } catch {
                // User input and provider errors can contain private material.
                // Show the action that failed and preserve the draft for retry.
                #if FLOE_MAC_HOST_SMOKE
                if vault == nil { smokeRunDiagnostics.append("\(mode.rawValue): \(error)") }
                #endif
                guard admitted ? selectedID == taskID : (selectedID == currentID && historySelection == originSelection) else {
                    return
                }
                if !admitted, acceptedPlan == nil, !resumingGoal { rejectedPrompt = text }
                if resumingGoal, !admitted {
                    notice = String(localized: "mac.agent.goalControlFailed")
                    await loadPlanning(conversationID: taskID, runtime: runtime)
                    return
                }
                switch error as? FloeMacSelfCoreError {
                case .attachmentUnavailable(let name):
                    notice = String(format: String(localized: "mac.workspace.documentChanged"), name)
                case .attachmentUnreadable(let name):
                    notice = String(format: String(localized: "mac.workspace.documentUnreadable"), name)
                default:
                    notice = String(localized: "host.chat.runFailed")
                }
            }
        }
        return true
    }

    #if FLOE_UNIFIED_MAC
    func canPauseGoal(_ candidate: ConversationGoal) -> Bool {
        canChangeGoal(candidate) && [.active, .waitingApproval, .waitingUser, .verifying].contains(candidate.status)
    }

    private func canChangeGoal(_ candidate: ConversationGoal) -> Bool {
        candidate == goal && selectedID == candidate.conversationID
            && !isTerminating && !isAcceptingPlan && !changingGoals.contains(candidate.conversationID)
    }

    func canContinueGoal(_ candidate: ConversationGoal) -> Bool {
        canChangeGoal(candidate) && !isSending
            && [.paused, .interrupted, .blocked].contains(candidate.status)
    }

    func canConfirmGoal(_ candidate: ConversationGoal) -> Bool {
        canChangeGoal(candidate) && !isSending && candidate.status == .verifying
    }

    func pauseGoal(_ candidate: ConversationGoal) async {
        guard canPauseGoal(candidate) else { return }
        await saveGoalAction(candidate)
    }

    func confirmGoal(_ candidate: ConversationGoal, completedSteps: Set<UUID>, confirmedCriteria: Set<UUID>) async {
        guard canConfirmGoal(candidate) else { return }
        await saveGoalAction(candidate, confirmation: (completedSteps, confirmedCriteria))
    }

    private func saveGoalAction(_ candidate: ConversationGoal,
                                confirmation: (steps: Set<UUID>, criteria: Set<UUID>)? = nil) async {
        guard let runtime, let release = admit() else { return }
        let id = candidate.conversationID
        let selection = historySelection
        let revision = candidate.revision ?? 1
        changingGoals.insert(id)
        defer { changingGoals.remove(id); release() }
        do {
            let updated = if let confirmation {
                try await runtime.confirmGoalCompletion(conversationID: id, goalID: candidate.id,
                                                        expectedRevision: revision, completedStepIDs: confirmation.steps,
                                                        confirmedCriterionIDs: confirmation.criteria)
            } else {
                try await runtime.setGoalPaused(conversationID: id, goalID: candidate.id, expectedRevision: revision)
            }
            if historySelection == selection {
                goal = updated
                notice = nil
            }
        } catch {
            await loadPlanning(conversationID: id, runtime: runtime)
            if historySelection == selection {
                notice = confirmation != nil ? String(localized: "mac.agent.goalConfirmationFailed")
                    : String(localized: "mac.agent.goalControlFailed")
            }
        }
    }

    func continueGoal(_ candidate: ConversationGoal) {
        guard canContinueGoal(candidate), let runtime else { return }
        do {
            guard let config = try configuration() else {
                notice = String(localized: "host.chat.configureFirst")
                return
            }
            guard config.model.capabilities.contains(.tools) else {
                notice = String(localized: "mac.agent.toolsModelRequired")
                return
            }
            _ = beginSend(String(localized: "mac.agent.continueGoalPrompt"), runtime: runtime, provider: config.binding(),
                          mode: .goal, resumingGoal: true)
        } catch {
            notice = String(localized: "host.chat.keychainUnavailable")
        }
    }
    #endif

    private func loadPlanning(conversationID: UUID, runtime: FloeMacSelfRuntime) async {
        guard selectedID == conversationID else { return }
        let selection = historySelection
        do {
            let latest = try await runtime.latestPlan(conversationID: conversationID)
            let goals = try await runtime.goals(conversationID: conversationID)
            guard selection == historySelection, !Task.isCancelled else { return }
            plan = latest
            goal = goals.first { !$0.status.isTerminal } ?? goals.first
        } catch {
            if selection == historySelection, !Task.isCancelled {
                notice = String(localized: "mac.agent.planningLoadFailed")
            }
        }
    }

    @discardableResult
    func confirmAndRunPlan(_ candidate: PlanDraft, as execution: PlanExecutionRecommendation) async -> Bool {
        guard isReady, !isSending, !isTerminating, !isAcceptingPlan,
              candidate == plan, selectedID == candidate.conversationID else { return false }
        do {
            guard let config = try configuration(), config.model.capabilities.contains(.tools) else {
                notice = String(localized: "mac.agent.toolsModelRequired")
                return false
            }
            return await acceptPlan(candidate, as: execution, launchWith: config.binding())
        } catch {
            notice = String(localized: "host.chat.keychainUnavailable")
            return false
        }
    }

    private func acceptPlan(_ candidate: PlanDraft, as execution: PlanExecutionRecommendation = .normal,
                            launchWith provider: FloeMacSelfProviderBinding? = nil) async -> Bool {
        guard isReady, let runtime, !isSending, !isTerminating, !isAcceptingPlan,
              candidate == plan, selectedID == candidate.conversationID,
              candidate.status == .ready, candidate.isDecisionComplete, let release = admit() else { return false }
        isAcceptingPlan = true
        notice = nil
        defer { isAcceptingPlan = false; release() }
        do {
            let receipt = try await runtime.acceptPlan(candidate, conversationID: candidate.conversationID,
                                                       execution: execution)
            let updated = try await runtime.conversationMessagePage(conversationID: candidate.conversationID)
            applyHistory(updated, retainingVisibleHistory: true)
            await loadPlanning(conversationID: candidate.conversationID, runtime: runtime)
            let mode: HostAgentMode = execution == .goal ? .goal : .agent
            #if FLOE_UNIFIED_MAC
            saveTaskMode(mode, for: candidate.conversationID)
            #endif
            guard let provider else { return true }
            let snapshot = receipt.snapshot
            return beginSend(snapshot.executionPrompt, runtime: runtime, provider: provider,
                             mode: mode, acceptedPlan: snapshot)
        } catch {
            #if FLOE_MAC_HOST_SMOKE
            if vault == nil { smokeRunDiagnostics.append("acceptPlan: \(error)") }
            #endif
            await loadPlanning(conversationID: candidate.conversationID, runtime: runtime)
            notice = String(localized: "mac.agent.planAcceptFailed")
            return false
        }
    }

    var pendingAcceptedPlan: PlanConfirmationSnapshot? {
        guard let plan, plan.status == .accepted else { return nil }
        return messages.reversed().lazy.filter { $0.runID == nil }
            .compactMap(PlanConfirmationSnapshot.from(message:))
            .first { $0.plan.id == plan.id && $0.plan.revision == plan.revision }
    }

    func runAcceptedPlan(_ saved: PlanConfirmationSnapshot) {
        guard isReady, let runtime, !isSending, !isTerminating, !isAcceptingPlan,
              saved == pendingAcceptedPlan, selectedID == saved.plan.conversationID else { return }
        do {
            guard let config = try configuration(), config.model.capabilities.contains(.tools) else {
                notice = String(localized: "mac.agent.toolsModelRequired")
                return
            }
            let mode: HostAgentMode = saved.execution == .goal ? .goal : .agent
            _ = beginSend(saved.executionPrompt, runtime: runtime, provider: config.binding(), mode: mode,
                          acceptedPlan: saved)
        } catch {
            notice = String(localized: "host.chat.keychainUnavailable")
        }
    }

    private func updateLiveRun(_ handle: FloeMacSelfSessionHandle) async {
        let taskID = handle.identity.conversationID
        guard liveRuns[taskID]?.handle?.identity == handle.identity else { return }
        let generation = liveSnapshotVersions[taskID, default: 0] &+ 1
        liveSnapshotVersions[taskID] = generation
        let snapshot = await handle.snapshot()
        guard liveRuns[taskID]?.handle?.identity == handle.identity,
              liveSnapshotVersions[taskID] == generation else { return }
        let text = snapshot?.streamedText ?? ""
        if liveRuns[taskID]?.streamedText != text { liveRuns[taskID]?.streamedText = text }
        guard let request = snapshot?.pendingApproval else {
            if liveRuns[taskID]?.approval != nil { liveRuns[taskID]?.approval = nil }
            return
        }
        let call = request.toolCall
        let preview: (path: String?, text: String?, previousText: String?)
        #if FLOE_UNIFIED_MAC
        let decoder = JSONDecoder()
        switch call.toolName {
        case MacAgentWorkspaceCreateFileTool.name:
            let args = try? decoder.decode(MacAgentWorkspaceCreateFileTool.Arguments.self, from: call.argumentsJSON)
            preview = (args?.path, args?.content, nil)
        case MacAgentWorkspaceReplaceTextTool.name:
            let args = try? decoder.decode(MacAgentWorkspaceReplaceTextTool.Arguments.self, from: call.argumentsJSON)
            preview = (args?.path, args?.newText, args?.oldText)
        default:
            preview = (nil, nil, nil)
        }
        #else
        preview = (nil, nil, nil)
        #endif
        let card = HostAgentApproval(conversationID: handle.identity.conversationID,
                                     runID: handle.identity.runID, workspaceID: handle.identity.workspaceID,
                                     requestedAt: request.requestedAt,
                                     toolCall: call, reason: request.reason, path: preview.path,
                                     text: preview.text, previousText: preview.previousText)
        if liveRuns[taskID]?.approval != card { liveRuns[taskID]?.approval = card }
    }

    func resolveApproval(_ approval: HostAgentApproval, allow: Bool) async {
        guard isSending, !isStopping, !isResolvingApproval, !isTerminating,
              pendingApproval == approval, let handle = activeRun,
              handle.identity.runID == approval.runID, !allow || approval.canAllow,
              let release = admit() else { return }
        let taskID = approval.conversationID
        liveRuns[taskID]?.resolvingApproval = true
        defer {
            if liveRuns[taskID]?.handle?.identity == handle.identity { liveRuns[taskID]?.resolvingApproval = false }
            release()
        }
        let decision: ApprovalDecision = allow
            ? .allow(scope: ApprovalScope(toolName: approval.toolName, singleUse: true), expiresAt: nil)
            : .deny(reason: "User declined this workspace operation.")
        let result = await handle.resolveApproval(.init(conversationID: approval.conversationID,
            runID: approval.runID, workspaceID: approval.workspaceID, callID: approval.callID,
            toolName: approval.toolName, decision: decision, requestedAt: approval.requestedAt))
        guard liveRuns[taskID]?.handle?.identity == handle.identity else { return }
        if result == .accepted, liveRuns[taskID]?.approval == approval { liveRuns[taskID]?.approval = nil }
        await updateLiveRun(handle)
        if result != .accepted, selectedID == taskID, liveRuns[taskID]?.approval == approval {
            notice = String(localized: "mac.agent.approvalFailed")
        }
    }

    func stop() {
        guard let taskID = selectedID ?? newDraftRunID else { return }
        stopTask(taskID)
    }

    func stopTask(_ taskID: UUID) {
        guard liveRuns[taskID]?.stopping == false else { return }
        liveRuns[taskID]?.stopping = true
        if let handle = liveRuns[taskID]?.handle { cancelRun(handle, taskID: taskID) }
    }

    private func cancelRun(_ handle: FloeMacSelfSessionHandle, taskID: UUID) {
        let release = admit()
        Task {
            defer {
                if liveRuns[taskID]?.handle?.identity == handle.identity { liveRuns[taskID]?.stopping = false }
                release?()
            }
            let cancellation = await handle.cancelAndWait()
            if cancellation.terminal?.confirmed != true, selectedID == taskID {
                notice = String(localized: "host.chat.unconfirmed")
            }
        }
    }

    var canStop: Bool { visibleRun != nil && !isStopping }

    func beginTermination() -> Bool {
        guard liveRuns.isEmpty, !isPreparing, !isAcceptingPlan else { return false }
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
        #if FLOE_UNIFIED_MAC && FLOE_MAC_HOST_SMOKE
        if vault == nil { return composerProvider }
        #endif
        guard let vault else { return nil }
        let store = try loadProviderStore()
        #if FLOE_UNIFIED_MAC
        if let provider = store.providers.first(where: { $0.profile.id == taskProviderID }) { return provider }
        #endif
        return store.providers.first(where: { $0.profile.id == store.selectedProviderID })
            ?? store.providers.first
    }

    #if FLOE_UNIFIED_MAC
    private func applyComposerRun(_ run: RunRecord?) {
        taskProviderID = run?.providerID
        if let run, ["failed", "blocked", "interrupted"].contains(run.state) {
            failedRunID = run.id
        } else {
            failedRunID = nil
        }
    }

    private func updateToolActivity(_ event: ToolLifecycleEvent, runID: UUID) {
        var activity = runToolActivity[runID, default: []]
        switch event {
        case .requested(let call), .started(let call):
            let state: String
            if case .started = event { state = "running" } else { state = "pending" }
            if let index = activity.firstIndex(where: { $0.id == call.id }) {
                activity[index].state = state
            } else {
                activity.append(.init(id: call.id, toolName: call.toolName, state: state))
            }
        case .finished(let result):
            if let index = activity.firstIndex(where: { $0.id == result.callID }) {
                activity[index].state = result.status.rawValue
            }
        }
        runToolActivity[runID] = Array(activity.suffix(40))
    }

    private func loadToolActivity(runID: UUID, conversationID: UUID, runtime: FloeMacSelfRuntime) async {
        guard let events = try? await runtime.recentRunEvents(runID: runID, limit: 250),
              selectedID == conversationID else { return }
        var steps: [HostAgentToolActivity] = []
        var indexes: [String: Int] = [:]
        for event in events where event.kind == .toolRequest || event.kind == .toolResult {
            guard let values = try? JSONDecoder().decode([String: String].self, from: Data(event.payloadJSON.utf8)),
                  let id = values["id"], let status = values["status"] else { continue }
            let summary = values["summary"].flatMap { CredentialMessagePart.clipboardText(String($0.prefix(700))) }
            if let index = indexes[id] {
                steps[index].state = status
                steps[index].summary = summary
            } else if let name = values["tool"], !name.isEmpty {
                indexes[id] = steps.count
                steps.append(.init(id: id, toolName: name, state: status, summary: summary))
            }
        }
        if !steps.isEmpty { runToolActivity[runID] = Array(steps.suffix(40)) }
    }
    #endif

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

    // MARK: - Model discovery

    /// Live result state for the provider editor's model listing. Results
    /// come straight from the endpoint's own listing through the shared
    /// factory adapter; nothing is invented locally.
    enum HostModelDiscoveryState: Equatable {
        /// No request yet, or the draft fields are not ready (blank endpoint
        /// or a key still required before discovery may run).
        case idle
        case discovering
        case succeeded(modelCount: Int)
        /// The endpoint publishes no model listing (subscription gateways):
        /// manual model entry is the honest path.
        case listingUnavailable
        /// Redacted, localized failure the editor shows next to the manual
        /// model field.
        case failed(String)
    }

    /// Live model candidates for the editor's current draft fields. Every
    /// entry keeps the capability metadata the endpoint reported.
    @Published private(set) var discoveredModels: [ModelProfile] = []
    @Published private(set) var modelDiscoveryState: HostModelDiscoveryState = .idle

    /// Debounce for automatic discovery while the user types.
    static let modelDiscoveryDebounceNanoseconds: UInt64 = 600_000_000
    private var modelDiscoveryGeneration: UInt64 = 0
    private var modelDiscoveryTask: Task<Void, Never>?

    /// Starts one model-listing pass for the editor's draft fields. Every
    /// call invalidates the previous pass synchronously: the old task is
    /// cancelled, the generation is bumped and the visible stale results are
    /// cleared before this function returns, so a stale listing can never
    /// cross a provider, endpoint or key change. The debounced form waits
    /// briefly so a burst of edits collapses into one request; intermediate
    /// endpoints the user typed through never receive a request.
    func requestModelDiscovery(endpoint: String, protocolKind: ModelProtocol, apiKey: String,
                               debounce: Bool, allowsPlainHTTP: Bool = false) {
        guard !isTerminating else { return }
        modelDiscoveryGeneration &+= 1
        let generation = modelDiscoveryGeneration
        modelDiscoveryTask?.cancel()
        discoveredModels = []
        modelDiscoveryState = .idle
        let trimmedEndpoint = endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        modelDiscoveryTask = Task { [weak self] in
            if debounce {
                try? await Task.sleep(nanoseconds: Self.modelDiscoveryDebounceNanoseconds)
            }
            guard !Task.isCancelled, let self else { return }
            await self.runModelDiscovery(generation: generation, endpoint: trimmedEndpoint,
                                         protocolKind: protocolKind, apiKey: trimmedKey,
                                         allowsPlainHTTP: allowsPlainHTTP)
        }
    }

    /// Abandons any in-flight listing and clears the live results. Called
    /// when the editor closes or switches records.
    func cancelModelDiscovery() {
        modelDiscoveryGeneration &+= 1
        modelDiscoveryTask?.cancel()
        modelDiscoveryTask = nil
        modelDiscoveryState = .idle
        discoveredModels = []
    }

    #if FLOE_UNIFIED_MAC
    func testProviderConnection(endpoint: String, protocolKind: ModelProtocol, modelID: String,
                                key: String, allowsPlainHTTP: Bool = false) async throws {
        guard isReady, !isTerminating, let release = admit() else { throw CancellationError() }
        defer { release() }
        let config = try HostAgentProvider(endpoint: endpoint, protocolKind: protocolKind, modelID: modelID,
                                           apiKey: key, allowsPlainHTTP: allowsPlainHTTP)
        let binding = config.binding()
        try await ProviderConnectionProbe.testConnection(provider: binding.provider, credentials: binding.credentials,
                                                          modelRemoteID: config.model.remoteModelID, adapter: binding.adapter)
    }
    #endif

    private func runModelDiscovery(generation: UInt64, endpoint: String,
                                   protocolKind: ModelProtocol, apiKey: String, allowsPlainHTTP: Bool) async {
        // The endpoint must parse to an absolute http(s) URL before any
        // network work; everything else stays idle.
        guard !endpoint.isEmpty,
              let url = URL(string: endpoint),
              let scheme = url.scheme?.lowercased(),
              scheme == "https" || scheme == "http",
              url.host?.isEmpty == false else {
            applyModelDiscoveryResult(generation: generation, state: .idle, models: [])
            return
        }
        // Subscription gateways publish no `/models` listing; their honest
        // path here is manual model entry, never a fabricated catalog.
        let preset = ProviderPreset.preset(for: .custom, baseURL: url)
        guard preset.supportsModelDiscovery else {
            applyModelDiscoveryResult(generation: generation, state: .listingUnavailable, models: [])
            return
        }
        // A blank key is allowed only for keyless (local) endpoints; every
        // other listing runs with the exact current key and the key is sent
        // only to this settled endpoint.
        guard preset.authStyle == .none || !apiKey.isEmpty || (allowsPlainHTTP && url.isLocalOrPrivateNetwork) else {
            applyModelDiscoveryResult(generation: generation, state: .idle, models: [])
            return
        }
        // The same key admission rule as save: control characters are never
        // transmitted.
        guard !apiKey.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            applyModelDiscoveryResult(generation: generation,
                                      state: .failed(String(localized: "mac.provider.keyInvalid")), models: [])
            return
        }
        applyModelDiscoveryResult(generation: generation, state: .discovering, models: [])
        do {
            var profile = ProviderProfile(kind: .custom, wireProtocol: protocolKind,
                                          baseURL: url, displayName: nil)
            profile.allowsPlainHTTP = allowsPlainHTTP
            try ProviderConfigurationValidation.validate(profile)
            let adapter = ProviderAdapterFactory().adapter(for: profile)
            let models = try await adapter.listModels(
                provider: profile,
                credentials: ProviderCredentials(apiKey: apiKey.isEmpty ? nil : apiKey)
            )
            try Task.checkCancellation()
            applyModelDiscoveryResult(generation: generation,
                                      state: .succeeded(modelCount: models.count), models: models)
        } catch is CancellationError {
            // A newer request owns the editor now; it republishes state.
        } catch {
            let message = SecretRedactor.redact(error.localizedDescription,
                                                secret: apiKey.isEmpty ? nil : apiKey)
            applyModelDiscoveryResult(generation: generation, state: .failed(message), models: [])
        }
    }

    private func applyModelDiscoveryResult(generation: UInt64, state: HostModelDiscoveryState,
                                           models: [ModelProfile]) {
        guard generation == modelDiscoveryGeneration else { return }
        modelDiscoveryState = state
        discoveredModels = models
    }

    private func admit() -> ReleaseWork? {
        guard !isTerminating else { return nil }
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
        guard vault == nil, isReady, let runtime, !isSending, selectedID == nil,
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
              messages.map(\.role) == ["user", "assistant"],
              conversations.first(where: { $0.id == conversationID })?.title == "Synthetic Mac chat" else { return false }
        await select(conversationID)
        return heldAdmission && messages.map(\.content) == ["Synthetic Mac chat", "Synthetic persisted reply."]
    }

    #if FLOE_UNIFIED_MAC
    func verifyConversationHistorySmoke(reference: URL) async -> Bool {
        guard vault == nil, let runtime, let id = selectedID, !isSending,
              let config = try? HostAgentProvider(endpoint: "https://example.invalid/v1",
                  protocolKind: .openAIChatCompletions, modelID: "mac-smoke", apiKey: "") else { return false }
        do {
            let database = try DatabaseManager(path: runtime.databaseURL)
            let store = SQLiteConversationStore(database: database)
            for index in 0..<105 {
                try await store.appendMessage(PersistedMessage(
                    id: UUID(), conversationID: id, role: "assistant",
                    content: "Fixture earlier message \(index)",
                    createdAt: Date(timeIntervalSince1970: 1_000 + Double(index))
                ))
            }
            try await database.close()
            await select(id)
            guard messages.count == 100, hasEarlierMessages else { return false }
            let transcript = try await transcript(conversationID: id)
            let exported = MacWorkspaceRootView.markdownTranscript(name: "Fixture", messages: transcript)
            guard transcript.count == 107, let earliest = transcript.first,
                  exported.contains("Fixture earlier message 0\n"),
                  exported.contains("Synthetic persisted reply.") else { return false }
            let search = MacConversationSearchModel(
                loadedWindow: { self.loadedMessageWindow },
                historyPage: { try await self.searchMessagePage(conversationID: id, before: $0) },
                reveal: { await self.revealMessage($0.messageID, in: id) }
            )
            search.bind(conversationID: id)
            search.begin()
            search.query = "\"Fixture earlier message 0\""
            await search.retry()
            guard search.hits.map(\.id) == [earliest.id], search.focusedMessageID == earliest.id,
                  !search.isPartial, search.errorText == nil else { return false }
            search.bind(conversationID: UUID())
            guard search.hits.isEmpty, search.focusedMessageID == nil else { return false }
            guard messages.map(\.id) == transcript.map(\.id), !hasEarlierMessages,
                  let attachment = stageAttachments([reference]).first else { return false }
            let provider = FloeMacSelfProviderBinding(provider: config.profile, model: config.model,
                                                      adapter: SmokeChatAdapter(expectedAttachmentText: "Synthetic attachment"),
                                                      credentials: .init())
            guard beginSend("Fixture follow-up", runtime: runtime, provider: provider), await waitForSmokeRun(),
                  messages.count == 109, messages.first?.id == transcript.first?.id,
                  messages.contains(where: { $0.content == "Fixture follow-up" }),
                  messages.last?.content == "Synthetic persisted reply." else { return false }
            await select(nil)
            await select(id)
            var resolved: URL?
            await withSavedAttachment(id: attachment.id, conversationID: id) { resolved = $0 }
            return resolved?.standardizedFileURL == reference.standardizedFileURL
                && messages.contains(where: { $0.parts.contains(where: { $0.attachmentID == attachment.id }) })
        } catch {
            return false
        }
    }

    func verifyTaskMoveSmoke(_ id: UUID, project: WorkspaceRecord) async -> Bool {
        guard vault == nil, !isSending else { return false }
        await select(id)
        let messagesBefore = messages.map(\.id)
        guard !messagesBefore.isEmpty, let personal = selectedConversationWorkspace, personal.kind == .privateTask,
              await moveTask(id, to: project.id), selectedConversationWorkspace?.id == project.id,
              projectTaskMembership?[project.id]?.contains(id) == true else {
            return false
        }
        await select(nil)
        await select(id)
        guard selectedConversationWorkspace?.id == project.id, messages.map(\.id) == messagesBefore,
              await moveTask(id, to: nil) else { return false }
        await select(id)
        guard let detached = projectTaskMembership, detached[project.id]?.contains(id) != true else { return false }
        return selectedConversationWorkspace?.id == personal.id && messages.map(\.id) == messagesBefore
            && conversations.first(where: { $0.id == id })?.isPinned == true
    }
    #endif

    private struct SmokeChatAdapter: ProviderAdapter {
        let protocolKind: ModelProtocol = .openAIChatCompletions
        var expectedAttachmentText: String? = nil

        func stream(request: ProviderStreamRequest,
                    credentials: ProviderCredentials) -> AsyncThrowingStream<AgentEvent, Error> {
            AsyncThrowingStream { continuation in
                let received = expectedAttachmentText.map { marker in
                    request.effectiveMessages.contains { message in
                        message.role == "user" && message.content.contains { part in
                            if case .text(let text) = part { return text.contains(marker) }
                            return false
                        }
                    }
                } ?? true
                let reply = received ? "Synthetic persisted reply." : "Required attachment absent."
                continuation.yield(.textDelta(.init(text: reply)))
                continuation.yield(.completed(.init(stopReason: .endTurn)))
                continuation.finish()
            }
        }

        func listModels(provider: ProviderProfile, credentials: ProviderCredentials) async throws -> [ModelProfile] {
            []
        }
    }

    #if FLOE_UNIFIED_MAC
    func verifyAgentApprovalSmoke(project: WorkspaceRecord, checkingFile root: URL,
                                  approveOnScreen: (Bool) -> Bool) async -> (allowed: Bool, denied: Bool) {
        guard vault == nil, let runtime, !isSending else { return (false, false) }
        await select(nil)
        var results: [Bool] = []
        for (file, allow) in [("approved.txt", true), ("declined.txt", false)] {
            let output = root.appendingPathComponent(file)
            guard let provider = smokeProvider(.createFile(file)),
                  beginSend("Create \(file)", runtime: runtime, provider: provider,
                            workspaceID: selectedID == nil ? project.id : nil, mode: .agent) else { break }
            let deadline = ContinuousClock.now + .seconds(6)
            while pendingApproval == nil && isSending && ContinuousClock.now < deadline {
                try? await Task.sleep(for: .milliseconds(30))
            }
            guard let approval = pendingApproval, approval.path == file,
                  approval.workspaceID == project.id, let handle = activeRun,
                  !FileManager.default.fileExists(atPath: output.path) else {
                stop()
                _ = await waitForSmokeRun()
                break
            }
            let stale = await handle.resolveApproval(.init(
                conversationID: approval.conversationID, runID: approval.runID,
                workspaceID: approval.workspaceID, callID: approval.callID, toolName: approval.toolName,
                decision: .deny(reason: "Stale fixture request"),
                requestedAt: approval.requestedAt.addingTimeInterval(-1)
            ))
            guard stale == .notPending else {
                stop()
                _ = await waitForSmokeRun()
                break
            }
            try? await Task.sleep(for: .milliseconds(85))
            if !approveOnScreen(allow) {
                await resolveApproval(approval, allow: allow)
            }
            let stored = await waitForSmokeRun()
            let data = try? String(contentsOf: output, encoding: .utf8)
            results.append(stored && (allow ? data == "Synthetic workspace output." : data == nil))
        }
        return (results.first == true, results.count == 2 && results[1])
    }

    func verifyAgentTextEditSmoke(project: WorkspaceRecord, folder: URL) async -> Bool {
        guard vault == nil, let runtime, !isSending else { return false }
        await select(nil)
        do {
            for scenario in ["approved", "denied", "stale", "ambiguous"] {
                let name = "edit-\(scenario).txt"
                let url = folder.appendingPathComponent(name)
                let prefix = Data([0xef, 0xbb, 0xbf])
                let body = scenario == "ambiguous" ? "before\r\nbefore\r\n" : "before\r\nkeep\r\n"
                let original = prefix + Data(body.utf8)
                try original.write(to: url, options: .withoutOverwriting)
                try FileManager.default.setAttributes([.posixPermissions: 0o640], ofItemAtPath: url.path)
                let priorCopies = try Self.smokePreviousVersions(in: folder)
                guard let provider = smokeProvider(.replaceText(name, FloeDigest.sha256Hex(original))),
                      beginSend("Edit \(name)", runtime: runtime, provider: provider,
                                workspaceID: selectedID == nil ? project.id : nil, mode: .agent) else { return false }
                let deadline = ContinuousClock.now + .seconds(6)
                while pendingApproval == nil && isSending && ContinuousClock.now < deadline {
                    try? await Task.sleep(for: .milliseconds(30))
                }
                guard let approval = pendingApproval, approval.path == name,
                      approval.toolName == MacAgentWorkspaceTools.replaceTextToolName,
                      approval.previousText == "before", approval.text == "after",
                      try Data(contentsOf: url) == original else {
                    stop()
                    _ = await waitForSmokeRun()
                    return false
                }
                let changedElsewhere = Data("external revision\n".utf8)
                if scenario == "stale" { try changedElsewhere.write(to: url, options: .atomic) }
                await resolveApproval(approval, allow: scenario != "denied")
                let succeeded = await waitForSmokeRun()
                guard !isSending, pendingApproval == nil else { return false }
                let events = try await runtime.runEvents(runID: approval.runID)
                let result = events.filter { $0.kind == .toolResult }.lazy
                    .compactMap { try? JSONDecoder().decode([String: String].self, from: Data($0.payloadJSON.utf8)) }
                    .first { $0["id"] == approval.callID }
                let versions = try Self.smokePreviousVersions(in: folder).subtracting(priorCopies)
                let actual = try Data(contentsOf: url)
                switch scenario {
                case "approved":
                    guard succeeded, result?["status"] == "ok", actual == prefix + Data("after\r\nkeep\r\n".utf8),
                          versions.count == 1, let backup = versions.first,
                          try Data(contentsOf: backup) == original,
                          (try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber)?
                            .intValue == 0o640 else { return false }
                case "stale":
                    guard actual == changedElsewhere, versions.isEmpty, result?["status"] == "failed",
                          result?["summary"]?.contains("the file changed since it was inspected") == true
                    else { return false }
                case "ambiguous":
                    guard actual == original, versions.isEmpty, result?["status"] == "failed",
                          result?["summary"]?.contains("the specified text must occur exactly once") == true
                    else { return false }
                default:
                    guard succeeded, result?["status"] == "denied", actual == original, versions.isEmpty else { return false }
                }
                smokeRunDiagnostics.append("workspace.replaceText \(scenario): verified")
            }
            return true
        } catch {
            smokeRunDiagnostics.append("workspace.replaceText fixture: \(error.localizedDescription)")
            if isSending { stop(); _ = await waitForSmokeRun() }
            return false
        }
    }

    private static func smokePreviousVersions(in folder: URL) throws -> Set<URL> {
        Set(try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix(".floe-previous-") })
    }

    func verifyProjectTaskWorkflowSmoke(
        project: WorkspaceRecord, folder: URL, attachment: URL, endpoint: URL,
        confirm: () -> Bool, approve: () -> Bool
    ) async -> Bool {
        guard vault == nil, let runtime, selectedID == nil, selectedWorkspaceID == project.id, activeRunCount == 0,
              endpoint.scheme == "http", endpoint.host == "127.0.0.1",
              let chosen = try? HostAgentProvider(endpoint: endpoint.absoluteString,
                  protocolKind: .openAIChatCompletions, modelID: "project-task-fixture", apiKey: "",
                  supportsTools: true, allowsPlainHTTP: true),
              let other = try? HostAgentProvider(endpoint: endpoint.absoluteString,
                  protocolKind: .openAIChatCompletions, modelID: "uncalled-fixture", apiKey: "",
                  supportsTools: true, allowsPlainHTTP: true) else { return false }
        let oldProviders = providers
        let oldProviderID = selectedProviderID
        defer {
            providers = oldProviders
            selectedProviderID = oldProviderID
        }
        providers = [other, chosen]
        selectedProviderID = other.profile.id
        selectComposerProvider(chosen.profile.id)
        composerMode = .plan
        smokePlanExecuteFrame = nil

        func exercise() async -> Bool {
            let prompt = "Use the attached brief to write and save the project acceptance report."
            let report = folder.appendingPathComponent("acceptance-report.md")
            guard composerProvider?.model.id == chosen.model.id,
                  let brief = stageAttachments([attachment]).first, brief.kind == .document,
                  send(prompt, workspaceID: selectedWorkspaceID, mode: composerMode),
                  await waitForSmokeRun(),
                  let taskID = selectedID, selectedConversationWorkspace?.id == project.id,
                  let proposal = plan, proposal.title == "Project acceptance report", proposal.status == .ready,
                  let planningRun = try? await runtime.recentRuns(conversationID: taskID, limit: 1).first,
                  planningRun.modelID == chosen.model.id, planningRun.conversationMode == "plan" else {
                smokeRunDiagnostics.append("Project task did not reach plan review with the selected model.")
                return false
            }
            guard confirm() else {
                smokeRunDiagnostics.append("Project task plan confirmation control was unavailable.")
                return false
            }
            let deadline = ContinuousClock.now + .seconds(8)
            while pendingApproval == nil && ContinuousClock.now < deadline {
                if notice != nil && !isSending { break }
                try? await Task.sleep(for: .milliseconds(30))
            }
            guard let approval = pendingApproval, approval.conversationID == taskID,
                  approval.workspaceID == project.id, approval.path == report.lastPathComponent,
                  !FileManager.default.fileExists(atPath: report.path), approve(),
                  await waitForSmokeRun(),
                  (try? String(contentsOf: report, encoding: .utf8)) == "# Acceptance\nSynthetic attachment verified.\n" else {
                smokeRunDiagnostics.append("Project task did not write the approved report.")
                return false
            }

            await select(nil)
            await select(taskID)
            let runs = try? await runtime.recentRuns(conversationID: taskID, limit: 3)
            let owners = projectTaskMembership
            var reopenedAttachment: URL?
            await withSavedAttachment(id: brief.id, conversationID: taskID) { reopenedAttachment = $0 }
            guard selectedConversationWorkspace?.id == project.id, owners?[project.id]?.contains(taskID) == true,
                  reopenedAttachment?.standardizedFileURL == attachment.standardizedFileURL,
                  composerProvider?.model.id == chosen.model.id, plan?.status == .accepted,
                  runs?.count == 2, let execution = runs?.first,
                  execution.modelID == chosen.model.id, execution.id == approval.runID,
                  let message = messages.first(where: { PlanConfirmationSnapshot.from(message: $0) != nil }),
                  message.runID == execution.id,
                  messages.contains(where: { $0.content.contains("Acceptance report saved.") }) else {
                smokeRunDiagnostics.append("Project task lost its folder, selected model, plan or attachment after reopening.")
                return false
            }
            return true
        }
        let passed = await exercise()
        if isSending {
            stop()
            _ = await waitForSmokeRun()
        }
        return passed
    }

    func verifyPlanningSmoke(project: WorkspaceRecord) async -> (planSaved: Bool, goalSaved: Bool) {
        guard vault == nil, let runtime, !isSending,
              let planner = smokeProvider(.submitPlan), let worker = smokeProvider(.workOnGoal) else {
            return (false, false)
        }
        await select(nil)
        guard beginSend("Plan how to verify this project", runtime: runtime, provider: planner,
                        workspaceID: project.id, mode: .plan), await waitForSmokeRun(),
              let proposal = plan, proposal.title == "Fixture plan", proposal.status == .ready,
              let conversationID = selectedID,
              await acceptPlan(proposal) else { return (false, false) }
        await select(nil)
        await select(conversationID)
        guard plan?.id == proposal.id, plan?.status == .accepted,
              let confirmed = pendingAcceptedPlan,
              let executor = smokeProvider(.executePlan),
              beginSend(confirmed.executionPrompt, runtime: runtime, provider: executor,
                        mode: .agent, acceptedPlan: confirmed), await waitForSmokeRun(),
              messages.first(where: { $0.id == confirmed.messageID })?.runID == confirmed.executionRunID else {
            return (false, false)
        }
        let planSaved = pendingAcceptedPlan == nil
        let criterion = "Read the saved file and verify the requested text."
        guard beginSend("Verify the project output", runtime: runtime, provider: worker,
                        mode: .goal, criterion: criterion), await waitForSmokeRun(),
              let stored = goal, stored.acceptanceCriteria.contains(where: { $0.text == criterion }),
              stored.evidence.contains(where: { $0.kind == .toolResult }),
              (try? await runtime.recentRuns(conversationID: conversationID, limit: 1))?.first?.goalID == stored.id else {
            return (planSaved, false)
        }
        await select(nil)
        await select(conversationID)
        return (planSaved, goal?.id == stored.id)
    }

    func verifyGoalControlsSmoke() async -> Bool {
        guard vault == nil, let runtime, let initial = goal, let id = selectedID,
              canPauseGoal(initial), let provider = smokeProvider(.workOnGoal),
              let previousRun = try? await runtime.recentRuns(conversationID: id, limit: 1).first else {
            smokeRunDiagnostics.append("Goal control fixture unavailable: \(goal?.status.rawValue ?? "-")")
            return false
        }
        await pauseGoal(initial)
        guard let paused = goal, paused.status == .paused, paused.id == initial.id,
              paused.evidence == initial.evidence, canContinueGoal(paused),
              beginSend("Continue the fixture goal", runtime: runtime, provider: provider, mode: .goal, resumingGoal: true),
              await waitForSmokeRun(),
              let newest = try? await runtime.recentRuns(conversationID: id, limit: 1).first else { return false }
        guard newest.id != previousRun.id, newest.goalID == initial.id,
              let ready = goal, ready.id == initial.id, ready.objective == initial.objective,
              ready.progress.cycleCount == initial.progress.cycleCount + 1, ready.status == .verifying else {
            smokeRunDiagnostics.append("Goal continuation: newRun=\(newest.id != previousRun.id), sameGoal=\(newest.goalID == initial.id), status=\(goal?.status.rawValue ?? "-"), cycles=\(goal?.progress.cycleCount ?? -1), prior=\(initial.progress.cycleCount)")
            return false
        }

        await confirmGoal(ready, completedSteps: [], confirmedCriteria: [])
        guard let unchanged = goal, unchanged.status == .verifying, unchanged.evidence == ready.evidence else { return false }
        await confirmGoal(unchanged, completedSteps: Set(unchanged.steps.map(\.id)),
                          confirmedCriteria: Set(unchanged.acceptanceCriteria.map(\.id)))
        return goal?.status == .completed
            && goal?.evidence.contains(where: { $0.kind == .userConfirmation }) == true
    }

    func verifyReadOnlyModelToolsSmoke(project: WorkspaceRecord, documentName: String) async -> Bool {
        guard vault == nil, let runtime, !isSending else { return false }
        let previous = allowsWorkspaceWrites
        allowsWorkspaceWrites = false
        defer { allowsWorkspaceWrites = previous }
        for (tool, arguments, mode) in [
            ("workspace.searchFiles", ["query": "Synthetic attachment", "path": "fixture.md"], HostAgentMode.agent),
            ("workspace.readDocument", ["path": documentName], HostAgentMode.plan),
        ] {
            await select(nil)
            guard let provider = smokeProvider(.readWorkspace(tool, arguments)),
                  beginSend("Read the fixture", runtime: runtime, provider: provider,
                            workspaceID: project.id, mode: mode),
                  await waitForSmokeRun(), let id = selectedID,
                  let run = try? await runtime.recentRuns(conversationID: id, limit: 1).first,
                  let events = try? await runtime.runEvents(runID: run.id),
                  events.contains(where: { event in
                      guard event.kind == .toolResult,
                            let values = try? JSONDecoder().decode([String: String].self, from: Data(event.payloadJSON.utf8))
                      else { return false }
                      return values["id"] == "smoke-read-workspace" && values["status"] == "ok"
                          && values["summary"]?.contains("Synthetic attachment") == true
                  }) else { return false }
        }
        return true
    }

    func verifyConcurrentTasksSmoke(project: WorkspaceRecord, folder: URL, otherProject: WorkspaceRecord,
                                    otherFolder: URL, openProjectTask: (UUID) async -> Bool) async -> Bool {
        guard vault == nil, let runtime, activeRunCount == 0 else { return false }
        let firstName = "background-approved.txt"
        let secondName = "background-stopped.txt"
        let firstFile = folder.appendingPathComponent(firstName)
        let secondFile = otherFolder.appendingPathComponent(secondName)
        func waitForApproval() async -> HostAgentApproval? {
            let deadline = ContinuousClock.now + .seconds(4)
            while pendingApproval == nil && isSending && ContinuousClock.now < deadline {
                try? await Task.sleep(for: .milliseconds(25))
            }
            return pendingApproval
        }
        func exercise() async -> Bool {
            guard await openProjectTask(project.id), selectedWorkspaceID == project.id,
                  let first = smokeProvider(.createFile(firstName)),
                  beginSend("Create the first fixture", runtime: runtime, provider: first, workspaceID: selectedWorkspaceID, mode: .agent),
                  let approval = await waitForApproval(), approval.path == firstName,
                  approval.workspaceID == project.id else {
                smokeRunDiagnostics.append("Concurrent projects: the first approval did not arrive.")
                return false
            }
            let firstID = approval.conversationID
            guard await openProjectTask(otherProject.id), selectedWorkspaceID == otherProject.id,
                  !isSending, pendingApproval == nil, backgroundTaskIDs == [firstID] else {
                smokeRunDiagnostics.append("Concurrent projects: could not open an empty task in the second project.")
                return false
            }
            guard let second = smokeProvider(.createFile(secondName)),
                  beginSend("Create the second fixture", runtime: runtime, provider: second, workspaceID: selectedWorkspaceID, mode: .agent),
                  let secondApproval = await waitForApproval(), secondApproval.path == secondName,
                  secondApproval.workspaceID == otherProject.id, secondApproval.conversationID != firstID,
                  activeRunCount == 2 else {
                smokeRunDiagnostics.append("Concurrent projects: the second approval did not arrive with its project identity.")
                return false
            }
            let secondID = secondApproval.conversationID
            await resolveApproval(approval, allow: true)
            let scopeIsolated = pendingApproval == secondApproval && !FileManager.default.fileExists(atPath: firstFile.path)
                && hasPendingApproval(in: firstID)
            let activeCannotArchive = !(await changeConversationMetadata(id: firstID, change: .archive(true)))
            guard scopeIsolated, activeCannotArchive else {
                smokeRunDiagnostics.append("Concurrent projects: first approval or archive was accepted from the second task.")
                return false
            }
            await select(firstID)
            guard pendingApproval == approval, selectedID == firstID, backgroundTaskIDs == [secondID] else { return false }
            stopTask(secondID)
            guard pendingApproval == approval else { return false }
            await resolveApproval(approval, allow: true)
            let deadline = ContinuousClock.now + .seconds(6)
            while activeRunCount != 0 && ContinuousClock.now < deadline {
                try? await Task.sleep(for: .milliseconds(25))
            }
            guard activeRunCount == 0, selectedID == firstID, selectedConversationWorkspace?.id == project.id,
                  (try? String(contentsOf: firstFile, encoding: .utf8)) == "Synthetic workspace output.",
                  !FileManager.default.fileExists(atPath: secondFile.path),
                  messages.contains(where: { $0.content == "Create the first fixture" }),
                  messages.allSatisfy({ $0.conversationID == firstID }) else {
                smokeRunDiagnostics.append("Concurrent projects: final file or task ownership checks failed.")
                return false
            }
            let stoppedRun = try? await runtime.recentRuns(conversationID: secondID, limit: 1).first
            let stoppedAdmission = try? await runtime.admissionRecord(conversationID: secondID)
            guard stoppedRun?.state == "checkpointed", stoppedRun?.endedAt != nil,
                  stoppedAdmission?.phase.isUnresolved == false else { return false }
            await select(secondID)
            return selectedConversationWorkspace?.id == otherProject.id
                && messages.contains(where: { $0.content == "Create the second fixture" })
                && messages.allSatisfy { $0.conversationID == secondID }
        }
        let passed = await exercise()
        if !passed {
            let activeIDs = Array(liveRuns.keys)
            for id in activeIDs { stopTask(id) }
            let deadline = ContinuousClock.now + .seconds(6)
            while activeRunCount != 0 && ContinuousClock.now < deadline {
                try? await Task.sleep(for: .milliseconds(25))
            }
        }
        return passed
    }

    private func waitForSmokeRun() async -> Bool {
        let deadline = ContinuousClock.now + .seconds(8)
        while isSending && ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(30))
        }
        return !isSending && notice == nil && pendingApproval == nil
    }

    private func smokeProvider(_ action: SmokeTaskAdapter.Action) -> FloeMacSelfProviderBinding? {
        guard let config = try? HostAgentProvider(endpoint: "https://example.invalid/v1",
                    protocolKind: .openAIChatCompletions, modelID: "mac-task-smoke", apiKey: "",
                    supportsTools: true) else { return nil }
        return .init(provider: config.profile, model: config.model,
                     adapter: SmokeTaskAdapter(action: action), credentials: .init())
    }

    private struct SmokeTaskAdapter: ProviderAdapter {
        enum Action: Sendable {
            case createFile(String), replaceText(String, String), submitPlan, executePlan, workOnGoal
            case readWorkspace(String, [String: String])

            var isReadOnly: Bool {
                switch self {
                case .submitPlan, .readWorkspace: true
                default: false
                }
            }
        }
        let action: Action
        let protocolKind: ModelProtocol = .openAIChatCompletions

        func stream(request: ProviderStreamRequest,
                    credentials: ProviderCredentials) -> AsyncThrowingStream<AgentEvent, Error> {
            AsyncThrowingStream { stream in
                do {
                    if action.isReadOnly, !MacAgentWorkspaceTools.writeToolNames.isDisjoint(with: request.allToolNames) {
                        throw FloeError.validationFailed("Read-only run offered a workspace write")
                    }
                    let call = try firstCall()
                    if !request.toolResults.contains(where: { $0.callID == call.id }),
                       !request.replayedToolPairs.contains(where: { $0.call.id == call.id }) {
                        guard request.allToolNames.contains(call.toolName)
                            || request.toolSchemas.contains(where: { $0.name == call.toolName }) else {
                            throw FloeError.validationFailed("Smoke tool was not offered: \(call.toolName)")
                        }
                        stream.yield(.toolRequest(call))
                        stream.yield(.completed(.init(stopReason: .toolUse)))
                    } else {
                        let wasDeclined = request.replayedToolPairs.contains { $0.call.id == call.id && $0.result.status == .denied }
                            || request.toolResults.contains { $0.callID == call.id && $0.output.contains("User declined") }
                        let answer = wasDeclined ? "The operation was declined and the file was not created." : "Synthetic task response."
                        stream.yield(.textDelta(.init(text: answer)))
                        stream.yield(.completed(.init(stopReason: .endTurn)))
                    }
                    stream.finish()
                } catch {
                    stream.finish(throwing: error)
                }
            }
        }

        private func firstCall() throws -> ToolCall {
            switch action {
            case .readWorkspace(let tool, let arguments):
                return try ToolCall(id: "smoke-read-workspace", toolName: tool,
                                    argumentsJSON: JSONEncoder().encode(arguments), scope: .local)
            case .createFile(let file):
                let body = try JSONEncoder().encode(["path": file, "content": "Synthetic workspace output."])
                return try ToolCall(id: "smoke-\(file)", toolName: "workspace.createFile", argumentsJSON: body, scope: .local)
            case .replaceText(let file, let sha256):
                let body = try JSONEncoder().encode([
                    "path": file, "oldText": "before", "newText": "after", "expectedSHA256": sha256,
                ])
                return try ToolCall(id: "smoke-\(file)", toolName: MacAgentWorkspaceTools.replaceTextToolName,
                                    argumentsJSON: body, scope: .local)
            case .submitPlan:
                let plan = PlanSubmission(title: "Fixture plan", summary: "Inspect and verify the project output.",
                    sections: [.init(title: "Inspect output", body: "Read the project output and verify its text.")],
                    acceptanceCriteria: [.init(text: "The output contains the requested text.", verification: "Read the saved file.")])
                return try ToolCall(id: "smoke-plan", toolName: "plan.submit", argumentsJSON: JSONEncoder().encode(plan), scope: .local)
            case .executePlan, .workOnGoal:
                let body = try JSONEncoder().encode(["path": "fixture.md"])
                let id = actionIsPlanExecution ? "smoke-plan-read" : "smoke-goal-read"
                return try ToolCall(id: id, toolName: "workspace.readFile",
                                    argumentsJSON: body, scope: .local)
            }
        }

        private var actionIsPlanExecution: Bool {
            if case .executePlan = action { return true }
            return false
        }

        func listModels(provider: ProviderProfile, credentials: ProviderCredentials) async throws -> [ModelProfile] { [] }
    }
    #endif
    #endif
}
