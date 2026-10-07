// FloeWorkbench — Non-destructive image renderer.
//
// The source pixels are never modified: layers and adjustments compose into a
// fresh bitmap only on preview/export. Decoding uses ImageIO with explicit
// thumbnail sizing and EXIF-orientation application so a 100 MP source never
// forces a full decode for an on-screen preview; the full-resolution path is
// reserved for export and guarded by `MediaResourceGuard`.

import Foundation
import FloeCore
#if canImport(CoreImage)
import CoreImage
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import CoreText
#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif
#endif

public enum WorkbenchImageError: Error, Sendable {
    case decodeFailed(String)
    case unsupportedSource(String)
    case encodeFailed(String)
    case verificationFailed
    case resourceGuardOfferScaled(maxEdge: Int)
}

public struct WorkbenchImageProbe: Sendable, Hashable {
    public var pixelWidth: Int
    public var pixelHeight: Int
    public var hasAlpha: Bool
    public var orientationDegrees: Int
    public var byteCount: Int64
}

#if canImport(CoreImage)
public actor WorkbenchImageRenderer {
    public struct Limits: Sendable {
        public var maximumExportEdge: Int
        public var maximumExportPixels: Int
        public init(maximumExportEdge: Int = 16_384, maximumExportPixels: Int = 64_000_000) {
            self.maximumExportEdge = maximumExportEdge
            self.maximumExportPixels = maximumExportPixels
        }
    }

    private let context: CIContext
    private let limits: Limits

    public init(context: CIContext? = nil, limits: Limits = Limits()) {
        self.context = context ?? CIContext()
        self.limits = limits
    }

    // MARK: Probe / decode

    public func probe(url: URL) throws -> WorkbenchImageProbe {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else {
            throw WorkbenchImageError.decodeFailed("could not open image")
        }
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] ?? [:]
        let width = properties[kCGImagePropertyPixelWidth] as? Int ?? 0
        let height = properties[kCGImagePropertyPixelHeight] as? Int ?? 0
        let orientationRaw = properties[kCGImagePropertyOrientation] as? UInt32 ?? 1
        let hasAlpha = (properties[kCGImagePropertyHasAlpha] as? Bool) ?? false
        let bytes = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64) ?? nil
        guard width > 0, height > 0 else { throw WorkbenchImageError.unsupportedSource("unreadable dimensions") }
        return WorkbenchImageProbe(pixelWidth: width, pixelHeight: height, hasAlpha: hasAlpha,
                                   orientationDegrees: Self.degrees(for: CGImagePropertyOrientation(rawValue: orientationRaw) ?? .up),
                                   byteCount: bytes ?? 0)
    }

    /// Decodes with EXIF orientation baked in. `maxEdge` down-samples for
    /// preview; nil requests full resolution (only on the export path).
    public func loadImage(url: URL, maxEdge: Int? = nil) throws -> CIImage {
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true, // applies EXIF orientation
            kCGImageSourceShouldCacheImmediately: true
        ]
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else {
            throw WorkbenchImageError.decodeFailed("could not open image")
        }
        var cgImage: CGImage?
        if let maxEdge, maxEdge > 0 {
            var thumbOptions = options
            thumbOptions[kCGImageSourceThumbnailMaxPixelSize] = maxEdge
            cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbOptions as CFDictionary)
        } else {
            cgImage = CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceCreateThumbnailWithTransform: true] as CFDictionary)
        }
        guard let cgImage else { throw WorkbenchImageError.decodeFailed("decode returned no image") }
        var image = CIImage(cgImage: cgImage)
        // CGImageSourceCreateImageAtIndex does not apply orientation itself;
        // read and apply it explicitly on the full-resolution path.
        if maxEdge == nil,
           let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
           let raw = properties[kCGImagePropertyOrientation] as? UInt32,
           let orientation = CGImagePropertyOrientation(rawValue: raw), orientation != .up {
            image = image.oriented(forExifOrientation: Int32(raw))
        }
        return image
    }

    // MARK: Composition

    /// Renders the flattened project to a `CGImage`. Asset URLs are resolved
    /// by `resolveAsset`, which keeps workspace containment policy at the
    /// app/tool layer rather than in the renderer.
    public func render(
        project: MediaProject,
        canvas: CGSize,
        resolveAsset: @Sendable (UUID) -> URL?,
        previewMaxEdge: Int? = nil
    ) throws -> CGImage {
        guard project.kind == .image else {
            throw WorkbenchImageError.unsupportedSource("not an image project")
        }
        let extent = CGRect(origin: .zero, size: canvas)
        var composited = CIImage(color: CIColor(red: 0, green: 0, blue: 0, alpha: 0)).cropped(to: extent)
        // Layers are stored bottom-first; render in that order.
        for layer in project.imageLayers where !layer.isHidden {
            if let renderedLayer = try renderLayer(layer, canvas: canvas, resolveAsset: resolveAsset,
                                                  previewMaxEdge: previewMaxEdge) {
                composited = renderedLayer.composited(over: composited)
            }
        }
        let composited2 = try applyAdjustment(project.canvasAdjustment, to: composited)
        guard let output = context.createCGImage(composited2, from: extent) else {
            throw WorkbenchImageError.encodeFailed("Core Image could not flatten the project")
        }
        return output
    }

    private func renderLayer(
        _ layer: ImageLayer,
        canvas: CGSize,
        resolveAsset: @Sendable (UUID) -> URL?,
        previewMaxEdge: Int?
    ) throws -> CIImage? {
        var image: CIImage
        switch layer.kind {
        case .image:
            guard let assetID = layer.assetID, let url = resolveAsset(assetID) else { return nil }
            image = try loadImage(url: url, maxEdge: previewMaxEdge)
            // Non-destructive crop first (normalized to the displayed frame).
            if let crop = layer.crop {
                let extent = image.extent
                image = image.cropped(to: CGRect(x: extent.minX + crop.x * extent.width,
                                                 y: extent.minY + crop.y * extent.height,
                                                 width: crop.width * extent.width,
                                                 height: crop.height * extent.height))
            }
            // Normalize origin, then aspect-fit the source into the canvas as
            // the layer's natural placement. User transform happens in place().
            let extent = image.extent
            let fitted = fit(extent.size, into: canvas)
            let normalized = image.transformed(by: CGAffineTransform(translationX: -extent.origin.x, y: -extent.origin.y))
            image = normalized.transformed(by: CGAffineTransform(scaleX: fitted.width / extent.width,
                                                                 y: fitted.height / extent.height))
        case .text:
            guard let text = layer.text else { return nil }
            image = try makeTextLayer(text, canvas: canvas)
        case .freehand:
            guard let freehand = layer.freehand else { return nil }
            image = try makeFreehandLayer(freehand, canvas: canvas)
        case .fill:
            image = try makeFillLayer(colorHex: layer.fillColorHex ?? "#FFFFFF", canvas: canvas)
        }
        image = try applyAdjustment(layer.adjustment, to: image)
        // Selection limits the layer's effect; the mask is a second,
        // non-destructive dimension. Both multiply into the alpha channel and
        // are applied before placement.
        if let selection = layer.selectionMask, !selection.isEmpty {
            image = try applySelection(selection, to: image, canvas: canvas)
        }
        if let mask = layer.mask, !mask.strokes.isEmpty {
            image = try applyMask(mask, to: image, canvas: canvas)
        }
        image = try place(image: image, layer: layer, canvas: canvas)
        return image
    }

    private func makeFillLayer(colorHex: String, canvas: CGSize) throws -> CIImage {
        let color = UIColorLike.ciColor(colorHex)
        return CIImage(color: color).cropped(to: CGRect(origin: .zero, size: canvas))
    }

    private func place(image: CIImage, layer: ImageLayer, canvas: CGSize) throws -> CIImage {
        // image at this point has origin .zero and its natural fitted size.
        let extent = image.extent
        let naturalWidth = extent.width
        let naturalHeight = extent.height
        // Final on-canvas center. Unit Y is top-leading; CI is bottom-leading.
        let center = CGPoint(x: layer.transform.centerX * canvas.width,
                             y: (1 - layer.transform.centerY) * canvas.height)
        let scale = layer.transform.scale
        let radians = -layer.transform.rotationDegrees * .pi / 180
        // Build transform for a point in the image: scale around its center,
        // rotate around the same center, then move it to the target center.
        var t = CGAffineTransform(translationX: center.x, y: center.y)
        if radians != 0 { t = t.rotated(by: radians) }
        if layer.transform.flipX == true || layer.transform.flipY == true {
            t = t.scaledBy(x: layer.transform.flipX == true ? -1 : 1,
                           y: layer.transform.flipY == true ? -1 : 1)
        }
        t = t.scaledBy(x: scale, y: scale)
        t = t.translatedBy(x: -naturalWidth / 2, y: -naturalHeight / 2)
        var placed = image.transformed(by: t)
        if layer.opacity < 1 {
            let alpha = CIFilter(name: "CIColorMatrix")!
            alpha.setValue(placed, forKey: kCIInputImageKey)
            alpha.setValue(CIVector(x: 0, y: 0, z: 0, w: CGFloat(layer.opacity)), forKey: "inputAVector")
            placed = alpha.outputImage ?? placed
        }
        return placed
    }

    private func applyAdjustment(_ adjustment: ImageLayerAdjustment, to input: CIImage) throws -> CIImage {
        guard !adjustment.isIdentity else { return input }
        var output = input
        if let temperature = adjustment.temperature, temperature.isFinite {
            let filter = CIFilter(name: "CITemperatureAndTint")!
            filter.setValue(output, forKey: kCIInputImageKey)
            filter.setValue(CIVector(x: CGFloat(max(1000, min(temperature, 40_000))), y: 0), forKey: "inputNeutral")
            filter.setValue(CIVector(x: 6500, y: 0), forKey: "inputTargetNeutral")
            output = filter.outputImage ?? output
        }
        if let hue = adjustment.hueDegrees, hue.isFinite, hue != 0 {
            let filter = CIFilter(name: "CIHueAdjust")!
            filter.setValue(output, forKey: kCIInputImageKey)
            filter.setValue(CGFloat(hue * .pi / 180), forKey: kCIInputAngleKey)
            output = filter.outputImage ?? output
        }
        if let levels = adjustment.levels {
            let black = max(0, min(levels.black, 0.99))
            let white = max(black + 0.01, min(levels.white, 1))
            let span = white - black
            let matrix = CIFilter(name: "CIColorMatrix")!
            matrix.setValue(output, forKey: kCIInputImageKey)
            matrix.setValue(CIVector(x: 1 / span, y: 0, z: 0, w: 0), forKey: "inputRVector")
            matrix.setValue(CIVector(x: 0, y: 1 / span, z: 0, w: 0), forKey: "inputGVector")
            matrix.setValue(CIVector(x: 0, y: 0, z: 1 / span, w: 0), forKey: "inputBVector")
            matrix.setValue(CIVector(x: CGFloat(-black / span), y: CGFloat(-black / span), z: CGFloat(-black / span), w: 0),
                            forKey: "inputBiasVector")
            output = matrix.outputImage ?? output
            if levels.gamma.isFinite, levels.gamma > 0, abs(levels.gamma - 1) > 0.001 {
                let gamma = CIFilter(name: "CIGammaAdjust")!
                gamma.setValue(output, forKey: kCIInputImageKey)
                gamma.setValue(CGFloat(1 / max(0.01, min(levels.gamma, 10))), forKey: "inputPower")
                output = gamma.outputImage ?? output
            }
        }
        if let saturation = adjustment.saturation
            ?? (adjustment.contrast != nil || adjustment.brightness != nil ? 1 : nil) {
            let filter = CIFilter(name: "CIColorControls")!
            filter.setValue(output, forKey: kCIInputImageKey)
            filter.setValue(saturation, forKey: "inputSaturation")
            filter.setValue(adjustment.contrast ?? 1, forKey: "inputContrast")
            filter.setValue(adjustment.brightness ?? 0, forKey: "inputBrightness")
            output = filter.outputImage ?? output
        }
        if let ev = adjustment.exposureEV {
            let filter = CIFilter(name: "CIExposureAdjust")!
            filter.setValue(output, forKey: kCIInputImageKey)
            filter.setValue(ev, forKey: "inputEV")
            output = filter.outputImage ?? output
        }
        if let radius = adjustment.blurRadius, radius > 0 {
            let filter = CIFilter(name: "CIGaussianBlur")!
            filter.setValue(output, forKey: kCIInputImageKey)
            filter.setValue(radius, forKey: "inputRadius")
            output = (filter.outputImage ?? output).cropped(to: input.extent)
        }
        if let radius = adjustment.sharpenRadius, radius > 0 {
            let filter = CIFilter(name: "CISharpenLuminance")!
            filter.setValue(output, forKey: kCIInputImageKey)
            filter.setValue(radius / 100, forKey: "inputSharpness")
            output = filter.outputImage ?? output
        }
        if let block = adjustment.mosaicBlockSize, block > 0 {
            output = try pixellate(output, blockSize: block)
        }
        if let filterID = adjustment.filterID, let applied = try builtInFilter(named: filterID, image: output) {
            output = applied
        }
        return output
    }

    /// Deterministic built-in filter set (no auto-downloaded assets).
    public static let supportedFilterIDs: [String] = [
        "CIPhotoEffectMono", "CIPhotoEffectNoir", "CIPhotoEffectChrome",
        "CIPhotoEffectFade", "CIPhotoEffectInstant", "CISepiaTone"
    ]

    private func builtInFilter(named name: String, image: CIImage) throws -> CIImage? {
        guard Self.supportedFilterIDs.contains(name), let filter = CIFilter(name: name) else { return nil }
        filter.setValue(image, forKey: kCIInputImageKey)
        return filter.outputImage
    }

    private func pixellate(_ image: CIImage, blockSize: Int) throws -> CIImage {
        let filter = CIFilter(name: "CIPixellate")!
        filter.setValue(image, forKey: kCIInputImageKey)
        filter.setValue(CGFloat(max(2, min(blockSize, 512))), forKey: "inputScale")
        guard let output = filter.outputImage else { return image }
        return output.cropped(to: image.extent)
    }

    private func makeTextLayer(_ content: ImageTextContent, canvas: CGSize) throws -> CIImage {
        let fontSize = max(8, min(content.fontSize, canvas.height * 0.5))
        let font = CTFontCreateWithName((content.fontName ?? "Helvetica") as CFString, fontSize, nil)
        let color = UIColorLike.ciColor(content.colorHex)
        var attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            // `.foregroundColor` expects a platform color; the previous
            // CIColor value was silently ignored by Core Text, so every text
            // layer rendered black regardless of its colorHex.
            .foregroundColor: UIColorLike.platformColor(content.colorHex)
        ]
        if let tracking = content.tracking, tracking.isFinite {
            attributes[.kern] = CGFloat(max(-fontSize, min(tracking, fontSize * 2)))
        }
        let paragraph = NSMutableParagraphStyle()
        if let leading = content.leading, leading.isFinite {
            paragraph.lineSpacing = CGFloat(max(0, min(leading, fontSize * 2)))
        }
        switch content.alignment ?? .left {
        case .left: paragraph.alignment = .left
        case .center: paragraph.alignment = .center
        case .right: paragraph.alignment = .right
        }
        attributes[.paragraphStyle] = paragraph
        if let strokeHex = content.strokeColorHex, let strokeWidth = content.strokeWidth, strokeWidth > 0 {
            attributes[.strokeColor] = UIColorLike.platformColor(strokeHex)
            attributes[.strokeWidth] = -min(strokeWidth, fontSize)
        }
        if let shadow = content.shadow {
            let nsShadow = NSShadow()
            nsShadow.shadowColor = UIColorLike.platformColor(shadow.colorHex)
            nsShadow.shadowBlurRadius = CGFloat(max(0, min(shadow.blur, fontSize)))
            nsShadow.shadowOffset = CGSize(width: shadow.offsetX, height: shadow.offsetY)
            attributes[.shadow] = nsShadow
        }
        let attributed = NSAttributedString(string: content.text, attributes: attributes)
        let framesetter = CTFramesetterCreateWithAttributedString(attributed)
        let maxSize = CGSize(width: canvas.width * 0.9, height: canvas.height * 0.9)
        let textSize = CTFramesetterSuggestFrameSizeWithConstraints(framesetter, CFRange(), nil, maxSize, nil)
        let renderer = CGImageRenderer(size: textSize, opaque: false)
        let cg = try renderer.image { ctx in
            ctx.textPosition = .zero
            let path = CGPath(rect: CGRect(origin: .zero, size: textSize), transform: nil)
            let frame = CTFramesetterCreateFrame(framesetter, CFRange(), path, nil)
            CTFrameDraw(frame, ctx)
        }
        return CIImage(cgImage: cg)
    }

    private func makeFreehandLayer(_ content: ImageFreehandContent, canvas: CGSize) throws -> CIImage {
        var output = CIImage(color: CIColor(red: 0, green: 0, blue: 0, alpha: 0))
            .cropped(to: CGRect(origin: .zero, size: canvas))
        for stroke in content.strokes {
            let pressures = stroke.points.compactMap(\.pressure)
            let pressureScale: Double = pressures.isEmpty
                ? 1
                : max(0.15, min(pressures.reduce(0, +) / Double(pressures.count), 1))
            let width = max(1, stroke.width * pressureScale)
            let opacity = max(0.02, min(stroke.opacity ?? 1, 1))
            let renderer = CGImageRenderer(size: canvas, opaque: false)
            let cg = try renderer.image { ctx in
                let path = CGMutablePath()
                for (index, point) in stroke.points.enumerated() {
                    let p = CGPoint(x: point.x * canvas.width, y: (1 - point.y) * canvas.height)
                    if index == 0 { path.move(to: p) } else { path.addLine(to: p) }
                }
                ctx.addPath(path)
                ctx.setLineWidth(width)
                ctx.setLineCap(.round)
                ctx.setLineJoin(.round)
                ctx.setStrokeColor(UIColorLike.cgColor(stroke.colorHex))
                ctx.setAlpha(CGFloat(opacity))
                ctx.strokePath()
            }
            var strokeImage = CIImage(cgImage: cg)
            let hardness = max(0, min(stroke.hardness ?? 0, 1))
            if hardness > 0.001 {
                let blur = CIFilter(name: "CIGaussianBlur")!
                blur.setValue(strokeImage, forKey: kCIInputImageKey)
                blur.setValue(CGFloat(hardness * max(1, width) * 0.6), forKey: kCIInputRadiusKey)
                strokeImage = (blur.outputImage ?? strokeImage).cropped(to: strokeImage.extent)
            }
            output = strokeImage.composited(over: output)
        }
        return output
    }

    /// Rasterizes a vector selection to an alpha mask and multiplies it into
    /// the layer's alpha, so selection-scoped effects never touch pixels
    /// outside the selection. Feather is applied in normalized space, keeping
    /// the soft edge proportional when the canvas is scaled.
    func applySelection(_ selection: ImageSelection, to input: CIImage, canvas: CGSize) throws -> CIImage {
        guard let mask = ImageSelectionRasterizer.maskImage(for: selection, canvas: canvas) else { return input }
        return try blend(input, withAlphaMask: mask)
    }

    /// Applies erase/restore mask strokes in order: erase hides pixels, a later
    /// restore reveals them again; the original pixels are never modified.
    func applyMask(_ mask: ImageLayerMask, to input: CIImage, canvas: CGSize) throws -> CIImage {
        var maskImage = CIImage(color: CIColor(red: 1, green: 1, blue: 1, alpha: 1))
            .cropped(to: CGRect(origin: .zero, size: canvas))
        for stroke in mask.strokes {
            let renderer = CGImageRenderer(size: canvas, opaque: false)
            let cg = try renderer.image { ctx in
                let path = CGMutablePath()
                for (index, point) in stroke.points.enumerated() {
                    let p = CGPoint(x: point.x * canvas.width, y: (1 - point.y) * canvas.height)
                    if index == 0 { path.move(to: p) } else { path.addLine(to: p) }
                }
                ctx.addPath(path)
                ctx.setLineWidth(max(1, stroke.width))
                ctx.setLineCap(.round)
                ctx.setLineJoin(.round)
                let value: CGFloat = stroke.restore ? 1 : 0
                ctx.setStrokeColor(CGColor(red: value, green: value, blue: value, alpha: 1))
                ctx.strokePath()
            }
            var strokeImage = CIImage(cgImage: cg)
            let hardness = max(0, min(stroke.hardness ?? 0, 1))
            if hardness > 0.001 {
                let blur = CIFilter(name: "CIGaussianBlur")!
                blur.setValue(strokeImage, forKey: kCIInputImageKey)
                blur.setValue(CGFloat(hardness * max(1, stroke.width) * 0.6), forKey: kCIInputRadiusKey)
                strokeImage = (blur.outputImage ?? strokeImage).cropped(to: strokeImage.extent)
            }
            maskImage = strokeImage.composited(over: maskImage)
        }
        return try blend(input, withAlphaMask: maskImage)
    }

    private func blend(_ input: CIImage, withAlphaMask mask: CIImage) throws -> CIImage {
        let blend = CIFilter(name: "CIBlendWithMask")!
        blend.setValue(input, forKey: kCIInputImageKey)
        blend.setValue(CIImage(color: CIColor(red: 0, green: 0, blue: 0, alpha: 0)).cropped(to: input.extent),
                       forKey: kCIInputBackgroundImageKey)
        blend.setValue(mask, forKey: kCIInputMaskImageKey)
        return (blend.outputImage ?? input).cropped(to: input.extent)
    }

    private func fit(_ source: CGSize, into target: CGSize) -> CGSize {
        let scale = min(target.width / source.width, target.height / source.height)
        return CGSize(width: source.width * scale, height: source.height * scale)
    }

    // MARK: Export

    /// Full-resolution guarded export. Writes to a staging file, re-reads and
    /// verifies dimensions/type, then atomically replaces the destination.
    @discardableResult
    public func exportImage(
        project: MediaProject,
        options: ImageExportOptions,
        resolveAsset: @Sendable (UUID) -> URL?,
        destination: URL
    ) throws -> WorkbenchImageExportReceipt {
        guard let canvas = project.canvas else {
            throw WorkbenchImageError.unsupportedSource("project canvas is not initialized")
        }
        let sourceHasAlpha = project.imageLayers.contains { layer in
            guard let assetID = layer.assetID, let url = resolveAsset(assetID),
                  let probe = try? probe(url: url) else { return true }
            return probe.hasAlpha
        }
        try MediaExportValidationCore.validateImage(options: options, canvasWidth: canvas.width,
                                                    canvasHeight: canvas.height, hasTransparency: sourceHasAlpha)
        let targetWidth = options.width ?? canvas.width
        let targetHeight = options.height ?? canvas.height
        guard targetWidth <= limits.maximumExportEdge, targetHeight <= limits.maximumExportEdge,
              targetWidth * targetHeight <= limits.maximumExportPixels else {
            throw WorkbenchImageError.encodeFailed("export dimensions exceed guard limits")
        }
        let full = try render(project: project, canvas: CGSize(width: canvas.width, height: canvas.height),
                              resolveAsset: resolveAsset, previewMaxEdge: nil)
        // Resample to explicit export dimensions when requested.
        let resized: CGImage
        if targetWidth != full.width || targetHeight != full.height {
            guard let bitmap = CGContext(data: nil, width: targetWidth, height: targetHeight,
                                         bitsPerComponent: 8, bytesPerRow: 0,
                                         space: CGColorSpaceCreateDeviceRGB(),
                                         bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
                  let resizedImage = bitmap.makeImage() else {
                throw WorkbenchImageError.encodeFailed("resize context unavailable")
            }
            bitmap.interpolationQuality = .high
            bitmap.draw(full, in: CGRect(x: 0, y: 0, width: targetWidth, height: targetHeight))
            resized = resizedImage
        } else {
            resized = full
        }
        let data = try encode(resized, options: options)
        try verify(data: data, expectedUTType: options.format.utType,
                   expectedWidth: targetWidth, expectedHeight: targetHeight)
        let directory = destination.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let staging = directory.appendingPathComponent(".floe-image-export-\(UUID().uuidString).\(options.format.fileExtension)")
        try data.write(to: staging, options: .atomic)
        if FileManager.default.fileExists(atPath: destination.path) {
            _ = try FileManager.default.replaceItemAt(destination, withItemAt: staging)
        } else {
            try FileManager.default.moveItem(at: staging, to: destination)
        }
        return WorkbenchImageExportReceipt(url: destination, width: targetWidth, height: targetHeight,
                                           format: options.format.rawValue, byteCount: Int64(data.count))
    }

    private func encode(_ image: CGImage, options: ImageExportOptions) throws -> Data {
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, options.format.utType.identifier as CFString, 1, nil) else {
            throw WorkbenchImageError.encodeFailed("no encoder for \(options.format)")
        }
        var encodeOptions: [CFString: Any] = [:]
        if options.format != .png {
            encodeOptions[kCGImageDestinationLossyCompressionQuality] = options.quality
        }
        if options.format == .jpeg && !options.preserveTransparency {
            // Explicit flatten for JPEG when the user opted out of transparency.
            let flattened = try flattenOverWhite(image)
            CGImageDestinationAddImage(destination, flattened, encodeOptions as CFDictionary)
        } else {
            CGImageDestinationAddImage(destination, image, encodeOptions as CFDictionary)
        }
        guard CGImageDestinationFinalize(destination) else {
            throw WorkbenchImageError.encodeFailed("encoder finalize failed")
        }
        return output as Data
    }

    private func flattenOverWhite(_ image: CGImage) throws -> CGImage {
        guard let ctx = CGContext(data: nil, width: image.width, height: image.height,
                                  bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else {
            throw WorkbenchImageError.encodeFailed("flatten context unavailable")
        }
        ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: image.width, height: image.height))
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        guard let flattened = ctx.makeImage() else { throw WorkbenchImageError.encodeFailed("flatten failed") }
        return flattened
    }

    private func verify(data: Data, expectedUTType: UTType, expectedWidth: Int, expectedHeight: Int) throws {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetCount(source) > 0,
              let cg = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw WorkbenchImageError.verificationFailed
        }
        guard cg.width == expectedWidth, cg.height == expectedHeight else {
            throw WorkbenchImageError.verificationFailed
        }
        let uttype = CGImageSourceGetType(source).flatMap { UTType($0 as String) }
        guard uttype?.conforms(to: expectedUTType) == true || uttype?.identifier == expectedUTType.identifier else {
            throw WorkbenchImageError.verificationFailed
        }
    }

    private static func degrees(for orientation: CGImagePropertyOrientation) -> Int {
        switch orientation {
        case .up, .upMirrored: 0
        case .right, .rightMirrored: 90
        case .down, .downMirrored: 180
        case .left, .leftMirrored: 270
        @unknown default: 0
        }
    }
}

