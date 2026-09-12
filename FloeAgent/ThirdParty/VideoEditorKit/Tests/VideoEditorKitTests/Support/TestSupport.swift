@preconcurrency import AVFoundation
import CoreGraphics
import CoreVideo
import Foundation
import SwiftUI

@testable import VideoEditorKit

enum TestFixtureError: Error {

    // MARK: - Public Properties

    case unableToCreatePixelBuffer
    case unableToCreateContext
    case unableToCreateCompositionTrack
    case unableToCreateExportSession
    case failedToAppendFrame
    case failedToFinishWriting

}

enum TestFixtures {

    typealias VideoFrameDrawer = @Sendable (CGContext, CGSize, Int) -> Void

    // MARK: - Public Methods

    static func temporaryURL(fileExtension: String) -> URL {
        let url = URL.temporaryDirectory.appending(
            path: "VideoEditorTests-\(UUID().uuidString).\(fileExtension)"
        )
        FileManager.default.removeIfExists(for: url)
        return url
    }

    static func createTemporaryFile(
        fileExtension: String = "tmp",
        contents: Data = Data("fixture".utf8)
    ) throws -> URL {
        let url = temporaryURL(fileExtension: fileExtension)
        try contents.write(to: url)
        return url
    }

    static func createTemporaryAudio(
        duration: TimeInterval = 0.5,
        sampleRate: Double = 44_100
    ) throws -> URL {
        let url = temporaryURL(fileExtension: "m4a")
        let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1)
        let frameCount = AVAudioFrameCount(duration * sampleRate)

        guard let format else {
            throw TestFixtureError.unableToCreateContext
        }

        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else {
            throw TestFixtureError.unableToCreatePixelBuffer
        }

        buffer.frameLength = frameCount

