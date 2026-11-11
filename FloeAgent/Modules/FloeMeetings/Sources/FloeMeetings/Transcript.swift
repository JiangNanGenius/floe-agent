// SPDX-License-Identifier: MPL-2.0
import Foundation

/// A speaker with a stable identity. Renames never change `id`, so every
/// transcript segment that references the speaker keeps its source. Merges
/// record the target id instead of rewriting segment rows.
public struct Speaker: Sendable, Codable, Identifiable, Hashable {
    public let id: SpeakerID
    public var label: String
    /// True when the label came from the user (rename). User-named speakers
    /// are protected from engine-side relabeling.
    public var userNamed: Bool
    /// Non-nil when this speaker was merged into another; resolve through it.
    public var mergedInto: SpeakerID?

    public init(id: SpeakerID = SpeakerID(), label: String, userNamed: Bool = false, mergedInto: SpeakerID? = nil) {
        self.id = id
        self.label = label
        self.userNamed = userNamed
        self.mergedInto = mergedInto
    }
}

public enum CorrectionAuthor: String, Sendable, Codable {
    case user
}

/// One transcript segment. `id` is stable for the life of the meeting so
/// notes, markers, todos and decisions can point at it.
public struct TranscriptSegment: Sendable, Codable, Identifiable, Hashable {
    public let id: TranscriptSegmentID
    public let meetingID: MeetingID
    public let sessionID: CaptureSessionID
    /// Speaker as attributed by the engine (or corrected by the user); may be
    /// nil when attribution is unavailable. Look up via
    /// `MeetingService.resolveSpeaker` for merges.
    public private(set) var speakerID: SpeakerID?
    /// Position in the original recording, seconds from session start.
    public let range: MediaTimeRange
    /// Current text. After a user correction this holds the corrected text.
    public private(set) var text: String
    /// Text before the user correction; nil while uncorrected.
    public private(set) var originalText: String?
    public private(set) var correctedBy: CorrectionAuthor?
    /// True once the USER corrected this segment's speaker attribution
    /// (reassign/clear). A later canonical transcription pass adopts better
    /// engine results everywhere except here.
    public private(set) var speakerCorrected: Bool
    public let language: String?
    public let source: SourceReference
    /// Insertion sequence within the session (for stable tie-break ordering).
    public let ordinal: Int

    public init(
        id: TranscriptSegmentID = TranscriptSegmentID(),
        meetingID: MeetingID,
        sessionID: CaptureSessionID,
        speakerID: SpeakerID?,
        range: MediaTimeRange,
        text: String,
        language: String? = nil,
        ordinal: Int
    ) {
        self.id = id
        self.meetingID = meetingID
        self.sessionID = sessionID
        self.speakerID = speakerID
        self.range = range
        self.text = text
        self.language = language
        self.source = .recording(session: sessionID, range: range)
        self.ordinal = ordinal
        self.speakerCorrected = false
    }

    /// User correction. Keeps the original engine text and the segment id, so
    /// every source reference to this segment still resolves.
    public mutating func applyUserCorrection(_ newText: String) {
        if originalText == nil { originalText = text }
        text = newText
        correctedBy = .user
    }

    /// User speaker correction; wins over any later engine attribution.
    public mutating func applyUserSpeakerCorrection(_ speaker: SpeakerID?) {
        speakerID = speaker
        speakerCorrected = true
    }

    /// Restores persisted correction state after decoding from storage.
    mutating func setStored(originalText: String?, correctedBy: CorrectionAuthor?, speakerCorrected: Bool) {
        self.originalText = originalText
        self.correctedBy = correctedBy
        self.speakerCorrected = speakerCorrected
    }
    private enum CodingKeys: String, CodingKey {
        case id, meetingID, sessionID, speakerID, range, text, originalText, correctedBy, speakerCorrected, language, source, ordinal
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decode(TranscriptSegmentID.self, forKey: .id)
        self.meetingID = try c.decode(MeetingID.self, forKey: .meetingID)
        self.sessionID = try c.decode(CaptureSessionID.self, forKey: .sessionID)
        self.speakerID = try c.decodeIfPresent(SpeakerID.self, forKey: .speakerID)
        self.range = try c.decode(MediaTimeRange.self, forKey: .range)
        self.text = try c.decode(String.self, forKey: .text)
        self.originalText = try c.decodeIfPresent(String.self, forKey: .originalText)
        self.correctedBy = try c.decodeIfPresent(CorrectionAuthor.self, forKey: .correctedBy)
        self.speakerCorrected = try c.decodeIfPresent(Bool.self, forKey: .speakerCorrected) ?? false
        self.language = try c.decodeIfPresent(String.self, forKey: .language)
        self.source = try c.decode(SourceReference.self, forKey: .source)
        self.ordinal = try c.decode(Int.self, forKey: .ordinal)
    }

}
