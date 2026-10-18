// FloeAppTests — PiP audio preferences, background-options persistence and
// the independent-capability runtime policy.
//
// These tests exercise the REAL load/migrate/save path (`BackgroundPrefer-
// encesRepository` is the exact code `SettingsCenter` delegates to) against
// an in-memory `SettingsStore`, and the REAL coordinator policy entry points
// for the three independent background capabilities. No full app environment
// is constructed and no assertion mirrors implementation trivia: every case
// pins a product contract (migration mapping, atomicity, normalization,
// capability independence, explicit-user-action gates).

#if canImport(UIKit)
import Foundation
import Testing
import UIKit
import FloeCore
import FloePersistence
@testable import FloeApp

// MARK: - In-memory store

private actor InMemorySettingsStore: SettingsStore {
    private var values: [String: String] = [:]

    func value(forKey key: String) async throws -> String? { values[key] }

    func setValue(_ json: String, forKey key: String) async throws {
        values[key] = json
    }

    func removeValue(forKey key: String) async throws {
        values[key] = nil
    }

    func allValues() async throws -> [String: String] { values }

    func seed(_ key: String, _ json: String) {
        values[key] = json
    }
}

// MARK: - Preference value contract

@Suite("FloeApp.PiPAudioPreferences")
struct PiPAudioPreferencesTests {

    @Test("Shipping defaults match the product contract")
    func shippingDefaults() {
        let defaults = PiPAudioPreferences()
        #expect(defaults.ambientEnabled == true) // ambient on by default…
        #expect(defaults.ambientGain == 0) // …but muted: zero-volume playback
        #expect(defaults.ambientSound == .rain)
        #expect(defaults.taskSpeechEnabled == false)
        #expect(defaults.taskSpeechGain == 0.7)
        #expect(defaults.cuesEnabled == false)
        #expect(defaults.version == PiPAudioPreferences.currentVersion)
    }

    @Test("Normalization clamps corrupt ranges and never yields NaN")
    func normalizationClamps() {
        var wild = PiPAudioPreferences()
        wild.ambientGain = 1.7
        wild.taskSpeechGain = -0.2
        wild.version = 99
        let clamped = wild.normalized
        #expect(clamped.ambientGain == 1.0)
        #expect(clamped.taskSpeechGain == 0)
        #expect(clamped.version == PiPAudioPreferences.currentVersion)

        var nan = PiPAudioPreferences()
        nan.ambientGain = .nan
        nan.taskSpeechGain = .infinity
        let repaired = nan.normalized
        #expect(repaired.ambientGain == 0) // ambient fallback is the muted default
        #expect(repaired.taskSpeechGain == 0.7)
        #expect(repaired.ambientGain.isFinite)
        #expect(repaired.taskSpeechGain.isFinite)
    }

    @Test("Partial, unknown or corrupt records decode field-by-field from defaults")
    func lenientDecoding() throws {
        let partial = try #require(
            #"{"version":1,"ambientGain":0.4}"#.data(using: .utf8)
        )
        let decoded = try JSONDecoder().decode(PiPAudioPreferences.self, from: partial)
        #expect(decoded.ambientGain == 0.4)
        #expect(decoded.ambientEnabled == true) // default preserved
        #expect(decoded.ambientSound == .rain)
        #expect(decoded.taskSpeechGain == 0.7)
        #expect(decoded.cuesEnabled == false)

