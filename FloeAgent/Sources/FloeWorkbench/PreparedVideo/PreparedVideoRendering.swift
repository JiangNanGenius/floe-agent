// FloeWorkbench — PreparedVideo: frame rendering.
//
// The renderer consumes the evaluator's layer list and draws it through Core
// Image/Core Graphics/Core Text. Current-frame preview and window export call
// `renderFrame` with the same plan, frame index and output settings, so a
// preview cannot drift from the exported frame through a second composition
// implementation.
//
// Asset loading is bounded and fail-closed: missing/unreadable files throw,
// no placeholder frame is returned, and cancellation is checked before any
// image is handed back as a success.

import Foundation
import CoreGraphics
import CoreImage
import CoreText
import ImageIO
import UniformTypeIdentifiers
import AVFoundation

// MARK: - Frame result

/// Immutable rendered frame. `CGImage` is immutable and safe to read from
/// another executor after this value is produced; the unchecked conformance
/// is limited to that fact.
public struct PreparedVideoFrame: @unchecked Sendable {
    public let planID: PreparedVideoPlanID
    public let frameIndex: Int64
    public let time: PreparedVideoTime
    public let outputSettings: PreparedVideoOutputSettings
    public let image: CGImage
    public let evaluation: PreparedVideoFrameEvaluation

    public var width: Int { image.width }
    public var height: Int { image.height }
}

// MARK: - Cancellation

/// Cooperative cancellation handle used by long render/export operations.
/// It can be cancelled directly, or wrap an existing task/store token via a
/// Sendable closure (the FloeCore adapter lives in a separate conditional
/// file so this component remains independently buildable).
public final class PreparedVideoCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    private let external: @Sendable () -> Bool

    public init(external: @escaping @Sendable () -> Bool = { false }) {
        self.external = external
    }

    public static let none = PreparedVideoCancellation()

    public var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled || external()
    }

    public func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
    }

    public func check() throws {
        if isCancelled { throw PreparedVideoError.cancelled }
    }
}

// MARK: - Renderer

