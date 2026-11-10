import XCTest
@testable import FloeMusicCore

@MainActor final class DJEditingTests: XCTestCase {
    private func setup() throws -> (MusicDocument, MusicDJWorkspace) {
        let a = try MusicFixtures.asset(id: "A", durationSamples: 480_000)
        let b = try MusicFixtures.asset(id: "B", durationSamples: 480_000)
        let document = try MusicDocument(name: "Decks", assets: [a, b])
        return (document, try MusicDJWorkspace(projectID: document.id, session: MusicDJSession(assets: document.assets)))
    }
    func testLegacySavedSessionPreservesCuesAndRestoresStopped() throws {
        let (document, original) = try setup(); var session = original.session
        try session.loadDeck(.a, asset: document.assets[0]); try session.setCue(.a, sample: 24_000)
        try session.setHotcue(.a, index: 2, sample: 48_000); try session.setPlaying(.a, true)
        let legacy = try JSONEncoder().encode(session)
        let loaded = try MusicDJWorkspace.decodeSaved(legacy, projectID: document.id)
        XCTAssertEqual(loaded.revision, 0); XCTAssertEqual(loaded.session.deckA.cue?.sample, 24_000)
        XCTAssertEqual(loaded.session.deckA.hotcues[0].index, 2); XCTAssertFalse(loaded.session.deckA.playing)
        let bytes = try JSONEncoder().encode(loaded)
        XCTAssertEqual(try MusicDJWorkspace.decodeSaved(bytes, projectID: document.id), loaded)
        XCTAssertThrowsError(try MusicDJWorkspace.decodeSaved(bytes, projectID: .init()))
    }
    func testTypedModelBatchAndUITransformProduceSameOriginal() throws {
        let (document, original) = try setup()
        let commands: [MusicDJEditCommand] = [.init(action: .load, deck: .a, assetID: document.assets[0].id),
            .init(action: .rate, deck: .a, value: 1.1), .init(action: .keyLock, deck: .a, enabled: true),
            .init(action: .cue, deck: .a, sample: 24_000), .init(action: .crossfader, value: 0.25)]
        let batch = try MusicDJEditBatch(expectedDJRevision: 0, commands: commands)
        let decoded = try MusicDJEditBatch.decode(JSONEncoder().encode(batch))
        let model = try original.applying(decoded, document: document, expectedMusicRevision: 0)
        let ui = try original.editing(document: document, expectedMusicRevision: 0, expectedDJRevision: 0) { session in
            try session.loadDeck(.a, asset: document.assets[0]); try session.setRate(.a, rate: 1.1)
            try session.setKeyLocked(.a, true); try session.setCue(.a, sample: 24_000); try session.setCrossfader(0.25)
        }
        XCTAssertEqual(model, ui); XCTAssertEqual(model.projectID, document.id); XCTAssertEqual(model.revision, 1)
        XCTAssertEqual(document.assets, original.session.assets); XCTAssertTrue(original.session.deckA.assetID == nil)
    }
    func testStaleMusicAndDJRevisionsRejectWholeBatch() throws {
        let (document, original) = try setup()
        let load = try MusicDJEditBatch(expectedDJRevision: 0, commands: [.init(action: .load, deck: .a, assetID: document.assets[0].id)])
        let next = try original.applying(load, document: document, expectedMusicRevision: 0)
        XCTAssertThrowsError(try next.applying(load, document: document, expectedMusicRevision: 0))
        XCTAssertThrowsError(try original.applying(load, document: document, expectedMusicRevision: 1))
        let invalid = try MusicDJEditBatch(expectedDJRevision: 1, commands: [
            .init(action: .crossfader, value: 0), .init(action: .hotcue, deck: .a, sample: 0, index: 100)])
        XCTAssertThrowsError(try next.applying(invalid, document: document, expectedMusicRevision: 0))
        XCTAssertEqual(next.session.crossfader, 0.5); XCTAssertEqual(next.revision, 1)
    }
    func testMissingSourceNeverResetsSavedDeckAndCanBeExplicitlyEjected() throws {
        let (document, original) = try setup()
        let load = try MusicDJEditBatch(expectedDJRevision: 0, commands: [.init(action: .load, deck: .a, assetID: document.assets[0].id)])
        let next = try original.applying(load, document: document, expectedMusicRevision: 0)
        var removed = document; removed.assets.removeFirst()
        XCTAssertThrowsError(try next.editing(document: removed, expectedMusicRevision: 0, expectedDJRevision: 1) { try $0.setCrossfader(0) })
        XCTAssertEqual(next.session.deckA.assetID, document.assets[0].id)
        let repaired = try next.applying(.init(expectedDJRevision: 1, commands: [.init(action: .eject, deck: .a)]),
            document: removed, expectedMusicRevision: 0)
        XCTAssertNil(repaired.session.deckA.assetID); XCTAssertEqual(repaired.session.assets, removed.assets)
    }
    func testAllLoopSyncCueCommandsApplyWithOwnershipAndBounds() throws {
        let (document, original) = try setup()
        let commands: [MusicDJEditCommand] = [
            .init(action: .load, deck: .a, assetID: document.assets[0].id),
            .init(action: .load, deck: .b, assetID: document.assets[1].id),
            .init(action: .beatGrid, deck: .a, value: 120, firstBeatSample: 0, beatCount: 20),
            .init(action: .beatGrid, deck: .b, value: 100, firstBeatSample: 0, beatCount: 16),
            .init(action: .seek, deck: .a, sample: 60_000), .init(action: .cue, deck: .a, sample: 24_000),
            .init(action: .jumpCue, deck: .a), .init(action: .hotcue, deck: .a, sample: 48_000, index: 2),
            .init(action: .jumpHotcue, deck: .a, index: 2), .init(action: .loop, deck: .a, startBeat: 2, lengthBeats: 4),
            .init(action: .exitLoop, deck: .a), .init(action: .sync, deck: .b, otherDeck: .a),
            .init(action: .masterGain, value: 0.8), .init(action: .cueGain, value: 0.7),
            .init(action: .cueSource, cueSource: .deckA), .init(action: .playing, deck: .a, enabled: true)]
        let next = try original.applying(.init(expectedDJRevision: 0, commands: commands), document: document, expectedMusicRevision: 0)
        XCTAssertEqual(next.session.deckA.playheadSamples, 48_000); XCTAssertEqual(next.session.deckB.rate, 1.2, accuracy: 0.0001)
        XCTAssertNil(next.session.deckA.activeLoop); XCTAssertTrue(next.session.deckA.playing)
        XCTAssertEqual(next.session.masterGain, 0.8); XCTAssertEqual(next.session.cueSource, .deckA)
        XCTAssertThrowsError(try next.applying(.init(expectedDJRevision: 1, commands: [.init(action: .load, deck: .a, assetID: .init(rawValue: "foreign"))]),
            document: document, expectedMusicRevision: 0))
    }
    func testDecodeGivesFieldPathAndRejectsUnknownFieldsOrActions() throws {
        for json in [
            #"{"workspace":"dj","expectedDJRevision":0,"commands":[{"action":"not-a-command"}]}"#,
            #"{"workspace":"dj","expectedDJRevision":"zero","commands":[]}"#,
            #"{"workspace":"dj","expectedDJRevision":0,"commands":[{"action":"seek","offset":5}]}"#
        ] {
            XCTAssertThrowsError(try MusicDJEditBatch.decode(Data(json.utf8))) { error in
                XCTAssertTrue(error is MusicEditJSONError); XCTAssertTrue(error.localizedDescription.contains("$"))
            }
        }
        let (document, original) = try setup()
        let missing = try MusicDJEditBatch.decode(Data(#"{"workspace":"dj","expectedDJRevision":0,"commands":[{"action":"seek","deck":"a"}]}"#.utf8))
        XCTAssertThrowsError(try original.applying(missing, document: document, expectedMusicRevision: 0)) { error in
            XCTAssertTrue(error.localizedDescription.contains("commands[0]")); XCTAssertTrue(error.localizedDescription.contains("sample"))
        }
    }
    func testNamedCueAndHotcueCanBeClearedThroughSameTypedBatch() throws {
        let (document, original) = try setup()
        let loaded = try original.applying(.init(expectedDJRevision: 0, commands: [
            .init(action: .load, deck: .a, assetID: document.assets[0].id),
            .init(action: .cue, deck: .a, sample: 0, label: "Intro"),
            .init(action: .hotcue, deck: .a, sample: 24_000, index: 0, label: "Verse")]), document: document, expectedMusicRevision: 0)
        XCTAssertEqual(loaded.session.deckA.cue?.label, "Intro")
        XCTAssertEqual(loaded.session.deckA.hotcues[0].label, "Verse")
        let cleared = try loaded.applying(.init(expectedDJRevision: 1, commands: [
            .init(action: .clearCue, deck: .a), .init(action: .removeHotcue, deck: .a, index: 0)]), document: document, expectedMusicRevision: 0)
        XCTAssertNil(cleared.session.deckA.cue); XCTAssertTrue(cleared.session.deckA.hotcues.isEmpty)
    }

    func testModelCanUsePlainAssetIDOrReturnedTypedIdentity() throws {
        let (document, original) = try setup()
        let text = #"{"workspace":"dj","expectedDJRevision":0,"commands":[{"action":"load","deck":"a","assetID":"A"}]}"#
        let batch = try MusicDJEditBatch.decode(Data(text.utf8))
        XCTAssertEqual(batch.commands[0].assetID, document.assets[0].id)
        let updated = try original.applying(batch, document: document, expectedMusicRevision: 0)
        XCTAssertEqual(updated.session.deckA.assetID, document.assets[0].id)
    }

}