        let unknownSound = try #require(
            #"{"ambientSound":"ocean","taskSpeechEnabled":true}"#.data(using: .utf8)
        )
        let fallback = try JSONDecoder().decode(PiPAudioPreferences.self, from: unknownSound)
        #expect(fallback.ambientSound == .rain) // unknown choice → default sound
        #expect(fallback.taskSpeechEnabled == true)

        let roundTrip = try JSONEncoder().encode(PiPAudioPreferences())
        #expect(
            try JSONDecoder().decode(PiPAudioPreferences.self, from: roundTrip)
                == PiPAudioPreferences()
        )
    }

    // MARK: - Repository: real load/migrate/save path

    @Test("Legacy mutually-exclusive choices migrate onto the independent options")
    func legacyMigrationMapping() async {
        let store = InMemorySettingsStore()
        let repository = BackgroundPreferencesRepository(store: store)

        await store.seed(AppSettingsKey.backgroundExecution, #""standard""#)
        var options = await repository.loadOptions()
        #expect(options.enhancedBackgroundEnabled == true)
        #expect(options.pictureInPictureEnabled == false)
        #expect(options.screenFeedbackEnabled == false)

        await store.seed(AppSettingsKey.backgroundExecution, #""pictureInPicture""#)
        options = await repository.loadOptions()
        #expect(options.enhancedBackgroundEnabled == true)
        #expect(options.pictureInPictureEnabled == true)
        #expect(options.screenFeedbackEnabled == false)

        await store.seed(AppSettingsKey.backgroundExecution, #""screenShare""#)
        options = await repository.loadOptions()
        #expect(options.enhancedBackgroundEnabled == true)
        #expect(options.pictureInPictureEnabled == true) // feedback implies PiP
        #expect(options.screenFeedbackEnabled == true)
    }

    @Test("Options persist as one atomic normalized object and win over the legacy key")
    func atomicSaveAndPrecedence() async throws {
        let store = InMemorySettingsStore()
        await store.seed(AppSettingsKey.backgroundExecution, #""screenShare""#)
        let repository = BackgroundPreferencesRepository(store: store)

        // An unnormalized object normalizes on save: feedback implies PiP.
        var unnormalized = BackgroundExecutionOptions()
        unnormalized.screenFeedbackEnabled = true // pip deliberately left false
        try await repository.saveOptions(unnormalized)

        let loaded = await repository.loadOptions()
        #expect(loaded.enhancedBackgroundEnabled == true)
        #expect(loaded.pictureInPictureEnabled == true)
        #expect(loaded.screenFeedbackEnabled == true)

        // The legacy key is never rewritten by the options save.
        let legacy = try #require(
            await store.value(forKey: AppSettingsKey.backgroundExecution)
        )
        #expect(legacy == #""screenShare""#)

        // One JSON object carries all three capabilities.
        let optionsJSON = try #require(
            await store.value(forKey: AppSettingsKey.backgroundExecutionOptions)
        )
        #expect(optionsJSON.contains("enhancedBackgroundEnabled"))
        #expect(optionsJSON.contains("pictureInPictureEnabled"))
        #expect(optionsJSON.contains("screenFeedbackEnabled"))
    }

    @Test("Corrupt options fall back to the legacy choice, then to defaults")
    func corruptOptionsFallback() async {
        let store = InMemorySettingsStore()
        await store.seed(AppSettingsKey.backgroundExecutionOptions, "{not json")
        await store.seed(AppSettingsKey.backgroundExecution, #""pictureInPicture""#)
        var options = await BackgroundPreferencesRepository(store: store).loadOptions()
        #expect(options.pictureInPictureEnabled == true)
        #expect(options.screenFeedbackEnabled == false)

        let defaults = await BackgroundPreferencesRepository(
            store: InMemorySettingsStore()
        ).loadOptions()
        #expect(defaults == BackgroundExecutionOptions())
    }

    @Test("PiP audio preferences round-trip through the store; corrupt values repair on load")
    func pipAudioRepositoryRoundTrip() async throws {
        let store = InMemorySettingsStore()
        let repository = BackgroundPreferencesRepository(store: store)

        let missing = await repository.loadPipAudioPreferences()
        #expect(missing == PiPAudioPreferences())

        var custom = PiPAudioPreferences()
        custom.ambientSound = .brownNoise
        custom.ambientGain = 0.35
        custom.taskSpeechEnabled = true
        custom.cuesEnabled = true
        try await repository.savePipAudioPreferences(custom)
        #expect(await repository.loadPipAudioPreferences() == custom)

        // A single atomic JSON object holds every channel.
        let json = try #require(await store.value(forKey: PiPAudioPreferences.settingsKey))
        #expect(json.contains("ambientSound"))
        #expect(json.contains("cuesEnabled"))

        // Out-of-range stored values are repaired on load, never trusted.
        await store.seed(
            PiPAudioPreferences.settingsKey,
            #"{"version":1,"ambientEnabled":true,"ambientSound":"rain","ambientGain":1.7,"taskSpeechEnabled":false,"taskSpeechGain":-0.2,"cuesEnabled":false}"#
        )
        let repaired = await repository.loadPipAudioPreferences()
        #expect(repaired.ambientGain == 1.0)
        #expect(repaired.taskSpeechGain == 0)
    }

    // MARK: - Independent-capability runtime policy (coordinator entry points)

    @Test("Enhanced background is kept and submitted independently of the visual surfaces")
    func enhancedIsIndependentOfVisuals() {
        let allOn = BackgroundExecutionOptions(
            enhancedBackgroundEnabled: true,
            pictureInPictureEnabled: true,
            screenFeedbackEnabled: true
        )
        #expect(BackgroundRunCoordinator.shouldKeepContinuedProcessing(
            for: allOn, launchPreferencesLoaded: true
        ))
        #expect(BackgroundRunCoordinator.shouldSubmitContinuedProcessing(
            for: allOn,
            launchPreferencesLoaded: true,
            origin: .explicitUserAction,
            hasAggregateForegroundScene: true
        ))

        // Visuals ON but enhanced OFF: no continued processing.
        let visualOnly = BackgroundExecutionOptions(
            enhancedBackgroundEnabled: false,
            pictureInPictureEnabled: true,
            screenFeedbackEnabled: true
        )
        #expect(!BackgroundRunCoordinator.shouldKeepContinuedProcessing(
            for: visualOnly, launchPreferencesLoaded: true
        ))
        #expect(!BackgroundRunCoordinator.shouldSubmitContinuedProcessing(
            for: visualOnly,
            launchPreferencesLoaded: true,
            origin: .explicitUserAction,
            hasAggregateForegroundScene: true
        ))

        // Enhanced alone (no visuals) still keeps processing.
        let enhancedOnly = BackgroundExecutionOptions(enhancedBackgroundEnabled: true)
        #expect(BackgroundRunCoordinator.shouldKeepContinuedProcessing(
            for: enhancedOnly, launchPreferencesLoaded: true
        ))

        // Unloaded launch preferences fail closed regardless of the toggle.
        #expect(!BackgroundRunCoordinator.shouldKeepContinuedProcessing(
            for: allOn, launchPreferencesLoaded: false
        ))

        // The explicit-user-action origin and foreground gates are preserved
        // for every capability combination.
        #expect(!BackgroundRunCoordinator.shouldSubmitContinuedProcessing(
            for: allOn,
            launchPreferencesLoaded: true,
            origin: .automaticTool,
            hasAggregateForegroundScene: true
        ))
        #expect(!BackgroundRunCoordinator.shouldSubmitContinuedProcessing(
            for: allOn,
            launchPreferencesLoaded: true,
            origin: .scheduledTask,
            hasAggregateForegroundScene: true
        ))
        #expect(!BackgroundRunCoordinator.shouldSubmitContinuedProcessing(
            for: allOn,
            launchPreferencesLoaded: true,
            origin: .explicitUserAction,
            hasAggregateForegroundScene: false
        ))
    }

    @Test("All three capabilities coexist: eligibility, auto-armed PiP and screen feedback at once")
    func allThreeOnRegression() {
        let allOn = BackgroundExecutionOptions(
            enhancedBackgroundEnabled: true,
            pictureInPictureEnabled: true,
            screenFeedbackEnabled: true
        )
        let honored = BackgroundRunCoordinator.honoredOptions(
            allOn, statusPiPEnabled: true
        )
        #expect(honored == allOn)

        // Continued processing stays eligible with both visuals on.
        #expect(BackgroundRunCoordinator.shouldKeepContinuedProcessing(
            for: honored, launchPreferencesLoaded: true
        ))

        // PiP is prepared (auto-arming is decided by the projection below)
        // while screen feedback runs at the same time.
        let transition = BackgroundRunCoordinator.visualSurfaceTransition(for: honored)
        #expect(transition.preparesPictureInPicture)
        #expect(!transition.stopsPictureInPicture)
        #expect(!transition.stopsScreenShare)
        #expect(!transition.requestsScreenShareAuthorization) // consent stays a run-start action

        // The legacy projection stays compatible, but automatic inline
        // arming is owned by the PiP capability ALONE: all three toggles ON
        // keep auto-arming even though the projection reads `.screenShare`.
        let pipOnly = BackgroundExecutionOptions(
            enhancedBackgroundEnabled: true,
            pictureInPictureEnabled: true
        )
        #expect(pipOnly.legacyPreference == .pictureInPicture)
        #expect(honored.legacyPreference == .screenShare)
        #expect(BackgroundRunCoordinator.shouldArmAutomaticInlineStart(for: allOn))
        #expect(BackgroundRunCoordinator.shouldArmAutomaticInlineStart(for: pipOnly))
        #expect(BackgroundRunCoordinator.shouldArmAutomaticInlineStart(for: honored))
        #expect(!BackgroundRunCoordinator.shouldArmAutomaticInlineStart(
            for: BackgroundExecutionOptions(enhancedBackgroundEnabled: true)
        ))

        // A disabled release gate strips ONLY the visual capabilities.
        let gated = BackgroundRunCoordinator.honoredOptions(
            allOn, statusPiPEnabled: false
        )
        #expect(gated.enhancedBackgroundEnabled == true)
        #expect(gated.pictureInPictureEnabled == false)
        #expect(gated.screenFeedbackEnabled == false)
        let gatedTransition = BackgroundRunCoordinator.visualSurfaceTransition(for: gated)
        #expect(gatedTransition.stopsPictureInPicture)
        #expect(gatedTransition.stopsScreenShare)
        #expect(!gatedTransition.preparesPictureInPicture)
        #expect(!BackgroundRunCoordinator.shouldArmAutomaticInlineStart(for: gated))
        #expect(BackgroundRunCoordinator.shouldKeepContinuedProcessing(
            for: gated, launchPreferencesLoaded: true
        ))
    }

    @Test("Independent surface transitions stop only what the user turned off")
    func transitionIndependence() {
        let pipOnly = BackgroundExecutionOptions(
            enhancedBackgroundEnabled: true,
            pictureInPictureEnabled: true
        )
        let pipTransition = BackgroundRunCoordinator.visualSurfaceTransition(for: pipOnly)
        #expect(pipTransition.preparesPictureInPicture)
        #expect(!pipTransition.stopsPictureInPicture)
        #expect(pipTransition.stopsScreenShare) // feedback off stops the broadcast
        #expect(!pipTransition.requestsScreenShareAuthorization)

        let none = BackgroundExecutionOptions(enhancedBackgroundEnabled: true)
        let noneTransition = BackgroundRunCoordinator.visualSurfaceTransition(for: none)
        #expect(noneTransition.stopsPictureInPicture)
        #expect(noneTransition.stopsScreenShare)
        #expect(!noneTransition.preparesPictureInPicture)
    }

    @Test("The legacy projection never reintroduces mutual exclusivity at runtime")
    func legacyProjectionStaysCompatible() {
        // Settings toggle cascade rules from the Core model.
        var options = BackgroundExecutionOptions()
        options.setScreenFeedbackEnabled(true)
        #expect(options.pictureInPictureEnabled) // feedback on ⇒ PiP on
        options.setPictureInPictureEnabled(false)
        #expect(!options.screenFeedbackEnabled) // PiP off ⇒ feedback off
        // Enhanced is untouched by both cascades.
        #expect(options.enhancedBackgroundEnabled)
        options.setPictureInPictureEnabled(true)
        #expect(options.enhancedBackgroundEnabled)
        #expect(options.legacyPreference == .pictureInPicture)
    }
}
#endif
