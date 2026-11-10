// SPDX-License-Identifier: MPL-2.0
import Foundation

/// A display projection of an existing native segment/partial. Its identity,
/// source session, exact text and time remain available for correction/citation.
/// No speaker, punctuation, transcript or word timing is synthesized here.
struct MeetingTranscriptFragment: Equatable, Sendable, Identifiable {
    let id: UUID
    let meetingID: UUID
    let sessionID: UUID
    let speakerID: UUID?
    let start: Double?
    let end: Double?
    let text: String
    let isFinal: Bool

    var hasValidRange: Bool {
        guard let start, let end else { return false }
        return start.isFinite && end.isFinite && start >= 0 && end > start
    }
}
struct MeetingTranscriptSpeaker: Equatable, Sendable {
    let id: UUID
    let label: String
    let mergedInto: UUID?
}
struct MeetingTranscriptBubble: Equatable, Sendable, Identifiable {
    var id: UUID { fragments[0].id }
    let meetingID: UUID
    let recordingID: UUID
    let speakerID: UUID?
    var fragments: [MeetingTranscriptFragment]
    var hasLiveTail: Bool { fragments.contains { !$0.isFinal } }
    var text: String { fragments.map(\.text).reduce("") { MeetingTranscriptPresentation.join($0, $1) } }
    /// Only verified final ranges support playback. Unfinalized tail text has
    /// no invented timestamps and cannot change the range of committed speech.
    var playbackRange: (start: Double, end: Double)? {
        let finals = fragments.filter(\.isFinal)
        guard !finals.isEmpty, finals.allSatisfy(\.hasValidRange),
              let start = finals.first?.start, let end = finals.compactMap(\.end).max() else { return nil }
        return (start, end)
    }
    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.meetingID == rhs.meetingID && lhs.recordingID == rhs.recordingID
            && lhs.speakerID == rhs.speakerID && lhs.fragments == rhs.fragments
    }
}

