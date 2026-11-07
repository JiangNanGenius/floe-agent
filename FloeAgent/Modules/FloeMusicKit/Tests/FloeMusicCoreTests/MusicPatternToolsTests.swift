import XCTest
@testable import FloeMusicCore

@MainActor
final class MusicPatternToolsTests: XCTestCase {
    private func fixture(notes: [MusicMIDINote], duration: Int64 = 4_000,
                         map: MusicTempoMap? = nil) throws -> (MusicDocument, MusicClip) {
        let map = try map ?? MusicFixtures.defaultTempoMap()
        let payload = try MusicMIDIClipPayload(durationTicks: duration, notes: notes,
            controllerPoints: [.init(controller: 64, tick: .init(0), value: 127)])
        let trackID = MusicTrackID(rawValue: "pattern-track")
        let clip = try MusicClip(id: .init(rawValue: "pattern-clip"), name: "Original take",
            trackID: trackID, offset: map.sample(atTick: .init(720)), body: .midi(payload))
        let track = try MusicTrack(id: trackID, name: "Keys", kind: .midi, clips: [clip],
            instrument: .init(pluginID: "host-owned-instrument", presetIndex: 2))
        return (try MusicDocument(name: "Pattern editing", tempoMap: map, tracks: [track]), clip)
    }

    private func updatedClip(_ ops: [MusicEditOp], file: StaticString = #filePath,
                             line: UInt = #line) throws -> MusicClip {
        XCTAssertEqual(ops.count, 1, file: file, line: line)
        guard let op = ops.first, case .updateClip(let clip) = op else {
            throw MusicError.invalidBatch(reason: "expected one clip update")
        }
        return clip
    }

    private func insertedClip(_ ops: [MusicEditOp]) throws -> MusicClip {
        XCTAssertEqual(ops.count, 1)
        guard let op = ops.first, case .insertClip(let clip) = op else {
            throw MusicError.invalidBatch(reason: "expected one new clip")
        }
        return clip
    }

    private func midi(_ clip: MusicClip) throws -> MusicMIDIClipPayload {
        guard case .midi(let payload) = clip.body else {
            throw MusicError.invalidMIDI(reason: "expected MIDI")
        }
        return payload
    }

    func testQuantizeStrengthAndCrossBarNotesPreserveSource() throws {
        let (document, clip) = try fixture(notes: [
            .init(id: "early", pitch: 60, startTick: .init(137), durationTicks: 500, velocity: 91, channel: 2),
            .init(id: "cross-bar", pitch: 67, startTick: .init(3_755), durationTicks: 200, velocity: 83)
        ])
        let updated = try updatedClip(MusicPatternTools.quantize(document: document, clipID: clip.id,
            gridTicks: 240, strength: 0.5))
        let payload = try midi(updated)
        XCTAssertEqual(payload.notes.map { $0.startTick.value }, [189, 3_798])
        XCTAssertEqual(payload.notes.map(\.durationTicks), [500, 200])
        XCTAssertEqual(payload.notes.map(\.id), ["early", "cross-bar"])
        XCTAssertEqual(payload.notes.map(\.velocity), [91, 83])
        XCTAssertEqual(payload.notes[0].channel, 2)
        XCTAssertEqual(payload.controllerPoints, try midi(clip).controllerPoints)
        XCTAssertEqual(payload.durationTicks, 4_000)
        XCTAssertEqual(updated.id, clip.id)
        XCTAssertEqual(updated.name, clip.name)
        XCTAssertEqual(updated.trackID, clip.trackID)
        XCTAssertEqual(updated.offset, clip.offset)
        XCTAssertEqual(try midi(document.tracks[0].clips[0]), try midi(clip))
    }

