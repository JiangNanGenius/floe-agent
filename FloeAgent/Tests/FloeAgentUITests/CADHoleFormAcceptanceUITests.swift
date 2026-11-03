// FloeAgentUITests — H1 native mechanical-hole FORM acceptance.
//
// The `--ui-test-cad-hole-form` launch argument reuses the real
// `CADWorkbenchFixtureHarness` and seeds a real saved plate with one
// unconsumed placement circle. The FloeCAD fixture arms the production
// `beginCreate(.hole)` + viewport-tap route; these tests interact only with
// the shipped `HoleOptionsSheet`, the real History edit entry, the real
// `commitHole` transaction and the host Save control. No fabricated sheet,
// draft, history row, success badge or package is asserted.
//
// SPDX-License-Identifier: MPL-2.0

#if canImport(XCTest)
import XCTest

private enum CADHoleFormLaunch {
    static let base = ["-AppleLanguages", "(en)", "-AppleLocale", "en_US",
                       // Argument-domain override: the test reads the real
                       // millimetre defaults without writing the persisted
                       // user preference. A stale user unit from another test
                       // cannot change what the form displays.
                       "-floe.cad.unit", "mm",
                       "-ui-testing", "-ui-testing-ipad", "--ui-test-cad-fixture",
                       "--ui-test-cad-hole-form"]

    @MainActor
    static func app(reset: Bool) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = base + (reset ? ["--ui-test-cad-hole-form-reset"] : [])
        app.launch()
        return app
    }
}

@MainActor
enum CADHoleFormUI {
    static let conditionalFieldIDs = [
        "HoleDepth",
        "HoleCounterboreDiameter",
        "HoleCounterboreDepth",
        "HoleCountersinkDiameter",
        "HoleCountersinkAngle",
    ]

    static func any(_ app: XCUIApplication, _ identifier: String) -> XCUIElement {
        app.descendants(matching: .any)[identifier]
    }

