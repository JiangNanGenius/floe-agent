import SwiftUI
import ImageIO
import UniformTypeIdentifiers
import FloeToolboxCore
import FloeToolboxUtilities

/// Drawing primitive for measurement annotations. Positions are always image
/// pixels; callers supply the mapping into their display space, which is why
/// the same layout renders identically on screen and in the exported PNG.
enum PhotoAnnotationPrimitive {
    case segment(PhotoPoint, PhotoPoint, PhotoAnnotationStyle)
    case marker(PhotoPoint, PhotoAnnotationStyle)
    case label(PhotoPoint, String, PhotoAnnotationStyle)
}

enum PhotoAnnotationStyle {
    case reference, measure

    var color: Color {
        switch self {
        case .reference: Color.orange
        case .measure: Color.accentColor
        }
    }
}

/// Renders measurement primitives in an arbitrary display space. Hit testing
/// is handled elsewhere, so this overlay never intercepts gestures.
struct PhotoMeasureAnnotationOverlay: View {
    var primitives: [PhotoAnnotationPrimitive]
    var map: (PhotoPoint) -> CGPoint
    var lineWidth: CGFloat
    var fontSize: CGFloat

    var body: some View {
        Canvas { context, _ in
            for primitive in primitives {
                switch primitive {
                case .segment(let start, let end, let style):
                    var path = Path()
                    path.move(to: map(start))
                    path.addLine(to: map(end))
                    context.stroke(path, with: .color(style.color),
                                   style: StrokeStyle(lineWidth: lineWidth, lineCap: .round, lineJoin: .round))
                case .marker(let point, let style):
                    let center = map(point)
                    let radius = max(lineWidth * 2.4, 3)
                    let dot = Path(ellipseIn: CGRect(x: center.x - radius, y: center.y - radius,
                                                     width: radius * 2, height: radius * 2))
                    context.fill(dot, with: .color(style.color))
                    context.stroke(dot, with: .color(.white.opacity(0.9)), lineWidth: max(1, lineWidth * 0.5))
                case .label(let anchor, let text, _):
                    drawLabel(text, at: anchor, into: &context)
                }
            }
        }
    }

    private func drawLabel(_ text: String, at anchor: PhotoPoint,
                           into context: inout GraphicsContext) {
        let point = map(anchor)
        let size = (text as NSString).size(withAttributes: [.font: Self.platformFont(size: fontSize)])
        let padding = fontSize * 0.35
        let background = CGRect(x: point.x - size.width / 2 - padding,
                                y: point.y - size.height / 2 - padding,
                                width: size.width + padding * 2,
                                height: size.height + padding * 2)
        let radius = (size.height + padding * 2) / 2.4
        context.fill(Path(roundedRect: background, cornerRadius: radius),
                     with: .color(.black.opacity(0.62)))
        let label = Text(text)
            .font(.system(size: fontSize, weight: .semibold, design: .rounded))
            .foregroundStyle(.white)
        context.draw(label, at: point, anchor: .center)
    }

    /// Platform font used only for measuring the label pill; the drawn text
    /// uses the same size and weight, so the metrics match.
    static func platformFont(size: CGFloat) -> FontHolder {
        #if canImport(UIKit)
        UIFont.systemFont(ofSize: size, weight: .semibold)
        #else
        NSFont.systemFont(ofSize: size, weight: .semibold)
        #endif
    }
}

#if canImport(UIKit)
import UIKit
typealias FontHolder = UIFont
#elseif canImport(AppKit)
import AppKit
typealias FontHolder = NSFont
#endif

/// Offscreen render target for the annotated export. The view is laid out in
/// image pixels and the renderer scale applies the export cap, so the output
/// is exactly the annotated image at its capped size.
private struct PhotoMeasureExportContent: View {
    let image: CGImage
    let pixels: PhotoPoint
    let primitives: [PhotoAnnotationPrimitive]
    let outputScale: CGFloat

    var body: some View {
        ZStack(alignment: .topLeading) {
            Image(decorative: image, scale: 1)
                .resizable()
                .frame(width: pixels.x, height: pixels.y)
            PhotoMeasureAnnotationOverlay(
                primitives: primitives,
                map: { point in CGPoint(x: point.x, y: point.y) },
                lineWidth: 2 / outputScale,
                fontSize: 14 / outputScale)
        }
        .frame(width: pixels.x, height: pixels.y)
        .clipped()
    }
}

struct PhotoDecodedImage: Sendable {
    let image: CGImage
    let pixels: PhotoPoint
    let wasDownsampled: Bool
}

