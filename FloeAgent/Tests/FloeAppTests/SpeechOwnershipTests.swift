#if canImport(UIKit)
import XCTest
@testable import FloeApp

@MainActor
final class SpeechOwnershipTests: XCTestCase {
    func testFailureOnlyBelongsToMessageThatStartedPlayback() {
        let speech = SpeechService()
        let owner = UUID(), anotherMessage = UUID()
        // An unconfigured service deterministically exercises the startup
        // failure path without a microphone, provider or audio device.
        speech.speak("Identical text", ownerID: owner)
        XCTAssertEqual(speech.failureOwnerID, owner)
        XCTAssertEqual(speech.failureKey, "voice.error.configuration")
        XCTAssertFalse(speech.isPreparing)
        speech.clearFailure(ownerID: anotherMessage)
        XCTAssertEqual(speech.failureOwnerID, owner)
        speech.clearFailure(ownerID: owner)
        XCTAssertNil(speech.failureKey)
        XCTAssertNil(speech.failureOwnerID)
    }

    func testStopAndNewMessageCannotRetainOldFailureOwner() {
        let speech = SpeechService()
        let first = UUID(), second = UUID()
        speech.speak("Same body", ownerID: first)
        speech.stop()
        XCTAssertNil(speech.failureOwnerID)
        XCTAssertNil(speech.failedText)
        XCTAssertNil(speech.activeOwnerID)
        speech.speak("Same body", ownerID: second)
        XCTAssertEqual(speech.failureOwnerID, second)
    }
}
#endif
