// SPDX-License-Identifier: MPL-2.0
import Foundation
import FloeCore
import FloeTools
#if canImport(AVFoundation) && canImport(Darwin)
import AVFoundation
import Darwin

/// Actual decoded PCM measurements. Bin amplitudes preserve Float32 PCM
/// values; they are not a rendered UI cache or a content/listening analysis.
public struct AudioWaveformInspection: Codable, Sendable {
    public struct Source: Codable, Sendable {
        public var kind: String
        /// Workspace-relative path, or an opaque verified native source reference. Never a host URL.
        public var path: String
        public var contentSHA256: String
        public var byteCount: Int64
        public var resourceIdentity: String
        public var environmentID: String?
        public var sampleRate: Double
        public var channelCount: Int
        public var frameCount: Int64
        public var durationSeconds: Double
    }
    public struct Window: Codable, Sendable {
        public var requestedStartSeconds: Double
        public var requestedEndSeconds: Double?
        public var effectiveEndSeconds: Double
        public var startFrame: Int64
        /// Exclusive. Frames address decoded PCM in the source timeline.
        public var endFrame: Int64
        public var startSeconds: Double
        public var endSeconds: Double
        public var analyzedFrameCount: Int64
        public var coversEntireSource: Bool
        public var requestedBins: Int
        public var effectiveBins: Int
    }
    public struct Bin: Codable, Sendable {
        public var startFrame: Int64
        public var endFrame: Int64
        public var frameCount: Int64
    }
    public struct Channel: Codable, Sendable {
        public var index: Int
        public var min: Double
        public var max: Double
        public var peakAbsolute: Double
        public var rms: Double
        public var meanDC: Double
        /// nil is exact digital silence; it never encodes -infinity/NaN.
        public var peakDBFS: Double?
        public var rmsDBFS: Double?
        public var exactDigitalSilence: Bool
        public var silentSampleCount: Int64
        public var longestSilentRunFrames: Int64
        public var fullScaleOrOverSampleCount: Int64
        public var overFullScaleSampleCount: Int64
        /// Same-order arrays, aligned to the top-level frame bins.
        public var binMin: [Double]
        public var binMax: [Double]
        public var binRMS: [Double]
        private enum CodingKeys: String, CodingKey {
            case index, min, max, peakAbsolute, rms, meanDC, peakDBFS, rmsDBFS, exactDigitalSilence
            case silentSampleCount, longestSilentRunFrames, fullScaleOrOverSampleCount, overFullScaleSampleCount
            case binMin, binMax, binRMS
        }
        public func encode(to encoder:Encoder) throws {
            var c = encoder.container(keyedBy:CodingKeys.self)
            try c.encode(index,forKey:.index); try c.encode(min,forKey:.min); try c.encode(max,forKey:.max)
            try c.encode(peakAbsolute,forKey:.peakAbsolute); try c.encode(rms,forKey:.rms); try c.encode(meanDC,forKey:.meanDC)
            try c.encode(peakDBFS,forKey:.peakDBFS); try c.encode(rmsDBFS,forKey:.rmsDBFS)
            try c.encode(exactDigitalSilence,forKey:.exactDigitalSilence)
            try c.encode(silentSampleCount,forKey:.silentSampleCount); try c.encode(longestSilentRunFrames,forKey:.longestSilentRunFrames)
            try c.encode(fullScaleOrOverSampleCount,forKey:.fullScaleOrOverSampleCount); try c.encode(overFullScaleSampleCount,forKey:.overFullScaleSampleCount)
            try c.encode(binMin,forKey:.binMin); try c.encode(binMax,forKey:.binMax); try c.encode(binRMS,forKey:.binRMS)
        }
    }
    public struct Semantics: Codable, Sendable {
        public var amplitude = "Decoded Float32 PCM, nominal full scale [-1,1]. Values are not peak-normalized or clamped; float sources may exceed full scale."
        public var bins = "All decoded samples in the selected window participate. Each bin is an exclusive-end contiguous frame range; min/max retain polarity and RMS=sqrt(sum(sample^2)/frameCount), per channel. No point sampling or resampling is used. Bin arrays do not preserve within-bin sample order."
        public var time = "Frame times use source sample rate. Start rounds down and end rounds up to the nearest frame, bounded by source length. Omitted end selects at most the next 30 seconds; request another window for the rest."
        public var silence = "silentSampleCount and longestSilentRunFrames use abs(sample)<=silenceThresholdAmplitude per channel; this is an amplitude threshold, not a speech or perceptual silence detector."
        public var clipping = "fullScaleOrOverSampleCount counts abs(sample)>=1; overFullScaleSampleCount counts abs(sample)>1. These are clipping candidates, not proof of clipping in the original recording."
        public var decibels = "Peak/RMS dBFS use 20*log10(amplitude); exact zero is null. RMS is unweighted; no standard LUFS/loudness measurement is claimed."
        public var content = "Waveform statistics do not establish speech, instruments, meaning, listening quality or any other content conclusion."
        public var silenceThresholdAmplitude = 0.0001
        public var fullScaleAmplitude = 1.0
    }
    public var formatVersion = 1
    public var source: Source
    public var window: Window
    public var bins: [Bin]
    public var channels: [Channel]
    public var semantics = Semantics()
}

