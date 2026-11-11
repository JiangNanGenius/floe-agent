// SPDX-License-Identifier: MPL-2.0
import AVFoundation
@preconcurrency import AudioKit
@preconcurrency import AudioKitEX
import Foundation
import FloeMusicCore

public struct MusicArrangementTransportSnapshot: Sendable, Hashable {
    public let positionSamples: Int64
    public let contentEndSamples: Int64
    public let running: Bool
}

private struct MusicArrangementSynthEvent {
    let sample: Int64
    let trackID: MusicTrackID
    let token: String
    let note: MusicMIDINote?
    let controller: MusicMIDIControllerPoint?
    let priority: Int
}

/// One owned AVAudioEngine that plays the arrangement's audible tracks from an
/// arbitrary start sample: audio clips stream through per-clip player nodes,
/// MIDI clips drive the same MusicSynthBank the live keyboard and the offline
/// renderer use. The audible playhead is the graph output clock, so the
/// visible playhead, accompaniment and a recording take share one clock by
/// construction. Session/category authority stays with the host service; the
/// DJ decks keep their own independent transport.
///
/// Supported graph subset matches the offline renderer's executable surface:
/// the built-in synth, master + track gain/pan strips, and audio clips with
/// gain/pan. Clip fades, inserts, buses/sends and looping are offline-render
/// features; an arrangement that needs them for its sound is rejected at
/// start so the host can record without accompaniment instead of playing a
/// different mix than the export would produce.
@MainActor public final class MusicArrangementTransport {
    public enum Output: Sendable, Equatable { case device, manual }
    public let ownerToken: String
    public let sampleRate: Int
    private let authority: any MusicAudioAuthority
    private let output: Output
    private let engine = AVAudioEngine()
    private let format: AVAudioFormat
    private let document: MusicDocument
    private let contentEnd: Int64
    private var graphs: [MusicTrackID: TrackGraph] = [:]
    private var audioOrder: [MusicTrackID] = []
    private var events: [MusicArrangementSynthEvent] = []
    private var nextEvent = 0
    private var acquired = false
    private var closed = false
    private var running = false
    private var keepAlive = false
    private var clockTask: Task<Void, Never>?
    private var anchorSample: Int64 = 0
    private var anchorClock: Double = 0
    /// Frozen loop region (recording only); `anchorSample == loop.startSample`.
    private var loop: MusicLoopRange?
    /// Elapsed output-clock samples at the last wrap; wraps advance it by the
    /// loop length so the content position wraps while the clock stays linear.
    private var loopAnchorElapsed: Int64 = 0
    private var loopWraps: Int64 = 0
    /// AudioKitEX.Fader wrappers stay alive for the transport's lifetime; the
    /// engine alone does not keep the Swift wrapper objects referenced.
    private var retainedFaders: [AudioKitEX.Fader] = []
    private var capture: MusicCaptureTapSink?
    private var monitorNode: AVAudioMixerNode?
    /// Identity of an in-flight startCapture: the awaited `service.begin`
    /// can outlive a stop/close, so the tap may only be installed when the
    /// same start is still the live one.
    private var captureStartID: UUID?
    private var captureStopping = false

    private final class ClipGraph {
        let player = AVAudioPlayerNode()
        let mixer = AVAudioMixerNode()
        var file: AVAudioFile?
        var generation = UUID()
        var nextTimelineSample: Int64 = 0
        /// Timeline ends of segments scheduled but not yet consumed (FIFO).
        var scheduledEnds: [Int64] = []
        /// project-sample -> file-frame ratio for this clip's source file.
        var ratio = 1.0
        var payload: MusicAudioClipPayload?
        var clipEnd: Int64 = 0
        /// While a recording loop is frozen, the portion of this clip that
        /// sounds every pass. It is constant for the whole recording; the
        /// gaps before and after it inside the loop are scheduled as silence
        /// so every pass occupies the whole loop length on the player's
        /// timeline with the window at its exact offset.
        var loopWindow: (start: Int64, end: Int64)?
        /// True when the clip lies entirely outside the frozen loop: it stays
        /// silent for the whole recording instead of scheduling anything.
        var silentInLoop = false
        /// Number of loop passes this clip has already scheduled through;
        /// keeps scheduled ends monotonic for the consumption FIFO.
        var passWraps: Int64 = 0
        /// One immutable zero buffer per distinct gap size, never mutated
        /// after creation: scheduleBuffer plays a buffer's whole frameLength,
        /// so sizes must match exactly or the player timeline drifts.
        var silenceBuffers: [Int: AVAudioPCMBuffer] = [:]
    }

    private final class TrackGraph {
        let mixer = AVAudioMixerNode()
        var synth: MusicSynthBank?
        var clips: [ClipGraph] = []
    }

    public init(ownerToken: String, authority: any MusicAudioAuthority, document: MusicDocument,
                sources: [ResolvedMusicSource], output: Output = .device) throws {
        guard !ownerToken.isEmpty, document.tempoMap.sampleRate >= MusicTempoMap.minSampleRate,
              document.tempoMap.sampleRate <= MusicTempoMap.maxSampleRate,
              let format = AVAudioFormat(standardFormatWithSampleRate: Double(document.tempoMap.sampleRate), channels: 2) else {
            throw MusicNativeError.invalid("arrangement owner or project format")
        }
        try document.validate()
        self.ownerToken = ownerToken
        self.authority = authority
        self.output = output
        self.document = document
        self.sampleRate = document.tempoMap.sampleRate
        self.format = format
        self.contentEnd = document.contentEndSample.value
        engine.mainMixerNode.outputVolume = 1
        if output == .manual { try engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: 4_096) }

