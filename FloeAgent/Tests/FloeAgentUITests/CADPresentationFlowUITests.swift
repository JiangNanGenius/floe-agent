#if canImport(XCTest)
import XCTest

@MainActor
final class CADPresentationFlowUITests: XCTestCase {
    func testNarrowLargeTextPresentationAndMaterialRemainReachable() throws {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchArguments = ["-AppleLanguages", "(en)", "-AppleLocale", "en_US",
                               "-ui-testing", "--ui-test-cad-fixture",
                               "--ui-test-cad-compact", "--ui-test-cad-large-text"]
        app.launch()
        defer { app.terminate() }
        XCTAssertTrue(app.otherElements["CADFixtureHarness"].waitForExistence(timeout: 30))
        let mode = app.segmentedControls["CADWorkbenchMode"]
        XCTAssertTrue(mode.waitForExistence(timeout: 15))
        mode.buttons["Present"].tap()
        XCTAssertTrue(app.buttons["CADPresentMaterial"].waitForExistence(timeout: 20))
        app.buttons["CADPresentMaterial"].tap()
        XCTAssertTrue(app.textFields["CADMaterialNameField"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["CADMaterialCancel"].isHittable)
        let inspector = XCTAttachment(screenshot: app.screenshot())
        inspector.name = "CAD-narrow-large-text-material-inspector"
        inspector.lifetime = .keepAlways
        add(inspector)
        app.buttons["CADMaterialCancel"].tap()
        XCTAssertTrue(mode.waitForExistence(timeout: 10))
        mode.buttons["Edit"].tap()
        XCTAssertTrue(app.buttons["UndoButton"].waitForExistence(timeout: 15))
    }

    func testPresentationEnvironmentAndMaterialReturnToSameWorkbench() throws {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .landscapeLeft
        let app = XCUIApplication()
        app.launchArguments = ["-AppleLanguages", "(en)", "-AppleLocale", "en_US",
                               "-ui-testing", "-ui-testing-ipad", "--ui-test-cad-fixture"]
        app.launch()
        defer { app.terminate() }
        XCTAssertTrue(app.otherElements["CADFixtureHarness"].waitForExistence(timeout: 30))
        XCTAssertTrue(app.buttons["UndoButton"].waitForExistence(timeout: 15))
        let mode = app.segmentedControls["CADWorkbenchMode"]
        XCTAssertTrue(mode.waitForExistence(timeout: 10))
        mode.buttons["Present"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["CADPresentationSurface"].waitForExistence(timeout: 20))
        XCTAssertTrue(app.buttons["CADPresentFit"].isHittable)
        app.buttons["CADPresentFit"].tap()
        let present = XCTAttachment(screenshot: app.screenshot())
        present.name = "CAD-Present-placed-parts"
        present.lifetime = .keepAlways
        add(present)

        app.buttons["CADPresentEnvironment"].tap()
        XCTAssertTrue(app.buttons["CADEnvironmentApply"].waitForExistence(timeout: 10))
        let environment = app.segmentedControls["CADEnvironmentKind"]
        XCTAssertTrue(environment.exists)
        environment.buttons["Dark"].tap()
        app.buttons["CADEnvironmentApply"].tap()
        XCTAssertTrue(app.buttons["CADPresentMaterial"].waitForExistence(timeout: 10))
        app.buttons["CADPresentMaterial"].tap()
        XCTAssertTrue(app.textFields["CADMaterialNameField"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["CADMaterialCancel"].exists)
        let inspector = XCTAttachment(screenshot: app.screenshot())
        inspector.name = "CAD-Material-inspector"
        inspector.lifetime = .keepAlways
        add(inspector)
        app.buttons["CADMaterialCancel"].tap()
        XCTAssertTrue(mode.waitForExistence(timeout: 10))
        mode.buttons["Edit"].tap()
        XCTAssertTrue(app.buttons["UndoButton"].waitForExistence(timeout: 15))
        XCTAssertTrue(app.buttons["ItemsButton"].exists)
    }
}
#endif
