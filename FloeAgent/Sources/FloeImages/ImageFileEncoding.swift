// FloeImages — Format-preserving raster encoding for interactive editors.
//
// The built-in editor emits a verified PNG. A workspace file, however, must
// keep its own container: a `.jpg`/`.heic` path must never receive PNG bytes.
// This utility maps a destination path extension to a writable raster
// container, re-encodes the editor output into it, and re-reads the encoded
// bytes before the workspace layer commits them atomically.
//
// Formats without a writable container (gif/webp/tiff/bmp/svg/…) return nil
// from `ImageFileFormat(pathExtension:)` so callers can explain why editing
// is unavailable instead of overwriting a file with foreign bytes.

import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

/// Raster containers Floe editors may write back into an existing file.
public enum ImageFileFormat: String, Sendable, CaseIterable {
    case png
    case jpeg
    case heic

    /// Maps a path extension (with or without a leading dot) to a writable
    /// raster container. Nil means the editor must not overwrite the path.
    public init?(pathExtension: String) {
        let ext = pathExtension.lowercased().hasPrefix(".")
            ? String(pathExtension.lowercased().dropFirst())
            : pathExtension.lowercased()
        switch ext {
        case "png": self = .png
        case "jpg", "jpeg": self = .jpeg
        case "heic", "heif": self = .heic
        default: return nil
        }
    }

    /// Uniform type identifier written by `ImageFileEncoder`.
    public var contentType: UTType {
        switch self {
        case .png: .png
        case .jpeg: .jpeg
        case .heic: .heic
        }
    }
}

/// Honest failures from the format-preserving re-encode step.
public enum ImageFileEncodingError: LocalizedError, Sendable, Equatable {
    case decodeFailed
    case encodeFailed(String)
    case verificationFailed

    public var errorDescription: String? {
        switch self {
        case .decodeFailed:
            "The image payload could not be decoded."
        case .encodeFailed(let detail):
            "The image could not be encoded: \(detail)"
        case .verificationFailed:
            "The encoded image did not pass the re-read check."
        }
    }
}

/// Encodes a `CGImage` (or the editor's PNG output) into a concrete raster
/// container and verifies the result by re-reading it.
public enum ImageFileEncoder {
    /// Default quality for lossy containers (JPEG/HEIC).
    public static let defaultQuality = 0.95

    /// Re-encodes received image bytes into `format`. Throws
    /// `.decodeFailed` when the payload is not a readable image.
    public static func reencode(
        _ data: Data,
        as format: ImageFileFormat,
        quality: Double = defaultQuality
    ) throws -> Data {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetCount(source) > 0,
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw ImageFileEncodingError.decodeFailed
        }
        return try encode(image, as: format, quality: quality)
    }

    /// Encodes `image` into `format` and re-reads the bytes to prove that the
    /// committed file will decode at the same pixel size.
    public static func encode(
        _ image: CGImage,
        as format: ImageFileFormat,
        quality: Double = defaultQuality
    ) throws -> Data {
        // JPEG carries no alpha; a transparent edit must not turn into a
        // black rectangle, so it is composited over white first.
        let encodable = format == .jpeg ? try flattenedOverWhite(image) : image
        guard let output = CFDataCreateMutable(nil, 0),
              let destination = CGImageDestinationCreateWithData(
                  output,
                  format.contentType.identifier as CFString,
                  1,
                  nil
              ) else {
            throw ImageFileEncodingError.encodeFailed("no encoder for \(format.contentType.identifier)")
        }
        var options: [CFString: Any] = [:]
        if format != .png {
            options[kCGImageDestinationLossyCompressionQuality] = min(max(quality, 0), 1)
        }
        CGImageDestinationAddImage(destination, encodable, options as CFDictionary)
        guard CGImageDestinationFinalize(destination), CFDataGetLength(output) > 0 else {
            throw ImageFileEncodingError.encodeFailed("finalize returned no data")
        }
        let encoded = output as Data
        guard let verifySource = CGImageSourceCreateWithData(encoded as CFData, nil),
              let decoded = CGImageSourceCreateImageAtIndex(verifySource, 0, nil),
              decoded.width == image.width,
              decoded.height == image.height else {
            throw ImageFileEncodingError.verificationFailed
        }
        return encoded
    }

    /// Composites the image onto an opaque white RGB bitmap.
    private static func flattenedOverWhite(_ image: CGImage) throws -> CGImage {
        let width = image.width
        let height = image.height
        guard width > 0, height > 0,
              let context = CGContext(
                  data: nil,
                  width: width,
                  height: height,
                  bitsPerComponent: 8,
                  bytesPerRow: 0,
                  space: CGColorSpaceCreateDeviceRGB(),
                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
              ) else {
            throw ImageFileEncodingError.encodeFailed("no RGB context for alpha flattening")
        }
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let flattened = context.makeImage() else {
            throw ImageFileEncodingError.encodeFailed("alpha flattening produced no image")
        }
        return flattened
    }
}
