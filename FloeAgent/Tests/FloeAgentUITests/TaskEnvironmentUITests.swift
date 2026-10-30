import XCTest
import UIKit

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
        // The preserved sidebar can grow past the realized window. Scroll the
        // native sidebar list only, then use the row's verified frame.
        let sidebar = app.descendants(matching: .any)
            .matching(identifier: "sidebar.list").firstMatch
        XCTAssertTrue(sidebar.waitForExistence(timeout: 30))
        let row = app.descendants(matching: .any)
            .matching(identifier: "sidebar.conversation.4C19EFD3-C19E-450F-8E5A-306000000001").firstMatch
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
        XCTAssertTrue(rowIsVisible(), "the synthetic task must be reachable in the sidebar")
        let screen = app.windows.firstMatch.frame
        app.windows.firstMatch.coordinate(withNormalizedOffset: .zero)
            .withOffset(CGVector(dx: row.frame.midX - screen.minX,
                                 dy: row.frame.midY - screen.minY))
            .tap()
        app.buttons["thread.inspector.menu"].tap()
        let entry = app.buttons["thread.taskEnvironment.menu"]
        XCTAssertTrue(entry.waitForExistence(timeout: 10)); entry.tap()
        // This synthetic task starts without a binding. Assert the unbound
        // branch explicitly and prove no failure is being mistaken for state.
        let unbound = app.staticTexts["尚未选择运行位置"].firstMatch
        let current = app.descendants(matching: .any)
            .matching(identifier: "task.environment.current").firstMatch
        XCTAssertTrue(unbound.waitForExistence(timeout: 10),
                      "the synthetic task must start without an environment binding")
        XCTAssertFalse(current.exists, "the initial sheet must not already show a bound environment")
        XCTAssertFalse(app.staticTexts["无法完成"].exists)
        XCTAssertFalse(app.staticTexts["Something went wrong"].exists)
        let local = app.buttons["task.environment.choice.local"]
        XCTAssertTrue(local.waitForExistence(timeout: 15)); local.tap()
        app.buttons["task.environment.check"].tap()
        // The form is a lazy list: the preview and optional-loss rows can sit
        // below the realized window. Scroll in bounded steps, accept the
        // explicit loss when the product requires it, then reach Start.
        let start = app.buttons["task.environment.start"]
        let losses = app.switches["task.environment.acceptLosses"]
        var sawLossToggle = false
        for _ in 0..<18 {
            if losses.exists { sawLossToggle = true }
            if start.exists { break }
            app.swipeUp()
        }
        if (start.exists && !start.isEnabled) || sawLossToggle || losses.exists {
            XCTAssertTrue(bringIntoView(losses, in: app), "loss acceptance must be reachable")
            let value = losses.value as? String
            if value == "0" || value == "off" || value == nil { losses.tap() }
        }
        XCTAssertTrue(bringIntoView(start, in: app), "start must be reachable after checking")
        XCTAssertTrue(start.isEnabled, "start stays disabled after the destination check")
        let before = XCTAttachment(screenshot: app.screenshot()); before.name = "Native task environment preflight"; before.lifetime = .keepAlways; add(before)
        start.tap()
        for _ in 0..<12 where !current.exists { app.swipeDown() }
        XCTAssertTrue(current.waitForExistence(timeout: 15),
                      "Start must commit a real environment binding")
        XCTAssertFalse(unbound.exists, "the unbound explanation must disappear after Start")
        XCTAssertFalse(app.staticTexts["无法完成"].exists)
        XCTAssertFalse(app.staticTexts["Something went wrong"].exists)
        XCTAssertFalse(app.staticTexts["正在下载运行环境"].exists)
        XCTAssertFalse(current.label.isEmpty)
        XCTAssertTrue(current.label.contains("Linux"),
                      "the committed binding must be the selected local environment")
        XCTAssertFalse(current.label.contains("远程") || current.label.contains("Remote"),
                       "a remote environment is not the selected local binding")
        let committedLabel = current.label
        app.buttons["task.environment.done"].tap()
        app.buttons["thread.inspector.menu"].tap(); app.buttons["thread.taskEnvironment.menu"].tap()
        XCTAssertTrue(current.waitForExistence(timeout: 10))
        XCTAssertEqual(current.label, committedLabel,
                       "the saved environment must survive sheet reconstruction")
        let after = XCTAttachment(screenshot: app.screenshot()); after.name = "Saved task environment survives sheet reconstruction"; after.lifetime = .keepAlways; add(after)
    }

    /// The sheet's Form materializes rows lazily, so a control below the
    /// viewport may not exist in the accessibility tree yet. Scroll in both
    /// directions in bounded steps and verify the actual frame.
    private func bringIntoView(_ element: XCUIElement, in app: XCUIApplication,
                               maxSwipes: Int = 16) -> Bool {
        if element.exists && element.isHittable { return true }
        let window = app.windows.firstMatch.frame
        let above = element.exists && element.frame.midY < window.midY
        func scroll(up: Bool) -> Bool {
            for _ in 0..<maxSwipes {
                if up { app.swipeUp() } else { app.swipeDown() }
                if element.exists && element.isHittable { return true }
            }
            return element.exists && element.isHittable
        }
        if above { return scroll(up: false) || scroll(up: true) }
        return scroll(up: true) || scroll(up: false)
    }
}
