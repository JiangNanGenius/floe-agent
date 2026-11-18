// SPDX-License-Identifier: MPL-2.0
//
// Mac toolbox — calibrated photo measurement.
//
// The image stays in its decoded pixel coordinate space. The view transform is
// presentation only, so zooming, panning and resizing never change a result.
// Scale comes only from two user-placed reference points and a user-entered
// physical length; no DPI or camera metadata is treated as a ruler.

import AppKit
import Darwin
import CoreGraphics
import Foundation
import ImageIO
import Observation
import SwiftUI
import UniformTypeIdentifiers
import FloeToolboxCore
import FloeToolboxUtilities

public struct MacPhotoDecodedImage: Sendable {
    public let image: CGImage
    public let pixels: PhotoPoint
    public let wasDownsampled: Bool
    public init(image: CGImage, pixels: PhotoPoint, wasDownsampled: Bool) {
        self.image = image
        self.pixels = pixels
        self.wasDownsampled = wasDownsampled
    }
}

public enum MacPhotoDecoder {
    public static let maximumEncodedBytes = 64 * 1024 * 1024
    public static let maximumPixels = 20_000_000
    public static let maximumDecodeDimension = 8192
    public static let maximumExportDimension = 2048
    public static let maximumExportBytes = 64 * 1024 * 1024

    /// Bounded ImageIO decode. The file is inspected before pixels are
    /// decoded; large images are downsampled and EXIF orientation is applied,
    /// so the pixel coordinate space matches the image the user sees.
    nonisolated public static func decode(_ data: Data) throws -> MacPhotoDecodedImage {
        try Task.checkCancellation()
        guard data.count <= maximumEncodedBytes else { throw ToolboxError.limit("image data") }
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary) else {
            throw ToolboxError.invalid("image data")
        }
        guard let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let widthNumber = properties[kCGImagePropertyPixelWidth] as? NSNumber,
              let heightNumber = properties[kCGImagePropertyPixelHeight] as? NSNumber else {
            throw ToolboxError.invalid("image metadata")
        }
        let originalWidth = widthNumber.doubleValue
        let originalHeight = heightNumber.doubleValue
        guard originalWidth.isFinite, originalHeight.isFinite,
              originalWidth > 0, originalHeight > 0,
              originalWidth <= 32768, originalHeight <= 32768 else {
            throw ToolboxError.invalid("image dimensions")
        }
        let originalPixels = originalWidth * originalHeight
        let downsampleScale = originalPixels > Double(maximumPixels)
            ? (Double(maximumPixels) / originalPixels).squareRoot()
            : 1
        let target = min(maximumDecodeDimension,
                         max(1, Int((max(originalWidth, originalHeight) * downsampleScale).rounded(.down))))
        let options = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCache: false,
            kCGImageSourceThumbnailMaxPixelSize: target,
        ] as CFDictionary
        try Task.checkCancellation()
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options) else {
            throw ToolboxError.invalid("image decode")
        }
        try Task.checkCancellation()
        let width = Double(image.width)
        let height = Double(image.height)
        guard width.isFinite, height.isFinite, width > 0, height > 0,
              width <= Double(maximumDecodeDimension), height <= Double(maximumDecodeDimension),
              width * height <= Double(maximumPixels) * 1.0001 else {
            throw ToolboxError.limit("decoded image")
        }
        let wasDownsampled = width * height < originalPixels * 0.999
        return MacPhotoDecodedImage(image: image, pixels: PhotoPoint(width, height), wasDownsampled: wasDownsampled)
    }

    nonisolated public static func encodePNG(_ image: CGImage) throws -> Data {
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, UTType.png.identifier as CFString, 1, nil) else {
            throw ToolboxError.invalid("PNG encoder")
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw ToolboxError.invalid("PNG encoder") }
        let data = output as Data
        guard data.count <= maximumExportBytes else { throw ToolboxError.limit("export size") }
        return data
    }
}

/// One decode at a time. ImageIO stays on this actor; only the immutable
/// image and value geometry cross back to the main actor.
public actor MacPhotoDecodeWorker {
    public static let shared = MacPhotoDecodeWorker()

    public func decode(_ data: Data) throws -> MacPhotoDecodedImage {
        try Task.checkCancellation()
        let value = try MacPhotoDecoder.decode(data)
        try Task.checkCancellation()
        return value
    }
}