        let audible = document.audibleTracks
        for track in audible {
            if track.outputBusID != MusicBus.masterBusID || !track.sends.isEmpty {
                throw MusicNativeError.unsupported("live arrangement routing beyond the master bus")
            }
            for effect in track.effects where effect.enabled {
                throw MusicNativeError.unsupported("live arrangement insert \(effect.pluginID)")
            }
        }
        let master = AVAudioMixerNode(); engine.attach(master)
        engine.connect(musicFader(input: master, strip: document.masterStrip, engine: engine, format: format, retained: &retainedFaders),
                       to: engine.mainMixerNode, format: format)
        for track in audible {
            let graph = TrackGraph(); engine.attach(graph.mixer)
            switch track.kind {
            case .audio:
                for clip in track.clips {
                    guard case .audio(let payload) = clip.body else { throw MusicNativeError.invalid("MIDI clip on audio track") }
                    // Live accompaniment executes the same subset as the
                    // contract documents: clip fades are offline-render
                    // features and are rejected rather than silently dropped.
                    guard payload.fadeInSamples == 0, payload.fadeOutSamples == 0 else {
                        throw MusicNativeError.unsupported("live arrangement clip fades")
                    }
                    guard let asset = document.assets.first(where: { $0.id == payload.assetID }),
                          let source = sources.first(where: { $0.asset.id == asset.id }),
                          source.asset.contentHash == asset.contentHash,
                          source.asset.sourceRevision == asset.sourceRevision else {
                        throw MusicNativeError.invalid("unresolved live arrangement source")
                    }
                    let clipGraph = ClipGraph()
                    engine.attach(clipGraph.player); engine.attach(clipGraph.mixer)
                    clipGraph.mixer.outputVolume = Float(payload.gain)
                    engine.connect(clipGraph.player, to: clipGraph.mixer, format: format)
                    let panned = musicFader(input: clipGraph.mixer, strip: try MusicStripSettings(gain: 1, pan: payload.pan),
                                            engine: engine, format: format, retained: &retainedFaders)
                    engine.connect(panned, to: graph.mixer, format: format)
                    clipGraph.file = try AVAudioFile(forReading: source.url)
                    let fileRate = clipGraph.file!.processingFormat.sampleRate
                    guard fileRate.isFinite, fileRate > 0, clipGraph.file!.length > 0 else {
                        throw MusicNativeError.unsupported("live arrangement source format")
                    }
                    clipGraph.ratio = fileRate / Double(sampleRate)
                    let fileStart = Int64((Double(payload.trimStartSamples) * clipGraph.ratio).rounded())
                    let fileEnd = Int64((Double(payload.trimStartSamples + payload.durationSamples) * clipGraph.ratio).rounded())
                    guard fileStart >= 0, fileEnd > fileStart, fileEnd <= clipGraph.file!.length else {
                        throw MusicNativeError.invalid("live arrangement clip exceeds its source")
                    }
                    clipGraph.payload = payload
                    clipGraph.clipEnd = clip.offset.value + payload.durationSamples
                    graph.clips.append(clipGraph)
                }
            case .midi:
                guard let instrument = track.instrument, instrument.pluginID == MusicNativeBuiltins.synth,
                      instrument.stateBlob.isEmpty else { throw MusicNativeError.unsupported("live arrangement instrument") }
                let bank = try MusicSynthBank(engine: engine, format: format,
                                              parameters: instrument.parameters, preset: instrument.presetIndex)
                if !instrument.enabled { bank.mixer.outputVolume = 0 }
                engine.connect(bank.mixer, to: graph.mixer, format: format)
                graph.synth = bank
                for clip in track.clips {
                    guard case .midi(let midi) = clip.body else { throw MusicNativeError.invalid("audio clip on MIDI track") }
                    for note in midi.notes {
                        let token = "\(clip.id.rawValue):\(note.id)"
                        let on = try clip.sample(atRelativeTick: note.startTick.value, tempoMap: document.tempoMap).value
                        let off = try clip.sample(atRelativeTick: note.startTick.value + note.durationTicks, tempoMap: document.tempoMap).value
                        events.append(.init(sample: on, trackID: track.id, token: token, note: note, controller: nil, priority: 1))
                        events.append(.init(sample: off, trackID: track.id, token: token, note: nil, controller: nil, priority: 0))
                    }
                    for point in midi.controllerPoints {
                        guard [1, 64, 128].contains(point.controller) else {
                            throw MusicNativeError.unsupported("live arrangement MIDI controller \(point.controller)")
                        }
                        events.append(.init(sample: try clip.sample(atRelativeTick: point.tick.value, tempoMap: document.tempoMap).value,
                                            trackID: track.id, token: "", note: nil, controller: point, priority: 2))
                    }
                }
                for channel in 0..<16 {
                    events.append(.init(sample: contentEnd, trackID: track.id, token: "", note: nil,
                                        controller: try MusicMIDIControllerPoint(controller: 64, tick: MusicTick(0), value: 0, channel: channel),
                                        priority: 3))
                }
            }
            let strip = musicFader(input: graph.mixer, strip: track.strip, engine: engine, format: format, retained: &retainedFaders)
            engine.connect(strip, to: master, format: format)
            graphs[track.id] = graph
            if track.kind == .audio { audioOrder.append(track.id) }
        }
        events.sort { $0.sample == $1.sample ? $0.priority < $1.priority : $0.sample < $1.sample }
    }

    private func require(_ owner: String) throws {
        guard !closed, owner == ownerToken else { throw MusicNativeError.staleOwner }
    }

    /// Begins playback (and the shared clock) at an absolute project sample.
    /// Sustained notes already sounding at the start point retrigger there, so
    /// accompaniment from a nonzero playhead does not drop held notes. A
    /// `loop` freezes the recording boundaries: the clock stays monotonic
    /// while the musical position wraps, and every wrap re-establishes the
    /// accompaniment at the loop start exactly like a new start.
    public func start(atSample: Int64, loop: MusicLoopRange? = nil, ownerToken: String) throws {
        try require(ownerToken)
        guard !running, atSample >= 0, atSample <= Int64.max / 4 else {
            throw MusicNativeError.invalid("arrangement start position")
        }
        if let loop {
            guard loop.startSample == atSample else {
                throw MusicNativeError.invalid("a recording loop must begin at the start position")
            }
        }
        anchorSample = atSample
        anchorClock = outputClockSeconds()
        loopAnchorElapsed = 0
        loopWraps = 0
        self.loop = loop
        for id in audioOrder {
            for clip in graphs[id]?.clips ?? [] {
                clip.loopWindow = nil
                clip.silentInLoop = false
                clip.passWraps = 0
                if let loop {
                    let start = max(audioClipStart(clip), loop.startSample)
                    let end = min(clip.clipEnd, loop.endSample)
                    if start < end { clip.loopWindow = (start, end) }
                    else { clip.silentInLoop = true }
                }
            }
        }
        establishState(atSample: atSample)
        for id in audioOrder { for clip in graphs[id]?.clips ?? [] { clip.scheduledEnds.removeAll() } }
        do {
            try startEngine()
        } catch {
            stopGraph()
            throw error
        }
        prepareAudio(from: atSample)
        if output == .manual {
            // A player node's first segment begins on the render cycle after
            // it was scheduled; spend that cycle here so the output clock and
            // the audible content start together at the requested anchor.
            guard let prime = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1_024) else {
                stopGraph(); throw MusicNativeError.invalid("arrangement prime buffer")
            }
            _ = try engine.renderOffline(1_024, to: prime)
            anchorClock = outputClockSeconds()
        }
        running = true
        if output == .device {
            clockTask = Task { @MainActor [weak self] in
                while !Task.isCancelled {
                    guard let self, !self.closed else { return }
                    self.dispatchAndReconcile()
                    do { try await Task.sleep(for: .milliseconds(20)) } catch { return }
                }
            }
        }
    }

    /// Re-establishes MIDI state at a content position: controller state from
    /// events before the point, then retrigger of notes already sounding
    /// there. Shared by `start(at:)` and every loop wrap so a wrap never
    /// drops a sustained accompaniment note or inherits a stale pedal.
    private func establishState(atSample: Int64) {
        nextEvent = events.firstIndex { $0.sample >= atSample } ?? events.count
        // Controller state established before the point is reconstructed so a
        // mid-project start (or wrap) does not inherit a stale pedal/bend.
        for event in events where event.sample < atSample {
            guard let point = event.controller, let synth = graphs[event.trackID]?.synth else { continue }
            apply(point, to: synth)
        }
        var held: [String: (trackID: MusicTrackID, note: MusicMIDINote)] = [:]
        for event in events where event.sample < atSample {
            if let note = event.note { held[event.token] = (event.trackID, note) }
            else if event.controller == nil { held.removeValue(forKey: event.token) }
        }
        for (token, heldNote) in held {
            if let synth = graphs[heldNote.trackID]?.synth {
                synth.noteOn(token: token, note: heldNote.note.pitch, velocity: heldNote.note.velocity, channel: heldNote.note.channel)
            }
        }
    }

    /// While recording, the clock must keep advancing after the last
    /// accompaniment note; the host marks that so end-of-content pauses the
    /// engine only for plain playback.
    public func markRecording(_ active: Bool, ownerToken: String) throws {
        try require(ownerToken)
        keepAlive = active
        if !active { dispatchAndReconcile() }
    }

    public var isRunning: Bool { running }

    /// Absolute project-sample playhead (start sample + elapsed output-clock
    /// time). Callers must NOT add a start offset again. The clock is always
    /// monotonic, even while a recording loop wraps.
    public func absolutePosition(ownerToken: String) throws -> Int64 {
        try require(ownerToken)
        guard running else { return anchorSample }
        return anchorSample + Int64((max(0, outputClockSeconds() - anchorClock) * Double(sampleRate)).rounded())
    }

    /// Musical position used to stamp recorded input: with a frozen loop this
    /// wraps inside the loop region; without one it equals `absolutePosition`.
    public func musicalPosition(ownerToken: String) throws -> Int64 {
        try require(ownerToken)
        guard let loop, running else { return try absolutePosition(ownerToken: ownerToken) }
        let elapsed = try absolutePosition(ownerToken: ownerToken) - anchorSample
        return loop.startSample + (elapsed - loopAnchorElapsed)
    }

    /// Number of fully crossed loop boundaries since the start of this
    /// recording pass (0 until the playhead first reaches the loop end).
    public func passIndex(ownerToken: String) throws -> Int64 {
        try require(ownerToken)
        return loopWraps
    }

    public var loopRange: MusicLoopRange? { loop }

    private func reconcileLoop(elapsed: Int64) {
        guard let loop else { return }
        var wrapped = false
        while elapsed - loopAnchorElapsed >= loop.lengthSamples {
            loopAnchorElapsed += loop.lengthSamples
            loopWraps += 1
            wrapped = true
        }
        guard wrapped else { return }
        // MIDI restarts at the loop start on every pass: sounding notes stop,
        // controller state and held notes are re-established (device MIDI is
        // dispatched on the transport tick, so this stays tick-granular).
        // Audio wraps through the continuous chunk plan in both device and
        // manual modes — the whole loop length is scheduled every pass with
        // the frozen window at its exact offset, so there is nothing to
        // invalidate and no audible gap at the wrap.
        for graph in graphs.values { graph.synth?.allOff() }
        establishState(atSample: loop.startSample)
    }

    /// Content position used to dispatch MIDI events and feed audio clips:
    /// the wrapped musical position while looping, the absolute position
    /// otherwise.
    private func contentPosition(elapsed: Int64) -> Int64 {
        guard let loop else { return anchorSample + elapsed }
        return loop.startSample + (elapsed - loopAnchorElapsed)
    }

    public func snapshot(ownerToken: String) throws -> MusicArrangementTransportSnapshot {
        try require(ownerToken)
        dispatchAndReconcile()
        return .init(positionSamples: try absolutePosition(ownerToken: ownerToken), contentEndSamples: contentEnd, running: running)
    }

    /// Advances the deterministic manual-rendering clock by one block,
    /// dispatching MIDI events at sample boundaries before rendering.
    public func renderOffline(frames: AVAudioFrameCount, ownerToken: String) throws -> AVAudioPCMBuffer {
        try require(ownerToken)
        guard output == .manual, frames > 0, frames <= 4_096,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else {
            throw MusicNativeError.invalid("arrangement offline rendering request")
        }
        guard running else { throw MusicNativeError.invalid("arrangement transport is stopped") }
        let elapsed = try self.absolutePosition(ownerToken: ownerToken) - anchorSample
        reconcileLoop(elapsed: elapsed)
        dispatchEvents(upTo: contentPosition(elapsed: elapsed))
        fillAudioQueues(upTo: contentPosition(elapsed: elapsed))
        let status = try engine.renderOffline(frames, to: buffer)
        guard status == .success else { throw MusicNativeError.render("arrangement offline engine status \(status.rawValue)") }
        dispatchAndReconcile()
        return buffer
    }

    public func stop(ownerToken: String) throws {
        try require(ownerToken)
        anchorSample = try absolutePosition(ownerToken: ownerToken)
        stopGraph()
    }

    public func close(ownerToken: String) throws {
        try require(ownerToken)
        stopGraph()
        closed = true
    }

    // MARK: - Microphone capture

    /// Starts microphone capture through the same engine the accompaniment
    /// plays on: an input-node tap converts to the project format and feeds
    /// bounded chunks to the service-owned writer, so recorded frames and the
    /// audible playhead share one clock by construction. The tap reads the
    /// input bus only — accompaniment and monitoring output are never
    /// re-recorded. Monitoring is a separate input→master branch connected
    /// only while `monitoring` is true.
    public func startCapture(destination: URL, service: MusicRecordingService, lease: MusicRenderLease,
                             monitoring: Bool, ownerToken: String) async throws {
        try require(ownerToken)
        guard output == .device, running else {
            throw MusicNativeError.invalid("capture needs a running device transport")
        }
        guard capture == nil, captureStartID == nil, !captureStopping else {
            throw MusicNativeError.invalid("capture already active")
        }
        let input = engine.inputNode
        let inputFormat = input.outputFormat(forBus: 0)
        guard inputFormat.sampleRate.isFinite, inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else {
            throw MusicNativeError.invalid("no audio input is available on this device")
        }
        // Anchor the capture to the same output clock the recording uses, so
        // every tapped frame maps to the transport linear position it was
        // captured at (never to the startCapture call site's playhead). The
        // hostTime AND the linear position come from ONE render-time
        // observation; input/output sampleTime domains have arbitrary zero
        // points and must never be subtracted directly.
        guard let renderTime = engine.mainMixerNode.lastRenderTime, renderTime.isHostTimeValid,
              renderTime.isSampleTimeValid, renderTime.sampleRate.isFinite, renderTime.sampleRate > 0 else {
            throw MusicNativeError.invalid("capture clock anchor")
        }
        let anchorClockNow = Double(renderTime.sampleTime) / renderTime.sampleRate
        let anchorLinear = anchorSample + Int64(((anchorClockNow - anchorClock) * Double(sampleRate)).rounded())
        let anchor = MusicCaptureTapSink.Anchor(startLinearSample: anchorLinear,
                                                outputHostTime: renderTime.hostTime,
                                                outputDeviceRate: renderTime.sampleRate,
                                                startClockSeconds: anchorClock,
                                                projectSampleRate: sampleRate)
        var startingMonitor: AVAudioMixerNode?
        if monitoring {
            let monitor = AVAudioMixerNode()
            engine.attach(monitor)
            engine.connect(input, to: monitor, format: inputFormat)
            engine.connect(monitor, to: engine.mainMixerNode, format: format)
            monitorNode = monitor
            startingMonitor = monitor
        }
        let startID = UUID()
        captureStartID = startID
        let handle: MusicTakeHandle
        do {
            handle = try await service.begin(document: document, lease: lease, destination: destination)
        } catch {
            if captureStartID == startID { captureStartID = nil }
            detachCaptureMonitor(ifOwned: startingMonitor)
            throw error
        }
        // The begin crossed an actor suspension: the graph may have been
        // stopped, closed or superseded meanwhile. Only the still-live start
        // may install its tap; a revoked one reclaims the just-begun take.
        guard captureStartID == startID, !closed, running, capture == nil else {
            if captureStartID == startID { captureStartID = nil }
            _ = try? await service.cancel(handle)
            detachCaptureMonitor(ifOwned: startingMonitor)
            throw MusicNativeError.staleOwner
        }
        let sink: MusicCaptureTapSink
        do {
            sink = try MusicCaptureTapSink(inputFormat: inputFormat, outputFormat: format, service: service,
                                           handle: handle, anchor: anchor, loop: loop)
        } catch {
            if captureStartID == startID { captureStartID = nil }
            // The take already began in the service: reclaim it so no writer
            // or handle leaks; empty takes vanish, recorded bytes recover.
            _ = try? await service.cancel(handle)
            detachCaptureMonitor(ifOwned: startingMonitor)
            throw error
        }
        input.installTap(onBus: 0, bufferSize: 4_096, format: inputFormat) { buffer, time in
            sink.receive(buffer, time: time)
        }
        capture = sink
    }

    private func detachCaptureMonitor(ifOwned monitor: AVAudioMixerNode?) {
        guard let monitor, monitorNode === monitor else { return }
        engine.disconnectNodeOutput(monitor)
        engine.disconnectNodeInput(monitor)
        engine.detach(monitor)
        monitorNode = nil
    }

    /// Stops microphone capture. `finish` commits the staged take at its
    /// destination; `cancel` keeps the recorded bytes as a recovery file.
    /// Both remove the input tap and the monitoring branch and return the
    /// frame-accurate pass map the host cuts per-pass take files from.
    public func stopCapture(finish: Bool, ownerToken: String) async throws -> MusicCapturedInput {
        try require(ownerToken)
        captureStartID = nil
        guard let sink = capture else {
            detachCaptureMonitor(ifOwned: monitorNode)
            return MusicCapturedInput(take: nil, totalFrames: 0, passBoundaries: [], firstLinearSample: 0,
                                      status: MusicCaptureTapSink.Status())
        }
        captureStopping = true
        defer { captureStopping = false }
        capture = nil
        engine.inputNode.removeTap(onBus: 0)
        detachCaptureMonitor(ifOwned: monitorNode)
        var status = await sink.drain()
        let stamps = sink.snapshot()
        // Finish commits the staged take; any failure falls back to the
        // recovery path on the SAME handle, so the recorded bytes always
        // survive with a health flag — the App never needs a second lookup.
        let take: MusicCapturedTake?
        if finish {
            do {
                take = try await sink.service.finish(sink.handle)
            } catch {
                take = try? await sink.service.cancel(sink.handle)
                status.deliveryFailed = true
            }
        } else {
            take = try? await sink.service.cancel(sink.handle)
        }
        return MusicCapturedInput(take: take, totalFrames: stamps.totalFrames,
                                  passBoundaries: stamps.passBoundaries,
                                  firstLinearSample: stamps.firstLinearSample ?? sink.firstLinearSample ?? 0,
                                  status: status)
    }


    private func startEngine() throws {
        guard !engine.isRunning else { return }
        if output == .device, !acquired { try authority.acquirePlayback(); acquired = true }
        do { try engine.start() }
        catch { if acquired { authority.releasePlayback(); acquired = false }; throw error }
        anchorClock = outputClockSeconds()
    }

    private func stopGraph() {
        clockTask?.cancel(); clockTask = nil
        running = false
        captureStartID = nil
        if let sink = capture {
            // Safety net: the host normally finishes/cancels the take first.
            // The suspending consumer exits via abandon(); staged bytes stay
            // recoverable in the service-owned writer.
            engine.inputNode.removeTap(onBus: 0)
            sink.abandon()
            capture = nil
        }
        if let monitor = monitorNode {
            engine.disconnectNodeOutput(monitor)
            engine.disconnectNodeInput(monitor)
            engine.detach(monitor)
            monitorNode = nil
        }
        for graph in graphs.values {
            graph.synth?.allOff()
            for clip in graph.clips { invalidate(clip) }
        }
        engine.stop()
        if acquired { authority.releasePlayback(); acquired = false }
    }

    private func outputClockSeconds() -> Double {
        if output == .manual { return Double(engine.manualRenderingSampleTime) / Double(sampleRate) }
        guard let time = engine.mainMixerNode.lastRenderTime, time.isSampleTimeValid,
              time.sampleRate.isFinite, time.sampleRate > 0 else { return 0 }
        return Double(time.sampleTime) / time.sampleRate
    }

    private func dispatchAndReconcile() {
        guard running, !closed else { return }
        guard let position = try? absolutePosition(ownerToken: ownerToken) else { return }
        let elapsed = position - anchorSample
        reconcileLoop(elapsed: elapsed)
        let content = contentPosition(elapsed: elapsed)
        dispatchEvents(upTo: content)
        fillAudioQueues(upTo: content)
        guard !keepAlive, position >= contentEnd else { return }
        var pendingAudio = false
        for id in audioOrder {
            for clip in graphs[id]?.clips ?? [] where !clip.scheduledEnds.isEmpty || (loop == nil && clip.nextTimelineSample < clip.clipEnd) {
                pendingAudio = true
            }
        }
        if !pendingAudio {
            anchorSample = position
            stopGraph()
        }
    }

    private func dispatchEvents(upTo sample: Int64) {
        while nextEvent < events.count, events[nextEvent].sample <= sample {
            let event = events[nextEvent]
            if let synth = graphs[event.trackID]?.synth {
                if let point = event.controller { apply(point, to: synth) }
                else if let note = event.note { synth.noteOn(token: event.token, note: note.pitch, velocity: note.velocity, channel: note.channel) }
                else { synth.noteOff(token: event.token) }
            }
            nextEvent += 1
        }
    }

    private func apply(_ point: MusicMIDIControllerPoint, to synth: MusicSynthBank) {
        switch point.controller {
        case 64: synth.sustain(point.value >= 64, channel: point.channel)
        case 1: synth.setModulation(Float(point.value) / 127, channel: point.channel)
        default: synth.pitchBend(Float(point.value - 8192) / (point.value >= 8192 ? 8191 : 8192), channel: point.channel)
        }
    }

    // MARK: - Audio clip scheduling

    private func prepareAudio(from startSample: Int64) {
        for id in audioOrder {
            for clip in graphs[id]?.clips ?? [] {
                invalidate(clip)
                clip.passWraps = 0
                clip.nextTimelineSample = max(startSample, regionStart(clip))
            }
        }
        fillAudioQueues(upTo: startSample)
    }

    private func audioClipStart(_ clip: ClipGraph) -> Int64 {
        clip.clipEnd - (clip.payload?.durationSamples ?? 0)
    }

    /// Start of the schedulable region: the whole frozen loop while looping
    /// (every pass occupies the full loop length on the player timeline), the
    /// whole clip otherwise.
    private func regionStart(_ clip: ClipGraph) -> Int64 {
        loop?.startSample ?? audioClipStart(clip)
    }

    /// End of the schedulable region (exclusive).
    private func regionEnd(_ clip: ClipGraph) -> Int64 {
        loop?.endSample ?? clip.clipEnd
    }

    /// One scheduled chunk of a clip's pass: either file audio (inside the
    /// frozen window) or silence (the gaps before/after it in the loop).
    private enum Chunk {
        case file(startFrame: Int64, count: Int64, endLinear: Int64)
        case silence(frames: Int64, endLinear: Int64)
    }

    /// Computes the next chunk for one clip and advances its pass cursor,
    /// wrapping to the region start at the end of a loop pass. Chunk edges
    /// split at the second boundary and at both window edges, so a chunk is
    /// either fully inside the window (file audio) or fully outside it
    /// (silence); the in-loop silence and the window phase repeat exactly
    /// every pass.
    private func nextChunk(_ clip: ClipGraph, file: AVAudioFile, payload: MusicAudioClipPayload) -> Chunk? {
        let start = regionStart(clip), end = regionEnd(clip)
        var position = clip.nextTimelineSample
        if position >= end {
            guard loop != nil else { return nil }
            clip.passWraps += 1
            position = start
        }
        guard position < end, let window = clip.loopWindow ?? (loop == nil ? (audioClipStart(clip), clip.clipEnd) : nil) else { return nil }
        var boundary = min(end, position + Int64(sampleRate))
        if position < window.start { boundary = min(boundary, window.start) }
        else if position < window.end { boundary = min(boundary, window.end) }
        let base = clip.passWraps * (loop?.lengthSamples ?? 0)
        let endLinear = base + boundary
        clip.nextTimelineSample = boundary
        guard position >= window.start, position < window.end else {
            return .silence(frames: boundary - position, endLinear: endLinear)
        }
        let ratio = clip.ratio
        let clipStart = audioClipStart(clip)
        let fileFrame = Int64((Double(payload.trimStartSamples) * ratio).rounded())
            + Int64((Double(position - clipStart) * ratio).rounded())
        let count = Int64((Double(boundary - position) * ratio).rounded())
        guard count > 0, fileFrame >= 0, fileFrame + count <= file.length else {
            return .silence(frames: boundary - position, endLinear: endLinear)
        }
        return .file(startFrame: fileFrame, count: count, endLinear: endLinear)
    }

    /// Shared by device ticks and manual rendering: one scheduling plan, no
    /// separate backfill path. Chunks chain back-to-back on the player's own
    /// timeline at bounded depth, so one-second boundaries — and loop wraps —
    /// never gap; a clip whose first chunk has not started stays silent until
    /// the shared output clock reaches its offset.
    private func fillAudioQueues(upTo position: Int64) {
        let purgeLimit = loop.map { position + loopWraps * $0.lengthSamples } ?? position
        for id in audioOrder {
            guard let clips = graphs[id]?.clips else { continue }
            for clipIndex in clips.indices {
                let clip = clips[clipIndex]
                purgeConsumed(clip, upTo: purgeLimit)
                guard !clip.silentInLoop, clip.scheduledEnds.count < 3,
                      !clip.scheduledEnds.isEmpty || clip.nextTimelineSample <= position,
                      let file = clip.file, let payload = clip.payload else { continue }
                if !clip.player.isPlaying { clip.player.play() }
                var safety = 0
                while clip.scheduledEnds.count < 3, safety < 4 {
                    safety += 1
                    guard let chunk = nextChunk(clip, file: file, payload: payload) else { break }
                    let generation = clip.generation
                    let completion: () -> Void = { [weak self] in
                        Task { @MainActor [weak self] in self?.consumed(trackID: id, index: clipIndex, generation: generation) }
                    }
                    switch chunk {
                    case .file(let startFrame, let count, let endLinear):
                        clip.player.scheduleSegment(file, startingFrame: startFrame, frameCount: AVAudioFrameCount(count), at: nil,
                            completionCallbackType: .dataConsumed) { _ in completion() }
                        clip.scheduledEnds.append(endLinear)
                    case .silence(let frames, let endLinear):
                        clip.player.scheduleBuffer(silenceBuffer(clip, frames: AVAudioFrameCount(frames)), at: nil,
                            completionCallbackType: .dataConsumed) { _ in completion() }
                        clip.scheduledEnds.append(endLinear)
                    }
                }
            }
        }
    }

    /// One immutable zero buffer per clip and gap size (never more than one
    /// scheduling second); scheduleBuffer plays a buffer's whole frameLength,
    /// so a size-mismatched reuse would drift the player timeline.
    private func silenceBuffer(_ clip: ClipGraph, frames: AVAudioFrameCount) -> AVAudioPCMBuffer {
        let key = Int(frames)
        if let buffer = clip.silenceBuffers[key] { return buffer }
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: max(frames, 1))!
        buffer.frameLength = buffer.frameCapacity
        memset(buffer.floatChannelData![0], 0, Int(buffer.frameCapacity) * MemoryLayout<Float>.stride)
        memset(buffer.floatChannelData![1], 0, Int(buffer.frameCapacity) * MemoryLayout<Float>.stride)
        clip.silenceBuffers[key] = buffer
        return buffer
    }

    private func purgeConsumed(_ clip: ClipGraph, upTo position: Int64) {
        if output == .manual {
            // Manual rendering consumes synchronously; completion callbacks
            // never arrive, so finished chunks are purged by the clock. In
            // loop mode `position` is linearized (content + wraps × length),
            // which keeps the FIFO monotonic across passes.
            while let first = clip.scheduledEnds.first, first <= position { clip.scheduledEnds.removeFirst() }
        }
    }

    private func consumed(trackID: MusicTrackID, index: Int, generation: UUID) {
        guard !closed, running, let clips = graphs[trackID]?.clips, clips.indices.contains(index) else { return }
        let clip = clips[index]
        guard clip.generation == generation else { return }
        if !clip.scheduledEnds.isEmpty { clip.scheduledEnds.removeFirst() }
        if let position = try? absolutePosition(ownerToken: ownerToken) {
            let elapsed = position - anchorSample
            reconcileLoop(elapsed: elapsed)
            fillAudioQueues(upTo: contentPosition(elapsed: elapsed))
            dispatchAndReconcile()
        }
    }

    private func invalidate(_ clip: ClipGraph) {
        clip.generation = UUID(); clip.player.stop(); clip.scheduledEnds.removeAll()
    }
}

