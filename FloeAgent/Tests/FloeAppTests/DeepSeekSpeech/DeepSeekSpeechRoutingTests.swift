// SPDX-License-Identifier: MPL-2.0
#if canImport(UIKit)
import XCTest
import Foundation
import FloeCore
import FloeProviders
import FloeSecurity
import Synchronization
@testable import FloeApp

private final class DeepSeekFixtureKeys: KeychainProbeStore {
    private let values = Mutex<[String: Data]>([:])
    func store(account: String, secret: Data) throws { values.withLock { $0[account] = secret } }
    func read(account: String) throws -> Data {
        try values.withLock { guard let value = $0[account] else { throw KeychainStoreError.itemNotFound }; return value }
    }
    func delete(account: String) throws { values.withLock { _ = $0.removeValue(forKey: account) } }
}

private actor DeepSeekFileSegments: ASRTranscribing {
    private(set) var sizes: [Int] = []
    private(set) var firstRequest: ASRFileTranscriptionRequest?
    func transcribe(_ request: ASRTranscriptionRequest, credential: String) async throws -> ASRTranscriptionResult {
        XCTFail("expected a profile-bound file request"); throw ASRTranscriptionError.invalidConfiguration("fixture")
    }
    func transcribe(_ request: ASRFileTranscriptionRequest, credential: String) async throws -> ASRTranscriptionResult {
        XCTAssertEqual(request.profile.provider, .deepSeek)
        if firstRequest == nil { firstRequest = request }
        XCTAssertLessThanOrEqual(request.audio.count, DeepSeekSpeechAPI.maximumFileBytes)
        XCTAssertLessThanOrEqual(request.sourceDurationSeconds ?? .infinity, DeepSeekSpeechAPI.maximumAudioSeconds)
        sizes.append(request.audio.count - 44)
        return .init(text: "part-\(sizes.count)", segments: [], timing: .sourceSpanOnly)
    }
}

@MainActor
final class DeepSeekSpeechRoutingTests: XCTestCase {
    func testSeparateCredentialsAndExplicitInputAndReadAloudSelection() async throws {
        let name = "floe.deepseek.speech." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let keys = DeepSeekFixtureKeys()
        let input = CloudASRSettingsStore(defaults: defaults, keychain: keys)
        let output = TTSSettingsService(defaults: defaults, keychain: keys)
        let profile = try input.addProfile(CloudASRSettingsStore.ProviderPreset.deepSeek.makeProfile(), credential: "fixture-input")
        XCTAssertTrue(input.isReady(profile))
        XCTAssertEqual(try input.credential(for: profile), "fixture-input")
        input.setPrimary(profile.id)
        let selection = CloudASRRouteResolver.resolve(method: VoiceRecognitionPreferences.Method.cloud.rawValue,
            profiles: input.profiles, primaryProfileID: input.primaryProfileID, readyProfileIDs: [profile.id])
        XCTAssertEqual(selection.cloudProfile?.id, profile.id)
        XCTAssertTrue(try ASRAdapterFactory.fileAdapter(for: profile) is DeepSeekTranscriptionAdapter)
        XCTAssertNil(try ASRAdapterFactory.liveAdapter(for: profile))
        var voice = output.profile(provider: .deepSeek, route: .payAsYouGo)
        voice.voiceID = "tide"
        try output.saveProfile(voice, credential: "fixture-output")
        XCTAssertEqual(output.snapshot.provider, .apple)
        XCTAssertTrue(output.selectSource(.online(provider: .deepSeek, route: .payAsYouGo)))
        let credential = try await output.credential(for: output.snapshot)
        XCTAssertEqual(credential, "fixture-output"); XCTAssertEqual(try input.credential(for: profile), "fixture-input")
        let request = ConfiguredTTSSpeechSource.makeRequest(snapshot: output.snapshot, text: "hello", sessionID: UUID(), segmentIndex: 3)
        XCTAssertEqual(request.provider, .deepSeek); XCTAssertEqual(request.voiceID, "tide"); XCTAssertNil(request.validationProblem())
        XCTAssertTrue(TTSSpeechService().provider(for: request) is DeepSeekSpeechAdapter)
        XCTAssertEqual(output.currentOutputSource, .online(provider: .deepSeek, route: .payAsYouGo))
    }

