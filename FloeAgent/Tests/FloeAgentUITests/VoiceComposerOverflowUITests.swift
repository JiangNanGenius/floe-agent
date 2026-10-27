import XCTest

/// Drives the real voice screen composer with no microphone or model request.
@MainActor
final class VoiceComposerOverflowUITests: XCTestCase {
    func testVoiceDraftWrapsExpandsAndReturnsWithoutEndingSession() {
        exerciseComposer(compact: false)
    }

    func testCompactVoiceComposerRetainsTheFullDraft() {
        exerciseComposer(compact: true)
    }

    private func exerciseComposer(compact: Bool) {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchArguments = ["-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN",
                               "-ui-testing", "-ui-testing-ipad", "--ui-test-skip-onboarding",
                               "--ui-test-voice-composer"]
        if compact { app.launchArguments.append("--ui-test-compact-width") }
        app.launch()
        defer { app.terminate() }
        let input = app.textViews["voice.composer.input"]
        XCTAssertTrue(input.waitForExistence(timeout: 30))
        if compact { XCTAssertLessThanOrEqual(input.frame.width, 390) }
        let initialHeight = input.frame.height
        let text = String(repeating: "语音聊天里编辑完整的一句话 Mixed English 日本語 https://example.com/averylongunbrokenpath1234567890 ", count: 16)
        input.tap()
        input.typeText(text)
        let expand = app.buttons["voice.composer.expand"]
        XCTAssertTrue(expand.waitForExistence(timeout: 15))
        XCTAssertGreaterThan(input.frame.height, initialHeight + 8)
        XCTAssertLessThan(input.frame.height, 300)
        XCTAssertEqual(input.value as? String, text)
        keepScreenshot(app, name: "Voice composer wrapped at real width")

        expand.tap()
        let editor = app.textViews["composer.editor.input"]
        XCTAssertTrue(editor.waitForExistence(timeout: 10))
        XCTAssertEqual(editor.value as? String, text)
        editor.tap()
        editor.typeText(XCUIKeyboardKey.return.rawValue + "补充一句")
        let edited = editor.value as? String ?? ""
        XCTAssertTrue(edited.contains("\n补充一句"), "Return edits the draft without sending")
        keepScreenshot(app, name: "Voice composer full editor with complete draft")
        app.buttons["composer.editor.done"].tap()
        XCTAssertTrue(input.waitForExistence(timeout: 10))
        XCTAssertEqual(input.value as? String, edited)
        // Editing intentionally shows the transcript instead of the orb/status.
        // Assert the surviving voice screen, not a deliberately hidden status label.
        XCTAssertTrue(app.descendants(matching: .any)
            .matching(identifier: "voice.conversation").firstMatch.exists,
                      "Closing only the child editor retains the parent voice screen")
        keepScreenshot(app, name: "Voice composer returned to the same session")
    }

    private func keepScreenshot(_ app: XCUIApplication, name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