public enum AudioWaveformInspectionError: Error, LocalizedError, Sendable, Equatable {
    case invalidInput(String)
    case budgetExceeded(String)
    case sourceChanged
    public var errorDescription: String? {
        switch self {
        case .invalidInput(let reason): return reason
        case .budgetExceeded(let reason): return reason
        case .sourceChanged: return "The source audio changed during inspection. Read the current file and retry."
        }
    }
}

/// Offline, read-only AVFoundation decoder. One actor owns the file and its
/// bounded PCM buffer for a call, independently of any editor view lifetime.
public actor AudioWaveformInspector {
    static let maximumSourceBytes: Int64 = 256 * 1024 * 1024
    static let maximumWindowSeconds = 120.0
    static let maximumDecodedSamples: Int64 = 32_000_000
    static let maximumChannelBins = 512
    static let maximumReportBytes = 65_536

    public init() {}

    public nonisolated static func validate(startSeconds: Double?, endSeconds: Double?, bins: Int?) throws {
        let start = startSeconds ?? 0
        guard start.isFinite, start >= 0,
              endSeconds.map({ $0.isFinite && $0 > start }) ?? true else {
            throw AudioWaveformInspectionError.invalidInput("Audio window requires finite seconds with 0 <= startSeconds < endSeconds.")
        }
        guard (1...256).contains(bins ?? 64) else {
            throw AudioWaveformInspectionError.budgetExceeded("bins must be between 1 and 256 per channel.")
        }
        if let endSeconds, endSeconds - start > maximumWindowSeconds {
            throw AudioWaveformInspectionError.budgetExceeded("Inspect at most 120 seconds at a time; request successive windows for longer audio.")
        }
    }

    public func inspect(path: String, startSeconds: Double? = nil, endSeconds: Double? = nil,
                        bins requestedBins: Int? = nil, context: ToolContext) throws -> AudioWaveformInspection {
        try Self.validate(startSeconds:startSeconds,endSeconds:endSeconds,bins:requestedBins)
        try Self.checkCancellation(context.cancellation)
        guard !context.temporaryReadOnly else {
            throw FloeError.validationFailed("Temporary chat cannot read workspace audio files.")
        }
        let (url, relative) = try Self.resolve(path, context:context)
        return try inspectResolved(url:url,sourceReference:relative,sourceKind:"taskWorkspace",expectedSHA256:nil,
            startSeconds:startSeconds,endSeconds:endSeconds,requestedBins:requestedBins,context:context) {
                let (current, currentRelative) = try Self.resolve(path,context:context)
                guard current == url, currentRelative == relative else { throw AudioWaveformInspectionError.sourceChanged }
            }
    }

    /// Native-code integration only. The caller must first verify project/task
    /// ownership and resolve a real asset or render receipt, and keep its lease
    /// / security scope alive throughout this await. A model path or asset ID
    /// alone is not authority. The required callback rechecks the caller's
    /// existing binding/revision before and after decoding; SHA binds the
    /// actual bytes. This entry is not a tool and accepts no model-authored URL.
    public func inspectAuthorizedSource(at url:URL,sourceReference:String,expectedSHA256:String,
        startSeconds:Double? = nil,endSeconds:Double? = nil,bins:Int? = nil,context:ToolContext,
        validateSource:@Sendable () async throws -> Void) async throws -> AudioWaveformInspection {
        try Self.validate(startSeconds:startSeconds,endSeconds:endSeconds,bins:bins)
        try Self.checkCancellation(context.cancellation)
        guard !context.temporaryReadOnly else { throw FloeError.validationFailed("Temporary chat cannot read native project audio.") }
        guard url.isFileURL, !sourceReference.isEmpty, sourceReference.utf8.count <= 1024,
              !sourceReference.hasPrefix("/"), !sourceReference.contains("file://"), !sourceReference.contains("\0"),
              expectedSHA256.range(of:"^[a-f0-9]{64}$",options:.regularExpression) != nil else {
            throw AudioWaveformInspectionError.invalidInput("Verified native source reference and expected SHA256 are required.")
        }
        try await validateSource()
        try Self.checkCancellation(context.cancellation)
        let canonical = url.resolvingSymlinksInPath().standardizedFileURL
        let report = try inspectResolved(url:canonical,sourceReference:sourceReference,sourceKind:"authorizedNativeSource",
            expectedSHA256:expectedSHA256,startSeconds:startSeconds,endSeconds:endSeconds,requestedBins:bins,context:context) {
                guard url.resolvingSymlinksInPath().standardizedFileURL == canonical else { throw AudioWaveformInspectionError.sourceChanged }
            }
        try await validateSource()
        try Self.checkCancellation(context.cancellation)
        let latest = try AudioWaveformSourceSnapshot.capture(url:canonical,cancellation:context.cancellation)
        guard latest.sha256 == report.source.contentSHA256, latest.stamp.resourceIdentity == report.source.resourceIdentity else {
            throw AudioWaveformInspectionError.sourceChanged
        }
        return report
    }

    private func inspectResolved(url:URL,sourceReference:String,sourceKind:String,expectedSHA256:String?,
        startSeconds:Double?,endSeconds:Double?,requestedBins:Int?,context:ToolContext,
        validateLocation:() throws -> Void) throws -> AudioWaveformInspection {
        let original = try AudioWaveformSourceSnapshot.capture(url:url,cancellation:context.cancellation)
        if let expectedSHA256, original.sha256 != expectedSHA256 { throw AudioWaveformInspectionError.sourceChanged }
        try validateLocation()
        let file = try AVAudioFile(forReading:url,commonFormat:.pcmFormatFloat32,interleaved:false)
        let format = file.processingFormat
        let rate = format.sampleRate, count = Int(format.channelCount)
        guard rate.isFinite, (1...384_000).contains(rate), (1...8).contains(count),
              file.length > 0, file.length < Int64.max / 256,
              format.commonFormat == .pcmFormatFloat32, !format.isInterleaved else {
            throw AudioWaveformInspectionError.invalidInput("Audio must have nonempty decodable PCM, 1–8 channels and a sample rate at most 384 kHz.")
        }
        let duration = Double(file.length) / rate
        let start = startSeconds ?? 0, end = endSeconds ?? min(duration,start + 30)
        guard start < duration, end > start, end <= duration else {
            throw AudioWaveformInspectionError.invalidInput("The requested audio window must lie within the source duration (\(duration) seconds).")
        }
        let lower = AVAudioFramePosition((start * rate).rounded(.down))
        let upper = min(file.length,AVAudioFramePosition((end * rate).rounded(.up)))
        let frameCount = upper - lower
        guard frameCount > 0, frameCount <= Self.maximumDecodedSamples / Int64(count) else {
            throw AudioWaveformInspectionError.budgetExceeded("The selected window exceeds the 32 million decoded sample budget. Request a shorter window.")
        }
        let binCount = min(requestedBins ?? 64,Int(frameCount))
        guard binCount * count <= Self.maximumChannelBins else {
            throw AudioWaveformInspectionError.budgetExceeded("The selected channels exceed the 512 channel-bin budget. Reduce bins per channel.")
        }
        let ranges = (0..<binCount).map { index in
            let a = lower + frameCount * Int64(index) / Int64(binCount)
            let b = lower + frameCount * Int64(index + 1) / Int64(binCount)
            return AudioWaveformInspection.Bin(startFrame:a,endFrame:b,frameCount:b-a)
        }
        var accumulators = (0..<count).map { _ in AudioWaveformChannelAccumulator(bins:binCount) }
        guard let buffer = AVAudioPCMBuffer(pcmFormat:format,frameCapacity:8192) else {
            throw AudioWaveformInspectionError.invalidInput("Could not allocate the bounded audio inspection buffer.")
        }
        file.framePosition = lower
        var bin = 0
        while file.framePosition < upper {
            try Self.checkCancellation(context.cancellation)
            let offset = file.framePosition
            try file.read(into:buffer,frameCount:AVAudioFrameCount(min(8192,upper-offset)))
            guard buffer.frameLength > 0, let pcm = buffer.floatChannelData,
                  file.framePosition == offset + Int64(buffer.frameLength), file.framePosition <= upper else {
                throw AudioWaveformInspectionError.invalidInput("Audio decoding did not produce the requested contiguous frame range.")
            }
            for frame in 0..<Int(buffer.frameLength) {
                let absolute = offset + Int64(frame)
                while bin + 1 < binCount, absolute >= ranges[bin].endFrame { bin += 1 }
                for channel in 0..<count {
                    let value = Double(pcm[channel][frame])
                    guard value.isFinite else { throw AudioWaveformInspectionError.invalidInput("Audio contains non-finite PCM samples.") }
                    accumulators[channel].append(value,bin:bin)
                }
            }
        }
        try Self.checkCancellation(context.cancellation)
        try validateLocation()
        try original.validate(url:url,cancellation:context.cancellation)
        let channels = accumulators.enumerated().map { $0.element.result(index:$0.offset,frames:frameCount,ranges:ranges) }
        let report = AudioWaveformInspection(source:.init(kind:sourceKind,path:sourceReference,contentSHA256:original.sha256,
            byteCount:original.stamp.bytes,resourceIdentity:original.stamp.resourceIdentity,environmentID:context.environmentID,
            sampleRate:rate,channelCount:count,frameCount:file.length,durationSeconds:duration),
            window:.init(requestedStartSeconds:start,requestedEndSeconds:endSeconds,effectiveEndSeconds:end,
                startFrame:lower,endFrame:upper,startSeconds:Double(lower)/rate,endSeconds:Double(upper)/rate,
                analyzedFrameCount:frameCount,coversEntireSource:lower == 0 && upper == file.length,requestedBins:requestedBins ?? 64,effectiveBins:binCount),
            bins:ranges,channels:channels)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard try encoder.encode(report).count <= Self.maximumReportBytes else {
            throw AudioWaveformInspectionError.budgetExceeded("Waveform JSON exceeds 64 KiB. Reduce bins per channel; all frames in each remaining bin will still be measured.")
        }
        return report
    }

    private static func resolve(_ path:String,context:ToolContext) throws -> (URL,String) {
        try context.authorizeWorkspacePath(path)
        let url = try MediaPathGuard.resolve(path,root:context.workspaceRootURL)
        guard let root = context.workspaceRootURL?.resolvingSymlinksInPath().standardizedFileURL,
              url.path.hasPrefix(root.path + "/") else {
            throw FloeError.validationFailed("An existing audio file in this task workspace is required.")
        }
        let relative = String(url.path.dropFirst(root.path.count + 1))
        try context.authorizeWorkspacePath(relative)
        return (url,relative)
    }

    private static func checkCancellation(_ cancellation:CancellationToken) throws {
        try cancellation.throwIfCancelled()
        try Task.checkCancellation()
    }
}

