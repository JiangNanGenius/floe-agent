// SPDX-License-Identifier: MPL-2.0
import XCTest
@testable import FloeMusicCore

@MainActor final class TimelineEditingTests: XCTestCase {
    func testEmptyProjectCursorCanSeekBeyondOneSecondAndRejectsNonFinite() {
        XCTAssertEqual(MusicTimelineEditing.cursor(seconds: 15, sampleRate: 48_000), 15)
        XCTAssertEqual(MusicTimelineEditing.cursor(seconds: -3, sampleRate: 48_000), 0)
        XCTAssertNil(MusicTimelineEditing.cursor(seconds: .nan, sampleRate: 48_000))
        XCTAssertNil(MusicTimelineEditing.cursor(seconds: .infinity, sampleRate: 48_000))
        XCTAssertNil(MusicTimelineEditing.cursor(seconds: 3, sampleRate: 0))
        XCTAssertEqual(MusicTimelineEditing.cursor(seconds: 1e250, sampleRate: 48_000), 9e15 / 48_000)
    }

    func testFingerPansScrollUntilHeldButSelectedEdgesTrim() {
        XCTAssertNil(MusicTimelineInputPolicy.editKind(x: 60, width: 120, selected: false, finger: true))
        XCTAssertNil(MusicTimelineInputPolicy.editKind(x: 60, width: 120, selected: true, finger: true))
        XCTAssertEqual(MusicTimelineInputPolicy.editKind(x: 60, width: 120, selected: false, finger: true, held: true), .move)
        XCTAssertEqual(MusicTimelineInputPolicy.editKind(x: 3, width: 120, selected: true, finger: true), .trimStart)
        XCTAssertEqual(MusicTimelineInputPolicy.editKind(x: 117, width: 120, selected: true, finger: true), .trimEnd)
        // Narrow clips retain a body area; overlapping handles cannot choose
        // the opposite edge or steal all scrolling space.
        XCTAssertNil(MusicTimelineInputPolicy.editKind(x: 22, width: 44, selected: true, finger: true))
    }

    func testPencilAndPointerDirectEditingAndInvalidHitTests() {
        XCTAssertEqual(MusicTimelineInputPolicy.editKind(x: 60, width: 120, selected: false, finger: false), .move)
        XCTAssertEqual(MusicTimelineInputPolicy.editKind(x: 3, width: 120, selected: false, finger: false), .move)
        XCTAssertEqual(MusicTimelineInputPolicy.editKind(x: 117, width: 120, selected: true, finger: false), .trimEnd)
        XCTAssertNil(MusicTimelineInputPolicy.editKind(x: -1, width: 120, selected: true, finger: false))
        XCTAssertNil(MusicTimelineInputPolicy.editKind(x: .nan, width: 120, selected: true, finger: false))
        XCTAssertNil(MusicTimelineInputPolicy.editKind(x: 3, width: .infinity, selected: true, finger: false))
    }

    func testPinchPreservesTimeUnderAnchor() {
        let oldOffset = 420.0, anchor = 170.0, oldScale = 48.0, newScale = 108.0
        let result = MusicTimelineEditing.anchoredScrollOffset(offset: oldOffset, anchorX: anchor, oldScale: oldScale, newScale: newScale)
        XCTAssertEqual((oldOffset + anchor) / oldScale, (result + anchor) / newScale, accuracy: 1e-10)
        XCTAssertEqual(MusicTimelineEditing.anchoredScrollOffset(offset: 0, anchorX: 200, oldScale: 100, newScale: 25), 0)
    }

