// SPDX-License-Identifier: MPL-2.0
import Foundation

public struct MediaTimedTranscriptSegment: Sendable, Hashable {
    public let start: Double
    public let end: Double
    public let text: String
    public init(start: Double,end: Double,text: String) { self.start=start;self.end=end;self.text=text }
}
public struct MediaTranslatedCaption: Sendable, Hashable {
    public let sourceID: UUID
    public let text: String
    public init(sourceID: UUID,text: String) { self.sourceID=sourceID;self.text=text }
}
public enum MediaCaptionTransformation {
    /// Provider timestamps are relative to the extracted source range. Map
    /// them to this clip's retimed timeline; existing captions are not replaced.
    public static func transcribedClips(_ segments: [MediaTimedTranscriptSegment],source: MediaPreparedClip,language: String? = nil) throws -> [MediaPreparedClip] {
        guard source.sourcePlayback?.isReversed != true,source.sourcePlayback?.holdSeconds == nil,
              source.speed.isFinite,source.speed>0 else { throw MediaPreparedCoreError.invalidOperation("transcribe forward playback or select its original audio") }
        guard !segments.isEmpty,segments.count<=MediaPreparedSchema.maximumClips,segments.reduce(0,{$0+$1.text.utf8.count})<=512_000 else { throw MediaPreparedCoreError.invalidOperation("transcription returned no text or exceeds the caption budget") }
        let duration = source.sourceRange.durationSeconds
        var previous = -Double.infinity
        return try segments.map { segment in
            guard segment.start.isFinite,segment.end.isFinite,segment.start>=0,segment.start>=previous,
                  segment.end>segment.start,segment.start<duration,segment.end<=duration+0.25,
                  !segment.text.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty else { throw MediaPreparedCoreError.invalidOperation("transcription returned invalid source-relative timing") }
            previous=segment.start
            let start=source.timelineRange.startSeconds+segment.start/source.speed
            // ASR may include up to 250ms of end padding in its final segment.
            let end=min(source.timelineRange.endSeconds,source.timelineRange.startSeconds+min(duration,segment.end)/source.speed)
            guard end>start else { throw MediaPreparedCoreError.invalidOperation("transcription lies outside this clip") }
            let range=try MediaTimeRange(start:.seconds(start,timescale:90_000),duration:.seconds(end-start,timescale:90_000))
            var clip=MediaPreparedClip(timelineRange:range,sourceRange:try .init(start:.init(value:0,timescale:90_000),duration:range.duration),captionText:segment.text,captionSource:.transcription)
            clip.captionLanguage=language
            return clip
        }
    }
    /// Match exact IDs before generating a new translated track. Order and
    /// timing always come from the saved source, never a model-authored list.
    public static func translatedClips(_ translated: [MediaTranslatedCaption],source: [MediaPreparedClip],language: String) throws -> [MediaPreparedClip] {
        let language=language.trimmingCharacters(in:.whitespacesAndNewlines)
        guard !language.isEmpty,language.utf8.count<=128,!source.isEmpty,source.count<=MediaPreparedSchema.maximumClips,
              source.count==translated.count,Set(source.map(\.id)).count==source.count,
              Set(translated.map(\.sourceID)).count==translated.count,
              Set(source.map(\.id))==Set(translated.map(\.sourceID)),
              translated.reduce(0,{$0+$1.text.utf8.count})<=8*1_024*1_024,
              translated.allSatisfy({!$0.text.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty && $0.text.utf8.count<=65_536}) else {
            throw MediaPreparedCoreError.invalidOperation("translation must retain every source caption ID exactly once")
        }
        let output=Dictionary(uniqueKeysWithValues:translated.map{($0.sourceID,$0.text)})
        return source.map { original in
            var clip=original;clip.id=UUID();clip.revision=0;clip.captionText=output[original.id]
            clip.sourceCaptionID=original.id;clip.captionLanguage=language
            return clip
        }
    }
}
