#if canImport(XCTest)
import XCTest

/// E37 uses real UIKit background transitions and the existing saved native
/// package. It does not post a synthetic lifecycle notification or reseed the
/// document when checking recovery in a fresh process.
@MainActor
final class CADBackgroundOwnershipFlowUITests: XCTestCase {
    func testBackgroundExportRefusesAndBackgroundSavedEditReopens() throws {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .landscapeLeft
        let app = XCUIApplication()
        let base = ["-AppleLanguages", "(en)", "-AppleLocale", "en_US",
                    "-ui-testing", "-ui-testing-ipad", "--ui-test-cad-fixture",
                    "--ui-test-cad-animation", "--ui-test-cad-animation-long"]
        app.launchArguments = base
        app.launch()
        defer { app.terminate() }
        XCTAssertTrue(app.buttons["HistoryButton"].waitForExistence(timeout: 60))
        let mode = app.segmentedControls["CADWorkbenchMode"]
        mode.buttons["Present"].tap()
        let export = app.buttons["CADPresentExport"]
        XCTAssertTrue(export.waitForExistence(timeout: 30))
        export.tap()
        app.buttons["MP4 video"].tap()
        let confirm = app.buttons["CADAnimationExportOptionsConfirm"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 10))
        app.buttons["CADAnimationExportResolution"].tap()
        app.buttons["720p"].tap()
        app.buttons["CADAnimationExportFrameRate"].tap()
        app.buttons["24 fps"].tap()
        confirm.tap()
        let progress = app.descendants(matching: .any)
            .matching(identifier: "CADAnimationExportProgress").firstMatch
        XCTAssertTrue(progress.waitForExistence(timeout: 20),
                      "a real owned export must still be running before backgrounding")
        snapshot("E37 actual export running before Home")
        XCUIDevice.shared.press(.home)
        assertBackground(app)
        // Let the actual renderer observe the background state. This is a
        // bounded real inactive interval, not a simulated callback or a fake
        // completed export. The 10s clip cannot finish in this interval.
        RunLoop.current.run(until: Date().addingTimeInterval(2))
        app.activate()
        let failed = app.alerts["Couldn't export"]
        XCTAssertTrue(failed.waitForExistence(timeout: 20),
                      "background rendering must refuse and return its actual failure")
        snapshot("E37 background export returns its actual refusal")
        failed.buttons["Done"].tap()
        XCTAssertTrue(waitForAbsence(progress, timeout: 10))
        XCTAssertTrue(export.isEnabled,
                      "the old export must release ownership so the document remains usable")
        mode.buttons["Edit"].tap()

        let history = app.buttons["HistoryButton"]
        XCTAssertTrue(history.waitForExistence(timeout: 20))
        history.tap()
        let name = app.textFields["HistoryName-Extrude"].firstMatch
        XCTAssertTrue(name.waitForExistence(timeout: 15))
        name.tap()
        let oldName = name.value as? String ?? "Extrude"
        name.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: oldName.count))
        name.typeText("BackgroundPlate\n")
        XCTAssertTrue(app.descendants(matching: .any)
            .matching(identifier: "HistoryRow-BackgroundPlate").firstMatch.waitForExistence(timeout: 10))
        snapshot("E37 real edit before background save")
        // No foreground Save: recovery below must depend on the production
        // scenePhase flush/autosave, not an explicit test-side commit.
        XCUIDevice.shared.press(.home)
        assertBackground(app)
        RunLoop.current.run(until: Date().addingTimeInterval(2))
        app.terminate()

        app.launchArguments = base + ["--ui-test-cad-reopen"]
        app.launch()
        XCTAssertTrue(app.buttons["HistoryButton"].waitForExistence(timeout: 60))
        app.buttons["HistoryButton"].tap()
        let savedRow = app.descendants(matching: .any)
            .matching(identifier: "HistoryRow-BackgroundPlate").firstMatch
        XCTAssertTrue(savedRow.waitForExistence(timeout: 20),
                      "a fresh process must reopen the actual background-saved edit")
        XCTAssertEqual(app.textFields["HistoryName-BackgroundPlate"].firstMatch.value as? String,
                       "BackgroundPlate")
        snapshot("E37 fresh process reopens the same background-saved package")
    }

    private func assertBackground(_ app: XCUIApplication) {
        let running = app.wait(for: .runningBackground, timeout: 5)
        XCTAssertTrue(running || app.state == .runningBackgroundSuspended,
                      "Home must produce a real UIKit background transition")
    }

    private func waitForAbsence(_ element: XCUIElement, timeout: TimeInterval) -> Bool {
        let predicate = NSPredicate(format: "exists == false")
        return XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: predicate, object: element)],
                             timeout: timeout) == .completed
    }

    private func snapshot(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}

@MainActor
final class CADPresentationFlowUITests: XCTestCase {
    func testEnvironmentPreviewCancelApplyUndoRedoAndReopen() throws {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .landscapeLeft
        let app = XCUIApplication()
        let base = ["-AppleLanguages", "(en)", "-AppleLocale", "en_US",
                    "-ui-testing", "-ui-testing-ipad", "--ui-test-cad-fixture"]
        app.launchArguments = base
        app.launch()
        defer { app.terminate() }
        XCTAssertTrue(app.buttons["UndoButton"].waitForExistence(timeout: 60))
        let mode = app.segmentedControls["CADWorkbenchMode"]
        mode.buttons["Present"].tap()
        let environment = app.buttons["CADPresentEnvironment"]
        XCTAssertTrue(environment.waitForExistence(timeout: 30))
        environment.tap()
        let choice = app.segmentedControls["CADEnvironmentKind"]
        XCTAssertTrue(choice.waitForExistence(timeout: 10))
        XCTAssertTrue(choice.buttons["Studio"].isSelected)
        choice.buttons["Dark"].tap()
        snapshotFaceFlow("X32 actual environment draft")
        app.buttons["CADEnvironmentCancel"].tap()
        environment.tap()
        XCTAssertTrue(choice.waitForExistence(timeout: 10))
        XCTAssertTrue(choice.buttons["Studio"].isSelected, "Cancel must not persist the preview")
        choice.buttons["Dark"].tap()
        app.buttons["CADEnvironmentApply"].tap()
        snapshotFaceFlow("X32 actual applied dark environment")
        mode.buttons["Edit"].tap()
        let undo = app.buttons["UndoButton"]
        XCTAssertTrue(undo.waitForExistence(timeout: 20))
        XCTAssertTrue(undo.isEnabled)
        undo.tap()
        mode.buttons["Present"].tap()
        environment.tap()
        XCTAssertTrue(choice.waitForExistence(timeout: 10))
        XCTAssertTrue(choice.buttons["Studio"].isSelected, "One undo must restore the inspector's prior values")
        app.buttons["CADEnvironmentCancel"].tap()
        mode.buttons["Edit"].tap()
        let redo = app.buttons["RedoButton"]
        XCTAssertTrue(redo.waitForExistence(timeout: 10))
        XCTAssertTrue(redo.isEnabled)
        redo.tap()
        mode.buttons["Present"].tap()
        environment.tap()
        XCTAssertTrue(choice.waitForExistence(timeout: 10))
        XCTAssertTrue(choice.buttons["Dark"].isSelected)
        app.buttons["CADEnvironmentCancel"].tap()
        snapshotFaceFlow("X32 actual redo restores presentation")
        // Production scene-phase save, followed by a fresh process reopening
        // the same package. The fixture is not regenerated on the second launch.
        XCUIDevice.shared.press(.home)
        let backgrounded = app.wait(for: .runningBackground, timeout: 5)
        XCTAssertTrue(backgrounded || app.state == .runningBackgroundSuspended)
        RunLoop.current.run(until: Date().addingTimeInterval(2))
        app.terminate()
        app.launchArguments = base + ["--ui-test-cad-reopen"]
        app.launch()
        XCTAssertTrue(app.buttons["UndoButton"].waitForExistence(timeout: 60))
        app.segmentedControls["CADWorkbenchMode"].buttons["Present"].tap()
        XCTAssertTrue(environment.waitForExistence(timeout: 30))
        environment.tap()
        XCTAssertTrue(choice.waitForExistence(timeout: 10))
        XCTAssertTrue(choice.buttons["Dark"].isSelected, "Fresh process must read the actual saved environment")
        snapshotFaceFlow("X32 saved environment reopened in fresh process")
        app.buttons["CADEnvironmentCancel"].tap()
    }

