// FloeApp — Setup guide model.
//
// SPDX-License-Identifier: MPL-2.0
//
// Bridges the guide's pure navigation and preset rules to the services that
// already own configuration, downloads and recovery. Three rules hold
// everywhere:
//
//   1. a preset only fills a choice the user has NOT made, taken from the
//      capability metadata of models, providers and device services that
//      really exist here;
//   2. navigation and Finish never wait for a download, verification, unpack
//      or install — those jobs belong to their own services;
//   3. guide progress is separate from provider readiness, so the guide can be
//      left and resumed before any provider works, and an already-set main
//      model never ends the guide by itself.

import Foundation
import Combine
import FloeCore
import FloeExecution
import FloeModels
import FloeProviders

/// Where the user came from, kept only so the entry screen can show an honest
/// "you already did this" line. Never affects which sections appear.
enum SetupGuideEntry: Equatable, Sendable {
    case firstLaunch
    case manual
    case resumed
}

@MainActor
final class SetupGuideModel: ObservableObject {
    @Published private(set) var state = SetupGuideState()
    @Published private(set) var plan = SetupGuidePresetPlan()
    /// Routes the preset actually wrote. The picker shows this, never the
    /// planner's wish list, so "filled" can only mean a real committed change.
    @Published private(set) var appliedRoutes: [SetupGuideRoute] = []
    /// The summary is built from real service state, not from a progress bar:
    /// saved, still preparing, postponed, or needing attention.
    @Published private(set) var summary: [SetupSummaryEntry] = []
    @Published private(set) var facts = SetupGuideDeviceFacts()
    @Published private(set) var entry: SetupGuideEntry = .firstLaunch
    @Published private(set) var hasResumableProgress = false
    @Published private(set) var isPreparingResources = false
    @Published private(set) var preparingCount = 0
    @Published private(set) var attentionCount = 0
    @Published var saveMessage: String?

    let center: ConversationCenter
    let resources: SetupResourcePreparation
    private var environment: AppEnvironment { center.environment }
    private let defaults: UserDefaults
    private var presetGeneration = 0
    private var loadGeneration = 0
    private var isPresented = true
    private var summarySink: AnyCancellable?
    private var lastPublishedCounts: (preparing: Int, attention: Int) = (0, 0)

    init(center: ConversationCenter, defaults: UserDefaults = .standard) {
        self.center = center
        self.defaults = defaults
        self.resources = SetupResourcePreparation(center: center)
    }

    // MARK: - Lifecycle

    /// Loads live facts and resumes the saved position. Provider readiness is
    /// never consulted: a user who left before configuring anything still
    /// returns to the same section.
    func load(preferredEntry: SetupGuideEntry = .firstLaunch) async {
        guard !Task.isCancelled else { return }
        loadGeneration += 1
        let generation = loadGeneration
        isPresented = true
        await center.reload()
        guard loadGeneration == generation, isPresented, !Task.isCancelled else { return }
        entry = preferredEntry
        if let saved = SetupGuideProgressStore.load(from: defaults), saved.currentSection != .chatModels
            || saved.statuses.isEmpty == false {
            hasResumableProgress = true
            apply(.resumeFrom(saved))
        }
        await refreshFacts()
        guard loadGeneration == generation, isPresented, !Task.isCancelled else { return }
        resources.observe()
        // Resource counts are mirrored on a coalesced cadence, so a streaming
        // byte callback cannot re-render the whole guide twice a second.
        summarySink = resources.$rows
            .receive(on: RunLoop.main)
            .sink { [weak self] rows in
                guard let self else { return }
                let preparing = rows.filter { $0.stage.isPreparing }.count
                var attention = 0
                for row in rows { if case .failed = row.stage { attention += 1 } }
                if preparing != self.preparingCount { self.preparingCount = preparing }
                if attention != self.attentionCount { self.attentionCount = attention }
                let nowPreparing = preparing > 0
                if nowPreparing != self.isPreparingResources { self.isPreparingResources = nowPreparing }
                self.rebuildSummary()
            }
    }

    /// View teardown: unsubscribes the mirror only. Owned jobs keep running
    /// and are visible again on return.
    func stopObserving() {
        loadGeneration += 1
        isPresented = false
        summarySink = nil
        resources.stopObserving()
    }

    func refreshFacts() async {
        facts = await Self.makeFacts(center: center)
        rebuildSummary()
    }

