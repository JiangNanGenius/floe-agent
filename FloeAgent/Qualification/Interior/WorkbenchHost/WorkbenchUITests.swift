// SPDX-License-Identifier: MPL-2.0
import XCTest

@MainActor
final class InteriorWorkbenchUITests:XCTestCase {
    private func launch()->XCUIApplication {
        let app=XCUIApplication();app.launchArguments=["-AppleLanguages","(zh-Hans)","-AppleLocale","zh_CN"];app.launch();return app
    }
    private func ready(_ element:XCUIElement,timeout:TimeInterval=15,file:StaticString=#filePath,line:UInt=#line){
        let predicate=NSPredicate(format:"exists == true AND hittable == true AND enabled == true")
        let result=XCTWaiter.wait(for:[XCTNSPredicateExpectation(predicate:predicate,object:element)],timeout:timeout)
        XCTAssertEqual(result,.completed,"Control not ready: "+element.identifier,file:file,line:line)
    }
    private func reveal(_ element:XCUIElement,app:XCUIApplication){
        for _ in 0..<6 {
            if element.exists && element.isHittable{return}
            app.swipeUp()
        }
        XCTAssertTrue(element.exists && element.isHittable,"Control could not be revealed")
    }
    private func select(_ section:String,in app:XCUIApplication) throws {
        let item=app.descendants(matching:.any)["building.section."+section].firstMatch
        if !item.isHittable {
            let toggle=app.buttons.matching(NSPredicate(format:"label CONTAINS[c] 'sidebar' OR label CONTAINS '边栏'")).firstMatch
            if toggle.exists && toggle.isHittable{toggle.tap()}
            else {
                let back=app.navigationBars.buttons.matching(NSPredicate(format:"label == %@ OR label == %@ OR label == %@","建筑设计","返回","Back")).firstMatch
                if back.exists && back.isHittable{back.tap()}
            }
        }
        ready(item)
        guard item.isHittable else{throw NSError(domain:"InteriorWorkbenchUI",code:1,userInfo:[NSLocalizedDescriptionKey:"Sidebar unavailable"])}
        item.tap()
        if ["cabinet","smartHome","radio","lighting","hvac"].contains(section){
            let save=app.buttons["building.design.save"];ready(save)
            XCTAssertEqual(app.buttons.matching(identifier:"building.design.save").count,1)
            XCTAssertFalse(app.buttons["building.cabinet.save"].exists)
            XCTAssertFalse(app.buttons["building.cabinet.update"].exists)
        }
    }
    private func replace(_ field:XCUIElement,with text:String){
        ready(field);field.tap()
        let old=field.value as? String ?? ""
        field.typeText(String(repeating:XCUIKeyboardKey.delete.rawValue,count:old.count)+text+XCUIKeyboardKey.return.rawValue)
    }
    private func number(_ field:XCUIElement,equals expected:Double,file:StaticString=#filePath,line:UInt=#line){
        let predicate=NSPredicate(format:"value == %@",String(format:"%.10g",expected))
        XCTAssertEqual(XCTWaiter.wait(for:[XCTNSPredicateExpectation(predicate:predicate,object:field)],timeout:15),.completed,file:file,line:line)
    }
    private func saved(_ app:XCUIApplication){
        let message=app.descendants(matching:.any)["building.notice"].firstMatch
        XCTAssertEqual(XCTWaiter.wait(for:[XCTNSPredicateExpectation(predicate:NSPredicate(format:"exists == true AND label BEGINSWITH %@","方案已保存"),object:message)],timeout:15),.completed)
    }
    private func screenshot(_ name:String,_ app:XCUIApplication){
        let a=XCTAttachment(screenshot:app.screenshot());a.name=name;a.lifetime = .keepAlways;add(a)
    }
    private func reopen(_ app:XCUIApplication){
        let more=app.buttons["building.more"];ready(more);more.tap()
        let reopen=app.buttons["building.reopen"];ready(reopen);reopen.tap()
    }
    func testRoomRenameSelectiveBillAndRelaunch() throws {
        let app=launch();try select("project",in:app)
        let suffix=String(UUID().uuidString.prefix(6)),name="验收房间_"+suffix,renamed="起居室_"+suffix
        replace(app.textFields["building.room.name"],with:name)
        ready(app.buttons["building.room.add"]);app.buttons["building.room.add"].tap()
        let rename=app.buttons["building.room.renameSelected"];reveal(rename,app:app);ready(rename);rename.tap()
        let renameField=app.textFields["building.room.renameText"];reveal(renameField,app:app);replace(renameField,with:renamed)
        app.buttons["building.room.renameSave"].tap()
        XCTAssertTrue(app.buttons[renamed].waitForExistence(timeout:15))
        try select("bill",in:app)
        replace(app.textFields["building.bom.targetName"],with:"验收料单_"+suffix)
        ready(app.buttons["building.bom.createTarget"]);app.buttons["building.bom.createTarget"].tap()
        ready(app.buttons["building.bom.sample"]);app.buttons["building.bom.sample"].tap()
        let relay=app.switches.matching(NSPredicate(format:"identifier BEGINSWITH 'building.bom.row.' AND label CONTAINS 'DEMO-RELAY'")).firstMatch
        reveal(relay,app:app);ready(relay);relay.tap()
        XCTAssertEqual(relay.value as? String,"0")
        let apply=app.buttons["building.bom.apply"];reveal(apply,app:app);ready(apply);apply.tap()
        let notice=app.descendants(matching:.any)["building.notice"].firstMatch
        XCTAssertTrue(notice.waitForExistence(timeout:15));XCTAssertTrue(notice.label.contains("所选行已采用"))
        screenshot("01-selected-bill-adoption",app)
        app.terminate();app.launch();try select("project",in:app)
        XCTAssertTrue(app.buttons[renamed].waitForExistence(timeout:15));screenshot("02-room-after-relaunch",app)
        XCTAssertFalse(app.descendants(matching:.any)["building.error"].exists)
    }
    func testCabinetDraftSurvivesSwitchUndoRedoCancelDiscardAndSave() throws {
        let app=launch();try select("cabinet",in:app)
        let field=app.textFields["building.number.cabinet.width"]
        replace(field,with:"2400")
        ready(app.buttons["building.design.save"]);app.buttons["building.design.save"].tap();saved(app)
        replace(field,with:"2600");try select("radio",in:app);try select("cabinet",in:app);number(field,equals:2600)
        ready(app.buttons["building.undo"]);app.buttons["building.undo"].tap();number(field,equals:2400)
        ready(app.buttons["building.redo"]);app.buttons["building.redo"].tap();number(field,equals:2600)
        reopen(app)
        let cancel=app.buttons["building.reopen.cancel"];ready(cancel);cancel.tap();number(field,equals:2600)
        reopen(app);let discard=app.buttons["building.reopen.discard"];ready(discard);discard.tap();number(field,equals:2400)
        replace(field,with:"2700");ready(app.buttons["building.design.save"]);app.buttons["building.design.save"].tap();saved(app)
        screenshot("03-cabinet-state-and-preview",app)
        app.terminate();app.launch();try select("cabinet",in:app);number(app.textFields["building.number.cabinet.width"],equals:2700)
        XCTAssertFalse(app.descendants(matching:.any)["building.error"].exists)
    }
    func testWirelessAndLightingResultsPersistAcrossWorkbenchSwitch() throws {
        let app=launch();try select("radio",in:app)
        let calculate=app.buttons["building.radio.calculate"];reveal(calculate,app:app);ready(calculate);calculate.tap()
        let result=app.staticTexts["building.radio.result"];reveal(result,app:app);XCTAssertTrue(result.waitForExistence(timeout:15));screenshot("04-radio-estimate",app)
        try select("lighting",in:app)
        ready(app.buttons["building.lighting.sample"]);app.buttons["building.lighting.sample"].tap()
        let light=app.buttons["building.lighting.calculate"];reveal(light,app:app);ready(light);light.tap()
        let value=app.descendants(matching:.any)["building.lighting.result"].firstMatch;reveal(value,app:app);XCTAssertTrue(value.waitForExistence(timeout:15))
        screenshot("05-direct-illuminance",app)
        try select("project",in:app);try select("lighting",in:app);reveal(value,app:app);XCTAssertTrue(value.exists)
        try select("smartHome",in:app);try select("hvac",in:app)
        XCTAssertFalse(app.descendants(matching:.any)["building.error"].exists)
    }
    func testIncompleteNumericInputIsRetainedAndUndoRestoresSavedValue() throws {
        let app=launch();try select("cabinet",in:app)
        let field=app.textFields["building.number.cabinet.width"]
        replace(field,with:"2800")
        ready(app.buttons["building.design.save"]);app.buttons["building.design.save"].tap();saved(app)
        replace(field,with:"1e")
        app.buttons["building.design.save"].tap()
        XCTAssertTrue(app.descendants(matching:.any)["building.error"].waitForExistence(timeout:15))
        try select("project",in:app);try select("cabinet",in:app)
        XCTAssertEqual(field.value as? String,"1e")
        ready(app.buttons["building.undo"]);app.buttons["building.undo"].tap();number(field,equals:2800)
        app.buttons["building.design.save"].tap();saved(app)
        XCTAssertFalse(app.descendants(matching:.any)["building.error"].exists)
        screenshot("06-numeric-input-recovery",app)
    }
}
