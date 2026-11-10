// SPDX-License-Identifier: MPL-2.0
import AVFoundation
import Foundation
import FloeMusicCore

/// Verified away from the audio/UI executor. Only host-resolved repository
/// files enter the graph; a model's opaque sourceLocator is never opened.
public struct MusicDJPreparedSource: Sendable {
    public let source: ResolvedMusicSource
    public let sampleRate: Double
    public let frameCount: Int64
    private let fileSize: UInt64
    private let inode: UInt64
    private let modified: Date

    public static func prepare(_ source: ResolvedMusicSource, projectSampleRate: Int) async throws -> Self {
        let work = Task.detached(priority: .userInitiated) {
            try Task.checkCancellation()
            guard source.url.isFileURL, source.asset.kind != .midiFile,
                  (MusicTempoMap.minSampleRate...MusicTempoMap.maxSampleRate).contains(projectSampleRate),
                  try MusicAudioPreparation.hashFile(source.url) == source.asset.contentHash else {
                throw MusicNativeError.invalid("DJ source identity")
            }
            let file = try AVAudioFile(forReading: source.url)
            let rate = file.processingFormat.sampleRate
            guard rate.isFinite, rate > 0, (1...2).contains(file.processingFormat.channelCount), file.length > 0,
                  abs(Double(file.length) / rate * Double(projectSampleRate) - Double(source.asset.durationSamples.value)) <= 1 else {
                throw MusicNativeError.unsupported("DJ source format or duration")
            }
            let attributes = try FileManager.default.attributesOfItem(atPath: source.url.path)
            guard let size = (attributes[.size] as? NSNumber)?.uint64Value,
                  let inode = (attributes[.systemFileNumber] as? NSNumber)?.uint64Value,
                  let modified = attributes[.modificationDate] as? Date else { throw MusicNativeError.invalid("DJ source metadata") }
            try Task.checkCancellation()
            return Self(source: source, sampleRate: rate, frameCount: file.length,
                        fileSize: size, inode: inode, modified: modified)
        }
        return try await withTaskCancellationHandler { try await work.value } onCancel: { work.cancel() }
    }

    func open() throws -> AVAudioFile {
        let attributes = try FileManager.default.attributesOfItem(atPath: source.url.path)
        guard (attributes[.size] as? NSNumber)?.uint64Value == fileSize,
              (attributes[.systemFileNumber] as? NSNumber)?.uint64Value == inode,
              attributes[.modificationDate] as? Date == modified else { throw MusicNativeError.invalid("DJ source changed after preparation") }
        let file = try AVAudioFile(forReading: source.url)
        guard file.length == frameCount, file.processingFormat.sampleRate == sampleRate else {
            throw MusicNativeError.invalid("DJ decoded source changed")
        }
        return file
    }
}

public struct MusicDJPlaybackSnapshot: Sendable, Hashable {
    public struct Deck: Sendable, Hashable {
        public let positionSamples: Int64
        public let playing: Bool
        public let rate: Double
    }
    public let deckA: Deck
    public let deckB: Deck
    public let running: Bool
}

/// One owned AVAudioEngine for both decks. Files are streamed by player nodes;
/// a bounded three-segment queue keeps loops independent from the UI refresh.
/// The same graph also supplies offline export/contract rendering. Session,
/// category and device-route authority remain with the existing App service.
@MainActor public final class MusicDJTransport {
    public enum Output: Sendable, Equatable { case device, manual }
    public let ownerToken: String
    public let sampleRate: Int
    private let authority: any MusicAudioAuthority
    private let output: Output
    private let engine = AVAudioEngine()
    private let format: AVAudioFormat
    private var session: MusicDJSession?
    private var acquired = false
    private var closed = false
    private var clockTask: Task<Void, Never>?
    private var capture: MusicDJRecordingCapture?
    private var captureStarting = false
    private var captureFinishing = false
    private var captureIdentity = UUID()
    private var tapped = false
    public var isRecording: Bool { capture != nil || captureStarting || captureFinishing }
    private let decks = [DeckGraph(), DeckGraph()]