    // MARK: - Navigation intents

    func select(preset: SetupGuidePreset) {
        presetGeneration += 1
        appliedRoutes = []
        apply(.start(preset))
        plan = SetupGuidePresetPlanner.plan(preset: preset, facts: facts)
        if preset == .voiceConversation, facts.hasAppleSpeechOutput,
           environment.ttsSettingsService.prefillConversationPreferencesIfUnset() {
            appliedRoutes = [.speechRate, .autoReadAnswers, .interruptionControl]
            apply(.setStatus(.voice, .defaulted))
        }
        if preset != .custom { applyPlanSilently() }
        rebuildSummary()
    }

    func next() { apply(.next) }
    func back() { apply(.back) }

    /// "Later" records the user's own decision, keeps the shipped behaviour
    /// and moves on. Nothing in the app may block it.
    func later() { apply(.deferCurrentSection) }

    func jump(to section: SetupGuideSection) {
        apply(.jump(section))
    }

    /// A chosen preset is remembered even when the user changes the answer
    /// later; the picker then shows the current explicit choices.
    func useSavedProgress() {
        if let saved = SetupGuideProgressStore.load(from: defaults) {
            apply(.resumeFrom(saved))
        }
    }

    func startFresh() {
        presetGeneration += 1
        appliedRoutes = []
        didFinish = false
        SetupGuideProgressStore.clear(from: defaults)
        state = SetupGuideState()
        plan = SetupGuidePresetPlan()
        rebuildSummary()
    }

    // MARK: - Status intents

    /// An explicit choice inside a section makes it the user's own; a preset
    /// can no longer touch that section.
    func markConfigured(_ section: SetupGuideSection) { apply(.setStatus(section, .configured)) }

    func markAttention(_ section: SetupGuideSection) { apply(.setStatus(section, .needsAttention)) }

    /// A mirrored preparation transition. It never blocks: it only tells the
    /// summary the truth about work still running in another service.
    func reflectPreparation(_ section: SetupGuideSection, isPreparing: Bool) {
        apply(.setPreparation(section, isPreparing))
    }

    // MARK: - Chat & model intents (existing services only)

    /// The main model choice. Selecting one never ends the guide: the user
    /// still walks every remaining section.
    func setMainModel(_ id: UUID) async {
        await center.setDefaultAgentModel(id)
        apply(.setStatus(.chatModels, .configured))
        await refreshFacts()
    }

    /// Routes one auxiliary role through the same preference writer the real
    /// auxiliary editor uses. Only the named role changes.
    func setAuxiliaryRole(_ role: SetupGuideAuxiliaryRole, modelID: UUID?) async {
        var preferences = center.modelPreferences
        switch role {
        case .vision: preferences.visionModelID = modelID
        case .generalHelper: preferences.generalAuxiliaryLLMModelID = modelID
        case .packageReview: preferences.packageReviewModelID = modelID
        case .approval: preferences.approvalModelID = modelID
        case .canvasAssistant: preferences.canvasAgentModelID = modelID
        case .canvasVision: preferences.canvasVisionModelID = modelID
        case .imageGeneration: preferences.imageGenerationModelID = modelID
        case .imageEditing: preferences.imageEditingModelID = modelID
        case .video: preferences.defaultVideoModelID = modelID
        }
        do {
            try await center.saveModelPreferences(preferences)
            apply(.setStatus(role.section, modelID == nil ? .deferred : .configured))
            saveMessage = nil
        } catch {
            saveMessage = SecretRedactor.redact(error.localizedDescription)
            apply(.setStatus(role.section, .needsAttention))
        }
        await refreshFacts()
    }

    // MARK: - Voice

    /// Remembers and prepares a voice the user picked while its pack is not
    /// installed yet. Everything goes through `TTSSettingsService`: the current
    /// playable source keeps playing until the pack is installed AND validated,
    /// the revision fence drops the intent when the user changed their mind,
    /// and nothing is substituted — no cloud fallback and no audition of a
    /// voice the user did not choose.
    ///
    /// Choosing and downloading stay two separate user actions: selecting an
    /// undownloaded voice never starts a transfer by itself.
    @discardableResult
    func choosePendingVoice(modelID: String, voiceID: String, prepare: Bool) -> Bool {
        let service = environment.ttsSettingsService
        guard let pack = service.chooseVoice(modelID: modelID, voiceID: voiceID) else {
            // Either the pack is already installed (the service applied the
            // choice immediately) or the catalog cannot serve it. Only the
            // second case needs a visible state change.
            let playable = service.localModelDescriptor(modelID) != nil
            apply(.setStatus(.voice, playable ? .configured : .needsAttention))
            return playable
        }
        apply(.setStatus(.voice, .preparing))
        persistProgress()
        if prepare { resources.prepareVoicePack(pack) }
        return true
    }

