// SPDX-License-Identifier: MPL-2.0
#if canImport(UIKit)
import AVFoundation
import Foundation
import Testing
import FloeMusicCore
import FloeMusicNative
@testable import FloeApp

/// Microphone recording on the shared transport: recording from the current
/// playhead, accompaniment ownership, loop takes preserved as validated
/// assets, and undo-friendly take selection. Runs on the reused qualification
/// Simulator; real microphone routing and hardware latency stay with
/// physical-device acceptance and are never claimed here.
@Suite("Music microphone transport", .serialized)
@MainActor struct MusicMicrophoneTransportTests {
    private func openSession() async throws -> (MusicProjectSession, URL) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("FloeMusicMicrophoneTransportTests")
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let id = UUID()
        let repository = try NativeMusicRepository(root: root)
        let document = try MusicDocument(id: .init(rawValue: id.uuidString.lowercased()), name: "Microphone transport test")
        _ = try await repository.save(document: document, expectedRevision: nil, fence: nil)
        let session = try await MusicProjectSession.open(id: id, directory: root, environment: FloeAgentApp.liveEnvironment)
        return (session, root)
    }

    private func insertAccompaniment(_ session: MusicProjectSession) async throws {
        let track = try FloeMusicCore.MusicTrack(name: "Guide", kind: .midi,
                                                 instrument: .init(pluginID: MusicNativeBuiltins.synth, presetIndex: 0))
        let clip = try MusicClip(name: "Guide clip", trackID: track.id, offset: .init(0),
                                 body: .midi(.init(durationTicks: 1_920,
                                                   notes: [try MusicMIDINote(pitch: 60, startTick: .init(0),
                                                                             durationTicks: 480, velocity: 96)])))
        try await session.apply([.insertTrack(track), .insertClip(clip)])
    }

    @Test func microphoneRecordsOnSharedTransportAndCommitsAlignedClip() async throws {
        let (session, root) = try await openSession()
        try await insertAccompaniment(session)
        session.seek(to: 1)
        await session.startMicrophone()
        guard session.isRecording else {
            // Simulators without an audio input reject capture honestly;
            // routing acceptance belongs to physical-device testing.
            #expect(session.diagnostic != nil)
            try? FileManager.default.removeItem(at: root)
            return
        }
        #expect(session.playbackIsActive, "the owned recording keeps its own accompaniment")
        #expect(session.playbackPosition >= 1)
        try await Task.sleep(for: .milliseconds(600))
        #expect(session.playbackPosition > 1.2, "the recording playhead advances on the shared clock")
        let revision = session.document.revision
        await session.stopMicrophone()
        #expect(!session.isRecording)
        #expect(!session.playbackIsActive)
        #expect(session.playbackPosition > 1.2, "playhead rests at the end of the take")
        let clip = try #require(session.document.tracks.flatMap(\.clips).first { $0.offset.value == 48_000 })
        guard case .audio(let payload) = clip.body else { Issue.record("recorded take is not audio"); return }
        #expect(payload.durationSamples > 0)
        #expect(session.document.assets.contains { $0.id == payload.assetID }, "the take is a validated committed asset")
        let takes = session.takes(for: clip)
        #expect(!takes.isEmpty)
        #expect(session.document.revision > revision)
        // Undo removes the committed clip and take assets atomically.
        await session.undo()
        #expect(session.document.tracks.flatMap(\.clips).first { $0.offset.value == 48_000 } == nil)
        try? FileManager.default.removeItem(at: root)
    }

    @Test func loopRecordingPreservesEveryPassAsValidatedAssets() async throws {
        let (session, root) = try await openSession()
        try await insertAccompaniment(session)
        session.setLooping(true)
        session.seek(to: 0.5)
        await session.startMicrophone()
        guard session.isRecording else {
            #expect(session.diagnostic != nil)
            try? FileManager.default.removeItem(at: root)
            return
        }
        // Record past at least one loop wrap ([0.5 s, content end ≈ 1 s)).
        try await Task.sleep(for: .milliseconds(1400))
        await session.stopMicrophone()
        let clip = try #require(session.document.tracks.flatMap(\.clips).first { $0.offset.value == 24_000 })
        let takes = session.takes(for: clip)
        #expect(takes.count >= 2, "each loop pass is preserved as its own take, got \(takes.count)")
        // The audible clip is the last pass only: no stacked layering.
        guard case .audio(let payload) = clip.body else { Issue.record("recorded take is not audio"); return }
        #expect(payload.assetID == takes.last?.assetID)
        // Reopen: the take list is derivable from the committed document.
        try await session.reload()
        let reloaded = try #require(session.document.tracks.flatMap(\.clips).first { $0.offset.value == 24_000 })
        #expect(session.takes(for: reloaded).count == takes.count)
        try? FileManager.default.removeItem(at: root)
    }

    @Test func selectTakeSwapsAudibleClipThroughStore() async throws {
        let (session, root) = try await openSession()
        try await insertAccompaniment(session)
        session.setLooping(true)
        session.seek(to: 0.5)
        await session.startMicrophone()
        guard session.isRecording else {
            #expect(session.diagnostic != nil)
            try? FileManager.default.removeItem(at: root)
            return
        }
        try await Task.sleep(for: .milliseconds(1400))
        await session.stopMicrophone()
        let clip = try #require(session.document.tracks.flatMap(\.clips).first { $0.offset.value == 24_000 })
        let takes = session.takes(for: clip)
        try #require(takes.count >= 2)
        guard case .audio(let original) = clip.body else { Issue.record("recorded take is not audio"); return }
        let first = try #require(takes.first)
        await session.selectTake(first, for: clip.id)
        let swapped = try #require(session.document.tracks.flatMap(\.clips).first { $0.id == clip.id })
        guard case .audio(let payload) = swapped.body else { Issue.record("swapped take is not audio"); return }
        #expect(payload.assetID == first.assetID && payload.assetID != original.assetID)
        // Selection is a normal store commit: undo restores the last take.
        await session.undo()
        let restored = try #require(session.document.tracks.flatMap(\.clips).first { $0.id == clip.id })
        guard case .audio(let restoredPayload) = restored.body else { Issue.record("restored take is not audio"); return }
        #expect(restoredPayload.assetID == original.assetID)
        try? FileManager.default.removeItem(at: root)
    }
}
#endif
