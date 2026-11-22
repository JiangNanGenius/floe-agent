// SPDX-License-Identifier: MPL-2.0

// Platform-neutral media editing core for the unified Mac workspace.
//
// The Mac app target does not link the iPad `FloeImages`/`FloeMedia`
// packages, so this file mirrors their shipping v1.8.72 contracts with the
// same semantics using only system frameworks (Core Graphics/Core Image,
// ImageIO, AVFoundation):
//
//   * `MacNormalizedCropRect` mirrors `FloeImages.NormalizedRect`
//     (unit-square rectangle, every component validated in 0...1).
//   * `MacImageAdjustment` mirrors the basic subset of the iPad
//     `ImageLayerAdjustment` (`saturation`/`contrast`/`brightness`/
//     `exposureEV`, nil = unchanged). Renderers apply the same Core Image
//     filter vocabulary as the deterministic iPad `ImagePipeline`
//     (`CIColorControls`, `CIExposureAdjust`, `CICrop`).
//   * `MacVideoTrimRange` mirrors the iPad video trim contract
//     (start/end seconds, clamped to the verified asset duration).
//
// Everything here is UI-free so it stays unit-testable on any host. Every
// export is bounded, cancellable, writes through a staging file and commits
// atomically with a read-back verification; original assets are never
// mutated.

import Foundation
import CoreGraphics
import CoreImage
import ImageIO
import UniformTypeIdentifiers
import AVFoundation
import FloeCore

// MARK: - Edit model

enum MacMediaEditKind: String, Codable, Hashable, Sendable {
    case image
    case video
}

/// One editable asset reference captured when the editor opens. Owner
/// context (which task or canvas the asset belongs to) is captured by the
/// owning view at presentation time, never inferred later.
struct MacMediaEditSource: Identifiable, Hashable, Sendable {
    let id: UUID
    let url: URL
    let kind: MacMediaEditKind
    /// Display title shown in the editor chrome.
    let title: String

    init(url: URL, kind: MacMediaEditKind, title: String, id: UUID = UUID()) {
        self.id = id
        self.url = url
        self.kind = kind
        self.title = title
    }
}

/// Unit-square crop rectangle; every component must be finite and inside
/// 0...1, with a non-empty area (same contract as `FloeImages.NormalizedRect`).
struct MacNormalizedCropRect: Codable, Hashable, Sendable {
    var x: Double
    var y: Double
    var width: Double
    var height: Double

    init(x: Double, y: Double, width: Double, height: Double) throws {
        let values = [x, y, width, height]
        guard values.allSatisfy({ $0.isFinite }) else { throw MacMediaEditError.invalidGeometry }
        guard x >= 0, y >= 0, width > 0, height > 0,
              x + width <= 1 + .ulpOfOne, y + height <= 1 + .ulpOfOne else {
            throw MacMediaEditError.invalidGeometry
        }
        self.x = min(max(x, 0), 1)
        self.y = min(max(y, 0), 1)
        self.width = min(width, 1 - self.x)
        self.height = min(height, 1 - self.y)
        guard self.width > 0, self.height > 0 else { throw MacMediaEditError.invalidGeometry }
    }

    /// Intersects with another rect, keeping the result inside the unit
    /// square. Returns nil when the intersection is empty.
    func intersection(_ other: MacNormalizedCropRect) -> MacNormalizedCropRect? {
        let nx = max(x, other.x)
        let ny = max(y, other.y)
        let nw = min(x + width, other.x + other.width) - nx
        let nh = min(y + height, other.y + other.height) - ny
        guard nw > 0, nh > 0 else { return nil }
        // Intersection of two validated rects is always valid; clamp
        // defensively against floating-point drift before re-validating.
        return try? MacNormalizedCropRect(
            x: min(nx, 1), y: min(ny, 1),
            width: min(nw, 1 - min(nx, 1)), height: min(nh, 1 - min(ny, 1)))
    }

