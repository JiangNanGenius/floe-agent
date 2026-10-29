// FloeAppTests — Setup guide behavioural regressions.
//
// Pins the rules this rewrite exists for: every path walks the same ten
// product sections in order and then the summary; Back / Later / Next are
// always available; a preset only fills choices the user has not made and
// only from capabilities the device really has; preparation never blocks
// navigation; and guide progress is resumable independently of whether a
// provider works. Pure reducer, planner and summary logic only — no view, no
// network, no credential and no service side effect.

import Foundation
import Testing
import FloeCore
@testable import FloeApp

@Suite("FloeApp.SetupGuideReducer")
struct SetupGuideReducerTests {

    @Test("Every path reaches all ten sections in order and then the summary")
    func fullWalkVisitsEverySection() {
        for preset in SetupGuidePreset.allCases {
            var state = SetupGuideState()
            SetupGuideReducer.reduce(&state, .start(preset))
            var visited: [SetupGuideSection] = [state.section]
            // Later/Next are available in every section, including the first.
            for _ in 0..<(SetupGuideSection.configurable.count + 2) {
                SetupGuideReducer.reduce(&state, .next)
                visited.append(state.section)
                if state.section == .summary { break }
            }
            #expect(visited == SetupGuideSection.allCases,
                    "\(preset.rawValue) must not skip or reorder a section")
            #expect(!state.finished, "only an explicit Finish ends the guide")
        }
    }

    @Test("Back walks the same path and stops at the first section")
    func backFollowsTheSameOrder() {
        var state = SetupGuideState()
        SetupGuideReducer.reduce(&state, .jump(.skills))
        var walked: [SetupGuideSection] = []
        for _ in 0..<20 {
            SetupGuideReducer.reduce(&state, .back)
            walked.append(state.section)
            if state.section == .chatModels { break }
        }
        #expect(walked.last == .chatModels)
        #expect(walked.count == SetupGuideSection.configurable.count - 1)
    }

    @Test("Later records a user decision, moves on, and never claims configured")
    func laterAdvancesWithoutMarkingConfigured() {
        var state = SetupGuideState()
        SetupGuideReducer.reduce(&state, .deferCurrentSection)
        #expect(state.section == .creation)
        #expect(state.status(for: .chatModels) == .deferred)
        #expect(state.status(for: .chatModels) != .configured)
    }

    @Test("An existing main model never ends the guide")
    func configuredModelDoesNotFinishTheGuide() {
        var state = SetupGuideState()
        // The service reports a working provider+model pair; the guide stays.
        SetupGuideReducer.reduce(&state, .setStatus(.chatModels, .configured))
        #expect(!state.finished)
        #expect(state.section == .chatModels)
        SetupGuideReducer.reduce(&state, .next)
        #expect(state.section == .creation)
    }

    @Test("Finish only works from the summary")
    func finishRequiresSummary() {
        var state = SetupGuideState()
        SetupGuideReducer.reduce(&state, .finish)
        #expect(!state.finished)
        SetupGuideReducer.reduce(&state, .jump(.summary))
        SetupGuideReducer.reduce(&state, .finish)
        #expect(state.finished)
    }

    @Test("Preparation lifts a section to preparing and never blocks navigation")
    func preparationReflectsWithoutBlocking() {
        var state = SetupGuideState()
        SetupGuideReducer.reduce(&state, .jump(.voice))
        SetupGuideReducer.reduce(&state, .setPreparation(.voice, true))
        #expect(state.status(for: .voice) == .preparing)
        SetupGuideReducer.reduce(&state, .next)
        #expect(state.section == .files, "a running job must not hold the user")
        // Finishing preparation is not the same as the user configuring it.
        SetupGuideReducer.reduce(&state, .setPreparation(.voice, false))
        #expect(state.status(for: .voice) == .defaulted)
    }

    @Test("Preparation never overwrites a user decision")
    func preparationKeepsUserStatus() {
        var state = SetupGuideState()
        SetupGuideReducer.reduce(&state, .setStatus(.voice, .configured))
        SetupGuideReducer.reduce(&state, .setPreparation(.voice, true))
        #expect(state.status(for: .voice) == .configured)
        SetupGuideReducer.reduce(&state, .setPreparation(.voice, false))
        #expect(state.status(for: .voice) == .configured)
    }

    @Test("Terminal Finish ignores every later action")
    func terminalFinishIsFenced() {
        var state = SetupGuideState()
        SetupGuideReducer.reduce(&state, .jump(.summary))
        SetupGuideReducer.reduce(&state, .finish)
        #expect(state.finished)
        // A late resource mirror, a status write and a navigation callback all
        // arrive after the user finished; none may reopen the guide.
        SetupGuideReducer.reduce(&state, .setPreparation(.voice, true))
        SetupGuideReducer.reduce(&state, .setStatus(.voice, .configured))
        SetupGuideReducer.reduce(&state, .jump(.chatModels))
        SetupGuideReducer.reduce(&state, .next)
        #expect(state.section == .summary)
        #expect(state.status(for: .voice) == .unset)
        #expect(state.finished)
    }

    @Test("Finish needs no provider, no model and no ready resource")
    func finishNeedsNothingConfigured() {
        var state = SetupGuideState()
        for section in SetupGuideSection.configurable {
            SetupGuideReducer.reduce(&state, .setStatus(section, .deferred))
        }
        SetupGuideReducer.reduce(&state, .jump(.summary))
        SetupGuideReducer.reduce(&state, .finish)
        #expect(state.finished)
        // The honest summary still says "later" for everything: finishing the
        // guide is not a claim that anything was configured.
        let entries = SetupGuideSummaryBuilder.entries(state: state)
        #expect(entries.allSatisfy { $0.outcome == .later })
    }

    @Test("Progress survives a save and reload, and stays secret-free")
    func progressRoundTrip() throws {
        let suiteName = "FloeAppTests.SetupGuide.\(UUID().uuidString)"
        let suite = UserDefaults(suiteName: suiteName)!
        defer { suite.removePersistentDomain(forName: suiteName) }
        var state = SetupGuideState()
        SetupGuideReducer.reduce(&state, .start(.everyday))
        SetupGuideReducer.reduce(&state, .setStatus(.voice, .deferred))
        for _ in 0..<4 { SetupGuideReducer.reduce(&state, .next) }
        let saved = SetupGuideReducer.progress(from: state)
        SetupGuideProgressStore.save(saved, to: suite)

        let reloaded = try #require(SetupGuideProgressStore.load(from: suite))
        #expect(reloaded.currentSection == state.section)
        #expect(reloaded.preset == .everyday)
        #expect(reloaded.status(for: .voice) == .deferred)

        var resumed = SetupGuideState()
        SetupGuideReducer.reduce(&resumed, .resumeFrom(reloaded))
        #expect(resumed.section == state.section)
        #expect(resumed.preset == .everyday)

        // The durable record holds navigation facts only: no endpoint, model
        // name or credential can appear in it.
        let data = try JSONEncoder().encode(reloaded)
        let text = String(decoding: data, as: UTF8.self)
        for needle in ["http", "key", "token", "Bearer", "gpt", "claude", "doubao"] {
            #expect(!text.lowercased().contains(needle.lowercased()),
                    "progress record must not carry \(needle)")
        }
    }

    @Test("Resume works with no provider at all, so progress is separate from readiness")
    func resumeWithoutProvider() {
        // Navigation never consults hasConfiguredProvider: this state is built
        // by hand with nothing configured and still resumes where it stopped.
        let progress = SetupGuideProgress(
            preset: .custom,
            currentSection: .permissions,
            statuses: ["chatModels": .deferred],
            visitedSections: [.chatModels, .permissions]
        )
        var state = SetupGuideState()
        SetupGuideReducer.reduce(&state, .resumeFrom(progress))
        #expect(state.section == .permissions)
        #expect(state.status(for: .chatModels) == .deferred)
        SetupGuideReducer.reduce(&state, .next)
        #expect(state.section == .background)
    }

    @Test("An unknown persisted section cannot corrupt the restored position")
    func resumeIgnoresUnknownKeys() {
        let progress = SetupGuideProgress(
            preset: nil,
            currentSection: .voice,
            statuses: ["nonsense": .configured, "skills": .deferred]
        )
        var state = SetupGuideState()
        SetupGuideReducer.reduce(&state, .resumeFrom(progress))
        #expect(state.statuses.count == 1)
        #expect(state.status(for: .skills) == .deferred)
    }

    @Test("The summary labels Saved, Preparing, Later and Needs attention")
    func summaryBuckets() {
        var state = SetupGuideState()
        SetupGuideReducer.reduce(&state, .setStatus(.chatModels, .configured))
        SetupGuideReducer.reduce(&state, .setStatus(.webSearch, .deferred))
        SetupGuideReducer.reduce(&state, .setStatus(.permissions, .needsAttention))
        SetupGuideReducer.reduce(&state, .setStatus(.background, .defaulted))
        let entries = SetupGuideSummaryBuilder.entries(state: state)
        let outcome = Dictionary(uniqueKeysWithValues: entries.map { ($0.section, $0.outcome) })
        #expect(outcome[.chatModels] == .saved)
        #expect(outcome[.webSearch] == .later)
        #expect(outcome[.permissions] == .needsAttention)
        #expect(outcome[.background] == .defaulted)
        // Nothing was touched: it reads as postponed, never as configured.
        #expect(outcome[.syncStorage] == .later)
        #expect(entries.count == SetupGuideSection.configurable.count)
        #expect(entries.allSatisfy { $0.canJump })
    }

    @Test("A live job shows as preparing in the summary without changing the user's status")
    func summaryShowsLiveJobs() {
        var state = SetupGuideState()
        SetupGuideReducer.reduce(&state, .setStatus(.voice, .configured))
        let rows = [
            SetupResourceStageRules.row(for: SetupResourceReport(
                kind: .localRuntime,
                titleKey: "setup.resource.local_runtime",
                jobSubjectID: "image",
                phase: .transferring,
                totalBytes: 100,
                transferredBytes: 30
            ))
        ]
        let entries = SetupGuideSummaryBuilder.entries(state: state, resources: rows)
        let bySection = Dictionary(uniqueKeysWithValues: entries.map { ($0.section, $0.outcome) })
        #expect(bySection[.files] == .preparing)
        #expect(bySection[.voice] == .saved)
        #expect(state.status(for: .files) != .preparing, "the mirror never rewrites state")
    }
}

