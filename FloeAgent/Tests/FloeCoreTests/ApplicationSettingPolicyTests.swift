import Foundation
import Testing
@testable import FloeCore

@Suite("Portable application setting contracts")
struct ApplicationSettingPolicyTests {
    @Test func speechParametersAndQuestionDefaultsRoundTrip() throws {
        var profile = ASRProfile.openAICompatible(name: "Synthetic transcription", fileModelID: "custom-asr",
            fileEndpoint: "https://speech.example.test/v1", liveEndpoint: nil)
        profile.languages = ["zh", "en"]; profile.prompt = "Meeting vocabulary"; profile.keywords = ["Floe"]
        let record = try ApplicationSettingRecord(key: ApplicationSettingPolicy.asrKey(profile.id),
            value: ApplicationSettingRecord.encodeValue(profile)).validated()
        #expect(try JSONDecoder().decode(ASRProfile.self, from: #require(record.value)) == profile)
        let voice = TTSSettingsSnapshot(provider: .alibaba, billingRoute: .tokenPlan,
            alibabaRegion: "cn-beijing", modelID: "custom-tts", voiceID: "synthetic-voice",
            speechRateRatio: 1.25, speechPitchSemitones: 2, autoReadEnabled: true,
            allowBargeIn: false, readLinksAloud: true, language: "zh-CN")
        let voiceRecord = try ApplicationSettingRecord(key: ApplicationSettingPolicy.ttsSelection,
            value: ApplicationSettingRecord.encodeValue(voice)).validated()
        #expect(try JSONDecoder().decode(TTSSettingsSnapshot.self, from: #require(voiceRecord.value)) == voice)
        let timeout = Data("{\"optionalTimeoutSeconds\":45}".utf8)
        #expect(try ApplicationSettingPolicy.canonicalValue(timeout,
            for: "defaults.floe.settings.userQuestionDefaults.v1") == timeout)
    }

    @Test func originBoundCredentialsCannotTravelInsideMetadata() throws {
        let a = ASRProfile.openAICompatible(name: "Synthetic", fileEndpoint: "https://one.example.test/v1", liveEndpoint: nil)
        var same = a; same.fileEndpoint = "https://one.example.test/other/v1"; same.fileModelID = "new-model"
        var other = same; other.fileEndpoint = "https://two.example.test/v1"
        #expect(SpeechCredentialBinding.asrAccount(a) == SpeechCredentialBinding.asrAccount(same))
        #expect(SpeechCredentialBinding.asrAccount(a) != SpeechCredentialBinding.asrAccount(other))
        var referenced = a
        referenced.credentialReference = .init(service: "synthetic-service", account: "synthetic-account")
        #expect(throws: (any Error).self) {
            try ApplicationSettingRecord(key: ApplicationSettingPolicy.asrKey(a.id),
                value: ApplicationSettingRecord.encodeValue(referenced)).validated()
        }
        var tts = TTSSettingsSnapshot(provider: .openAI, modelID: "custom", voiceID: "voice")
        let official = SpeechCredentialBinding.ttsAccount(tts)
        tts.openAIBaseURL = "https://other.example.test/v1"
        #expect(SpeechCredentialBinding.ttsAccount(tts) != official)
    }

    @Test func tombstonesAndSafetyExclusionsAreExplicit() throws {
        for raw in ["sync.overallEnabled", "sync.savedCredentialsEnabled", "agent.defaultMode",
                    "exec.target", "workspace.default", "voice.output.pendingVoice.v1",
                    "voice.output.firstInstallSelection", "linux.runtime.root", "permissions.microphone"] {
            #expect(!ApplicationSettingPolicy.isAllowed("defaults." + raw))
            #expect(!ApplicationSettingPolicy.isAllowed("database." + raw))
        }
        let deleted = ApplicationSettingRecord(key: ApplicationSettingPolicy.ttsSelection, value: nil)
        let json = try #require(JSONSerialization.jsonObject(with: ApplicationSettingRecord.encodeValue(deleted)) as? [String: Any])
        #expect(json["value"] is NSNull)
        var missingValue = json; missingValue.removeValue(forKey: "value")
        let missingBytes = try JSONSerialization.data(withJSONObject: missingValue)
        #expect(throws: (any Error).self) { try JSONDecoder().decode(ApplicationSettingRecord.self, from: missingBytes) }
        #expect(throws: (any Error).self) { try ApplicationSettingRecord(key: deleted.key, value: nil, schemaVersion: 2).validated() }
        #expect(throws: (any Error).self) {
            try ApplicationSettingPolicy.canonicalValue(Data("{\"optionalTimeoutSeconds\":1}".utf8),
                for: "defaults.floe.settings.userQuestionDefaults.v1")
        }
    }
}
