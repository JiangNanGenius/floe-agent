// SPDX-License-Identifier: MPL-2.0
// Real App controls over TWO saved open-line sketches. The fixture never
// creates surfaces or invokes an authoring proxy. Source supplied; not run by
// the private packet author. Root owns canonical-iPad App acceptance.
#if canImport(XCTest)
import XCTest

@MainActor final class CADLoftSurfaceFormAcceptanceUITests: XCTestCase {
    private func launch(reset: Bool) -> XCUIApplication {
        continueAfterFailure=false
        let app=XCUIApplication()
        app.launchArguments=["-AppleLanguages","(en)","-AppleLocale","en_US","-floe.cad.unit","mm",
            "-ui-testing","-ui-testing-ipad","--ui-test-cad-fixture","--ui-test-cad-surface-form"]
            + (reset ? ["--ui-test-cad-surface-form-reset"] : [])
        app.launch()
        XCTAssertTrue(app.buttons["HistoryButton"].waitForExistence(timeout:60),app.debugDescription)
        return app
    }
    private func any(_ app: XCUIApplication,_ id: String) -> XCUIElement { app.descendants(matching:.any)[id] }
    private func gone(_ element: XCUIElement,_ seconds: TimeInterval = 30) -> Bool {
        let expectation=XCTNSPredicateExpectation(predicate:NSPredicate(format:"exists == false"),object:element)
        return XCTWaiter().wait(for:[expectation],timeout:seconds) == .completed
    }
    private func visible(_ app: XCUIApplication,_ id: String) -> XCUIElement {
        let element=any(app,id)
        XCTAssertTrue(element.waitForExistence(timeout:20),"Missing real control \(id): \(app.debugDescription)")
        if !element.isHittable {
            let form=any(app,"CADSurfaceOptionsForm")
            for _ in 0..<4 where !element.isHittable { form.swipeUp() }
        }
        XCTAssertTrue(element.isHittable,"Unreachable real control \(id): \(app.debugDescription)")
        return element
    }
    private func openSurface(_ app: XCUIApplication) {
        let button=app.buttons["CADSurfaceButton"]
        if !button.exists || !button.isHittable { app.buttons["ModifyGroup"].tap() }
        XCTAssertTrue(button.waitForExistence(timeout:15),app.debugDescription);button.tap()
        XCTAssertTrue(app.buttons["CADSurfaceApply"].waitForExistence(timeout:30),app.debugDescription)
    }
    private func operation(_ app: XCUIApplication,_ raw: String,_ label: String) {
        visible(app,"CADSurfaceOperation").tap()
        let identified=any(app,"CADSurfaceOperationOption-"+raw)
        if identified.waitForExistence(timeout:3),identified.isHittable { identified.tap();return }
        let button=app.buttons[label].firstMatch
        if button.waitForExistence(timeout:3) { button.tap();return }
        let item=app.menuItems[label].firstMatch
        XCTAssertTrue(item.waitForExistence(timeout:5),app.debugDescription);item.tap()
    }
    private func number(_ app: XCUIApplication,_ id: String,_ value: String) {
        _ = visible(app,id)
        CADHoleFormUI.replaceNumber(app, identifier: id, with: value)
    }
    private func apply(_ app: XCUIApplication) {
        let button=app.buttons["CADSurfaceApply"]
        XCTAssertTrue(button.isEnabled,"Real settings are not valid: \(app.debugDescription)");button.tap()
        XCTAssertTrue(gone(button),"The real transaction must finish: \(app.debugDescription)")
    }
    private func history(_ app: XCUIApplication,_ open: Bool) {
        let panel=any(app,"HistoryPanel")
        if panel.exists != open { app.buttons["HistoryButton"].tap() }
        if open { XCTAssertTrue(panel.waitForExistence(timeout:15)) } else { XCTAssertTrue(gone(panel,10)) }
    }
    private func assertRows(_ app: XCUIApplication,thickened: Bool) {
        history(app,true)
        for name in ["Surface","Trim"] {
            XCTAssertEqual(app.descendants(matching:.any).matching(identifier:"HistoryRow-"+name).count,1,app.debugDescription)
        }
        XCTAssertEqual(app.descendants(matching:.any).matching(identifier:"HistoryRow-Thicken").count,thickened ? 1 : 0,app.debugDescription)
        XCTAssertFalse(any(app,"HistoryError-Surface").exists);XCTAssertFalse(any(app,"HistoryError-Trim").exists)
        XCTAssertFalse(any(app,"HistoryError-Thicken").exists)
        history(app,false)
    }
    private func save(_ app: XCUIApplication) {
        let button=app.buttons["cad.host.save"]
        XCTAssertTrue(button.waitForExistence(timeout:15));button.tap()
        let outcome=any(app,"cad.host.saveOutcome")
        XCTAssertTrue(outcome.waitForExistence(timeout:60));XCTAssertEqual(outcome.label,"Saved")
    }
    private func capture(_ app: XCUIApplication,_ name: String) {
        let attachment=XCTAttachment(screenshot:app.screenshot());attachment.name=name;attachment.lifetime = .keepAlways;add(attachment)
    }
    func testRealSurfaceCreateTrimThickenUndoSaveReopenAndSameHistoryEdit() {
        var app=launch(reset:true)
        // Only sketches exist at launch. The first real form creates an
        // actual open surface from the two source curves.
        history(app,true)
        XCTAssertFalse(any(app,"HistoryRow-Surface").exists)
        history(app,false)
        openSurface(app)
        XCTAssertTrue(app.buttons["CADSurfaceApply"].isEnabled)
        apply(app)
        capture(app,"M17 real open surface created")
        openSurface(app);operation(app,"trim","Trim")
        number(app,"CADSurfaceAcrossStart","25");number(app,"CADSurfaceAcrossEnd","75")
        number(app,"CADSurfaceAlongStart","25");number(app,"CADSurfaceAlongEnd","75")
        apply(app)
        openSurface(app);operation(app,"thicken","Thicken")
        visible(app,"CADSurfaceCheck").tap()
        let closure=any(app,"CADSurfaceClosed")
        XCTAssertTrue(closure.waitForExistence(timeout:15));XCTAssertEqual(closure.value as? String,"No")
        number(app,"CADSurfaceThickness","2");apply(app)
        assertRows(app,thickened:true);capture(app,"M17 native trim and thicken history")
        app.buttons["UndoButton"].tap();assertRows(app,thickened:false)
        app.buttons["RedoButton"].tap();assertRows(app,thickened:true)
        save(app);app.terminate()
        app=launch(reset:false)
        assertRows(app,thickened:true)
        history(app,true)
        let row=any(app,"HistoryRow-Thicken")
        XCTAssertTrue(row.waitForExistence(timeout:20));row.press(forDuration:1.2)
        let edit=app.buttons["EditSurface-Thicken"]
        if edit.waitForExistence(timeout:5) { edit.tap() }
        else {
            let labelled=app.buttons["Edit Surface"].firstMatch
            XCTAssertTrue(labelled.waitForExistence(timeout:5));labelled.tap()
        }
        XCTAssertTrue(app.buttons["CADSurfaceApply"].waitForExistence(timeout:30))
        XCTAssertEqual(visible(app,"CADSurfaceThickness").value as? String,"2")
        number(app,"CADSurfaceThickness","3");apply(app)
        assertRows(app,thickened:true)
        save(app);capture(app,"M17 reopened same feature thickness edited to 3")
        app.terminate()
    }
}
#endif