/// One decode at a time across workbenches. ImageIO objects stay on this actor;
/// only encoded Data and the SDK's immutable, Sendable CGImage cross executors.
private actor PhotoImageDecodeWorker {
    static let shared = PhotoImageDecodeWorker()

    func decode(_ data: Data) throws -> PhotoDecodedImage {
        try Task.checkCancellation()
        let decoded = try PhotoMeasureModel.decodeImage(from: data)
        try Task.checkCancellation()
        return decoded
    }
}

/// State and media pipeline for the photo measurement workbench. All numbers
/// shown to the user come from the pure math layer; this class only owns
/// decoding bounds, gesture-to-image mapping, lifecycle fencing and export.
@MainActor public final class PhotoMeasureModel: ObservableObject {
    public enum Phase: Equatable, Sendable {
        case empty, importing, ready, failed(String)
    }

    /// Encoded image input above this many bytes is rejected before parsing.
    nonisolated public static let maximumEncodedBytes = 64 * 1024 * 1024
    /// Decode target: images above this many pixels are downsampled first so
    /// memory stays bounded; the smaller dimension follows aspect ratio.
    nonisolated public static let maximumPixels = 20_000_000
    /// Hard cap on the decoded image's long edge.
    nonisolated public static let maximumDecodeDimension = 8192
    /// The annotated export is scaled down so its long edge fits this.
    public static let exportMaximumDimension = 4096
    /// Encoded PNG output above this many bytes is rejected.
    public static let maximumExportBytes = 64 * 1024 * 1024
    /// Reference/measurement points may not leave the image bounds.
    static let handleGrabRadius: CGFloat = 26

    @Published public private(set) var phase: Phase = .empty
    @Published public private(set) var image: CGImage?
    @Published public private(set) var imagePixels: PhotoPoint = .zero
    @Published public private(set) var wasDownsampled = false
    @Published public private(set) var store = PhotoMeasureStore()
    @Published public var mode: PhotoMeasureMode = .length
    @Published public var unit: PhotoUnit
    @Published public var referenceValueText = ""
    @Published public private(set) var hint: String?
    @Published public private(set) var lastExportError: String?
    @Published public private(set) var transform: PhotoViewTransform?

    private let importImage: @MainActor () async throws -> Data?
    private let exportImage: @MainActor (Data) -> Void
    private var generation = UUID()
    private var decodeTask: Task<PhotoDecodedImage, Error>?

    public init(unit: PhotoUnit = PhotoUnit.default(metric: Locale.current.measurementSystem == .metric),
                importImage: @escaping @MainActor () async throws -> Data?,
                exportImage: @escaping @MainActor (Data) -> Void) {
        self.unit = unit
        self.importImage = importImage
        self.exportImage = exportImage
    }

    // MARK: - Derived state

    public var isCalibrated: Bool { store.isCalibrated }
    public var referencePointCount: Int { store.referencePoints.count }
    public var canExport: Bool { phase == .ready && image != nil && store.isCalibrated }

    public var readout: PhotoMeasureReadout {
        PhotoMeasurementMath.readout(mode: mode, vertices: store.vertices, calibration: store.calibration)
    }

    /// Parses the reference length field. Accepts a decimal comma when there
    /// is no decimal point, so both 5.4 and 5,4 work.
    public var parsedReferenceValue: Double? {
        let trimmed = referenceValueText.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        let normalized = trimmed.contains(".") ? trimmed : trimmed.replacingOccurrences(of: ",", with: ".")
        guard let value = Double(normalized), value.isFinite else { return nil }
        return value
    }

    public var canApplyCalibration: Bool {
        store.hasReferencePair && (parsedReferenceValue ?? 0) > 0
    }

    public var allPoints: [PhotoMeasurePoint] { store.referencePoints + store.vertices }

    // MARK: - Import

    /// Asks the host for an image and decodes it within documented bounds.
    /// Late decode results from a previous request are discarded: the
    /// generation fence guarantees only the newest import commits state.
    public func importFromHost() async {
        decodeTask?.cancel()
        decodeTask = nil
        let token = UUID()
        generation = token
        phase = .importing
        defer {
            if generation == token {
                decodeTask = nil
                phase = image != nil ? .ready : .empty
            }
        }
        do {
            try Task.checkCancellation()
            guard let data = try await importImage() else { return }
            try Task.checkCancellation()
            guard generation == token else { return }
            let task = Task { try await PhotoImageDecodeWorker.shared.decode(data) }
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
            transform = currentViewSize.flatMap {
                PhotoViewTransform.fitting(imageSize: decoded.pixels, into: $0)
            }
            hint = nil
        } catch is CancellationError {
            // A cancelled import leaves the previous image untouched.
        } catch {
            guard generation == token else { return }
            hint = Self.describe(error)
        }
    }