/// Constant-power stereo fader shared with the offline renderer's routing.
private func musicFader(input: AVAudioNode, strip: MusicStripSettings, engine: AVAudioEngine,
                        format: AVAudioFormat, retained: inout [AudioKitEX.Fader]) -> AVAudioNode {
    let reference = MusicArrangementNodeReference(input, format: format)
    let node = AudioKitEX.Fader(reference)
    let angle = (strip.pan + 1) * Double.pi / 4
    let gain = strip.muted ? 0 : strip.gain
    node.leftGain = Float(gain * cos(angle) * sqrt(2))
    node.rightGain = Float(gain * sin(angle) * sqrt(2))
    engine.attach(node.avAudioNode)
    engine.connect(input, to: node.avAudioNode, format: format)
    retained.append(node)
    return node.avAudioNode
}

private final class MusicArrangementNodeReference: AudioKit.Node {
    let avAudioNode: AVAudioNode
    let outputFormat: AVAudioFormat
    var connections: [any AudioKit.Node] { [] }
    init(_ node: AVAudioNode, format: AVAudioFormat) { avAudioNode = node; outputFormat = format }
}

/// Result of a stopped capture: the finished (or recovery) take plus the
/// frame-accurate pass map the host uses to cut per-pass take files.
public struct MusicCapturedInput: Sendable {
    public let take: MusicCapturedTake?
    /// Total project-rate frames written to the take file.
    public let totalFrames: Int64
    /// Frame offsets where each new loop pass began (pass 1+; pass 0 starts at 0).
    public let passBoundaries: [Int64]
    /// Monotonic transport linear sample the first written frame belongs to.
    public let firstLinearSample: Int64
    /// Overload / timestamp / delivery health; a compromised take is kept
    /// recoverable, never committed silently.
    public let status: MusicCaptureHealth

