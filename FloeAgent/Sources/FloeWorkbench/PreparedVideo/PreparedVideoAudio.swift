// FloeWorkbench — PreparedVideo: offline audio mixing.
//
// The mix is rendered in AVAudioEngine manual-rendering mode, never through a
// live output device. Each audio clip is decoded only for the overlap with the
// requested window, converted to the offline format, given its clip fade
// envelope, scheduled at an exact sample frame, and routed through the track's
// AVAudioUnitEQ / AVAudioUnitDynamicsProcessor settings.
//
// Render contract:
//   * `requestedFrames` are delivered at the requested sample rate/channels.
//   * `latencyFrames` are rendered before sample zero and trimmed, so a graph
//     latency cannot shift the first audible sample.
//   * `tailFrames` are rendered after the requested window and reported; they
//     are intentionally not appended to the delivered file. This makes effect
//     tails explicit instead of silently truncating them or extending a proxy
//     beyond its declared range.
//   * cancellation or failure never replaces an existing destination.

import Foundation
import AVFoundation
import AVFAudio
import AudioToolbox
#if canImport(Darwin)
import Darwin
#endif

// MARK: - Request / receipt

public struct PreparedVideoAudioMixRequest: Sendable {
    public var plan: PreparedVideoPlan
    public var window: PreparedVideoFrameWindow
    public var sampleRate: Double
    public var channelCount: Int
    public var destination: URL
    public var overwrite: Bool
    /// nil uses `plan.audio.tailSeconds`.
    public var tailFrames: Int?

    public init(plan: PreparedVideoPlan, window: PreparedVideoFrameWindow,
                sampleRate: Double = 48_000, channelCount: Int = 2,
                destination: URL, overwrite: Bool = false,
                tailFrames: Int? = nil) {
        self.plan = plan
        self.window = window
        self.sampleRate = sampleRate
        self.channelCount = channelCount
        self.destination = destination
        self.overwrite = overwrite
        self.tailFrames = tailFrames
    }
}

public struct PreparedVideoAudioMixReceipt: Sendable, Hashable {
    public let url: URL
    public let planID: PreparedVideoPlanID
    public let window: PreparedVideoFrameWindow
    public let sampleRate: Double
    public let channelCount: Int
    public let requestedFrames: Int
    public let deliveredFrames: Int
    public let renderedFrames: Int
    public let latencyFrames: Int
    public let tailFrames: Int
    public let peak: Float
    public let rms: Float
    public let tailPeak: Float
    public let durationSeconds: Double
}

// MARK: - Mixer

