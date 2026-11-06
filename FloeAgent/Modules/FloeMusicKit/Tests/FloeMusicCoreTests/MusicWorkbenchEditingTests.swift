import XCTest
@testable import FloeMusicCore

@MainActor
final class MusicWorkbenchEditingTests: XCTestCase {
    func testAudioSplitPreservesSourceAndOuterFades() throws {
        let map = try MusicFixtures.defaultTempoMap()
        let clip = try MusicFixtures.audioClip(id: "c", trackID: "t", assetID: "a", offset: 100, duration: 1000, fadeIn: 50, fadeOut: 60)
        let ops = try MusicWorkbenchEditing.split(clip, at: .init(500), tempoMap: map)
        guard case .updateClip(let left) = ops[0], case .insertClip(let right) = ops[1],
              case .audio(let a) = left.body, case .audio(let b) = right.body else { return XCTFail("audio split") }
        XCTAssertEqual(a.durationSamples, 400)
        XCTAssertEqual(a.fadeInSamples, 50)
        XCTAssertEqual(a.fadeOutSamples, 0)
        XCTAssertEqual(b.trimStartSamples, 400)
        XCTAssertEqual(b.durationSamples, 600)
        XCTAssertEqual(b.fadeOutSamples, 60)
        XCTAssertEqual(right.offset.value, 500)
        XCTAssertNotEqual(left.id, right.id)
    }

    func testMIDISplitRetainsCrossingNotesAndControllerOrderAtTempoChange() throws {
        let map = try MusicTempoMap(segments: [
            .init(startTick: .init(0), bpm: 120, beatsPerBar: 4, beatUnit: 4),
            .init(startTick: .init(960), bpm: 90, beatsPerBar: 4, beatUnit: 4)
        ])
        let payload = try MusicMIDIClipPayload(durationTicks: 2880, notes: [
            .init(pitch: 60, startTick: .init(480), durationTicks: 1440, velocity: 100)
        ], controllerPoints: [
            .init(controller: 1, tick: .init(240), value: 30),
            .init(controller: 1, tick: .init(1200), value: 90),
            .init(controller: 64, tick: .init(0), value: 127)
        ])
        let clip = try MusicClip(trackID: MusicTrackID(), offset: .init(0), body: .midi(payload))
        let split = try map.sample(atTick: .init(960))
        let ops = try MusicWorkbenchEditing.split(clip, at: split, tempoMap: map)
        guard case .updateClip(let left) = ops[0], case .insertClip(let right) = ops[1],
              case .midi(let a) = left.body, case .midi(let b) = right.body else { return XCTFail("MIDI split") }
        XCTAssertEqual(a.notes[0].durationTicks, 480)
        XCTAssertEqual(b.notes[0].startTick.value, 0)
        XCTAssertEqual(b.notes[0].durationTicks, 960)
        XCTAssertEqual(right.offset, split)
        XCTAssertEqual(b.controllerPoints.map(\.controller), [1, 1, 64])
        XCTAssertEqual(b.controllerPoints.map { $0.tick.value }, [0, 240, 0])
        _ = try MusicMIDIClipPayload(durationTicks: b.durationTicks, notes: b.notes, controllerPoints: b.controllerPoints)
    }

    func testMixerMasterAndBusEditsAreAtomicAndUndoable() async throws {
        let bus = try MusicBus(id: .init(rawValue: "aux"), name: "Return", sends: [MusicBus.masterBusID])
        let document = try MusicDocument(name: "Mix", buses: [bus])
        let store = try await MusicProjectStore(document: document, repository: FixtureMusicRepository())
        let owner = await store.beginSession(ownerToken: "workbench")
        let saved = try await store.commit(.init(baseRevision: 0, ops: [
            .setMasterStrip(.init(gain: 0.8)),
            .setBusStrip(bus.id, .init(gain: 0.4)),
            .setBusEffects(bus.id, [.init(pluginID: "floe.reverb", parameters: ["mix": 1])])
        ]), as: owner)
        XCTAssertEqual(saved.masterStrip.gain, 0.8)
        XCTAssertEqual(saved.buses[0].strip.gain, 0.4)
        let undone = try await store.undo(await store.beginSession(ownerToken: "workbench"))
        XCTAssertEqual(undone.masterStrip.gain, 1)
        XCTAssertTrue(undone.buses[0].effects.isEmpty)
        var invalid = try MusicStripSettings(); invalid.gain = .nan
        await XCTAssertThrowsErrorAsync(try await store.commit(.init(baseRevision: undone.revision, ops: [.setMasterStrip(invalid)]), as: await store.beginSession(ownerToken: "workbench")))
        let current = try await store.currentSnapshot()
        XCTAssertEqual(current.revision, undone.revision)
        XCTAssertEqual(current.masterStrip.gain, 1)
    }

    func testTrimAndQuantizeKeepNotesInsideMusicalClip() throws {
        let map = try MusicFixtures.defaultTempoMap()
        let clip = try MusicFixtures.midiClip(id: "c", trackID: "t", notes: [MusicFixtures.midiNote(start: 40, duration: 1200)])
        let trimmed = try MusicWorkbenchEditing.trim(clip, start: map.sample(atTick: .init(480)), end: map.sample(atTick: .init(1440)), tempoMap: map)
        guard case .midi(let payload) = trimmed.body else { return XCTFail("MIDI trim") }
        XCTAssertEqual(payload.durationTicks, 960)
        XCTAssertEqual(payload.notes[0].durationTicks, 760)
        let quantized = try MusicWorkbenchEditing.quantize(trimmed, gridTicks: 240)
        guard case .midi(let notes) = quantized.body else { return XCTFail("quantize") }
        XCTAssertEqual(notes.notes[0].startTick.value, 0)
        XCTAssertLessThanOrEqual(notes.notes[0].durationTicks, notes.durationTicks)
    }
}
