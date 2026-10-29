// SPDX-License-Identifier: MPL-2.0
#if canImport(UIKit) && canImport(WhisperKit)
import Foundation

enum SpeechCaptionExport {
    static let formats: Set<String> = ["srt", "vtt", "json", "txt", "text"]

    static func data(segments: [TimedSpeechSegment], format: String) throws -> Data {
        guard formats.contains(format),
              segments.allSatisfy({ $0.start.isFinite && $0.end.isFinite && $0.start >= 0 && $0.end > $0.start && $0.end < 1_000_000_000 }) else {
            throw FileSpeechError.invalidAudio
        }
        if format == "json" { return try JSONEncoder().encode(segments) }
        if format == "txt" || format == "text" {
            return Data(plainText(segments: segments).utf8)
        }
        func timestamp(_ seconds: Double) -> String {
            let ms = Int((seconds * 1000).rounded())
            return String(format: "%02d:%02d:%02d%@%03d", ms / 3_600_000, ms / 60_000 % 60, ms / 1000 % 60, format == "srt" ? "," : ".", ms % 1000)
        }
        var text = format == "vtt" ? "WEBVTT\n\n" : ""
        for (index, segment) in segments.enumerated() {
            let caption = segment.text.replacingOccurrences(of: "&", with: "&amp;")
                .replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
                .components(separatedBy: .newlines).filter { !$0.isEmpty }.joined(separator: " ")
            text += "\(index + 1)\n\(timestamp(segment.start)) --> \(timestamp(segment.end))\n\(caption)\n\n"
        }
        return Data(text.utf8)
    }

    /// One transcript line per timed segment. The text is the exact
    /// recognized content (no timestamps), suitable for a .txt output or a
    /// direct tool result.
    static func plainText(segments: [TimedSpeechSegment]) -> String {
        segments.map { segment in
            segment.text.replacingOccurrences(of: "\r\n", with: "\n")
                .components(separatedBy: .newlines)
                .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
                .joined(separator: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }.filter { !$0.isEmpty }.joined(separator: "\n")
    }
}
#endif
