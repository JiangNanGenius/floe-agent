import XCTest
@testable import FloeMusicCore

@MainActor
final class IntegrationContractTests: XCTestCase {
    func testOpenExistingProjectDoesNotCreateOverIt() async throws {
        let repository = InMemoryMusicRepository()
        let original = try MusicFixtures.emptyDocument()
        let store = try await MusicProjectStore(document: original, repository: repository)
        let saved = try await store.commit(MusicEditBatch(baseRevision: 0, ops: [.setName("saved")]),
                                            as: await store.beginSession(ownerToken: "editor"))
        let reopened = try await MusicProjectStore.open(projectID: original.id, repository: repository)
        let snapshot = try await reopened.currentSnapshot()
        XCTAssertEqual(snapshot, saved)
        // Undo is currently process-local; reopening must not invent history.
        let canUndo = await reopened.canUndo
        XCTAssertFalse(canUndo)
    }

    func testForgedCloseCannotFenceRealOwner() async throws {
        let store = try await MusicProjectStore(document: MusicFixtures.emptyDocument(), repository: InMemoryMusicRepository())
        let session = await store.beginSession(ownerToken: "editor")
        let forged = MusicSessionHandle(sessionID: session.sessionID, ownerToken: "other", baseRevision: 0)
        await XCTAssertThrowsErrorAsync(try await store.close(forged))
        let saved = try await store.commit(MusicEditBatch(baseRevision: 0, ops: [.setName("owner")]), as: session)
        XCTAssertEqual(saved.name, "owner")
    }

    func testOldHandleCannotPresentNewBatchRevision() async throws {
        let store = try await MusicProjectStore(document: MusicFixtures.emptyDocument(), repository: InMemoryMusicRepository())
        let old = await store.beginSession(ownerToken: "editor")
        _ = try await store.commit(MusicEditBatch(baseRevision: 0, ops: [.setName("first")]), as: old)
        await XCTAssertThrowsErrorAsync(try await store.commit(MusicEditBatch(baseRevision: 1, ops: [.setName("late")]), as: old))
        let snapshot = try await store.currentSnapshot()
        XCTAssertEqual(snapshot.name, "first")
    }

    func testCloseDuringPendingSavePreventsRepositoryCommit() async throws {
        let repository = PausingMusicRepository()
        let original = try MusicFixtures.emptyDocument()
        let store = try await MusicProjectStore(document: original, repository: repository)
        let session = await store.beginSession(ownerToken: "late-ai")
        await repository.pauseNextWrite()
        let pending = Task { try await store.commit(MusicEditBatch(baseRevision: 0, ops: [.setName("late")]), as: session) }
        await repository.waitUntilPaused()
        try await store.close(session)
        await repository.resumeWrite()
        await XCTAssertThrowsErrorAsync(try await pending.value)
        let stored = try await repository.load(projectID: original.id)
        let snapshot = try await store.currentSnapshot()
        XCTAssertEqual(stored, original)
        XCTAssertEqual(snapshot, original)
        let canUndo = await store.canUndo
        XCTAssertFalse(canUndo)
    }

    func testReactivationDoesNotReviveAlreadyPendingWrite() async throws {
        let repository = PausingMusicRepository()
        let original = try MusicFixtures.emptyDocument()
        let store = try await MusicProjectStore(document: original, repository: repository)
        let session = await store.beginSession(ownerToken: "editor")
        await repository.pauseNextWrite()
        let pending = Task { try await store.commit(MusicEditBatch(baseRevision: 0, ops: [.setName("stale")]), as: session) }
        await repository.waitUntilPaused()
        try await store.markInactive(session)
        try await store.reactivate(session)
        await repository.resumeWrite()
        await XCTAssertThrowsErrorAsync(try await pending.value)
        let saved = try await store.commit(MusicEditBatch(baseRevision: 0, ops: [.setName("fresh")]), as: session)
        XCTAssertEqual(saved.name, "fresh")
    }

