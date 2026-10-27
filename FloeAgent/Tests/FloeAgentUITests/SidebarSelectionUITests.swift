// FloeAgentUITests — corrected sidebar row long-press + inline Multi-select.
//
// Binding user correction (2026-10-27): ordinary sidebar rows show NO
// trailing ellipsis and NO circles; a long press opens the native context
// menu (置顶 / 重命名 / 移动到项目 / 多选 / 归档 / 删除) and must NOT enter
// selection directly. Only 多选 (Multi-select) reveals the inline circles
// and selects the invoking row; tapping the row toggles without navigating;
// 完成 (Done) exits and restores the ordinary rows. 置顶/取消置顶 flip in
// the same menu proves the durable pin round-trip through the real App UI.
//
// Fixture: --ui-test-batch-fixture seeds exactly one durable conversation
// 批量选择测试 with the stable id 57C0A79F-CF1B-45D2-B640-EF54E5C55391
// (shared with the existing suites). zh-Hans launch keeps the menu labels
// deterministic. iOS 27 may report no AX activation point for a visible
// sidebar row, so the row is only ever touched through its VERIFIED frame
// via a window-coordinate long press (same rule the existing
// ComposerOverflowUITests / TemporaryConversationUITests follow), and only
// the fixed synthetic fixture is pressed — never an arbitrary user row.
// The suite always finishes unpinned and out of selection mode so repeat
// runs start from the same shape.

import XCTest

@MainActor
final class SidebarSelectionUITests: XCTestCase {
    private let fixtureID = "57C0A79F-CF1B-45D2-B640-EF54E5C55391"

    private func launchApp() -> XCUIApplication {
        let app = XCUIApplication()
        app.terminate()
        XCUIDevice.shared.orientation = .landscapeLeft
        app.launchArguments = [
            "-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN", "-ui-testing",
            "--ui-test-skip-onboarding", "--ui-test-batch-fixture", "-ui-testing-ipad"
        ]
        app.launch()
        return app
    }

