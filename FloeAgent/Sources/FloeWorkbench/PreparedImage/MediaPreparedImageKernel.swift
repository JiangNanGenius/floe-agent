// SPDX-License-Identifier: MPL-2.0
import Foundation
import CoreGraphics
import CoreImage

public enum MediaPreparedImageError: Error, Sendable, Equatable {
    case invalidGeometry
    case resourceLimit
    case cancelled
    case renderFailed
}

/// A resolved raster operation, not an alternative document or save store.
/// Coordinates are normalized; feather is explicitly in source pixels.
public struct MediaPreparedSelectionSpec: Codable, Sendable, Hashable {
    public enum Shape: String, Codable, Sendable { case rectangle, ellipse, lasso }
    public var shape: Shape
    public var points: [MediaPreparedBrushPoint]
    public var featherPixels: Double
    public var inverted: Bool

    public init(shape: Shape, points: [MediaPreparedBrushPoint], featherPixels: Double = 0,
                inverted: Bool = false) {
        self.shape = shape; self.points = points
        self.featherPixels = featherPixels; self.inverted = inverted
    }

    public static func legacyFeatherPixels(normalized: Double, sourceWidth: Int,
                                           sourceHeight: Int) throws -> Double {
        guard normalized.isFinite, (0...0.5).contains(normalized), sourceWidth > 0,
              sourceHeight > 0 else { throw MediaPreparedImageError.invalidGeometry }
        return normalized * Double(min(sourceWidth, sourceHeight))
    }
}

public enum MediaPreparedImageKernel {
    public static let maximumPixels = 64_000_000
    public static let maximumSamples = 100_000

    private static func dimensions(sourceWidth: Int, sourceHeight: Int,
                                   scale: Double) throws -> (Int, Int) {
        guard sourceWidth > 0, sourceHeight > 0, sourceWidth <= 16_384,
              sourceHeight <= 16_384, scale.isFinite, scale > 0, scale <= 1 else {
            throw MediaPreparedImageError.invalidGeometry
        }
        let w = max(1, Int((Double(sourceWidth) * scale).rounded()))
        let h = max(1, Int((Double(sourceHeight) * scale).rounded()))
        guard w <= maximumPixels / h else { throw MediaPreparedImageError.resourceLimit }
        return (w, h)
    }

    private static func valid(_ points: [MediaPreparedBrushPoint]) -> Bool {
        !points.isEmpty && points.count <= maximumSamples && points.allSatisfy {
            $0.x.isFinite && $0.y.isFinite && abs($0.x) <= 16 && abs($0.y) <= 16
        }
    }

    public static func selectionMask(_ spec: MediaPreparedSelectionSpec,
                                     sourceWidth: Int, sourceHeight: Int,
                                     renderScale: Double = 1,
                                     isCancelled: () -> Bool = { false }) throws -> CGImage {
        let (w, h) = try dimensions(sourceWidth: sourceWidth, sourceHeight: sourceHeight,
                                    scale: renderScale)
        guard valid(spec.points), spec.featherPixels.isFinite,
              spec.featherPixels >= 0, spec.featherPixels <= Double(min(sourceWidth, sourceHeight)) else {
            throw MediaPreparedImageError.invalidGeometry
        }
        if isCancelled() { throw MediaPreparedImageError.cancelled }
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8,
                                  bytesPerRow: w, space: CGColorSpaceCreateDeviceGray(),
                                  bitmapInfo: CGImageAlphaInfo.none.rawValue) else {
            throw MediaPreparedImageError.renderFailed
        }
        ctx.setFillColor(gray: spec.inverted ? 1 : 0, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        ctx.setFillColor(gray: spec.inverted ? 0 : 1, alpha: 1)
        let points = spec.points.map { CGPoint(x: $0.x * Double(w), y: (1 - $0.y) * Double(h)) }
        switch spec.shape {
        case .rectangle, .ellipse:
            guard points.count == 2 else { throw MediaPreparedImageError.invalidGeometry }
            let rect = CGRect(x: min(points[0].x, points[1].x), y: min(points[0].y, points[1].y),
                              width: abs(points[1].x - points[0].x), height: abs(points[1].y - points[0].y))
            if spec.shape == .rectangle { ctx.fill(rect) } else { ctx.fillEllipse(in: rect) }
        case .lasso:
            guard points.count >= 3 else { throw MediaPreparedImageError.invalidGeometry }
            ctx.move(to: points[0]); points.dropFirst().forEach { ctx.addLine(to: $0) }
            ctx.closePath(); ctx.fillPath()
        }
        guard let bitmap = ctx.makeImage() else { throw MediaPreparedImageError.renderFailed }
        let radius = spec.featherPixels * renderScale
        guard radius > 0 else { return bitmap }
        // Mask values are coverage, not display colours. Colour-managed
        // grayscale conversion would gamma-encode a 0.5 mask and make a
        // feather plus its inverse fail to sum to full coverage.
        var image = CIImage(cgImage: bitmap, options: [.colorSpace: NSNull()])
        let filter = CIFilter(name: "CIGaussianBlur")!
        filter.setValue(image.clampedToExtent(), forKey: kCIInputImageKey)
        filter.setValue(radius, forKey: kCIInputRadiusKey)
        image = (filter.outputImage ?? image).cropped(to: image.extent)
        if isCancelled() { throw MediaPreparedImageError.cancelled }
        let context = CIContext(options: [.useSoftwareRenderer: true,
                                          .workingColorSpace: NSNull(),
                                          .outputColorSpace: NSNull()])
        guard let output = context.createCGImage(image, from: image.extent) else {
            throw MediaPreparedImageError.renderFailed
        }
        return output
    }