    func testProviderEntryRecognizesOnlyOfficialHTTPSOrigin() {
        for url in ["https://api.deepseek.com", "https://api.deepseek.com:443/v1"] {
            XCTAssertTrue(DeepSeekSpeechAPI.isOfficialConnection(URL(string: url)))
        }
        for url in ["http://api.deepseek.com", "https://api.deepseek.com.example", "https://api.deepseek.com:8443", "https://user@api.deepseek.com/v1", "https://custom.example/deepseek"] {
            XCTAssertFalse(DeepSeekSpeechAPI.isOfficialConnection(URL(string: url)))
        }
    }

    func testRecognizedWAVAndOggPreserveTheirCompleteOriginalFiles() async throws {
        var stereo = CloudPCMCodec.wav(pcm16: Data([0, 0, 255, 127, 0, 0, 255, 127]), sampleRate: 16_000)
        stereo.replaceSubrange(22..<24, with: [2, 0])
        stereo.replaceSubrange(28..<32, with: [0, 250, 0, 0])
        stereo.replaceSubrange(32..<34, with: [4, 0])
        // Complete 100 ms Ogg Opus silence, encoded with libopus, including both headers and EOS.
        let ogg = try XCTUnwrap(Data(base64Encoded:
            "T2dnUwACAAAAAAAAAABI11AeAAAAAAV6mdUBE09wdXNIZWFkAQE4AYC7AAAAAABPZ2dTAAAA"
            + "AAAAAAAAAEjXUB4BAAAAAwQJwAE8T3B1c1RhZ3MMAAAATGF2ZjYzLjEuMTAyAQAAABwAAABl"
            + "bmNvZGVyPUxhdmM2My4xLjEwMiBsaWJvcHVzT2dnUwAE+BMAAAAAAABI11AeAgAAAMMBLYsG"
            + "BwYGBgYGCAvkuaC8hAgHxrMOxggHxrMOxggHxrMOxggHxrMOxggHxrMOxg=="))
        for (audio, mime) in [(stereo, "audio/wav"), (ogg, "audio/ogg")] {
            let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: url) }
            try audio.write(to: url)
            let adapter = DeepSeekFileSegments()
            _ = try await CloudASRFilePipeline.transcribe(fileURL: url, profile: .deepSeek(), adapter: adapter,
                credential: "fixture-input", language: .automatic, requiresTiming: false)
            let request = await adapter.firstRequest
            XCTAssertEqual(request?.audio, audio)
            XCTAssertEqual(request?.mimeType, mime)
            let calls = await adapter.sizes.count
            XCTAssertEqual(calls, 1)
        }
    }

    func testRecordedAudioLongerThanTwoMinutesIsCompletelyTranscribedInOrder() async throws {
        let sampleRate = 16_000
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".wav")
        defer { try? FileManager.default.removeItem(at: file) }
        let pcm = Data(repeating: 0, count: sampleRate * 2 * 121)
        try CloudPCMCodec.wav(pcm16: pcm, sampleRate: sampleRate).write(to: file)
        let adapter = DeepSeekFileSegments()
        let result = try await CloudASRFilePipeline.transcribe(fileURL: file, profile: .deepSeek(), adapter: adapter,
            credential: "fixture-input", language: .automatic, requiresTiming: false)
        let chunks = await adapter.sizes
        XCTAssertEqual(chunks, [sampleRate * 2 * 120, sampleRate * 2])
        XCTAssertEqual(result.text, "part-1\npart-2"); XCTAssertTrue(result.segments.isEmpty)
    }
}
#endif