enum MacPhotoFileIO {
    struct Identity: Sendable, Equatable {
        let device: dev_t
        let inode: ino_t
        let size: Int64
        let modifiedSeconds: Int64
        let modifiedNanos: Int64
        let changedSeconds: Int64
        let changedNanos: Int64

        init(_ info: stat) {
            device = info.st_dev
            inode = info.st_ino
            size = info.st_size
            modifiedSeconds = Int64(info.st_mtimespec.tv_sec)
            modifiedNanos = Int64(info.st_mtimespec.tv_nsec)
            changedSeconds = Int64(info.st_ctimespec.tv_sec)
            changedNanos = Int64(info.st_ctimespec.tv_nsec)
        }
    }

    static func identity(_ url: URL) throws -> Identity {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        try Task.checkCancellation()
        var info = stat()
        guard lstat(url.path, &info) == 0,
              (info.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG) else { throw ToolboxError.invalid("image file") }
        return Identity(info)
    }

    static func read(_ url: URL, expected: Identity? = nil, onChunk: (@Sendable () -> Void)? = nil) throws -> Data {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        try Task.checkCancellation()
        let expected = try expected ?? identity(url)
        let fd = Darwin.open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { _ = Darwin.close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0,
              (info.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG),
              Identity(info) == expected else { throw ToolboxError.invalid("image file changed") }
        guard info.st_size >= 0, info.st_size <= Int64(MacPhotoDecoder.maximumEncodedBytes) else { throw ToolboxError.limit("image data") }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 65_536)
        while true {
            try Task.checkCancellation()
            let remaining = MacPhotoDecoder.maximumEncodedBytes - data.count
            let count = Darwin.read(fd, &buffer, min(buffer.count, remaining + 1))
            if count < 0 && errno == EINTR { continue }
            guard count >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            if count == 0 { break }
            guard count <= remaining else { throw ToolboxError.limit("image data") }
            data.append(contentsOf: buffer.prefix(count))
            onChunk?()
        }
        try Task.checkCancellation()
        guard fstat(fd, &info) == 0, Identity(info) == expected else { throw ToolboxError.invalid("image file changed") }
        return data
    }

    static func writeNew(_ data: Data, to url: URL, control: MacPhotoExportControl = MacPhotoExportControl(), beforeCommit: (@Sendable (URL) throws -> Void)? = nil) throws -> MacPhotoExportOutcome {
        try MacPhotoAtomicExport.write(data, to: url, control: control, beforeCommit: beforeCommit)
    }
}

enum MacPhotoPrimitive {
    case segment(PhotoPoint, PhotoPoint, Bool)
    case marker(PhotoPoint)
    case label(PhotoPoint, String)
}

@MainActor
@Observable
public final class MacPhotoMeasureModel {
    public enum Phase: Equatable, Sendable {
        case empty
        case importing
        case ready
        case failed
    }

    public private(set) var phase: Phase = .empty
    public private(set) var image: CGImage?
    public private(set) var imagePixels: PhotoPoint = .zero
    public private(set) var wasDownsampled = false
    public private(set) var store = PhotoMeasureStore()
    public private(set) var transform: PhotoViewTransform?
    public private(set) var hint: MacInstrumentNotice?
    public private(set) var lastExportError: MacInstrumentNotice?
    public var mode: PhotoMeasureMode = .length
    public var unit: PhotoUnit
    public var referenceValueText = ""

    private var viewSize: PhotoPoint?
    private var generation = UUID()
    private var decodeTask: Task<MacPhotoDecodedImage, Error>?
    private var importTask: Task<Void, Never>?
    private var exportTask: Task<Void, Never>?
    private var exportControl: MacPhotoExportControl?
    private let activity: MacInstrumentActivityCoordinator?

    public init(unit: PhotoUnit? = nil, activity: MacInstrumentActivityCoordinator? = nil) {
        self.unit = unit ?? PhotoUnit.default(metric: Locale.current.measurementSystem == .metric)
        self.activity = activity
    }

    public var isCalibrated: Bool { store.isCalibrated }
    public var referencePointCount: Int { store.referencePoints.count }
    public var allPoints: [PhotoMeasurePoint] { store.referencePoints + store.vertices }
    public var canExport: Bool { phase == .ready && image != nil && store.isCalibrated }

