import Foundation

/// Transposition never wraps to another octave or silently removes notes.
public enum MusicPitchRangePolicy: Sendable, Hashable {
    case reject
    case clamp
}

/// Small native starting patterns. Instrument selection belongs to the host;
/// these patterns only add musical data to the requested MIDI track.
public enum MusicPatternTemplate: String, Sendable, CaseIterable, Codable, Hashable, Identifiable {
    case drumGroove
    case chordProgression
    case arpeggio
    case bassLine

    public var id: String { rawValue }

    public var defaultName: String {
        switch self {
        case .drumGroove: "Drum groove"
        case .chordProgression: "Chord progression"
        case .arpeggio: "Arpeggio"
        case .bassLine: "Bass line"
        }
    }
}

/// Pure MIDI edit planners for the existing revision-checked store. The caller
/// commits the returned operations together with its ordinary session owner,
/// save and undo transaction. No files, instruments or project tempo are changed.
public enum MusicPatternTools {
    /// Snap clip-relative note starts to a tick grid. `strength` is 0...1;
    /// `quantizeEnds` also snaps note ends instead of preserving their duration.
    /// Clip/note identities, offset, controllers and track ownership survive.
    /// Clamping at the clip edges always retains at least one audible tick.
    public static func quantize(document: MusicDocument, clipID: MusicClipID,
                                gridTicks: Int64, strength: Double = 1,
                                quantizeEnds: Bool = false) throws -> [MusicEditOp] {
        guard gridTicks > 0, strength.isFinite, (0...1).contains(strength) else {
            throw MusicError.invalidMIDI(reason: "quantize requires a positive grid and strength in 0...1")
        }
        let clip = try midiClip(document: document, clipID: clipID)
        guard case .midi(var payload) = clip.body else { return [] }
        for index in payload.notes.indices {
            let note = payload.notes[index]
            let start = min(payload.durationTicks - 1, blended(
                note.startTick.value, toward: snapped(note.startTick.value, grid: gridTicks,
                                                      upperBound: payload.durationTicks),
                strength: strength))
            let end: Int64
            if quantizeEnds {
                let originalEnd = note.startTick.value + note.durationTicks
                end = max(start + 1, blended(originalEnd,
                    toward: snapped(originalEnd, grid: gridTicks, upperBound: payload.durationTicks),
                    strength: strength))
            } else {
                end = start + min(note.durationTicks, payload.durationTicks - start)
            }
            payload.notes[index].startTick = MusicTick(start)
            payload.notes[index].durationTicks = end - start
        }
        return try update(clip, payload: payload)
    }

    /// Reject the entire plan by default if any pitch leaves MIDI 0...127.
    /// The explicit `.clamp` policy saturates at those limits without dropping
    /// notes. Even extreme Int values are checked before arithmetic can wrap.
    public static func transpose(document: MusicDocument, clipID: MusicClipID,
                                 semitones: Int,
                                 outOfRange: MusicPitchRangePolicy = .reject) throws -> [MusicEditOp] {
        let clip = try midiClip(document: document, clipID: clipID)
        guard case .midi(var payload) = clip.body else { return [] }
        for index in payload.notes.indices {
            let (pitch, overflow) = payload.notes[index].pitch.addingReportingOverflow(semitones)
            if overflow || !(MusicMIDINote.minPitch...MusicMIDINote.maxPitch).contains(pitch) {
                guard outOfRange == .clamp else {
                    throw MusicError.invalidMIDI(reason: "transposition places a note outside MIDI pitch 0...127")
                }
                payload.notes[index].pitch = semitones < 0 ? MusicMIDINote.minPitch : MusicMIDINote.maxPitch
            } else {
                payload.notes[index].pitch = pitch
            }
        }
        return try update(clip, payload: payload)
    }