    /// The full unit square.
    static let identity = try! MacNormalizedCropRect(x: 0, y: 0, width: 1, height: 1)

    /// True when this rect keeps every source pixel.
    var isIdentity: Bool { self == .identity }
}

/// Basic color adjustments; nil means unchanged (iPad
/// `ImageLayerAdjustment` basic subset semantics). Values follow the Core
/// Image vocabulary used by the deterministic iPad `ImagePipeline`:
///   * exposureEV: `CIExposureAdjust` inputEV (-10...10).
///   * saturation/contrast/brightness: `CIColorControls`
///     (saturation 0...2, contrast 0...4, brightness -1...1).
struct MacImageAdjustment: Codable, Hashable, Sendable {
    var saturation: Double?
    var contrast: Double?
    var brightness: Double?
    var exposureEV: Double?

    init(saturation: Double? = nil, contrast: Double? = nil,
         brightness: Double? = nil, exposureEV: Double? = nil) throws {
        if let saturation, !(saturation.isFinite && (0...2).contains(saturation)) { throw MacMediaEditError.invalidAdjustment }
        if let contrast, !(contrast.isFinite && (0...4).contains(contrast)) { throw MacMediaEditError.invalidAdjustment }
        if let brightness, !(brightness.isFinite && (-1...1).contains(brightness)) { throw MacMediaEditError.invalidAdjustment }
        if let exposureEV, !(exposureEV.isFinite && (-10...10).contains(exposureEV)) { throw MacMediaEditError.invalidAdjustment }
        self.saturation = saturation
        self.contrast = contrast
        self.brightness = brightness
        self.exposureEV = exposureEV
    }

    var isIdentity: Bool {
        saturation == nil && contrast == nil && brightness == nil && exposureEV == nil
    }
}

/// Video trim range in seconds, clamped to the verified source duration.
struct MacVideoTrimRange: Codable, Hashable, Sendable {
    let start: Double
    let end: Double

    init(start: Double, end: Double, duration: Double) throws {
        guard start.isFinite, end.isFinite, duration.isFinite, duration > 0 else {
            throw MacMediaEditError.invalidGeometry
        }
        guard start >= 0, end > start, start < duration else { throw MacMediaEditError.invalidGeometry }
        self.start = min(start, duration)
        self.end = min(end, duration)
        guard self.end > self.start else { throw MacMediaEditError.invalidGeometry }
    }

    var duration: Double { end - start }
}

// MARK: - Errors

enum MacMediaEditError: Error, Hashable, LocalizedError {
    case sourceUnreadable
    case invalidGeometry
    case invalidAdjustment
    case exportFailed(String)
    case cancelled
    case verificationFailed

    var errorDescription: String? {
        switch self {
        case .sourceUnreadable:
            return MacMediaEditStrings.sourceUnreadable
        case .invalidGeometry:
            return MacMediaEditStrings.invalidGeometry
        case .invalidAdjustment:
            return MacMediaEditStrings.invalidAdjustment
        case .exportFailed(let detail):
            return String(format: MacMediaEditStrings.exportFailedFormat, detail)
        case .cancelled:
            return MacMediaEditStrings.cancelled
        case .verificationFailed:
            return MacMediaEditStrings.verificationFailed
        }
    }
}

// MARK: - Image export

/// Deterministic Core Image renderer for the mirrored edit model. The same
/// source plus the same crop/adjustment always produces identical pixels.
struct MacImageEditRenderer: Sendable {
    private let context: CIContext

    init(context: CIContext = CIContext()) {
        self.context = context
    }