@Suite("FloeApp.SetupGuidePresets")
struct SetupGuidePresetTests {

    /// One configured model with exactly the metadata a preset may read.
    private func model(id: UUID = UUID(), name: String,
                       chat: Bool = false, vision: Bool = false, tools: Bool = false,
                       approval: Bool = false, auxiliary: Bool = false,
                       image: Bool = false, edit: Bool = false,
                       video: Bool = false, hidden: Bool = false) -> SetupGuideModelFact {
        SetupGuideModelFact(id: id, displayName: name, hasChat: chat, hasVision: vision,
                            hasTools: tools, hasApproval: approval,
                            hasGeneralAuxiliary: auxiliary,
                            hasImageGeneration: image,
                            hasImageEditing: edit, hasVideoGeneration: video,
                            visibleInPicker: !hidden, isDefaultAgent: false)
    }

    private func facts(
        _ models: [SetupGuideModelFact],
        search: Bool = false,
        voice: Bool = true,
        runtime: Bool = true
    ) -> SetupGuideDeviceFacts {
        var value = SetupGuideDeviceFacts()
        value.models = models
        value.hasUsableChatModel = models.contains { $0.supports(.chat) }
        value.hasVisionModel = models.contains { $0.supports(.vision) }
        value.hasGeneralHelperModel = models.contains { $0.supports(.generalAuxiliary) }
        value.imageCapableModelCount = models.filter { $0.supports(.imageGeneration) }.count
        value.videoCapableModelCount = models.filter { $0.supports(.videoGeneration) }.count
        value.approvalCapableModelCount = models.filter { $0.supports(.approval) }.count
        value.hasConfiguredSearchProvider = search
        value.searchProviderCount = search ? 1 : 0
        value.hasAppleSpeechOutput = voice
        value.supportsLocalRuntime = runtime
        return value
    }

