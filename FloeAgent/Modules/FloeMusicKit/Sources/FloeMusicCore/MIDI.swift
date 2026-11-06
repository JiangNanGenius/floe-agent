import Foundation

/// A single MIDI note. Pitch/velocity are bounded to the MIDI spec and all
/// times are integer ticks, so decoded notes enforce the same rules as
/// constructed ones.
public struct MusicMIDINote: Sendable, Codable, Hashable, Identifiable {
    public static let minPitch = 0
    public static let maxPitch = 127
    public static let minVelocity = 1
    public static let maxVelocity = 127

    /// Stable note identity within its clip.
    public var id: String
    /// MIDI pitch 0...127 (C-1 ... G9).
    public var pitch: Int
    /// Start position in ticks from the clip start.
    public var startTick: MusicTick
    /// Duration in ticks; strictly positive.
    public var durationTicks: Int64
    /// MIDI velocity 1...127 (0 means note-off; never stored).
    public var velocity: Int
    /// Optional MIDI channel 0...15.
    public var channel: Int

    public init(id: String = UUID().uuidString.lowercased(), pitch: Int,
                startTick: MusicTick, durationTicks: Int64, velocity: Int,
                channel: Int = 0) throws {
        guard pitch >= Self.minPitch, pitch <= Self.maxPitch else {
            throw MusicError.invalidMIDI(reason: "pitch \(pitch) outside [\(Self.minPitch), \(Self.maxPitch)]")
        }
        guard durationTicks > 0 else {
            throw MusicError.invalidMIDI(reason: "note duration must be positive")
        }
        guard velocity >= Self.minVelocity, velocity <= Self.maxVelocity else {
            throw MusicError.invalidMIDI(reason: "velocity \(velocity) outside [\(Self.minVelocity), \(Self.maxVelocity)]")
        }
        guard channel >= 0, channel <= 15 else {
            throw MusicError.invalidMIDI(reason: "channel \(channel) outside [0, 15]")
        }
        guard startTick.value >= 0 else {
            throw MusicError.invalidMIDI(reason: "negative note start tick")
        }
        self.id = id
        self.pitch = pitch
        self.startTick = startTick
        self.durationTicks = durationTicks
        self.velocity = velocity
        self.channel = channel
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let id = try c.decode(String.self, forKey: .id)
        let pitch = try c.decode(Int.self, forKey: .pitch)
        let start = try c.decode(MusicTick.self, forKey: .startTick)
        let dur = try c.decode(Int64.self, forKey: .durationTicks)
        let vel = try c.decode(Int.self, forKey: .velocity)
        let chan = try c.decodeIfPresent(Int.self, forKey: .channel) ?? 0
        do {
            try self.init(id: id, pitch: pitch, startTick: start, durationTicks: dur,
                          velocity: vel, channel: chan)
        } catch let error as MusicError {
            throw DecodingError.dataCorruptedError(forKey: .pitch, in: c,
                                                   debugDescription: error.description)
        }
    }
}

/// Continuous MIDI controller data (pitch bend, modulation, sustain, …) as
/// bounded, tick-sorted points. Values are raw MIDI 7/14-bit integers.
public struct MusicMIDIControllerPoint: Sendable, Codable, Hashable {
    /// MIDI controller number 0...127, or 128 for pitch bend (14-bit).
    public var controller: Int
    public var tick: MusicTick
    public var value: Int

    public init(controller: Int, tick: MusicTick, value: Int) throws {
        guard controller >= 0, controller <= 128 else {
            throw MusicError.invalidMIDI(reason: "controller \(controller) outside [0, 128]")
        }
        let maxValue = controller == 128 ? 16_383 : 127
        guard value >= 0, value <= maxValue else {
            throw MusicError.invalidMIDI(reason: "controller value \(value) outside [0, \(maxValue)]")
        }
        guard tick.value >= 0 else {
            throw MusicError.invalidMIDI(reason: "negative controller tick")
        }
        self.controller = controller
        self.tick = tick
        self.value = value
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let controller = try c.decode(Int.self, forKey: .controller)
        let tick = try c.decode(MusicTick.self, forKey: .tick)
        let value = try c.decode(Int.self, forKey: .value)
        do {
            try self.init(controller: controller, tick: tick, value: value)
        } catch let error as MusicError {
            throw DecodingError.dataCorruptedError(forKey: .value, in: c,
                                                   debugDescription: error.description)
        }
    }
}
