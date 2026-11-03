// SPDX-License-Identifier: MPL-2.0
import XCTest

/// Real native taps; the fixture creates only the INITIAL geometry.
@MainActor final class CADM30SelectedTargetWitnessUITests: XCTestCase {
    func testHoleHistoryTapAndSaveWitness() throws { try witness("hole") }
    func testThreadHistoryTapAndSaveWitness() throws { try witness("thread") }
    func testSurfaceHistoryTapAndSaveWitness() throws { try witness("surface") }
    func testDatumHistoryTapAndSaveWitnessWithoutBody() throws { try witness("datum") }
    private func witness(_ target: String) throws {
        continueAfterFailure = false
        let nonce = try XCTUnwrap(ProcessInfo.processInfo.environment["FLOE_M30_NONCE"].flatMap(UUID.init(uuidString:)), "Root must supply one fresh nonce for all four UI witnesses")
        let app = XCUIApplication()
        app.launchArguments = ["-AppleLanguages", "(en)", "-AppleLocale", "en_US", "-floe.cad.unit", "mm",
            "-ui-testing", "-ui-testing-ipad", "--ui-test-cad-fixture", "--ui-test-cad-m30-selected"]
        app.launchEnvironment["FLOE_M30_NONCE"] = nonce.uuidString
        app.launchEnvironment["FLOE_M30_TARGET"] = target
        app.launch()
        let history = app.buttons["HistoryButton"]
        XCTAssertTrue(history.waitForExistence(timeout: 120), app.debugDescription)
        XCTAssertEqual(app.staticTexts["M30SelectionState"].label, "unselected")
        let targetID = app.staticTexts["M30TargetID"].label
        let identifier = app.staticTexts["M30TargetRow"].label
        XCTAssertFalse(identifier.isEmpty)
        history.tap()
        let row = app.descendants(matching: .any).matching(identifier: identifier).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 30), app.debugDescription)
        for _ in 0..<4 where !row.isHittable { app.descendants(matching: .any)["HistoryPanel"].swipeUp() }
        XCTAssertTrue(row.isHittable, app.debugDescription)
        if target == "datum" {
            row.tap() // The actual native datum row is a Button.
        } else {
            let select = row.buttons["HistorySelect-" + targetID]
            XCTAssertTrue(select.isHittable, "Use the real History selection button, preserving inline rename/parameter fields")
            select.tap()
        } // Sole selection producer; no setSelection/proxy.
        let selected = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == 'selected'"), object: app.staticTexts["M30SelectionState"])
        XCTAssertEqual(XCTWaiter.wait(for: [selected], timeout: 20), .completed)
        XCTAssertTrue(row.isSelected, "Actual native History row must expose selected trait")
        let shot = XCTAttachment(screenshot: app.screenshot()); shot.name = "M30-\(target)-real-History-tap"; shot.lifetime = .keepAlways; add(shot)
        history.tap()
        app.buttons["cad.host.save"].tap() // Shipped host save, not fixture export button.
        let status = app.staticTexts["M30WitnessStatus"]
        let saved = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label BEGINSWITH %@", "witness saved \(target) "), object: status)
        XCTAssertEqual(XCTWaiter.wait(for: [saved], timeout: 45), .completed, app.debugDescription)
        let receipt = XCTAttachment(string: "nonce=\(nonce.uuidString) target=\(target) id=\(app.staticTexts["M30TargetID"].label) \(status.label)")
        receipt.name = "M30-\(target)-UI-save-witness"; receipt.lifetime = .keepAlways; add(receipt)
        XCTAssertTrue(app.buttons["cad.selection.askAssistant"].isEnabled, "Typed target, including a no-body datum, must reach the existing task composer")
        app.buttons["cad.selection.askAssistant"].tap() // Existing native task composer, no send.
        let composer = app.descendants(matching: .any)["composer.input"]
        XCTAssertTrue(composer.waitForExistence(timeout: 30), app.debugDescription)
        let draft = composer.value as? String ?? ""
        XCTAssertEqual(draft, "M30 synthetic unsent draft", "Selection must not modify user draft text")
        XCTAssertFalse(draft.contains(targetID), "No technical JSON/UUID in the visible draft")
        XCTAssertTrue(app.staticTexts["Selected 3D Part.json"].waitForExistence(timeout: 10), "Actual removable native attachment chip")
        let composerShot = XCTAttachment(screenshot: app.screenshot())
        composerShot.name = "M30-\(target)-same-task-attachment-no-send"; composerShot.lifetime = .keepAlways; add(composerShot)
        app.buttons["cad.selection.assistant.done"].tap()
        let adopted = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == %@", "witness ready with attachment \(target)"), object: status)
        XCTAssertEqual(XCTWaiter.wait(for: [adopted], timeout: 15), .completed)
        app.terminate() // Preserve the owned workspace for the App-host phase.
    }
}
