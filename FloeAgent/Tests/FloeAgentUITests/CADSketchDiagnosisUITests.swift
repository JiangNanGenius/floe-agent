// FloeAgentUITests — native workbench acceptance for the original M02/M06/M19
// remaining UI clauses.
//
// The `--ui-test-cad-sketch-loop`, `--ui-test-cad-sketch-conflict` and
// `--ui-test-cad-face-rotation` launch arguments open the REAL FloeCAD
// workbench on fixed synthetic documents built with the production Sketch /
// FeatureNode / document-command types (and, for the face rotation, the real
// kernel replay). Nothing here substitutes a solver verdict: the status chip,
// red relation badges, History parameter field and dependent Extrude rebuild
// are produced by the same views/services the product uses.
//
// SPDX-License-Identifier: MPL-2.0

#if canImport(XCTest)
import XCTest

private enum CADSketchDiagnosisLaunch {
    static let base = ["-AppleLanguages", "(en)", "-AppleLocale", "en_US",
                       "-ui-testing", "-ui-testing-ipad", "--ui-test-cad-fixture"]

    @MainActor
    static func app(_ extra: [String]) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = base + extra
        app.launch()
        return app
    }
}

@MainActor
private enum CADSketchDiagnosisUI {
    static func any(_ app: XCUIApplication, _ identifier: String) -> XCUIElement {
        app.descendants(matching: .any)[identifier]
    }

    static func waitForValue(_ element: XCUIElement, _ value: String,
                             timeout: TimeInterval) -> Bool {
        guard element.waitForExistence(timeout: timeout) else { return false }
        let predicate = NSPredicate(format: "value == %@", value)
        let expectation = XCTNSPredicateExpectation(predicate: predicate, object: element)
        return XCTWaiter().wait(for: [expectation], timeout: timeout) == .completed
    }

    static func waitForLabelContains(_ element: XCUIElement, _ text: String,
                                     timeout: TimeInterval) -> Bool {
        guard element.waitForExistence(timeout: timeout) else { return false }
        let predicate = NSPredicate(format: "label CONTAINS %@", text)
        let expectation = XCTNSPredicateExpectation(predicate: predicate, object: element)
        return XCTWaiter().wait(for: [expectation], timeout: timeout) == .completed
    }

    /// Safe failure text for a diagnostic assertion. Reading `.label` from a
    /// missing element raises an accessibility-snapshot error and replaces the
    /// real XCTAssert failure with that error; describe absence instead. This
    /// changes only the message, never a wait or an assertion.
    static func describe(_ element: XCUIElement) -> String {
        element.exists ? "label '\(element.label)'" : "element is absent"
    }

    /// Open one real Items row, then close the Items panel again. The row is
    /// the same `ItemRow-<name>` the product shows; `selectItemSketch` enters
    /// the sketch editor through its ordinary route.
    static func openSketch(_ name: String, in app: XCUIApplication,
                           file: StaticString = #filePath, line: UInt = #line) {
        app.buttons["ItemsButton"].tap()
        let row = any(app, "ItemRow-\(name)")
        XCTAssertTrue(row.waitForExistence(timeout: 30),
                      "Items must list the real \(name) sketch row: \(app.debugDescription)",
                      file: file, line: line)
        row.tap()
        // Selecting the row does not dismiss the panel; close it so the
        // viewport's status chip and dimension badges stay unobstructed.
        if any(app, "ItemsPanel").exists {
            app.buttons["ItemsButton"].tap()
        }
    }

    /// Replace the inline dimension editor's text and commit it through the
    /// real keyboard/commit control. The editor opens in system-keyboard mode
    /// (`CADPreferences.prefersSystemKeyboard`), so this is the product path a
    /// person uses, not a test-only text field.
    static func replaceDimension(_ app: XCUIApplication, with text: String,
                                 file: StaticString = #filePath, line: UInt = #line) {
        let field = app.textFields["DimensionField"]
        XCTAssertTrue(field.waitForExistence(timeout: 10),
                      "tapping the dimension badge must open the real inline editor",
                      file: file, line: line)
        field.tap()
        let seed = field.value as? String ?? ""
        for _ in seed {
            field.typeText(XCUIKeyboardKey.delete.rawValue)
        }
        field.typeText(text)
        let commit = app.buttons["DimensionCommit"]
        XCTAssertTrue(commit.waitForExistence(timeout: 5),
                      "the system-keyboard commit control must exist",
                      file: file, line: line)
        commit.tap()
    }

