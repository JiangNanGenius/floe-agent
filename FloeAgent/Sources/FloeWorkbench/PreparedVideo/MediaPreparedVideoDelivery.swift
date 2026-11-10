// SPDX-License-Identifier: MPL-2.0
import AVFoundation
import Foundation

/// Bounded segments use the same native frame/audio renderer as scrubbing.
/// Long output is stitched only after every segment is independently saved.
public actor MediaPreparedVideoDelivery {
    private let exporter = PreparedVideoExporter()
    public init() {}

    public func export(document: MediaPreparedDocument, assetURLs: [UUID: URL],
                       options: VideoExportOptions, destination: URL,
                       cancellation: PreparedVideoCancellation = .none,
                       progress: @escaping @Sendable (Double) -> Void = { _ in }) async throws -> WorkbenchVideoExportReceipt {
        let plan = try MediaPreparedVideoDocumentAdapter.resolve(document, assetURLs: assetURLs)
        guard abs(options.frameRate - Double(plan.frameRate.numerator) / Double(plan.frameRate.denominator)) < 0.0001 else {
            throw PreparedVideoError.unsupportedCapability("output frame rate must match the project")
        }
        let settings = try PreparedVideoOutputSettings(width: options.width, height: options.height,
            frameRate: plan.frameRate, codec: options.codec == .hevc ? .hevc : .h264, quality: options.quality,colorProfile: options.colorProfile ?? plan.colorProfile)
        let total = plan.frameRate.frameIndex(for: plan.duration, rounding: .up)
        guard total > 0, plan.duration.seconds <= 3600 else { throw PreparedVideoError.invalidPlan("output duration outside 0...3600 seconds") }
        let directory = destination.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let work = directory.appendingPathComponent(".media-segments-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: work) }
        let perSegment = max(1, Int64(20 * Double(plan.frameRate.numerator) / Double(plan.frameRate.denominator)))
        var urls: [URL] = []
        var first: Int64 = 0
        while first < total {
            try cancellation.check()
            let end = min(total, first + perSegment)
            let window = try PreparedVideoFrameWindow(startFrame: first, endFrame: end,
                frameRate: plan.frameRate, timescale: plan.timeScale)
            let url = work.appendingPathComponent("segment-\(urls.count).mp4")
            let completed = first
            _ = try await exporter.renderWindow(plan: plan, window: window, settings: settings,
                destination: url, overwrite: false, cancellation: cancellation) { value in
                    let fraction = Double(value.completed) / Double(max(1, value.total ?? value.completed))
                    progress((Double(completed) + Double(window.frameCount) * fraction) / Double(total) * 0.9)
                }
            urls.append(url); first = end
        }
        let staged = work.appendingPathComponent("final.mp4")
        let composition = AVMutableComposition()
        guard let video = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) else { throw PreparedVideoError.renderFailed("composition track") }
        var audio: AVMutableCompositionTrack?
        var cursor = CMTime.zero
        for url in urls {
            try cancellation.check()
            let asset = AVURLAsset(url: url)
            let duration = try await asset.load(.duration)
            guard let source = try await asset.loadTracks(withMediaType: .video).first else { throw PreparedVideoError.renderFailed("segment has no video") }
            try video.insertTimeRange(CMTimeRange(start: .zero, duration: duration), of: source, at: cursor)
            if let sound = try await asset.loadTracks(withMediaType: .audio).first {
                if audio == nil { audio = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) }
                try audio?.insertTimeRange(CMTimeRange(start: .zero, duration: duration), of: sound, at: cursor)
            }
            cursor = CMTimeAdd(cursor, duration)
        }
        guard let writer = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetPassthrough) else { throw PreparedVideoError.renderFailed("segment finalizer") }
        try await writer.export(to: staged, as: .mp4)
        try cancellation.check()
        let verified = AVURLAsset(url: staged)
        let duration = try await verified.load(.duration).seconds
        guard let track = try await verified.loadTracks(withMediaType: .video).first else { throw PreparedVideoError.renderFailed("final video missing") }
        let size = try await track.load(.naturalSize)
        if let profile = settings.colorProfile {
            guard let description = try await track.load(.formatDescriptions).first else { throw PreparedVideoError.renderFailed("final video color description missing") }
            try MediaVideoColorProfile.validateEncoded(profile,description: description)
        }
        guard abs(duration - plan.duration.seconds) <= 1 / options.frameRate + 0.01,
              Int(size.width) == options.width, Int(size.height) == options.height else { throw PreparedVideoError.renderFailed("final output metadata mismatch") }
        guard !FileManager.default.fileExists(atPath: destination.path) else { throw PreparedVideoError.renderFailed("output already exists") }
        try FileManager.default.moveItem(at: staged, to: destination)
        let bytes = try destination.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        progress(1)
        return WorkbenchVideoExportReceipt(url: destination, durationSeconds: duration, width: options.width,
            height: options.height, frameRate: options.frameRate, codec: options.codec.rawValue,
            hasAudio: audio != nil, byteCount: Int64(bytes))
    }
}
