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
#endif