    static func snapshot(_ name: String, in app: XCUIApplication, test: XCTestCase,
                         croppedTo crop: XCUIElement? = nil) {
        let full = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        full.name = name
        full.lifetime = .keepAlways
        test.add(full)
        if let crop, crop.exists {
            let detail = XCTAttachment(screenshot: crop.screenshot())
            detail.name = name + " — detail"
            detail.lifetime = .keepAlways
            test.add(detail)
        }
    }

    static func assertFixtureLoaded(_ app: XCUIApplication,
                                    file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(app.otherElements["CADFixtureHarness"].waitForExistence(timeout: 60),
                      "the real workbench fixture must load: \(app.debugDescription)",
                      file: file, line: line)
        XCTAssertTrue(app.buttons["UndoButton"].waitForExistence(timeout: 60),
                      "the real workbench toolbar must be ready: \(app.debugDescription)",
                      file: file, line: line)
        XCTAssertFalse(app.staticTexts["CAD fixture failed"].exists,
                       "the native fixture package failed to build",
                       file: file, line: line)
    }
}

// MARK: - M02: closed arc+spline section, remaining DOF, driven edit

@MainActor
final class CADSketchLoopDiagnosisUITests: XCTestCase {
    func testSplineArcLoopShowsRemainingDOFAndSurvivesDrivenRadiusEdit() throws {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .landscapeLeft
        let app = CADSketchDiagnosisLaunch.app(["--ui-test-cad-sketch-loop"])
        defer { app.terminate() }
        CADSketchDiagnosisUI.assertFixtureLoaded(app)

        CADSketchDiagnosisUI.openSketch("Spline loop", in: app)

        let dof = CADSketchDiagnosisUI.any(app, "SketchDOFChip")
        // Resolve the actual chip before the assertion (the same 30 s predicate
        // wait, not a longer one) so the failure evidence records the settled
        // status pill, for example the unsupported chip that used to replace
        // the DOF chip. The assertion itself remains the same.
        let dofReady = CADSketchDiagnosisUI.waitForLabelContains(
            dof, "2 DOF remaining", timeout: 30)
        CADSketchDiagnosisUI.snapshot("M02 arc+spline loop — status at the DOF assertion",
                                      in: app, test: self)
        XCTAssertTrue(dofReady,
                      "the locked centre + radius leaves exactly 2 real DOF; got "
                        + CADSketchDiagnosisUI.describe(dof))
        XCTAssertFalse(CADSketchDiagnosisUI.any(app, "SketchConflictChip").exists,
                       "a healthy connected/tangent section must not report a conflict")
        XCTAssertFalse(CADSketchDiagnosisUI.any(app, "SketchUnsupportedChip").exists)
        CADSketchDiagnosisUI.snapshot("M02 arc+spline loop — 2 DOF remaining before edit",
                                      in: app, test: self)

        // The one driving radius is edited through its actual on-canvas badge.
        let badge = app.buttons["DimensionLabel"].firstMatch
        XCTAssertTrue(badge.waitForExistence(timeout: 20),
                      "the real radius badge must be on the section: \(app.debugDescription)")
        XCTAssertTrue(badge.label.contains("R25"), "unexpected initial badge: \(badge.label)")
        badge.tap()
        CADSketchDiagnosisUI.replaceDimension(app, with: "40")

        let updated = app.buttons["DimensionLabel"].firstMatch
        XCTAssertTrue(CADSketchDiagnosisUI.waitForLabelContains(updated, "R40", timeout: 30),
                      "the driven radius must land at 40 and the section must stay usable; got "
                        + CADSketchDiagnosisUI.describe(updated))
        XCTAssertTrue(CADSketchDiagnosisUI.waitForLabelContains(
            dof, "2 DOF remaining", timeout: 20),
                      "the dimension edit must not change the real remaining DOF; got "
                        + CADSketchDiagnosisUI.describe(dof))
        XCTAssertFalse(CADSketchDiagnosisUI.any(app, "SketchConflictChip").exists,
                       "the justified dimension edit must not become a conflicting best fit")
        CADSketchDiagnosisUI.snapshot("M02 arc+spline loop — driven radius 40, still 2 DOF",
                                      in: app, test: self, croppedTo: CADSketchDiagnosisUI.any(app, "CADFixtureHarness"))

        // A refused size keeps the previous geometry and states the real
        // reason. This is the ordinary dimension-validation failure surface
        // (not a fabricated status label).
        updated.tap()
        CADSketchDiagnosisUI.replaceDimension(app, with: "0")
        let notice = app.staticTexts["EditorNotice"]
        XCTAssertTrue(notice.waitForExistence(timeout: 10),
                      "a refused dimension must surface its reason: \(app.debugDescription)")
        XCTAssertTrue(notice.label.contains("greater than zero"),
                      "unexpected refusal reason: \(notice.label)")
        XCTAssertTrue(app.buttons["DimensionLabel"].firstMatch.label.contains("R40"),
                      "a refused dimension must not change the committed value")
        CADSketchDiagnosisUI.snapshot("M02 refused zero dimension — reason shown, R40 retained",
                                      in: app, test: self)

        // Exit the sketch and prove the real dependent Extrude replayed as one
        // clean feature: a split/refused section would leave an error badge.
        let exit = app.buttons["Exit Sketching"]
        XCTAssertTrue(exit.waitForExistence(timeout: 10))
        exit.tap()
        app.buttons["HistoryButton"].tap()
        let panel = CADSketchDiagnosisUI.any(app, "HistoryPanel")
        let scroll = app.scrollViews["HistoryPanel"]
        XCTAssertTrue(panel.waitForExistence(timeout: 20) || scroll.waitForExistence(timeout: 20),
                      "the real History panel must open: \(app.debugDescription)")
        let extrude = CADSketchDiagnosisUI.any(app, "HistoryRow-Extrude")
        XCTAssertTrue(extrude.waitForExistence(timeout: 20),
                      "the consuming Extrude must remain a real history node")
        XCTAssertFalse(CADSketchDiagnosisUI.any(app, "HistoryError-Extrude").exists,
                       "the edited section must still resolve the dependent Extrude profile")
        app.buttons["ItemsButton"].tap()
        let body = CADSketchDiagnosisUI.any(app, "ItemRow-Extrude")
        XCTAssertTrue(body.waitForExistence(timeout: 20),
                      "the rebuilt solid must remain a real body item")
        CADSketchDiagnosisUI.snapshot("M02 closed section — dependent Extrude rebuilt without error",
                                      in: app, test: self, croppedTo: panel.exists ? panel : nil)
    }
}