        if let channelData = buffer.floatChannelData {
            channelData[0].update(repeating: 0, count: Int(frameCount))
        }

        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 1,
            AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue,
        ]

        let file = try AVAudioFile(forWriting: url, settings: settings)
        try file.write(from: buffer)
        return url
    }

    static func makeSolidImage(
        size: CGSize = CGSize(width: 40, height: 20),
        color: UIColor = .systemBlue,
        scale: CGFloat = 1
    ) -> UIImage {
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = scale

        let renderer = UIGraphicsImageRenderer(size: size, format: format)
        return renderer.image { context in
            color.setFill()
            context.fill(CGRect(origin: .zero, size: size))
        }
    }

    static func createTemporaryVideo(
        size: CGSize = CGSize(width: 48, height: 24),
        frameCount: Int = 30,
        framesPerSecond: Int32 = 30,
        color: UIColor = .systemRed,
        transform: CGAffineTransform = .identity,
        drawFrame: VideoFrameDrawer? = nil
    ) async throws -> URL {
        let outputURL = temporaryURL(fileExtension: "mp4")
        let writer = try AVAssetWriter(outputURL: outputURL, fileType: .mp4)
        let writerBox = UncheckedAssetWriterBox(writer)

        let outputSettings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: Int(size.width),
            AVVideoHeightKey: Int(size.height),
        ]

        let input = AVAssetWriterInput(mediaType: .video, outputSettings: outputSettings)
        input.transform = transform
        input.expectsMediaDataInRealTime = false

        let pixelBufferAttributes: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32ARGB,
            kCVPixelBufferWidthKey as String: Int(size.width),
            kCVPixelBufferHeightKey as String: Int(size.height),
        ]

        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: pixelBufferAttributes
        )

        writer.add(input)
        writer.startWriting()
        writer.startSession(atSourceTime: .zero)

        let resolvedFrameCount = max(frameCount, 1)

        for frameIndex in 0..<resolvedFrameCount {
            while !input.isReadyForMoreMediaData {
                try await Task.sleep(for: .milliseconds(10))
            }

            let pixelBuffer = try makePixelBuffer(
                size: size,
                color: color,
                frameIndex: frameIndex,
                drawFrame: drawFrame
            )
            let presentationTime = CMTime(
                value: CMTimeValue(frameIndex),
                timescale: framesPerSecond
            )

            guard adaptor.append(pixelBuffer, withPresentationTime: presentationTime) else {
                throw writer.error ?? TestFixtureError.failedToAppendFrame
            }
        }

        input.markAsFinished()

        try await withCheckedThrowingContinuation { continuation in
            writer.finishWriting {
                switch writerBox.writer.status {
                case .completed:
                    continuation.resume()
                case .failed, .cancelled:
                    continuation.resume(
                        throwing: writerBox.writer.error ?? TestFixtureError.failedToFinishWriting
                    )
                default:
                    continuation.resume(throwing: TestFixtureError.failedToFinishWriting)
                }
            }
        }

        return outputURL
    }

    static func createTemporaryVideoWithAudio(
        size: CGSize = CGSize(width: 48, height: 24),
        frameCount: Int = 30,
        framesPerSecond: Int32 = 30,
        color: UIColor = .systemRed,
        transform: CGAffineTransform = .identity,
        drawFrame: VideoFrameDrawer? = nil
    ) async throws -> URL {
        let resolvedFrameCount = max(frameCount, 1)
        let duration = TimeInterval(resolvedFrameCount) / TimeInterval(framesPerSecond)
        let videoURL = try await createTemporaryVideo(
            size: size,
            frameCount: resolvedFrameCount,
            framesPerSecond: framesPerSecond,
            color: color,
            transform: transform,
            drawFrame: drawFrame
        )
        let audioURL = try createTemporaryAudio(duration: duration)
        let outputURL = temporaryURL(fileExtension: "mp4")

        defer {
            FileManager.default.removeIfExists(for: videoURL)
            FileManager.default.removeIfExists(for: audioURL)
        }

        let videoAsset = AVURLAsset(url: videoURL)
        let audioAsset = AVURLAsset(url: audioURL)
        let composition = AVMutableComposition()
        let videoDuration = try await videoAsset.load(.duration)

        guard
            let sourceVideoTrack = try await videoAsset.loadTracks(withMediaType: .video).first,
            let compositionVideoTrack = composition.addMutableTrack(
                withMediaType: .video,
                preferredTrackID: kCMPersistentTrackID_Invalid
            )
        else {
            throw TestFixtureError.unableToCreateCompositionTrack
        }

        try compositionVideoTrack.insertTimeRange(
            CMTimeRange(start: .zero, duration: videoDuration),
            of: sourceVideoTrack,
            at: .zero
        )
        compositionVideoTrack.preferredTransform = try await sourceVideoTrack.load(.preferredTransform)

        guard
            let sourceAudioTrack = try await audioAsset.loadTracks(withMediaType: .audio).first,
            let compositionAudioTrack = composition.addMutableTrack(
                withMediaType: .audio,
                preferredTrackID: kCMPersistentTrackID_Invalid
            )
        else {
            throw TestFixtureError.unableToCreateCompositionTrack
        }

        try compositionAudioTrack.insertTimeRange(
            CMTimeRange(start: .zero, duration: videoDuration),
            of: sourceAudioTrack,
            at: .zero
        )

        guard
            let exportSession = AVAssetExportSession(
                asset: composition,
                presetName: AVAssetExportPresetHighestQuality
            )
        else {
            throw TestFixtureError.unableToCreateExportSession
        }

        exportSession.shouldOptimizeForNetworkUse = false

        try await exportSession.export(to: outputURL, as: .mp4)
        return outputURL
    }

    // MARK: - Private Methods

    private static func makePixelBuffer(
        size: CGSize,
        color: UIColor,
        frameIndex: Int,
        drawFrame: VideoFrameDrawer?
    ) throws -> CVPixelBuffer {
        var pixelBuffer: CVPixelBuffer?
        let attributes =
            [
                kCVPixelBufferCGImageCompatibilityKey: true,
                kCVPixelBufferCGBitmapContextCompatibilityKey: true,
            ] as CFDictionary

        let status = CVPixelBufferCreate(
            kCFAllocatorDefault,
            Int(size.width),
            Int(size.height),
            kCVPixelFormatType_32ARGB,
            attributes,
            &pixelBuffer
        )

        guard status == kCVReturnSuccess, let pixelBuffer else {
            throw TestFixtureError.unableToCreatePixelBuffer
        }

        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }

        guard
            let context = CGContext(
                data: CVPixelBufferGetBaseAddress(pixelBuffer),
                width: Int(size.width),
                height: Int(size.height),
                bitsPerComponent: 8,
                bytesPerRow: CVPixelBufferGetBytesPerRow(pixelBuffer),
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue
            )
        else {
            throw TestFixtureError.unableToCreateContext
        }

        if let drawFrame {
            drawFrame(context, size, frameIndex)
        } else {
            context.setFillColor(color.cgColor)
            context.fill(CGRect(origin: .zero, size: size))
        }

        return pixelBuffer
    }

}

private struct UncheckedAssetWriterBox: @unchecked Sendable {

    let writer: AVAssetWriter

    init(_ writer: AVAssetWriter) {
        self.writer = writer
    }

}