/// A full-byte guard, separate from the decoder so metadata cannot stand in
/// for content identity. Hashing is streamed before and after PCM decoding.
struct AudioWaveformSourceSnapshot {
    struct Stamp: Equatable {
        var device: Int64
        var inode: UInt64
        var bytes: Int64
        var modifiedSeconds: Int64
        var modifiedNanoseconds: Int64
        var changedSeconds: Int64
        var changedNanoseconds: Int64
        var resourceIdentity: String { FloeDigest.sha256Hex(Data("\(device):\(inode)".utf8)) }
        static func read(_ url:URL) throws -> Self {
            var value = stat()
            guard lstat(url.path,&value) == 0 else { throw NSError(domain:NSPOSIXErrorDomain,code:Int(errno)) }
            guard (value.st_mode & S_IFMT) == S_IFREG, value.st_size > 0 else {
                throw AudioWaveformInspectionError.invalidInput("Audio source must be a nonempty regular file.")
            }
            guard value.st_size <= AudioWaveformInspector.maximumSourceBytes else {
                throw AudioWaveformInspectionError.budgetExceeded("Audio inspection source exceeds 256 MiB. Use a smaller source file.")
            }
            return .init(device:Int64(value.st_dev),inode:UInt64(value.st_ino),bytes:value.st_size,
                modifiedSeconds:Int64(value.st_mtimespec.tv_sec),modifiedNanoseconds:Int64(value.st_mtimespec.tv_nsec),
                changedSeconds:Int64(value.st_ctimespec.tv_sec),changedNanoseconds:Int64(value.st_ctimespec.tv_nsec))
        }
    }
    var stamp: Stamp
    var sha256: String
    static func capture(url:URL,cancellation:CancellationToken) throws -> Self {
        let before = try Stamp.read(url)
        let hash = try FloeDigest.sha256Hex(ofFileAt:url,isCancelled:{ cancellation.isCancelled || Task.isCancelled })
        guard try Stamp.read(url) == before else { throw AudioWaveformInspectionError.sourceChanged }
        return .init(stamp:before,sha256:hash)
    }
    func validate(url:URL,cancellation:CancellationToken) throws {
        try cancellation.throwIfCancelled(); try Task.checkCancellation()
        guard try Stamp.read(url) == stamp else { throw AudioWaveformInspectionError.sourceChanged }
        let hash = try FloeDigest.sha256Hex(ofFileAt:url,isCancelled:{ cancellation.isCancelled || Task.isCancelled })
        guard hash == sha256, try Stamp.read(url) == stamp else { throw AudioWaveformInspectionError.sourceChanged }
    }
}