    static func waitForAbsence(_ element: XCUIElement, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if !element.exists { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        return !element.exists
    }

    static func waitForValue(_ element: XCUIElement, _ value: String,
                             timeout: TimeInterval) -> Bool {
        guard element.waitForExistence(timeout: timeout) else { return false }
        let predicate = NSPredicate(format: "value == %@", value)
        let expectation = XCTNSPredicateExpectation(predicate: predicate, object: element)
        return XCTWaiter().wait(for: [expectation], timeout: timeout) == .completed
    }

    static func assertFixtureLoaded(_ app: XCUIApplication,
                                    file: StaticString = #filePath,
                                    line: UInt = #line) {
        XCTAssertTrue(any(app, "CADFixtureHarness").waitForExistence(timeout: 60),
                      "the real CAD fixture host must open: \(app.debugDescription)",
                      file: file, line: line)
    }

    /// The real workbench is up (its toolbar is the first stable product
    /// surface). Used before asserting that a saved hole does NOT present a
    /// create draft: waiting on the harness container alone would pass before
    /// the document had loaded.
    static func waitForWorkbench(_ app: XCUIApplication,
                                 file: StaticString = #filePath,
                                 line: UInt = #line) {
        assertFixtureLoaded(app, file: file, line: line)
        XCTAssertTrue(app.buttons["HistoryButton"].waitForExistence(timeout: 60),
                      "the real workbench must finish opening: \(app.debugDescription)",
                      file: file, line: line)
    }

    /// The production HoleOptionsSheet, opened by the real draft route.
    static func waitForForm(_ app: XCUIApplication,
                            file: StaticString = #filePath,
                            line: UInt = #line) {
        assertFixtureLoaded(app, file: file, line: line)
        XCTAssertTrue(app.buttons["HoleCreate"].waitForExistence(timeout: 60),
                      "the real hole options form must present from the fixture draft: \(app.debugDescription)",
                      file: file, line: line)
        XCTAssertTrue(app.buttons["HoleCancel"].waitForExistence(timeout: 10),
                      "the real form must expose its Cancel action", file: file, line: line)
    }

    static func tapTypePicker(_ app: XCUIApplication,
                              file: StaticString = #filePath,
                              line: UInt = #line) {
        let picker = any(app, "HoleTypePicker")
        if picker.waitForExistence(timeout: 15), picker.isHittable {
            picker.tap()
            return
        }
        // SwiftUI may expose the Form row by its composed label rather than
        // the identifier attached to the Picker. Both are the same control.
        let labelled = app.buttons.matching(
            NSPredicate(format: "label BEGINSWITH %@", "Type")
        ).firstMatch
        if labelled.waitForExistence(timeout: 5) {
            labelled.tap()
            return
        }
        XCTFail("the native hole Type picker must be reachable: \(app.debugDescription)",
                file: file, line: line)
    }

    static func selectType(_ app: XCUIApplication, raw: String, label: String,
                           file: StaticString = #filePath,
                           line: UInt = #line) {
        tapTypePicker(app, file: file, line: line)
        let byID = any(app, "HoleTypeOption-\(raw)")
        if byID.waitForExistence(timeout: 5), byID.isHittable {
            byID.tap()
            return
        }
        let byButton = app.buttons[label].firstMatch
        if byButton.waitForExistence(timeout: 5) {
            byButton.tap()
            return
        }
        let byMenuItem = app.menuItems[label].firstMatch
        if byMenuItem.waitForExistence(timeout: 3) {
            byMenuItem.tap()
            return
        }
        XCTFail("the real Type picker must offer \(label): \(app.debugDescription)",
                file: file, line: line)
    }

    static func assertConditionalFields(_ app: XCUIApplication, expected: [String],
                                        type: String,
                                        file: StaticString = #filePath,
                                        line: UInt = #line) {
        for identifier in conditionalFieldIDs {
            let element = any(app, identifier)
            if expected.contains(identifier) {
                XCTAssertTrue(element.waitForExistence(timeout: 15),
                              "\(identifier) must be visible for the \(type) type: \(app.debugDescription)",
                              file: file, line: line)
            } else {
                XCTAssertTrue(waitForAbsence(element, timeout: 5),
                              "\(identifier) must not be visible for the \(type) type",
                              file: file, line: line)
            }
        }
    }

    static func replaceNumber(_ app: XCUIApplication, identifier: String, with text: String,
                              file: StaticString = #filePath,
                              line: UInt = #line) {
        let field = app.textFields[identifier]
        XCTAssertTrue(field.waitForExistence(timeout: 10),
                      "the real numeric field \(identifier) must exist: \(app.debugDescription)",
                      file: file, line: line)
        let seed = field.value as? String ?? ""
        // A native Form exposes the whole LabeledContent row as this text
        // field, although the editable rounded box is at its trailing edge.
        // Tap inside that visible box, not the row's label/empty centre.
        // The final four points are beyond the trailing text's native inset,
        // placing the caret after the existing value rather than before it.
        field.coordinate(withNormalizedOffset: CGVector(dx: 1, dy: 0.5))
            .withOffset(CGVector(dx: -4, dy: 0)).tap()
        let pad = any(app, "NumericKeypad")
        if pad.waitForExistence(timeout: 3) {
            let delete = app.buttons["KeypadDelete"]
            XCTAssertTrue(delete.waitForExistence(timeout: 10),
                          "the real numeric keypad must expose Delete",
                          file: file, line: line)
            for _ in seed { delete.tap() }
            for character in text {
                let token = character == "-" ? "−" : String(character)
                let key = app.buttons["Keypad-" + token]
                XCTAssertTrue(key.waitForExistence(timeout: 10),
                              "the real numeric keypad must expose \(token)",
                              file: file, line: line)
                key.tap()
            }
            let commit = app.buttons["KeypadCommit"]
            XCTAssertTrue(commit.waitForExistence(timeout: 10),
                          "the real numeric keypad must expose its commit action",
                          file: file, line: line)
            commit.tap()
            XCTAssertTrue(waitForAbsence(pad, timeout: 10),
                          "committing the value must close the real keypad",
                          file: file, line: line)
        } else {
            // typeText itself requires real keyboard focus, including when
            // a hardware keyboard is connected. An onscreen keyboard's
            // presence is not a substitute for that focus check.
            for _ in seed { field.typeText(XCUIKeyboardKey.delete.rawValue) }
            field.typeText(text)
            field.typeText(XCUIKeyboardKey.return.rawValue)
        }
        XCTAssertTrue(waitForValue(field, text, timeout: 5),
                      "the real numeric input must replace its previous value with \(text)",
                      file: file, line: line)
    }

    static func oppositeNormalSegment(_ app: XCUIApplication,
                                      file: StaticString = #filePath,
                                      line: UInt = #line) -> XCUIElement {
        let segment = app.segmentedControls.buttons["Opposite normal"]
        let button = app.buttons["Opposite normal"]
        let form = any(app, "HoleOptionsForm")
        for _ in 0..<4 {
            if segment.exists && segment.isHittable { return segment }
            if button.exists && button.isHittable { return button }
            guard form.waitForExistence(timeout: 5) else { break }
            // Scroll the actual modal Form. Its lower sections are virtualized;
            // waiting for an offscreen segment cannot make it appear, and an
            // app-wide swipe can instead move the background tool palette.
            form.swipeUp()
        }
        XCTAssertTrue(button.exists && button.isHittable,
                      "the real drill-direction control must offer Opposite normal: \(app.debugDescription)",
                      file: file, line: line)
        return button
    }

    static func selectOppositeNormal(_ app: XCUIApplication,
                                     file: StaticString = #filePath,
                                     line: UInt = #line) {
        let segment = oppositeNormalSegment(app, file: file, line: line)
        XCTAssertTrue(segment.isHittable,
                      "the direction control must be reachable in the form", file: file, line: line)
        segment.tap()
        XCTAssertTrue(segment.isSelected,
                      "tapping Opposite normal must select the real direction control",
                      file: file, line: line)
    }

    static func openHistory(_ app: XCUIApplication,
                            file: StaticString = #filePath,
                            line: UInt = #line) {
        app.buttons["HistoryButton"].tap()
        let panel = any(app, "HistoryPanel")
        let scroll = app.scrollViews["HistoryPanel"]
        XCTAssertTrue(panel.waitForExistence(timeout: 20) || scroll.waitForExistence(timeout: 20),
                      "the real History panel must open: \(app.debugDescription)",
                      file: file, line: line)
    }

    static func closeHistory(_ app: XCUIApplication,
                             file: StaticString = #filePath,
                             line: UInt = #line) {
        app.buttons["HistoryButton"].tap()
        XCTAssertTrue(waitForAbsence(any(app, "HistoryPanel"), timeout: 10),
                      "tapping History again must close the real panel", file: file, line: line)
    }

    static func openHoleEdit(_ app: XCUIApplication, kindLabel: String,
                             file: StaticString = #filePath,
                             line: UInt = #line) {
        let row = any(app, "HistoryRow-Hole")
        XCTAssertTrue(row.waitForExistence(timeout: 30),
                      "the real History row for the saved hole must exist: \(app.debugDescription)",
                      file: file, line: line)
        let anchor = app.staticTexts[kindLabel]
        let pressTarget = anchor.waitForExistence(timeout: 10) ? anchor : row
        pressTarget.press(forDuration: 1.2)
        let edit = app.buttons["EditHole-Hole"]
        if !edit.waitForExistence(timeout: 8) {
            // The row content and the parent draggable both accept a long
            // press. Retry once on the row itself; still the real menu.
            row.press(forDuration: 1.2)
        }
        var action = edit
        if !action.waitForExistence(timeout: 8) {
            // Some iOS menu presentations drop custom identifiers; the same
            // real action still carries its shipped English label here.
            let byLabel = app.descendants(matching: .any)
                .matching(NSPredicate(format: "label == %@", "Edit Hole")).firstMatch
            if byLabel.waitForExistence(timeout: 5) {
                action = byLabel
            }
        }
        XCTAssertTrue(action.waitForExistence(timeout: 5),
                      "the real History context menu must offer Edit Hole: \(app.debugDescription)",
                      file: file, line: line)
        action.tap()
        XCTAssertTrue(app.buttons["HoleCreate"].waitForExistence(timeout: 30),
                      "Edit Hole must present the same real options form: \(app.debugDescription)",
                      file: file, line: line)
    }

    static func holeRowCount(_ app: XCUIApplication) -> Int {
        app.descendants(matching: .any).matching(identifier: "HistoryRow-Hole").count
    }

    static func tapHostSave(_ app: XCUIApplication,
                            file: StaticString = #filePath,
                            line: UInt = #line) {
        let save = app.buttons["cad.host.save"]
        XCTAssertTrue(save.waitForExistence(timeout: 20),
                      "the production host Save control must exist", file: file, line: line)
        save.tap()
        let outcome = any(app, "cad.host.saveOutcome")
        XCTAssertTrue(outcome.waitForExistence(timeout: 60),
                      "the production host must report its save outcome: \(app.debugDescription)",
                      file: file, line: line)
        XCTAssertEqual(outcome.label, "Saved",
                       "the real host save must succeed; got \(outcome.label)",
                       file: file, line: line)
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
}

@MainActor
final class CADHoleFormAcceptanceUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .landscapeLeft
    }

