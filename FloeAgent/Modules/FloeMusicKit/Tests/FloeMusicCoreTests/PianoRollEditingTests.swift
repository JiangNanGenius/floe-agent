import XCTest
@testable import FloeMusicCore

final class PianoRollEditingTests: XCTestCase {
    private func payload() throws -> MusicMIDIClipPayload {
        try .init(durationTicks: 1920, notes: [
            .init(id: "a", pitch: 60, startTick: .init(120), durationTicks: 480, velocity: 80, channel: 2),
            .init(id: "b", pitch: 67, startTick: .init(360), durationTicks: 240, velocity: 100, channel: 2),
            .init(id: "c", pitch: 72, startTick: .init(960), durationTicks: 480, velocity: 70)
        ], controllerPoints: [.init(controller: 64, tick: .init(0), value: 127)])
    }
    func testGroupMovePreservesIntervalsAndStopsAtBoundaries() throws {
        let source = try payload()
        let moved = try MusicPianoRollEditing.move(source, selection: ["a", "b"], ticks: -999, semitones: 999)
        XCTAssertEqual(moved.notes[0].startTick.value, 0)
        XCTAssertEqual(moved.notes[1].startTick.value, 240)
        XCTAssertEqual(moved.notes[1].pitch, 127)
        XCTAssertEqual(moved.notes[1].pitch - moved.notes[0].pitch, 7)
        XCTAssertEqual(moved.notes[2], source.notes[2])
        XCTAssertEqual(moved.controllerPoints, source.controllerPoints)
    }
    func testResizeBothEdgesPreservesValidGroupAndEndPoints() throws {
        let source = try payload()
        let shortened = try MusicPianoRollEditing.resize(source, selection: ["a", "b"], edge: .end, ticks: -1000)
        XCTAssertEqual(shortened.notes[1].durationTicks, 1)
        XCTAssertEqual(shortened.notes[0].durationTicks, 241)
        let left = try MusicPianoRollEditing.resize(source, selection: ["a", "b"], edge: .start, ticks: -500)
        XCTAssertEqual(left.notes[0].startTick.value, 0)
        XCTAssertEqual(left.notes[0].startTick.value + left.notes[0].durationTicks, 600)
        XCTAssertEqual(left.notes[1].startTick.value + left.notes[1].durationTicks, 600)
    }
    func testClipboardCopiesEventsWithNewIdentityAndExtendsClip() throws {
        let source = try payload()
        let clipboard = try MusicMIDINoteClipboard(notes: Array(source.notes.prefix(2)))
        let decoded = try JSONDecoder().decode(MusicMIDINoteClipboard.self, from: JSONEncoder().encode(clipboard))
        let (pasted, ids) = try MusicPianoRollEditing.paste(decoded, into: source, at: 2400)
        XCTAssertEqual(pasted.notes.count, 5)
        XCTAssertEqual(pasted.durationTicks, 2880)
        XCTAssertEqual(ids.count, 2)
        XCTAssertTrue(ids.isDisjoint(with: Set(source.notes.map(\.id))))
        XCTAssertEqual(pasted.notes.last?.channel, 2)
        XCTAssertEqual(pasted.notes.last?.velocity, 100)
        XCTAssertEqual(pasted.controllerPoints, source.controllerPoints)
        XCTAssertThrowsError(try MusicPianoRollEditing.paste(clipboard, into: source, at: Int64.max))
    }
    func testSelectedVelocityAndMusicalGridDoNotAffectOtherNotes() throws {
        let source = try payload()
        let adjusted = try MusicPianoRollEditing.setVelocity(source, selection: ["a", "b"], value: 110)
        XCTAssertEqual(adjusted.notes.map(\.velocity), [110, 110, 70])
        XCTAssertEqual(MusicPianoRollGrid.eighthTriplet.ticks(ticksPerQuarter: 960), 320)
        XCTAssertEqual(MusicPianoRollGrid.sixteenth.snapped(390, ticksPerQuarter: 960), 480)
        XCTAssertEqual(MusicPianoRollGrid.free.snapped(391, ticksPerQuarter: 960), 391)
        XCTAssertThrowsError(try MusicPianoRollEditing.setVelocity(source, selection: ["a"], value: 0))
    }
}
