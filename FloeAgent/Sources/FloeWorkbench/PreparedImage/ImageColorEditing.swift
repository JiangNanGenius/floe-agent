// SPDX-License-Identifier: MPL-2.0
import Foundation
import CoreGraphics

public struct ImageChannelCurves: Codable, Sendable, Hashable {
    public var red: [ImageFreehandStroke.Point]?
    public var green: [ImageFreehandStroke.Point]?
    public var blue: [ImageFreehandStroke.Point]?

    public init(red: [ImageFreehandStroke.Point]? = nil, green: [ImageFreehandStroke.Point]? = nil,
                blue: [ImageFreehandStroke.Point]? = nil) {
        self.red = red; self.green = green; self.blue = blue
    }
}

/// UI and agent edits use the same typed, journalled parameter change. Source
/// pixels, masks, placement and all unrelated color controls stay intact.
public enum MediaImageColorEditing {
    public static let identityCurve: [ImageFreehandStroke.Point] = [
        .init(x: 0, y: 0), .init(x: 0.25, y: 0.25), .init(x: 0.5, y: 0.5),
        .init(x: 0.75, y: 0.75), .init(x: 1, y: 1)
    ]

    public static func controls(of layer: MediaPreparedLayer) -> ImageLayerAdjustment {
        if case .adjustment(let controls) = layer.content { return controls }
        return layer.adjustment
    }

    public static func merging(_ input: ImageLayerAdjustment, into original: ImageLayerAdjustment,
                               tool: String, selection: ImageSelection?) throws -> ImageLayerAdjustment {
        var next = original
        switch tool {
        case "image.curves":
            if let curve = input.toneCurve { next.toneCurve = curve }
            if let channels = input.channelCurves {
                var merged = next.channelCurves ?? .init()
                if let red = channels.red { merged.red = red }
                if let green = channels.green { merged.green = green }
                if let blue = channels.blue { merged.blue = blue }
                next.channelCurves = merged
            }
        case "image.balance": next.colorBalance = input.colorBalance
        case "image.lut": next.colorLUT = input.colorLUT; next.filterID = input.filterID
        case "image.denoise": next.noiseReduction = input.noiseReduction; next.sharpenRadius = input.sharpenRadius
        default: throw MediaPreparedCoreError.invalidOperation("unsupported color control")
        }
        // No new selection means re-editing the saved effect in its saved region.
        if let selection { next.effectRegion = selection }
        try MediaNativeColor.validateExtended(next)
        return next
    }

    public static func action(layer: MediaPreparedLayer, controls: ImageLayerAdjustment) throws -> MediaPreparedAction {
        guard !layer.isLocked else { throw MediaPreparedCoreError.invalidOperation("layer is locked") }
        try MediaNativeColor.validateExtended(controls)
        if case .adjustment = layer.content {
            return .replaceLayerContent(id: layer.id, expectedRevision: layer.revision, content: .adjustment(controls))
        }
        return .updateLayerAdjustment(id: layer.id, expectedRevision: layer.revision, adjustment: controls)
    }
}

public struct ImageColorHistogram: Sendable {
    public var red = [Int](repeating: 0, count: 256)
    public var green = [Int](repeating: 0, count: 256)
    public var blue = [Int](repeating: 0, count: 256)
    public var luminance = [Int](repeating: 0, count: 256)

    public static func measure(_ image: CGImage) throws -> Self {
        let scale = min(1, 128 / Double(max(image.width, image.height)))
        let width = max(1, Int(Double(image.width) * scale)), height = max(1, Int(Double(image.height) * scale))
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        let drawn = bytes.withUnsafeMutableBytes { storage -> Bool in
            guard let context = CGContext(data: storage.baseAddress, width: width, height: height,
                bitsPerComponent: 8, bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { throw MediaPreparedImageError.renderFailed }
        var result = Self()
        for offset in stride(from: 0, to: bytes.count, by: 4) where bytes[offset + 3] > 0 {
            let alpha = Int(bytes[offset + 3])
            let r = min(255, Int(bytes[offset]) * 255 / alpha)
            let g = min(255, Int(bytes[offset + 1]) * 255 / alpha)
            let b = min(255, Int(bytes[offset + 2]) * 255 / alpha)
            result.red[r] += 1; result.green[g] += 1; result.blue[b] += 1
            let luma = Double(r) * 0.2126 + Double(g) * 0.7152 + Double(b) * 0.0722
            let bin = min(255, Int(luma))
            result.luminance[bin] += 1
        }
        return result
    }
}