    private final class DeckGraph {
        let player = AVAudioPlayerNode()
        let speed = AVAudioUnitVarispeed()
        let pitch = AVAudioUnitTimePitch()
        let gain = AVAudioUnitEQ(numberOfBands: 0)
        var file: AVAudioFile?
        var identity: MusicAsset?
        var generation = UUID()
        var originFrame: Int64 = 0
        var nextFrame: Int64 = 0
        var loop: Range<Int64>?
        var queued = 0
        var playing = false
        var rate = 1.0
        var clockAnchor = 0.0
    }

    public init(ownerToken: String, authority: any MusicAudioAuthority, sampleRate: Int = 48_000,
                output: Output = .device) throws {
        guard !ownerToken.isEmpty, (MusicTempoMap.minSampleRate...MusicTempoMap.maxSampleRate).contains(sampleRate),
              let format = AVAudioFormat(standardFormatWithSampleRate: Double(sampleRate), channels: 2) else {
            throw MusicNativeError.invalid("DJ owner or output format")
        }
        self.ownerToken = ownerToken; self.authority = authority; self.sampleRate = sampleRate
        self.output = output; self.format = format
        for deck in decks {
            engine.attach(deck.player); engine.attach(deck.speed); engine.attach(deck.pitch); engine.attach(deck.gain)
            connect(deck, format: format)
        }
        engine.mainMixerNode.outputVolume = 1
        if output == .manual { try engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: 4_096) }
    }

    private func require(_ owner: String) throws {
        guard !closed, owner == ownerToken else { throw MusicNativeError.staleOwner }
    }
    private func connect(_ deck: DeckGraph, format: AVAudioFormat) {
        engine.connect(deck.player, to: deck.speed, format: format)
        engine.connect(deck.speed, to: deck.pitch, format: format)
        engine.connect(deck.pitch, to: deck.gain, format: format)
        engine.connect(deck.gain, to: engine.mainMixerNode, format: format)
    }

    /// Commands update this graph immediately, with explicit source identity.
    /// An unchanged persisted playhead is not interpreted as a seek while
    /// moving a mixer/rate control; actual audio clock positions survive.
    public func apply(_ next: MusicDJSession, prepared: [MusicDJPreparedSource] = [],
                      seeking: Set<MusicDJSession.DeckSlot>? = nil, ownerToken: String) throws {
        try require(ownerToken); try next.validate()
        guard next.sampleRate == sampleRate else { throw MusicNativeError.invalid("DJ project sample rate changed") }
        let incoming = [next.deckA, next.deckB]
        let previous = session.map { [$0.deckA, $0.deckB] }
        let positions = decks.indices.map { position($0) }
        var opened: [Int: (AVAudioFile, MusicAsset)] = [:]
        for index in decks.indices {
            let value = incoming[index], graph = decks[index]
            guard let id = value.assetID else { continue }
            guard let asset = next.assets.first(where: { $0.id == id }), asset.contentHash == value.assetContentHash,
                  asset.sourceRevision == value.assetSourceRevision else { throw MusicNativeError.invalid("DJ deck/source mismatch") }
            if graph.identity != asset {
                guard let verified = prepared.first(where: { $0.source.asset == asset }) else {
                    throw MusicNativeError.invalid("DJ source has not been prepared")
                }
                opened[index] = (try verified.open(), asset)
            }
        }
        let reconnect = !opened.isEmpty
        if reconnect {
            for deck in decks { invalidate(deck) }
            engine.stop()
        }
        for index in decks.indices {
            let graph = decks[index], value = incoming[index]
            let old = previous?[index]
            if let opened = opened[index] {
                engine.disconnectNodeOutput(graph.player); engine.disconnectNodeOutput(graph.speed)
                engine.disconnectNodeOutput(graph.pitch); engine.disconnectNodeOutput(graph.gain)
                graph.file = opened.0; graph.identity = opened.1
                connect(graph, format: opened.0.processingFormat)
            } else if value.assetID == nil {
                invalidate(graph); graph.file = nil; graph.identity = nil
            }
            graph.rate = value.rate
            if !reconnect, old?.rate != value.rate {
                if let file = graph.file {
                    graph.originFrame = Int64((Double(positions[index]) / Double(sampleRate) * file.processingFormat.sampleRate).rounded())
                    graph.clockAnchor = outputClockSeconds()
                }
            }
            graph.speed.rate = Float(value.keyLocked ? 1 : value.rate)
            graph.pitch.rate = Float(value.keyLocked ? value.rate : 1)
            graph.pitch.pitch = 0
            graph.pitch.bypass = !value.keyLocked || value.rate == 1
            let gains = next.channelGains()
            let gain = index == 0 ? gains.deckAMaster : gains.deckBMaster
            graph.player.volume = gain == 0 ? 0 : 1
            graph.gain.globalGain = Float(20 * log10(max(0.000_1, gain)))
            let changedPosition = old == nil || (seeking?.contains(index == 0 ? .a : .b)
                ?? (old?.playheadSamples != value.playheadSamples))
            if reconnect || changedPosition || old?.playing != value.playing || old?.activeLoop != value.activeLoop {
                invalidate(graph)
                let start = changedPosition ? value.playheadSamples : positions[index]
                configure(graph, state: value, start: start)
            }
        }
        session = next
        if decks.contains(where: { $0.playing }) || isRecording {
            do {
                try startEngine()
                for index in decks.indices where decks[index].playing {
                    fillQueue(index)
                    if !decks[index].player.isPlaying { decks[index].player.play() }
                }
            } catch { stopGraph(); throw error }
        } else { pauseEngine() }
    }

    private func configure(_ graph: DeckGraph, state: MusicDJSession.Deck, start: Int64) {
        guard let file = graph.file else { graph.playing = false; return }
        let ratio = file.processingFormat.sampleRate / Double(sampleRate)
        var frame = Int64((Double(max(0, min(start, state.assetDurationSamples))) * ratio).rounded())
        graph.loop = nil
        if let loop = state.activeLoop, let beat = state.beatGrid {
            let length = beat.beatLengthSamples(sampleRate: sampleRate)
            let a = Int64(((Double(beat.firstBeatSample) + Double(loop.startBeat) * length) * ratio).rounded())
            let b = Int64(((Double(beat.firstBeatSample) + Double(loop.startBeat + loop.lengthBeats) * length) * ratio).rounded())
            if a >= 0, b > a, b <= file.length {
                graph.loop = a..<b
                if !graph.loop!.contains(frame) { frame = a }
            }
        }
        graph.originFrame = min(file.length, frame); graph.nextFrame = graph.originFrame
        graph.clockAnchor = outputClockSeconds()
        graph.playing = state.playing && (graph.loop != nil || frame < file.length)
    }

    private func startEngine() throws {
        guard !engine.isRunning else { return }
        if output == .device, !acquired { try authority.acquirePlayback(); acquired = true }
        do {
            try engine.start()
            for graph in decks where graph.playing { graph.clockAnchor = outputClockSeconds() }
            if output == .device, clockTask == nil {
                clockTask = Task { @MainActor [weak self] in
                    while !Task.isCancelled {
                        guard let self, !self.closed else { return }
                        self.reconcileEnds()
                        do { try await Task.sleep(for: .milliseconds(100)) } catch { return }
                    }
                }
            }
        }
        catch { if acquired { authority.releasePlayback(); acquired = false }; throw error }
    }
    private func pauseEngine() {
        clockTask?.cancel(); clockTask = nil
        engine.pause()
        if acquired { authority.releasePlayback(); acquired = false }
    }
    private func invalidate(_ deck: DeckGraph) {
        deck.generation = UUID(); deck.player.stop(); deck.queued = 0
    }
    private func fillQueue(_ index: Int) {
        let graph = decks[index]
        guard graph.playing, let file = graph.file else { return }
        while graph.queued < 3 {
            let boundary = graph.loop?.upperBound ?? file.length
            if graph.nextFrame >= boundary {
                guard let loop = graph.loop else { return }
                graph.nextFrame = loop.lowerBound
            }
            let amount = min(boundary - graph.nextFrame, max(1, Int64(file.processingFormat.sampleRate)))
            guard amount > 0 else { return }
            let generation = graph.generation
            graph.player.scheduleSegment(file, startingFrame: graph.nextFrame, frameCount: AVAudioFrameCount(amount), at: nil,
                completionCallbackType: .dataConsumed) { [weak self] _ in
                    Task { @MainActor [weak self] in self?.consumed(index, generation: generation) }
                }
            graph.nextFrame += amount; graph.queued += 1
        }
    }
    private func consumed(_ index: Int, generation: UUID) {
        guard !closed else { return }
        let graph = decks[index]
        guard graph.generation == generation, graph.playing else { return }
        graph.queued = max(0, graph.queued - 1)
        fillQueue(index)
        reconcileEnds()
    }
    private func outputClockSeconds() -> Double {
        if output == .manual { return Double(engine.manualRenderingSampleTime) / Double(sampleRate) }
        guard let time = engine.mainMixerNode.lastRenderTime, time.isSampleTimeValid,
              time.sampleRate.isFinite, time.sampleRate > 0 else { return 0 }
        return Double(time.sampleTime) / time.sampleRate
    }
    private func reconcileEnds() {
        for index in decks.indices {
            let graph = decks[index]
            if graph.playing, graph.loop == nil, let file = graph.file,
               position(index) >= Int64((Double(file.length) / file.processingFormat.sampleRate * Double(sampleRate)).rounded()) {
                graph.originFrame = file.length; graph.playing = false
            }
        }
        if !decks.contains(where: { $0.playing }), !isRecording { pauseEngine() }
    }
    private func position(_ index: Int) -> Int64 {
        let graph = decks[index]
        guard let file = graph.file else { return 0 }
        // Player nodes may prefetch thousands of frames ahead of the output,
        // and expose an invalid non-nil player time before the first render.
        // The graph's actual output clock drives the audible playhead instead.
        let elapsed = graph.playing ? max(0, outputClockSeconds() - graph.clockAnchor) : 0
        var frame = graph.originFrame + Int64((elapsed * file.processingFormat.sampleRate * graph.rate).rounded())
        if let loop = graph.loop, frame >= loop.upperBound {
            frame = loop.lowerBound + (frame - loop.lowerBound) % (loop.upperBound - loop.lowerBound)
        }
        frame = max(0, min(file.length, frame))
        return Int64((Double(frame) / file.processingFormat.sampleRate * Double(sampleRate)).rounded())
    }

    public func snapshot(ownerToken: String) throws -> MusicDJPlaybackSnapshot {
        try require(ownerToken)
        reconcileEnds()
        return MusicDJPlaybackSnapshot(deckA: .init(positionSamples: position(0), playing: decks[0].playing, rate: decks[0].rate),
            deckB: .init(positionSamples: position(1), playing: decks[1].playing, rate: decks[1].rate), running: engine.isRunning)
    }

    /// Real engine output for exports and native qualification; does not use
    /// the device speaker or acquire an AVAudioSession route.
    public func renderOffline(frames: AVAudioFrameCount, ownerToken: String) throws -> AVAudioPCMBuffer {
        try require(ownerToken)
        guard output == .manual, frames > 0, frames <= 4_096,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else {
            throw MusicNativeError.invalid("DJ offline rendering request")
        }
        guard engine.isRunning else { throw MusicNativeError.invalid("DJ transport is stopped") }
        let status = try engine.renderOffline(frames, to: buffer)
        guard status == .success else { throw MusicNativeError.render("DJ offline engine status \(status.rawValue)") }
        capture?.push(buffer)
        return buffer
    }

    public func startRecording(document: MusicDocument, lease: MusicRenderLease, destination: URL,
                               maximumBytes: Int64 = 2_147_483_648, ownerToken: String) async throws {
        try require(ownerToken); try lease.validate(document: document)
        guard !isRecording, document.tempoMap.sampleRate == sampleRate, lease.ownerToken == ownerToken else {
            throw MusicNativeError.invalid("DJ recording is already active or its owner changed")
        }
        guard decks.compactMap(\.identity).allSatisfy({ document.assets.contains($0) }) else {
            throw MusicNativeError.invalid("DJ recording sources do not belong to this project")
        }
        captureStarting = true; captureIdentity = UUID()
        let identity = captureIdentity
        defer { if captureIdentity == identity { captureStarting = false } }
        do {
            try startEngine()
            let tapFormat = output == .manual ? format : engine.mainMixerNode.outputFormat(forBus: 0)
            guard tapFormat.sampleRate.isFinite, (8_000...192_000).contains(tapFormat.sampleRate),
                  tapFormat.channelCount == 2, tapFormat.commonFormat == .pcmFormatFloat32, !tapFormat.isInterleaved else {
                throw MusicNativeError.unsupported("DJ recording output route format")
            }
            let prepared = try await MusicDJRecordingCapture.create(document: document, lease: lease, destination: destination,
                sampleRate: Int(tapFormat.sampleRate), maximumBytes: maximumBytes)
            guard !closed, captureIdentity == identity, !Task.isCancelled else {
                _ = try? await prepared.finish(recovery: true)
                throw MusicNativeError.staleOwner
            }
            capture = prepared
            if output == .device {
                engine.mainMixerNode.installTap(onBus: 0, bufferSize: 1_024, format: tapFormat) { buffer, _ in prepared.push(buffer) }
                tapped = true
            }
        } catch {
            if !decks.contains(where: { $0.playing }), capture == nil { pauseEngine() }
            throw error
        }
    }
    /// Offline exports may wait for disk; the device's realtime tap never does.
    public func drainRecording(ownerToken: String) async throws {
        try require(ownerToken)
        guard let capture else { throw MusicNativeError.invalid("DJ recording is not active") }
        await capture.drain()
    }
    public func finishRecording(recovery: Bool = false, ownerToken: String) async throws -> MusicDJRecordingReceipt {
        try require(ownerToken)
        guard let capture, !captureFinishing else { throw MusicNativeError.invalid("DJ recording is not active") }
        if tapped { engine.mainMixerNode.removeTap(onBus: 0); tapped = false }
        self.capture = nil; captureFinishing = true
        defer {
            captureFinishing = false
            if !decks.contains(where: { $0.playing }) { pauseEngine() }
        }
        return try await withTaskCancellationHandler { try await capture.finish(recovery: recovery) }
            onCancel: { capture.invalidateCommit() }
    }

    private func stopGraph() {
        clockTask?.cancel(); clockTask = nil
        for graph in decks { invalidate(graph); graph.playing = false }
        engine.stop()
        if acquired { authority.releasePlayback(); acquired = false }
    }
    public func stop(ownerToken: String) throws {
        try require(ownerToken)
        if captureStarting { captureIdentity = UUID(); captureStarting = false }
        let positions = decks.indices.map { position($0) }
        stopGraph()
        for i in decks.indices {
            if let file = decks[i].file { decks[i].originFrame = Int64((Double(positions[i]) / Double(sampleRate) * file.processingFormat.sampleRate).rounded()) }
        }
        if var session { session.deckA.playing = false; session.deckB.playing = false; self.session = session }
    }
    public func close(ownerToken: String) throws {
        try require(ownerToken)
        guard !isRecording else { throw MusicNativeError.invalid("Finish or recover the DJ recording before closing") }
        stopGraph(); closed = true
    }
}
