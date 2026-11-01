//
//  CADExportImage.swift
//  FloeCADKit
//
//  Bounded image normalization shared by texture-bearing exporters.
//
//  The engineering material pipeline stores image bytes plus per-map semantics
//  (colour space and row origin). Formats such as Wavefront MTL have neither a
//  colour-space tag nor a per-map UV transform, so a faithful OBJ bundle must
//  normalize the actual pixels instead of relabelling them. This file provides
//  the one bounded decode/normalize/encode path used by `OBJBundleExporter`:
//
//    * header dimensions are checked BEFORE a bitmap is allocated, against the
//      same 4096 px / 64 MiB limits the viewport and GLB exporter use;
//    * EXIF-rotated images are refused (a filename-only texture reference
//      cannot carry that transform; silently writing rotated pixels would be a
//      different appearance);
//    * decoded pixels are straight-alpha, row 0 = top row, matching the
//      engineering texture convention;
//    * `.bottomLeft` authored maps are flipped exactly once;
//    * colour transforms use the same sRGB transfer the Metal shader and the
//      GLB/USDZ exporters use;
//    * PNG encoding writes straight alpha so RGB code values are not quantised
//      against a lowered alpha channel.
//
//  This is deliberately a value-only API: no cache, no temporary files and no
//  mutation of a document, material library or source `Body`.
//
//  The pixel transforms mirror GLBExporter's private rgbaBytes/encodePNG
//  semantics exactly. GLB is intentionally left byte-stable for the existing
//  X14 witnesses; this file is the shared implementation for the new OBJ
//  exporter and the consolidation point for a later GLB adoption.
//

import Foundation
import CoreGraphics
import ImageIO

