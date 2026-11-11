import XCTest
@testable import FloeMusicCore

/// The shared accompaniment rule used by the live recording transport, the
/// offline renderer and the session must resolve mute/solo identically and
/// report content end in project samples.
final class MusicArrangementAudibleTests: XCTestCase {
    private func track(id: String, kind: MusicTrack.Kind, muted: Bool = false,
                       soloed: Bool = false, clips: [MusicClip] = []) throws -> MusicTrack {
        try MusicTrack(id: MusicTrackID(rawValue: id), name: id, kind: kind, clips: clips,
                       strip: MusicStripSettings(muted: muted, soloed: soloed))
    }

    func testNoSoloOrMuteSoundsEveryTrack() throws {
        let a = try track(id: "a", kind: .midi)
        let b = try track(id: "b", kind: .audio)
        let document = try MusicFixtures.emptyDocument()
            .settingTracks([a, b])
        XCTAssertEqual(document.audibleTracks.map(\.id.rawValue), ["a", "b"])
    }

    func testMutedTrackIsSilentAndAnySoloRestrictsToSoloedTracks() throws {
        let muted = try track(id: "muted", kind: .midi, muted: true)
        let open = try track(id: "open", kind: .midi)
        let soloed = try track(id: "solo", kind: .audio, soloed: true)
        let document = try MusicFixtures.emptyDocument().settingTracks([muted, open, soloed])
        XCTAssertEqual(document.audibleTracks.map(\.id.rawValue), ["solo"])
        let unmuted = try MusicFixtures.emptyDocument().settingTracks([muted, open])
        XCTAssertEqual(unmuted.audibleTracks.map(\.id.rawValue), ["open"])
    }

    func testContentEndIsLatestClipEndAcrossTrackKinds() throws {
        let asset = try MusicFixtures.asset(id: "asset-1")
        let audio = try track(id: "audio", kind: .audio,
                              clips: [try MusicFixtures.audioClip(id: "c1", trackID: "audio",
                                                                assetID: asset.id.rawValue,
                                                                offset: 480_000, duration: 96_000)])
        // 960 ticks = one quarter at 120 bpm = 0.5 s = 24_000 samples at
        // 48 kHz, placed at offset 240_000 → MIDI clip end 264_000. The audio
        // clip ends later, so content end follows it.
        let midi = try track(id: "midi", kind: .midi,
                             clips: [try MusicFixtures.midiClip(id: "c2", trackID: "midi",
                                                                offset: 240_000,
                                                                durationTicks: 960,
                                                                notes: [try MusicFixtures.midiNote(start: 0, duration: 960)])])
        let document = try MusicFixtures.emptyDocument()
            .settingAssets([asset])
            .settingTracks([audio, midi])
        XCTAssertEqual(document.contentEndSample.value, 576_000)
    }

    func testEmptyProjectHasZeroContentEnd() throws {
        XCTAssertEqual(try MusicFixtures.emptyDocument().contentEndSample.value, 0)
    }
}

private extension MusicDocument {
    func settingTracks(_ tracks: [MusicTrack]) throws -> MusicDocument {
        try MusicDocument(id: id, name: name, createdAt: createdAt, updatedAt: updatedAt,
                          revision: revision, tempoMap: tempoMap, assets: assets,
                          tracks: tracks, buses: buses, masterStrip: masterStrip,
                          automationLanes: automationLanes)
    }
    func settingAssets(_ assets: [MusicAsset]) throws -> MusicDocument {
        try MusicDocument(id: id, name: name, createdAt: createdAt, updatedAt: updatedAt,
                          revision: revision, tempoMap: tempoMap, assets: assets,
                          tracks: tracks, buses: buses, masterStrip: masterStrip,
                          automationLanes: automationLanes)
    }
}
