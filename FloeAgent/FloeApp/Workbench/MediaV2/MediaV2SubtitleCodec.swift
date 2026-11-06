// SPDX-License-Identifier: MPL-2.0
import Foundation

/// Plain-text SRT/WebVTT exchange. Styling, regions and cue positioning are
/// rejected explicitly because the current prepared caption renderer cannot
/// preserve them. No script, HTML or external resource is interpreted.
nonisolated enum MediaV2SubtitleCodec {
    struct Cue: Hashable, Sendable { var start: Double; var duration: Double; var text: String }
    enum Format { case srt, vtt }
    enum Failure: Error { case malformed, unsupportedStyle, limit }

    static func parse(_ text: String) throws -> [Cue] {
        guard text.utf8.count <= 2_097_152 else { throw Failure.limit }
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "\u{FEFF}")))
        let blocks = normalized.components(separatedBy: "\n\n")
        var cues: [Cue] = []
        for block in blocks {
            var lines = block.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
            while lines.first?.trimmingCharacters(in: .whitespaces).isEmpty == true { lines.removeFirst() }
            guard let first = lines.first else { continue }
            if first.hasPrefix("WEBVTT") {
                guard lines.count == 1 else { throw Failure.unsupportedStyle }; continue
            }
            if first == "STYLE" || first == "REGION" { throw Failure.unsupportedStyle }
            if first == "NOTE" || first.hasPrefix("NOTE ") { continue }
            if !first.contains("-->") { lines.removeFirst() } // SRT index or VTT cue identifier.
            guard let timing = lines.first else { throw Failure.malformed }
            let parts = timing.components(separatedBy: "-->")
            guard parts.count == 2 else { throw Failure.malformed }
            let endToken = parts[1].trimmingCharacters(in: .whitespaces)
            guard !endToken.contains(" "), !endToken.contains("\t") else { throw Failure.unsupportedStyle }
            let start = try seconds(parts[0]), end = try seconds(endToken)
            guard end > start, end <= 86_400 else { throw Failure.malformed }
            let content = lines.dropFirst().joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !content.isEmpty, content.utf8.count <= 32_768 else { throw Failure.malformed }
            guard !content.contains("<"), !content.contains(">") else { throw Failure.unsupportedStyle }
            cues.append(.init(start: start, duration: end - start, text: content))
            guard cues.count <= 4096 else { throw Failure.limit }
        }
        guard !cues.isEmpty else { throw Failure.malformed }
        return cues.sorted { $0.start < $1.start }
    }
    private static func seconds(_ token: String) throws -> Double {
        let value = token.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ".")
        let parts = value.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 2 || parts.count == 3,
              let minute = Int(parts[parts.count - 2]), (0..<60).contains(minute),
              let second = Double(parts.last!), second.isFinite, second >= 0, second < 60 else { throw Failure.malformed }
        let hour = parts.count == 3 ? Int(parts[0]) : 0
        guard let hour, hour >= 0, hour < 24 else { throw Failure.malformed }
        return Double(hour * 3600 + minute * 60) + second
    }
    static func encode(_ cues: [Cue], format: Format) throws -> String {
        guard cues.count <= 4096, cues.reduce(0, { $0 + $1.text.utf8.count }) <= 2_097_152,
              cues.allSatisfy({ $0.start.isFinite && $0.duration.isFinite && $0.start >= 0
            && $0.duration > 0 && $0.start + $0.duration <= 86_400 && !$0.text.isEmpty
            && !$0.text.contains("<") && !$0.text.contains(">") && !$0.text.contains("\n\n") }) else { throw Failure.malformed }
        let blocks = cues.sorted { $0.start < $1.start }.enumerated().map { index, cue in
            "\(index + 1)\n\(timestamp(cue.start, format: format)) --> \(timestamp(cue.start + cue.duration, format: format))\n\(cue.text)"
        }
        return (format == .vtt ? "WEBVTT\n\n" : "") + blocks.joined(separator: "\n\n") + "\n"
    }
    private static func timestamp(_ seconds: Double, format: Format) -> String {
        let milliseconds = Int((seconds * 1000).rounded())
        let hours = milliseconds / 3_600_000, minutes = milliseconds / 60_000 % 60
        let whole = milliseconds / 1000 % 60, fraction = milliseconds % 1000
        return String(format: "%02d:%02d:%02d%@%03d", hours, minutes, whole, format == .srt ? "," : ".", fraction)
    }
}