// MARK: - M06: exact conflict attribution on the real overlays

@MainActor
final class CADSketchConflictDiagnosisUITests: XCTestCase {
    func testConflictHighlightsTheTwoActualDimensionsAndNotTheCleanRelation() throws {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .landscapeLeft
        let app = CADSketchDiagnosisLaunch.app(["--ui-test-cad-sketch-conflict"])
        defer { app.terminate() }
        CADSketchDiagnosisUI.assertFixtureLoaded(app)

        CADSketchDiagnosisUI.openSketch("Spline conflict", in: app)

        let chip = CADSketchDiagnosisUI.any(app, "SketchConflictChip")
        XCTAssertTrue(chip.waitForExistence(timeout: 30),
                      "the saved contradictory system must report a real conflict: \(app.debugDescription)")
        XCTAssertTrue(chip.label.contains("Constraints conflict"), "unexpected chip: \(chip.label)")

        // Exactly the two contradictory radius dimensions are attributed; the
        // unrelated satisfied line dimension stays a normal badge.
        let conflicts = app.buttons.matching(identifier: "DimensionLabelConflict")
        let second = conflicts.element(boundBy: 1)
        XCTAssertTrue(second.waitForExistence(timeout: 30),
                      "both real conflicting dimensions must be highlighted: \(app.debugDescription)")
        XCTAssertEqual(conflicts.count, 2,
                       "only the actual contradictory dimensions may be red")
        let clean = app.buttons.matching(identifier: "DimensionLabel").firstMatch
        XCTAssertTrue(clean.waitForExistence(timeout: 10),
                      "the unrelated satisfied dimension must stay a normal badge")
        XCTAssertEqual(app.buttons.matching(identifier: "ConstraintGlyphConflict").count, 0,
                       "satisfied loop relations must not be painted red with the dimensions")
        XCTAssertFalse(CADSketchDiagnosisUI.any(app, "SketchStateChip").exists,
                       "a best fit must never be presented as fully defined/satisfied")

        let labels = (0..<conflicts.count).map { conflicts.element(boundBy: $0).label }
        // Capture the actual badges (colour and text) BEFORE the critical
        // value assertions, so a failing value still leaves visual evidence.
        CADSketchDiagnosisUI.snapshot("M06 conflict — two exact red dimensions, clean relation unmarked",
                                      in: app, test: self, croppedTo: CADSketchDiagnosisUI.any(app, "CADFixtureHarness"))
        XCTAssertTrue(labels.contains { $0.contains("R25") },
                      "one highlighted label must name the 25 mm driving value: \(labels)")
        XCTAssertTrue(labels.contains { $0.contains("R40") },
                      "one highlighted label must name the 40 mm driving value: \(labels)")
        XCTAssertTrue(clean.label.contains("60"),
                      "unexpected clean dimension label: \(clean.label)")

        // Editing a red driving value must be refused with the real conflict
        // reason and must not commit the solver's compromise. This is the
        // "best fit is never written as satisfied" UI path.
        conflicts.firstMatch.tap()
        CADSketchDiagnosisUI.replaceDimension(app, with: "30")
        let notice = app.staticTexts["EditorNotice"]
        XCTAssertTrue(notice.waitForExistence(timeout: 10),
                      "a conflicting dimension edit must surface its reason: \(app.debugDescription)")
        XCTAssertTrue(notice.label.lowercased().contains("conflict"),
                      "unexpected conflict refusal reason: \(notice.label)")
        XCTAssertTrue(CADSketchDiagnosisUI.any(app, "SketchConflictChip").exists,
                      "the refused edit must leave the real conflict state in place")
        CADSketchDiagnosisUI.snapshot("M06 conflicting edit refused — reason shown, no best fit committed",
                                      in: app, test: self)
    }
}