public actor PreparedVideoAudioMixer {
    public struct Limits: Sendable {
        public var maximumRequestedFrames: Int
        public var maximumChannels: Int
        public var maximumRenderFrames: Int
        public var maximumScheduledClips: Int
        public var maximumScheduledPCMBytes: Int
        public var maximumDecodeBytes: Int

        public init(maximumRequestedFrames: Int = 48_000 * 60,
                    maximumChannels: Int = 2,
                    maximumRenderFrames: Int = 48_000 * 70,
                    maximumScheduledClips: Int = 64,
                    maximumScheduledPCMBytes: Int = 128 * 1024 * 1024,
                    maximumDecodeBytes: Int = 64 * 1024 * 1024) {
            self.maximumRequestedFrames = maximumRequestedFrames
            self.maximumChannels = maximumChannels
            self.maximumRenderFrames = maximumRenderFrames
            self.maximumScheduledClips = maximumScheduledClips
            self.maximumScheduledPCMBytes = maximumScheduledPCMBytes
            self.maximumDecodeBytes = maximumDecodeBytes
        }
    }

    private let limits: Limits

    public init(limits: Limits = Limits()) {
        self.limits = limits
    }

    /// True when at least one unmuted audio clip intersects the window.
    public static func hasAudibleContent(plan: PreparedVideoPlan,
                                         window: PreparedVideoFrameWindow) -> Bool {
        guard let range = try? window.timeRange() else { return false }
        for track in plan.audio.tracks where !track.isMuted {
            for clip in track.clips where clip.timelineRange.intersects(range) {
                if clip.volume > 0 { return true }
            }
        }
        return false
    }

    public func mix(_ request: PreparedVideoAudioMixRequest,
                    cancellation: PreparedVideoCancellation = .none,
                    progress: @Sendable (PreparedVideoProgress) -> Void = { _ in }) async throws -> PreparedVideoAudioMixReceipt {
        try cancellation.check()
        try request.plan.validateForRender()
        guard request.sampleRate.isFinite, (8_000...192_000).contains(request.sampleRate) else {
            throw PreparedVideoError.audioFailure("sample rate is outside 8000...192000")
        }
        guard request.channelCount >= 1, request.channelCount <= limits.maximumChannels else {
            throw PreparedVideoError.audioFailure("channel count exceeds the supported bound")
        }
        guard ["wav", "caf"].contains(request.destination.pathExtension.lowercased()) else {
            throw PreparedVideoError.audioFailure("offline mixes are written as WAV or CAF")
        }
        let requestedFrames = Int((request.window.durationSeconds * request.sampleRate).rounded())
        guard requestedFrames > 0 else {
            throw PreparedVideoError.audioFailure("the requested window is shorter than one sample")
        }
        guard requestedFrames <= limits.maximumRequestedFrames else {
            throw PreparedVideoError.audioFailure("the requested window exceeds the offline mix bound")
        }
        let tailFrames: Int
        if let supplied = request.tailFrames {
            guard supplied >= 0 else {
                throw PreparedVideoError.audioFailure("tail frames must be non-negative")
            }
            tailFrames = min(supplied, Int(request.sampleRate * 5))
        } else {
            tailFrames = max(0, min(Int(request.plan.audio.tailSeconds * request.sampleRate),
                                   Int(request.sampleRate * 5)))
        }
        guard requestedFrames + tailFrames <= limits.maximumRenderFrames else {
            throw PreparedVideoError.audioFailure("the requested window plus tail exceeds the render bound")
        }
        guard request.destination.isFileURL else {
            throw PreparedVideoError.audioFailure("destination must be a file URL")
        }
        try FileManager.default.createDirectory(
            at: request.destination.deletingLastPathComponent(),
            withIntermediateDirectories: true)
        let destinationExists = FileManager.default.fileExists(atPath: request.destination.path)
        if destinationExists && !request.overwrite {
            throw PreparedVideoError.destinationExists
        }

        let temporary = request.destination.deletingLastPathComponent()
            .appendingPathComponent(".prepared-video-audio-\(UUID().uuidString).\(request.destination.pathExtension.lowercased())")
        defer { try? FileManager.default.removeItem(at: temporary) }

        let prepared = try await prepare(plan: request.plan, window: request.window,
                                         sampleRate: request.sampleRate,
                                         channelCount: request.channelCount,
                                         requestedFrames: requestedFrames,
                                         tailFrames: tailFrames,
                                         cancellation: cancellation)
        guard prepared.hasClips else {
            prepared.engine.stop()
            throw PreparedVideoError.audioFailure("no audible audio clips intersect the requested window")
        }
        progress(PreparedVideoProgress(phase: .audio, completed: 1, total: 3))

        let mixed = try renderOffline(prepared: prepared,
                                      requestedFrames: requestedFrames,
                                      tailFrames: tailFrames,
                                      sampleRate: request.sampleRate,
                                      channelCount: request.channelCount,
                                      cancellation: cancellation)
        progress(PreparedVideoProgress(phase: .audio, completed: 2, total: 3))
        try write(rendered: mixed, to: temporary,
                  sampleRate: request.sampleRate,
                  channelCount: request.channelCount,
                  requestedFrames: requestedFrames,
                  tailFrames: tailFrames,
                  cancellation: cancellation)
        progress(PreparedVideoProgress(phase: .audio, completed: 3, total: 3))
        try cancellation.check()
        try PreparedVideoAtomicCommit.commit(staged: temporary,
                                             destination: request.destination,
                                             overwrite: request.overwrite)
        let receipt = PreparedVideoAudioMixReceipt(
            url: request.destination, planID: request.plan.id, window: request.window,
            sampleRate: request.sampleRate, channelCount: request.channelCount,
            requestedFrames: requestedFrames,
            deliveredFrames: requestedFrames,
            renderedFrames: mixed.renderedFrames,
            latencyFrames: mixed.latencyFrames,
            tailFrames: tailFrames,
            peak: mixed.peak, rms: mixed.rms, tailPeak: mixed.tailPeak,
            durationSeconds: Double(requestedFrames) / request.sampleRate)
        return receipt
    }

    // MARK: Preparation

    private struct PreparedGraph {
        var engine: AVAudioEngine
        var format: AVAudioFormat
        var latencyFrames: Int
        var hasClips: Bool
        var players: [AVAudioPlayerNode]
        var effectUnits: [AVAudioUnit]
    }

    private func prepare(plan: PreparedVideoPlan,
                         window: PreparedVideoFrameWindow,
                         sampleRate: Double,
                         channelCount: Int,
                         requestedFrames: Int,
                         tailFrames: Int,
                         cancellation: PreparedVideoCancellation) async throws -> PreparedGraph {
        guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                         sampleRate: sampleRate,
                                         channels: AVAudioChannelCount(channelCount),
                                         interleaved: false) else {
            throw PreparedVideoError.audioFailure("could not create the offline audio format")
        }
        guard let windowRange = try? window.timeRange() else {
            throw PreparedVideoError.audioFailure("the frame window has no valid time range")
        }
        let engine = AVAudioEngine()
        var players: [AVAudioPlayerNode] = []
        var scheduled: [(player: AVAudioPlayerNode, buffer: AVAudioPCMBuffer, startFrame: Int)] = []
        var effectChains: [[AVAudioUnit]] = []
        var hasClips = false
        var scheduledCount = 0
        var scheduledBytes = 0

        for track in plan.audio.tracks where !track.isMuted {
            var clipsToSchedule: [(PreparedVideoAudioClip, AVAudioPCMBuffer, Int)] = []
            for clip in track.clips {
                try cancellation.check()
                guard clip.volume > 0,
                      let overlap = try? clip.timelineRange.clamped(to: windowRange),
                      overlap.duration.seconds > 0 else { continue }
                let start = Int(((overlap.start.seconds - windowRange.start.seconds) * sampleRate).rounded())
                let clipFrames = Int((overlap.duration.seconds * sampleRate).rounded())
                let available = requestedFrames - start
                guard available > 0 else { continue }
                let outputFrames = min(clipFrames, available)
                guard outputFrames > 0 else { continue }
                guard let asset = plan.asset(clip.assetID) else {
                    throw PreparedVideoError.missingAsset(clip.assetID)
                }
                guard asset.kind == .audio else {
                    throw PreparedVideoError.audioFailure("audio clip references a non-audio asset")
                }
                guard scheduledCount < limits.maximumScheduledClips,
                      outputFrames <= (limits.maximumScheduledPCMBytes - scheduledBytes) / max(1, channelCount * 4) else {
                    throw PreparedVideoError.audioFailure("scheduled audio exceeds the PCM memory or clip bound")
                }
                scheduledCount += 1
                scheduledBytes += outputFrames * channelCount * 4
                let buffer = try decode(clip: clip, asset: asset, overlap: overlap,
                                        windowStart: windowRange.start,
                                        outputFrames: outputFrames,
                                        sampleRate: sampleRate,
                                        format: format,
                                        cancellation: cancellation)
                clipsToSchedule.append((clip, buffer, max(0, start)))
            }
            guard !clipsToSchedule.isEmpty else { continue }
            hasClips = true

            let trackMixer = AVAudioMixerNode()
            let eq = AVAudioUnitEQ(numberOfBands: max(1, track.eqBands.count))
            configure(eq: eq, bands: track.eqBands)
            engine.attach(trackMixer)
            engine.attach(eq)
            var trackEffects: [AVAudioUnit] = [eq]
            engine.connect(trackMixer, to: eq, format: format)
            var lastNode: AVAudioNode = eq
            if let dynamics = track.dynamics {
                let dynamicsNode = AVAudioUnitEffect(audioComponentDescription: AudioComponentDescription(
                    componentType: kAudioUnitType_Effect,
                    componentSubType: kAudioUnitSubType_DynamicsProcessor,
                    componentManufacturer: kAudioUnitManufacturer_Apple,
                    componentFlags: 0,
                    componentFlagsMask: 0))
                configure(dynamics: dynamicsNode, settings: dynamics)
                engine.attach(dynamicsNode)
                trackEffects.append(dynamicsNode)
                engine.connect(lastNode, to: dynamicsNode, format: format)
                lastNode = dynamicsNode
            }
            if let limiter = track.limiter {
                let node = AVAudioUnitEffect(audioComponentDescription:.init(componentType:kAudioUnitType_Effect,
                    componentSubType:kAudioUnitSubType_PeakLimiter,componentManufacturer:kAudioUnitManufacturer_Apple,
                    componentFlags:0,componentFlagsMask:0))
                guard let parameters = node.auAudioUnit.parameterTree,
                      let attack = parameters.parameter(withAddress:AUParameterAddress(kLimiterParam_AttackTime)),
                      let decay = parameters.parameter(withAddress:AUParameterAddress(kLimiterParam_DecayTime)),
                      let preGain = parameters.parameter(withAddress:AUParameterAddress(kLimiterParam_PreGain)) else {
                    throw PreparedVideoError.audioFailure("native peak limiter is unavailable")
                }
                attack.value = Float(limiter.attackTime);decay.value = Float(limiter.decayTime)
                // Boost into the native 0 dB limiter and lower its output by
                // the same amount. Quiet samples keep gain; peaks obey this
                // clip's ceiling before other tracks/master gain are mixed.
                preGain.value = Float(-limiter.ceilingDB)
                let attenuation = AVAudioMixerNode()
                engine.attach(node);engine.attach(attenuation);trackEffects.append(node)
                engine.connect(lastNode,to:node,format:format);engine.connect(node,to:attenuation,format:format)
                lastNode = attenuation
            }
            effectChains.append(trackEffects)
            engine.connect(lastNode, to: engine.mainMixerNode, format: format)
            // Connecting a mixer resets its output bus gain. Apply this only
            // after the final graph connection, just like trackMixer below.
            if let limiter = track.limiter,let attenuation = lastNode as? AVAudioMixerNode {
                attenuation.outputVolume = Float(pow(10,limiter.ceilingDB/20))
            }
            trackMixer.outputVolume = Float(track.volume)

            for (_, buffer, startFrame) in clipsToSchedule {
                let player = AVAudioPlayerNode()
                engine.attach(player)
                engine.connect(player, to: trackMixer, format: format)
                scheduled.append((player, buffer, startFrame))
                players.append(player)
            }
        }
        engine.mainMixerNode.outputVolume = Float(plan.audio.masterVolume)

        // Parallel tracks share time zero; only the longest processing path
        // determines graph latency. Summing all tracks would shift the mix.
        let latencySeconds = effectChains.map { chain in chain.reduce(0.0) { $0 + max(0,$1.auAudioUnit.latency) } }.max() ?? 0
        let latencyFrames = min(requestedFrames, max(0, Int((latencySeconds * sampleRate).rounded())))
        guard requestedFrames + tailFrames + latencyFrames <= limits.maximumRenderFrames else {
            throw PreparedVideoError.audioFailure("the graph latency plus window exceeds the render bound")
        }

        try engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: 4_096)
        for item in scheduled {
            item.player.scheduleBuffer(item.buffer,
                                       at: AVAudioTime(sampleTime: AVAudioFramePosition(item.startFrame),
                                                       atRate: sampleRate),
                                       options: [], completionHandler: nil)
        }
        engine.prepare()
        do {
            try engine.start()
            for player in players { player.play() }
        } catch {
            throw PreparedVideoError.audioFailure("could not start the offline audio graph")
        }
        return PreparedGraph(engine: engine, format: format,
                             latencyFrames: latencyFrames, hasClips: hasClips,
                             players: players, effectUnits: effectChains.flatMap { $0 })
    }

    private func configure(eq: AVAudioUnitEQ, bands: [PreparedVideoEQBand]) {
        if bands.isEmpty {
            eq.bands[0].bypass = true
            return
        }
        for (index, band) in bands.enumerated() where index < eq.bands.count {
            let parameter = eq.bands[index]
            switch band.filter {
            case .lowShelf: parameter.filterType = .lowShelf
            case .parametric: parameter.filterType = .parametric
            case .highShelf: parameter.filterType = .highShelf
            }
            parameter.frequency = Float(band.frequency)
            parameter.gain = Float(band.gain)
            parameter.bandwidth = Float(band.bandwidth)
            parameter.bypass = !band.isEnabled
        }
    }

    private func configure(dynamics: AVAudioUnitEffect,
                           settings: PreparedVideoDynamics) {
        guard let tree = dynamics.auAudioUnit.parameterTree else { return }
        func set(_ address: UInt32, _ value: Float) {
            tree.parameter(withAddress: AUParameterAddress(address))?.value = value
        }
        set(kDynamicsProcessorParam_Threshold, Float(settings.threshold))
        set(kDynamicsProcessorParam_HeadRoom, Float(settings.headRoom))
        set(kDynamicsProcessorParam_ExpansionRatio, Float(settings.expansionRatio))
        set(kDynamicsProcessorParam_AttackTime, Float(settings.attackTime))
        set(kDynamicsProcessorParam_ReleaseTime, Float(settings.releaseTime))
        set(kDynamicsProcessorParam_OverallGain, Float(settings.masterGain))
    }

    // MARK: Decode / retime

    private func decode(clip: PreparedVideoAudioClip,
                        asset: PreparedVideoAsset,
                        overlap: PreparedVideoTimeRange,
                        windowStart: PreparedVideoTime,
                        outputFrames: Int,
                        sampleRate: Double,
                        format: AVAudioFormat,
                        cancellation: PreparedVideoCancellation) throws -> AVAudioPCMBuffer {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: asset.url.path, isDirectory: &isDirectory),
              !isDirectory.boolValue else {
            throw PreparedVideoError.missingAsset(asset.id)
        }
        let file: AVAudioFile
        do {
            file = try AVAudioFile(forReading: asset.url,
                                   commonFormat: .pcmFormatFloat32,
                                   interleaved: false)
        } catch {
            throw PreparedVideoError.assetUnreadable(asset.id)
        }
        let fileFormat = file.processingFormat
        guard fileFormat.sampleRate > 0, fileFormat.sampleRate <= 384_000,
              fileFormat.channelCount > 0, fileFormat.channelCount <= 8, file.length > 0 else {
            throw PreparedVideoError.assetUnreadable(asset.id)
        }
        let rate = clip.speed ?? 1
        let local = overlap.start.seconds - clip.timelineRange.start.seconds
        let sourceHigh = clip.sourceRange.endSeconds - local * rate
        let sourceStart = clip.isReversed == true
            ? max(clip.sourceRange.start.seconds, sourceHigh - overlap.duration.seconds * rate - 2 / sampleRate)
            : clip.sourceRange.start.seconds + local * rate
        let sourceStartFrame = AVAudioFramePosition((sourceStart * fileFormat.sampleRate).rounded())
        let sourceSpan = clip.isReversed == true ? sourceHigh - sourceStart : overlap.duration.seconds * rate
        let sourceFrameCount = AVAudioFrameCount(max(1, Int(ceil(sourceSpan * fileFormat.sampleRate)) + (rate == 1 ? 0 : 2)))
        guard sourceStartFrame >= 0, sourceStartFrame < file.length else {
            throw PreparedVideoError.audioFailure("audio source range starts outside the file")
        }
        let availableFrames = file.length - sourceStartFrame
        guard availableFrames > 0 else {
            throw PreparedVideoError.audioFailure("audio source range is empty")
        }
        let readFrames = AVAudioFrameCount(min(Int64(sourceFrameCount), Int64(availableFrames)))
        guard Int(readFrames) <= limits.maximumDecodeBytes / max(1, Int(fileFormat.channelCount) * 4) else {
            throw PreparedVideoError.audioFailure("audio decode exceeds the PCM memory bound")
        }
        guard let input = AVAudioPCMBuffer(pcmFormat: fileFormat, frameCapacity: readFrames) else {
            throw PreparedVideoError.audioFailure("could not allocate an audio decode buffer")
        }
        file.framePosition = sourceStartFrame
        do {
            try file.read(into: input, frameCount: readFrames)
        } catch {
            throw PreparedVideoError.assetUnreadable(asset.id)
        }
        guard input.frameLength > 0 else {
            throw PreparedVideoError.audioFailure("audio decoder made no progress")
        }
        try cancellation.check()

        var converted: AVAudioPCMBuffer
        if fileFormat.sampleRate == sampleRate && fileFormat.channelCount == format.channelCount {
            converted = input
        } else {
            guard let converter = AVAudioConverter(from: fileFormat, to: format) else {
                throw PreparedVideoError.audioFailure("could not create an audio format converter")
            }
            let ratio = sampleRate / fileFormat.sampleRate
            let capacity = AVAudioFrameCount(Double(input.frameLength) * ratio + 64)
            guard let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else {
                throw PreparedVideoError.audioFailure("could not allocate an audio conversion buffer")
            }
            var supplied = false
            var error: NSError?
            _ = converter.convert(to: output, error: &error) { _, status in
                if supplied {
                    status.pointee = .endOfStream
                    return nil
                }
                supplied = true
                status.pointee = .haveData
                return input
            }
            if let error {
                throw PreparedVideoError.audioFailure("audio conversion failed: \(error.localizedDescription)")
            }
            guard output.frameLength > 0 else {
                throw PreparedVideoError.audioFailure("audio conversion produced no frames")
            }
            converted = output
        }

        if rate != 1 || clip.isReversed == true {
            // Deterministic source-rate resampling: preview and export use the
            // same source positions and exact output frame count. Pitch follows
            // speed; this does not claim a pitch-preserving time-stretch.
            guard let samples = converted.floatChannelData,
                  let retimed = AVAudioPCMBuffer(pcmFormat:format, frameCapacity:AVAudioFrameCount(outputFrames)),
                  let destination = retimed.floatChannelData else {
                throw PreparedVideoError.audioFailure("could not allocate retimed audio")
            }
            let count = Int(converted.frameLength)
            retimed.frameLength = AVAudioFrameCount(outputFrames)
            for frame in 0..<outputFrames {
                if frame % 4096 == 0 { try cancellation.check() }
                let rawPosition = clip.isReversed == true
                    ? (sourceHigh - Double(sourceStartFrame) / fileFormat.sampleRate) * sampleRate - 1 - Double(frame) * rate
                    : Double(frame) * rate
                let position = max(0, min(Double(count-1), rawPosition))
                let left = min(count-1, Int(position)), right = min(count-1,left+1), fraction = Float(position-Double(left))
                for channel in 0..<Int(format.channelCount) {
                    destination[channel][frame] = samples[channel][left] * (1-fraction) + samples[channel][right] * fraction
                }
            }
            converted = retimed
        }

        // Clip gain/fade envelope is applied at output-timeline positions.
        guard let channels = converted.floatChannelData else {
            throw PreparedVideoError.audioFailure("decoded audio has no float channel data")
        }
        let channelCount = Int(converted.format.channelCount)
        let frameCount = Int(converted.frameLength)
        let clipStart = clip.timelineRange.start.seconds
        let clipEnd = clip.timelineRange.endSeconds
        let clipVolume = clip.volume
        let fadeIn = clip.fadeInSeconds
        let fadeOut = clip.fadeOutSeconds
        let overlapStart = overlap.start.seconds
        for frame in 0..<frameCount {
            let timeline = overlapStart + Double(frame) / sampleRate
            let local = timeline - clipStart
            let remaining = clipEnd - timeline
            var gain = clipVolume
            if fadeIn > 0 { gain *= min(1, max(0, local / fadeIn)) }
            if fadeOut > 0 { gain *= min(1, max(0, remaining / fadeOut)) }
            let value = Float(gain)
            for channel in 0..<channelCount {
                channels[channel][frame] *= value
            }
        }
        _ = windowStart
        return converted
    }

    // MARK: Offline render

    private struct MixedAudio {
        var channels: [[Float]]
        var sampleRate: Double
        var requestedFrames: Int
        var latencyFrames: Int
        var tailFrames: Int
        var renderedFrames: Int
        var peak: Float
        var rms: Float
        var tailPeak: Float
    }

    private func renderOffline(prepared: PreparedGraph,
                               requestedFrames: Int,
                               tailFrames: Int,
                               sampleRate: Double,
                               channelCount: Int,
                               cancellation: PreparedVideoCancellation) throws -> MixedAudio {
        let renderFrames = prepared.latencyFrames + requestedFrames + tailFrames
        var mixed = [[Float]](repeating: [Float](repeating: 0, count: renderFrames),
                              count: channelCount)
        guard let scratch = AVAudioPCMBuffer(pcmFormat: prepared.engine.manualRenderingFormat,
                                             frameCapacity: 4_096) else {
            throw PreparedVideoError.audioFailure("could not allocate an offline render buffer")
        }
        defer { prepared.engine.stop() }
        var rendered = 0
        while rendered < renderFrames {
            try cancellation.check()
            let request = AVAudioFrameCount(min(4_096, renderFrames - rendered))
            let status: AVAudioEngineManualRenderingStatus
            do {
                status = try prepared.engine.renderOffline(request, to: scratch)
            } catch {
                throw PreparedVideoError.audioFailure("offline audio render failed")
            }
            switch status {
            case .success:
                let frames = Int(scratch.frameLength)
                if frames == 0 {
                    // Input can end exactly at the requested boundary while
                    // the declared tail is still being collected. The arrays
                    // are zero-initialized, so an exhausted tail is silence.
                    if rendered >= requestedFrames {
                        rendered = renderFrames
                        continue
                    }
                    throw PreparedVideoError.audioFailure("offline audio render made no progress")
                }
                guard let data = scratch.floatChannelData else {
                    throw PreparedVideoError.audioFailure("offline audio render made no progress")
                }
                for channel in 0..<channelCount {
                    let source = data[channel]
                    for frame in 0..<frames {
                        if rendered + frame < renderFrames {
                            mixed[channel][rendered + frame] = source[frame]
                        }
                    }
                }
                rendered += frames
            case .cannotDoInCurrentContext:
                continue
            case .insufficientDataFromInputNode:
                if rendered >= requestedFrames {
                    rendered = renderFrames
                    continue
                }
                throw PreparedVideoError.audioFailure("offline audio graph ran out of scheduled input")
            case .error:
                throw PreparedVideoError.audioFailure("offline audio graph reported an error")
            @unknown default:
                throw PreparedVideoError.audioFailure("offline audio graph returned an unknown status")
            }
        }
        try cancellation.check()

        var peak: Float = 0
        var sumSquares: Double = 0
        var tailPeak: Float = 0
        let deliveredStart = min(prepared.latencyFrames, renderFrames)
        let deliveredEnd = min(deliveredStart + requestedFrames, renderFrames)
        for channel in 0..<channelCount {
            for frame in deliveredStart..<deliveredEnd {
                let value = mixed[channel][frame]
                peak = max(peak, abs(value))
                sumSquares += Double(value) * Double(value)
            }
            for frame in deliveredEnd..<renderFrames {
                tailPeak = max(tailPeak, abs(mixed[channel][frame]))
            }
        }
        let sampleCount = max(1, (deliveredEnd - deliveredStart) * channelCount)
        let rms = Float((sumSquares / Double(sampleCount)).squareRoot())
        return MixedAudio(channels: mixed, sampleRate: sampleRate,
                          requestedFrames: requestedFrames,
                          latencyFrames: prepared.latencyFrames,
                          tailFrames: tailFrames,
                          renderedFrames: renderFrames,
                          peak: peak, rms: rms, tailPeak: tailPeak)
    }

    // MARK: Write / commit

    private func write(rendered: MixedAudio,
                       to temporary: URL,
                       sampleRate: Double,
                       channelCount: Int,
                       requestedFrames: Int,
                       tailFrames: Int,
                       cancellation: PreparedVideoCancellation) throws {
        try cancellation.check()
        guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                         sampleRate: sampleRate,
                                         channels: AVAudioChannelCount(channelCount),
                                         interleaved: false) else {
            throw PreparedVideoError.audioFailure("could not create the output audio format")
        }
        guard let output = AVAudioPCMBuffer(pcmFormat: format,
                                            frameCapacity: AVAudioFrameCount(requestedFrames)) else {
            throw PreparedVideoError.audioFailure("could not allocate the output audio buffer")
        }
        output.frameLength = AVAudioFrameCount(requestedFrames)
        guard let destinationChannels = output.floatChannelData else {
            throw PreparedVideoError.audioFailure("output audio buffer has no channels")
        }
        let start = min(rendered.latencyFrames, rendered.renderedFrames)
        for channel in 0..<channelCount {
            for frame in 0..<requestedFrames {
                let sourceIndex = start + frame
                destinationChannels[channel][frame] = sourceIndex < rendered.channels[channel].count
                    ? rendered.channels[channel][sourceIndex] : 0
            }
        }
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: channelCount,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false
        ]
        do {
            let file = try AVAudioFile(forWriting: temporary, settings: settings,
                                       commonFormat: .pcmFormatFloat32, interleaved: false)
            try file.write(from: output)
        } catch {
            throw PreparedVideoError.audioFailure("could not write the offline audio file")
        }
        _ = tailFrames
    }
}

