import CoreGraphics
import FloeMusicKeyboard
import XCTest

/// Implements the advertised host-side all-off semantics, independently of
/// the controller's event sequence. It models a pedal-held sounding voice.
@MainActor
private final class SemanticInstrumentSink: KeyboardPerformanceSink {
    var sustain = false
    var bend: Float = 0
    var modulation: Float = 0
    var hasVoice = false

    func receive(_ event: KeyboardPerformanceEvent) {
        switch event {
        case .noteOn: hasVoice = true
        case .noteOff: if !sustain { hasVoice = false }
        case .sustain(_, let value):
            sustain = value
            if !value { hasVoice = false }
        case .pitchBend(_, let value): bend = value
        case .modulation(_, let value): modulation = value
        case .allNotesOff:
            hasVoice = false
            sustain = false
            bend = 0
            modulation = 0
        }
    }
}

@MainActor
final class KeyboardPerformanceControllerTests: XCTestCase {
    private let ownerA = KeyboardOwnerToken("track-1")
    private let ownerB = KeyboardOwnerToken("track-2")

    private func makeController(
        owner: KeyboardOwnerToken? = nil,
        velocityPolicy: KeyVelocityPolicy = .fixed(100)
    ) -> (KeyboardPerformanceController, RecordingKeyboardSink) {
        let sink = RecordingKeyboardSink()
        let controller = KeyboardPerformanceController(
            owner: owner ?? ownerA,
            sink: sink,
            velocityPolicy: velocityPolicy
        )
        return (controller, sink)
    }

    // MARK: - Basic note lifecycle

    func testNoteOnNoteOffRoundTrip() {
        let (controller, sink) = makeController()
        controller.keyDown(sourcePitch: 60)
        XCTAssertEqual(sink.events, [.noteOn(ownerA, PerformanceNote(note: 60, velocity: 100, channel: 0))])
        controller.keyUp(sourcePitch: 60)
        XCTAssertEqual(sink.events.last, .noteOff(owner: ownerA, note: 60, channel: 0))
    }

    func testRepeatedSameNoteRetriggers() {
        let (controller, sink) = makeController()
        controller.keyDown(sourcePitch: 60)
        controller.keyDown(sourcePitch: 60)
        XCTAssertEqual(
            sink.events,
            [
                .noteOn(ownerA, PerformanceNote(note: 60, velocity: 100, channel: 0)),
                .noteOff(owner: ownerA, note: 60, channel: 0),
                .noteOn(ownerA, PerformanceNote(note: 60, velocity: 100, channel: 0))
            ]
        )
        controller.keyUp(sourcePitch: 60)
        XCTAssertEqual(
            sink.events,
            [
                .noteOn(ownerA, PerformanceNote(note: 60, velocity: 100, channel: 0)),
                .noteOff(owner: ownerA, note: 60, channel: 0),
                .noteOn(ownerA, PerformanceNote(note: 60, velocity: 100, channel: 0)),
                .noteOff(owner: ownerA, note: 60, channel: 0)
            ]
        )
    }

    func testKeyUpWithoutHeldNoteIsIgnored() {
        let (controller, sink) = makeController()
        controller.keyUp(sourcePitch: 60)
        XCTAssertTrue(sink.events.isEmpty)
    }

    func testHeldSourcePitchesAreTracked() {
        let (controller, _) = makeController()
        XCTAssertEqual(controller.heldSourcePitches, [])
        controller.keyDown(sourcePitch: 64)
        controller.keyDown(sourcePitch: 60)
        XCTAssertEqual(controller.heldSourcePitches, [60, 64])
        controller.keyUp(sourcePitch: 60)
        XCTAssertEqual(controller.heldSourcePitches, [64])
        controller.keyUp(sourcePitch: 64)
        XCTAssertEqual(controller.heldSourcePitches, [])
    }

    func testChannelStamping() {
        let sink = RecordingKeyboardSink()
        let controller = KeyboardPerformanceController(owner: ownerA, sink: sink, velocityPolicy: .fixed(100), defaultChannel: 3)
        controller.keyDown(sourcePitch: 60)
        XCTAssertEqual(sink.events, [.noteOn(ownerA, PerformanceNote(note: 60, velocity: 100, channel: 3))])
    }

    // MARK: - Velocity

    func testFixedVelocityPolicy() {
        let (controller, sink) = makeController(velocityPolicy: .fixed(72))
        controller.keyDown(sourcePitch: 60, normalizedPoint: CGPoint(x: 0.5, y: 0.0))
        XCTAssertEqual(sink.events, [.noteOn(ownerA, PerformanceNote(note: 60, velocity: 72, channel: 0))])
    }

