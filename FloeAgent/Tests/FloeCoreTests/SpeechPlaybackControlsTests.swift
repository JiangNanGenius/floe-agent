// FloeCoreTests — persisted speech playback controls.
//
// Pins the frozen cross-stage contract
// Local/Private/voice-device-fix-20261024/PLAYBACK-CONTROL-CONTRACT.json:
// neutral 0 pitch, finite clamp -6…6 semitones, finite clamp 0.5…2.0 rate,
// backward-compatible decoding of settings written before either control
// existed, and a snapshot whose computed playbackControls can never expose an
// out-of-contract value to a player.

import Foundation
import Testing
@testable import FloeCore

@Suite("FloeCore.TTSPlaybackControls")
struct SpeechPlaybackControlsTests {
    private func decode(_ json: String) throws -> TTSSettingsSnapshot {
        try JSONDecoder().decode(TTSSettingsSnapshot.self, from: Data(json.utf8))
    }

    // MARK: - Backward-compatible decoding

    @Test("The real baseline snapshot shape minus the new pitch field decodes with pitch 0")
    func legacySettingsWithoutPitchDecodeNeutral() throws {
        // Shape written by the shipped synthesized Codable before this stage:
        // the four optionals are present as null in the profile envelope, and
        // every baseline-required field is present.
        let baseline = """
        {"provider":"openAI","billingRoute":"payAsYouGo","alibabaRegion":null,"modelID":"tts-1","voiceID":"alloy","speechRateRatio":1,"autoReadEnabled":false,"allowBargeIn":true,"connectionProviderID":null}
        """
        let snapshot = try decode(baseline)
        #expect(snapshot.provider == .openAI)
        #expect(snapshot.modelID == "tts-1")
        #expect(snapshot.voiceID == "alloy")
        #expect(snapshot.speechRateRatio == 1)
        #expect(snapshot.speechPitchSemitones == 0)
        #expect(!snapshot.autoReadEnabled)
        #expect(snapshot.allowBargeIn)
        #expect(snapshot.playbackControls == TTSPlaybackControls(
            speechRateRatio: 1, speechPitchSemitones: 0))

        // A non-neutral baseline rate is preserved exactly.
        let slower = try decode("""
        {"provider":"volcengine","billingRoute":"payAsYouGo","alibabaRegion":null,"modelID":"doubao-seed-tts-2.0","voiceID":"zh_female_vv_uranus_bigtts","speechRateRatio":1.35,"autoReadEnabled":true,"allowBargeIn":false,"connectionProviderID":null}
        """)
        #expect(slower.speechRateRatio == 1.35)
        #expect(slower.speechPitchSemitones == 0)
        #expect(slower.provider == .volcengine)
        #expect(slower.voiceID == "zh_female_vv_uranus_bigtts")
    }

    @Test("Malformed or incomplete stored identity is still rejected, never defaulted")
    func malformedIdentityIsStillRejected() {
        // The previous synthesized decoder required these fields. A record
        // missing its provider/route/voice/rate must keep failing instead of
        // silently becoming Apple/empty, so no corrupted store can change the
        // active route.
        let missingProvider = #"{"billingRoute":"payAsYouGo","modelID":"tts-1","voiceID":"alloy","speechRateRatio":1,"autoReadEnabled":false,"allowBargeIn":true}"#
        let missingRoute = #"{"provider":"openAI","modelID":"tts-1","voiceID":"alloy","speechRateRatio":1,"autoReadEnabled":false,"allowBargeIn":true}"#
        let missingVoice = #"{"provider":"openAI","billingRoute":"payAsYouGo","modelID":"tts-1","speechRateRatio":1,"autoReadEnabled":false,"allowBargeIn":true}"#
        let missingRate = #"{"provider":"openAI","billingRoute":"payAsYouGo","modelID":"tts-1","voiceID":"alloy","autoReadEnabled":false,"allowBargeIn":true}"#
        let unknownProvider = #"{"provider":"someone-else","billingRoute":"payAsYouGo","modelID":"tts-1","voiceID":"alloy","speechRateRatio":1,"autoReadEnabled":false,"allowBargeIn":true}"#
        for (name, json) in [
            ("provider", missingProvider), ("billingRoute", missingRoute),
            ("voiceID", missingVoice), ("speechRateRatio", missingRate),
            ("provider value", unknownProvider)
        ] {
            do {
                _ = try decode(json)
                Issue.record("A record missing \(name) must not decode: \(json)")
            } catch {}
        }
    }

    @Test("Unknown extra keys and missing optionals never break the decode")
    func unknownKeysAreIgnored() throws {
        let snapshot = try decode("""
        {"provider":"openAI","billingRoute":"payAsYouGo","alibabaRegion":null,"openAIBaseURL":null,"modelID":"gpt-4o-mini-tts","voiceID":"alloy","speechRateRatio":1,"speechPitchSemitones":-2.5,"autoReadEnabled":false,"allowBargeIn":true,"connectionProviderID":null,"futureField":"ignored"}
        """)
        #expect(snapshot.provider == .openAI)
        #expect(snapshot.speechPitchSemitones == -2.5)
        #expect(snapshot.playbackControls == TTSPlaybackControls(
            speechRateRatio: 1.0, speechPitchSemitones: -2.5))
    }

    @Test("A saved rate and pitch round-trip through encoding")
    func controlsRoundTrip() throws {
        var snapshot = TTSSettingsSnapshot(
            provider: .volcengine, billingRoute: .agentPlan,
            modelID: "doubao-seed-tts-2.0",
            voiceID: "zh_female_vv_uranus_bigtts")
        snapshot.speechRateRatio = 1.45
        snapshot.speechPitchSemitones = -3
        let decoded = try JSONDecoder().decode(
            TTSSettingsSnapshot.self, from: JSONEncoder().encode(snapshot))
        #expect(decoded == snapshot)
        #expect(decoded.playbackControls == TTSPlaybackControls(
            speechRateRatio: 1.45, speechPitchSemitones: -3))
    }

    // MARK: - Sanitizing

    @Test("Non-finite construction falls back to neutral on both axes")
    func nonFiniteFallsBackToNeutral() {
        #expect(TTSPlaybackControls(
            speechRateRatio: .nan, speechPitchSemitones: .nan) == .neutral)
        #expect(TTSPlaybackControls(
            speechRateRatio: .infinity, speechPitchSemitones: -.infinity) == .neutral)
        #expect(TTSPlaybackControls(
            speechRateRatio: -.infinity, speechPitchSemitones: .signalingNaN) == .neutral)
    }

    @Test("Finite out-of-range construction clamps to the contract range")
    func outOfRangeClamps() {
        #expect(TTSPlaybackControls(
            speechRateRatio: 0.1, speechPitchSemitones: 40) == TTSPlaybackControls(
                speechRateRatio: 0.5, speechPitchSemitones: 6))
        #expect(TTSPlaybackControls(
            speechRateRatio: 9, speechPitchSemitones: -40) == TTSPlaybackControls(
                speechRateRatio: 2, speechPitchSemitones: -6))
        #expect(TTSPlaybackControls(
            speechRateRatio: 0.5, speechPitchSemitones: -6) == TTSPlaybackControls(
                speechRateRatio: 0.5, speechPitchSemitones: -6))
    }

    @Test("Decoded settings re-sanitize a corrupt persisted control value")
    func decodingSanitizesStoredValues() throws {
        let snapshot = try decode("""
        {"provider":"apple","billingRoute":"payAsYouGo","modelID":"","voiceID":"","speechRateRatio":12,"speechPitchSemitones":-9,"autoReadEnabled":false,"allowBargeIn":true}
        """)
        #expect(snapshot.speechRateRatio == 2)
        #expect(snapshot.speechPitchSemitones == -6)
        #expect(snapshot.playbackControls == TTSPlaybackControls(
            speechRateRatio: 2, speechPitchSemitones: -6))
    }

    @Test("The snapshot initializer normalizes like the controls type")
    func snapshotInitializerNormalizes() {
        let snapshot = TTSSettingsSnapshot(
            provider: .apple, speechRateRatio: 99, speechPitchSemitones: -99)
        #expect(snapshot.speechRateRatio == 2)
        #expect(snapshot.speechPitchSemitones == -6)
    }

    @Test("playbackControls normalizes fields mutated after construction")
    func computedControlsNormalizeMutatedFields() {
        var snapshot = TTSSettingsSnapshot.systemDefault
        snapshot.speechRateRatio = 7.5
        snapshot.speechPitchSemitones = 12
        #expect(snapshot.playbackControls == TTSPlaybackControls(
            speechRateRatio: 2, speechPitchSemitones: 6))
        #expect(snapshot.playbackControls.speechRateRatio == 2)
    }

    // MARK: - Neutral + request semantics

    @Test("Neutral is exactly normal speed and unchanged pitch")
    func neutralIsRateOnePitchZero() {
        #expect(TTSPlaybackControls.neutral.speechRateRatio == 1.0)
        #expect(TTSPlaybackControls.neutral.speechPitchSemitones == 0)
        #expect(TTSPlaybackControls.neutral.isNeutral)
        #expect(!TTSPlaybackControls(speechPitchSemitones: 1).isNeutral)
        #expect(!TTSPlaybackControls(speechRateRatio: 1.2).isNeutral)
        #expect(TTSSettingsSnapshot.systemDefault.playbackControls == .neutral)
    }

    @Test("Direct synthesis requests keep their explicit provider-knob rate semantics")
    func directRequestRateStaysExplicit() {
        // A direct provider caller is NOT the configured source: its rate is
        // applied by the adapter's documented knob and must not be rewritten.
        let slow = TTSSynthesisRequest(
            provider: .volcengine, billingRoute: .payAsYouGo,
            modelID: "doubao-seed-tts-2.0", voiceID: "zh_female_vv_uranus_bigtts",
            text: "hello", speechRateRatio: 0.2)
        #expect(slow.speechRateRatio == 0.5)
        let fast = TTSSynthesisRequest(
            provider: .volcengine, billingRoute: .payAsYouGo,
            modelID: "doubao-seed-tts-2.0", voiceID: "zh_female_vv_uranus_bigtts",
            text: "hello", speechRateRatio: 3)
        #expect(fast.speechRateRatio == 2)
        let unchanged = TTSSynthesisRequest(
            provider: .volcengine, billingRoute: .payAsYouGo,
            modelID: "doubao-seed-tts-2.0", voiceID: "zh_female_vv_uranus_bigtts",
            text: "hello", speechRateRatio: 1.7)
        #expect(unchanged.speechRateRatio == 1.7)
    }
}