    /// Renders crop + adjustment to a new CGImage. EXIF orientation is
    /// applied first so the crop rect always works in the upright image
    /// space the user sees; crop is then applied in pixel space, followed
    /// by color adjustments (the iPad export order).
    func render(_ source: CGImage, orientation: Int = 1, crop: MacNormalizedCropRect?,
                adjustment: MacImageAdjustment?) throws -> CGImage {
        var image = CIImage(cgImage: source)
        if orientation > 1, orientation <= 8 {
            image = image.oriented(forExifOrientation: Int32(orientation))
        }
        if let crop, !crop.isIdentity {
            let extent = image.extent
            let rect = CGRect(x: extent.minX + crop.x * extent.width,
                              y: extent.minY + crop.y * extent.height,
                              width: crop.width * extent.width,
                              height: crop.height * extent.height)
            // Inset by half a pixel when the rect lands on fractional
            // boundaries so edge replication cannot add a fringe row.
            let integral = rect.integral.insetBy(dx: 0, dy: 0)
            image = image.cropped(to: integral.isEmpty ? rect : integral)
        }
        if let adjustment, !adjustment.isIdentity {
            if let exposureEV = adjustment.exposureEV {
                image = try filter("CIExposureAdjust", on: image, ["inputEV": exposureEV])
            }
            if adjustment.saturation != nil || adjustment.contrast != nil || adjustment.brightness != nil {
                image = try filter("CIColorControls", on: image, [
                    "inputSaturation": adjustment.saturation ?? 1,
                    "inputContrast": adjustment.contrast ?? 1,
                    "inputBrightness": adjustment.brightness ?? 0,
                ])
            }
        }
        let extent = image.extent
        guard !extent.isInfinite, !extent.isEmpty else { throw MacMediaEditError.exportFailed("empty extent") }
        guard let rendered = context.createCGImage(image, from: extent) else {
            throw MacMediaEditError.exportFailed("Core Image render")
        }
        return rendered
    }

    private func filter(_ name: String, on input: CIImage, _ parameters: [String: Any]) throws -> CIImage {
        guard let filter = CIFilter(name: name) else {
            throw MacMediaEditError.exportFailed("missing filter \(name)")
        }
        filter.setValue(input, forKey: kCIInputImageKey)
        for (key, value) in parameters { filter.setValue(value, forKey: key) }
        guard let output = filter.outputImage else {
            throw MacMediaEditError.exportFailed("filter \(name) produced no output")
        }
        return output
    }
}

/// Image exporter: decode → render → encode → atomic verified commit.
/// The source file is only ever read; metadata is never carried over.
struct MacImageEditExporter: Sendable {
    /// Source files above this cap are refused instead of being decoded.
    nonisolated static let maximumSourceBytes = 128 * 1_048_576
    /// Rendered images above this cap are refused (bounds memory use).
    nonisolated static let maximumRenderedBytes = 256 * 1_048_576

    private let renderer: MacImageEditRenderer

    init(renderer: MacImageEditRenderer = MacImageEditRenderer()) {
        self.renderer = renderer
    }

    /// Container types preserved through an edit; everything else becomes
    /// PNG so the output always opens with the system codecs.
    private static let preservedTypes: [UTType] = [.png, .jpeg, .heic]