    func testFirstUnpaintedFaceMaterialOpenAndModeRoundTripKeepSameTarget() throws {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .landscapeLeft
        let app = XCUIApplication()
        app.launchArguments = ["-AppleLanguages", "(en)", "-AppleLocale", "en_US",
                               "-ui-testing", "-ui-testing-ipad", "--ui-test-cad-fixture",
                               "--ui-test-cad-uninstanced"]
        app.launch()
        defer { app.terminate() }
        XCTAssertTrue(app.buttons["UndoButton"].waitForExistence(timeout: 60))
        let mode = app.segmentedControls["CADWorkbenchMode"]
        mode.buttons["Present"].tap()
        let surface = app.descendants(matching: .any)
            .matching(identifier: "CADPresentationSurface").firstMatch
        XCTAssertTrue(surface.waitForExistence(timeout: 30))
        let granularity = app.segmentedControls["CADPresentSelectionMode"]
        XCTAssertTrue(granularity.waitForExistence(timeout: 10))
        app.buttons["CADPresentFit"].tap()
        granularity.buttons["Face"].tap()

        // Project the fixture's known top-face point (25,10,-30) mm through
        // the production Fit camera. This is an actual viewport touch on an
        // unpainted B-rep, not a direct selection or pre-painted test seam.
        let azimuth = Double.pi * 0.22
        let elevation = Double.pi * 0.12
        let halfFov = Double.pi / 6
        let radius = sqrt(100.0 * 100 + 10.0 * 10 + 60.0 * 60) / 2
        let distance = max(radius / tan(halfFov) * 1.18, radius * 1.6)
        let horizontal = -25 * cos(azimuth)
        let vertical = 25 * sin(azimuth) * sin(elevation) + 5 * cos(elevation)
        let depth = distance - (-25 * cos(elevation) * sin(azimuth) + 5 * sin(elevation))
        let aspect = Double(surface.frame.width / surface.frame.height)
        let x = 0.5 + horizontal / (2 * depth * tan(halfFov) * aspect)
        let y = 0.5 - vertical / (2 * depth * tan(halfFov))
        XCTAssertGreaterThan(x, 0.1)
        XCTAssertLessThan(x, 0.9)
        XCTAssertGreaterThan(y, 0.1)
        XCTAssertLessThan(y, 0.9)
        surface.coordinate(withNormalizedOffset: CGVector(dx: x, dy: y)).tap()

        let selection = app.staticTexts["CADPresentSelection"]
        let facePicked = NSPredicate(format: "exists == true AND label CONTAINS %@", " · Face ")
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(
            predicate: facePicked, object: selection)], timeout: 20), .completed)
        let expectedTarget = selection.label
        snapshotFaceFlow("X20 actual unpainted face selected")

        let material = app.buttons["CADPresentMaterial"]
        material.tap()
        assertMaterialTarget(app, equals: expectedTarget)
        snapshotFaceFlow("X20 first material open keeps exact face")
        XCTAssertTrue(app.buttons["CADMaterialApply"].isEnabled)
        app.buttons["CADMaterialCancel"].tap()

        mode.buttons["Edit"].tap()
        XCTAssertTrue(app.buttons["UndoButton"].waitForExistence(timeout: 20))
        snapshotFaceFlow("X20 edit retains selected face")
        mode.buttons["Present"].tap()
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == true AND label == %@", expectedTarget),
            object: selection)], timeout: 20), .completed)
        material.tap()
        assertMaterialTarget(app, equals: expectedTarget)
        app.buttons["CADMaterialApply"].tap()
        let target = app.descendants(matching: .any)
            .matching(identifier: "CADMaterialSelectedTarget").firstMatch
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == false"), object: target)], timeout: 20), .completed)
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == true AND label == %@", expectedTarget),
            object: selection)], timeout: 20), .completed)
        snapshotFaceFlow("X20 apply keeps same face target")
    }

    private func assertMaterialTarget(_ app: XCUIApplication, equals expected: String) {
        let target = app.descendants(matching: .any)
            .matching(identifier: "CADMaterialSelectedTarget").firstMatch
        XCTAssertTrue(target.waitForExistence(timeout: 10),
                      "the first material sheet must receive a real selection")
        XCTAssertTrue(target.label.contains(expected)
                      || (target.value as? String)?.contains(expected) == true,
                      "the inspector must own the same exact face as the viewport")
    }

    private func snapshotFaceFlow(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

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

    /// X29-R2: the output type is explicit in the shipped sheet. Choosing
    /// `PNG frames (ZIP)` must show the real frame options (opaque-background
    /// note, no video codec/quality), and the legacy MP4 route must keep the
    /// video-only choices. Source-only selector evidence; Root runs it on the
    /// canonical iPad.
    func testFrameSequenceSelectionShowsOnlyFrameOptions() throws {
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
        let frames = app.buttons["PNG frames (ZIP)"]
        XCTAssertTrue(frames.waitForExistence(timeout: 10))
        frames.tap()
        let cancel = app.buttons["CADAnimationExportOptionsCancel"]
        XCTAssertTrue(cancel.waitForExistence(timeout: 10),
                      "PNG frames must open the shipped native options sheet")
        let format = app.buttons["CADAnimationExportFormat"]
        XCTAssertTrue(format.waitForExistence(timeout: 10),
                      "the output type must be explicit in the sheet")
        XCTAssertTrue(waitForExportOptionValue(format, "PNG frames (ZIP)"),
                      "the sheet must show the selected PNG output; label=\(format.label) "
                        + "value=\(String(describing: format.value))")
        XCTAssertTrue(app.descendants(matching: .any)
            .matching(identifier: "CADAnimationExportAlphaNote").firstMatch.exists,
                      "the opaque-background rule must stay visible")
        XCTAssertFalse(app.buttons["CADAnimationExportCodec"].exists,
                       "video codec must be hidden for PNG frames")
        XCTAssertFalse(app.buttons["CADAnimationExportQuality"].exists,
                       "video quality must be hidden for PNG frames")
        XCTAssertTrue(app.buttons["CADAnimationExportOptionsConfirm"].isEnabled)
        XCTAssertFalse(app.descendants(matching: .any)
            .matching(identifier: "CADAnimationExportProgress").firstMatch.exists,
                       "choosing a format must not start the exporter")
        cancel.tap()
        XCTAssertTrue(export.waitForExistence(timeout: 10))

        // The historical MP4 route keeps the video-only choices.
        export.tap()
        let video = app.buttons["MP4 video"]
        XCTAssertTrue(video.waitForExistence(timeout: 10))
        video.tap()
        XCTAssertTrue(cancel.waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["CADAnimationExportCodec"].waitForExistence(timeout: 10),
                      "MP4 must keep its native codec choice")
        XCTAssertTrue(app.buttons["CADAnimationExportQuality"].waitForExistence(timeout: 10),
                      "MP4 must keep its native quality choice")
        cancel.tap()
    }

    private func waitForExportOptionValue(_ element: XCUIElement, _ expected: String,
                                          timeout: TimeInterval = 20) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let value = (element.value as? String) ?? ""
            if value == expected || value.contains(expected)
                || element.label.contains(expected) {
                return true
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        let value = (element.value as? String) ?? ""
        return value == expected || value.contains(expected)
            || element.label.contains(expected)
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

    func testBOMCSVExportFromNativeDrawingPanel() throws {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .landscapeLeft
        let app = XCUIApplication()
        app.launchArguments = ["-AppleLanguages", "(en)", "-AppleLocale", "en_US",
                               "-ui-testing", "-ui-testing-ipad", "--ui-test-cad-fixture",
                               "--ui-test-cad-shared-sheet"]
        app.launch()
        defer { app.terminate() }
        XCTAssertTrue(app.otherElements["CADFixtureHarness"].waitForExistence(timeout: 30))
        app.buttons["CADWorkbenchToolsButton"].tap()
        XCTAssertTrue(app.otherElements["CADWorkbenchToolsPanel"].waitForExistence(timeout: 15))
        app.buttons["Drawings"].tap()
        // Expand the frontmost native inspector before reaching the later
        // drawing actions. The background ToolPalette is also a hittable
        // ScrollView; scrolling that first match never moves this sheet.
        let inspectorBar = app.navigationBars["CAD Tools"]
        XCTAssertTrue(inspectorBar.waitForExistence(timeout: 10))
        inspectorBar.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            .press(forDuration: 0.1,
                   thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.12)))
        let bom = app.buttons["BOM"].firstMatch
        reveal(bom, in: app)
        bom.tap()
        let derive = app.buttons["CADDrawingBOMDerive"]
        XCTAssertTrue(derive.waitForExistence(timeout: 10))
        derive.tap()
        let close = app.buttons["CADDrawingBOMClose"]
        XCTAssertTrue(close.waitForExistence(timeout: 10))
        close.tap()
        let csv = app.buttons.matching(NSPredicate(
            format: "identifier BEGINSWITH %@", "CADDrawingBOMCSV-")).firstMatch
        reveal(csv, in: app)
        XCTAssertFalse(app.buttons["CADDrawingShareExport"].exists)
        csv.tap()
        let share = app.buttons["CADDrawingShareExport"]
        reveal(share, in: app, scrollingUp: false)
        XCTAssertTrue(share.isHittable,
                      "The actual native CSV action must produce a shareable file")
        let screen = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        screen.name = "CAD-BOM-CSV-native-export"
        screen.lifetime = .keepAlways
        add(screen)
    }

    func testManufacturingEditKeepsOneSavedAnnotation() throws {
        let app = launchManufacturingDrawing()
        defer { app.terminate() }

        let manufacturing = app.buttons.matching(NSPredicate(
            format: "identifier BEGINSWITH %@", "CADDrawingManufacturing-")).firstMatch
        reveal(manufacturing, in: app)
        manufacturing.tap()
        expandDrawingInspector("GD&T", in: app)
        let datum = app.textFields["Datum letter"]
        replaceDrawingField(datum, with: "A", in: app)
        let add = app.buttons["CADDrawingManufacturingAdd"]
        reveal(add, in: app)
        add.tap()
        let rows = app.buttons.matching(identifier: "CADDrawingManufacturingRow")
        reveal(rows.firstMatch, in: app)
        XCTAssertEqual(rows.count, 1)
        XCTAssertTrue(rows.firstMatch.label.contains("A"))
        rows.firstMatch.tap()
        replaceDrawingField(datum, with: "B", in: app)
        let save = app.buttons["CADDrawingManufacturingSave"]
        reveal(save, in: app)
        save.tap()
        reveal(rows.firstMatch, in: app)
        XCTAssertEqual(rows.count, 1, "Editing must update the real annotation rather than append one")
        XCTAssertTrue(rows.firstMatch.label.contains("B"))
        drawingSnapshot("CAD native manufacturing edit keeps one annotation")
        app.navigationBars["GD&T"].buttons["Close"].tap()

        reveal(manufacturing, in: app, scrollingUp: false)
        manufacturing.tap()
        reveal(rows.firstMatch, in: app)
        XCTAssertEqual(rows.count, 1)
        XCTAssertTrue(rows.firstMatch.label.contains("B"), "Reopening must read the edited document")
        app.navigationBars["GD&T"].buttons["Close"].tap()
    }

    func testTemplateDecimalDraftsAndNativeRevisionSurviveReopening() throws {
        let app = launchManufacturingDrawing()
        defer { app.terminate() }
        let templates = app.buttons["Templates"].firstMatch
        reveal(templates, in: app, scrollingUp: false)
        templates.tap()
        expandDrawingInspector("Templates", in: app)
        let newTemplate = app.buttons["CADDrawingTemplateNew"]
        reveal(newTemplate, in: app)
        newTemplate.tap()
        let name = "Floe native manufacturing A3"
        replaceDrawingField(app.textFields["Name"], with: name, in: app)
        let margin = app.textFields["CADDrawingTemplateMargin"]
        replaceDrawingField(margin, with: "8.", in: app)
        XCTAssertEqual(margin.value as? String, "8.", "A decimal draft must not be rewritten while typing")
        let lineWidth = app.textFields["CADDrawingTemplateLineWidth"]
        replaceDrawingField(lineWidth, with: "0.25", in: app)
        XCTAssertEqual(lineWidth.value as? String, "0.25")
        let revisionAdd = app.buttons["CADDrawingRevisionAdd"]
        reveal(revisionAdd, in: app)
        revisionAdd.tap()
        replaceDrawingField(app.textFields["Rev"], with: "A", in: app)
        replaceDrawingField(app.textFields["Date"], with: "2026-11-01", in: app)
        replaceDrawingField(app.textFields["Description"], with: "Native revision proof", in: app)
        drawingSnapshot("CAD template native decimal drafts and revision row")
        let templateSave = app.buttons["CADDrawingTemplateSave"]
        reveal(templateSave, in: app)
        templateSave.tap()
        // Saving inserts the template library and application sections above
        // this action. Bring its new lazy Form row back onscreen before
        // checking the exact saved-state label.
        reveal(templateSave, in: app)
        let saved = expectation(for: NSPredicate(format: "label == %@", "Update template"),
                                evaluatedWith: templateSave)
        wait(for: [saved], timeout: 20)
        app.navigationBars["Templates"].buttons["Close"].tap()

        reveal(templates, in: app, scrollingUp: false)
        templates.tap()
        expandDrawingInspector("Templates", in: app)
        let stored = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", name)).firstMatch
        reveal(stored, in: app)
        stored.tap()
        reveal(margin, in: app)
        XCTAssertEqual(Double(margin.value as? String ?? ""), 8)
        reveal(lineWidth, in: app)
        XCTAssertEqual(Double(lineWidth.value as? String ?? ""), 0.25)
        reveal(app.textFields["Description"], in: app)
        XCTAssertEqual(app.textFields["Rev"].value as? String, "A")
        XCTAssertEqual(app.textFields["Date"].value as? String, "2026-11-01")
        XCTAssertEqual(app.textFields["Description"].value as? String, "Native revision proof")
        XCTAssertEqual(app.buttons.matching(identifier: "CADDrawingRevisionRemove").count, 1)
        drawingSnapshot("CAD template values and native revision survive reopening")
    }

    private func launchManufacturingDrawing() -> XCUIApplication {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .landscapeLeft
        let app = XCUIApplication()
        app.launchArguments = ["-AppleLanguages", "(en)", "-AppleLocale", "en_US",
                               "-ui-testing", "-ui-testing-ipad", "--ui-test-cad-fixture",
                               "--ui-test-cad-shared-sheet"]
        app.launch()
        XCTAssertTrue(app.otherElements["CADFixtureHarness"].waitForExistence(timeout: 30))
        app.buttons["CADWorkbenchToolsButton"].tap()
        XCTAssertTrue(app.otherElements["CADWorkbenchToolsPanel"].waitForExistence(timeout: 15))
        app.buttons["Drawings"].tap()
        expandDrawingInspector("CAD Tools", in: app)
        return app
    }

    private func expandDrawingInspector(_ title: String, in app: XCUIApplication) {
        let bar = app.navigationBars[title]
        XCTAssertTrue(bar.waitForExistence(timeout: 10))
        bar.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            .press(forDuration: 0.1,
                   thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.12)))
    }

    private func replaceDrawingField(_ field: XCUIElement, with text: String,
                                     in app: XCUIApplication) {
        reveal(field, in: app)
        // These are short native TextFields. Place the insertion point after
        // the rendered value, then clear and verify before typing the draft.
        field.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.5)).tap()
        let value = field.value as? String ?? ""
        let existing = value == field.placeholderValue ? "" : value
        if !existing.isEmpty {
            field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: existing.count))
            let cleared = expectation(for: NSPredicate(format: "value == %@ OR value == %@",
                                                       "", field.placeholderValue ?? ""),
                                      evaluatedWith: field)
            wait(for: [cleared], timeout: 5)
        }
        field.typeText(text)
    }

    private func drawingSnapshot(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
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
        reveal(viewCount(5, in: app), in: app, scrollingUp: false)
        let remove = app.buttons["CADDrawingViewRemove"]
        reveal(remove, in: app)
        remove.tap()
        reveal(viewCount(4, in: app), in: app, scrollingUp: false)
        close.tap()

        // Expand the actual native inspector via its visible navigation bar
        // before inspecting the whole drawing, as a user can do.
        let bar = app.navigationBars["CAD Tools"]
        XCTAssertTrue(bar.waitForExistence(timeout: 10))
        bar.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            .press(forDuration: 0.1,
                   thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.12)))

        // The existing localized product action is "View" (the source's
        // fallback says "Preview"); exercise the label actually shown.
        let preview = app.buttons["View"].firstMatch
        reveal(preview, in: app)
        preview.tap()
        let canvas = app.descendants(matching: .any)["CADDrawingPreview"]
        fullyReveal(canvas, in: app)
        XCTAssertFalse(app.descendants(matching: .any)["CADDrawingPreviewStale"].exists,
                       "a projection just refreshed by View must not show its old stale marker")
        let drawing = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        drawing.name = compact ? "CAD-shared-sheet-narrow-preview" : "CAD-shared-sheet-preview"
        drawing.lifetime = .keepAlways
        add(drawing)
        let previewClose = app.buttons["CADDrawingPreviewClose"]
        reveal(previewClose, in: app, scrollingUp: false)
        previewClose.tap()
        XCTAssertTrue(app.buttons["CADToolsSheetCloseButton"].isHittable)
        app.buttons["CADToolsSheetCloseButton"].tap()
        XCTAssertTrue(app.buttons["UndoButton"].waitForExistence(timeout: 10))
    }

    private func viewCount(_ count: Int, in app: XCUIApplication) -> XCUIElement {
        app.staticTexts.matching(NSPredicate(format: "label ==[c] %@", "\(count) views")).firstMatch
    }

    private func fullyReveal(_ element: XCUIElement, in app: XCUIApplication) {
        XCTAssertTrue(element.waitForExistence(timeout: 10))
        for _ in 0..<8 {
            let scrollable = [app.collectionViews.firstMatch, app.scrollViews.firstMatch]
                .first { $0.exists && $0.isHittable }
            let bounds = scrollable?.frame.intersection(app.frame) ?? app.frame
            let frame = element.frame
            let visible = frame.intersection(bounds)
            if element.isHittable && !visible.isNull
                && visible.width >= frame.width * 0.95
                && visible.height >= frame.height * 0.95 { return }
            let target = scrollable ?? app
            if frame.maxY > bounds.maxY { target.swipeUp() } else { target.swipeDown() }
        }
        XCTFail("The whole drawing preview must fit inside the expanded native inspector")
    }

    private func reveal(_ element: XCUIElement, in app: XCUIApplication, scrollingUp: Bool = true) {
        // A lower form row can be laid out underneath the real software
        // keyboard. Dismiss it through its native control before scrolling;
        // a whole-view swipe there would type keys into the focused field.
        let keyboard = app.keyboards.firstMatch
        if keyboard.exists {
            let hide = app.buttons["Hide keyboard"].firstMatch
            // UIKit retains an offscreen keyboard AX tree during dismissal.
            // Its old Hide control can be below the entire screen. Act only
            // on the currently visible native key; never scroll that ghost.
            if hide.exists && hide.isHittable && app.frame.contains(
                CGPoint(x: hide.frame.midX, y: hide.frame.midY)) {
                hide.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
                let deadline = Date().addingTimeInterval(5)
                while Date() < deadline, hide.exists && hide.isHittable {
                    RunLoop.main.run(until: Date().addingTimeInterval(0.05))
                }
                XCTAssertFalse(hide.exists && hide.isHittable,
                               "The visible native keyboard must dismiss before scrolling")
            }
        }
        // Form creates offscreen sections lazily; requiring existence before
        // scrolling prevents the driver from reaching real controls below it.
        for _ in 0..<8 {
            if element.exists && element.isHittable { return }
            // Scope the gesture to the active native Form/ScrollView.
            // Swiping the entire app can hit the uncovered workbench or
            // dismiss an inspector instead of scrolling its contents.
            let scrollable = activeDrawingScrollView(in: app)
            let target = scrollable ?? app
            if scrollingUp { target.swipeUp() } else { target.swipeDown() }
        }
        let hierarchy = XCTAttachment(string: app.debugDescription)
        hierarchy.name = "CAD-drawing-unreachable-control-hierarchy"
        hierarchy.lifetime = .keepAlways
        add(hierarchy)
        let screen = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        screen.name = "CAD-drawing-unreachable-control"
        screen.lifetime = .keepAlways
        add(screen)
        XCTAssertTrue(element.isHittable, "The drawing control must remain reachable")
    }

    private func activeDrawingScrollView(in app: XCUIApplication) -> XCUIElement? {
        // The workbench and the presenting Tools sheet remain in the AX tree.
        // Match the front native inspector's horizontal bounds so its Form is
        // scrolled instead of the still-hittable background tool palette.
        let bar = ["GD&T", "Templates", "Dimensions", "Drawing views", "CAD Tools"]
            .map { app.navigationBars[$0] }
            .first { $0.exists && $0.isHittable }
        let candidates = app.collectionViews.allElementsBoundByIndex
            + app.scrollViews.allElementsBoundByIndex
        if let bar {
            let bounds = bar.frame
            return candidates.filter {
                $0.exists && $0.isHittable && $0.frame.height > 100
                    && $0.frame.minX >= bounds.minX - 2
                    && $0.frame.maxX <= bounds.maxX + 2
                    && $0.frame.width >= bounds.width * 0.85
            }.min { abs($0.frame.width - bounds.width) < abs($1.frame.width - bounds.width) }
        }
        return candidates.first { $0.exists && $0.isHittable && $0.frame.height > 100 }
    }
}