    func testQuantizedEndsAndClipEdgeRetainOneTickNotes() throws {
        let (document, clip) = try fixture(notes: [
            .init(id: "head", pitch: 60, startTick: .init(1), durationTicks: 1, velocity: 1),
            .init(id: "tail", pitch: 60, startTick: .init(999), durationTicks: 1, velocity: 127)
        ], duration: 1_000)
        let ends = try midi(updatedClip(MusicPatternTools.quantize(document: document,
            clipID: clip.id, gridTicks: 240, quantizeEnds: true)))
        XCTAssertEqual(ends.notes.map { $0.startTick.value }, [0, 960])
        XCTAssertEqual(ends.notes.map(\.durationTicks), [1, 1])

        let boundary = try midi(updatedClip(MusicPatternTools.quantize(document: document,
            clipID: clip.id, gridTicks: 1_024)))
        XCTAssertEqual(boundary.notes.last?.startTick.value, 999)
        XCTAssertEqual(boundary.notes.last?.durationTicks, 1)
        XCTAssertTrue(boundary.notes.allSatisfy {
            $0.startTick.value >= 0 && $0.durationTicks > 0 && $0.startTick.value + $0.durationTicks <= 1_000
        })
    }

    func testOddAndExtremeGridUseCheckedIntegerArithmetic() throws {
        let (document, clip) = try fixture(notes: [
            .init(pitch: 60, startTick: .init(2), durationTicks: 20, velocity: 90),
            .init(pitch: 64, startTick: .init(3), durationTicks: 20, velocity: 90)
        ])
        let odd = try midi(updatedClip(MusicPatternTools.quantize(document: document,
            clipID: clip.id, gridTicks: 5)))
        XCTAssertEqual(odd.notes.map { $0.startTick.value }, [0, 5])
        let extreme = try midi(updatedClip(MusicPatternTools.quantize(document: document,
            clipID: clip.id, gridTicks: Int64.max)))
        XCTAssertEqual(extreme.notes.map { $0.startTick.value }, [0, 0])
    }

    func testQuantizeRejectsInvalidConfigurationAndWrongTarget() throws {
        let (document, clip) = try fixture(notes: [MusicFixtures.midiNote()])
        for strength in [Double.nan, .infinity, -0.1, 1.01] {
            XCTAssertThrowsError(try MusicPatternTools.quantize(document: document, clipID: clip.id,
                gridTicks: 240, strength: strength))
        }
        for grid in [Int64(0), -1, .min] {
            XCTAssertThrowsError(try MusicPatternTools.quantize(document: document,
                clipID: clip.id, gridTicks: grid))
        }
        XCTAssertThrowsError(try MusicPatternTools.quantize(document: document,
            clipID: .init(rawValue: "missing"), gridTicks: 240))
        let asset = try MusicFixtures.asset(id: "a")
        let audio = try MusicFixtures.audioClip(id: "audio", trackID: "audio-track", assetID: "a")
        let audioDocument = try MusicDocument(name: "Audio", assets: [asset], tracks: [
            .init(id: audio.trackID, name: "Audio", kind: .audio, clips: [audio])
        ])
        XCTAssertThrowsError(try MusicPatternTools.quantize(document: audioDocument,
            clipID: audio.id, gridTicks: 240))
        XCTAssertThrowsError(try MusicPatternTools.transpose(document: audioDocument,
            clipID: audio.id, semitones: 1))
    }

    func testTransposeRejectsWholePlanOrExplicitlyClamps() throws {
        let notes = try [0, 60, 127].enumerated().map { index, pitch in
            try MusicMIDINote(id: "n\(index)", pitch: pitch, startTick: .init(Int64(index) * 480),
                              durationTicks: 240, velocity: 96)
        }
        let (document, clip) = try fixture(notes: notes)
        XCTAssertThrowsError(try MusicPatternTools.transpose(document: document,
            clipID: clip.id, semitones: 1))
        XCTAssertThrowsError(try MusicPatternTools.transpose(document: document,
            clipID: clip.id, semitones: -1))
        for (delta, expected) in [(Int.max, 127), (Int.min, 0)] {
            let updated = try midi(updatedClip(MusicPatternTools.transpose(document: document,
                clipID: clip.id, semitones: delta, outOfRange: .clamp)))
            XCTAssertEqual(updated.notes.map(\.pitch), [expected, expected, expected])
            XCTAssertEqual(updated.notes.map(\.id), notes.map(\.id))
            XCTAssertEqual(updated.notes.map(\.startTick), notes.map(\.startTick))
        }
        XCTAssertEqual(try midi(document.tracks[0].clips[0]).notes, notes)
        let (ordinary, ordinaryClip) = try fixture(notes: [MusicFixtures.midiNote(pitch: 60)])
        let transposed = try midi(updatedClip(MusicPatternTools.transpose(document: ordinary,
            clipID: ordinaryClip.id, semitones: -12)))
        XCTAssertEqual(transposed.notes[0].pitch, 48)
    }

