import XCTest

@MainActor
final class ComposerOverflowUITests: XCTestCase {
    func testSoftWrappedDraftExpandsWithoutLosingText() throws {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchArguments = ["-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN",
                               "-ui-testing", "-ui-testing-ipad", "--ui-test-skip-onboarding",
                               "--ui-test-task-management-fixture"]
        app.launch()
        defer { app.terminate() }

        // Only the fixed, synthetic task is edited. Never replace a user's
        // current draft, send a request or change a configured provider.
        let row = app.descendants(matching: .any)
            .matching(identifier: "sidebar.conversation.A1D4A0F2-6F2E-4E7A-9C31-0B7C51E6A003").firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 30))
        row.tap()
        let input = app.textViews["composer.input"]
        XCTAssertTrue(input.waitForExistence(timeout: 20))
        let text = String(repeating: "Soft wrapping must keep this complete sentence inside the composer. ", count: 16)
            + "https://example.invalid/" + String(repeating: "a", count: 220)
        input.tap()
        let previous = input.value as? String ?? ""
        if previous != text {
            if !previous.isEmpty {
                input.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: previous.count))
            }
            input.typeText(text)
        }
        let expand = app.buttons["composer.expand"]
        XCTAssertTrue(expand.waitForExistence(timeout: 15), "A genuinely overflowing soft-wrapped draft exposes Expand")
        let inline = XCTAttachment(screenshot: app.screenshot())
        inline.name = "Composer soft-wrapped overflow"
        inline.lifetime = .keepAlways
        add(inline)

        expand.tap()
        let editor = app.textViews["composer.editor.input"]
        XCTAssertTrue(editor.waitForExistence(timeout: 10))
        XCTAssertEqual(editor.value as? String, text, "Expanding must retain the whole draft")
        let expanded = XCTAttachment(screenshot: app.screenshot())
        expanded.name = "Composer full editor complete draft"
        expanded.lifetime = .keepAlways
        add(expanded)
        app.buttons["composer.editor.done"].tap()
        XCTAssertTrue(input.waitForExistence(timeout: 10))
        XCTAssertEqual(input.value as? String, text, "Closing the editor retains the same draft")
    }
}
