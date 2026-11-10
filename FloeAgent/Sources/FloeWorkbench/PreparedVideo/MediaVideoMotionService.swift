// SPDX-License-Identifier: MPL-2.0
import Foundation
import AVFoundation
import CoreGraphics
import Crypto

public struct MediaVideoMotionRequest: Sendable {
    public var assetID: UUID
    public var assetRevision: UInt64
    public var expectedContentHash: String?
    public var startSeconds: Double
    public var durationSeconds: Double
    public var sampleRate: Double
    public init(assetID: UUID, assetRevision: UInt64, expectedContentHash: String?,
                startSeconds: Double, durationSeconds: Double, sampleRate: Double = 15) {
        self.assetID = assetID; self.assetRevision = assetRevision; self.expectedContentHash = expectedContentHash
        self.startSeconds = startSeconds; self.durationSeconds = durationSeconds; self.sampleRate = sampleRate
    }
}

/// The image is immutable; no AVFoundation/Vision object crosses the actor.
public struct MediaVideoMotionPreview: @unchecked Sendable {
    public let image: CGImage
    public let sourceSeconds: Double
}

public struct MediaVideoMotionFrameBytes: Sendable {
    public let pngData: Data
    public let contentHash: String
    public let width: Int
    public let height: Int
    public let requestedSeconds: Double
    public let actualSeconds: Double
}