private struct AudioWaveformChannelAccumulator {
    var minimum = Double.infinity, maximum = -Double.infinity, squares = 0.0, sum = 0.0
    var silent: Int64 = 0, silentRun: Int64 = 0, longestSilentRun: Int64 = 0
    var fullScale: Int64 = 0, overFullScale: Int64 = 0
    var binMin: [Double], binMax: [Double], binSquares: [Double]
    init(bins:Int) {
        binMin = .init(repeating:.infinity,count:bins)
        binMax = .init(repeating:-.infinity,count:bins)
        binSquares = .init(repeating:0,count:bins)
    }
    mutating func append(_ value:Double,bin:Int) {
        minimum = min(minimum,value); maximum = max(maximum,value)
        squares += value * value; sum += value
        binMin[bin] = min(binMin[bin],value); binMax[bin] = max(binMax[bin],value); binSquares[bin] += value * value
        if abs(value) <= 0.0001 { silent += 1; silentRun += 1; longestSilentRun = max(longestSilentRun,silentRun) }
        else { silentRun = 0 }
        if abs(value) >= 1 { fullScale += 1 }
        if abs(value) > 1 { overFullScale += 1 }
    }
    func result(index:Int,frames:Int64,ranges:[AudioWaveformInspection.Bin]) -> AudioWaveformInspection.Channel {
        let peak = max(abs(minimum),abs(maximum)), rms = sqrt(squares/Double(frames))
        return .init(index:index,min:minimum,max:maximum,peakAbsolute:peak,rms:rms,meanDC:sum/Double(frames),
            peakDBFS:peak == 0 ? nil:20 * log10(peak),rmsDBFS:rms == 0 ? nil:20 * log10(rms),exactDigitalSilence:peak == 0,
            silentSampleCount:silent,longestSilentRunFrames:longestSilentRun,fullScaleOrOverSampleCount:fullScale,overFullScaleSampleCount:overFullScale,
            binMin:binMin,binMax:binMax,binRMS:zip(binSquares,ranges).map { sqrt($0.0/Double($0.1.frameCount)) })
    }
}
#endif