// MARK: - X21 saved cameras and E29/X31 OBJ options: native UI cases

private enum CADNativeSheetLaunch {
    static let ipad = ["-AppleLanguages", "(en)", "-AppleLocale", "en_US",
                       "-ui-testing", "-ui-testing-ipad", "--ui-test-cad-fixture"]
    static let compact = ["-AppleLanguages", "(en)", "-AppleLocale", "en_US",
                          "-ui-testing", "--ui-test-cad-fixture",
                          "--ui-test-cad-compact", "--ui-test-cad-large-text"]
}

/// Drives the real presented Form sheets. Every helper acts on the production
/// controls (buttons, toggles, segmented pickers, alerts); none of them calls a
/// model/view-model API or fabricates a rendered result. Shared by the other
/// native CAD Form UI suites (E26 IGES exchange), so it is module-internal;
/// it remains test-target-only.
@MainActor
enum CADSheetProbe {
    static func attach(_ name: String, to test: XCTestCase) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        test.add(attachment)
    }

    static func any(_ app: XCUIApplication, _ identifier: String) -> XCUIElement {
        app.descendants(matching: .any)[identifier]
    }

    static func waitForAbsence(_ element: XCUIElement, timeout: TimeInterval) -> Bool {
        XCTWaiter.wait(for: [XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == false"), object: element)],
                       timeout: timeout) == .completed
    }

    static func waitForLabel(_ element: XCUIElement, contains text: String,
                             timeout: TimeInterval) -> Bool {
        guard element.waitForExistence(timeout: timeout) else { return false }
        return XCTWaiter.wait(for: [XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "label CONTAINS %@", text),
            object: element)], timeout: timeout) == .completed
    }

    static func waitForSelection(_ element: XCUIElement, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if element.exists && element.isSelected { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        return element.exists && element.isSelected
    }

    static func waitForEnabled(_ element: XCUIElement, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if element.exists && element.isEnabled { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        return element.exists && element.isEnabled
    }

    static func waitForValue(_ element: XCUIElement, _ value: String,
                             timeout: TimeInterval = 20) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if element.exists && (element.value as? String) == value { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        return element.exists && (element.value as? String) == value
    }

    static func waitForLabelEquals(_ element: XCUIElement, _ label: String,
                                   timeout: TimeInterval = 20) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if element.exists && element.label == label { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        return element.exists && element.label == label
    }

    static func waitForHittable(_ element: XCUIElement, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if element.exists && element.isHittable { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        return element.exists && element.isHittable
    }

    static func describe(_ element: XCUIElement) -> String {
        element.exists ? "label '\(element.label)'" : "element is absent"
    }

    /// The Form behind the presented sheet. The workbench underneath keeps its
    /// own scroll views in the AX tree, so match the sheet's navigation-bar
    /// horizontal bounds instead of taking the first hittable scroll view.
    static func sheetScrollView(title: String, in app: XCUIApplication) -> XCUIElement? {
        let bar = app.navigationBars[title]
        guard bar.exists else { return nil }
        let bounds = bar.frame
        let candidates = app.collectionViews.allElementsBoundByIndex
            + app.scrollViews.allElementsBoundByIndex
        return candidates
            .filter {
                $0.exists && $0.isHittable && $0.frame.height > 80
                    && $0.frame.minX >= bounds.minX - 2
                    && $0.frame.maxX <= bounds.maxX + 2
                    && $0.frame.width >= bounds.width * 0.85
            }
            .min { abs($0.frame.width - bounds.width) < abs($1.frame.width - bounds.width) }
    }

    /// Expand the presented sheet to its large detent through the standard
    /// sheet grabber before walking its Form. Subsequent scrolling stays
    /// inside the Form rather than starting on the grabber/navigation bar.
    static func expandSheet(_ title: String, in app: XCUIApplication) {
        let bar = app.navigationBars[title]
        guard bar.exists else { return }
        bar.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            .press(forDuration: 0.1,
                   thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.12)))
    }

    /// Reveal a control in either direction in the expanded sheet's real
    /// Form. A control can still exist in the AX tree above the viewport;
    /// asking its hittability there can itself fail with an invalid activation
    /// point (actual OBJ partial-coverage UI139). Check its visible frame first
    /// and move back toward it without dragging the sheet's grabber.
    static func reveal(_ element: XCUIElement, in app: XCUIApplication,
                       sheet title: String, swipes: Int = 8,
                       searchEarlierRowsFirst: Bool = false) {
        for _ in 0..<swipes {
            let form = sheetScrollView(title: title, in: app)
            let bar = app.navigationBars[title]
            let frame = form?.frame ?? app.frame
            let top = bar.exists ? max(frame.minY, bar.frame.maxY) : frame.minY
            let viewport = CGRect(x: frame.minX, y: top,
                                  width: frame.width, height: max(0, frame.maxY - top))
            // A lazy Form can remove an earlier row from the AX tree. Its
            // missing frame cannot tell us to scroll back toward that row.
            var towardEarlierRows = searchEarlierRowsFirst
            if element.exists {
                let target = element.frame
                let center = CGPoint(x: target.midX, y: target.midY)
                if !target.isEmpty, viewport.contains(center), element.isHittable { return }
                towardEarlierRows = target.maxY <= viewport.minY
                    || target.midY < viewport.minY
            }
            let scroll = form ?? app
            let startY: CGFloat = towardEarlierRows ? 0.32 : 0.72
            let endY: CGFloat = towardEarlierRows ? 0.72 : 0.32
            scroll.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: startY))
                .press(forDuration: 0.05, thenDragTo: scroll.coordinate(
                    withNormalizedOffset: CGVector(dx: 0.5, dy: endY)))
        }
    }

    static func toggle(_ identifier: String, in app: XCUIApplication) -> XCUIElement {
        let control = app.switches[identifier]
        return control.exists ? control : any(app, identifier)
    }

    /// A SwiftUI Toggle inside a Form exposes its whole labeled row as the
    /// Switch element (the provider-picker, interference and task-environment
    /// drivers pin the same native behavior). A synthesized tap at the row's
    /// midpoint lands on the label rather than the switch control, so flip the
    /// real control at its trailing edge and require the published value.
    static func setToggle(_ toggle: XCUIElement, _ value: String,
                          timeout: TimeInterval = 20) -> Bool {
        if (toggle.value as? String) == value { return true }
        toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.92, dy: 0.5)).tap()
        return waitForValue(toggle, value, timeout: timeout)
    }

    /// A Form `LabeledContent` row is one semantic element. Depending on the
    /// platform, its accessible text is published as a combined label
    /// ("Objects, 2 / 2") or as a separate `value`; read the row's own text
    /// instead of assuming a bare value-only static text.
    static func labeledRow(_ label: String, in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(
            NSPredicate(format: "label == %@ OR label BEGINSWITH %@ "
                        + "OR (label BEGINSWITH %@ AND label CONTAINS %@)",
                        label, label + ", ", label, " / ")
        ).firstMatch
    }

    static func labeledText(_ row: XCUIElement) -> String {
        ([row.label] + [(row.value as? String) ?? ""]).joined(separator: " ")
    }

    /// Poll while scrolling the presented Form upward. Used for rows that the
    /// sheet creates below the fold only after its real preflight finishes,
    /// so existence and the async work are waited for together.
    static func scrollReveal(_ element: XCUIElement, in app: XCUIApplication,
                             sheet title: String, timeout: TimeInterval = 90) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if element.exists && element.isHittable { return true }
            (sheetScrollView(title: title, in: app) ?? app).swipeUp()
            RunLoop.current.run(until: Date().addingTimeInterval(0.25))
        }
        return element.exists && element.isHittable
    }

    static func menuItem(_ title: String, in app: XCUIApplication) -> XCUIElement {
        let button = app.buttons[title].firstMatch
        return button.exists ? button : app.menuItems[title].firstMatch
    }

    static func cameraRows(in app: XCUIApplication) -> XCUIElementQuery {
        app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@",
                                         "CADPresentCameraRow-"))
    }

    static func enterPresent(_ app: XCUIApplication) {
        let mode = app.segmentedControls["CADWorkbenchMode"]
        XCTAssertTrue(mode.waitForExistence(timeout: 30))
        mode.buttons["Present"].tap()
    }

    /// The reality surface must exist before a view can be saved: the live
    /// camera is owned by that surface's controller, not by the sheet.
    static func waitForPresentSurface(_ app: XCUIApplication) {
        let surface = app.descendants(matching: .any)["CADPresentationSurface"]
        XCTAssertTrue(surface.waitForExistence(timeout: 30),
                      "Present must build the real presentation surface")
    }

    static func openCamera(_ app: XCUIApplication) {
        enterPresent(app)
        let camera = app.buttons["CADPresentCamera"]
        if !camera.exists, app.buttons["CADPresentMoreMenu"].exists {
            app.buttons["CADPresentMoreMenu"].tap()
        }
        XCTAssertTrue(camera.waitForExistence(timeout: 30))
        XCTAssertTrue(camera.isHittable,
                      "Present must keep the native Camera control reachable")
        camera.tap()
        XCTAssertTrue(app.navigationBars["Camera"].waitForExistence(timeout: 15),
                      "the real camera Form sheet must present")
        expandSheet("Camera", in: app)
    }

    static func closeCamera(_ app: XCUIApplication) {
        let done = app.buttons["CADPresentCameraDone"]
        XCTAssertTrue(done.waitForExistence(timeout: 15))
        done.tap()
        XCTAssertTrue(waitForAbsence(app.navigationBars["Camera"], timeout: 15))
    }

    static func enterEditor(_ app: XCUIApplication) {
        let mode = app.segmentedControls["CADWorkbenchMode"]
        XCTAssertTrue(mode.waitForExistence(timeout: 30))
        mode.buttons["Edit"].tap()
        let undo = app.buttons["UndoButton"]
        XCTAssertTrue(waitForHittable(undo, timeout: 20),
                      "Edit must expose the real Undo control")
    }

    /// The host's real Save control, then its reported outcome. Reopening in a
    /// new process is only meaningful after this succeeded.
    static func saveDocument(_ app: XCUIApplication) {
        let save = app.buttons["cad.host.save"]
        XCTAssertTrue(save.waitForExistence(timeout: 20),
                      "the production host Save control must exist")
        save.tap()
        let outcome = any(app, "cad.host.saveOutcome")
        XCTAssertTrue(outcome.waitForExistence(timeout: 120),
                      "the host must report its save outcome")
        XCTAssertEqual(outcome.label, "Saved")
    }

    /// Open one saved view's own actions (its long-press menu, otherwise the
    /// row's native swipe actions) and return the requested production action.
    static func rowAction(_ title: String, row: XCUIElement,
                          in app: XCUIApplication) -> XCUIElement? {
        // The row content and the parent list both accept a long press (the
        // same pattern the History context menus use). Retry once on the row
        // before falling back to the row's native swipe actions.
        for _ in 0..<2 {
            row.press(forDuration: 1.2)
            if let item = actionItem(title, in: app) { return item }
        }
        row.swipeLeft()
        return actionItem(title, in: app)
    }

    /// A context-menu/swipe action may drop its identifier but keeps its
    /// shipped English label; match the exact label on any element type.
    static func actionItem(_ title: String, in app: XCUIApplication) -> XCUIElement? {
        let button = app.buttons[title].firstMatch
        if button.waitForExistence(timeout: 6) { return button }
        let labelled = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label == %@", title)).firstMatch
        if labelled.waitForExistence(timeout: 4) { return labelled }
        return nil
    }

    static func replace(_ field: XCUIElement, with text: String) {
        field.coordinate(withNormalizedOffset: CGVector(dx: 0.92, dy: 0.5)).tap()
        let value = field.value as? String ?? ""
        if !value.isEmpty {
            field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue,
                                  count: value.count))
        }
        field.typeText(text)
    }

    /// Open one workbench toolbar action, using the system's own navigation
    /// overflow when the bar is full (the same native route the Versions host
    /// test uses). Never reaches a menu that is not on screen.
    static func openToolbarAction(_ identifier: String, label: String,
                                  in app: XCUIApplication) -> Bool {
        var button = app.buttons[identifier].firstMatch
        if !button.exists || !button.isHittable {
            let overflow = app.navigationBars.buttons["OverflowBarButtonItem"].firstMatch
            if overflow.exists && overflow.isHittable { overflow.tap() }
            if !button.exists { button = app.buttons[label].firstMatch }
        }
        guard button.waitForExistence(timeout: 20), button.isHittable else { return false }
        button.tap()
        return true
    }

    static func openOBJOptions(_ app: XCUIApplication, compact: Bool) {
        if compact {
            let more = app.buttons["CADCompactMoreMenu"]
            XCTAssertTrue(more.waitForExistence(timeout: 30),
                          "the compact control strip must expose the real overflow menu")
            more.tap()
            let export = menuItem("Export", in: app)
            XCTAssertTrue(export.waitForExistence(timeout: 15))
            export.tap()
        } else {
            XCTAssertTrue(openToolbarAction("ExportMenu", label: "Export", in: app),
                          "the workbench toolbar must expose the real Export menu")
        }
        let obj = menuItem("OBJ", in: app)
        XCTAssertTrue(obj.waitForExistence(timeout: 15),
                      "the Export menu must offer the native OBJ options entry")
        obj.tap()
        XCTAssertTrue(app.navigationBars["OBJ Export"].waitForExistence(timeout: 15),
                      "the real OBJ options Form must present")
        expandSheet("OBJ Export", in: app)
    }
}

