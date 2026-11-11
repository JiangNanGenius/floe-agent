import XCTest

final class ToolboxLocationUITests: XCTestCase {
    @MainActor
    private func launch(_ extra: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--tool", "location", "--location-fixture", "-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN"] + extra
        app.launch()
        XCTAssertTrue(app.buttons["toolbox.location.start"].waitForExistence(timeout: 15))
        return app
    }

    @MainActor
    private func keepScreenshot(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    @MainActor
    private func reveal(_ target: XCUIElement, in app: XCUIApplication) {
        for _ in 0..<6 where !target.isHittable {
            let surface = app.scrollViews.firstMatch
            let from = surface.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.90))
            let to = surface.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.35))
            from.press(forDuration: 0.1, thenDragTo: to)
        }
    }

    @MainActor
    func testLocationMapShowsLabeledFixtureAndControls() {
        let app = launch()
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "合成界面样例")).firstMatch.exists)
        XCTAssertTrue(app.staticTexts["toolbox.location.latitude"].exists)
        XCTAssertTrue(app.staticTexts["toolbox.location.longitude"].exists)
        let altitude = app.staticTexts["toolbox.location.altitude"]
        let accuracy = app.staticTexts["toolbox.location.horizontalAccuracy"]
        XCTAssertTrue(altitude.exists && accuracy.exists)
        XCTAssertEqual(altitude.frame.minY, accuracy.frame.minY, accuracy: 2)
        XCTAssertTrue(app.buttons["toolbox.location.recenter"].exists)
        let map = app.descendants(matching: .any).matching(identifier: "toolbox.location.map").firstMatch
        XCTAssertTrue(map.exists)
        XCTAssertFalse(map.frame.intersects(app.buttons["toolbox.location.recenter"].frame))
        keepScreenshot(app, "location-tablet-light")
        reveal(app.buttons["toolbox.location.savePlace"], in: app)
        keepScreenshot(app, "location-data-grouped")
        app.terminate()
    }

    @MainActor
    func testLocationDarkCompactLayoutKeepsControlsReachable() {
        let app = launch(["--compact", "--dark", "--large-text"])
        let start = app.buttons["toolbox.location.start"]
        reveal(start, in: app)
        XCTAssertTrue(start.isHittable)
        keepScreenshot(app, "location-compact-dark-large-text")
        app.terminate()
    }

    @MainActor
    func testSavedPlaceSurvivesAppRelaunch() {
        let app = launch(["--compact"])
        let placeName = "Toolbox UI " + UUID().uuidString.prefix(8)
        let save = app.buttons["toolbox.location.savePlace"]
        reveal(save, in: app)
        XCTAssertTrue(save.isHittable)
        save.tap()
        let field = app.alerts.textFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 3))
        field.tap()
        field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: 80) + placeName)
        app.alerts.buttons["保存"].tap()
        let predicate = NSPredicate(format: "label BEGINSWITH %@", placeName)
        XCTAssertTrue(app.buttons.matching(predicate).firstMatch.waitForExistence(timeout: 5))
        app.terminate()
        app.launch()
        let place = app.buttons.matching(predicate).firstMatch
        reveal(place, in: app)
        XCTAssertTrue(place.waitForExistence(timeout: 5))
        keepScreenshot(app, "location-saved-place-reopened")
        app.terminate()
    }
}
