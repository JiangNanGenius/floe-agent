import XCTest
@testable import FloeMusicCore

/// DJ deck/cue/loop/sync/crossfader boundaries and the honest cue-bus model.
@MainActor
final class DJTests: XCTestCase {
    private func makeAsset(id: String = "dj-asset", duration: Int64 = 10_000_000,
                           revision: Int64 = 0) throws -> MusicAsset {
        try MusicAsset(id: MusicAssetID(rawValue: id), sourceLocator: "cas://\(id)",
                       contentHash: MusicFixtures.hexHash(id), sourceRevision: revision,
                       kind: .audioMP3, durationSamples: MusicSampleTime(duration), name: id)
    }

    func testLoadDeckBindsImmutableSourceIdentity() throws {
        let asset = try makeAsset()
        var session = try MusicDJSession(assets: [asset])
        try session.loadDeck(.a, asset: asset)
        XCTAssertEqual(session.deckA.assetID, asset.id)
        XCTAssertEqual(session.deckA.assetContentHash, asset.contentHash)
        XCTAssertEqual(session.deckA.assetSourceRevision, asset.sourceRevision)
        XCTAssertEqual(session.deckA.assetDurationSamples, asset.durationSamples.value)
        // Unknown or MIDI assets are rejected.
        XCTAssertThrowsError(try session.loadDeck(.b, asset: asset.withID("other")))
        let midi = try MusicAsset(id: MusicAssetID(rawValue: "m1"), sourceLocator: "cas://m1",
                                  contentHash: MusicFixtures.hexHash("m1"), kind: .midiFile,
                                  durationSamples: MusicSampleTime(0), name: "m")
        XCTAssertThrowsError(try session.loadDeck(.b, asset: midi))
    }

    func testDeckRejectsStaleSourceIdentity() throws {
        let asset = try makeAsset(revision: 1)
        var session = try MusicDJSession(assets: [asset])
        try session.loadDeck(.a, asset: asset)
        // Simulate the staged asset being replaced by a newer source revision:
        // the deck's cached identity no longer matches.
        let replaced = try MusicAsset(id: asset.id, sourceLocator: asset.sourceLocator,
                                      contentHash: MusicFixtures.hexHash("new-content"),
                                      sourceRevision: 2, kind: .audioMP3,
                                      durationSamples: MusicSampleTime(10_000_000), name: asset.name)
        XCTAssertThrowsError(try MusicDJSession(assets: [replaced], deckA: session.deckA)) { error in
            guard case MusicError.invalidDJ = error else {
                return XCTFail("expected invalidDJ, got \(error)")
            }
        }
    }

    func testSeekRateAndCueBounds() throws {
        let asset = try makeAsset()
        var session = try MusicDJSession(assets: [asset])
        try session.loadDeck(.a, asset: asset)
        try session.setRate(.a, rate: 0.1)
        XCTAssertEqual(session.deckA.rate, MusicDJSession.minRate) // clamped
        try session.setRate(.a, rate: 100)
        XCTAssertEqual(session.deckA.rate, MusicDJSession.maxRate)
        XCTAssertThrowsError(try session.setRate(.a, rate: .nan))
        // Negative seeks throw; oversized seeks clamp to asset duration.
        XCTAssertThrowsError(try session.seek(.a, sample: -1))
        try session.seek(.a, sample: 99_000_000)
        XCTAssertEqual(session.deckA.playheadSamples, asset.durationSamples.value)
        // Cue clamps into bounds and jump returns to it.
        try session.setCue(.a, sample: 5_000_000)
        try session.seek(.a, sample: 8_000_000)
        try session.jumpToCue(.a)
        XCTAssertEqual(session.deckA.playheadSamples, 5_000_000)
        XCTAssertThrowsError(try session.setCue(.b, sample: 0)) // empty deck has no asset; cue still settable
    }

    func testHotcueIndexBounds() throws {
        let asset = try makeAsset()
        var session = try MusicDJSession(assets: [asset])
        try session.loadDeck(.a, asset: asset)
        XCTAssertThrowsError(try session.setHotcue(.a, index: 8, sample: 0))
        XCTAssertThrowsError(try session.setHotcue(.a, index: -1, sample: 0))
        try session.setHotcue(.a, index: 0, sample: 1_000_000)
        try session.setHotcue(.a, index: 0, sample: 2_000_000) // replace same slot
        XCTAssertEqual(session.deckA.hotcues.count, 1)
        XCTAssertEqual(session.deckA.hotcues[0].sample, 2_000_000)
        try session.seek(.a, sample: 9_000_000)
        try session.jumpToHotcue(.a, index: 0)
        XCTAssertEqual(session.deckA.playheadSamples, 2_000_000)
        XCTAssertThrowsError(try session.jumpToHotcue(.a, index: 7))
    }

    func testLoopBoundaries() throws {
        let asset = try makeAsset()
        var session = try MusicDJSession(assets: [asset])
        try session.loadDeck(.a, asset: asset)
        // No grid -> no loop.
        XCTAssertThrowsError(try session.setLoop(.a, startBeat: 0, lengthBeats: 4))
        try session.setBeatGrid(.a, bpm: 120, firstBeatSample: 0, beatCount: 16)
        XCTAssertThrowsError(try session.setLoop(.a, startBeat: 0, lengthBeats: 0))
        XCTAssertThrowsError(try session.setLoop(.a, startBeat: 0, lengthBeats: 33))
        XCTAssertThrowsError(try session.setLoop(.a, startBeat: 14, lengthBeats: 4)) // past grid
        try session.setLoop(.a, startBeat: 4, lengthBeats: 4)
        XCTAssertEqual(session.deckA.activeLoop?.startBeat, 4)
        try session.exitLoop(.a)
        XCTAssertNil(session.deckA.activeLoop)
    }

