import XCTest
@testable import FloeMusicCore

/// Round-trip coding plus malformed-payload rejection and content
/// preservation (unsupported asset kinds and plugin states).
@MainActor
final class CodecTests: XCTestCase {
    private func roundTrip(_ document: MusicDocument) throws -> MusicDocument {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(document)
        return try JSONDecoder().decode(MusicDocument.self, from: data)
    }

    func testRoundTripPreservesContent() throws {
        let asset = try MusicFixtures.asset()
        let audioClip = try MusicFixtures.audioClip(id: "clip-a", trackID: "track-a",
                                                    assetID: asset.id.rawValue)
        let note = try MusicFixtures.midiNote()
        let midiClip = try MusicFixtures.midiClip(id: "clip-m", trackID: "track-m", notes: [note])
        let plugin = try MusicPluginState(
            pluginID: "au://vendor/eq", enabled: true,
            parameters: ["frequency": 1_200.0],
            stateBlob: Data([0xDE, 0xAD]))
        let audioTrack = try MusicTrack(id: MusicTrackID(rawValue: "track-a"),
                                        name: "vox", kind: .audio, clips: [audioClip])
        let midiTrack = try MusicTrack(id: MusicTrackID(rawValue: "track-m"),
                                       name: "keys", kind: .midi, clips: [midiClip],
                                       instrument: plugin)
        let document = try MusicDocument(
            id: MusicProjectID(rawValue: "project-1"), name: "song",
            tempoMap: MusicFixtures.defaultTempoMap(),
            assets: [asset], tracks: [audioTrack, midiTrack])

        let decoded = try roundTrip(document)
        XCTAssertEqual(decoded, document)
        // Unsupported / foreign content survives verbatim.
        XCTAssertEqual(decoded.tracks[1].instrument?.stateBlob, Data([0xDE, 0xAD]))
        XCTAssertEqual(decoded.tracks[1].instrument?.parameters["frequency"], 1_200.0)
    }

    func testUnsupportedAssetKindPreserved() throws {
        let asset = try MusicAsset(id: MusicAssetID(rawValue: "asset-x"),
                                   sourceLocator: "cas://x",
                                   contentHash: MusicFixtures.hexHash("x"),
                                   kind: .unsupportedRaw("audioFLAC"),
                                   durationSamples: MusicSampleTime(10),
                                   name: "flac")
        let data = try JSONEncoder().encode([asset])
        let decoded = try JSONDecoder().decode([MusicAsset].self, from: data)
        guard case .unsupportedRaw(let raw) = decoded[0].kind else {
            return XCTFail("unsupported kind was dropped")
        }
        XCTAssertEqual(raw, "audioFLAC")
    }

    func testDecoderRejectsMalformedNotePitch() throws {
        let note = try MusicFixtures.midiNote(pitch: 60)
        var object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(note)) as! [String: Any]
        object["pitch"] = 200
        let data = try JSONSerialization.data(withJSONObject: object)
        XCTAssertThrowsError(try JSONDecoder().decode(MusicMIDINote.self, from: data)) { error in
            guard case DecodingError.dataCorrupted = error else {
                return XCTFail("expected dataCorrupted, got \(error)")
            }
        }
    }

    func testDecoderRejectsMalformedDocumentFields() throws {
        let document = try MusicFixtures.emptyDocument()
        let base = try JSONSerialization.jsonObject(with: JSONEncoder().encode(document)) as! [String: Any]

        // Unsupported schema versions (zero / negative / newer) are rejected.
        for version in [0, -1, MusicDocument.currentSchemaVersion + 1] {
            var object = base
            object["schemaVersion"] = version
            let data = try JSONSerialization.data(withJSONObject: object)
            XCTAssertThrowsError(try JSONDecoder().decode(MusicDocument.self, from: data),
                                 "schemaVersion \(version) must be rejected") { error in
                guard case DecodingError.dataCorrupted = error else {
                    return XCTFail("expected dataCorrupted, got \(error)")
                }
            }
        }

        // Negative clip offset is rejected.
        var object = base
        object["tracks"] = [[
            "id": "t1", "name": "t", "kind": "audio",
            "clips": [[
                "id": "c1", "trackID": "t1", "offset": [-5],
                "body": ["kind": "audio", "audio": [
                    "assetID": "missing", "trimStartSamples": 0, "durationSamples": 100,
                    "fadeInSamples": 0, "fadeOutSamples": 0, "gain": 1, "pan": 0,
                ]],
            ]],
        ]]
        var data = try JSONSerialization.data(withJSONObject: object)
        XCTAssertThrowsError(try JSONDecoder().decode(MusicDocument.self, from: data))

        // Fade longer than clip duration is rejected.
        object = base
        object["assets"] = [[
            "id": "a1", "sourceLocator": "cas://a1",
            "contentHashAlgorithm": "sha256",
            "contentHash": MusicFixtures.hexHash("a1"),
            "sourceRevision": 0, "kind": "audioMP3",
            "durationSamples": [1_000], "name": "a", "provenance": "",
        ]]
        object["tracks"] = [[
            "id": "t1", "name": "t", "kind": "audio",
            "clips": [[
                "id": "c1", "trackID": "t1", "offset": [0],
                "body": ["kind": "audio", "audio": [
                    "assetID": "a1", "trimStartSamples": 0, "durationSamples": 100,
                    "fadeInSamples": 60, "fadeOutSamples": 60, "gain": 1, "pan": 0,
                ]],
            ]],
        ]]
        data = try JSONSerialization.data(withJSONObject: object)
        XCTAssertThrowsError(try JSONDecoder().decode(MusicDocument.self, from: data))

        // Asset hash that is not 64 lowercase hex chars is rejected.
        object = base
        object["assets"] = [[
            "id": "a1", "sourceLocator": "cas://a1",
            "contentHash": "XYZ", "kind": "audioMP3",
            "durationSamples": [0], "name": "a",
        ]]
        data = try JSONSerialization.data(withJSONObject: object)
        XCTAssertThrowsError(try JSONDecoder().decode(MusicDocument.self, from: data))
    }

    func testOverlappingClipsAllowed() throws {
        // Splice/overlap arrangement is standard DAW behaviour and must not
        // be rejected by the model.
        let asset = try MusicFixtures.asset()
        let first = try MusicFixtures.audioClip(id: "c1", trackID: "t1",
                                                assetID: asset.id.rawValue,
                                                offset: 0, duration: 100_000)
        let second = try MusicFixtures.audioClip(id: "c2", trackID: "t1",
                                                 assetID: asset.id.rawValue,
                                                 offset: 50_000, duration: 100_000,
                                                 fadeIn: 10_000, fadeOut: 10_000)
        let track = try MusicTrack(id: MusicTrackID(rawValue: "t1"), name: "t",
                                   kind: .audio, clips: [first, second])
        let document = try MusicDocument(
            name: "song", tempoMap: MusicFixtures.defaultTempoMap(),
            assets: [asset], tracks: [track])
        let decoded = try roundTrip(document)
        XCTAssertEqual(decoded.tracks[0].clips.count, 2)
    }
}