    func testTouchVerticalVelocityMapping() {
        let (controller, sink) = makeController(velocityPolicy: .touchVertical(minVelocity: 48, maxVelocity: 127))
        controller.keyDown(sourcePitch: 60, normalizedPoint: CGPoint(x: 0.5, y: 0))
        controller.keyUp(sourcePitch: 60)
        controller.keyDown(sourcePitch: 60, normalizedPoint: CGPoint(x: 0.5, y: 1))
        controller.keyUp(sourcePitch: 60)
        controller.keyDown(sourcePitch: 60, normalizedPoint: CGPoint(x: 0.5, y: 0.5))
        XCTAssertEqual(
            sink.events,
            [
                .noteOn(ownerA, PerformanceNote(note: 60, velocity: 48, channel: 0)),
                .noteOff(owner: ownerA, note: 60, channel: 0),
                .noteOn(ownerA, PerformanceNote(note: 60, velocity: 127, channel: 0)),
                .noteOff(owner: ownerA, note: 60, channel: 0),
                .noteOn(ownerA, PerformanceNote(note: 60, velocity: 88, channel: 0))
            ]
        )
    }

    // MARK: - Wheels

    func testPitchBendClampingAndEmission() {
        let (controller, sink) = makeController()
        controller.pitchBend = 0.5
        controller.pitchBend = 2 // clamps to 1
        controller.pitchBend = -3 // clamps to -1
        XCTAssertEqual(controller.pitchBend, -1)
        XCTAssertEqual(
            sink.events,
            [
                .pitchBend(ownerA, value: 0.5),
                .pitchBend(ownerA, value: 1),
                .pitchBend(ownerA, value: -1)
            ]
        )
    }

    func testModulationClampingAndEmission() {
        let (controller, sink) = makeController()
        controller.modulation = 0.25
        controller.modulation = -1 // clamps to 0
        XCTAssertEqual(controller.modulation, 0)
        XCTAssertEqual(
            sink.events,
            [
                .modulation(ownerA, value: 0.25),
                .modulation(ownerA, value: 0)
            ]
        )
    }

    // MARK: - Sustain

    func testSustainIsForwardedAndKeyReleaseIsNotDeferred() {
        let (controller, sink) = makeController()
        controller.sustain = true
        controller.keyDown(sourcePitch: 60)
        controller.keyUp(sourcePitch: 60) // pedal semantics stay with the host
        controller.sustain = false
        XCTAssertEqual(
            sink.events,
            [
                .sustain(ownerA, true),
                .noteOn(ownerA, PerformanceNote(note: 60, velocity: 100, channel: 0)),
                .noteOff(owner: ownerA, note: 60, channel: 0),
                .sustain(ownerA, false)
            ]
        )
    }

    // MARK: - Octave / transpose / range / preset

    func testOctaveChangeReleasesOriginalSoundingPitches() {
        let (controller, sink) = makeController()
        controller.keyDown(sourcePitch: 60) // sounds 60
        controller.octaveOffset = 1
        // Releasing after the shift must NOT turn off the newly shifted note.
        controller.keyUp(sourcePitch: 60)
        XCTAssertEqual(
            sink.events,
            [
                .noteOn(ownerA, PerformanceNote(note: 60, velocity: 100, channel: 0)),
                .noteOff(owner: ownerA, note: 60, channel: 0),
                .allNotesOff(ownerA)
            ]
        )
        controller.keyDown(sourcePitch: 60) // now sounds 72
        XCTAssertEqual(
            sink.events.last,
            .noteOn(ownerA, PerformanceNote(note: 72, velocity: 100, channel: 0))
        )
    }

    func testTransposeChangeReleasesOriginalSoundingPitches() {
        let (controller, sink) = makeController()
        controller.keyDown(sourcePitch: 60) // sounds 60
        controller.transpose = 2
        controller.keyUp(sourcePitch: 60)
        XCTAssertEqual(
            sink.events,
            [
                .noteOn(ownerA, PerformanceNote(note: 60, velocity: 100, channel: 0)),
                .noteOff(owner: ownerA, note: 60, channel: 0),
                .allNotesOff(ownerA)
            ]
        )
        controller.keyDown(sourcePitch: 60)
        XCTAssertEqual(
            sink.events.last,
            .noteOn(ownerA, PerformanceNote(note: 62, velocity: 100, channel: 0))
        )
    }

