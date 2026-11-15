import XCTest

@MainActor final class NativeMoleculePreviewUITests: XCTestCase {
    override func setUp() { continueAfterFailure = false }
    func testReal2DMoleculesGenerateAndPersistIndependentPreviews() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()
        defer { app.terminate(); XCUIDevice.shared.orientation = .portrait }
        XCUIDevice.shared.orientation = .landscapeLeft
        let landscape = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in app.frame.width > app.frame.height }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [landscape], timeout: 15), .completed)
        let generate = app.buttons["preview.generate"]
        XCTAssertTrue(generate.waitForExistence(timeout: 30))
        for sample in ["cyclohexane", "lactic-R", "benzene", "ethanol"] {
            app.buttons["preview.samples"].tap()
            app.buttons["sample."+sample].tap()
            XCTAssertTrue(generate.isEnabled)
            generate.tap()
            XCTAssertTrue(app.staticTexts["preview.ready"].waitForExistence(timeout: 10))
            let model = app.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH %@", "Molecular structure.")).firstMatch
            XCTAssertTrue(model.waitForExistence(timeout: 10), "The actual native 3D view must exist before the screenshot")
            let image = XCTAttachment(screenshot: XCUIScreen.main.screenshot()); image.name = "native-3d-"+sample; image.lifetime = .keepAlways; add(image)
        }
        app.terminate(); app.launch()
        XCTAssertTrue(generate.waitForExistence(timeout: 30)); generate.tap()
        XCTAssertTrue(app.staticTexts["preview.ready"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["Saved preview"].exists)
        app.terminate()
    }
    func testEditedNativeDrawingIsTheActual3DInput() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch(); defer { app.terminate(); XCUIDevice.shared.orientation = .portrait }
        XCTAssertTrue(app.buttons["preview.samples"].waitForExistence(timeout: 30))
        app.buttons["preview.samples"].tap(); app.buttons["sample.aspirin"].tap()
        app.buttons["preview.generate"].tap()
        XCTAssertTrue(app.staticTexts["preview.ready"].waitForExistence(timeout: 10))
        app.buttons["preview.edit"].tap()
        let twoD = app.segmentedControls.buttons["2D drawing"]
        XCTAssertTrue(twoD.waitForExistence(timeout: 15)); twoD.tap()
        let canvas = app.otherElements["chemistry.nativeCanvas"].firstMatch
        XCTAssertTrue(canvas.waitForExistence(timeout: 20))
        let copy = app.buttons["Copy drawing"]
        let opened = XCTNSPredicateExpectation(predicate: NSPredicate(format: "enabled == true"), object: copy)
        XCTAssertEqual(XCTWaiter.wait(for: [opened], timeout: 60), .completed, "Wait for the actual drawing conversion before editing")
        if app.staticTexts["Finger pans"].exists {
            let touch = app.descendants(matching: .any).matching(identifier: "chemistry.drawing.fingerDrawing").firstMatch
            XCTAssertTrue(touch.waitForExistence(timeout: 5)); touch.tap()
        }
        app.buttons["Drawing options"].tap(); app.buttons["Clear drawing"].tap()
        app.buttons["Ring 6"].tap()
        canvas.coordinate(withNormalizedOffset: .init(dx: 0.5, dy: 0.5)).tap()
        let counts = app.staticTexts["chemistry.drawingCounts"]
        let drawn = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == %@", "6 atoms · 6 bonds"), object: counts)
        XCTAssertEqual(XCTWaiter.wait(for: [drawn], timeout: 10), .completed)
        let save = app.staticTexts["chemistry.saveStatus"]
        let saved = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == %@", "Saved"), object: save)
        XCTAssertEqual(XCTWaiter.wait(for: [saved], timeout: 20), .completed)
        app.buttons["preview.drawing.done"].tap()
        XCTAssertTrue(app.buttons["preview.generate"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.staticTexts["preview.ready"].exists, "Edited drawing must invalidate its older preview")
        app.buttons["preview.generate"].tap()
        XCTAssertTrue(app.staticTexts["preview.ready"].waitForExistence(timeout: 10))
        let screenshot = XCTAttachment(screenshot: XCUIScreen.main.screenshot()); screenshot.name = "edited-2d-to-native-3d"; screenshot.lifetime = .keepAlways; add(screenshot)
    }
}
