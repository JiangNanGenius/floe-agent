// FloeAgentUITests — native CAD Canvas node entry surface.
//
// Regression for the two reported CUA defects on a selected canvas CAD node:
//   1. the node rendered a generic document icon labelled image/png instead of
//      its real viewport thumbnail with an editable `.floecad` identity;
//   2. the selected-node contextual pencil "编辑/Edit" action only inline
//      renamed the node instead of opening the native CAD workbench.
//
// The `-ui-testing --ui-test-canvas-cad-fixture` harness creates an ordinary
// canvas with ONE canvas-owned native CAD node through the production bridge
// and presents the real WorkspaceCanvasView with that node selected, so the
// bottom contextual toolbar shows the explicit CAD action.
//
// SPDX-License-Identifier: MPL-2.0

#if canImport(XCTest)
import XCTest

@MainActor
final class CanvasCADEntryUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments += ["-AppleLanguages", "(en)", "-AppleLocale", "en_US",
                                "-ui-testing", "-ui-testing-ipad",
                                "--ui-test-canvas-cad-fixture"]
        app.launch()
    }

    override func tearDownWithError() throws {
        app.terminate()
        app = nil
    }

    func testSelectedCADNodeContextualActionOpensNativeEditor() throws {
        // The fixture canvas with its CAD node is presented.
        XCTAssertTrue(app.otherElements["CanvasCADFixtureHarness"]
            .waitForExistence(timeout: 60),
                      "the canvas CAD fixture must launch")

        // The CAD node card presents its real viewport thumbnail and editable
        // `.floecad` identity (dedicated CAD body, not a generic document icon
        // labelled image/png). The host node card combines the CAD body, so
        // the `canvas.node.<uuid>` element's label carries the identity.
        let nodeCard = app.descendants(matching: .any).matching(
            NSPredicate(format:
                "identifier BEGINSWITH %@ AND label CONTAINS %@",
                "canvas.node.", ".floecad")
        ).firstMatch
        XCTAssertTrue(nodeCard.waitForExistence(timeout: 20),
                      "the CAD node must identify its editable .floecad source on the node card")
        XCTAssertTrue((nodeCard.label ?? "").contains("CAD"),
                      "the CAD node label must read as a CAD model, got: \(nodeCard.label ?? "-")")

        // The selected-node bottom contextual toolbar appears and carries the
        // EXPLICIT CAD editor action (cube icon), distinct from rename.
        let toolbar = app.otherElements["canvas.node.toolbar"]
        XCTAssertTrue(toolbar.waitForExistence(timeout: 30),
                      "selecting the CAD node must show its contextual toolbar")
        let openButton = app.buttons["canvas.toolbar.openNativeCAD"]
        XCTAssertTrue(openButton.waitForExistence(timeout: 20),
                      "the contextual toolbar must expose the explicit Open CAD action")
        // A separate rename control must exist (Edit no longer means rename).
        let renameCount = app.buttons.matching(
            NSPredicate(format: "label == %@", "Rename")).count
        XCTAssertGreaterThan(renameCount, 0, "rename stays a separate contextual action")

        openButton.tap()

        // The SAME binding route as double tap opens the full-screen native
        // workbench: its explicit Done control and tools entry are present.
        let workbenchDone = app.buttons["canvas.nativeCAD.done"]
        XCTAssertTrue(workbenchDone.waitForExistence(timeout: 30),
                      "the explicit CAD action must open the native workbench")
        XCTAssertTrue(app.segmentedControls["CADWorkbenchMode"].waitForExistence(timeout: 10),
                      "the opened surface must expose the native Edit/Present modes")
        let workbench = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        workbench.name = "Canvas CAD node in the native workbench before tools"
        workbench.lifetime = .keepAlways
        add(workbench)

        // The native iPad toolbar moves trailing actions into More in a
        // portrait or narrower window. Follow that real route instead of
        // requiring every action to remain drawn in the navigation bar.
        var tools = app.buttons["CADWorkbenchToolsButton"].firstMatch
        if !tools.exists || !tools.isHittable {
            let nativeBar = app.navigationBars.containing(
                .button, identifier: "canvas.nativeCAD.done").firstMatch
            let overflow = nativeBar.buttons["OverflowBarButtonItem"].firstMatch
            XCTAssertTrue(overflow.waitForExistence(timeout: 5),
                          "the native toolbar must keep its overflow entry reachable")
            overflow.tap()
            if !tools.exists { tools = app.buttons["CAD Tools"].firstMatch }
        }
        XCTAssertTrue(tools.waitForExistence(timeout: 10),
                      "the native CAD tools action must remain reachable")
        tools.tap()
        XCTAssertTrue(app.otherElements["CADWorkbenchToolsPanel"].waitForExistence(timeout: 15),
                      "the actual tools panel must open from this Canvas-owned document")
        let closeTools = app.buttons["CADToolsSheetCloseButton"]
        XCTAssertTrue(closeTools.waitForExistence(timeout: 5))
        closeTools.tap()
        XCTAssertTrue(workbenchDone.isHittable,
                      "closing tools must return to the same native workbench")
        workbenchDone.tap()
        XCTAssertTrue(toolbar.waitForExistence(timeout: 10))
        XCTAssertTrue(toolbar.isHittable,
                      "closing the workbench returns to the selected canvas node")
    }
}

