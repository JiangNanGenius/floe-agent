import Foundation
import FloeMusicCore

public struct MusicImportedNoteSequence: Sendable {
    public let source: MusicAsset
    public let tempoMap: MusicTempoMap
    public let tracks: [FloeMusicCore.MusicTrack]
    public let originalOnlyEventCount: Int
    public let supportedSubset = "notes-channels-programs-controllers-bend-names-tempo-meter"
}

public enum MusicMIDINoteImport {
    public static func read(url: URL, sampleRate: Int = 48_000, ticksPerQuarter: Int? = nil) throws -> MusicImportedNoteSequence {
        guard url.isFileURL, (try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? Int.max) <= MusicMIDIFileExchange.maximumBytes else {
            throw MusicNativeError.invalid("MIDI source URL or size")
        }
        let digest = try MusicAudioPreparation.hashFile(url)
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        let imported = try MusicMIDIFileExchange.read(data, sampleRate: sampleRate, ticksPerQuarter: ticksPerQuarter)
        guard try MusicAudioPreparation.hashFile(url) == digest else { throw MusicNativeError.invalid("changed MIDI source") }
        let duration = try imported.tracks.flatMap(\.clips).map { try $0.endSample(tempoMap: imported.tempoMap).value }.max() ?? 1
        let provenance = "SMF type \(imported.sourceFormat); editable notes/channels/programs/CC/bend/tempo/meter; \(imported.originalOnlyEventCount) events retained only in original asset; built-in sound is not a General MIDI soundfont"
        let source = try MusicAsset(sourceLocator: "host-resolved", contentHash: digest, kind: .midiFile,
            durationSamples: .init(max(1, duration)), name: url.lastPathComponent, provenance: provenance)
        return MusicImportedNoteSequence(source: source, tempoMap: imported.tempoMap, tracks: imported.tracks, originalOnlyEventCount: imported.originalOnlyEventCount)
    }
}
