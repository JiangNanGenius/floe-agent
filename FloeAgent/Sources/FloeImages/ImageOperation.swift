// FloeImages — Precompiled local image operations (iOS-only target).
// See blazing-aurora-darwin.md §5.9. Every operation is validated before
// execution; model-supplied parameters never bypass `validate()`.

import Foundation
import FloeCore

/// A precompiled local image operation with validated parameters.
public enum ImageOperation: Sendable, Codable, Hashable {
    case crop(rect: NormalizedRect)
    case rotate(degrees: Double)
    case resize(width: Int, height: Int, preserveAspect: Bool)
    case convertFormat(ImageFormat)
    case compress(quality: Double)
    case removeMetadata
    case adjustExposure(ev: Double)
    case adjustColor(saturation: Double, contrast: Double, brightness: Double)
    case sharpen(radius: Double)
    case blur(radius: Double)
    case applyMask(maskImageID: UUID)
    case composite(overlayImageID: UUID, at: NormalizedPoint, opacity: Double)
    case drawText(text: String, at: NormalizedPoint, fontSize: Double, colorHex: String)
    case watermark(text: String, opacity: Double)
    case removeBackground

    public enum ImageFormat: String, Sendable, Codable, Hashable {
        case png, jpeg, heic, webp
    }

    /// Unit-square normalized rectangle (0...1 per component).
    public struct NormalizedRect: Sendable, Codable, Hashable {
        public var x: Double
        public var y: Double
        public var width: Double
        public var height: Double

        public init(x: Double, y: Double, width: Double, height: Double) {
            self.x = x
            self.y = y
            self.width = width
            self.height = height
        }
    }

    /// Unit-square normalized point.
    public struct NormalizedPoint: Sendable, Codable, Hashable {
        public var x: Double
        public var y: Double

        public init(x: Double, y: Double) {
            self.x = x
            self.y = y
        }
    }

    /// Validates parameters before execution.
    public func validate() throws {
        switch self {
        case .crop(let rect):
            guard (0...1).contains(rect.x), (0...1).contains(rect.y),
                  rect.width > 0, rect.height > 0,
                  rect.x + rect.width <= 1.0, rect.y + rect.height <= 1.0 else {
                throw FloeError.validationFailed("Crop rect must fit inside the unit square")
            }
        case .rotate(let degrees):
            guard degrees.isFinite, abs(degrees) <= 360 else {
                throw FloeError.validationFailed("Rotation must be within ±360°")
            }
        case .resize(let width, let height, _):
            guard (1...16384).contains(width), (1...16384).contains(height) else {
                throw FloeError.validationFailed("Resize dimensions must be 1-16384 px")
            }
        case .convertFormat:
            break
        case .compress(let quality):
            guard quality.isFinite, (0.01...1.0).contains(quality) else {
                throw FloeError.validationFailed("Compression quality must be 0.01-1.0")
            }
        case .removeMetadata:
            break
        case .adjustExposure(let ev):
            guard ev.isFinite, abs(ev) <= 10 else {
                throw FloeError.validationFailed("Exposure adjustment must be within ±10 EV")
            }
        case .adjustColor(let saturation, let contrast, let brightness):
            for value in [saturation, contrast, brightness] {
                guard value.isFinite, abs(value) <= 4 else {
                    throw FloeError.validationFailed("Color adjustments must be within ±4")
                }
            }
        case .sharpen(let radius), .blur(let radius):
            guard radius.isFinite, (0...100).contains(radius) else {
                throw FloeError.validationFailed("Radius must be 0-100")
            }
        case .applyMask:
            break
        case .composite(_, let at, let opacity):
            guard (0...1).contains(at.x), (0...1).contains(at.y) else {
                throw FloeError.validationFailed("Composite position must be normalized")
            }
            guard opacity.isFinite, (0...1).contains(opacity) else {
                throw FloeError.validationFailed("Opacity must be 0-1")
            }
        case .drawText(let text, let at, let fontSize, let colorHex):
            guard text.utf8.count <= 4096 else {
                throw FloeError.validationFailed("Draw text exceeds 4 KiB")
            }
            guard (0...1).contains(at.x), (0...1).contains(at.y) else {
                throw FloeError.validationFailed("Text position must be normalized")
            }
            guard fontSize.isFinite, (1...1000).contains(fontSize) else {
                throw FloeError.validationFailed("Font size must be 1-1000")
            }
            guard colorHex.range(of: #"^#[0-9a-fA-F]{6}$"#, options: .regularExpression) != nil else {
                throw FloeError.validationFailed("colorHex must be #RRGGBB")
            }
        case .watermark(let text, let opacity):
            guard text.utf8.count <= 1024 else {
                throw FloeError.validationFailed("Watermark text exceeds 1 KiB")
            }
            guard opacity.isFinite, (0...1).contains(opacity) else {
                throw FloeError.validationFailed("Opacity must be 0-1")
            }
        case .removeBackground:
            break
        }
    }
}
