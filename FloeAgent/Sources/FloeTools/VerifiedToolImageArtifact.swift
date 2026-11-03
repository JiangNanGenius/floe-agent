// SPDX-License-Identifier: MPL-2.0
import Foundation
import FloeCore
import FloeModels
#if canImport(ImageIO)
import ImageIO
import CoreGraphics
#endif

/// Shared storage boundary for image artifacts shown in chat or sent to a
/// model. A preview is derived evidence; it never replaces the retained file.
public struct VerifiedToolImageArtifact: Sendable {
    public static let maximumStoredImageBytes = 24 * 1_024 * 1_024
    public static let namespaces: Set<String> = [
        "BrowserArtifacts", "GeneratedImages", "VNCArtifacts",
        "CADViewportArtifacts", "CADAnimationFrames", "EngineeringObservations",
        "ImageInspectionArtifacts"
    ]

    public let reference: ToolArtifactReference
    public let fileURL: URL
    public let mimeType: String
    public let data: Data

    /// Encoded pixel dimensions and EXIF orientation, read without decoding
    /// the full bitmap. Display dimensions account for quarter-turn metadata.
    public struct PixelGeometry: Sendable, Equatable {
        public let width: Int
        public let height: Int
        public let orientation: Int

        public var displayWidth: Int { (5...8).contains(orientation) ? height : width }
        public var displayHeight: Int { (5...8).contains(orientation) ? width : height }
    }

    public struct Delivery: Sendable {
        public let data: Data
        public let mimeType: String
        public let sourceSHA256: String
        public let attachedSHA256: String
        public let isPreview: Bool
        public let sourceGeometry: PixelGeometry?
        public let attachedGeometry: PixelGeometry?

        public var receipt: String {
            var text = "sourceSHA256=\(sourceSHA256) attachedSHA256=\(attachedSHA256) "
                + "bytes=\(data.count) representation=\(isPreview ? "derived-preview" : "original")"
            if let sourceGeometry {
                text += " sourcePixels=\(sourceGeometry.width)x\(sourceGeometry.height)"
                    + " sourceOrientation=\(sourceGeometry.orientation)"
            }
            if let attachedGeometry {
                text += " attachedPixels=\(attachedGeometry.width)x\(attachedGeometry.height)"
                    + " attachedOrientation=\(attachedGeometry.orientation)"
            }
            if let sourceGeometry, let attachedGeometry {
                let scaleX = Double(attachedGeometry.displayWidth) / Double(sourceGeometry.displayWidth)
                let scaleY = Double(attachedGeometry.displayHeight) / Double(sourceGeometry.displayHeight)
                let locale = Locale(identifier: "en_US_POSIX")
                text += " scaleX=\(String(format: "%.6g", locale: locale, scaleX))"
                    + " scaleY=\(String(format: "%.6g", locale: locale, scaleY))"
            }
            return text
        }
    }

    private static func pixelGeometry(in data: Data) -> PixelGeometry? {
#if canImport(ImageIO)
        guard let source = CGImageSourceCreateWithData(data as CFData,
                    [kCGImageSourceShouldCache: false] as CFDictionary),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
              let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue,
              width > 0, height > 0 else { return nil }
        let orientation = (properties[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1
        guard (1...8).contains(orientation) else { return nil }
        return PixelGeometry(width: width, height: height, orientation: orientation)
#else
        return nil
#endif
    }

    public static func load(_ reference: ToolArtifactReference, root: URL) throws -> Self {
        let components = reference.relativePath.split(separator: "/", omittingEmptySubsequences: false)
        guard components.count >= 2,
              let namespace = components.first, namespaces.contains(String(namespace)),
              components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }),
              !reference.relativePath.contains("\\"), !reference.relativePath.contains("\0"),
              reference.byteCount > 0, reference.byteCount <= maximumStoredImageBytes,
              let mime = ProviderImageEvidencePolicy.canonicalMIMEType(reference.mimeType)
        else { throw FloeError.validationFailed("The image artifact has an unsupported identity, type, or size.") }

        let canonicalRoot = root.standardizedFileURL.resolvingSymlinksInPath()
        let candidate = canonicalRoot.appendingPathComponent(reference.relativePath).standardizedFileURL
        let prefix = canonicalRoot.path.hasSuffix("/") ? canonicalRoot.path : canonicalRoot.path + "/"
        guard candidate.path.hasPrefix(prefix),
              candidate.resolvingSymlinksInPath() == candidate else {
            throw FloeError.validationFailed("The image artifact is outside its retained storage.")
        }
        let attributes = try FileManager.default.attributesOfItem(atPath: candidate.path)
        guard attributes[.type] as? FileAttributeType == .typeRegular,
              (attributes[.size] as? NSNumber)?.intValue == reference.byteCount else {
            throw FloeError.validationFailed("The retained image size does not match its receipt.")
        }
        let bytes = try Data(floeContentsOf: candidate, options: [.mappedIfSafe])
        guard bytes.count == reference.byteCount,
              ProviderImageEvidencePolicy.sniffedMIME(bytes) == mime,
              FloeDigest.sha256Hex(bytes) == reference.sha256.lowercased() else {
            throw FloeError.validationFailed("The retained image does not match its type or digest.")
        }
        return Self(reference: reference, fileURL: candidate, mimeType: mime, data: bytes)
    }