    func testMIDIClipOffsetUsesTempoAtItsActualPosition() throws {
        let tempo = try MusicTempoMap(ticksPerQuarter: 960, sampleRate: 48_000, segments: [
            MusicTempoSegment(startTick: MusicTick(0), bpm: 120, beatsPerBar: 4, beatUnit: 4),
            MusicTempoSegment(startTick: MusicTick(960), bpm: 60, beatsPerBar: 4, beatUnit: 4)
        ])
        let clip = try MusicFixtures.midiClip(id: "offset", trackID: "keys", offset: 24_000,
                                              durationTicks: 960, notes: [MusicFixtures.midiNote(duration: 960)])
        XCTAssertEqual(try clip.sample(atRelativeTick: 960, tempoMap: tempo).value, 72_000)
        XCTAssertEqual(try clip.endSample(tempoMap: tempo).value, 72_000)
    }

    func testRemovingBusRepairsTrackRoutesAndSends() async throws {
        let busID = MusicBus.MusicBusID(rawValue: "aux")
        let track = try MusicTrack(name: "audio", kind: .audio, outputBusID: busID,
                                   sends: [MusicTrackSend(busID: busID, gain: 0.2)])
        var document = try MusicDocument(name: "routing", tracks: [track], buses: [MusicBus(id: busID, name: "aux")])
        try document.apply(.removeBus(busID))
        try document.validate()
        XCTAssertEqual(document.tracks[0].outputBusID, MusicBus.masterBusID)
        XCTAssertTrue(document.tracks[0].sends.isEmpty)
        // apply edits a draft; the public store validates the whole batch so
        // a later operation can legitimately create a referenced bus.
        let store = try await MusicProjectStore(document: document, repository: InMemoryMusicRepository())
        await XCTAssertThrowsErrorAsync(try await store.commit(
            MusicEditBatch(baseRevision: 0, ops: [.setTrackRouting(track.id, output: busID, sends: [])]),
            as: await store.beginSession(ownerToken: "routing")))
        let snapshot = try await store.currentSnapshot()
        XCTAssertEqual(snapshot, document)
    }

    func testDJFailedMutationKeepsOriginalSession() throws {
        let asset = try MusicFixtures.asset(durationSamples: 192_000)
        var session = try MusicDJSession(assets: [asset])
        try session.loadDeck(.a, asset: asset)
        try session.setBeatGrid(.a, bpm: 120, firstBeatSample: 0, beatCount: 8)
        try session.setLoop(.a, startBeat: 1, lengthBeats: 2)
        let before = session
        XCTAssertThrowsError(try session.setBeatGrid(.a, bpm: 120, firstBeatSample: 0, beatCount: 1))
        XCTAssertEqual(session, before)
        session.masterGain = .nan
        XCTAssertThrowsError(try session.validate())
        session = before
        session.sampleRate = 0
        XCTAssertThrowsError(try session.validate())
    }
}

/// Suspends before the real repository's commit point, without sleeps or
/// replacing the strict persistence implementation with a success mock.
private actor PausingMusicRepository: MusicRepository {
    let base = InMemoryMusicRepository()
    var pause = false
    var blocked: CheckedContinuation<Void, Never>?
    var waiter: CheckedContinuation<Void, Never>?

    func pauseNextWrite() { pause = true }
    func waitUntilPaused() async {
        if blocked != nil { return }
        await withCheckedContinuation { waiter = $0 }
    }
    func resumeWrite() { blocked?.resume(); blocked = nil }
    func stageAsset(_ payload: MusicAssetPayload) async throws { try await base.stageAsset(payload) }
    func save(document: MusicDocument, expectedRevision: Int64?, fence: MusicCommitFence?) async throws -> MusicRevisionToken {
        if pause, expectedRevision != nil {
            pause = false
            await withCheckedContinuation { continuation in
                blocked = continuation; waiter?.resume(); waiter = nil
            }
        }
        return try await base.save(document: document, expectedRevision: expectedRevision, fence: fence)
    }
    func load(projectID: MusicProjectID) async throws -> MusicDocument { try await base.load(projectID: projectID) }
    func assetPayload(assetID: MusicAssetID) async throws -> MusicAssetPayload? { try await base.assetPayload(assetID: assetID) }
}
