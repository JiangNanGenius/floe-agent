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
        let inspector = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
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
        let present = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
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
        let inspector = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
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

@MainActor
final class CADAnimationExportOptionsFlowUITests: XCTestCase {
    func testExportOptionsUseNativeChoicesAndCancelWithoutStartingExport() throws {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .landscapeLeft
        let app = XCUIApplication()
        app.launchArguments = ["-AppleLanguages", "(en)", "-AppleLocale", "en_US",
                               "-ui-testing", "-ui-testing-ipad", "--ui-test-cad-fixture",
                               "--ui-test-cad-animation"]
        app.launch()
        defer { app.terminate() }
        XCTAssertTrue(app.otherElements["CADFixtureHarness"].waitForExistence(timeout: 30))
        app.segmentedControls["CADWorkbenchMode"].buttons["Present"].tap()
        let export = app.buttons["CADPresentExport"]
        XCTAssertTrue(export.waitForExistence(timeout: 20))
        export.tap()
        let video = app.buttons["MP4 video"]
        XCTAssertTrue(video.waitForExistence(timeout: 10))
        XCTAssertTrue(video.isEnabled)
        video.tap()
        let cancel = app.buttons["CADAnimationExportOptionsCancel"]
        XCTAssertTrue(cancel.waitForExistence(timeout: 10))
        for identifier in ["CADAnimationExportOrientation", "CADAnimationExportResolution",
                           "CADAnimationExportFrameRate", "CADAnimationExportCodec",
                           "CADAnimationExportQuality"] {
            XCTAssertTrue(app.buttons[identifier].isHittable, "Missing native choice: \(identifier)")
        }
        app.buttons["CADAnimationExportOrientation"].tap()
        app.buttons["Portrait"].tap()
        app.buttons["CADAnimationExportResolution"].tap()
        app.buttons["720p"].tap()
        app.buttons["CADAnimationExportFrameRate"].tap()
        app.buttons["24 fps"].tap()
        let choices = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        choices.name = "CAD-animation-export-native-options"
        choices.lifetime = .keepAlways
        add(choices)
        XCTAssertTrue(app.buttons["CADAnimationExportOptionsConfirm"].isEnabled)
        cancel.tap()
        XCTAssertTrue(export.waitForExistence(timeout: 10))
        XCTAssertFalse(app.descendants(matching: .any)["CADAnimationExportProgress"].exists,
                       "Cancelling the options must not start an export job")
    }
}

@MainActor
final class CADDrawingMultiViewFlowUITests: XCTestCase {
    func testSharedSheetViewManagementAndPreview() throws {
        try checkSharedSheet(compact: false)
    }

    func testSharedSheetViewManagementWithNarrowLargeText() throws {
        try checkSharedSheet(compact: true)
    }

    private func checkSharedSheet(compact: Bool) throws {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = compact ? .portrait : .landscapeLeft
        let app = XCUIApplication()
        app.launchArguments = ["-AppleLanguages", "(en)", "-AppleLocale", "en_US",
                               "-ui-testing", "--ui-test-cad-fixture", "--ui-test-cad-shared-sheet"]
        if compact {
            app.launchArguments += ["--ui-test-cad-compact", "--ui-test-cad-large-text"]
        } else {
            app.launchArguments += ["-ui-testing-ipad"]
        }
        app.launch()
        defer { app.terminate() }
        XCTAssertTrue(app.otherElements["CADFixtureHarness"].waitForExistence(timeout: 30))
        app.buttons["CADWorkbenchToolsButton"].tap()
        XCTAssertTrue(app.otherElements["CADWorkbenchToolsPanel"].waitForExistence(timeout: 15))
        app.buttons["Drawings"].tap()
        let views = app.buttons.matching(NSPredicate(
            format: "identifier BEGINSWITH %@", "CADDrawingViews-")).firstMatch
        reveal(views, in: app)
        views.tap()
        let close = app.buttons["CADDrawingViewsClose"]
        XCTAssertTrue(close.waitForExistence(timeout: 10))
        XCTAssertTrue(viewCount(4, in: app).waitForExistence(timeout: 10))
        let layout = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        layout.name = compact ? "CAD-shared-sheet-narrow-large-text" : "CAD-shared-sheet-views"
        layout.lifetime = .keepAlways
        add(layout)

        let addView = app.buttons["CADDrawingViewAdd"]
        reveal(addView, in: app)
        addView.tap()
        XCTAssertTrue(viewCount(5, in: app).waitForExistence(timeout: 15))
        let remove = app.buttons["CADDrawingViewRemove"]
        reveal(remove, in: app)
        remove.tap()
        XCTAssertTrue(viewCount(4, in: app).waitForExistence(timeout: 15))
        close.tap()

        let preview = app.buttons["Preview"].firstMatch
        reveal(preview, in: app)
        preview.tap()
        XCTAssertTrue(app.otherElements["CADDrawingPreview"].waitForExistence(timeout: 10))
        let drawing = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        drawing.name = compact ? "CAD-shared-sheet-narrow-preview" : "CAD-shared-sheet-preview"
        drawing.lifetime = .keepAlways
        add(drawing)
        app.buttons["CADDrawingPreviewClose"].tap()
        XCTAssertTrue(app.buttons["CADToolsSheetCloseButton"].isHittable)
        app.buttons["CADToolsSheetCloseButton"].tap()
        XCTAssertTrue(app.buttons["UndoButton"].waitForExistence(timeout: 10))
    }

    private func viewCount(_ count: Int, in app: XCUIApplication) -> XCUIElement {
        app.staticTexts.matching(NSPredicate(format: "label ==[c] %@", "\(count) views")).firstMatch
    }

    private func reveal(_ element: XCUIElement, in app: XCUIApplication) {
        XCTAssertTrue(element.waitForExistence(timeout: 10))
        for _ in 0..<8 {
            if element.isHittable { return }
            app.swipeUp()
        }
        XCTAssertTrue(element.isHittable, "The drawing control must remain reachable")
    }
}
#endif
