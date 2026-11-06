import AVFoundation
@preconcurrency import AudioKit
@preconcurrency import AudioKitEX
@preconcurrency import SoundpipeAudioKit
import Foundation

public enum MusicPerformanceMessage: Sendable {
    case noteOn(note: UInt8, velocity: UInt8, channel: UInt8)
    case noteOff(note: UInt8, channel: UInt8)
    case sustain(Bool)
    case pitchBend(Float)
    /// This basic patch maps modulation to a small detuning offset (0...3Hz).
    case modulation(Float)
    case allNotesOff
}

/// Session/category/route ownership stays in the existing host services.
@MainActor
public protocol MusicAudioAuthority: AnyObject {
    func acquirePlayback() throws
    func releasePlayback()
}

/// Reused for both the live instrument and the offline graph. Controls are
/// applied on the owning service executor, never inside our DSP callback.
final class MusicSynthBank {
    final class Voice {
        let oscillator: DynamicOscillator
        let envelope: AmplitudeEnvelope
        var token: String?
        var note = 0
        var channel = 0
        var held = false
        var order = 0
        init(saw: Bool, attack: Float, release: Float) {
            oscillator = DynamicOscillator(waveform: Table(saw ? .sawtooth : .sine), amplitude: 0.12)
            envelope = AmplitudeEnvelope(oscillator, attackDuration: attack, decayDuration: 0.08,
                                         sustainLevel: 0.75, releaseDuration: release)
        }
    }
    let mixer = AVAudioMixerNode()
    private var voices: [Voice] = []
    private var pedal = false
    private var bend: Float = 0
    private var modulation: Float = 0
    private var order = 0

    init(engine: AVAudioEngine, format: AVAudioFormat, parameters: [String: Double] = [:], preset: Int = 0) throws {
        let supported: Set<String> = ["attack", "release", "gain"]
        guard Set(parameters.keys).isSubset(of: supported), [0, 1].contains(preset),
              parameters.values.allSatisfy(\.isFinite) else { throw MusicNativeError.unsupported("synth state") }
        let attack = parameters["attack"] ?? 0.008
        let release = parameters["release"] ?? 0.08
        let gain = parameters["gain"] ?? 1
        guard (0...99).contains(attack), (0...99).contains(release), (0...1).contains(gain) else {
            throw MusicNativeError.invalid("synth parameter range")
        }
        engine.attach(mixer)
        mixer.outputVolume = Float(gain)
        for _ in 0..<8 {
            let voice = Voice(saw: preset == 1, attack: Float(attack), release: Float(release))
            engine.attach(voice.oscillator.avAudioNode)
            engine.attach(voice.envelope.avAudioNode)
            engine.connect(voice.oscillator.avAudioNode, to: voice.envelope.avAudioNode, format: format)
            engine.connect(voice.envelope.avAudioNode, to: mixer, fromBus: 0,
                           toBus: mixer.nextAvailableInputBus, format: format)
            voice.envelope.closeGate()
            voices.append(voice)
        }
    }

    func noteOn(token: String, note: Int, velocity: Int, channel: Int) {
        guard (0...127).contains(note), (1...127).contains(velocity), (0...15).contains(channel) else { return }
        let voice = voices.first(where: { $0.token == token })
            ?? voices.first(where: { $0.token == nil })
            ?? voices.first(where: { !$0.held && !pedal })
            ?? voices.min(by: { $0.order < $1.order })!
        voice.envelope.closeGate()
        order += 1
        voice.token = token; voice.note = note; voice.channel = channel; voice.held = true; voice.order = order
        voice.oscillator.frequency = Float(440 * pow(2, (Double(note) - 69 + Double(bend) * 2) / 12))
        voice.oscillator.detuningOffset = modulation * 3
        voice.oscillator.amplitude = Float(velocity) / 127 * 0.12
        voice.oscillator.start()
        voice.envelope.openGate()
    }

    func noteOff(token: String) {
        guard let voice = voices.first(where: { $0.token == token }) else { return }
        voice.held = false
        if !pedal { voice.envelope.closeGate() }
    }

    func sustain(_ enabled: Bool) {
        pedal = enabled
        if !enabled { for voice in voices where !voice.held { voice.envelope.closeGate() } }
    }

    func pitchBend(_ value: Float) {
        bend = value.isFinite ? min(1, max(-1, value)) : 0
        for voice in voices where voice.token != nil {
            voice.oscillator.frequency = Float(440 * pow(2, (Double(voice.note) - 69 + Double(bend) * 2) / 12))
        }
    }

    func setModulation(_ value: Float) {
        modulation = value.isFinite ? min(1, max(0, value)) : 0
        for voice in voices { voice.oscillator.detuningOffset = modulation * 3 }
    }

    func allOff() {
        pedal = false; bend = 0; modulation = 0
        for voice in voices {
            voice.envelope.closeGate(); voice.oscillator.stop()
            voice.token = nil; voice.held = false
            voice.oscillator.detuningOffset = 0
        }
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