    func testVelocityDeltasSaturateWithoutCreatingNoteOff() throws {
        let notes = try [1, 64, 127].enumerated().map { index, velocity in
            try MusicMIDINote(id: "v\(index)", pitch: 60, startTick: .init(Int64(index) * 480),
                              durationTicks: 240, velocity: velocity)
        }
        let (document, clip) = try fixture(notes: notes)
        let ordinary = try midi(updatedClip(MusicPatternTools.adjustVelocity(document: document,
            clipID: clip.id, delta: 10)))
        XCTAssertEqual(ordinary.notes.map(\.velocity), [11, 74, 127])
        for (delta, expected) in [(Int.max, 127), (Int.min, 1)] {
            let updated = try midi(updatedClip(MusicPatternTools.adjustVelocity(document: document,
                clipID: clip.id, delta: delta)))
            XCTAssertEqual(updated.notes.map(\.velocity), [expected, expected, expected])
            XCTAssertEqual(updated.notes.map(\.id), notes.map(\.id))
            XCTAssertEqual(updated.notes.map(\.pitch), notes.map(\.pitch))
        }
    }

    func testNoChangeReturnsNoOperationsAndMutatedModelsAreRejected() throws {
        let (document, clip) = try fixture(notes: [MusicFixtures.midiNote(start: 137)])
        XCTAssertTrue(try MusicPatternTools.quantize(document: document,
            clipID: clip.id, gridTicks: 240, strength: 0).isEmpty)
        XCTAssertTrue(try MusicPatternTools.transpose(document: document,
            clipID: clip.id, semitones: 0).isEmpty)
        XCTAssertTrue(try MusicPatternTools.adjustVelocity(document: document,
            clipID: clip.id, delta: 0).isEmpty)
        var invalid = document
        var payload = try midi(clip)
        payload.notes[0].pitch = 200
        invalid.tracks[0].clips[0].body = .midi(payload)
        XCTAssertThrowsError(try MusicPatternTools.transpose(document: invalid,
            clipID: clip.id, semitones: -100))
        XCTAssertThrowsError(try MusicPatternTools.adjustVelocity(document: invalid,
            clipID: clip.id, delta: 1))
    }

    func testTemplatesFollowThreeFourAndFourFourWithoutReplacingContent() throws {
        for beats in [3, 4] {
            let map = try MusicTempoMap(segments: [
                .init(startTick: .init(0), bpm: 97.5, beatsPerBar: beats, beatUnit: 4)
            ])
            let (document, original) = try fixture(notes: [MusicFixtures.midiNote()], map: map)
            let insertion = MusicTick(Int64(beats * 960 * 2))
            for template in MusicPatternTemplate.allCases {
                let ops = try MusicPatternTools.insertTemplate(template, document: document,
                    trackID: original.trackID, atTick: insertion)
                let clip = try insertedClip(ops), payload = try midi(clip)
                XCTAssertEqual(payload.durationTicks, Int64(beats * 960 * 4))
                XCTAssertEqual(clip.trackID, original.trackID)
                XCTAssertEqual(clip.offset, try map.sample(atTick: insertion))
                XCTAssertNotEqual(clip.id, original.id)
                XCTAssertEqual(Set(payload.notes.map(\.id)).count, payload.notes.count)
                XCTAssertTrue(payload.notes.allSatisfy {
                    $0.durationTicks > 0 && $0.startTick.value >= 0
                        && $0.startTick.value + $0.durationTicks <= payload.durationTicks
                })
                switch template {
                case .drumGroove:
                    XCTAssertEqual(payload.notes.count, beats == 3 ? 36 : 48)
                    XCTAssertEqual(Set(payload.notes.map(\.pitch)), [36, 38, 42])
                    XCTAssertEqual(Set(payload.notes.map(\.channel)), [9])
                case .chordProgression:
                    XCTAssertEqual(payload.notes.map(\.pitch), [60, 64, 67, 67, 71, 74, 69, 72, 76, 65, 69, 72])
                    XCTAssertEqual(payload.notes.map { $0.startTick.value },
                        [0, 0, 0, 1, 1, 1, 2, 2, 2, 3, 3, 3].map { Int64($0 * beats * 960) })
                case .arpeggio:
                    XCTAssertEqual(payload.notes.count, beats * 2 * 4)
                    XCTAssertEqual(Array(payload.notes.prefix(4)).map(\.pitch), [60, 64, 67, 64])
                case .bassLine:
                    XCTAssertEqual(payload.notes.count, beats * 4)
                    XCTAssertEqual(payload.notes[0].pitch, 36)
                    XCTAssertEqual(payload.notes[1].pitch, 43)
                }
                var applied = document
                for op in ops { try applied.apply(op) }
                try applied.validate()
                XCTAssertEqual(applied.tracks[0].clips[0], original)
                XCTAssertEqual(applied.tracks[0].instrument, document.tracks[0].instrument)
                XCTAssertEqual(applied.tempoMap, map)
            }
        }
    }