    public init(take: MusicCapturedTake?, totalFrames: Int64, passBoundaries: [Int64],
                firstLinearSample: Int64, status: MusicCaptureHealth) {
        self.take = take
        self.totalFrames = totalFrames
        self.passBoundaries = passBoundaries
        self.firstLinearSample = firstLinearSample
        self.status = status
    }
}

/// Realtime input-tap → staged-writer bridge. The tap callback only converts
/// one bounded buffer and hands an ordered append to a serial task chain, so
/// the realtime thread never blocks. Every buffer is stamped against the
/// transport's own output clock anchor, so the first recorded PCM frame maps
/// to the exact linear position it was captured at — a delayed or nonzero
/// start never misaligns the take.
public struct MusicCaptureHealth: Sendable {
    public var overflowed = false
    public var misaligned = false
    public var deliveryFailed = false
    public init(overflowed: Bool = false, misaligned: Bool = false, deliveryFailed: Bool = false) {
        self.overflowed = overflowed
        self.misaligned = misaligned
        self.deliveryFailed = deliveryFailed
    }
}

final class MusicCaptureTapSink: @unchecked Sendable {
    /// Capture-start anchor from ONE render-time observation: the output
    /// render clock's hostTime and the transport linear position derived
    /// from that same sample timestamp. Input and output sampleTime domains
    /// have arbitrary independent zero points, so mapping goes through
    /// hostTime (or an explicitly same-domain sample reference), never by
    /// subtracting sampleTimes across domains.
    struct Anchor: Sendable {
        /// Transport linear position at the anchor instant.
        let startLinearSample: Int64
        /// System-clock hostTime of the output render clock at that instant.
        let outputHostTime: UInt64
        /// Output device rate at the anchor (linear = start + (t/rate - clock)·projectRate).
        let outputDeviceRate: Double
        /// Output clock seconds at transport start (anchorClock).
        let startClockSeconds: Double
        let projectSampleRate: Int
    }

