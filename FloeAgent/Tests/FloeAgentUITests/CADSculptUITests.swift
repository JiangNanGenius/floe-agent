// SPDX-License-Identifier: MPL-2.0
import XCTest

/// Drives shipped native controls and real viewport drag gestures. The DEBUG
/// fixture ONLY seeds one ordinary polygon grid. No command-executing proxy,
/// fake sculpt result or seeded mask/detail is used. XCUITest finger drags
/// have unit pressure; actual Pencil force qualification remains physical.
@MainActor final class CADSculptUITests:XCTestCase {
    private var app:XCUIApplication!
    override func setUpWithError() throws {
        continueAfterFailure=false;XCUIDevice.shared.orientation = .landscapeLeft
        app=XCUIApplication();app.launchArguments=["-AppleLanguages","(en)","-AppleLocale","en_US","-ui-testing","-ui-testing-ipad","--ui-test-cad-fixture","--ui-test-cad-sculpt","--ui-test-cad-sculpt-reset"]
        app.launch()
    }
    override func tearDownWithError() throws { app?.terminate();app=nil }
    private func openSculpt() {
        XCTAssertTrue(app.otherElements["CADFixtureHarness"].waitForExistence(timeout:60))
        let tools=app.buttons["CADWorkbenchToolsButton"].firstMatch
        if !tools.isHittable {
            let overflow=app.navigationBars.buttons["OverflowBarButtonItem"].firstMatch
            if overflow.waitForExistence(timeout:5) { overflow.tap() }
        }
        if tools.isHittable { tools.tap() } else { app.buttons["CAD Tools"].firstMatch.tap() }
        let mesh=app.segmentedControls.buttons["Mesh"].firstMatch
        XCTAssertTrue(mesh.waitForExistence(timeout:10));mesh.tap()
        let start=app.buttons["CADSculptStart"].firstMatch
        XCTAssertTrue(start.waitForExistence(timeout:10))
        for _ in 0..<4 where !start.isHittable { app.swipeUp() }
        if !start.isHittable { for _ in 0..<4 where !start.isHittable { app.swipeDown() } }
        XCTAssertTrue(start.isHittable);XCTAssertTrue(start.isEnabled);start.tap()
        XCTAssertTrue(app.otherElements["CADSculptHUD"].waitForExistence(timeout:15))
    }
    private func stroke(_ mode:String) {
        app.segmentedControls["CADSculptBrush"].buttons[mode].tap()
        let ack=app.staticTexts["CADSculptApplied"].firstMatch,before=ack.exists ? ack.label:""
        let viewport=app.descendants(matching:.any).matching(identifier:"CADEditorViewport").firstMatch
        XCTAssertTrue(viewport.exists)
        let a=viewport.coordinate(withNormalizedOffset:CGVector(dx:0.43,dy:0.34)),b=viewport.coordinate(withNormalizedOffset:CGVector(dx:0.60,dy:0.34))
        a.press(forDuration:0.08,thenDragTo:b,withVelocity:.slow,thenHoldForDuration:0.1)
        let applied=NSPredicate { _,_ in ack.exists && ack.label != before }
        XCTAssertEqual(XCTWaiter.wait(for:[XCTNSPredicateExpectation(predicate:applied,object:nil)],timeout:20),.completed,"A real new stroke must reach the ordinary service commit, not merely keep an old success label")
        XCTAssertFalse(app.staticTexts["CADSculptMessage"].exists)
    }
    func testNativeDrawSmoothMaskSubdivisionUndoAndColdSavedReopen() {
        openSculpt();stroke("Draw");stroke("Smooth");stroke("Mask")
        let subdivide=app.buttons["CADSculptSubdivide"].firstMatch
        XCTAssertTrue(subdivide.isEnabled);subdivide.tap()
        let level=app.descendants(matching:.any).matching(identifier:"CADSculptLevel").firstMatch
        let refined=NSPredicate { _,_ in String(describing:level.value).contains("1") && subdivide.isEnabled }
        XCTAssertEqual(XCTWaiter.wait(for:[XCTNSPredicateExpectation(predicate:refined,object:nil)],timeout:20),.completed)
        app.buttons["CADSculptUndo"].tap()
        let coarse=NSPredicate { _,_ in String(describing:level.value).contains("0") }
        XCTAssertEqual(XCTWaiter.wait(for:[XCTNSPredicateExpectation(predicate:coarse,object:nil)],timeout:10),.completed)
        app.buttons["CADSculptRedo"].tap()
        XCTAssertEqual(XCTWaiter.wait(for:[XCTNSPredicateExpectation(predicate:refined,object:nil)],timeout:20),.completed)
        subdivide.tap()
        let finer=NSPredicate { _,_ in String(describing:level.value).contains("2") && subdivide.isEnabled }
        XCTAssertEqual(XCTWaiter.wait(for:[XCTNSPredicateExpectation(predicate:finer,object:nil)],timeout:20),.completed)
        // Save is awaited by the real service callback; no fixture recreates
        // the document on this second launch. Process relaunch is cold storage.
        app.buttons["CADSculptDone"].tap();app.terminate()
        app.launchArguments.removeAll { $0=="--ui-test-cad-sculpt-reset" };app.launch()
        openSculpt()
        XCTAssertTrue(String(describing:app.descendants(matching:.any).matching(identifier:"CADSculptLevel").firstMatch.value).contains("2"))
        XCTAssertTrue(app.buttons["CADSculptClearMask"].exists)
        app.buttons["CADSculptDone"].tap()
    }
}