// MARK: - Atomic commit

/// Shared staged-file commit used by audio and video outputs. A failed or
/// cancelled operation never replaces an existing destination.
enum PreparedVideoAtomicCommit {
    static func commit(staged: URL, destination: URL, overwrite: Bool) throws {
        guard staged.isFileURL, destination.isFileURL else {
            throw PreparedVideoError.renderFailed("staged and destination paths must be file URLs")
        }
        let exists = FileManager.default.fileExists(atPath: destination.path)
        if exists && !overwrite {
            throw PreparedVideoError.destinationExists
        }
        if overwrite {
            guard rename(staged.path, destination.path) == 0 else {
                throw PreparedVideoError.renderFailed("could not atomically replace the destination")
            }
        } else {
            do {
                try FileManager.default.moveItem(at: staged, to: destination)
            } catch {
                throw PreparedVideoError.renderFailed("could not atomically move the staged output")
            }
        }
    }
}

// MARK: - Progress

public struct PreparedVideoProgress: Sendable, Hashable {
    public enum Phase: String, Sendable, Hashable {
        case preflight
        case audio
        case video
        case finalizing
    }

    public let phase: Phase
    public let completed: Int
    public let total: Int?

    public init(phase: Phase, completed: Int, total: Int? = nil) {
        self.phase = phase
        self.completed = completed
        self.total = total
    }
}