    func testOddPPQNAndEighthNoteMeterRoundAbsolutePositions() throws {
        let map = try MusicTempoMap(ticksPerQuarter: 25, segments: [
            .init(startTick: .init(0), bpm: 120, beatsPerBar: 3, beatUnit: 8)
        ])
        let (document, original) = try fixture(notes: [], map: map)
        let payload = try midi(insertedClip(MusicPatternTools.insertTemplate(.arpeggio,
            document: document, trackID: original.trackID, atTick: .init(0), bars: 4)))
        XCTAssertEqual(payload.durationTicks, 150)
        XCTAssertEqual(Array(payload.notes.prefix(6)).map { $0.startTick.value }, [0, 6, 13, 19, 25, 31])
        XCTAssertEqual([0, 6, 12, 18].map { payload.notes[$0].startTick.value }, [0, 38, 75, 113])
        XCTAssertTrue(payload.notes.allSatisfy { $0.startTick.value + $0.durationTicks <= 150 })
    }

    func testTemplateFollowsTempoChangesWithoutChangingProjectTempo() throws {
        let map = try MusicTempoMap(segments: [
            .init(startTick: .init(0), bpm: 120, beatsPerBar: 4, beatUnit: 4),
            .init(startTick: .init(1_920), bpm: 90, beatsPerBar: 4, beatUnit: 4)
        ])
        let (document, original) = try fixture(notes: [], map: map)
        let clip = try insertedClip(MusicPatternTools.insertTemplate(.chordProgression,
            document: document, trackID: original.trackID, atTick: .init(960), bars: 2))
        XCTAssertEqual(try clip.endSample(tempoMap: map), try map.sample(atTick: .init(8_640)))
        XCTAssertEqual(document.tempoMap, map)
    }

    func testTemplateRejectsInteriorMeterChangeAndAllowsEndpointChange() throws {
        for boundary in [Int64(1_920), 3_840] {
            let map = try MusicTempoMap(segments: [
                .init(startTick: .init(0), bpm: 120, beatsPerBar: 4, beatUnit: 4),
                .init(startTick: .init(boundary), bpm: 120, beatsPerBar: 3, beatUnit: 4)
            ])
            let (document, clip) = try fixture(notes: [], map: map)
            if boundary == 1_920 {
                XCTAssertThrowsError(try MusicPatternTools.insertTemplate(.drumGroove,
                    document: document, trackID: clip.trackID, atTick: .init(0), bars: 1))
            } else {
                let result = try insertedClip(MusicPatternTools.insertTemplate(.drumGroove,
                    document: document, trackID: clip.trackID, atTick: .init(0), bars: 1))
                XCTAssertEqual(try midi(result).durationTicks, 3_840)
            }
        }
    }