#if canImport(UIKit)
import FloeWorkbench

extension MediaV2Session {
    func captionImportActions(_ text: String, offset: Double = 0) throws -> [MediaPreparedAction] {
        guard project.kind == .video, offset.isFinite, offset >= 0 else { throw MediaV2CommandError.invalidInput }
        let cues: [MediaV2SubtitleCodec.Cue]
        do { cues = try MediaV2SubtitleCodec.parse(text) }
        catch MediaV2SubtitleCodec.Failure.unsupportedStyle {
            throw SubtitleImportError.unsupportedStyle
        } catch { throw SubtitleImportError.malformed }
        let track = document.trackGraph.tracks.first { $0.id == selectedTrackID && $0.kind == .caption && !$0.isLocked }
            ?? document.trackGraph.tracks.first { $0.kind == .caption && !$0.isLocked }
            ?? MediaPreparedTrack(kind: .caption, name: WorkbenchText.t("字幕", "Captions"))
        var actions: [MediaPreparedAction] = []
        if document.trackGraph.track(track.id) == nil { actions.append(.insertTrack(track: track, index: nil)) }
        for cue in cues {
            let clip = MediaPreparedClip(timelineRange: try Self.range(start: cue.start + offset, duration: cue.duration),
                sourceRange: try Self.range(start: 0, duration: cue.duration), captionText: cue.text)
            actions.append(.insertClip(trackID: track.id, clip: clip, index: nil))
        }
        return actions
    }
    func importCaptions(_ url: URL) async throws {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard values.isRegularFile == true, (values.fileSize ?? 0) <= 2_097_152 else { throw SubtitleImportError.malformed }
        let data = try Data(contentsOf: url)
        guard let text = String(data: data, encoding: .utf8) else { throw SubtitleImportError.malformed }
        let base = document.revision, actions = try captionImportActions(text)
        _ = try await apply(actions.map { .init(action: $0) }, expectedRevision: base)
    }
    func exportCaptions(_ format: MediaV2SubtitleCodec.Format) throws -> URL {
        let cues = document.trackGraph.tracks.filter { $0.kind == .caption }.flatMap(\.clips).compactMap { clip -> MediaV2SubtitleCodec.Cue? in
            guard let text = clip.captionText else { return nil }
            return .init(start: clip.timelineRange.startSeconds, duration: clip.timelineRange.durationSeconds, text: text)
        }
        guard !cues.isEmpty else { throw MediaV2CommandError.missingSelection }
        let content = try MediaV2SubtitleCodec.encode(cues, format: format)
        let folder = root.appendingPathComponent("Exports", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appendingPathComponent("captions-\(document.revision)-\(UUID().uuidString)." + (format == .srt ? "srt" : "vtt"))
        try Data(content.utf8).write(to: file, options: .atomic)
        return file
    }
}
private enum SubtitleImportError: LocalizedError {
    case malformed, unsupportedStyle
    var errorDescription: String? {
        switch self {
        case .malformed: WorkbenchText.t("请使用有效的 UTF-8 纯文本 SRT/VTT 字幕。", "Use valid UTF-8 plain-text SRT/VTT captions.")
        case .unsupportedStyle: WorkbenchText.t("此字幕包含尚未支持的样式或定位。请先导出为纯文本字幕。", "These captions use unsupported styling or positioning. Export plain-text captions first.")
        }
    }
}
#endif
