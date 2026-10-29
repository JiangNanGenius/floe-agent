// FloeProvidersTests — source-specific spoken projection and accepted MOSS
// flatPause planning. Pure text only; no model, network or device.
#if canImport(Foundation)
import Foundation
import Testing
import FloeCore
@testable import FloeProviders

@Suite("Speech text routing")
struct SpeechTextRoutingTests {
    private func substring(_ value: String, utf16Start: Int, utf16Length: Int) -> String {
        let ns = value as NSString
        return ns.substring(with: NSRange(location: utf16Start, length: utf16Length))
    }

    @Test("Cloud keeps the authored URL and Markdown label")
    func cloudKeepsURLs() {
        let source = "Read [the docs](https://example.com:8080/a/b/?q=1) and https://example.org/x/."
        let projection = SpeechAnswerProjection.project(source, destination: .cloud)
        #expect(projection.spokenText.contains("the docs https://example.com:8080/a/b/?q=1"))
        #expect(projection.spokenText.contains("https://example.org/x/"))
        #expect(projection.spans.count == 2)
        #expect(projection.spans.allSatisfy { $0.kind == .url })
    }

    @Test("Local Read-links off keeps the label and drops every URL")
    func localOffDropsURLs() {
        let source = "Read [the docs](https://example.com:8080/a/b/) and https://example.org/x/."
        let projection = SpeechAnswerProjection.project(
            source, destination: .local(readLinks: false, language: .chinese))
        #expect(projection.spokenText.contains("the docs"))
        #expect(!projection.spokenText.contains("https"))
        #expect(!projection.spokenText.contains("example.com"))
        #expect(projection.spans.count == 2)
        #expect(projection.spans.allSatisfy { $0.kind == .removedURL })
        #expect(projection.spans.allSatisfy { $0.spokenUTF16Length == 0 })
    }

