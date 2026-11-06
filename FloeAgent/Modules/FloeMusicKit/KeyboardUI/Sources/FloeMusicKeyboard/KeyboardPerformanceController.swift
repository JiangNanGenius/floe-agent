import CoreGraphics
import Foundation
import Observation

/// Why a full or partial performance release happened. Exposed for host
/// logging and tests; the controller already performed the release.
public enum KeyboardReleaseReason: String, Hashable, Sendable {
    case octaveChanged
    case transposeChanged
    case rangeChanged
    case presetChanged
    case ownerChanged
    case sinkReplaced
    case sceneBecameInactive
    case panelClosed
}

/// One key currently held down, with the exact note that was sounded for it.
private struct HeldKey: Hashable {
    var sourcePitch: Int
    var note: PerformanceNote
    var owner: KeyboardOwnerToken
}

/// Main-actor performance state machine between the upstream key view and the
/// host sink. It tracks which physical key is held, which concrete note (and
/// owner) that key sounded, and releases exactly those notes on any change of
/// offset, range, preset, owner, sink or scene state.
///
/// The controller never emits into a replacement owner: ownership and sink
/// changes first release the previous context, and only afterwards can new
/// events with the new context be produced.
@MainActor
@Observable
public final class KeyboardPerformanceController {
    // MARK: - Identity

    /// Instrument track / session currently bound to the keyboard.
    /// Changing it releases every held note, pedal and wheel state to the
    /// previous owner before the new owner takes effect.
    public var owner: KeyboardOwnerToken {
        willSet {
            guard newValue != owner else { return }
            releaseAll(overridingSink: nil, tag: owner)
        }
    }

    /// Host-injected event destination. Assigning a different sink first
    /// performs a full release into the previous sink, so no note-off is ever
    /// delivered into a replacement sink. Re-assigning the same sink is a no-op.
    public var sink: (any KeyboardPerformanceSink)? {
        willSet {
            guard let previous = sink, (newValue as AnyObject?) !== previous else { return }
            releaseAll(overridingSink: previous, tag: owner)
        }
    }

    // MARK: - Performance controls

    /// Octave shift applied to touched keys, in octaves. The panel offers
    /// -3...3; out-of-range resulting pitches are ignored. Changing it releases the
    /// originally sounding pitches.
    public var octaveOffset: Int = 0 {
        willSet {
            guard newValue != octaveOffset else { return }
            releaseHeldKeys(tag: owner)
        }
    }

    /// Semitone transposition applied after the octave offset. Changing it
    /// releases the originally sounding pitches.
    public var transpose: Int = 0 {
        willSet {
            guard newValue != transpose else { return }
            releaseHeldKeys(tag: owner)
        }
    }

    /// Sustain pedal. Forwarded to the host; key releases are not deferred
    /// here — pedal semantics (held voices vs. newly released keys) belong to
    /// the host instrument so MIDI recording stays faithful.
    public var sustain = false {
        didSet {
            guard sustain != oldValue else { return }
            emit(.sustain(owner, sustain))
        }
    }

    /// Pitch-bend normalized to -1...1. Values are clamped; 0 is center.
    private var bendValue: Float = 0
    public var pitchBend: Float {
        get { bendValue }
        set {
            let clamped = newValue.isFinite ? min(1, max(-1, newValue)) : 0
            guard clamped != bendValue else { return }
            bendValue = clamped
            emit(.pitchBend(owner, value: clamped))
        }
    }

    /// Modulation normalized to 0...1. Values are clamped.
    private var modulationValue: Float = 0
    public var modulation: Float {
        get { modulationValue }
        set {
            let clamped = newValue.isFinite ? min(1, max(0, newValue)) : 0
            guard clamped != modulationValue else { return }
            modulationValue = clamped
            emit(.modulation(owner, value: clamped))
        }
    }

    /// How touches map to MIDI velocity.
    public var velocityPolicy: KeyVelocityPolicy

    /// Channel stamped on produced notes.
    public var defaultChannel: UInt8

    /// Source pitches currently held (pre octave/transpose), for host UI such
    /// as external key highlighting.
    public private(set) var heldSourcePitches: [Int] = []

    // MARK: - Init

    public init(
        owner: KeyboardOwnerToken,
        sink: (any KeyboardPerformanceSink)? = nil,
        velocityPolicy: KeyVelocityPolicy = .touchVertical(),
        defaultChannel: UInt8 = 0
    ) {
        self.owner = owner
        self.sink = sink
        self.velocityPolicy = velocityPolicy
        self.defaultChannel = min(15, defaultChannel)
    }

    // MARK: - Key surface entry points (called by the panel from upstream callbacks)

