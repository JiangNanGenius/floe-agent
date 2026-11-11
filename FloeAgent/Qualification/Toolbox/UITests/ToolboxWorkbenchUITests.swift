import XCTest

final class ToolboxWorkbenchUITests: XCTestCase {
    @MainActor
    private func open(_ tool: String, anchor: String, extra: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--tool", tool, "-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN"] + extra
        app.launch()
        XCTAssertTrue(app.descendants(matching: .any).matching(identifier: anchor).firstMatch.waitForExistence(timeout: 15), tool)
        return app
    }

    @MainActor
    private func capture(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    @MainActor
    func testFirstBatchWorkbenchesOnTablet() {
        XCUIDevice.shared.orientation = .landscapeLeft
        defer { XCUIDevice.shared.orientation = .portrait }
        let tools = [("level", "toolbox.level.bubble"), ("motion", "toolbox.motion.start"),
                     ("compass", "toolbox.compass.dial"), ("ruler", "toolbox.ruler.canvas"),
                     ("measure", "toolbox.measure.start"), ("calculator", "toolbox.calculator.expression")]
        for (tool, anchor) in tools {
            let app = open(tool, anchor: anchor)
            XCTAssertFalse(app.staticTexts["Existing App tool"].exists)
            capture(app, tool + "-tablet-landscape")
            app.terminate()
        }
    }

    @MainActor
    func testCalculatorEvaluatesAndConvertsInCompactLayout() {
        XCUIDevice.shared.orientation = .portrait
        let app = open("calculator", anchor: "toolbox.calculator.expression", extra: ["--compact"])
        let expression = app.textFields["toolbox.calculator.expression"].exists
            ? app.textFields["toolbox.calculator.expression"] : app.textViews["toolbox.calculator.expression"]
        expression.tap()
        expression.typeText("sqrt(81)+3^2")
        app.buttons["toolbox.calculator.evaluate"].tap()
        XCTAssertEqual(app.staticTexts["toolbox.calculator.result"].label, "18")
        capture(app, "calculator-compact-result")
        app.segmentedControls.buttons["单位换算"].tap()
        XCTAssertTrue(app.textFields["toolbox.converter.input"].waitForExistence(timeout: 5))
        capture(app, "converter-compact")
        app.terminate()
    }

    @MainActor
    func testLevelRemainsReadableInCompactDarkLargeType() {
        let app = open("level", anchor: "toolbox.level.bubble", extra: ["--compact", "--dark", "--large-text"])
        XCTAssertTrue(app.staticTexts["toolbox.level.unavailable"].exists || app.buttons["toolbox.level.pause"].exists)
        capture(app, "level-compact-dark-large-text")
        app.terminate()
    }

    @MainActor
    func testConverterStartsWithValidUnitsAndSwapsItsActualSelection() {
        let app = open("calculator", anchor: "toolbox.calculator.expression", extra: ["--compact"])
        defer { app.terminate() }
        app.segmentedControls.buttons["单位换算"].tap()
        let from = app.buttons["toolbox.converter.from"]
        let to = app.buttons["toolbox.converter.to"]
        XCTAssertTrue(from.waitForExistence(timeout: 5))
        let originalFrom = from.label
        let originalTo = to.label
        XCTAssertTrue(originalFrom.contains("mm"), originalFrom)
        XCTAssertTrue(originalTo.contains("cm"), originalTo)
        XCTAssertEqual(app.staticTexts["toolbox.converter.result"].label, "0.1")
        app.buttons["toolbox.converter.swap"].tap()
        XCTAssertTrue(from.label.contains("cm"), from.label)
        XCTAssertTrue(to.label.contains("mm"), to.label)
        XCTAssertEqual(app.staticTexts["toolbox.converter.result"].label, "10")
        app.buttons["toolbox.converter.category"].tap()
        app.buttons["温度"].tap()
        XCTAssertTrue(from.label.contains("°C"), from.label)
        XCTAssertTrue(to.label.contains("°F"), to.label)
        XCTAssertEqual(app.staticTexts["toolbox.converter.result"].label, "33.8")
        capture(app, "converter-valid-initial-units-swap-and-category")
    }

    @MainActor
    func testRulerPlacesSeparateHandlesAndDragsInCanvasCoordinates() {
        XCUIDevice.shared.orientation = .landscapeLeft
        defer { XCUIDevice.shared.orientation = .portrait }
        let app = open("ruler", anchor: "toolbox.ruler.canvas")
        defer { app.terminate() }
        let a = app.descendants(matching: .any).matching(identifier: "toolbox.ruler.handle.a").firstMatch
        let b = app.descendants(matching: .any).matching(identifier: "toolbox.ruler.handle.b").firstMatch
        XCTAssertTrue(a.waitForExistence(timeout: 5))
        XCTAssertTrue(b.waitForExistence(timeout: 5))
        XCTAssertGreaterThan(abs(a.frame.midX - b.frame.midX), 44)
        XCTAssertGreaterThanOrEqual(a.frame.width, 44)
        XCTAssertGreaterThanOrEqual(a.frame.height, 44)
        XCTAssertEqual(a.frame.midY, b.frame.midY, accuracy: 2)
        let before = a.frame.midX
        let start = a.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        start.press(forDuration: 0.1, thenDragTo: start.withOffset(CGVector(dx: 80, dy: 0)))
        XCTAssertEqual(a.frame.midX, before + 80, accuracy: 6)
        app.buttons["toolbox.ruler.reset"].tap()
        XCTAssertEqual(a.frame.midX, before, accuracy: 3)
        XCTAssertTrue(app.buttons["toolbox.ruler.calibration.finish"].isEnabled)
        capture(app, "ruler-separated-draggable-handles-tablet")
        app.segmentedControls["toolbox.ruler.mode"].buttons["角度"].tap()
        XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "toolbox.ruler.readout.angle").firstMatch.exists)
        capture(app, "ruler-angle-handles-tablet")
    }

    @MainActor
    func testPhotoCalibrationAndExportOnTablet() {
        XCUIDevice.shared.orientation = .landscapeLeft
        defer { XCUIDevice.shared.orientation = .portrait }
        let app = open("photoMeasure", anchor: "toolbox.photo.choose", extra: ["--photo-fixture"])
        app.buttons["toolbox.photo.choose"].tap()
        let canvas = app.descendants(matching: .any).matching(identifier: "toolbox.photo.canvas").firstMatch
        XCTAssertTrue(canvas.waitForExistence(timeout: 10))
        canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0.45)).tap()
        canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.7, dy: 0.45)).tap()
        let value = app.textFields["toolbox.photo.referenceValue"]
        XCTAssertTrue(value.waitForExistence(timeout: 5))
        value.tap(); value.typeText("100")
        app.buttons["toolbox.photo.apply"].tap()
        XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "toolbox.photo.readout").firstMatch.waitForExistence(timeout: 5))
        canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.2, dy: 0.65)).tap()
        canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.6, dy: 0.65)).tap()
        app.buttons["toolbox.photo.export"].tap()
        XCTAssertTrue(app.staticTexts["qualification.photo.exported"].waitForExistence(timeout: 10))
        capture(app, "photo-measure-calibrated-export-tablet")
        app.terminate()
    }

    @MainActor
    func testPhotoToolsInCompactDarkLargeType() {
        XCUIDevice.shared.orientation = .portrait
        let app = open("photoMeasure", anchor: "toolbox.photo.choose", extra: ["--photo-fixture", "--compact", "--dark", "--large-text"])
        app.buttons["toolbox.photo.choose"].tap()
        XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "toolbox.photo.canvas").firstMatch.waitForExistence(timeout: 10))
        capture(app, "photo-measure-compact-dark-large-text")
        app.terminate()
    }
}
