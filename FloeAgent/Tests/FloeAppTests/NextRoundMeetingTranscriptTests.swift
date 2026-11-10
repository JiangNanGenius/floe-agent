// SPDX-License-Identifier: MPL-2.0
#if canImport(UIKit)
import Foundation
import Testing
@testable import FloeApp

@Suite("RQ27 speaker bubbles preserve actual source and reader position", .serialized)
struct NextRoundMeetingTranscriptTests {
    let meeting = UUID(), recording = UUID()
    func segment(_ text: String, start: Double = 0, end: Double = 1,
                 speaker: UUID? = nil, session: UUID? = nil, id: UUID = UUID(), final: Bool = true) -> MeetingTranscriptFragment {
        .init(id: id, meetingID: meeting, sessionID: session ?? recording, speakerID: speaker,
              start: final ? start : nil, end: final ? end : nil, text: text, isFinal: final)
    }

    @Test("Consecutive short finalized chunks merge across analysis sessions and preserve repeated speech and exact times")
    func shortChunksBecomeOneReadableBubble() throws {
        let firstAnalysis = UUID(), secondAnalysis = UUID()
        let first = segment("yes", session: firstAnalysis)
        let second = segment("yes", start: 1.1, end: 2, session: secondAnalysis)
        let output = MeetingTranscriptPresentation.bubbles([first, second], originalSessions: [firstAnalysis: recording, secondAnalysis: recording])
        #expect(output.count == 1)
        let bubble = try #require(output.first)
        #expect(bubble.id == first.id && bubble.text == "yes yes")
        #expect(bubble.speakerID == nil && bubble.recordingID == recording)
        #expect(bubble.fragments == [first, second])
        #expect(bubble.playbackRange?.start == 0 && bubble.playbackRange?.end == 2)
    }

    @Test("Speaker change, real pause and a different recording separate bubbles")
    func actualSpeechBoundariesSeparateBubbles() {
        let alice = UUID(), bob = UUID(), otherRecording = UUID()
        let speakers = [MeetingTranscriptSpeaker(id: alice, label: "Alice", mergedInto: nil),
                        MeetingTranscriptSpeaker(id: bob, label: "Bob", mergedInto: nil)]
        let source = [segment("one", speaker: alice), segment("two", start: 1.1, end: 2, speaker: bob),
                      segment("three", start: 8, end: 9, speaker: bob), segment("four", speaker: bob, session: otherRecording)]
        let output = MeetingTranscriptPresentation.bubbles(source, speakers: speakers)
        #expect(output.count == 4)
        #expect(output.flatMap(\.fragments) == source)
    }

    @Test("A partial updates its existing tail and a final with the same ID replaces it once without duplicate text")
    func liveTailFinalizationIsIdentityBound() throws {
        let first = segment("Hello", start: 0, end: 1), tailID = UUID()
        let old = segment("wo", id: tailID, final: false)
        let newest = segment("world", id: tailID, final: false)
        let live = MeetingTranscriptPresentation.bubbles([first, old, newest])
        #expect(live.count == 1 && live.first?.id == first.id)
        #expect(live.first?.text == "Hello world" && live.first?.hasLiveTail == true)
        #expect(live.first?.playbackRange?.end == 1)
        let final = segment("world.", start: 1.1, end: 2, id: tailID)
        let settled = MeetingTranscriptPresentation.bubbles([first, final, newest])
        let bubble = try #require(settled.first)
        #expect(bubble.id == first.id && bubble.fragments.count == 2 && bubble.text == "Hello world.")
        #expect(!bubble.hasLiveTail && bubble.fragments.last?.id == tailID && bubble.playbackRange?.end == 2)
    }

    @Test("A speaker merge changes only display identity; missing or cyclic attribution remains unknown")
    func speakerResolutionNeverInventsAttribution() {
        let former = UUID(), target = UUID(), cycle = UUID(), missing = UUID()
        let speakers = [MeetingTranscriptSpeaker(id: former, label: "Old", mergedInto: target),
                        MeetingTranscriptSpeaker(id: target, label: "Alice", mergedInto: nil)]
        let first = segment("Hello", speaker: former), second = segment("again", start: 1.1, end: 2, speaker: target)
        let output = MeetingTranscriptPresentation.bubbles([first, second], speakers: speakers)
        #expect(output.count == 1 && output.first?.speakerID == target)
        #expect(output.first?.fragments == [first, second])
        let lookup = [cycle: MeetingTranscriptSpeaker(id: cycle, label: "Unverified", mergedInto: cycle)]
        #expect(MeetingTranscriptPresentation.resolvedSpeaker(cycle, speakers: lookup) == nil)
        #expect(MeetingTranscriptPresentation.resolvedSpeaker(missing, speakers: lookup) == nil)
        #expect(MeetingTranscriptPresentation.resolvedSpeaker(nil, speakers: lookup) == nil)
    }

    @Test("Display spacing joins Chinese and English chunks without editing punctuation or raw fragments")
    func textSpacingPreservesOriginals() {
        #expect(MeetingTranscriptPresentation.join("你好", "，世界。") == "你好，世界。")
        #expect(MeetingTranscriptPresentation.join("我们", "开始。") == "我们开始。")
        #expect(MeetingTranscriptPresentation.join("Hello", "world.") == "Hello world.")
        #expect(MeetingTranscriptPresentation.join("Version", "2") == "Version 2")
        #expect(MeetingTranscriptPresentation.join("A ", "B") == "A B")
    }

