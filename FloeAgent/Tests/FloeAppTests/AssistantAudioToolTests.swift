// FloeAppTests — assistant file transcription/synthesis tool contracts and
// real caption/audio byte helpers. No App build, network or device.
#if canImport(UIKit)
import Foundation
import Testing
@testable import FloeApp

@Suite("Assistant audio tools")
struct AssistantAudioToolTests {
    private func schema(_ json: String) throws -> [String: Any] {
        try #require(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
    }

    #if canImport(WhisperKit)
    @Test("Transcription schema preserves language and adds direct/TXT output")
    func transcriptionSchema() throws {
        let object = try schema(AudioTranscribeTool.parametersJSON)
        let required = try #require(object["required"] as? [String])
        #expect(required == ["path"])
        let properties = try #require(object["properties"] as? [String: Any])
        #expect(properties["output"] != nil)
        #expect(properties["format"] != nil)
        #expect(properties["service"] != nil)
        let format = try #require(properties["format"] as? [String: Any])
        #expect(Set(try #require(format["enum"] as? [String])) == ["text", "srt", "vtt", "json"])
        let language = try #require(properties["language"] as? [String: Any])
        #expect(Set(try #require(language["enum"] as? [String]))
            == Set(VoiceRecognitionLanguage.allCases.map(\.rawValue)))
    }
    #endif

    @Test("Synthesis schema requires text and a concrete output path")
    func synthesisSchema() throws {
        let object = try schema(AudioSynthesizeTool.parametersJSON)
        #expect(try #require(object["required"] as? [String]) == ["text", "output"])
        let properties = try #require(object["properties"] as? [String: Any])
        #expect(properties["service"] != nil)
        #expect(AudioSynthesizeTool.riskLabels.contains(.writesFiles))
        #expect(AudioSynthesizeTool.riskLabels.contains(.sendsDataToProvider))
    }


    @Test("Legacy single-service preference migrates to first priority")
    func legacyPreferenceMigration() throws {
        let legacy = Data(#"{"transcriptionServiceID":"asr.cloud.openai-compatible","synthesisServiceID":"tts.system","asrModelID":"whisper-1"}"#.utf8)
        let preferences = try JSONDecoder().decode(AssistantAudioPreferences.self, from: legacy)
        #expect(preferences.transcriptionPriority == ["asr.cloud.openai-compatible"])
        #expect(preferences.synthesisPriority == ["tts.system"])
        let encoded = try JSONEncoder().encode(preferences)
        let object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        #expect(object["transcriptionServiceID"] == nil)
        #expect(object["synthesisServiceID"] == nil)
        #expect(object["transcriptionPriority"] as? [String] == ["asr.cloud.openai-compatible"])
    }

    @Test("Priority arrays are deduplicated and trim empty IDs")
    func priorityDeduplication() {
        let preferences = AssistantAudioPreferences(
            transcriptionPriority: ["a", "a", " ", "b"],
            synthesisPriority: ["x", "x"])
        #expect(preferences.transcriptionPriority == ["a", "b"])
        #expect(preferences.synthesisPriority == ["x"])
    }

    @Test("Service discovery is read-only and exposes no secret")
    func serviceToolBoundary() {
        #expect(AudioServicesTool.toolEffect == .readOnly)
        #expect(!AudioServicesTool.isSideEffecting)
        #expect(AudioServicesTool.riskLabels.isEmpty)
    }

    #if canImport(WhisperKit)
    @Test("Old file output still validates; direct text and format mismatches are explicit")
    func transcriptionValidation() throws {
        let srt = AudioTranscribeTool.Arguments(
            path: "audio.m4a", output: "captions.srt", format: nil,
            language: "simplifiedChinese", service: nil)
        try AudioTranscribeTool().validate(srt)

        let direct = AudioTranscribeTool.Arguments(
            path: "audio.m4a", output: nil, format: "text",
            language: nil, service: nil)
        try AudioTranscribeTool().validate(direct)

        let txt = AudioTranscribeTool.Arguments(
            path: "audio.m4a", output: "transcript.txt", format: "text",
            language: nil, service: nil)
        try AudioTranscribeTool().validate(txt)

        let mismatch = AudioTranscribeTool.Arguments(
            path: "audio.m4a", output: "transcript.txt", format: "srt",
            language: nil, service: nil)
        #expect(throws: (any Error).self) { try AudioTranscribeTool().validate(mismatch) }

        let badFormat = AudioTranscribeTool.Arguments(
            path: "audio.m4a", output: nil, format: "xml",
            language: nil, service: nil)
        #expect(throws: (any Error).self) { try AudioTranscribeTool().validate(badFormat) }
    }
    #endif

    @Test("Synthesis validation only accepts real audio file extensions")
    func synthesisValidation() throws {
        let wav = AudioSynthesizeTool.Arguments(text: "Hello.", output: "hello.wav", service: nil)
        try AudioSynthesizeTool().validate(wav)
        let mp3 = AudioSynthesizeTool.Arguments(text: "Hello.", output: "hello.mp3", service: nil)
        #expect(throws: (any Error).self) { try AudioSynthesizeTool().validate(mp3) }
        let empty = AudioSynthesizeTool.Arguments(text: "  ", output: "hello.wav", service: nil)
        #expect(throws: (any Error).self) { try AudioSynthesizeTool().validate(empty) }
    }

    #if canImport(WhisperKit)
    @Test("Caption export preserves SRT/VTT/JSON and adds exact TXT")
    func captionExport() throws {
        let segments = [
            TimedSpeechSegment(start: 0, end: 1.25, text: "Hello & <world>", words: []),
            TimedSpeechSegment(start: 1.25, end: 2.5, text: "第二句。", words: []),
        ]
        let srt = String(decoding: try SpeechCaptionExport.data(segments: segments, format: "srt"), as: UTF8.self)
        #expect(srt.contains("00:00:00,000 --> 00:00:01,250"))
        #expect(srt.contains("Hello &amp; &lt;world&gt;"))
        let vtt = String(decoding: try SpeechCaptionExport.data(segments: segments, format: "vtt"), as: UTF8.self)
        #expect(vtt.hasPrefix("WEBVTT\n\n"))
        #expect(vtt.contains("00:00:01.250 --> 00:00:02.500"))
        let json = try SpeechCaptionExport.data(segments: segments, format: "json")
        #expect(try JSONDecoder().decode([TimedSpeechSegment].self, from: json).count == 2)
        let txt = String(decoding: try SpeechCaptionExport.data(segments: segments, format: "text"), as: UTF8.self)
        #expect(txt == "Hello & <world>\n第二句。")
        #expect(SpeechCaptionExport.plainText(segments: segments) == txt)
    }
    #endif
}
#endif
