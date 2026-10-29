// FloeAppTests — local MOSS flatPause preparation and assistant-audio source
// projection. Pure text/bytes only; no model mount, network or device.
#if canImport(UIKit)
import Foundation
import Testing
import FloeCore
import FloeProviders
@testable import FloeApp

@Suite("Local speech preparation")
struct LocalSpeechPreparationTests {
    private let acceptedSource = "报告已完成。 The report is ready。 数据已核对。 The numbers look right。 请保存原件。 Please keep the files。 明天再讨论。 We can talk tomorrow."
    private let acceptedSpoken = "报告已完成，The report is ready，数据已核对，The numbers look right，请保存原件，Please keep the files，明天再讨论，We can talk tomorrow."
    private let acceptedUnits = [
        "报告已完成。", "The report is ready。", "数据已核对。", "The numbers look right。",
        "请保存原件。", "Please keep the files。", "明天再讨论。", "We can talk tomorrow.",
    ]

    @Test("MOSS paragraph planning is applied only to the MOSS engine")
    func mossOnlyParagraphPlanning() {
        #expect(MossSpeechPreparation.prepareParagraphs(acceptedSource, engine: "mossTTSNano")
            == acceptedSpoken)
        #expect(MossSpeechPreparation.prepareParagraphs(acceptedSource, engine: "qwen3TTS")
            == acceptedSource)
        #expect(MossSpeechPreparation.prepareParagraphs(acceptedSource, engine: nil)
            == acceptedSource)
    }

    @Test("Streaming alternation produces the accepted flatPause request")
    func streamingAlternation() {
        var preparation = MossProsodyStreamPreparation()
        let emitted = preparation.accept(acceptedUnits) + preparation.finish()
        #expect(emitted.count == 2)
        #expect(emitted.joined(separator: " ").contains("报告已完成，The report is ready，"))
        #expect(emitted.joined(separator: " ").contains("请保存原件，Please keep the files，"))
        #expect(!emitted.joined(separator: " ").contains("。 The"))
    }

    @Test("Non-alternating short sentences flush without waiting")
    func nonAlternatingFlushes() {
        var preparation = MossProsodyStreamPreparation()
        #expect(preparation.accept(["第一句。", "第二句。"]) == ["第一句。", "第二句。"])
        #expect(preparation.finish().isEmpty)
    }

    @Test("Destination routing separates cloud prose from local Read-links")
    func destinationRouting() {
        let cloud = TTSSettingsSnapshot(
            provider: .openAI, billingRoute: .payAsYouGo,
            modelID: "gpt-4o-mini-tts", voiceID: "alloy")
        #expect(AnswerSpeechText.destination(for: cloud, text: "看看 https://example.com/")
            == .cloud)

        let local = TTSSettingsSnapshot(
            provider: .onDevice, billingRoute: .payAsYouGo,
            modelID: "moss-tts-nano-100m-coreml", voiceID: "default",
            readLinksAloud: true, language: "zh-CN")
        #expect(AnswerSpeechText.destination(for: local, text: "看看 https://example.com/")
            == .local(readLinks: true, language: .chinese))
        #expect(AnswerSpeechText.destination(
            for: TTSSettingsSnapshot(provider: .onDevice, modelID: "m", voiceID: "v"),
            text: "看看 https://example.com/")
            == .local(readLinks: false, language: .chinese))
    }

    @Test("Cloud read-aloud keeps a URL; local default keeps only the label")
    func externalProjection() {
        let source = "看[文档](https://example.com:8080/a/) 和 https://example.org/x/"
        let cloud = AnswerSpeechText.spokenText(source, destination: .cloud)
        #expect(cloud.contains("看文档 https://example.com:8080/a/"))
        #expect(cloud.contains("https://example.org/x/"))
        let local = AnswerSpeechText.spokenText(
            source, destination: .local(readLinks: false, language: .chinese))
        #expect(local.contains("看文档"))
        #expect(!local.contains("https://"))
        let spokenLocal = AnswerSpeechText.spokenText(
            source, destination: .local(readLinks: true, language: .chinese))
        #expect(spokenLocal.contains("冒号 八 零 八 零 斜杠"))
        #expect(spokenLocal.contains("斜杠"))
    }

    @Test("A planned paragraph remains one complete-sentence request")
    func plannedParagraphSegmentation() {
        let segments = AssistantAudioService.completeSentences(acceptedSpoken)
        #expect(segments == [acceptedSpoken])
    }

    @Test("WAV writer emits a valid bounded PCM header")
    func wavHeader() throws {
        let pcm = Data([0x00, 0x00, 0x01, 0x00])
        let wav = AssistantAudioFileWriter.wavData(pcm: pcm, sampleRate: 24_000)
        #expect(wav.count == 44 + pcm.count)
        #expect(String(data: wav[0..<4], encoding: .ascii) == "RIFF")
        #expect(String(data: wav[8..<12], encoding: .ascii) == "WAVE")
        #expect(String(data: wav[36..<40], encoding: .ascii) == "data")
        #expect(Array(wav[40..<44]) == [0x04, 0x00, 0x00, 0x00])
    }

    @Test("Inline player embeds real audio and escapes the title")
    func inlinePlayer() throws {
        let pcm = Data(repeating: 0, count: 200)
        let wav = AssistantAudioFileWriter.wavData(pcm: pcm, sampleRate: 24_000)
        let html = try #require(AssistantAudioInlinePlayer.html(
            audio: wav, mimeType: "audio/wav", title: "<script>x</script>"))
        let text = try #require(String(data: html, encoding: .utf8))
        #expect(text.contains("<audio controls"))
        #expect(text.contains("data:audio/wav;base64,"))
        #expect(!text.contains("<script>x</script>"))
        #expect(text.contains("&lt;script&gt;"))
    }


    @Test("URL-only local Read-links OFF completes as zero speech units")
    func urlOnlyLocalOffCompletesWithoutSynthesis() {
        let url = "https://example.com:8080/"
        let local = TTSSettingsSnapshot(
            provider: .onDevice, billingRoute: .payAsYouGo,
            modelID: "moss-tts-nano-100m-coreml", voiceID: "default",
            readLinksAloud: false, language: "zh-CN")
        let context = VoiceSpeechProjectionContext(local)
        let normalized = context.normalize(url)
        #expect(normalized.isEmpty)
        #expect(AssistantAudioService.completeSentences(normalized).isEmpty)
        #expect(AnswerSpeechText.spokenText("看 \(url)", settings: local) == "看")
        #expect(AnswerSpeechText.spokenText("https://example.com.", settings: local).isEmpty)
        let voiceNormalizer = VoiceSpeechProjectionContext(local, mossEngine: true)
        #expect(voiceNormalizer.normalize(acceptedSource) == acceptedSpoken)

        let cloud = TTSSettingsSnapshot(
            provider: .openAI, billingRoute: .payAsYouGo,
            modelID: "gpt-4o-mini-tts", voiceID: "alloy")
        #expect(AnswerSpeechText.spokenText(url, settings: cloud) == url)
        #expect(!AssistantAudioService.completeSentences(url).isEmpty)
    }

    @Test("Local pronunciation and pause changes keep captions in source text")
    func captionsRetainSource() {
        var local = TTSSettingsSnapshot(
            provider: .onDevice, billingRoute: .payAsYouGo,
            modelID: "moss-tts-nano-100m-coreml", voiceID: "default",
            readLinksAloud: true, language: "en")
        let source = "Open https://example.com:8080/a/ now."
        let context = VoiceSpeechProjectionContext(local)
        let spoken = context.normalize(source)
        #expect(spoken != source)
        #expect(context.caption(for: spoken) == source)
        #expect(context.caption(for: "Open") == "Open")
        local.readLinksAloud = false
        context.update(local)
        let trimmed = context.normalize("https://example.com/ Hello.")
        #expect(trimmed == "Hello.")
        #expect(context.caption(for: trimmed) == "Hello.")
        let moss = VoiceSpeechProjectionContext(local, mossEngine: true)
        #expect(moss.caption(for: moss.normalize(acceptedSource)) == acceptedSource)
        #expect(MossSpeechPreparation.prepareParagraphs("  " + acceptedSource + "  ",
            engine: MossSpeechPreparation.mossEngine) == "  " + acceptedSpoken + "  ")
    }

    @Test("Assistant audio MIME mapping is concrete")
    func mimeMapping() {
        #expect(AssistantAudioService.mimeType(for: "wav") == "audio/wav")
        #expect(AssistantAudioService.mimeType(for: "m4a") == "audio/mp4")
        #expect(AssistantAudioService.mimeType(for: "mp4") == "video/mp4")
        #expect(AssistantAudioService.mimeType(for: "unknown") == "application/octet-stream")
    }
}
#endif
