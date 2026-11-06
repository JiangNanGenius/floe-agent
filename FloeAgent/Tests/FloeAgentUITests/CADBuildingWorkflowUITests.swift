// SPDX-License-Identifier: MPL-2.0
import XCTest

@MainActor
final class CADBuildingWorkflowUITests:XCTestCase {
    private var app:XCUIApplication!
    private let base=["-AppleLanguages","(en)","-AppleLocale","en_US","-ui-testing","-ui-testing-ipad","--ui-test-cad-fixture","--ui-test-cad-building"]
    override func setUpWithError() throws { continueAfterFailure=false;XCUIDevice.shared.orientation = .landscapeLeft }
    override func tearDownWithError() throws { app?.terminate();app=nil }
    private func any(_ id:String)->XCUIElement { app.descendants(matching:.any).matching(identifier:id).firstMatch }
    private func tap(_ id:String,_ title:String) {
        let identified=app.buttons[id].firstMatch
        if identified.exists,identified.isHittable { identified.tap();return }
        let overflow=app.navigationBars.buttons["OverflowBarButtonItem"].firstMatch
        if overflow.exists,overflow.isHittable { overflow.tap() }
        if identified.exists,identified.isHittable { identified.tap();return }
        let named=app.buttons[title].firstMatch
        XCTAssertTrue(named.waitForExistence(timeout:10),app.debugDescription);named.tap()
    }
    private func add(_ type:String) {
        tap("building.addElement","Add element")
        app.buttons[type].firstMatch.tap()
        XCTAssertTrue(app.buttons["building.element.apply"].waitForExistence(timeout:10))
        app.buttons["building.element.apply"].tap()
    }
    func testPlanImportModelSaveReopenDrawingAndProfessionalMenus() {
        app=XCUIApplication();app.launchArguments=base+["--ui-test-cad-building-reset"];app.launch()
        XCTAssertTrue(app.buttons["building.import.preview"].waitForExistence(timeout:60),app.debugDescription)
        app.buttons["building.import.preview"].tap()
        XCTAssertTrue(app.buttons["building.import.generate"].waitForExistence(timeout:15),app.debugDescription)
        app.buttons["building.import.generate"].tap()
        XCTAssertTrue(any("building.plan.canvas").waitForExistence(timeout:20),app.debugDescription)
        add("Slab");add("Door");add("Beam")
        tap("building.save","Save")
        XCTAssertTrue(app.buttons["building.save"].waitForExistence(timeout:10))
        let saved=XCTNSPredicateExpectation(predicate:NSPredicate(format:"enabled == true"),object:app.buttons["building.save"])
        XCTAssertEqual(XCTWaiter.wait(for:[saved],timeout:30),.completed)
        app.terminate();app.launchArguments=base+["--ui-test-cad-building-reopen"];app.launch()
        XCTAssertTrue(any("building.plan.canvas").waitForExistence(timeout:60),app.debugDescription)
        XCTAssertTrue(any("building.fixture.status").label.contains("bodies=7"),app.debugDescription)
        app.segmentedControls["building.mode"].buttons["Model"].tap()
        XCTAssertTrue(any("CADEditorViewport").waitForExistence(timeout:30),app.debugDescription)
        let modelShot=XCTAttachment(screenshot:XCUIScreen.main.screenshot());modelShot.name="Building model after cold reopen";modelShot.lifetime = .keepAlways;add(modelShot)
        app.segmentedControls["building.mode"].buttons["Plan"].tap()
        for kind in ["Column","Roof","Stair","Window","Space","Pipe","Duct"] {
            tap("building.addElement","Add element");app.buttons[kind].firstMatch.tap()
            XCTAssertTrue(app.buttons["building.element.apply"].waitForExistence(timeout:10),kind)
            app.buttons["Cancel"].firstMatch.tap()
        }
        for (title, sheetTitle) in [("IFC exchange","Export IFC"),("Structural study","Beam analysis"),("MEP coordination","MEP coordination"),("Information requirements","Information requirements")] {
            tap("building.tools","Building tools");app.buttons[title].firstMatch.tap()
            XCTAssertTrue(app.staticTexts["Open the building from a task workspace and select a Linux execution environment."].waitForExistence(timeout:10),app.debugDescription)
            app.navigationBars[sheetTitle].buttons["Done"].tap()
        }
        tap("building.tools","Building tools");app.buttons["Project checks"].firstMatch.tap()
        XCTAssertTrue(app.staticTexts["Project rules"].waitForExistence(timeout:10),app.debugDescription)
        XCTAssertTrue(any("building.check.jurisdiction").exists)
        let checksShot=XCTAttachment(screenshot:XCUIScreen.main.screenshot());checksShot.name="Building checks show unevaluated project rules";checksShot.lifetime = .keepAlways;add(checksShot)
        app.navigationBars["Project checks"].buttons["Done"].tap()
        tap("building.tools","Building tools");app.buttons["Create drawings"].firstMatch.tap()
        XCTAssertTrue(any("CADDrawingPanel").waitForExistence(timeout:30),app.debugDescription)
        let shot=XCTAttachment(screenshot:XCUIScreen.main.screenshot());shot.name="Building plan to native drawings";shot.lifetime = .keepAlways;add(shot)
        app.buttons["View"].firstMatch.tap()
        let vectorTitle=app.staticTexts.matching(NSPredicate(format:"label BEGINSWITH %@","Vector preview · ")).firstMatch
        XCTAssertTrue(vectorTitle.waitForExistence(timeout:30),app.debugDescription)
        let entityCount=Int(vectorTitle.label.components(separatedBy:"·").last?.trimmingCharacters(in:.whitespacesAndNewlines) ?? "")
        XCTAssertGreaterThan(entityCount ?? 0,0,"The building drawing must contain actual projected vectors")
        XCTAssertTrue(any("CADDrawingPreview").exists)
        let vectorShot=XCTAttachment(screenshot:XCUIScreen.main.screenshot());vectorShot.name="Building actual projected vector drawing";vectorShot.lifetime = .keepAlways;add(vectorShot)
        app.buttons["CADDrawingPreviewClose"].tap()
        app.buttons["DXF"].firstMatch.tap()
        XCTAssertTrue(app.buttons["CADDrawingShareExport"].waitForExistence(timeout:30),app.debugDescription)
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format:"label BEGINSWITH %@","DXF export ready")).firstMatch.exists,
                      "The real DXF writer must complete before the flow is accepted")
        let exportShot=XCTAttachment(screenshot:XCUIScreen.main.screenshot());exportShot.name="Building actual DXF export ready";exportShot.lifetime = .keepAlways;add(exportShot)
    }
}
