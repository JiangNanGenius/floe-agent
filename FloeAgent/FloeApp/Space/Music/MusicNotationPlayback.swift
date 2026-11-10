// SPDX-License-Identifier: MPL-2.0
#if canImport(UIKit)
import AVFoundation
import Foundation
import FloeHeavyEditorSupport
import FloeMusicCore
import FloeMusicNative

/// A performed-score projection for the existing native renderer, never a MIDI
/// round trip or a persisted replacement of the notation or arrangement.
nonisolated enum MusicNotationPerformance {
    static func document(_ performance: EditorJSON, parent: MusicDocument) throws -> MusicDocument {
        guard performance["format"].string == "floe.score.performance/1",
              let duration = performance["duration"].number, duration.isFinite, duration > 0,
              duration <= 6 * 3600, performance["events"].array.count <= 200_000 else { throw HeavyEditorError.invalidDocument }
        // Fixed linear timebase represents the compiled seconds, including
        // rubato, ties, articulation gates and pedal, without flattening XML.
        let ppq = 15_360, factor = Double(ppq) * 2
        let tempo = try MusicTempoMap(ticksPerQuarter: ppq, sampleRate: parent.tempoMap.sampleRate,
            segments: [MusicTempoSegment(startTick: .init(0), bpm: 120, beatsPerBar: 4, beatUnit: 4)])
        let length = max(1, Int64((duration * factor).rounded(.up)))
        var groups: [String: (name: String, preset: Int, notes: [MusicMIDINote])] = [:]
        for event in performance["events"].array {
            guard let start = event["start"].number, let duration = event["duration"].number,
                  let pitch = event["pitch"].number, let velocity = event["velocity"].number,
                  start >= 0, start.isFinite, duration > 0, duration.isFinite,
                  pitch.rounded() == pitch, (0...127).contains(pitch), (0...127).contains(velocity),
                  start * factor < Double(Int64.max), duration * factor < Double(Int64.max) else { throw HeavyEditorError.invalidDocument }
            let volume = event["volume"].number ?? 1
            guard volume.isFinite, (0...1).contains(volume) else { throw HeavyEditorError.invalidDocument }
            if volume == 0 || velocity == 0 { continue }
            let percussion = event["percussion"].bool ?? false, programValue = event["program"].number ?? 0
            guard programValue.isFinite, programValue.rounded() == programValue, (0...127).contains(programValue) else { throw HeavyEditorError.invalidDocument }
            let program = Int(programValue)
            let preset: Int
            if let selected = event["nativePreset"].number {
                guard selected.isFinite, selected.rounded() == selected, selected >= 0, selected <= 4096,
                      MusicPresetCatalog.preset(index: Int(selected)) != nil else { throw HeavyEditorError.invalidDocument }
                preset = Int(selected)
            } else { preset = presetIndex(program: program, percussion: percussion) }
            let part = event["part"].string ?? "score"
            let key = part + ":\(preset):\(percussion)"
            let tick = Int64((start * factor).rounded())
            guard tick < length else { continue }
            let ticks = min(length - tick, max(1, Int64((duration * factor).rounded())))
            let note = try MusicMIDINote(pitch: Int(pitch), startTick: .init(tick), durationTicks: ticks,
                velocity: max(1, min(127, Int((velocity * volume).rounded()))), channel: percussion ? 9 : 0)
            if groups[key] == nil { groups[key] = (part, preset, []) }
            groups[key]?.notes.append(note)
        }
        if groups.isEmpty { groups["silence"] = ("Score", 0, []) }
        var tracks: [FloeMusicCore.MusicTrack] = []
        for key in groups.keys.sorted() {
            guard let group = groups[key] else { continue }
            let trackID = MusicTrackID(), preset = group.preset
            let clip = try MusicClip(name: group.name, trackID: trackID, offset: .init(0),
                body: .midi(.init(durationTicks: length, notes: group.notes)))
            tracks.append(try MusicTrack(id: trackID, name: group.name, kind: .midi, clips: [clip],
                instrument: .init(pluginID: MusicNativeBuiltins.synth, presetIndex: preset)))
        }
        return try MusicDocument(id: parent.id, name: parent.name, revision: parent.revision, tempoMap: tempo, tracks: tracks)
    }
    static func presetIndex(program: Int, percussion: Bool) -> Int {
        if percussion { return MusicPresetCatalog.electronicDrumKitIndex }
        let category: MusicPresetCategory
        switch program {
        case 0...7: category = .keyboard
        case 8...15: category = .bell
        case 16...23: category = .organ
        case 24...31: category = .pluck
        case 32...39: category = .bass
        case 40...55: category = .strings
        case 88...103: category = .pad
        default: category = .lead
        }
        return MusicPresetCatalog.all.first { $0.category == category }?.index ?? 0
    }
}