    public var readout: PhotoMeasureReadout {
        PhotoMeasurementMath.readout(mode: mode, vertices: store.vertices, calibration: store.calibration)
    }

    public var parsedReferenceValue: Double? {
        let trimmed = referenceValueText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let normalized = trimmed.contains(".") ? trimmed : trimmed.replacingOccurrences(of: ",", with: ".")
        guard let value = Double(normalized), value.isFinite, value > 0 else { return nil }
        return value
    }

    public var canApplyCalibration: Bool {
        store.hasReferencePair && parsedReferenceValue != nil
    }

    public func importImage(from url: URL) {
        cancelImport()
        let expected: MacPhotoFileIO.Identity
        do { expected = try MacPhotoFileIO.identity(url) }
        catch {
            hint = MacInstrumentNotice(zh: "图片无法读取，请选择普通图片文件。",
                                       en: "The image could not be read. Choose a regular image file.")
            return
        }
        let token = UUID()
        generation = token
        phase = .importing
        importTask = Task { [weak self] in
            guard !Task.isCancelled, let self, self.generation == token else { return }
            let worker = Task.detached { try MacPhotoFileIO.read(url, expected: expected) }
            do {
                let data = try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
                try Task.checkCancellation()
                guard self.generation == token else { return }
                await self.load(data: data)
            } catch is CancellationError {
            } catch {
                guard self.generation == token else { return }
                self.phase = self.image == nil ? .empty : .ready
                self.hint = MacInstrumentNotice(
                    zh: "图片无法读取或超过 64 MB。请检查文件并重试。",
                    en: "The image could not be read or exceeds 64 MB. Check the file and try again.")
            }
        }
    }

    public func load(data: Data) async {
        decodeTask?.cancel()
        decodeTask = nil
        let token = UUID()
        generation = token
        phase = .importing
        hint = nil
        defer {
            if generation == token {
                decodeTask = nil
                if phase == .importing { phase = image == nil ? .empty : .ready }
            }
        }
        do {
            let task = Task { try await MacPhotoDecodeWorker.shared.decode(data) }
            decodeTask = task
            let decoded = try await withTaskCancellationHandler {
                try await task.value
            } onCancel: {
                task.cancel()
            }
            try Task.checkCancellation()
            guard generation == token else { return }
            image = decoded.image
            imagePixels = decoded.pixels
            wasDownsampled = decoded.wasDownsampled
            store.beginImage(token)
            transform = viewSize.flatMap {
                PhotoViewTransform.fitting(imageSize: decoded.pixels, into: $0)
            }
            phase = .ready
        } catch is CancellationError {
            // A cancelled import leaves the previous image untouched.
        } catch {
            guard generation == token else { return }
            hint = MacInstrumentNotice(
                zh: "图片无法载入。请选择有效的 PNG、JPEG、HEIC 或 TIFF 图片。",
                en: "The image could not be loaded. Choose a valid PNG, JPEG, HEIC or TIFF image.")
            phase = image == nil ? .failed : .ready
        }
    }

    public func cancelImport() {
        generation = UUID()
        importTask?.cancel()
        importTask = nil
        decodeTask?.cancel()
        decodeTask = nil
        if phase == .importing { phase = image == nil ? .empty : .ready }
    }

    public func setViewSize(_ size: CGSize) {
        let value = PhotoPoint(size.width, size.height)
        guard value.isFinite, value.x > 0, value.y > 0 else { return }
        let previous = viewSize
        viewSize = value
        guard let fit = PhotoViewTransform.fitting(imageSize: imagePixels, into: value) else { return }
        guard let transform, let previous,
              let previousFit = PhotoViewTransform.fitting(imageSize: imagePixels, into: previous) else {
            self.transform = fit
            return
        }
        if previous == value {
            self.transform = transform.clampedPan(imageSize: imagePixels, viewSize: value)
            return
        }
        let zoom = max(1, transform.scale / previousFit.scale)
        let scale = min(fit.scale * zoom, max(fit.scale, 64))
        let focus = transform.imagePoint(fromView: PhotoPoint(previous.x / 2, previous.y / 2))
        let offset = PhotoPoint(value.x / 2 - focus.x * scale, value.y / 2 - focus.y * scale)
        self.transform = (PhotoViewTransform(scale: scale, offset: offset) ?? fit)
            .clampedPan(imageSize: imagePixels, viewSize: value)
    }