    /// Why a take stops being trustworthy; the host turns these into an
    /// explicit diagnosis while the recorded bytes stay recoverable.
    typealias Status = MusicCaptureHealth

    /// Owned PCM snapshot: the tap's mutable callback buffer is copied
    /// before receive returns (installTap only lends it for the callback),
    /// so the consumer never reads storage the producer can overwrite.
    /// Blocks live in a small fixed pool and are recycled exactly once.
    private final class PCMBlock: @unchecked Sendable {
        let capacity: Int
        var frames: Int = 0
        var channelCount: Int = 0
        var data: [Float]
        init(capacity: Int) { self.capacity = capacity; data = [Float](repeating: 0, count: capacity * 2) }
    }
    private struct QueuedChunk: @unchecked Sendable {
        let block: PCMBlock
        let linear: Int64
    }

    let service: MusicRecordingService
    let handle: MusicTakeHandle
    private let converter: AVAudioConverter
    private let inputFormat: AVAudioFormat
    private let outputFormat: AVAudioFormat
    private let anchor: Anchor
    private let loop: MusicLoopRange?
    private let capacity: Int
    private let blockCapacity: Int
    private var freeBlocks: [PCMBlock] = []
    private let lock = NSLock()
    private var pendingCount = 0
    private var stopping = false
    private var totalFrames: Int64 = 0
    private var passBoundaries: [Int64] = []
    private var lastPass: Int64 = 0
    private var lastLinear: Int64 = 0
    private var firstWrittenLinear: Int64?
    private var status = Status()
    /// First observed input-domain (sampleTime, hostTime) pair; converts
    /// sampleTime stamps when a later buffer lacks a valid hostTime.
    private var inputReference: (sample: Int64, host: UInt64, rate: Double)?
    private let (stream, continuation) = AsyncStream<QueuedChunk>.makeStream()
    private var consumer: Task<Void, Never>?