    func testSyncTempoAndPhase() throws {
        let assetA = try makeAsset(id: "a", duration: 20_000_000)
        let assetB = try makeAsset(id: "b", duration: 20_000_000)
        var session = try MusicDJSession(assets: [assetA, assetB], sampleRate: 48_000)
        try session.loadDeck(.a, asset: assetA)
        try session.loadDeck(.b, asset: assetB)
        try session.setBeatGrid(.a, bpm: 120, firstBeatSample: 0, beatCount: 64)
        try session.setBeatGrid(.b, bpm: 100, firstBeatSample: 0, beatCount: 64)
        try session.setRate(.a, rate: 1.0)
        // Deck B is half a beat behind in phase.
        let beatB = 60.0 * 48_000 / 100.0 // 28 800 samples per beat
        try session.seek(.b, sample: Int64(beatB / 2))
        try session.syncDeck(.b, to: .a)
        // Tempo: effective BPM equal (120 * 1.0).
        XCTAssertEqual(session.deckB.rate * 100.0, 120.0, accuracy: 0.000_1)
        // Phase: slave shifted by half a beat.
        XCTAssertEqual(session.deckB.playheadSamples, Int64(beatB), accuracy: 2)
    }

    func testSyncRequiresGrids() throws {
        let asset = try makeAsset()
        var session = try MusicDJSession(assets: [asset])
        try session.loadDeck(.a, asset: asset)
        try session.loadDeck(.b, asset: asset)
        XCTAssertThrowsError(try session.syncDeck(.b, to: .a))
    }

    func testEqualPowerCrossfaderBoundaries() throws {
        let asset = try makeAsset()
        var session = try MusicDJSession(assets: [asset])
        try session.setCrossfader(0)
        var gains = session.channelGains()
        XCTAssertEqual(gains.deckAMaster, 1, accuracy: 1e-12)
        XCTAssertEqual(gains.deckBMaster, 0, accuracy: 1e-12)
        try session.setCrossfader(1)
        gains = session.channelGains()
        XCTAssertEqual(gains.deckAMaster, 0, accuracy: 1e-12)
        XCTAssertEqual(gains.deckBMaster, 1, accuracy: 1e-12)
        try session.setCrossfader(0.5)
        gains = session.channelGains()
        XCTAssertEqual(gains.deckAMaster, sqrt(0.5), accuracy: 1e-12)
        XCTAssertEqual(gains.deckBMaster, sqrt(0.5), accuracy: 1e-12)
        // Constant power everywhere.
        for position in stride(from: 0.0, through: 1.0, by: 0.05) {
            try session.setCrossfader(position)
            let g = session.channelGains()
            XCTAssertEqual(g.deckAMaster * g.deckAMaster + g.deckBMaster * g.deckBMaster,
                           1, accuracy: 1e-9)
        }
        XCTAssertThrowsError(try session.setCrossfader(.infinity))
    }

    func testSingleStereoCueBusHonesty() throws {
        let asset = try makeAsset()
        var session = try MusicDJSession(assets: [asset])
        try session.setCueSource(.deckA)
        var gains = session.channelGains()
        XCTAssertEqual(gains.deckACue, session.cueGain)
        XCTAssertEqual(gains.deckBCue, 0)
        // Cueing B replaces A: one stereo output cannot expose two
        // independent stereo cue channels.
        try session.setCueSource(.deckB)
        gains = session.channelGains()
        XCTAssertEqual(gains.deckACue, 0)
        XCTAssertEqual(gains.deckBCue, session.cueGain)
        try session.setCueSource(.none)
        gains = session.channelGains()
        XCTAssertEqual(gains.deckACue + gains.deckBCue, 0)
        XCTAssertThrowsError(try session.setCueGain(5))
        XCTAssertThrowsError(try session.setMasterGain(-0.5))
    }

    func testPlayingIsEphemeralAndRestoredStopped() throws {
        let asset = try makeAsset()
        var session = try MusicDJSession(assets: [asset])
        try session.loadDeck(.a, asset: asset)
        try session.setPlaying(.a, true)
        XCTAssertTrue(session.deckA.playing)
        let encoder = JSONEncoder()
        let data = try encoder.encode(session)
        let restored = try JSONDecoder().decode(MusicDJSession.self, from: data)
        XCTAssertFalse(restored.deckA.playing)
    }

    func testRoundTrip() throws {
        let asset = try makeAsset()
        var session = try MusicDJSession(assets: [asset])
        try session.loadDeck(.a, asset: asset)
        try session.setBeatGrid(.a, bpm: 128, firstBeatSample: 0, beatCount: 64)
        try session.setHotcue(.a, index: 3, sample: 1_234_567)
        try session.setLoop(.a, startBeat: 8, lengthBeats: 8)
        try session.setCrossfader(0.25)
        let data = try JSONEncoder().encode(session)
        let restored = try JSONDecoder().decode(MusicDJSession.self, from: data)
        XCTAssertEqual(restored, session)
    }
}

private extension MusicAsset {
    func withID(_ raw: String) -> MusicAsset {
        // Fixture helper: same content, different identity.
        try! MusicAsset(id: MusicAssetID(rawValue: raw), sourceLocator: "cas://\(raw)",
                        contentHash: MusicFixtures.hexHash(raw), kind: self.kind,
                        durationSamples: self.durationSamples, name: raw)
    }
}
