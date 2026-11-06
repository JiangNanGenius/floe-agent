import XCTest
@testable import FloeMusicCore

/// Coordinator-directed: public mutable fields must not let an invalid state
/// reach persistence/render entrypoints — validate() and the store must
/// re-run nested rules.
@MainActor
final class MutationRevalidationTests: XCTestCase {
    private func committedStoreWithNote() async throws -> (MusicProjectStore, MusicClip, MusicTrackID) {
        let trackID = MusicTrackID(rawValue: "t1")
        let track = try MusicTrack(id: trackID, name: "keys", kind: .midi)
        let clip = try MusicFixtures.midiClip(id: "c1", trackID: trackID.rawValue,
                                              notes: [try MusicFixtures.midiNote()])
        let store = try await MusicProjectStore(
            document: MusicFixtures.emptyDocument(), repository: FixtureMusicRepository())
        try await store.commit(MusicEditBatch(baseRevision: 0, ops: [
            .insertTrack(track), .insertClip(clip),
        ]), as: await store.beginSession(ownerToken: "editor"))
        return (store, clip, trackID)
    }

    func testMutatedNotePitchRejectedByCommit() async throws {
        let (store, clip, _) = try await committedStoreWithNote()
        var mutated = clip
        if case .midi(var payload) = mutated.body {
            payload.notes[0].pitch = 200 // public mutation past MIDI range
            mutated.body = .midi(payload)
        }
        await XCTAssertThrowsErrorAsync(try await store.commit(
            MusicEditBatch(baseRevision: 1, ops: [.updateClip(mutated)]),
            as: await store.beginSession(ownerToken: "editor"))) { error in
            guard case MusicError.invalidMIDI = error else {
                return XCTFail("expected invalidMIDI, got \(error)")
            }
        }
        // Stored content untouched.
        let snapshot = try await store.currentSnapshot()
        guard case .midi(let payload) = snapshot.tracks[0].clips[0].body else {
            return XCTFail("expected MIDI clip")
        }
        XCTAssertEqual(payload.notes[0].pitch, 60)
    }

    func testMutatedNoteStartDurationOverflowRejected() async throws {
        let (store, clip, _) = try await committedStoreWithNote()
        var mutated = clip
        if case .midi(var payload) = mutated.body {
            payload.notes[0].startTick = MusicTick(Int64.max - 100)
            payload.notes[0].durationTicks = 480
            mutated.body = .midi(payload)
        }
        await XCTAssertThrowsErrorAsync(try await store.commit(
            MusicEditBatch(baseRevision: 1, ops: [.updateClip(mutated)]),
            as: await store.beginSession(ownerToken: "editor")))
    }

    func testMutatedTempoSegmentAndMapFieldsRejected() async throws {
        var document = try MusicFixtures.emptyDocument()
        var segment = document.tempoMap.segments[0]
        segment.bpm = 5 // mutation of a previously valid child must be rejected
        XCTAssertThrowsError(try MusicTempoMap(segments: [segment]))
        document = try MusicFixtures.emptyDocument()
        document.tempoMap.sampleRate = 1
        XCTAssertThrowsError(try document.validate())
        document = try MusicFixtures.emptyDocument()
        document.tempoMap.ticksPerQuarter = 0
        XCTAssertThrowsError(try document.validate())
    }

    func testMutatedAudioPayloadFieldsRejected() throws {
        let asset = try MusicFixtures.asset()
        var payload = try MusicAudioClipPayload(assetID: asset.id, durationSamples: 1_000)
        payload.fadeInSamples = -10
        payload.fadeOutSamples = 2_000
        var track = try MusicTrack(id: MusicTrackID(rawValue: "t1"), name: "a", kind: .audio)
        let clip = try MusicClip(id: MusicClipID(rawValue: "c1"), trackID: track.id,
                                 offset: MusicSampleTime(0), body: .audio(payload))
        track.clips = [clip]
        XCTAssertThrowsError(try MusicDocument(
            name: "song", tempoMap: MusicFixtures.defaultTempoMap(),
            assets: [asset], tracks: [track]))
        _ = clip
    }

    func testMutatedPluginParameterRejected() throws {
        var plugin = try MusicPluginState(pluginID: "au://eq", parameters: ["q": 1.0])
        plugin.parameters["q"] = .nan // non-finite
        let track = try MusicTrack(id: MusicTrackID(rawValue: "t1"), name: "a", kind: .midi,
                                   instrument: plugin)
        XCTAssertThrowsError(try MusicDocument(name: "song",
                                               tempoMap: MusicFixtures.defaultTempoMap(),
                                               tracks: [track]))
    }

    func testMutatedStripAndClipOffsetRejected() throws {
        var document = try MusicFixtures.emptyDocument()
        document.masterStrip.pan = 3
        XCTAssertThrowsError(try document.validate())
        document = try MusicFixtures.emptyDocument()
        document.masterStrip.gain = .nan
        XCTAssertThrowsError(try document.validate())

        let asset = try MusicFixtures.asset()
        let clip = try MusicFixtures.audioClip(id: "c1", trackID: "t1",
                                               assetID: asset.id.rawValue)
        var mutated = clip
        mutated.offset = MusicSampleTime(-5)
        let track = try MusicTrack(id: MusicTrackID(rawValue: "t1"), name: "a",
                                   kind: .audio, clips: [mutated])
        XCTAssertThrowsError(try MusicDocument(name: "song",
                                               tempoMap: MusicFixtures.defaultTempoMap(),
                                               assets: [asset], tracks: [track]))
    }

    func testMutatedTrimDurationOverflowRejected() throws {
        let asset = try MusicAsset(id: MusicAssetID(rawValue: "a1"),
                                   sourceLocator: "cas://a1",
                                   contentHash: MusicFixtures.hexHash("a1"),
                                   kind: .audioMP3, durationSamples: MusicSampleTime(1_000),
                                   name: "a")
        var payload = try MusicAudioClipPayload(assetID: asset.id, durationSamples: 500)
        payload.trimStartSamples = Int64.max - 100
        let clip = try MusicClip(id: MusicClipID(rawValue: "c1"),
                                 trackID: MusicTrackID(rawValue: "t1"),
                                 offset: MusicSampleTime(0), body: .audio(payload))
        let track = try MusicTrack(id: MusicTrackID(rawValue: "t1"), name: "a",
                                   kind: .audio, clips: [clip])
        XCTAssertThrowsError(try MusicDocument(name: "song",
                                               tempoMap: MusicFixtures.defaultTempoMap(),
                                               assets: [asset], tracks: [track]))
    }

    func testMutatedAutomationValueRejected() throws {
        var document = try MusicFixtures.emptyDocument()
        let lane = try MusicAutomationLane(
            ownerID: MusicBus.masterBusID.rawValue, target: .busGain,
            points: [try MusicAutomationPoint(sample: MusicSampleTime(0), value: 0.5)])
        document.automationLanes = [lane]
        try document.validate()
        document.automationLanes[0].points[0].value = 2
        XCTAssertThrowsError(try document.validate())
    }
}