    /// A key went down. `sourcePitch` is the touched MIDI note before
    /// octave/transpose. Re-triggering an already-held key first releases the
    /// previous note instance.
    public func keyDown(sourcePitch pitch: Int, normalizedPoint: CGPoint = CGPoint(x: 0.5, y: 0.8)) {
        guard let note = makeNote(sourcePitch: pitch, normalizedPoint: normalizedPoint) else { return }
        if let previous = heldKeys[pitch] {
            emit(.noteOff(owner: previous.owner, note: previous.note.note, channel: previous.note.channel))
        }
        heldKeys[pitch] = HeldKey(sourcePitch: pitch, note: note, owner: owner)
        heldSourcePitches = heldKeys.keys.sorted()
        emit(.noteOn(owner, note))
    }

    /// A key went up (touch ended, was cancelled, or the key left the touch
    /// set). Releases exactly the note instance that was sounded for this key.
    public func keyUp(sourcePitch pitch: Int) {
        guard let held = heldKeys.removeValue(forKey: pitch) else { return }
        heldSourcePitches = heldKeys.keys.sorted()
        emit(.noteOff(owner: held.owner, note: held.note.note, channel: held.note.channel))
    }

    /// The panel's key range changed. Releases the originally sounding pitches.
    public func noteRangeDidChange() {
        releaseHeldKeys(tag: owner)
    }

    /// The host changed the active preset/voice. Releases the originally
    /// sounding pitches so no voice keeps ringing with the old preset.
    public func presetDidChange() {
        releaseHeldKeys(tag: owner)
    }

    /// Full release of everything this controller owns: per-note note-offs (so
    /// recorded MIDI keeps correct lengths), sustain off and wheel resets, and
    /// an explicit all-notes-off fence as the last event. Call on scene
    /// inactive/background, panel close and disconnect. Owner and sink
    /// replacement perform this automatically.
    public func releaseAll(reason: KeyboardReleaseReason) {
        releaseAll(overridingSink: nil, tag: owner)
    }

    // MARK: - Internals

    private var heldKeys: [Int: HeldKey] = [:]

    /// During a sink-replacement release, events are delivered to the sink
    /// being replaced instead of the (not yet installed) new one.
    private var overridingSink: (any KeyboardPerformanceSink)?

    private func emit(_ event: KeyboardPerformanceEvent) {
        if let overridingSink {
            overridingSink.receive(event)
        } else {
            sink?.receive(event)
        }
    }

    private func makeNote(sourcePitch pitch: Int, normalizedPoint: CGPoint) -> PerformanceNote? {
        guard (0...127).contains(pitch) else { return nil }
        let (octave, octaveOverflow) = octaveOffset.multipliedReportingOverflow(by: 12)
        let (offset, offsetOverflow) = pitch.addingReportingOverflow(octave)
        let (shifted, transposeOverflow) = offset.addingReportingOverflow(transpose)
        guard !octaveOverflow, !offsetOverflow, !transposeOverflow else { return nil }
        guard (0...127).contains(shifted) else { return nil }
        return PerformanceNote(
            note: UInt8(shifted),
            velocity: velocityPolicy.velocity(for: normalizedPoint),
            channel: min(15, defaultChannel)
        )
    }

    /// Partial release: only held keys, keeping pedal / wheel state.
    private func releaseHeldKeys(tag: KeyboardOwnerToken) {
        // Pedal-held voices may remain after every physical key has been released.
        guard !heldKeys.isEmpty || sustain else { return }
        let held = heldKeys.values.sorted { $0.sourcePitch < $1.sourcePitch }
        heldKeys.removeAll()
        heldSourcePitches = []
        for key in held {
            emit(.noteOff(owner: key.owner, note: key.note.note, channel: key.note.channel))
        }
        emit(.allNotesOff(tag))
        // allNotesOff resets the host's controllers too. Reapply the controls
        // retained by this surface so its next note agrees with its visible state.
        if sustain { emit(.sustain(tag, true)) }
        if pitchBend != 0 { emit(.pitchBend(tag, value: pitchBend)) }
        if modulation != 0 { emit(.modulation(tag, value: modulation)) }
    }

    /// Full release, tagged for `tag`, optionally delivered to a sink that is
    /// being replaced. State resets flow through the property observers so the
    /// controller state and emitted events can never drift apart.
    private func releaseAll(overridingSink override: (any KeyboardPerformanceSink)?, tag: KeyboardOwnerToken) {
        let previousOverride = overridingSink
        overridingSink = override ?? previousOverride
        defer { overridingSink = previousOverride }

        let held = heldKeys.values.sorted { $0.sourcePitch < $1.sourcePitch }
        heldKeys.removeAll()
        heldSourcePitches = []
        for key in held {
            emit(.noteOff(owner: key.owner, note: key.note.note, channel: key.note.channel))
        }
        if sustain {
            sustain = false
        }
        if pitchBend != 0 {
            pitchBend = 0
        }
        if modulation != 0 {
            modulation = 0
        }
        emit(.allNotesOff(tag))
    }
}
