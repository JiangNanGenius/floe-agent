import XCTest
@testable import FloeMusicCore

/// Draft-then-commit batches, atomicity, monotonic revision, bounded
/// undo/redo.
@MainActor
final class EditingTests: XCTestCase {
    private func makeStore() async throws -> (MusicProjectStore, MusicSessionHandle) {
        let store = try await MusicProjectStore(
            document: MusicFixtures.emptyDocument(),
            repository: FixtureMusicRepository())
        return (store, await store.beginSession(ownerToken: "editor"))
    }

    func testCommitAdvancesRevisionExactlyOnce() async throws {
        let (store, session) = try await makeStore()
        let asset = try MusicFixtures.asset()
        let track = try MusicTrack(id: MusicTrackID(rawValue: "t1"), name: "vox", kind: .audio)
        let batch = MusicEditBatch(baseRevision: 0, author: "test",
                                   ops: [.insertAsset(asset), .insertTrack(track)])
        let committed = try await store.commit(batch, as: session)
        XCTAssertEqual(committed.revision, 1)
        XCTAssertEqual(committed.assets.count, 1)
        XCTAssertEqual(committed.tracks.count, 1)
    }

    func testInvalidBatchLeavesStoreUntouched() async throws {
        let (store, session) = try await makeStore()
        let asset = try MusicFixtures.asset()
        let goodTrack = try MusicTrack(id: MusicTrackID(rawValue: "t1"), name: "a", kind: .audio)
        let badClip = try MusicFixtures.audioClip(id: "c1", trackID: "missing",
                                                  assetID: asset.id.rawValue)
        let batch = MusicEditBatch(baseRevision: 0, ops: [
            .insertAsset(asset),
            .insertTrack(goodTrack),
            .insertClip(badClip), // references a track that is not in the doc
        ])
        await XCTAssertThrowsErrorAsync(try await store.commit(batch, as: session)) { error in
            guard case MusicError.invalidClip = error else {
                return XCTFail("expected invalidClip, got \(error)")
            }
        }
        let snapshot = try await store.currentSnapshot()
        XCTAssertEqual(snapshot.revision, 0)
        XCTAssertTrue(snapshot.tracks.isEmpty)
        XCTAssertTrue(snapshot.assets.isEmpty)
        let canUndo = await store.canUndo
        XCTAssertFalse(canUndo)
    }

    func testConstructorInvalidValueCannotCommit() async throws {
        let (store, session) = try await makeStore()
        // A clip whose fades exceed its duration can never be constructed...
        XCTAssertThrowsError(try MusicAudioClipPayload(
            assetID: MusicAssetID(rawValue: "a"), trimStartSamples: 0, durationSamples: 100,
            fadeInSamples: 80, fadeOutSamples: 80))
        // ...and a mutated valid value is caught by commit-time validation.
        var payload = try MusicAudioClipPayload(assetID: MusicAssetID(rawValue: "a"),
                                                durationSamples: 100)
        payload.fadeOutSamples = 500
        let asset = try MusicFixtures.asset()
        let track = try MusicTrack(id: MusicTrackID(rawValue: "t1"), name: "a", kind: .audio)
        let clip = try MusicClip(id: MusicClipID(rawValue: "c1"), trackID: track.id,
                                 offset: MusicSampleTime(0), body: .audio(payload))
        let batch = MusicEditBatch(baseRevision: 0, ops: [
            .insertAsset(asset), .insertTrack(track), .insertClip(clip),
        ])
        await XCTAssertThrowsErrorAsync(try await store.commit(batch, as: session))
        try await XCTAssertEqualAsync(try await store.currentSnapshot().revision, 0)
    }

    func testUndoMonotonicAndRedoClearedByNewCommit() async throws {
        let (store, session) = try await makeStore()
        func commitName(_ name: String, base: Int64) async throws {
            try await store.commit(MusicEditBatch(baseRevision: base, ops: [.setName(name)]),
                                   as: await store.beginSession(ownerToken: "editor"))
        }
        try await commitName("one", base: 0)
        try await commitName("two", base: 1)
        try await XCTAssertEqualAsync(try await store.currentSnapshot().name, "two")
        try await XCTAssertEqualAsync(try await store.currentSnapshot().revision, 2)

        // Undo: content returns to "one" but revision still advances.
        try await store.undo(await store.beginSession(ownerToken: "editor"))
        try await XCTAssertEqualAsync(try await store.currentSnapshot().name, "one")
        try await XCTAssertEqualAsync(try await store.currentSnapshot().revision, 3)

        // New commit clears the redo stack.
        try await commitName("three", base: 3)
        let canRedo = await store.canRedo
        XCTAssertFalse(canRedo)
        try await XCTAssertEqualAsync(try await store.currentSnapshot().name, "three")
    }