    @Test("All four presets plus Custom keep all ten sections")
    func presetsNeverHideASection() {
        let configured = facts([model(name: "Primary Chat", chat: true, vision: true, tools: true,
                                      approval: true, image: true, video: true)],
                               search: true)
        for preset in SetupGuidePreset.allCases {
            let plan = SetupGuidePresetPlanner.plan(preset: preset, facts: configured)
            // Whatever the plan decides, the flow still contains every section:
            // a preset may fill a choice but never remove a step.
            let sections = preset.desiredRoutes.map(\.section)
            #expect(Set(sections).isSubset(of: Set(SetupGuideSection.configurable)))
            for route in preset.desiredRoutes {
                #expect(SetupGuideSection.configurable.contains(route.section),
                        "\(preset.rawValue).\(route.rawValue) has no home section")
            }
            #expect(plan.prefilled.count + plan.suggested.count + plan.keptExisting.count
                        + plan.unavailable.count == preset.desiredRoutes.count)
        }
        // Custom asks for nothing.
        #expect(SetupGuidePreset.custom.desiredRoutes.isEmpty)
    }

    @Test("A preset never overwrites a choice the user already made")
    func existingChoicesWin() {
        let primary = model(name: "Primary Chat", chat: true, vision: true, tools: true)
        let helper = model(name: "General Helper", chat: true, auxiliary: true)
        var configured = facts([primary, helper])
        configured.defaultAgentModelID = primary.id
        configured.visionModelID = primary.id
        configured.canvasAssistantModelID = primary.id
        configured.generalHelperModelID = helper.id
        configured.autoReadEnabled = true
        configured.interruptionAllowed = true
        configured.memoryProfilePresent = true
        configured.hasConfiguredSearchProvider = true
        // An already saved answer-voice channel settles the voice route: the
        // preset must not switch it back to the system voice.
        configured.hasSavedVoiceChoice = true
        configured.contentAutoUpdate = true

        let plan = SetupGuidePresetPlanner.plan(preset: .everyday, facts: configured)
        #expect(plan.prefilled.isEmpty, "nothing unset remains to fill")
        for route in [SetupGuideRoute.chatModel, .generalHelper, .visionHelper, .canvasHelper,
                      .searchProvider, .systemVoice, .autoReadAnswers, .interruptionControl,
                      .memoryPersonalization, .keepContentCurrent] {
            #expect(plan.keptExisting.contains(route),
                    "\(route.rawValue) must keep the user's existing choice")
        }
        #expect(plan.unavailable.contains(.deviceSync),
                "an unavailable route is reported, never silently rewritten")
        #expect(!plan.prefilled.contains(.autoReadAnswers))
    }

    @Test("A saved system or online voice is kept even with no pack model id")
    func savedVoiceChannelWithoutModelIDIsKept() {
        let primary = model(name: "Primary", chat: true)
        var configured = facts([primary], voice: true)
        configured.hasSavedVoiceChoice = true
        configured.availableVoicePackIDs = ["pack-a"]

        // A fresh install may still be offered the system voice.
        var fresh = facts([primary], voice: true)
        fresh.availableVoicePackIDs = ["pack-a"]
        #expect(SetupGuidePresetPlanner.plan(preset: .everyday, facts: fresh)
                .prefilled.contains(.systemVoice))

        // Any saved voice record (explicit system voice, local pack or online
        // profile even when its modelID is empty) keeps both voice routes.
        let everyday = SetupGuidePresetPlanner.plan(preset: .everyday, facts: configured)
        #expect(everyday.keptExisting.contains(.systemVoice))
        #expect(!everyday.prefilled.contains(.systemVoice))
        let voice = SetupGuidePresetPlanner.plan(preset: .voiceConversation, facts: configured)
        #expect(voice.keptExisting.contains(.voiceSelection))
        #expect(!voice.prefilled.contains(.voiceSelection))
    }

    @Test("An unsupported capability is dropped, not faked")
    func unsupportedCapabilitiesAreUnavailable() {
        // Text-only endpoint: no vision, no media, no reviewer contract.
        let plain = facts([model(name: "Plain", chat: true)])
        let plan = SetupGuidePresetPlanner.plan(preset: .everyday, facts: plain)
        #expect(plan.unavailable.contains(.visionHelper))
        #expect(plan.unavailable.contains(.canvasHelper))
        #expect(!plan.prefilled.contains(.visionHelper))
        #expect(!plan.prefilled.contains(.canvasHelper))
        // The chat route itself is still fillable.
        #expect(plan.prefilled.contains(.chatModel))
    }

    @Test("A model hidden from the picker cannot be pre-selected as the main model")
    func hiddenModelsAreNotRouted() {
        let hidden = model(name: "Hidden Image", chat: true, hidden: true)
        let plan = SetupGuidePresetPlanner.plan(
            preset: .lightStart,
            facts: facts([hidden])
        )
        #expect(plan.unavailable.contains(.chatModel))
        #expect(SetupGuidePresetPlanner.resolvedModelID(
            for: .chatModel, facts: facts([hidden])) == nil)
    }

    @Test("Only a single verified candidate may be chosen silently")
    func ambiguousCandidatesStayUntouched() {
        let one = model(name: "Solo", chat: true, vision: true)
        #expect(SetupGuidePresetPlanner.resolvedModelID(
            for: .visionHelper, facts: facts([one])) == one.id)
        let two = [one, model(name: "Other", vision: true)]
        #expect(SetupGuidePresetPlanner.resolvedModelID(
            for: .visionHelper, facts: facts(two)) == nil,
            "two candidates means the user chooses")
        // The already-chosen default wins when it really serves the route.
        var configured = facts(two)
        configured.defaultAgentModelID = one.id
        #expect(SetupGuidePresetPlanner.resolvedModelID(for: .visionHelper, facts: configured) == one.id)
    }

    @Test("Routes that need consent stay explicit while model routing is prefilled")
    func consentRoutesStayExplicit() {
        let configured = facts(
            [model(name: "Primary", chat: true, image: true, edit: true, video: true)],
            search: true, runtime: true
        )
        let plan = SetupGuidePresetPlanner.plan(preset: .developmentCreation, facts: configured)
        for route in plan.prefilled {
            #expect(!route.requiresExplicitConsent,
                    "\(route.rawValue) may not be applied by a preset")
        }
        #expect(plan.suggested.contains(.localRuntime), "the runtime needs an explicit tap")
        #expect(plan.suggested.contains(.keepContentCurrent))
        // Image and video defaults only route future requests through an
        // already configured model surface; they start nothing by themselves.
        #expect(plan.prefilled.contains(.imageCreationModel))
        #expect(plan.prefilled.contains(.imageEditingModel))
        #expect(plan.prefilled.contains(.videoCreationModel))
        // A configured search provider is already the user's decision; making
        // a new credential-backed provider remains an explicit action.
        #expect(plan.keptExisting.contains(.searchProvider))
        #expect(!plan.prefilled.contains(.searchProvider))
    }

    @Test("A generation-only model cannot promise an editing route")
    func mediaRoutesRequireTheirExactCapability() {
        let generationOnly = facts([model(name: "Generator", chat: true, image: true)])
        let plan = SetupGuidePresetPlanner.plan(preset: .developmentCreation, facts: generationOnly)
        #expect(plan.prefilled.contains(.imageCreationModel))
        #expect(!plan.prefilled.contains(.imageEditingModel))
        #expect(plan.unavailable.contains(.imageEditingModel))
    }

    @Test("Voice presets route real voice facts, not generic flags only")
    func voicePresetCoversTheRealVoiceRoutes() {
        var configured = facts([model(name: "Primary", chat: true)])
        configured.availableVoicePackIDs = ["pack-a"]
        configured.installedVoicePackIDs = []
        let plan = SetupGuidePresetPlanner.plan(preset: .voiceConversation, facts: configured)
        #expect(plan.suggested.contains(.voiceSelection))
        #expect(plan.suggested.contains(.speechRecognition))
        #expect(plan.prefilled.contains(.autoReadAnswers))
        #expect(plan.prefilled.contains(.interruptionControl))
        #expect(plan.prefilled.contains(.recognitionLanguage))
    }

    @Test("Light Start keeps the assistant answer-review route on the approval contract")
    func answerReviewNeedsApprovalCapability() {
        let noReviewer = facts([model(name: "Plain", chat: true)])
        let plan = SetupGuidePresetPlanner.plan(preset: .lightStart, facts: noReviewer)
        #expect(!plan.prefilled.contains(.answerReview))
    }

    @Test("The planner is pure: same facts, same plan")
    func plannerIsDeterministic() {
        let configured = facts([model(name: "Primary", chat: true, vision: true, tools: true)])
        #expect(SetupGuidePresetPlanner.plan(preset: .everyday, facts: configured)
                == SetupGuidePresetPlanner.plan(preset: .everyday, facts: configured))
    }
}