@MainActor
final class CADSavedCameraNativeSheetUITests: XCTestCase {
    func testSavedCameraFormSavesSelectsProjectsUpdatesUndoRedoReopenAndDelete() throws {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .landscapeLeft
        let app = XCUIApplication()
        app.launchArguments = CADNativeSheetLaunch.ipad
        app.launch()
        defer { app.terminate() }
        XCTAssertTrue(app.buttons["UndoButton"].waitForExistence(timeout: 60))
        CADSheetProbe.enterPresent(app)
        CADSheetProbe.waitForPresentSurface(app)
        XCTAssertTrue(app.buttons["CADPresentFit"].waitForExistence(timeout: 20))
        app.buttons["CADPresentFit"].tap()

        CADSheetProbe.openCamera(app)
        XCTAssertTrue(app.staticTexts["No saved views yet."].waitForExistence(timeout: 15),
                      "a freshly seeded document must start with no saved views")
        CADSheetProbe.attach("X21 camera sheet - no saved views", to: self)

        let saveView = app.buttons["Save Current View"]
        CADSheetProbe.reveal(saveView, in: app, sheet: "Camera")
        XCTAssertTrue(saveView.isHittable,
                      "the real Save Current View action must be reachable")
        saveView.tap()

        let saved = CADSheetProbe.cameraRows(in: app).firstMatch
        XCTAssertTrue(saved.waitForExistence(timeout: 15),
                      "saving the current view must add a real saved-view row")
        XCTAssertTrue(saved.label.contains("View 1"), saved.label)
        let picker = app.segmentedControls["CADPresentCameraProjection"]
        XCTAssertTrue(picker.waitForExistence(timeout: 15))
        XCTAssertTrue(CADSheetProbe.waitForSelection(picker.buttons["Perspective"], timeout: 20),
                      "saving the live perspective view must keep its projection shown")
        XCTAssertFalse(app.staticTexts["The live view differs from the selected view."].exists,
                       "saving the current view must not report a differing live view")
        CADSheetProbe.attach("X21 saved camera row", to: self)

        // Undo/redo of the save: saved views are ordinary undoable commands.
        CADSheetProbe.closeCamera(app)
        CADSheetProbe.enterEditor(app)
        let undo = app.buttons["UndoButton"]
        XCTAssertTrue(undo.isEnabled)
        undo.tap()
        CADSheetProbe.openCamera(app)
        XCTAssertTrue(app.staticTexts["No saved views yet."].waitForExistence(timeout: 20),
                      "undo of the save command must remove the saved view")
        CADSheetProbe.closeCamera(app)
        CADSheetProbe.enterEditor(app)
        let redo = app.buttons["RedoButton"]
        XCTAssertTrue(redo.isEnabled)
        redo.tap()
        CADSheetProbe.openCamera(app)
        XCTAssertTrue(saved.waitForExistence(timeout: 20),
                      "redo must restore the same saved view")

        // Select / Free view / live projection through the native controls.
        let free = app.buttons["CADPresentCameraFree"]
        CADSheetProbe.reveal(free, in: app, sheet: "Camera")
        free.tap()
        CADSheetProbe.reveal(picker, in: app, sheet: "Camera")
        picker.buttons["Orthographic"].tap()
        CADSheetProbe.reveal(saved, in: app, sheet: "Camera")
        saved.tap()
        XCTAssertTrue(CADSheetProbe.waitForSelection(picker.buttons["Perspective"], timeout: 20),
                      "selecting the saved view must restore its own projection")

        // Update from Current View stores the live orthographic projection.
        CADSheetProbe.reveal(picker, in: app, sheet: "Camera")
        picker.buttons["Orthographic"].tap()
        XCTAssertTrue(CADSheetProbe.waitForSelection(picker.buttons["Orthographic"], timeout: 20),
                      "the live projection choice must update before any saved-row reload")
        XCTAssertTrue(app.staticTexts["The live view differs from the selected view."]
            .waitForExistence(timeout: 20),
                      "a live projection change must immediately mark the selected view as different")
        CADSheetProbe.attach("X21 live projection updates before reload", to: self)
        CADSheetProbe.reveal(saved, in: app, sheet: "Camera")
        let update = CADSheetProbe.rowAction("Update from Current View",
                                             row: saved, in: app)
        XCTAssertNotNil(update, "the saved row must expose its native update action")
        update?.tap()
        CADSheetProbe.reveal(saved, in: app, sheet: "Camera")
        saved.tap()
        XCTAssertTrue(CADSheetProbe.waitForSelection(picker.buttons["Orthographic"], timeout: 20),
                      "update must store the live orthographic projection")
        CADSheetProbe.attach("X21 updated saved camera", to: self)

        // Rename through the production alert.
        CADSheetProbe.reveal(saved, in: app, sheet: "Camera")
        let rename = CADSheetProbe.rowAction("Rename", row: saved, in: app)
        XCTAssertNotNil(rename, "the saved row must expose its native rename action")
        rename?.tap()
        let alert = app.alerts.firstMatch
        XCTAssertTrue(alert.waitForExistence(timeout: 15),
                      "rename must present its native name alert")
        let field = alert.textFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 10))
        CADSheetProbe.replace(field, with: "Hero view")
        alert.buttons["Save"].tap()
        XCTAssertTrue(CADSheetProbe.waitForLabel(saved, contains: "Hero view", timeout: 20),
                      "the renamed saved view must keep the same row: \(CADSheetProbe.describe(saved))")
        CADSheetProbe.reveal(saved, in: app, sheet: "Camera")
        saved.tap()
        XCTAssertTrue(CADSheetProbe.waitForSelection(picker.buttons["Orthographic"], timeout: 20),
                      "the renamed view must keep its saved orthographic projection")
        CADSheetProbe.attach("X21 renamed saved camera", to: self)

        // Save through the host, then reopen the same package in a new process.
        CADSheetProbe.closeCamera(app)
        CADSheetProbe.enterEditor(app)
        CADSheetProbe.saveDocument(app)
        app.terminate()

        app.launchArguments = CADNativeSheetLaunch.ipad + ["--ui-test-cad-reopen"]
        app.launch()
        XCTAssertTrue(app.buttons["UndoButton"].waitForExistence(timeout: 60))
        CADSheetProbe.openCamera(app)
        let reopened = CADSheetProbe.cameraRows(in: app).firstMatch
        XCTAssertTrue(reopened.waitForExistence(timeout: 25),
                      "the saved view must survive a new process opening the same package")
        XCTAssertTrue(reopened.label.contains("Hero view"), reopened.label)
        let reopenedPicker = app.segmentedControls["CADPresentCameraProjection"]
        XCTAssertTrue(reopenedPicker.waitForExistence(timeout: 15))
        CADSheetProbe.reveal(reopened, in: app, sheet: "Camera")
        reopened.tap()
        XCTAssertTrue(CADSheetProbe.waitForSelection(reopenedPicker.buttons["Orthographic"],
                                                     timeout: 20),
                      "reopening the package must restore the saved orthographic projection")
        CADSheetProbe.attach("X21 reopened saved camera", to: self)

        // Delete the reopened view through the row's own action.
        CADSheetProbe.reveal(reopened, in: app, sheet: "Camera")
        let delete = CADSheetProbe.rowAction("Delete", row: reopened, in: app)
        XCTAssertNotNil(delete, "the saved row must expose its native delete action")
        delete?.tap()
        XCTAssertTrue(CADSheetProbe.waitForAbsence(reopened, timeout: 20),
                      "delete must remove the saved view")
        XCTAssertTrue(app.staticTexts["No saved views yet."].waitForExistence(timeout: 15))
        CADSheetProbe.attach("X21 deleted saved camera", to: self)
        CADSheetProbe.closeCamera(app)
    }

    func testSavedCameraFormRemainsReachableWithNarrowLargeText() throws {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchArguments = CADNativeSheetLaunch.compact
        app.launch()
        defer { app.terminate() }
        XCTAssertTrue(app.otherElements["CADFixtureHarness"].waitForExistence(timeout: 60))

        CADSheetProbe.enterPresent(app)
        CADSheetProbe.waitForPresentSurface(app)
        CADSheetProbe.openCamera(app)
        let picker = app.segmentedControls["CADPresentCameraProjection"]
        XCTAssertTrue(picker.waitForExistence(timeout: 15))
        let free = app.buttons["CADPresentCameraFree"]
        CADSheetProbe.reveal(free, in: app, sheet: "Camera")
        XCTAssertTrue(free.isHittable,
                      "the narrow large-text camera form must keep Free view reachable")
        let saveView = app.buttons["Save Current View"]
        CADSheetProbe.reveal(saveView, in: app, sheet: "Camera")
        XCTAssertTrue(saveView.isHittable,
                      "the narrow large-text camera form must keep Save Current View reachable")
        saveView.tap()
        let saved = CADSheetProbe.cameraRows(in: app).firstMatch
        XCTAssertTrue(saved.waitForExistence(timeout: 20))
        XCTAssertTrue(saved.label.contains("View 1"), saved.label)
        CADSheetProbe.attach("X21 camera form - narrow large text", to: self)
        XCTAssertTrue(app.buttons["CADPresentCameraDone"].isHittable)
        CADSheetProbe.closeCamera(app)
        XCTAssertTrue(app.buttons["CADPresentMaterial"].waitForExistence(timeout: 25),
                      "the workbench must remain usable after the compact camera form")
    }
}