    public func zoom(factor: Double, anchor: CGPoint) {
        guard let transform, let viewSize else { return }
        self.transform = transform.zoomed(by: factor, anchor: PhotoPoint(anchor.x, anchor.y))?
            .clampedPan(imageSize: imagePixels, viewSize: viewSize)
    }

    public func pan(delta: CGSize) {
        guard let transform, let viewSize else { return }
        self.transform = transform.panned(by: PhotoPoint(delta.width, delta.height))?
            .clampedPan(imageSize: imagePixels, viewSize: viewSize)
    }

    public func resetZoom() {
        transform = viewSize.flatMap { PhotoViewTransform.fitting(imageSize: imagePixels, into: $0) }
    }

    public func tap(at point: CGPoint) {
        guard phase == .ready, let transform else { return }
        let imagePoint = transform.imagePoint(fromView: PhotoPoint(point.x, point.y))
        guard imagePoint.x >= 0, imagePoint.y >= 0,
              imagePoint.x <= imagePixels.x, imagePoint.y <= imagePixels.y else { return }
        guard handleHitTest(point) == nil else { return }
        do {
            if !store.isCalibrated {
                try store.addReferencePoint(imagePoint)
            } else {
                try store.addVertex(imagePoint)
            }
            hint = nil
        } catch {
            hint = placeHint(error)
        }
    }

    public func addReferencePoint(pixel: PhotoPoint) {
        do {
            try store.addReferencePoint(pixel)
            hint = nil
        } catch {
            hint = placeHint(error)
        }
    }

    public func addVertex(pixel: PhotoPoint) {
        do {
            try store.addVertex(pixel)
            hint = nil
        } catch {
            hint = placeHint(error)
        }
    }

    public func handleHitTest(_ point: CGPoint) -> UUID? {
        guard let transform else { return nil }
        var best: (UUID, Double)?
        for placed in allPoints {
            let view = transform.viewPoint(fromImage: placed.position)
            let dx = view.x - Double(point.x)
            let dy = view.y - Double(point.y)
            let distance = (dx * dx + dy * dy).squareRoot()
            guard distance <= 26 else { continue }
            if distance < (best?.1 ?? .infinity) { best = (placed.id, distance) }
        }
        return best?.0
    }

    public func moveHandle(id: UUID, to point: CGPoint) {
        guard let transform else { return }
        let raw = transform.imagePoint(fromView: PhotoPoint(point.x, point.y))
        let clamped = PhotoPoint(min(max(raw.x, 0), imagePixels.x),
                                 min(max(raw.y, 0), imagePixels.y))
        if store.referencePoints.contains(where: { $0.id == id }) {
            try? store.moveReferencePoint(id: id, to: clamped)
        } else {
            try? store.moveVertex(id: id, to: clamped)
        }
    }

    public func applyCalibration() {
        guard let value = parsedReferenceValue else { return }
        do {
            try store.applyCalibration(value: value, unit: unit)
            hint = nil
        } catch {
            hint = MacInstrumentNotice(
                zh: "无法应用尺度。请放置两个不同的参照点，并检查参考长度。",
                en: "The scale could not be applied. Place two distinct reference points and check the reference length.")
        }
    }

    public func recalibrate() {
        store.reset()
    }

    public func undo() { store.undo() }
    public func clearMeasurements() { store.clearVertices() }

    public func annotatedPNGData() throws -> Data {
        try MacPhotoDecoder.encodePNG(renderAnnotatedImage())
    }

    private func renderAnnotatedImage() throws -> CGImage {
        lastExportError = nil
        guard canExport, let image, let calibration = store.calibration else {
            throw ToolboxError.invalid("export")
        }
        let longEdge = max(imagePixels.x, imagePixels.y)
        let exportScale = longEdge > Double(MacPhotoDecoder.maximumExportDimension)
            ? Double(MacPhotoDecoder.maximumExportDimension) / longEdge
            : 1
        let content = MacPhotoExportContent(
            image: image,
            pixels: imagePixels,
            primitives: primitives(calibration: calibration),
            outputScale: exportScale)
        let renderer = ImageRenderer(content: content)
        renderer.scale = exportScale
        renderer.isOpaque = true
        guard let rendered = renderer.cgImage else { throw ToolboxError.invalid("export render") }
        return rendered
    }