    func testMoveSnapsToMusicalGridAndKeepsOriginalAsset() throws {
        let map = try MusicFixtures.defaultTempoMap()
        let clip = try MusicFixtures.audioClip(id: "c", trackID: "t", assetID: "source", offset: 12_345, duration: 48_000)
        let moved = try MusicTimelineEditing.edit(clip, kind: .move, deltaSeconds: 0.14, snapping: true, tempoMap: map)
        XCTAssertEqual(moved.offset.value, 18_000) // 3 sixteenth notes at 120 BPM
        XCTAssertEqual(moved.id, clip.id); XCTAssertEqual(moved.body, clip.body)
        XCTAssertEqual(clip.offset.value, 12_345)
        let clamped = try MusicTimelineEditing.edit(clip, kind: .move, deltaSeconds: -100, snapping: false, tempoMap: map)
        XCTAssertEqual(clamped.offset.value, 0)
        XCTAssertEqual(try MusicTimelineEditing.edit(clip, kind: .move, deltaSeconds: 0, snapping: true, tempoMap: map), clip)
    }

    func testAudioEdgesCanRevealImmutableSourceAgain() throws {
        let map = try MusicFixtures.defaultTempoMap()
        let clip = try MusicClip(trackID: .init(rawValue: "t"), offset: .init(96_000),
            body: .audio(.init(assetID: .init(rawValue: "source"), trimStartSamples: 48_000, durationSamples: 96_000,
                               fadeInSamples: 5_000, fadeOutSamples: 5_000)))
        let left = try MusicTimelineEditing.edit(clip, kind: .trimStart, deltaSeconds: -10, snapping: false,
            tempoMap: map, sourceDurationSamples: 240_000)
        guard case .audio(let a) = left.body else { return XCTFail("audio") }
        XCTAssertEqual(left.offset.value, 48_000); XCTAssertEqual(a.trimStartSamples, 0)
        XCTAssertEqual(a.durationSamples, 144_000); XCTAssertEqual(a.assetID.rawValue, "source")
        let right = try MusicTimelineEditing.edit(clip, kind: .trimEnd, deltaSeconds: 20, snapping: false,
            tempoMap: map, sourceDurationSamples: 240_000)
        guard case .audio(let b) = right.body else { return XCTFail("audio") }
        XCTAssertEqual(b.durationSamples, 192_000); XCTAssertEqual(b.trimStartSamples, 48_000)
        let tiny = try MusicTimelineEditing.edit(clip, kind: .trimEnd, deltaSeconds: -20, snapping: false, tempoMap: map)
        guard case .audio(let c) = tiny.body else { return XCTFail("audio") }
        XCTAssertEqual(c.durationSamples, 1); XCTAssertEqual(c.fadeInSamples + c.fadeOutSamples, 0)
    }

    func testMIDIEdgesPreserveExpressionAcrossTempoChanges() throws {
        let map = try MusicTempoMap(segments: [
            .init(startTick: .init(0), bpm: 120, beatsPerBar: 4, beatUnit: 4),
            .init(startTick: .init(1_920), bpm: 80, beatsPerBar: 3, beatUnit: 4)
        ])
        let original = try MusicClip(trackID: .init(rawValue: "m"), offset: map.sample(atTick: .init(960)),
            body: .midi(.init(durationTicks: 2_880, notes: [
                .init(pitch: 60, startTick: .init(0), durationTicks: 1_600, velocity: 100, channel: 2)
            ], controllerPoints: [.init(controller: 64, tick: .init(0), value: 127, channel: 2)],
                programChanges: [.init(tick: .init(0), channel: 2, program: 12)])))
        let shorter = try MusicTimelineEditing.edit(original, kind: .trimStart, deltaSeconds: 0.25, snapping: true, tempoMap: map)
        guard case .midi(let a) = shorter.body else { return XCTFail("MIDI") }
        XCTAssertEqual(try map.tick(atSample: shorter.offset).value, 1_440)
        XCTAssertEqual(a.durationTicks, 2_400); XCTAssertEqual(a.notes[0].durationTicks, 1_120)
        XCTAssertEqual(a.controllerPoints[0].tick.value, 0); XCTAssertEqual(a.controllerPoints[0].channel, 2)
        XCTAssertEqual(a.programChanges[0].tick.value, 0); XCTAssertEqual(a.programChanges[0].program, 12)
        let longer = try MusicTimelineEditing.edit(original, kind: .trimEnd, deltaSeconds: 0.75, snapping: true, tempoMap: map)
        guard case .midi(let b) = longer.body else { return XCTFail("MIDI") }
        XCTAssertEqual(b.durationTicks, 3_840); XCTAssertEqual(b.notes, aNote(original))
        let earlier = try MusicTimelineEditing.edit(original, kind: .trimStart, deltaSeconds: -0.5, snapping: true, tempoMap: map)
        guard case .midi(let c) = earlier.body else { return XCTFail("MIDI") }
        XCTAssertEqual(earlier.offset.value, 0); XCTAssertEqual(c.durationTicks, 3_840)
        XCTAssertEqual(c.notes[0].startTick.value, 960)
        XCTAssertEqual(c.controllerPoints[0].tick.value, 960); XCTAssertEqual(c.programChanges[0].tick.value, 960)
    }