nonisolated enum CADExportImage {

    struct Decoded {
        var width: Int
        var height: Int
        var image: CGImage
    }

    /// Straight-alpha RGBA, row 0 = the top row of the normalized image.
    struct Pixels: Equatable {
        var width: Int
        var height: Int
        var rgba: [UInt8]

        var pixelCount: Int { width * height }
    }

    enum Failure: Error, Equatable {
        case invalid
        case oversized
        case unsupportedOrientation
        case decodeFailed
        case encodeFailed
    }

    /// One bounded decode. `Data` must already have passed the material byte
    /// bound; this repeats it so a direct caller cannot bypass the limit.
    static func decode(_ data: Data) -> Result<Decoded, Failure> {
        guard !data.isEmpty,
              data.count <= CADMaterialLimits.maximumTextureBytes,
              MaterialImageSniffer.mimeType(of: data) != nil,
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetCount(source) == 1,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil)
                as? [CFString: Any],
              let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
              let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue else {
            return .failure(.invalid)
        }
        guard width > 0, height > 0,
              width <= CADImagePackingLimits.maximumDimension,
              height <= CADImagePackingLimits.maximumDimension,
              width * height <= CADImagePackingLimits.maximumPixelCount,
              width * height * 4 <= CADImagePackingLimits.maximumDecodedBytes else {
            return .failure(.oversized)
        }
        if let orientation = (properties[kCGImagePropertyOrientation] as? NSNumber)?.intValue,
           orientation != 1 {
            return .failure(.unsupportedOrientation)
        }
        guard let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
              image.width > 0, image.height > 0,
              image.width <= CADImagePackingLimits.maximumDimension,
              image.height <= CADImagePackingLimits.maximumDimension,
              image.width * image.height <= CADImagePackingLimits.maximumPixelCount,
              image.width * image.height * 4 <= CADImagePackingLimits.maximumDecodedBytes else {
            return .failure(.decodeFailed)
        }
        return .success(Decoded(width: width, height: height, image: image))
    }

    /// Draw into a bounded target size (nearest-neighbor) and recover straight
    /// alpha. A nil result means the bounded bitmap allocation or draw failed;
    /// callers must refuse rather than invent pixels.
    static func pixels(_ decoded: Decoded,
                       width: Int? = nil,
                       height: Int? = nil,
                       orientation: MaterialTextureOrientation = .topLeft) -> Pixels? {
        let targetWidth = width ?? decoded.width
        let targetHeight = height ?? decoded.height
        guard targetWidth > 0, targetHeight > 0,
              targetWidth <= CADImagePackingLimits.maximumDimension,
              targetHeight <= CADImagePackingLimits.maximumDimension,
              targetWidth * targetHeight <= CADImagePackingLimits.maximumPixelCount,
              targetWidth * targetHeight * 4 <= CADImagePackingLimits.maximumDecodedBytes else {
            return nil
        }
        var bytes = [UInt8](repeating: 0, count: targetWidth * targetHeight * 4)
        var drew = false
        bytes.withUnsafeMutableBytes { buffer in
            guard let context = CGContext(
                data: buffer.baseAddress, width: targetWidth, height: targetHeight,
                bitsPerComponent: 8, bytesPerRow: targetWidth * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
            context.interpolationQuality = .none
            context.draw(decoded.image, in: CGRect(x: 0, y: 0,
                                                   width: targetWidth, height: targetHeight))
            drew = true
        }
        guard drew else { return nil }
        unpremultiply(&bytes)
        if orientation == .bottomLeft {
            flipRows(&bytes, width: targetWidth, height: targetHeight)
        }
        return Pixels(width: targetWidth, height: targetHeight, rgba: bytes)
    }

    /// Straight-alpha PNG, matching the GLB/USDZ encoders.
    static func encodePNG(_ pixels: Pixels) -> Data? {
        guard pixels.rgba.count == pixels.width * pixels.height * 4,
              let provider = CGDataProvider(data: Data(pixels.rgba) as CFData),
              let image = CGImage(width: pixels.width, height: pixels.height,
                                  bitsPerComponent: 8, bitsPerPixel: 32,
                                  bytesPerRow: pixels.width * 4,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue),
                                  provider: provider, decode: nil,
                                  shouldInterpolate: false, intent: .defaultIntent) else {
            return nil
        }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            output as CFMutableData, "public.png" as CFString, 1, nil) else {
            return nil
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return output as Data
    }

    /// Exact sRGB transfer used by `Shaders.metal`, GLB and USDZ.
    static func linearToSRGB(_ value: Double) -> Double {
        let c = min(max(value, 0), 1)
        return c <= 0.0031308 ? c * 12.92 : 1.055 * pow(c, 1.0 / 2.4) - 0.055
    }

    static func srgbToLinear(_ value: Double) -> Double {
        let c = min(max(value, 0), 1)
        return c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
    }

    static func encodedChannel(_ value: UInt8, fromLinear: Bool) -> UInt8 {
        guard fromLinear else { return value }
        return UInt8((linearToSRGB(Double(value) / 255.0) * 255.0).rounded())
    }

    /// Convert RGB from linear code values to the sRGB encoding MTL colour
    /// maps conventionally carry. Alpha is untouched.
    static func colorToSRGB(_ pixels: Pixels) -> Pixels {
        var copy = pixels
        var offset = 0
        while offset + 3 < copy.rgba.count {
            for channel in 0..<3 {
                copy.rgba[offset + channel] = encodedChannel(copy.rgba[offset + channel],
                                                             fromLinear: true)
            }
            offset += 4
        }
        return copy
    }

    /// A straight-alpha image without its alpha channel. Used for `map_Kd`
    /// after the effective alpha has been baked into `map_d`; leaving the
    /// original alpha in place would apply it twice in viewers that read both.
    static func flattenAlpha(_ pixels: Pixels) -> Pixels {
        var copy = pixels
        var offset = 3
        while offset < copy.rgba.count {
            copy.rgba[offset] = 255
            offset += 4
        }
        return copy
    }

    /// Normalize a scalar map to grayscale linear code values. The engineering
    /// shader samples the luminance of these maps; writing R=G=B keeps the same
    /// value in viewers that read any single channel. The RGB values are
    /// transformed according to the map's DECLARED colour space before the
    /// luminance weights are applied, exactly like `sampleScalarMap`.
    static func grayscale(_ pixels: Pixels, srgb: Bool) -> Pixels {
        var copy = pixels
        var offset = 0
        while offset + 3 < copy.rgba.count {
            let value = luminance(pixels, offset / 4, srgb: srgb)
            copy.rgba[offset] = value
            copy.rgba[offset + 1] = value
            copy.rgba[offset + 2] = value
            copy.rgba[offset + 3] = 255
            offset += 4
        }
        return copy
    }

    static func luminance(_ pixels: Pixels, _ pixel: Int, srgb: Bool = false) -> UInt8 {
        let base = pixel * 4
        guard base + 2 < pixels.rgba.count else { return 0 }
        if srgb {
            let r = srgbToLinear(Double(pixels.rgba[base]) / 255.0)
            let g = srgbToLinear(Double(pixels.rgba[base + 1]) / 255.0)
            let b = srgbToLinear(Double(pixels.rgba[base + 2]) / 255.0)
            let value = (r * 54.0 + g * 183.0 + b * 19.0) / 256.0
            return UInt8((min(max(value, 0), 1) * 255.0).rounded())
        }
        let value = (Int(pixels.rgba[base]) * 54
                     + Int(pixels.rgba[base + 1]) * 183
                     + Int(pixels.rgba[base + 2]) * 19) >> 8
        return UInt8(min(max(value, 0), 255))
    }

    static func hasTransparentPixel(_ pixels: Pixels) -> Bool {
        var offset = 3
        while offset < pixels.rgba.count {
            if pixels.rgba[offset] != 255 { return true }
            offset += 4
        }
        return false
    }

    static func isGrayscaleOpaque(_ pixels: Pixels) -> Bool {
        var offset = 0
        while offset + 3 < pixels.rgba.count {
            if pixels.rgba[offset] != pixels.rgba[offset + 1]
                || pixels.rgba[offset] != pixels.rgba[offset + 2] {
                return false
            }
            if pixels.rgba[offset + 3] != 255 { return false }
            offset += 4
        }
        return true
    }

    /// Row-major alpha channel, used to build a `map_d` from an albedo map's
    /// authored transparency.
    static func alphaValues(_ pixels: Pixels) -> [UInt8] {
        var values = [UInt8]()
        values.reserveCapacity(pixels.pixelCount)
        var offset = 3
        while offset < pixels.rgba.count {
            values.append(pixels.rgba[offset])
            offset += 4
        }
        return values
    }

    // MARK: - Internals

    /// CGContext draws premultiplied pixels. Recover straight RGBA so
    /// luminance/copied RGB match the bytes a GPU samples from a PNG.
    private static func unpremultiply(_ bytes: inout [UInt8]) {
        var pixel = 0
        while pixel < bytes.count {
            let alpha = Int(bytes[pixel + 3])
            if alpha == 0 {
                bytes[pixel] = 0
                bytes[pixel + 1] = 0
                bytes[pixel + 2] = 0
            } else if alpha < 255 {
                for channel in 0..<3 {
                    let value = Int(bytes[pixel + channel]) * 255
                    bytes[pixel + channel] = UInt8(min(255, (value + alpha / 2) / alpha))
                }
            }
            pixel += 4
        }
    }

    private static func flipRows(_ bytes: inout [UInt8], width: Int, height: Int) {
        let rowBytes = width * 4
        guard rowBytes > 0, height > 1 else { return }
        var flipped = bytes
        for row in 0..<height {
            let source = row * rowBytes
            let target = (height - 1 - row) * rowBytes
            flipped.replaceSubrange(target..<(target + rowBytes),
                                    with: bytes[source..<(source + rowBytes)])
        }
        bytes = flipped
    }
}
