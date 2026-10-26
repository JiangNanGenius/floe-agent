// FloeAgentUITests — bulk task management acceptance on OWNED synthetic tasks.
//
// The canonical management surface (ConversationBatchManagementView) is driven
// end to end: multi-select, archive with confirmation, the archived slice,
// restore, archive again after a restore, and restore-then-delete — all in one
// open screen. Only the three fixed synthetic tasks seeded by
// `--ui-test-task-management-fixture` are ever selected, so no real user
// conversation can be archived or deleted by this test.
//
// The archive→restore→archive and restore→delete sequences are the regression
// for the review finding that a lifetime "completed" set silently excluded a
// task from every later, separately confirmed operation.

import XCTest

final class TaskBulkManagementUITests: XCTestCase {
    private let titleA = "任务管理测试-A"
    private let titleB = "任务管理测试-B"
    private let titleC = "任务管理测试-C"

    func testBulkManagementArchiveRestoreRearrangeAndDeleteSyntheticTasks() throws {
        continueAfterFailure = false
        let app = launchFixtureApp()
        defer { app.terminate() }

        openManagement(app)

        // The fixture seeds three active synthetic tasks.
        XCTAssertTrue(waitForRow(app, title: titleA, exists: true), "synthetic task A must be listed")
        XCTAssertTrue(waitForRow(app, title: titleB, exists: true), "synthetic task B must be listed")
        XCTAssertTrue(waitForRow(app, title: titleC, exists: true), "synthetic task C must be listed")

        // 1. Multi-select A + B and archive them through the real confirmation.
        tapRow(app, title: titleA)
        tapRow(app, title: titleB)
        XCTAssertTrue(app.staticTexts["已选 2"].waitForExistence(timeout: 5),
                      "the selected count must reflect the multi-selection")
        tapAndConfirm(app, action: "tasks.manage.archive", confirmation: "停止并归档")

        XCTAssertTrue(waitForRow(app, title: titleA, exists: false),
                      "an archived task leaves the active slice")
        XCTAssertTrue(waitForRow(app, title: titleB, exists: false),
                      "an archived task leaves the active slice")
        XCTAssertTrue(waitForRow(app, title: titleC, exists: true),
                      "an unselected task is never touched")

        // 2. The archived slice lists both, and only those were archived.
        selectFilter(app, "已归档")
        XCTAssertTrue(waitForRow(app, title: titleA, exists: true), "A must be restorable from the archive")
        XCTAssertTrue(waitForRow(app, title: titleB, exists: true), "B must be restorable from the archive")

        // 3. Restore A from the archive.
        tapRow(app, title: titleA)
        tapAndConfirm(app, action: "tasks.manage.restore", confirmation: nil)
        XCTAssertTrue(waitForRow(app, title: titleA, exists: false),
                      "a restored task leaves the archived slice")
        XCTAssertTrue(waitForRow(app, title: titleB, exists: true),
                      "restoring A must not touch B")

        // 4. archive → restore → ARCHIVE AGAIN in the same open screen. The
        // lifetime-exclusion bug skipped this second archive.
        selectFilter(app, "任务")
        XCTAssertTrue(waitForRow(app, title: titleA, exists: true), "A is active again after the restore")
        tapRow(app, title: titleA)
        tapAndConfirm(app, action: "tasks.manage.archive", confirmation: "停止并归档")
        XCTAssertTrue(waitForRow(app, title: titleA, exists: false),
                      "the re-archive of a restored task must really run")

        // 5. restore → DELETE for the same identity.
        selectFilter(app, "已归档")
        tapRow(app, title: titleA)
        tapAndConfirm(app, action: "tasks.manage.restore", confirmation: nil)
        XCTAssertTrue(waitForRow(app, title: titleA, exists: false))
        selectFilter(app, "任务")
        XCTAssertTrue(waitForRow(app, title: titleA, exists: true))
        tapRow(app, title: titleA)
        tapAndConfirm(app, action: "tasks.manage.delete", confirmation: "删除")
        XCTAssertTrue(waitForRow(app, title: titleA, exists: false),
                      "delete after restore must really run for the same identity")

        // 6. The other synthetic tasks are intact: C stays active, B stays
        // archived.
        XCTAssertTrue(waitForRow(app, title: titleC, exists: true),
                      "deleting A must not delete the unselected synthetic task C")
        selectFilter(app, "已归档")
        XCTAssertTrue(waitForRow(app, title: titleB, exists: true),
                      "deleting A must not delete the archived task B")
        capture(app, name: "task-bulk-management-final")
    }