    @Test("Local Read-links on pronounces the entire URL, port and final slash")
    func localOnPronouncesFullURL() throws {
        let url = "https://example.com:8080/a/"
        let projection = SpeechAnswerProjection.project(
            url, destination: .local(readLinks: true, language: .english))
        #expect(projection.spokenText.hasPrefix("aitch tee tee pee ess colon slash slash"))
        #expect(projection.spokenText.contains("ee ex ay em pee ell ee dot cee oh em colon eight zero eight zero slash ay slash"))
        #expect(projection.spokenText.hasSuffix("slash"))
        let pronunciation = try #require(projection.urls.first)
        #expect(pronunciation.spoken == projection.spokenText)
        let span = try #require(projection.spans.first)
        #expect(span.kind == .url)
        #expect(substring(projection.spokenText,
            utf16Start: span.spokenUTF16Start, utf16Length: span.spokenUTF16Length)
            == pronunciation.spoken)
    }

    @Test("URL source and spoken spans use the same UTF-16 coordinates")
    func urlSpansMapBothWays() {
        let source = "A **bold** https://a.example:1/ and [second](https://b.example:2/x/)."
        let projection = SpeechAnswerProjection.project(
            source, destination: .local(readLinks: true, language: .chinese))
        #expect(projection.spans.count == 2)
        for span in projection.spans {
            #expect(substring(projection.sourceText,
                utf16Start: span.sourceUTF16Start, utf16Length: span.sourceUTF16Length) == span.url)
            #expect(span.spokenUTF16Start >= 0)
            #expect(span.spokenUTF16Start + span.spokenUTF16Length <= projection.spokenText.utf16.count)
        }
        #expect(!projection.spokenText.contains("**"))
    }

    @Test("URL pronunciation units cover every source character and preserve the final slash")
    func urlUnitsCoverSource() {
        let url = "https://127.0.0.1:8080/"
        let pronunciation = SpeechURLPronouncer.pronounce(url, language: .chinese)
        var rebuilt = ""
        for unit in pronunciation.units {
            rebuilt += substring(url, utf16Start: unit.sourceUTF16Start,
                                 utf16Length: unit.sourceUTF16Length)
        }
        #expect(rebuilt == url)
        #expect(pronunciation.spoken.contains("八 零 八 零"))
        #expect(pronunciation.spoken.hasSuffix("斜杠"))
        var previousEnd = 0
        for unit in pronunciation.units {
            #expect(unit.sourceUTF16Start == previousEnd)
            previousEnd = unit.sourceUTF16Start + unit.sourceUTF16Length
        }
        #expect(previousEnd == url.utf16.count)
    }

    @Test("Cloud link projection preserves a final slash and query")
    func cloudTrailingSlashAndQuery() {
        let source = "See https://example.com:443/path/?a=1&b=2."
        let projection = SpeechAnswerProjection.project(source, destination: .cloud)
        #expect(projection.spokenText.contains("https://example.com:443/path/?a=1&b=2"))
        #expect(projection.spokenText.hasSuffix("."))
    }

    @Test("Transcription endpoint composes once and rejects insecure URLs")
    func transcriptionEndpoint() throws {
        #expect(try OpenAITranscriptionEndpoint.endpointURL(base: nil)
            == OpenAITranscriptionEndpoint.officialURL)
        #expect(try OpenAITranscriptionEndpoint.endpointURL(base: "https://api.openai.com/v1")
            == OpenAITranscriptionEndpoint.officialURL)
        let proxy = try OpenAITranscriptionEndpoint.endpointURL(base: "https://proxy.example/v1")
        #expect(proxy.absoluteString == "https://proxy.example/v1/audio/transcriptions")
        let full = try OpenAITranscriptionEndpoint.endpointURL(
            base: "https://proxy.example/v1/audio/transcriptions")
        #expect(full.absoluteString == "https://proxy.example/v1/audio/transcriptions")
        #expect(throws: ASRTranscriptionError.self) {
            _ = try OpenAITranscriptionEndpoint.endpointURL(base: "http://proxy.example/v1")
        }
        #expect(throws: ASRTranscriptionError.self) {
            _ = try OpenAITranscriptionEndpoint.endpointURL(base: "https://user:key@proxy.example/v1")
        }
    }

    @Test("Accepted flatPause fixture reproduces the baseline exactly")
    func acceptedFlatPauseFixture() {
        let source = "报告已完成。 The report is ready。 数据已核对。 The numbers look right。 请保存原件。 Please keep the files。 明天再讨论。 We can talk tomorrow."
        let plan = MossProsodyPlanner.flatPause(source)
        #expect(plan.eligible)
        #expect(plan.reason == "eligible")
        #expect(plan.spoken == "报告已完成，The report is ready，数据已核对，The numbers look right，请保存原件，Please keep the files，明天再讨论，We can talk tomorrow.")
        #expect(plan.sourceWordSequencePreserved)
        #expect(plan.finalTerminatorPreserved)
        #expect(plan.edits.count == 7)
        #expect(MossProsodyPlanner.reconstructing(plan.spoken, with: plan.edits) == source)
        #expect(plan.units.count == 8)
        #expect(plan.units.map(\.language) == ["zh", "en", "zh", "en", "zh", "en", "zh", "en"])
    }

    @Test("Ineligible paragraphs stay byte-identical")
    func ineligibleUnchanged() {
        for source in [
            "See https://example.com/a/ for details.",
            "Hello. Hello. Hello. Hello.",
            "第一句。第二句。第三句。第四句。",
            "A short quote: “Hello.” Then another.",
        ] {
            let plan = MossProsodyPlanner.flatPause(source)
            #expect(!plan.eligible)
            #expect(plan.spoken == source)
            #expect(plan.edits.isEmpty)
        }
    }

    @Test("Streaming classifier only marks short declarative units")
    func classifierGate() {
        #expect(MossProsodyPlanner.classify("报告已完成。") == .shortChinese)
        #expect(MossProsodyPlanner.classify("The report is ready.") == .shortEnglish)
        #expect(MossProsodyPlanner.classify("这是一个很长很长的句子，包含很多超过门槛的中文字符，因此不应该被归为短句。") == .other)
        #expect(MossProsodyPlanner.classify("Is this a question?") == .other)
    }
}
#endif
