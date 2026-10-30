// SPDX-License-Identifier: MPL-2.0
import Foundation
import FloeCore
import FloeModels
#if canImport(ImageIO)
import ImageIO
#endif

/// Shared storage boundary for image artifacts shown in chat or sent to a
/// model. A preview is derived evidence; it never replaces the retained file.
public struct VerifiedToolImageArtifact: Sendable {
    public static let maximumStoredImageBytes = 24 * 1_024 * 1_024
    public static let namespaces: Set<String> = [
        "BrowserArtifacts", "GeneratedImages", "VNCArtifacts",
        "CADViewportArtifacts", "CADAnimationFrames", "EngineeringObservations"
    ]

    public let reference: ToolArtifactReference
    public let fileURL: URL
    public let mimeType: String
    public let data: Data

    public struct Delivery: Sendable {
        public let data: Data
        public let mimeType: String
        public let sourceSHA256: String
        public let attachedSHA256: String
        public let isPreview: Bool

        public var receipt: String {
            "sourceSHA256=\(sourceSHA256) attachedSHA256=\(attachedSHA256) "
                + "bytes=\(data.count) representation=\(isPreview ? "derived-preview" : "original")"
        }
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

    /// Large original images remain shareable. Only the provider attachment
    /// becomes a bounded, separately hashed JPEG preview, decoded by ImageIO
    /// as a thumbnail rather than first allocating the full-size bitmap.
    public func providerDelivery(byteLimit: Int = ProviderImageEvidencePolicy.maximumImageBytes) throws -> Delivery {
        guard byteLimit > 0 else {
            throw FloeError.validationFailed("The visual evidence budget is exhausted.")
        }
        if data.count <= byteLimit {
            return Delivery(data: data, mimeType: mimeType, sourceSHA256: reference.sha256.lowercased(),
                            attachedSHA256: reference.sha256.lowercased(), isPreview: false)
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
                                attachedSHA256: FloeDigest.sha256Hex(bytes), isPreview: true)
            }
        }
#endif
        throw FloeError.validationFailed("The original image was retained, but no preview fits the visual evidence budget.")
    }
}
