import XCTest
@testable import FloeMusicCore

@MainActor
final class MusicEditJSONCodecTests: XCTestCase {
    private func document() throws -> MusicDocument {
        let map = try MusicTempoMap(ticksPerQuarter: 960, sampleRate: 48_000, segments: [
            .init(startTick: .init(0), bpm: 100, beatsPerBar: 4, beatUnit: 4)
        ])
        let trackID = MusicTrackID(rawValue: "actual-midi-track")
        let notes = try [60, 64, 67].enumerated().map { index, pitch in
            try MusicMIDINote(id: "original-\(index)", pitch: pitch,
                startTick: .init(Int64(index) * 3_840), durationTicks: 1_920,
                velocity: 70 + index * 10, channel: 2)
        }
        let clip = try MusicClip(id: .init(rawValue: "actual-midi-clip"), name: "Original three notes",
            trackID: trackID, offset: .init(0), body: .midi(.init(durationTicks: 15_360, notes: notes,
                controllerPoints: [.init(controller: 1, tick: .init(0), value: 40),
                                   .init(controller: 64, tick: .init(0), value: 127)])))
        let bus = try MusicBus(id: .init(rawValue: "actual-bus"), name: "Return",
            strip: .init(gain: 0.8, pan: -0.1), sends: [MusicBus.masterBusID])
        let track = try MusicTrack(id: trackID, name: "Original keys", kind: .midi, clips: [clip],
            strip: .init(gain: 1.25, pan: -0.25, muted: false, soloed: true,
                         recordArmed: true, inputMonitoring: true),
            instrument: .init(pluginID: "host-owned-synth", presetIndex: 2,
                              parameters: ["release": 0.5], stateBlob: Data([0, 255, 3])),
            effects: [.init(pluginID: "host-owned-eq", parameters: ["high": 0.2])],
            outputBusID: bus.id, sends: [.init(busID: MusicBus.masterBusID, gain: 0.3)])
        let other = try MusicTrack(id: .init(rawValue: "other-audio-track"), name: "Other source",
            kind: .audio, strip: .init(gain: 0.7, pan: 0.4, muted: true))
        let lane = try MusicAutomationLane(id: "existing-automation", ownerID: trackID.rawValue,
            target: .trackGain, points: [.init(sample: .init(0), value: 0.9)])
        return try MusicDocument(name: "User's existing project", revision: 11, tempoMap: map,
            tracks: [track, other], buses: [bus],
            masterStrip: .init(gain: 0.5, pan: 0.2, muted: true), automationLanes: [lane])
    }

    private var finalChord: String {
        """
        [{"id":"new-c","pitch":60,"startTick":46080,"durationTicks":1920,"velocity":96},
         {"id":"new-e","pitch":64,"startTick":46080,"durationTicks":1920,"velocity":96},
         {"id":"new-g","pitch":67,"startTick":46080,"durationTicks":1920,"velocity":96}]
        """
    }

    private func appendJSON() -> String {
        """
        [{"op":"midi.clip.update","clipID":"actual-midi-clip","durationTicks":48000,
          "notesMode":"append","notes":\(finalChord)}]
        """
    }

    private func payload(_ clip: MusicClip) throws -> MusicMIDIClipPayload {
        guard case .midi(let value) = clip.body else { throw MusicError.invalidMIDI(reason: "MIDI expected") }
        return value
    }

    private func apply(_ operations: [MusicEditOp], to document: MusicDocument) throws -> MusicDocument {
        var draft = document
        for operation in operations { try draft.apply(operation) }
        try draft.validate()
        return draft
    }

