//
//  CADImportLimitsUITests.swift
//  FloeAgentUITests — E31 native import-limit UI qualification.
//
//  Three focused flows over the DEBUG fixture (`CADImportLimitsUIFixture`):
//
//    * accepted: the SHIPPED pre-Apply import banner names the real GLB source,
//      format and mesh class; Apply consumes the pending proposal and adds the
//      real imported body as one undoable step.
//    * rejected: a 400 MiB DECLARED zip is refused by the production kernel
//      import path; the fixture's read-back status proves zero bodies, zero
//      proposals, unchanged revision and byte-identical source.
//    * cancelled: the real parse is cancelled at its first large allocation;
//      the status proves zero bodies/proposals, unchanged revision, unchanged
//      source and an off-main parse.
//
//  Every displayed value is read back from the real services; the fixture does
//  not fabricate a refusal, cancellation or success. Root owns the Simulator
//  run. This is not a physical-iPad memory/latency measurement.
//
//  SPDX-License-Identifier: MPL-2.0
//

import XCTest

@MainActor
final class CADImportLimitsUITests: XCTestCase {
    private enum Launch {
        static let base = ["-AppleLanguages", "(en)", "-AppleLocale", "en_US",
                           "-ui-testing", "-ui-testing-ipad", "--ui-test-cad-fixture"]
        static let accepted = "--ui-test-cad-import-accepted"
        static let rejected = "--ui-test-cad-import-rejected"
        static let cancelled = "--ui-test-cad-import-cancelled"
    }

    func testAcceptedGLBImportShowsTheRealBannerAndAppliesOneBody() throws {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .landscapeLeft
        let app = XCUIApplication()
        app.launchArguments = Launch.base + [Launch.accepted]
        app.launch()
        defer { app.terminate() }

        let apply = app.buttons["cad.native.apply"]
        XCTAssertTrue(apply.waitForExistence(timeout: 120),
                      "the shipped import banner must appear for a real GLB proposal")
        let detail = app.staticTexts["cad.native.importDetail"]
        XCTAssertTrue(detail.waitForExistence(timeout: 20))
        XCTAssertTrue(detail.label.contains("AcceptedGrid.glb"), detail.label)
        XCTAssertTrue(detail.label.contains("GLB"), detail.label)
        XCTAssertTrue(detail.label.lowercased().contains("mesh"), detail.label)
        XCTAssertTrue(app.buttons["cad.native.discard"].exists)
        CADSheetProbe.attach("E31 accepted GLB proposal before Apply", to: self)

        apply.tap()
        XCTAssertTrue(CADSheetProbe.waitForAbsence(apply, timeout: 120),
                      "Apply must consume the real pending import proposal")
        openItems(app)
        XCTAssertTrue(itemRow(containing: "Grid", in: app).waitForExistence(timeout: 60),
                      "Apply must add the real imported mesh body")
        XCTAssertTrue(app.buttons["UndoButton"].waitForExistence(timeout: 30),
                      "the imported body must be undoable from the shipped workbench")
        CADSheetProbe.attach("E31 accepted GLB body after Apply", to: self)
    }

    func testOverBudgetZipIsRefusedBeforeAnyBodyAndKeepsTheSource() throws {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .landscapeLeft
        let app = XCUIApplication()
        app.launchArguments = Launch.base + [Launch.rejected]
        app.launch()
        defer { app.terminate() }

        let status = app.staticTexts["cad.importLimits.fixtureStatus"]
        XCTAssertTrue(status.waitForExistence(timeout: 120),
                      "the fixture must publish the real over-budget outcome")
        let label = status.label
        XCTAssertTrue(label.contains("overbudget"), label)
        XCTAssertTrue(label.contains("bodies=0"), label)
        XCTAssertTrue(label.contains("proposals=0"), label)
        XCTAssertTrue(label.contains("revisionUnchanged=true"), label)
        XCTAssertTrue(label.contains("sourceUnchanged=true"), label)
        XCTAssertTrue(label.contains("detail="), label)
        XCTAssertFalse(app.buttons["cad.native.apply"].exists,
                       "a refused import must not offer an Apply banner")
        CADSheetProbe.attach("E31 over-budget zip refusal (actual read-back)", to: self)
    }

    func testCancelledImportLeavesNoProposalBodyOrSourceChange() throws {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .landscapeLeft
        let app = XCUIApplication()
        app.launchArguments = Launch.base + [Launch.cancelled]
        app.launch()
        defer { app.terminate() }

        let status = app.staticTexts["cad.importLimits.fixtureStatus"]
        XCTAssertTrue(status.waitForExistence(timeout: 120),
                      "the fixture must publish the real cancellation outcome")
        let label = status.label
        XCTAssertTrue(label.contains("cancelled"), label)
        XCTAssertTrue(label.contains("bodies=0"), label)
        XCTAssertTrue(label.contains("proposals=0"), label)
        XCTAssertTrue(label.contains("revisionUnchanged=true"), label)
        XCTAssertTrue(label.contains("sourceUnchanged=true"), label)
        XCTAssertTrue(label.contains("parse=offmain"), label)
        XCTAssertFalse(app.buttons["cad.native.apply"].exists,
                       "a cancelled import must not leave a late Apply banner")
        CADSheetProbe.attach("E31 cancelled import (actual read-back)", to: self)
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
