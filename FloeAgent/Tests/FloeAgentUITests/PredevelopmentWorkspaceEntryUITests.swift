// SPDX-License-Identifier: MPL-2.0
import XCTest

@MainActor
final class PredevelopmentWorkspaceEntryUITests: XCTestCase {
    private func application() -> XCUIApplication {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .landscapeLeft
        let app = XCUIApplication(bundleIdentifier: "org.floeagent.ios")
        app.launchArguments = ["-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN",
                               "-ui-testing", "-ui-testing-ipad", "--ui-test-skip-onboarding"]
        return app
    }

    func testSpaceOffersGameProjectCreation() {
        let app = application()
        app.launch()
        let space = app.collectionViews["sidebar.list"].cells.containing(.staticText, identifier: "sidebar.notes").firstMatch
        XCTAssertTrue(space.waitForExistence(timeout: 25))
        space.tap()
        let files = app.segmentedControls["space.sections"].buttons["文件"]
        XCTAssertTrue(files.waitForExistence(timeout: 15))
        files.tap()
        let new = app.buttons["space.new"]
        XCTAssertTrue(new.waitForExistence(timeout: 10))
        new.tap()
        app.buttons["space.new.game"].tap()
        let title = app.textFields["game.new.title"]
        XCTAssertTrue(title.waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["创建"].isEnabled)
        app.buttons["取消"].tap()
        XCTAssertTrue(title.waitForNonExistence(timeout: 10))
    }

    func testSavedCADDrawingOpensAnIndependentBuildingProject() {
        let app = application()
        app.launchEnvironment["FLOE_BUILDING_FIXTURE_ID"] = UUID().uuidString
        app.launchArguments += ["--ui-test-cad-fixture", "--ui-test-cad-building", "--ui-test-cad-building-reopen"]
        app.launch()
        let project = app.buttons["cad.building.project"]
        XCTAssertTrue(project.waitForExistence(timeout: 25))
        project.tap()
        let create = app.buttons["建立工程"]
        XCTAssertTrue(create.waitForExistence(timeout: 10))
        create.tap()
        let close = app.buttons["building.close"]
        XCTAssertTrue(close.waitForExistence(timeout: 30))
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "建筑工程"
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