    /// Fences picker/decode callbacks when the workbench leaves the screen.
    /// Existing image, viewport and measurements remain ready for its return.
    public func cancelImport() {
        generation = UUID()
        decodeTask?.cancel()
        decodeTask = nil
        if phase == .importing { phase = image != nil ? .ready : .empty }
    }

    /// Bounded ImageIO decode: properties are inspected before any pixel is
    /// decoded, sources above the pixel budget are downsampled via the
    /// thumbnail path, and the EXIF orientation transform is always applied
    /// so measurements line up with what the user sees.
    nonisolated static func decodeImage(from data: Data) throws -> PhotoDecodedImage {
        try Task.checkCancellation()
        guard data.count <= maximumEncodedBytes else { throw ToolboxError.limit("image data") }
        let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithData(data as CFData, sourceOptions) else {
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
        let targetMaxDimension = min(maximumDecodeDimension,
                                     max(1, Int((max(originalWidth, originalHeight) * downsampleScale).rounded(.down))))
        let thumbnailOptions = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCache: false,
            kCGImageSourceThumbnailMaxPixelSize: targetMaxDimension,
        ] as CFDictionary
        try Task.checkCancellation()
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbnailOptions) else {
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
        return PhotoDecodedImage(image: image, pixels: PhotoPoint(width, height), wasDownsampled: wasDownsampled)
    }

    // MARK: - Viewport

    /// Fits the first real viewport. Resizing preserves zoom relative to the
    /// previous fit and the image point at the viewport center, then clamps pan.
    public func updateViewport(_ size: CGSize) {
        let viewSize = PhotoPoint(size.width, size.height)
        guard viewSize.isFinite, viewSize.x > 0, viewSize.y > 0 else { return }
        let previousSize = currentViewSize
        currentViewSize = viewSize
        guard let fit = PhotoViewTransform.fitting(imageSize: imagePixels, into: viewSize) else { return }
        guard let transform, let previousSize,
              let previousFit = PhotoViewTransform.fitting(imageSize: imagePixels, into: previousSize) else {
            self.transform = fit
            return
        }
        if previousSize == viewSize {
            self.transform = transform.clampedPan(imageSize: imagePixels, viewSize: viewSize)
            return
        }
        let zoom = max(1, transform.scale / previousFit.scale)
        let scale = min(fit.scale * zoom, max(fit.scale, 64))
        let focus = transform.imagePoint(fromView: PhotoPoint(previousSize.x / 2, previousSize.y / 2))
        let offset = PhotoPoint(viewSize.x / 2 - focus.x * scale, viewSize.y / 2 - focus.y * scale)
        self.transform = (PhotoViewTransform(scale: scale, offset: offset) ?? fit)
            .clampedPan(imageSize: imagePixels, viewSize: viewSize)
    }

    public func zoom(by factor: Double, anchor: CGPoint) {
        guard let transform, let currentViewSize else { return }
        self.transform = transform
            .zoomed(by: factor, anchor: PhotoPoint(anchor.x, anchor.y))?
            .clampedPan(imageSize: imagePixels, viewSize: currentViewSize)
    }

    public func pan(by delta: CGSize) {
        guard let transform, let currentViewSize else { return }
        self.transform = transform
            .panned(by: PhotoPoint(delta.width, delta.height))?
            .clampedPan(imageSize: imagePixels, viewSize: currentViewSize)
    }

    public func resetZoom() {
        transform = currentViewSize.flatMap {
            PhotoViewTransform.fitting(imageSize: imagePixels, into: $0)
        }
    }

    private var currentViewSize: PhotoPoint?
    public func setViewSize(_ size: CGSize) {
        updateViewport(size)
    }

    // MARK: - Editing

    /// Converts a tap into a reference or measurement point. Taps outside the
    /// image and taps that land on an existing handle are ignored.
    public func tap(at viewPoint: CGPoint) {
        guard phase == .ready, let transform else { return }
        let imagePoint = transform.imagePoint(fromView: PhotoPoint(viewPoint.x, viewPoint.y))
        guard imagePoint.x >= 0, imagePoint.y >= 0,
              imagePoint.x <= imagePixels.x, imagePoint.y <= imagePixels.y else { return }
        if handleHitTest(viewPoint) != nil { return }
        do {
            if !store.isCalibrated {
                try store.addReferencePoint(imagePoint)
                hint = nil
            } else {
                try store.addVertex(imagePoint)
                hint = nil
            }
        } catch {
            hint = Self.describe(error)
        }
    }

