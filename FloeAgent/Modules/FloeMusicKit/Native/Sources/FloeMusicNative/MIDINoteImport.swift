@preconcurrency import AudioKit
import Foundation
import FloeMusicCore

public struct MusicImportedNoteSequence: Sendable {
    public let source: MusicAsset
    public let tempoMap: MusicTempoMap
    public let tracks: [FloeMusicCore.MusicTrack]
    /// Notes and tempo are imported; the complete original SMF remains an
    /// immutable asset. Controller/meter/meta editing is a later exchange gate.
    public let supportedSubset = "notes-and-tempo"
}

public enum MusicMIDINoteImport {
    public static func read(url: URL, sampleRate: Int = 48_000) throws -> MusicImportedNoteSequence {
        guard url.isFileURL else { throw MusicNativeError.invalid("MIDI source URL") }
        let digest = try MusicAudioPreparation.hashFile(url)
        let sequence = AppleSequencer(fromURL: url)
        let ppq = 960
        var segments: [Int64: MusicTempoSegment] = [0: try MusicTempoSegment(startTick: MusicTick(0), bpm: sequence.getTempo(at: 0), beatsPerBar: 4, beatUnit: 4)]
        for (beat, bpm) in sequence.allTempoEvents {
            let tick = beat * Double(ppq)
            guard tick.isFinite, tick >= 0, tick < 9.0e18 else { throw MusicNativeError.invalid("MIDI tempo time") }
            let value = Int64(tick.rounded())
            segments[value] = try MusicTempoSegment(startTick: MusicTick(value), bpm: bpm, beatsPerBar: 4, beatUnit: 4)
        }
        let tempo = try MusicTempoMap(ticksPerQuarter: ppq, sampleRate: sampleRate, segments: segments.keys.sorted().map { segments[$0]! })
        var tracks: [FloeMusicCore.MusicTrack] = []
        var totalTicks: Int64 = 0
        for sourceTrack in sequence.tracks {
            let data = sourceTrack.getMIDINoteData()
            guard !data.isEmpty else { continue }
            var notes: [MusicMIDINote] = []
            var end: Int64 = 1
            for item in data {
                let start = item.position.beats * Double(ppq), length = item.duration.beats * Double(ppq)
                guard start.isFinite, length.isFinite, start >= 0, length > 0,
                      start < 9.0e18, length < 9.0e18 else { throw MusicNativeError.invalid("MIDI note time") }
                let tick = Int64(start.rounded()), duration = max(1, Int64(length.rounded()))
                let (last, overflow) = tick.addingReportingOverflow(duration)
                guard !overflow else { throw MusicNativeError.invalid("MIDI note overflow") }
                notes.append(try MusicMIDINote(pitch: Int(item.noteNumber), startTick: MusicTick(tick), durationTicks: duration,
                                              velocity: Int(item.velocity), channel: Int(item.channel)))
                end = max(end, last)
            }
            let id = MusicTrackID()
            let clip = try MusicClip(name: "MIDI", trackID: id, offset: MusicSampleTime(0),
                                     body: .midi(MusicMIDIClipPayload(durationTicks: end, notes: notes)))
            tracks.append(try FloeMusicCore.MusicTrack(id: id, name: "Synth", kind: .midi, clips: [clip],
                                         instrument: MusicPluginState(pluginID: MusicNativeBuiltins.synth)))
            totalTicks = max(totalTicks, end)
        }
        guard !tracks.isEmpty, try MusicAudioPreparation.hashFile(url) == digest else {
            throw MusicNativeError.invalid("empty or changed MIDI note source")
        }
        let source = try MusicAsset(sourceLocator: "host-resolved", contentHash: digest, kind: .midiFile,
                                    durationSamples: tempo.sample(atTick: MusicTick(totalTicks)), name: url.lastPathComponent)
        return MusicImportedNoteSequence(source: source, tempoMap: tempo, tracks: tracks)
    }
}