    /// Annotations for the on-screen overlay. The same primitives feed the
    /// exported PNG, so the on-screen and exported layouts cannot drift.
    var screenPrimitives: [MacPhotoPrimitive] {
        if let calibration = store.calibration {
            return primitives(calibration: calibration)
        }
        var values: [MacPhotoPrimitive] = []
        let reference = store.referencePoints.map(\.position)
        if reference.count == 2 { values.append(.segment(reference[0], reference[1], true)) }
        for point in reference { values.append(.marker(point)) }
        return values
    }

    public func clearExportError() {
        lastExportError = nil
    }

    public func exportAnnotatedPNG(to url: URL) {
        guard exportTask == nil else { return }
        guard activity?.acceptsNewWork != false else { return }
        do {
            let rendered = try renderAnnotatedImage()
            let control = MacPhotoExportControl()
            let token = activity?.begin()
            guard activity == nil || token != nil else { return }
            exportControl = control
            let activity = self.activity
            exportTask = Task { [weak self, activity] in
                defer { if let token { activity?.finish(token) } }
                guard !Task.isCancelled else { control.cancel(); self?.exportTask = nil; self?.exportControl = nil; return }
                let worker = Task.detached {
                    try control.check()
                    let data = try MacPhotoDecoder.encodePNG(rendered)
                    try control.check()
                    return try MacPhotoFileIO.writeNew(data, to: url, control: control)
                }
                do {
                    let outcome = try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
                    self?.exportTask = nil
                    self?.exportControl = nil
                    switch outcome {
                    case .committed:
                        self?.lastExportError = MacInstrumentNotice(
                            zh: "图片已导出。", en: "The image was exported.")
                    case .committedDurabilityUncertain:
                        self?.lastExportError = MacInstrumentNotice(
                            zh: "图片已创建并校验，但无法确认已写入存储设备。",
                            en: "The image was created and verified, but storage synchronization could not be confirmed.")
                    case .committedUnverified:
                        self?.lastExportError = MacInstrumentNotice(
                            zh: "目标可能已经创建，但无法确认导出结果。请检查目标文件。",
                            en: "The destination may have been created, but the export could not be verified. Check it.")
                    }
                } catch is CancellationError {
                    self?.exportTask = nil
                    self?.exportControl = nil
                } catch {
                    self?.exportTask = nil
                    self?.exportControl = nil
                    self?.lastExportError = MacInstrumentNotice(
                        zh: "未能导出。请选择新文件名；目标与临时目录须位于支持克隆的同一宗卷。",
                        en: "Export failed. Choose a new filename on the same clone-capable volume as the temporary directory.")
                }
            }
        } catch {
            lastExportError = MacInstrumentNotice(zh: "无法生成标注图片。", en: "The annotated image could not be generated.")
        }
    }

    public func cancelExport() { exportControl?.cancel(); exportTask?.cancel() }

    /// Annotations are built from the same math used by the readout. The
    /// exported image is presentation, not a second measurement path.
    func primitives(calibration: PhotoCalibration) -> [MacPhotoPrimitive] {
        var values: [MacPhotoPrimitive] = []
        let reference = store.referencePoints.map(\.position)
        if reference.count == 2 {
            values.append(.segment(reference[0], reference[1], true))
        }
        for point in reference { values.append(.marker(point)) }
        let vertices = store.vertices.map(\.position)
        switch mode {
        case .length:
            for index in 1..<max(vertices.count, 1) where index < vertices.count {
                values.append(.segment(vertices[index - 1], vertices[index], false))
                if let length = PhotoMeasurementMath.distance(vertices[index - 1], vertices[index]),
                   let meters = PhotoMeasurementMath.physicalLength(pixels: length, calibration: calibration) {
                    values.append(.label(midpoint(vertices[index - 1], vertices[index]), unit.format(meters)))
                }
            }
        case .area:
            if vertices.count >= 3 {
                for index in 0..<vertices.count {
                    values.append(.segment(vertices[index], vertices[(index + 1) % vertices.count], false))
                }
                if let area = readout.area {
                    values.append(.label(centroid(vertices), unit.areaFormat(area)))
                }
            }
        case .angle:
            for index in stride(from: 0, to: max(vertices.count - 2, 0), by: 3)
            where index + 2 < vertices.count {
                let a = vertices[index], b = vertices[index + 1], c = vertices[index + 2]
                values.append(.segment(b, a, false))
                values.append(.segment(b, c, false))
                if let angle = PhotoMeasurementMath.angle(vertex: b, first: a, second: c) {
                    values.append(.label(b, String(format: "%.1f°", locale: Locale(identifier: "en_US_POSIX"), angle)))
                }
            }
        }
        for point in vertices { values.append(.marker(point)) }
        return values
    }