    override func tearDownWithError() throws {
        // Leave no fixture app running after success or an early failure.
        XCUIApplication().terminate()
    }

    /// The shipped form offers all four types with the right conditional
    /// fields and leaves the saved package unchanged on Cancel. A relaunch
    /// without the reset flag opens the SAME package again (verified through a
    /// real History rename that survives the process boundary).
    func testFormCoversFourTypesAndCancelKeepsSavedFixture() throws {
        let app = CADHoleFormLaunch.app(reset: true)
        CADHoleFormUI.waitForForm(app)

        // Through all is the initial type: no conditional numeric fields.
        CADHoleFormUI.assertConditionalFields(app, expected: [], type: "through all")

        CADHoleFormUI.selectType(app, raw: "blind", label: "Blind")
        CADHoleFormUI.assertConditionalFields(app, expected: ["HoleDepth"], type: "blind")
        XCTAssertTrue(CADHoleFormUI.waitForValue(
            CADHoleFormUI.any(app, "HoleDepth"), "6", timeout: 10),
            "the blind draft's real depth must be shown")

        CADHoleFormUI.selectType(app, raw: "counterbore", label: "Counterbore")
        CADHoleFormUI.assertConditionalFields(
            app, expected: ["HoleCounterboreDiameter", "HoleCounterboreDepth"],
            type: "counterbore")
        XCTAssertTrue(CADHoleFormUI.waitForValue(
            CADHoleFormUI.any(app, "HoleCounterboreDiameter"), "12", timeout: 10),
            "the counterbore draft's real recess diameter must be shown")
        XCTAssertTrue(CADHoleFormUI.waitForValue(
            CADHoleFormUI.any(app, "HoleCounterboreDepth"), "3", timeout: 10),
            "the counterbore draft's real recess depth must be shown")

        CADHoleFormUI.selectType(app, raw: "countersink", label: "Countersink")
        CADHoleFormUI.assertConditionalFields(
            app, expected: ["HoleCountersinkDiameter", "HoleCountersinkAngle"],
            type: "countersink")
        XCTAssertTrue(CADHoleFormUI.waitForValue(
            CADHoleFormUI.any(app, "HoleCountersinkDiameter"), "14", timeout: 10),
            "the countersink draft's real opening diameter must be shown")
        XCTAssertTrue(CADHoleFormUI.waitForValue(
            CADHoleFormUI.any(app, "HoleCountersinkAngle"), "90", timeout: 10),
            "the countersink draft's real included angle must be shown")
        CADHoleFormUI.snapshot("H1 hole form — four real types and conditional fields",
                               in: app, test: self)

        app.buttons["HoleCancel"].tap()
        XCTAssertTrue(CADHoleFormUI.waitForAbsence(app.buttons["HoleCreate"], timeout: 20),
                      "Cancel must dismiss the real form")

        CADHoleFormUI.openHistory(app)
        XCTAssertTrue(CADHoleFormUI.any(app, "HistoryRow-Extrude").waitForExistence(timeout: 20),
                      "Cancel must leave the real plate Extrude in history")
        XCTAssertFalse(CADHoleFormUI.any(app, "HistoryRow-Hole").exists,
                       "Cancel must not create a hole feature")

        // Rename the real Extrude row so the next process can prove it reopened
        // the SAME saved package rather than silently reseeding it.
        let name = app.textFields["HistoryName-Extrude"]
        XCTAssertTrue(name.waitForExistence(timeout: 20),
                      "the real History row name field must exist")
        name.tap()
        let oldName = name.value as? String ?? "Extrude"
        for _ in oldName {
            name.typeText(XCUIKeyboardKey.delete.rawValue)
        }
        name.typeText("PlateBody")
        name.typeText(XCUIKeyboardKey.return.rawValue)
        XCTAssertTrue(CADHoleFormUI.any(app, "HistoryRow-PlateBody").waitForExistence(timeout: 20),
                      "the real History rename must persist in the open document")
        CADHoleFormUI.closeHistory(app)
        CADHoleFormUI.tapHostSave(app)
        CADHoleFormUI.snapshot("H1 hole form — Cancel leaves no hole; saved fixture renamed",
                               in: app, test: self)
        app.terminate()

        // Relaunch WITHOUT reset: the same own package must open and re-arm the
        // real create form from its still-unconsumed placement circle.
        let reopened = CADHoleFormLaunch.app(reset: false)
        CADHoleFormUI.waitForForm(reopened)
        reopened.buttons["HoleCancel"].tap()
        XCTAssertTrue(CADHoleFormUI.waitForAbsence(reopened.buttons["HoleCreate"], timeout: 20))
        CADHoleFormUI.openHistory(reopened)
        XCTAssertTrue(CADHoleFormUI.any(reopened, "HistoryRow-PlateBody").waitForExistence(timeout: 20),
                      "the no-reset relaunch must show the renamed, saved Extrude (same package)")
        XCTAssertFalse(CADHoleFormUI.any(reopened, "HistoryRow-Hole").exists,
                       "the no-reset relaunch must still have no hole")
        CADHoleFormUI.snapshot("H1 hole form — no-reset relaunch keeps the saved package",
                               in: reopened, test: self)
        reopened.terminate()
    }

