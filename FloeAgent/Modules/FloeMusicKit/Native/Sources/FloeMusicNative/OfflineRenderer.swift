import AVFoundation
@preconcurrency import AudioKit
@preconcurrency import AudioKitEX
import Foundation
import FloeMusicCore

public struct MusicRenderReceipt: Sendable, Codable {
    public let projectID: String
    public let revision: Int64
    public let frames: Int64
    public let sampleRate: Int
    public let tailFrames: Int64
    public let sha256: String
    public let file: URL
}

private final class MusicRenderTrack {
    let track: FloeMusicCore.MusicTrack
    let mixer = AVAudioMixerNode()
    var player: AVAudioPlayerNode?
    var synth: MusicSynthBank?
    init(_ track: FloeMusicCore.MusicTrack) { self.track = track }
}

/// A narrow AudioKit node reference for the graph already owned here. It
/// never asks AudioKit to create a second engine or manage the audio session.
private final class MusicAudioNodeReference: AudioKit.Node {
    let avAudioNode: AVAudioNode
    let outputFormat: AVAudioFormat
    var connections: [any AudioKit.Node] { [] }
    init(_ node: AVAudioNode, format: AVAudioFormat) { avAudioNode = node; outputFormat = format }
}

private struct MusicSynthEvent {
    let sample: Int64
    let trackID: MusicTrackID
    let token: String
    let note: MusicMIDINote?
    let controller: MusicMIDIControllerPoint?
    let priority: Int
}