    @discardableResult
    private func error(_ json: String, document: MusicDocument, code: String, path: String,
                       file: StaticString = #filePath, line: UInt = #line) throws -> MusicEditJSONError {
        var received: MusicEditJSONError?
        XCTAssertThrowsError(try MusicEditJSONCodec.decode(json, document: document), file: file, line: line) {
            received = $0 as? MusicEditJSONError
            XCTAssertNotNil(received, "Typed JSON diagnostic expected", file: file, line: line)
        }
        let value = try XCTUnwrap(received, file: file, line: line)
        XCTAssertEqual(value.code, code, file: file, line: line)
        XCTAssertEqual(value.path, path, file: file, line: line)
        XCTAssertFalse(value.expected.isEmpty, file: file, line: line)
        XCTAssertFalse(value.recovery.isEmpty, file: file, line: line)
        return value
    }

    private func assertMixUnchanged(_ before: MusicDocument, _ after: MusicDocument,
                                    file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(after.masterStrip, before.masterStrip, file: file, line: line)
        XCTAssertTrue(after.masterStrip.muted, file: file, line: line)
        XCTAssertEqual(after.buses, before.buses, file: file, line: line)
        XCTAssertEqual(after.assets, before.assets, file: file, line: line)
        XCTAssertEqual(after.automationLanes, before.automationLanes, file: file, line: line)
        XCTAssertEqual(after.tempoMap, before.tempoMap, file: file, line: line)
        XCTAssertEqual(after.name, before.name, file: file, line: line)
        XCTAssertEqual(after.tracks[1], before.tracks[1], file: file, line: line)
        var a = before.tracks[0], b = after.tracks[0]
        a.clips = []; b.clips = []
        XCTAssertEqual(a, b, file: file, line: line)
    }

    func testPlainAppendThirtySecondsPreservesThreeNotesMixAndRevisionOnSaveReopen() async throws {
        let original = try document()
        let repository = InMemoryMusicRepository()
        let store = try await MusicProjectStore(document: original, repository: repository)
        let operations = try MusicEditJSONCodec.decode(appendJSON(), document: original)
        let saved = try await store.commit(.init(baseRevision: 11, author: "studio.edit", ops: operations),
            as: await store.beginSession(ownerToken: "studio.edit"))
        XCTAssertEqual(saved.revision, 12)
        XCTAssertEqual(saved.tracks.count, 2)
        XCTAssertEqual(saved.tracks[0].clips.count, 1)
        let clip = saved.tracks[0].clips[0], midi = try payload(clip)
        XCTAssertEqual(clip.id, original.tracks[0].clips[0].id)
        XCTAssertEqual(midi.durationTicks, 48_000)
        XCTAssertEqual(Array(midi.notes.prefix(3)), try payload(original.tracks[0].clips[0]).notes)
        XCTAssertEqual(midi.notes.count, 6)
        XCTAssertEqual(midi.notes.suffix(3).map { $0.startTick.value }, [46_080, 46_080, 46_080])
        XCTAssertEqual(midi.notes.suffix(3).map { $0.startTick.value + $0.durationTicks }, [48_000, 48_000, 48_000])
        XCTAssertEqual(midi.controllerPoints, try payload(original.tracks[0].clips[0]).controllerPoints)
        XCTAssertEqual(try clip.endSample(tempoMap: saved.tempoMap).value, 1_440_000)
        assertMixUnchanged(original, saved)
        let reopened = try await MusicProjectStore.open(projectID: original.id, repository: repository)
        let loaded = try await reopened.currentSnapshot()
        XCTAssertEqual(loaded, saved)
        let undone = try await store.undo(await store.beginSession(ownerToken: "studio.edit"))
        XCTAssertEqual(undone.revision, 13)
        XCTAssertEqual(undone.tracks, original.tracks)
        assertMixUnchanged(original, undone)
    }

