// FloeApp — Setup guide presets.
//
// SPDX-License-Identifier: MPL-2.0
//
// A preset is a starting point, not a shortcut. Four optional presets and
// Custom all walk the SAME ten product sections in the SAME order; a preset
// may only pre-fill a choice the user has not made yet, and only from the
// capability metadata of models, providers and device services that really
// exist here. A preset never skips a section, never resets an existing
// decision, never starts a download, never spends credit, never asks for a
// system permission and never turns on advanced background running by itself.

import Foundation

/// The selectable starting points. `custom` pre-fills nothing.
enum SetupGuidePreset: String, CaseIterable, Identifiable, Codable, Equatable, Sendable {
    case lightStart
    case everyday
    case voiceConversation
    case developmentCreation
    case custom

    var id: String { rawValue }
    var titleKey: String { "setup.preset.\(rawValue)" }
    var detailKey: String { "setup.preset.\(rawValue).detail" }

    /// Highlighted as the everyday suggestion on first display only; always
    /// changeable, never forced.
    static var recommended: SetupGuidePreset { .everyday }

    var systemImage: String {
        switch self {
        case .lightStart: "feather"
        case .everyday: "sparkles"
        case .voiceConversation: "mic"
        case .developmentCreation: "hammer"
        case .custom: "slider.horizontal.3"
        }
    }

    /// What this preset would like to set up, in order. Entries the device
    /// cannot serve, or that the user already decided, drop out of the plan;
    /// the section list never changes.
    var desiredRoutes: [SetupGuideRoute] {
        switch self {
        case .lightStart:
            return [.chatModel, .generalHelper, .searchProvider, .systemVoice,
                    .interruptionControl]
        case .everyday:
            return [.chatModel, .generalHelper, .visionHelper, .canvasHelper, .searchProvider,
                    .systemVoice, .autoReadAnswers, .interruptionControl, .memoryPersonalization,
                    .deviceSync, .keepContentCurrent]
        case .voiceConversation:
            return [.chatModel, .speechRecognition, .recognitionLanguage, .voiceSelection,
                    .speechRate, .autoReadAnswers, .interruptionControl]
        case .developmentCreation:
            return [.chatModel, .generalHelper, .packageReview, .visionHelper,
                    .imageCreationModel, .imageEditingModel, .videoCreationModel, .canvasHelper,
                    .searchProvider, .workspaceFolder, .localRuntime, .codeConnections,
                    .keepContentCurrent]
        case .custom:
            return []
        }
    }
}

/// One concrete set-up route. Each belongs to exactly one product section and
/// is resolved against real configured metadata, never a model-name guess.
enum SetupGuideRoute: String, CaseIterable, Codable, Equatable, Sendable, Identifiable {
    // Chat & Models
    case chatModel
    case generalHelper
    case packageReview
    case answerReview
    // Images & Creation
    case visionHelper
    case imageCreationModel
    case imageEditingModel
    case videoCreationModel
    case canvasHelper
    // Web Search
    case searchProvider
    // Voice
    case speechRecognition
    case recognitionLanguage
    case voiceSelection
    case systemVoice
    case speechRate
    case autoReadAnswers
    case interruptionControl
    // Files & Workspaces
    case workspaceFolder
    case localRuntime
    case codeConnections
    // Personalization & Memory
    case memoryPersonalization
    // Permissions & Privacy
    case permissionProfile
    // Background
    case extendedBackground
    // Sync & Storage
    case deviceSync
    // Skills & Updates
    case keepContentCurrent

    var id: String { rawValue }

    var section: SetupGuideSection {
        switch self {
        case .chatModel, .generalHelper, .packageReview, .answerReview: .chatModels
        case .visionHelper, .imageCreationModel, .imageEditingModel,
             .videoCreationModel, .canvasHelper: .creation
        case .searchProvider: .webSearch
        case .speechRecognition, .recognitionLanguage, .voiceSelection, .systemVoice,
             .speechRate, .autoReadAnswers, .interruptionControl: .voice
        case .workspaceFolder, .localRuntime, .codeConnections: .files
        case .memoryPersonalization: .personalization
        case .permissionProfile: .permissions
        case .extendedBackground: .background
        case .deviceSync: .syncStorage
        case .keepContentCurrent: .skills
        }
    }

    var titleKey: String { "setup.route.\(rawValue)" }
    var detailKey: String { "setup.route.\(rawValue).detail" }

