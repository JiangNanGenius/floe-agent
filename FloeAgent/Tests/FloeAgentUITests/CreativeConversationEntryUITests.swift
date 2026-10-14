import XCTest

@MainActor
final class CreativeConversationEntryUITests: XCTestCase {
    func testCreativeStartUsesConversationAndRetainsUnsentDraft() throws {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .landscapeLeft
        let app = XCUIApplication()
        app.launchArguments += ["-ui-testing", "-ui-testing-ipad", "--ui-test-reset-creative-draft"]
        app.launch()
        let creative = app.descendants(matching: .any)
            .matching(identifier: "sidebar.creative").firstMatch
        XCTAssertTrue(creative.waitForExistence(timeout: 10))
        if !creative.isHittable {
            let drawer = app.buttons["phone.sidebar.open"]
            XCTAssertTrue(drawer.waitForExistence(timeout: 5))
            drawer.tap()
        }
        creative.tap()
        let start = app.buttons["canvas.home.design"]
        XCTAssertTrue(start.waitForExistence(timeout: 8))
        start.tap()
        let input = app.textViews["composer.input"]
        XCTAssertTrue(input.waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["design.owner.creativeStart"].exists)
        XCTAssertFalse(app.buttons["canvas.home.design.presentation"].exists)
        let prompt = "Create a presentation with editable charts"
        input.tap()
        let old = input.value as? String ?? ""
        if !old.isEmpty { input.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: old.count)) }
        input.typeText(prompt)
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "Creative natural-language start"
        attachment.lifetime = .keepAlways
        add(attachment)
        // No send: this UI acceptance must never trigger a paid model call.
        app.terminate()
        // Relaunch WITHOUT the draft-reset flag: retention is the assertion.
        let relaunched = XCUIApplication()
        relaunched.launchArguments += ["-ui-testing", "-ui-testing-ipad"]
        relaunched.launch()
        let reopened = relaunched.descendants(matching: .any).matching(identifier: "sidebar.creative").firstMatch
        XCTAssertTrue(reopened.waitForExistence(timeout: 10))
        if !reopened.isHittable {
            let drawer = relaunched.buttons["phone.sidebar.open"]
            XCTAssertTrue(drawer.waitForExistence(timeout: 5))
            drawer.tap()
        }
        reopened.tap()
        let restarted = relaunched.buttons["canvas.home.design"]
        XCTAssertTrue(restarted.waitForExistence(timeout: 8))
        restarted.tap()
        let retainedInput = relaunched.textViews["composer.input"]
        XCTAssertTrue(retainedInput.waitForExistence(timeout: 10))
        XCTAssertEqual(retainedInput.value as? String, prompt)
    }
}