    func testPlainInsertAddsThirtySecondClipWithoutReplacingOriginalOrSelectingAnotherTrack() async throws {
        let original = try document(), repository = InMemoryMusicRepository()
        let store = try await MusicProjectStore(document: original, repository: repository)
        let json = """
        [{"op":"midi.clip.insert","trackID":"actual-midi-track","name":"30-second phrase",
          "durationTicks":48000,"offsetSamples":0,"notes":\(finalChord)}]
        """
        let operations = try MusicEditJSONCodec.decode(json, document: original)
        let saved = try await store.commit(.init(baseRevision: 11, ops: operations),
            as: await store.beginSession(ownerToken: "studio.edit"))
        XCTAssertEqual(saved.tracks[0].clips.count, 2)
        XCTAssertEqual(saved.tracks[0].clips[0], original.tracks[0].clips[0])
        let inserted = saved.tracks[0].clips[1]
        XCTAssertNotEqual(inserted.id, original.tracks[0].clips[0].id)
        XCTAssertEqual(inserted.trackID, original.tracks[0].id)
        XCTAssertEqual(inserted.offset.value, 0)
        XCTAssertEqual(try payload(inserted).durationTicks, 48_000)
        XCTAssertEqual(try inserted.endSample(tempoMap: saved.tempoMap).value, 1_440_000)
        assertMixUnchanged(original, saved)
        let loaded = try await repository.load(projectID: original.id)
        XCTAssertEqual(loaded, saved)
    }

    func testExplicitReplacementCanClearNotesAndNameOnlyKeepsOtherFields() throws {
        let original = try document()
        let renamed = try apply(MusicEditJSONCodec.decode(
            #"[{"op":"midi.clip.update","clipID":"actual-midi-clip","name":"Renamed"}]"#,
            document: original), to: original)
        XCTAssertEqual(renamed.tracks[0].clips[0].name, "Renamed")
        XCTAssertEqual(try payload(renamed.tracks[0].clips[0]), try payload(original.tracks[0].clips[0]))
        let cleared = try apply(MusicEditJSONCodec.decode(
            #"[{"op":"midi.clip.update","clipID":"actual-midi-clip","durationTicks":1,"notesMode":"replace","notes":[]}]"#,
            document: original), to: original)
        XCTAssertTrue(try payload(cleared.tracks[0].clips[0]).notes.isEmpty)
        XCTAssertEqual(try payload(cleared.tracks[0].clips[0]).controllerPoints,
                       try payload(original.tracks[0].clips[0]).controllerPoints)
        assertMixUnchanged(original, cleared)
    }

    func testNativeJSONEncoderUpdateAndInsertRemainCompatibleWithSaveReopen() async throws {
        let original = try document(), repository = InMemoryMusicRepository()
        let store = try await MusicProjectStore(document: original, repository: repository)
        var updated = original.tracks[0].clips[0], midi = try payload(original.tracks[0].clips[0])
        midi.durationTicks = 48_000
        midi.notes.append(try .init(id: "native-chord", pitch: 60, startTick: .init(46_080), durationTicks: 1_920, velocity: 96))
        updated.body = .midi(midi)
        let inserted = try MusicClip(name: "Native insert", trackID: updated.trackID,
            offset: .init(0), body: .midi(midi))
        let expected: [MusicEditOp] = [.updateClip(updated), .insertClip(inserted)]
        let json = String(decoding: try JSONEncoder().encode(expected), as: UTF8.self)
        let decoded = try MusicEditJSONCodec.decode(json, document: original)
        XCTAssertEqual(decoded, expected)
        let saved = try await store.commit(.init(baseRevision: 11, ops: decoded),
            as: await store.beginSession(ownerToken: "native-compatible"))
        XCTAssertEqual(saved.tracks[0].clips, [updated, inserted])
        assertMixUnchanged(original, saved)
        let reopened = try await MusicProjectStore.open(projectID: original.id, repository: repository)
        let loaded = try await reopened.currentSnapshot()
        XCTAssertEqual(loaded, saved)
    }