@MainActor
final class CADMeshExportOptionsNativeSheetUITests: XCTestCase {
    private static let mtlViewerNote = NSPredicate(
        format: "label BEGINSWITH %@", "Some viewers show only base color")
    private static let geometryOnlyNote = NSPredicate(
        format: "label BEGINSWITH %@", "Writes one .obj with UVs")
    private static let fallbackNote = NSPredicate(
        format: "label BEGINSWITH %@", "Some face materials couldn't be resolved")

    func testOBJOptionsBundlePlainSeparateAndCancel() throws {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .landscapeLeft
        let app = XCUIApplication()
        app.launchArguments = CADNativeSheetLaunch.ipad
        app.launch()
        defer { app.terminate() }
        XCTAssertTrue(app.buttons["UndoButton"].waitForExistence(timeout: 60))

        CADSheetProbe.openOBJOptions(app, compact: false)
        let materials = CADSheetProbe.toggle("ExportIncludeMaterialsToggle", in: app)
        XCTAssertTrue(materials.waitForExistence(timeout: 15))
        XCTAssertTrue(CADSheetProbe.waitForValue(materials, "1"),
                      "the OBJ bundle must start with materials and textures included")

        let summary = CADSheetProbe.any(app, "ExportBundleSummary")
        XCTAssertTrue(CADSheetProbe.scrollReveal(summary, in: app, sheet: "OBJ Export"),
                      "the real .zip preflight must summarise its contents before export")
        XCTAssertTrue(summary.label.contains(" files"), summary.label)
        XCTAssertTrue(summary.label.contains("MB"), summary.label)
        let mtlNote = app.staticTexts.matching(Self.mtlViewerNote).firstMatch
        XCTAssertTrue(CADSheetProbe.scrollReveal(mtlNote, in: app, sheet: "OBJ Export",
                                                 timeout: 30),
                      "the bundle must state the real MTL viewer limitation before export")
        let confirm = app.buttons["MeshExportConfirm"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 15))
        XCTAssertTrue(CADSheetProbe.waitForLabelEquals(confirm, "Export"))
        XCTAssertTrue(confirm.isEnabled)
        CADSheetProbe.attach("E29 OBJ bundle summary", to: self)

        // "Separate File per Body" is a stable native choice.
        let perBody = CADSheetProbe.toggle("ExportPerBodyToggle", in: app)
        CADSheetProbe.reveal(perBody, in: app, sheet: "OBJ Export")
        XCTAssertTrue(CADSheetProbe.waitForValue(perBody, "0"),
                      "the OBJ bundle must start as one file per export")
        XCTAssertTrue(CADSheetProbe.setToggle(perBody, "1"),
                      "the native Separate File per Body switch must turn on")
        XCTAssertTrue(CADSheetProbe.waitForEnabled(confirm, timeout: 90))
        XCTAssertTrue(CADSheetProbe.scrollReveal(summary, in: app, sheet: "OBJ Export"))
        CADSheetProbe.reveal(perBody, in: app, sheet: "OBJ Export")
        XCTAssertTrue(CADSheetProbe.setToggle(perBody, "0"),
                      "the native Separate File per Body switch must turn off")
        XCTAssertTrue(CADSheetProbe.waitForEnabled(confirm, timeout: 90))
        XCTAssertTrue(CADSheetProbe.scrollReveal(summary, in: app, sheet: "OBJ Export"))

        // Materials OFF is one real .obj: the bundle summary must retire.
        CADSheetProbe.reveal(materials, in: app, sheet: "OBJ Export")
        XCTAssertTrue(CADSheetProbe.setToggle(materials, "0"),
                      "the native Materials & Textures switch must turn off")
        XCTAssertTrue(CADSheetProbe.waitForAbsence(summary, timeout: 20),
                      "a single .obj must not keep a stale .zip summary")
        let geometryNote = app.staticTexts.matching(Self.geometryOnlyNote).firstMatch
        CADSheetProbe.reveal(geometryNote, in: app, sheet: "OBJ Export")
        XCTAssertTrue(geometryNote.exists)
        XCTAssertTrue(CADSheetProbe.waitForLabelEquals(confirm, "Export"))
        XCTAssertTrue(CADSheetProbe.waitForEnabled(confirm, timeout: 20))

        // Cancel must not stage an export.
        app.buttons["MeshExportCancel"].tap()
        XCTAssertTrue(CADSheetProbe.waitForAbsence(app.navigationBars["OBJ Export"],
                                                   timeout: 20))
        XCTAssertTrue(app.buttons["ExportMenu"].isHittable)
        XCTAssertFalse(app.navigationBars["Save"].exists,
                       "cancelling the options must not present the file exporter")
        CADSheetProbe.attach("E29 OBJ options cancelled without export", to: self)

