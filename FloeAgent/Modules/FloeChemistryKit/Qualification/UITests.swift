import XCTest

@MainActor final class ChemistryHostUITests: XCTestCase {
    func testNativeProjectComputeAndReopen() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-AppleLanguages", "(en)", "-AppleLocale", "en_AU"]
        continueAfterFailure = false
        app.launch()
        defer { app.terminate(); XCUIDevice.shared.orientation = .portrait }
        let token = "ChemistryQA-" + String(UUID().uuidString.prefix(8))
        let field = app.textFields["Project name"]
        XCTAssertTrue(field.waitForExistence(timeout: 15))
        field.tap(); field.typeText(" " + token)
        app.buttons["Create chemistry project"].tap()
        let addButton = app.buttons["Add object"].firstMatch
        XCTAssertTrue(addButton.waitForExistence(timeout: 10)); addButton.tap()
        app.buttons["Import or create"].firstMatch.tap()
        app.buttons["Water · XYZ"].tap()
        app.buttons["Add"].tap()
        XCTAssertTrue(app.staticTexts["H2O"].firstMatch.waitForExistence(timeout: 10))
        app.buttons["Properties and methods"].firstMatch.tap()
        XCTAssertTrue(app.buttons["Run calculation"].waitForExistence(timeout: 10))
        app.buttons["Run calculation"].tap()
        app.buttons["Done"].tap()
        let apply = app.buttons["Apply structure"].firstMatch
        XCTAssertTrue(apply.waitForExistence(timeout: 15)); apply.tap()
        let structure = XCTAttachment(screenshot: app.screenshot())
        structure.name = "Chemistry-native-UFF"; structure.lifetime = .keepAlways; add(structure)
        XCUIDevice.shared.orientation = .landscapeLeft
        waitForLandscape(app)
        XCTAssertTrue(app.buttons["Fit structure"].waitForExistence(timeout: 10))
        let landscape = XCTAttachment(screenshot: XCUIScreen.main.screenshot()); landscape.name = "Chemistry-landscape-workbench"; landscape.lifetime = .keepAlways; add(landscape)
        XCUIDevice.shared.orientation = .portrait
        app.segmentedControls.buttons["Document"].tap()
        let text = app.textViews.firstMatch
        XCTAssertTrue(text.waitForExistence(timeout: 10)); text.tap(); text.typeText(token)
        let saved = app.staticTexts["chemistry.saveStatus"]
        let expectation = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == %@", "Saved"), object: saved)
        XCTAssertEqual(XCTWaiter.wait(for: [expectation], timeout: 15), .completed)
        app.terminate(); app.launch()
        let project = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", token)).firstMatch
        XCTAssertTrue(project.waitForExistence(timeout: 15)); project.tap()
        app.segmentedControls.buttons["Document"].tap()
        XCTAssertTrue(app.textViews.firstMatch.waitForExistence(timeout: 10))
        XCTAssertTrue((app.textViews.firstMatch.value as? String ?? "").contains(token))
        let reopened = XCTAttachment(screenshot: app.screenshot())
        reopened.name = "Chemistry-document-reopened"; reopened.lifetime = .keepAlways; add(reopened)
    }
    func testNativeDrawingAndReopen() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-AppleLanguages", "(en)", "-AppleLocale", "en_AU"]
        continueAfterFailure = false
        app.launch(); defer { app.terminate(); XCUIDevice.shared.orientation = .portrait }
        let token = "SketchQA-" + String(UUID().uuidString.prefix(8))
        let field = app.textFields["Project name"]
        XCTAssertTrue(field.waitForExistence(timeout: 15)); field.tap(); field.typeText(" " + token)
        app.buttons["Create chemistry project"].tap()
        app.buttons["New drawing"].firstMatch.tap()
        let canvas = app.otherElements["chemistry.nativeCanvas"].firstMatch
        XCTAssertTrue(canvas.waitForExistence(timeout: 20))
        XCTAssertEqual(app.webViews.count, 0)
        let finger = app.buttons["chemistry.drawing.fingerDrawing"]
        XCTAssertTrue(finger.waitForExistence(timeout: 5))
        if app.staticTexts["Finger pans"].exists { finger.tap() }
        XCTAssertTrue(app.staticTexts["Finger draws"].exists)
        app.staticTexts["Untitled molecule"].firstMatch.tap()
        app.buttons["Benzene template"].tap()
        canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.48, dy: 0.45)).tap()
        let counts = app.staticTexts["chemistry.drawingCounts"]
        let six = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == %@", "6 atoms · 6 bonds"), object: counts)
        XCTAssertEqual(XCTWaiter.wait(for: [six], timeout: 10), .completed)
        app.buttons["Undo"].tap()
        XCTAssertEqual(counts.label, "0 atoms · 0 bonds")
        app.buttons["Redo"].tap()
        XCTAssertEqual(counts.label, "6 atoms · 6 bonds")
        app.buttons["Bond"].tap()
        canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.2, dy: 0.2)).press(forDuration: 0.05, thenDragTo: canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.38, dy: 0.2)))
        let added = XCTNSPredicateExpectation(predicate:NSPredicate(format:"label == %@","8 atoms · 7 bonds"),object:counts)
        XCTAssertEqual(XCTWaiter.wait(for:[added],timeout:10),.completed, "Input: \(String(describing:canvas.value)); \(canvas.debugDescription)")
        app.buttons["Undo"].tap()
        XCTAssertEqual(counts.label, "6 atoms · 6 bonds")
        let save = app.staticTexts["chemistry.saveStatus"]
        let saved = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == %@", "Saved"), object: save)
        XCTAssertEqual(XCTWaiter.wait(for: [saved], timeout: 20), .completed)
        // A native formula appears only after the diagram has reached the real parser/store.
        XCTAssertTrue(app.staticTexts["C6H6"].firstMatch.waitForExistence(timeout: 15))
        let drawn = XCTAttachment(screenshot: app.screenshot()); drawn.name = "Native-Pencil-canvas-benzene"; drawn.lifetime = .keepAlways; add(drawn)
        app.terminate(); app.launchArguments += ["--chemistry-qa-dark"]; app.launch()
        let project = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", token)).firstMatch
        XCTAssertTrue(project.waitForExistence(timeout: 15)); project.tap()
        XCTAssertTrue(app.otherElements["chemistry.nativeCanvas"].firstMatch.waitForExistence(timeout: 20))
        XCTAssertEqual(app.webViews.count, 0)
        XCTAssertEqual(app.staticTexts["chemistry.drawingCounts"].label, "6 atoms · 6 bonds")
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == %@", "Saved"), object: app.staticTexts["chemistry.saveStatus"])
        XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 30), .completed)
        XCTAssertTrue(app.staticTexts["C6H6"].firstMatch.waitForExistence(timeout: 15))
        let reopened = XCTAttachment(screenshot: app.screenshot()); reopened.name = "Native-Pencil-canvas-reopened"; reopened.lifetime = .keepAlways; add(reopened)
        XCUIDevice.shared.orientation = .landscapeLeft
        waitForLandscape(app)
        XCTAssertTrue(app.otherElements["chemistry.nativeCanvas"].firstMatch.waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["Pan"].isHittable)
        XCTAssertTrue(app.buttons["Periodic table"].isHittable)
        XCTAssertTrue(app.buttons["Element I"].isHittable)
        let landscape = XCTAttachment(screenshot: XCUIScreen.main.screenshot()); landscape.name = "Native-Pencil-canvas-dark-landscape"; landscape.lifetime = .keepAlways; add(landscape)
        let touchMode = app.buttons["chemistry.drawing.fingerDrawing"]
        XCTAssertTrue(touchMode.exists);touchMode.tap()
        XCTAssertTrue(app.staticTexts["Finger pans"].exists);touchMode.tap()
        XCUIDevice.shared.orientation = .portrait
        app.terminate();app.launchArguments += ["--chemistry-qa-high-contrast"];app.launch()
        let highContrastProject = app.buttons.matching(NSPredicate(format:"label CONTAINS %@",token)).firstMatch
        XCTAssertTrue(highContrastProject.waitForExistence(timeout:15));highContrastProject.tap()
        XCTAssertTrue(app.otherElements["chemistry.nativeCanvas"].firstMatch.waitForExistence(timeout:15))
        let accessible = XCTAttachment(screenshot:app.screenshot());accessible.name = "Native-Pencil-canvas-increased-contrast";accessible.lifetime = .keepAlways;add(accessible)
    }
    private func waitForLandscape(_ app: XCUIApplication) {
        let settled = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            let frame = app.windows.firstMatch.frame
            return frame.width > frame.height
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [settled], timeout: 15), .completed)
    }
}