    @Test("Appending live speech preserves all earlier bubble anchors and original source rows")
    func historicalAnchorsStayStableOnAppend() {
        let first = segment("First sentence."), second = segment("Second", start: 8, end: 9)
        let earlier = MeetingTranscriptPresentation.bubbles([first, second])
        let third = segment("sentence.", start: 9.2, end: 10)
        let later = MeetingTranscriptPresentation.bubbles([first, second, third])
        #expect(earlier.count == 2 && later.count == 2)
        #expect(later.first == earlier.first)
        #expect(later.map(\.id) == earlier.map(\.id))
        #expect(later.flatMap(\.fragments) == [first, second, third])
    }

    @Test("Correction or language changes invalidate old translation, and an obsolete failure cannot color the new source")
    func translationAlwaysMatchesCurrentSourceAndLanguage() {
        let binding = MeetingTranslationBinding(original: "old", language: "Chinese")
        let cache = MeetingTranslationValue(binding: binding, text: "旧")
        #expect(MeetingTranslationDisplay.resolve(text: "old", language: "Chinese", cached: cache) == .ready("旧"))
        #expect(MeetingTranslationDisplay.resolve(text: "corrected", language: "Chinese", cached: cache) == .stale)
        #expect(MeetingTranslationDisplay.resolve(text: "old", language: "Japanese", cached: cache) == .stale)
        #expect(MeetingTranslationDisplay.resolve(text: "corrected", language: "Chinese", cached: nil, failure: binding) == .missing)
        let current = MeetingTranslationBinding(original: "corrected", language: "Chinese")
        #expect(MeetingTranslationDisplay.resolve(text: "corrected", language: "Chinese", cached: cache, inFlight: current) == .translating)
        #expect(MeetingTranslationDisplay.resolve(text: "corrected", language: "Chinese", cached: cache, failure: current) == .failed)
    }

    @Test("Reading older speech suspends following; content updates do not pull the reader back until Return to live")
    func readerPositionIsAnExplicitIntent() {
        var reader = MeetingTranscriptFollowState()
        #expect(reader.shouldScrollForContentUpdate)
        reader.userScrolled(nearLiveEnd: false)
        for _ in 0..<5 { #expect(!reader.shouldScrollForContentUpdate) }
        reader.returnToLive()
        #expect(reader.shouldScrollForContentUpdate)
        reader.userScrolled(nearLiveEnd: true)
        #expect(reader.followsLive)
    }

    @Test("Dense continuous speech is bounded without deleting a word or splitting source identities")
    func groupingHasReadableSizeBoundaries() {
        var limits = MeetingTranscriptPresentation.Limits()
        limits.maximumCharacters = 8; limits.maximumFragments = 2
        let source = [segment("one"), segment("two", start: 1, end: 2), segment("three", start: 2, end: 3)]
        let output = MeetingTranscriptPresentation.bubbles(source, limits: limits)
        #expect(output.count == 2 && output.first?.fragments.count == 2)
        #expect(output.flatMap(\.fragments) == source)
    }

    @Test("Different timed repetitions and out-of-order ranges are retained, not removed by text matching")
    func repeatedWordsAreEvidenceNotDeduplicationKeys() {
        let first = segment("again", start: 8, end: 9), second = segment("again", start: 2, end: 3)
        let output = MeetingTranscriptPresentation.bubbles([first, second])
        #expect(output.count == 2 && output.flatMap(\.fragments) == [first, second])
        let invalid = segment("no timestamp", start: .nan, end: .infinity)
        #expect(MeetingTranscriptPresentation.bubbles([invalid]).first?.playbackRange == nil)
    }
}


@Suite("RQ27 saved translation metadata stays backward compatible")
struct NextRoundMeetingTranslationPersistenceTests {
    @Test("A pre-update translation decodes intact but cannot claim a target language it never saved")
    func legacyTranslationPreservesBytesAndNeedsRefresh() throws {
        struct Legacy: Encodable { let original: String; let text: String }
        let data = try JSONEncoder().encode(Legacy(original: "Hello", text: "你好"))
        let value = try JSONDecoder().decode(MeetingIntelligenceState.Translation.self, from: data)
        #expect(value.original == "Hello" && value.text == "你好" && value.language == nil)
        let cached = MeetingTranslationValue(binding: .init(original: value.original, language: value.language ?? ""), text: value.text)
        #expect(MeetingTranslationDisplay.resolve(text: "Hello", language: "中文", cached: cached) == .stale)
    }
    @Test("The new translation retains exact source/target through save/reopen and a correction makes it stale")
    func newTranslationRoundTripsAndCorrectionInvalidatesIt() throws {
        let value = MeetingIntelligenceState.Translation(original: "Ship it.", text: "发布。", language: "中文")
        let restored = try JSONDecoder().decode(MeetingIntelligenceState.Translation.self, from: JSONEncoder().encode(value))
        #expect(restored.language == "中文" && restored.original == value.original && restored.text == value.text)
        let cached = MeetingTranslationValue(binding: .init(original: restored.original, language: restored.language ?? ""), text: restored.text)
        #expect(MeetingTranslationDisplay.resolve(text: "Ship it.", language: "中文", cached: cached) == .ready("发布。"))
        #expect(MeetingTranslationDisplay.resolve(text: "Do not ship it.", language: "中文", cached: cached) == .stale)
    }
}

#endif