    func testPartialReleaseKeepsPedalAndWheels() {
        let (controller, sink) = makeController()
        controller.sustain = true
        controller.pitchBend = 0.5
        controller.modulation = 0.25
        controller.keyDown(sourcePitch: 60)
        sink.reset()
        controller.octaveOffset = 1
        XCTAssertEqual(
            sink.events,
            [
                .noteOff(owner: ownerA, note: 60, channel: 0),
                .allNotesOff(ownerA),
                .sustain(ownerA, true),
                .pitchBend(ownerA, value: 0.5),
                .modulation(ownerA, value: 0.25)
            ]
        )
        XCTAssertTrue(controller.sustain)
        XCTAssertEqual(controller.pitchBend, 0.5)
        XCTAssertEqual(controller.modulation, 0.25)
    }

    func testNoteRangeChangeReleasesHeldKeys() {
        let (controller, sink) = makeController()
        controller.keyDown(sourcePitch: 60)
        sink.reset()
        controller.noteRangeDidChange()
        XCTAssertEqual(
            sink.events,
            [
                .noteOff(owner: ownerA, note: 60, channel: 0),
                .allNotesOff(ownerA)
            ]
        )
        // A late touch release after the range change releases nothing new.
        controller.keyUp(sourcePitch: 60)
        XCTAssertEqual(sink.events.count, 2)
    }

    func testPresetChangeReleasesHeldKeys() {
        let (controller, sink) = makeController()
        controller.keyDown(sourcePitch: 60)
        sink.reset()
        controller.presetDidChange()
        XCTAssertEqual(
            sink.events,
            [
                .noteOff(owner: ownerA, note: 60, channel: 0),
                .allNotesOff(ownerA)
            ]
        )
    }

    func testShiftedNoteOutsideMIDIRangeIsDropped() {
        let (controller, sink) = makeController()
        controller.octaveOffset = 6 // 60 + 72 = 132 > 127
        controller.keyDown(sourcePitch: 60)
        XCTAssertTrue(sink.events.isEmpty)
        controller.octaveOffset = 0
        controller.transpose = -60
        controller.keyDown(sourcePitch: 10) // 10 - 60 = -50 < 0
        XCTAssertTrue(sink.events.isEmpty)
    }

    // MARK: - Owner changes

    func testPartialReleaseKeepsHostControlsInSyncAndStopsPedalHeldVoice() {
        let host = SemanticInstrumentSink()
        let controller = KeyboardPerformanceController(owner: ownerA, sink: host)
        controller.sustain = true
        controller.pitchBend = 0.5
        controller.modulation = 0.25
        controller.keyDown(sourcePitch: 60)
        controller.keyUp(sourcePitch: 60)
        XCTAssertTrue(controller.heldSourcePitches.isEmpty)
        XCTAssertTrue(host.hasVoice)
        controller.octaveOffset = 1
        XCTAssertFalse(host.hasVoice)
        XCTAssertEqual(host.sustain, controller.sustain)
        XCTAssertEqual(host.bend, controller.pitchBend)
        XCTAssertEqual(host.modulation, controller.modulation)
        controller.keyDown(sourcePitch: 60)
        XCTAssertTrue(host.hasVoice)
    }

    func testExtremeShiftValuesAreRejectedWithoutOverflow() {
        let (controller, sink) = makeController()
        controller.octaveOffset = Int.max
        controller.keyDown(sourcePitch: 60)
        controller.octaveOffset = Int.min
        controller.keyDown(sourcePitch: 60)
        controller.octaveOffset = 0
        controller.transpose = Int.max
        controller.keyDown(sourcePitch: 60)
        controller.transpose = 0
        controller.keyDown(sourcePitch: Int.min)
        XCTAssertTrue(sink.events.isEmpty)
    }

    func testMalformedTouchAndChannelValuesProduceValidMIDI() {
        let (controller, sink) = makeController(velocityPolicy: .touchVertical(minVelocity: 255, maxVelocity: 200))
        controller.defaultChannel = 255
        controller.keyDown(sourcePitch: 60, normalizedPoint: CGPoint(x: 0.5, y: CGFloat.nan))
        XCTAssertEqual(sink.events.last, .noteOn(ownerA, PerformanceNote(note: 60, velocity: 127, channel: 15)))
        controller.keyUp(sourcePitch: 60)
        controller.velocityPolicy = .fixed(0)
        controller.keyDown(sourcePitch: 60)
        XCTAssertEqual(sink.events.last, .noteOn(ownerA, PerformanceNote(note: 60, velocity: 1, channel: 15)))
        controller.pitchBend = .nan
        controller.modulation = .infinity
        XCTAssertEqual(controller.pitchBend, 0)
        XCTAssertEqual(controller.modulation, 0)
    }