    public static func renderBrush(samples: [MediaPreparedBrushSample], sourceWidth: Int,
                                   sourceHeight: Int, width: Double, opacity: Double,
                                   hardness: Double, color: CGColor,
                                   profile: MediaPreparedPressureProfile = .pencilLike,
                                   renderScale: Double = 1,
                                   isCancelled: () -> Bool = { false }) throws -> CGImage {
        let (w, h) = try dimensions(sourceWidth: sourceWidth, sourceHeight: sourceHeight, scale: renderScale)
        guard valid(samples.map(\.point)), samples.allSatisfy(\.isFinite),
              width.isFinite, width > 0, width <= 4096,
              opacity.isFinite, (0...1).contains(opacity),
              hardness.isFinite, (0...1).contains(hardness) else {
            throw MediaPreparedImageError.invalidGeometry
        }
        if isCancelled() { throw MediaPreparedImageError.cancelled }
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8,
                                  bytesPerRow: w * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue) else {
            throw MediaPreparedImageError.renderFailed
        }
        let profileValues = [profile.minimumWidthRatio, profile.maximumWidthRatio,
            profile.widthExponent, profile.minimumOpacityRatio, profile.opacityExponent,
            profile.minimumResolvedWidth, profile.noPressureWidthRatio, profile.noPressureOpacityRatio]
        guard profileValues.allSatisfy({ $0.isFinite && $0 >= 0 }) else {
            throw MediaPreparedImageError.invalidGeometry
        }
        var scaledProfile = profile
        scaledProfile.minimumResolvedWidth *= renderScale
        let resolved = MediaPreparedPressureResolver.resolve(samples, baseWidth: width * renderScale,
                                                             baseOpacity: opacity, profile: scaledProfile)
        let curve = MediaPreparedStrokeSmoother.smooth(resolved)
        func point(_ p: MediaPreparedBrushPoint) -> CGPoint {
            CGPoint(x: p.x * Double(w), y: (1 - p.y) * Double(h))
        }
        ctx.setLineCap(.round); ctx.setLineJoin(.round)
        if let dot = curve.dot {
            let p = point(dot.point), radius = dot.width / 2
            ctx.setFillColor(color); ctx.setAlpha(dot.opacity)
            ctx.fillEllipse(in: CGRect(x: p.x - radius, y: p.y - radius,
                                      width: radius * 2, height: radius * 2))
        }
        for segment in curve.segments {
            if isCancelled() { throw MediaPreparedImageError.cancelled }
            let steps = segment.kind == .quad ? 16 : 8
            var previous = point(segment.start)
            for step in 1...steps {
                let t = Double(step) / Double(steps), p = point(segment.point(at: t))
                ctx.setStrokeColor(color); ctx.setAlpha(segment.opacity(at: t))
                ctx.setLineWidth(segment.width(at: t)); ctx.move(to: previous); ctx.addLine(to: p)
                ctx.strokePath(); previous = p
            }
        }
        guard let bitmap = ctx.makeImage() else { throw MediaPreparedImageError.renderFailed }
        guard hardness < 0.999 else { return bitmap }
        let image = CIImage(cgImage: bitmap)
        let filter = CIFilter(name: "CIGaussianBlur")!
        filter.setValue(image, forKey: kCIInputImageKey)
        filter.setValue((1 - hardness) * width * renderScale * 0.3, forKey: kCIInputRadiusKey)
        if isCancelled() { throw MediaPreparedImageError.cancelled }
        guard let output = CIContext(options: [.useSoftwareRenderer: true]).createCGImage(
            (filter.outputImage ?? image).cropped(to: image.extent), from: image.extent) else {
            throw MediaPreparedImageError.renderFailed
        }
        return output
    }
}