    init(inputFormat: AVAudioFormat, outputFormat: AVAudioFormat, service: MusicRecordingService,
         handle: MusicTakeHandle, anchor: Anchor, loop: MusicLoopRange?, capacity: Int = 8) throws {
        guard let converter = AVAudioConverter(from: inputFormat, to: outputFormat) else {
            throw MusicNativeError.invalid("capture conversion format")
        }
        self.inputFormat = inputFormat
        self.outputFormat = outputFormat
        self.converter = converter
        self.service = service
        self.handle = handle
        self.anchor = anchor
        self.loop = loop
        self.capacity = max(1, capacity)
        // The tap bufferSize is only a request; snapshot blocks cover twice
        // the requested frames, and anything larger flags overload.
        self.blockCapacity = 8_192
        freeBlocks = (0..<(self.capacity * 2)).map { _ in PCMBlock(capacity: self.blockCapacity) }
        consumer = Task { [stream, weak self] in
            for await chunk in stream {
                guard let self else { return }
                await self.deliver(chunk)
            }
        }
    }

    /// Position the first actually-written PCM frame maps to; nil when
    /// nothing was written yet. Never the startCapture call-site playhead.
    var firstLinearSample: Int64? { firstWrittenLinear }

    /// Maps a tap buffer's first-frame time onto the transport linear clock.
    /// hostTime is the system clock shared by input and output; sampleTime
    /// fallback converts only within the input's own domain via the first
    /// observed (sample, host) pair. A buffer with neither is dropped and
    /// flags the take misaligned — never zero-filled.
    private func linearSample(for time: AVAudioTime) -> Int64? {
        let project = Double(anchor.projectSampleRate)
        if time.isHostTimeValid {
            let seconds = AVAudioTime.seconds(forHostTime: time.hostTime) - AVAudioTime.seconds(forHostTime: anchor.outputHostTime)
            guard seconds.isFinite else { return nil }
            return anchor.startLinearSample + Int64((seconds * project).rounded())
        }
        guard time.isSampleTimeValid, let reference = inputReference else { return nil }
        let stampRate = time.sampleRate.isFinite && time.sampleRate > 0 ? Double(time.sampleRate) : reference.rate
        guard stampRate == reference.rate else { return nil }
        let stampHost = AVAudioTime.hostTime(forSeconds: Double(time.sampleTime - reference.sample) / reference.rate)
        let seconds = AVAudioTime.seconds(forHostTime: stampHost + reference.host) - AVAudioTime.seconds(forHostTime: anchor.outputHostTime)
        guard seconds.isFinite else { return nil }
        return anchor.startLinearSample + Int64((seconds * project).rounded())
    }