    /// Add a velocity delta with saturation at 1...127. Velocity zero means
    /// note-off in MIDI, so making a phrase quieter never turns it into silence.
    public static func adjustVelocity(document: MusicDocument, clipID: MusicClipID,
                                      delta: Int) throws -> [MusicEditOp] {
        let clip = try midiClip(document: document, clipID: clipID)
        guard case .midi(var payload) = clip.body else { return [] }
        for index in payload.notes.indices {
            let (velocity, overflow) = payload.notes[index].velocity.addingReportingOverflow(delta)
            payload.notes[index].velocity = overflow
                ? (delta < 0 ? MusicMIDINote.minVelocity : MusicMIDINote.maxVelocity)
                : min(MusicMIDINote.maxVelocity, max(MusicMIDINote.minVelocity, velocity))
        }
        return try update(clip, payload: payload)
    }

    /// Append a new clip to an existing MIDI track, never replace its contents.
    /// Bars follow the meter at `atTick`; tempo changes remain project-owned.
    /// A meter change inside the requested span is rejected rather than guessed.
    /// `rootPitch` is the tonic for I–V–vi–IV (default C4); the bass uses the
    /// same tonic two octaves lower. Drums use GM 36/38/42 on channel 10.
    /// Non-integral PPQN subdivisions are rounded from the absolute pattern
    /// position, avoiding accumulated drift. Patterns are bounded to 1...64 bars.
    public static func insertTemplate(_ template: MusicPatternTemplate,
                                      document: MusicDocument, trackID: MusicTrackID,
                                      atTick: MusicTick, bars: Int = 4,
                                      rootPitch: Int = 60, velocity: Int = 96,
                                      name: String? = nil) throws -> [MusicEditOp] {
        try document.validate()
        guard let track = document.tracks.first(where: { $0.id == trackID }), track.kind == .midi else {
            throw MusicError.invalidTrack(reason: "template requires an existing MIDI track")
        }
        guard track.clips.count < MusicTrack.maxClipsPerTrack else {
            throw MusicError.boundsExceeded(field: "clips", limit: MusicTrack.maxClipsPerTrack)
        }
        guard atTick.value >= 0, (1...64).contains(bars), (0...127).contains(rootPitch),
              (1...127).contains(velocity) else {
            throw MusicError.invalidMIDI(reason: "invalid template position, bar count, pitch or velocity")
        }
        let map = document.tempoMap
        let meter = map.segments[try map.segmentIndex(atTick: atTick)]
        let halfBeatsPerBar = meter.beatsPerBar * 2
        // All products are bounded by validated PPQN, meter and the 64-bar cap.
        func tick(_ halfBeat: Int) -> Int64 {
            let numerator = Int64(halfBeat) * Int64(map.ticksPerQuarter) * 4
            let denominator = Int64(meter.beatUnit) * 2
            let remainder = numerator % denominator
            return numerator / denominator + (remainder * 2 >= denominator ? 1 : 0)
        }
        let duration = tick(bars * halfBeatsPerBar)
        let (endTick, overflow) = atTick.value.addingReportingOverflow(duration)
        guard !overflow else { throw MusicError.invalidMIDI(reason: "template tick range overflows") }
        for segment in map.segments where segment.startTick.value > atTick.value && segment.startTick.value < endTick {
            guard segment.beatsPerBar == meter.beatsPerBar, segment.beatUnit == meter.beatUnit else {
                throw MusicError.invalidTempoMap(reason: "template cannot cross a meter change")
            }
        }
        var notes: [MusicMIDINote] = []
        func add(_ pitch: Int, start: Int64, end: Int64, velocity: Int,
                 channel: Int = 0) throws {
            notes.append(try MusicMIDINote(pitch: pitch, startTick: MusicTick(start),
                durationTicks: max(1, end - start), velocity: max(1, velocity), channel: channel))
        }
        func gatedEnd(_ start: Int64, _ end: Int64) -> Int64 {
            end - max(1, (end - start) / 8)
        }
        let roots = [0, 7, 9, 5]
        for bar in 0..<bars {
            let base = bar * halfBeatsPerBar
            let chordRoot = rootPitch + roots[bar % roots.count]
            let third = bar % roots.count == 2 ? 3 : 4
            switch template {
            case .drumGroove:
                for step in 0..<halfBeatsPerBar {
                    let start = tick(base + step)
                    let end = start + max(1, (tick(base + step + 1) - start) / 3)
                    try add(42, start: start, end: end,
                            velocity: velocity * (step.isMultiple(of: 2) ? 3 : 2) / 4, channel: 9)
                    if step.isMultiple(of: 2) {
                        let beat = step / 2
                        if beat == 0 || (meter.beatsPerBar >= 4 && beat.isMultiple(of: 2)) {
                            try add(36, start: start, end: end, velocity: velocity, channel: 9)
                        }
                        if !beat.isMultiple(of: 2) || (meter.beatsPerBar == 3 && beat == 2) {
                            try add(38, start: start, end: end, velocity: velocity * 7 / 8, channel: 9)
                        }
                    }
                }
            case .chordProgression:
                let start = tick(base), end = gatedEnd(start, tick(base + halfBeatsPerBar))
                for interval in [0, third, 7] {
                    try add(chordRoot + interval, start: start, end: end, velocity: velocity)
                }
            case .arpeggio:
                let intervals = [0, third, 7, third]
                for step in 0..<halfBeatsPerBar {
                    let start = tick(base + step)
                    try add(chordRoot + intervals[step % intervals.count], start: start,
                            end: gatedEnd(start, tick(base + step + 1)),
                            velocity: step.isMultiple(of: 2) ? velocity : velocity * 7 / 8)
                }
            case .bassLine:
                for beat in 0..<meter.beatsPerBar {
                    let start = tick(base + beat * 2)
                    try add(chordRoot - 24 + (beat.isMultiple(of: 2) ? 0 : 7), start: start,
                            end: gatedEnd(start, tick(base + (beat + 1) * 2)),
                            velocity: beat == 0 ? velocity : velocity * 7 / 8)
                }
            }
        }
        let payload = try MusicMIDIClipPayload(durationTicks: duration, notes: notes)
        let clip = try MusicClip(name: name ?? template.defaultName, trackID: trackID,
                                 offset: map.sample(atTick: atTick), body: .midi(payload))
        _ = try clip.endSample(tempoMap: map)
        return [.insertClip(clip)]
    }

