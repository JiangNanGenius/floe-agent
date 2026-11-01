//
//  CADAnimationExportFormat.swift
//  FloeCADKit
//
//  Original X29 — the output type is explicit before a frame is rendered, so
//  the track/alpha/frame-sequence read-back can name exactly what was written.
//
//  Two executable outputs exist:
//
//    * `.mp4`          — the historical opaque H.264/HEVC video. Neither
//                        codec carries an alpha channel.
//    * `.pngSequence`  — ordered lossless PNG frames plus a small manifest,
//                        delivered as one ZIP bundle. Frames are composited
//                        over the same opaque appearance background the MP4
//                        path uses, so the declared alpha is `opaque`.
//
//  A transparent request is REFUSED by `CADAnimationExportSettings.validated()`
//  before any renderer, staging file or durable task starts. The native
//  renderer currently composites an opaque scene background and MP4 has no
//  alpha channel; pretending otherwise by setting a metadata flag would be a
//  false claim, and silently ignoring the request would hide it.
//

import Foundation

/// Exact user/tool-visible output kind. Raw values are persisted in the
/// additive UI preference, the X30 recovery snapshot and tool records, so they
/// never change after release.
public nonisolated enum CADAnimationExportOutputFormat: String, Sendable,
    CaseIterable, Codable {
    /// Historical MP4 video (opaque H.264/HEVC).
    case mp4
    /// Ordered lossless PNG frames + manifest.json in one ZIP bundle.
    case pngSequence = "png_zip"

    /// Destination extension the exporter validates before starting.
    public var pathExtension: String {
        switch self {
        case .mp4: return "mp4"
        case .pngSequence: return "zip"
        }
    }

    /// Video settings (codec/bitrate/quality) only apply to this kind.
    public var isVideo: Bool { self == .mp4 }
}

/// Explicit alpha contract for one export. Only `opaque` is executable today;
/// `transparent` exists so a request is validated and refused by name instead
/// of being ignored or faked.
public nonisolated enum CADAnimationExportAlpha: String, Sendable,
    CaseIterable, Codable {
    case opaque
    case transparent
}