    private func midpoint(_ a: PhotoPoint, _ b: PhotoPoint) -> PhotoPoint {
        PhotoPoint((a.x + b.x) / 2, (a.y + b.y) / 2)
    }

    private func centroid(_ points: [PhotoPoint]) -> PhotoPoint {
        guard !points.isEmpty else { return .zero }
        let count = Double(points.count)
        return PhotoPoint(points.reduce(0) { $0 + $1.x } / count,
                          points.reduce(0) { $0 + $1.y } / count)
    }

    private func placeHint(_ error: Error) -> MacInstrumentNotice {
        if case PhotoMeasurementError.tooManyPoints = error {
            return MacInstrumentNotice(
                zh: "最多放置 \(PhotoMeasurementMath.maximumVertices) 个测量点。",
                en: "You can place up to \(PhotoMeasurementMath.maximumVertices) measurement points.")
        }
        return MacInstrumentNotice(
            zh: "此点无法放置。请与已有点保持距离，并确保点在图片范围内。",
            en: "This point cannot be placed. Keep it apart from existing points and inside the image.")
    }
}

private struct MacPhotoExportContent: View {
    let image: CGImage
    let pixels: PhotoPoint
    let primitives: [MacPhotoPrimitive]
    let outputScale: CGFloat

    var body: some View {
        ZStack(alignment: .topLeading) {
            Image(decorative: image, scale: 1)
                .resizable()
                .frame(width: pixels.x, height: pixels.y)
            MacPhotoAnnotationOverlay(
                primitives: primitives,
                map: { CGPoint(x: $0.x, y: $0.y) },
                lineWidth: 2 / outputScale,
                fontSize: 14 / outputScale)
        }
        .frame(width: pixels.x, height: pixels.y)
        .clipped()
    }
}

struct MacPhotoAnnotationOverlay: View {
    let primitives: [MacPhotoPrimitive]
    let map: (PhotoPoint) -> CGPoint
    let lineWidth: CGFloat
    let fontSize: CGFloat

    var body: some View {
        Canvas { context, _ in
            for primitive in primitives {
                switch primitive {
                case .segment(let start, let end, let reference):
                    var path = Path()
                    path.move(to: map(start))
                    path.addLine(to: map(end))
                    context.stroke(path,
                                   with: .color(reference ? .orange : .accentColor),
                                   style: StrokeStyle(lineWidth: lineWidth, lineCap: .round, lineJoin: .round))
                case .marker(let point):
                    let center = map(point)
                    let radius = max(lineWidth * 2.4, 3)
                    let dot = Path(ellipseIn: CGRect(x: center.x - radius, y: center.y - radius,
                                                     width: radius * 2, height: radius * 2))
                    context.fill(dot, with: .color(.accentColor))
                    context.stroke(dot, with: .color(.white.opacity(0.9)), lineWidth: max(1, lineWidth * 0.5))
                case .label(let anchor, let text):
                    drawLabel(text, at: map(anchor), in: &context)
                }
            }
        }
    }

    private func drawLabel(_ text: String, at point: CGPoint, in context: inout GraphicsContext) {
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: fontSize, weight: .semibold)
        ]
        let size = (text as NSString).size(withAttributes: attributes)
        let padding = fontSize * 0.35
        let background = CGRect(x: point.x - size.width / 2 - padding,
                                y: point.y - size.height / 2 - padding,
                                width: size.width + padding * 2,
                                height: size.height + padding * 2)
        context.fill(Path(roundedRect: background, cornerRadius: (size.height + padding * 2) / 2.4),
                     with: .color(.black.opacity(0.62)))
        context.draw(Text(text).font(.system(size: fontSize, weight: .semibold, design: .rounded))
            .foregroundColor(.white), at: point, anchor: .center)
    }
}