    private func fixtureRow(_ app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: "sidebar.conversation.\(fixtureID)").firstMatch
    }

    private func circle(_ app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: "tasks.inline.circle.\(fixtureID)").firstMatch
    }

    /// Scroll only the sidebar list until the fixture row's frame is real
    /// AND inside both the list and the window. Returns the sidebar query
    /// for later in-place taps. Fails the test instead of pressing blind.
    @discardableResult
    private func realizeFixtureRow(_ app: XCUIApplication) -> XCUIElement {
        let sidebar = app.descendants(matching: .any)
            .matching(identifier: "sidebar.list").firstMatch
        XCTAssertTrue(sidebar.waitForExistence(timeout: 30), "the sidebar list must exist")
        let row = fixtureRow(app)
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
        return sidebar
    }

    /// Long-press the fixture row through its verified frame coordinates.
    private func openRowMenu(_ app: XCUIApplication) {
        realizeFixtureRow(app)
        let row = fixtureRow(app)
        let screen = app.windows.firstMatch.frame
        app.windows.firstMatch
            .coordinate(withNormalizedOffset: .zero)
            .withOffset(CGVector(dx: row.frame.midX - screen.minX, dy: row.frame.midY - screen.minY))
            .press(forDuration: 0.9)
    }

    private func menuButton(_ app: XCUIApplication, _ label: String) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "label == %@", label)).firstMatch
    }

    private func dismissMenu(_ app: XCUIApplication) {
        // Tap the navigation bar area (outside the popover) to close the menu
        // without touching a row.
        app.navigationBars.firstMatch.tap()
    }

    // MARK: - Ordinary row shape

    func testOrdinaryRowHasNoEllipsisAndNoCircles() {
        continueAfterFailure = false
        let app = launchApp()
        defer { app.terminate() }
        realizeFixtureRow(app)
        XCTAssertFalse(
            app.descendants(matching: .any)
                .matching(identifier: "sidebar.rowActions.\(fixtureID)")
                .firstMatch.exists,
            "corrected rows carry no trailing ellipsis control")
        XCTAssertFalse(circle(app).exists, "ordinary rows show no selection circles")
        keepScreenshot(app, name: "Sidebar ordinary rows without selection or More")
    }

    // MARK: - Menu vs selection interaction (binding)

    func testLongPressOpensMenuWithoutEnteringSelection() {
        continueAfterFailure = false
        let app = launchApp()
        defer { app.terminate() }
        openRowMenu(app)

        let pin = menuButton(app, "置顶")
        let multi = menuButton(app, "多选")
        XCTAssertTrue(pin.waitForExistence(timeout: 10),
                      "the long press must open the native menu with Pin")
        XCTAssertTrue(multi.exists, "the long-press menu must offer Multi-select")
        XCTAssertFalse(circle(app).exists,
                       "the long press itself must never enter selection — only Multi-select does")
        keepScreenshot(app, name: "Sidebar long press opens native menu")
        dismissMenu(app)
        XCTAssertFalse(circle(app).exists, "dismissing the menu leaves no selection state")
    }

    func testMultiSelectEntersInlineModeTogglesAndDoneRestores() {
        continueAfterFailure = false
        let app = launchApp()
        defer { app.terminate() }

        openRowMenu(app)
        let multi = menuButton(app, "多选")
        XCTAssertTrue(multi.waitForExistence(timeout: 10), "the menu must offer Multi-select")
        multi.tap()

        // Mode open with the invoking row selected: circle + header appear.
        let circle = self.circle(app)
        XCTAssertTrue(circle.waitForExistence(timeout: 10),
                      "Multi-select must reveal the inline circle for the invoking row")
        XCTAssertEqual(circle.label, "已选择", "the invoking row starts selected")
        XCTAssertTrue(app.descendants(matching: .any)
            .matching(identifier: "tasks.inline.count").firstMatch
            .waitForExistence(timeout: 10), "the header count must show")
        XCTAssertTrue(app.buttons["tasks.inline.selectAll"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["tasks.inline.done"].exists)
        keepScreenshot(app, name: "Sidebar inline multiselect with compact controls")

        // A row tap toggles WITHOUT navigating: tap the SAME verified-frame
        // coordinate as the long press, then assert the circle label flips.
        func tapFixtureRow() {
            realizeFixtureRow(app)
            let row = fixtureRow(app)
            let screen = app.windows.firstMatch.frame
            app.windows.firstMatch
                .coordinate(withNormalizedOffset: .zero)
                .withOffset(CGVector(dx: row.frame.midX - screen.minX, dy: row.frame.midY - screen.minY))
                .tap()
        }
        tapFixtureRow()
        XCTAssertEqual(circle.label, "未选择", "tapping the row deselects it")
        tapFixtureRow()
        XCTAssertEqual(circle.label, "已选择", "tapping again re-selects it")

        // Done exits and restores the ordinary rows.
        app.buttons["tasks.inline.done"].tap()
        let deadline = Date().addingTimeInterval(10)
        while circle.exists && Date() < deadline {
            app.swipeDown()
            Thread.sleep(forTimeInterval: 0.2)
        }
        XCTAssertFalse(circle.exists, "Done must remove the inline circles")
        XCTAssertFalse(app.descendants(matching: .any)
            .matching(identifier: "tasks.inline.count").firstMatch.exists,
            "Done must remove the selection header")
        // Ordinary rows return: the long press opens the menu again, not a circle.
        openRowMenu(app)
        XCTAssertTrue(menuButton(app, "多选").waitForExistence(timeout: 10))
        dismissMenu(app)
    }

    // MARK: - Durable pin flip through the real App UI

    func testPinMenuItemFlipsWithinTheSameMenuSession() {
        continueAfterFailure = false
        let app = launchApp()
        defer { app.terminate() }

        // Pin: the menu starts with 置顶 (fixture row is unpinned on a fresh
        // database; the run leaves it unpinned again for the next).
        openRowMenu(app)
        let pin = menuButton(app, "置顶")
        XCTAssertTrue(pin.waitForExistence(timeout: 10), "an ordinary row must offer Pin")
        pin.tap()

        // Reopen: the same row now offers 取消置顶 — the pin persisted to the
        // conversation row and the menu rebuilt from real state.
        openRowMenu(app)
        let unpin = menuButton(app, "取消置顶")
        XCTAssertTrue(unpin.waitForExistence(timeout: 10),
                      "a pinned row's menu must flip to Unpin")
        unpin.tap()

        // And back: unpinning restores the ordinary Pin item (normal sort).
        openRowMenu(app)
        XCTAssertTrue(menuButton(app, "置顶").waitForExistence(timeout: 10),
                      "cancel pin must restore the ordinary menu state")
        dismissMenu(app)
    }
    private func keepScreenshot(_ app: XCUIApplication, name: String) {
        let attachment = XCTAttachment(screenshot: XCUIDevice.shared.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

}