    /// Counterbore is created through the real form, saved by the host, then
    /// reopened in new processes and edited through the real History entry.
    /// The second Save must update the SAME feature (exactly one Hole row).
    func testCounterboreCreateSaveReopenEditPreservesIdentity() throws {
        let app = CADHoleFormLaunch.app(reset: true)
        CADHoleFormUI.waitForForm(app)
        XCTAssertTrue(app.buttons["HoleCreate"].isEnabled,
                      "the seeded target body must enable the real Create action")

        CADHoleFormUI.selectType(app, raw: "counterbore", label: "Counterbore")
        CADHoleFormUI.assertConditionalFields(
            app, expected: ["HoleCounterboreDiameter", "HoleCounterboreDepth"],
            type: "counterbore")
        CADHoleFormUI.replaceNumber(app, identifier: "HoleCounterboreDiameter", with: "18")
        CADHoleFormUI.replaceNumber(app, identifier: "HoleCounterboreDepth", with: "4")
        CADHoleFormUI.selectOppositeNormal(app)

        XCTAssertTrue(CADHoleFormUI.waitForValue(
            CADHoleFormUI.any(app, "HoleCounterboreDiameter"), "18", timeout: 10),
            "the real numeric field must hold the typed counterbore diameter")
        XCTAssertTrue(CADHoleFormUI.waitForValue(
            CADHoleFormUI.any(app, "HoleCounterboreDepth"), "4", timeout: 10),
            "the real numeric field must hold the typed counterbore depth")
        CADHoleFormUI.snapshot("H1 hole form — counterbore values and direction entered",
                               in: app, test: self)

        app.buttons["HoleCreate"].tap()
        XCTAssertTrue(CADHoleFormUI.waitForAbsence(app.buttons["HoleCreate"], timeout: 30),
                      "a valid counterbore must commit and dismiss the real form")
        XCTAssertFalse(app.staticTexts.matching(
            NSPredicate(format: "label CONTAINS %@", "Hole could not be completed")
        ).firstMatch.exists, "the real graph transaction must not report a hole failure")

        CADHoleFormUI.openHistory(app)
        let createdRow = CADHoleFormUI.any(app, "HistoryRow-Hole")
        XCTAssertTrue(createdRow.waitForExistence(timeout: 30),
                      "Create must produce the real History Hole row: \(app.debugDescription)")
        XCTAssertTrue(app.staticTexts["Hole · Counterbore"].waitForExistence(timeout: 10),
                      "the History row must report the real committed counterbore type")
        XCTAssertFalse(CADHoleFormUI.any(app, "HistoryError-Hole").exists,
                       "the committed counterbore must rebuild without an error badge")
        XCTAssertEqual(CADHoleFormUI.holeRowCount(app), 1,
                       "Create must make exactly one hole feature")
        CADHoleFormUI.snapshot("H1 hole form — committed counterbore appears in real History",
                               in: app, test: self, croppedTo: CADHoleFormUI.any(app, "HistoryPanel"))
        CADHoleFormUI.closeHistory(app)
        CADHoleFormUI.tapHostSave(app)
        app.terminate()

        // New process: the saved hole opens without a create draft; edit it
        // through the real History context menu.
        let reopened = CADHoleFormLaunch.app(reset: false)
        CADHoleFormUI.waitForWorkbench(reopened)
        XCTAssertFalse(reopened.buttons["HoleCreate"].exists,
                       "a package with the saved hole must not arm a second create draft")
        CADHoleFormUI.openHistory(reopened)
        XCTAssertTrue(CADHoleFormUI.any(reopened, "HistoryRow-Hole").waitForExistence(timeout: 30),
                      "the reopened package must still show the same Hole history row")
        XCTAssertEqual(CADHoleFormUI.holeRowCount(reopened), 1,
                       "reopening must keep exactly one hole feature")
        CADHoleFormUI.openHoleEdit(reopened, kindLabel: "Hole · Counterbore")

        XCTAssertTrue(CADHoleFormUI.any(reopened, "HoleCounterboreDiameter").waitForExistence(timeout: 20),
                      "the same real form must reopen on the saved counterbore")
        XCTAssertTrue(CADHoleFormUI.any(reopened, "HoleCounterboreDepth").exists)
        XCTAssertTrue(CADHoleFormUI.waitForValue(
            CADHoleFormUI.any(reopened, "HoleCounterboreDiameter"), "18", timeout: 10),
            "the saved counterbore diameter must persist into the reopened form")
        XCTAssertTrue(CADHoleFormUI.waitForValue(
            CADHoleFormUI.any(reopened, "HoleCounterboreDepth"), "4", timeout: 10),
            "the saved counterbore depth must persist into the reopened form")
        XCTAssertTrue(CADHoleFormUI.oppositeNormalSegment(reopened).isSelected,
                      "the saved reversed drill direction must persist into the reopened form")
        XCTAssertTrue(reopened.buttons["HoleCreate"].label.contains("Save"),
                      "editing an existing hole must use the real Save action: \(reopened.buttons["HoleCreate"].label)")
        CADHoleFormUI.snapshot("H1 hole form — new-process History edit shows saved values and identity",
                               in: reopened, test: self)

        CADHoleFormUI.replaceNumber(reopened, identifier: "HoleCounterboreDepth", with: "5")
        XCTAssertTrue(CADHoleFormUI.waitForValue(
            CADHoleFormUI.any(reopened, "HoleCounterboreDepth"), "5", timeout: 10),
            "the real numeric field must accept the edited counterbore depth")
        reopened.buttons["HoleCreate"].tap()
        XCTAssertTrue(CADHoleFormUI.waitForAbsence(reopened.buttons["HoleCreate"], timeout: 30),
                      "the edited counterbore must commit and dismiss the real form")
        XCTAssertFalse(reopened.staticTexts.matching(
            NSPredicate(format: "label CONTAINS %@", "Hole could not be completed")
        ).firstMatch.exists, "the real edit transaction must not report a hole failure")
        XCTAssertEqual(CADHoleFormUI.holeRowCount(reopened), 1,
                       "editing through History must update the same hole, not add one")
        XCTAssertFalse(CADHoleFormUI.any(reopened, "HistoryError-Hole").exists,
                       "the edited counterbore must rebuild without an error badge")
        CADHoleFormUI.snapshot("H1 hole form — History Save updates the same feature",
                               in: reopened, test: self, croppedTo: CADHoleFormUI.any(reopened, "HistoryPanel"))
        CADHoleFormUI.tapHostSave(reopened)
        reopened.terminate()

        // Third process: prove the edited values were committed to the same
        // package and that the feature identity survived another save/reopen.
        let final = CADHoleFormLaunch.app(reset: false)
        CADHoleFormUI.waitForWorkbench(final)
        XCTAssertFalse(final.buttons["HoleCreate"].exists,
                       "the final reopen must not arm a create draft over the saved hole")
        CADHoleFormUI.openHistory(final)
        XCTAssertEqual(CADHoleFormUI.holeRowCount(final), 1,
                       "the final reopen must still contain exactly one hole feature")
        CADHoleFormUI.openHoleEdit(final, kindLabel: "Hole · Counterbore")
        XCTAssertTrue(CADHoleFormUI.waitForValue(
            CADHoleFormUI.any(final, "HoleCounterboreDiameter"), "18", timeout: 15),
            "the final reopen must retain the committed counterbore diameter")
        XCTAssertTrue(CADHoleFormUI.waitForValue(
            CADHoleFormUI.any(final, "HoleCounterboreDepth"), "5", timeout: 15),
            "the final reopen must retain the edited counterbore depth")
        XCTAssertTrue(CADHoleFormUI.oppositeNormalSegment(final).isSelected,
                      "the final reopen must retain the saved reversed direction")
        CADHoleFormUI.snapshot("H1 hole form — final reopen keeps values and one feature identity",
                               in: final, test: self)
        final.terminate()
    }
}
#endif
