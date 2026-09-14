import XCTest
final class ManagementUITests: XCTestCase {
    private func capture(_ app: XCUIApplication, name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
    func testStreamingPreviewKeepsHeightAndPreviousRoundCollapses() {
        let app = XCUIApplication()
        app.launchArguments = ["--thread", "-AppleLanguages", "(zh-Hans)"]
        app.launch()
        let reasoning = app.buttons["reasoning.expand"]
        XCTAssertTrue(reasoning.waitForExistence(timeout: 20))
        let height = reasoning.frame.height
        for _ in 0..<4 {
            app.buttons["fixture.reasoningFragment"].tap()
            XCTAssertEqual(reasoning.frame.height, height, accuracy: 1)
        }
        app.buttons["fixture.nextRound"].tap()
        XCTAssertFalse(app.staticTexts["workspace.readFile"].exists)
        capture(app, name: "previous-round-auto-collapsed")
    }
    func testLanguagePackageNavigationShowsSelectedEnvironment() {
        let app = XCUIApplication()
        app.launchArguments = ["-AppleLanguages", "(zh-Hans)"]
        app.launch()
        let project = app.buttons.containing(.staticText, identifier: "Floe 项目").firstMatch
        XCTAssertTrue(project.waitForExistence(timeout: 20))
        project.tap()
        let python = app.buttons["Python · PyPI"]
        XCTAssertTrue(python.waitForExistence(timeout: 10))
        capture(app, name: "environment-language-managers")
        python.tap()
        XCTAssertTrue(app.navigationBars["Python · PyPI"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.textFields.firstMatch.exists)
        capture(app, name: "python-management-fixture-runtime-unavailable")
    }
    func testCollapsedBatchStaysCollapsedWhenToolArrives() {
        let app = XCUIApplication()
        app.launchArguments = ["--thread", "-AppleLanguages", "(zh-Hans)"]
        app.launch()
        let toggle = app.buttons["thread.steps.toggle"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 20))
        XCTAssertTrue(app.staticTexts["workspace.readFile"].exists)
        capture(app, name: "thread-expanded")
        toggle.tap()
        XCTAssertFalse(app.staticTexts["workspace.readFile"].exists)
        app.buttons["fixture.append"].tap()
        XCTAssertTrue(app.staticTexts["3 个工具调用"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["video.transcode"].exists)
        XCTAssertFalse(app.staticTexts["workspace.readFile"].exists)
        XCTAssertEqual(toggle.value as? String, "已折叠")
        capture(app, name: "thread-folded-active")
        toggle.tap()
        XCTAssertTrue(app.staticTexts["workspace.readFile"].waitForExistence(timeout: 5))
    }
    func testAppearanceChoicesAndThinkingDisclosure() {
        let app = XCUIApplication()
        app.launchArguments = ["--appearance", "-AppleLanguages", "(zh-Hans)"]
        app.launch()
        XCTAssertTrue(app.navigationBars["通用"].waitForExistence(timeout: 20))
        for label in ["夜间", "日间", "自动"] {
            let choice = app.segmentedControls.buttons[label]
            choice.tap()
            let selected = XCTNSPredicateExpectation(predicate: NSPredicate(format: "isSelected == true"), object: choice)
            XCTAssertEqual(XCTWaiter.wait(for: [selected], timeout: 5), .completed)
            capture(app, name: "appearance-" + label)
        }
        app.terminate()
        app.launchArguments = ["--thread", "-AppleLanguages", "(zh-Hans)"]
        app.launch()
        let reasoning = app.buttons["reasoning.expand"]
        XCTAssertTrue(reasoning.waitForExistence(timeout: 20))
        reasoning.tap()
        XCTAssertTrue(app.buttons["复制"].exists)
    }
}
