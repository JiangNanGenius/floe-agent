import AVFoundation
@preconcurrency import AudioKit
@preconcurrency import AudioKitEX
@preconcurrency import SoundpipeAudioKit
import Foundation
import FloeMusicCore

public enum MusicPerformanceMessage: Sendable {
    case noteOn(note: UInt8, velocity: UInt8, channel: UInt8)
    case noteOff(note: UInt8, channel: UInt8)
    case sustain(Bool)
    case pitchBend(Float)
    /// Maps modulation to a small detuning offset (0...3 Hz).
    case modulation(Float)
    case allNotesOff
}

/// Session/category/route ownership stays in the existing host services.
@MainActor
public protocol MusicAudioAuthority: AnyObject {
    func acquirePlayback() throws
    func releasePlayback()
}

/// One interpretation for saved preset indices and parameter overrides. Both
/// live playback and the offline renderer construct MusicSynthBank with this
/// resolver, so exporting never substitutes a different instrument patch.
struct MusicSynthPatch: Equatable, Sendable {
    let presetIndex: Int
    let parameters: [String: Double]

    var waveform: Int { Int(parameters["waveform"]!) }
    var gain: Float { Float(parameters["gain"]!) }
    var oneShot: Bool {
        MusicPresetCatalog.preset(index: presetIndex)?.category == .percussion && parameters["sustain"] == 0
    }

    static func resolve(preset: Int, overrides: [String: Double]) throws -> Self {
        guard let entry = MusicPresetCatalog.preset(index: preset) else {
            throw MusicNativeError.unsupported("synth preset \(preset)")
        }
        let ranges: [String: ClosedRange<Double>] = [
            "waveform": 0...8, "attack": 0...99, "decay": 0...99,
            "sustain": 0...1, "release": 0...99, "gain": 0...1,
            "pulseWidth": 0.05...0.95, "fmRatio": 0.1...16, "fmIndex": 0...12,
            "transpose": -48...48, "fixedNote": -1...127, "detune": -50...50,
            "highpass": 0...20_000, "lowpass": 20...20_000
        ]
        let harmonicKeys = Set((2...8).map { "harmonic\($0)" })
        guard overrides.keys.allSatisfy({ ranges[$0] != nil || harmonicKeys.contains($0) }) else {
            throw MusicNativeError.unsupported("synth parameter")
        }
        var values = entry.parameters
        values.merge(overrides) { _, replacement in replacement }
        for (key, value) in values {
            guard value.isFinite, (ranges[key] ?? (0...1)).contains(value) else {
                throw MusicNativeError.invalid("synth parameter range: \(key)")
            }
        }
        guard values["waveform"]!.rounded() == values["waveform"],
              (values["fixedNote"] ?? -1).rounded() == (values["fixedNote"] ?? -1),
              (values["highpass"] ?? 0) < (values["lowpass"] ?? 20_000) else {
            throw MusicNativeError.invalid("synth waveform, fixed note or filter range")
        }
        if values["waveform"] == 8 {
            let kitKeys: Set<String> = ["waveform", "attack", "decay", "sustain", "release", "gain"]
            guard Set(overrides.keys).isSubset(of: kitKeys) else {
                throw MusicNativeError.unsupported("drum kit parameter")
            }
        }
        return Self(presetIndex: preset, parameters: values)
    }

    func table() -> Table {
        switch waveform {
        case 0: return Table(.sine)
        case 1: return Table(.sawtooth)
        case 2: return Table(.triangle)
        case 3: return Table(.square)
        default:
            // Generate and normalize small, immutable wavetables on the
            // service executor. No allocation or Swift callback in DSP.
            let count = 4096
            var values = [Float](repeating: 0, count: count)
            for index in values.indices {
                let phase = 2 * Double.pi * Double(index) / Double(count)
                var value: Double = 0
                if waveform == 4 {
                    let width = parameters["pulseWidth"] ?? 0.25
                    for harmonic in 1...24 {
                        let n = Double(harmonic)
                        value += 2 * sin(Double.pi * n * width) / (Double.pi * n) * cos(n * phase)
                    }
                } else {
                    value = sin(phase)
                    for harmonic in 2...8 {
                        value += (parameters["harmonic\(harmonic)"] ?? 0) * sin(Double(harmonic) * phase)
                    }
                }
                values[index] = Float(value)
            }
            let peak = max(values.map { abs($0) }.max() ?? 1, 0.0001)
            return Table(values.map { $0 / peak })
        }
    }