        // A second open starts a fresh default review.
        CADSheetProbe.openOBJOptions(app, compact: false)
        let reopenedToggle = CADSheetProbe.toggle("ExportIncludeMaterialsToggle", in: app)
        CADSheetProbe.reveal(reopenedToggle, in: app, sheet: "OBJ Export")
        XCTAssertTrue(CADSheetProbe.waitForValue(reopenedToggle, "1"))
        XCTAssertTrue(CADSheetProbe.scrollReveal(summary, in: app, sheet: "OBJ Export"))
        app.buttons["MeshExportCancel"].tap()
    }

    /// The launch fixture DELIBERATELY saves one malformed face-material
    /// binding (an explicit fault-injected input). A normal reopen keeps its
    /// real face range after the E29 repair, so this negative receipt must come
    /// from that malformed input, never from ordinary document reopening.
    func testOBJOptionsShowPartialCoverageConsentBeforeSaving() throws {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .landscapeLeft
        let app = XCUIApplication()
        app.launchArguments = CADNativeSheetLaunch.ipad + ["--ui-test-cad-obj-coverage"]
        app.launch()
        defer { app.terminate() }
        XCTAssertTrue(app.buttons["UndoButton"].waitForExistence(timeout: 60))

        CADSheetProbe.openOBJOptions(app, compact: false)
        let materials = CADSheetProbe.toggle("ExportIncludeMaterialsToggle", in: app)
        XCTAssertTrue(materials.waitForExistence(timeout: 15))
        XCTAssertTrue(CADSheetProbe.waitForValue(materials, "1"),
                      "the shared coverage receipt must be reviewed with materials included")
        // The Objects row is above the warning rows, so assert its own native
        // `LabeledContent` text before any downward Form walk.
        let objectsRow = CADSheetProbe.labeledRow("Objects", in: app)
        XCTAssertTrue(objectsRow.waitForExistence(timeout: 20),
                      "the shared coverage receipt must expose its included/total Objects row")
        let objectsText = CADSheetProbe.labeledText(objectsRow)
        XCTAssertTrue(objectsText.contains("2 / 2"),
                      "both real bodies must stay included in the shared receipt: \(objectsText)")
        let faceWarning = app.staticTexts["A face material needs reassignment."]
        XCTAssertTrue(CADSheetProbe.scrollReveal(faceWarning, in: app, sheet: "OBJ Export",
                                                 timeout: 30),
                      "the shared coverage receipt must name the malformed face material")
        XCTAssertTrue(app.staticTexts["Material warnings"].exists)

        let confirm = app.buttons["MeshExportConfirm"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 15))
        XCTAssertTrue(CADSheetProbe.waitForLabelEquals(confirm, "Export Included"),
                      "an incomplete receipt must ask for explicit partial consent")
        let summary = CADSheetProbe.any(app, "ExportBundleSummary")
        XCTAssertTrue(CADSheetProbe.scrollReveal(summary, in: app, sheet: "OBJ Export"),
                      "the accepted partial bundle must still preflight its real bytes")
        let fallback = app.staticTexts.matching(Self.fallbackNote).firstMatch
        XCTAssertTrue(CADSheetProbe.scrollReveal(fallback, in: app, sheet: "OBJ Export",
                                                 timeout: 30),
                      "the preflight must report the real face-material fallback")
        XCTAssertTrue(CADSheetProbe.waitForEnabled(confirm, timeout: 30),
                      "the explicit partial bundle must be exportable after review")
        CADSheetProbe.attach("E29 OBJ partial coverage consent", to: self)

        // Geometry-only OBJ carries no face materials, so the same document is
        // complete there: no partial label and no stale bundle summary.
        CADSheetProbe.reveal(materials, in: app, sheet: "OBJ Export")
        XCTAssertTrue(CADSheetProbe.setToggle(materials, "0"),
                      "the native Materials & Textures switch must turn off")
        XCTAssertTrue(CADSheetProbe.waitForAbsence(summary, timeout: 20))
        XCTAssertTrue(CADSheetProbe.waitForLabelEquals(confirm, "Export"))
        XCTAssertTrue(CADSheetProbe.waitForEnabled(confirm, timeout: 20))
        app.buttons["MeshExportCancel"].tap()
        XCTAssertTrue(CADSheetProbe.waitForAbsence(app.navigationBars["OBJ Export"],
                                                   timeout: 20))
    }

    func testOBJOptionsRefuseUnsupportedMaterialBeforeExport() throws {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .landscapeLeft
        let app = XCUIApplication()
        app.launchArguments = CADNativeSheetLaunch.ipad + ["--ui-test-cad-obj-refusal"]
        app.launch()
        defer { app.terminate() }
        XCTAssertTrue(app.buttons["UndoButton"].waitForExistence(timeout: 60))

        CADSheetProbe.openOBJOptions(app, compact: false)
        let materials = CADSheetProbe.toggle("ExportIncludeMaterialsToggle", in: app)
        XCTAssertTrue(materials.waitForExistence(timeout: 15))
        let refusal = CADSheetProbe.any(app, "ExportBundleRefusal")
        XCTAssertTrue(CADSheetProbe.scrollReveal(refusal, in: app, sheet: "OBJ Export"),
                      "the real OBJ preflight must refuse the unsupported material")
        XCTAssertTrue(refusal.label.contains("Emission strength above 1"), refusal.label)
        let glowWarning = app.staticTexts["This format cannot keep this glow strength."]
        XCTAssertTrue(CADSheetProbe.scrollReveal(glowWarning, in: app, sheet: "OBJ Export",
                                                 timeout: 30),
                      "the shared receipt must explain the fidelity loss before export")
        let confirm = app.buttons["MeshExportConfirm"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 15))
        XCTAssertTrue(CADSheetProbe.waitForLabelEquals(confirm, "Export Included"))
        XCTAssertFalse(confirm.isEnabled,
                       "a refused bundle must stay non-exportable even with partial consent")
        CADSheetProbe.attach("E29 OBJ refusal before export", to: self)

        // The same geometry stays a complete single .obj without materials.
        CADSheetProbe.reveal(materials, in: app, sheet: "OBJ Export")
        XCTAssertTrue(CADSheetProbe.setToggle(materials, "0"),
                      "the native Materials & Textures switch must turn off")
        XCTAssertTrue(CADSheetProbe.waitForAbsence(refusal, timeout: 20))
        XCTAssertTrue(CADSheetProbe.waitForLabelEquals(confirm, "Export"))
        XCTAssertTrue(CADSheetProbe.waitForEnabled(confirm, timeout: 20))
        app.buttons["MeshExportCancel"].tap()
        XCTAssertTrue(CADSheetProbe.waitForAbsence(app.navigationBars["OBJ Export"],
                                                   timeout: 20))
    }

    func testOBJOptionsRemainReachableWithNarrowLargeText() throws {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchArguments = CADNativeSheetLaunch.compact
        app.launch()
        defer { app.terminate() }
        XCTAssertTrue(app.otherElements["CADFixtureHarness"].waitForExistence(timeout: 60))

        CADSheetProbe.openOBJOptions(app, compact: true)
        let materials = CADSheetProbe.toggle("ExportIncludeMaterialsToggle", in: app)
        XCTAssertTrue(materials.waitForExistence(timeout: 20))
        XCTAssertTrue(CADSheetProbe.waitForValue(materials, "1"))
        let summary = CADSheetProbe.any(app, "ExportBundleSummary")
        XCTAssertTrue(CADSheetProbe.scrollReveal(summary, in: app, sheet: "OBJ Export"),
                      "the narrow large-text OBJ form must keep the real summary reachable")
        XCTAssertTrue(app.buttons["MeshExportConfirm"].isHittable)
        XCTAssertTrue(app.buttons["MeshExportCancel"].isHittable)
        CADSheetProbe.attach("E29 OBJ options - narrow large text", to: self)
        app.buttons["MeshExportCancel"].tap()
        XCTAssertTrue(CADSheetProbe.waitForAbsence(app.navigationBars["OBJ Export"],
                                                   timeout: 20))
        XCTAssertTrue(app.buttons["CADCompactMoreMenu"].isHittable)
    }
}

// MARK: - X30 direct native editor export recovery

@MainActor
private enum CADEditorExportRecoveryLaunch {
    static let reset = "--ui-test-cad-recovery-reset"
    static let interrupted = "--ui-test-cad-recovery-interrupted"
    static let completed = "--ui-test-cad-recovery-completed"
    static let cancelled = "--ui-test-cad-recovery-cancelled"
    static let empty = "--ui-test-cad-recovery-empty"

    static func arguments(_ mode: String? = nil, reset: Bool) -> [String] {
        CADNativeSheetLaunch.ipad
            + (mode.map { [$0] } ?? [])
            + (reset ? [Self.reset] : [])
    }

    static func app(_ mode: String? = nil, reset: Bool) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = arguments(mode, reset: reset)
        return app
    }
}

@MainActor
final class CADEditorAnimationExportRecoveryUITests: XCTestCase {
    private let noticeIdentifier = "CADAnimationExportRecovery"

    func testInterruptedNoticeRestoresExactChoicesWithoutStartingExport() throws {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .landscapeLeft
        let app = CADEditorExportRecoveryLaunch.app(
            CADEditorExportRecoveryLaunch.interrupted, reset: true)
        app.launch()
        defer { app.terminate() }
        openPresent(app)

        let notice = CADSheetProbe.any(app, noticeIdentifier)
        XCTAssertTrue(notice.waitForExistence(timeout: 30),
                      "the real interrupted export record must render its native Present notice")
        XCTAssertTrue(CADSheetProbe.waitForLabel(notice, contains: "Video export interrupted",
                                                 timeout: 10))
        let details = app.staticTexts.matching(NSPredicate(
            format: "label CONTAINS %@ AND label CONTAINS %@ AND label CONTAINS %@ "
                + "AND label CONTAINS %@",
            argumentArray: ["Recovery animation.mp4", "720×1280", "24 fps", "HEVC"]
        )).firstMatch
        XCTAssertTrue(details.waitForExistence(timeout: 10),
                      "the notice must describe the exact saved portrait/720/24/HEVC choices")

        let restore = app.buttons["CADAnimationExportRecoveryRestore"]
        XCTAssertTrue(CADSheetProbe.waitForHittable(restore, timeout: 20),
                      "the notice's real Use settings control must be reachable")
        assertNoExportStarted(app)
        CADSheetProbe.attach("X30 interrupted notice - exact saved choices", to: self)

        restore.tap()
        let cancel = app.buttons["CADAnimationExportOptionsCancel"]
        XCTAssertTrue(cancel.waitForExistence(timeout: 15),
                      "Use settings must open the shipped native export options sheet")
        assertPickerShows(app, "CADAnimationExportOrientation", "Portrait")
        assertPickerShows(app, "CADAnimationExportResolution", "720p")
        assertPickerShows(app, "CADAnimationExportFrameRate", "24 fps")
        assertPickerShows(app, "CADAnimationExportCodec", "HEVC (smaller)")
        assertPickerShows(app, "CADAnimationExportQuality", "Higher quality")
        XCTAssertTrue(app.staticTexts["36 frames"].waitForExistence(timeout: 5),
                      "the 1.5 s clip at 24 fps must show the real 36-frame estimate")
        CADSheetProbe.attach("X30 restored export sheet - portrait 720 24 HEVC higher", to: self)

        cancel.tap()
        XCTAssertTrue(CADSheetProbe.waitForAbsence(cancel, timeout: 10))
        assertNoExportStarted(app)

        // Cancelling the restored sheet must not dismiss the durable record.
        app.terminate()
        app.launchArguments = CADEditorExportRecoveryLaunch.arguments(
            CADEditorExportRecoveryLaunch.interrupted, reset: false)
        app.launch()
        openPresent(app)
        let reopenedNotice = CADSheetProbe.any(app, noticeIdentifier)
        XCTAssertTrue(reopenedNotice.waitForExistence(timeout: 30),
                      "the untouched interrupted record must reopen with the same document")
        assertNoExportStarted(app)
        CADSheetProbe.attach("X30 interrupted record remains after app and document reopen",
                             to: self)
    }