enum MeetingTranscriptPresentation {
    /// Display grouping, separate from capture chunk size and persisted rows.
    struct Limits: Sendable {
        var maximumGap: Double = 2
        var maximumDuration: Double = 45
        var maximumCharacters: Int = 480
        var maximumFragments: Int = 20
    }
    static func resolvedSpeaker(_ id: UUID?, speakers: [UUID: MeetingTranscriptSpeaker]) -> UUID? {
        var cursor = id, seen = Set<UUID>()
        while let current = cursor {
            guard seen.count < 64, seen.insert(current).inserted,
                  let speaker = speakers[current] else { return nil }
            if let target = speaker.mergedInto { cursor = target }
            else { return speaker.label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : current }
        }
        return nil
    }
    static func bubbles(_ input: [MeetingTranscriptFragment], speakers suppliedSpeakers: [MeetingTranscriptSpeaker] = [],
                        originalSessions: [UUID: UUID] = [:], limits: Limits = Limits()) -> [MeetingTranscriptBubble] {
        var speakers: [UUID: MeetingTranscriptSpeaker] = [:]
        for speaker in suppliedSpeakers { speakers[speaker.id] = speaker }
        // The same native ID transitions from partial to final. Only that
        // identity is coalesced. Repeated words at different times/IDs remain.
        let finalIDs = Set(input.filter(\.isFinal).map(\.id))
        var fragments: [MeetingTranscriptFragment] = [], positions: [UUID: Int] = [:]
        for fragment in input {
            if !fragment.isFinal && finalIDs.contains(fragment.id) { continue }
            if let index = positions[fragment.id] {
                if !fragments[index].isFinal { fragments[index] = fragment }
            } else { positions[fragment.id] = fragments.count; fragments.append(fragment) }
        }
        var result: [MeetingTranscriptBubble] = []
        for fragment in fragments {
            let recording = originalSessions[fragment.sessionID] ?? fragment.sessionID
            let speaker = resolvedSpeaker(fragment.speakerID, speakers: speakers)
            if let previous = result.last,
               mayAppend(fragment, to: previous, recording: recording, speaker: speaker, limits: limits) {
                result[result.count - 1].fragments.append(fragment)
            } else {
                result.append(.init(meetingID: fragment.meetingID, recordingID: recording,
                                    speakerID: speaker, fragments: [fragment]))
            }
        }
        return result
    }
    private static func mayAppend(_ next: MeetingTranscriptFragment, to bubble: MeetingTranscriptBubble,
                                  recording: UUID, speaker: UUID?, limits: Limits) -> Bool {
        guard bubble.meetingID == next.meetingID, bubble.recordingID == recording, bubble.speakerID == speaker,
              bubble.fragments.count < max(1, limits.maximumFragments),
              bubble.text.count + next.text.count <= max(1, limits.maximumCharacters),
              let last = bubble.fragments.last else { return false }
        // Partials remain live UI state, never durable row replacements.
        if !next.isFinal { return !bubble.hasLiveTail }
        guard last.isFinal, last.hasValidRange, next.hasValidRange,
              let start = next.start, let end = next.end, let lastStart = last.start,
              let lastEnd = last.end, let firstStart = bubble.fragments.first?.start else { return false }
        guard start >= lastStart - 0.00001, start - lastEnd <= max(0, limits.maximumGap),
              end - firstStart <= max(0, limits.maximumDuration) else { return false }
        // A long natural sentence/paragraph ends a bubble; short finalized
        // network chunks alone do not create a separate card.
        let punctuation = ".!?。！？"
        let prior = last.text.trimmingCharacters(in: .whitespacesAndNewlines)
        if end - firstStart >= 20, let tail = prior.last,
           punctuation.contains(tail), start - lastEnd >= 0.5 { return false }
        if last.text.hasSuffix("\n\n") { return false }
        return true
    }
    static func join(_ first: String, _ second: String) -> String {
        guard let left = first.last else { return second }
        guard let right = second.first else { return first }
        if left.isWhitespace || right.isWhitespace { return first + second }
        if ",.;:!?，。；：！？、)]}）】》”’".contains(right) || "([{（【《“‘".contains(left) { return first + second }
        // CJK text keeps its normal spacing. Latin/number runs get a display
        // separator; the exact original fragment text remains untouched.
        func cjk(_ character: Character) -> Bool {
            character.unicodeScalars.contains { (0x2E80...0x9FFF).contains($0.value) || (0xF900...0xFAFF).contains($0.value) || (0x20000...0x3134F).contains($0.value) }
        }
        return first + (cjk(left) && cjk(right) ? "" : " ") + second
    }
}

struct MeetingTranslationBinding: Equatable, Sendable {
    let original: String
    let language: String
}
struct MeetingTranslationValue: Equatable, Sendable {
    let binding: MeetingTranslationBinding
    let text: String
}
enum MeetingTranslationDisplay: Equatable, Sendable {
    case missing, stale, translating, failed, ready(String)
    static func resolve(text: String, language: String, cached: MeetingTranslationValue?,
                        inFlight: MeetingTranslationBinding? = nil, failure: MeetingTranslationBinding? = nil) -> Self {
        let current = MeetingTranslationBinding(original: text, language: language)
        if let cached, cached.binding == current { return .ready(cached.text) }
        if inFlight == current { return .translating }
        if failure == current { return .failed }
        return cached == nil ? .missing : .stale
    }
}

struct MeetingTranscriptFollowState: Equatable, Sendable {
    private(set) var followsLive = true
    mutating func userScrolled(nearLiveEnd: Bool) { followsLive = nearLiveEnd }
    /// Transcript updates never alter the reader's intent. A new segment does
    /// not become an instruction to drag a reader away from earlier speech.
    var shouldScrollForContentUpdate: Bool { followsLive }
    mutating func returnToLive() { followsLive = true }
}
