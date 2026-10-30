import XCTest

@MainActor
final class TaskEnvironmentUITests: XCTestCase {
    func testChooseInitialLocationWithoutStartingDownloadAndReopen() {
        continueAfterFailure = false
        let app = XCUIApplication()
        let common = ["-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN", "-ui-testing", "-ui-testing-ipad", "--ui-test-skip-onboarding"]
        app.launchArguments = common + ["--ui-test-task-environment"]
        app.launch()
        defer {
            app.terminate()
            app.launchArguments = common + ["--ui-test-task-environment-cleanup"]
            app.launch()
            XCTAssertTrue(app.buttons["globalSearch.open"].waitForExistence(timeout: 30))
            app.terminate()
        }
        let row = app.descendants(matching: .any).matching(identifier: "sidebar.conversation.4C19EFD3-C19E-450F-8E5A-306000000001").firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 30)); row.tap()
        app.buttons["thread.inspector.menu"].tap()
        let entry = app.buttons["thread.taskEnvironment.menu"]
        XCTAssertTrue(entry.waitForExistence(timeout: 10)); entry.tap()
        let local = app.buttons["task.environment.choice.local"]
        XCTAssertTrue(local.waitForExistence(timeout: 15)); local.tap()
        app.buttons["task.environment.check"].tap()
        let start = app.buttons["task.environment.start"]
        XCTAssertTrue(start.waitForExistence(timeout: 20))
        let losses = app.switches["task.environment.acceptLosses"]
        if losses.exists, (losses.value as? String) == "0" { losses.tap() }
        XCTAssertTrue(start.isEnabled)
        for _ in 0..<6 where !start.isHittable { app.swipeUp() }
        XCTAssertTrue(start.isHittable)
        let before = XCTAttachment(screenshot: app.screenshot()); before.name = "Native task environment preflight"; before.lifetime = .keepAlways; add(before)
        start.tap()
        let current = app.descendants(matching: .any).matching(identifier: "task.environment.current").firstMatch
        XCTAssertTrue(current.waitForExistence(timeout: 15))
        XCTAssertFalse(app.staticTexts["正在下载运行环境"].exists)
        app.buttons["task.environment.done"].tap()
        app.buttons["thread.inspector.menu"].tap(); app.buttons["thread.taskEnvironment.menu"].tap()
        XCTAssertTrue(current.waitForExistence(timeout: 10))
        let after = XCTAttachment(screenshot: app.screenshot()); after.name = "Saved task environment survives sheet reconstruction"; after.lifetime = .keepAlways; add(after)
    }
}