public actor PreparedVideoFrameRenderer {
    public struct Limits: Sendable {
        public var maximumOutputPixels: Int
        public var maximumAssetDimension: Int
        public var maximumTextPixels: Int
        public var maximumLayersPerFrame: Int

        public init(maximumOutputPixels: Int = 33_177_600,
                    maximumAssetDimension: Int = 8_192,
                    maximumTextPixels: Int = 16_777_216,
                    maximumLayersPerFrame: Int = 64) {
            self.maximumOutputPixels = maximumOutputPixels
            self.maximumAssetDimension = maximumAssetDimension
            self.maximumTextPixels = maximumTextPixels
            self.maximumLayersPerFrame = maximumLayersPerFrame
        }
    }

    private let limits: Limits
    private let ciContext: CIContext
    private let colorSpace: CGColorSpace
    private var managedContexts: [MediaVideoColorProfile: CIContext] = [:]
    private struct AssetCacheKey: Hashable {
        var planID: PreparedVideoPlanID
        var asset: PreparedVideoAsset
        var profile: MediaVideoColorProfile? = nil
    }
    private var videoAssets: [AssetCacheKey: AVURLAsset] = [:]
    private var imageCache: [AssetCacheKey: CGImage] = [:]
    private var chromaCubes: [MediaVideoChromaKey:Data] = [:]
    private var secondaryCubes: [MediaHSLSecondary:Data] = [:]
    private var matchCubes: [MediaVideoColorMatch:Data] = [:]
    private let maximumCachedImagePixels = 16_777_216
    private struct MotionSignature: Hashable { let size: Int64; let modified: Date; let fileNumber: UInt64 }
    private var verifiedMotion: [AssetCacheKey: (signature: MotionSignature, hash: String)] = [:]
    private func motionSignature(_ url: URL) throws -> MotionSignature {
        let a = try FileManager.default.attributesOfItem(atPath: url.path)
        guard a[.type] as? FileAttributeType == .typeRegular, let size = a[.size] as? NSNumber,
              let modified = a[.modificationDate] as? Date, let number = a[.systemFileNumber] as? NSNumber else {
            throw PreparedVideoError.renderFailed("motion source is unavailable")
        }
        return .init(size: size.int64Value, modified: modified, fileNumber: number.uint64Value)
    }
    private func verifiedMotionSource(asset: PreparedVideoAsset, planID: PreparedVideoPlanID,
                                      bindings: [MediaVideoMotionSource], colorMatch: MediaVideoColorMatch?, cancellation: PreparedVideoCancellation) async throws -> MotionSignature {
        let signature = try motionSignature(asset.url), key = AssetCacheKey(planID: planID, asset: asset)
        let hash: String
        if let cached = verifiedMotion[key], cached.signature == signature { hash = cached.hash }
        else {
            hash = try await MediaVideoMotionService.shared.contentHash(asset.url, cancellation: cancellation)
            guard try motionSignature(asset.url) == signature else { throw PreparedVideoError.assetUnreadable(asset.id) }
            if verifiedMotion.count >= 64 { verifiedMotion.removeAll(keepingCapacity: true) }
            verifiedMotion[key] = (signature,hash)
        }
        guard bindings.allSatisfy({ $0.assetID == asset.id && $0.contentHash == hash }),
              colorMatch.map({ $0.target.assetID == asset.id && $0.target.contentHash == hash }) ?? true else {
            throw PreparedVideoError.assetUnreadable(asset.id)
        }
        return signature
    }

    public init(limits: Limits = Limits()) {
        self.limits = limits
        self.colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        self.ciContext = CIContext(options: [
            .workingColorSpace: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
            .outputColorSpace: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
            .cacheIntermediates: false
        ])
    }

    // MARK: Public entry points

    /// Renders an exact frame index via the shared evaluator.
    public func renderFrame(plan: PreparedVideoPlan,
                            frameIndex: Int64,
                            settings: PreparedVideoOutputSettings,
                            cancellation: PreparedVideoCancellation = .none) async throws -> PreparedVideoFrame {
        let settings = settings.resolvingColorProfile(plan.colorProfile)
        try validate(plan: plan, settings: settings)
        try cancellation.check()
        let evaluation = try PreparedVideoFrameEvaluator.evaluate(plan: plan, frameIndex: frameIndex)
        return try await render(evaluation: evaluation, plan: plan,
                                settings: settings, cancellation: cancellation)
    }

    /// Renders the frame containing a timeline time. Frame-aligned calls use
    /// `renderFrame(plan:frameIndex:)`; this entry point is useful for a
    /// scrubbed preview and reports the nearest frame index in the result.
    public func renderFrame(plan: PreparedVideoPlan,
                            at time: PreparedVideoTime,
                            settings: PreparedVideoOutputSettings,
                            cancellation: PreparedVideoCancellation = .none) async throws -> PreparedVideoFrame {
        let settings = settings.resolvingColorProfile(plan.colorProfile)
        try validate(plan: plan, settings: settings)
        try cancellation.check()
        let evaluation = try PreparedVideoFrameEvaluator.evaluate(plan: plan, at: time)
        return try await render(evaluation: evaluation, plan: plan,
                                settings: settings, cancellation: cancellation)
    }

    /// Encodes a rendered frame without touching a destination file. Callers
    /// own the atomic write policy for previews/snapshots.
    public func pngData(for frame: PreparedVideoFrame) throws -> Data {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            data as CFMutableData, UTType.png.identifier as CFString, 1, nil) else {
            throw PreparedVideoError.renderFailed("could not create a PNG destination")
        }
        CGImageDestinationAddImage(destination, frame.image, nil)
        guard CGImageDestinationFinalize(destination) else {
            throw PreparedVideoError.renderFailed("could not encode the rendered frame")
        }
        return data as Data
    }

    // MARK: Render

    private func validate(plan: PreparedVideoPlan,
                          settings: PreparedVideoOutputSettings) throws {
        try plan.validateForRender()
        guard settings.pixelCount <= limits.maximumOutputPixels else {
            throw PreparedVideoError.invalidOutputSettings("output exceeds the renderer pixel limit")
        }
    }

    private func render(evaluation: PreparedVideoFrameEvaluation,
                        plan: PreparedVideoPlan,
                        settings: PreparedVideoOutputSettings,
                        cancellation: PreparedVideoCancellation) async throws -> PreparedVideoFrame {
        guard evaluation.layers.count <= limits.maximumLayersPerFrame else {
            throw PreparedVideoError.limitExceededLayers(limits.maximumLayersPerFrame)
        }
        let outputRect = CGRect(x: 0, y: 0,
                                width: CGFloat(settings.width),
                                height: CGFloat(settings.height))
        let scaleX = CGFloat(settings.width) / CGFloat(plan.canvas.width)
        let scaleY = CGFloat(settings.height) / CGFloat(plan.canvas.height)

        var canvas = CIImage(color: CIColor(red: CGFloat(evaluation.background.red),
                                            green: CGFloat(evaluation.background.green),
                                            blue: CGFloat(evaluation.background.blue),
                                            alpha: CGFloat(evaluation.background.alpha)))
            .cropped(to: outputRect)

        for layer in evaluation.layers {
            try cancellation.check()
            let prepared = try await layerImage(layer: layer, plan: plan,
                                                settings: settings,
                                                scaleX: scaleX, scaleY: scaleY,
                                                cancellation: cancellation)
            var image = prepared.image
            if let stabilization = layer.stabilization, let time = layer.sourceTime {
                image = try stabilization.apply(to: image, sourceSeconds: time.seconds)
            }
            if let key = layer.chromaKey {
                let cube:Data
                if let cached = chromaCubes[key] { cube = cached }
                else { cube = try key.cubeData();if chromaCubes.count>=4 { chromaCubes.removeAll(keepingCapacity:true) };chromaCubes[key] = cube }
                image = image.applyingFilter("CIColorCube",parameters:["inputCubeDimension":32,"inputCubeData":cube])
            }
            if let grade = layer.videoGrade {
                var secondaryCube: Data?
                if let secondary = grade.secondary {
                    let cube: Data
                    if let cached = secondaryCubes[secondary] { cube = cached }
                    else {
                        cube = try secondary.cubeData()
                        if secondaryCubes.count >= 4 { secondaryCubes.removeAll(keepingCapacity: true) }
                        secondaryCubes[secondary] = cube
                    }
                    secondaryCube = cube
                }
                var matchCube: Data?
                if let match = grade.colorMatch {
                    if let cached = matchCubes[match] { matchCube = cached }
                    else {
                        let cube = try match.cubeData()
                        if matchCubes.count >= 4 { matchCubes.removeAll(keepingCapacity: true) }
                        matchCubes[match] = cube;matchCube = cube
                    }
                }
                image = try grade.apply(to: image,secondaryCube: secondaryCube,matchCube: matchCube)
            }
            if let mask = layer.mask {
                image = try apply(mask: mask, to: image, cancellation: cancellation)
            }
            image = transform(image: image, layer: layer, imageSize: prepared.size,
                              outputRect: outputRect, scaleX: scaleX, scaleY: scaleY)
            image = apply(opacity: layer.opacity, to: image)
            if let filter = layer.blendMode?.filterName { canvas = image.applyingFilter(filter,parameters:[kCIInputBackgroundImageKey:canvas]).cropped(to:outputRect) }
            else { canvas = image.composited(over: canvas) }
        }

        for caption in evaluation.captions {
            try cancellation.check()
            let captionImage = try captionImage(caption, plan: plan, settings: settings)
            canvas = captionImage.composited(over: canvas)
        }

        try cancellation.check()
        let outputSpace = try settings.colorProfile?.colorSpace() ?? colorSpace
        let context: CIContext
        if let profile = settings.colorProfile {
            if let cached = managedContexts[profile] { context = cached }
            else {
                let working = profile.isHDR ? CGColorSpace(name: CGColorSpace.extendedLinearITUR_2020)! : outputSpace
                let created = CIContext(options: [.workingColorSpace:working,.outputColorSpace:outputSpace,.cacheIntermediates:false])
                managedContexts[profile] = created;context = created
            }
        } else { context = ciContext }
        guard let cgImage = context.createCGImage(canvas, from: outputRect,
                                                    format: settings.colorProfile?.isHDR == true ? .RGBAh : .RGBA8,
                                                    colorSpace: outputSpace) else {
            throw PreparedVideoError.renderFailed("Core Image could not produce the output frame")
        }
        try cancellation.check()
        return PreparedVideoFrame(planID: plan.id, frameIndex: evaluation.frameIndex,
                                  time: evaluation.time, outputSettings: settings,
                                  image: cgImage, evaluation: evaluation)
    }

    private struct PreparedLayerImage {
        var image: CIImage
        var size: CGSize
        var alreadyFitted: Bool
    }

    private func layerImage(layer: PreparedVideoLayerEvaluation,
                            plan: PreparedVideoPlan,
                            settings: PreparedVideoOutputSettings,
                            scaleX: CGFloat,
                            scaleY: CGFloat,
                            cancellation: PreparedVideoCancellation) async throws -> PreparedLayerImage {
        switch layer.content {
        case .video(let assetID), .image(let assetID):
            guard let asset = plan.asset(assetID) else {
                throw PreparedVideoError.missingAsset(assetID)
            }
            guard let sourceTime = layer.sourceTime else {
                throw PreparedVideoError.invalidPlan("media layer has no source time")
            }
            let bindings = [layer.videoTracking?.source,layer.stabilization?.source].compactMap({ $0 })
            let match = layer.videoGrade?.colorMatch
            let signature = bindings.isEmpty && match == nil ? nil : try await verifiedMotionSource(asset: asset, planID: plan.id, bindings: bindings, colorMatch: match, cancellation: cancellation)
            let media = try await mediaImage(asset: asset, planID: plan.id, sourceTime: sourceTime,
                                             cancellation: cancellation,profile: settings.colorProfile)
            if let signature {
                guard try motionSignature(asset.url) == signature else { throw PreparedVideoError.assetUnreadable(asset.id) }
                for binding in bindings {
                    guard abs(media.1.width / media.1.height - Double(binding.width) / Double(binding.height)) <= 2 / media.1.height else {
                        throw PreparedVideoError.assetUnreadable(asset.id)
                    }
                }
            }
            return PreparedLayerImage(image: media.0, size: media.1, alreadyFitted: false)
        case .text(let text):
            let raster = try rasterize(text: text, scale: scaleX,
                                       maximumWidth: CGFloat(settings.width) * 0.9,
                                       cancellation: cancellation)
            return PreparedLayerImage(image: CIImage(cgImage: raster),
                                      size: CGSize(width: raster.width, height: raster.height),
                                      alreadyFitted: true)
        case .graphic(let graphic):
            let raster = try rasterize(graphic: graphic, settings: settings,
                                       scaleX: scaleX, scaleY: scaleY,
                                       cancellation: cancellation)
            return PreparedLayerImage(image: CIImage(cgImage: raster),
                                      size: CGSize(width: raster.width, height: raster.height),
                                      alreadyFitted: true)
        }
    }

    private func mediaImage(asset: PreparedVideoAsset,
                            planID: PreparedVideoPlanID,
                            sourceTime: PreparedVideoTime,
                            cancellation: PreparedVideoCancellation,profile: MediaVideoColorProfile?) async throws -> (CIImage, CGSize) {
        let url = asset.url
        let cacheKey = AssetCacheKey(planID: planID, asset: asset,profile: profile)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
              !isDirectory.boolValue else {
            throw PreparedVideoError.missingAsset(asset.id)
        }
        switch asset.kind {
        case .video:
            let urlAsset: AVURLAsset
            if let cached = videoAssets[cacheKey] {
                urlAsset = cached
            } else {
                let created = AVURLAsset(url: url)
                if videoAssets.count >= 64 { videoAssets.removeAll(keepingCapacity: true) }
                videoAssets[cacheKey] = created
                urlAsset = created
            }
            // A fresh generator per request avoids sharing a non-Sendable
            // AVAssetImageGenerator across actor reentrancy.
            let generator = AVAssetImageGenerator(asset: urlAsset)
            generator.appliesPreferredTrackTransform = true
            generator.dynamicRangePolicy = profile?.isHDR == true ? .matchSource : .forceSDR
            generator.requestedTimeToleranceBefore = .zero
            generator.requestedTimeToleranceAfter = .zero
            do {
                try cancellation.check()
                let result = try await generator.image(
                    at: CMTime(value: sourceTime.value, timescale: sourceTime.timescale))
                let image = result.image
                guard image.width > 0, image.height > 0,
                      image.width <= limits.maximumAssetDimension,
                      image.height <= limits.maximumAssetDimension else {
                    throw PreparedVideoError.assetUnreadable(asset.id)
                }
                return (CIImage(cgImage: image),
                        CGSize(width: image.width, height: image.height))
            } catch let error as PreparedVideoError {
                throw error
            } catch {
                throw PreparedVideoError.assetUnreadable(asset.id)
            }
        case .image:
            if let cached = imageCache[cacheKey] {
                return (CIImage(cgImage: cached),
                        CGSize(width: cached.width, height: cached.height))
            }
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                  let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
                  let width = properties[kCGImagePropertyPixelWidth] as? Int,
                  let height = properties[kCGImagePropertyPixelHeight] as? Int,
                  width > 0, height > 0,
                  width <= limits.maximumAssetDimension, height <= limits.maximumAssetDimension,
                  width <= limits.maximumOutputPixels / height,
                  let image = CGImageSourceCreateImageAtIndex(source, 0, profile?.isHDR == true ?
                    [kCGImageSourceShouldAllowFloat:true,kCGImageSourceDecodeRequest:kCGImageSourceDecodeToHDR] as CFDictionary :
                    (profile == .rec709 ? [kCGImageSourceDecodeRequest:kCGImageSourceDecodeToSDR] as CFDictionary : nil)) else {
                throw PreparedVideoError.assetUnreadable(asset.id)
            }
            guard image.width > 0, image.height > 0,
                  image.width <= limits.maximumAssetDimension,
                  image.height <= limits.maximumAssetDimension else {
                throw PreparedVideoError.assetUnreadable(asset.id)
            }
            let pixels = image.width * image.height
            if pixels <= maximumCachedImagePixels {
                let retained = imageCache.values.reduce(0) { $0 + $1.width * $1.height }
                if retained + pixels > maximumCachedImagePixels { imageCache.removeAll(keepingCapacity: true) }
                imageCache[cacheKey] = image
            }
            return (CIImage(cgImage: image), CGSize(width: image.width, height: image.height))
        case .audio:
            throw PreparedVideoError.invalidPlan("audio assets cannot be used as visual content")
        }
    }

    // MARK: Transform / opacity / mask

    private func transform(image: CIImage, layer: PreparedVideoLayerEvaluation,
                           imageSize: CGSize, outputRect: CGRect,
                           scaleX: CGFloat, scaleY: CGFloat) -> CIImage {
        let outWidth = outputRect.width
        let outHeight = outputRect.height
        let transform = layer.transform
        var scaleXForImage: CGFloat
        var scaleYForImage: CGFloat

        if layer.content.isMedia, transform.fit != .stretch {
            let fitScale: CGFloat
            switch transform.fit {
            case .aspectFit:
                fitScale = min(outWidth / imageSize.width, outHeight / imageSize.height)
            case .aspectFill:
                fitScale = max(outWidth / imageSize.width, outHeight / imageSize.height)
            case .stretch:
                fitScale = 1
            }
            scaleXForImage = fitScale * CGFloat(transform.scale)
            scaleYForImage = fitScale * CGFloat(transform.scale)
        } else if transform.fit == .stretch, layer.content.isMedia {
            scaleXForImage = (outWidth / imageSize.width) * CGFloat(transform.scale)
            scaleYForImage = (outHeight / imageSize.height) * CGFloat(transform.scale)
        } else {
            // Text/graphic bitmaps were already rasterized at output pixels.
            scaleXForImage = CGFloat(transform.scale)
            scaleYForImage = CGFloat(transform.scale)
        }

        let center = CGPoint(x: CGFloat(transform.centerX) * outWidth,
                             y: (1 - CGFloat(transform.centerY)) * outHeight)
        let angle = -CGFloat(transform.rotationDegrees) * .pi / 180
        var matrix = CGAffineTransform(translationX: center.x, y: center.y)
        matrix = matrix.rotated(by: angle)
        matrix = matrix.scaledBy(x: scaleXForImage, y: scaleYForImage)
        matrix = matrix.translatedBy(x: -imageSize.width / 2, y: -imageSize.height / 2)
        return image.transformed(by: matrix)
    }

    private func apply(opacity: Double, to image: CIImage) -> CIImage {
        guard opacity < 0.999_999 else { return image }
        let alpha = CGFloat(min(1, max(0, opacity)))
        let filter = CIFilter(name: "CIColorMatrix", parameters: [
            kCIInputImageKey: image,
            "inputRVector": CIVector(x: alpha, y: 0, z: 0, w: 0),
            "inputGVector": CIVector(x: 0, y: alpha, z: 0, w: 0),
            "inputBVector": CIVector(x: 0, y: 0, z: alpha, w: 0),
            "inputAVector": CIVector(x: 0, y: 0, z: 0, w: alpha),
            "inputBiasVector": CIVector(x: 0, y: 0, z: 0, w: 0)
        ])
        return filter?.outputImage ?? image
    }

    private func apply(mask: PreparedVideoMask, to image: CIImage,
                       cancellation: PreparedVideoCancellation) throws -> CIImage {
        try cancellation.check()
        let extent = image.extent
        guard extent.width > 0, extent.height > 0 else {
            throw PreparedVideoError.renderFailed("layer has an empty extent")
        }
        let maskCG = try PreparedVideoMaskKernel.mask(
            mask, width: Int(extent.width.rounded()), height: Int(extent.height.rounded()),
            cancellation: cancellation)
        let maskImage = CIImage(cgImage: maskCG,
                                options: [.colorSpace: NSNull()]).cropped(to: extent)
        let transparent = CIImage(color: CIColor.clear).cropped(to: extent)
        let filter = CIFilter(name: "CIBlendWithMask", parameters: [
            kCIInputImageKey: image,
            kCIInputBackgroundImageKey: transparent,
            kCIInputMaskImageKey: maskImage
        ])
        guard let output = filter?.outputImage else {
            throw PreparedVideoError.renderFailed("could not apply the layer mask")
        }
        return output
    }

    // MARK: Text / captions / graphics

    private func captionImage(_ caption: PreparedVideoCaptionEvaluation,
                              plan: PreparedVideoPlan,
                              settings: PreparedVideoOutputSettings) throws -> CIImage {
        let style = caption.style
        let scale = CGFloat(settings.width) / CGFloat(plan.canvas.width)
        let text = PreparedVideoText(text: caption.text,
                                     fontSize: style.fontSize,
                                     color: style.color,
                                     fontName: style.fontName,
                                     alignment: style.alignment,
                                     backgroundColor: style.backgroundColor,
                                     padding: 10)
        let image = try rasterize(text: text, scale: scale,
                                  maximumWidth: CGFloat(settings.width) * 0.9,
                                  cancellation: .none)
        let ciImage = CIImage(cgImage: image)
        let centerX = CGFloat(settings.width) / 2
        let positionY = CGFloat(min(0.95, max(0.05, style.positionY)))
        let centerY = (1 - positionY) * CGFloat(settings.height)
        let matrix = CGAffineTransform(translationX: centerX, y: centerY)
            .translatedBy(x: -CGFloat(image.width) / 2, y: -CGFloat(image.height) / 2)
        return ciImage.transformed(by: matrix)
    }

    private func rasterize(text: PreparedVideoText, scale: CGFloat,
                           maximumWidth: CGFloat,
                           cancellation: PreparedVideoCancellation) throws -> CGImage {
        try cancellation.check()
        let fontSize = max(1, CGFloat(text.fontSize) * scale)
        let padding = max(0, CGFloat(text.padding) * scale)
        let font: CTFont
        if let name = text.fontName, !name.isEmpty {
            font = CTFontCreateWithName(name as CFString, fontSize, nil)
        } else if let system = CTFontCreateUIFontForLanguage(.system, fontSize, nil) {
            font = system
        } else {
            font = CTFontCreateWithName("Helvetica" as CFString, fontSize, nil)
        }

        var attributes: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): text.color.cgColor
        ]
        var alignment = text.alignment.coreTextAlignment
        let paragraphStyle: CTParagraphStyle = withUnsafePointer(to: &alignment) { pointer in
            var setting = CTParagraphStyleSetting(
                spec: .alignment,
                valueSize: MemoryLayout<CTTextAlignment>.size,
                value: UnsafeRawPointer(pointer))
            return withUnsafePointer(to: &setting) {
                CTParagraphStyleCreate($0, 1)
            }
        }
        attributes[NSAttributedString.Key(kCTParagraphStyleAttributeName as String)] = paragraphStyle
        let attributed = NSAttributedString(string: text.text, attributes: attributes)
        let framesetter = CTFramesetterCreateWithAttributedString(attributed as CFAttributedString)
        let availableWidth = max(1, min(maximumWidth, CGFloat(16_384)) - padding * 2)
        let suggested = CTFramesetterSuggestFrameSizeWithConstraints(
            framesetter, CFRange(location: 0, length: 0), nil,
            CGSize(width: availableWidth, height: 8_192), nil)
        let contentWidth = max(1, ceil(suggested.width))
        let contentHeight = max(1, ceil(suggested.height))
        let width = Int(min(CGFloat(16_384), contentWidth + padding * 2))
        let height = Int(min(CGFloat(16_384), contentHeight + padding * 2))
        guard width > 0, height > 0, width * height <= limits.maximumTextPixels else {
            throw PreparedVideoError.renderFailed("text raster exceeds the renderer bound")
        }
        guard let context = CGContext(data: nil, width: width, height: height,
                                      bitsPerComponent: 8, bytesPerRow: width * 4,
                                      space: colorSpace,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw PreparedVideoError.renderFailed("could not allocate a text bitmap")
        }
        context.clear(CGRect(x: 0, y: 0, width: width, height: height))
        if let background = text.backgroundColor {
            let rect = CGRect(x: 0, y: 0, width: CGFloat(width), height: CGFloat(height))
            let radius = min(12 * scale, CGFloat(height) / 2)
            context.setFillColor(background.cgColor)
            context.addPath(CGPath(roundedRect: rect, cornerWidth: radius,
                                   cornerHeight: radius, transform: nil))
            context.fillPath()
        }
        let path = CGPath(rect: CGRect(x: padding, y: padding,
                                       width: max(1, CGFloat(width) - padding * 2),
                                       height: max(1, CGFloat(height) - padding * 2)),
                          transform: nil)
        let frame = CTFramesetterCreateFrame(framesetter, CFRange(location: 0, length: 0), path, nil)
        context.textMatrix = .identity
        CTFrameDraw(frame, context)
        guard let image = context.makeImage() else {
            throw PreparedVideoError.renderFailed("could not create the text image")
        }
        return image
    }

    private func rasterize(graphic: PreparedVideoGraphic,
                           settings: PreparedVideoOutputSettings,
                           scaleX: CGFloat, scaleY: CGFloat,
                           cancellation: PreparedVideoCancellation) throws -> CGImage {
        try cancellation.check()
        let width = max(1, Int((CGFloat(graphic.width) * CGFloat(settings.width)).rounded()))
        let height = max(1, Int((CGFloat(graphic.height) * CGFloat(settings.height)).rounded()))
        guard width <= 16_384, height <= 16_384, width * height <= limits.maximumTextPixels else {
            throw PreparedVideoError.renderFailed("graphic raster exceeds the renderer bound")
        }
        guard let context = CGContext(data: nil, width: width, height: height,
                                      bitsPerComponent: 8, bytesPerRow: width * 4,
                                      space: colorSpace,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw PreparedVideoError.renderFailed("could not allocate a graphic bitmap")
        }
        context.clear(CGRect(x: 0, y: 0, width: width, height: height))
        let inset = CGFloat(graphic.strokeWidth) * min(scaleX, scaleY) / 2
        let rect = CGRect(x: inset, y: inset,
                          width: max(1, CGFloat(width) - inset * 2),
                          height: max(1, CGFloat(height) - inset * 2))
        let path: CGPath
        switch graphic.shape {
        case .rectangle:
            let radius = CGFloat(graphic.cornerRadius) * min(CGFloat(width), CGFloat(height))
            path = CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
        case .ellipse:
            path = CGPath(ellipseIn: rect, transform: nil)
        }
        context.addPath(path)
        context.setFillColor(graphic.fillColor.cgColor)
        context.fillPath()
        if let strokeColor = graphic.strokeColor, graphic.strokeWidth > 0 {
            context.addPath(path)
            context.setStrokeColor(strokeColor.cgColor)
            context.setLineWidth(max(0.1, CGFloat(graphic.strokeWidth) * min(scaleX, scaleY)))
            context.strokePath()
        }
        guard let image = context.makeImage() else {
            throw PreparedVideoError.renderFailed("could not create the graphic image")
        }
        return image
    }
}

// MARK: - Small extensions

private extension PreparedVideoVisualContent {
    var isMedia: Bool {
        switch self {
        case .video, .image: true
        case .text, .graphic: false
        }
    }
}

private extension PreparedVideoTextAlignment {
    var coreTextAlignment: CTTextAlignment {
        switch self {
        case .leading: .left
        case .center: .center
        case .trailing: .right
        }
    }
}

private extension PreparedVideoError {
    static func limitExceededLayers(_ limit: Int) -> PreparedVideoError {
        .renderFailed("layer count exceeds the renderer limit of \(limit)")
    }
}
