// FloeAgentUITests — native whole-document version management.
// The existing plate fixture uses the real CAD document, store and workbench.
// UI actions create versions, change a variable, compare exact stored data,
// restore the original, and delete only the new branch checkpoint.

import XCTest

@MainActor
final class CADVersionManagementUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .landscapeLeft
        app = XCUIApplication()
        app.launchArguments += ["-AppleLanguages", "(en)", "-AppleLocale", "en_US",
                                "-ui-testing", "-ui-testing-ipad", "--ui-test-cad-fixture"]
        app.launch()
    }

    override func tearDownWithError() throws {
        app.terminate()
        app = nil
    }

    func testNativeVersionsCreateCompareRestoreAndDeleteBranch() throws {
        XCTAssertTrue(app.otherElements["CADFixtureHarness"].waitForExistence(timeout: 60))
        openVersions()
        let baselineID = try createVersion("Plate baseline")
        app.buttons["CADVersionsCloseButton"].tap()

        // Make a real persisted change through the existing editor UI. The
        // second version settles autosave, so compare must see this variable.
        openWorkbenchAction("VariablesButton", label: "Variables")
        let add = app.buttons["AddVariableButton"]
        XCTAssertTrue(add.waitForExistence(timeout: 10))
        add.tap()
        XCTAssertTrue(app.textFields["VariableNameField-var1"].waitForExistence(timeout: 10))
        openWorkbenchAction("VariablesButton", label: "Variables")

        openVersions()
        let changedID = try createVersion("With variable")
        XCTAssertNotEqual(baselineID, changedID)
        snapshot("Native versions after a real editor change")

        let compare = app.buttons["CADVersionCompare-" + baselineID]
        reveal(compare, upwards: true)
        compare.tap()
        let comparison = app.descendants(matching: .any)
            .matching(identifier: "CADVersionCompareResult").firstMatch
        let modelChanged = app.staticTexts["Model changed"]
        reveal(modelChanged, upwards: true)
        XCTAssertTrue(comparison.exists)
        XCTAssertTrue(modelChanged.exists,
                      "the current saved variable must change the model comparison")
        snapshot("Native version comparison with stored differences")

        let record = app.buttons.matching(NSPredicate(
            format: "identifier BEGINSWITH %@", "CADVersionRecord-")).firstMatch
        reveal(record, upwards: true)
        record.tap()
        XCTAssertTrue(app.descendants(matching: .any)
            .matching(identifier: "CADVersionRecordSheet").firstMatch.waitForExistence(timeout: 10),
                      "a real selected comparison record must be accessible")
        snapshot("Native version stored record details")
        app.buttons["CADVersionRecordCloseButton"].tap()

        let restore = app.buttons["CADVersionRestore-" + baselineID]
        reveal(restore, upwards: false)
        restore.tap()
        let restoreAlert = app.alerts["Restore Version?"]
        XCTAssertTrue(restoreAlert.waitForExistence(timeout: 5))
        restoreAlert.buttons.matching(identifier: "CADVersionRestoreConfirm").firstMatch.tap()
        let outcome = app.descendants(matching: .any)
            .matching(identifier: "CADVersionsOutcome").firstMatch
        // Native List virtualizes rows below the selected version details.
        // Reveal the actual status before waiting for its restore receipt.
        reveal(outcome, upwards: true)
        let restored = NSPredicate(format: "exists == true AND label CONTAINS %@", "Restored")
        let restoredExpectation = expectation(for: restored, evaluatedWith: outcome)
        wait(for: [restoredExpectation], timeout: 30)
        XCTAssertFalse(app.staticTexts["CADVersionsError"].exists,
                       "restoring the same document must report any real commit or branch failure")

        let branch = app.buttons.matching(NSPredicate(
            format: "identifier BEGINSWITH %@ AND label CONTAINS %@",
            "CADVersionRow-", "Branch")).firstMatch
        reveal(branch, upwards: false)
        XCTAssertTrue(branch.exists, "restore must create the actual branch it reports")
        let branchID = try versionID(from: branch)
        snapshot("Native versions after restoring the baseline")

        let delete = app.buttons["CADVersionDelete-" + branchID]
        reveal(delete, upwards: true)
        delete.tap()
        let deleteAlert = app.alerts["Delete Version?"]
        XCTAssertTrue(deleteAlert.waitForExistence(timeout: 5))
        deleteAlert.buttons.matching(identifier: "CADVersionDeleteConfirm").firstMatch.tap()
        let deleted = expectation(for: NSPredicate(format: "exists == false"),
                                  evaluatedWith: branch)
        wait(for: [deleted], timeout: 20)
        XCTAssertFalse(app.staticTexts["CADVersionsError"].exists)
        app.buttons["CADVersionsCloseButton"].tap()

        openWorkbenchAction("VariablesButton", label: "Variables")
        XCTAssertTrue(app.staticTexts["No variables yet"].waitForExistence(timeout: 10),
                      "restore must replace the current variable graph, not only the list label")
        XCTAssertFalse(app.textFields["VariableNameField-var1"].exists)
        snapshot("Native workbench graph after the version restore")
    }

    private func openVersions() {
        openWorkbenchAction("CADVersionsButton", label: "Versions")
        XCTAssertTrue(app.otherElements["CADVersionsPanel"].waitForExistence(timeout: 10))
        // Reuse the native inspector expansion gesture already exercised by
        // the drawing UI tests; scroll only this sheet's List afterward.
        let bar = app.navigationBars["Design Versions"]
        XCTAssertTrue(bar.waitForExistence(timeout: 5))
        bar.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            .press(forDuration: 0.1,
                   thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.12)))
    }

    private func createVersion(_ name: String) throws -> String {
        let create = app.buttons["CADVersionCreateButton"]
        XCTAssertTrue(create.waitForExistence(timeout: 10))
        create.tap()
        let alert = app.alerts["New Design Version"]
        XCTAssertTrue(alert.waitForExistence(timeout: 5))
        let field = alert.textFields.firstMatch
        XCTAssertTrue(field.exists)
        field.tap()
        field.typeText(name)
        // UIKit exposes nested same-frame buttons for this native alert on
        // iPadOS 27. Use its semantic action identifier and one native target.
        alert.buttons.matching(identifier: "CADVersionCreateConfirm").firstMatch.tap()
        let row = app.buttons.matching(NSPredicate(
            format: "identifier BEGINSWITH %@ AND label CONTAINS %@",
            "CADVersionRow-", name)).firstMatch
        if !row.waitForExistence(timeout: 30) {
            snapshot("Native version creation failure")
            let details = XCTAttachment(string: app.debugDescription)
            details.lifetime = .keepAlways
            add(details)
            XCTFail("the named version must exist after its actual store operation")
        }
        XCTAssertFalse(app.staticTexts["CADVersionsError"].exists)
        return try versionID(from: row)
    }

    private func versionID(from row: XCUIElement) throws -> String {
        let prefix = "CADVersionRow-"
        XCTAssertTrue(row.identifier.hasPrefix(prefix))
        let value = String(row.identifier.dropFirst(prefix.count))
        _ = try XCTUnwrap(UUID(uuidString: value), "the row must expose its real version identity")
        return value
    }

    private func openWorkbenchAction(_ identifier: String, label: String) {
        var button = app.buttons[identifier].firstMatch
        if !button.exists || !button.isHittable {
            let overflow = app.navigationBars.buttons["OverflowBarButtonItem"].firstMatch
            XCTAssertTrue(overflow.waitForExistence(timeout: 5),
                          "native overflow must preserve the requested workbench action")
            overflow.tap()
            if !button.exists { button = app.buttons[label].firstMatch }
        }
        XCTAssertTrue(button.waitForExistence(timeout: 5))
        XCTAssertTrue(button.isHittable)
        button.tap()
    }

    private func reveal(_ element: XCUIElement, upwards: Bool) {
        for _ in 0..<8 {
            if element.exists && element.isHittable { return }
            let list = app.collectionViews.firstMatch
            XCTAssertTrue(list.exists && list.isHittable,
                          "the native Versions list, not the background editor, must receive the scroll")
            if upwards { list.swipeUp() } else { list.swipeDown() }
        }
        snapshot("Unreachable native version action")
        let details = XCTAttachment(string: app.debugDescription)
        details.lifetime = .keepAlways
        add(details)
        XCTAssertTrue(element.exists && element.isHittable)
    }

    private func snapshot(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
