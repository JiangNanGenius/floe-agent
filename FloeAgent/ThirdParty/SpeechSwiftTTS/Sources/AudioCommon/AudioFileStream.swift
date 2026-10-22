import AVFoundation
import Foundation

/// Controls how a multichannel recording is converted to the mono signal used
/// by speech models.
public enum AudioChannelSelection: Sendable, Equatable {
    /// Average every input channel. This is the safest default for recordings
    /// where speech may be present on any channel.
    case mixAll
    /// Preserve the historical channel-zero behavior explicitly.
    case first
    /// Average the selected zero-based input channels.
    case select([Int])
}

/// Options for bounded-memory file decoding.
public struct AudioFileStreamOptions: Sendable, Equatable {
    public var targetSampleRate: Int
    public var chunkDuration: TimeInterval
    public var channelSelection: AudioChannelSelection
    public var resampleQuality: ResampleQuality

    public init(
        targetSampleRate: Int = 24_000,
        chunkDuration: TimeInterval = 5,
        channelSelection: AudioChannelSelection = .mixAll,
        resampleQuality: ResampleQuality = .standard
    ) {
        self.targetSampleRate = targetSampleRate
        self.chunkDuration = chunkDuration
        self.channelSelection = channelSelection
        self.resampleQuality = resampleQuality
    }
}

/// A pull-driven audio-file sequence.
///
/// Decoding advances only when the consumer asks for the next element, which
/// provides natural backpressure without a producer task or an unbounded queue.
/// At most two output chunks are retained so the last element can be marked
/// with `isFinal`.
public struct AudioFileStream: AsyncSequence, Sendable {
    public typealias Element = CapturedAudioChunk

    private let url: URL
    private let options: AudioFileStreamOptions

    public init(url: URL, options: AudioFileStreamOptions = .init()) {
        self.url = url
        self.options = options
    }

    public struct AsyncIterator: AsyncIteratorProtocol {
        private var reader: AudioFileChunkReader?
        private var initializationError: Error?

        fileprivate init(url: URL, options: AudioFileStreamOptions) {
            do {
                reader = try AudioFileChunkReader(url: url, options: options)
            } catch {
                initializationError = error
            }
        }

        public mutating func next() async throws -> CapturedAudioChunk? {
            try Task.checkCancellation()
            if let initializationError {
                self.initializationError = nil
                throw initializationError
            }
            return try reader?.readChunk()
        }
    }

    public func makeAsyncIterator() -> AsyncIterator {
        AsyncIterator(url: url, options: options)
    }
}

/// Synchronous pull reader backing ``AudioFileStream``. Each call performs
/// bounded work and never retains the full file.
public final class AudioFileChunkReader {
    private let file: AVAudioFile
    private let sourceFormat: AVAudioFormat
    private let monoSourceFormat: AVAudioFormat
    private let targetFormat: AVAudioFormat
    private let selectedChannels: [Int]
    private let sourceFramesPerRead: AVAudioFrameCount
    private let targetFramesPerChunk: AVAudioFrameCount
    private let converter: AVAudioConverter?

    private var converterInputBuffer: AVAudioPCMBuffer?
    private var sourceEnded = false
    private var conversionEnded = false
    private var pendingSamples: [Float]?
    private var outputFrameIndex: Int64 = 0