/// A service executor owns decoding, graph creation, manual rendering and
/// staged file commits. No Swift timer/callback drives musical time.
public actor MusicOfflineRenderer {
    public init() {}

    public func render(document: MusicDocument, sources: [ResolvedMusicSource], destination: URL,
                       lease: MusicRenderLease, tailFrames: Int64 = 48_000,
                       onProgress: @Sendable (Int64) -> Void = { _ in }) throws -> MusicRenderReceipt {
        var phase = "validate"
        do {
            return try renderAudio(document: document, sources: sources, destination: destination, lease: lease,
                                   tailFrames: tailFrames, onProgress: onProgress, phase: &phase)
        } catch let error as MusicNativeError {
            throw error
        } catch {
            throw MusicNativeError.render("\(phase): \(String(reflecting: error))")
        }
    }

    private func renderAudio(document: MusicDocument, sources: [ResolvedMusicSource], destination: URL,
                             lease: MusicRenderLease, tailFrames: Int64,
                             onProgress: @Sendable (Int64) -> Void, phase: inout String) throws -> MusicRenderReceipt {
        try document.validate()
        try lease.validate(document: document)
        guard destination.isFileURL, tailFrames >= 0,
              let format = AVAudioFormat(standardFormatWithSampleRate: Double(document.tempoMap.sampleRate), channels: 2) else {
            throw MusicNativeError.invalid("render format or tail")
        }
        let contentEnd = try document.tracks.flatMap(\.clips).map { try $0.endSample(tempoMap: document.tempoMap).value }.max() ?? 0
        let (totalFrames, overflow) = contentEnd.addingReportingOverflow(tailFrames)
        guard !overflow, totalFrames > 0 else { throw MusicNativeError.invalid("render length") }
        let work = destination.deletingLastPathComponent().appendingPathComponent(".music-work-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: work) }
        let staged = musicStagingURL(for: destination)
        defer { try? FileManager.default.removeItem(at: staged) }
        let soloed = document.tracks.contains { $0.strip.soloed }
        let audible = document.tracks.filter { !$0.strip.muted && (!soloed || $0.strip.soloed) }
        var sourceFiles: [MusicAssetID: AVAudioFile] = [:]
        for track in audible {
            for clip in track.clips {
                guard case .audio(let payload) = clip.body else { continue }
                if sourceFiles[payload.assetID] == nil {
                    guard let asset = document.assets.first(where: { $0.id == payload.assetID }),
                          let source = sources.first(where: { $0.asset.id == asset.id }),
                          source.asset.contentHash == asset.contentHash,
                          source.asset.sourceRevision == asset.sourceRevision else { throw MusicNativeError.invalid("unresolved source version") }
                    let derivative = work.appendingPathComponent("\(asset.contentHash).caf")
                    if !FileManager.default.fileExists(atPath: derivative.path) {
                        phase = "decode source \(asset.name)"
                        try MusicAudioPreparation.prepare(source, sampleRate: document.tempoMap.sampleRate, destination: derivative)
                    }
                    phase = "open decoded source"
                    sourceFiles[asset.id] = try AVAudioFile(forReading: derivative, commonFormat: .pcmFormatFloat32, interleaved: false)
                }
                guard let file = sourceFiles[payload.assetID],
                      payload.trimStartSamples <= file.length,
                      payload.durationSamples <= file.length - payload.trimStartSamples else {
                    throw MusicNativeError.invalid("clip exceeds decoded source")
                }
            }
        }
        phase = "create audio graph"
        let engine = AVAudioEngine()
        defer { engine.stop() }
        var faders: [AudioKitEX.Fader] = []
        defer { withExtendedLifetime(faders) {} }
        let master = AVAudioMixerNode(); engine.attach(master)
        let masterOutput = fader(input: master, strip: document.masterStrip, engine: engine, format: format, retained: &faders)
        engine.connect(masterOutput, to: engine.mainMixerNode, format: format)
        var busNodes: [MusicBus.MusicBusID: AVAudioMixerNode] = [MusicBus.masterBusID: master]
        for bus in document.buses {
            guard !bus.strip.soloed else { throw MusicNativeError.unsupported("bus solo") }
            let mixer = AVAudioMixerNode(); engine.attach(mixer)
            busNodes[bus.id] = mixer
        }
        for bus in document.buses {
            let effect = try effects(bus.effects, input: busNodes[bus.id]!, engine: engine, format: format)
            let source = fader(input: effect, strip: bus.strip, engine: engine, format: format, retained: &faders)
            try route(source, to: bus.sends.isEmpty ? [MusicBus.masterBusID] : bus.sends,
                      nodes: busNodes, engine: engine, format: format)
        }
        var tracks: [MusicTrackID: MusicRenderTrack] = [:]
        var events: [MusicSynthEvent] = []
        for track in audible {
            let runtime = MusicRenderTrack(track)
            engine.attach(runtime.mixer)
            if track.kind == .audio {
                guard track.instrument == nil else { throw MusicNativeError.unsupported("instrument on audio track") }
                let player = AVAudioPlayerNode(); engine.attach(player)
                engine.connect(player, to: runtime.mixer, format: format)
                runtime.player = player
            } else {
                guard let instrument = track.instrument, instrument.pluginID == MusicNativeBuiltins.synth,
                      instrument.stateBlob.isEmpty else { throw MusicNativeError.unsupported("missing or unsupported instrument") }
                let bank = try MusicSynthBank(engine: engine, format: format,
                                             parameters: instrument.parameters, preset: instrument.presetIndex)
                if !instrument.enabled { bank.mixer.outputVolume = 0 }
                engine.connect(bank.mixer, to: runtime.mixer, format: format)
                runtime.synth = bank
                for clip in track.clips {
                    guard case .midi(let midi) = clip.body else { continue }
                    for note in midi.notes {
                        let token = "\(clip.id.rawValue):\(note.id)"
                        let on = try clip.sample(atRelativeTick: note.startTick.value, tempoMap: document.tempoMap).value
                        let off = try clip.sample(atRelativeTick: note.startTick.value + note.durationTicks, tempoMap: document.tempoMap).value
                        events.append(MusicSynthEvent(sample: on, trackID: track.id, token: token, note: note, controller: nil, priority: 1))
                        events.append(MusicSynthEvent(sample: off, trackID: track.id, token: token, note: nil, controller: nil, priority: 0))
                    }
                    for point in midi.controllerPoints {
                        guard [1, 64, 128].contains(point.controller) else { throw MusicNativeError.unsupported("MIDI controller \(point.controller)") }
                        events.append(MusicSynthEvent(sample: try clip.sample(atRelativeTick: point.tick.value, tempoMap: document.tempoMap).value,
                                                     trackID: track.id, token: "", note: nil, controller: point, priority: 2))
                    }
                }
                events.append(MusicSynthEvent(sample: contentEnd, trackID: track.id, token: "", note: nil,
                                             controller: try MusicMIDIControllerPoint(controller: 64, tick: MusicTick(0), value: 0), priority: 3))
            }
            let effect = try effects(track.effects, input: runtime.mixer, engine: engine, format: format)
            let output = fader(input: effect, strip: track.strip, engine: engine, format: format, retained: &faders)
            var destinations: [AVAudioConnectionPoint] = []
            guard let main = busNodes[track.outputBusID] else { throw MusicNativeError.invalid("output bus") }
            destinations.append(AVAudioConnectionPoint(node: main, bus: main.nextAvailableInputBus))
            for send in track.sends {
                guard !send.preFader, let target = busNodes[send.busID] else { throw MusicNativeError.unsupported("pre-fader or missing send") }
                let sendInput = AVAudioMixerNode(); engine.attach(sendInput)
                let sendGain = fader(input: sendInput, strip: try MusicStripSettings(gain: send.gain), engine: engine, format: format, retained: &faders)
                engine.connect(sendGain, to: target, fromBus: 0, toBus: target.nextAvailableInputBus, format: format)
                destinations.append(AVAudioConnectionPoint(node: sendInput, bus: 0))
            }
            engine.connect(output, to: destinations, fromBus: 0, format: format)
            tracks[track.id] = runtime
        }
        for lane in document.automationLanes {
            guard lane.target == .trackGain,
                  audible.contains(where: { $0.id.rawValue == lane.ownerID && $0.kind == .audio }) else {
                throw MusicNativeError.unsupported("automation target \(lane.target.rawValue)")
            }
        }
        events.sort { $0.sample == $1.sample ? $0.priority < $1.priority : $0.sample < $1.sample }
        phase = "enable offline audio graph"
        try engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: 1024)
        phase = "start offline audio graph"
        try engine.start()
        guard let outputBuffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1024) else { throw MusicNativeError.invalid("render buffer") }
        phase = "create output file"
        var writer: AVAudioFile? = try AVAudioFile(forWriting: staged, settings: musicPCMFileSettings(format))
        var position: Int64 = 0
        var nextEvent = 0
        while position < totalFrames {
            try Task.checkCancellation()
            try lease.validate(document: document)
            while nextEvent < events.count, events[nextEvent].sample <= position {
                let event = events[nextEvent]
                if let bank = tracks[event.trackID]?.synth {
                    if let point = event.controller {
                        switch point.controller {
                        case 64: bank.sustain(point.value >= 64)
                        case 1: bank.setModulation(Float(point.value) / 127)
                        default: bank.pitchBend(Float(point.value - 8192) / (point.value >= 8192 ? 8191 : 8192))
                        }
                    } else if let note = event.note { bank.noteOn(token: event.token, note: note.pitch, velocity: note.velocity, channel: note.channel) }
                    else { bank.noteOff(token: event.token) }
                }
                nextEvent += 1
            }
            let nextBoundary = nextEvent < events.count ? events[nextEvent].sample : totalFrames
            let count = AVAudioFrameCount(min(1024, min(totalFrames - position, max(1, nextBoundary - position))))
            for runtime in tracks.values where runtime.player != nil {
                let buffer = try audioBuffer(track: runtime.track, at: position, count: count, format: format,
                                             files: sourceFiles, automation: document.automationLanes)
                runtime.player!.scheduleBuffer(buffer)
                if !runtime.player!.isPlaying { runtime.player!.play() }
            }
            var retries = 0
            while true {
                phase = "render audio at sample \(position)"
                let status = try engine.renderOffline(count, to: outputBuffer)
                if status == .success { break }
                retries += 1
                guard status == .cannotDoInCurrentContext, retries < 8 else { throw MusicNativeError.render("manual render status \(status.rawValue)") }
            }
            guard outputBuffer.frameLength == count else { throw MusicNativeError.render("short rendered buffer") }
            guard let pcm = outputBuffer.floatChannelData,
                  (0..<2).allSatisfy({ channel in (0..<Int(count)).allSatisfy { pcm[channel][$0].isFinite } }) else {
                throw MusicNativeError.render("nonfinite rendered audio")
            }
            phase = "write output at sample \(position)"
            try writer?.write(from: outputBuffer)
            position += Int64(count)
            onProgress(position)
        }
        for runtime in tracks.values { runtime.synth?.allOff(); runtime.player?.stop() }
        engine.stop(); writer = nil
        phase = "commit rendered audio"
        try musicSynchronize(staged)
        let digest = try MusicAudioPreparation.hashFile(staged)
        try lease.commit(staged: staged, destination: destination)
        return MusicRenderReceipt(projectID: document.id.rawValue, revision: document.revision, frames: totalFrames,
                                  sampleRate: document.tempoMap.sampleRate, tailFrames: tailFrames, sha256: digest, file: destination)
    }

    private func fader(input: AVAudioNode, strip: MusicStripSettings, engine: AVAudioEngine, format: AVAudioFormat,
                       retained: inout [AudioKitEX.Fader]) -> AVAudioNode {
        let node = AudioKitEX.Fader(MusicAudioNodeReference(input, format: format))
        let angle = (strip.pan + 1) * Double.pi / 4
        let gain = strip.muted ? 0 : strip.gain
        // Explicit stereo channel gains preserve unity at center and apply
        // consistently across effects, sends and the final master route.
        node.leftGain = Float(gain * cos(angle) * sqrt(2))
        node.rightGain = Float(gain * sin(angle) * sqrt(2))
        engine.attach(node.avAudioNode)
        engine.connect(input, to: node.avAudioNode, format: format)
        retained.append(node)
        return node.avAudioNode
    }

    private func route(_ input: AVAudioNode, to ids: [MusicBus.MusicBusID], nodes: [MusicBus.MusicBusID: AVAudioMixerNode],
                       engine: AVAudioEngine, format: AVAudioFormat) throws {
        let points = try ids.map { id -> AVAudioConnectionPoint in
            guard let node = nodes[id] else { throw MusicNativeError.invalid("bus route") }
            return AVAudioConnectionPoint(node: node, bus: node.nextAvailableInputBus)
        }
        engine.connect(input, to: points, fromBus: 0, format: format)
    }

    private func effects(_ states: [MusicPluginState], input: AVAudioNode, engine: AVAudioEngine, format: AVAudioFormat) throws -> AVAudioNode {
        var output = input
        for state in states where state.enabled {
            guard state.stateBlob.isEmpty, state.presetIndex == 0 else { throw MusicNativeError.unsupported("opaque effect or preset state") }
            let effect: AVAudioNode
            if state.pluginID == MusicNativeBuiltins.eq {
                guard Set(state.parameters.keys).isSubset(of: ["frequency", "gainDB", "bandwidth"]) else { throw MusicNativeError.unsupported("EQ parameter") }
                let unit = AVAudioUnitEQ(numberOfBands: 1)
                let frequency = state.parameters["frequency"] ?? 1000, gain = state.parameters["gainDB"] ?? 0, bandwidth = state.parameters["bandwidth"] ?? 1
                guard (20...20_000).contains(frequency), (-96...24).contains(gain), (0.05...5).contains(bandwidth) else { throw MusicNativeError.invalid("EQ range") }
                unit.bands[0].filterType = .parametric
                unit.bands[0].frequency = Float(frequency); unit.bands[0].gain = Float(gain)
                unit.bands[0].bandwidth = Float(bandwidth); unit.bands[0].bypass = false
                effect = unit
            } else if state.pluginID == MusicNativeBuiltins.reverb {
                guard Set(state.parameters.keys).isSubset(of: ["mix"]) else { throw MusicNativeError.unsupported("reverb parameter") }
                let mix = state.parameters["mix"] ?? 1
                guard (0...1).contains(mix) else { throw MusicNativeError.invalid("reverb mix") }
                let unit = AVAudioUnitReverb(); unit.loadFactoryPreset(.mediumRoom); unit.wetDryMix = Float(mix * 100)
                effect = unit
            } else { throw MusicNativeError.unsupported("effect \(state.pluginID)") }
            engine.attach(effect); engine.connect(output, to: effect, format: format); output = effect
        }
        return output
    }

    private func audioBuffer(track: FloeMusicCore.MusicTrack, at position: Int64, count: AVAudioFrameCount, format: AVAudioFormat,
                             files: [MusicAssetID: AVAudioFile], automation: [MusicAutomationLane]) throws -> AVAudioPCMBuffer {
        guard let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: count), let destination = output.floatChannelData else {
            throw MusicNativeError.invalid("track buffer")
        }
        output.frameLength = count
        for channel in 0..<2 { destination[channel].initialize(repeating: 0, count: Int(count)) }
        for clip in track.clips {
            guard case .audio(let payload) = clip.body, let file = files[payload.assetID] else { continue }
            let start = max(position, clip.offset.value)
            let end = min(position + Int64(count), clip.offset.value + payload.durationSamples)
            guard end > start, let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(end - start)) else { continue }
            file.framePosition = payload.trimStartSamples + start - clip.offset.value
            try file.read(into: buffer, frameCount: AVAudioFrameCount(end - start))
            guard buffer.frameLength == AVAudioFrameCount(end - start), let pcm = buffer.floatChannelData else { throw MusicNativeError.render("short clip read") }
            let pan = (payload.pan + 1) * Double.pi / 4
            let gains = [Float(cos(pan) * sqrt(2)), Float(sin(pan) * sqrt(2))]
            for index in 0..<Int(buffer.frameLength) {
                let relative = start - clip.offset.value + Int64(index)
                var fade: Double = 1
                if payload.fadeInSamples > 0 { fade = min(fade, Double(relative) / Double(payload.fadeInSamples)) }
                if payload.fadeOutSamples > 0 { fade = min(fade, Double(payload.durationSamples - relative) / Double(payload.fadeOutSamples)) }
                var gain = Float(payload.gain * max(0, fade))
                for lane in automation where lane.ownerID == track.id.rawValue && lane.target == .trackGain {
                    gain *= Float(automationValue(lane.points, at: start + Int64(index)))
                }
                let target = Int(start - position) + index
                for channel in 0..<2 { destination[channel][target] += pcm[channel][index] * gain * gains[channel] }
            }
        }
        return output
    }

    private func automationValue(_ points: [MusicAutomationPoint], at sample: Int64) -> Double {
        guard let first = points.first, let last = points.last else { return 1 }
        if sample <= first.sample.value { return first.value }
        if sample >= last.sample.value { return last.value }
        for index in points.indices.dropFirst() where sample <= points[index].sample.value {
            let left = points[index - 1], right = points[index]
            let fraction = Double(sample - left.sample.value) / Double(right.sample.value - left.sample.value)
            return left.value + (right.value - left.value) * fraction
        }
        return last.value
    }
}
