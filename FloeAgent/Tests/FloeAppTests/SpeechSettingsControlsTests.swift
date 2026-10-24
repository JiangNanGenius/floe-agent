// FloeAppTests — speech settings controls, catalogue compatibility and the
// saved-key reveal policy.
//
// Covers the frozen cross-stage contract
// Local/Private/voice-device-fix-20261024/PLAYBACK-CONTROL-CONTRACT.json and
// the settings UI copy/ownership rules without touching playback files:
// selecting a voice never resets the user's rate/pitch/autoread/barge
// controls, saving a service never selects it, Volcengine 2.0 voices are
// offered only for the 2.0 model, the configured source generates a neutral
// provider rate while carrying the frozen controls, no provider gains an
// invented pitch parameter, and an explicitly revealed saved key is fenced to
// the owner that asked for it.

#if canImport(UIKit)
import Foundation
import XCTest
import FloeCore
import FloeProviders
import FloeSecurity
@testable import FloeApp

@MainActor
final class SpeechSettingsControlsTests: XCTestCase {
    private struct Fixture {
        let name: String
        let defaults: UserDefaults
        let keychain: ControlsTestKeychain
        let settings: TTSSettingsService
        func cleanup() { defaults.removePersistentDomain(forName: name) }
    }

    private func makeFixture() throws -> Fixture {
        let name = "speech-controls-test." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        let keychain = ControlsTestKeychain()
        return Fixture(
            name: name, defaults: defaults, keychain: keychain,
            settings: TTSSettingsService(defaults: defaults, keychain: keychain))
    }

    private func volcengineProfile(voice: String = "zh_female_vv_uranus_bigtts") -> TTSSettingsSnapshot {
        TTSSettingsSnapshot(
            provider: .volcengine, billingRoute: .payAsYouGo,
            modelID: "doubao-seed-tts-2.0", voiceID: voice)
    }

    // MARK: - Selection never resets the user's global controls

    func testChoosingACloudVoiceKeepsGlobalControlsAndCustomIDs() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let settings = fixture.settings
        settings.update {
            $0.speechRateRatio = 1.6
            $0.speechPitchSemitones = 2
            $0.autoReadEnabled = true
            $0.allowBargeIn = false
        }

        // A saved profile may carry a different stored rate/pitch; choosing its
        // voice must not move the user's live controls.
        var profile = volcengineProfile()
        profile.speechRateRatio = 0.6
        profile.speechPitchSemitones = -5
        settings.choose(profile)
        XCTAssertEqual(settings.snapshot.voiceID, "zh_female_vv_uranus_bigtts")
        XCTAssertEqual(settings.snapshot.speechRateRatio, 1.6)
        XCTAssertEqual(settings.snapshot.speechPitchSemitones, 2)
        XCTAssertTrue(settings.snapshot.autoReadEnabled)
        XCTAssertFalse(settings.snapshot.allowBargeIn)

        // An unknown/custom voice ID is preserved verbatim.
        var custom = volcengineProfile(voice: "my_cloned_voice_v9")
        custom.speechRateRatio = 0.7
        settings.choose(custom)
        XCTAssertEqual(settings.snapshot.voiceID, "my_cloned_voice_v9")
        XCTAssertEqual(settings.snapshot.speechRateRatio, 1.6)
        XCTAssertEqual(settings.snapshot.speechPitchSemitones, 2)

