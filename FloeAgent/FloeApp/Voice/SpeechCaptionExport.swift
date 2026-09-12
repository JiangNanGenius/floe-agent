// SPDX-License-Identifier: MPL-2.0
#if canImport(UIKit) && canImport(WhisperKit)
import Foundation

enum SpeechCaptionExport {
    static func data(segments: [TimedSpeechSegment], format: String) throws -> Data {
        guard ["srt", "vtt", "json"].contains(format),
              segments.allSatisfy({ $0.start.isFinite && $0.end.isFinite && $0.start >= 0 && $0.end > $0.start && $0.end < 1_000_000_000 }) else {
            throw FileSpeechError.invalidAudio
        }
        if format == "json" { return try JSONEncoder().encode(segments) }
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
}
#endif
