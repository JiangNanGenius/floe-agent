// SPDX-License-Identifier: MPL-2.0
#if canImport(UIKit)
import Foundation
import CryptoKit
import ImageIO
import UIKit
import UniformTypeIdentifiers
import FloeCanvasCore
import FloeCanvasIntegration

/// Canvas originals own their imported bytes. A locator from an imported
/// document cannot select another directory or fetch an arbitrary URL.
actor CanvasHostAssets: CanvasAssetStore, CanvasPreviewProviding, CanvasResourceLeasing {
    let root: URL
    private var leases: [UUID: CanvasFileLease] = [:]
    private let maximumBytes = 64 * 1_024 * 1_024

    init(root: URL) throws {
        self.root = root.standardizedFileURL.resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: self.root, withIntermediateDirectories: true)
    }

    func bytes(for locator: CanvasAssetLocator) async throws -> Data {
        let file = try resolve(locator)
        guard file.bytes <= maximumBytes else { throw CanvasHostError.assetTooLarge }
        return try Data(contentsOf: file.url, options: .mappedIfSafe)
    }

    func store(_ bytes: Data, preferredID: UUID?) throws -> CanvasAssetLocator {
        guard bytes.count <= maximumBytes else { throw CanvasHostError.assetTooLarge }
        let hash = Self.hash(bytes)
        let id = preferredID ?? UUID()
        let path = id.uuidString.lowercased() + ".asset"
        let destination = root.appendingPathComponent(path)
        if FileManager.default.fileExists(atPath: destination.path) {
            guard Self.hash(try Data(contentsOf: destination)) == hash else { throw PersonalContentError.changedDocument }
        } else { try bytes.write(to: destination, options: [.atomic, .completeFileProtectionUnlessOpen]) }
        let locator = CanvasAssetLocator(id: id, contentHash: hash, relativePath: path, byteCount: Int64(bytes.count))
        try saveLocator(locator)
        return locator
    }

    /// File-backed import supports long audio/video without assembling it in RAM.
    func importFile(_ source: URL) throws -> CanvasAssetLocator {
        let access = source.startAccessingSecurityScopedResource()
        defer { if access { source.stopAccessingSecurityScopedResource() } }
        let properties = try source.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey])
        guard properties.isRegularFile == true, properties.isSymbolicLink != true,
              let bytes = properties.fileSize, bytes <= 2_147_483_648 else { throw CanvasHostError.assetTooLarge }
        let id = UUID()
        let ext = source.pathExtension.lowercased()
        let safeExtension = ext.range(of: "^[a-z0-9]{1,16}$", options: .regularExpression) != nil ? ext : "asset"
        let name = id.uuidString.lowercased() + "." + safeExtension
        let staged = root.appendingPathComponent(".import-" + id.uuidString)
        let destination = root.appendingPathComponent(name)
        defer { try? FileManager.default.removeItem(at: staged) }
        try FileManager.default.copyItem(at: source, to: staged)
        try Task.checkCancellation()
        let digest = try Self.hashFile(staged)
        try FileManager.default.moveItem(at: staged, to: destination)
        let locator = CanvasAssetLocator(id: id, contentHash: digest, relativePath: name,
            mimeType: UTType(filenameExtension: safeExtension)?.preferredMIMEType, byteCount: Int64(bytes))
        try saveLocator(locator)
        return locator
    }

    func resolve(_ locator: CanvasAssetLocator) throws -> (url: URL, bytes: Int) {
        let locator = try registered(locator)
        guard let path = locator.relativePath, !path.isEmpty, !path.hasPrefix("/"),
              !path.split(separator: "/").contains(".."), !path.contains("\\"), !path.contains("\0") else {
            throw PersonalContentError.outsideLibrary
        }
        let url = root.appendingPathComponent(path).standardizedFileURL.resolvingSymlinksInPath()
        guard url.path.hasPrefix(root.path + "/") else { throw PersonalContentError.outsideLibrary }
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey, .isSymbolicLinkKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true, let size = values.fileSize else {
            throw PersonalContentError.missingDocument
        }
        return (url, size)
    }

    /// PDF/formula content carries only an asset ID. Its byte location is
    /// resolved from the host's import receipt, never guessed from a path.
    private func registered(_ locator: CanvasAssetLocator) throws -> CanvasAssetLocator {
        let metadata = root.appendingPathComponent(locator.id.uuidString.lowercased() + ".locator.json")
        guard FileManager.default.fileExists(atPath: metadata.path) else { return locator }
        let data = try Data(contentsOf: metadata)
        guard data.count <= 16_384 else { throw PersonalContentError.invalidProject }
        let saved = try JSONDecoder().decode(CanvasAssetLocator.self, from: data)
        guard saved.id == locator.id,
              locator.contentHash == nil || saved.contentHash == locator.contentHash,
              locator.relativePath == nil || saved.relativePath == locator.relativePath else { throw PersonalContentError.changedDocument }
        return saved
    }
    private func saveLocator(_ locator: CanvasAssetLocator) throws {
        try JSONEncoder().encode(locator).write(to: root.appendingPathComponent(locator.id.uuidString.lowercased() + ".locator.json"),
            options: [.atomic, .completeFileProtectionUnlessOpen])
    }

    func preview(_ request: CanvasPreviewRequest, cancellation token: CanvasCancellationToken?) async throws -> CanvasPreviewResult {
        try Task.checkCancellation()
        guard token?.isCancelled != true else { throw CancellationError() }
        let source = try resolve(request.locator)
        // The existing renderer owns PDFKitGate and its ObjC exception
        // boundary. PDFKit objects never escape into the asset actor.
        let image: CGImageSource?
        if source.url.pathExtension.lowercased() == "pdf" {
            image = CGImageSourceCreateWithData(try OfficeSavedCoverRenderer.firstPageData(at: source.url) as CFData, nil)
        } else { image = CGImageSourceCreateWithURL(source.url as CFURL, nil) }
        guard let image,
              let thumbnail = CGImageSourceCreateThumbnailAtIndex(image, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: min(2_048, max(64, request.maxPixelSize))
              ] as CFDictionary) else { throw CanvasHostError.previewUnavailable }
        let bytes = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(bytes, UTType.png.identifier as CFString, 1, nil) else {
            throw CanvasHostError.previewUnavailable
        }
        CGImageDestinationAddImage(destination, thumbnail, nil)
        guard CGImageDestinationFinalize(destination), token?.isCancelled != true else { throw CanvasHostError.previewUnavailable }
        return .init(data: bytes as Data, mimeType: "image/png", pixelWidth: thumbnail.width,
            pixelHeight: thumbnail.height, isPlaceholder: false, sourceByteCount: Int64(source.bytes),
            cacheKey: (request.locator.contentHash ?? request.locator.id.uuidString) + "/\(request.maxPixelSize)")
    }

    func leaseFile(for locator: CanvasAssetLocator, leaseDuration: TimeInterval,
                   cancellation token: CanvasCancellationToken?) throws -> CanvasFileLease {
        guard token?.isCancelled != true else { throw CancellationError() }
        leases = leases.filter { ($0.value.expiresAt ?? .distantPast) > Date() }
        let file = try resolve(locator)
        let lease = CanvasFileLease(fileURL: file.url, byteCount: Int64(file.bytes), mimeType: locator.mimeType,
            isReadOnly: true, expiresAt: Date().addingTimeInterval(min(3_600, max(1, leaseDuration))))
        leases[lease.leaseID] = lease
        return lease
    }
    func releaseLease(_ leaseID: UUID) { leases[leaseID] = nil }

    nonisolated static func hash(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
    nonisolated static func hashFile(_ url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hash = SHA256()
        while let data = try handle.read(upToCount: 1_048_576), !data.isEmpty {
            try Task.checkCancellation(); hash.update(data: data)
        }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

enum CanvasHostError: LocalizedError {
    case assetTooLarge, previewUnavailable, executionUnavailable, staleRun, unsupportedStep(String)
    var errorDescription: String? {
        switch self {
        case .assetTooLarge: IDELanguageRunText.t("素材过大，请选择较小文件。", "This asset is too large. Choose a smaller file.")
        case .previewUnavailable: IDELanguageRunText.t("暂时无法生成预览，可打开原文件。", "A preview is unavailable. Open the original file.")
        case .executionUnavailable: IDELanguageRunText.t("请先为此任务选择可用的 Linux 环境。", "Select an available Linux environment for this task.")
        case .staleRun: IDELanguageRunText.t("画布或任务已更改，请重新运行。", "The canvas or task changed. Run it again.")
        case .unsupportedStep(let text): text
        }
    }
}
#endif