    func testOwnerChangeReleasesHeldNotesWithOldOwner() {
        let (controller, sink) = makeController()
        controller.keyDown(sourcePitch: 60)
        controller.keyDown(sourcePitch: 64)
        sink.reset()
        controller.owner = ownerB
        XCTAssertEqual(
            sink.events,
            [
                .noteOff(owner: ownerA, note: 60, channel: 0),
                .noteOff(owner: ownerA, note: 64, channel: 0),
                .allNotesOff(ownerA)
            ]
        )
        // New events carry the new owner only.
        controller.keyDown(sourcePitch: 62)
        XCTAssertEqual(
            sink.events.last,
            .noteOn(ownerB, PerformanceNote(note: 62, velocity: 100, channel: 0))
        )
    }

    func testOwnerChangeResetsPedalAndWheels() {
        let (controller, sink) = makeController()
        controller.sustain = true
        controller.pitchBend = 0.5
        controller.modulation = 0.25
        controller.keyDown(sourcePitch: 60)
        sink.reset()
        controller.owner = ownerB
        XCTAssertEqual(
            sink.events,
            [
                .noteOff(owner: ownerA, note: 60, channel: 0),
                .sustain(ownerA, false),
                .pitchBend(ownerA, value: 0),
                .modulation(ownerA, value: 0),
                .allNotesOff(ownerA)
            ]
        )
        XCTAssertFalse(controller.sustain)
        XCTAssertEqual(controller.pitchBend, 0)
        XCTAssertEqual(controller.modulation, 0)
    }

    func testSettingSameOwnerIsANoOp() {
        let (controller, sink) = makeController()
        controller.keyDown(sourcePitch: 60)
        sink.reset()
        controller.owner = ownerA
        XCTAssertTrue(sink.events.isEmpty)
    }

    // MARK: - Sink replacement

    func testSinkReplacementDeliversReleaseToOldSinkOnly() {
        let (controller, sinkA) = makeController()
        let sinkB = RecordingKeyboardSink()
        controller.keyDown(sourcePitch: 60)
        controller.sustain = true
        sinkA.reset()
        controller.sink = sinkB
        XCTAssertEqual(
            sinkA.events,
            [
                .noteOff(owner: ownerA, note: 60, channel: 0),
                .sustain(ownerA, false),
                .allNotesOff(ownerA)
            ]
        )
        XCTAssertTrue(sinkB.events.isEmpty)
        // New events flow to the replacement sink.
        controller.keyDown(sourcePitch: 62)
        XCTAssertEqual(
            sinkB.events,
            [.noteOn(ownerA, PerformanceNote(note: 62, velocity: 100, channel: 0))]
        )
    }

    func testReassigningSameSinkDoesNotRelease() {
        let (controller, sink) = makeController()
        controller.keyDown(sourcePitch: 60)
        controller.sink = sink
        XCTAssertEqual(
            sink.events,
            [.noteOn(ownerA, PerformanceNote(note: 60, velocity: 100, channel: 0))]
        )
    }

    // MARK: - Full release

    func testReleaseAllEmitsNoteOffsResetsControllersAndFences() {
        let (controller, sink) = makeController()
        controller.sustain = true
        controller.pitchBend = 0.5
        controller.keyDown(sourcePitch: 60)
        controller.keyDown(sourcePitch: 65)
        sink.reset()
        controller.releaseAll(reason: .panelClosed)
        XCTAssertEqual(
            sink.events,
            [
                .noteOff(owner: ownerA, note: 60, channel: 0),
                .noteOff(owner: ownerA, note: 65, channel: 0),
                .sustain(ownerA, false),
                .pitchBend(ownerA, value: 0),
                .allNotesOff(ownerA)
            ]
        )
        // Late touch releases after close are no-ops (no autoplay/stuck notes).
        controller.keyUp(sourcePitch: 60)
        controller.keyUp(sourcePitch: 65)
        XCTAssertEqual(sink.events.count, 5)
    }

    func testEventsResumeAfterReleaseAllOnNewTouches() {
        let (controller, sink) = makeController()
        controller.releaseAll(reason: .sceneBecameInactive)
        sink.reset()
        controller.keyDown(sourcePitch: 60)
        XCTAssertEqual(sink.events, [.noteOn(ownerA, PerformanceNote(note: 60, velocity: 100, channel: 0))])
    }
}