    /// Drops a remembered voice intent before it is applied. The pack and the
    /// currently playing source are untouched.
    func clearPendingVoice() {
        environment.ttsSettingsService.clearPendingVoice()
        apply(.setStatus(.voice, .unset))
        persistProgress()
    }

    // MARK: - Finish

    /// Terminal Finish. It must complete even with nothing configured: the
    /// user reviewed the sections and chose to start using Floe, and any
    /// preparation still running keeps running in its own service.
    ///
    /// Ordering matters twice over. The durable status write happens FIRST, so
    /// a failure stays actionable instead of silently claiming completion; and
    /// the guide only becomes terminal after that write succeeded, so a failed
    /// Finish leaves the user on the summary with the honest message and a
    /// working retry. The resumable record is cleared last, and only then can a
    /// relaunch avoid restoring a completed guide as work in progress.
    ///
    /// This is the guide's own outcome record. It does not touch launch
    /// gating: `ConversationCenter.reconcileOnboardingForLaunch` still decides
    /// whether the first-run sheet appears, and that file belongs to the
    /// approval owner.
    func finish() async {
        presetGeneration += 1
        var preferences = center.modelPreferences
        preferences.onboardingStatus = .completed
        preferences.updatedAt = Date()
        preferences.syncRevision += 1
        do {
            try await center.saveModelPreferences(preferences)
        } catch {
            saveMessage = SecretRedactor.redact(error.localizedDescription)
            return
        }
        saveMessage = nil
        didFinish = true
        apply(.finish)
        // A completion returning after dismissal no longer owns the progress
        // of a guide the user may already have reopened.
        if isPresented { SetupGuideProgressStore.clear(from: defaults) }
    }

    /// True only after the completion status was really written.
    @Published private(set) var didFinish = false

    /// Retries a Finish whose status write failed.
    func retryFinish() async { await finish() }

    /// Leaving mid-guide keeps the position for a later resume. A completed
    /// guide has nothing to resume, so a teardown after Finish never writes a
    /// fresh record that would reopen it as work in progress.
    func exitAndKeepProgress() {
        guard !didFinish, !state.finished else { return }
        // Explicit teardown owns this one snapshot; later async callbacks do
        // not get to persist another copy after the page has left.
        SetupGuideProgressStore.save(progressSnapshot, to: defaults)
    }

    var progressSnapshot: SetupGuideProgress {
        var progress = SetupGuideReducer.progress(from: state)
        progress.pendingVoiceModelID = resources.pendingVoiceModelID
        return progress
    }

    // MARK: - Preset application

