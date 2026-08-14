import XCTest

final class SetupGuideUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testFirstLaunchCanSkipAndReopenSetup() throws {
        let app = XCUIApplication()
        app.launchArguments = [
            "--ui-test-reset-onboarding",
            "-AppleLanguages", "(zh-Hans)",
            "-AppleLocale", "zh_CN"
        ]
        app.launch()

        let skip = app.buttons["setup.skip"]
        XCTAssertTrue(skip.waitForExistence(timeout: 8))
        skip.tap()

        let reopen = app.buttons["setup.open"]
        XCTAssertTrue(reopen.waitForExistence(timeout: 5))
        reopen.tap()
        XCTAssertTrue(skip.waitForExistence(timeout: 5))
    }

    @MainActor
    func testPullDownDismissalPersistsSkippedState() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-test-reset-onboarding"]
        app.launch()
        XCTAssertTrue(app.buttons["setup.skip"].waitForExistence(timeout: 8))

        app.swipeDown(velocity: .fast)
        XCTAssertTrue(app.buttons["setup.open"].waitForExistence(timeout: 5))

        app.terminate()
        app.launchArguments = []
        app.launch()
        XCTAssertFalse(app.buttons["setup.skip"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.buttons["setup.open"].exists)
    }
}
