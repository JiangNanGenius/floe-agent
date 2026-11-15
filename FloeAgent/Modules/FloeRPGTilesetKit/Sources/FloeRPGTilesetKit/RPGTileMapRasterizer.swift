// SPDX-License-Identifier: MPL-2.0
import Foundation
import CoreGraphics
import ImageIO

/// Real CoreGraphics rasterizer for a render plan. Used by tests and the
/// render probe; the UI can also use it for contact sheets. It is bounded to
/// `maxDimension` and never allocates a per-cell full-image copy.
public enum RPGTileMapRasterizer {
    public static func render(plan: RPGTileRenderPlan,
                              images: [String: CGImage],
                              scale: CGFloat = 1,
                              background: CGColor? = nil,
                              showGrid: Bool = false,
                              maxDimension: Int = 4_096) -> CGImage? {
        let content = plan.contentSize
        guard content.width > 0, content.height > 0 else { return nil }
        let safeScale = max(CGFloat(0.01), scale)
        let pixelWidth = Int((content.width * safeScale).rounded(.up))
        let pixelHeight = Int((content.height * safeScale).rounded(.up))
        guard pixelWidth > 0, pixelHeight > 0,
              pixelWidth <= maxDimension, pixelHeight <= maxDimension,
              pixelWidth * pixelHeight <= 16_777_216 else { return nil }
        guard let context = CGContext(
            data: nil, width: pixelWidth, height: pixelHeight,
            bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.interpolationQuality = .none
        context.setShouldAntialias(false)
        if let background {
            context.setFillColor(background)
            context.fill(CGRect(x: 0, y: 0, width: CGFloat(pixelWidth), height: CGFloat(pixelHeight)))
        } else {
            context.setFillColor(CGColor(red: 0.07, green: 0.08, blue: 0.10, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: CGFloat(pixelWidth), height: CGFloat(pixelHeight)))
        }
        let cropCache = RPGCropCache()
        for command in plan.commands {
            guard let image = images[command.imagePath] else {
                drawFallback(command: command, context: context, pixelHeight: pixelHeight, scale: safeScale)
                continue
            }
            guard let cropped = cropCache.crop(image, rect: command.source) else {
                drawFallback(command: command, context: context, pixelHeight: pixelHeight, scale: safeScale)
                continue
            }
            context.saveGState()
            context.translateBy(x: 0, y: CGFloat(pixelHeight))
            context.scaleBy(x: safeScale, y: -safeScale)
            context.draw(cropped, in: command.destination)
            context.restoreGState()
        }
        for marker in plan.markers {
            context.saveGState()
            context.translateBy(x: 0, y: CGFloat(pixelHeight))
            context.scaleBy(x: safeScale, y: -safeScale)
            context.setFillColor(CGColor(red: 1, green: 0.55, blue: 0.05, alpha: 0.24))
            context.fill(marker.rect)
            context.setStrokeColor(CGColor(red: 1, green: 0.65, blue: 0.10, alpha: 0.95))
            context.setLineWidth(1.5 / safeScale)
            context.stroke(marker.rect.insetBy(dx: 0.75, dy: 0.75))
            context.restoreGState()
        }
        if showGrid {
            context.saveGState()
            context.translateBy(x: 0, y: CGFloat(pixelHeight))
            context.scaleBy(x: safeScale, y: -safeScale)
            context.setStrokeColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.10))
            context.setLineWidth(1 / safeScale)
            let step = CGFloat(plan.tileSize)
            var x: CGFloat = 0
            while x <= content.width {
                context.move(to: CGPoint(x: x, y: 0))
                context.addLine(to: CGPoint(x: x, y: content.height))
                x += step
            }
            var y: CGFloat = 0
            while y <= content.height {
                context.move(to: CGPoint(x: 0, y: y))
                context.addLine(to: CGPoint(x: content.width, y: y))
                y += step
            }
            context.strokePath()
            context.restoreGState()
        }
        return context.makeImage()
    }

    private static func drawFallback(command: RPGTileDrawCommand, context: CGContext,
                                     pixelHeight: Int, scale: CGFloat) {
        var hash: UInt64 = 1469598103934665603
        for byte in command.imagePath.utf8 { hash = (hash ^ UInt64(byte)) &* 1099511628211 }
        let red = CGFloat((hash >> 8) & 0xff) / 255
        let green = CGFloat((hash >> 16) & 0xff) / 255
        let blue = CGFloat((hash >> 24) & 0xff) / 255
        context.saveGState()
        context.translateBy(x: 0, y: CGFloat(pixelHeight))
        context.scaleBy(x: scale, y: -scale)
        context.setFillColor(CGColor(red: red * 0.45, green: green * 0.45,
                                     blue: blue * 0.45, alpha: 0.85))
        context.fill(command.destination)
        context.setStrokeColor(CGColor(red: 1, green: 0.25, blue: 0.25, alpha: 0.7))
        context.setLineWidth(1 / scale)
        context.move(to: CGPoint(x: command.destination.minX, y: command.destination.minY))
        context.addLine(to: CGPoint(x: command.destination.maxX, y: command.destination.maxY))
        context.strokePath()
        context.restoreGState()
    }
}

/// Small bounded crop cache. CGImage.cropping shares the decoded backing store
/// (it does not decode another huge image per map cell).
final class RPGCropCache {
    private struct Key: Hashable {
        let object: ObjectIdentifier
        let x: Int
        let y: Int
        let width: Int
        let height: Int
    }
    private var cache: [Key: CGImage] = [:]
    private let limit: Int
    init(limit: Int = 2_048) { self.limit = limit }

    func crop(_ image: CGImage, rect: CGRect) -> CGImage? {
        let integral = CGRect(x: rect.minX.rounded(), y: rect.minY.rounded(),
                              width: rect.width.rounded(), height: rect.height.rounded())
        guard integral.width > 0, integral.height > 0 else { return nil }
        let clipped = integral.intersection(CGRect(x: 0, y: 0, width: CGFloat(image.width), height: CGFloat(image.height)))
        guard !clipped.isNull, clipped.width > 0, clipped.height > 0 else { return nil }
        let key = Key(object: ObjectIdentifier(image), x: Int(clipped.minX), y: Int(clipped.minY),
                      width: Int(clipped.width), height: Int(clipped.height))
        if let cached = cache[key] { return cached }
        guard let cropped = image.cropping(to: clipped) else { return nil }
        if cache.count >= limit { cache.removeAll(keepingCapacity: true) }
        cache[key] = cropped
        return cropped
    }
}

public enum RPGImageWriter {
    public enum WriteError: Error, Sendable { case destination, encode }
    public static func writePNG(_ image: CGImage, to url: URL) throws {
        guard let destination = CGImageDestinationCreateWithURL(
            url as CFURL, "public.png" as CFString, 1, nil) else {
            throw WriteError.destination
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw WriteError.encode }
    }

    public static func pngData(_ image: CGImage) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            data, "public.png" as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }
}