    /// Realtime-thread entry: stamps and appends without ever blocking.
    /// Conversion and file writes run on the single suspending consumer;
    /// when the bounded queue is full the capture flags overload instead
    /// of growing memory or dropping silently.
    func receive(_ buffer: AVAudioPCMBuffer, time: AVAudioTime) {
        guard buffer.frameLength > 0 else { return }
        lock.lock()
        guard !stopping else { lock.unlock(); return }
        if inputReference == nil, time.isSampleTimeValid, time.isHostTimeValid,
           inputFormat.sampleRate.isFinite, inputFormat.sampleRate > 0 {
            inputReference = (time.sampleTime, time.hostTime, inputFormat.sampleRate)
        }
        guard let linear = linearSample(for: time) else {
            status.misaligned = true
            lock.unlock()
            return
        }
        guard pendingCount < capacity, let freeIndex = freeBlocks.indices.last else {
            status.overflowed = true
            lock.unlock()
            return
        }
        let block = freeBlocks[freeIndex]
        freeBlocks.removeLast()
        lock.unlock()
        let copied = copyIntoBlock(block, from: buffer)
        lock.lock()
        guard copied, !stopping else {
            freeBlocks.append(block)
            if !copied { status.overflowed = true }
            lock.unlock()
            return
        }
        pendingCount += 1
        lock.unlock()
        continuation.yield(QueuedChunk(block: block, linear: linear))
    }

    /// Bounded copy of the tap buffer into an owned pool block. Runs on the
    /// realtime thread, touches only the block's own storage, and makes no
    /// allocations: the engine may reuse its callback buffer the moment this
    /// callback returns, so nothing here may reference it afterwards.
    private func copyIntoBlock(_ block: PCMBlock, from buffer: AVAudioPCMBuffer) -> Bool {
        let frames = Int(buffer.frameLength)
        let channels = Int(buffer.format.channelCount)
        guard frames > 0, channels >= 1, channels <= 2, frames <= block.capacity,
              let source = buffer.floatChannelData else { return false }
        let planar = min(channels, 2)
        block.frames = frames
        block.channelCount = planar
        for channel in 0..<planar {
            source[channel].withMemoryRebound(to: Float.self, capacity: frames) { src in
                block.data.withUnsafeMutableBufferPointer { dst in
                    dst.baseAddress!.advanced(by: channel * block.capacity)
                        .update(from: src, count: frames)
                }
            }
        }
        return true
    }