    func testTemplateRejectsInvalidRangeAndUnknownTrack() throws {
        let (document, clip) = try fixture(notes: [])
        for bars in [0, 65, Int.max] {
            XCTAssertThrowsError(try MusicPatternTools.insertTemplate(.drumGroove, document: document,
                trackID: clip.trackID, atTick: .init(0), bars: bars))
        }
        for tick in [Int64(-1), Int64.max] {
            XCTAssertThrowsError(try MusicPatternTools.insertTemplate(.drumGroove, document: document,
                trackID: clip.trackID, atTick: .init(tick)))
        }
        XCTAssertThrowsError(try MusicPatternTools.insertTemplate(.chordProgression,
            document: document, trackID: clip.trackID, atTick: .init(0), rootPitch: 127))
        XCTAssertThrowsError(try MusicPatternTools.insertTemplate(.bassLine,
            document: document, trackID: clip.trackID, atTick: .init(0), rootPitch: 0))
        XCTAssertThrowsError(try MusicPatternTools.insertTemplate(.arpeggio,
            document: document, trackID: clip.trackID, atTick: .init(0), velocity: 0))
        XCTAssertThrowsError(try MusicPatternTools.insertTemplate(.arpeggio,
            document: document, trackID: .init(rawValue: "missing"), atTick: .init(0)))
    }

    func testOrdinaryOperationsShareAtomicSaveUndoAndReopen() async throws {
        let (original, clip) = try fixture(notes: [
            .init(id: "retained-note", pitch: 60, startTick: .init(137), durationTicks: 400, velocity: 80)
        ])
        let repository = InMemoryMusicRepository()
        let store = try await MusicProjectStore(document: original, repository: repository)
        var draft = original, allOps: [MusicEditOp] = []
        let quantize = try MusicPatternTools.quantize(document: draft, clipID: clip.id, gridTicks: 240)
        for op in quantize { try draft.apply(op) }
        allOps += quantize
        let transpose = try MusicPatternTools.transpose(document: draft, clipID: clip.id, semitones: 7)
        for op in transpose { try draft.apply(op) }
        allOps += transpose
        let velocity = try MusicPatternTools.adjustVelocity(document: draft, clipID: clip.id, delta: -10)
        for op in velocity { try draft.apply(op) }
        allOps += velocity
        allOps += try MusicPatternTools.insertTemplate(.arpeggio, document: draft,
            trackID: clip.trackID, atTick: .init(7_680), bars: 1, name: "Added arpeggio")
        // Persistence uses the existing operation schema, without a new special op.
        let ops = try JSONDecoder().decode([MusicEditOp].self, from: JSONEncoder().encode(allOps))
        let committed = try await store.commit(.init(baseRevision: original.revision, ops: ops),
            as: await store.beginSession(ownerToken: "music-pattern-test"))
        XCTAssertEqual(committed.revision, 1)
        XCTAssertEqual(committed.tracks[0].clips.count, 2)
        let note = try midi(committed.tracks[0].clips[0]).notes[0]
        XCTAssertEqual(note.id, "retained-note")
        XCTAssertEqual(note.startTick.value, 240)
        XCTAssertEqual(note.pitch, 67)
        XCTAssertEqual(note.velocity, 70)
        let reopened = try await MusicProjectStore.open(projectID: original.id, repository: repository)
        let loaded = try await reopened.currentSnapshot()
        XCTAssertEqual(loaded, committed)
        let undone = try await store.undo(await store.beginSession(ownerToken: "music-pattern-test"))
        XCTAssertEqual(undone.revision, 2)
        XCTAssertEqual(undone.tracks, original.tracks)
        let reloadedUndo = try await repository.load(projectID: original.id)
        XCTAssertEqual(reloadedUndo.tracks, original.tracks)
        let redone = try await store.redo(await store.beginSession(ownerToken: "music-pattern-test"))
        XCTAssertEqual(redone.revision, 3)
        XCTAssertEqual(redone.tracks, committed.tracks)
        let savedRedo = try await repository.load(projectID: original.id)
        XCTAssertEqual(savedRedo, redone)
    }
}