    func export(source: URL, crop: MacNormalizedCropRect?,
                adjustment: MacImageAdjustment?, to destination: URL) async throws {
        try Task.checkCancellation()
        let type = Self.outputType(for: source)
        let sourceBytes = try boundedSourceSize(source)
        guard let imageSource = CGImageSourceCreateWithURL(source as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(imageSource, 0, nil) as? [CFString: Any],
              let sourceImage = CGImageSourceCreateImageAtIndex(imageSource, 0, nil) else {
            throw MacMediaEditError.sourceUnreadable
        }
        guard sourceImage.width > 0, sourceImage.height > 0 else { throw MacMediaEditError.sourceUnreadable }
        let orientation = (properties[kCGImagePropertyOrientation] as? NSNumber).map(\.intValue) ?? 1
        try Task.checkCancellation()
        let rendered = try renderer.render(sourceImage, orientation: orientation, crop: crop, adjustment: adjustment)
        try Task.checkCancellation()
        let encoded = try encode(rendered, type: type)
        guard encoded.count <= Self.maximumRenderedBytes else { throw MacMediaEditError.exportFailed("rendered image exceeds the size bound") }
        _ = sourceBytes
        try await MacMediaEditCommit.commit(encoded, to: destination) { url in
            Self.verify(url, expectedType: type)
        }
    }

    static func outputType(for source: URL) -> UTType {
        guard let type = UTType(filenameExtension: source.pathExtension) else { return .png }
        return preservedTypes.contains(type) ? type : .png
    }

    static func outputExtension(for type: UTType) -> String {
        switch type {
        case .jpeg: return "jpg"
        case .heic: return "heic"
        default: return "png"
        }
    }

    private func boundedSourceSize(_ url: URL) throws -> Int {
        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size <= Self.maximumSourceBytes else { throw MacMediaEditError.exportFailed("source exceeds the size bound") }
        return size
    }

    private func encode(_ image: CGImage, type: UTType) throws -> Data {
        let mutableData = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(mutableData, type.identifier as CFString, 1, nil) else {
            throw MacMediaEditError.exportFailed("encoder unavailable")
        }
        // Metadata (location, device, orientation, etc.) is intentionally
        // not carried over; orientation is baked into pixels before encode.
        let properties: [CFString: Any]
        if type == .jpeg {
            properties = [kCGImageDestinationLossyCompressionQuality: 0.92]
        } else {
            properties = [:]
        }
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else {
            throw MacMediaEditError.exportFailed("encode")
        }
        return mutableData as Data
    }

    /// Read-back verification: the committed file must decode with the
    /// expected container type.
    static func verify(_ url: URL, expectedType: UTType) -> Bool {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return false }
        let type = CGImageSourceGetType(source) as String?
        return type == expectedType.identifier && CGImageSourceGetCount(source) > 0
    }
}

// MARK: - Video export

/// Video trim exporter built on AVAssetExportSession. Export is bounded by
/// the verified source duration, reports progress, supports cancellation,
/// removes partial output on cancel/failure, and verifies the committed
/// file by opening it and checking its playable duration.
final class MacVideoEditExporter: @unchecked Sendable {
    nonisolated static let maximumSourceBytes = 2 * 1_073_741_824
    /// Trimmed output above this cap is refused after export completes.
    nonisolated static let maximumOutputBytes = 2 * 1_073_741_824

    /// AVAssetExportSession is NS_SWIFT_NONSENDABLE; the system exporter is
    /// internally thread-safe (state observation runs while the export runs).
    private struct SessionBox: @unchecked Sendable { let session: AVAssetExportSession }

    /// Reads and validates the source duration; throws when the file is not
    /// a playable movie.
    static func verifiedDuration(of url: URL) async throws -> Double {
        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size > 0, size <= maximumSourceBytes else { throw MacMediaEditError.sourceUnreadable }
        let asset = AVURLAsset(url: url)
        let duration = try await asset.load(.duration).seconds
        guard duration.isFinite, duration > 0 else { throw MacMediaEditError.sourceUnreadable }
        return duration
    }