    /// Consumer path (single suspending task): convert, split to
    /// service-sized chunks, append in order. Failures are recorded, never
    /// thrown into the take.
    private func deliver(_ chunk: QueuedChunk) async {
        let block = chunk.block
        defer { markDelivered(block) }
        // Rebuild a planar stereo/mono source buffer from the owned snapshot;
        // nothing here references the engine's mutable callback buffer.
        let blockFormat = AVAudioFormat(standardFormatWithSampleRate: inputFormat.sampleRate,
                                        channels: AVAudioChannelCount(max(block.channelCount, 1)))!
        guard block.frames > 0,
              let input = AVAudioPCMBuffer(pcmFormat: blockFormat, frameCapacity: AVAudioFrameCount(block.frames)) else {
            markDeliveryFailed()
            return
        }
        input.frameLength = AVAudioFrameCount(block.frames)
        if let destination = input.floatChannelData {
            for channel in 0..<min(block.channelCount, 2) {
                block.data.withUnsafeBufferPointer { src in
                    destination[channel].update(from: src.baseAddress!.advanced(by: channel * block.capacity), count: block.frames)
                }
            }
        }
        let ratio = outputFormat.sampleRate / inputFormat.sampleRate
        let capacity = AVAudioFrameCount((Double(block.frames) * ratio).rounded(.up) + 16)
        guard let output = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity) else {
            markDeliveryFailed()
            return
        }
        var consumedInput = false
        var conversionError: NSError?
        converter.convert(to: output, error: &conversionError) { _, inputStatus in
            if consumedInput { inputStatus.pointee = .noDataNow; return nil }
            consumedInput = true
            inputStatus.pointee = .haveData
            return input
        }
        guard conversionError == nil, output.frameLength > 0, let channels = output.floatChannelData else {
            markDeliveryFailed()
            return
        }
        let frames = Int(output.frameLength)
        let data = interleave(channels, frames)
        var offset = 0
        while offset < data.count {
            let end = min(data.count, offset + 32_768)
            do {
                try await service.append(interleavedStereo: Array(data[offset..<end]), handle: handle)
            } catch {
                markDeliveryFailed()
                return
            }
            offset = end
        }
        recordDeliveredChunk(linear: chunk.linear, frames: Int64(frames))
    }

    /// Bookkeeping for one fully-appended chunk, in sample order: the first
    /// written frame's real position, stamp contiguity, and every loop-pass
    /// boundary the chunk crosses (a chunk may cross several tiny loops).
    private func recordDeliveredChunk(linear: Int64, frames: Int64) {
        lock.lock()
        defer { lock.unlock() }
        if firstWrittenLinear == nil { firstWrittenLinear = linear }
        // Contiguity: stamps must advance with the written frames. A real
        // gap means the take cannot be treated as one continuous recording.
        let gap = linear - lastLinear
        if lastLinear != 0, abs(gap) > 4 { status.misaligned = true }
        if let loop {
            let endLinear = linear + frames
            var pass = lastPass + 1
            while loop.passIndex(linearSample: endLinear - 1) >= pass {
                let boundaryLinear = loop.startSample + pass * loop.lengthSamples
                passBoundaries.append(totalFrames + max(0, min(frames, boundaryLinear - linear)))
                pass += 1
            }
            lastPass = loop.passIndex(linearSample: endLinear - 1)
        }
        totalFrames += frames
        lastLinear = linear + frames
    }

    private func interleave(_ channels: UnsafePointer<UnsafeMutablePointer<Float>>, _ frames: Int) -> [Float] {
        var data = [Float](repeating: 0, count: frames * 2)
        for index in 0..<frames {
            data[index * 2] = channels[0][index]
            data[index * 2 + 1] = channels[1][index]
        }
        return data
    }

    /// Stops accepting buffers, finishes the stream so the suspending
    /// consumer drains and exits, flushes the converter tail, and reports
    /// the frame map and health. A stopped sink ignores late tap callbacks,
    /// so they can never attach to a new run.
    func drain() async -> Status {
        markStopping()
        continuation.finish()
        await consumer?.value
        consumer = nil
        await flushConverter()
        return finalStatus()
    }

    /// Resampling keeps a filter tail inside the converter; pull it once so
    /// the take carries every captured frame. End-of-stream frames continue
    /// at the last delivered position, keeping the frame map monotonic.
    private func flushConverter() async {
        guard let output = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: 8_192) else { return }
        var error: NSError?
        converter.convert(to: output, error: &error) { _, inputStatus in
            inputStatus.pointee = .endOfStream
            return nil
        }
        if error != nil {
            markDeliveryFailed()
            return
        }
        guard output.frameLength > 0, let channels = output.floatChannelData else { return }
        let frames = Int(output.frameLength)
        let data = interleave(channels, frames)
        let base: Int64 = currentLastLinear()
        var offset = 0
        while offset < data.count {
            let end = min(data.count, offset + 32_768)
            do {
                try await service.append(interleavedStereo: Array(data[offset..<end]), handle: handle)
            } catch {
                markDeliveryFailed()
                return
            }
            offset = end
        }
        recordFlushed(frames: Int64(frames), linear: base)
    }

    private func markStopping() {
        lock.lock(); stopping = true; lock.unlock()
    }
    private func finalStatus() -> Status {
        lock.lock(); defer { lock.unlock() }
        return Status(overflowed: status.overflowed, misaligned: status.misaligned, deliveryFailed: status.deliveryFailed)
    }
    private func markDeliveryFailed() {
        lock.lock(); status.deliveryFailed = true; lock.unlock()
    }
    private func markDelivered(_ block: PCMBlock) {
        lock.lock()
        pendingCount -= 1
        freeBlocks.append(block)
        lock.unlock()
    }
    private func currentLastLinear() -> Int64 {
        lock.lock(); defer { lock.unlock() }
        return lastLinear
    }
    private func recordFlushed(frames: Int64, linear: Int64) {
        lock.lock()
        if firstWrittenLinear == nil { firstWrittenLinear = linear }
        if let loop {
            let endLinear = linear + frames
            var pass = lastPass + 1
            while loop.passIndex(linearSample: endLinear - 1) >= pass {
                let boundaryLinear = loop.startSample + pass * loop.lengthSamples
                passBoundaries.append(totalFrames + max(0, min(frames, boundaryLinear - linear)))
                pass += 1
            }
            lastPass = loop.passIndex(linearSample: endLinear - 1)
        }
        totalFrames += frames
        lastLinear = linear + frames
        lock.unlock()
    }

    /// Synchronous teardown for abnormal paths (engine stopped underneath
    /// the capture): stops the sink and finishes the stream so the
    /// suspending consumer exits; the staged take bytes stay in the service
    /// as recovery data. Normal stop/cancel paths use `drain()` instead.
    func abandon() {
        lock.lock()
        stopping = true
        lock.unlock()
        continuation.finish()
    }

    /// Ordered frame map of everything written so far.
    func snapshot() -> (totalFrames: Int64, passBoundaries: [Int64], firstLinearSample: Int64?, status: Status) {
        lock.lock()
        defer { lock.unlock() }
        return (totalFrames, passBoundaries, firstWrittenLinear,
                Status(overflowed: status.overflowed, misaligned: status.misaligned, deliveryFailed: status.deliveryFailed))
    }
}