    func testDismissalSurvivesAppAndDocumentReopen() throws {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .landscapeLeft
        let app = CADEditorExportRecoveryLaunch.app(
            CADEditorExportRecoveryLaunch.interrupted, reset: true)
        app.launch()
        defer { app.terminate() }
        openPresent(app)

        let notice = CADSheetProbe.any(app, noticeIdentifier)
        XCTAssertTrue(notice.waitForExistence(timeout: 30))
        let dismiss = app.buttons["CADAnimationExportRecoveryDismiss"]
        XCTAssertTrue(CADSheetProbe.waitForHittable(dismiss, timeout: 20))
        CADSheetProbe.attach("X30 interrupted notice before durable dismissal", to: self)
        dismiss.tap()
        XCTAssertTrue(CADSheetProbe.waitForAbsence(notice, timeout: 20),
                      "Dismiss must clear the notice through the production registry adapter")
        XCTAssertTrue(app.buttons["CADPresentExport"].waitForExistence(timeout: 10),
                      "the Present controls must remain usable after dismissal")
        CADSheetProbe.attach("X30 interrupted notice dismissed", to: self)

        app.terminate()
        app.launchArguments = CADEditorExportRecoveryLaunch.arguments(
            CADEditorExportRecoveryLaunch.interrupted, reset: false)
        app.launch()
        openPresent(app)
        let reopenedNotice = CADSheetProbe.any(app, noticeIdentifier)
        XCTAssertFalse(reopenedNotice.waitForExistence(timeout: 5),
                       "a durable dismissal must survive a new process reopening the same document")
        assertNoExportStarted(app)
        CADSheetProbe.attach("X30 dismissed recovery absent after app and document reopen",
                             to: self)
    }

    func testCompletedCancelledAndEmptyInputShowNoNotice() throws {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .landscapeLeft
        assertNoNotice(mode: CADEditorExportRecoveryLaunch.completed,
                       label: "completed")
        assertNoNotice(mode: CADEditorExportRecoveryLaunch.cancelled,
                       label: "cancelled")
        assertNoNotice(mode: CADEditorExportRecoveryLaunch.empty,
                       label: "no-record")
    }

    private func openPresent(_ app: XCUIApplication) {
        XCTAssertTrue(app.buttons["UndoButton"].waitForExistence(timeout: 60),
                      "the real saved recovery fixture must open in the workbench")
        CADSheetProbe.enterPresent(app)
        CADSheetProbe.waitForPresentSurface(app)
        XCTAssertTrue(app.buttons["CADPresentExport"].waitForExistence(timeout: 20))
    }

    private func assertNoNotice(mode: String, label: String) {
        let app = CADEditorExportRecoveryLaunch.app(mode, reset: true)
        app.launch()
        defer { app.terminate() }
        openPresent(app)
        let notice = CADSheetProbe.any(app, noticeIdentifier)
        XCTAssertFalse(notice.waitForExistence(timeout: 5),
                       "\(label) recovery input must not render an interrupted notice")
        assertNoExportStarted(app)
        CADSheetProbe.attach("X30 \(label) recovery input shows no notice", to: self)
    }

    private func assertNoExportStarted(
        _ app: XCUIApplication,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let progress = app.descendants(matching: .any)
            .matching(identifier: "CADAnimationExportProgress").firstMatch
        XCTAssertFalse(progress.waitForExistence(timeout: 2),
                       "opening recovery metadata must not start an exporter frame loop",
                       file: file, line: line)
        XCTAssertFalse(app.buttons["CADAnimationExportOptionsConfirm"].exists,
                       "recovery metadata must not open the export options sheet by itself",
                       file: file, line: line)
        XCTAssertFalse(app.navigationBars["Save"].exists,
                       "recovery metadata must not present a file exporter by itself",
                       file: file, line: line)
    }

    private func assertPickerShows(
        _ app: XCUIApplication,
        _ identifier: String,
        _ expected: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let picker = app.buttons[identifier]
        XCTAssertTrue(picker.waitForExistence(timeout: 10),
                      "missing native choice \(identifier)", file: file, line: line)
        XCTAssertTrue(waitForPickerValue(picker, expected),
                      "\(identifier) must restore \(expected); label=\(picker.label) "
                        + "value=\(String(describing: picker.value))",
                      file: file, line: line)
    }

    private func waitForPickerValue(_ element: XCUIElement, _ expected: String,
                                    timeout: TimeInterval = 20) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let value = (element.value as? String) ?? ""
            if value == expected || value.contains(expected) || element.label.contains(expected) {
                return true
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        let value = (element.value as? String) ?? ""
        return value == expected || value.contains(expected) || element.label.contains(expected)
    }
}

/// Drives shipped sheets and controls. Exact curved geometry, texture pixels,
/// saved UVs and two-copy conflict/rollback semantics have separate native tests.
@MainActor
final class CADNativeUVAndCopyMergeFlowUITests: XCTestCase {
    func testIPadUVEditorUnwrapTransformPackHistoryPreviewAndReturn() throws {
        try checkUV(compact: false, edit: true)
    }

    func testCompactLargeTextUVEditorRemainsReachable() throws {
        try checkUV(compact: true, edit: false)
    }

    func testIPadCopyMergeEntryUsesNativeSheetAndRequiresInputs() throws {
        try checkMerge(compact: false)
    }

    func testCompactLargeTextCopyMergeEntryRemainsReachable() throws {
        try checkMerge(compact: true)
    }

    private func launch(compact: Bool) -> XCUIApplication {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = compact ? .portrait : .landscapeLeft
        let app = XCUIApplication()
        app.launchArguments = ["-AppleLanguages", "(en)", "-AppleLocale", "en_US",
            "-ui-testing", "--ui-test-cad-fixture", "--ui-test-cad-uninstanced"]
        app.launchArguments += compact
            ? ["--ui-test-cad-compact", "--ui-test-cad-large-text"] : ["-ui-testing-ipad"]
        app.launch()
        XCTAssertTrue(app.buttons["UndoButton"].waitForExistence(timeout: 60))
        return app
    }

    private func reveal(_ element: XCUIElement, sheet: String, app: XCUIApplication,
                        searchEarlierRowsFirst: Bool = false) {
        CADSheetProbe.reveal(element, in: app, sheet: sheet, swipes: 14,
                             searchEarlierRowsFirst: searchEarlierRowsFirst)
        XCTAssertTrue(element.exists && element.isHittable, "The native control must be visible: \(element)")
    }

    private func ready(_ app: XCUIApplication) {
        let running = app.buttons["CADUVOperationCancel"]
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == false"), object: running)],
            timeout: 30), .completed)
        XCTAssertFalse(app.staticTexts["CADUVError"].exists, "A failed edit must not be accepted as ready")
    }

    private func snapshot(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func checkUV(compact: Bool, edit: Bool) throws {
        let app = launch(compact: compact)
        defer { app.terminate() }
        app.segmentedControls["CADWorkbenchMode"].buttons["Present"].tap()
        let surface = app.descendants(matching: .any)
            .matching(identifier: "CADPresentationSurface").firstMatch
        XCTAssertTrue(surface.waitForExistence(timeout: 30))
        let granularity = app.segmentedControls["CADPresentSelectionMode"]
        XCTAssertTrue(granularity.waitForExistence(timeout: 10))
        if compact {
            let more = app.buttons["CADPresentMoreMenu"]
            XCTAssertTrue(more.waitForExistence(timeout: 15) && more.isHittable)
            snapshot("X09 compact large text adaptive presentation toolbar")
            more.tap()
            for identifier in ["CADPresentAnimation", "CADPresentEnvironment", "CADPresentCamera", "CADPresentOverlays", "CADPresentExport"] {
                XCTAssertTrue(app.buttons[identifier].waitForExistence(timeout: 10))
            }
            app.buttons["CADPresentCamera"].tap()
            XCTAssertTrue(app.buttons["CADPresentCameraDone"].waitForExistence(timeout: 15))
            app.buttons["CADPresentCameraDone"].tap()
        }
        app.buttons["CADPresentFit"].tap()
        granularity.buttons["Body"].tap()
        // Use the fixture's real top face, projected through the production
        // Fit camera, as in the existing unpainted-face acceptance flow.
        // Opening Material with no selection deliberately has no body UVs.
        let azimuth = Double.pi * 0.22
        let elevation = Double.pi * 0.12
        let halfFov = Double.pi / 6
        let radius = sqrt(100.0 * 100 + 10.0 * 10 + 60.0 * 60) / 2
        let aspect = Double(surface.frame.width / surface.frame.height)
        let fittedTangent = max(tan(halfFov) * min(1, aspect), 0.05)
        let distance = max(radius / fittedTangent * 1.18, radius * 1.6)
        let horizontal = -25 * cos(azimuth)
        let vertical = 25 * sin(azimuth) * sin(elevation) + 5 * cos(elevation)
        let depth = distance - (-25 * cos(elevation) * sin(azimuth) + 5 * sin(elevation))
        let x = 0.5 + horizontal / (2 * depth * tan(halfFov) * aspect)
        let y = 0.5 - vertical / (2 * depth * tan(halfFov))
        XCTAssertGreaterThan(x, 0.1)
        XCTAssertLessThan(x, 0.9)
        XCTAssertGreaterThan(y, 0.1)
        XCTAssertLessThan(y, 0.9)
        surface.coordinate(withNormalizedOffset: CGVector(dx: x, dy: y)).tap()
        XCTAssertTrue(app.staticTexts["CADPresentSelection"].waitForExistence(timeout: 20),
                      "UV editing requires a real selected body")
        let material = app.buttons["CADPresentMaterial"]
        XCTAssertTrue(material.waitForExistence(timeout: 30))
        material.tap()
        XCTAssertTrue(app.descendants(matching: .any)
            .matching(identifier: "CADMaterialSelectedTarget").firstMatch.waitForExistence(timeout: 15))
        let open = app.buttons["CADMaterialOpenUVEditor"]
        reveal(open, sheet: "Material", app: app)
        open.tap()
        let done = app.buttons["CADUVDone"]
        XCTAssertTrue(done.waitForExistence(timeout: 20) && done.isHittable)
        let seams = app.descendants(matching: .any).matching(identifier: "CADUVSeamCanvas").firstMatch
        XCTAssertTrue(seams.waitForExistence(timeout: 20))
        snapshot(compact ? "X09 compact large text native UV editor" : "X09 native UV seams and controls")
        if edit {
            let unwrap = app.buttons["CADUVUnwrap"]
            reveal(unwrap, sheet: "UV Editor", app: app)
            unwrap.tap()
            let islands = app.descendants(matching: .any).matching(identifier: "CADUVIslandCanvas").firstMatch
            ready(app)
            reveal(islands, sheet: "UV Editor", app: app)
            snapshot("X09 actual native UV islands after unwrap")
            let move = app.textFields["CADUVField-cad.uv.moveU"]
            reveal(move, sheet: "UV Editor", app: app)
            move.tap()
            let previous = move.value as? String ?? "0"
            move.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: previous.count) + "0.25")
            let hide = app.buttons["Hide keyboard"].firstMatch
            if hide.exists && hide.isHittable { hide.tap() }
            let apply = app.buttons["CADUVApplyTransform"]
            reveal(apply, sheet: "UV Editor", app: app)
            XCTAssertTrue(apply.isEnabled)
            apply.tap()
            ready(app)
            let pack = app.buttons["Pack Islands"]
            reveal(pack, sheet: "UV Editor", app: app, searchEarlierRowsFirst: true)
            pack.tap()
            ready(app)
            let undo = app.buttons["CADUVUndo"]
            reveal(undo, sheet: "UV Editor", app: app)
            XCTAssertTrue(undo.isEnabled)
            undo.tap()
            let redo = app.buttons["CADUVRedo"]
            XCTAssertTrue(redo.waitForExistence(timeout: 10) && redo.isEnabled)
            redo.tap()
            ready(app)
            let preview = app.buttons["Refresh 3D Preview"]
            reveal(preview, sheet: "UV Editor", app: app, searchEarlierRowsFirst: true)
            preview.tap()
            let image = app.descendants(matching: .any).matching(identifier: "CADUVActual3DPreview").firstMatch
            XCTAssertTrue(image.waitForExistence(timeout: 20))
            reveal(image, sheet: "UV Editor", app: app)
            snapshot("X09 native UV editor actual 3D preview after transform pack and history")
        }
        done.tap()
        XCTAssertTrue(app.buttons["CADMaterialCancel"].waitForExistence(timeout: 15))
        app.buttons["CADMaterialCancel"].tap()
        app.segmentedControls["CADWorkbenchMode"].buttons["Edit"].tap()
        XCTAssertTrue(app.buttons["UndoButton"].waitForExistence(timeout: 15))
    }

    private func checkMerge(compact: Bool) throws {
        let app = launch(compact: compact)
        defer { app.terminate() }
        let versions = app.buttons["CADVersionsButton"]
        if !versions.exists {
            let more = app.buttons["CADCompactMoreMenu"]
            XCTAssertTrue(more.waitForExistence(timeout: 10))
            more.tap()
        }
        XCTAssertTrue(versions.waitForExistence(timeout: 15))
        versions.tap()
        CADSheetProbe.expandSheet("Design Versions", in: app)
        let merge = app.buttons["CADVersionsMergeCopiesButton"]
        reveal(merge, sheet: "Design Versions", app: app)
        merge.tap()
        let cancel = app.buttons["CADMergeCancelButton"]
        XCTAssertTrue(cancel.waitForExistence(timeout: 15) && cancel.isHittable)
        XCTAssertTrue(app.buttons["CADMergeSourcePicker"].exists)
        XCTAssertFalse(app.buttons["CADMergeCompareButton"].isEnabled)
        XCTAssertFalse(app.buttons["CADMergeApplyButton"].isEnabled)
        snapshot(compact ? "E35 compact large text native copy merge sheet" : "E35 native copy merge inputs")
        cancel.tap()
        let close = app.buttons["CADVersionsCloseButton"]
        XCTAssertTrue(close.waitForExistence(timeout: 15) && close.isHittable)
        close.tap()
        XCTAssertTrue(app.buttons["UndoButton"].waitForExistence(timeout: 15))
    }
}