    /// Writes only the routes the planner proved are unset, supported and
    /// consent-free, each into its OWN preference slot, and re-checks every
    /// slot against the live values at the save boundary. A choice the user
    /// made while the preset was being applied therefore always wins, and a
    /// route is reported as filled only when the write really happened.
    private func applyPlanSilently() {
        guard state.preset != .custom, !plan.prefilled.isEmpty else { return }
        let intents: [SetupGuidePrefillIntent] = plan.prefilled.compactMap { route in
            guard let id = SetupGuidePresetPlanner.resolvedModelID(for: route, facts: facts)
            else { return nil }
            return SetupGuidePrefillIntent(route: route, modelID: id)
        }
        guard !intents.isEmpty else { return }
        let generation = presetGeneration
        Task { [weak self] in
            guard let self, self.presetGeneration == generation, !self.didFinish else { return }
            // Live re-read at the boundary: the facts the plan was made from
            // are already history by the time this runs.
            await self.center.reload()
            guard self.presetGeneration == generation, !self.didFinish else { return }
            var preferences = self.center.modelPreferences
            let enabledProviderIDs = Set(self.center.providers.filter(\.isEnabled).map(\.id))
            let liveModels = self.center.configuredModelsByProvider.values.flatMap { $0 }
            let isUsable: (UUID, SetupGuideModelCapability) -> Bool = { id, capability in
                guard let model = liveModels.first(where: { $0.id == id }),
                      model.isEnabled,
                      enabledProviderIDs.contains(model.providerID) else { return false }
                switch capability {
                case .chat:
                    return model.supportsChatAgentSurface && model.isVisibleInPrimaryPicker
                case .vision:
                    return model.capabilities.contains(.vision)
                case .toolCalling:
                    return model.capabilities.contains(.tools)
                case .approval:
                    return model.supportsApprovalSurface
                case .generalAuxiliary:
                    return model.supportsGeneralAuxiliaryLLM
                case .imageGeneration:
                    return model.supportsImageGenerationSurface
                        && model.capabilities.contains(.imageGeneration)
                case .imageEditing:
                    return model.supportsImageGenerationSurface
                        && model.capabilities.contains(.imageEditing)
                case .videoGeneration:
                    return model.supportsVideoGenerationSurface
                }
            }
            let applied = SetupGuidePrefillWriter.apply(
                intents, to: &preferences, isUsable: isUsable
            )
            guard !applied.isEmpty else { return }
            preferences.updatedAt = Date()
            preferences.syncRevision += 1
            do {
                try await self.center.saveModelPreferences(preferences)
            } catch {
                guard self.presetGeneration == generation, self.isPresented, !self.didFinish else { return }
                self.saveMessage = SecretRedactor.redact(error.localizedDescription)
                // The model choices were not committed. Independently saved
                // voice defaults remain part of the actual applied choices.
                return
            }
            guard self.presetGeneration == generation, self.isPresented, !self.didFinish else { return }
            self.saveMessage = nil
            self.appliedRoutes += applied.filter { !self.appliedRoutes.contains($0) }
            for route in applied where self.state.status(for: route.section) == .unset {
                self.apply(.setStatus(route.section, .defaulted))
            }
            await self.refreshFacts()
        }
    }

    // MARK: - Helpers

    private func apply(_ action: SetupGuideAction) {
        SetupGuideReducer.reduce(&state, action)
        persistProgress()
        rebuildSummary()
    }

    private func persistProgress() {
        // A completed guide is terminal: no late refresh, status mirror or
        // teardown callback may resurrect it as unfinished work.
        guard isPresented, !didFinish else { return }
        SetupGuideProgressStore.save(progressSnapshot, to: defaults)
    }

    private func rebuildSummary() {
        summary = SetupGuideSummaryBuilder.entries(state: state, resources: resources.rows)
    }

    /// Kept for the view's explicit refresh calls; the Combine mirror above is
    /// what normally updates the summary.
    func scheduleSummaryRefresh() { rebuildSummary() }

    // MARK: - Live facts

