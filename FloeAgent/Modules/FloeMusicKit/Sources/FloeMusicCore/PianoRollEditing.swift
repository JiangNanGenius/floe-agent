import Foundation

/// Musical grid shared by the piano-roll UI and model-authored edit batches.
public enum MusicPianoRollGrid: Int, Codable, Sendable, CaseIterable {
    case free = 0, quarter = 1, eighth = 2, eighthTriplet = 3, sixteenth = 4, thirtySecond = 8
    public func ticks(ticksPerQuarter: Int) -> Int64 { rawValue == 0 ? 1 : max(1, Int64(ticksPerQuarter / rawValue)) }
    public func snapped(_ tick: Int64, ticksPerQuarter: Int) -> Int64 {
        let step = ticks(ticksPerQuarter: ticksPerQuarter)
        let remainder = tick % step
        let floor = tick - remainder
        if remainder >= (step + 1) / 2, floor <= Int64.max - step { return floor + step }
        return floor
    }
}

public struct MusicMIDINoteClipboard: Codable, Sendable, Hashable {
    public let notes: [MusicMIDINote]
    public init(notes: [MusicMIDINote]) throws {
        guard !notes.isEmpty, notes.count <= MusicMIDIClipPayload.maxNotesPerClip else { throw MusicError.invalidMIDI(reason: "empty or oversized note selection") }
        let anchor = notes.map(\.startTick.value).min() ?? 0
        self.notes = try notes.map { try MusicMIDINote(pitch: $0.pitch, startTick: .init($0.startTick.value - anchor),
                                                      durationTicks: $0.durationTicks, velocity: $0.velocity, channel: $0.channel) }
    }
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(notes: container.decode([MusicMIDINote].self, forKey: .notes))
    }
}

public enum MusicPianoRollEditing {
    public enum Edge: Sendable { case start, end }

    /// Clamp one group delta, preserving intervals and rhythm at every boundary.
    public static func move(_ payload: MusicMIDIClipPayload, selection: Set<String>, ticks: Int64, semitones: Int) throws -> MusicMIDIClipPayload {
        let notes = payload.notes.filter { selection.contains($0.id) }
        guard !notes.isEmpty else { return payload }
        let lower = -(notes.map(\.startTick.value).min() ?? 0)
        let upper = notes.map { payload.durationTicks - $0.startTick.value - $0.durationTicks }.min() ?? 0
        let dt = min(max(ticks, lower), upper)
        let dp = min(max(semitones, -(notes.map(\.pitch).min() ?? 0)), 127 - (notes.map(\.pitch).max() ?? 127))
        var copy = payload
        for index in copy.notes.indices where selection.contains(copy.notes[index].id) {
            copy.notes[index].startTick = .init(copy.notes[index].startTick.value + dt)
            copy.notes[index].pitch += dp
        }
        return try checked(copy)
    }

    public static func resize(_ payload: MusicMIDIClipPayload, selection: Set<String>, edge: Edge, ticks: Int64) throws -> MusicMIDIClipPayload {
        let notes = payload.notes.filter { selection.contains($0.id) }
        guard !notes.isEmpty else { return payload }
        let lower: Int64, upper: Int64
        switch edge {
        case .end:
            lower = 1 - (notes.map(\.durationTicks).min() ?? 1)
            upper = notes.map { payload.durationTicks - $0.startTick.value - $0.durationTicks }.min() ?? 0
        case .start:
            lower = -(notes.map(\.startTick.value).min() ?? 0)
            upper = (notes.map(\.durationTicks).min() ?? 1) - 1
        }
        let dt = min(max(ticks, lower), upper)
        var copy = payload
        for index in copy.notes.indices where selection.contains(copy.notes[index].id) {
            if edge == .start { copy.notes[index].startTick = .init(copy.notes[index].startTick.value + dt); copy.notes[index].durationTicks -= dt }
            else { copy.notes[index].durationTicks += dt }
        }
        return try checked(copy)
    }

    public static func setVelocity(_ payload: MusicMIDIClipPayload, selection: Set<String>, value: Int) throws -> MusicMIDIClipPayload {
        guard (1...127).contains(value) else { throw MusicError.invalidMIDI(reason: "velocity outside [1,127]") }
        var copy = payload
        for index in copy.notes.indices where selection.contains(copy.notes[index].id) { copy.notes[index].velocity = value }
        return try checked(copy)
    }

    public static func paste(_ clipboard: MusicMIDINoteClipboard, into payload: MusicMIDIClipPayload, at tick: Int64) throws -> (MusicMIDIClipPayload, Set<String>) {
        guard tick >= 0, !clipboard.notes.isEmpty, payload.notes.count + clipboard.notes.count <= MusicMIDIClipPayload.maxNotesPerClip else { throw MusicError.invalidMIDI(reason: "paste exceeds note bounds") }
        var copy = payload
        var ids: Set<String> = []
        for note in clipboard.notes {
            let (start, a) = note.startTick.value.addingReportingOverflow(tick)
            let (end, b) = start.addingReportingOverflow(note.durationTicks)
            guard !a, !b else { throw MusicError.invalidMIDI(reason: "paste time overflow") }
            let inserted = try MusicMIDINote(pitch: note.pitch, startTick: .init(start), durationTicks: note.durationTicks, velocity: note.velocity, channel: note.channel)
            copy.notes.append(inserted); ids.insert(inserted.id); copy.durationTicks = max(copy.durationTicks, end)
        }
        return (try checked(copy), ids)
    }

    private static func checked(_ payload: MusicMIDIClipPayload) throws -> MusicMIDIClipPayload {
        try MusicMIDIClipPayload(durationTicks: payload.durationTicks, notes: payload.notes, controllerPoints: payload.controllerPoints, programChanges: payload.programChanges)
    }
}
