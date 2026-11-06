// SPDX-License-Identifier: MPL-2.0
import Foundation

public enum MeetingExportFormat: String, Sendable, Codable, CaseIterable {
    case txt
    case markdown
    case srt
    case vtt
}

public enum MeetingExportError: Error, Sendable, Hashable {
    case nonFiniteTimeReference(TranscriptSegmentID)
    case unsupportedFormat(MeetingExportFormat)
}

/// Pure-data exporters. SRT/VTT follow the same formatting rules as the
/// app's existing caption export (`FloeApp/Voice/SpeechCaptionExport.swift`):
/// `,` millisecond separator for SRT, `.` for VTT, `WEBVTT` header, HTML
/// escaping of `& < >`, and single-line captions. Every cue keeps its segment
/// id so time references remain verifiable back to the transcript.
public enum MeetingExport {
    /// Cue with its source segment — the export keeps the link intact.
    public struct Cue: Sendable, Hashable {
        public let segmentID: TranscriptSegmentID
        public let range: MediaTimeRange
        public let text: String
    }

    public static func cues(segments: [TranscriptSegment]) throws -> [Cue] {
        try segments.sorted { lhs, rhs in
            if lhs.range.start != rhs.range.start { return lhs.range.start < rhs.range.start }
            return lhs.ordinal < rhs.ordinal
        }.map { segment in
            guard segment.range.start.isFinite, segment.range.end.isFinite,
                  segment.range.start >= 0, segment.range.end > segment.range.start,
                  segment.range.end < 1_000_000_000 else {
                throw MeetingExportError.nonFiniteTimeReference(segment.id)
            }
            return Cue(segmentID: segment.id, range: segment.range, text: segment.text)
        }
    }

    static func timestamp(_ seconds: Double, srtStyle: Bool) -> String {
        let ms = Int((seconds * 1000).rounded())
        return String(
            format: "%02d:%02d:%02d%@%03d",
            ms / 3_600_000, ms / 60_000 % 60, ms / 1000 % 60, srtStyle ? "," : ".", ms % 1000
        )
    }

    static func escapedLine(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .components(separatedBy: .newlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    public static func captionData(cues: [Cue], format: MeetingExportFormat) throws -> Data {
        switch format {
        case .srt, .vtt:
            break
        case .txt, .markdown:
            throw MeetingExportError.unsupportedFormat(format)
        }
        var text = format == .vtt ? "WEBVTT\n\n" : ""
        for (index, cue) in cues.enumerated() {
            let line = escapedLine(cue.text)
            text += "\(index + 1)\n\(timestamp(cue.range.start, srtStyle: format == .srt)) --> \(timestamp(cue.range.end, srtStyle: format == .srt))\n\(line)\n\n"
        }
        return Data(text.utf8)
    }

    /// Plain-text / Markdown transcript export with speaker labels.
    public static func documentData(
        segments: [TranscriptSegment],
        speakers: [Speaker],
        title: String,
        format: MeetingExportFormat
    ) throws -> Data {
        let cues = try cues(segments: segments)
        let resolved = Dictionary(uniqueKeysWithValues: speakers.map { ($0.id, $0) })
        func label(for id: SpeakerID?) -> String {
            guard let id else { return MeetingStrings.text("Unknown speaker", "未知发言人") }
            var current = id
            var seen: Set<SpeakerID> = []
            while let speaker = resolved[current], let next = speaker.mergedInto, !seen.contains(current) {
                seen.insert(current)
                current = next
            }
            return resolved[current]?.label ?? MeetingStrings.text("Unknown speaker", "未知发言人")
        }
        var lines: [String] = []
        if format == .markdown {
            lines.append("# \(title)")
            lines.append("")
        } else {
            lines.append(title)
            lines.append("")
        }
        for cue in cues {
            let stamp = timestamp(cue.range.start, srtStyle: false)
            let segment = segments.first { $0.id == cue.segmentID }
            lines.append("[\(stamp)] \(label(for: segment?.speakerID)): \(cue.text)")
        }
        return Data((lines.joined(separator: "\n") + "\n").utf8)
    }
}