    /// Kit voices are allocated before starting the graph. Common envelope
    /// controls scale each drum's own length; no graph mutation on note-on.
    fileprivate func drumPatch(_ family: MusicDrumFamily) throws -> Self {
        let index: Int
        switch family {
        case .kick: index = 35
        case .snare: index = 37
        case .hat: index = 38
        case .tom: index = 36
        }
        var values = MusicPresetCatalog.preset(index: index)!.parameters
        values["attack"] = parameters["attack"]
        values["decay"] = min(99, values["decay"]! * parameters["decay"]! / 0.18)
        values["sustain"] = parameters["sustain"]
        values["release"] = min(99, values["release"]! * parameters["release"]! / 0.04)
        if family == .tom { values["fixedNote"] = -1 }
        return try Self.resolve(preset: index, overrides: values)
    }
}

private enum MusicDrumFamily: CaseIterable {
    case kick, snare, hat, tom
    static func family(note: Int) -> Self {
        switch note {
        case 35, 36: .kick
        case 37, 38, 39, 40: .snare
        case 42, 44, 46, 49, 51, 52, 53, 55, 57, 59: .hat
        default: .tom
        }
    }
}

/// Reused for both the live instrument and the offline graph. Controls are
/// applied on the owning service executor, never inside our DSP callback.
final class MusicSynthBank {
    private enum Source {
        case oscillator(DynamicOscillator)
        case fm(FMOscillator)
        case noise(WhiteNoise)

        var node: any AudioKit.Node {
            switch self {
            case .oscillator(let node): node
            case .fm(let node): node
            case .noise(let node): node
            }
        }

        func amplitude(_ value: Float) {
            switch self {
            case .oscillator(let node): node.amplitude = value
            case .fm(let node): node.amplitude = value
            case .noise(let node): node.amplitude = value
            }
        }

        func frequency(_ value: Float, detune: Float, modulation: Float) {
            switch self {
            case .oscillator(let node):
                node.frequency = value
                node.detuningMultiplier = pow(2, detune / 1_200)
                node.detuningOffset = modulation * 3
            case .fm(let node): node.baseFrequency = min(20_000, value * pow(2, detune / 1_200) + modulation * 3)
            case .noise: break
            }
        }
    }

    private final class Voice {
        let source: Source
        let envelope: AmplitudeEnvelope
        let filter: AVAudioUnitEQ?
        let patch: MusicSynthPatch
        let family: MusicDrumFamily?
        var token: String?
        var note = 0
        var channel = 0
        var held = false
        var order = 0

        init(patch: MusicSynthPatch, family: MusicDrumFamily?, engine: AVAudioEngine,
             format: AVAudioFormat, mixer: AVAudioMixerNode) {
            self.patch = patch
            self.family = family
            let p = patch.parameters
            switch patch.waveform {
            case 6:
                source = .fm(FMOscillator(carrierMultiplier: 1,
                                         modulatingMultiplier: Float(p["fmRatio"] ?? 2),
                                         modulationIndex: Float(p["fmIndex"] ?? 1), amplitude: 0.12))
            case 7: source = .noise(WhiteNoise(amplitude: 0.12))
            default: source = .oscillator(DynamicOscillator(waveform: patch.table(), amplitude: 0.12))
            }
            envelope = AmplitudeEnvelope(source.node, attackDuration: Float(p["attack"]!),
                                         decayDuration: Float(p["decay"]!), sustainLevel: Float(p["sustain"]!),
                                         releaseDuration: Float(p["release"]!))
            let high = p["highpass"] ?? 0, low = p["lowpass"] ?? 20_000
            if high > 0 || low < 20_000 {
                let unit = AVAudioUnitEQ(numberOfBands: 2)
                let ceiling = min(20_000, format.sampleRate * 0.45)
                unit.bands[0].filterType = .highPass
                unit.bands[0].frequency = Float(min(ceiling, max(20, high)))
                unit.bands[0].bypass = high == 0
                unit.bands[1].filterType = .lowPass
                unit.bands[1].frequency = Float(min(ceiling, low))
                unit.bands[1].bypass = low == 20_000
                filter = unit
            } else { filter = nil }
            engine.attach(source.node.avAudioNode)
            engine.attach(envelope.avAudioNode)
            engine.connect(source.node.avAudioNode, to: envelope.avAudioNode, format: format)
            let output: AVAudioNode
            if let filter {
                engine.attach(filter)
                engine.connect(envelope.avAudioNode, to: filter, format: format)
                output = filter
            } else { output = envelope.avAudioNode }
            engine.connect(output, to: mixer, fromBus: 0, toBus: mixer.nextAvailableInputBus, format: format)
            envelope.closeGate()
        }