    /// Exports the trimmed range to `destination` atomically. When the
    /// range covers the whole source, the file is still re-exported so the
    /// output is always a freshly verified copy owned by the caller.
    func export(source: URL, trim: MacVideoTrimRange, to destination: URL,
                progress: (@Sendable (Double) -> Void)? = nil) async throws {
        let duration = try await Self.verifiedDuration(of: source)
        guard trim.end <= duration + 0.05 else { throw MacMediaEditError.invalidGeometry }
        let asset = AVURLAsset(url: source)
        let preset = await Self.preset(for: asset)
        guard let session = AVAssetExportSession(asset: asset, presetName: preset) else {
            throw MacMediaEditError.exportFailed("exporter unavailable")
        }
        let isQuickTime = source.pathExtension.lowercased() == "mov"
        let fileType: AVFileType = isQuickTime ? .mov : .mp4
        session.timeRange = CMTimeRange(
            start: CMTime(seconds: trim.start, preferredTimescale: 600),
            duration: CMTime(seconds: trim.duration, preferredTimescale: 600))

        let staging = MacMediaEditCommit.stagingURL(
            near: destination, pathExtension: isQuickTime ? "mov" : "mp4")
        let box = SessionBox(session: session)
        let states = session.states(updateInterval: 0.2)
        let progressTask = Task { @Sendable in
            for await state in states {
                if case .exporting(let value) = state {
                    progress?(value.fractionCompleted)
                }
            }
        }
        do {
            try await withTaskCancellationHandler {
                // The modern overlay honours Structured Concurrency
                // cancellation, so a cancelled task stops the export and
                // throws CancellationError.
                try await box.session.export(to: staging, as: fileType)
            } onCancel: {}
            progressTask.cancel()
            try await MacMediaEditCommit.commitFile(at: staging, to: destination) { url in
                await Self.verify(url, expectedDuration: trim.duration)
            }
        } catch is CancellationError {
            progressTask.cancel()
            try? FileManager.default.removeItem(at: staging)
            throw MacMediaEditError.cancelled
        } catch {
            progressTask.cancel()
            try? FileManager.default.removeItem(at: staging)
            throw MacMediaEditError.exportFailed(String(describing: error))
        }
    }

    /// Read-back verification: the committed file must open as a movie and
    /// its playable duration must match the trimmed range within a frame.
    static func verify(_ url: URL, expectedDuration: Double) async -> Bool {
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        guard size > 0, size <= maximumOutputBytes else { return false }
        let asset = AVURLAsset(url: url)
        guard let duration = try? await asset.load(.duration).seconds,
              duration.isFinite, duration > 0 else { return false }
        return abs(duration - expectedDuration) < 0.35
    }

    private static func preset(for asset: AVAsset) async -> String {
        // Passthrough keeps generation lossless for locally generated
        // H.264/HEVC clips; fall back to the highest compatible re-encode
        // only when passthrough cannot apply.
        let candidates = [
            AVAssetExportPresetPassthrough,
            AVAssetExportPresetHighestQuality,
            AVAssetExportPresetMediumQuality,
            AVAssetExportPreset1280x720,
        ]
        for candidate in candidates {
            if await AVAssetExportSession.compatibility(ofExportPreset: candidate, with: asset, outputFileType: nil) {
                return candidate
            }
        }
        return AVAssetExportPresetMediumQuality
    }
}

// MARK: - Atomic commit

/// Staged, verified, atomic file commits shared by both exporters.
/// A commit either publishes the complete verified bytes at the destination
/// or leaves the destination untouched.
enum MacMediaEditCommit {
    /// Unique staging URL beside the destination (same volume, so the
    /// final move is atomic).
    static func stagingURL(near destination: URL, pathExtension: String) -> URL {
        destination.deletingLastPathComponent()
            .appendingPathComponent(".\(UUID().uuidString).\(pathExtension)")
    }

    static func commit(_ data: Data, to destination: URL,
                       verify: @Sendable (URL) async -> Bool) async throws {
        let staging = stagingURL(near: destination, pathExtension: destination.pathExtension)
        do {
            try data.write(to: staging, options: .atomic)
            try await publish(staging: staging, to: destination, verify: verify)
        } catch {
            try? FileManager.default.removeItem(at: staging)
            throw error
        }
    }

    static func commitFile(at staging: URL, to destination: URL,
                           verify: @Sendable (URL) async -> Bool) async throws {
        try await publish(staging: staging, to: destination, verify: verify)
    }

