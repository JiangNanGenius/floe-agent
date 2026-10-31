//
//  CADAnimationExportOptions.swift
//  FloeCADKit
//
//  User-facing export options for the Present MP4 export (original X28).
//  The options sheet works in the units a person picks — orientation,
//  resolution class, frame rate, codec and quality — and converts them
//  EXACTLY once into the production `CADAnimationExportSettings` consumed by
//  `FloeCADDocument.startAnimationExportMP4`. Nothing is silently reset to
//  defaults: every selected value reaches the real exporter, and the media
//  read-back path in the exporter verifies what was actually encoded.
//
//  The default selection reproduces the historical export behavior
//  (1920x1080 @ 30 fps, H.264, automatic bitrate) so existing flows are
//  unchanged until the user picks otherwise. Choices are persisted
//  additively in UserDefaults (`floe.cad.animationExportOptions`); the
//  document schema, version and saved geometry are untouched.
//

#if canImport(SwiftUI) && canImport(RealityKit) && canImport(UIKit)
import Foundation
import SwiftUI
import UIKit

// MARK: - Selection model

/// Video aspect. Present renders the live stage; the exporter's pixel
/// composer scales the real render into the selected aspect.
public nonisolated enum CADAnimationExportOrientation: String, Sendable, CaseIterable, Codable {
    case landscape
    case portrait
}

/// Resolution class at a 16:9 presentation aspect. The short edge follows
/// the picked orientation. Every combination stays inside the exporter's
/// validation bounds (even dimensions, 64...4096 per edge, within 4K).
public nonisolated enum CADAnimationExportResolution: Int, Sendable, CaseIterable, Codable {
    case p720 = 720
    case p1080 = 1080
    case p1440 = 1440
    case p2160 = 2160
}

public nonisolated enum CADAnimationExportFrameRate: Int, Sendable, CaseIterable, Codable {
    case fps24 = 24
    case fps30 = 30
    case fps60 = 60
}

/// Bitrate policy. `.automatic` leaves `bitrate` nil so the exporter uses
/// its proven auto formula; the other two derive from the same formula so a
/// quality pick never leaves the encoder's validated range.
public nonisolated enum CADAnimationExportQuality: String, Sendable, CaseIterable, Codable {
    case automatic
    case smaller
    case higher
}

/// One screen of export choices. Pure value type: mapping, persistence and
/// unit tests run without any renderer.
public nonisolated struct CADAnimationExportOptions: Sendable, Equatable, Codable {
    public var orientation: CADAnimationExportOrientation
    public var resolution: CADAnimationExportResolution
    public var frameRate: CADAnimationExportFrameRate
    public var codec: CADAnimationVideoCodec
    public var quality: CADAnimationExportQuality

    public init(orientation: CADAnimationExportOrientation = .landscape,
                resolution: CADAnimationExportResolution = .p1080,
                frameRate: CADAnimationExportFrameRate = .fps30,
                codec: CADAnimationVideoCodec = .h264,
                quality: CADAnimationExportQuality = .automatic) {
        self.orientation = orientation
        self.resolution = resolution
        self.frameRate = frameRate
        self.codec = codec
        self.quality = quality
    }

    /// The historical behavior, option for option.
    public static let `default` = CADAnimationExportOptions()

    // MARK: Mapping

    public var width: Int {
        let longEdge = resolution.rawValue * 16 / 9
        return orientation == .portrait ? resolution.rawValue : longEdge
    }

    public var height: Int {
        let longEdge = resolution.rawValue * 16 / 9
        return orientation == .portrait ? longEdge : resolution.rawValue
    }

    /// The exporter's own automatic bitrate, mirrored so quality picks stay
    /// proportional to the real encoder budget (2...40 Mbps).
    public var automaticBitrate: Int {
        let pixels = width * height
        return min(40_000_000, max(2_000_000, pixels * frameRate.rawValue / 3))
    }

    public var bitrate: Int? {
        switch quality {
        case .automatic: return nil
        case .smaller: return max(250_000, automaticBitrate / 2)
        case .higher: return min(80_000_000, automaticBitrate * 2)
        }
    }

    /// Exact production settings for the current selection. No defaulting,
    /// no rounding beyond the documented resolution math.
    public func exportSettings() -> CADAnimationExportSettings {
        CADAnimationExportSettings(
            width: width,
            height: height,
            frameRate: frameRate.rawValue,
            codec: codec,
            bitrate: bitrate,
            overwrite: false,
            posterEnabled: true)
    }

    // MARK: Persistence (additive preference, no document schema change)

    private static let defaultsKey = "floe.cad.animationExportOptions"

    nonisolated static func load(from defaults: UserDefaults = .standard)
    -> CADAnimationExportOptions {
        guard let data = defaults.data(forKey: defaultsKey) else { return .default }
        return (try? JSONDecoder().decode(CADAnimationExportOptions.self, from: data))
            ?? .default
    }

    nonisolated func save(to defaults: UserDefaults = .standard) {
        guard let data = try? JSONEncoder().encode(self) else { return }
        defaults.set(data, forKey: Self.defaultsKey)
    }

    // Tolerate partial or legacy payloads: any missing or unknown field
    // falls back to its historical default instead of failing the load.
    private enum CodingKeys: String, CodingKey {
        case orientation, resolution, frameRate, codec, quality
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(orientation.rawValue, forKey: .orientation)
        try container.encode(resolution.rawValue, forKey: .resolution)
        try container.encode(frameRate.rawValue, forKey: .frameRate)
        try container.encode(codec.rawValue, forKey: .codec)
        try container.encode(quality.rawValue, forKey: .quality)
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        orientation = CADAnimationExportOrientation(
            rawValue: try container.decodeIfPresent(String.self, forKey: .orientation) ?? "")
            ?? .landscape
        resolution = CADAnimationExportResolution(
            rawValue: try container.decodeIfPresent(Int.self, forKey: .resolution) ?? 0)
            ?? .p1080
        frameRate = CADAnimationExportFrameRate(
            rawValue: try container.decodeIfPresent(Int.self, forKey: .frameRate) ?? 0)
            ?? .fps30
        codec = CADAnimationVideoCodec(
            rawValue: try container.decodeIfPresent(String.self, forKey: .codec) ?? "")
            ?? .h264
        quality = CADAnimationExportQuality(
            rawValue: try container.decodeIfPresent(String.self, forKey: .quality) ?? "")
            ?? .automatic
    }
}