        func updatePitch(bend: Float, modulation: Float) {
            let p = patch.parameters
            let pitch = (p["fixedNote"] ?? -1) >= 0 ? p["fixedNote"]! : Double(note)
            let hz = 440 * pow(2, (pitch - 69 + (p["transpose"] ?? 0) + Double(bend) * 2) / 12)
            source.frequency(Float(min(20_000, hz)), detune: Float(p["detune"] ?? 0), modulation: modulation)
        }

        func start(velocity: Int, bend: Float, modulation: Float) {
            updatePitch(bend: bend, modulation: modulation)
            if family == .hat {
                let isOpen = [46, 49, 51, 52, 53, 55, 57, 59].contains(note)
                envelope.decayDuration = Float(patch.parameters["decay"]!) * (isOpen ? 8 : 1)
            }
            source.amplitude(Float(velocity) / 127 * 0.12)
            source.node.start()
            envelope.openGate()
        }

        func stop() {
            envelope.closeGate()
            source.node.stop()
            token = nil
            held = false
        }
    }

    let mixer = AVAudioMixerNode()
    let patch: MusicSynthPatch
    private var voices: [Voice] = []
    private var pedal = false
    private var bend: Float = 0
    private var modulation: Float = 0
    private var channelPedals: [Int: Bool] = [:]
    private var channelBends: [Int: Float] = [:]
    private var channelModulations: [Int: Float] = [:]
    private var order = 0

    init(engine: AVAudioEngine, format: AVAudioFormat, parameters: [String: Double] = [:], preset: Int = 0) throws {
        patch = try MusicSynthPatch.resolve(preset: preset, overrides: parameters)
        engine.attach(mixer)
        mixer.outputVolume = patch.gain
        if patch.waveform == 8 {
            for family in MusicDrumFamily.allCases {
                let drum = try patch.drumPatch(family)
                for _ in 0..<2 { voices.append(Voice(patch: drum, family: family, engine: engine, format: format, mixer: mixer)) }
            }
        } else {
            for _ in 0..<8 { voices.append(Voice(patch: patch, family: nil, engine: engine, format: format, mixer: mixer)) }
        }
    }

    func noteOn(token: String, note: Int, velocity: Int, channel: Int) {
        guard (0...127).contains(note), (1...127).contains(velocity), (0...15).contains(channel) else { return }
        let family: MusicDrumFamily? = patch.waveform == 8 ? .family(note: note) : nil
        let eligible = voices.filter { $0.family == family }
        guard let voice = eligible.first(where: { $0.token == token })
            ?? eligible.first(where: { $0.token == nil })
            ?? eligible.filter({ !$0.held && !(channelPedals[$0.channel] ?? pedal) }).min(by: { $0.order < $1.order })
            ?? eligible.min(by: { $0.order < $1.order }) else { return }
        if family == .hat && [42, 44].contains(note) {
            for ringing in eligible where ringing !== voice { ringing.envelope.closeGate() }
        }
        voice.envelope.closeGate()
        order += 1
        voice.token = token; voice.note = note; voice.channel = channel; voice.held = true; voice.order = order
        voice.start(velocity: velocity, bend: channelBends[channel] ?? bend, modulation: channelModulations[channel] ?? modulation)
    }

