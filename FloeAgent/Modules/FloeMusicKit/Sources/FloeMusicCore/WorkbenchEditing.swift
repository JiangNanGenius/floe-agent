import Foundation

/// Shared by the native timeline and agent commands. These helpers produce
/// one batch for the existing revision-checked store; they do not save files.
public enum MusicWorkbenchEditing {
    public static func duplicate(_ clip: MusicClip, tempoMap: MusicTempoMap) throws -> MusicClip {
        var copy = clip
        copy.id = MusicClipID()
        copy.offset = try clip.endSample(tempoMap: tempoMap)
        return copy
    }

    public static func split(_ clip: MusicClip, at sample: MusicSampleTime,
                             tempoMap: MusicTempoMap) throws -> [MusicEditOp] {
        let end = try clip.endSample(tempoMap: tempoMap)
        guard sample.value > clip.offset.value, sample.value < end.value else {
            throw MusicError.invalidClip(reason: "split must be inside the clip")
        }
        var left = clip
        var right = clip
        right.id = MusicClipID()
        right.offset = sample
        switch clip.body {
        case .audio(let payload):
            let length = sample.value - clip.offset.value
            var a = payload, b = payload
            a.durationSamples = length
            a.fadeInSamples = min(payload.fadeInSamples, length)
            a.fadeOutSamples = 0
            b.trimStartSamples += length
            b.durationSamples -= length
            b.fadeInSamples = 0
            b.fadeOutSamples = min(payload.fadeOutSamples, b.durationSamples)
            left.body = .audio(a); right.body = .audio(b)
        case .midi(let payload):
            let anchor = try tempoMap.tick(atSample: clip.offset).value
            let boundary = try tempoMap.tick(atSample: sample).value - anchor
            guard boundary > 0, boundary < payload.durationTicks else {
                throw MusicError.invalidMIDI(reason: "split is outside the musical clip")
            }
            // Snap the second half to the exact musical boundary so a tempo
            // change never shifts the surviving notes by a rounded sample.
            right.offset = try clip.sample(atRelativeTick: boundary, tempoMap: tempoMap)
            left.body = .midi(try midiRange(payload, lower: 0, upper: boundary))
            right.body = .midi(try midiRange(payload, lower: boundary, upper: payload.durationTicks))
        }
        return [.updateClip(left), .insertClip(right)]
    }

    public static func trim(_ clip: MusicClip, start: MusicSampleTime,
                            end: MusicSampleTime, tempoMap: MusicTempoMap) throws -> MusicClip {
        let originalEnd = try clip.endSample(tempoMap: tempoMap)
        guard start.value >= clip.offset.value, end.value <= originalEnd.value,
              end.value > start.value else {
            throw MusicError.invalidClip(reason: "trim must remain inside the clip")
        }
        var result = clip
        result.offset = start
        switch clip.body {
        case .audio(var payload):
            payload.trimStartSamples += start.value - clip.offset.value
            payload.durationSamples = end.value - start.value
            payload.fadeInSamples = min(payload.fadeInSamples, payload.durationSamples / 2)
            payload.fadeOutSamples = min(payload.fadeOutSamples, payload.durationSamples / 2)
            result.body = .audio(payload)
        case .midi(let payload):
            let anchor = try tempoMap.tick(atSample: clip.offset).value
            let lower = try tempoMap.tick(atSample: start).value - anchor
            let upper = try tempoMap.tick(atSample: end).value - anchor
            guard lower >= 0, upper <= payload.durationTicks, upper > lower else {
                throw MusicError.invalidMIDI(reason: "invalid musical trim")
            }
            result.offset = try clip.sample(atRelativeTick: lower, tempoMap: tempoMap)
            result.body = .midi(try midiRange(payload, lower: lower, upper: upper))
        }
        return result
    }

    public static func quantize(_ clip: MusicClip, gridTicks: Int64) throws -> MusicClip {
        guard case .midi(var payload) = clip.body, gridTicks > 0 else {
            throw MusicError.invalidMIDI(reason: "quantize requires a MIDI clip and positive grid")
        }
        for index in payload.notes.indices {
            let note = payload.notes[index]
            let snapped = Int64((Double(note.startTick.value) / Double(gridTicks)).rounded()) * gridTicks
            payload.notes[index].startTick = MusicTick(min(max(0, snapped), payload.durationTicks - 1))
            payload.notes[index].durationTicks = min(note.durationTicks,
                payload.durationTicks - payload.notes[index].startTick.value)
        }
        var result = clip; result.body = .midi(payload)
        return result
    }

    private static func midiRange(_ payload: MusicMIDIClipPayload, lower: Int64,
                                  upper: Int64) throws -> MusicMIDIClipPayload {
        let notes = try payload.notes.compactMap { note -> MusicMIDINote? in
            let start = max(lower, note.startTick.value)
            let end = min(upper, note.startTick.value + note.durationTicks)
            guard end > start else { return nil }
            return try MusicMIDINote(id: note.id, pitch: note.pitch,
                startTick: MusicTick(start - lower), durationTicks: end - start,
                velocity: note.velocity, channel: note.channel)
        }
        var points = payload.controllerPoints.filter { $0.tick.value >= lower && $0.tick.value < upper }
        // Restore each controller's last value at the new clip start.
        if lower > 0 {
            for key in Set(payload.controllerPoints.map { $0.controller * 16 + $0.channel }) {
                let controller = key / 16, channel = key % 16
                if !points.contains(where: { $0.controller == controller && $0.channel == channel && $0.tick.value == lower }),
                   var previous = payload.controllerPoints.last(where: { $0.controller == controller && $0.channel == channel && $0.tick.value < lower }) {
                    previous.tick = MusicTick(lower)
                    points.append(previous)
                }
            }
        }
        points = points.map { point in var copy = point; copy.tick = MusicTick(point.tick.value - lower); return copy }
        points.sort { ($0.controller, $0.channel, $0.tick.value) < ($1.controller, $1.channel, $1.tick.value) }
        var programs = payload.programChanges.filter { $0.tick.value >= lower && $0.tick.value < upper }
        if lower > 0 {
            for channel in Set(payload.programChanges.map(\.channel)) {
                if !programs.contains(where: { $0.channel == channel && $0.tick.value == lower }),
                   var previous = payload.programChanges.last(where: { $0.channel == channel && $0.tick.value < lower }) {
                    previous.tick = .init(lower); programs.append(previous)
                }
            }
        }
        programs = programs.map { var copy = $0; copy.tick = .init(copy.tick.value - lower); return copy }
        programs.sort { ($0.channel, $0.tick.value) < ($1.channel, $1.tick.value) }
        return try MusicMIDIClipPayload(durationTicks: upper - lower, notes: notes, controllerPoints: points, programChanges: programs)
    }
}