    /// Routes that need something the user must ask for explicitly: a byte
    /// transfer, a paid route, a system permission or advanced background
    /// behaviour. Those are only ever SUGGESTED inside their own section; a
    /// preset never performs them.
    var requiresExplicitConsent: Bool {
        switch self {
        case .speechRecognition, .voiceSelection, .localRuntime, .imageCreationModel,
             .imageEditingModel, .videoCreationModel, .searchProvider, .extendedBackground,
             .deviceSync, .permissionProfile, .codeConnections, .keepContentCurrent:
            return true
        case .chatModel, .generalHelper, .packageReview, .answerReview, .visionHelper,
             .canvasHelper, .recognitionLanguage, .systemVoice, .speechRate,
             .autoReadAnswers, .interruptionControl, .workspaceFolder, .memoryPersonalization:
            return false
        }
    }

    /// The capability a route needs from the configured model set. nil means
    /// the route is not model-gated. Checked against the shipped capability
    /// bits, so a media or approval route can never be pre-filled from a name.
    var requiredModelCapability: SetupGuideModelCapability? {
        switch self {
        case .chatModel: .chat
        // The general helper is the text-only auxiliary surface, and the
        // package reviewer is the approval surface: two different contracts,
        // two different slots.
        case .generalHelper: .generalAuxiliary
        case .answerReview, .packageReview: .approval
        case .visionHelper: .vision
        case .canvasHelper: .toolCalling
        case .imageCreationModel: .imageGeneration
        case .imageEditingModel: .imageEditing
        case .videoCreationModel: .videoGeneration
        case .searchProvider, .speechRecognition, .recognitionLanguage, .voiceSelection,
             .systemVoice, .speechRate, .autoReadAnswers, .interruptionControl,
             .workspaceFolder, .localRuntime, .codeConnections, .memoryPersonalization,
             .permissionProfile, .extendedBackground, .deviceSync, .keepContentCurrent:
            nil
        }
    }
}

/// The capability shapes the guide can verify from saved model metadata, named
/// after the shipped `ModelCapabilities` bits so no caller can invent one.
enum SetupGuideModelCapability: String, Codable, Equatable, Sendable {
    case chat, vision, toolCalling, approval, generalAuxiliary
    case imageGeneration, imageEditing, videoGeneration
}

/// One configured model, reduced to the facts a preset may rely on.
struct SetupGuideModelFact: Equatable, Sendable, Identifiable {
    var id: UUID
    var displayName: String
    var hasChat: Bool
    var hasVision: Bool
    var hasTools: Bool
    var hasApproval: Bool
    var hasGeneralAuxiliary: Bool = false
    var hasImageGeneration: Bool
    var hasImageEditing: Bool
    var hasVideoGeneration: Bool
    var visibleInPicker: Bool
    var isDefaultAgent: Bool

    func supports(_ capability: SetupGuideModelCapability) -> Bool {
        switch capability {
        case .chat: hasChat && visibleInPicker
        case .vision: hasVision
        case .toolCalling: hasTools
        case .approval: hasApproval
        case .generalAuxiliary: hasGeneralAuxiliary
        case .imageGeneration: hasImageGeneration
        case .imageEditing: hasImageEditing
        case .videoGeneration: hasVideoGeneration
        }
    }
}

/// Everything the guide may legitimately read as available here, from the real
/// services. An absent fact makes a route unavailable; it never hides a
/// section, which still shows its honest "not on this device yet" state.
struct SetupGuideDeviceFacts: Equatable, Sendable {
    var models: [SetupGuideModelFact] = []
    var hasUsableChatModel = false
    var hasVisionModel = false
    var imageCapableModelCount = 0
    var videoCapableModelCount = 0
    var approvalCapableModelCount = 0
    var hasGeneralHelperModel = false
    var defaultAgentModelID: UUID?
    var visionModelID: UUID?
    var generalHelperModelID: UUID?
    var packageReviewModelID: UUID?
    var approvalModelID: UUID?
    var canvasAssistantModelID: UUID?
    var canvasVisionModelID: UUID?
    var hasConfiguredProvider = false
    var hasConfiguredImageModel = false
    var hasConfiguredVideoModel = false
    var hasConfiguredSearchProvider = false
    var searchProviderCount = 0
    var hasAppleSpeechOutput = false
    var installedVoicePackIDs: [String] = []
    var availableVoicePackIDs: [String] = []
    var hasCloudSpeechCredential = false
    var hasSelectedVoicePack = false
    var enhancedRecognitionInstalled = false
    var workspaces: [String] = []
    var defaultWorkspaceName: String?
    var supportsLocalRuntime = false
    var hasSavedRemoteHost = false
    var gitRepositoryCount = 0
    var memoryProfilePresent = false
    var memorySoulPresent = false
    var cloudSyncAvailable = false
    var cloudSyncEnabled: Bool?
    var answerReviewEnabled: Bool?
    var autoReadEnabled: Bool?
    var interruptionAllowed: Bool?
    var speechRateRatio: Double?
    var recognitionLanguageCode: String?
    var contentAutoUpdate: Bool?