    func testUndoRedoDepthIsBounded() async throws {
        let config = MusicStoreConfig(maxUndoDepth: 3, maxRedoDepth: 3)
        let store = try await MusicProjectStore(
            document: MusicFixtures.emptyDocument(),
            repository: FixtureMusicRepository(), config: config)
        for index in 0..<6 {
            try await store.commit(
                MusicEditBatch(baseRevision: Int64(index), ops: [.setName("r\(index)")]),
                as: await store.beginSession(ownerToken: "editor"))
        }
        let undoDepth = await store.undoDepth
        XCTAssertEqual(undoDepth, 3)
        for _ in 0..<3 {
            try await store.undo(await store.beginSession(ownerToken: "editor"))
        }
        let redoDepth = await store.redoDepth
        XCTAssertEqual(redoDepth, 3)
        // A 4th undo is a no-op error (nothing left).
        await XCTAssertThrowsErrorAsync(try await store.undo(await store.beginSession(ownerToken: "editor")))
    }

    func testMIDIClipCommitAndUpdate() async throws {
        let (store, session) = try await makeStore()
        let track = try MusicTrack(id: MusicTrackID(rawValue: "t1"), name: "keys", kind: .midi,
                                   instrument: try MusicPluginState(pluginID: "au://keys"))
        let note = try MusicFixtures.midiNote()
        let clip = try MusicFixtures.midiClip(id: "c1", trackID: "t1", notes: [note])
        try await store.commit(MusicEditBatch(baseRevision: 0, ops: [
            .insertTrack(track), .insertClip(clip),
        ]), as: session)

        var updated = clip
        if case .midi(var payload) = updated.body {
            payload.notes.append(try MusicFixtures.midiNote(pitch: 64, start: 480))
            updated.body = .midi(payload)
        }
        try await store.commit(MusicEditBatch(baseRevision: 1, ops: [.updateClip(updated)]),
                               as: await store.beginSession(ownerToken: "editor"))
        let snapshot = try await store.currentSnapshot()
        guard case .midi(let payload) = snapshot.tracks[0].clips[0].body else {
            return XCTFail("expected MIDI clip")
        }
        XCTAssertEqual(payload.notes.count, 2)
    }

    func testMixerRoutingCycleRejectedAtomically() async throws {
        let (store, session) = try await makeStore()
        let busA = try MusicBus(id: MusicBus.MusicBusID(rawValue: "bus-a"), name: "A")
        let busB = try MusicBus(id: MusicBus.MusicBusID(rawValue: "bus-b"), name: "B")
        try await store.commit(MusicEditBatch(baseRevision: 0, ops: [
            .insertBus(busA), .insertBus(busB),
        ]), as: session)
        // Creating a cycle must fail and change nothing.
        await XCTAssertThrowsErrorAsync(try await store.commit(MusicEditBatch(baseRevision: 1, ops: [
            .setBusSends(MusicBus.MusicBusID(rawValue: "bus-a"), [MusicBus.MusicBusID(rawValue: "bus-b")]),
            .setBusSends(MusicBus.MusicBusID(rawValue: "bus-b"), [MusicBus.MusicBusID(rawValue: "bus-a")]),
        ]), as: await store.beginSession(ownerToken: "editor"))) { error in
            guard case MusicError.invalidMixer = error else {
                return XCTFail("expected invalidMixer, got \(error)")
            }
        }
        let snapshot = try await store.currentSnapshot()
        XCTAssertEqual(snapshot.buses.count, 2)
        XCTAssertTrue(snapshot.buses.allSatisfy { $0.sends.isEmpty })
        XCTAssertEqual(snapshot.revision, 1)
    }
}