// MARK: - M19: real History angle control, 30° -> 45°, save/reopen units

@MainActor
final class CADFaceRotationParameterUITests: XCTestCase {
    func testFaceRotationHistoryShowsThirtyEditsToFortyFiveAndReopensInDegrees() throws {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .landscapeLeft
        let app = CADSketchDiagnosisLaunch.app(
            ["--ui-test-cad-face-rotation", "--ui-test-cad-face-rotation-reset"])
        CADSketchDiagnosisUI.assertFixtureLoaded(app)

        openRotationHistory(in: app)
        let field = app.textFields["HistoryScalarField-rotateAngle-Rotate Face"]
        XCTAssertTrue(field.waitForExistence(timeout: 20),
                      "the real History angle field must exist: \(app.debugDescription)")
        XCTAssertTrue(CADSketchDiagnosisUI.waitForValue(field, "30", timeout: 20),
                      "the face rotation must display its saved value in DEGREES; got \(field.value ?? "nil")")
        let row = CADSketchDiagnosisUI.any(app, "HistoryRow-Rotate Face")
        XCTAssertTrue(row.exists)
        let unit = app.staticTexts["HistoryScalarUnit-rotateAngle-Rotate Face"]
        XCTAssertTrue(unit.waitForExistence(timeout: 10),
                      "the History control must expose its degree unit: \(app.debugDescription)")
        XCTAssertEqual(unit.label, "°",
                       "the angle parameter must be shown in degrees")
        CADSketchDiagnosisUI.snapshot("M19 face rotation — History displays 30 degrees",
                                      in: app, test: self, croppedTo: CADSketchDiagnosisUI.any(app, "HistoryPanel"))

        // Edit through the actual History numeric keypad popover.
        field.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        let pad = CADSketchDiagnosisUI.any(app, "NumericKeypad")
        XCTAssertTrue(pad.waitForExistence(timeout: 10),
                      "tapping the real History value must open its keypad: \(app.debugDescription)")
        app.buttons["KeypadDelete"].tap()
        app.buttons["KeypadDelete"].tap()
        app.buttons["Keypad-4"].tap()
        app.buttons["Keypad-5"].tap()
        app.buttons["KeypadCommit"].tap()

        XCTAssertTrue(CADSketchDiagnosisUI.waitForValue(field, "45", timeout: 20),
                      "the committed History value must read 45 in degrees; got \(field.value ?? "nil")")
        XCTAssertFalse(CADSketchDiagnosisUI.any(app, "HistoryError-Rotate Face").exists,
                       "the real parameter update must rebuild the feature without an error")
        CADSketchDiagnosisUI.snapshot("M19 face rotation — History accepts 45 degrees",
                                      in: app, test: self, croppedTo: CADSketchDiagnosisUI.any(app, "HistoryPanel"))

        // Save through the host's real save action, then reopen the same
        // package in a NEW process. The unit is part of the saved state.
        let save = app.buttons["cad.host.save"]
        XCTAssertTrue(save.waitForExistence(timeout: 10))
        save.tap()
        let outcome = CADSketchDiagnosisUI.any(app, "cad.host.saveOutcome")
        XCTAssertTrue(outcome.waitForExistence(timeout: 60),
                      "the real host save must complete: \(app.debugDescription)")
        XCTAssertTrue(outcome.label.contains("Saved"),
                      "unexpected save outcome: \(outcome.label)")
        app.terminate()

        let reopened = CADSketchDiagnosisLaunch.app(["--ui-test-cad-face-rotation"])
        defer { reopened.terminate() }
        CADSketchDiagnosisUI.assertFixtureLoaded(reopened)
        openRotationHistory(in: reopened)
        let reopenedField = reopened.textFields["HistoryScalarField-rotateAngle-Rotate Face"]
        XCTAssertTrue(reopenedField.waitForExistence(timeout: 20),
                      "the reopened History angle field must exist: \(reopened.debugDescription)")
        XCTAssertTrue(CADSketchDiagnosisUI.waitForValue(reopenedField, "45", timeout: 20),
                      "reopening must preserve 45 DEGREES (no double radian conversion); got \(reopenedField.value ?? "nil")")
        let reopenedRow = CADSketchDiagnosisUI.any(reopened, "HistoryRow-Rotate Face")
        XCTAssertTrue(reopenedRow.exists)
        let reopenedUnit = reopened.staticTexts["HistoryScalarUnit-rotateAngle-Rotate Face"]
        XCTAssertTrue(reopenedUnit.waitForExistence(timeout: 10),
                      "reopening must expose the degree unit: \(reopened.debugDescription)")
        XCTAssertEqual(reopenedUnit.label, "°",
                       "reopening must preserve the degree unit")
        CADSketchDiagnosisUI.snapshot("M19 face rotation — reopened package still shows 45 degrees",
                                      in: reopened, test: self,
                                      croppedTo: CADSketchDiagnosisUI.any(reopened, "HistoryPanel"))
    }

    private func openRotationHistory(in app: XCUIApplication,
                                     file: StaticString = #filePath, line: UInt = #line) {
        let history = app.buttons["HistoryButton"]
        XCTAssertTrue(history.waitForExistence(timeout: 20),
                      "the real workbench toolbar must expose History",
                      file: file, line: line)
        history.tap()
        XCTAssertTrue(CADSketchDiagnosisUI.any(app, "HistoryPanel").waitForExistence(timeout: 20)
                        || app.scrollViews["HistoryPanel"].waitForExistence(timeout: 20),
                      "the real History panel must open: \(app.debugDescription)",
                      file: file, line: line)
    }
}
#endif
