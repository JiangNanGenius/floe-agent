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
#if FLOE_UNIFIED_MAC
import LocalAuthentication
#endif

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
         limits: ModelLimits = .init(contextTokens: 32_768, maxOutputTokens: 0), allowsPlainHTTP: Bool = false,
         catalog: ProviderCatalogIndex? = HostProviderAccount.providerCatalog) throws {
        let account = try HostProviderAccount.configured(name: displayName, endpoint: endpoint, protocolKind: protocolKind,
            apiKey: apiKey, presetID: presetID, allowsPlainHTTP: allowsPlainHTTP, catalog: catalog)
        let modelID = modelID.trimmingCharacters(in: .whitespacesAndNewlines)
        profile = account.profile
        var capabilities = ModelCapabilities.defaultTextModel(for: protocolKind).subtracting([.tools, .vision])
        if supportsImages { capabilities.insert(.vision) }
        if supportsTools { capabilities.insert(.tools) }
        model = ModelProfile(providerID: profile.id, remoteModelID: modelID, displayName: modelID,
                             limits: limits,
                             capabilities: capabilities)
        self.apiKey = account.apiKey
        self.presetID = presetID
        try validate()
    }

    mutating func setApprovalEligibility(_ enabled: Bool) {
        if enabled { model.capabilities.insert(.approval); model.useSurfaces?.insert(.approval) }
        else { model.capabilities.remove(.approval); model.useSurfaces?.remove(.approval) }
        model.explicitCapabilities = (model.explicitCapabilities ?? []).union(.approval)
    }

    mutating func applyCatalogModel(_ discovered: ModelProfile?) {
        guard let discovered, discovered.remoteModelID == model.remoteModelID else { return }
        let editable: ModelCapabilities = [.tools, .vision]
        let selected = model.capabilities.intersection(editable)
        let overrides = selected.symmetricDifference(discovered.capabilities.intersection(editable))
        let owned = (model.explicitCapabilities ?? []).union(editable)
        model.capabilities = discovered.capabilities.subtracting(owned).union(model.capabilities.intersection(owned))
        model.displayName = discovered.displayName
        if let metadata = discovered.reasoningMetadata { model.reasoningMetadata = metadata }
        if !overrides.isEmpty {
            model.explicitCapabilities = (model.explicitCapabilities ?? []).union(overrides)
        }
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

    init(profile: ProviderProfile, model: ModelProfile, apiKey: String, presetID: String?) {
        self.profile = profile
        self.model = model
        self.apiKey = apiKey
        self.presetID = presetID
    }

    var canSelectAsPrimary: Bool {
        profile.isEnabled && model.isEnabled && model.isVisibleInPrimaryPicker && model.supportsChatAgentSurface
    }

}

enum HostAgentMode: String, CaseIterable {
    case agent, chat, plan, goal

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
    var canAllow: Bool {
        #if FLOE_UNIFIED_MAC
        if MacNativeCommandPolicy.review(toolCall) != nil || MacTaskActionPreview(toolCall) != nil
            || MacTaskBrowserApproval.applies(to: toolCall) { return true }
        if toolName == WorkspaceOutputPublication.name,
           let args = try? JSONDecoder().decode(WorkspaceOutputPublication.Arguments.self, from: toolCall.argumentsJSON),
           let relative = try? MacAgentWorkspacePinSupport.standardizedRelativePath(args.path) {
            return relative != "." && (args.displayName.map(RunOutputFile.isValidDisplayName) ?? true)
        }
        if toolName == MacAgentWorkspaceTools.createDirectoryToolName, let path,
           let relative = try? MacAgentWorkspacePinSupport.standardizedRelativePath(path) {
            return relative != "."
        }
        #endif
        if toolName == DelegateTool.name { return text?.isEmpty == false }
        return path?.isEmpty == false && text != nil
    }

    #if FLOE_UNIFIED_MAC
    var cardRequest: PendingApproval {
        let writesFiles = MacAgentWorkspaceTools.writeToolNames.contains(toolName)
        let conversationAction = MacTaskActionPreview(toolCall)
        let riskLabels: Set<String>
        switch toolName {
        case MacNativeShellTool.name: riskLabels = ["executesLocalCode", "writesFiles"]
        case MacDesktopControl.name: riskLabels = ["controlsGUI"]
        case "browser.download": riskLabels = ["networkAccess", "writesFiles"]
        case _ where MacTaskBrowserApproval.applies(to: toolCall): riskLabels = ["controlsGUI"]
        case DelegateTool.name: riskLabels = Set(DelegateTool.riskLabels.map(\.rawValue))
        case _ where conversationAction != nil: riskLabels = conversationAction?.riskLabels ?? []
        default: riskLabels = writesFiles ? ["writesFiles"] : []
        }
        let displayReason = reason == "Human approval policy requires explicit user decision" ? "" : reason
        return PendingApproval(runID: runID, conversationID: conversationID, toolCall: toolCall,
                               reason: displayReason, riskLabels: riskLabels,
                               isSideEffecting: conversationAction?.changesState ?? !riskLabels.isEmpty,
                               requestedAt: requestedAt, workspaceID: workspaceID)
    }
    #endif
}

#if FLOE_UNIFIED_MAC
enum MacTaskBrowserApproval {
    static func applies(to call: ToolCall) -> Bool {
        guard case .local = call.scope else { return false }
        return ["browser.tab", "browser.click", "browser.type", "browser.scroll", "browser.download",
                "browser.takeover"].contains(call.toolName)
    }

    static func preview(_ call: ToolCall) -> (path: String?, text: String?)? {
        guard applies(to: call) else { return nil }
        struct Download: Decodable { let path: String; let url: URL }
        if call.toolName == "browser.download",
           let download = try? JSONDecoder().decode(Download.self, from: call.argumentsJSON) {
            return (download.path, download.url.host())
        }
        return (nil, call.toolName)
    }
}

private struct MacProjectApprovalContext {
    let grants: FloeMacSelfApprovalGrants
    let workspaceID: UUID
    let conversationID: UUID
    let root: URL
    let identities: [String: String]
    let primaryIsOnDevice: Bool
    let networkStatus: NetworkStatusMonitor

    func policy(_ mode: TaskApprovalMode, reviewer: FloeMacSelfProviderBinding?) -> any ApprovalPolicy {
        let taskPolicy = MacTaskApprovalPolicy.make(mode: mode, reviewer: reviewer,
            primaryIsOnDevice: primaryIsOnDevice, isOffline: networkStatus.isOffline)
        let files = grants.wrapping(taskPolicy, workspaceID: workspaceID, conversationID: conversationID,
                                   workspaceRoot: root, authorizationIdentities: identities)
        return MacNativeCommandPolicy(mode: mode, base: files)
    }
}

struct HostAgentToolActivity: Identifiable, Equatable {
    let id: String
    let toolName: String
    var state: String
    var summary: String?
    var outputPath: String?
    var outputWorkspaceID: UUID?
    var mediaArtifacts: [ToolArtifactReference] = []