        // Selecting the plain system default keeps them too.
        settings.choose(.systemDefault)
        XCTAssertEqual(settings.snapshot.provider, .apple)
        XCTAssertEqual(settings.snapshot.speechRateRatio, 1.6)
        XCTAssertEqual(settings.snapshot.speechPitchSemitones, 2)
        XCTAssertTrue(settings.snapshot.autoReadEnabled)
        XCTAssertFalse(settings.snapshot.allowBargeIn)
    }

    func testSwitchingProviderKeepsGlobalControls() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let settings = fixture.settings
        settings.update {
            $0.speechRateRatio = 0.8
            $0.speechPitchSemitones = -2
            $0.autoReadEnabled = true
            $0.allowBargeIn = false
        }
        settings.select(.openAI)
        XCTAssertEqual(settings.snapshot.provider, .openAI)
        XCTAssertEqual(settings.snapshot.speechRateRatio, 0.8)
        XCTAssertEqual(settings.snapshot.speechPitchSemitones, -2)
        XCTAssertTrue(settings.snapshot.autoReadEnabled)
        XCTAssertFalse(settings.snapshot.allowBargeIn)

        settings.select(.volcengine)
        XCTAssertEqual(settings.snapshot.provider, .volcengine)
        XCTAssertEqual(settings.snapshot.speechRateRatio, 0.8)
        XCTAssertEqual(settings.snapshot.speechPitchSemitones, -2)
    }

    // MARK: - Saving a service never selects it

    func testSavingANewServiceNeverSelectsItOrMovesControls() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let settings = fixture.settings
        settings.update {
            $0.speechRateRatio = 1.4
            $0.speechPitchSemitones = 3
            $0.autoReadEnabled = true
        }
        var account = volcengineProfile()
        account.speechRateRatio = 0.65
        account.speechPitchSemitones = -4
        try settings.saveProfile(account, credential: "synthetic-volcengine-key")

        XCTAssertEqual(settings.snapshot.provider, .apple, "Saving a service must not select it")
        XCTAssertEqual(settings.snapshot.voiceID, "")
        XCTAssertEqual(settings.snapshot.speechRateRatio, 1.4)
        XCTAssertEqual(settings.snapshot.speechPitchSemitones, 3)
        XCTAssertTrue(settings.snapshot.autoReadEnabled)
        XCTAssertEqual(settings.configuredProfiles.count, 1)
        XCTAssertTrue(settings.hasCredential(for: account))
    }

    func testSavingTheActiveServiceKeepsLiveControls() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let settings = fixture.settings
        var active = volcengineProfile()
        try settings.saveProfile(active, credential: "synthetic-key")
        settings.choose(active)
        settings.update { $0.speechRateRatio = 1.75; $0.speechPitchSemitones = -1 }

        // The editor's profile copy still carries its older stored controls.
        active.voiceID = "zh_male_m191_uranus_bigtts"
        active.speechRateRatio = 0.55
        active.speechPitchSemitones = 5
        try settings.saveProfile(active, credential: "")
        XCTAssertEqual(settings.snapshot.voiceID, "zh_male_m191_uranus_bigtts")
        XCTAssertEqual(settings.snapshot.speechRateRatio, 1.75)
        XCTAssertEqual(settings.snapshot.speechPitchSemitones, -1)
    }

    // MARK: - Sanitizing + backward compatibility

    func testUpdateSanitizesAndPersistsBothControls() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let settings = fixture.settings

        settings.update { $0.speechRateRatio = .nan; $0.speechPitchSemitones = .infinity }
        XCTAssertEqual(settings.snapshot.speechRateRatio, 1)
        XCTAssertEqual(settings.snapshot.speechPitchSemitones, 0)

        settings.update { $0.speechRateRatio = 99; $0.speechPitchSemitones = -99 }
        XCTAssertEqual(settings.snapshot.speechRateRatio, 2)
        XCTAssertEqual(settings.snapshot.speechPitchSemitones, -6)

        let reloaded = TTSSettingsService(defaults: fixture.defaults, keychain: fixture.keychain)
        XCTAssertEqual(reloaded.snapshot.speechRateRatio, 2)
        XCTAssertEqual(reloaded.snapshot.speechPitchSemitones, -6)
    }

    func testLegacyPersistedSettingsAndProfilesDecodeWithoutPitch() throws {
        let name = "speech-controls-legacy." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let legacy = #"{"provider":"volcengine","billingRoute":"payAsYouGo","alibabaRegion":null,"modelID":"doubao-seed-tts-2.0","voiceID":"zh_female_vv_uranus_bigtts","speechRateRatio":1.25,"autoReadEnabled":false,"allowBargeIn":true,"connectionProviderID":null}"#
        defaults.set(Data(legacy.utf8), forKey: "voice.output.settings.v1")
        defaults.set(Data("{\"volcengine.payAsYouGo\":\(legacy)}".utf8), forKey: "voice.output.profiles.v1")
        let keychain = ControlsTestKeychain()
        try keychain.store(account: "tts.volcengine.payAsYouGo", secret: Data("legacy-key".utf8))
        let settings = TTSSettingsService(defaults: defaults, keychain: keychain)

        XCTAssertEqual(settings.snapshot.provider, .volcengine)
        XCTAssertEqual(settings.snapshot.speechRateRatio, 1.25)
        XCTAssertEqual(settings.snapshot.speechPitchSemitones, 0)
        XCTAssertEqual(settings.snapshot.playbackControls, TTSPlaybackControls(
            speechRateRatio: 1.25, speechPitchSemitones: 0))
        XCTAssertEqual(settings.configuredProfiles.count, 1)
        XCTAssertEqual(settings.profile(
            provider: .volcengine, route: .payAsYouGo).speechPitchSemitones, 0)

        // The upgraded record persists the new field and survives a relaunch.
        settings.update { $0.speechPitchSemitones = 2.5 }
        let reloaded = TTSSettingsService(defaults: defaults, keychain: keychain)
        XCTAssertEqual(reloaded.snapshot.speechRateRatio, 1.25)
        XCTAssertEqual(reloaded.snapshot.speechPitchSemitones, 2.5)
    }

    func testMalformedStoredIdentityFallsBackInsteadOfChangingRoute() throws {
        // Only the new pitch field is allowed to default. A stored record that
        // is missing its baseline-required identity keeps failing to decode,
        // and the service keeps its documented system-default fallback instead
        // of silently selecting another provider/route.
        let name = "speech-controls-corrupt." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set(
            Data(#"{"billingRoute":"payAsYouGo","modelID":"tts-1","voiceID":"alloy","speechRateRatio":1,"autoReadEnabled":false,"allowBargeIn":true}"#.utf8),
            forKey: "voice.output.settings.v1")
        let settings = TTSSettingsService(defaults: defaults, keychain: ControlsTestKeychain())
        XCTAssertEqual(settings.snapshot, .systemDefault)
        XCTAssertEqual(settings.snapshot.provider, .apple)
    }

    // MARK: - Catalogue compatibility

    func testVolcengineCatalogueIsHumanReadableAndModelBound() {
        let catalogue = VolcengineSpeechAdapter.voiceCatalog2
        XCTAssertEqual(catalogue.count, 9)
        XCTAssertEqual(Set(catalogue.map(\.voiceID)).count, 9, "Verified voice IDs are unique")
        XCTAssertEqual(
            catalogue.first(where: { $0.voiceID == "zh_female_vv_uranus_bigtts" })?.displayName,
            "Vivi 2.0")
        XCTAssertEqual(
            catalogue.first(where: { $0.voiceID == "zh_female_xiaohe_uranus_bigtts" })?.displayName,
            "小何 2.0")
        XCTAssertTrue(catalogue.allSatisfy { $0.kind == .builtin })

        XCTAssertTrue(VolcengineSpeechAdapter.isTwoPointZeroModel("doubao-seed-tts-2.0"))
        XCTAssertTrue(VolcengineSpeechAdapter.isTwoPointZeroModel("seed-tts-2.0"))
        XCTAssertFalse(VolcengineSpeechAdapter.isTwoPointZeroModel("doubao-seed-tts-1.0"))
        XCTAssertTrue(VolcengineSpeechAdapter.catalogueVoices(
            forModel: "doubao-seed-tts-1.0").isEmpty,
            "A 2.0 speaker is never offered for the 1.0 model")

        let service = TTSSpeechService()
        XCTAssertEqual(service.builtinVoices(
            for: .volcengine, modelID: "doubao-seed-tts-2.0").count, 9)
        XCTAssertTrue(service.builtinVoices(
            for: .volcengine, modelID: "doubao-seed-tts-1.0").isEmpty)
        XCTAssertEqual(service.builtinVoices(
            for: .openAI, modelID: "gpt-4o-mini-tts").count,
            OpenAISpeechAdapter.builtInVoices.count)

        // Every catalogue voice is dispatchable on the verified 2.0 bindings.
        for voice in catalogue {
            let request = TTSSynthesisRequest(
                provider: .volcengine, billingRoute: .payAsYouGo,
                modelID: "doubao-seed-tts-2.0", voiceID: voice.voiceID, text: "你好")
            XCTAssertNil(request.validationProblem())
        }
        XCTAssertNotNil(VolcengineSpeechAdapter.resourceID(
            forModel: "doubao-seed-tts-2.0", route: .agentPlan))
        XCTAssertNotNil(VolcengineSpeechAdapter.resourceID(
            forModel: "doubao-seed-tts-2.0", route: .payAsYouGo))
    }

    // MARK: - Neutral generation + frozen stream carrier

    func testConfiguredSourceUsesNeutralGenerationAndCarriesFrozenControls() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        var snapshot = volcengineProfile()
        snapshot.speechRateRatio = 1.6
        snapshot.speechPitchSemitones = -3

        let request = ConfiguredTTSSpeechSource.makeRequest(
            snapshot: snapshot, text: "hello", sessionID: UUID(), segmentIndex: 2)
        XCTAssertEqual(request.speechRateRatio, 1.0,
                       "The configured source must not scale the provider stream")
        XCTAssertEqual(request.provider, .volcengine)
        XCTAssertEqual(request.voiceID, "zh_female_vv_uranus_bigtts")
        XCTAssertEqual(request.segmentIndex, 2)
        XCTAssertNil(request.language)

        let source = ConfiguredTTSSpeechSource(
            snapshot: snapshot, settings: fixture.settings, service: TTSSpeechService())
        let configured = source.synthesize(text: "hello", sessionID: UUID(), segmentIndex: 0)
        XCTAssertEqual(configured.playbackControls, TTSPlaybackControls(
            speechRateRatio: 1.6, speechPitchSemitones: -3))
        // No credential is stored: the segment fails before any network use,
        // which also proves the stream is fully constructed with the controls.
        var caught: Error?
        do { for try await _ in configured.stream {} } catch { caught = error }
        if case .credentialMissing? = caught as? TTSSynthesisError {
            // expected
        } else {
            XCTFail("expected credentialMissing, got \(String(describing: caught))")
        }
    }

    func testStreamDefaultsToNeutralForExistingCallers() {
        let service = TTSSpeechService()
        let invalid = TTSSynthesisRequest(
            provider: .apple, billingRoute: .payAsYouGo,
            modelID: "", voiceID: "", text: " ")
        let raw = service.synthesize(invalid, credential: "")
        let configured = TTSConfiguredStream(stream: raw, close: {})
        XCTAssertEqual(configured.playbackControls, .neutral,
                       "Direct stream builders keep the neutral passthrough")
    }

    // MARK: - No invented provider pitch parameter

    func testNoProviderGainsAPitchParameter() throws {
        let volc = TTSSynthesisRequest(
            provider: .volcengine, billingRoute: .payAsYouGo,
            modelID: "doubao-seed-tts-2.0", voiceID: "zh_female_vv_uranus_bigtts",
            text: "你好", speechRateRatio: 1.6)
        let volcBody = VolcengineSpeechAdapter.makeBody(for: volc)
        let volcJSON = try jsonObject(volcBody)
        let audioParams = try XCTUnwrap(
            (volcJSON["req_params"] as? [String: Any])?["audio_params"] as? [String: Any])
        XCTAssertEqual(audioParams["speech_rate"] as? Int, 60)
        XCTAssertNoPitchKeys(in: volcJSON)

        var openAI = TTSSynthesisRequest(
            provider: .openAI, billingRoute: .payAsYouGo,
            modelID: "gpt-4o-mini-tts", voiceID: "alloy", text: "hi",
            speechRateRatio: 1.6)
        let openAIJSON = try jsonObject(OpenAISpeechAdapter.makeBody(for: openAI))
        XCTAssertEqual(openAIJSON["speed"] as? Double, 1.6)
        XCTAssertNoPitchKeys(in: openAIJSON)

        openAI.speechRateRatio = 1.0
        let neutralOpenAI = try jsonObject(OpenAISpeechAdapter.makeBody(for: openAI))
        XCTAssertNil(neutralOpenAI["speed"], "A neutral rate never writes the knob")
        XCTAssertNoPitchKeys(in: neutralOpenAI)

        var eleven = TTSSynthesisRequest(
            provider: .elevenLabs, billingRoute: .payAsYouGo,
            modelID: "eleven_multilingual_v2", voiceID: "synthetic",
            text: "hi", speechRateRatio: 1.6)
        let elevenJSON = try jsonObject(ElevenLabsSpeechAdapter.makeBody(for: eleven))
        XCTAssertEqual((elevenJSON["voice_settings"] as? [String: Any])?["speed"] as? Double, 1.5)
        XCTAssertNoPitchKeys(in: elevenJSON)

        eleven.speechRateRatio = 1.0
        let neutralEleven = try jsonObject(ElevenLabsSpeechAdapter.makeBody(for: eleven))
        XCTAssertNil(neutralEleven["voice_settings"],
                     "A neutral rate never writes provider voice settings")
        XCTAssertNoPitchKeys(in: neutralEleven)
    }

    private func jsonObject(_ data: Data) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func XCTAssertNoPitchKeys(
        in value: Any, path: String = "root", file: StaticString = #filePath, line: UInt = #line
    ) {
        switch value {
        case let dictionary as [String: Any]:
            for (key, nested) in dictionary {
                let lower = key.lowercased()
                XCTAssertFalse(
                    lower.contains("pitch") || lower.contains("inton"),
                    "Unexpected provider pitch parameter '\(path).\(key)'",
                    file: file, line: line)
                XCTAssertNoPitchKeys(in: nested, path: "\(path).\(key)", file: file, line: line)
            }
        case let array as [Any]:
            for (index, nested) in array.enumerated() {
                XCTAssertNoPitchKeys(in: nested, path: "\(path)[\(index)]", file: file, line: line)
            }
        default:
            break
        }
    }

    // MARK: - Saved-key reveal ownership

    func testSavedKeyRevealOwnerFencesLateResults() {
        var owner = SpeechSavedKeyRevealOwner()
        XCTAssertFalse(owner.isRevealed)
        XCTAssertNil(owner.value)

        let token = owner.token()
        owner.complete(token: token, value: "synthetic-stored-key")
        XCTAssertEqual(owner.value, "synthetic-stored-key")

        // Inactivity only hides visible plaintext; the pending generation is
        // untouched so an in-flight biometric prompt can still complete.
        owner.hide()
        XCTAssertNil(owner.value)
        XCTAssertTrue(owner.isCurrent(token))
        owner.complete(token: token, value: "synthetic-stored-key")
        XCTAssertEqual(owner.value, "synthetic-stored-key")

        // A background/exit/provider-route change fences the pending reveal.
        owner.invalidate()
        XCTAssertNil(owner.value)
        XCTAssertFalse(owner.isCurrent(token))
        owner.complete(token: token, value: "late-key")
        XCTAssertNil(owner.value, "A late result for a rotated owner is discarded")

        // The next reveal owns a fresh generation.
        let next = owner.token()
        XCTAssertTrue(owner.isCurrent(next))
        owner.complete(token: next, value: "synthetic-replacement")
        XCTAssertEqual(owner.value, "synthetic-replacement")
    }

    func testSavedKeyRevealReadsStoredCredentialWithoutChangingSettings() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let settings = fixture.settings
        settings.update { $0.speechRateRatio = 1.3; $0.speechPitchSemitones = 1 }
        var profile = TTSSettingsSnapshot(
            provider: .openAI, billingRoute: .payAsYouGo,
            modelID: "gpt-4o-mini-tts", voiceID: "alloy")
        try settings.saveProfile(profile, credential: "synthetic-stored-key")

        // The explicit resolver is what the reveal view reads after owner
        // authentication. Reading it must not select the service or move any
        // control, and the typed replacement key stays a separate input.
        let revealed = try await settings.credential(for: profile)
        XCTAssertEqual(revealed, "synthetic-stored-key")
        XCTAssertEqual(settings.snapshot.provider, .apple)
        XCTAssertEqual(settings.snapshot.speechRateRatio, 1.3)
        XCTAssertEqual(settings.snapshot.speechPitchSemitones, 1)

        // A replacement only takes effect after an explicit save.
        try settings.saveProfile(profile, credential: "synthetic-replacement")
        XCTAssertEqual(try await settings.credential(for: profile), "synthetic-replacement")

        // Without a stored secret the reveal has nothing to show.
        try settings.removeProfile(profile)
        do {
            _ = try await settings.credential(for: profile)
            XCTFail("A removed profile must not resolve a credential")
        } catch {}
        XCTAssertFalse(settings.hasCredential(for: profile))
    }
}

/// Dictionary keychain used only by these tests; no Keychain, no network.
private final class ControlsTestKeychain: KeychainProbeStore, @unchecked Sendable {
    private let lock = NSLock()
    private var items: [String: Data] = [:]
    func store(account: String, secret: Data) throws {
        lock.lock(); defer { lock.unlock() }
        items[account] = secret
    }
    func read(account: String) throws -> Data {
        lock.lock(); defer { lock.unlock() }
        guard let value = items[account] else { throw KeychainStoreError.itemNotFound }
        return value
    }
    func delete(account: String) throws {
        lock.lock(); defer { lock.unlock() }
        items.removeValue(forKey: account)
    }
}
#endif