// MARK: - Options sheet

/// Compact iPad-first sheet shown by the Present export menu before an MP4
/// export starts. The draft lives only in this sheet: cancelling discards
/// it, confirming hands the exact draft to the existing export service.
struct CADAnimationExportOptionsSheet: View {
    let initial: CADAnimationExportOptions
    /// Active clip duration, used only for the frame estimate footer.
    let clipDuration: Double
    let onExport: (CADAnimationExportOptions) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var draft: CADAnimationExportOptions

    init(initial: CADAnimationExportOptions,
         clipDuration: Double,
         onExport: @escaping (CADAnimationExportOptions) -> Void) {
        self.initial = initial
        self.clipDuration = clipDuration
        self.onExport = onExport
        _draft = State(initialValue: initial)
    }

    var body: some View {
        NavigationStack {
            Form {
                Picker(FloeCADStrings.text("cad.animation.export.options.orientation",
                                           "Orientation"),
                       selection: $draft.orientation) {
                    ForEach(CADAnimationExportOrientation.allCases, id: \.self) { value in
                        Text(title(for: value)).tag(value)
                    }
                }
                .pickerStyle(.menu)
                .accessibilityIdentifier("CADAnimationExportOrientation")

                Picker(FloeCADStrings.text("cad.animation.export.options.resolution",
                                           "Resolution"),
                       selection: $draft.resolution) {
                    ForEach(CADAnimationExportResolution.allCases, id: \.self) { value in
                        Text("\(value.rawValue)p").tag(value)
                    }
                }
                .pickerStyle(.menu)
                .accessibilityIdentifier("CADAnimationExportResolution")

                Picker(FloeCADStrings.text("cad.animation.export.options.frameRate",
                                           "Frame rate"),
                       selection: $draft.frameRate) {
                    ForEach(CADAnimationExportFrameRate.allCases, id: \.self) { value in
                        Text("\(value.rawValue) fps").tag(value)
                    }
                }
                .pickerStyle(.menu)
                .accessibilityIdentifier("CADAnimationExportFrameRate")

                Picker(FloeCADStrings.text("cad.animation.export.options.codec",
                                           "Format"),
                       selection: $draft.codec) {
                    ForEach(CADAnimationVideoCodec.allCases, id: \.self) { value in
                        Text(title(for: value)).tag(value)
                    }
                }
                .pickerStyle(.menu)
                .accessibilityIdentifier("CADAnimationExportCodec")

                Picker(FloeCADStrings.text("cad.animation.export.options.quality",
                                           "Quality"),
                       selection: $draft.quality) {
                    ForEach(CADAnimationExportQuality.allCases, id: \.self) { value in
                        Text(title(for: value)).tag(value)
                    }
                }
                .pickerStyle(.menu)
                .accessibilityIdentifier("CADAnimationExportQuality")

                if clipDuration.isFinite, clipDuration > 0 {
                    let frames = max(1, Int((clipDuration * Double(draft.frameRate.rawValue))
                        .rounded()))
                    Text(FloeCADStrings.format("cad.animation.export.options.frames",
                                               "%d frames", frames))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("CADAnimationExportFrameEstimate")
                }
            }
            .navigationTitle(FloeCADStrings.text("cad.animation.export.options.title",
                                                 "Video export"))
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(FloeCADStrings.text("cad.ui.common.cancel", "Cancel")) {
                        dismiss()
                    }
                    .accessibilityIdentifier("CADAnimationExportOptionsCancel")
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(FloeCADStrings.text("cad.present.export", "Export")) {
                        let confirmed = draft
                        dismiss()
                        onExport(confirmed)
                    }
                    .disabled(draft.exportSettings().validationError != nil)
                    .accessibilityIdentifier("CADAnimationExportOptionsConfirm")
                }
            }
        }
        .presentationCompactAdaptation(horizontal: .popover, vertical: .sheet)
        .accessibilityIdentifier("CADAnimationExportOptions")
    }

    private func title(for orientation: CADAnimationExportOrientation) -> String {
        switch orientation {
        case .landscape:
            return FloeCADStrings.text("cad.animation.export.options.orientation.landscape",
                                       "Landscape")
        case .portrait:
            return FloeCADStrings.text("cad.animation.export.options.orientation.portrait",
                                       "Portrait")
        }
    }

    private func title(for codec: CADAnimationVideoCodec) -> String {
        switch codec {
        case .h264:
            return FloeCADStrings.text("cad.animation.export.options.codec.h264", "H.264")
        case .hevc:
            return FloeCADStrings.text("cad.animation.export.options.codec.hevc",
                                       "HEVC (smaller)")
        }
    }

    private func title(for quality: CADAnimationExportQuality) -> String {
        switch quality {
        case .automatic:
            return FloeCADStrings.text("cad.animation.export.options.quality.automatic",
                                       "Automatic")
        case .smaller:
            return FloeCADStrings.text("cad.animation.export.options.quality.smaller",
                                       "Smaller file")
        case .higher:
            return FloeCADStrings.text("cad.animation.export.options.quality.higher",
                                       "Higher quality")
        }
    }
}

#endif
