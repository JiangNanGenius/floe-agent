// SPDX-License-Identifier: MPL-2.0
#if canImport(UIKit)
import Foundation
import CoreFoundation
import FloeCore
import FloeMusicCore
import FloeMusicNative

/// Model-facing editing uses the same validated native operations as the UI.
/// The document supplied here is the host's fresh, authorized original.
enum StudioMusicEditingContract {
    static func decode(_ json: String, document: MusicDocument) throws -> [MusicEditOp] {
        do { return try MusicEditJSONCodec.decode(json, document: document) }
        catch let error as MusicEditJSONError {
            let title = IDELanguageRunText.t("音乐编辑参数有误", "Invalid music edit")
            throw FloeError.validationFailed("\(title) [\(error.code)] at \(error.path): \(error.reason). Expected: \(error.expected). \(error.recovery)")
        }
    }

    static func guide(document: MusicDocument?, ticksPerQuarter: Int) -> String {
        guard (MusicTempoMap.minTicksPerQuarter...MusicTempoMap.maxTicksPerQuarter).contains(ticksPerQuarter) else {
            return "Read a valid current MusicDocument tempo map before editing musical ticks."
        }
        let quarter = Int64(ticksPerQuarter)
        var guide = "Preferred MIDI clip editing format: operationsJSON is a JSON ARRAY of explicit commands. IDs are plain strings and note startTick/durationTicks are integer musical ticks in this format. Do not mix these commands with the legacy Codable cases below in one batch. Outer expectedRevision is still the fresh studio.read revision. midi.clip.update identifies an ACTUAL existing MIDI clipID; it keeps its track, offset, controller points and all undeclared fields. If notes are supplied, notesMode MUST explicitly be append (retain every old note) or replace (replace notes deliberately). Omit note IDs for newly generated native IDs; explicit note IDs must be unique. midi.clip.insert requires an ACTUAL existing MIDI trackID, name, positive durationTicks, notes and optional offsetSamples (integer sample time, default 0); the native service creates its new clip ID. Never invent a target or use UI selection as an implicit target. No command changes mute, gain, routing, monitoring or recording state."
        guide += " A 50-quarter-note piece at 100 BPM lasts 30 seconds. With 960 ticks per quarter this is 48000 ticks; the final two-quarter chord begins at 46080. Other tempi/tempo maps change seconds. Offset uses SAMPLES, not ticks. studio.run renderWAV/renderMP3 accepts inputJSON {\"tailFrames\":0} for an exact content-length file; omitted tailFrames keeps the existing 48000-frame effect tail. Render respects the saved mix, including master mute. A saved muted mix produces a silent file; do not silently unmute it. Render returns actual output metadata and audioObservation; saving alone is not audio generation."
        let targetTrack = document?.tracks.first(where: { $0.kind == .midi })
        let targetClip = targetTrack?.clips.first(where: { if case .midi = $0.body { return true }; return false })
        let chord: [[String: Any]] = [60, 64, 67].map {
            ["pitch": $0, "startTick": quarter * 48, "durationTicks": quarter * 2, "velocity": 96]
        }
        let update: [[String: Any]] = [["op": "midi.clip.update", "clipID": targetClip?.id.rawValue ?? "ACTUAL_EXISTING_MIDI_CLIP_ID",
            "durationTicks": quarter * 50, "notesMode": "append", "notes": chord]]
        let insert: [[String: Any]] = [["op": "midi.clip.insert", "trackID": targetTrack?.id.rawValue ?? "ACTUAL_EXISTING_MIDI_TRACK_ID",
            "name": "New phrase", "durationTicks": quarter * 50, "offsetSamples": 0, "notes": chord]]
        if let text = json(update) { guide += "\nComplete MIDI update/append operationsJSON (retain all existing notes):\n" + text }
        if let text = json(insert) { guide += "\nComplete MIDI insert operationsJSON (adds a NEW clip):\n" + text }
        if targetTrack == nil { guide += " This original currently has no MIDI track. First add one through the native insertTrack example, read the saved state, then use its actual trackID. Placeholder IDs in these examples are never valid targets." }
        if targetClip == nil { guide += " This original currently has no MIDI clip to update. Insert a new clip into an existing MIDI track instead of inventing an update target." }
        if let targetClip, case .midi(let payload) = targetClip.body,
           payload.notes.count <= 16, payload.controllerPoints.count <= 16,
           let complete = try? StudioTypedEditExamples.encode([MusicEditOp.updateClip(targetClip)]),
           complete.utf8.count <= 8_000 {
            guide += "\nComplete legacy updateClip shape using this ACTUAL clip, including every current note. Edit only intended fields; the unchanged example is documentation, not a requested edit:\n" + complete
        }
        if let track = targetTrack,
           let clip = try? MusicClip(name: "New MIDI phrase", trackID: track.id, offset: .init(0),
                                     body: .midi(.init(durationTicks: quarter * 4))),
           let complete = try? StudioTypedEditExamples.encode([MusicEditOp.insertClip(clip)]) {
            guide += "\nComplete legacy insertClip shape with a NEW clip ID and this ACTUAL track ID; fill notes through their exact native encoding:\n" + complete
        }
        if let track = targetTrack,
           let patch = try? MusicPluginState(pluginID: MusicNativeBuiltins.synth, presetIndex: 2),
           let example = try? StudioTypedEditExamples.encode([MusicEditOp.setInstrument(track.id, patch)]) {
            guide += "\nComplete legacy setInstrument operationsJSON using this ACTUAL MIDI track and built-in preset index 2. Read musicCapabilities.presets for all actual IDs and defaults. Applying a preset changes only its instrument; it does not unmute the mix:\n" + example
        }
        if let document,
           let example = try? StudioTypedEditExamples.encode([MusicEditOp.setMasterStrip(document.masterStrip)]) {
            guide += "\nMaster output settings are document.masterStrip, separate from auxiliary buses. The virtual routing ID master is NOT a target for setBusStrip. Complete legacy setMasterStrip shape using the ACTUAL current settings, unchanged; change only an intended mix setting and preserve the rest. This example is documentation, not an instruction to unmute:\n" + example
        }
        guide += "\nMIDI editing commands also return ordinary saved native edits: midi.clip.quantize {clipID,gridTicks,strength?:0...1,quantizeEnds?:bool}; midi.clip.transpose {clipID,semitones,outOfRange?:reject|clamp}; midi.clip.velocity {clipID,delta}; midi.template.insert {trackID,template:drumGroove|chordProgression|arpeggio|bassLine,atTick,bars?:1...64,rootPitch?:0...127,velocity?:1...127,name?:string}. Each is one object with op inside the same preferred array. Templates add a new clip and never replace the existing piece or select an instrument implicitly. Drum templates use GM notes on channel 9; select preset 40 explicitly on a MIDI track if an electronic drum kit is intended. A pure no-op returns the current revision without committing an empty edit."
        return guide
    }