    /// Reads the real configuration. Every capability claim comes from stored
    /// model metadata or a shipped adapter contract, never from a name match.
    static func makeFacts(center: ConversationCenter) async -> SetupGuideDeviceFacts {
        let environment = center.environment
        var facts = SetupGuideDeviceFacts()
        let preferences = center.modelPreferences
        let enabledProviderIDs = Set(center.providers.filter(\.isEnabled).map(\.id))
        let allModels = center.configuredModelsByProvider.values.flatMap { $0 }
        facts.models = allModels.filter { $0.isEnabled && enabledProviderIDs.contains($0.providerID) }
            .map { model in
                SetupGuideModelFact(
                    id: model.id,
                    displayName: model.displayName,
                    hasChat: model.supportsChatAgentSurface,
                    hasVision: model.capabilities.contains(.vision),
                    hasTools: model.capabilities.contains(.tools),
                    hasApproval: model.supportsApprovalSurface,
                    hasGeneralAuxiliary: model.supportsGeneralAuxiliaryLLM,
                    hasImageGeneration: model.supportsImageGenerationSurface,
                    hasImageEditing: model.supportsImageGenerationSurface
                        && model.capabilities.contains(.imageEditing),
                    hasVideoGeneration: model.supportsVideoGenerationSurface,
                    visibleInPicker: model.isVisibleInPrimaryPicker,
                    isDefaultAgent: model.id == preferences.defaultAgentModelID
                )
            }
        facts.hasUsableChatModel = !center.availableAgentModels.isEmpty
        facts.hasVisionModel = !center.visionModels.isEmpty
        facts.imageCapableModelCount = center.imageModels.count
        facts.videoCapableModelCount = center.videoModels.count
        facts.approvalCapableModelCount = center.approvalModels.count
        facts.hasGeneralHelperModel = !allModels.filter {
            $0.isEnabled && enabledProviderIDs.contains($0.providerID)
                && $0.supportsGeneralAuxiliaryLLM
        }.isEmpty
        facts.defaultAgentModelID = preferences.defaultAgentModelID
        facts.visionModelID = preferences.visionModelID
        facts.generalHelperModelID = preferences.generalAuxiliaryLLMModelID
        facts.packageReviewModelID = preferences.packageReviewModelID
        facts.approvalModelID = preferences.approvalModelID
        facts.canvasAssistantModelID = preferences.canvasAgentModelID
        facts.canvasVisionModelID = preferences.canvasVisionModelID
        facts.hasConfiguredProvider = center.hasConfiguredProvider
        facts.hasConfiguredImageModel = preferences.imageGenerationModelID != nil
            || preferences.sharedImageModelID != nil
        facts.hasConfiguredVideoModel = preferences.defaultVideoModelID != nil

        let search = environment.webSearchSettingsCenter
        let usable = search.instances.filter {
            $0.configuration.enabled
                && search.hasCredential(account: $0.configuration.credentialAccount)
        }
        facts.hasConfiguredSearchProvider = !usable.isEmpty
        facts.searchProviderCount = usable.count

        let speech = environment.ttsSettingsService
        facts.hasAppleSpeechOutput = speech.outputSources.contains { $0.id == "system" }
        facts.installedVoicePackIDs = Array(speech.localInstalledModelIDs).sorted()
        facts.availableVoicePackIDs = speech.localVisibleModels.map(\.id)
        facts.hasCloudSpeechCredential = speech.configuredProfiles.contains {
            speech.hasCredential(for: $0)
        }
        facts.hasSelectedVoicePack = speech.snapshot.modelID.isEmpty == false
        facts.enhancedRecognitionInstalled = await WhisperModelStore.shared.isInstalled()

        let settings = environment.settingsCenter
        facts.workspaces = settings.workspaces.filter { $0.kind == .project }.map(\.name)
        facts.defaultWorkspaceName = settings.defaultWorkspaceID.flatMap { id in
            settings.workspaces.first { $0.id == id }?.name
        }
        facts.hasSavedRemoteHost = settings.remoteHostCount > 0
        facts.gitRepositoryCount = environment.sourceControlCenter.repositories.count
        // Availability is the shipped pinned runtime entry, never a name
        // guess: an image this App cannot install is never offered.
        facts.supportsLocalRuntime = LinuxGuestImageDistributionCatalog
            .entry(id: LinuxGuestImageDistributionCatalog.defaultImageID) != nil
        facts.memoryProfilePresent = environment.memoryCenter.profile != nil
        facts.memorySoulPresent = environment.memoryCenter.soul != nil
        if case .available = settings.iCloudDrive { facts.cloudSyncAvailable = true }
        facts.cloudSyncEnabled = settings.overallSyncEnabled
        facts.answerReviewEnabled = settings.verifyFinalAnswer
        if speech.hasSavedPlaybackPreferences {
            facts.autoReadEnabled = speech.snapshot.autoReadEnabled
            facts.interruptionAllowed = speech.snapshot.allowBargeIn
            facts.speechRateRatio = speech.snapshot.speechRateRatio
        }
        facts.contentAutoUpdate = environment.contentUpdateCenter.autoUpdateDeclarativeContent
        return facts
    }
}

/// The auxiliary roles the guide can route. Each maps to an existing
/// preference the real editors already write — no new role is invented.
enum SetupGuideAuxiliaryRole: String, CaseIterable, Identifiable, Sendable {
    case vision
    case generalHelper
    case packageReview
    case approval
    case canvasAssistant
    case canvasVision
    case imageGeneration
    case imageEditing
    case video

    var id: String { rawValue }

    /// Where the role belongs in the product flow. The general helper and the
    /// package reviewer stay with answers; vision, media and Canvas stay with
    /// creation; the reviewer model stays with permissions.
    var section: SetupGuideSection {
        switch self {
        case .vision, .canvasAssistant, .canvasVision, .imageGeneration, .imageEditing, .video:
            .creation
        case .generalHelper, .packageReview:
            .chatModels
        case .approval:
            .permissions
        }
    }

    var titleKey: String { "setup.role.\(rawValue)" }
    var detailKey: String { "setup.role.\(rawValue).detail" }
}
