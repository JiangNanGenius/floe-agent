import Foundation

/// Stable token identifying the instrument track / session that currently owns
/// the keyboard panel. The host supplies this (e.g. its instrument-track id);
/// every performance event is tagged with the owner that was current when the
/// event was produced, so a host can never route a stale note-off into a
/// replacement owner.
public struct KeyboardOwnerToken: Hashable, Sendable, Codable {
    public var rawValue: String

    public init(_ rawValue: String) {
        self.rawValue = rawValue
    }
}

/// One concrete note instance the host must voice.
public struct PerformanceNote: Hashable, Sendable {
    /// MIDI note number, 0...127.
    public var note: UInt8
    /// MIDI velocity, 0...127. Produced by the controller's velocity policy.
    public var velocity: UInt8
    /// MIDI channel, 0...15.
    public var channel: UInt8

    public init(note: UInt8, velocity: UInt8 = 100, channel: UInt8 = 0) {
        self.note = note
        self.velocity = velocity
        self.channel = channel
    }
}

/// Performance events emitted by the keyboard panel. All values are small,
/// value-typed and `Sendable`; delivery happens on the main actor via
/// `KeyboardPerformanceSink`, never on a DSP/realtime thread.
public enum KeyboardPerformanceEvent: Hashable, Sendable {
    /// A key started sounding. The note values are post octave/transpose.
    case noteOn(KeyboardOwnerToken, PerformanceNote)
    /// A key stopped sounding. `note` is the exact note number that was
    /// originally sounded; the controller never recomputes it on release, so
    /// an octave change while held cannot turn off a newly shifted note.
    case noteOff(owner: KeyboardOwnerToken, note: UInt8, channel: UInt8)
    /// Sustain pedal state.
    case sustain(KeyboardOwnerToken, Bool)
    /// Pitch-bend wheel, normalized to -1.0 ... 1.0 (0.0 = center). The host
    /// maps this to its bend range (commonly ±2 semitones).
    case pitchBend(KeyboardOwnerToken, value: Float)
    /// Modulation wheel, normalized to 0.0 ... 1.0.
    case modulation(KeyboardOwnerToken, value: Float)
    /// Explicit all-off fence for an owner: every held note, pedal and wheel
    /// state for this owner must be released by the host, even if individual
    /// note-offs were missed.
    case allNotesOff(KeyboardOwnerToken)
}
