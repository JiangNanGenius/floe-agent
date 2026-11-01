//
//  CADImportSchedulingUITests.swift
//  FloeAgentUITests — E31-R2 exact/manual import scheduling UI qualification.
//
//  Three focused flows over the DEBUG fixture (`CADImportLimitsUIFixture`):
//
//    * exact accepted: a REAL STEP written by the production document writer
//      drafts through the tool host and shows the shipped import banner; Apply
//      consumes the pending proposal and adds the real exact body.
//    * exact cancelled: the real STEP read/tessellation is held at its
//      prepared-body checkpoint, cancelled, and the fixture's read-back status
//      proves zero bodies/proposals, unchanged revision and unchanged source
//      while the parse ran off the MainActor.
//    * manual STEP: the real Workbench editor consumes the fixture trigger and
//      runs the SAME async manual import the Import menu starts; the body
//      appears in Items and is undoable.
//
//  Every value shown in the status line is read back from the real services;
//  the fixture never fabricates a refusal, cancellation or success. Root owns
//  the Simulator run. This is not a physical-iPad memory/latency measurement.
//
//  SPDX-License-Identifier: MPL-2.0
//

import XCTest

@MainActor
final class CADImportSchedulingUITests: XCTestCase {
    private enum Launch {
        static let base = ["-AppleLanguages", "(en)", "-AppleLocale", "en_US",
                           "-ui-testing", "-ui-testing-ipad", "--ui-test-cad-fixture"]
        static let exactAccepted = "--ui-test-cad-import-exact-accepted"
        static let exactCancelled = "--ui-test-cad-import-exact-cancelled"
        static let manualStep = "--ui-test-cad-import-manual-step"
    }

    func testExactSTEPToolImportShowsBannerAndAppliesOneBody() throws {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .landscapeLeft
        let app = XCUIApplication()
        app.launchArguments = Launch.base + [Launch.exactAccepted]
        app.launch()
        defer { app.terminate() }

        let apply = app.buttons["cad.native.apply"]
        XCTAssertTrue(apply.waitForExistence(timeout: 120),
                      "the shipped import banner must appear for a real STEP proposal")
        let detail = app.staticTexts["cad.native.importDetail"]
        XCTAssertTrue(detail.waitForExistence(timeout: 20))
        XCTAssertTrue(detail.label.contains("ExactPlate.step"), detail.label)
        XCTAssertTrue(detail.label.contains("STEP"), detail.label)
        XCTAssertTrue(app.buttons["cad.native.discard"].exists)
        CADSheetProbe.attach("E31-R2 exact STEP proposal before Apply", to: self)

        apply.tap()
        XCTAssertTrue(CADSheetProbe.waitForAbsence(apply, timeout: 120),
                      "Apply must consume the real pending exact proposal")
        openItems(app)
        XCTAssertTrue(itemRow(containing: "ExactPlate", in: app).waitForExistence(timeout: 60),
                      "Apply must add the real exact STEP body")
        XCTAssertTrue(app.buttons["UndoButton"].waitForExistence(timeout: 30),
                      "the exact import must be undoable from the shipped workbench")
        CADSheetProbe.attach("E31-R2 exact STEP body after Apply", to: self)
    }

    func testExactCancelledImportLeavesNoProposalBodyOrSourceChange() throws {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .landscapeLeft
        let app = XCUIApplication()
        app.launchArguments = Launch.base + [Launch.exactCancelled]
        app.launch()
        defer { app.terminate() }

        let status = app.staticTexts["cad.importLimits.fixtureStatus"]
        XCTAssertTrue(status.waitForExistence(timeout: 120),
                      "the fixture must publish the real exact cancellation outcome")
        let label = status.label
        XCTAssertTrue(label.contains("cancelled"), label)
        XCTAssertTrue(label.contains("bodies=0"), label)
        XCTAssertTrue(label.contains("proposals=0"), label)
        XCTAssertTrue(label.contains("revisionUnchanged=true"), label)
        XCTAssertTrue(label.contains("sourceUnchanged=true"), label)
        XCTAssertTrue(label.contains("parse=offmain"), label)
        XCTAssertTrue(label.contains("formatted=step"), label)
        XCTAssertFalse(app.buttons["cad.native.apply"].exists,
                       "a cancelled exact import must not leave a late Apply banner")
        CADSheetProbe.attach("E31-R2 exact cancelled import (actual read-back)", to: self)
    }

    func testManualSTEPImportAddsOneBodyThroughTheRealWorkbench() throws {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .landscapeLeft
        let app = XCUIApplication()
        app.launchArguments = Launch.base + [Launch.manualStep]
        app.launch()
        defer { app.terminate() }

        XCTAssertTrue(app.buttons["ItemsButton"].waitForExistence(timeout: 120),
                      "the fixture must present the real Workbench")
        openItems(app)
        XCTAssertTrue(itemRow(containing: "ManualStep", in: app).waitForExistence(timeout: 120),
                      "the manual STEP import must add the real body through the Workbench")
        XCTAssertTrue(app.buttons["UndoButton"].waitForExistence(timeout: 30),
                      "the manual exact import must be one undoable step")
        CADSheetProbe.attach("E31-R2 manual STEP body", to: self)
    }

    // MARK: - Shipped workbench helpers

    private func openItems(_ app: XCUIApplication) {
        let direct = app.buttons["ItemsButton"].firstMatch
        if direct.waitForExistence(timeout: 60) && direct.isHittable {
            direct.tap()
        } else {
            XCTAssertTrue(CADSheetProbe.openToolbarAction("ItemsButton", label: "Items", in: app),
                          "the workbench must expose the real Items toggle")
        }
        XCTAssertTrue(CADSheetProbe.any(app, "ItemsPanel").waitForExistence(timeout: 30),
                      "the real Items panel must open")
    }

    private func itemRow(containing text: String, in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(
            NSPredicate(format: "identifier BEGINSWITH %@ AND identifier CONTAINS %@",
                        "ItemRow-", text)
        ).firstMatch
    }
}
