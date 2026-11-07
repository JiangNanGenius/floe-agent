import XCTest
@testable import FloeMusicCore

@MainActor
final class MusicPresetCatalogTests: XCTestCase {
    func testStableLegacyIndicesAndCodableCatalog() throws {
        XCTAssertEqual(MusicPresetCatalog.all.map(\.index), Array(0...40))
        XCTAssertEqual(Set(MusicPresetCatalog.all.map(\.category)), Set(MusicPresetCategory.allCases))
        XCTAssertEqual(MusicPresetCatalog.preset(index: 0)?.parameters,
                       ["waveform": 0, "attack": 0.008, "decay": 0.08, "sustain": 0.75, "release": 0.08, "gain": 1])
        XCTAssertEqual(MusicPresetCatalog.preset(index: 1)?.parameters["waveform"], 1)
        XCTAssertEqual(MusicPresetCatalog.preset(index: 40)?.category, .percussion)
        XCTAssertNil(MusicPresetCatalog.preset(index: -1))
        XCTAssertNil(MusicPresetCatalog.preset(index: 1000))
        let bytes = try JSONEncoder().encode(MusicPresetCatalog.all)
        XCTAssertEqual(try JSONDecoder().decode([MusicInstrumentPreset].self, from: bytes), MusicPresetCatalog.all)
        let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys
        XCTAssertEqual(Set(try MusicPresetCatalog.all.map { try encoder.encode($0.parameters) }).count, 41)
        for preset in MusicPresetCatalog.all {
            XCTAssertEqual(preset.id, preset.index)
            XCTAssertFalse(preset.nameEN.isEmpty)
            XCTAssertFalse(preset.nameZH.isEmpty)
            XCTAssertTrue(preset.parameters.values.allSatisfy(\.isFinite))
        }
    }

    func testEveryPresetAndOverrideSurvivesSaveAndReopen() async throws {
        let repository = InMemoryMusicRepository()
        let tracks = try MusicPresetCatalog.all.map { preset in
            try MusicTrack(name: preset.nameEN, kind: .midi,
                           instrument: MusicPluginState(pluginID: "floe.synth", presetIndex: preset.index,
                                                        parameters: ["attack": 0.02, "gain": 0.65]))
        }
        let document = try MusicDocument(name: "Preset round trip", tracks: tracks)
        _ = try await repository.save(document: document, expectedRevision: nil)
        let reopened = try await repository.load(projectID: document.id)
        let decoded = try JSONDecoder().decode(MusicDocument.self, from: JSONEncoder().encode(reopened))
        XCTAssertEqual(decoded, document)
        for (index, track) in decoded.tracks.enumerated() {
            XCTAssertEqual(track.instrument?.presetIndex, index)
            XCTAssertEqual(track.instrument?.parameters, ["attack": 0.02, "gain": 0.65])
            XCTAssertNotNil(MusicPresetCatalog.preset(index: track.instrument!.presetIndex))
        }
    }
}