    public init(url: URL, options: AudioFileStreamOptions = .init()) throws {
        guard options.targetSampleRate > 0 else {
            throw AudioLoadError.invalidStreamConfiguration("Target sample rate must be positive")
        }
        guard options.chunkDuration > 0, options.chunkDuration.isFinite else {
            throw AudioLoadError.invalidStreamConfiguration("Chunk duration must be positive and finite")
        }

        let file = try AVAudioFile(forReading: url)
        let sourceFormat = file.processingFormat
        guard sourceFormat.channelCount > 0 else {
            throw AudioLoadError.unsupportedFormat("Audio file has no channels")
        }
        guard sourceFormat.commonFormat == .pcmFormatFloat32,
              !sourceFormat.isInterleaved,
              file.length >= 0 else {
            throw AudioLoadError.unsupportedFormat("Expected non-interleaved Float32 processing audio")
        }

        let selectedChannels = try Self.resolveChannels(
            options.channelSelection,
            available: Int(sourceFormat.channelCount))
        guard let monoSourceFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sourceFormat.sampleRate,
            channels: 1,
            interleaved: false),
              let targetFormat = AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: Double(options.targetSampleRate),
                channels: 1,
                interleaved: false) else {
            throw AudioLoadError.bufferCreationFailed
        }

        let sourceFrames = max(1, Int((options.chunkDuration * sourceFormat.sampleRate).rounded()))
        let targetFrames = max(1, Int((options.chunkDuration * Double(options.targetSampleRate)).rounded()))
        guard sourceFrames <= Int(UInt32.max), targetFrames <= Int(UInt32.max) else {
            throw AudioLoadError.invalidStreamConfiguration("Chunk duration is too large")
        }

        self.file = file
        self.sourceFormat = sourceFormat
        self.monoSourceFormat = monoSourceFormat
        self.targetFormat = targetFormat
        self.selectedChannels = selectedChannels
        self.sourceFramesPerRead = AVAudioFrameCount(sourceFrames)
        self.targetFramesPerChunk = AVAudioFrameCount(targetFrames)

        if Int(sourceFormat.sampleRate.rounded()) == options.targetSampleRate {
            converter = nil
        } else {
            guard let converter = AVAudioConverter(from: monoSourceFormat, to: targetFormat) else {
                throw AudioLoadError.unsupportedFormat("Cannot create sample-rate converter")
            }
            switch options.resampleQuality {
            case .standard:
                break
            case .mastering:
                converter.sampleRateConverterAlgorithm = AVSampleRateConverterAlgorithm_Mastering
                converter.sampleRateConverterQuality = .max
            }
            self.converter = converter
        }
    }

    /// Read the next mono chunk. Returns `nil` after the final chunk.
    public func readChunk() throws -> CapturedAudioChunk? {
        if pendingSamples == nil {
            pendingSamples = try produceSamples()
        }
        guard let current = pendingSamples else { return nil }

        pendingSamples = try produceSamples()
        let chunk = CapturedAudioChunk(
            samples: current,
            sampleRate: Int(targetFormat.sampleRate),
            hostTime: nil,
            frameIndex: outputFrameIndex,
            isFinal: pendingSamples == nil)
        outputFrameIndex += Int64(current.count)
        return chunk
    }

    private func produceSamples() throws -> [Float]? {
        if converter == nil {
            return try readMixedSource(maxFrames: sourceFramesPerRead)
        }
        guard let converter else { return nil }

        var noProgressCount = 0
        while !conversionEnded {
            guard let output = AVAudioPCMBuffer(
                pcmFormat: targetFormat,
                frameCapacity: targetFramesPerChunk) else {
                throw AudioLoadError.bufferCreationFailed
            }
            output.frameLength = 0

            var inputFailure: Error?
            var conversionError: NSError?
            let status = converter.convert(to: output, error: &conversionError) {
                [self] requestedPackets, outputStatus in
                if sourceEnded {
                    outputStatus.pointee = .endOfStream
                    return nil
                }
                do {
                    let requested = max(1, min(requestedPackets, sourceFramesPerRead))
                    guard let samples = try readMixedSource(maxFrames: requested) else {
                        sourceEnded = true
                        outputStatus.pointee = .endOfStream
                        return nil
                    }
                    guard let input = AVAudioPCMBuffer(
                        pcmFormat: monoSourceFormat,
                        frameCapacity: AVAudioFrameCount(samples.count)) else {
                        throw AudioLoadError.bufferCreationFailed
                    }
                    input.frameLength = AVAudioFrameCount(samples.count)
                    samples.withUnsafeBufferPointer { source in
                        input.floatChannelData![0].update(
                            from: source.baseAddress!, count: samples.count)
                    }
                    converterInputBuffer = input
                    outputStatus.pointee = .haveData
                    return input
                } catch {
                    inputFailure = error
                    outputStatus.pointee = .endOfStream
                    return nil
                }
            }

            if let inputFailure { throw inputFailure }
            if let conversionError {
                throw AudioLoadError.conversionFailed(conversionError.localizedDescription)
            }
            if status == .error {
                throw AudioLoadError.conversionFailed("AVAudioConverter returned an error")
            }

            let count = Int(output.frameLength)
            if status == .endOfStream {
                conversionEnded = true
            }
            if count > 0, let channel = output.floatChannelData?[0] {
                return Array(UnsafeBufferPointer(start: channel, count: count))
            }

            if conversionEnded { return nil }
            noProgressCount += 1
            if noProgressCount > 2 {
                throw AudioLoadError.conversionFailed("Sample-rate converter made no progress")
            }
        }
        return nil
    }

    private func readMixedSource(maxFrames: AVAudioFrameCount) throws -> [Float]? {
        guard !sourceEnded else { return nil }
        guard let input = AVAudioPCMBuffer(
            pcmFormat: sourceFormat,
            frameCapacity: maxFrames) else {
            throw AudioLoadError.bufferCreationFailed
        }
        try file.read(into: input, frameCount: maxFrames)
        let count = Int(input.frameLength)
        guard count > 0 else {
            sourceEnded = true
            return nil
        }
        if file.framePosition >= file.length {
            sourceEnded = true
        }
        guard let channels = input.floatChannelData else {
            throw AudioLoadError.noFloatData
        }

        if selectedChannels.count == 1 {
            return Array(UnsafeBufferPointer(
                start: channels[selectedChannels[0]], count: count))
        }

        let scale = 1 / Float(selectedChannels.count)
        var mixed = [Float](repeating: 0, count: count)
        for channelIndex in selectedChannels {
            let source = channels[channelIndex]
            for frame in 0..<count {
                mixed[frame] += source[frame] * scale
            }
        }
        return mixed
    }

    static func resolveChannels(
        _ selection: AudioChannelSelection,
        available: Int
    ) throws -> [Int] {
        let channels: [Int]
        switch selection {
        case .mixAll:
            channels = Array(0..<available)
        case .first:
            channels = [0]
        case .select(let selected):
            channels = selected
        }
        guard !channels.isEmpty else {
            throw AudioLoadError.invalidChannelSelection(
                requested: channels, availableChannelCount: available)
        }
        var seen = Set<Int>()
        let unique = channels.filter { seen.insert($0).inserted }
        guard unique.allSatisfy({ $0 >= 0 && $0 < available }) else {
            throw AudioLoadError.invalidChannelSelection(
                requested: channels, availableChannelCount: available)
        }
        return unique
    }
}
