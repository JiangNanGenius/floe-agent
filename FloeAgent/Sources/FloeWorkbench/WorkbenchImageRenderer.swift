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
        if let prepared = project.prepared {
            return try renderPrepared(prepared, canvas: canvas, resolveAsset: resolveAsset, previewMaxEdge: previewMaxEdge)
        }
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
        guard let unplaced = try unplacedLayer(layer, canvas: canvas,
                                               resolveAsset: resolveAsset,
                                               previewMaxEdge: previewMaxEdge) else { return nil }
        return try place(image: unplaced, layer: layer, canvas: canvas)
    }

    /// Native v2 composition reads the authoritative typed layers, including
    /// vectors, group transforms, masks and clipping. The frozen v1 projection
    /// is never rendered in place of edited v2 content.
    public func renderPrepared(_ document: MediaPreparedDocument, canvas: CGSize,
                               resolveAsset: @Sendable (UUID) -> URL?, previewMaxEdge: Int? = nil,
                               includeLayerIDs: Set<UUID>? = nil, applyCanvasAdjustment: Bool = true,
                               rasterOverrides: [UUID: CGImage] = [:], outputMaxEdge: Int? = nil) throws -> CGImage {
        try MediaPreparedIntegrity.validate(document)
        guard document.kind == .image, document.unknownOperations.isEmpty,
              canvas.width > 0, canvas.height > 0,
              canvas.width * canvas.height <= Double(limits.maximumExportPixels) else {
            throw WorkbenchImageError.unsupportedSource("unresolved image content or canvas bounds")
        }
        if let outputMaxEdge, !(1...8_192).contains(outputMaxEdge) { throw WorkbenchImageError.unsupportedSource("preview output bound") }
        for (id,image) in rasterOverrides {
            guard let layer = document.layer(id), layer.parentID == nil, !layer.isLocked,
                  layer.contentKind != .group, layer.contentKind != .adjustment,
                  image.width > 0, image.height > 0, image.width <= 8_192, image.height <= 8_192,
                  abs(Double(image.width)/Double(image.height)-Double(canvas.width/canvas.height)) <= 2/Double(image.height) else {
                throw WorkbenchImageError.unsupportedSource("preview override must name a supported layer and the same logical canvas")
            }
        }
        let extent = CGRect(origin: .zero, size: canvas)
        let clear = CIImage(color: .clear).cropped(to: extent)
        var cache: [UUID: CIImage] = [:]
        func coverage(_ mask: MediaPreparedLayerMask,canvas:CGSize) throws -> CIImage {
            let extent=CGRect(origin:.zero,size:canvas)
            var image = CIImage(color: .white).cropped(to: extent)
            if let vector = mask.vector { image = try applySelection(vector, to: image, canvas: canvas) }
            if !mask.strokes.isEmpty { image = try applyMask(.init(strokes: mask.strokes), to: image, canvas: canvas) }
            if mask.isInverted {
                image = image.applyingFilter("CIColorMatrix", parameters: [
                    "inputAVector": CIVector(x: 0, y: 0, z: 0, w: -1),
                    "inputBiasVector": CIVector(x: 0, y: 0, z: 0, w: 1)])
            }
            return image
        }
        func render(_ layer: MediaPreparedLayer,parentCanvas:CGSize) throws -> CIImage {
            let canvas=layer.canvasSpace.map{CGSize(width:$0.referenceCanvas.width,height:$0.referenceCanvas.height)} ?? parentCanvas
            let extent=CGRect(origin:.zero,size:canvas),clear=CIImage(color:.clear).cropped(to:extent)
            if let cached = cache[layer.id] { return cached }
            if !layer.isVisible { return clear }
            if let raster = rasterOverrides[layer.id] {
                // Native override is the already placed full-canvas layer;
                // all per-layer mapping/mask/clip/opacity is already baked.
                // Mapping a reduced raster to this one logical canvas avoids
                // double placement and keeps clip-base alpha in this cache.
                let placed = CIImage(cgImage: raster).transformed(by: .init(scaleX: canvas.width/CGFloat(raster.width),y: canvas.height/CGFloat(raster.height))).cropped(to: extent)
                cache[layer.id] = placed
                return placed
            }
            let sourceAdjustment = layer.adjustment.effectRegion == nil ? layer.adjustment : .init()
            var legacy = ImageLayer(id: layer.id, kind: .fill, name: layer.name,
                transform: layer.transform, opacity: layer.opacity, adjustment: sourceAdjustment)
            var unplaced: CIImage
            switch layer.content {
            case .raster(let raster):
                switch raster.source {
                case .asset(let id):
                    guard resolveAsset(id) != nil else { throw WorkbenchImageError.decodeFailed("missing layer source") }
                    legacy.kind = .image; legacy.assetID = id
                    // Prepared selections/crops use top-leading Y; the legacy
                    // CI raster crop receives a bottom-leading source rectangle.
                    legacy.crop = raster.crop.map { .init(x: $0.x, y: 1 - $0.y - $0.height, width: $0.width, height: $0.height) }
                case .solidColor(let hex): legacy.fillColorHex = hex
                case .empty: return clear
                }
                guard let image = try unplacedLayer(legacy, canvas: canvas, resolveAsset: resolveAsset, previewMaxEdge: previewMaxEdge) else { throw WorkbenchImageError.decodeFailed("empty layer source") }
                unplaced = image
            case .text(let text): unplaced = try applyAdjustment(sourceAdjustment, to: makeTextLayer(text, canvas: canvas))
            case .strokes(let strokes):
                var image = clear
                for stroke in strokes.strokes {
                    try Task.checkCancellation()
                    let cg = try MediaPreparedImageDocumentAdapter.renderStroke(stroke, sourceWidth: Int(canvas.width), sourceHeight: Int(canvas.height))
                    image = CIImage(cgImage: cg).composited(over: image)
                }
                unplaced = try applyAdjustment(sourceAdjustment, to: image)
            case .vectorPaths(let path): unplaced = try applyAdjustment(sourceAdjustment, to: vectorImage(path, canvas: canvas))
            case .group: unplaced = try applyAdjustment(sourceAdjustment, to: compose(parent: layer.id,canvas:canvas))
            case .adjustment: throw WorkbenchImageError.unsupportedSource("adjustment layer cannot be used as clipping base")
            }
            if let mask = layer.mask, mask.isEnabled {
                unplaced = unplaced.applyingFilter("CIBlendWithAlphaMask", parameters: [kCIInputBackgroundImageKey: clear, kCIInputMaskImageKey: try coverage(mask,canvas:canvas)])
            }
            // A group is a stable parent coordinate frame. A child's overflow
            // must not move that frame's pivot as its CI extent grows.
            let groupCenter=layer.contentKind == .group ? CGPoint(x:canvas.width/2,y:canvas.height/2):nil
            var placed = try place(image: unplaced, layer: legacy, canvas: canvas,imageCenter:groupCenter)
            if let space=layer.canvasSpace { placed=placed.transformed(by:space.transform.cgAffineTransform) }
            if layer.adjustment.effectRegion != nil {
                placed = try applyAdjustment(layer.adjustment, to: placed.cropped(to: CGRect(origin: .zero, size: parentCanvas)))
            }
            if let clip = layer.clip, let base = document.layer(clip.baseLayerID) {
                var alpha = try render(base,parentCanvas:parentCanvas)
                if clip.mode == .luminance { alpha = alpha.applyingFilter("CIMaskToAlpha") }
                if clip.isInverted { alpha = alpha.applyingFilter("CIColorMatrix", parameters: ["inputAVector": CIVector(x: 0, y: 0, z: 0, w: -1), "inputBiasVector": CIVector(x: 0, y: 0, z: 0, w: 1)]) }
                placed = placed.applyingFilter("CIBlendWithAlphaMask", parameters: [kCIInputBackgroundImageKey: clear, kCIInputMaskImageKey: alpha])
            }
            cache[layer.id] = placed
            return placed
        }
        func compose(parent: UUID?,canvas:CGSize) throws -> CIImage {
            let extent=CGRect(origin:.zero,size:canvas),clear=CIImage(color:.clear).cropped(to:extent)
            var result = clear
            for layer in document.layers where layer.parentID == parent && layer.isVisible {
                if parent == nil, let includeLayerIDs, !includeLayerIDs.contains(layer.id) { continue }
                try Task.checkCancellation()
                if case .adjustment(let adjustment) = layer.content {
                    let adjusted = try applyAdjustment(adjustment, to: result)
                    var alpha = CIImage(color: CIColor(red: 1, green: 1, blue: 1, alpha: layer.opacity)).cropped(to: extent)
                    if let mask = layer.mask, mask.isEnabled {
                        let reference=layer.canvasSpace.map{CGSize(width:$0.referenceCanvas.width,height:$0.referenceCanvas.height)} ?? canvas
                        alpha=try coverage(mask,canvas:reference)
                        if let space=layer.canvasSpace { alpha=alpha.transformed(by:space.transform.cgAffineTransform) }
                        alpha=alpha.applyingFilter("CIColorMatrix", parameters: ["inputAVector": CIVector(x: 0, y: 0, z: 0, w: layer.opacity)])
                    }
                    result = adjusted.applyingFilter("CIBlendWithAlphaMask", parameters: [kCIInputBackgroundImageKey: result, kCIInputMaskImageKey: alpha])
                } else {
                    let foreground = try render(layer,parentCanvas:canvas)
                    if case .group(let group) = layer.content, let mode = group.blendMode, mode != "normal" {
                        let modes = ["multiply": "CIMultiplyBlendMode", "screen": "CIScreenBlendMode", "overlay": "CIOverlayBlendMode", "darken": "CIDarkenBlendMode", "lighten": "CILightenBlendMode", "difference": "CIDifferenceBlendMode", "exclusion": "CIExclusionBlendMode"]
                        guard let filter = modes[mode] else { throw WorkbenchImageError.unsupportedSource("group blend mode \(mode)") }
                        result = foreground.applyingFilter(filter, parameters: [kCIInputBackgroundImageKey: result])
                    } else { result = foreground.composited(over: result) }
                }
            }
            return result
        }
        let image = try applyAdjustment(applyCanvasAdjustment ? document.canvasAdjustment : .init(), to: compose(parent: nil,canvas:canvas)).cropped(to: extent)
        let output: CIImage
        let outputExtent: CGRect
        if let outputMaxEdge {
            let scale = min(1,CGFloat(outputMaxEdge)/max(canvas.width,canvas.height))
            output = image.transformed(by: .init(scaleX: scale,y: scale)); outputExtent = output.extent
        } else { output = image; outputExtent = extent }
        guard let cg = context.createCGImage(output, from: outputExtent) else { throw WorkbenchImageError.encodeFailed("prepared image composition failed") }
        return cg
    }

    private func vectorImage(_ vector: MediaVectorPath, canvas: CGSize) throws -> CIImage {
        let path=try MediaNativeVectorGeometry.cgPath(vector,canvas:.init(width:Int(canvas.width),height:Int(canvas.height)),maximumAnchors:8_388_608)
        let cg = try CGImageRenderer(size: canvas, opaque: false).image { ctx in
            ctx.setAlpha(vector.opacity)
            if let fill = vector.fillColorHex {
                ctx.addPath(path); ctx.setFillColor(UIColorLike.cgColor(fill)); ctx.drawPath(using: vector.fillRule == .evenOdd ? .eoFill : .fill)
            }
            if let stroke = vector.strokeColorHex, vector.strokeWidth > 0 {
                ctx.addPath(path); ctx.setStrokeColor(UIColorLike.cgColor(stroke)); ctx.setLineWidth(vector.strokeWidth)
                ctx.setLineCap(vector.lineCap == .round ? .round : vector.lineCap == .square ? .square : .butt)
                ctx.setLineJoin(vector.lineJoin == .round ? .round : vector.lineJoin == .bevel ? .bevel : .miter); ctx.strokePath()
            }
        }
        return CIImage(cgImage: cg)
    }

    /// Layer content after adjustments/selection/mask but before placement.
    private func unplacedLayer(
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
        return image
    }

    public func exchangeMask(_ mask: MediaPreparedLayerMask, canvas: CGSize) throws -> CGImage {
        let extent = CGRect(origin: .zero, size: canvas)
        var image = CIImage(color: .white).cropped(to: extent)
        if let vector = mask.vector { image = try applySelection(vector, to: image, canvas: canvas) }
        if !mask.strokes.isEmpty { image = try applyMask(.init(strokes: mask.strokes), to: image, canvas: canvas) }
        let sign: CGFloat = mask.isInverted ? -1 : 1, bias: CGFloat = mask.isInverted ? 1 : 0
        image = image.applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": CIVector(x: 0, y: 0, z: 0, w: sign),
            "inputGVector": CIVector(x: 0, y: 0, z: 0, w: sign),
            "inputBVector": CIVector(x: 0, y: 0, z: 0, w: sign),
            "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 0),
            "inputBiasVector": CIVector(x: bias, y: bias, z: bias, w: 1)])
        guard let output = context.createCGImage(image, from: extent) else { throw WorkbenchImageError.encodeFailed("mask export") }
        return output
    }

    /// Measures the untransformed rendered size of a layer in canvas pixels,
    /// used for rendered-edge alignment. Returns nil if the layer cannot be
    /// resolved (e.g. missing asset); the caller must refuse that alignment.
    public func naturalSize(
        of layer: ImageLayer,
        canvas: CGSize,
        resolveAsset: @Sendable (UUID) -> URL?,
        previewMaxEdge: Int? = nil
    ) throws -> CGSize? {
        guard let unplaced = try unplacedLayer(layer, canvas: canvas,
                                               resolveAsset: resolveAsset,
                                               previewMaxEdge: previewMaxEdge) else { return nil }
        let extent = unplaced.extent
        guard extent.width.isFinite, extent.height.isFinite,
              extent.width > 0, extent.height > 0 else { return nil }
        return CGSize(width: extent.width, height: extent.height)
    }

    /// Composites ONLY the named layers (project stacking order, hidden
    /// skipped) into a transparent full-canvas bitmap, without the
    /// whole-canvas adjustment. The returned pixels are exactly what those
    /// layers contributed, so replacing them with a single identity-placed
    /// image layer is render-preserving (used by layer merge).
    public func renderMerge(
        project: MediaProject,
        layerIDs: Set<UUID>,
        canvas: CGSize,
        resolveAsset: @Sendable (UUID) -> URL?,
        previewMaxEdge: Int? = nil
    ) throws -> CGImage {
        if let document = project.prepared {
            let positions = document.layers.indices.filter { layerIDs.contains(document.layers[$0].id) }
            guard layerIDs.count >= 2, positions.count == layerIDs.count,
                  positions.last! - positions.first! + 1 == positions.count,
                  document.layers.filter({ layerIDs.contains($0.id) }).allSatisfy({ $0.parentID == nil && $0.contentKind != .group && !$0.isLocked }),
                  !document.layers.contains(where: { !layerIDs.contains($0.id) && $0.clip.map { layerIDs.contains($0.baseLayerID) } == true }) else {
                throw WorkbenchImageError.unsupportedSource("select at least two unlocked top-level layers")
            }
            return try renderPrepared(document, canvas: canvas, resolveAsset: resolveAsset, previewMaxEdge: previewMaxEdge,
                includeLayerIDs: layerIDs, applyCanvasAdjustment: false)
        }
        guard project.kind == .image else {
            throw WorkbenchImageError.unsupportedSource("not an image project")
        }
        let extent = CGRect(origin: .zero, size: canvas)
        var composited = CIImage(color: CIColor(red: 0, green: 0, blue: 0, alpha: 0)).cropped(to: extent)
        var contributed = false
        for layer in project.imageLayers where !layer.isHidden && layerIDs.contains(layer.id) {
            if let placed = try renderLayer(layer, canvas: canvas,
                                            resolveAsset: resolveAsset,
                                            previewMaxEdge: previewMaxEdge) {
                composited = placed.composited(over: composited)
                contributed = true
            }
        }
        guard contributed else {
            throw WorkbenchImageError.unsupportedSource("none of the merge layers could be rendered")
        }
        guard let output = context.createCGImage(composited, from: extent) else {
            throw WorkbenchImageError.encodeFailed("Core Image could not render the merge")
        }
        return output
    }

        private func makeFillLayer(colorHex: String, canvas: CGSize) throws -> CIImage {        let color = UIColorLike.ciColor(colorHex)
        return CIImage(color: color).cropped(to: CGRect(origin: .zero, size: canvas))
    }

    private func place(image: CIImage, layer: ImageLayer, canvas: CGSize,imageCenter:CGPoint? = nil) throws -> CIImage {
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
        t = t.translatedBy(x: -(imageCenter?.x ?? naturalWidth / 2), y: -(imageCenter?.y ?? naturalHeight / 2))
        var placed = image.transformed(by: t)
        if layer.opacity < 1 {
            let alpha = CIFilter(name: "CIColorMatrix")!
            alpha.setValue(placed, forKey: kCIInputImageKey)
            alpha.setValue(CIVector(x: 0, y: 0, z: 0, w: CGFloat(layer.opacity)), forKey: "inputAVector")
            placed = alpha.outputImage ?? placed
        }
        return placed
    }

    private func applyAdjustment(_ adjustment:ImageLayerAdjustment,to input:CIImage) throws -> CIImage {
        try MediaNativeColor.apply(adjustment,to:input)
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
        if content.pathLayout != nil {
            let outline=try MediaNativeTextGeometry.outline(content,canvas:.init(width:Int(canvas.width),height:Int(canvas.height)))
            let cg=try CGImageRenderer(size:canvas,opaque:false).image { ctx in
                if let shadow=content.shadow {
                    ctx.setShadow(offset:.init(width:shadow.offsetX,height:shadow.offsetY),blur:max(0,min(shadow.blur,outline.fontSize)),color:UIColorLike.cgColor(shadow.colorHex))
                }
                ctx.addPath(outline.path);ctx.setFillColor(UIColorLike.cgColor(content.colorHex))
                if let stroke=content.strokeColorHex,let width=content.strokeWidth,width>0 {
                    ctx.setStrokeColor(UIColorLike.cgColor(stroke));ctx.setLineWidth(min(width,outline.fontSize)*outline.fontSize/100);ctx.drawPath(using:.fillStroke)
                } else { ctx.fillPath() }
            }
            return CIImage(cgImage:cg)
        }
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
            if stroke.points.contains(where: { $0.pressure != nil }) {
                let samples = stroke.points.map {
                    MediaPreparedBrushSample(x: $0.x, y: $0.y, pressure: $0.pressure,
                                             pressureSource: $0.pressure == nil ? MediaPreparedPressureSource.none : .legacyUnverified)
                }
                let image = try MediaPreparedImageKernel.renderBrush(
                    samples: samples, sourceWidth: Int(canvas.width), sourceHeight: Int(canvas.height),
                    width: stroke.width, opacity: max(0, min(stroke.opacity ?? 1, 1)),
                    hardness: 1 - max(0, min(stroke.hardness ?? 0, 1)), color: UIColorLike.cgColor(stroke.colorHex),
                    profile: .init(usesPressureForOpacity: false), isCancelled: { Task.isCancelled })
                output = CIImage(cgImage: image).composited(over: output)
                continue
            }
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
            if let region = stroke.region,
               let regionMask = ImageSelectionRasterizer.maskImage(for: region, canvas: canvas) {
                // Region stroke (selection cut/restore): use the SAME mask
                // pipeline as the displayed selection — operations
                // (replace/add/subtract), inverted and feather included.
                // BlendWithMask(input: black|white, background: current mask,
                // mask: region): inside the region becomes black (erase) or
                // white (restore); everything outside keeps the running mask.
                let extent = CGRect(origin: .zero, size: canvas)
                let color = stroke.restore
                    ? CIImage(color: CIColor(red: 1, green: 1, blue: 1, alpha: 1)).cropped(to: extent)
                    : CIImage(color: CIColor(red: 0, green: 0, blue: 0, alpha: 1)).cropped(to: extent)
                let blend = CIFilter(name: "CIBlendWithMask")
                blend?.setValue(color, forKey: kCIInputImageKey)
                blend?.setValue(maskImage.cropped(to: extent), forKey: kCIInputBackgroundImageKey)
                blend?.setValue(regionMask.cropped(to: extent), forKey: kCIInputMaskImageKey)
                maskImage = (blend?.outputImage ?? maskImage).cropped(to: extent)
                continue
            }
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
                                         bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
                throw WorkbenchImageError.encodeFailed("resize context unavailable")
            }
            bitmap.interpolationQuality = .high
            bitmap.draw(full, in: CGRect(x: 0, y: 0, width: targetWidth, height: targetHeight))
            guard let resizedImage = bitmap.makeImage() else {
                throw WorkbenchImageError.encodeFailed("resize image unavailable")
            }
            resized = resizedImage
        } else {
            resized = full
        }
        let data = try encode(resized, options: options, metadata: sourceMetadata(project, options: options, resolveAsset: resolveAsset))
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

    /// Bounded preview uses the real container encoder; file size is an
    /// explicitly labelled estimate scaled from the encoded preview pixels.
    public func previewImageExport(project: MediaProject, options: ImageExportOptions,
                                   resolveAsset: @Sendable (UUID) -> URL?) throws -> (image: CGImage, estimatedBytes: Int64) {
        guard let canvas = project.canvas else { throw WorkbenchImageError.encodeFailed("missing canvas") }
        try MediaExportValidationCore.validateImage(options: options, canvasWidth: canvas.width, canvasHeight: canvas.height, hasTransparency: true)
        let targetWidth = options.width ?? canvas.width, targetHeight = options.height ?? canvas.height
        let scale = min(1, 512 / Double(max(targetWidth, targetHeight)))
        let width = max(1, Int(Double(targetWidth) * scale)), height = max(1, Int(Double(targetHeight) * scale))
        let rendered: CGImage
        if let document = project.prepared {
            rendered = try renderPrepared(document, canvas: .init(width: canvas.width, height: canvas.height), resolveAsset: resolveAsset,
                                          previewMaxEdge: 512, outputMaxEdge: 512)
        } else {
            rendered = try render(project: project, canvas: .init(width: canvas.width, height: canvas.height), resolveAsset: resolveAsset, previewMaxEdge: 512)
        }
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { throw WorkbenchImageError.encodeFailed("preview allocation") }
        context.interpolationQuality = .high; context.draw(rendered, in: .init(x: 0, y: 0, width: width, height: height))
        guard let image = context.makeImage() else { throw WorkbenchImageError.encodeFailed("preview image") }
        let data = try encode(image, options: options)
        guard let source = CGImageSourceCreateWithData(data as CFData, nil), let decoded = CGImageSourceCreateImageAtIndex(source, 0, nil) else { throw WorkbenchImageError.encodeFailed("preview decode") }
        return (decoded, Int64(Double(data.count) * Double(targetWidth * targetHeight) / Double(width * height)))
    }

    private func sourceMetadata(_ project: MediaProject, options: ImageExportOptions,
                                resolveAsset: @Sendable (UUID) -> URL?) -> [CFString: Any] {
        guard !options.stripMetadata else { return [:] }
        let sourceID: UUID?
        if let document = project.prepared {
            sourceID = document.layers.compactMap { layer -> UUID? in
                if case .raster(let raster) = layer.content, case .asset(let id) = raster.source { return id }
                return nil
            }.first
        } else { sourceID = project.imageLayers.compactMap(\.assetID).first }
        guard let sourceID, let url = resolveAsset(sourceID), let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let original = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] else { return [:] }
        var result: [CFString: Any] = [:]
        for key in [kCGImagePropertyExifDictionary, kCGImagePropertyTIFFDictionary, kCGImagePropertyGPSDictionary, kCGImagePropertyIPTCDictionary] {
            if var values = original[key] as? [CFString: Any] {
                values.removeValue(forKey: kCGImagePropertyExifPixelXDimension)
                values.removeValue(forKey: kCGImagePropertyExifPixelYDimension)
                values.removeValue(forKey: kCGImagePropertyTIFFOrientation)
                result[key] = values
            }
        }
        return result
    }

    private func encode(_ image: CGImage, options: ImageExportOptions, metadata: [CFString: Any] = [:]) throws -> Data {
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, options.format.utType.identifier as CFString, 1, nil) else {
            throw WorkbenchImageError.encodeFailed("no encoder for \(options.format)")
        }
        var encodeOptions = metadata
        if options.format != .png {
            encodeOptions[kCGImageDestinationLossyCompressionQuality] = options.quality
        }
        if !options.preserveTransparency {
            // Every container honors the user's background choice.
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

/// Encodes a CGImage to a lossless, alpha-preserving PNG. Used to stage the
/// output of a layer merge as a new project asset.
public enum WorkbenchPNG {
    public static func encode(_ image: CGImage) -> Data? {
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            output, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return output as Data
    }
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
        let shift = value.count == 8 ? 8 : 0
        let r = Double((int >> (16 + shift)) & 0xFF) / 255
        let g = Double((int >> (8 + shift)) & 0xFF) / 255
        let b = Double((int >> shift) & 0xFF) / 255
        return (r, g, b, value.count == 8 ? Double(int & 0xFF) / 255 : 1)
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