@Suite("FloeApp.SetupGuidePrefillWriter")
struct SetupGuidePrefillWriterTests {

    /// Every route the writer may touch, with its own model.
    private let chat = UUID()
    private let reviewer = UUID()
    private let helper = UUID()
    private let vision = UUID()
    private let canvas = UUID()

    private func usable(_ ids: UUID...) -> (UUID, SetupGuideModelCapability) -> Bool {
        let allowed = Set(ids)
        return { id, _ in allowed.contains(id) }
    }

    @Test("Each route writes exactly its own slot")
    func exactSlotPerRoute() {
        var preferences = ModelSelectionPreferences()
        let intents = [
            SetupGuidePrefillIntent(route: .chatModel, modelID: chat),
            SetupGuidePrefillIntent(route: .answerReview, modelID: reviewer),
            SetupGuidePrefillIntent(route: .packageReview, modelID: helper),
            SetupGuidePrefillIntent(route: .generalHelper, modelID: helper),
            SetupGuidePrefillIntent(route: .visionHelper, modelID: vision),
            SetupGuidePrefillIntent(route: .canvasHelper, modelID: canvas)
        ]
        let applied = SetupGuidePrefillWriter.apply(
            intents, to: &preferences, isUsable: usable(chat, reviewer, helper, vision, canvas)
        )
        #expect(preferences.defaultAgentModelID == chat)
        #expect(preferences.approvalModelID == reviewer)
        // The package reviewer has its own slot: it must never land in the
        // answer-reviewer slot, and the general helper has its own too.
        #expect(preferences.packageReviewModelID == helper)
        #expect(preferences.generalAuxiliaryLLMModelID == helper)
        #expect(preferences.visionModelID == vision)
        #expect(preferences.canvasAgentModelID == canvas)
        #expect(Set(applied) == Set([SetupGuideRoute.chatModel, .answerReview, .packageReview,
                                     .generalHelper, .visionHelper, .canvasHelper]))
    }

    @Test("A slot filled at the save boundary keeps the user's later choice")
    func laterUserChoiceWinsAtBoundary() {
        var preferences = ModelSelectionPreferences()
        let userPick = UUID()
        preferences.packageReviewModelID = userPick
        preferences.defaultAgentModelID = userPick
        let applied = SetupGuidePrefillWriter.apply(
            [
                SetupGuidePrefillIntent(route: .packageReview, modelID: helper),
                SetupGuidePrefillIntent(route: .chatModel, modelID: chat)
            ],
            to: &preferences,
            isUsable: usable(helper, chat)
        )
        #expect(preferences.packageReviewModelID == userPick)
        #expect(preferences.defaultAgentModelID == userPick)
        #expect(applied.isEmpty, "nothing was written, so nothing may be reported")
    }

    @Test("A model that is no longer usable is skipped, not written")
    func unusableModelIsSkipped() {
        var preferences = ModelSelectionPreferences()
        let gone = UUID()
        let applied = SetupGuidePrefillWriter.apply(
            [
                SetupGuidePrefillIntent(route: .visionHelper, modelID: gone),
                SetupGuidePrefillIntent(route: .chatModel, modelID: chat)
            ],
            to: &preferences,
            isUsable: usable(chat)
        )
        #expect(preferences.visionModelID == nil)
        #expect(preferences.defaultAgentModelID == chat)
        #expect(applied == [.chatModel])
    }

    @Test("Routes that need consent are never written by a preset")
    func consentRoutesAreNeverWritten() {
        var preferences = ModelSelectionPreferences()
        let original = preferences
        let consent: [SetupGuideRoute] = [
            .speechRecognition, .voiceSelection, .localRuntime, .searchProvider,
            .extendedBackground, .deviceSync, .permissionProfile, .codeConnections,
            .keepContentCurrent
        ]
        for route in consent {
            #expect(route.requiresExplicitConsent,
                    "\(route.rawValue) needs an explicit user action")
        }
        let intents = consent.map { SetupGuidePrefillIntent(route: $0, modelID: chat) }
        // Even if a consent route reached the writer by mistake, it has no
        // model slot and writes nothing.
        let forced = SetupGuidePrefillWriter.apply(intents, to: &preferences, isUsable: usable(chat))
        #expect(forced.isEmpty)
        #expect(preferences == original)
    }

    @Test("Image and video routing choices occupy their own slots when separated")
    func mediaRoutingPrefillsOwnSlots() {
        var preferences = ModelSelectionPreferences()
        preferences.auxiliaryImageMode = .separate
        let image = UUID()
        let editor = UUID()
        let video = UUID()
        let applied = SetupGuidePrefillWriter.apply(
            [
                SetupGuidePrefillIntent(route: .imageCreationModel, modelID: image),
                SetupGuidePrefillIntent(route: .imageEditingModel, modelID: editor),
                SetupGuidePrefillIntent(route: .videoCreationModel, modelID: video)
            ],
            to: &preferences,
            isUsable: usable(image, editor, video)
        )
        #expect(applied == [.imageCreationModel, .imageEditingModel, .videoCreationModel])
        #expect(preferences.imageGenerationModelID == image)
        #expect(preferences.imageEditingModelID == editor)
        #expect(preferences.defaultVideoModelID == video)
        // None of these routes can spend credit or start a transfer; they only
        // record which configured model serves the route.
        for route in [SetupGuideRoute.imageCreationModel, .imageEditingModel, .videoCreationModel] {
            #expect(!route.requiresExplicitConsent)
        }
    }

    @Test("Shared image routing writes one shared slot, never two")
    func sharedImageRoutingUsesOneModel() {
        var preferences = ModelSelectionPreferences()
        let media = UUID()
        let applied = SetupGuidePrefillWriter.apply(
            [
                SetupGuidePrefillIntent(route: .imageCreationModel, modelID: media),
                SetupGuidePrefillIntent(route: .imageEditingModel, modelID: media)
            ],
            to: &preferences,
            isUsable: usable(media)
        )
        #expect(preferences.auxiliaryImageMode == .shared)
        #expect(preferences.sharedImageModelID == media)
        #expect(preferences.imageGenerationModelID == nil)
        #expect(preferences.imageEditingModelID == nil)
        #expect(applied == [.imageCreationModel, .imageEditingModel])
    }

    @Test("Shared image routing never splits two different models across slots")
    func sharedImageRoutingDoesNotSplitModels() {
        var preferences = ModelSelectionPreferences()
        let generation = UUID()
        let editing = UUID()
        let applied = SetupGuidePrefillWriter.apply(
            [
                SetupGuidePrefillIntent(route: .imageCreationModel, modelID: generation),
                SetupGuidePrefillIntent(route: .imageEditingModel, modelID: editing)
            ],
            to: &preferences,
            isUsable: usable(generation, editing)
        )
        #expect(preferences.auxiliaryImageMode == .shared)
        #expect(preferences.sharedImageModelID == nil)
        #expect(preferences.imageGenerationModelID == nil)
        #expect(preferences.imageEditingModelID == nil)
        #expect(applied.isEmpty)
    }

    @Test("An empty intent list changes nothing")
    func emptyIntentsAreNoOp() {
        var preferences = ModelSelectionPreferences()
        preferences.defaultAgentModelID = chat
        let before = preferences
        let applied = SetupGuidePrefillWriter.apply([], to: &preferences, isUsable: usable(chat))
        #expect(applied.isEmpty)
        #expect(preferences == before)
    }
}