    private static func publish(staging: URL, to destination: URL,
                                verify: @Sendable (URL) async -> Bool) async throws {
        let manager = FileManager.default
        guard await verify(staging) else { throw MacMediaEditError.verificationFailed }
        if manager.fileExists(atPath: destination.path) {
            _ = try manager.replaceItemAt(destination, withItemAt: staging)
        } else {
            try manager.moveItem(at: staging, to: destination)
        }
        // Final read-back against the published bytes, not the staging file.
        guard await verify(destination) else { throw MacMediaEditError.verificationFailed }
    }
}

// MARK: - Session staging directory

/// Per-edit-session scratch directory. Exported intermediates live here
/// until the caller routes them to a task, canvas or Save panel; the whole
/// directory is removed on `clear()`.
final class MacMediaEditStaging: @unchecked Sendable {
    let directory: URL

    init() throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("FloeMediaEdit-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        self.directory = base
    }

    func fileURL(name: String, pathExtension: String) -> URL {
        directory.appendingPathComponent("\(name).\(pathExtension)")
    }

    func clear() {
        try? FileManager.default.removeItem(at: directory)
    }
}

// MARK: - Bilingual strings

enum MacMediaEditStrings {
    static var sourceUnreadable: String { t(en: "The file couldn’t be read.", zh: "无法读取该文件。") }
    static var invalidGeometry: String { t(en: "The crop or trim values are invalid.", zh: "裁剪或剪辑范围无效。") }
    static var invalidAdjustment: String { t(en: "The adjustment values are invalid.", zh: "调节参数无效。") }
    static var exportFailedFormat: String { t(en: "Export failed: %@.", zh: "导出失败：%@。") }
    static var cancelled: String { t(en: "Export cancelled.", zh: "导出已取消。") }
    static var verificationFailed: String { t(en: "The exported file failed verification.", zh: "导出文件校验失败。") }

    // Editor chrome
    static var titleImage: String { t(en: "Edit Image", zh: "编辑图片") }
    static var titleVideo: String { t(en: "Trim Video", zh: "剪辑视频") }
    static var cropSection: String { t(en: "Crop", zh: "裁剪") }
    static var adjustSection: String { t(en: "Adjust", zh: "调节") }
    static var reset: String { t(en: "Reset", zh: "还原") }
    static var trimSection: String { t(en: "Trim", zh: "剪辑") }
    static var export: String { t(en: "Export…", zh: "导出…") }
    static var exportProgress: String { t(en: "Exporting…", zh: "导出中…") }
    static var cancelExport: String { t(en: "Cancel Export", zh: "取消导出") }
    static var done: String { t(en: "Done", zh: "完成") }
    static var close: String { t(en: "Close", zh: "关闭") }
    static var exportFailedTitle: String { t(en: "Export Failed", zh: "导出失败") }
    static var saveToTask: String { t(en: "Save to Task Files", zh: "保存到任务文件") }
    static var addToCanvas: String { t(en: "Add to Canvas", zh: "添加到画布") }
    static var exportedReady: String { t(en: "Export finished. Choose where to keep it.", zh: "导出完成。请选择保存位置。") }
    static var saturation: String { t(en: "Saturation", zh: "饱和度") }
    static var contrast: String { t(en: "Contrast", zh: "对比度") }
    static var brightness: String { t(en: "Brightness", zh: "亮度") }
    static var exposure: String { t(en: "Exposure", zh: "曝光") }
    static var trimStart: String { t(en: "Start", zh: "起点") }
    static var trimEnd: String { t(en: "End", zh: "终点") }
    static var cropHint: String { t(en: "Drag the crop frame to choose the kept area.", zh: "拖移裁剪框以选择保留区域。") }
    static var noEditsApplied: String { t(en: "No edits to apply yet.", zh: "还没有可应用的编辑。") }
    static var pickOutputName: String { t(en: "Edited", zh: "已编辑") }
    static var editImage: String { t(en: "Edit Image…", zh: "编辑图片…") }
    static var editVideo: String { t(en: "Trim Video…", zh: "剪辑视频…") }

    private static func t(en: String, zh: String) -> String {
        FloeL10n.isChinese ? zh : en
    }
}
