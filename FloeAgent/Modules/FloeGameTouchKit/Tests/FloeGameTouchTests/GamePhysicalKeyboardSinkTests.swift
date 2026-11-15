// SPDX-License-Identifier: MPL-2.0
import XCTest
import FloeGameWebKit
@testable import FloeGameTouch

@MainActor private final class KeyboardRecorder {
    var current = true
    var failingPress: GameKeyboardKey?
    var events: [String] = []
    enum Failure: Error { case write }
    func send(_ key: GameKeyboardKey, _ pressed: Bool) throws {
        events.append("\(pressed ? "down" : "up"):\(key.rawValue)")
        if pressed, key == failingPress { throw Failure.write }
    }
}

@MainActor final class GamePhysicalKeyboardSinkTests: XCTestCase {
    func testOverlappingChordsKeepSharedModifierHeldUntilBothRelease() async throws {
        let recorder = KeyboardRecorder()
        let sink = GamePhysicalKeyboardSink(isCurrent: { recorder.current }, transport: recorder.send)
        let undo = GameTouchBinding.chord(try GameTouchChord(keys: [.control, .z]))
        let cut = GameTouchBinding.chord(try GameTouchChord(keys: [.control, .x]))
        try await sink.set(undo, pressed: true)
        try await sink.set(cut, pressed: true)
        try await sink.set(undo, pressed: false)
        XCTAssertEqual(recorder.events, ["down:control", "down:z", "down:x", "up:z"])
        try await sink.set(cut, pressed: false)
        XCTAssertEqual(Array(recorder.events.suffix(2)), ["up:x", "up:control"])
    }

    func testEveryPhysicalKeySupportsDistinctPressAndRelease() async throws {
        let recorder = KeyboardRecorder()
        let sink = GamePhysicalKeyboardSink(isCurrent: { true }, transport: recorder.send)
        for key in GameKeyboardKey.allCases {
            try await sink.set(.key(key), pressed: true)
            try await sink.set(.key(key), pressed: true)
            try await sink.set(.key(key), pressed: false)
        }
        XCTAssertEqual(recorder.events.count, GameKeyboardKey.allCases.count * 2)
        XCTAssertEqual(Array(recorder.events.prefix(2)), ["down:left", "up:left"])
    }

    func testStaleDisplayReleasesCapturedKeysAndRejectsLatePress() async throws {
        let recorder = KeyboardRecorder()
        let sink = GamePhysicalKeyboardSink(isCurrent: { recorder.current }, transport: recorder.send)
        try await sink.set(.key(.left), pressed: true)
        recorder.current = false
        do {
            try await sink.set(.key(.right), pressed: true)
            XCTFail("Stale display input must fail")
        } catch { XCTAssertEqual(error as? GamePhysicalKeyboardSinkError, .staleSession) }
        XCTAssertEqual(recorder.events, ["down:left", "up:left"])
        sink.invalidate()
        XCTAssertEqual(recorder.events.count, 2)
    }

    func testPartialTransportFailureReleasesAttemptedKeyAndModifier() async throws {
        let recorder = KeyboardRecorder()
        recorder.failingPress = .right
        let sink = GamePhysicalKeyboardSink(isCurrent: { true }, transport: recorder.send)
        do {
            try await sink.set(.chord(try GameTouchChord(keys: [.control, .right])), pressed: true)
            XCTFail("Transport failure must be observable")
        } catch { XCTAssertTrue(error is KeyboardRecorder.Failure) }
        XCTAssertEqual(recorder.events, ["down:control", "down:right", "up:right", "up:control"])
        do {
            try await sink.set(.key(.left), pressed: true)
            XCTFail("Failed input session must be fenced")
        } catch { XCTAssertEqual(error as? GamePhysicalKeyboardSinkError, .staleSession) }
    }
}
