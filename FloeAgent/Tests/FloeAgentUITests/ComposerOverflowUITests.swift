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
        // The reused simulator preserves many workspace groups above the
        // Chats section and chat rows stay lazy until the sidebar scrolls
        // them into the realized window. Scroll only the sidebar list —
        // never workspace or user data — until the seeded fixture row is
        // visible. iOS 27 may report no AX activation point for a visible
        // drawer row; use its verified frame, as TemporaryConversation does.
        let sidebar = app.descendants(matching: .any)
            .matching(identifier: "sidebar.list").firstMatch
        XCTAssertTrue(sidebar.waitForExistence(timeout: 10))
        func rowIsVisible() -> Bool {
            guard row.exists else { return false }
            let frame = row.frame
            let point = CGPoint(x: frame.midX, y: frame.midY)
            return frame.width > 0 && frame.height > 0
                && point.x.isFinite && point.y.isFinite
                && sidebar.frame.contains(point) && app.windows.firstMatch.frame.contains(point)
        }
        for _ in 0..<20 where !rowIsVisible() { sidebar.swipeUp() }
        for _ in 0..<20 where !rowIsVisible() { sidebar.swipeDown() }
        XCTAssertTrue(rowIsVisible(),
                      "the seeded synthetic conversation must be reachable in the sidebar")
        let screen = app.windows.firstMatch.frame
        app.windows.firstMatch.coordinate(withNormalizedOffset: .zero)
            .withOffset(CGVector(dx: row.frame.midX - screen.minX, dy: row.frame.midY - screen.minY))
            .tap()
        XCTAssertTrue(app.navigationBars["任务管理测试-C"].waitForExistence(timeout: 10),
                      "Only the synthetic conversation may receive the test draft")
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
