// SPDX-License-Identifier: MPL-2.0
#if canImport(UIKit)
import Foundation
import FloeMeetings

extension MeetingProjectSession {
    var displayTranscriptFragments: [MeetingTranscriptFragment] {
        transcript.map { segment in
            MeetingTranscriptFragment(id: segment.id.rawValue, meetingID: segment.meetingID.rawValue,
                sessionID: segment.sessionID.rawValue, speakerID: segment.speakerID?.rawValue,
                start: segment.range.start, end: segment.range.end, text: segment.text, isFinal: true)
        } + transcriptPartials.map { partial in
            MeetingTranscriptFragment(id: partial.id.rawValue, meetingID: partial.meetingID.rawValue,
                sessionID: partial.sessionID.rawValue, speakerID: nil, start: nil, end: nil,
                text: partial.text, isFinal: false)
        }
    }
    var displayTranscriptBubbles: [MeetingTranscriptBubble] {
        let fragments = displayTranscriptFragments
        var originals: [UUID: UUID] = [:]
        for fragment in fragments {
            originals[fragment.sessionID] = originalCaptureSession(for: CaptureSessionID(fragment.sessionID)).rawValue
        }
        return MeetingTranscriptPresentation.bubbles(fragments,
            speakers: speakers.map { .init(id: $0.id.rawValue, label: $0.label, mergedInto: $0.mergedInto?.rawValue) },
            originalSessions: originals)
    }
    func displayTranslation(for fragment: MeetingTranscriptFragment) -> MeetingTranslationDisplay {
        let value = intelligence.translations[fragment.id]
        return .resolve(text: fragment.text, language: intelligence.translationLanguage,
            cached: value.map { .init(binding: .init(original: $0.original, language: $0.language ?? ""), text: $0.text) },
            inFlight: translationWork[fragment.id], failure: translationFailures[fragment.id])
    }
    func playTranscriptBubble(_ bubble: MeetingTranscriptBubble) {
        guard bubble.meetingID == id, let range = bubble.playbackRange,
              let recording = recordings.first(where: { $0.id.rawValue == bubble.recordingID }) else { return }
        play(recording, at: range.start, until: range.end)
    }
    func playTranscriptFragment(_ fragment: MeetingTranscriptFragment) {
        guard fragment.meetingID == id, fragment.isFinal, fragment.hasValidRange,
              let start = fragment.start, let end = fragment.end else { return }
        let original = originalCaptureSession(for: CaptureSessionID(fragment.sessionID))
        guard let recording = recordings.first(where: { $0.id == original }) else { return }
        play(recording, at: start, until: end)
    }
    func mergeTranscriptSpeaker(_ source: Speaker, into target: Speaker) async {
        guard source.id != target.id else { return }
        do {
            try await service.mergeSpeaker(source.id, into: target.id, meeting: MeetingID(id))
            await refresh()
        } catch { diagnostic = error.localizedDescription }
    }

    /// Anonymous engine speakers are stored language-neutrally as
    /// "Speaker N"; the UI localizes only that generated prefix. Names the
    /// user typed are always shown verbatim.
    func displaySpeakerLabel(_ speaker: Speaker) -> String {
        guard !speaker.userNamed, speaker.label.hasPrefix("Speaker "),
              let ordinal = speaker.label.dropFirst("Speaker ".count).split(separator: " ").first else {
            return speaker.label
        }
        return IDELanguageRunText.t("说话人 \(ordinal)", "Speaker \(ordinal)")
    }
}
#endif
