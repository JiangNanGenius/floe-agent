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
// Presentation correction (2026-10-27, second binding user note): the open
// mode must look like the platform's own editing mode, not a custom strip.
// The controls therefore live in the sidebar column's REAL navigation bar —
// 完成 leading, 已选 N as the bar's principal status, 全选 plus one native
// actions menu trailing — and the batch commands are system menu rows with
// SF-Symbol icons. These tests assert that grouping (bar containment, count
// label, disabled/scoped menu rows), not just the identifiers, so a
// regression back to inserted bars fails here as well as in review.
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

    /// Taps the verified fixture-row frame (window coordinates). Inside the
    /// mode this must toggle WITHOUT navigating.
    private func tapFixtureRow(_ app: XCUIApplication) {
        realizeFixtureRow(app)
        let row = fixtureRow(app)
        let screen = app.windows.firstMatch.frame
        app.windows.firstMatch
            .coordinate(withNormalizedOffset: .zero)
            .withOffset(CGVector(dx: row.frame.midX - screen.minX, dy: row.frame.midY - screen.minY))
            .tap()
    }

    private func selectedCountStatus(_ app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: "tasks.inline.count").firstMatch
    }

    /// The batch-actions control is a native bar Menu: match its identifier
    /// when the platform forwards it, otherwise its bar-button label (system
    /// menu surfaces sometimes expose only the label). Either way it must be
    /// a button of the navigation bar.
    private func batchActionsControl(_ app: XCUIApplication) -> XCUIElement {
        let byIdentifier = app.navigationBars.buttons
            .matching(identifier: "tasks.inline.actions").firstMatch
        if byIdentifier.exists { return byIdentifier }
        return app.navigationBars.buttons.matching(
            NSPredicate(format: "label == %@ OR label == %@", "操作", "Actions")).firstMatch
    }

    /// The editing controls must be real navigation-bar items: each of them
    /// renders INSIDE a navigation bar, which is exactly what an inserted
    /// custom strip above/below the list can never satisfy.
    private func assertNativeEditingBar(_ app: XCUIApplication) {
        let bars = app.navigationBars.allElementsBoundByIndex
        XCTAssertFalse(bars.isEmpty, "the sidebar must expose its real navigation bar")
        let sidebarFrame = app.descendants(matching: .any)
            .matching(identifier: "sidebar.list").firstMatch.frame
        let controls: [(String, XCUIElement)] = [
            ("done", app.navigationBars.buttons.matching(identifier: "tasks.inline.done").firstMatch),
            ("select-all", app.navigationBars.buttons.matching(identifier: "tasks.inline.selectAll").firstMatch),
            ("actions", batchActionsControl(app)),
        ]
        for (name, control) in controls {
            XCTAssertTrue(control.exists, "the native editing bar must expose \(name)")
            XCTAssertGreaterThanOrEqual(control.frame.midX, sidebarFrame.minX - 2,
                                        "\(name) belongs to the sidebar column")
            XCTAssertLessThanOrEqual(control.frame.midX, sidebarFrame.maxX + 2,
                                     "\(name) must not migrate into the conversation's bar")
            XCTAssertTrue(
                bars.contains { $0.frame.insetBy(dx: -2, dy: -2).contains(control.frame) },
                "\(name) must be a real navigation-bar item, not an inserted custom strip")
        }
        let count = selectedCountStatus(app)
        XCTAssertTrue(count.exists, "the bar must carry the selected-count status")
        XCTAssertGreaterThanOrEqual(count.frame.midX, sidebarFrame.minX - 2)
        XCTAssertLessThanOrEqual(count.frame.midX, sidebarFrame.maxX + 2,
                                 "the selection title belongs to the sidebar, not the detail")
        XCTAssertTrue(
            bars.contains { $0.frame.insetBy(dx: -2, dy: -2).contains(count.frame) },
            "the selected count must render as the bar's native title/status")
    }

    @discardableResult
    private func openBatchActions(_ app: XCUIApplication) -> XCUIElement {
        let actions = batchActionsControl(app)
        XCTAssertTrue(actions.waitForExistence(timeout: 10), "the editing bar must offer the actions menu")
        actions.tap()
        return actions
    }

    private func dismissMenu(_ app: XCUIApplication) {
        // Tap the navigation bar area (outside the popover) to close the menu
        // without touching a row, then wait for the animated popover to leave
        // the accessibility tree so the next row tap cannot land on it.
        let menuLabels = ["多选", "置顶", "取消置顶", "重命名", "移动到项目", "暂无项目", "归档", "删除"]
        func anyMenuRowVisible() -> Bool {
            menuLabels.contains { menuButton(app, $0).exists }
        }
        app.navigationBars.firstMatch.tap()
        let deadline = Date().addingTimeInterval(5)
        while anyMenuRowVisible() && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.1)
        }
        if anyMenuRowVisible() {
            app.navigationBars.firstMatch.tap()
            Thread.sleep(forTimeInterval: 0.3)
        }
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

        // Mode open with the invoking row selected: circle + native bar.
        let circle = self.circle(app)
        XCTAssertTrue(circle.waitForExistence(timeout: 10),
                      "Multi-select must reveal the inline circle for the invoking row")
        XCTAssertEqual(circle.label, "已选择", "the invoking row starts selected")
        let count = selectedCountStatus(app)
        XCTAssertTrue(count.waitForExistence(timeout: 10), "the editing bar must show the count")
        XCTAssertEqual(count.label, "已选 1", "the count is the bar's native status for real state")
        XCTAssertTrue(app.buttons["tasks.inline.selectAll"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["tasks.inline.done"].exists)
        // The platform's own editing chrome, not an inserted strip: Done,
        // Select-All, the actions menu and the count all render inside a
        // navigation bar of this column.
        assertNativeEditingBar(app)
        keepScreenshot(app, name: "Sidebar inline multiselect in the native editing bar")

        // A row tap toggles WITHOUT navigating: the same verified-frame
        // coordinate as the long press, then assert the circle label flips.
        tapFixtureRow(app)
        XCTAssertEqual(circle.label, "未选择", "tapping the row deselects it")
        XCTAssertEqual(count.label, "已选 0", "the native status follows the real selection")

        // Select-all lives in the same bar and selects every visible row.
        // Starting from an empty selection this is deterministic: the
        // fixture row itself is visible, so the count can never stay 0.
        app.navigationBars.buttons.matching(identifier: "tasks.inline.selectAll").firstMatch.tap()
        XCTAssertTrue(
            NSPredicate(format: "label MATCHES %@", "已选 [1-9][0-9]*").evaluate(with: count),
            "select-all must select at least the visible fixture row")
        XCTAssertEqual(circle.label, "已选择", "the visible fixture row is part of select-all")

        // Row toggling stays independent of select-all.
        tapFixtureRow(app)
        XCTAssertEqual(circle.label, "未选择", "toggling still applies after select-all")
        tapFixtureRow(app)
        XCTAssertEqual(circle.label, "已选择", "toggling back re-selects the row")

        // Done exits and restores the ordinary rows.
        app.navigationBars.buttons.matching(identifier: "tasks.inline.done").firstMatch.tap()
        let deadline = Date().addingTimeInterval(10)
        while circle.exists && Date() < deadline {
            app.swipeDown()
            Thread.sleep(forTimeInterval: 0.2)
        }
        XCTAssertFalse(circle.exists, "Done must remove the inline circles")
        XCTAssertFalse(count.exists, "Done must remove the selection status")
        XCTAssertFalse(
            app.navigationBars.buttons.matching(identifier: "tasks.inline.done").firstMatch.exists,
            "Done must restore the ordinary navigation bar")
        // Ordinary rows return: the long press opens the menu again, not a circle.
        openRowMenu(app)
        XCTAssertTrue(menuButton(app, "多选").waitForExistence(timeout: 10))
        dismissMenu(app)
    }

    // MARK: - Native batch actions menu (presentation correction)

    func testBatchActionsLiveInANativeScopedMenu() {
        continueAfterFailure = false
        let app = launchApp()
        defer { app.terminate() }

        openRowMenu(app)
        let multi = menuButton(app, "多选")
        XCTAssertTrue(multi.waitForExistence(timeout: 10), "the menu must offer Multi-select")
        multi.tap()
        XCTAssertTrue(circle(app).waitForExistence(timeout: 10))
        assertNativeEditingBar(app)

        // Exactly one row selected: archive/delete AND the single-item
        // rename/move commands, all as icon+label rows of a system menu.
        openBatchActions(app)
        XCTAssertTrue(menuButton(app, "归档").waitForExistence(timeout: 10),
                      "the actions menu must offer archive")
        XCTAssertTrue(menuButton(app, "删除").exists, "the actions menu must offer delete")
        XCTAssertTrue(menuButton(app, "重命名").exists,
                      "one selected row must offer rename")
        // Move needs a real project workspace; the fixture database seeds
        // none, so the honest disabled "no projects" row is the expected
        // native presentation here. Either form proves the command row.
        XCTAssertTrue(
            menuButton(app, "移动到项目").exists || menuButton(app, "暂无项目").exists,
            "one selected row must offer the move command (or its honest no-projects row)")
        keepScreenshot(app, name: "Sidebar native batch actions menu with icon labels")
        dismissMenu(app)

        // No selection: batch archive/delete stay present but disabled, and
        // the single-item commands disappear with the scope rule.
        tapFixtureRow(app)
        XCTAssertEqual(selectedCountStatus(app).label, "已选 0")
        openBatchActions(app)
        let archive = menuButton(app, "归档")
        XCTAssertTrue(archive.waitForExistence(timeout: 10),
                      "batch archive stays available for a later selection")
        XCTAssertFalse(archive.isEnabled, "batch archive must be disabled without a selection")
        XCTAssertFalse(menuButton(app, "重命名").exists,
                       "rename must not exist without exactly one selected row")
        XCTAssertFalse(menuButton(app, "移动到项目").exists,
                       "move must not exist without exactly one selected row")
        XCTAssertFalse(menuButton(app, "暂无项目").exists,
                       "the no-projects hint must not exist without exactly one selected row")
        dismissMenu(app)

        // Leave the surface exactly as it was for the next run.
        app.navigationBars.buttons.matching(identifier: "tasks.inline.done").firstMatch.tap()
        let deadline = Date().addingTimeInterval(10)
        while circle(app).exists && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.2)
        }
        XCTAssertFalse(circle(app).exists)
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
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

}
