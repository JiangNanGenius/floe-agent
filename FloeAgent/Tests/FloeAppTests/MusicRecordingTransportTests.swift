// SPDX-License-Identifier: MPL-2.0
#if canImport(UIKit)
import AVFoundation
import Foundation
import Testing
import FloeMusicCore
import FloeMusicNative
@testable import FloeApp

/// Unified recording-transport integration: a MIDI take started from a
/// nonzero playhead advances the shared playhead, keeps every pre-existing
/// clip, rejects seeks and second players while recording, and leaves the
/// playhead at the end of the take. Requires the FloeApp test host
/// (registered in project.yml by the integration owner) and runs on the
/// reused qualification Simulator; it is delivered unwired this round.
@Suite("Music recording transport unification", .serialized)
@MainActor struct MusicRecordingTransportTests {
    private func openSession() async throws -> (MusicProjectSession, URL) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("FloeMusicRecordingTransportTests")
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let id = UUID()
        let repository = try NativeMusicRepository(root: root)
        let document = try MusicDocument(id: .init(rawValue: id.uuidString.lowercased()), name: "Recording transport test")
        _ = try await repository.save(document: document, expectedRevision: nil, fence: nil)
        let session = try await MusicProjectSession.open(id: id, directory: root, environment: FloeAgentApp.liveEnvironment)
        return (session, root)
    }

    private func insertInstrumentClip(_ session: MusicProjectSession) async throws {
        let track = try FloeMusicCore.MusicTrack(name: "Guide", kind: .midi,
                                                 instrument: .init(pluginID: MusicNativeBuiltins.synth, presetIndex: 0))
        let clip = try MusicClip(name: "Guide clip", trackID: track.id, offset: .init(0),
                                 body: .midi(.init(durationTicks: 1_920,
                                                   notes: [try MusicMIDINote(pitch: 60, startTick: .init(0),
                                                                             durationTicks: 480, velocity: 96)])))
        try await session.apply([.insertTrack(track), .insertClip(clip)])
        session.selectTrack(track.id)
    }

    @Test func recordingFromNonzeroPlayheadAdvancesPlayheadAndPreservesOriginalClips() async throws {
        let (session, root) = try await openSession()
        defer { session.stopLive(); session.stopPlayback(); try? FileManager.default.removeItem(at: root) }
        try await insertInstrumentClip(session)
        let revision = session.document.revision
        session.seek(to: 2)
        session.startMIDIRecording()
        try #require(session.isMIDIRecording)
        #expect(session.playbackIsActive, "the recording transport is the active arrangement playback")
        let start = session.playbackPosition
        #expect(start >= 2)
        try await Task.sleep(for: .milliseconds(700))
        #expect(session.playbackPosition > start + 0.25, "playhead advances with the recording transport clock")
        await session.stopMIDIRecording()
        #expect(!session.playbackIsActive)
        #expect(session.playheadSeconds > 2, "playhead rests at the end of the take")
        let clips = session.document.tracks.flatMap(\.clips)
        #expect(clips.contains { $0.offset.value == 0 }, "original guide clip is retained")
        #expect(session.document.revision == revision, "an empty take commits nothing")
    }

    /// Regression: the transport clock is absolute. Recording from a 10 s
    /// playhead must show 10 s + elapsed (never 20 s), the first performed
    /// note lands near tick 0 of the new clip, and the committed take plays
    /// back from the same timeline position after a store reload.
    @Test func recordingFromNonzeroStartKeepsNotesPlayheadAndSavedTakeOnOneClock() async throws {
        let (session, root) = try await openSession()
        defer { session.stopLive(); session.stopPlayback(); try? FileManager.default.removeItem(at: root) }
        try await insertInstrumentClip(session)
        session.seek(to: 10)
        #expect(session.playheadSeconds == 10)
        session.startMIDIRecording()
        try #require(session.isMIDIRecording)
        #expect(session.playbackIsActive)
        session.keyboard.keyDown(sourcePitch: 60)
        try await Task.sleep(for: .milliseconds(500))
        let position = session.playbackPosition
        #expect(position > 10.2 && position < 11, "UI playhead is start + elapsed, not doubled: \(position)")
        session.keyboard.keyUp(sourcePitch: 60)
        await session.stopMIDIRecording()
        #expect(!session.isMIDIRecording)
        let take = try #require(session.document.tracks.flatMap(\.clips).first { $0.offset.value == 480_000 })
        guard case .midi(let payload) = take.body else { Issue.record("recorded take is not MIDI"); return }
        let first = try #require(payload.notes.first)
        #expect(first.startTick.value < 480, "first note is near tick 0 of the take, got \(first.startTick.value)")
        #expect(session.document.tracks.flatMap(\.clips).contains { $0.offset.value == 0 }, "original guide clip is retained")
        // Saved take aligns with the same playhead after a store reload.
        try await session.reload()
        let reloaded = try #require(session.document.tracks.flatMap(\.clips).first { $0.offset.value == 480_000 })
        guard case .midi(let savedPayload) = reloaded.body else { Issue.record("saved take is not MIDI"); return }
        #expect(savedPayload.notes == payload.notes)
    }

    @Test func seekAndArrangementPlaybackAreRejectedWhileRecording() async throws {
        let (session, root) = try await openSession()
        defer { session.stopLive(); session.stopPlayback(); try? FileManager.default.removeItem(at: root) }
        try await insertInstrumentClip(session)
        session.seek(to: 1.5)
        session.startMIDIRecording()
        try #require(session.isMIDIRecording)
        session.seek(to: 0.25)
        #expect(session.playbackPosition >= 1.5, "seek cannot move a recording playhead")
        #expect(session.diagnostic != nil)
        session.render(asMP3: false, play: true)
        #expect(!session.isRendering, "a second player never starts during a take")
        #expect(!session.playbackIsActive || session.isMIDIRecording)
        await session.stopMIDIRecording()
        #expect(!session.isMIDIRecording)
    }
}
#endif
