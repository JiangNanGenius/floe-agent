// SPDX-License-Identifier: MPL-2.0

// SRT/WebVTT subtitle exchange for the Mac timeline editor.
//
// The shipping iPad `MediaV2SubtitleCodec` (FloeAgent/FloeApp/Workbench/
// MediaV2/MediaV2SubtitleCodec.swift) is already portable: its only UIKit
// dependency is the `MediaV2Session` extension behind `#if canImport(UIKit)`.
// The coordinator adds that exact shared source to the Mac OTA target, so
// this file NEVER re-implements the parser. It only:
//
//   * type-aliases the shared codec to the Mac name used across the
//     MediaParity sources and tests;
//   * adds the small presentation layer the Mac editor needs: user-facing
//     errors for import failures and cue-array conversion into validated
//     `MacTimelineClip` caption clips (the iPad `captionImportActions`
//     equivalent for the Mac draft model).

import FloeCore
import Foundation

typealias MacSubtitleCodec = MediaV2SubtitleCodec

extension MacSubtitleCodec.Cue {
    /// Converts one parsed cue into a validated caption clip. `offset`
    /// shifts the whole import (mirrors the iPad import offset).
    func makeClip(offset: Double, title: String = "") throws -> MacTimelineClip {
        guard offset.isFinite, offset >= 0 else { throw MacTimelineError.invalidTime }
        return try MacTimelineClip.caption(
            timelineStart: start + offset, duration: duration, text: text, title: title)
    }
}

extension MacTimelineDraft {
    /// Imports parsed cues into a caption track (the selected caption track
    /// when it exists, otherwise a new one), mirroring the iPad
    /// `captionImportActions` flow without duplicating the codec.
    mutating func importCues(_ cues: [MacSubtitleCodec.Cue], offset: Double = 0) throws {
        guard !cues.isEmpty else { throw MacSubtitleCodec.Failure.malformed }
        let trackID: UUID
        if let existing = tracks.first(where: { $0.kind == .caption && !$0.isMuted }) {
            trackID = existing.id
        } else {
            trackID = try addTrack(.caption).id
        }
        for cue in cues.sorted(by: { $0.start < $1.start }) {
            _ = try addClip(try cue.makeClip(offset: offset), toTrack: trackID)
        }
    }

    /// All caption clips across caption tracks, as codec cues, for export.
    var captionCues: [MacSubtitleCodec.Cue] {
        tracks.filter { $0.kind == .caption }.flatMap(\.clips).compactMap { clip in
            guard let text = clip.captionText else { return nil }
            return MacSubtitleCodec.Cue(
                start: clip.timelineRange.startSeconds,
                duration: clip.timelineRange.durationSeconds,
                text: text)
        }
    }
}

/// User-facing localization for subtitle import failures; the shared codec
/// itself stays UI-free.
struct MacSubtitleImportError: LocalizedError {
    let failure: MacSubtitleCodec.Failure

    init(_ failure: MacSubtitleCodec.Failure) { self.failure = failure }

    var errorDescription: String? {
        switch failure {
        case .unsupportedStyle:
            return MacSubtitleStrings.unsupportedStyle
        case .malformed, .limit:
            return MacSubtitleStrings.malformed
        }
    }
}

enum MacSubtitleStrings {
    static var importButton: String { t(en: "Import Subtitles…", zh: "导入字幕…") }
    static var exportSRT: String { t(en: "Export Subtitles (SRT)…", zh: "导出字幕（SRT）…") }
    static var exportVTT: String { t(en: "Export Subtitles (VTT)…", zh: "导出字幕（VTT）…") }
    static var importFailed: String { t(en: "Subtitle Import Failed", zh: "字幕导入失败") }
    static var exportFailed: String { t(en: "Subtitle Export Failed", zh: "字幕导出失败") }
    static var unsupportedStyle: String {
        t(en: "These captions use unsupported styling or positioning. Export plain-text captions first.",
           zh: "此字幕包含尚未支持的样式或定位。请先导出为纯文本字幕。")
    }
    static var malformed: String {
        t(en: "Use valid UTF-8 plain-text SRT/VTT captions.", zh: "请使用有效的 UTF-8 纯文本 SRT/VTT 字幕。")
    }

    private static func t(en: String, zh: String) -> String {
        FloeL10n.isChinese ? zh : en
    }
}