    func testNativeTrackPluginDataOptionalValuesAndOtherOperationsRemainCompatible() throws {
        let original = try document()
        let plugin = try MusicPluginState(pluginID: "another-plugin", enabled: false, presetIndex: 8,
            parameters: ["dynamic-name": 0.25], stateBlob: Data([0, 255, 3]))
        let expected: [MusicEditOp] = [
            .setName("Compatible native operations"),
            .setInstrument(original.tracks[0].id, plugin),
            .setInstrument(original.tracks[0].id, nil),
            .insertTrack(try .init(name: "Native track", kind: .midi, instrument: plugin)),
            .setTempo(atTick: .init(960), bpm: 101.5, beatsPerBar: 4, beatUnit: 4)
        ]
        let json = String(decoding: try JSONEncoder().encode(expected), as: UTF8.self)
        XCTAssertEqual(try MusicEditJSONCodec.decode(json, document: original), expected)
    }

    func testMissingPlainFieldsAndNotesModeHaveExactPaths() throws {
        let original = try document()
        try error(#"[{"op":"midi.clip.update","clipID":"actual-midi-clip","notes":[]}]"#,
                  document: original, code: "missing_field", path: "operations[0].notesMode")
        try error(#"[{"op":"midi.clip.update","clipID":"actual-midi-clip","notesMode":"append","notes":[{"pitch":60,"startTick":0,"velocity":96}]}]"#,
                  document: original, code: "missing_field", path: "operations[0].notes[0].durationTicks")
        try error(#"[{"op":"midi.clip.insert","trackID":"actual-midi-track","durationTicks":48000,"notes":[]}]"#,
                  document: original, code: "missing_field", path: "operations[0].name")
    }

    private func nativeNoteJSON(pitch: String, duration: String = "\"durationTicks\":1920,") -> String {
        """
        [{"updateClip":{"_0":{"id":{"rawValue":"actual-midi-clip"},"trackID":{"rawValue":"actual-midi-track"},
          "offset":{"value":0},"body":{"kind":"midi","midi":{"durationTicks":48000,"notes":[
          {"id":"native-note","pitch":\(pitch),"startTick":{"value":46080},\(duration)"velocity":96}]}}}}}]
        """
    }

    func testNativeDecodingErrorsKeepCodingPathsAndPerformNoWrites() async throws {
        let original = try document(), repository = MusicJSONRecordingRepository()
        let store = try await MusicProjectStore(document: original, repository: repository)
        try error(#"[{"updateClip":{"clip":{}}}]"#, document: original,
                  code: "missing_field", path: "operations[0].updateClip._0")
        try error(nativeNoteJSON(pitch: "60", duration: ""), document: original,
                  code: "missing_field", path: "operations[0].updateClip._0.body.midi.notes[0].durationTicks")
        try error(nativeNoteJSON(pitch: "\"60\""), document: original,
                  code: "type_mismatch", path: "operations[0].updateClip._0.body.midi.notes[0].pitch")
        try error(nativeNoteJSON(pitch: "null"), document: original,
                  code: "type_mismatch", path: "operations[0].updateClip._0.body.midi.notes[0].pitch")
        try error(nativeNoteJSON(pitch: "128"), document: original,
                  code: "invalid_value", path: "operations[0].updateClip._0.body.midi.notes[0].pitch")
        let count = await repository.saveCount
        XCTAssertEqual(count, 1)
        let snapshot = try await store.currentSnapshot()
        XCTAssertEqual(snapshot, original)
        let saved = try await repository.load(projectID: original.id)
        XCTAssertEqual(saved, original)
    }