    func testPreviewDoesNotSaveAndCommitHasOneUndoAndStaleFence() async throws {
        let map = try MusicFixtures.defaultTempoMap()
        let track = try MusicTrack(id: .init(rawValue: "t"), name: "Keys", kind: .midi)
        let original = try MusicFixtures.midiClip(id: "c", trackID: "t", notes: [MusicFixtures.midiNote()])
        var document = try MusicDocument(name: "Timeline", tempoMap: map, tracks: [track])
        document.tracks[0].clips = [original]
        let repository = FixtureMusicRepository()
        let store = try await MusicProjectStore(document: document, repository: repository)
        let owner = await store.beginSession(ownerToken: "timeline")
        var preview = original
        for seconds in [0.1, 0.2, 0.3] {
            preview = try MusicTimelineEditing.edit(original, kind: .move, deltaSeconds: seconds, snapping: true, tempoMap: map)
        }
        let before = try await store.currentSnapshot()
        XCTAssertEqual(before.revision, 0); XCTAssertEqual(before.tracks[0].clips[0], original)
        let committed = try await store.commit(.init(baseRevision: 0, ops: [.updateClip(preview)]), as: owner)
        XCTAssertEqual(committed.revision, 1); XCTAssertEqual(committed.tracks[0].clips[0], preview)
        let reloaded = try await repository.load(projectID: document.id)
        XCTAssertEqual(reloaded.tracks[0].clips[0], preview)
        await XCTAssertThrowsErrorAsync(try await store.commit(.init(baseRevision: 0, ops: [.updateClip(original)]),
            as: await store.beginSession(ownerToken: "timeline")))
        let undone = try await store.undo(await store.beginSession(ownerToken: "timeline"))
        XCTAssertEqual(undone.tracks[0].clips[0], original)
        let redone = try await store.redo(await store.beginSession(ownerToken: "timeline"))
        XCTAssertEqual(redone.tracks[0].clips[0], preview)
    }

    func testMalformedMovementAndSourceRangeFailWithoutTrapping() throws {
        let map = try MusicFixtures.defaultTempoMap()
        let clip = try MusicFixtures.audioClip(id: "c", trackID: "t", assetID: "a", offset: 48_000)
        for delta in [Double.nan, .infinity, 1e250] {
            XCTAssertThrowsError(try MusicTimelineEditing.edit(clip, kind: .move, deltaSeconds: delta, snapping: false, tempoMap: map))
        }
        XCTAssertThrowsError(try MusicTimelineEditing.edit(clip, kind: .trimEnd, deltaSeconds: 1, snapping: false,
            tempoMap: map, sourceDurationSamples: .max))
    }

    private func aNote(_ clip: MusicClip) -> [MusicMIDINote] {
        if case .midi(let payload) = clip.body { return payload.notes }; return []
    }
}
