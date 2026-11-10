// SPDX-License-Identifier: MPL-2.0
import Foundation
import CoreGraphics
import CoreImage
import ImageIO

public struct MediaVideoColorFrameRequest: Sendable {
    public var assetID: UUID
    public var assetRevision: UInt64
    public var url: URL
    public var kind: MediaAssetKind
    public var expectedContentHash: String?
    public var sourceSeconds: Double
    public var grade: MediaVideoGrade?
    public var chromaKey: MediaVideoChromaKey?
    public var mask: ImageSelection?
    public var stabilization: MediaVideoStabilization?
    public init(assetID: UUID,assetRevision: UInt64,url: URL,kind: MediaAssetKind,expectedContentHash: String?,
                sourceSeconds: Double,grade: MediaVideoGrade? = nil,chromaKey: MediaVideoChromaKey? = nil,
                mask: ImageSelection? = nil,stabilization: MediaVideoStabilization? = nil) {
        self.assetID = assetID;self.assetRevision = assetRevision;self.url = url;self.kind = kind
        self.expectedContentHash = expectedContentHash;self.sourceSeconds = sourceSeconds;self.grade = grade
        self.chromaKey = chromaKey;self.mask = mask;self.stabilization = stabilization
    }
}
public struct MediaVideoColorFrameSample: Sendable {
    public let frame: MediaVideoColorMatchFrame
    public let previewPNG: Data
}
public actor MediaVideoColorMatchService {
    public static let shared = MediaVideoColorMatchService()
    private let context = CIContext(options: [.workingColorSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
        .outputColorSpace: CGColorSpace(name: CGColorSpace.sRGB)!, .cacheIntermediates: false])
    private struct FileStamp: Hashable { let bytes: Int64;let modified: Date;let inode: UInt64 }
    private var verifiedFiles: [URL:(stamp: FileStamp,hash: String)] = [:]
    public init() {}

    private func fileStamp(_ url: URL) throws -> FileStamp {
        let a = try FileManager.default.attributesOfItem(atPath: url.path)
        guard a[.type] as? FileAttributeType == .typeRegular, let size = a[.size] as? NSNumber,
              let modified = a[.modificationDate] as? Date, let inode = a[.systemFileNumber] as? NSNumber else {
            throw MediaPreparedCoreError.invalidOperation("the color reference source is unavailable")
        }
        return .init(bytes: size.int64Value,modified: modified,inode: inode.uint64Value)
    }
    private func observedHash(_ url: URL,cancellation: PreparedVideoCancellation) async throws -> (stamp: FileStamp,hash: String) {
        let stamp = try fileStamp(url)
        if let cached = verifiedFiles[url],cached.stamp == stamp { return cached }
        let hash = try await MediaVideoMotionService.shared.contentHash(url,cancellation: cancellation)
        guard try fileStamp(url) == stamp else { throw MediaPreparedCoreError.documentChanged }
        if verifiedFiles.count >= 64 { verifiedFiles.removeAll(keepingCapacity: true) }
        let result = (stamp: stamp,hash: hash);verifiedFiles[url] = result;return result
    }

    public func sample(_ request: MediaVideoColorFrameRequest, cancellation: PreparedVideoCancellation = .none) async throws -> MediaVideoColorFrameSample {
        guard request.url.isFileURL, request.sourceSeconds.isFinite, request.sourceSeconds >= 0 else {
            throw MediaPreparedCoreError.invalidOperation("choose a valid local source frame")
        }
        try cancellation.check();try Task.checkCancellation()
        let observed = try await observedHash(request.url,cancellation: cancellation), hash = observed.hash
        if let expected = request.expectedContentHash, expected != hash { throw MediaPreparedCoreError.documentChanged }
        let original: CGImage
        switch request.kind {
        case .video:
            original = try await MediaVideoMotionService.shared.sourcePreview(url: request.url,sourceSeconds: request.sourceSeconds,maximumPixelSize: 512).image
        case .image:
            guard request.sourceSeconds == 0,
                  let source = CGImageSourceCreateWithURL(request.url as CFURL,nil),
                  let image = CGImageSourceCreateThumbnailAtIndex(source,0,[kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceCreateThumbnailWithTransform: false,kCGImageSourceThumbnailMaxPixelSize: 512,
                    kCGImageSourceShouldCacheImmediately: true] as CFDictionary) else {
                throw MediaPreparedCoreError.invalidOperation("the reference image cannot be read")
            }
            original = image
        case .audio: throw MediaPreparedCoreError.invalidOperation("color matching requires an image or video source")
        }
        try cancellation.check();try Task.checkCancellation()
        let input = CIImage(cgImage: original)
        var graded = input
        if let stabilization = request.stabilization {
            guard stabilization.source.assetID == request.assetID, stabilization.source.assetRevision == request.assetRevision,
                  stabilization.source.contentHash == hash else { throw MediaPreparedCoreError.documentChanged }
            graded = try stabilization.apply(to: graded,sourceSeconds: request.sourceSeconds)
        }
        if let key = request.chromaKey {
            graded = graded.applyingFilter("CIColorCube",parameters: ["inputCubeDimension":32,"inputCubeData":try key.cubeData()])
        }
        if let match = request.grade?.colorMatch {
            guard match.target.assetID == request.assetID, match.target.assetRevision == request.assetRevision,
                  match.target.contentHash == hash else { throw MediaPreparedCoreError.documentChanged }
        }
        graded = try request.grade?.apply(to: graded) ?? graded
        if let mask = request.mask {
            guard let alpha = ImageSelectionRasterizer.maskImage(for: mask,canvas: input.extent.size) else {
                throw MediaPreparedCoreError.invalidOperation("the source mask cannot be sampled")
            }
            graded = graded.applyingFilter("CIBlendWithAlphaMask",parameters: [kCIInputMaskImageKey:alpha,
                kCIInputBackgroundImageKey:CIImage(color: .clear).cropped(to: input.extent)])
        }
        guard let image = context.createCGImage(graded,from: input.extent,format: .RGBA8,colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!),
              let png = WorkbenchPNG.encode(image) else { throw PreparedVideoError.renderFailed("could not sample graded source colors") }
        let moments = try MediaLabColorMath.moments(image)
        guard try fileStamp(request.url) == observed.stamp else {
            throw MediaPreparedCoreError.documentChanged
        }
        try cancellation.check();try Task.checkCancellation()
        return .init(frame: .init(assetID: request.assetID,assetRevision: request.assetRevision,contentHash: hash,
                                 sourceSeconds: request.sourceSeconds,moments: moments),previewPNG: png)
    }
    public func match(target: MediaVideoColorFrameRequest,reference: MediaVideoColorFrameRequest,referenceClipID: UUID,
                      mix: Double = 1,matchesContrast: Bool = true,
                      cancellation: PreparedVideoCancellation = .none) async throws -> MediaVideoColorMatch {
        guard mix.isFinite,(0...1).contains(mix) else { throw MediaPreparedCoreError.invalidOperation("color match strength must be in 0...1") }
        let a = try await sample(target,cancellation: cancellation), b = try await sample(reference,cancellation: cancellation)
        guard try await MediaVideoMotionService.shared.contentHash(target.url,cancellation: cancellation) == a.frame.contentHash,
              try await MediaVideoMotionService.shared.contentHash(reference.url,cancellation: cancellation) == b.frame.contentHash else {
            throw MediaPreparedCoreError.documentChanged
        }
        let value = MediaVideoColorMatch(target: a.frame,reference: b.frame,referenceClipID: referenceClipID,mix: mix,matchesContrast: matchesContrast)
        try value.validate();return value
    }
}
