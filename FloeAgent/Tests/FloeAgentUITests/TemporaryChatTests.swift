// FloeAgentUITests — Temporary chat voice entry and compact-header retention.
//
// Lane job-9dd076dfbf764bac. TemporaryConversationUITests (primary-owned,
// patched for the compact header) already covers: launchpad entry, the badge
// menu with hint + Keep + End, banner absence, voice visibility at entry,
// separate-session leave, explicit End/Keep, rotation and background
// retention with a RAM draft.
//
// This suite deliberately adds ONLY the cases that suite does not exercise:
//  1. actually using the microphone entry inside a temporary chat (the chat
//     and its draft must survive whatever the permission state is);
//  2. background/foreground keeping the compact header ACTIONS and the voice
//     entry available (menu opens with Keep/End, no banner returns).
// It reuses the same DEBUG-only TemporaryChatUITestFixture (no duplicated
// fixture) and never sends a message.

import XCTest

@MainActor
final class TemporaryChatTests: XCTestCase {

    private func presetApp() -> XCUIApplication {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments += [
            "-ui-testing",
            "--ui-test-temporary-chat-fixture",
            "--ui-test-temporary-chat-preset-session",
        ]
        if UIDevice.current.userInterfaceIdiom == .pad {
            app.launchArguments.append("-ui-testing-ipad")
        }
        app.launch()
        return app
    }

    /// Opens the compact temporary action menu from the header badge. iOS 27
    /// can expose a toolbar menu with a valid frame but no usable AX
    /// activation point, so the verified on-screen center is tapped when the
    /// first tap did not open the menu.
    private func openTemporaryMenu(_ app: XCUIApplication) {
        let badge = app.descendants(matching: .any)["chat.temporary.badge"].firstMatch
        XCTAssertTrue(badge.waitForExistence(timeout: 10), "temporary badge must be in the header")
        badge.tap()
        let keep = app.descendants(matching: .any)["chat.temporary.keep"].firstMatch
        if !keep.waitForExistence(timeout: 5) {
            let screen = app.windows.firstMatch.frame
            let frame = badge.frame
            let center = CGPoint(x: frame.midX, y: frame.midY)
            if frame.width > 0, frame.height > 0, screen.contains(center) {
                app.windows.firstMatch.coordinate(withNormalizedOffset: .zero)
                    .withOffset(CGVector(dx: center.x - screen.minX, dy: center.y - screen.minY))
                    .tap()
            }
        }
        XCTAssertTrue(keep.waitForExistence(timeout: 8), "the temporary action menu must open")
    }

    /// NEW case: the microphone is a usable temporary-chat control. Tapping it
    /// enters the product's real voice-capture composer mode (which replaces
    /// the editor + microphone with the documented square stop control) or, when
    /// capture cannot start (permission denied / unavailable), leaves the
    /// standard composer. In BOTH paths the temporary session, its messages and
    /// the in-RAM draft must survive, and the draft must come back once the
    /// capture session stops.
    func testTemporaryMicrophoneInteractionKeepsSessionAndDraft() {
        let app = presetApp()
        // A system speech/microphone permission alert can appear on a fresh
        // install; dismiss it either way so both product paths are exercised.
        addUIInterruptionMonitor(withDescription: "voice permission") { alert in
            for label in ["Allow", "允许", "OK", "好", "Don't Allow", "不允许"] {
                let button = alert.buttons[label]
                if button.exists {
                    button.tap()
                    return true
                }
            }
            return false
        }
        let badge = app.descendants(matching: .any)["chat.temporary.badge"].firstMatch
        XCTAssertTrue(badge.waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["合成临时提问"].waitForExistence(timeout: 8))

        let draft = "临时语音前的草稿 \(UUID().uuidString.prefix(8))"
        let input = app.textViews["composer.input"]
        XCTAssertTrue(input.waitForExistence(timeout: 8))
        input.tap()
        input.typeText(draft)

        let mic = app.buttons["composer.voice"]
        XCTAssertTrue(mic.waitForExistence(timeout: 8), "temporary chat must offer voice input")
        mic.tap()

        // The temporary session, its messages and the compact header survive
        // the microphone interaction in every permission state.
        XCTAssertTrue(badge.waitForExistence(timeout: 8))
        XCTAssertTrue(app.staticTexts["合成临时提问"].waitForExistence(timeout: 8))
        XCTAssertFalse(app.descendants(matching: .any)["chat.temporary.banner"].firstMatch.exists)

        // Voice capture is a distinct composer mode: while a session is active
        // the editable row is replaced by the explicit square stop control.
        let stop = app.buttons["composer.voice.stop"]
        if !stop.waitForExistence(timeout: 12) {
            // Trigger the interruption monitor if a permission alert is up.
            app.tap()
        }
        if stop.waitForExistence(timeout: 8) {
            stop.tap()
        }

        // Both paths restore the editable composer with the draft intact.
        let restored = app.textViews["composer.input"]
        XCTAssertTrue(restored.waitForExistence(timeout: 15),
                      "the composer must return after the voice interaction")
        XCTAssertEqual(restored.value as? String, draft,
                       "the temporary draft must survive the voice interaction")
        // Text-only staging stays hidden.
        XCTAssertFalse(app.buttons["composer.attach"].exists)
        XCTAssertFalse(app.descendants(matching: .any)["chat.temporary.banner"].firstMatch.exists)
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "Temporary composer — microphone interaction keeps the session"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    /// NEW case: background/foreground keeps the compact header ACTIONS and
    /// the voice entry (the patched suite checks the badge/messages/draft).
    func testBackgroundKeepsTemporaryHeaderActionsAndVoiceEntry() {
        let app = presetApp()
        let badge = app.descendants(matching: .any)["chat.temporary.badge"].firstMatch
        XCTAssertTrue(badge.waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["合成临时提问"].waitForExistence(timeout: 8))

        XCUIDevice.shared.press(.home)
        let backgrounded = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in
                app.state == .runningBackground || app.state == .runningBackgroundSuspended
            },
            object: app
        )
        XCTAssertEqual(XCTWaiter.wait(for: [backgrounded], timeout: 8), .completed)
        app.activate()

        XCTAssertTrue(badge.waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["合成临时提问"].exists)
        XCTAssertTrue(app.buttons["composer.voice"].waitForExistence(timeout: 8))
        openTemporaryMenu(app)
        XCTAssertTrue(app.descendants(matching: .any)["chat.temporary.end"].firstMatch.exists)
        XCTAssertFalse(app.descendants(matching: .any)["chat.temporary.banner"].firstMatch.exists)
    }
}