/// A bounded, streaming decoder: at most two analysis frames are retained.
/// Source bytes are verified before/after analysis; it never writes assets.
public actor MediaVideoMotionService {
    public static let shared = MediaVideoMotionService()
    public init() {}

    public func contentHash(_ url: URL, cancellation: PreparedVideoCancellation = .none) throws -> String {
        guard url.isFileURL else { throw MediaPreparedCoreError.invalidOperation("motion analysis requires a local source") }
        let file = try FileHandle(forReadingFrom: url); defer { try? file.close() }
        var hash = SHA256(), bytes: Int64 = 0
        while let data = try file.read(upToCount: 1_048_576), !data.isEmpty {
            try cancellation.check(); try Task.checkCancellation()
            bytes += Int64(data.count)
            guard bytes <= 4_294_967_296 else { throw MediaPreparedCoreError.limitsExceeded("motion source exceeds 4 GiB") }
            hash.update(data: data)
        }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }
    public func sourcePreview(url: URL, sourceSeconds: Double, maximumPixelSize: Int = 960) async throws -> MediaVideoMotionPreview {
        guard url.isFileURL, sourceSeconds.isFinite, sourceSeconds >= 0, (64...1024).contains(maximumPixelSize) else { throw PreparedVideoError.invalidTime("invalid source preview") }
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.appliesPreferredTrackTransform = true; generator.maximumSize = CGSize(width: maximumPixelSize, height: maximumPixelSize)
        generator.requestedTimeToleranceBefore = .zero; generator.requestedTimeToleranceAfter = .zero
        let value = try await generator.image(at: CMTime(seconds: sourceSeconds, preferredTimescale: 90_000))
        try Task.checkCancellation()
        return .init(image: value.image, sourceSeconds: value.actualTime.seconds)
    }

    /// Read-only native observation for the existing run-owned image artifact
    /// publisher. The caller supplies its authorized asset URL and range.
    public func inspectSource(url: URL, sourceSeconds: Double, maximumPixelSize: Int,
                              expectedContentHash: String?, cancellation: PreparedVideoCancellation = .none) async throws -> MediaVideoMotionFrameBytes {
        let hash = try contentHash(url, cancellation: cancellation)
        guard expectedContentHash == nil || expectedContentHash == hash else { throw MediaPreparedCoreError.documentChanged }
        let preview = try await sourcePreview(url: url, sourceSeconds: sourceSeconds, maximumPixelSize: maximumPixelSize)
        try cancellation.check(); try Task.checkCancellation()
        guard try contentHash(url, cancellation: cancellation) == hash, let data = WorkbenchPNG.encode(preview.image) else {
            throw MediaPreparedCoreError.documentChanged
        }
        return .init(pngData: data, contentHash: hash, width: preview.image.width, height: preview.image.height,
            requestedSeconds: sourceSeconds, actualSeconds: preview.sourceSeconds)
    }

    public func track(url: URL, request: MediaVideoMotionRequest, region: NormalizedRect,
                      minimumConfidence: Double = 0.3, cancellation: PreparedVideoCancellation = .none,
                      progress: @Sendable (Double) -> Void = { _ in }) async throws -> MediaVideoTracking {
        let setup = try await prepare(url: url, request: request, cancellation: cancellation)
        let tracker = try MediaVideoObjectTracker(region: region, minimumConfidence: minimumConfidence)
        var samples: [MediaVideoTrackingSample] = []
        for (index, seconds) in setup.times.enumerated() {
            try cancellation.check(); try Task.checkCancellation()
            let result = try await sourcePreview(url: url, sourceSeconds: seconds)
            samples.append(try autoreleasepool { try tracker.consume(result.image, sourceSeconds: seconds,
                last: index == setup.times.count-1, cancellation: cancellation) })
            progress(Double(index+1)/Double(setup.times.count))
        }
        guard try contentHash(url, cancellation: cancellation) == setup.source.contentHash else { throw MediaPreparedCoreError.documentChanged }
        let result = MediaVideoTracking(source: setup.source, minimumConfidence: minimumConfidence, samples: samples)
        try result.validate(); return result
    }
    public func stabilize(url: URL, request: MediaVideoMotionRequest, smoothingSeconds: Double = 0.3,
                          strength: Double = 1, cropEdges: Bool = true,
                          cancellation: PreparedVideoCancellation = .none,
                          progress: @Sendable (Double) -> Void = { _ in }) async throws -> MediaVideoStabilization {
        guard smoothingSeconds.isFinite, (0.05...2).contains(smoothingSeconds), strength.isFinite, (0...1).contains(strength) else {
            throw MediaPreparedCoreError.invalidOperation("invalid stabilization controls")
        }
        let setup = try await prepare(url: url, request: request, cancellation: cancellation)
        let tracker = MediaVideoTranslationTracker()
        var samples: [MediaVideoStabilizationSample] = []
        for (index, seconds) in setup.times.enumerated() {
            try cancellation.check(); try Task.checkCancellation()
            let result = try await sourcePreview(url: url, sourceSeconds: seconds)
            samples.append(try autoreleasepool { try tracker.consume(result.image, sourceSeconds: seconds, cancellation: cancellation) })
            progress(Double(index+1)/Double(setup.times.count))
        }
        guard try contentHash(url, cancellation: cancellation) == setup.source.contentHash else { throw MediaPreparedCoreError.documentChanged }
        return try MediaVideoMotionMath.stabilize(source: setup.source, measured: samples,
            smoothingSeconds: smoothingSeconds, strength: strength, cropEdges: cropEdges)
    }
    private struct Setup {
        var source: MediaVideoMotionSource
        var times: [Double]
    }
    private func prepare(url: URL, request: MediaVideoMotionRequest, cancellation: PreparedVideoCancellation) async throws -> Setup {
        guard url.isFileURL, request.sampleRate.isFinite, (1...30).contains(request.sampleRate),
              request.startSeconds.isFinite, request.startSeconds >= 0,
              request.durationSeconds.isFinite, (0.05...120).contains(request.durationSeconds) else {
            throw MediaPreparedCoreError.invalidOperation("analyze a local video interval up to two minutes, sampled at 1–30 fps")
        }
        try cancellation.check(); try Task.checkCancellation()
        let hash = try contentHash(url, cancellation: cancellation)
        if let expected = request.expectedContentHash, expected != hash { throw MediaPreparedCoreError.documentChanged }
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else {
            throw MediaPreparedCoreError.invalidOperation("select a video clip for motion analysis")
        }
        let duration = try await asset.load(.duration).seconds
        guard duration.isFinite, request.startSeconds+request.durationSeconds <= duration+0.0001 else {
            throw MediaPreparedCoreError.invalidOperation("motion interval exceeds the actual video duration")
        }
        let size = try await track.load(.naturalSize), transform = try await track.load(.preferredTransform)
        let rect = CGRect(origin: .zero, size: size).applying(transform)
        let fps = Double(try await track.load(.nominalFrameRate))
        guard fps.isFinite, fps >= 1, fps <= 240, rect.width.isFinite, rect.height.isFinite,
              (1...16384).contains(abs(rect.width)), (1...16384).contains(abs(rect.height)) else {
            throw MediaPreparedCoreError.invalidOperation("video frame geometry is unavailable")
        }
        let source = MediaVideoMotionSource(assetID: request.assetID, assetRevision: request.assetRevision,
            contentHash: hash, startSeconds: request.startSeconds, durationSeconds: request.durationSeconds,
            frameDuration: 1/fps, width: Int(abs(rect.width).rounded()), height: Int(abs(rect.height).rounded()))
        try source.validate()
        let last = source.endSeconds-source.frameDuration, step = 1/min(fps,request.sampleRate)
        var times: [Double] = [], value = source.startSeconds
        while value < last-0.00001 { times.append(value); value += step }
        times.append(last)
        guard (2...3600).contains(times.count) else { throw MediaPreparedCoreError.limitsExceeded("motion analysis needs 2–3600 frames") }
        return .init(source: source, times: times)
    }
}