    init() {}

    /// The models that really serve one capability today.
    func candidates(for capability: SetupGuideModelCapability) -> [SetupGuideModelFact] {
        models.filter { $0.supports(capability) }
    }

    func isRouteAvailable(_ route: SetupGuideRoute) -> Bool {
        switch route {
        case .chatModel:
            return hasUsableChatModel
        case .generalHelper:
            return hasGeneralHelperModel
        case .packageReview, .answerReview:
            return approvalCapableModelCount > 0
        case .visionHelper:
            return hasVisionModel
        case .imageCreationModel:
            return imageCapableModelCount > 0
        case .imageEditingModel:
            return imageCapableModelCount > 0
        case .videoCreationModel:
            return videoCapableModelCount > 0
        case .canvasHelper:
            return candidates(for: .toolCalling).isEmpty == false
        case .searchProvider:
            return hasConfiguredSearchProvider || searchProviderCount > 0
        case .speechRecognition, .recognitionLanguage, .workspaceFolder,
             .memoryPersonalization, .permissionProfile, .extendedBackground,
             .keepContentCurrent:
            return true
        case .voiceSelection:
            return !availableVoicePackIDs.isEmpty || hasCloudSpeechCredential
        case .systemVoice:
            return hasAppleSpeechOutput
        case .speechRate, .autoReadAnswers, .interruptionControl:
            return hasAppleSpeechOutput || !installedVoicePackIDs.isEmpty || hasCloudSpeechCredential
        case .localRuntime:
            return supportsLocalRuntime
        case .codeConnections:
            return hasSavedRemoteHost || gitRepositoryCount > 0
        case .deviceSync:
            return cloudSyncAvailable
        }
    }

    /// A choice the user already made is authoritative for that route, and a
    /// preset must leave it exactly as it is.
    func isRouteAlreadyChosen(_ route: SetupGuideRoute) -> Bool {
        switch route {
        case .chatModel: defaultAgentModelID != nil
        case .generalHelper: generalHelperModelID != nil
        case .packageReview: packageReviewModelID != nil
        case .answerReview: approvalModelID != nil || answerReviewEnabled != nil
        case .visionHelper: visionModelID != nil
        case .imageCreationModel, .imageEditingModel: hasConfiguredImageModel
        case .videoCreationModel: hasConfiguredVideoModel
        case .canvasHelper: canvasAssistantModelID != nil || canvasVisionModelID != nil
        case .searchProvider: hasConfiguredSearchProvider
        case .speechRecognition: false
        case .recognitionLanguage: recognitionLanguageCode != nil
        case .voiceSelection: hasSelectedVoicePack
        case .systemVoice: false
        case .speechRate: speechRateRatio != nil
        case .autoReadAnswers: autoReadEnabled != nil
        case .interruptionControl: interruptionAllowed != nil
        case .workspaceFolder: defaultWorkspaceName != nil
        case .localRuntime, .codeConnections, .permissionProfile, .extendedBackground: false
        case .deviceSync: cloudSyncEnabled != nil
        case .keepContentCurrent: contentAutoUpdate != nil
        }
    }
}

/// The resolved outcome for one preset against the real device state.
struct SetupGuidePresetPlan: Equatable, Sendable {
    /// Routes the guide may set now: unset, supported, and needing no
    /// transfer, spend, permission or advanced background consent.
    var prefilled: [SetupGuideRoute] = []
    /// Routes the preset recommends, each with an explicit action inside its
    /// own section. Nothing happens until the user takes it.
    var suggested: [SetupGuideRoute] = []
    /// Routes left exactly as the user had them.
    var keptExisting: [SetupGuideRoute] = []
    /// Routes this device or configuration cannot serve right now.
    var unavailable: [SetupGuideRoute] = []

    var isCustom: Bool { prefilled.isEmpty && suggested.isEmpty }

    var touchedSections: Set<SetupGuideSection> { Set(prefilled.map(\.section)) }
}