    func testNoteBoundsDuplicateIDsAndShrinkingPastRetainedNotesAreRejected() throws {
        let original = try document()
        for length in ["0", "9223372036854775807"] {
            try error(#"[{"op":"midi.clip.update","clipID":"actual-midi-clip","notesMode":"append","notes":[{"pitch":60,"startTick":46080,"durationTicks":\#(length),"velocity":96}]}]"#,
                      document: original, code: "invalid_value", path: "operations[0].notes[0].durationTicks")
        }
        try error(#"[{"op":"midi.clip.update","clipID":"actual-midi-clip","notesMode":"append","notes":[{"id":"original-0","pitch":60,"startTick":0,"durationTicks":1,"velocity":96}]}]"#,
                  document: original, code: "duplicate_id", path: "operations[0].notes[0].id")
        try error(#"[{"op":"midi.clip.update","clipID":"actual-midi-clip","durationTicks":1000}]"#,
                  document: original, code: "invalid_value", path: "operations[0].durationTicks")
        try error(#"[{"op":"midi.clip.insert","trackID":"actual-midi-track","name":"Duplicate","durationTicks":100,"notes":[{"id":"same","pitch":60,"startTick":0,"durationTicks":1,"velocity":96},{"id":"same","pitch":64,"startTick":0,"durationTicks":1,"velocity":96}]}]"#,
                  document: original, code: "duplicate_id", path: "operations[0].notes[1].id")
    }

    func testUnknownFieldsIDsOperationsAndMixedFormatsNeverSelectFallbackObjects() throws {
        let original = try document()
        try error(#"[{"op":"midi.clip.update","clipID":"missing","name":"Oops"}]"#,
                  document: original, code: "unknown_id", path: "operations[0].clipID")
        try error(#"[{"op":"midi.clip.insert","trackID":"missing","name":"Oops","durationTicks":100,"notes":[]}]"#,
                  document: original, code: "unknown_id", path: "operations[0].trackID")
        try error(#"[{"op":"midi.clip.update","clipID":"actual-midi-clip","name":"Oops","masterStrip":{"muted":false}}]"#,
                  document: original, code: "unknown_field", path: "operations[0].masterStrip")
        try error(#"[{"op":"midi.clip.insert","trackID":"actual-midi-track","clipID":"actual-midi-clip","name":"Oops","durationTicks":100,"notes":[]}]"#,
                  document: original, code: "unknown_field", path: "operations[0].clipID")
        try error(#"[{"op":"midi.clip.unknown","clipID":"actual-midi-clip"}]"#,
                  document: original, code: "unknown_operation", path: "operations[0].op")
        try error(#"[{"op":"midi.clip.update","clipID":"actual-midi-clip","name":"Okay"},{"setName":{"_0":"Native"}}]"#,
                  document: original, code: "mixed_formats", path: "operations")
    }

    func testIntegerTokensJSONSyntaxAndResourceBudgetsAreStrict() throws {
        let original = try document()
        for token in ["1.5", "1.0", "1e2", "\"100\"", "true", "9223372036854775808"] {
            try error(#"[{"op":"midi.clip.update","clipID":"actual-midi-clip","durationTicks":\#(token)}]"#,
                      document: original, code: "type_mismatch", path: "operations[0].durationTicks")
        }
        try error(#"[{"op":"midi.clip.update","clipID":"actual-midi-clip","durationTicks":NaN}]"#,
                  document: original, code: "invalid_json", path: "operations[0].durationTicks")
        try error(#"[{"op":"midi.clip.update","clipID":"actual-midi-clip","name":"one","name":"two"}]"#,
                  document: original, code: "duplicate_field", path: "operations[0].name")
        try error("[]", document: original, code: "empty_batch", path: "operations")
        try error("{}", document: original, code: "type_mismatch", path: "operations")
        try error(String(repeating: " ", count: MusicEditJSONCodec.maxJSONBytes + 1), document: original,
                  code: "budget_exceeded", path: "operations")
        let command = #"{"op":"midi.clip.update","clipID":"actual-midi-clip","name":"Update"}"#
        try error("[" + Array(repeating: command, count: 129).joined(separator: ",") + "]",
                  document: original, code: "budget_exceeded", path: "operations")
        let note = #"{"pitch":60,"startTick":0,"durationTicks":1,"velocity":96}"#
        let tooMany = Array(repeating: note, count: MusicEditJSONCodec.maxNotesPerBatch + 1).joined(separator: ",")
        try error(#"[{"op":"midi.clip.update","clipID":"actual-midi-clip","notesMode":"replace","notes":[\#(tooMany)]}]"#,
                  document: original, code: "budget_exceeded", path: "operations[0].notes")
    }