/// Service-owned score playback uses the parent music audio authority and
/// renderer. It owns no AVAudioSession and cannot reset another audio owner.
@MainActor final class MusicNotationPlayback: NSObject, AVAudioPlayerDelegate {
    private weak var parent: MusicProjectSession?
    private let authority: any MusicAudioAuthority
    private let renderer: MusicOfflineRenderer
    private let ownerToken: String
    private var player: AVAudioPlayer?
    private var lease: MusicRenderLease?
    private var task: Task<URL, any Error>?
    private var output: URL?
    private var acquired = false
    private var generation = UUID()
    private var position = 0.0
    private var duration = 0.0
    var isBusy: Bool { task != nil || player?.isPlaying == true }
    init(parent: MusicProjectSession, authority: any MusicAudioAuthority, renderer: MusicOfflineRenderer, ownerToken: String) {
        self.parent = parent; self.authority = authority; self.renderer = renderer; self.ownerToken = ownerToken
    }
    func run(_ arguments: EditorJSON) async throws -> EditorJSON {
        guard let parent else { throw PersonalContentError.changedDocument }
        switch arguments["action"].string ?? "status" {
        case "start":
            guard !parent.isRecording, !parent.isMIDIRecording, !parent.notationRestoring else { throw MusicError.invalidBatch(reason: "Finish recording or restoration before playing") }
            let resume = arguments["position"].number ?? position
            if arguments["performance"] != .null {
                stop() // Stop only this score render/player/output after caching resume.
                parent.cancelRender(); parent.stopLive(); parent.stopPlayback()
                let identity = UUID(); generation = identity
                let frozen = parent.document
                let projection = try MusicNotationPerformance.document(arguments["performance"], parent: frozen)
                let lease = try MusicRenderLease(document: projection, ownerToken: ownerToken); self.lease = lease
                let directory = parent.root.appendingPathComponent("NotationPlayback", isDirectory: true)
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                let destination = directory.appendingPathComponent(UUID().uuidString + ".wav")
                let renderer = renderer
                let render = Task { () throws -> URL in
                    do {
                        _ = try await renderer.render(document: projection, sources: [], destination: destination, lease: lease, tailFrames: 0)
                        try Task.checkCancellation(); return destination
                    } catch { try? FileManager.default.removeItem(at: destination); throw error }
                }
                task = render
                defer { if generation == identity { task = nil } }
                let file = try await render.value
                guard generation == identity, parent.document.revision == frozen.revision, !parent.notationRestoring else {
                    try? FileManager.default.removeItem(at: file); throw CancellationError()
                }
                try Task.checkCancellation()
                let next = try AVAudioPlayer(contentsOf: file); next.delegate = self; next.prepareToPlay()
                player = next; output = file; duration = arguments["performance"]["duration"].number ?? next.duration
            }
            guard let player else { throw HeavyEditorError.invalidDocument }
            guard resume.isFinite, resume >= 0 else { throw HeavyEditorError.invalidDocument }
            position = min(duration, resume); if position >= duration { position = 0 }
            player.currentTime = position; player.numberOfLoops = arguments["loop"].bool == true ? -1 : 0
            if !acquired { try authority.acquirePlayback(); acquired = true }
            guard player.play() else { release(); throw MusicNativeError.render("Score playback did not start") }
        case "pause": position = player?.currentTime ?? position; player?.pause(); release()
        case "stop": stop()
        case "seek":
            guard let value = arguments["position"].number, value.isFinite, value >= 0 else { throw HeavyEditorError.invalidDocument }
            position = min(duration, value); player?.currentTime = position
        case "status": break
        default: throw HeavyEditorError.invalidCommand
        }
        return .object(["playing": .bool(player?.isPlaying ?? false), "position": .number(player?.isPlaying == true ? player!.currentTime : position),
                        "duration": .number(duration), "referenceTimbres": .bool(false)])
    }
    func stop() {
        generation = UUID(); lease?.invalidate(); lease = nil; task?.cancel(); task = nil
        player?.stop(); player = nil; position = 0; release()
        if let output { try? FileManager.default.removeItem(at: output); self.output = nil }
    }
    private func release() { if acquired { acquired = false; authority.releasePlayback() } }
    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        let finishedID = ObjectIdentifier(player)
        Task { @MainActor [weak self] in
            guard let self, self.player.map(ObjectIdentifier.init) == finishedID, self.player?.isPlaying != true else { return }
            self.position = self.duration; self.release()
        }
    }
}
#endif