public struct WorkbenchImageExportReceipt: Sendable, Hashable {
    public var url: URL
    public var width: Int
    public var height: Int
    public var format: String
    public var byteCount: Int64
}

private enum UIColorLike {
    static func ciColor(_ hex: String) -> CIColor {
        let rgba = parse(hex)
        return CIColor(red: CGFloat(rgba.r), green: CGFloat(rgba.g), blue: CGFloat(rgba.b), alpha: CGFloat(rgba.a))
    }
    static func cgColor(_ hex: String) -> CGColor {
        let rgba = parse(hex)
        return CGColor(red: CGFloat(rgba.r), green: CGFloat(rgba.g), blue: CGFloat(rgba.b), alpha: CGFloat(rgba.a))
    }
#if canImport(UIKit)
    static func platformColor(_ hex: String) -> UIColor { UIColor(cgColor: cgColor(hex)) }
#else
    static func platformColor(_ hex: String) -> NSColor { NSColor(cgColor: cgColor(hex)) ?? .black }
#endif
    static func parse(_ hex: String) -> (r: Double, g: Double, b: Double, a: Double) {
        var value = hex
        if value.hasPrefix("#") { value.removeFirst() }
        guard let int = UInt32(value, radix: 16) else { return (0, 0, 0, 1) }
        let r = Double((int >> 16) & 0xFF) / 255
        let g = Double((int >> 8) & 0xFF) / 255
        let b = Double(int & 0xFF) / 255
        return (r, g, b, 1)
    }
}

/// Thin wrapper that returns a CGImage from a Core Graphics drawing block.
private struct CGImageRenderer {
    let size: CGSize
    let opaque: Bool

    func image(_ actions: (CGContext) throws -> Void) throws -> CGImage {
        guard let ctx = CGContext(data: nil, width: max(1, Int(size.width.rounded(.up))),
                                  height: max(1, Int(size.height.rounded(.up))),
                                  bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw WorkbenchImageError.encodeFailed("graphics context unavailable")
        }
        try actions(ctx)
        guard let image = ctx.makeImage() else { throw WorkbenchImageError.encodeFailed("drawing produced no image") }
        return image
    }
}
extension ImageExportFormat {
    var utType: UTType {
        switch self {
        case .png: .png
        case .jpeg: .jpeg
        case .heic: .heic
        }
    }
}
#endif

// MARK: - Cross-platform export validation bridge

enum MediaExportValidationCore {
    static func validateImage(options: ImageExportOptions, canvasWidth: Int, canvasHeight: Int,
                              hasTransparency: Bool) throws {
        let size = CGSizeLike(width: canvasWidth, height: canvasHeight)
        try MediaExportValidation.validateImage(options, canvasSize: size, hasTransparency: hasTransparency)
    }
}