    // MARK: - Helpers

    private func launchFixtureApp() -> XCUIApplication {
        let app = XCUIApplication()
        app.terminate()
        XCUIDevice.shared.orientation = .landscapeLeft
        app.launchArguments = [
            "-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN", "-ui-testing",
            "--ui-test-skip-onboarding", "--ui-test-task-management-fixture", "-ui-testing-ipad"
        ]
        app.launch()
        return app
    }

    private func openManagement(_ app: XCUIApplication) {
        // The sidebar and Task Center now select inline. This suite keeps
        // exercising the dedicated data-management page and its archive slice.
        let settings = app.descendants(matching: .any)
            .matching(identifier: "sidebar.settings").firstMatch
        XCTAssertTrue(settings.waitForExistence(timeout: 30))
        settings.tap()
        let data = app.descendants(matching: .any)
            .matching(identifier: "settings.section.dataManagement").firstMatch
        XCTAssertTrue(data.waitForExistence(timeout: 15))
        for _ in 0..<5 where !data.isHittable {
            let sections = app.descendants(matching: .any)
                .matching(identifier: "settings.sections").firstMatch
            XCTAssertTrue(sections.exists)
            sections.swipeUp()
        }
        XCTAssertTrue(data.isHittable)
        data.tap()
        let manage = app.staticTexts["管理任务"].firstMatch
        XCTAssertTrue(manage.waitForExistence(timeout: 15), "the dedicated management entry must remain available")
        manage.tap()
        XCTAssertTrue(app.buttons["tasks.manage.selectAll"].waitForExistence(timeout: 30),
                      "the canonical management screen must open")
    }

    private func row(_ app: XCUIApplication, title: String) -> XCUIElement {
        let predicate = NSPredicate(
            format: "identifier BEGINSWITH %@ AND label CONTAINS %@",
            "tasks.batch.row.", title
        )
        return app.buttons.matching(predicate).firstMatch
    }

    /// A bounded reveal: the management list can need a short scroll when the
    /// seeded tasks sort below other fixtures.
    private func waitForRow(_ app: XCUIApplication, title: String, exists: Bool,
                            file: StaticString = #filePath, line: UInt = #line) -> Bool {
        let element = row(app, title: title)
        let deadline = Date().addingTimeInterval(20)
        while Date() < deadline {
            if element.exists == exists { return true }
            if exists, app.scrollViews.firstMatch.exists { app.scrollViews.firstMatch.swipeUp() }
            Thread.sleep(forTimeInterval: 0.3)
        }
        return element.exists == exists
    }

    private func tapRow(_ app: XCUIApplication, title: String,
                        file: StaticString = #filePath, line: UInt = #line) {
        let element = row(app, title: title)
        XCTAssertTrue(element.waitForExistence(timeout: 10), "row \(title) must exist", file: file, line: line)
        element.tap()
    }

    private func selectFilter(_ app: XCUIApplication, _ label: String,
                              file: StaticString = #filePath, line: UInt = #line) {
        let option = app.buttons[label]
        XCTAssertTrue(option.waitForExistence(timeout: 10), "filter \(label) must exist", file: file, line: line)
        option.tap()
        Thread.sleep(forTimeInterval: 0.6)
    }

    /// Runs a bottom-bar action. When `confirmation` is set the real
    /// confirmation dialog must appear and its confirm button is tapped. The
    /// dialog scope is used because a label like "删除" also exists on the
    /// bottom bar (ambiguous unscoped query).
    private func tapAndConfirm(_ app: XCUIApplication, action: String, confirmation: String?,
                               file: StaticString = #filePath, line: UInt = #line) {
        let button = app.buttons[action]
        XCTAssertTrue(button.waitForExistence(timeout: 10), "\(action) must exist", file: file, line: line)
        button.tap()
        if let confirmation {
            let inSheet = app.sheets.buttons[confirmation].firstMatch
            let inAlert = app.alerts.buttons[confirmation].firstMatch
            let confirm = inSheet.waitForExistence(timeout: 3) ? inSheet : inAlert
            XCTAssertTrue(confirm.waitForExistence(timeout: 10),
                          "the \(confirmation) confirmation must appear", file: file, line: line)
            confirm.tap()
        }
        Thread.sleep(forTimeInterval: 0.8)
    }

    private func capture(_ app: XCUIApplication, name: String) {
        let image = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        image.name = name
        image.lifetime = .keepAlways
        add(image)
    }
}