    private static func midiClip(document: MusicDocument, clipID: MusicClipID) throws -> MusicClip {
        try document.validate()
        guard let clip = document.tracks.lazy.flatMap(\.clips).first(where: { $0.id == clipID }) else {
            throw MusicError.invalidClip(reason: "unknown clip \(clipID)")
        }
        guard case .midi = clip.body else {
            throw MusicError.invalidMIDI(reason: "editing action requires a MIDI clip")
        }
        return clip
    }

    private static func update(_ clip: MusicClip, payload: MusicMIDIClipPayload) throws -> [MusicEditOp] {
        let validated = try MusicMIDIClipPayload(durationTicks: payload.durationTicks,
            notes: payload.notes, controllerPoints: payload.controllerPoints)
        var result = clip
        result.body = .midi(validated)
        return result == clip ? [] : [.updateClip(result)]
    }

    /// Integer nearest-grid arithmetic keeps odd and very large grids safe.
    /// Ties move forward; the final clip edge may be between grid positions.
    private static func snapped(_ value: Int64, grid: Int64, upperBound: Int64) -> Int64 {
        let remainder = value % grid
        let lower = value - remainder
        guard remainder >= grid - remainder else { return lower }
        let (upper, overflow) = lower.addingReportingOverflow(grid)
        return overflow ? upperBound : min(upper, upperBound)
    }

    private static func blended(_ value: Int64, toward target: Int64, strength: Double) -> Int64 {
        guard strength > 0 else { return value }
        guard strength < 1 else { return target }
        let distance = target >= value ? target - value : value - target
        let rounded = (Double(distance) * strength).rounded(.toNearestOrAwayFromZero)
        // Comparing before conversion also handles Int64.max rounding to 2^63.
        let amount = rounded >= Double(distance) ? distance : Int64(rounded)
        return target >= value ? value + amount : value - amount
    }
}
