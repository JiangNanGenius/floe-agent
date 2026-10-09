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
        XCTAssertTrue(app.buttons["CADWorkbenchToolsButton"].waitForExistence(timeout: 20),
                      "the opened surface is the real CAD workbench (tools entry present)")
        workbenchDone.tap()
        XCTAssertTrue(toolbar.waitForExistence(timeout: 10),
                      "closing the workbench returns to the canvas node")
    }
}
#endif