    /// Nearest placed point within the grab radius, in view coordinates.
    public func handleHitTest(_ viewPoint: CGPoint) -> UUID? {
        guard let transform else { return nil }
        var best: (id: UUID, distance: CGFloat)?
        for point in allPoints {
            let view = transform.viewPoint(fromImage: point.position)
            let dx = view.x - Double(viewPoint.x)
            let dy = view.y - Double(viewPoint.y)
            let distance = (dx * dx + dy * dy).squareRoot()
            guard distance <= Self.handleGrabRadius else { continue }
            if distance < (best?.distance ?? .infinity) { best = (point.id, distance) }
        }
        return best?.id
    }

    /// Moves a handle, clamping to the image bounds so measurements can never
    /// reference pixels outside the decoded image.
    public func moveHandle(id: UUID, to viewPoint: CGPoint) {
        guard let transform else { return }
        let raw = transform.imagePoint(fromView: PhotoPoint(viewPoint.x, viewPoint.y))
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
            hint = Self.describe(error)
        }
    }

    /// Clears reference and calibration but keeps the image, starting a new
    /// calibration cycle. Measurements are discarded because their scale is
    /// no longer valid.
    public func recalibrate() {
        store.reset()
    }

    public func undo() { store.undo() }
    public func clearMeasurements() { store.clearVertices() }

    // MARK: - Export

    /// Renders the image with the calibration reference, measurement lines,
    /// handles and value labels into a PNG capped at
    /// `exportMaximumDimension` on the long edge, then hands it to the host
    /// through the export callback. Throws nothing: failures surface as
    /// `lastExportError`.
    public func exportAnnotatedPNG() {
        lastExportError = nil
        guard canExport, let image, let calibration = store.calibration else { return }
        do {
            let data = try Self.renderAnnotatedPNG(image: image, pixels: imagePixels,
                                                   reference: calibration, store: store,
                                                   mode: mode, unit: unit)
            exportImage(data)
        } catch {
            lastExportError = Self.describe(error)
        }
    }

    static func renderAnnotatedPNG(image: CGImage, pixels: PhotoPoint, reference: PhotoCalibration,
                                   store: PhotoMeasureStore, mode: PhotoMeasureMode,
                                   unit: PhotoUnit) throws -> Data {
        let longEdge = max(pixels.x, pixels.y)
        let exportScale = longEdge > Double(exportMaximumDimension)
            ? Double(exportMaximumDimension) / longEdge
            : 1
        let primitives = annotationPrimitives(reference: reference, store: store, mode: mode, unit: unit)
        let content = PhotoMeasureExportContent(image: image, pixels: pixels,
                                                primitives: primitives, outputScale: exportScale)
        let renderer = ImageRenderer(content: content)
        renderer.scale = exportScale
        renderer.isOpaque = true
        guard let rendered = renderer.cgImage else { throw ToolboxError.invalid("export render") }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, UTType.png.identifier as CFString, 1, nil) else {
            throw ToolboxError.invalid("PNG encoder")
        }
        CGImageDestinationAddImage(destination, rendered, nil)
        guard CGImageDestinationFinalize(destination) else { throw ToolboxError.invalid("PNG encoder") }
        let data = output as Data
        guard data.count <= maximumExportBytes else { throw ToolboxError.limit("export size") }
        return data
    }

    // MARK: - Annotation layout

    /// Annotation primitives for the on-screen overlay: the full measurement
    /// layout once calibrated, otherwise just the reference segment/markers
    /// collected so far. Internal: the primitive types are module-private and
    /// the overlay consumes them in the workbench view.
    var screenPrimitives: [PhotoAnnotationPrimitive] {
        if let calibration = store.calibration {
            return Self.annotationPrimitives(reference: calibration, store: store, mode: mode, unit: unit)
        }
        var primitives: [PhotoAnnotationPrimitive] = []
        let references = store.referencePoints.map(\.position)
        if references.count == 2 {
            primitives.append(.segment(references[0], references[1], .reference))
        }
        for point in references { primitives.append(.marker(point, .reference)) }
        return primitives
    }

    /// Builds the drawable annotation list in image pixel coordinates. Used
    /// verbatim by the export renderer; the on-screen overlay maps the same
    /// primitives through the current view transform.
    static func annotationPrimitives(reference: PhotoCalibration, store: PhotoMeasureStore,
                                     mode: PhotoMeasureMode, unit: PhotoUnit) -> [PhotoAnnotationPrimitive] {
        var primitives: [PhotoAnnotationPrimitive] = []
        primitives.append(.segment(reference.start, reference.end, .reference))
        primitives.append(.marker(reference.start, .reference))
        primitives.append(.marker(reference.end, .reference))
        primitives.append(.label(midpoint(reference.start, reference.end), unit.format(reference.lengthMeters), .reference))

        let vertices = store.vertices.map(\.position)
        guard !vertices.isEmpty else { return primitives }
        switch mode {
        case .length:
            if vertices.count == 1 {
                primitives.append(.marker(vertices[0], .measure))
            } else {
                for index in 1..<vertices.count {
                    let start = vertices[index - 1], end = vertices[index]
                    primitives.append(.segment(start, end, .measure))
                    if let calibration = store.calibration,
                       let length = PhotoMeasurementMath.physicalLength(
                           pixels: PhotoMeasurementMath.distance(start, end) ?? 0, calibration: calibration) {
                        primitives.append(.label(midpoint(start, end), unit.format(length), .measure))
                    }
                }
                for point in vertices { primitives.append(.marker(point, .measure)) }
            }
        case .area:
            for index in 0..<vertices.count {
                primitives.append(.segment(vertices[index], vertices[(index + 1) % vertices.count], .measure))
            }
            for point in vertices { primitives.append(.marker(point, .measure)) }
            if vertices.count >= 3, let calibration = store.calibration,
               let squarePixels = try? PhotoMeasurementMath.polygonArea(vertices),
               let area = PhotoMeasurementMath.physicalArea(squarePixels: squarePixels, calibration: calibration) {
                primitives.append(.label(centroid(vertices), unit.areaFormat(area), .measure))
            }
        case .angle:
            var index = 0
            while index + 2 <= vertices.count - 1 {
                let vertex = vertices[index + 1]
                primitives.append(.segment(vertices[index], vertex, .measure))
                primitives.append(.segment(vertex, vertices[index + 2], .measure))
                if let value = PhotoMeasurementMath.angle(vertex: vertex,
                                                          first: vertices[index], second: vertices[index + 2]) {
                    primitives.append(.label(vertex, String(format: "%.1f°", value), .measure))
                }
                index += 3
            }
            for point in vertices { primitives.append(.marker(point, .measure)) }
        }
        return primitives
    }

    private static func midpoint(_ a: PhotoPoint, _ b: PhotoPoint) -> PhotoPoint {
        PhotoPoint((a.x + b.x) / 2, (a.y + b.y) / 2)
    }

    private static func centroid(_ points: [PhotoPoint]) -> PhotoPoint {
        guard !points.isEmpty else { return .zero }
        let sum = points.reduce(PhotoPoint.zero) { PhotoPoint($0.x + $1.x, $0.y + $1.y) }
        return PhotoPoint(sum.x / Double(points.count), sum.y / Double(points.count))
    }

    // MARK: - Errors

    static func describe(_ error: Error) -> String {
        let zh: String
        let en: String
        if let toolboxError = error as? ToolboxError {
            switch toolboxError {
            case .limit(let subject):
                zh = "“\(subject)”超出大小上限，无法处理。"; en = "The \(subject) exceeds the size limit and cannot be processed."
            case .invalid(let subject):
                zh = "“\(subject)”无效或已损坏。"; en = "The \(subject) is invalid or corrupted."
            case .unsupported(let subject):
                zh = "不支持“\(subject)”。"; en = "The \(subject) is not supported."
            default:
                zh = "操作未完成，请重试。"; en = "The operation did not finish. Try again."
            }
        } else if let photoError = error as? PhotoMeasurementError {
            switch photoError {
            case .nonFinite: zh = "输入包含无效数值。"; en = "The input contains an invalid value."
            case .invalidLength: zh = "参照长度必须大于零。"; en = "The reference length must be greater than zero."
            case .zeroDistance: zh = "两个参照点之间的距离太短，无法确定比例。"; en = "The two reference points are too close to establish a scale."
            case .insufficientPoints: zh = "参照点不足。"; en = "There are not enough reference points."
            case .tooManyPoints: zh = "测量点数量已达上限。"; en = "The measurement point limit was reached."
            default: zh = "无法完成测量。"; en = "The measurement could not be completed."
            }
        } else {
            zh = "操作未完成，请重试。"; en = "The operation did not finish. Try again."
        }
        return workbenchText(zh, en, .current)
    }
}