@MainActor
final class CADThreadOptionsNativeFlowUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .landscapeLeft
    }

    func testNativeThreadOptionsAndCancel() { checkOptions(compact: false) }
    func testCompactLargeTextThreadOptionsAndCancel() { checkOptions(compact: true) }

    func testNativeThreadAppliesCompatibleBoreDimensions() { checkOptions(compact: false, applyChanges: true) }

    private func checkOptions(compact: Bool, applyChanges: Bool = false) {
        let app = XCUIApplication()
        app.launchArguments = ["-AppleLanguages", "(en)", "-AppleLocale", "en_US",
            "-ui-testing", "--ui-test-cad-fixture", "--ui-test-cad-uninstanced"]
        app.launchArguments += compact
            ? ["--ui-test-cad-compact", "--ui-test-cad-large-text"] : ["-ui-testing-ipad"]
        app.launch()
        defer { app.terminate() }
        XCTAssertTrue(app.buttons["UndoButton"].waitForExistence(timeout: 60))
        let modify = app.buttons["ModifyGroup"]
        XCTAssertTrue(modify.waitForExistence(timeout: 15) && modify.isHittable)
        modify.tap()
        let entry = app.buttons["CADThreadButton"]
        XCTAssertTrue(entry.waitForExistence(timeout: 15) && entry.isHittable)
        entry.tap()
        let cancel = app.buttons["CADThreadCancel"]
        XCTAssertTrue(cancel.waitForExistence(timeout: 20) && cancel.isHittable)
        let length = app.textFields["CADThreadLength"]
        CADSheetProbe.reveal(length, in: app, sheet: "Metric thread")
        XCTAssertTrue(length.exists && length.isHittable)
        let apply = app.buttons["CADThreadApply"]
        XCTAssertTrue(apply.exists && apply.isHittable && apply.isEnabled,
                      "The real bore must be available through the native source query")
        let image = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        image.name = compact ? "M13 native thread options compact large text" : "M13 native metric thread options"
        image.lifetime = .keepAlways
        add(image)
        if applyChanges {
            apply.tap()
            let closed = NSPredicate(format: "exists == false")
            expectation(for: closed, evaluatedWith: cancel)
            waitForExpectations(timeout: 90)
        } else { cancel.tap() }
        XCTAssertFalse(app.buttons["CADThreadCancel"].waitForExistence(timeout: 2))
        XCTAssertTrue(app.buttons["UndoButton"].waitForExistence(timeout: 15))
    }
}
@MainActor
final class CADExternalProjectionNativeFlowUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .landscapeLeft
    }

    override func tearDownWithError() throws {
        XCUIApplication().terminate()
    }

    private func launch(broken: Bool, compact: Bool = false) -> XCUIApplication {
        let app = XCUIApplication()
        app.terminate()
        app.launchArguments = ["-AppleLanguages", "(en)", "-AppleLocale", "en_US", "-ui-testing",
            "--ui-test-cad-fixture", "--ui-test-cad-projection"]
        if broken { app.launchArguments += ["--ui-test-cad-projection-broken"] }
        app.launchArguments += compact ? ["--ui-test-cad-compact", "--ui-test-cad-large-text"] : ["-ui-testing-ipad"]
        app.launch()
        XCTAssertTrue(app.buttons["UndoButton"].waitForExistence(timeout: 60), app.debugDescription)
        waitState(app, ["ready=true"])
        if app.alerts.firstMatch.exists {
            let okay = app.alerts.buttons["OK"]
            XCTAssertTrue(okay.exists); okay.tap()
        }
        return app
    }

    private func element(_ app: XCUIApplication, _ id: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: id).firstMatch
    }

    private func waitState(_ app: XCUIApplication, _ terms: [String], timeout: TimeInterval = 30) {
        let state = element(app, "CADProjectionState")
        let predicate = NSPredicate { _, _ in state.exists && terms.allSatisfy { state.label.contains($0) } }
        let expected = XCTNSPredicateExpectation(predicate: predicate, object: state)
        let result = XCTWaiter.wait(for: [expected], timeout: timeout)
        if result != .completed {
            capture("M05 live state failure")
            let details = "state=\(state.exists ? state.label : "missing") camera=\(element(app, "CADProjectionCamera").label) tree=\(element(app, "CADProjectionViewTree").label) edge=\(element(app, "CADProjectionEdgeScreen").label) line=\(element(app, "CADProjectionLineScreen").label)"
            let attachment = XCTAttachment(string: details + "\n" + app.debugDescription)
            attachment.name = "M05 actual camera and native hierarchy"
            attachment.lifetime = .keepAlways; add(attachment)
        }
        XCTAssertEqual(result, .completed, "Expected \(terms); actual \(state.exists ? state.label : "missing")")
    }

    private func reveal(_ button: XCUIElement, in app: XCUIApplication) {
        for _ in 0..<6 {
            if button.exists && button.isHittable { return }
            let palette = app.scrollViews["ToolPalette"]
            if palette.exists { palette.swipeUp() }
        }
        XCTAssertTrue(button.exists && button.isHittable, app.debugDescription)
    }

    private func tapWorldReadback(_ id: String, in app: XCUIApplication) {
        let text = element(app, id)
        XCTAssertTrue(text.waitForExistence(timeout: 15))
        let values = text.label.split(separator: ",").compactMap { Double($0) }
        XCTAssertEqual(values.count, 2, text.label)
        guard values.count == 2 else { return }
        let viewport = element(app, "CADEditorViewport")
        XCTAssertTrue(viewport.exists && viewport.frame.width > 0)
        XCTAssertGreaterThan(values[0], 0); XCTAssertGreaterThan(values[1], 0)
        XCTAssertLessThan(values[0], Double(viewport.frame.width))
        XCTAssertLessThan(values[1], Double(viewport.frame.height))
        viewport.coordinate(withNormalizedOffset: .zero)
            .withOffset(CGVector(dx: CGFloat(values[0]), dy: CGFloat(values[1]))).tap()
    }

    private func capture(_ title: String) {
        let image = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        image.name = title; image.lifetime = .keepAlways; add(image)
    }

    private func save(_ app: XCUIApplication) {
        app.buttons["cad.host.save"].tap()
        let outcome = element(app, "cad.host.saveOutcome")
        XCTAssertTrue(outcome.waitForExistence(timeout: 60))
        XCTAssertEqual(outcome.label, "Saved")
    }

    func testProjectPaletteAndActualViewportTapCreateOneLinkedEdge() {
        let app = launch(broken: false); defer { app.terminate() }
        waitState(app, ["references=0", "entities=0", "broken=0"])
        let project = app.buttons["Project"]
        reveal(project, in: app); project.tap()
        waitState(app, ["armed=true"])
        tapWorldReadback("CADProjectionEdgeScreen", in: app)
        waitState(app, ["references=1", "entities=1", "broken=0"])
        XCTAssertEqual(element(app, "CADProjectionError").label, "none")
        capture("M05 actual Project tool viewport edge selection")
        app.buttons["UndoButton"].tap()
        waitState(app, ["references=0", "entities=0"])
        app.buttons["RedoButton"].tap()
        waitState(app, ["references=1", "entities=1"])
        save(app)
    }

    func testBrokenLinkWarningAndNativeDetachKeepLineUndoRedoAndSave() {
        let app = launch(broken: true); defer { app.terminate() }
        waitState(app, ["references=1", "entities=1", "broken=1"])
        let warning = element(app, "CADExternalProjectionBrokenWarning")
        XCTAssertTrue(warning.exists)
        capture("M05 actual missing source warning")
        tapWorldReadback("CADProjectionLineScreen", in: app)
        waitState(app, ["selected=1"])
        let detach = app.buttons["DetachProjectionButton"]
        reveal(detach, in: app)
        XCTAssertTrue(detach.isEnabled); detach.tap()
        waitState(app, ["references=0", "entities=1", "broken=0"])
        XCTAssertFalse(warning.exists)
        capture("M05 native Detach preserves projected line")
        app.buttons["UndoButton"].tap()
        waitState(app, ["references=1", "entities=1", "broken=1"])
        app.buttons["RedoButton"].tap()
        waitState(app, ["references=0", "entities=1", "broken=0"])
        save(app)
    }

    func testCompactLargeTextBrokenLinkAndDetachControlRemainVisible() {
        let app = launch(broken: true, compact: true); defer { app.terminate() }
        waitState(app, ["references=1", "entities=1", "broken=1"])
        XCTAssertTrue(element(app, "CADExternalProjectionBrokenWarning").exists)
        let detach = app.buttons["DetachProjectionButton"]
        reveal(detach, in: app)
        let viewport = element(app, "CADEditorViewport")
        let status = element(app, "SketchStatusPill")
        XCTAssertTrue(status.exists)
        XCTAssertLessThan(status.frame.height, viewport.frame.height * 0.35,
            "Large text status must leave the drawing surface usable")
        XCTAssertLessThanOrEqual(status.frame.width, viewport.frame.width)
        XCTAssertTrue(app.buttons["ExitSketchingButton"].isHittable)
        capture("M05 compact large text warning and native controls")
    }
}
#endif