    mutating func applyMediaReceipt(_ values: [String: String], conversationID: UUID, workspaceID: UUID?) {
        mediaArtifacts = []
        guard values["tool"] == toolName, values["id"] == id, values["status"] == "ok",
              values["dispatched"] == "true", values["outcomeUnknown"] != "true",
              let owner = values["workspaceID"].flatMap(UUID.init(uuidString:)), owner == workspaceID,
              let json = values["artifactRefsJSON"], json.utf8.count <= 65_536 else { return }
        let folder: String
        let mimePrefix: String
        switch toolName {
        case MacTaskImageGenerateTool.name:
            folder = "GeneratedImages/" + conversationID.uuidString + "/"
            mimePrefix = "image/"
        case "video.generate", "video.status", "video.cancel":
            folder = MacTaskVideoOwner.directoryName(conversationID) + "/"
            mimePrefix = "video/"
        default: return
        }
        guard let references = try? JSONDecoder().decode([ToolArtifactReference].self, from: Data(json.utf8)) else { return }
        var seenPaths = Set<String>()
        var seenIDs = Set<UUID>()
        for ref in references where ref.byteCount > 0 && ref.mimeType.hasPrefix(mimePrefix)
            && ref.relativePath.hasPrefix(folder) && MacAgentWorkspaceTools.canRememberFile(ref.relativePath)
            && ref.sha256.utf8.count == 64 && ref.sha256.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) {
            guard !seenIDs.contains(ref.id), seenPaths.insert(ref.relativePath).inserted else { continue }
            seenIDs.insert(ref.id)
            mediaArtifacts.append(ref)
        }
        if !mediaArtifacts.isEmpty { outputWorkspaceID = owner }
    }
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
        var reconnectAttempt: Int?
        var reasoningText = ""
        var awaitingModel = false
        var waitingForQuestion = false
        var reviewingCalls = Set<String>()
        var approval: HostAgentApproval?
        /// Live question card projected from the durable question center.
        var question: HostAgentQuestion?
        var stopping = false
        var resolvingApproval = false
        var steering = false
        var lastSteer: String?
        var modelID: UUID?
        #if FLOE_UNIFIED_MAC
        var approvalContext: MacProjectApprovalContext?
        var approvalMode: TaskApprovalMode = .ask
        #endif
    }

    @Published private(set) var isReady = false
    @Published private(set) var isPreparing = false
    @Published private(set) var isTerminating = false
    @Published private var liveRuns: [UUID: LiveRun] = [:]
    #if !FLOE_UNIFIED_MAC
    private var newDraftRunID: UUID?
    #endif
    private var liveSnapshotVersions: [UUID: Int] = [:]

    private var visibleTaskID: UUID? {
        #if FLOE_UNIFIED_MAC
        selectedID ?? cachedDraftTaskID
        #else
        selectedID ?? newDraftRunID
        #endif
    }

    private var visibleRun: LiveRun? {
        guard let id = visibleTaskID else { return nil }
        return liveRuns[id]
    }

    private var activeRun: FloeMacSelfSessionHandle? { visibleRun?.handle }
    var isSending: Bool { visibleRun != nil }
    var isStopping: Bool { visibleRun?.stopping == true }
    var activeRunCount: Int { liveRuns.count }
    var pendingApproval: HostAgentApproval? { visibleRun?.approval }
    /// The question card for the visible task: the live run projection while a
    /// run is parked, otherwise the durable card restored for a reopened task.
    var pendingQuestion: HostAgentQuestion? {
        if let visibleRun { return visibleRun.question }
        return selectedID.flatMap { restoredQuestions[$0] }
    }
    var isResolvingApproval: Bool { visibleRun?.resolvingApproval == true }
    var runPhase: FloeMacSelfSessionPhase? { visibleRun?.phase }
    var liveReasoning: String { visibleRun?.reasoningText ?? "" }
    var awaitingModel: Bool { visibleRun?.awaitingModel == true }
    var reconnectAttempt: Int? { visibleRun?.reconnectAttempt }
    var isReviewingApproval: Bool { visibleRun?.reviewingCalls.isEmpty == false }
    var streamedText: String { visibleRun?.streamedText ?? "" }
    var pendingPrompt: String? {
        guard let run = visibleRun else { return nil }
        if let id = run.handle?.identity.userMessageID, messages.contains(where: { $0.id == id }) { return nil }
        return run.prompt
    }

    var backgroundTaskIDs: [UUID] {
        liveRuns.filter { $0.key != visibleTaskID }
            .sorted { $0.value.startedAt < $1.value.startedAt }
            .map(\.key)
    }

    // MARK: - Owned background project subagents (host-facing surface)

    /// Active and completed children of the presented task (durable read).
    var presentedChildSubagents: [HostChildSubagentSnapshot] { childSubagents.presentedChildren }

    /// Durable children of any task, bound or not — the history surface.
    func childSubagents(of taskID: UUID) async -> [HostChildSubagentSnapshot] {
        await childSubagents.children(of: taskID)
    }

    /// Cancels exactly one background child of one bound parent run; the
    /// child settles durably as terminal `.cancelled`.
    @discardableResult
    func cancelChildSubagent(runID: UUID, conversationID: UUID, childID: UUID) async -> Bool {
        await childSubagents.cancelChild(runID: runID, conversationID: conversationID, childID: childID)
    }

    func isTaskRunning(_ id: UUID) -> Bool { liveRuns[id] != nil }
    func hasPendingApproval(in id: UUID) -> Bool { liveRuns[id]?.approval != nil }
    func isWaitingForAnswer(in id: UUID) -> Bool { liveRuns[id]?.waitingForQuestion == true }
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
    @Published var windowShowsTask = false
    var draftSelectionID: UUID { historySelection }
    #if FLOE_MAC_HOST_SMOKE
    var smokeOwnerAuthentication: (() -> Bool)?
    var smokeAuxiliaryModelsMounted = false
    var smokeTaskSearchMounted = false
    var smokeTaskFindInvocations = 0
    var smokeConversationSearchMounted = false
    var smokeApprovalFrames: [Bool: CGRect] = [:]
    var smokeRunningModeFrame: CGRect?
    var smokePromptFrame: CGRect?
    var smokeSteerFrame: CGRect?
    var smokeModeFrame: CGRect?
    var smokeComposerModelFrame: CGRect?
    var smokeClosePlanFrame: CGRect?
    var smokeReopenPlanFrame: CGRect?
    var smokePlanExecuteFrame: CGRect?
    var smokeProjectNewTaskFrames: [UUID: CGRect] = [:]
    var smokeProjectNameFrames: [UUID: CGRect] = [:]
    var smokeSpacePage: MacSpacePage?
    var smokeCreativeMounted = false
    var smokeMediaAddFrame: CGRect?
    var smokeMediaSettingsRole: String?
    var smokeCreativeFrame: CGRect?
    var smokeSpaceFrame: CGRect?
    var smokeSpacePickerFrame: CGRect?
    var smokeInspectorShown = false
    var smokeFilesTakeDetail = false
    #endif
    @Published var allowsWorkspaceWrites: Bool { didSet { preferences.set(allowsWorkspaceWrites, forKey: "floe.mac.workspace.allowWrites") } }
    @Published var verifyAgentAnswers: Bool { didSet { preferences.set(verifyAgentAnswers, forKey: "floe.mac.agent.verifyAnswers") } }
    @Published var defaultMode: HostAgentMode { didSet { preferences.set(defaultMode.rawValue, forKey: "floe.mac.agent.defaultMode") } }
    @Published private(set) var defaultApprovalMode: TaskApprovalMode
    @Published private(set) var approvalModelID: UUID?
    @Published private var selectedApprovalMode: TaskApprovalMode?
    @Published private var draftApprovalMode: TaskApprovalMode?
    @Published private(set) var savingApprovalMode = false
    @Published private(set) var approvalSettingsError: String?
    private static let defaultApprovalKey = "floe.mac.agent.defaultApprovalMode"
    private static let reviewerKey = "floe.mac.agent.approvalModelID"

    var taskApprovalMode: TaskApprovalMode {
        selectedID == nil ? draftApprovalMode ?? defaultApprovalMode : selectedApprovalMode ?? .ask
    }

    private var reviewer: FloeMacSelfProviderBinding? {
        providers.first { $0.model.id == approvalModelID && $0.profile.isEnabled && $0.model.isEnabled && $0.model.supportsApprovalSurface }?.binding()
    }

    func approvalGrantStore() async throws -> FloeMacSelfApprovalGrants {
        guard isReady, let runtime else { throw CocoaError(.fileReadUnknown) }
        return try await runtime.approvalGrantStore()
    }

    func setApprovalModelID(_ id: UUID?) {
        guard !savingApprovalMode, id != approvalModelID, !isTerminating,
              id == nil || providers.contains(where: {
                  $0.model.id == id && $0.profile.isEnabled && $0.model.isEnabled && $0.model.supportsApprovalSurface
              }) else { return }
        approvalModelID = id
        preferences.set(id?.uuidString, forKey: Self.reviewerKey)
        refreshAutomaticReviewers()
    }

    private func refreshAutomaticReviewers() {
        let handles = liveRuns.values.compactMap { run -> (FloeMacSelfSessionHandle, MacProjectApprovalContext)? in
            guard run.approvalMode == .automatic, !run.stopping, let handle = run.handle,
                  let context = run.approvalContext else { return nil }
            return (handle, context)
        }
        guard !handles.isEmpty, !savingApprovalMode, let release = admit() else { return }
        let selected = reviewer
        savingApprovalMode = true
        Task {
            defer { savingApprovalMode = false; release() }
            for (handle, context) in handles where liveRuns[context.conversationID]?.handle?.identity == handle.identity {
                _ = await handle.updateApprovalPolicy(context.policy(.automatic, reviewer: selected))
                await updateLiveRun(handle)
            }
        }
    }

    private func authorizeFullAccess() async throws -> Bool {
        #if FLOE_MAC_HOST_SMOKE
        if vault == nil, let smokeOwnerAuthentication { return smokeOwnerAuthentication() }
        #endif
        return try await LAContext().evaluatePolicy(.deviceOwnerAuthentication,
            localizedReason: String(localized: "mac.permissions.authenticate"))
    }

    @discardableResult
    func setApprovalMode(_ mode: TaskApprovalMode, asDefault: Bool) async -> Bool {
        guard isReady, !isTerminating, !savingApprovalMode, let runtime, let release = admit() else { return false }
        let id = selectedID
        let selection = historySelection
        approvalSettingsError = nil
        guard asDefault || (!isLoadingHistory && (!isSending || activeRun != nil)) else { release(); return false }
        if mode == (asDefault ? defaultApprovalMode : taskApprovalMode) { release(); return true }
        savingApprovalMode = true
        defer { savingApprovalMode = false; release() }
        do {
            if mode == .fullAccess {
                guard try await authorizeFullAccess() else { return false }
            }
            guard !isTerminating, asDefault || (selection == historySelection && id == selectedID) else { return false }
            if asDefault {
                defaultApprovalMode = mode
                preferences.set(mode.rawValue, forKey: Self.defaultApprovalKey)
            } else if let id {
                try await runtime.setTaskApprovalMode(mode, conversationID: id)
                if let handle = liveRuns[id]?.handle, let context = liveRuns[id]?.approvalContext {
                    liveRuns[id]?.approvalMode = mode
                    _ = await handle.updateApprovalPolicy(context.policy(mode, reviewer: reviewer))
                    await updateLiveRun(handle)
                }
                if selection == historySelection { selectedApprovalMode = mode }
            } else { draftApprovalMode = mode }
            return true
        } catch {
            if let auth = error as? LAError, [.userCancel, .appCancel, .systemCancel].contains(auth.code) { return false }
            let message = (error as? LAError)?.localizedDescription ?? String(localized: "mac.permissions.saveFailed")
            if asDefault { approvalSettingsError = message }
            if selection == historySelection { notice = message }
            return false
        }
    }

    @Published private(set) var chatReasoning: ChatReasoningPreference = .fast
    @Published private(set) var savingChatReasoning = false

    func changeChatReasoning(_ value: ChatReasoningPreference) async {
        guard !isSending, !isTerminating, !isLoadingHistory, !savingChatReasoning, let runtime else { return }
        guard let id = selectedID else { chatReasoning = value; return }
        guard let release = admit() else { return }
        let selection = historySelection
        savingChatReasoning = true
        defer { savingChatReasoning = false; release() }
        do {
            try await runtime.setChatReasoning(value, conversationID: id)
            if selection == historySelection { chatReasoning = value }
        } catch {
            if selection == historySelection { notice = String(localized: "mac.reasoning.saveFailed") }
        }
    }

    func changeModelEffort(_ value: ModelReasoningEffort, modelID: UUID) {
        _ = updateProviderStore { store in
            let (i, j) = try store.indices(for: modelID)
            store.accounts[i].models[j].reasoningEffort = value == .automatic ? nil : value
        }
    }

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
    weak var taskImages: MacImageGeneration?
    weak var taskVideos: MacVideoGeneration?
    var makeTaskBrowserTools: ((UUID, URL) -> [AnyAgentTool])?
    var endTaskBrowserRun: ((UUID) -> Void)?
    let webSearch: MacSearchSettings
    private let networkStatus = NetworkStatusMonitor()
    @Published private(set) var auxiliaryPreferences: ModelSelectionPreferences
    @Published var auxiliaryVisionReasoning: Bool {
        didSet { preferences.set(auxiliaryVisionReasoning, forKey: Self.visionReasoningKey) }
    }
    private static let auxiliaryPreferencesKey = "floe.mac.agent.auxiliaryModels.v1"
    private static let visionReasoningKey = "floe.mac.agent.auxiliaryVisionReasoning"
    private var namingTasks: [UUID: Task<Void, Never>] = [:]

    func updateProviderOptions(providerID: UUID, modelID: UUID, enabled: Bool, compatibility: Bool,
                               headers: [String: String], displayName: String, hidden: Bool, omitReasoning: Bool) -> Bool {
        updateProviderStore { store in
            let (i, j) = try store.indices(for: modelID)
            guard store.accounts[i].id == providerID else { throw ProviderStoreError.missingRecord }
            store.accounts[i].profile.isEnabled = enabled
            store.accounts[i].profile.toolNameCompatibility = compatibility
            store.accounts[i].profile.nonSecretHeaders = headers
            store.accounts[i].models[j].displayName = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
            store.accounts[i].models[j].isHiddenFromPrimaryPicker = hidden
            store.accounts[i].models[j].omitReasoningParameters = omitReasoning
        }
    }

    func auxiliaryCandidates(_ role: MacAuxiliaryRole) -> [HostAgentProvider] {
        providers.filter { $0.profile.isEnabled && $0.model.isEnabled && role.accepts($0.model) }
    }

    func setAuxiliaryModel(_ id: UUID?, for role: MacAuxiliaryRole) {
        guard id == nil || auxiliaryCandidates(role).contains(where: { $0.model.id == id }) else { return }
        var next = auxiliaryPreferences
        switch role {
        case .text: next.generalAuxiliaryLLMModelID = id
        case .vision: next.visionModelID = id
        }
        saveAuxiliaryPreferences(next)
    }

    func setAutonomousImageRouting(_ enabled: Bool) {
        var next = auxiliaryPreferences
        next.autonomousImageRouting = enabled
        saveAuxiliaryPreferences(next)
    }

    private func saveAuxiliaryPreferences(_ value: ModelSelectionPreferences) {
        var next = value
        guard next != auxiliaryPreferences else { return }
        next.updatedAt = Date()
        guard let data = try? JSONEncoder().encode(next) else { return }
        preferences.set(data, forKey: Self.auxiliaryPreferencesKey)
        auxiliaryPreferences = next
    }

    func reconcileAuxiliaryModels() {
        for role in MacAuxiliaryRole.allCases {
            if let id = role.selection(in: auxiliaryPreferences), !providers.contains(where: { $0.model.id == id }) {
                setAuxiliaryModel(nil, for: role)
            }
        }
    }

    func selectedAuxiliary(_ role: MacAuxiliaryRole) -> HostAgentProvider? {
        let id = role.selection(in: auxiliaryPreferences)
        return auxiliaryCandidates(role).first { $0.model.id == id }
    }

    private func auxiliaryText(for main: FloeMacSelfProviderBinding) -> FloeMacSelfProviderBinding? {
        if auxiliaryPreferences.generalAuxiliaryLLMModelID != nil { return selectedAuxiliary(.text)?.binding() }
        return main.model.supportsGeneralAuxiliaryLLM ? main : nil
    }

    private func auxiliaryRoutes(for main: FloeMacSelfProviderBinding) -> FloeMacSelfAuxiliaryRoutes {
        let helper = auxiliaryText(for: main)
        let classifier = helper.flatMap { binding -> AutomaticReasoningEffortAuxiliaryClassifier? in
            if binding.provider.kind == .local && binding.model.id == main.model.id { return nil }
            return .init(provider: binding.provider, model: binding.model, credentials: binding.credentials, adapter: binding.adapter)
        }
        return .init(vision: selectedAuxiliary(.vision)?.binding(), visionReasoning: auxiliaryVisionReasoning, effortClassifier: classifier)
    }

    private func scheduleTaskTitle(_ id: UUID, prompt: String, helper: FloeMacSelfProviderBinding,
                                   primary: FloeMacSelfProviderBinding, runtime: FloeMacSelfRuntime) {
        guard !isTerminating, namingTasks[id] == nil else { return }
        let safePrompt = SecretRedactor.redact(SecretRedactor.redact(prompt, secret: primary.credentials.apiKey), secret: helper.credentials.apiKey)
        guard !safePrompt.contains(SecretRedactor.replacement) else { return }
        namingTasks[id] = Task { [weak self] in
            defer { self?.namingTasks.removeValue(forKey: id) }
            guard let title = try? await MacTaskNaming.title(for: safePrompt, using: helper),
                  !Task.isCancelled, let self, !self.isTerminating,
                  (try? await runtime.saveAutomaticTitle(title, conversationID: id)) == true else { return }
            try? await self.reloadConversations(using: runtime)
        }
    }

    private let preferences: UserDefaults
    @Published private var taskModelID: UUID?
    @Published private var failedRunID: UUID?
    @Published private var historyContinuation: (run: RunRecord, action: FloeMacSelfContinuation)?
    var continuableRun: RunRecord? {
        guard isReady, !isSending, !isLoadingHistory, !historyLoadFailed, !isTerminating, !isAcceptingPlan,
              pendingAcceptedPlan == nil, plan?.awaitsConfirmation != true, pendingQuestion == nil,
              let run = historyContinuation?.run, run.conversationID == selectedID else { return nil }
        return run
    }
    var resumesOriginalRun: Bool { historyContinuation?.action.resumesOriginalRun == true }
    var restoredApprovalSummary: String? {
        guard let approval = historyContinuation?.action.pendingApproval else { return nil }
        return "\(approval.toolCall.toolName) · \(approval.reason)"
    }
    var needsInterruptedRunReview: Bool { historyContinuation?.action.needsReview == true }
    @Published private var changingGoals = Set<UUID>()
    private var goalReviews: [UUID: Task<ConversationGoal?, Never>] = [:]
    @Published private(set) var settledQuestions: [UUID: [UserQuestionWaitingSnapshot]] = [:]
    /// Durable question card re-presented for a reopened task that has no
    /// live run (relaunch/reconnect). The durable store and coordinator remain
    /// the only writers; this is a read projection of their exact
    /// conversation/run/request/question state. It is set only for the
    /// selected task with a stable load generation, and it steps aside the
    /// moment a live run exists for the same task again.
    @Published private(set) var restoredQuestions: [UUID: HostAgentQuestion] = [:]
    @Published private(set) var runToolActivity: [UUID: [HostAgentToolActivity]] = [:]
    @Published private(set) var showsModelSettingsForFailure = false
    var officialCatalogs: FloeMacOfficialCatalogs?
    @Published private(set) var modelProviderCatalog = HostProviderAccount.providerCatalog
    @Published private(set) var refreshingModelProviderCatalog = false
    private var modelProviderCatalogRevision = UUID()

    func loadActiveModelProviderCatalog() async {
        let revision = modelProviderCatalogRevision
        guard let officialCatalogs, !refreshingModelProviderCatalog,
              let bytes = try? await officialCatalogs.active(.models),
              let catalog = try? ProviderCatalogIndex.validated(from: bytes),
              revision == modelProviderCatalogRevision else { return }
        modelProviderCatalog = catalog
    }

    func refreshModelProviderCatalog() async throws {
        guard let officialCatalogs, !refreshingModelProviderCatalog else { return }
        modelProviderCatalogRevision = UUID()
        refreshingModelProviderCatalog = true
        defer { refreshingModelProviderCatalog = false }
        if let bytes = try await officialCatalogs.refresh(.models, validate: {
            _ = try ProviderCatalogIndex.validated(from: $0)
        }) {
            modelProviderCatalog = try ProviderCatalogIndex.validated(from: bytes)
        }
    }

    var liveToolActivity: [HostAgentToolActivity] {
        guard let runID = activeRun?.identity.runID else { return [] }
        return runToolActivity[runID] ?? []
    }

    var composerProvider: HostAgentProvider? {
        providers.first { $0.model.id == taskModelID && $0.profile.isEnabled && $0.model.isEnabled && $0.model.supportsChatAgentSurface }
            ?? providers.first { $0.model.id == selectedModelID && $0.canSelectAsPrimary }
            ?? providers.first(where: \.canSelectAsPrimary)
    }

    var failedUserMessage: PersistedMessage? {
        guard let failedRunID else { return nil }
        return messages.first {
            $0.runID == failedRunID && $0.role == "user"
                && PlanConfirmationSnapshot.from(message: $0) == nil
        }
    }

    func selectComposerProvider(_ id: UUID) {
        if let model = providers.first(where: { $0.profile.id == id && $0.canSelectAsPrimary }) { selectComposerModel(model.model.id) }
    }

    @discardableResult
    func selectComposerModel(_ id: UUID) -> Bool {
        guard !isSending, !isLoadingHistory, !isTerminating,
              providers.contains(where: { $0.model.id == id && $0.canSelectAsPrimary }) else { return false }
        taskModelID = id
        return true
    }

    #endif
    @Published private(set) var modelName: String?
    @Published private(set) var conversations: [ConversationRecord] = []
    @Published private(set) var recentTaskRuns: [UUID: RunRecord] = [:]
    @Published private(set) var taskRunLookupFailed = false
    // Task Center cross-conversation content search. Query/scope are host
    // in-memory state only (never persisted), so returning from an opened
    // match restores the exact search without keeping any user query log.
    @Published var taskCenterQuery = ""
    @Published var taskCenterShowsArchived = false
    @Published private(set) var taskContentMatchesByID: [UUID: ConversationSearchMatch] = [:]
    @Published private(set) var taskContentSearchFailed = false
    @Published private(set) var selectedID: UUID?
    #if FLOE_UNIFIED_MAC
    @Published private(set) var admittedDraftID: UUID?
    private let transcriptPager = ThreadHistoryPager()
    private var transcriptObservation: AnyCancellable?
    var messages: [PersistedMessage] { transcriptPager.messages }
    var hasEarlierMessages: Bool { transcriptPager.hasEarlierMessages }
    var transcriptLiveRunID: UUID? { activeRun?.identity.runID }
    var transcriptRuns: [RunRecord] {
        let visible = Set(messages.compactMap(\.runID))
            .union([transcriptLiveRunID ?? transcriptPager.runs.first?.id].compactMap { $0 })
        return transcriptPager.runs.filter { visible.contains($0.id) }
    }
    var transcriptEventsByRun: [UUID: [RunEventRecord]] { transcriptPager.eventsByRun }
    var earlierEventRunIDs: Set<UUID> { transcriptPager.earlierEventRunIDs }
    var loadingEventRunIDs: Set<UUID> { transcriptPager.loadingEventRunIDs }
    var failedEarlierEventRunIDs: Set<UUID> { transcriptPager.failedEarlierEventRunIDs }
    #else
    @Published private(set) var messages: [PersistedMessage] = []
    @Published private(set) var hasEarlierMessages = false
    #endif
    @Published private(set) var isLoadingHistory = false
    @Published private(set) var isLoadingEarlierMessages = false
    @Published private(set) var historyLoadFailed = false
    /// Projects the user can choose for a new task.
    @Published private(set) var workspaces: [WorkspaceRecord] = []
    @Published private(set) var projectTaskMembership: [UUID: Set<UUID>]?
    @Published private(set) var projectTasksUnavailable = false
    @Published private(set) var selectedWorkspaceID: UUID?
    #if FLOE_UNIFIED_MAC

    /// Stable UUID of the current unsaved draft, persisting across
    /// navigating away and relaunches until the first send is durably
    /// admitted. A draft's personal safe-files root
    /// (`PrivateTasks/<draft UUID>`) is therefore stable from before the
    /// first send through admission; the next draft — including one started
    /// after an admitted conversation or while other runs are live — always
    /// allocates a fresh UUID once the previous one has been admitted.
    /// Reading this property never creates a directory; it only mints and
    /// persists an id on first use, so repeated SwiftUI body reads observe
    /// one constant value.
    private var cachedDraftTaskID: UUID?
    private static let draftTaskIDKey = "floe.mac.agent.draftTaskID"

    var attachmentOwnerID: UUID { selectedID ?? draftTaskID }
    var uncommittedDraftID: UUID { draftTaskID }
    var idsWithRuns: Set<UUID> { Set(liveRuns.keys) }

    private var draftTaskID: UUID {
        if let cachedDraftTaskID { return cachedDraftTaskID }
        if let raw = preferences.string(forKey: Self.draftTaskIDKey),
           let persisted = UUID(uuidString: raw) {
            cachedDraftTaskID = persisted
            return persisted
        }
        let minted = UUID()
        preferences.set(minted.uuidString, forKey: Self.draftTaskIDKey)
        cachedDraftTaskID = minted
        return minted
    }

    /// Called once a draft's first send is durably admitted: the admitted
    /// conversation itself owns the id from here on, so the next draft must
    /// allocate a distinct UUID.
    private func clearDraftTaskID() {
        cachedDraftTaskID = nil
        preferences.removeObject(forKey: Self.draftTaskIDKey)
    }
    #endif
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
    /// Owned background project subagents (shared iOS v1.8.57 delegation on
    /// Mac). One controller for the workspace; every project Agent/Goal run
    /// binds its parent run for the session's lifetime, concurrently with
    /// any background task. Selection is presentation only.
    let childSubagents = HostChildSubagentController()
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
    private var taskContentLookup = UUID()
    private var taskContentSearchTask: Task<Void, Never>?
    /// Debounce for typing-driven Task Center content search (mirrors the
    /// in-conversation find model). Restoration (on appear / scope change)
    /// reschedules and is covered by the same latest-query-wins fence.
    private static let taskContentSearchDebounce: Duration = .milliseconds(180)
    private var historySelection = UUID()
    #if !FLOE_UNIFIED_MAC
    private var earlierMessageCursor: ConversationMessageCursor?
    #endif
    /// Durable user-question event subscription (one per runtime lifetime).
    private var questionSubscription: UUID?
    private static let settingsAccount = "selected-chat-provider.v1"
    private static let providerListAccount = "chat-providers.v2"
    @Published private(set) var accounts: [HostProviderAccount] = []
    @Published private(set) var selectedModelID: UUID?

    init(supportDirectory: URL, namespace: String, useKeychain: Bool = true, preferences: UserDefaults = .standard,
         admitWork: @escaping AdmitWork = { {} }) {
        self.supportDirectory = supportDirectory
        self.namespace = namespace
        self.vault = useKeychain ? KeychainStore(service: namespace + ".chat",
            synchronizable: false, accessibility: .whenUnlockedThisDeviceOnly) : nil
        self.admitWork = admitWork
        #if FLOE_UNIFIED_MAC
        self.webSearch = MacSearchSettings(namespace: namespace, useKeychain: useKeychain, preferences: preferences)
        self.preferences = preferences
        self.auxiliaryPreferences = preferences.data(forKey: Self.auxiliaryPreferencesKey)
            .flatMap { try? JSONDecoder().decode(ModelSelectionPreferences.self, from: $0) } ?? .init()
        self.auxiliaryVisionReasoning = preferences.bool(forKey: Self.visionReasoningKey)
        self.defaultApprovalMode = preferences.string(forKey: Self.defaultApprovalKey).flatMap(TaskApprovalMode.init(rawValue:)) ?? .ask
        self.approvalModelID = preferences.string(forKey: Self.reviewerKey).flatMap(UUID.init(uuidString:))
        self.allowsWorkspaceWrites = preferences.object(forKey: "floe.mac.workspace.allowWrites") as? Bool ?? true
        self.verifyAgentAnswers = preferences.bool(forKey: "floe.mac.agent.verifyAnswers")
        // A fresh install composes in Agent: both the first launch and every
        // new task default to Agent until the user explicitly picks another
        // mode (the explicit choice keeps persisting here).
        self.defaultMode = preferences.string(forKey: "floe.mac.agent.defaultMode").flatMap(HostAgentMode.init(rawValue:)) ?? .agent
        self.taskModes = preferences.dictionary(forKey: Self.taskModesKey) as? [String: String] ?? [:]
        self.transcriptObservation = transcriptPager.objectWillChange.sink { [weak self] in
            self?.objectWillChange.send()
        }
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
            try await childSubagents.prepare(runtime: runtime)
            // Archived tasks stay out of the workspace; they are only
            // reachable again after an explicit restore.
            conversations = try await runtime.conversations(includeArchived: true)
            #if FLOE_UNIFIED_MAC
            if conversations.contains(where: { $0.id == draftTaskID }) { clearDraftTaskID() }
            #endif
            workspaces = try await runtime.workspaces()
            await reloadProjectTasks(using: runtime)
            if let recent = conversations.first(where: { $0.isVisibleInOrdinaryList }) {
                selectedID = recent.id
                #if FLOE_UNIFIED_MAC
                try await refreshTranscript(for: recent.id, runtime: runtime)
                #else
                applyHistory(try await runtime.conversationMessagePage(conversationID: recent.id))
                #endif
                selectedConversationWorkspace = try? await runtime.workspaceForConversation(recent.id)
                #if FLOE_UNIFIED_MAC
                let run = transcriptPager.runs.first
                selectedApprovalMode = try await runtime.taskApprovalMode(conversationID: recent.id)
                chatReasoning = try await runtime.chatReasoning(conversationID: recent.id)
                applyComposerRun(run)
                if let run {
                    await loadToolActivity(runID: run.id, conversationID: recent.id, runtime: runtime)
                    await loadHistoryContinuation(run, runtime: runtime)
                }
                #endif
                await loadPlanning(conversationID: recent.id, runtime: runtime)
            }
            isReady = true
            restoreStagedAttachments(for: selectedID)
            reloadProviders()
            #if FLOE_UNIFIED_MAC
            if let selectedID { await refreshQueue(selectedID) }
            #endif
            await subscribeQuestionEvents(using: runtime)
            if let selectedID { await restoreQuestion(for: selectedID) }
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
        if let active = providers.first(where: { $0.model.id == selectedModelID }) {
            return updateProvider(id: active.profile.id, name: active.profile.displayName, endpoint: endpoint,
                                  protocolKind: protocolKind, modelID: modelID, key: key, editingModelID: active.model.id)
        }
        return addProvider(name: nil, endpoint: endpoint, protocolKind: protocolKind, modelID: modelID, key: key)
    }

    private var configuredProviderCatalog: ProviderCatalogIndex? {
        #if FLOE_UNIFIED_MAC
        modelProviderCatalog
        #else
        HostProviderAccount.providerCatalog
        #endif
    }

    /// Media-only accounts leave the currently selected chat model in place.
    @discardableResult
    func addProvider(name: String?, endpoint: String, protocolKind: ModelProtocol,
                     modelID: String, key: String, supportsImages: Bool = false, supportsTools: Bool = false,
                     presetID: String? = nil, limits: ModelLimits = .init(contextTokens: 32_768, maxOutputTokens: 0),
                     allowsPlainHTTP: Bool = false, catalogModel: ModelProfile? = nil,
                     explicit: ModelCapabilities = [], supportsApproval: Bool? = nil,
                     role: ProviderCatalogServiceRole = .conversation) -> Bool {
        updateProviderStore { store in
            if modelID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                var account = try HostProviderAccount.configured(name: name, endpoint: endpoint, protocolKind: protocolKind,
                    apiKey: key, presetID: presetID, allowsPlainHTTP: allowsPlainHTTP, catalog: configuredProviderCatalog)
                account.initialRole = role
                store.accounts.append(account)
                return
            }
            var record = try HostAgentProvider(displayName: name, endpoint: endpoint,
                                               protocolKind: protocolKind, modelID: modelID, apiKey: key,
                                               supportsImages: supportsImages, supportsTools: supportsTools,
                                               presetID: presetID, limits: limits, allowsPlainHTTP: allowsPlainHTTP,
                                               catalog: configuredProviderCatalog)
            record.model.explicitCapabilities = explicit
            record.applyCatalogModel(catalogModel)
            if let supportsApproval { record.setApprovalEligibility(supportsApproval) }
            role.configureNewModel(&record.model)
            var account = HostProviderAccount(record)
            account.initialRole = role
            store.accounts.append(account)
            if store.selected == nil, record.canSelectAsPrimary { store.selectedModelID = record.model.id }
        }
    }

    /// Replaces the record at `id`, keeping its identity so existing
    /// selections and conversations stay bound to the same provider.
    @discardableResult
    func updateProvider(id: UUID, name: String?, endpoint: String, protocolKind: ModelProtocol,
                        modelID: String, key: String, supportsImages: Bool = false, supportsTools: Bool = false,
                        presetID: String? = nil, limits: ModelLimits? = nil, allowsPlainHTTP: Bool = false,
                        catalogModel: ModelProfile? = nil, explicit: ModelCapabilities = [], supportsApproval: Bool? = nil, editingModelID: UUID? = nil) -> Bool {
        updateProviderStore { store in
            let i = try store.accountIndex(id)
            let account = store.accounts[i]
            guard let j = account.models.firstIndex(where: { $0.id == editingModelID }) ?? (editingModelID == nil ? account.models.indices.first : nil)
            else {
                guard account.models.isEmpty && editingModelID == nil else { throw ProviderStoreError.missingRecord }
                var updated = try HostProviderAccount.configured(name: name, endpoint: endpoint, protocolKind: protocolKind,
                    apiKey: key, presetID: presetID, allowsPlainHTTP: allowsPlainHTTP, catalog: configuredProviderCatalog)
                updated.initialRole = account.initialRole
                updated.profile = account.profileForEdit(updated.profile)
                store.accounts[i] = updated
                return
            }
            let previous = account.record(account.models[j])
            var record = try HostAgentProvider(displayName: name, endpoint: endpoint,
                                               protocolKind: protocolKind, modelID: modelID, apiKey: key,
                                               supportsImages: supportsImages, supportsTools: supportsTools,
                                               presetID: presetID, limits: limits ?? previous.model.limits,
                                               allowsPlainHTTP: allowsPlainHTTP, catalog: configuredProviderCatalog)
            record.profile = account.profileForEdit(record.profile)
            if previous.profile.baseURL == record.profile.baseURL && previous.profile.wireProtocol == protocolKind {
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
            if !explicit.isEmpty {
                record.model.explicitCapabilities = (record.model.explicitCapabilities ?? []).union(explicit)
            }
            record.applyCatalogModel(catalogModel)
            if let supportsApproval { record.setApprovalEligibility(supportsApproval) }
            if previous.model.supportsImageGenerationSurface || previous.model.supportsVideoGenerationSurface {
                record.model.capabilities = previous.model.capabilities
                record.model.useSurfaces = previous.model.useSurfaces
                record.model.isHiddenFromPrimaryPicker = previous.model.isHiddenFromPrimaryPicker
                record.model.explicitCapabilities = previous.model.explicitCapabilities
            }
            record.model.isEnabled = previous.model.isEnabled
            record.model.id = previous.model.id
            record.model.providerID = id
            if previous.model.displayName != previous.model.remoteModelID && previous.model.remoteModelID == record.model.remoteModelID {
                record.model.displayName = previous.model.displayName
            }
            store.accounts[i].profile = record.profile
            store.accounts[i].apiKey = record.apiKey
            store.accounts[i].presetID = record.presetID
            store.accounts[i].models[j] = record.model
        }
    }

    /// Editing shared connection fields from an empty role on a mixed account
    /// never selects an arbitrary sibling model to update.
    @discardableResult
    func updateProviderAccount(id: UUID, name: String?, endpoint: String, protocolKind: ModelProtocol,
                               key: String, presetID: String?, allowsPlainHTTP: Bool) -> Bool {
        updateProviderStore { store in
            let i = try store.accountIndex(id)
            let updated = try HostProviderAccount.configured(name: name, endpoint: endpoint,
                protocolKind: protocolKind, apiKey: key, presetID: presetID, allowsPlainHTTP: allowsPlainHTTP,
                catalog: configuredProviderCatalog)
            store.accounts[i].profile = store.accounts[i].profileForEdit(updated.profile)
            store.accounts[i].apiKey = updated.apiKey
            store.accounts[i].presetID = presetID
        }
    }

    @discardableResult
    func setAccountEnabled(id: UUID, enabled: Bool) -> Bool {
        updateProviderStore { store in
            let i = try store.accountIndex(id)
            store.accounts[i].profile.isEnabled = enabled
        }
    }

    @discardableResult
    func addProviderModel(providerID: UUID, model: ModelProfile) -> Bool {
        updateProviderStore { store in
            let i = try store.accountIndex(providerID)
            var added = model
            added.providerID = providerID
            store.accounts[i].models.append(added)
        }
    }

    /// Explicitly adopt an existing model created as text by an older editor.
    /// Keep its stable ID, enabled state and every other account model intact.
    @discardableResult
    func assignMediaRole(_ role: ProviderCatalogServiceRole, to modelID: UUID, providerID: UUID) -> Bool {
        guard role != .conversation else { return false }
        return updateProviderStore { store in
            let (i, j) = try store.indices(for: modelID)
            guard store.accounts[i].id == providerID else { throw ProviderStoreError.missingRecord }
            role.configureNewModel(&store.accounts[i].models[j])
        }
    }

    @discardableResult
    func removeProviderModel(modelID: UUID) -> Bool {
        updateProviderStore { store in
            let (i, j) = try store.indices(for: modelID)
            store.accounts[i].models.remove(at: j)
        }
    }

    @discardableResult
    func setProviderModelEnabled(modelID: UUID, enabled: Bool) -> Bool {
        updateProviderStore { store in
            let (i, j) = try store.indices(for: modelID)
            store.accounts[i].models[j].isEnabled = enabled
        }
    }

    #if FLOE_UNIFIED_MAC
    func synchronizeCloudModels(publishingModelID modelID: UUID? = nil) async throws -> [MacCloudModelEntry] {
        guard vault != nil, isReady, !isSending, !isTerminating, !isSynchronizingCloudModels,
              let release = admit() else { throw MacICloudModelError.temporarilyUnavailable }
        isSynchronizingCloudModels = true
        defer { isSynchronizingCloudModels = false; release() }
        let entry: MacCloudModelEntry?
        if let modelID {
            guard let record = providers.first(where: { $0.model.id == modelID }),
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
            if let i = store.accounts.firstIndex(where: { $0.id == base.id }) {
                let saved = store.accounts[i].profile
                guard saved.baseURL == base.baseURL, saved.wireProtocol == base.wireProtocol, saved.kind == base.kind else {
                    throw MacICloudModelError.invalidProvider
                }
                if let j = store.accounts[i].models.firstIndex(where: { $0.id == entry.model.id }) {
                    guard store.accounts[i].models[j].remoteModelID == entry.model.remoteModelID else { throw MacICloudModelError.invalidProvider }
                    store.accounts[i].models[j] = entry.model
                } else {
                    store.accounts[i].models.append(entry.model)
                }
            } else {
                store.accounts.append(HostProviderAccount(profile: base, apiKey: "", presetID: base.presetID, models: [entry.model]))
            }
        }
    }
    #endif

    /// Removes the record and its stored key. Chat history is kept; when the
    /// removed provider was selected, the first remaining one takes over.
    @discardableResult
    func removeProvider(id: UUID) -> Bool {
        updateProviderStore { store in
            let i = try store.accountIndex(id)
            store.accounts.remove(at: i)
        }
    }

    @discardableResult
    func selectDefaultModel(_ id: UUID) -> Bool {
        updateProviderStore { store in
            guard store.providers.contains(where: { $0.model.id == id && $0.canSelectAsPrimary }) else { throw ProviderStoreError.missingRecord }
            store.selectedModelID = id
        }
    }


    func select(_ id: UUID?) async {
        guard !Task.isCancelled, isReady, !isTerminating, !isAcceptingPlan, let runtime else { return }
        guard let release = admit() else { return }
        defer { release() }
        let selection = resetTaskSelection(to: id)
        guard let id else { return }
        if let handle = liveRuns[id]?.handle { await updateLiveRun(handle) }
        defer {
            if historySelection == selection { isLoadingHistory = false }
        }
        do {
            #if FLOE_UNIFIED_MAC
            try await refreshTranscript(for: id, runtime: runtime)
            try transcriptFence(for: id, selection: selection).guardCurrent()
            #else
            let page = try await runtime.conversationMessagePage(conversationID: id)
            guard historySelection == selection, !Task.isCancelled else { return }
            applyHistory(page)
            #endif
            let owner = try? await runtime.workspaceForConversation(id)
            guard historySelection == selection, !Task.isCancelled else { return }
            selectedConversationWorkspace = owner
            #if FLOE_UNIFIED_MAC
            let run = transcriptPager.runs.first
            guard historySelection == selection, !Task.isCancelled else { return }
            let reasoning = try await runtime.chatReasoning(conversationID: id)
            guard historySelection == selection, !Task.isCancelled else { return }
            let approvalMode = try await runtime.taskApprovalMode(conversationID: id)
            guard historySelection == selection, !Task.isCancelled else { return }
            selectedApprovalMode = approvalMode
            chatReasoning = reasoning
            applyComposerRun(run)
            if let run {
                await loadToolActivity(runID: run.id, conversationID: id, runtime: runtime)
                await loadHistoryContinuation(run, runtime: runtime)
            }
            #endif
            await loadPlanning(conversationID: id, runtime: runtime)
            #if FLOE_UNIFIED_MAC
            await refreshQueue(id)
            #endif
            await restoreQuestion(for: id)
        } catch {
            if historySelection == selection, !Task.isCancelled { historyLoadFailed = true }
        }
    }

    #if FLOE_UNIFIED_MAC
    func selectNewDraft(in projectID: UUID?, recovering draftID: UUID? = nil) -> Bool {
        guard isReady, !isTerminating, !isAcceptingPlan, let release = admit() else { return false }
        defer { release() }
        if let draftID {
            guard liveRuns[draftID] == nil, !conversations.contains(where: { $0.id == draftID }) else { return false }
            cachedDraftTaskID = draftID
            preferences.set(draftID.uuidString, forKey: Self.draftTaskIDKey)
        } else if let current = cachedDraftTaskID, liveRuns[current] != nil || selectedWorkspaceID != projectID {
            // A pending launch or a different project keeps its draft. The
            // newly opened composer uses a separate identity.
            clearDraftTaskID()
        }
        selectedWorkspaceID = projectID
        if selectedID != nil { clearStagedAttachments() }
        _ = resetTaskSelection(to: nil)
        return true
    }
    #endif

    private func resetTaskSelection(to id: UUID?) -> UUID {
        let selection = UUID()
        historySelection = selection
        #if FLOE_UNIFIED_MAC
        selectedApprovalMode = nil
        draftApprovalMode = nil
        chatReasoning = .fast
        #endif
        isLoadingHistory = id != nil
        isLoadingEarlierMessages = false
        historyLoadFailed = false
        #if FLOE_UNIFIED_MAC
        transcriptPager.reset()
        #else
        applyHistory(.init(messages: [], earlierCursor: nil, hasEarlier: false))
        #endif
        selectedID = id
        selectedConversationWorkspace = nil
        #if FLOE_UNIFIED_MAC
        applyComposerRun(nil)
        settledQuestions.removeAll()
        showsModelSettingsForFailure = false
        let liveIDs = Set(liveRuns.values.compactMap { $0.handle?.identity.runID })
        runToolActivity = runToolActivity.filter { liveIDs.contains($0.key) }
        #endif
        plan = nil
        goal = nil
        notice = nil
        restoreStagedAttachments(for: id)
        return selection
    }

    #if FLOE_UNIFIED_MAC
    private func transcriptFence(for id: UUID, selection: UUID) -> ThreadHistoryPager.Fence {
        .init { [weak self] in
            self?.selectedID == id && self?.historySelection == selection
                && self?.isTerminating == false && !Task.isCancelled
        }
    }

    private func refreshTranscript(for id: UUID, runtime: FloeMacSelfRuntime, runID: UUID? = nil,
                                   updatedMessageID: UUID? = nil) async throws {
        let fence = transcriptFence(for: id, selection: historySelection)
        try fence.guardCurrent()
        let stores = try await runtime.transcriptReadStores()
        try fence.guardCurrent()
        try await transcriptPager.loadLatestMessages(conversationID: id, store: stores.conversations, fence: fence)
        if let updatedMessageID {
            try await transcriptPager.refreshPresentedMessage(id: updatedMessageID, conversationID: id,
                                                               store: stores.conversations, fence: fence)
        }
        try await transcriptPager.loadRunHeaders(conversationID: id, store: stores.runs, fence: fence)
        try await hydrateTranscriptRuns(for: id, store: stores.runs, fence: fence)
        if let runID = runID ?? transcriptPager.runs.first?.id {
            try await transcriptPager.loadLatestEvents(runID: runID, store: stores.runs, fence: fence)
        }
    }

    private func hydrateTranscriptRuns(for id: UUID, store: any RunStore, fence: ThreadHistoryPager.Fence) async throws {
        let ids = Set(messages.compactMap(\.runID))
        try await transcriptPager.ensureRunHeaders(ids, conversationID: id, store: store, fence: fence)
        let known = Set(transcriptPager.runs.map(\.id))
        transcriptPager.markRunsNeedingEventHydration(ids.intersection(known))
    }

    func loadEarlierMessages() async {
        guard let id = selectedID, hasEarlierMessages, !isLoadingHistory, !isLoadingEarlierMessages,
              !isTerminating, let runtime, let release = admit() else { return }
        let selection = historySelection
        let fence = transcriptFence(for: id, selection: selection)
        isLoadingEarlierMessages = true
        defer {
            if historySelection == selection { isLoadingEarlierMessages = false }
            release()
        }
        do {
            let stores = try await runtime.transcriptReadStores()
            try fence.guardCurrent()
            try await transcriptPager.loadEarlierMessages(conversationID: id, store: stores.conversations, fence: fence)
            try await hydrateTranscriptRuns(for: id, store: stores.runs, fence: fence)
        } catch {
            if fence.isCurrent() { notice = String(localized: "host.chat.historyUnavailable") }
        }
    }

    func loadEarlierEvents(runID: UUID) async {
        guard let id = selectedID, earlierEventRunIDs.contains(runID), !loadingEventRunIDs.contains(runID),
              !isTerminating, let runtime, let release = admit() else { return }
        defer { release() }
        let fence = transcriptFence(for: id, selection: historySelection)
        do {
            let stores = try await runtime.transcriptReadStores()
            try fence.guardCurrent()
            try await transcriptPager.loadEarlierEvents(runID: runID, store: stores.runs, fence: fence)
        } catch {
            if fence.isCurrent(), failedEarlierEventRunIDs.contains(runID) {
                notice = String(localized: "host.chat.historyUnavailable")
            }
        }
    }

    private func refreshTranscriptEvents(runID: UUID, conversationID: UUID, runtime: FloeMacSelfRuntime) async {
        guard selectedID == conversationID, !isLoadingHistory, !isTerminating else { return }
        let fence = transcriptFence(for: conversationID, selection: historySelection)
        do {
            let stores = try await runtime.transcriptReadStores()
            try fence.guardCurrent()
            try await transcriptPager.loadLatestEvents(runID: runID, store: stores.runs, fence: fence)
        } catch {
            // Refresh the durable tail again at the end of the run.
        }
    }

    func searchTranscript(_ query: ConversationSearchQuery, in conversationID: UUID) async -> ThreadSearchResult {
        let empty = ThreadSearchResult(hits: [], includesDurableHistory: false)
        guard !query.isEmpty, selectedID == conversationID, !isTerminating, let runtime, let release = admit() else { return empty }
        defer { release() }
        let fence = transcriptFence(for: conversationID, selection: historySelection)
        let local = ThreadSearchText.hits(in: messages.compactMap(ThreadSearchText.document(for:)), query: query)
        let durable = try? await runtime.conversationMessageMatches(conversationID: conversationID, rawQuery: query.raw)
        guard fence.isCurrent() else { return empty }
        var byID = Dictionary(uniqueKeysWithValues: local.map { ($0.messageID, $0) })
        for match in durable ?? [] where byID[match.messageID] == nil {
            byID[match.messageID] = ThreadSearchHit(messageID: match.messageID, role: match.role,
                createdAt: match.createdAt, snippet: match.snippet)
        }
        let hits = byID.values.sorted { ($0.createdAt, $0.messageID.uuidString) < ($1.createdAt, $1.messageID.uuidString) }
        return ThreadSearchResult(hits: hits, includesDurableHistory: durable != nil)
    }

    func revealMessage(_ messageID: UUID, in conversationID: UUID) async -> Bool {
        guard selectedID == conversationID, !isLoadingHistory, !isTerminating,
              let runtime, let release = admit() else { return false }
        defer { release() }
        let fence = transcriptFence(for: conversationID, selection: historySelection)
        do {
            if !messages.contains(where: { $0.id == messageID }) {
                let window = try await runtime.conversationMessageWindow(conversationID: conversationID, around: messageID)
                try fence.guardCurrent()
                guard window.contains(where: { $0.id == messageID }) else { return false }
                transcriptPager.mergeSearchWindow(window)
            }
            guard let target = messages.first(where: { $0.id == messageID }),
                  ThreadSearchText.document(for: target) != nil else { return false }
            if let runID = target.runID {
                let stores = try await runtime.transcriptReadStores()
                try fence.guardCurrent()
                try await hydrateTranscriptRuns(for: conversationID, store: stores.runs, fence: fence)
                if target.role == "assistant", transcriptPager.eventsByRun[runID] == nil {
                    try await transcriptPager.loadLatestEvents(runID: runID, store: stores.runs, fence: fence)
                }
            }
            return fence.isCurrent()
        } catch { return false }
    }
    #else
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
    #endif

    func transcript(conversationID: UUID) async throws -> [PersistedMessage] {
        guard let runtime, isReady, !isSending, !isTerminating,
              conversations.contains(where: { $0.id == conversationID && $0.isVisibleInOrdinaryList }),
              let release = admit() else { throw CancellationError() }
        defer { release() }
        return try await runtime.conversationTranscript(conversationID: conversationID)
    }

    func exportStructuredConversation(conversationID: UUID, to url: URL) async throws {
        guard let runtime, isReady, !isTerminating,
              conversations.contains(where: { $0.id == conversationID && $0.isVisibleInOrdinaryList }),
              let release = admit() else { throw CancellationError() }
        defer { release() }
        try await runtime.exportStructuredConversation(conversationID: conversationID, to: url)
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

    #if !FLOE_UNIFIED_MAC
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
    #endif

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

    func renameProject(_ id: UUID, name: String) async -> Bool {
        guard let runtime, isReady, !isTerminating, let release = admit() else { return false }
        defer { release() }
        do {
            guard let record = try await runtime.renameProject(id: id, name: name) else { return false }
            if let index = workspaces.firstIndex(where: { $0.id == id }) {
                workspaces[index] = record
                workspaces.sort { ($0.name.lowercased(), $0.id.uuidString) < ($1.name.lowercased(), $1.id.uuidString) }
            }
            if selectedConversationWorkspace?.id == id { selectedConversationWorkspace = record }
            return true
        } catch {
            return false
        }
    }

    /// Stages picked files for the next send. Only regular files that open
    /// for reading, produce a read-only security-scoped bookmark, and pass
    /// the bounded size/type rules are staged; duplicates of an already
    /// staged path are ignored. The bounded read fetches at most the ceiling
    /// plus one byte so an oversized file is rejected without being fully
    /// loaded. The returned array lists exactly what was staged.
    ///
    /// Staging stays available while the visible task runs: the in-flight
    /// run captured its attachment set at admission, so anything staged now
    /// belongs to the next queued or steered message and is consumed only
    /// when the user submits that message (see `enqueue`/`steer`).
    @discardableResult
    func stageAttachments(_ urls: [URL], importedImageID: UUID? = nil) -> [HostAgentAttachmentDraft] {
        guard isReady, !isTerminating else { return [] }
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
                id: urls.count == 1 ? (importedImageID ?? UUID()) : UUID(),
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
        saveAttachmentDraft?(attachmentDraftKey(for: selectedID), stagedAttachments.map(\.reference))
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
        guard let index = stagedAttachments.firstIndex(where: { $0.id == id }) else { return }
        let removed = stagedAttachments.remove(at: index)
        saveAttachmentDraft?(attachmentDraftKey(for: selectedID), stagedAttachments.map(\.reference))
        #if FLOE_UNIFIED_MAC
        HostAgentDatabase.discardComposerImage(removed.url, id: removed.id, owner: attachmentOwnerID,
                                              runtimeDirectory: personalTaskLeaseBase)
        #endif
    }

    func clearStagedAttachments() {
        stagedAttachments.removeAll()
    }

    private func restoreStagedAttachments(for conversationID: UUID?) {
        guard let references = loadAttachmentDraft?(attachmentDraftKey(for: conversationID)) else { return }
        stagedAttachments = references.prefix(Self.maximumStagedAttachmentCount).compactMap { draftAttachment($0, id: $0.id) }
        if stagedAttachments.count != references.count {
            notice = String(localized: "mac.workspace.attachmentUnavailable")
        }
    }

    private func attachmentDraftKey(for conversationID: UUID?) -> UUID? {
        #if FLOE_UNIFIED_MAC
        conversationID ?? draftTaskID
        #else
        conversationID
        #endif
    }

    private func draftAttachment(_ reference: AttachmentRef, id: UUID) -> HostAgentAttachmentDraft? {
        guard reference.storage == .securityScopedBookmark, let bookmark = reference.urlBookmark,
              reference.kind == .image || reference.kind == .document,
              reference.byteCount > 0, reference.byteCount <= Self.maximumAttachmentBytes else { return nil }
        var stale = false
        guard let url = try? URL(resolvingBookmarkData: bookmark, options: [.withoutUI],
                                 relativeTo: nil, bookmarkDataIsStale: &stale), !stale else { return nil }
        return .init(id: id, kind: reference.kind == .image ? .image : .document,
                     url: url, bookmark: bookmark, displayName: reference.displayName,
                     byteCount: reference.byteCount, sha256: reference.sha256, uti: reference.uti,
                     createdAt: reference.createdAt)
    }

    #if FLOE_UNIFIED_MAC
    func editFailedInput(_ message: PersistedMessage, applyText: (String) -> Bool) async {
        guard let id = selectedID, id == message.conversationID, failedUserMessage?.id == message.id,
              !isSending, stagedAttachments.isEmpty, !isTerminating, let runtime, let release = admit(),
              let text = CredentialMessagePart.clipboardText(message.content) else { return }
        defer { release() }
        let selection = historySelection
        do {
            var restored: [HostAgentAttachmentDraft] = []
            for part in message.parts where part.kind == .image || part.kind == .file {
                guard let key = part.attachmentID, let ref = try await runtime.conversationAttachment(id: key, conversationID: id),
                      let draft = draftAttachment(ref, id: UUID()) else { throw CocoaError(.fileNoSuchFile) }
                restored.append(draft)
            }
            guard historySelection == selection, selectedID == id, !isSending, !isTerminating,
                  failedUserMessage?.id == message.id, stagedAttachments.isEmpty, applyText(text) else { return }
            stagedAttachments = restored
            saveAttachmentDraft?(id, restored.map(\.reference))
        } catch {
            if selectedID == id { notice = String(localized: "mac.workspace.attachmentUnavailable") }
        }
    }
    #endif

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
            if case .delete = change {
                saveTaskMode(nil, for: id)
                HostAgentDatabase.removeComposerImages(for: id, runtimeDirectory: personalTaskLeaseBase)
            }
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

    // MARK: - Personal file workspace

    /// The file workspace of the current task, for file panes and Space
    /// browsing only: the explicit project when the selected conversation
    /// (or the draft's project picker) is bound to one, otherwise the
    /// per-task personal workspace — the durable owner row for a saved
    /// conversation, or a synthetic private record for the unsaved draft.
    /// Personal records carry an empty bookmark by design, so the returned
    /// presentation record populates a bookmark bound to the verified
    /// per-task root exactly like a project row. For the current task only,
    /// the root may be materialized lazily (0o700, owner-pinned) so a fresh
    /// draft's Files work before the first send; no folder is ever created
    /// for tasks other than the current one, and the stable UUID keeps the
    /// root constant across repeated reads.
    var fileWorkspaceForCurrentTask: WorkspaceRecord? {
        if let selectedID {
            guard let owner = selectedConversationWorkspace else { return nil }
            return presentationRecord(for: owner)
        }
        // Draft: an explicitly picked project wins; otherwise the synthetic
        // per-task scope keyed by the persisted draft UUID.
        if let projectID = selectedWorkspaceID,
           let project = workspaces.first(where: { $0.id == projectID && $0.kind == .project }) {
            return project
        }
        return presentationRecord(for: personalWorkspaceRecord(id: draftTaskID, title: ""))
    }

    func saveGeneratedMedia(_ source: URL, owner: UUID, workspaceID: UUID) async -> Bool {
        guard isReady, !isTerminating, !changingTasks.contains(owner), !hasPendingWorkspaceFileChanges,
              owner == attachmentOwnerID, let record = fileWorkspaceForCurrentTask, record.id == workspaceID,
              let type = UTType(filenameExtension: source.pathExtension),
              type.conforms(to: .image) || type.conforms(to: .movie), let release = admit() else { return false }
        changingTasks.insert(owner)
        defer { changingTasks.remove(owner); release() }
        let bookmark = record.rootBookmark
        let publication = Task.detached(priority: .userInitiated) {
            var stale = false
            let root = try URL(resolvingBookmarkData: bookmark, options: [.withoutUI],
                               relativeTo: nil, bookmarkDataIsStale: &stale)
            guard !stale else { throw CocoaError(.fileWriteNoPermission) }
            let accessing = root.startAccessingSecurityScopedResource()
            defer { if accessing { root.stopAccessingSecurityScopedResource() } }
            return try MacWorkspaceFileImport.save(source, in: root)
        }
        let saved = await withTaskCancellationHandler {
            try? await publication.value
        } onCancel: {
            publication.cancel()
        }
        guard saved != nil else { return false }
        workspaceRevision = UUID()
        return true
    }

    /// App-owned directory that aggregates every personal task folder
    /// (`<runtime directory>/PrivateTasks`). Space browsing only; pure
    /// location lookup, no I/O and no directory creation.
    var defaultConversationsDirectory: URL? {
        HostAgentDatabase.privateTasksDirectoryURL(applicationSupport: supportDirectory, namespace: namespace)
    }

    /// Owner-only runtime directory: the lease base every personal task
    /// root resolves under (`<base>/PrivateTasks/<task UUID>`).
    var personalTaskLeaseBase: URL {
        HostAgentDatabase.runtimeDirectoryURL(applicationSupport: supportDirectory, namespace: namespace)
    }

    var runOutputArtifactRoot: URL {
        HostAgentDatabase.runOutputArtifactRoot(in: personalTaskLeaseBase)
    }

    /// Durable-shaped private workspace record for one stable task UUID.
    private func personalWorkspaceRecord(id: UUID, title: String) -> WorkspaceRecord {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return WorkspaceRecord(
            id: id,
            name: trimmed.isEmpty ? "Chat" : String(trimmed.prefix(80)),
            rootBookmark: Data(),
            kind: .privateTask,
            internalRelativePath: "PrivateTasks/\(id.uuidString)"
        )
    }

    /// UI presentation form of a workspace record: personal rows resolve
    /// their root through the same verified pinned resolver as the tool
    /// binding (which may lazily materialize the current task's leaf with
    /// 0o700 ownership checks) and gain a bookmark bound to that exact leaf —
    /// personal rows persist an empty bookmark by design. Project rows are
    /// returned unchanged. Nil when the root cannot be verified; never binds
    /// a shared parent instead.
    private func presentationRecord(for record: WorkspaceRecord) -> WorkspaceRecord? {
        guard record.kind == .privateTask else { return record }
        guard let relative = record.internalRelativePath,
              MacAgentWorkspaceTools.personalTaskID(relativePath: relative) != nil else { return nil }
        let root: URL
        do {
            root = try MacAgentWorkspaceTools.verifiedPersonalTaskRoot(
                relativePath: relative, leaseBase: personalTaskLeaseBase, createIfNeeded: true
            )
        } catch {
            return nil
        }
        guard let bookmark = try? root.bookmarkData() else { return nil }
        var presented = record
        presented.rootBookmark = bookmark
        return presented
    }
    #endif

    #if FLOE_UNIFIED_MAC
    func usageStatistics() async throws -> UsageStatistics {
        guard isReady, let runtime, let release = admit() else {
            throw FloeMacSelfCoreError.hostGateUnavailable("usage")
        }
        defer { release() }
        return try await runtime.usageStatistics()
    }

    func keepTemporaryConversation(_ snapshot: ConversationPromoter.Snapshot,
                                   configuration: [ConversationPromoter.ModelConfiguration],
                                   checkCancellation: @escaping @Sendable () throws -> Void) async throws {
        guard isReady, !isTerminating, let runtime, let release = admit() else {
            throw FloeMacSelfCoreError.hostGateUnavailable("temporary.keep")
        }
        defer { release() }
        try await runtime.keepTemporaryConversation(snapshot, configuration: configuration, checkCancellation: checkCancellation)
        // The Keep transaction already committed. A list refresh can retry on the next load.
        try? await reloadConversations(using: runtime)
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

    // MARK: - Task Center cross-conversation content search

    /// Durable message-text search across the user's ordinary conversations,
    /// reusing the shared `SQLiteIntelligenceStore.conversationSearchMatches`
    /// contract (visible-text matcher, projected snippets). `archived: false`
    /// addresses the current visible list; `archived: true` addresses the
    /// archived scope. Local SQLite only; results are bounded by the store.
    func taskContentMatches(_ query: String, archived: Bool, projectID: UUID? = nil) async throws -> [ConversationSearchMatch] {
        guard let runtime, isReady, !isTerminating, let release = admit() else { throw CancellationError() }
        defer { release() }
        return try await runtime.taskContentMatches(query, archived: archived, projectID: projectID)
    }

    /// Debounced, latest-query-wins search scheduling. A newer query cancels
    /// the pending lookup and invalidates any in-flight publish, so a stale
    /// or cancelled search never touches the published matches (and the UI
    /// selection is never yanked by an old query). An empty query clears
    /// results immediately without a store round trip.
    func scheduleTaskContentSearch(query: String, archived: Bool, projectID: UUID? = nil) {
        taskContentSearchTask?.cancel()
        taskContentLookup = UUID()
        let lookup = taskContentLookup
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        taskContentMatchesByID = [:]
        taskContentSearchFailed = false
        guard !trimmed.isEmpty, !isTerminating else { return }
        taskContentSearchTask = Task { [weak self] in
            guard let self else { return }
            try? await Task.sleep(for: Self.taskContentSearchDebounce)
            guard !Task.isCancelled, lookup == self.taskContentLookup, self.isReady else { return }
            do {
                let results = try await self.taskContentMatches(trimmed, archived: archived, projectID: projectID)
                guard !Task.isCancelled, lookup == self.taskContentLookup else { return }
                var byID: [UUID: ConversationSearchMatch] = [:]
                for match in results where byID[match.conversationID] == nil {
                    byID[match.conversationID] = match
                }
                self.taskContentMatchesByID = byID
                self.taskContentSearchFailed = false
            } catch {
                guard !Task.isCancelled, lookup == self.taskContentLookup else { return }
                self.taskContentMatchesByID = [:]
                self.taskContentSearchFailed = true
            }
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
            #if FLOE_UNIFIED_MAC
            let acceptsImages = config.model.capabilities.contains(.vision) || selectedAuxiliary(.vision) != nil
            #else
            let acceptsImages = config.model.capabilities.contains(.vision)
            #endif
            guard acceptsImages || !stagedAttachments.contains(where: { $0.kind == .image }) else {
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

    /// `queuedAttachments` carries the durable refs of a queued row being
    /// launched: they reach the session request directly, so draining the
    /// queue for one task never touches (or leaks through) the visible
    /// task's staged composer strip.
    private func beginSend(_ text: String, runtime: FloeMacSelfRuntime,
                            provider: FloeMacSelfProviderBinding,
                            workspaceID: UUID? = nil, mode: HostAgentMode = .chat, criterion: String = "",
                            acceptedPlan: PlanConfirmationSnapshot? = nil, resumingGoal: Bool = false,
                            continuingFromHistory: Bool = false, checkpointRunID: UUID? = nil,
                            queued: PendingUserInput? = nil, queuedGoal: ConversationGoal? = nil,
                            automaticGoal: (predecessor: UUID, goal: ConversationGoal)? = nil,
                            queuedAttachments: [HostAgentAttachmentDraft] = [],
                            onAdmitted: (() -> Void)? = nil) -> Bool {
        #if FLOE_UNIFIED_MAC
        let auxRoutes = auxiliaryRoutes(for: provider)
        let titleHelper = auxiliaryText(for: provider)
        #else
        let auxRoutes = FloeMacSelfAuxiliaryRoutes()
        #endif
        let currentID = automaticGoal?.goal.conversationID ?? queued?.conversationID ?? selectedID
        #if FLOE_UNIFIED_MAC
        // A draft keeps its persisted stable task UUID, so its personal
        // safe-files root is the same one the file panes showed before the
        // first send; a saved task (or queued input) always uses its own id.
        let taskID = currentID ?? draftTaskID
        #else
        let taskID = currentID ?? UUID()
        #endif
        let originSelection = historySelection
        guard (queued != nil || automaticGoal != nil ? liveRuns[taskID] == nil : !isSending),
              !isTerminating, !changingTasks.contains(taskID) else { return false }
        let attachmentDraftID = attachmentDraftKey(for: currentID)
        let currentGoal = automaticGoal?.goal ?? queuedGoal ?? (mode == .goal && criterion.isEmpty && goal?.conversationID == currentID
            && goal?.status.isTerminal == false ? goal : nil)
        var criteria: [String] = []
        if mode == .goal, currentGoal == nil, acceptedPlan == nil, !resumingGoal {
            criteria = criterion.components(separatedBy: .newlines)
                .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            if criteria.isEmpty { criteria = [String(localized: "mac.agent.defaultGoalCriterion")] }
        }
        let goalCriteria = criteria
        let selectedProject = workspaces.first { $0.id == workspaceID && $0.kind == .project }
        #if FLOE_UNIFIED_MAC
        let newTaskApproval = draftApprovalMode ?? defaultApprovalMode
        guard !savingApprovalMode, !savingChatReasoning else { return false }
        let draftReasoning: ChatReasoningPreference? = currentID == nil && mode == .chat ? chatReasoning : nil
        let acceptsQuestions = true
        #else
        let draftReasoning: ChatReasoningPreference? = nil
        let acceptsQuestions = false
        #endif
        // Agent and Plan mode no longer require an explicit project: an
        // ordinary personal conversation gets its own durable safe-files
        // root instead (below), so nothing here blocks the send.
        guard let release = admit() else { return false }
        #if !FLOE_UNIFIED_MAC
        if currentID == nil { newDraftRunID = taskID }
        #endif
        let pendingPrompt = acceptedPlan == nil && checkpointRunID == nil ? text : nil
        liveRuns[taskID] = LiveRun(prompt: pendingPrompt, mode: mode, modelID: provider.model.id)
        // A live run for this task becomes the sole authority for its question
        // card, even before its handle lands; any durable restored card for an
        // earlier run steps aside.
        restoredQuestions.removeValue(forKey: taskID)
        if selectedID == currentID {
            notice = nil
            rejectedPrompt = nil
            #if FLOE_UNIFIED_MAC
            showsModelSettingsForFailure = false
            #endif
        }
        let drafts = continuingFromHistory || resumingGoal || acceptedPlan != nil || automaticGoal != nil ? []
            : (queued != nil ? queuedAttachments : stagedAttachments)
        // Bind delegation to the same durable run as plan execution, queued
        // input, or a manually started round.
        let delegationRunID: UUID? = mode == .agent || mode == .goal
            ? (checkpointRunID ?? acceptedPlan?.executionRunID ?? queued?.id ?? UUID()) : nil
        #if FLOE_UNIFIED_MAC
        let readOnly = mode == .plan || !allowsWorkspaceWrites
        let finalReview = mode != .chat && mode != .plan && verifyAgentAnswers
        #else
        let finalReview = false
        #endif
        Task {
            var admitted = false
            var finishedNormally = false
            #if FLOE_UNIFIED_MAC
            var nextGoalRound: (predecessor: UUID, goal: ConversationGoal)?
            #endif
            defer {
                #if !FLOE_UNIFIED_MAC
                if newDraftRunID == taskID { newDraftRunID = nil }
                #endif
                liveSnapshotVersions.removeValue(forKey: taskID)
                liveRuns.removeValue(forKey: taskID)
                #if FLOE_UNIFIED_MAC
                if (finishedNormally && queuedInputs[taskID]?.isEmpty == false) || (queued != nil && !admitted) {
                    Task {
                        if let queued, !admitted, let store = try? await runtime.runningInputStore() {
                            try? await store.restoreQueued(id: queued.id)
                        }
                        if finishedNormally { await startNextQueued(taskID) }
                        else { await refreshQueue(taskID) }
                    }
                }
                #endif
                if let delegationRunID {
                    Task {
                        await self.childSubagents.release(runID: delegationRunID)
                        release()
                        #if FLOE_UNIFIED_MAC
                        if let nextGoalRound { self.startAutomaticGoalRound(nextGoalRound, provider: provider, runtime: runtime) }
                        #endif
                    }
                } else {
                    release()
                }
            }
            do {
                let tools: FloeMacSelfToolBinding?
                #if FLOE_UNIFIED_MAC
                let approvalMode: TaskApprovalMode
                if let currentID { approvalMode = try await runtime.taskApprovalMode(conversationID: currentID) }
                else { approvalMode = newTaskApproval }
                let project: WorkspaceRecord?
                let durablePersonal: WorkspaceRecord?
                if let currentID {
                    let owner = try await runtime.workspaceForConversation(currentID)
                    if let queued, owner?.id != queued.workspaceID { throw CocoaError(.userCancelled) }
                    if let owner, owner.kind == .project {
                        project = owner
                        durablePersonal = nil
                    } else {
                        // Ordinary personal conversation: its durable owner
                        // is the per-task private workspace (nil only for a
                        // legacy ownerless row, which stays tool-free rather
                        // than ever binding a shared parent).
                        project = nil
                        durablePersonal = owner
                    }
                } else {
                    project = selectedProject
                    durablePersonal = nil
                }
                // The workspace that tools bind to: the explicit project when
                // there is one, otherwise the per-task personal workspace.
                // Agent/Plan always need it; Goal uses it when present; chat
                // binds it only when the model actually offers tools.
                let toolWorkspace: WorkspaceRecord?
                if project != nil {
                    toolWorkspace = project
                } else if mode != .chat || provider.model.capabilities.contains(.tools) {
                    if let currentID {
                        toolWorkspace = durablePersonal
                    } else {
                        // First launch of a personal draft: materialize the
                        // durable per-task row (keyed by the draft's stable
                        // UUID) so the binding and the launch transaction
                        // agree on the exact owner.
                        toolWorkspace = try await runtime.ensurePersonalWorkspace(
                            conversationID: taskID,
                            title: Self.initialTaskTitle(text, provider: provider)
                        )
                    }
                } else {
                    toolWorkspace = nil
                }
                let delegationRegistry = delegationRunID == nil ? nil : childSubagents.childRegistry
                if let toolWorkspace, mode != .chat || provider.model.capabilities.contains(.tools) {
                    let grants = try await runtime.approvalGrantStore()
                    let conversations = mode == .chat ? nil : try await runtime.conversationToolCapability()
                    let mediaEnabled = !readOnly && (mode == .agent || mode == .goal)
                    let images = mediaEnabled ? taskImages?.taskTools(conversationID: taskID, autonomous: auxiliaryPreferences.autonomousImageRouting == true) : nil
                    var videoTools: [AnyAgentTool] = []
                    if mediaEnabled, let taskVideos {
                        videoTools = MacTaskVideoTools.make(service: taskVideos, conversationID: taskID,
                                                          workspace: toolWorkspace, privateTaskRootBase: personalTaskLeaseBase) { owner, attachment in
                            guard owner == taskID else { return nil }
                            return try await runtime.conversationAttachment(id: attachment, conversationID: taskID)
                        }
                    }
                    tools = try MacAgentWorkspaceTools.binding(workspace: toolWorkspace,
                        privateTaskRootBase: personalTaskLeaseBase, runOutputArtifactRoot: runOutputArtifactRoot, readOnly: readOnly,
                        chatOnly: mode == .chat, delegationRegistry: delegationRegistry,
                        search: webSearch.access, conversations: conversations, imageTools: images, videoTools: videoTools,
                        browserTools: { root in self.makeTaskBrowserTools?(taskID, root) ?? [] }) { root, identities in
                        let context = MacProjectApprovalContext(grants: grants, workspaceID: toolWorkspace.id,
                            conversationID: taskID, root: root, identities: identities,
                            primaryIsOnDevice: provider.provider.id == ProviderProfile.onDeviceProviderID, networkStatus: self.networkStatus)
                        self.liveRuns[taskID]?.approvalContext = context
                        self.liveRuns[taskID]?.approvalMode = approvalMode
                        return context.policy(approvalMode, reviewer: self.reviewer)
                    }
                } else {
                    tools = nil
                }
                if let delegationRunID, let tools {
                    // Bind the child runner before the session can dispatch so
                    // the first provider turn already sees its delegation
                    // handlers; released in the defer below. The child
                    // inherits the run's effective tool universe; per-call
                    // authority comes from the session runtime's canonical
                    // dispatcher (no Mac-side read-only allowlist).
                    try await childSubagents.bind(
                        runID: delegationRunID,
                        conversationID: taskID,
                        provider: provider,
                        projectExecutor: FloeMacPeerAwareToolExecutor(wrapping: tools.executor),
                        runtime: runtime
                    )
                }
                #else
                let approvalMode: TaskApprovalMode = .ask
                let toolWorkspace = selectedProject
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
                    workspaceID: tools == nil ? workspaceID : toolWorkspace?.id,
                    conversationTitle: currentID == nil ? Self.initialTaskTitle(text, provider: provider) : "",
                    goal: acceptedExecution?.goal ?? text,
                    mode: acceptedExecution?.conversationMode ?? mode.runtimeMode,
                    initialPolicy: .init(approvalMode: approvalMode),
                    runID: checkpointRunID ?? acceptedExecution?.runID ?? queued?.id ?? delegationRunID,
                    context: FloeMacSelfRunContext(workspaceName: toolWorkspace?.name),
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
                    chatReasoningPreference: draftReasoning,
                    allowsUserQuestions: acceptsQuestions,
                    verifyFinalAnswer: finalReview,
                    goalCriteria: goalCriteria,
                    reusingUserMessageID: acceptedExecution?.userMessageID,
                    expectedGoal: expectedGoal,
                    automaticGoalPredecessor: automaticGoal?.predecessor
                )
                guard liveRuns[taskID]?.stopping == false else { return }
                let handle: FloeMacSelfSessionHandle
                if resumingGoal {
                    handle = try await runtime.resumeGoalSession(request, provider: provider, tools: tools,
                                                                 auxiliary: auxRoutes, restoringCheckpoint: checkpointRunID != nil)
                } else if checkpointRunID != nil {
                    handle = try await runtime.resumeCheckpointSession(request, provider: provider, tools: tools, auxiliary: auxRoutes)
                } else {
                    handle = try await runtime.startSession(request, provider: provider, tools: tools, auxiliary: auxRoutes)
                }
                admitted = true
                let events = handle.events()
                var hasOriginSelection: Bool { selectedID == currentID && historySelection == originSelection }
                #if FLOE_UNIFIED_MAC
                if let queued, let store = try? await runtime.runningInputStore() {
                    do { try await store.markConsumed(id: queued.id, runID: handle.identity.runID) }
                    catch { if selectedID == taskID { notice = String(localized: "mac.agent.queueUnavailable") } }
                    await refreshQueue(taskID)
                }
                if !continuingFromHistory { saveTaskMode(mode, for: taskID) }
                if currentID == nil, hasOriginSelection { draftMode = nil; draftApprovalMode = nil }
                #endif
                if !drafts.isEmpty,
                   loadAttachmentDraft.map({ $0(attachmentDraftID).map(\.id) == drafts.map(\.id) }) ?? true {
                    saveAttachmentDraft?(attachmentDraftID, [])
                    if hasOriginSelection, stagedAttachments == drafts { stagedAttachments = [] }
                }
                onAdmitted?()
                liveRuns[taskID]?.handle = handle
                if acceptsQuestions { await refreshQuestionCard(for: taskID) }
                if liveRuns[taskID]?.stopping == true { cancelRun(handle, taskID: taskID) }
                let admittedOwner: WorkspaceRecord?
                if currentID == nil, hasOriginSelection, toolWorkspace == nil {
                    admittedOwner = try? await runtime.workspaceForConversation(handle.identity.conversationID)
                } else {
                    admittedOwner = toolWorkspace
                }
                if hasOriginSelection && currentID == nil {
                    selectedConversationWorkspace = admittedOwner
                    selectedID = handle.identity.conversationID
                    #if FLOE_UNIFIED_MAC
                    admittedDraftID = handle.identity.conversationID
                    #endif
                }
                #if FLOE_UNIFIED_MAC
                if currentID == nil, cachedDraftTaskID == taskID { clearDraftTaskID() }
                #else
                if newDraftRunID == taskID { newDraftRunID = nil }
                #endif
                #if FLOE_UNIFIED_MAC
                if selectedID == taskID {
                    selectedApprovalMode = approvalMode
                    taskModelID = provider.model.id
                    failedRunID = nil
                    historyContinuation = nil
                }
                #endif
                let initialPhase = await handle.phase()
                liveRuns[taskID]?.phase = initialPhase
                try? await reloadConversations(using: runtime)
                #if FLOE_UNIFIED_MAC
                if selectedID == taskID {
                    try? await refreshTranscript(for: taskID, runtime: runtime, runID: handle.identity.runID,
                                                 updatedMessageID: acceptedExecution?.userMessageID)
                    if mode == .goal { await loadPlanning(conversationID: taskID, runtime: runtime) }
                }
                #endif
                await updateLiveRun(handle)
                var lastPaint = ContinuousClock.now
                for await event in events {
                    switch event {
                    case .harness(.answerDelta), .harness(.reasoningDelta):
                        guard visibleTaskID == taskID,
                              lastPaint.duration(to: .now) >= .milliseconds(33) else { continue }
                        lastPaint = .now
                        await updateLiveRun(handle)
                        continue
                    default: break
                    }
                    await updateLiveRun(handle)
                    let phase = await handle.phase()
                    if liveRuns[taskID]?.phase != phase { liveRuns[taskID]?.phase = phase }
                    switch event {
                    case .harness(.planChanged), .harness(.goalChanged):
                        await loadPlanning(conversationID: handle.identity.conversationID, runtime: runtime)
                    #if FLOE_UNIFIED_MAC
                    case .harness(.approvalReviewChanged(let review)):
                        let key = review.callID ?? review.toolName
                        if review.isEvaluating { liveRuns[taskID]?.reviewingCalls.insert(key) }
                        else { liveRuns[taskID]?.reviewingCalls.remove(key) }
                    case .harness(.toolLifecycle(let event)):
                        updateToolActivity(event, runID: handle.identity.runID)
                        await refreshTranscriptEvents(runID: handle.identity.runID, conversationID: taskID, runtime: runtime)
                    case .harness(.approvalRequested), .harness(.approvalResolved):
                        await refreshTranscriptEvents(runID: handle.identity.runID, conversationID: taskID, runtime: runtime)
                    case .harness(.userInputConsumed):
                        if selectedID == taskID {
                            try? await refreshTranscript(for: taskID, runtime: runtime, runID: handle.identity.runID)
                        }
                    #endif
                    default:
                        break
                    }
                }
                let terminal = await handle.waitForTerminal()
                finishedNormally = terminal?.confirmed == true && terminal?.outcome == .completed && liveRuns[taskID]?.stopping != true
                #if FLOE_UNIFIED_MAC
                endTaskBrowserRun?(handle.identity.runID)
                if finishedNormally, currentID == nil, let titleHelper, providers.contains(where: { $0.model.id == provider.model.id }) {
                    scheduleTaskTitle(taskID, prompt: text, helper: titleHelper, primary: provider, runtime: runtime)
                }
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
                #if FLOE_UNIFIED_MAC
                await refreshQueue(taskID)
                #endif
                if selectedID == taskID {
                    #if FLOE_UNIFIED_MAC
                    try? await refreshTranscript(for: taskID, runtime: runtime, runID: handle.identity.runID)
                    #else
                    let selection = historySelection
                    if let page = try? await runtime.conversationMessagePage(conversationID: taskID),
                       selectedID == taskID, selection == historySelection {
                        applyHistory(page, retainingVisibleHistory: true)
                    }
                    #endif
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
                    if terminal?.unconfirmedReason == "resumeNotDispatched" {
                        _ = try? await handle.close(allowUnconfirmed: true)
                        #if FLOE_UNIFIED_MAC
                        if selectedID == taskID, let run = try? await runtime.runRecord(runID: handle.identity.runID) {
                            await loadHistoryContinuation(run, runtime: runtime)
                        }
                        #endif
                        return
                    }
                    if selectedID == taskID { notice = String(localized: "host.chat.unconfirmed") }
                    return
                }
                _ = try await handle.close()
                #if FLOE_UNIFIED_MAC
                if mode == .goal, finishedNormally, liveRuns[taskID]?.stopping != true {
                    // The execution lease has retired. Review uses a separate
                    // model request without exposing the old approval surface.
                    liveRuns[taskID]?.handle = nil
                    let roundID = handle.identity.runID
                    let review = Task { [weak self] in
                        try? await runtime.reviewCompletedGoalRound(runID: roundID, conversationID: taskID,
                                                                   provider: provider) { [weak self] in
                            await MainActor.run {
                                self?.liveRuns[taskID]?.stopping == false && self?.isTerminating == false
                            }
                        }
                    }
                    goalReviews[taskID] = review
                    if let next = await review.value, liveRuns[taskID]?.stopping == false {
                        nextGoalRound = (roundID, next)
                    }
                    goalReviews.removeValue(forKey: taskID)
                    if liveRuns[taskID]?.stopping == true {
                        finishedNormally = false
                        if let completed = try? await runtime.runRecord(runID: roundID),
                           let saved = try? await runtime.goals(conversationID: taskID).first(where: { $0.id == completed.goalID }),
                           saved.status == .active || saved.status == .verifying {
                            _ = try? await runtime.setGoalPaused(conversationID: taskID, goalID: saved.id, expectedRevision: saved.revision ?? 1)
                        }
                    }
                    if selectedID == taskID { await loadPlanning(conversationID: taskID, runtime: runtime) }
                }
                if selectedID == taskID, [.failed, .interrupted].contains(terminal.outcome),
                   let run = try await runtime.recentRuns(conversationID: taskID, limit: 1).first,
                   run.id == handle.identity.runID {
                    await loadHistoryContinuation(run, runtime: runtime)
                }
                #endif
                if selectedID == taskID && (terminal.outcome == .failed || terminal.outcome == .blocked) {
                    #if FLOE_UNIFIED_MAC
                    failedRunID = handle.identity.runID
                    #endif
                    if notice == nil { notice = String(localized: "host.chat.runFailed") }
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
                if !admitted, queued == nil, acceptedPlan == nil, !resumingGoal, !continuingFromHistory { rejectedPrompt = text }
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
                    notice = checkpointRunID == nil ? String(localized: "host.chat.runFailed")
                        : String(localized: "mac.agent.checkpointUnavailable")
                }
            }
        }
        return true
    }

    #if FLOE_UNIFIED_MAC
    private func loadHistoryContinuation(_ run: RunRecord, runtime: FloeMacSelfRuntime) async {
        guard run.conversationID == selectedID, run.state != "completed" else { return }
        let selection = historySelection
        let action = try? await runtime.continuation(after: run.id, in: run.conversationID)
        guard historySelection == selection, selectedID == run.conversationID else { return }
        historyContinuation = action.map { (run: run, action: $0) }
        if run.state == "failed" { await loadProviderFailure(run, runtime: runtime, selection: selection) }
    }

    private func loadProviderFailure(_ run: RunRecord, runtime: FloeMacSelfRuntime, selection: UUID) async {
        guard let events = try? await runtime.recentRunEvents(runID: run.id, limit: 25) else { return }
        guard historySelection == selection, selectedID == run.conversationID else { return }
        let decoder = JSONDecoder()
        var failure: [String: String]?
        for event in events.reversed() where event.kind == .error || event.kind == .status {
            guard let fields = try? decoder.decode([String: String].self, from: Data(event.payloadJSON.utf8)) else { continue }
            if event.kind == .error, fields["kind"].flatMap(AgentEvent.NormalizedError.Kind.init(rawValue:)) != nil {
                failure = fields
                break
            }
            if event.kind == .status, fields["kind"] == "providerAttempt" {
                if fields["status"] == "completed" { return }
                if ["failed", "exhausted"].contains(fields["status"] ?? "") {
                    failure = fields
                    break
                }
            }
        }
        guard let failure else { return }
        let provider = accounts.first { $0.id == run.providerID }?.profile
        let status = failure["httpStatus"].flatMap(Int.init)
        let kind = (failure["errorKind"] ?? failure["kind"]).flatMap(AgentEvent.NormalizedError.Kind.init(rawValue:))
        let reason = failure["reason"] ?? failure["message"] ?? ""
        if let provider,
           (kind == .auth && status == 400 && ProviderBillingEndpoint.resolve(provider.baseURL) == .volcengineAgentPlan
            || ProviderConnectionProbe.isInactiveVolcenginePlan(provider: provider, status: status, body: reason)) {
            notice = ProviderConnectionProbe.inactiveVolcenginePlanMessage
        } else {
            switch kind {
            case .auth:
                notice = MacPermissionsText.t("供应商拒绝了当前凭据或模型访问权限。请检查 API 密钥和模型权限。",
                                              "The provider refused access. Check the API key and the model’s permissions.")
            case .rateLimited:
                notice = MacPermissionsText.t("供应商的额度或请求频率受限。请稍后重试，或切换模型。",
                                              "The provider is rate limited or out of quota. Try again later or change models.")
            case .contextOverflow:
                notice = MacPermissionsText.t("请求超过了模型的上下文上限。请缩短消息，或选择支持更长上下文的模型。",
                                              "The request exceeded the model’s context limit. Shorten the message or choose a model with a larger context window.")
            case .malformed where status == 404:
                notice = MacPermissionsText.t("供应商找不到模型或接口。请检查接口地址、协议和模型 ID。",
                                              "The provider could not find the model or endpoint. Check the endpoint, protocol and model ID.")
            case .network, .server:
                notice = MacPermissionsText.t("未能连接模型或供应商暂时不可用。可从已保存的任务继续。",
                                              "The model could not be reached or the provider is unavailable. You can continue from the saved task.")
            case .malformed:
                let reference = status.map { " (HTTP \($0))" } ?? ""
                notice = MacPermissionsText.t("供应商未接受请求\(reference)。请检查模型配置或选择另一个模型。",
                                              "The provider rejected the request\(reference). Check the model configuration or choose another model.")
            default:
                return
            }
        }
        showsModelSettingsForFailure = true
    }

    func continueFromHistory(_ run: RunRecord) async {
        guard run == continuableRun, let runtime, let release = admit() else { return }
        defer { release() }
        let selection = historySelection
        do {
            let action = try await runtime.continuation(after: run.id, in: run.conversationID)
            guard historySelection == selection, run == continuableRun else { return }
            guard let action else { historyContinuation = nil; return }
            guard let config = try configuration(), taskModelID == nil || config.model.id == taskModelID,
                  !action.resumesOriginalRun || (config.model.id == run.modelID && config.profile.id == run.providerID) else {
                notice = action.resumesOriginalRun ? String(localized: "mac.agent.continueOriginalModel")
                    : String(localized: "host.chat.configureFirst")
                return
            }
            let mode: HostAgentMode = switch action.toolAccess { case .chat: .chat; case .task: .agent; case .plan: .plan }
            guard mode == .chat || config.model.capabilities.contains(.tools) else {
                notice = String(localized: "mac.agent.toolsModelRequired")
                return
            }
            if action.resumesOriginalRun {
                _ = beginSend(run.goal, runtime: runtime, provider: config.binding(), workspaceID: selectedConversationWorkspace?.id,
                              mode: mode, continuingFromHistory: true, checkpointRunID: run.id)
                return
            }
            if action.needsReview {
                try await runtime.retireForSeparateReview(runID: run.id, conversationID: run.conversationID)
                guard historySelection == selection, run == continuableRun else { return }
            }
            let prompt = action.needsReview
                ? MacPermissionsText.t(
                    "核对上一个中断回合。根据已保存的执行记录和工作区文件，说明哪些操作可以确认、哪些结果仍待核对。请先使用只读检查。",
                    "Review the interrupted round. Use the saved execution records and workspace files to distinguish confirmed outcomes from those that still need review. Start with read-only checks.")
                : MacPermissionsText.t(
                "从此会话已保存的进度继续。先核对最后完成的步骤与工具结果，只处理剩余工作。结果不确定的操作先核实，无法核实时询问我。",
                "Continue from the saved progress in this conversation. Check the last completed steps and tool results, then work on what remains. Verify any uncertain outcome and ask me if it cannot be verified.")
            _ = beginSend(prompt, runtime: runtime, provider: config.binding(), mode: mode, continuingFromHistory: true)
        } catch {
            if historySelection == selection { notice = String(localized: "host.chat.runFailed") }
        }
    }

    func canPauseGoal(_ candidate: ConversationGoal) -> Bool {
        canChangeGoal(candidate) && [.active, .waitingApproval, .waitingUser, .verifying].contains(candidate.status)
    }

    private func canChangeGoal(_ candidate: ConversationGoal) -> Bool {
        candidate == goal && selectedID == candidate.conversationID
            && !isTerminating && !isAcceptingPlan && !changingGoals.contains(candidate.conversationID)
    }

    func canContinueGoal(_ candidate: ConversationGoal) -> Bool {
        let incomplete = !candidate.acceptanceCriteria.allSatisfy(\.isSatisfied)
            || candidate.steps.contains { $0.status != .completed && $0.status != .skipped }
        return canChangeGoal(candidate) && !isSending && pendingQuestion == nil && pendingApproval == nil
            && !needsInterruptedRunReview
            && ([.active, .paused, .interrupted, .blocked, .waitingUser].contains(candidate.status)
                || (candidate.status == .verifying && incomplete))
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
        let selection = historySelection
        Task {
            let route: FloeMacSelfGoalContinuation
            do {
                route = try await runtime.goalContinuation(conversationID: candidate.conversationID, goalID: candidate.id,
                                                           expectedRevision: candidate.revision ?? 1)
            } catch {
                if historySelection == selection && canContinueGoal(candidate) {
                    notice = String(localized: "mac.agent.goalControlFailed")
                }
                return
            }
            guard historySelection == selection, canContinueGoal(candidate) else { return }
            do {
                guard let config = try configuration() else {
                    notice = String(localized: "host.chat.configureFirst")
                    return
                }
                guard config.model.capabilities.contains(.tools) else {
                    notice = String(localized: "mac.agent.toolsModelRequired")
                    return
                }
                switch route {
                case .checkpoint(let original):
                    guard config.model.id == original.modelID, config.profile.id == original.providerID else {
                        notice = String(localized: "mac.agent.continueOriginalModel")
                        return
                    }
                    _ = beginSend(original.goal, runtime: runtime, provider: config.binding(),
                                  workspaceID: selectedConversationWorkspace?.id, mode: .goal, resumingGoal: true,
                                  checkpointRunID: original.id)
                case .newRound:
                    _ = beginSend(String(localized: "mac.agent.continueGoalPrompt"), runtime: runtime, provider: config.binding(),
                                  mode: .goal, resumingGoal: true)
                }
            } catch {
                notice = String(localized: "host.chat.keychainUnavailable")
            }
        }
    }

    private func startAutomaticGoalRound(_ round: (predecessor: UUID, goal: ConversationGoal),
                                         provider: FloeMacSelfProviderBinding, runtime: FloeMacSelfRuntime) {
        let taskID = round.goal.conversationID
        guard !isTerminating, !changingGoals.contains(taskID), queuedInputs[taskID]?.isEmpty != false,
              liveRuns[taskID] == nil else { return }
        let currentProvider = providers.first { $0.profile.id == provider.provider.id && $0.model.id == provider.model.id
            && $0.profile.isEnabled && $0.model.isEnabled }?.binding()
        guard let binding = currentProvider ?? (vault == nil ? provider : nil) else { return }
        let prompt = MacPermissionsText.t(
            "继续当前目标。核对前一轮的证据与尚未完成的验收条件，在授权范围内推进。请从实际产物取得新证据，并按照目标的停止条件结束。",
            "Continue the active Goal. Check the previous round’s evidence and unfinished criteria, then make authorized progress. Verify the actual deliverable with new evidence and respect the Goal’s stopping conditions.")
        _ = beginSend(prompt, runtime: runtime, provider: binding, mode: .goal, automaticGoal: round)
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

    #if FLOE_UNIFIED_MAC
    func editGoal(_ expected: ConversationGoal, objective: String, criteria: [String],
                  blockers: [String], stops: [String]) async -> Bool {
        let id = expected.conversationID
        guard selectedID == id, expected.id == goal?.id, !isTaskRunning(id), !isTerminating,
              !changingGoals.contains(id), let runtime, let release = admit() else { return false }
        changingGoals.insert(id)
        defer { changingGoals.remove(id); release() }
        do {
            _ = try await runtime.editGoalDefinition(conversationID: id, goalID: expected.id,
                expectedRevision: expected.revision ?? 1, objective: objective, criteria: criteria,
                blockers: blockers, stops: stops)
            await loadPlanning(conversationID: id, runtime: runtime)
            return true
        } catch {
            if selectedID == id { notice = String(localized: "mac.agent.goalControlFailed") }
            return false
        }
    }

    #endif

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
            #if FLOE_UNIFIED_MAC
            try await refreshTranscript(for: candidate.conversationID, runtime: runtime)
            #else
            let updated = try await runtime.conversationMessagePage(conversationID: candidate.conversationID)
            applyHistory(updated, retainingVisibleHistory: true)
            #endif
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
        let reasoning = snapshot?.reasoningText ?? ""
        if liveRuns[taskID]?.reasoningText != reasoning { liveRuns[taskID]?.reasoningText = reasoning }
        let waiting = snapshot?.liveness.phase == .waitingForFirstEvent
        if liveRuns[taskID]?.awaitingModel != waiting { liveRuns[taskID]?.awaitingModel = waiting }
        let waitingForQuestion = snapshot?.stateName == "waitingUserQuestion"
        if liveRuns[taskID]?.waitingForQuestion != waitingForQuestion {
            liveRuns[taskID]?.waitingForQuestion = waitingForQuestion
        }
        let attempt = snapshot?.providerAttempt
        let reconnect = attempt.flatMap { $0.status == .retryScheduled ? $0.attempt + 1 : ($0.attempt > 1 && $0.status == .started ? $0.attempt : nil) }
        if liveRuns[taskID]?.reconnectAttempt != reconnect { liveRuns[taskID]?.reconnectAttempt = reconnect }
        guard let request = snapshot?.pendingApproval else {
            if liveRuns[taskID]?.approval != nil { liveRuns[taskID]?.approval = nil }
            return
        }
        let call = request.toolCall
        let preview: (path: String?, text: String?, previousText: String?)
        #if FLOE_UNIFIED_MAC
        let decoder = JSONDecoder()
        if let mutation = MacAgentWorkspaceMutationPreview.preview(of: call) {
            preview = mutation
        } else if let browser = MacTaskBrowserApproval.preview(call) {
            preview = (browser.path, browser.text, nil)
        } else {
            switch call.toolName {
            case WorkspaceOutputPublication.name:
                let args = try? decoder.decode(WorkspaceOutputPublication.Arguments.self, from: call.argumentsJSON)
                preview = (args?.path, nil, nil)
            case DelegateTool.name:
                let args = try? decoder.decode(DelegateTool.Arguments.self, from: call.argumentsJSON)
                let details = args.map { [$0.task, $0.context].compactMap { $0 }.joined(separator: "\n\n") }
                preview = (nil, details, nil)
            default:
                preview = (nil, MacNativeCommandPolicy.preview(call) ?? MacTaskActionPreview(call)?.detail, nil)
            }
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

    func resolveApproval(_ approval: HostAgentApproval, allow: Bool, remember scope: FloeMacFileGrantScope? = nil) async {
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
        #if FLOE_UNIFIED_MAC
        let context = liveRuns[taskID]?.approvalContext
        #endif
        let decision: ApprovalDecision = allow
            ? .allow(scope: ApprovalScope(toolName: approval.toolName, singleUse: true), expiresAt: nil)
            : .deny(reason: "User declined this workspace operation.")
        let result = await handle.resolveApproval(.init(conversationID: approval.conversationID,
            runID: approval.runID, workspaceID: approval.workspaceID, callID: approval.callID,
            toolName: approval.toolName, decision: decision, requestedAt: approval.requestedAt))
        #if FLOE_UNIFIED_MAC
        if result == .accepted, allow, let scope, let context, context.conversationID == taskID,
           context.workspaceID == approval.workspaceID, let path = approval.path,
           MacAgentWorkspaceTools.writeToolNames.contains(approval.toolName), MacAgentWorkspaceTools.canRememberFile(path),
           let identity = context.identities[approval.toolName] {
            do {
                try await context.grants.remember(scope: scope, workspaceID: context.workspaceID,
                    conversationID: taskID, toolName: approval.toolName, path: path, authorizationIdentity: identity, workspaceRoot: context.root)
            } catch {
                if selectedID == taskID { notice = String(localized: "mac.permissions.grantFailed") }
            }
        }
        #endif
        guard liveRuns[taskID]?.handle?.identity == handle.identity else { return }
        if result == .accepted, liveRuns[taskID]?.approval == approval { liveRuns[taskID]?.approval = nil }
        await updateLiveRun(handle)
        if result != .accepted, selectedID == taskID, liveRuns[taskID]?.approval == approval {
            notice = String(localized: "mac.agent.approvalFailed")
        }
    }

    #if FLOE_UNIFIED_MAC
    var runningInputMode: RunningInputMode {
        get { RunningInputMode(rawValue: preferences.string(forKey: "floe.mac.runningInputMode") ?? "") ?? .queue }
        set {
            objectWillChange.send()
            preferences.set(newValue.rawValue, forKey: "floe.mac.runningInputMode")
        }
    }

    @Published private(set) var queuedInputs: [UUID: [PendingUserInput]] = [:]
    private var drainingQueues = Set<UUID>()
    private var queueRefreshes: [UUID: UUID] = [:]

    private func refreshQueue(_ id: UUID) async {
        guard let runtime else { return }
        let token = UUID()
        queueRefreshes[id] = token
        do {
            let store = try await runtime.runningInputStore()
            let rows = try await store.pending(conversationID: id)
            if queueRefreshes[id] == token {
                // Mirror the iPad pending set so the disclosure can offer
                // "Back to queue" for accepted-but-unconsumed guidance and a
                // converting caption for a row mid-promotion. Browser-handoff
                // notice rows stay hidden: their execution mode never maps to
                // a host mode.
                queuedInputs[id] = rows.filter {
                    $0.status.isPending && HostAgentMode(rawValue: $0.executionMode) != nil
                }
                queueRefreshes[id] = nil
            }
        } catch {
            if selectedID == id { notice = String(localized: "mac.agent.queueUnavailable") }
        }
    }

    /// Queues text plus an optional exact set of staged attachments as one
    /// durable message for the active run's conversation. Only the submitted
    /// set is consumed from the composer strip after the store commit, so
    /// files staged later or in parallel are never touched. Text stays
    /// required (an attachment-only payload is not part of the shared
    /// contract) and is normalized the same way as an idle send.
    func enqueue(_ text: String, attachments: [HostAgentAttachmentDraft] = [], onAccepted: @escaping () -> Void) {
        guard canSteer, let run = visibleRun, let id = selectedID, let handle = run.handle,
              let modelID = run.modelID, let runtime, let release = admit() else { return }
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, text.utf8.count <= 1_048_576, !text.utf8.contains(0) else {
            release()
            notice = String(localized: "mac.agent.queueUnavailable")
            return
        }
        let submitted = attachments
        if submitted.contains(where: { $0.kind == .image }), !modelAcceptsImages(modelID) {
            release()
            notice = String(localized: "mac.workspace.selectVisionModel")
            return
        }
        let input = PendingUserInput(conversationID: id, targetRunID: handle.identity.runID,
                                     content: text, mode: .queue, status: .queued, position: 0,
                                     attachments: submitted.map(\.reference),
                                     selectedModelID: modelID, workspaceID: handle.identity.workspaceID,
                                     executionMode: run.mode.rawValue)
        liveRuns[id]?.steering = true
        Task {
            defer {
                if liveRuns[id]?.handle?.identity == handle.identity { liveRuns[id]?.steering = false }
                release()
            }
            do {
                let store = try await runtime.runningInputStore()
                _ = try await store.enqueue(input)
                consumeStaged(submitted, for: id)
                onAccepted()
                await refreshQueue(id)
                // The original run may have finished during the store commit.
                if liveRuns[id] == nil, let receipt = await handle.waitForTerminal(),
                   receipt.confirmed, receipt.outcome == .completed { await startNextQueued(id) }
            } catch {
                if selectedID == id { notice = String(localized: "mac.agent.queueUnavailable") }
            }
        }
    }

    /// True when the model bound to `modelID`, plus the configured
    /// auxiliary vision route, can accept image attachments. Text-only
    /// runs must refuse image guidance up front: the row is never created
    /// (submit) or is kept queued (drain) with an honest notice, and the
    /// staged files plus draft stay with the user.
    private func modelAcceptsImages(_ modelID: UUID) -> Bool {
        let modelVision = providers.first(where: { $0.model.id == modelID })?
            .model.capabilities.contains(.vision) == true
        return modelVision || selectedAuxiliary(.vision) != nil
    }

    /// Drops exactly the attachments a queued/steered submission consumed,
    /// computed against the conversation's stored draft rather than the
    /// live selection: the stored refs are filtered by the submitted ids,
    /// re-verified through the security-scoped resolution, and persisted
    /// back under the same conversation. The visible strip is mutated only
    /// while it still shows that conversation's draft, and anything staged
    /// after the submission keeps its identity.
    private func consumeStaged(_ submitted: [HostAgentAttachmentDraft], for conversationID: UUID) {
        guard !submitted.isEmpty else { return }
        let key = attachmentDraftKey(for: conversationID)
        let consumedIDs = Set(submitted.map(\.id))
        let stored = loadAttachmentDraft?(key) ?? []
        var remaining: [AttachmentRef] = []
        var dropped = false
        for reference in stored where !consumedIDs.contains(reference.id) {
            if draftAttachment(reference, id: reference.id) != nil {
                remaining.append(reference)
            } else {
                dropped = true
            }
        }
        saveAttachmentDraft?(key, remaining)
        if selectedID == conversationID {
            stagedAttachments = remaining.compactMap { draftAttachment($0, id: $0.id) }
        }
        if dropped, selectedID == conversationID {
            notice = String(localized: "mac.workspace.attachmentUnavailable")
        }
    }

    /// Withdraws one accepted-but-unconsumed guidance row through the exact
    /// live session that owns it. `row` must be the row freshly re-read from
    /// the store by the caller — never the UI-rendered copy — because the
    /// runtime consumes against durable state, not presentation state.
    /// Returns false when the row is still steerPending but could not be
    /// withdrawn (the runtime consumed it or the owning session is gone);
    /// throws for store failures. Callers must treat false as "already on
    /// its way" and never edit/delete the row.
    private func withdrawQueuedGuidanceIfLive(_ row: PendingUserInput) async throws -> Bool {
        guard row.status == .steerPending else { return true }
        guard let targetRunID = row.targetRunID,
              let handle = liveRuns[row.conversationID]?.handle,
              handle.identity.runID == targetRunID else {
            // No live session owns the steer anymore: the confirmed-terminal
            // sweep requeues it. Fail closed instead of restoring a row the
            // runtime may still consume.
            return false
        }
        return await handle.withdrawSteer(id: row.id)
    }

    /// The shared composer bound mirrored for queue edits and conversion:
    /// the runtime never accepts a user text above 1 MiB or containing NUL.
    static let maximumQueuedContentBytes = 1_048_576

    /// iPad-style pending queue edit. The current durable row is re-read and
    /// validated (same conversation, eligible status, size bound) before any
    /// write: a queued row updates in place, a steerPending row is withdrawn
    /// first so the runtime never consumes an edited message, and the
    /// restored queued row then takes the new text. The original
    /// model/workspace/execution-mode binding is never touched.
    func editQueued(_ input: PendingUserInput, content: String) async {
        let text = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard selectedID == input.conversationID, !text.isEmpty, !text.utf8.contains(0),
              text.utf8.count <= Self.maximumQueuedContentBytes,
              let runtime, let release = admit() else { return }
        defer { release() }
        let conversationID = input.conversationID
        do {
            let store = try await runtime.runningInputStore()
            guard let row = try await store.input(id: input.id),
                  row.conversationID == conversationID else {
                await refreshQueue(conversationID)
                return
            }
            guard try await withdrawQueuedGuidanceIfLive(row) else {
                if selectedID == conversationID {
                    notice = String(localized: "mac.agent.guidanceAlreadySent")
                }
                await refreshQueue(conversationID)
                return
            }
            try await store.updateContent(id: row.id, content: text)
            await refreshQueue(conversationID)
        } catch {
            if selectedID == conversationID { notice = String(localized: "mac.agent.queueUnavailable") }
        }
    }

    /// Moves one queued row up or down by `offset` positions, mirroring the
    /// iPad queue reorder. The row is re-read first: only a still-queued row
    /// of this conversation participates, and a stale list fails closed
    /// through the store's exact-set check.
    func moveQueued(_ input: PendingUserInput, offset: Int) async {
        guard selectedID == input.conversationID, offset != 0, let runtime,
              let release = admit() else { return }
        defer { release() }
        let conversationID = input.conversationID
        let queued = (queuedInputs[conversationID] ?? []).filter { $0.status == .queued }
        guard let source = queued.firstIndex(where: { $0.id == input.id }) else { return }
        let destination = source + offset
        guard queued.indices.contains(destination) else { return }
        var reordered = queued
        reordered.swapAt(source, destination)
        do {
            let store = try await runtime.runningInputStore()
            guard let row = try await store.input(id: input.id),
                  row.conversationID == conversationID, row.status == .queued else {
                await refreshQueue(conversationID)
                return
            }
            try await store.reorder(conversationID: conversationID,
                                    orderedIDs: reordered.map(\.id))
            await refreshQueue(conversationID)
        } catch {
            if selectedID == conversationID { notice = String(localized: "mac.agent.queueUnavailable") }
        }
    }

    /// Converts one queued row into running guidance for the active run,
    /// reusing the row's exact id so the durable lifecycle (queued ->
    /// promoting -> steerPending -> consumed/restore) mirrors the iPad path
    /// and a rejected conversion leaves the text queued, never duplicated.
    /// The row is re-read before submission and steered with its current
    /// durable content and its own execution mode, so a restored row
    /// relaunches with its original mode, model and workspace.
    func promoteQueuedToGuidance(_ input: PendingUserInput) async {
        guard canSteer, selectedID == input.conversationID,
              let run = visibleRun, let handle = run.handle, let runtime,
              let release = admit() else { return }
        let conversationID = input.conversationID
        liveRuns[conversationID]?.steering = true
        defer {
            if liveRuns[conversationID]?.handle?.identity == handle.identity {
                liveRuns[conversationID]?.steering = false
            }
            release()
        }
        do {
            let store = try await runtime.runningInputStore()
            // Convert the durable row, not the UI copy: same exact id,
            // current content, still queued, bounded size, valid mode.
            guard let row = try await store.input(id: input.id),
                  row.conversationID == conversationID,
                  row.status == .queued,
                  HostAgentMode(rawValue: row.executionMode) != nil,
                  !row.content.utf8.contains(0),
                  row.content.utf8.count <= Self.maximumQueuedContentBytes else {
                await refreshQueue(conversationID)
                return
            }
            guard row.workspaceID == handle.identity.workspaceID, row.selectedModelID == run.modelID,
                  row.executionMode == run.mode.rawValue else {
                if selectedID == conversationID { notice = String(localized: "mac.agent.queueHeld") }
                return
            }
            if run.mode == .goal {
                guard let source = row.targetRunID,
                      let goalID = try await runtime.runRecord(runID: source)?.goalID,
                      try await runtime.runRecord(runID: handle.identity.runID)?.goalID == goalID,
                      try await runtime.goals(conversationID: conversationID).contains(where: { $0.id == goalID && $0.status == .active })
                else {
                    if selectedID == conversationID { notice = String(localized: "mac.agent.queueHeld") }
                    return
                }
            }
            let accepted = try await handle.steer(
                text: row.content,
                inputID: row.id,
                expectedConversationID: conversationID,
                expectedRunID: handle.identity.runID,
                executionMode: row.executionMode
            )
            if !accepted, selectedID == conversationID { notice = String(localized: "mac.agent.queueHeld") }
            await refreshQueue(conversationID)
        } catch {
            if selectedID == conversationID { notice = String(localized: "mac.agent.queueUnavailable") }
        }
    }

    /// Demotes one accepted-but-unconsumed guidance row back to the ordinary
    /// queue ("Back to queue"). The current durable row is re-read and only a
    /// steerPending row bound to the exact live session is withdrawn; false
    /// means the row was already consumed or changed, in which case the row
    /// keeps its honest status and only the list refreshes.
    func demoteQueuedGuidance(_ input: PendingUserInput) async {
        guard selectedID == input.conversationID, let runtime, let release = admit() else { return }
        defer { release() }
        let conversationID = input.conversationID
        do {
            let store = try await runtime.runningInputStore()
            let row = try await store.input(id: input.id)
            guard row?.conversationID == conversationID,
                  row?.status == .steerPending,
                  let targetRunID = row?.targetRunID,
                  let handle = liveRuns[conversationID]?.handle,
                  handle.identity.runID == targetRunID,
                  await handle.withdrawSteer(id: input.id) else {
                if selectedID == conversationID, row?.status == .steerPending {
                    notice = String(localized: "mac.agent.guidanceAlreadySent")
                }
                await refreshQueue(conversationID)
                return
            }
            await refreshQueue(conversationID)
        } catch {
            if selectedID == conversationID { notice = String(localized: "mac.agent.queueUnavailable") }
        }
    }

    func cancelQueued(_ input: PendingUserInput) async {
        guard selectedID == input.conversationID, let runtime, let release = admit() else { return }
        defer { release() }
        let conversationID = input.conversationID
        do {
            let store = try await runtime.runningInputStore()
            // Removing a guidance row re-reads it and withdraws the current
            // steerPending state first: the runtime must not consume a
            // message the user is deleting. A consumed row cannot be
            // withdrawn and stays honest instead of disappearing.
            guard let row = try await store.input(id: input.id),
                  row.conversationID == conversationID else {
                await refreshQueue(conversationID)
                return
            }
            guard try await withdrawQueuedGuidanceIfLive(row) else {
                if selectedID == conversationID {
                    notice = String(localized: "mac.agent.guidanceAlreadySent")
                }
                await refreshQueue(conversationID)
                return
            }
            try await store.cancel(id: row.id)
            await refreshQueue(conversationID)
        } catch {
            if selectedID == conversationID { notice = String(localized: "mac.agent.queueUnavailable") }
        }
    }

    func startNextQueued(_ id: UUID) async {
        guard !isTerminating, !changingTasks.contains(id), liveRuns[id] == nil, let runtime,
              !drainingQueues.contains(id), let release = admit() else { return }
        drainingQueues.insert(id)
        defer {
            drainingQueues.remove(id)
            release()
        }
        do {
            let store = try await runtime.runningInputStore()
            while let input = try await store.claimNextQueued(conversationID: id) {
                do {
                    if let existing = try await runtime.runRecord(runID: input.id), existing.conversationID == id {
                        try await store.markConsumed(id: input.id, runID: existing.id)
                        continue
                    }
                    guard let mode = HostAgentMode(rawValue: input.executionMode),
                          let model = providers.first(where: { $0.model.id == input.selectedModelID && $0.profile.isEnabled && $0.model.isEnabled && $0.model.supportsChatAgentSurface }),
                          let owner = try await runtime.workspaceForConversation(id), owner.id == input.workspaceID,
                          !isTerminating, !changingTasks.contains(id), liveRuns[id] == nil else { throw CocoaError(.userCancelled) }
                    // A queued guidance carrying an image the bound model
                    // cannot accept stays queued with an honest notice; the
                    // exact row is never launched and never dropped.
                    if input.attachments.contains(where: { $0.kind == .image }),
                       !model.model.capabilities.contains(.vision), selectedAuxiliary(.vision) == nil {
                        try await store.restoreQueued(id: input.id)
                        if selectedID == id { notice = String(localized: "mac.workspace.selectVisionModel") }
                        break
                    }
                    // Restore the row's durable attachments through the same
                    // verified security-scoped resolution the failed-prompt
                    // recovery uses. They travel into the session request as
                    // `queuedAttachments`, so the visible task's staged strip
                    // is never mutated by a background drain.
                    let queuedAttachments: [HostAgentAttachmentDraft]
                    if input.attachments.isEmpty {
                        queuedAttachments = []
                    } else {
                        let restored = input.attachments.prefix(Self.maximumStagedAttachmentCount)
                            .compactMap { draftAttachment($0, id: $0.id) }
                        guard restored.count == input.attachments.count else {
                            try await store.restoreQueued(id: input.id)
                            if selectedID == id { notice = String(localized: "mac.workspace.attachmentUnavailable") }
                            break
                        }
                        queuedAttachments = restored
                    }
                    let priorGoal: ConversationGoal?
                    if mode == .goal {
                        guard let sourceID = input.targetRunID,
                              let goalID = try await runtime.runRecord(runID: sourceID)?.goalID,
                              let active = try await runtime.goals(conversationID: id).first(where: { $0.id == goalID }),
                              active.status == .active else { throw CocoaError(.userCancelled) }
                        priorGoal = active
                    } else { priorGoal = nil }
                    guard beginSend(input.content, runtime: runtime, provider: model.binding(),
                                    workspaceID: owner.id, mode: mode, queued: input, queuedGoal: priorGoal,
                                    queuedAttachments: queuedAttachments)
                    else { throw CocoaError(.userCancelled) }
                } catch {
                    try await store.restoreQueued(id: input.id)
                    if selectedID == id { notice = String(localized: "mac.agent.queueHeld") }
                }
                break
            }
            await refreshQueue(id)
        } catch {
            if selectedID == id { notice = String(localized: "mac.agent.queueUnavailable") }
        }
    }

    var canSteer: Bool {
        guard let run = visibleRun, let identity = run.handle?.identity else { return false }
        return identity.conversationID == selectedID && !run.steering && !run.stopping
            && !isTerminating && run.phase == .running && !isLoadingHistory
    }

    var lastSteer: String? { visibleRun?.lastSteer }

    /// Steers the active run with text plus an optional exact set of staged
    /// attachments. Attachments travel through the same durable pending row
    /// as queued messages (iPad `submitRunningInput` parity), so a rejected
    /// or stale steer restores to the ordinary queue with its attachments
    /// intact instead of dropping them; only a consumed steer consumes the
    /// staged set. Text stays required by the shared contract.
    func steer(_ text: String, attachments: [HostAgentAttachmentDraft] = [], onAccepted: @escaping () -> Void) {
        guard canSteer, let run = visibleRun, let handle = run.handle, let id = selectedID else { return }
        let content = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !content.isEmpty, let release = admit() else { return }
        let runID = handle.identity.runID
        let inputID = UUID()
        let submitted = attachments
        liveRuns[id]?.steering = true
        Task {
            defer {
                if liveRuns[id]?.handle?.identity.runID == runID { liveRuns[id]?.steering = false }
                release()
            }
            do {
                if !submitted.isEmpty, let runtime {
                    if submitted.contains(where: { $0.kind == .image }),
                       let modelID = run.modelID, !modelAcceptsImages(modelID) {
                        if selectedID == id { notice = String(localized: "mac.workspace.selectVisionModel") }
                        return
                    }
                    // Commit the row (with attachments) before promotion so a
                    // rejected steer remains an ordinary queued message, the
                    // iPad lifecycle for a failed steer conversion.
                    let store = try await runtime.runningInputStore()
                    _ = try await store.enqueue(PendingUserInput(
                        id: inputID, conversationID: id, targetRunID: runID,
                        content: content, mode: .queue, status: .queued, position: 0,
                        attachments: submitted.map(\.reference),
                        selectedModelID: run.modelID, workspaceID: handle.identity.workspaceID,
                        executionMode: run.mode.rawValue))
                    if try await handle.steer(text: content, inputID: inputID, expectedConversationID: id,
                                              expectedRunID: runID, executionMode: run.mode.rawValue) {
                        consumeStaged(submitted, for: id)
                        onAccepted()
                        if liveRuns[id]?.handle?.identity.runID == runID { liveRuns[id]?.lastSteer = content }
                        return
                    }
                    // Rejected: the session restored the row to the durable
                    // queue. Confirm that exact durable state, then clear the
                    // composer copy (text and the consumed attachments) so
                    // the user cannot submit the same message twice, and
                    // surface queued feedback instead of an error.
                    if let row = try await store.input(id: inputID), row.status == .queued {
                        consumeStaged(submitted, for: id)
                        onAccepted()
                        if selectedID == id {
                            notice = MacComposerInputText.t("消息已加入队列。", "Message added to the queue.")
                        }
                        if liveRuns[id] == nil, let receipt = await handle.waitForTerminal(),
                           receipt.confirmed, receipt.outcome == .completed { await startNextQueued(id) }
                    } else if selectedID == id {
                        notice = String(localized: "mac.agent.steerNotAccepted")
                    }
                    await refreshQueue(id)
                    return
                } else if try await handle.steer(text: content, inputID: inputID, expectedConversationID: id,
                                                 expectedRunID: runID, executionMode: run.mode.rawValue) {
                    onAccepted()
                    if liveRuns[id]?.handle?.identity.runID == runID { liveRuns[id]?.lastSteer = content }
                    return
                } else if let runtime {
                    let store = try await runtime.runningInputStore()
                    if try await store.input(id: inputID)?.status == .queued { try await store.cancel(id: inputID) }
                    await refreshQueue(id)
                }
            } catch { /* Keep the draft available if the store cannot confirm delivery. */ }
            if selectedID == id { notice = String(localized: "mac.agent.steerNotAccepted") }
        }
    }
    #endif

    func stop() {
        guard let taskID = visibleTaskID else { return }
        stopTask(taskID)
    }

    func stopTask(_ taskID: UUID) {
        guard liveRuns[taskID]?.stopping == false else { return }
        liveRuns[taskID]?.stopping = true
        #if FLOE_UNIFIED_MAC
        goalReviews[taskID]?.cancel()
        #endif
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
        taskContentSearchTask?.cancel()
        await taskContentSearchTask?.value
        taskContentSearchTask = nil
        #if FLOE_UNIFIED_MAC
        let background = Array(namingTasks.values)
        for task in background { task.cancel() }
        for task in background { await task.value }
        #endif
        if let runtime {
            _ = try await runtime.shutdown(cancelActive: false)
            questionSubscription = nil
        }
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
        guard vault != nil else { return nil }
        let store = try loadProviderStore()
        #if FLOE_UNIFIED_MAC
        if let provider = store.providers.first(where: { $0.model.id == taskModelID && $0.profile.isEnabled && $0.model.isEnabled && $0.model.supportsChatAgentSurface }) { return provider }
        #endif
        return store.selected
    }

    #if FLOE_UNIFIED_MAC
    private func applyComposerRun(_ run: RunRecord?) {
        historyContinuation = nil
        taskModelID = run?.modelID
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
        case .executionFinished(let callID, _, _):
            guard let index = activity.firstIndex(where: { $0.id == callID }),
                  activity[index].state == "running" || activity[index].state == "pending" else { return }
            activity[index].state = "settling"
        case .finished(let result):
            if let index = activity.firstIndex(where: { $0.id == result.callID }) {
                activity[index].state = result.status.rawValue
            }
        }
        runToolActivity[runID] = Array(activity.suffix(40))
    }

    private var loadingActivityRuns: [UUID: Task<Void, Never>] = [:]

    func loadVisibleToolActivity(runID: UUID, conversationID: UUID) async {
        guard selectedID == conversationID, activeRun?.identity.runID != runID, let runtime,
              runToolActivity[runID] == nil else { return }
        if let pending = loadingActivityRuns[runID] { await pending.value; return }
        let pending = Task { await loadToolActivity(runID: runID, conversationID: conversationID, runtime: runtime) }
        loadingActivityRuns[runID] = pending
        await pending.value
        loadingActivityRuns[runID] = nil
    }

    func withOutputFile(_ step: HostAgentToolActivity, use: (URL) -> Void) {
        guard let path = step.outputPath, let project = selectedConversationWorkspace,
              project.id == step.outputWorkspaceID else { notice = String(localized: "mac.run.fileUnavailable"); return }
        do { try MacAgentWorkspaceTools.withWorkspaceFile(project, privateTaskRootBase: personalTaskLeaseBase, path: path, use: use) }
        catch { notice = String(localized: "mac.run.fileUnavailable") }
    }

    func withOutputFile(_ step: HostAgentToolActivity, artifact: ToolArtifactReference,
                        use: @escaping @MainActor @Sendable (URL) -> Void) async {
        guard let owner = selectedConversationWorkspace, owner.id == step.outputWorkspaceID,
              let conversationID = selectedID, step.mediaArtifacts.contains(artifact) else {
            notice = String(localized: "mac.run.fileUnavailable")
            return
        }
        let base = personalTaskLeaseBase
        let work = Task.detached(priority: .userInitiated) {
            try MacAgentWorkspaceTools.withWorkspaceFile(owner, privateTaskRootBase: base,
                path: artifact.relativePath, artifact: artifact) { url in
                // Keep the scoped bookmark and verified descriptor alive for the Finder request.
                DispatchQueue.main.sync {
                    guard self.selectedID == conversationID, self.selectedConversationWorkspace?.id == owner.id,
                          !self.isTerminating else { return }
                    use(url)
                }
            }
        }
        do {
            try await withTaskCancellationHandler(operation: { try await work.value }, onCancel: { work.cancel() })
        } catch {
            if !Task.isCancelled, selectedID == conversationID, selectedConversationWorkspace?.id == owner.id {
                notice = String(localized: "mac.run.fileUnavailable")
            }
        }
    }

    private func loadToolActivity(runID: UUID, conversationID: UUID, runtime: FloeMacSelfRuntime) async {
        guard selectedID == conversationID else {
            // A background run's live rows lack durable receipts. Recover them when it is next opened.
            runToolActivity[runID] = nil
            return
        }
        guard let events = try? await runtime.recentRunEvents(runID: runID, limit: 250),
              selectedID == conversationID else { return }
        struct FileArgument: Decodable { var path: String }
        var paths: [String: String] = [:]
        var steps: [HostAgentToolActivity] = []
        var indexes: [String: Int] = [:]
        for event in events where event.kind == .toolRequest || event.kind == .toolResult {
            guard let values = try? JSONDecoder().decode([String: String].self, from: Data(event.payloadJSON.utf8)),
                  let id = values["id"], let status = values["status"] else { continue }
            let summary = values["summary"].flatMap { CredentialMessagePart.clipboardText(String($0.prefix(700))) }
            if event.kind == .toolRequest, let name = values["tool"],
               [MacAgentWorkspaceCreateFileTool.name, MacAgentWorkspaceReplaceTextTool.name].contains(name),
               let json = values["input"], let path = try? JSONDecoder().decode(FileArgument.self, from: Data(json.utf8)).path {
                paths[id] = path
            }
            let index: Int
            if let existing = indexes[id] {
                index = existing
                steps[index].state = status
                steps[index].summary = summary
            } else if let name = values["tool"], !name.isEmpty {
                index = steps.count
                indexes[id] = index
                steps.append(.init(id: id, toolName: name, state: status, summary: summary))
            } else { continue }
            guard event.kind == .toolResult else { continue }
            if status == "ok", values["dispatched"] == "true", values["tool"] == steps[index].toolName,
               let owner = values["workspaceID"].flatMap(UUID.init(uuidString:)), let path = paths[id] {
                steps[index].outputPath = path
                steps[index].outputWorkspaceID = owner
            }
            steps[index].applyMediaReceipt(values, conversationID: conversationID, workspaceID: selectedConversationWorkspace?.id)
        }
        runToolActivity[runID] = Array(steps.suffix(40))
    }
    #endif

    // MARK: - Provider store

    /// Reads the persisted list, migrating the 1.3.0 single-profile account
    /// on first use. Reads are non-destructive: invalid or duplicate records
    /// fail closed (surfaced as the existing Keychain-unavailable notice)
    /// and the stored bytes are never rewritten by a read.
    private func loadProviderStore() throws -> ProviderListEnvelope {
        #if FLOE_UNIFIED_MAC && FLOE_MAC_HOST_SMOKE
        if vault == nil { return ProviderListEnvelope(accounts: accounts, selectedModelID: selectedModelID) }
        #endif
        guard let vault else { return ProviderListEnvelope() }
        do {
            return try JSONDecoder().decode(ProviderListEnvelope.self, from: vault.read(account: Self.providerListAccount))
        } catch KeychainStoreError.itemNotFound {
            do {
                let old = try JSONDecoder().decode(HostAgentProvider.self, from: vault.read(account: Self.settingsAccount))
                try old.validate()
                var store = ProviderListEnvelope(accounts: [HostProviderAccount(old)], selectedModelID: old.model.id)
                store.normalizeSelection()
                try persistProviderStore(store)
                return store
            } catch KeychainStoreError.itemNotFound { return ProviderListEnvelope() }
        }
    }

    private func persistProviderStore(_ store: ProviderListEnvelope) throws {
        guard let vault else { return }
        let encoder = JSONEncoder()
        try vault.store(account: Self.providerListAccount, secret: encoder.encode(store))
        if let selected = store.selected { try? vault.store(account: Self.settingsAccount, secret: encoder.encode(selected)) }
        else { try? vault.delete(account: Self.settingsAccount) }
    }

    private func reloadProviders() {
        guard vault != nil else {
            providers = []
            accounts = []
            selectedModelID = nil
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
        accounts = store.accounts
        providers = store.providers
        selectedModelID = store.selectedModelID
        #if FLOE_UNIFIED_MAC
        reconcileAuxiliaryModels()
        if let approvalModelID, !providers.contains(where: { $0.model.id == approvalModelID }) {
            self.approvalModelID = nil
            preferences.removeObject(forKey: Self.reviewerKey)
        }
        refreshAutomaticReviewers()
        #endif
        selectedProviderID = store.selected?.profile.id
        modelName = store.selected?.model.displayName
    }

    /// Serialized list mutation: load, mutate, persist, then republish. Any
    /// Keychain read/write or decode failure leaves the stored bytes
    /// untouched and reports the existing local error notices.
    @discardableResult
    private func updateProviderStore(_ mutation: (inout ProviderListEnvelope) throws -> Void) -> Bool {
        #if !(FLOE_UNIFIED_MAC && FLOE_MAC_HOST_SMOKE)
        guard vault != nil else { return false }
        #endif
        guard !isSending, !isTerminating, let release = admit() else { return false }
        defer { release() }
        do {
            var store = try loadProviderStore()
            try mutation(&store)
            try store.validate()
            store.normalizeSelection()
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
                               debounce: Bool, allowsPlainHTTP: Bool = false, providerID: UUID? = nil,
                               presetID: ProviderTemplateID? = nil) {
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
                                         allowsPlainHTTP: allowsPlainHTTP, providerID: providerID, presetID: presetID)
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
                                key: String, allowsPlainHTTP: Bool = false, providerID: UUID? = nil,
                                presetID: ProviderTemplateID? = nil) async throws {
        guard isReady, !isTerminating, let release = admit() else { throw CancellationError() }
        defer { release() }
        var config = try HostProviderAccount.configured(name: nil, endpoint: endpoint, protocolKind: protocolKind,
            apiKey: key, presetID: presetID?.rawValue, allowsPlainHTTP: allowsPlainHTTP, catalog: modelProviderCatalog)
        config.profile.nonSecretHeaders = savedHeaders(for: providerID, endpoint: config.profile.baseURL)
        let credentials = ProviderCredentials(apiKey: config.apiKey.isEmpty ? nil : config.apiKey)
        try await ProviderConnectionProbe.testConnection(provider: config.profile, credentials: credentials,
            modelRemoteID: modelID, adapter: ProviderAdapterFactory().adapter(for: config.profile))
    }
    #endif

    private func savedHeaders(for accountID: UUID?, endpoint: URL) -> [String: String] {
        guard let accountID, let saved = accounts.first(where: { $0.id == accountID }),
              saved.profile.baseURL == endpoint else { return [:] }
        return saved.profile.nonSecretHeaders
    }

    private func runModelDiscovery(generation: UInt64, endpoint: String,
                                   protocolKind: ModelProtocol, apiKey: String, allowsPlainHTTP: Bool,
                                   providerID: UUID?, presetID: ProviderTemplateID?) async {
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
        let preset = ProviderPreset.all.first { $0.id == presetID } ?? ProviderPreset.preset(for: .custom, baseURL: url)
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
            var profile = ProviderProfile(kind: preset.kind, wireProtocol: protocolKind,
                                          baseURL: url, displayName: nil, presetID: preset.id.rawValue)
            profile.allowsPlainHTTP = allowsPlainHTTP
            profile.nonSecretHeaders = savedHeaders(for: providerID, endpoint: url)
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
    /// Debug-only fixture for the packaged App smoke: installs an in-memory
    /// provider aimed at the coordinator's loopback mock so an ordinary send
    /// runs without a project and without touching the Keychain, user
    /// providers or any persisted artifact. Loopback http only; production
    /// vault-backed hosts never enter this path.
    @discardableResult
    func useNativeCommandFixture(endpoint: URL) -> Bool {
        guard vault == nil, isReady, !isTerminating,
              endpoint.scheme == "http",
              endpoint.host == "127.0.0.1" || endpoint.host == "localhost",
              endpoint.port != nil,
              let config = try? HostAgentProvider(endpoint: endpoint.absoluteString,
                  protocolKind: .openAIChatCompletions, modelID: "native-mac-fixture", apiKey: "",
                  supportsTools: true, allowsPlainHTTP: true) else { return false }
        providers = [config]
        selectedProviderID = config.profile.id
        selectedModelID = config.model.id
        return true
    }

    // Used only by the packaged App smoke command with its temporary
    // database and Keychain disabled. The adapter never creates a request.
    func verifyChatSmoke(reply: String = "Synthetic persisted reply.", admissionIsClosedToInstall: () -> Bool = { true }) async -> Bool {
        guard vault == nil, isReady, let runtime, !isSending, selectedID == nil,
              let config = try? HostAgentProvider(endpoint: "https://example.invalid/v1",
                  protocolKind: .openAIChatCompletions, modelID: "mac-smoke", apiKey: "") else { return false }
        guard beginSend("Synthetic Mac chat", runtime: runtime,
                  provider: .init(provider: config.profile, model: config.model,
                                  adapter: SmokeChatAdapter(reply: reply), credentials: .init())) else { return false }
        let heldAdmission = admissionIsClosedToInstall()
        let deadline = ContinuousClock.now + .seconds(8)
        while isSending && ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(50))
        }
        guard !isSending, notice == nil, let conversationID = selectedID,
              messages.map(\.role) == ["user", "assistant"],
              conversations.first(where: { $0.id == conversationID })?.title == "Synthetic Mac chat" else { return false }
        await select(conversationID)
        return heldAdmission && messages.map(\.content) == ["Synthetic Mac chat", reply]
    }

    #if FLOE_UNIFIED_MAC
    func verifyProviderAccountsSmoke() async -> Bool {
        guard vault == nil else { return false }
        let scope = "org.floeagent.qa.model-catalog." + UUID().uuidString
        let fixture = HostAgentWorkspace(supportDirectory: supportDirectory, namespace: scope,
            useKeychain: true, preferences: preferences, admitWork: { {} })
        guard let vault = fixture.vault else { return false }
        defer {
            try? vault.delete(account: Self.providerListAccount)
            try? vault.delete(account: Self.settingsAccount)
        }
        do {
            struct OldCatalog: Encodable {
                var version = 1
                let providers: [HostAgentProvider]
                let selectedProviderID: UUID
            }
            let a = try HostAgentProvider(displayName: "Example A", endpoint: "https://example.invalid/v1",
                protocolKind: .openAIChatCompletions, modelID: "base", apiKey: "synthetic-A")
            let b = try HostAgentProvider(displayName: "Example B", endpoint: "https://example.invalid/v1",
                protocolKind: .openAIChatCompletions, modelID: "base", apiKey: "synthetic-B")
            try vault.store(account: Self.providerListAccount, secret: JSONEncoder().encode(OldCatalog(providers: [a,b], selectedProviderID: b.profile.id)))
            fixture.reloadProviders()
            guard fixture.accounts.count == 2, fixture.selectedModelID == b.model.id else { return false }
            let second = ModelProfile(providerID: a.profile.id, remoteModelID: "vision", displayName: "Vision",
                                      limits: a.model.limits, capabilities: [.text, .vision])
            guard fixture.addProviderModel(providerID: a.profile.id, model: second), fixture.selectDefaultModel(second.id),
                  !fixture.addProviderModel(providerID: a.profile.id, model: second),
                  fixture.updateProviderOptions(providerID: a.profile.id, modelID: second.id, enabled: true, compatibility: true,
                    headers: ["X-Project": "fixture"], displayName: "Vision review", hidden: true, omitReasoning: true)
            else { return false }
            var stored = try fixture.loadProviderStore()
            guard stored.accounts.count == 2, stored.accounts[0].models.count == 2, stored.selectedModelID != second.id,
                  stored.accounts[0].models.last?.displayName == "Vision review", stored.accounts[0].apiKey == "synthetic-A",
                  stored.accounts[0].profile.nonSecretHeaders == ["X-Project": "fixture"],
                  stored.accounts[1].apiKey == "synthetic-B", stored.accounts[1].profile.nonSecretHeaders.isEmpty,
                  fixture.setProviderModelEnabled(modelID: second.id, enabled: false),
                  fixture.removeProviderModel(modelID: second.id), fixture.removeProviderModel(modelID: a.model.id)
            else { return false }
            stored = try fixture.loadProviderStore()
            guard stored.accounts.count == 2, stored.accounts[0].models.isEmpty, stored.selectedModelID == b.model.id,
                  fixture.addProviderModel(providerID: a.profile.id, model: second), fixture.removeProvider(id: a.profile.id),
                  fixture.removeProvider(id: b.profile.id) else { return false }
            fixture.reloadProviders()
            guard fixture.accounts.isEmpty, fixture.selectedModelID == nil,
                  fixture.addProvider(name: "Empty", endpoint: a.profile.baseURL.absoluteString, protocolKind: .openAIChatCompletions,
                                      modelID: "", key: "synthetic-C"), let empty = fixture.accounts.first, empty.models.isEmpty,
                  fixture.addProviderModel(providerID: empty.id, model: second),
                  fixture.updateProvider(id: empty.id, name: "Renamed", endpoint: a.profile.baseURL.absoluteString,
                      protocolKind: .openAIChatCompletions, modelID: second.remoteModelID, key: "synthetic-D",
                      supportsImages: true, editingModelID: second.id) else { return false }
            let saved = try fixture.loadProviderStore()
            guard saved.accounts.count == 1, saved.accounts.first?.apiKey == "synthetic-D",
                  saved.accounts.first?.models.first?.id == second.id, saved.accounts.first?.name == "Renamed",
                  saved.selectedModelID == second.id,
                  fixture.addProvider(name: "Alternate", endpoint: "https://example.invalid/v1",
                    protocolKind: .openAIChatCompletions, modelID: "alternate", key: "synthetic-alternate"),
                  let alternate = fixture.accounts.last, let alternateModel = alternate.models.first,
                  fixture.selectedModelID == second.id, fixture.selectComposerModel(alternateModel.id),
                  try fixture.configuration()?.model.id == alternateModel.id,
                  try fixture.loadProviderStore().selectedModelID == second.id,
                  fixture.removeProvider(id: alternate.id),
                  fixture.addProvider(name: "Studio", endpoint: ProviderPreset.volcengineArk.defaultBaseURL.absoluteString,
                    protocolKind: .openAIChatCompletions, modelID: "test-image", key: "synthetic-media",
                    presetID: ProviderTemplateID.volcengineArk.rawValue, role: .image),
                  let studio = fixture.accounts.last, let image = studio.models.first,
                  studio.profile.kind == .volcengineArk, image.supportsImageGenerationSurface,
                  !image.supportsChatAgentSurface, !fixture.selectDefaultModel(image.id)
            else { return false }
            var video = ModelProfile(providerID: studio.id, remoteModelID: "test-video", displayName: "Video",
                                     limits: image.limits, capabilities: [.text])
            ProviderCatalogServiceRole.video.configureNewModel(&video)
            guard fixture.addProviderModel(providerID: studio.id, model: video),
                  fixture.setProviderModelEnabled(modelID: image.id, enabled: false),
                  fixture.updateProvider(id: studio.id, name: "Studio", endpoint: studio.profile.baseURL.absoluteString,
                      protocolKind: studio.profile.wireProtocol, modelID: image.remoteModelID, key: studio.apiKey,
                      presetID: studio.presetID, editingModelID: image.id),
                  fixture.setAccountEnabled(id: studio.id, enabled: false),
                  fixture.updateProviderAccount(id: studio.id, name: "Media", endpoint: studio.profile.baseURL.absoluteString,
                      protocolKind: studio.profile.wireProtocol, key: studio.apiKey, presetID: studio.presetID,
                      allowsPlainHTTP: false)
            else { return false }
            fixture.reloadProviders()
            guard let reloaded = fixture.accounts.first(where: { $0.id == studio.id }),
                  reloaded.name == "Media", reloaded.apiKey == studio.apiKey, reloaded.initialRole == .image,
                  !reloaded.profile.isEnabled, reloaded.models.count == 2,
                  reloaded.models.contains(where: { $0.id == image.id && !$0.isEnabled && $0.supportsImageGenerationSurface }),
                  reloaded.models.contains(where: { $0.id == video.id && $0.isEnabled && $0.supportsVideoGenerationSurface }),
                  !reloaded.models.contains(where: { $0.supportsChatAgentSurface || $0.supportsGeneralAuxiliaryLLM }),
                  fixture.setAccountEnabled(id: studio.id, enabled: true)
            else { return false }
            guard fixture.selectedModelID == second.id,
                  fixture.setAccountEnabled(id: empty.id, enabled: false), fixture.selectedModelID == nil,
                  !fixture.selectDefaultModel(second.id), !fixture.selectDefaultModel(video.id),
                  fixture.setAccountEnabled(id: empty.id, enabled: true), fixture.selectedModelID == second.id
            else { return false }
            var legacyMedia = second
            legacyMedia.id = UUID()
            legacyMedia.remoteModelID = "legacy-media-as-text"
            guard fixture.addProviderModel(providerID: studio.id, model: legacyMedia),
                  fixture.assignMediaRole(.image, to: legacyMedia.id, providerID: studio.id),
                  let adopted = fixture.providers.first(where: { $0.model.id == legacyMedia.id })
            else { return false }
            return adopted.model.supportsImageGenerationSurface && !adopted.canSelectAsPrimary && fixture.selectedModelID == second.id
        } catch { return false }
    }

    func verifyAuxiliaryModelsSmoke(endpoint: URL, showConfiguredModels: @MainActor () async -> Void) async -> Bool {
        guard vault == nil, let runtime, !isSending, endpoint.host == "127.0.0.1",
              var primary = try? HostAgentProvider(endpoint: endpoint.absoluteString, protocolKind: .openAIChatCompletions,
                  modelID: "task-primary", apiKey: "fixture-primary", allowsPlainHTTP: true),
              var helper = try? HostAgentProvider(endpoint: endpoint.absoluteString, protocolKind: .openAIChatCompletions,
                  modelID: "task-helper", apiKey: "fixture-helper", supportsImages: true, allowsPlainHTTP: true)
        else { return false }
        let original = providers
        let originalAccounts = accounts
        let originalText = auxiliaryPreferences.generalAuxiliaryLLMModelID
        let originalVision = auxiliaryPreferences.visionModelID
        defer {
            providers = original
            accounts = originalAccounts
            setAuxiliaryModel(originalText, for: .text)
            setAuxiliaryModel(originalVision, for: .vision)
        }
        primary.profile.nonSecretHeaders = ["X-Floe-Route": "primary"]
        helper.profile.nonSecretHeaders = ["X-Floe-Route": "helper"]
        var second = primary
        second.model = ModelProfile(providerID: primary.profile.id, remoteModelID: "task-fast",
                                    displayName: "Fast project model", limits: primary.model.limits, capabilities: [.text])
        providers = [primary, second, helper]
        var group = HostProviderAccount(primary)
        group.models.append(second.model)
        accounts = [group, HostProviderAccount(helper)]
        setAuxiliaryModel(nil, for: .text)
        guard auxiliaryText(for: primary.binding())?.model.id == primary.model.id else { return false }
        setAuxiliaryModel(helper.model.id, for: .text)
        setAuxiliaryModel(helper.model.id, for: .vision)
        setAuxiliaryModel(primary.model.id, for: .vision)
        guard selectedAuxiliary(.vision)?.model.id == helper.model.id,
              let data = preferences.data(forKey: Self.auxiliaryPreferencesKey),
              let stored = try? JSONDecoder().decode(ModelSelectionPreferences.self, from: data),
              stored.generalAuxiliaryLLMModelID == helper.model.id, stored.visionModelID == helper.model.id
        else { return false }
        await showConfiguredModels()
        await select(nil)
        selectComposerModel(primary.model.id)
        guard send("Summarize the project notes") else { return false }
        let deadline = ContinuousClock.now + .seconds(12)
        while (isSending || !namingTasks.isEmpty) && ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(35))
        }
        guard let id = selectedID, !isSending,
              messages.last?.content == "Summary from primary",
              conversations.first(where: { $0.id == id })?.title == "Project Notes",
              await changeConversationMetadata(id: id, change: .rename("My project")),
              (try? await runtime.saveAutomaticTitle("Late title", conversationID: id)) == false
        else { return false }
        return (try? await runtime.conversations().first(where: { $0.id == id })?.title) == "My project"
    }

    func verifyConversationHistorySmoke(reference: URL) async -> Bool {
        guard vault == nil, let runtime, let id = selectedID, !isSending,
              let config = try? HostAgentProvider(endpoint: "https://example.invalid/v1",
                  protocolKind: .openAIChatCompletions, modelID: "mac-smoke", apiKey: "") else { return false }
        var stage = "seed"
        defer {
            if stage != "complete" {
                smokeRunDiagnostics.append("Shared history fixture failed at \(stage), loaded=\(messages.count), earlier=\(hasEarlierMessages).")
            }
        }
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
            stage = "latest page"
            await select(id)
            guard messages.count == ThreadHistoryPager.latestMessageWindow, hasEarlierMessages else { return false }
            stage = "transcript export"
            let transcript = try await transcript(conversationID: id)
            let exported = MacWorkspaceRootView.markdownTranscript(name: "Fixture", messages: transcript)
            let plain = MacWorkspaceRootView.readableTranscript(name: "Fixture", messages: transcript, markdown: false)
            let structured = reference.deletingLastPathComponent().appendingPathComponent("export-" + UUID().uuidString + ".jsonl")
            defer { try? FileManager.default.removeItem(at: structured) }
            try await exportStructuredConversation(conversationID: id, to: structured)
            let rows = try String(contentsOf: structured, encoding: .utf8).split(separator: "\n")
            guard plain.hasPrefix("Fixture\n"), plain.contains("Fixture earlier message 0"),
                  let first = rows.first, let last = rows.last,
                  let manifest = try JSONSerialization.jsonObject(with: Data(first.utf8)) as? [String: Any],
                  let completed = try JSONSerialization.jsonObject(with: Data(last.utf8)) as? [String: Any],
                  manifest["conversationID"] as? String == id.uuidString,
                  completed["messageCount"] as? Int == transcript.count else { return false }

            guard transcript.count == 107, let earliest = transcript.first,
                  exported.contains("Fixture earlier message 0\n"),
                  exported.contains("Synthetic persisted reply.") else { return false }
            stage = "legacy messages before newer runs"
            let latestTimeline = ThreadTimelineBuilder.buildConversation(messages: messages, runs: transcriptRuns,
                eventsByRun: transcriptEventsByRun, liveRunID: nil, isRunning: false,
                liveStreamedText: "", liveReasoningText: "", pendingApprovals: [])
            guard let oldestLoaded = messages.first,
                  latestTimeline.first?.id == "assistant.\(oldestLoaded.id.uuidString)",
                  case .terminal? = latestTimeline.last else { return false }
            stage = "exact search"
            let search = ThreadSearchModel(
                provider: { await self.searchTranscript($0, in: id) },
                reveal: { await self.revealMessage($0.messageID, in: id) }
            )
            search.begin()
            search.query = "\"Fixture earlier message 0\""
            await search.retry()
            guard search.hits.map(\.id) == [earliest.id], search.focusedMessageID == earliest.id,
                  search.errorText == nil, messages.first?.id == earliest.id,
                  messages.count < transcript.count, hasEarlierMessages else { return false }
            stage = "close find"
            search.end()
            guard search.hits.isEmpty, search.focusedMessageID == nil else { return false }
            stage = "earlier pages"
            let beforeFirstPage = messages.count
            await loadEarlierMessages()
            guard messages.count == beforeFirstPage + ThreadHistoryPager.earlierMessageWindow else { return false }
            for _ in 0..<3 where hasEarlierMessages {
                await loadEarlierMessages()
            }
            guard messages.map(\.id) == transcript.map(\.id), !hasEarlierMessages,
                  let attachment = stageAttachments([reference]).first else { return false }
            stage = "send with history open"
            let provider = FloeMacSelfProviderBinding(provider: config.profile, model: config.model,
                                                      adapter: SmokeChatAdapter(expectedAttachmentText: "Synthetic attachment"),
                                                      credentials: .init())
            guard beginSend("Fixture follow-up", runtime: runtime, provider: provider), await waitForSmokeRun(),
                  messages.count == 109, messages.first?.id == transcript.first?.id,
                  messages.contains(where: { $0.content == "Fixture follow-up" }),
                  messages.last?.content == "Synthetic persisted reply." else { return false }
            stage = "reopen the attachment"
            await select(nil)
            await select(id)
            var resolved: URL?
            await withSavedAttachment(id: attachment.id, conversationID: id) { resolved = $0 }
            guard resolved?.standardizedFileURL == reference.standardizedFileURL,
                  messages.contains(where: { $0.parts.contains(where: { $0.attachmentID == attachment.id }) }) else {
                return false
            }
            stage = "complete"
            return true
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
        var reply = "Synthetic persisted reply."

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
                let reply = received ? self.reply : "Required attachment absent."
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

    private struct SmokeApprovalReviewer: ProviderAdapter {
        let protocolKind: ModelProtocol = .openAIChatCompletions
        let modelID: UUID

        func stream(request: ProviderStreamRequest, credentials: ProviderCredentials) -> AsyncThrowingStream<AgentEvent, Error> {
            AsyncThrowingStream { stream in
                guard request.model.id == modelID, request.toolSchemas.isEmpty, !request.messages.isEmpty else {
                    stream.finish(throwing: CocoaError(.fileReadUnknown)); return
                }
                stream.yield(.textDelta(.init(text: #"{"decision":"deny","reason":"fixture reviewer decision"}"#)))
                stream.yield(.completed(.init(stopReason: .endTurn)))
                stream.finish()
            }
        }

        func listModels(provider: ProviderProfile, credentials: ProviderCredentials) async throws -> [ModelProfile] { [] }
    }

    func verifyApprovalReviewerSmoke() async -> Bool {
        guard vault == nil, let saved = try? HostAgentProvider(endpoint: "https://example.invalid/v1",
                  protocolKind: .openAIChatCompletions, modelID: "approval-fixture", apiKey: ""),
              saved.model.supportsApprovalSurface,
              let call = try? ToolCall(id: "review-fixture", toolName: "fixture.sensitive", argumentsJSON: Data("{}".utf8), scope: .local)
        else { return false }
        let action = ProposedAction(toolCall: call, riskLabels: ["accessesCredentials"], userGoal: "Inspect this action",
                                    hostAndPathScope: .local)
        let binding = FloeMacSelfProviderBinding(provider: saved.profile, model: saved.model,
            adapter: SmokeApprovalReviewer(modelID: saved.model.id), credentials: .init())
        let configured = MacTaskApprovalPolicy.make(mode: .automatic, reviewer: binding, primaryIsOnDevice: false, isOffline: false)
        let missing = MacTaskApprovalPolicy.make(mode: .automatic, reviewer: nil, primaryIsOnDevice: false, isOffline: false)
        guard case .deny = try? await configured.decide(action),
              case .escalateToHuman = try? await missing.decide(action) else { return false }
        return true
    }

    func verifyTaskPermissionSmoke(project: WorkspaceRecord, folder: URL) async -> Bool {
        guard vault == nil, !isSending, let runtime else { return false }
        await select(nil)
        guard await setApprovalMode(.ask, asDefault: true),
              let provider = smokeProvider(.createFile("permission-live.txt")),
              beginSend("Create permission-live.txt", runtime: runtime, provider: provider,
                        workspaceID: project.id, mode: .agent) else { return false }
        let deadline = ContinuousClock.now + .seconds(6)
        while pendingApproval == nil && isSending && ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(30))
        }
        guard pendingApproval?.path == "permission-live.txt", let original = selectedID,
              await setApprovalMode(.automatic, asDefault: false),
              await waitForSmokeRun(),
              (try? String(contentsOf: folder.appendingPathComponent("permission-live.txt"), encoding: .utf8)) == "Synthetic workspace output.",
              defaultApprovalMode == .ask else { stop(); return false }

        await select(nil)
        guard taskApprovalMode == .ask, await setApprovalMode(.automatic, asDefault: true),
              taskApprovalMode == .automatic,
              let next = smokeProvider(.createFile("permission-default.txt")),
              beginSend("Create permission-default.txt", runtime: runtime, provider: next,
                        workspaceID: project.id, mode: .agent), await waitForSmokeRun(),
              let second = selectedID, second != original,
              (try? String(contentsOf: folder.appendingPathComponent("permission-default.txt"), encoding: .utf8)) == "Synthetic workspace output.",
              await setApprovalMode(.ask, asDefault: true) else { stop(); return false }
        await select(original)
        guard taskApprovalMode == .automatic, await setApprovalMode(.ask, asDefault: false),
              (try? await runtime.taskApprovalMode(conversationID: original)) == .ask else { return false }
        await select(second)
        guard taskApprovalMode == .automatic, defaultApprovalMode == .ask else { return false }
        smokeOwnerAuthentication = { false }
        defer { smokeOwnerAuthentication = nil }
        guard !(await setApprovalMode(.fullAccess, asDefault: false)),
              (try? await runtime.taskApprovalMode(conversationID: second)) == .automatic else { return false }
        smokeOwnerAuthentication = { true }
        guard await setApprovalMode(.fullAccess, asDefault: false),
              let full = smokeProvider(.createFile("permission-full.txt")),
              beginSend("Create permission-full.txt", runtime: runtime, provider: full, mode: .agent),
              await waitForSmokeRun(),
              (try? String(contentsOf: folder.appendingPathComponent("permission-full.txt"), encoding: .utf8)) == "Synthetic workspace output.",
              (try? await runtime.taskApprovalMode(conversationID: second)) == .fullAccess else { stop(); return false }
        return await setApprovalMode(.ask, asDefault: false)
    }

    func verifySavedFilePermissionSmoke(project: WorkspaceRecord, folder: URL) async -> Bool {
        guard vault == nil, !isSending, let runtime else { return false }
        await select(nil)
        let path = "permission-remember.txt"
        let original = Data("before\nkeep\n".utf8)
        let url = folder.appendingPathComponent(path)
        func startEdit() -> Bool {
            guard let provider = smokeProvider(.replaceText(path, FloeDigest.sha256Hex(original))) else { return false }
            return beginSend("Edit " + path, runtime: runtime, provider: provider,
                             workspaceID: selectedID == nil ? project.id : nil, mode: .agent)
        }
        func waitForCard() async -> HostAgentApproval? {
            let deadline = ContinuousClock.now + .seconds(5)
            while pendingApproval == nil && isSending && ContinuousClock.now < deadline {
                try? await Task.sleep(for: .milliseconds(25))
            }
            return pendingApproval
        }
        do {
            try original.write(to: url, options: .withoutOverwriting)
            guard startEdit(), let card = await waitForCard(), card.path == path else { stop(); return false }
            let owner = card.conversationID
            await resolveApproval(card, allow: true, remember: .task)
            guard await waitForSmokeRun(), try String(contentsOf: url, encoding: .utf8) == "after\nkeep\n" else { return false }
            await select(nil)
            await select(owner)
            try original.write(to: url, options: .atomic)
            guard startEdit(), await waitForSmokeRun(),
                  try String(contentsOf: url, encoding: .utf8) == "after\nkeep\n" else { stop(); return false }
            await select(nil)
            try original.write(to: url, options: .atomic)
            guard startEdit(), let different = await waitForCard(), different.conversationID != owner else { stop(); return false }
            await resolveApproval(different, allow: true, remember: .workspace)
            guard await waitForSmokeRun() else { return false }
            await select(nil)
            try original.write(to: url, options: .atomic)
            guard startEdit(), await waitForSmokeRun(),
                  try String(contentsOf: url, encoding: .utf8) == "after\nkeep\n" else { stop(); return false }
            let grants = try await approvalGrantStore()
            let saved = try await grants.list(workspaceID: project.id).filter { $0.path == path }
            guard saved.count == 2 else { return false }
            for grant in saved { try await grants.revoke(id: grant.id) }
            guard try await grants.list(workspaceID: project.id).allSatisfy({ $0.path != path }) else { return false }
            await select(owner)
            try original.write(to: url, options: .atomic)
            guard startEdit(), let revoked = await waitForCard(), revoked.conversationID == owner else { stop(); return false }
            await resolveApproval(revoked, allow: false)
            _ = await waitForSmokeRun()
            return try Data(contentsOf: url) == original
        } catch { stop(); return false }
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

    func startNamedAgentFixture(_ prompt: String, modelID: String, endpoint: URL, projectID: UUID?,
                                mode: HostAgentMode = .agent) -> Bool {
        guard vault == nil, isReady, !isSending, let runtime, endpoint.scheme == "http", endpoint.host == "127.0.0.1",
              let profile = try? HostAgentProvider(endpoint: endpoint.absoluteString, protocolKind: .openAIChatCompletions,
                                                   modelID: modelID, apiKey: "", supportsTools: true, allowsPlainHTTP: true)
        else { return false }
        return beginSend(prompt, runtime: runtime, provider: profile.binding(), workspaceID: projectID, mode: mode)
    }

    func configureCheckpointFixtureModel(run: RunRecord, endpoint: URL) -> Bool {
        guard vault == nil, endpoint.scheme == "http", endpoint.host == "127.0.0.1",
              let providerID = run.providerID, let modelID = run.modelID,
              var fixture = try? HostAgentProvider(endpoint: endpoint.absoluteString, protocolKind: .openAIChatCompletions,
                  modelID: "recovery-fixture", apiKey: "", supportsTools: true, allowsPlainHTTP: true) else { return false }
        fixture.profile.id = providerID
        fixture.model.id = modelID
        fixture.model.providerID = providerID
        providers = [fixture]
        selectedProviderID = providerID
        selectedModelID = modelID
        return composerProvider?.model.id == modelID
    }

    func latestRecoveryFixtureRun() async -> RunRecord? {
        guard vault == nil, let runtime, let selectedID else { return nil }
        return try? await runtime.recentRuns(conversationID: selectedID, limit: 1).first
    }

    func recoveryFixtureState() async -> [String: String] {
        guard vault == nil, let runtime, let run = await latestRecoveryFixtureRun() else { return [:] }
        let checkpoint = try? await runtime.recoveryPoint(runID: run.id)
        let admission = try? await runtime.admissionRecord(conversationID: run.conversationID)
        let route = try? await runtime.continuation(after: run.id, in: run.conversationID)
        return ["run": run.state, "checkpoint": checkpoint?.state.name ?? "",
                "approvalProof": String(checkpoint?.undispatchedApproval != nil),
                "providerProof": String(checkpoint?.providerDispatchEnvelope != nil),
                "admission": admission?.phase.rawValue ?? "",
                "route": route?.needsReview == true ? "review" : route?.resumesOriginalRun == true ? "resume" : "none"]
    }

    func verifyProjectTaskWorkflowSmoke(
        project: WorkspaceRecord, folder: URL, attachment: URL, endpoint: URL,
        chooseModel: (String) async -> Bool, chooseMode: (HostAgentMode) async -> Bool, answerQuestion: () async -> Bool,
        confirm: () async -> Bool, approve: () async -> Bool,
        newProjectTask: () async -> Bool, approveSubtask: () async -> Bool
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
        let oldModelID = selectedModelID
        defer {
            providers = oldProviders
            selectedProviderID = oldProviderID
            selectedModelID = oldModelID
        }
        providers = [other, chosen]
        selectedProviderID = other.profile.id
        selectedModelID = other.model.id
        smokePlanExecuteFrame = nil
        guard await chooseModel(chosen.model.displayName), composerProvider?.model.id == chosen.model.id else {
            smokeRunDiagnostics.append("The intended model was unavailable in the composer menu.")
            return false
        }

        func exercise() async -> Bool {
            let prompt = "Use the attached brief to write and save the project acceptance report."
            let report = folder.appendingPathComponent("acceptance-report.md")
            guard await chooseMode(.chat), await chooseMode(.goal), await chooseMode(.agent),
                  await chooseMode(.plan), composerMode == .plan, composerProvider?.model.id == chosen.model.id,
                  let brief = stageAttachments([attachment]).first, brief.kind == .document,
                  send(prompt, workspaceID: selectedWorkspaceID, mode: composerMode),
                  await answerQuestion(),
                  await waitForSmokeRun(),
                  let taskID = selectedID, selectedConversationWorkspace?.id == project.id,
                  let proposal = plan, proposal.title == "Project acceptance report", proposal.status == .ready,
                  let planningRun = try? await runtime.recentRuns(conversationID: taskID, limit: 1).first,
                  planningRun.modelID == chosen.model.id, planningRun.conversationMode == "plan" else {
                smokeRunDiagnostics.append("Project task did not reach plan review with the selected model.")
                return false
            }
            guard await confirm() else {
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
                  !FileManager.default.fileExists(atPath: report.path) else {
                smokeRunDiagnostics.append("Project task did not present the correct file approval.")
                return false
            }
            guard await approve() else {
                smokeRunDiagnostics.append("Project task approval controls could not be used after sending guidance.")
                return false
            }
            guard await waitForSmokeRun(),
                  (try? String(contentsOf: report, encoding: .utf8)) == "# Acceptance\nSynthetic attachment verified.\n" else {
                smokeRunDiagnostics.append("Project task did not write the approved report.")
                return false
            }

            let queuedDeadline = ContinuousClock.now + .seconds(5)
            while !messages.contains(where: { $0.content == "Queued report summary." }) && ContinuousClock.now < queuedDeadline {
                try? await Task.sleep(for: .milliseconds(25))
            }
            await select(nil)
            await select(taskID)
            let runs = try? await runtime.recentRuns(conversationID: taskID, limit: 3)
            let owners = projectTaskMembership
            await loadVisibleToolActivity(runID: approval.runID, conversationID: taskID)
            guard let output = runToolActivity[approval.runID]?.first(where: { $0.outputPath == "acceptance-report.md" }),
                  output.outputWorkspaceID == project.id else {
                smokeRunDiagnostics.append("Saved report has no project file receipt.")
                return false
            }
            var outputURL: URL?
            withOutputFile(output) { outputURL = $0 }
            guard outputURL?.resolvingSymlinksInPath() == report.resolvingSymlinksInPath() else {
                smokeRunDiagnostics.append("Saved report receipt did not resolve in its original project.")
                return false
            }
            if CommandLine.arguments.contains("--project-question-fixture") {
                guard let center = try? await runtime.userQuestionCenter(),
                      let restored = try? await center.snapshots(conversationID: taskID, includeSettled: true),
                      let originalRun = restored.first?.runID, settledQuestions[originalRun]?.isEmpty == false,
                      restored.contains(where: { snapshot in
                    snapshot.currentQuestion == nil && snapshot.questions.contains(where: { question in
                        question.answerRecord()?.selectedOptionIDs == ["report"] && question.answerRecord()?.source == .human
                    })
                }) else {
                    smokeRunDiagnostics.append("The original project question did not retain its human answer.")
                    return false
                }
            }
            var reopenedAttachment: URL?
            await withSavedAttachment(id: brief.id, conversationID: taskID) { reopenedAttachment = $0 }
            guard selectedConversationWorkspace?.id == project.id, owners?[project.id]?.contains(taskID) == true,
                  reopenedAttachment?.standardizedFileURL == attachment.standardizedFileURL,
                  composerProvider?.model.id == chosen.model.id, plan?.status == .accepted,
                  runs?.count == 3, queuedInputs[taskID]?.isEmpty == true,
                  let next = runs?.first, next.id != approval.runID,
                  messages.contains(where: { $0.content == "Queued report summary." && $0.runID == next.id }),
                  let execution = runs?.first(where: { $0.id == approval.runID }),
                  execution.modelID == chosen.model.id, execution.id == approval.runID,
                  let message = messages.first(where: { PlanConfirmationSnapshot.from(message: $0) != nil }),
                  message.runID == execution.id,
                  messages.filter({ $0.content == "Mention the checked attachment in your reply." && $0.role == "user" && $0.runID == execution.id }).count == 1,
                  messages.contains(where: { $0.content.contains("Acceptance report saved.") }) else {
                smokeRunDiagnostics.append("Project task lost its folder, selected model, plan or attachment after reopening.")
                return false
            }
            if CommandLine.arguments.contains("--project-child-fixture") {
                guard await newProjectTask() else { return false }
                selectComposerProvider(chosen.profile.id)
                guard send("Delegate an independent project check and summarize its finding.", workspaceID: project.id,
                           mode: .agent), let review = await waitForApproval(), review.toolName == DelegateTool.name,
                      review.canAllow, await approveSubtask(), await waitForSmokeRun(),
                      let owner = selectedID, owner != taskID else {
                    smokeRunDiagnostics.append("Background work did not pass its project approval.")
                    return false
                }
                await select(nil)
                await select(owner)
                let children = await childSubagents(of: owner)
                guard children.count == 1, let child = children.first, child.status == .completed,
                      child.findings?.contains("Acceptance") == true,
                      messages.contains(where: { $0.role == "assistant" && $0.content.contains("Project check completed.") }) else {
                    smokeRunDiagnostics.append("The project subtask or its finding was missing after reopening.")
                    return false
                }
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
                        mode: .agent, acceptedPlan: confirmed), await waitForSmokeRun() else {
            return (false, false)
        }
        guard messages.first(where: { $0.id == confirmed.messageID })?.runID == confirmed.executionRunID else {
            smokeRunDiagnostics.append("The accepted-plan message did not reach the visible execution run.")
            return (false, false)
        }
        let planSaved = pendingAcceptedPlan == nil
        let criterion = "Read the saved file and verify the requested text."
        guard beginSend("Verify the project output", runtime: runtime, provider: worker,
                        mode: .goal, criterion: criterion + "\nConfirm the result."), await waitForSmokeRun(),
              let stored = goal, stored.acceptanceCriteria.map(\.text) == [criterion, "Confirm the result."],
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
              await editGoal(paused, objective: "Verify the project and report the outcome",
                             criteria: paused.acceptanceCriteria.map(\.text), blockers: ["Missing project"], stops: ["Report verified"]),
              let edited = goal, edited.status == .paused, edited.evidence == paused.evidence,
              edited.acceptanceCriteria == paused.acceptanceCriteria, edited.blockingConditions == ["Missing project"],
              edited.stoppingConditions == ["Report verified"], edited.revision != paused.revision,
              !(await editGoal(paused, objective: "Stale edit", criteria: ["Stale"], blockers: [], stops: [])),
              beginSend("Continue the fixture goal", runtime: runtime, provider: provider, mode: .goal, resumingGoal: true),
              await waitForSmokeRun(),
              let newest = try? await runtime.recentRuns(conversationID: id, limit: 1).first else { return false }
        guard newest.id != previousRun.id, newest.goalID == initial.id,
              let ready = goal, ready.id == initial.id, ready.objective == edited.objective,
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
        defer { allowsWorkspaceWrites = previous }
        guard let chat = try? MacAgentWorkspaceTools.binding(workspace: project, readOnly: false, chatOnly: true),
              chat.allowedToolNames == ["workspace.listDirectory", "workspace.searchFiles", "workspace.readFile", "web.fetch"],
              chat.executor.descriptor(named: "workspace.createFile") == nil,
              chat.executor.descriptor(named: "workspace.replaceText") == nil else { return false }
        for (tool, arguments, mode) in [
            ("workspace.searchFiles", ["query": "Synthetic attachment", "path": "fixture.md"], HostAgentMode.chat),
            ("workspace.searchFiles", ["query": "Synthetic attachment", "path": "fixture.md"], HostAgentMode.agent),
            ("workspace.readDocument", ["path": documentName], HostAgentMode.plan),
        ] {
            allowsWorkspaceWrites = mode == .chat
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

    private func waitForApproval() async -> HostAgentApproval? {
        let deadline = ContinuousClock.now + .seconds(4)
        while pendingApproval == nil && isSending && ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(25))
        }
        return pendingApproval
    }

    func verifyConcurrentTasksSmoke(project: WorkspaceRecord, folder: URL, otherProject: WorkspaceRecord,
                                    otherFolder: URL, openProjectTask: (UUID) async -> Bool) async -> Bool {
        guard vault == nil, let runtime, activeRunCount == 0 else { return false }
        let firstName = "background-approved.txt"
        let secondName = "background-stopped.txt"
        let firstFile = folder.appendingPathComponent(firstName)
        let secondFile = otherFolder.appendingPathComponent(secondName)
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

// MARK: - User questions (projection, restore, answering)
//
// The workspace owns no question state of its own: the durable store is the
// only writer and the session handle is the only answer fence. This region
// only subscribes the workbench to the runtime question center's ordered
// events, projects one card per live run, passively restores the pending
// card when a conversation is re-opened (no run resume, no provider call),
// and forwards card submit/cancel/draft actions to the exact-run session
// handle. Optional-answer next-turn delivery is runtime-owned.
extension HostAgentWorkspace {

    /// Subscribes once per runtime. The center's event order is the runtime
    /// projection first, then this host projection.
    func subscribeQuestionEvents(using runtime: FloeMacSelfRuntime) async {
        guard questionSubscription == nil, let center = try? await runtime.userQuestionCenter() else { return }
        let token = await center.subscribeEvents { [weak self] event in
            await self?.handleQuestionEvent(event)
        }
        questionSubscription = token
    }

    private func handleQuestionEvent(_ event: UserQuestionEvent) async {
        switch event {
        case .presented(let snapshot), .settled(let snapshot):
            #if FLOE_UNIFIED_MAC
            if selectedID == snapshot.conversationID { recordSettledQuestions([snapshot]) }
            #endif
            projectQuestionSnapshot(snapshot)
        case .answerAvailable(let delivery):
            // Optional-answer rows are delivered into the durable queue by
            // the runtime; the host only refreshes its queue projection.
            #if FLOE_UNIFIED_MAC
            await refreshQueue(delivery.conversationID)
            #endif
        }
    }

    private func projectQuestionSnapshot(_ snapshot: UserQuestionWaitingSnapshot) {
        if let run = liveRuns[snapshot.conversationID], run.handle?.identity.runID == snapshot.runID {
            // The live parked run stays authoritative for its own card.
            restoredQuestions[snapshot.conversationID] = nil
            if snapshot.currentQuestion == nil, run.question?.requestID != snapshot.requestID { return }
            let card = snapshot.currentQuestion == nil ? nil : HostAgentQuestion(
                conversationID: snapshot.conversationID,
                runID: snapshot.runID,
                snapshot: snapshot
            )
            if liveRuns[snapshot.conversationID]?.question != card {
                liveRuns[snapshot.conversationID]?.question = card
            }
            return
        }
        guard liveRuns[snapshot.conversationID] == nil, selectedID == snapshot.conversationID, !snapshot.isEphemeral else { return }
        // No live run: project or close the durable restored card. A settled
        // snapshot (answer, cancel, expiry or terminal fence) closes it; a
        // pending one re-presents the exact stored question.
        if snapshot.currentQuestion == nil {
            if restoredQuestions[snapshot.conversationID]?.requestID == snapshot.requestID {
                restoredQuestions[snapshot.conversationID] = nil
            }
        } else {
            restoredQuestions[snapshot.conversationID] = HostAgentQuestion(
                conversationID: snapshot.conversationID,
                runID: snapshot.runID,
                snapshot: snapshot
            )
        }
    }

    #if FLOE_UNIFIED_MAC
    private func recordSettledQuestions(_ snapshots: [UserQuestionWaitingSnapshot]) {
        for snapshot in snapshots where snapshot.currentQuestion == nil {
            var rows = settledQuestions[snapshot.runID] ?? []
            if let index = rows.firstIndex(where: { $0.requestID == snapshot.requestID }) {
                if rows[index] == snapshot { continue }
                rows[index] = snapshot
            } else {
                rows.append(snapshot)
            }
            settledQuestions[snapshot.runID] = rows.sorted { $0.createdAt < $1.createdAt }
        }
    }
    #endif

    /// Passive restored transcript: re-presenting the durable pending
    /// question for a re-opened conversation without resuming any run. This
    /// restores only for the selected task and a stable load generation, and
    /// only the durable exact question still pending for this conversation in
    /// the store (never an ephemeral row); a live parked run, when present,
    /// keeps sole ownership of the card and is left untouched here.
    func restoreQuestion(for conversationID: UUID) async {
        guard let runtime, let center = try? await runtime.userQuestionCenter() else { return }
        let selection = historySelection
        await center.restore(conversationID: conversationID)
        try? await runtime.deliverOptionalQuestionAnswers(conversationID: conversationID)
        #if FLOE_UNIFIED_MAC
        if let rows = try? await center.snapshots(conversationID: conversationID, includeSettled: true),
           selectedID == conversationID {
            recordSettledQuestions(rows)
        }
        #endif
        guard selectedID == conversationID, historySelection == selection,
              liveRuns[conversationID] == nil else { return }
        let snapshot = try? await center.pendingSnapshot(conversationID: conversationID)
        guard selectedID == conversationID, historySelection == selection, liveRuns[conversationID] == nil else { return }
        guard let snapshot, !snapshot.isEphemeral, snapshot.conversationID == conversationID,
              snapshot.currentQuestion != nil else {
            restoredQuestions[conversationID] = nil
            return
        }
        restoredQuestions[conversationID] = HostAgentQuestion(
            conversationID: snapshot.conversationID,
            runID: snapshot.runID,
            snapshot: snapshot
        )
    }

    private func refreshQuestionCard(for conversationID: UUID) async {
        guard let runtime, let center = try? await runtime.userQuestionCenter() else { return }
        guard let snapshot = try? await center.pendingSnapshot(conversationID: conversationID) else {
            if liveRuns[conversationID]?.question != nil { liveRuns[conversationID]?.question = nil }
            restoredQuestions[conversationID] = nil
            return
        }
        projectQuestionSnapshot(snapshot)
    }

    /// Submits one complete card answer. True means this exact answer settled
    /// the question in the durable store; anything else refreshes the card
    /// from durable truth and returns false so the card shows the retry copy.
    /// A live parked run keeps its session-fenced path; a restored card (no
    /// live run) settles through the same durable coordinator CAS, which
    /// re-validates exact conversation/run/request/question ownership, the
    /// expected revision, normalization and the no-secret rule.
    @discardableResult
    func answerQuestion(target: UserQuestionAnswerTarget, answer: UserQuestionAnswer) async -> Bool {
        if let handle = liveRuns[target.conversationID]?.handle, handle.identity.runID == target.runID {
            let command = FloeMacSelfQuestionAnswerCommand(
                conversationID: target.conversationID,
                runID: target.runID,
                requestID: target.requestID,
                questionID: target.questionID,
                expectedRevision: target.expectedRevision,
                answer: answer
            )
            let result = await handle.resolveQuestion(command)
            switch result {
            case .accepted:
                return true
            case .notPending(let receipt):
                await refreshQuestionCard(for: target.conversationID)
                return receipt?.accepted == true
            case .rejected(let rejection):
                if rejection == .staleQuestion || rejection == .sessionEnded
                    || rejection == .conversationMismatch || rejection == .runMismatch {
                    await refreshQuestionCard(for: target.conversationID)
                }
                return false
            }
        }
        return await answerRestoredQuestion(target: target, answer: answer)
    }

    /// Settles a restored card's answer directly through the durable CAS. The
    /// projected card must still own the exact request/run; the store then
    /// re-applies the same binding plus the CAS revision inside its
    /// transaction, so a task change or an already settled question fails
    /// closed without touching durable state.
    private func answerRestoredQuestion(target: UserQuestionAnswerTarget, answer: UserQuestionAnswer) async -> Bool {
        guard let restored = pendingQuestion, selectedID == target.conversationID, visibleRun == nil,
              restored.runID == target.runID, restored.requestID == target.requestID,
              let runtime, !isTerminating, let release = admit() else { return false }
        defer { release() }
        let selection = historySelection
        guard let center = try? await runtime.userQuestionCenter(), historySelection == selection,
              visibleRun == nil, pendingQuestion == restored else { return false }
        do {
            let receipt = try await center.submitHumanAnswer(target: target, answer: answer)
            await refreshQuestionCard(for: target.conversationID)
            return receipt.accepted
        } catch {
            await refreshQuestionCard(for: target.conversationID)
            return false
        }
    }

    func saveQuestionDraft(target: UserQuestionAnswerTarget, answer: UserQuestionAnswer) async {
        guard let runtime, let center = try? await runtime.userQuestionCenter() else { return }
        let live = liveRuns[target.conversationID]?.handle?.identity.runID == target.runID
        let restored = restoredQuestions[target.conversationID]?.runID == target.runID
            && restoredQuestions[target.conversationID]?.requestID == target.requestID
        guard live || restored else { return }
        _ = try? await center.saveDraft(target: target, draft: answer)
    }

    /// Decline cancels the whole question request for this exact run; a parked
    /// run receives the cancelled tool receipt. A restored card (no live run)
    /// cancels through the same durable coordinator; its settled event closes
    /// the card without fabricating an answer.
    func declineQuestion(requestID: String) async {
        guard let id = visibleTaskID, let question = pendingQuestion,
              question.conversationID == id, question.requestID == requestID else { return }
        if let handle = liveRuns[id]?.handle, handle.identity.runID == question.runID {
            _ = await handle.cancelQuestion(requestID: requestID)
            return
        }
        guard restoredQuestions[id]?.runID == question.runID,
              restoredQuestions[id]?.requestID == requestID,
              let runtime, !isTerminating, let release = admit() else { return }
        defer { release() }
        let selection = historySelection
        guard let center = try? await runtime.userQuestionCenter(), historySelection == selection,
              visibleRun == nil, pendingQuestion == question else { return }
        try? await center.cancelRequest(requestID: requestID)
        await refreshQuestionCard(for: id)
    }

    // MARK: - Restored question recovery semantics

    /// True while the visible question card is a durable restore with no live
    /// run behind it (relaunch/reconnect), so the UI can state its recovery
    /// semantics honestly instead of implying a parked run.
    var pendingQuestionIsRestored: Bool {
        visibleRun == nil && pendingQuestion != nil
    }

    /// Concise recovery copy for a restored card: the answer is saved durably
    /// to this task; a required answer reaches the model only through the
    /// task's own continuation, an optional answer joins the task queue once.
    var pendingQuestionRecoveryNote: String? {
        guard pendingQuestionIsRestored, let question = pendingQuestion else { return nil }
        return question.snapshot.currentQuestion?.waitPolicy == .optionalContinue
            ? String(localized: "mac.question.restored.note.optional")
            : String(localized: "mac.question.restored.note.required")
    }
}