    /// Original images remain shareable. Opaque CAD captures may use a smaller
    /// same-size JPEG for transport; oversized images use a bounded thumbnail.
    /// Either derived representation carries its own digest and geometry.
    public func providerDelivery(byteLimit: Int = ProviderImageEvidencePolicy.maximumImageBytes) throws -> Delivery {
        guard byteLimit > 0 else {
            throw FloeError.validationFailed("The visual evidence budget is exhausted.")
        }
        let originalGeometry = Self.pixelGeometry(in: data)
#if canImport(ImageIO)
        if let delivery = sameSizeCADDelivery(byteLimit: byteLimit, geometry: originalGeometry) {
            return delivery
        }
#endif
        if data.count <= byteLimit {
            return Delivery(data: data, mimeType: mimeType, sourceSHA256: reference.sha256.lowercased(),
                            attachedSHA256: reference.sha256.lowercased(), isPreview: false,
                            sourceGeometry: originalGeometry, attachedGeometry: originalGeometry)
        }
#if canImport(ImageIO)
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary) else {
            throw FloeError.validationFailed("The original image could not be decoded for a preview.")
        }
        for dimension in [2048, 1024, 512] {
            let options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: dimension,
                kCGImageSourceShouldCacheImmediately: true
            ]
            guard let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { continue }
            let output = NSMutableData()
            guard let destination = CGImageDestinationCreateWithData(output, "public.jpeg" as CFString, 1, nil) else { continue }
            CGImageDestinationAddImage(destination, thumbnail, [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary)
            guard CGImageDestinationFinalize(destination) else { continue }
            let bytes = output as Data
            if !bytes.isEmpty, bytes.count <= byteLimit {
                return Delivery(data: bytes, mimeType: "image/jpeg", sourceSHA256: reference.sha256.lowercased(),
                                attachedSHA256: FloeDigest.sha256Hex(bytes), isPreview: true,
                                sourceGeometry: originalGeometry,
                                attachedGeometry: PixelGeometry(width: thumbnail.width,
                                                                height: thumbnail.height, orientation: 1))
            }
        }
#endif
        throw FloeError.validationFailed("The original image was retained, but no preview fits the visual evidence budget.")
    }

#if canImport(ImageIO)
    /// Limit this optimization to retained viewport captures, never user images,
    /// QR codes, generated artwork or animation frames. A PNG with transparency
    /// or orientation metadata keeps the original representation.
    private func sameSizeCADDelivery(byteLimit: Int, geometry: PixelGeometry?) -> Delivery? {
        guard reference.relativePath.hasPrefix("CADViewportArtifacts/"),
              mimeType == "image/png", data.count >= 64 * 1_024,
              let geometry, geometry.orientation == 1,
              geometry.width <= 4_096, geometry.height <= 4_096,
              geometry.width * geometry.height <= 4_194_304,
              let source = CGImageSourceCreateWithData(data as CFData,
                    [kCGImageSourceShouldCache: false] as CFDictionary),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
              image.width == geometry.width, image.height == geometry.height,
              Self.isOpaque(image) else { return nil }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, "public.jpeg" as CFString, 1, nil) else {
            return nil
        }
        CGImageDestinationAddImage(destination, image, [
            kCGImageDestinationLossyCompressionQuality: 0.90,
            kCGImagePropertyOrientation: 1
        ] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        let bytes = output as Data
        guard !bytes.isEmpty, bytes.count < data.count, bytes.count <= byteLimit,
              ProviderImageEvidencePolicy.sniffedMIME(bytes) == "image/jpeg",
              Self.pixelGeometry(in: bytes) == geometry,
              let verification = CGImageSourceCreateWithData(bytes as CFData, nil),
              let decoded = CGImageSourceCreateImageAtIndex(verification, 0, nil),
              decoded.width == image.width, decoded.height == image.height else { return nil }
        return Delivery(data: bytes, mimeType: "image/jpeg",
                        sourceSHA256: reference.sha256.lowercased(),
                        attachedSHA256: FloeDigest.sha256Hex(bytes), isPreview: true,
                        sourceGeometry: geometry, attachedGeometry: geometry)
    }

    private static func isOpaque(_ image: CGImage) -> Bool {
        switch image.alphaInfo {
        case .none, .noneSkipFirst, .noneSkipLast: return true
        case .alphaOnly: return false
        default: break
        }
        // ImageIO can report an alpha channel for an otherwise opaque CAD
        // render. Check actual pixels instead of discarding that channel or
        // inventing a background for genuinely transparent captures.
        guard let context = CGContext(data: nil, width: image.width, height: image.height,
                bitsPerComponent: 8, bytesPerRow: image.width * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                    | CGBitmapInfo.byteOrder32Big.rawValue),
              let pixels = context.data else { return false }
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        let bytes = pixels.assumingMemoryBound(to: UInt8.self)
        for offset in stride(from: 3, to: context.bytesPerRow * image.height, by: 4) {
            if bytes[offset] != 255 { return false }
        }
        return true
    }
#endif
}