@MainActor
final class CADRecoveryCopyFlowUITests: XCTestCase {
    func testDamagedCanvasPreviewsPreviousAndRestoresAnEditableSeparateCopy() throws {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .landscapeLeft
        let app = XCUIApplication()
        app.launchArguments = ["-AppleLanguages", "(en)", "-AppleLocale", "en_US",
                               "-ui-testing", "-ui-testing-ipad",
                               "--ui-test-canvas-cad-fixture", "--ui-test-canvas-cad-damaged"]
        app.launch()
        defer { app.terminate() }
        let open = app.buttons["canvas.toolbar.openNativeCAD"]
        XCTAssertTrue(open.waitForExistence(timeout: 60))
        open.tap()

        let sheet = app.descendants(matching: .any)
            .matching(identifier: "cad.recovery.sheet").firstMatch
        XCTAssertTrue(sheet.waitForExistence(timeout: 30))
        XCTAssertTrue(app.descendants(matching: .any)["cad.recovery.previewImage"].exists,
                      "the real previous viewport thumbnail must be available")
        snapshot("Damaged canvas verified previous preview")
        // Cancel does not silently replace the damaged package.
        app.buttons["cad.recovery.closeButton"].tap()
        let review = app.buttons["cad.recovery.reviewButton"]
        XCTAssertTrue(review.waitForExistence(timeout: 10))
        XCTAssertFalse(app.segmentedControls["CADWorkbenchMode"].exists)
        review.tap()
        XCTAssertTrue(sheet.waitForExistence(timeout: 10))

        let unknown = app.staticTexts[
            "Changes made after this save can't be verified. Their fields are unknown; they stay in the damaged document."]
        reveal(unknown, in: app)
        XCTAssertTrue(unknown.exists, "unrecoverable fields must be reported honestly")
        snapshot("Recovery report keeps unverified current changes explicit")
        app.buttons["cad.recovery.restoreButton"].tap()
        let mode = app.segmentedControls["CADWorkbenchMode"]
        XCTAssertTrue(mode.waitForExistence(timeout: 30))
        XCTAssertTrue(app.descendants(matching: .any)["cad.recovery.canvas.unbound"].exists,
                      "the recovered copy must not silently replace the node binding")
        snapshot("Recovered copy is editable and remains separate from its canvas node")

        openWorkbenchAction("VariablesButton", label: "Variables", in: app)
        let add = app.buttons["AddVariableButton"]
        XCTAssertTrue(add.waitForExistence(timeout: 10))
        add.tap()
        XCTAssertTrue(app.textFields["VariableNameField-var1"].waitForExistence(timeout: 10))
        openWorkbenchAction("VariablesButton", label: "Variables", in: app)
        app.buttons["canvas.nativeCAD.done"].tap()
        XCTAssertTrue(open.waitForExistence(timeout: 20))
        open.tap()
        XCTAssertTrue(sheet.waitForExistence(timeout: 20),
                      "reopening the node must still find the damaged original, not the recovered copy")
        snapshot("Canvas still owns the unchanged damaged original after copy editing")
        app.buttons["cad.recovery.closeButton"].tap()
        app.buttons["canvas.nativeCAD.done"].tap()
        XCTAssertTrue(open.waitForExistence(timeout: 10))
    }

    private func reveal(_ element: XCUIElement, in app: XCUIApplication) {
        for _ in 0..<8 {
            if element.exists && element.isHittable { return }
            let scroll = app.scrollViews.firstMatch
            if scroll.exists { scroll.swipeUp() } else { app.swipeUp() }
        }
        XCTFail("The recovery report must keep its remaining fields reachable")
    }

    private func openWorkbenchAction(_ identifier: String, label: String,
                                     in app: XCUIApplication) {
        let direct = app.buttons[identifier].firstMatch
        if direct.exists && direct.isHittable {
            direct.tap()
            return
        }
        let bar = app.navigationBars.containing(.button, identifier: "canvas.nativeCAD.done").firstMatch
        let overflow = bar.buttons["OverflowBarButtonItem"].firstMatch
        XCTAssertTrue(overflow.waitForExistence(timeout: 5))
        overflow.tap()
        let action = direct.exists ? direct : app.buttons[label].firstMatch
        XCTAssertTrue(action.waitForExistence(timeout: 5))
        action.tap()
    }

    private func snapshot(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
#endif
