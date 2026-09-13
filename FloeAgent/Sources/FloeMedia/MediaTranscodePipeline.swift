import Foundation
import FloeCore
import FloeTools
#if canImport(AVFoundation)
import AVFoundation

/// Reader/writer conversion with bounded sample queues. Only validated files reach the destination.
enum MediaTranscodePipeline {
    static func run(_ spec: MediaExportEngine.TranscodeSpec, input: URL, output: URL,
                    cancellation: CancellationToken?) async throws -> String {
        try cancellation?.throwIfCancelled()
        try Task.checkCancellation()
        guard input != output else { throw FloeError.validationFailed("Choose a separate output file") }
        let types: [String: AVFileType] = ["mp4": .mp4, "mov": .mov, "m4v": .m4v]
        guard let fileType = types[spec.container.lowercased()] else {
            throw FloeError.validationFailed("Video export supports mp4, mov and m4v")
        }
        for value in [spec.width, spec.height, spec.videoBitrate, spec.audioBitrate].compactMap({ $0 }) {
            guard value > 0 else { throw FloeError.validationFailed("Dimensions and bitrates must be positive") }
        }
        if let fps = spec.frameRate, !fps.isFinite || fps <= 0 || fps > 240 {
            throw FloeError.validationFailed("frameRate must be finite and in (0, 240]")
        }
        guard (spec.width == nil) == (spec.height == nil) else {
            throw FloeError.validationFailed("Provide both width and height")
        }
        guard [nil, "h264", "hevc"].contains(spec.videoCodec?.lowercased()),
              [nil, "aac"].contains(spec.audioCodec?.lowercased()) else {
            throw FloeError.validationFailed("Supported video codecs are h264 and hevc; audio codec is aac")
        }
        if spec.passthrough && (spec.videoCodec != nil || spec.audioCodec != nil || spec.width != nil ||
                               spec.frameRate != nil || spec.videoBitrate != nil || spec.audioBitrate != nil) {
            throw FloeError.validationFailed("Remux cannot change codecs, dimensions, frame rate or bitrates")
        }
        let asset = AVURLAsset(url: input)
        let videoTracks = try await asset.loadTracks(withMediaType: .video)
        guard let video = videoTracks.first else { throw FloeError.validationFailed("Input has no video track") }
        let duration = try await asset.load(.duration)
        guard duration.seconds.isFinite, duration.seconds > 0 else { throw FloeError.validationFailed("Input duration is invalid") }
        let temporary = output.deletingLastPathComponent().appendingPathComponent(".floe-export-\(UUID().uuidString).\(spec.container)")
        defer { try? FileManager.default.removeItem(at: temporary) }
        try FileManager.default.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
        if spec.passthrough {
            let outputType = fileType.rawValue
            // Construct AVFoundation state inside the export task; only its
            // Sendable handle crosses the custom cancellation watcher.
            let operation = Task {
                let exportAsset = AVURLAsset(url: input)
                let type = AVFileType(rawValue: outputType)
                guard let exporter = AVAssetExportSession(asset: exportAsset, presetName: AVAssetExportPresetPassthrough),
                      exporter.supportedFileTypes.contains(type) else {
                    throw FloeError.validationFailed("Input streams cannot be remuxed to this container")
                }
                try await exporter.export(to: temporary, as: type)
            }
            let watcher = Task {
                while !Task.isCancelled {
                    if cancellation?.isCancelled == true { operation.cancel(); return }
                    do { try await Task.sleep(for: .milliseconds(50)) } catch { return }
                }
            }
            defer { watcher.cancel() }
            try await withTaskCancellationHandler { try await operation.value } onCancel: { operation.cancel() }

        } else {
            let natural = try await video.load(.naturalSize)
            let transform = try await video.load(.preferredTransform)
            let displayed = CGRect(origin: .zero, size: natural).applying(transform)
            let width = spec.width ?? Int(abs(displayed.width).rounded())
            let height = spec.height ?? Int(abs(displayed.height).rounded())
            guard width > 0, height > 0, width <= 8192, height <= 8192, width % 2 == 0, height % 2 == 0 else {
                throw FloeError.validationFailed("Encoded dimensions must be even and between 2 and 8192")
            }
            let sourceFPS = Double(try await video.load(.nominalFrameRate))
            let fps = spec.frameRate ?? (sourceFPS > 0 ? sourceFPS : 30)
            let reader = try AVAssetReader(asset: asset)
            let writer = try AVAssetWriter(outputURL: temporary, fileType: fileType)
            let composition = AVMutableVideoComposition()
            composition.renderSize = CGSize(width: width, height: height)
            composition.frameDuration = CMTime(seconds: 1 / fps, preferredTimescale: 600_000)
            let instruction = AVMutableVideoCompositionInstruction()
            instruction.timeRange = CMTimeRange(start: .zero, duration: duration)
            let layer = AVMutableVideoCompositionLayerInstruction(assetTrack: video)
            let normalized = transform.concatenating(CGAffineTransform(translationX: -displayed.minX, y: -displayed.minY))
            layer.setTransform(normalized.concatenating(CGAffineTransform(scaleX: Double(width) / abs(displayed.width), y: Double(height) / abs(displayed.height))), at: .zero)
            instruction.layerInstructions = [layer]
            composition.instructions = [instruction]
            let videoOutput = AVAssetReaderVideoCompositionOutput(videoTracks: [video], videoSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
            videoOutput.videoComposition = composition
            videoOutput.alwaysCopiesSampleData = false
            var videoSettings: [String: Any] = [AVVideoCodecKey: spec.videoCodec?.lowercased() == "hevc" ? AVVideoCodecType.hevc : AVVideoCodecType.h264,
                AVVideoWidthKey: width, AVVideoHeightKey: height]
            if let bitrate = spec.videoBitrate { videoSettings[AVVideoCompressionPropertiesKey] = [AVVideoAverageBitRateKey: bitrate] }
            guard writer.canApply(outputSettings: videoSettings, forMediaType: .video) else {
                throw FloeError.validationFailed("Device rejected the requested video encoder settings")
            }
            let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
            videoInput.expectsMediaDataInRealTime = false
            guard reader.canAdd(videoOutput), writer.canAdd(videoInput) else { throw FloeError.validationFailed("Cannot connect video reader and writer") }
            var streams: [(AVAssetReaderOutput, AVAssetWriterInput)] = [(videoOutput, videoInput)]
            if let audio = try await asset.loadTracks(withMediaType: .audio).first {
                let descriptions = try await audio.load(.formatDescriptions)
                guard let description = descriptions.first,
                      let format = CMAudioFormatDescriptionGetStreamBasicDescription(description)?.pointee else {
                    throw FloeError.validationFailed("Audio format could not be read")
                }
                let audioOutput = AVAssetReaderTrackOutput(track: audio, outputSettings: [AVFormatIDKey: kAudioFormatLinearPCM])
                audioOutput.alwaysCopiesSampleData = false
                var settings: [String: Any] = [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: format.mSampleRate, AVNumberOfChannelsKey: Int(format.mChannelsPerFrame)]
                if let bitrate = spec.audioBitrate { settings[AVEncoderBitRateKey] = bitrate }
                guard writer.canApply(outputSettings: settings, forMediaType: .audio) else { throw FloeError.validationFailed("Device rejected audio settings") }
                let audioInput = AVAssetWriterInput(mediaType: .audio, outputSettings: settings)
                audioInput.expectsMediaDataInRealTime = false
                guard reader.canAdd(audioOutput), writer.canAdd(audioInput) else { throw FloeError.validationFailed("Cannot connect audio reader and writer") }
                streams.append((audioOutput, audioInput))
            } else if spec.audioCodec != nil || spec.audioBitrate != nil {
                throw FloeError.validationFailed("Audio parameters require an audio track")
            }
            try await transfer(reader: reader, writer: writer, streams: streams, cancellation: cancellation)

        }
        try cancellation?.throwIfCancelled(); try Task.checkCancellation()
        let result = AVURLAsset(url: temporary)
        let actualDuration = try await result.load(.duration).seconds
        guard try await result.load(.isPlayable), actualDuration > 0, abs(actualDuration - duration.seconds) < max(0.25, duration.seconds * 0.001),
              let actualTrack = try await result.loadTracks(withMediaType: .video).first else {
            throw FloeError.validationFailed("Export failed playback or duration verification")
        }
        let size = try await actualTrack.load(.naturalSize)
        let rate = try await actualTrack.load(.nominalFrameRate)
        if let width = spec.width, let height = spec.height, Int(size.width) != width || Int(size.height) != height {
            throw FloeError.validationFailed("Exported dimensions do not match the request")
        }
        if let fps = spec.frameRate, abs(Double(rate) - fps) > 0.1 {
            throw FloeError.validationFailed("Exported frame rate does not match the request")
        }
        let bytes = try FileManager.default.attributesOfItem(atPath: temporary.path)[.size] as? NSNumber
        guard let bytes, bytes.int64Value > 0 else { throw FloeError.validationFailed("Export is empty") }
        try cancellation?.throwIfCancelled(); try Task.checkCancellation()
        if FileManager.default.fileExists(atPath: output.path) {
            _ = try FileManager.default.replaceItemAt(output, withItemAt: temporary)
        } else { try FileManager.default.moveItem(at: temporary, to: output) }
        return "status=ok output=\(spec.output) container=\(spec.container) bytes=\(bytes) width=\(Int(size.width)) height=\(Int(size.height)) frameRate=\(rate) duration=\(actualDuration)"
    }

    private static func transfer(reader: AVAssetReader, writer: AVAssetWriter,
                                 streams: [(AVAssetReaderOutput, AVAssetWriterInput)], cancellation: CancellationToken?) async throws {
        // Provider.next() still enters a cooperative executor in some SDK 27 builds.
        // Native blocking sample I/O therefore runs on dedicated GCD workers.
        for (source, destination) in streams { reader.add(source); writer.add(destination) }
        let control = MediaTransferControl(reader: reader, writer: writer)
        let transfers = streams.map { MediaSampleTransfer(source: $0.0, destination: $0.1, control: control) }
        guard writer.startWriting(), reader.startReading() else {
            control.cancel()
            throw writer.error ?? reader.error ?? FloeError.internalError("Could not start media processing")
        }
        writer.startSession(atSourceTime: .zero)
        let watcher = Task {
            while !Task.isCancelled {
                if cancellation?.isCancelled == true { control.cancel(); return }
                do { try await Task.sleep(for: .milliseconds(50)) } catch { return }
            }
        }
        defer { watcher.cancel() }
        try await withTaskCancellationHandler {
            do {
                try await withThrowingTaskGroup(of: Void.self) { group in
                    for transfer in transfers { group.addTask { try await transfer.run(cancellation: cancellation) } }
                    do { for try await _ in group { } }
                    catch { control.cancel(); group.cancelAll(); throw error }
                }
                try cancellation?.throwIfCancelled(); try Task.checkCancellation()
                try await control.finish()
            } catch { control.cancel(); throw error }
        } onCancel: { control.cancel() }
    }
}

/// Each stream owns one serial worker and retains at most one sample. Blocking
/// calls never execute on Swift's cooperative pool. The continuation resumes only
/// after the worker leaves, including after cancellation; no sample memory escapes.
private final class MediaSampleTransfer: @unchecked Sendable {
    private let source: AVAssetReaderOutput
    private let destination: AVAssetWriterInput
    private let control: MediaTransferControl
    private let queue = DispatchQueue(label: "org.floe.media.sample-transfer", qos: .userInitiated)
    init(source: AVAssetReaderOutput, destination: AVAssetWriterInput, control: MediaTransferControl) {
        self.source = source; self.destination = destination; self.control = control
    }
    func run(cancellation: CancellationToken?) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            queue.async { [self] in
                do {
                    while true {
                        try cancellation?.throwIfCancelled()
                        if control.writer.status == .cancelled || control.reader.status == .cancelled { throw CancellationError() }
                        guard control.writer.status == .writing else {
                            throw control.writer.error ?? FloeError.internalError("Media writer stopped before stream completion")
                        }
                        guard destination.isReadyForMoreMediaData else {
                            // Only the dedicated worker waits; cancellation and other
                            // streams remain schedulable and no samples accumulate.
                            Thread.sleep(forTimeInterval: 0.002)
                            continue
                        }
                        let hasSample = try autoreleasepool { () throws -> Bool in
                            guard let sample = source.copyNextSampleBuffer() else {
                                if control.reader.status == .cancelled { throw CancellationError() }
                                guard control.reader.status != .failed else {
                                    throw control.reader.error ?? FloeError.internalError("Media sample read failed")
                                }
                                return false
                            }
                            guard destination.append(sample) else {
                                throw control.writer.error ?? FloeError.internalError("Media sample write failed")
                            }
                            return true
                        }
                        if !hasSample { destination.markAsFinished(); break }
                    }
                    continuation.resume()
                } catch { continuation.resume(throwing: error) }
            }
        }
    }
}

/// Cancellation can arrive from the token watcher, task cancellation and error unwind.
/// Deliver it once: concurrent repeated cancellation can race AVFoundation observer teardown.
/// The wrapper stays alive until all sample workers and writer completion have returned.
private final class MediaTransferControl: @unchecked Sendable {
    let reader: AVAssetReader
    let writer: AVAssetWriter
    init(reader: AVAssetReader, writer: AVAssetWriter) { self.reader = reader; self.writer = writer }
    private let cancellationLock = NSLock()
    private var cancellationSent = false
    func cancel() {
        let first = cancellationLock.withLock {
            guard !cancellationSent else { return false }
            cancellationSent = true
            return true
        }
        guard first else { return }
        reader.cancelReading(); writer.cancelWriting()
    }
    func finish() async throws {
        await writer.finishWriting()
        guard writer.status == .completed, reader.status != .failed else {
            throw writer.error ?? reader.error ?? FloeError.internalError("Media transfer did not finish")
        }
    }
}

#endif