    func testNativeUnknownFieldsExactIntegerTokensAndDuplicateNoteIDsAreRejected() throws {
        let original = try document()
        let json = nativeNoteJSON(pitch: "60")
        let extra = json.replacingOccurrences(of: "\"offset\":{\"value\":0}", with: "\"offset\":{\"value\":0},\"muted\":false")
        try error(extra, document: original, code: "unknown_field", path: "operations[0].updateClip._0.muted")
        let decimal = json.replacingOccurrences(of: "\"durationTicks\":48000", with: "\"durationTicks\":48000.0")
        try error(decimal, document: original, code: "type_mismatch", path: "operations[0].updateClip._0.body.midi.durationTicks")
        var clip = original.tracks[0].clips[0], midi = try payload(original.tracks[0].clips[0])
        midi.notes.append(midi.notes[0]); clip.body = .midi(midi)
        let duplicate = String(decoding: try JSONEncoder().encode([MusicEditOp.updateClip(clip)]), as: UTF8.self)
        try error(duplicate, document: original, code: "duplicate_id", path: "operations[0].updateClip._0.body.midi.notes[3].id")
    }

    func testPatternCommandsComposeOnSameDraftAndCommitOnce() async throws {
        var original = try document(), midi = try payload(document().tracks[0].clips[0])
        midi.notes[0].startTick = .init(137)
        original.tracks[0].clips[0].body = .midi(midi)
        let repository = InMemoryMusicRepository()
        let store = try await MusicProjectStore(document: original, repository: repository)
        let json = """
        [{"op":"midi.clip.quantize","clipID":"actual-midi-clip","gridTicks":240,"strength":0.5,"quantizeEnds":false},
         {"op":"midi.clip.transpose","clipID":"actual-midi-clip","semitones":7},
         {"op":"midi.clip.velocity","clipID":"actual-midi-clip","delta":-10},
         {"op":"midi.template.insert","trackID":"actual-midi-track","template":"arpeggio","atTick":48000,"bars":1,"name":"Added pattern"}]
        """
        let operations = try MusicEditJSONCodec.decode(json, document: original)
        XCTAssertEqual(operations.count, 4)
        let saved = try await store.commit(.init(baseRevision: 11, ops: operations),
            as: await store.beginSession(ownerToken: "pattern-json"))
        XCTAssertEqual(saved.revision, 12)
        let note = try payload(saved.tracks[0].clips[0]).notes[0]
        XCTAssertEqual(note.id, "original-0")
        XCTAssertEqual(note.startTick.value, 189)
        XCTAssertEqual(note.pitch, 67)
        XCTAssertEqual(note.velocity, 60)
        XCTAssertEqual(saved.tracks[0].clips[1].name, "Added pattern")
        XCTAssertEqual(try payload(saved.tracks[0].clips[1]).notes.count, 8)
        assertMixUnchanged(original, saved)
        let reloaded = try await repository.load(projectID: original.id)
        XCTAssertEqual(reloaded, saved)
    }