enum SetupGuidePresetPlanner {
    /// Pure: no persistence, no service call, no side effect.
    static func plan(preset: SetupGuidePreset, facts: SetupGuideDeviceFacts) -> SetupGuidePresetPlan {
        var plan = SetupGuidePresetPlan()
        for route in preset.desiredRoutes {
            guard facts.isRouteAvailable(route) else {
                plan.unavailable.append(route)
                continue
            }
            guard !facts.isRouteAlreadyChosen(route) else {
                plan.keptExisting.append(route)
                continue
            }
            if route.requiresExplicitConsent {
                plan.suggested.append(route)
            } else {
                plan.prefilled.append(route)
            }
        }
        return plan
    }

    /// The one model a preset may choose silently: the model the user already
    /// marked default when it really serves the route, otherwise the single
    /// verified candidate. Never a name match, never a guess — nil means the
    /// route stays untouched until the user chooses.
    static func resolvedModelID(
        for route: SetupGuideRoute,
        facts: SetupGuideDeviceFacts
    ) -> UUID? {
        guard let capability = route.requiredModelCapability else { return nil }
        let candidates = facts.candidates(for: capability)
        guard !candidates.isEmpty else { return nil }
        if let existingDefault = facts.defaultAgentModelID,
           candidates.contains(where: { $0.id == existingDefault }) {
            return existingDefault
        }
        return candidates.count == 1 ? candidates[0].id : nil
    }
}


/// One route the preset would like to fill, with the model the planner
/// resolved for it from real capability metadata.
struct SetupGuidePrefillIntent: Equatable, Sendable {
    let route: SetupGuideRoute
    let modelID: UUID
}

/// The commit-time writer. It is pure so the mapping can be tested without a
/// database, and it is deliberately strict:
///
///   * each route writes exactly its own preference slot — the package
///     reviewer never lands in the answer-reviewer slot or anywhere else;
///   * a slot that is already filled at the save boundary is left alone, so a
///     choice the user made while the preset was being applied always wins;
///   * a model that is no longer usable for that capability is skipped;
///   * only routes that were really written are returned, so the UI can never
///     claim "filled" for a route that was not.
enum SetupGuidePrefillWriter {
    @discardableResult
    static func apply(
        _ intents: [SetupGuidePrefillIntent],
        to preferences: inout ModelSelectionPreferences,
        isUsable: (UUID, SetupGuideModelCapability) -> Bool
    ) -> [SetupGuideRoute] {
        var applied: [SetupGuideRoute] = []
        for intent in intents {
            guard let capability = intent.route.requiredModelCapability,
                  isUsable(intent.modelID, capability) else { continue }
            let slotIsFree: Bool
            switch intent.route {
            case .chatModel:
                slotIsFree = preferences.defaultAgentModelID == nil
                if slotIsFree { preferences.defaultAgentModelID = intent.modelID }
            case .generalHelper:
                slotIsFree = preferences.generalAuxiliaryLLMModelID == nil
                if slotIsFree { preferences.generalAuxiliaryLLMModelID = intent.modelID }
            case .packageReview:
                slotIsFree = preferences.packageReviewModelID == nil
                if slotIsFree { preferences.packageReviewModelID = intent.modelID }
            case .answerReview:
                slotIsFree = preferences.approvalModelID == nil
                if slotIsFree { preferences.approvalModelID = intent.modelID }
            case .visionHelper:
                slotIsFree = preferences.visionModelID == nil
                if slotIsFree { preferences.visionModelID = intent.modelID }
            case .canvasHelper:
                slotIsFree = preferences.canvasAgentModelID == nil
                if slotIsFree { preferences.canvasAgentModelID = intent.modelID }
            case .imageCreationModel:
                slotIsFree = preferences.imageGenerationModelID == nil
                    && preferences.sharedImageModelID == nil
                if slotIsFree { preferences.imageGenerationModelID = intent.modelID }
            case .imageEditingModel:
                slotIsFree = preferences.imageEditingModelID == nil
                    && preferences.sharedImageModelID == nil
                if slotIsFree { preferences.imageEditingModelID = intent.modelID }
            case .videoCreationModel:
                slotIsFree = preferences.defaultVideoModelID == nil
                if slotIsFree { preferences.defaultVideoModelID = intent.modelID }
            default:
                // Every other route is a device, permission, network or
                // transfer decision. A preset may suggest it inside its own
                // section but never write it.
                slotIsFree = false
            }
            if slotIsFree { applied.append(intent.route) }
        }
        return applied
    }
}