    func noteOff(token: String) {
        guard let voice = voices.first(where: { $0.token == token }) else { return }
        voice.held = false
        // Percussion reaches zero through its own decay even for a very
        // short MIDI hit. Stop/allOff always terminates it immediately.
        if !(channelPedals[voice.channel] ?? pedal) && !voice.patch.oneShot { voice.envelope.closeGate() }
    }

    func sustain(_ enabled: Bool, channel: Int? = nil) {
        if let channel { channelPedals[channel] = enabled } else { pedal = enabled; channelPedals = [:] }
        if !enabled {
            for voice in voices where !voice.held && !voice.patch.oneShot && (channel == nil || voice.channel == channel) { voice.envelope.closeGate() }
        }
    }

    func pitchBend(_ value: Float, channel: Int? = nil) {
        let amount = value.isFinite ? min(1, max(-1, value)) : 0
        if let channel { channelBends[channel] = amount } else { bend = amount; channelBends = [:] }
        for voice in voices where voice.token != nil && (channel == nil || voice.channel == channel) {
            voice.updatePitch(bend: channelBends[voice.channel] ?? bend, modulation: channelModulations[voice.channel] ?? modulation)
        }
    }

    func setModulation(_ value: Float, channel: Int? = nil) {
        let amount = value.isFinite ? min(1, max(0, value)) : 0
        if let channel { channelModulations[channel] = amount } else { modulation = amount; channelModulations = [:] }
        for voice in voices where voice.token != nil && (channel == nil || voice.channel == channel) {
            voice.updatePitch(bend: channelBends[voice.channel] ?? bend, modulation: channelModulations[voice.channel] ?? modulation)
        }
    }

    func allOff() {
        pedal = false; bend = 0; modulation = 0; order = 0
        channelPedals = [:]; channelBends = [:]; channelModulations = [:]
        for voice in voices { voice.stop() }
    }

    func receive(_ message: MusicPerformanceMessage, owner: String) throws {
        switch message {
        case .noteOn(let note, let velocity, let channel):
            guard note < 128, velocity > 0, velocity < 128, channel < 16 else { throw MusicNativeError.invalid("MIDI note") }
            noteOn(token: "\(owner):\(channel):\(note)", note: Int(note), velocity: Int(velocity), channel: Int(channel))
        case .noteOff(let note, let channel): noteOff(token: "\(owner):\(channel):\(note)")
        case .sustain(let enabled): sustain(enabled)
        case .pitchBend(let value): pitchBend(value)
        case .modulation(let value): setModulation(value)
        case .allNotesOff: allOff()
        }
    }
}

@MainActor
public final class MusicLiveInstrument {
    private let engine = AVAudioEngine()
    private let bank: MusicSynthBank
    private let authority: any MusicAudioAuthority
    public let ownerToken: String
    public private(set) var isRunning = false
    public var presetIndex: Int { bank.patch.presetIndex }
    public var resolvedParameters: [String: Double] { bank.patch.parameters }

    public init(ownerToken: String, authority: any MusicAudioAuthority, preset: Int = 0,
                parameters: [String: Double] = [:]) throws {
        guard !ownerToken.isEmpty, let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2) else {
            throw MusicNativeError.invalid("instrument owner or format")
        }
        self.ownerToken = ownerToken
        self.authority = authority
        bank = try MusicSynthBank(engine: engine, format: format, parameters: parameters, preset: preset)
        engine.connect(bank.mixer, to: engine.mainMixerNode, format: format)
        engine.mainMixerNode.outputVolume = 0.8
    }

    public func start() throws {
        guard !isRunning else { return }
        try authority.acquirePlayback()
        do { try engine.start(); isRunning = true }
        catch { authority.releasePlayback(); throw error }
    }

    public func send(_ message: MusicPerformanceMessage, ownerToken: String) throws {
        guard isRunning, self.ownerToken == ownerToken else { throw MusicNativeError.staleOwner }
        try bank.receive(message, owner: ownerToken)
    }

    public func stop() {
        bank.allOff()
        engine.stop()
        if isRunning { isRunning = false; authority.releasePlayback() }
    }
}