    func testPatternFieldsRangesAndNoOpBehaviorAreExplicit() throws {
        let original = try document()
        let noOp = """
        [{"op":"midi.clip.quantize","clipID":"actual-midi-clip","gridTicks":240,"strength":0},
         {"op":"midi.clip.transpose","clipID":"actual-midi-clip","semitones":0},
         {"op":"midi.clip.velocity","clipID":"actual-midi-clip","delta":0}]
        """
        XCTAssertTrue(try MusicEditJSONCodec.decode(noOp, document: original).isEmpty)
        try error(#"[{"op":"midi.clip.quantize","clipID":"actual-midi-clip","gridTicks":0}]"#,
                  document: original, code: "invalid_value", path: "operations[0].gridTicks")
        try error(#"[{"op":"midi.clip.quantize","clipID":"actual-midi-clip","gridTicks":240,"strength":2}]"#,
                  document: original, code: "invalid_value", path: "operations[0].strength")
        try error(#"[{"op":"midi.clip.quantize","clipID":"actual-midi-clip","gridTicks":240,"quantizeEnds":"false"}]"#,
                  document: original, code: "type_mismatch", path: "operations[0].quantizeEnds")
        try error(#"[{"op":"midi.clip.transpose","clipID":"actual-midi-clip","semitones":127}]"#,
                  document: original, code: "invalid_value", path: "operations[0].semitones")
        let clamped = try apply(MusicEditJSONCodec.decode(#"[{"op":"midi.clip.transpose","clipID":"actual-midi-clip","semitones":9223372036854775807,"outOfRange":"clamp"}]"#,
            document: original), to: original)
        XCTAssertEqual(try payload(clamped.tracks[0].clips[0]).notes.map(\.pitch), [127, 127, 127])
        let quieter = try apply(MusicEditJSONCodec.decode(#"[{"op":"midi.clip.velocity","clipID":"actual-midi-clip","delta":-9223372036854775808}]"#,
            document: original), to: original)
        XCTAssertEqual(try payload(quieter.tracks[0].clips[0]).notes.map(\.velocity), [1, 1, 1])
        try error(#"[{"op":"midi.template.insert","trackID":"actual-midi-track","template":"unknown","atTick":0}]"#,
                  document: original, code: "invalid_value", path: "operations[0].template")
        try error(#"[{"op":"midi.template.insert","trackID":"actual-midi-track","template":"arpeggio","atTick":0,"bars":65}]"#,
                  document: original, code: "invalid_value", path: "operations[0].bars")
    }

    func testEveryPlainTemplateAddsNativeNotesAndPreservesInstrument() throws {
        let original = try document()
        let commands = MusicPatternTemplate.allCases.map { template in
            #"{"op":"midi.template.insert","trackID":"actual-midi-track","template":"\#(template.rawValue)","atTick":48000,"bars":1}"#
        }.joined(separator: ",")
        let applied = try apply(MusicEditJSONCodec.decode("[" + commands + "]", document: original), to: original)
        XCTAssertEqual(applied.tracks[0].clips.count, 5)
        XCTAssertEqual(applied.tracks[0].clips[0], original.tracks[0].clips[0])
        XCTAssertEqual(try applied.tracks[0].clips.dropFirst().map { try payload($0).notes.count }, [12, 3, 8, 4])
        XCTAssertEqual(Set(applied.tracks[0].clips.map(\.id)).count, 5)
        assertMixUnchanged(original, applied)
    }

    func testDiagnosticsDoNotEchoPayloadValues() throws {
        let original = try document()
        let secret = "payload-value-must-not-be-echoed"
        let diagnostic = try error(#"[{"op":"midi.clip.update","clipID":"actual-midi-clip","durationTicks":"\#(secret)"}]"#,
            document: original, code: "type_mismatch", path: "operations[0].durationTicks")
        XCTAssertFalse(diagnostic.localizedDescription.contains(secret))
    }
}

private actor MusicJSONRecordingRepository: MusicRepository {
    private let base = InMemoryMusicRepository()
    private(set) var saveCount = 0
    func stageAsset(_ payload: MusicAssetPayload) async throws { try await base.stageAsset(payload) }
    func save(document: MusicDocument, expectedRevision: Int64?, fence: MusicCommitFence?) async throws -> MusicRevisionToken {
        let token = try await base.save(document: document, expectedRevision: expectedRevision, fence: fence)
        saveCount += 1
        return token
    }
    func load(projectID: MusicProjectID) async throws -> MusicDocument { try await base.load(projectID: projectID) }
    func assetPayload(assetID: MusicAssetID) async throws -> MusicAssetPayload? { try await base.assetPayload(assetID: assetID) }
}
