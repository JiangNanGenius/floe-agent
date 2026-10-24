// FloeApp — Bounded bitmap previews of verified run-output snapshots.
// SPDX-License-Identifier: MPL-2.0

#if canImport(ImageIO) && canImport(UIKit)
import Foundation
import ImageIO
import UniformTypeIdentifiers
import Darwin
import FloeCore
import FloeModels
import FloeTools

struct RunOutputImagePreviewRequest: Sendable, Hashable {
    let receipt: RunOutputFile
    let context: RunOutputReceiptContext
    var artifactRoot: URL? = nil
}

/// Only bounded encoded bytes cross the worker boundary; ImageIO objects and
/// UIKit images stay on the actor/thread that creates them.
struct RunOutputImagePreview: Sendable {
    let request: RunOutputImagePreviewRequest
    let pngData: Data
    let pixelWidth: Int
    let pixelHeight: Int
    let sourceByteCount: Int
    let metadataByteCount: Int
}

enum RunOutputImagePreviewLoader {
    struct Limits: Sendable {
        var inputBytes = 16 * 1_024 * 1_024
        var sourcePixels = 40_000_000
        var sourceDimension = 16_384
        var metadataBytes = 256 * 1_024
        var thumbnailDimension = 1_024
        var thumbnailBytes = 4 * 1_024 * 1_024 + 65_536
    }

    static func load(_ request: RunOutputImagePreviewRequest,
                     limits: Limits = Limits()) async -> RunOutputImagePreview? {
        guard !Task.isCancelled else { return nil }
        let worker = Task.detached(priority: .utility) {
            autoreleasepool { decode(request, limits: limits) }
        }
        return await withTaskCancellationHandler {
            let result = await worker.value
            return Task.isCancelled ? nil : result
        } onCancel: {
            worker.cancel()
        }
    }

    private static func decode(_ request: RunOutputImagePreviewRequest,
                               limits: Limits) -> RunOutputImagePreview? {
        let receipt = request.receipt
        guard !Task.isCancelled,
              RunOutputReceiptGate.accepts(receipt, in: request.context),
              receipt.mimeType.lowercased().hasPrefix("image/"),
              receipt.byteCount > 0, receipt.byteCount <= limits.inputBytes,
              limits.thumbnailDimension > 0,
              case .verified(let url) = RunOutputSnapshotStore.verify(
                receipt, artifactRoot: request.artifactRoot),
              !Task.isCancelled,
              let data = readVerifiedBytes(url, receipt: receipt, limit: limits.inputBytes),
              !Task.isCancelled,
              let source = CGImageSourceCreateWithData(data as CFData, [
                kCGImageSourceShouldCache: false
              ] as CFDictionary),
              CGImageSourceGetStatus(source) == .statusComplete,
              (1...32).contains(CGImageSourceGetCount(source)),
              let typeID = CGImageSourceGetType(source),
              let type = UTType(typeID as String), type.conforms(to: .image),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any],
              let width = properties[kCGImagePropertyPixelWidth as String] as? Int,
              let height = properties[kCGImagePropertyPixelHeight as String] as? Int,
              width > 0, height > 0,
              width <= limits.sourceDimension, height <= limits.sourceDimension,
              // Division avoids overflow on a hostile dimension product.
              width <= limits.sourcePixels / height else { return nil }

        // Bound both container and frame metadata before pixel decoding. The
        // input byte cap also bounds the parser's initial metadata input.
        let metadata: [String: Any] = [
            "container": CGImageSourceCopyProperties(source, nil) as? [String: Any] ?? [:],
            "frame": properties
        ]
        guard let metadataData = try? PropertyListSerialization.data(
            fromPropertyList: metadata, format: .binary, options: 0),
              metadataData.count <= limits.metadataBytes, !Task.isCancelled,
              let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: limits.thumbnailDimension,
                kCGImageSourceShouldCacheImmediately: true
              ] as CFDictionary),
              thumbnail.width > 0, thumbnail.height > 0,
              max(thumbnail.width, thumbnail.height) <= limits.thumbnailDimension,
              !Task.isCancelled else { return nil }

        let encoded = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            encoded, UTType.png.identifier as CFString, 1, nil) else { return nil }
        // Re-encoding drops source metadata and retains only the small bitmap.
        CGImageDestinationAddImage(destination, thumbnail, nil)
        guard CGImageDestinationFinalize(destination),
              encoded.length <= limits.thumbnailBytes, !Task.isCancelled else { return nil }
        return RunOutputImagePreview(
            request: request, pngData: encoded as Data,
            pixelWidth: thumbnail.width, pixelHeight: thumbnail.height,
            sourceByteCount: data.count, metadataByteCount: metadataData.count)
    }

    /// Recheck the exact bytes handed to ImageIO, closing the interval between
    /// store verification and reading. A replaced leaf must still be a plain,
    /// single-link file and match the receipt; no mmap or unbounded read.
    private static func readVerifiedBytes(_ url: URL, receipt: RunOutputFile,
                                          limit: Int) -> Data? {
        let descriptor = open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard descriptor >= 0 else { return nil }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close() }
        var info = stat()
        guard fstat(descriptor, &info) == 0,
              (info.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG),
              info.st_nlink == 1, info.st_size == receipt.byteCount else { return nil }
        var bytes = Data()
        do {
            while !Task.isCancelled {
                guard let part = try handle.read(upToCount: min(65_536, limit - bytes.count + 1)),
                      !part.isEmpty else { break }
                bytes.append(part)
                guard bytes.count <= limit else { return nil }
            }
        } catch { return nil }
        guard !Task.isCancelled, bytes.count == receipt.byteCount,
              FloeDigest.sha256Hex(bytes) == receipt.sha256 else { return nil }
        return bytes
    }
}
#endif