    struct Capabilities: Encodable {
        let presets: [MusicInstrumentPreset]
        let templates: [MusicPatternTemplate]
        let clipCommands: [String]
        let presetKind: String
        let defaultRenderTailFrames: Int64
        let maximumRenderTailFrames: Int64
    }
    static func capabilities(sampleRate: Int) -> Capabilities {
        .init(presets: MusicPresetCatalog.all, templates: MusicPatternTemplate.allCases,
              clipCommands: ["midi.clip.insert", "midi.clip.update", "midi.clip.quantize", "midi.clip.transpose", "midi.clip.velocity", "midi.template.insert"],
              presetKind: "Native synthesized timbres; not sampled acoustic instruments",
              defaultRenderTailFrames: 48_000, maximumRenderTailFrames: Int64(sampleRate) * 10)
    }

    static func renderTailFrames(inputJSON: String?, sampleRate: Int) throws -> Int64 {
        guard let inputJSON, !inputJSON.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return 48_000 }
        let data = Data(inputJSON.utf8)
        guard data.count <= 4_096,
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              Set(object.keys).isSubset(of: ["tailFrames"]) else {
            throw FloeError.validationFailed("Music render inputJSON must be one object with only optional tailFrames, an integer frame count.")
        }
        guard let value = object["tailFrames"] else { return 48_000 }
        guard let number = value as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID(),
              ["c", "s", "i", "l", "q", "C", "S", "I", "L", "Q"].contains(String(cString: number.objCType)),
              let frames = Int64(number.stringValue), frames >= 0, frames <= Int64(sampleRate) * 10 else {
            throw FloeError.validationFailed("inputJSON.tailFrames must be an integer in 0...\(Int64(sampleRate) * 10). Use 0 for no effect tail; the original mix stays unchanged.")
        }
        return frames
    }

    private static func json(_ value: Any) -> String? {
        guard let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]) else { return nil }
        return String(decoding: data, as: UTF8.self)
    }
}
#endif
