// SPDX-License-Identifier: MPL-2.0
import XCTest

@MainActor
final class InteriorEditorUITests:XCTestCase {
    private func application()->XCUIApplication {
        let app=XCUIApplication()
        app.launchArguments=["-AppleLanguages","(zh-Hans)","-AppleLocale","zh_CN"]
        app.launchEnvironment["FLOE_INTERIOR_QUALIFICATION_RUN_ID"]=UUID().uuidString
        app.launch();return app
    }
    private func ready(_ element:XCUIElement,file:StaticString=#filePath,line:UInt=#line) {
        let predicate=NSPredicate(format:"exists == true AND hittable == true AND enabled == true")
        XCTAssertEqual(XCTWaiter.wait(for:[XCTNSPredicateExpectation(predicate:predicate,object:element)],timeout:30),.completed,file:file,line:line)
    }
    private func choose(_ name:String,app:XCUIApplication) {
        let item=app.descendants(matching:.any)["building.section."+name].firstMatch
        if !item.isHittable {
            let toggle=app.buttons.matching(NSPredicate(format:"label CONTAINS[c] 'sidebar' OR label CONTAINS '边栏'")).firstMatch
            if toggle.exists && toggle.isHittable {toggle.tap()}
        }
        ready(item);item.tap()
    }
    private func capture(_ title:String,app:XCUIApplication) {
        let attachment=XCTAttachment(screenshot:app.screenshot());attachment.name=title;attachment.lifetime = .keepAlways;add(attachment)
    }
    func testOneProjectToolbarAcrossNativeModelFurnitureAndDrawings() {
        let app=application()
        ready(app.buttons["building.design.save"])
        for section in ["model","furniture","cabinet","deliverables","project"] {
            choose(section,app:app)
            XCTAssertEqual(app.buttons.matching(identifier:"building.design.save").count,1)
            XCTAssertEqual(app.buttons.matching(identifier:"building.close").count,1)
            XCTAssertFalse(app.buttons["building.cabinet.save"].exists)
            XCTAssertFalse(app.buttons["building.cabinet.update"].exists)
            capture("Editor-"+section,app:app)
        }
    }
    func testUnfinishedWorkingCopyIsOfferedAfterProcessTermination() {
        let app=application();ready(app.buttons["building.design.save"])
        choose("project",app:app)
        let field=app.textFields["building.room.name"];ready(field);field.tap();field.typeText("Recovered room")
        let add=app.buttons["building.room.add"];ready(add);add.tap()
        XCTAssertTrue(app.buttons["Recovered room"].waitForExistence(timeout:15))
        app.terminate();app.launch()
        XCTAssertTrue(app.buttons["building.recovery.published"].waitForExistence(timeout:30))
        capture("Editor-recovery-choice",app:app)
    }
    func testNativeModelModeHasOneHistoryAndProjectSaveOwner() {
        let app=application();ready(app.buttons["building.design.save"])
        choose("model",app:app)
        let modes=app.segmentedControls["building.mode"];ready(modes)
        let model=modes.buttons.matching(NSPredicate(format:"label == '模型' OR label == 'Model'")).firstMatch
        ready(model);model.tap()
        XCTAssertTrue(app.buttons["UndoButton"].waitForExistence(timeout:30))
        XCTAssertEqual(app.buttons.matching(identifier:"UndoButton").count,1)
        XCTAssertEqual(app.buttons.matching(identifier:"RedoButton").count,1)
        XCTAssertFalse(app.buttons["building.undo"].exists)
        XCTAssertFalse(app.buttons["building.redo"].exists)
        XCTAssertEqual(app.buttons.matching(identifier:"building.design.save").count,1)
        XCTAssertFalse(app.buttons["CADBuildingSave"].exists)
        let exports=app.buttons["ExportMenu"];ready(exports);exports.tap()
        XCTAssertFalse(app.buttons["SaveProjectButton"].exists, "Native CAD must not offer a partial save as the whole building project save")
        capture("Editor-native-history-and-save-owner",app:app)
    }
    func testFloorDraftingUsesOneProjectToolbarAndReturnsToModel() {
        let app=application();ready(app.buttons["building.design.save"])
        choose("model",app:app)
        let modes=app.segmentedControls["building.mode"];ready(modes)
        let drafting=modes.buttons.matching(NSPredicate(format:"label == '二维 CAD' OR label == '2D CAD'")).firstMatch
        ready(drafting);drafting.tap()
        XCTAssertTrue(app.descendants(matching:.any)["building.drafting.workspace"].waitForExistence(timeout:30))
        XCTAssertTrue(app.descendants(matching:.any)["CAD2DDraftingBar"].waitForExistence(timeout:30))
        XCTAssertEqual(app.buttons.matching(identifier:"building.design.save").count,1)
        XCTAssertEqual(app.buttons.matching(identifier:"building.close").count,1)
        XCTAssertEqual(app.buttons.matching(identifier:"UndoButton").count,1)
        XCTAssertEqual(app.buttons.matching(identifier:"RedoButton").count,1)
        XCTAssertFalse(app.buttons["building.undo"].exists)
        XCTAssertFalse(app.buttons["building.redo"].exists)
        let exports=app.buttons["ExportMenu"];ready(exports);exports.tap()
        XCTAssertFalse(app.buttons["SaveProjectButton"].exists)
        capture("Editor-floor-drafting-toolbar",app:app)
        // Close the menu without choosing an output or a partial save.
        app.tap()
        let model=modes.buttons.matching(NSPredicate(format:"label == '模型' OR label == 'Model'")).firstMatch
        ready(model);model.tap()
        XCTAssertFalse(app.descendants(matching:.any)["CAD2DDraftingBar"].exists)
        XCTAssertEqual(app.buttons.matching(identifier:"building.design.save").count,1)
        XCTAssertEqual(app.buttons.matching(identifier:"UndoButton").count,1)
        choose("project",app:app);choose("model",app:app)
        ready(drafting);drafting.tap()
        XCTAssertTrue(app.descendants(matching:.any)["CAD2DDraftingBar"].waitForExistence(timeout:30))
        capture("Editor-floor-drafting-return",app:app)
    }
    func testSavedProjectClosesAndReopensWithoutRelaunchingApp() {
        let app=application();let save=app.buttons["building.design.save"];ready(save);save.tap()
        let close=app.buttons["building.close"];ready(close);close.tap()
        let reopen=app.buttons["building.closed.reopen"];ready(reopen)
        capture("Editor-closed-project",app:app);reopen.tap()
        ready(app.buttons["building.design.save"])
        XCTAssertFalse(app.descendants(matching:.any)["building.error"].exists)
    }
}
