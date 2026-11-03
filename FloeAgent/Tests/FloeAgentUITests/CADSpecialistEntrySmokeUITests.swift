// SPDX-License-Identifier: MPL-2.0
import XCTest

/// Three native-entry smoke cases. Existing fixtures supply source geometry
/// only; every gear/rig/material edit below is a real shipped UI action.
/// Source-only packet: root owns canonical-iPad execution and visual judgment.
@MainActor final class CADSpecialistEntrySmokeUITests:XCTestCase {
    private var app:XCUIApplication!
    private let common=["-AppleLanguages","(en)","-AppleLocale","en_US","-floe.cad.unit","mm","-ui-testing","-ui-testing-ipad","--ui-test-cad-fixture"]
    override func setUpWithError() throws { continueAfterFailure=false;XCUIDevice.shared.orientation = .landscapeLeft }
    override func tearDownWithError() throws { app?.terminate();app=nil }
    private func any(_ id:String) -> XCUIElement { app.descendants(matching:.any).matching(identifier:id).firstMatch }
    private func launch(_ flags:[String]) {
        app=XCUIApplication();app.launchArguments=common+flags;app.launch()
        XCTAssertTrue(any("CADFixtureHarness").waitForExistence(timeout:60),app.debugDescription)
    }
    private func awaitValue(_ predicate:NSPredicate,_ object:Any?,timeout:TimeInterval=30) {
        XCTAssertEqual(XCTWaiter.wait(for:[XCTNSPredicateExpectation(predicate:predicate,object:object)],timeout:timeout),.completed,app.debugDescription)
    }
    private func gone(_ element:XCUIElement) { awaitValue(NSPredicate(format:"exists == false"),element) }
    private func enabled(_ element:XCUIElement) { awaitValue(NSPredicate(format:"exists == true AND enabled == true"),element) }
    private func toolbar(_ id:String,_ label:String) {
        let identified=app.buttons[id].firstMatch
        if identified.exists && identified.isHittable { identified.tap();return }
        let overflow=app.navigationBars.buttons["OverflowBarButtonItem"].firstMatch
        XCTAssertTrue(overflow.waitForExistence(timeout:10),"Missing toolbar action \(id)");overflow.tap()
        if identified.exists && identified.isHittable { identified.tap();return }
        let labelled=app.buttons[label].firstMatch
        XCTAssertTrue(labelled.waitForExistence(timeout:10));XCTAssertTrue(labelled.isHittable);labelled.tap()
    }
    private func openTools() {
        toolbar("CADWorkbenchToolsButton","CAD Tools")
        XCTAssertTrue(any("CADWorkbenchToolsPanel").waitForExistence(timeout:15))
    }
    private func closeTools() {
        let done=app.buttons["CADToolsSheetCloseButton"]
        if !done.isHittable {
            let named=app.navigationBars.buttons["CAD Tools"].firstMatch
            let back=named.exists && named.isHittable ? named:app.navigationBars.buttons["Back"].firstMatch
            XCTAssertTrue(back.waitForExistence(timeout:10));XCTAssertTrue(back.isHittable);back.tap()
        }
        XCTAssertTrue(done.waitForExistence(timeout:10));XCTAssertTrue(done.isHittable);done.tap();gone(done)
    }
    private func visibleBounds(_ container:XCUIElement) -> CGRect {
        var frame=container.frame.intersection(app.frame).insetBy(dx:6,dy:10)
        for bar in app.navigationBars.allElementsBoundByIndex where bar.exists && bar.isHittable && bar.frame.intersects(frame) {
            let top=max(frame.minY,bar.frame.maxY+5)
            frame=CGRect(x:frame.minX,y:top,width:frame.width,height:max(0,frame.maxY-top))
        }
        return frame
    }
    private func edgeScroll(_ container:XCUIElement,up:Bool) {
        let bounds=visibleBounds(container)
        XCTAssertGreaterThan(bounds.width,20);XCTAssertGreaterThan(bounds.height,100)
        let origin=container.coordinate(withNormalizedOffset:.zero)
        // Only the right margin of the identified Form/Tools/ToolPalette.
        // Never app.swipe*, viewport coordinates or a center-canvas gesture.
        let x=bounds.maxX-2,y0=bounds.minY+bounds.height*(up ? 0.8:0.25),y1=bounds.minY+bounds.height*(up ? 0.25:0.8)
        origin.withOffset(CGVector(dx:x-container.frame.minX,dy:y0-container.frame.minY))
            .press(forDuration:0.05,thenDragTo:origin.withOffset(CGVector(dx:x-container.frame.minX,dy:y1-container.frame.minY)))
    }
    @discardableResult private func reveal(_ element:XCUIElement,in containerID:String) -> XCUIElement {
        let container=any(containerID)
        XCTAssertTrue(container.waitForExistence(timeout:15),"No native container \(containerID)")
        for _ in 0..<14 {
            let bounds=visibleBounds(container)
            if element.exists && element.isHittable && bounds.contains(element.frame) { return element }
            let above=element.exists && element.frame.minY<bounds.minY
            edgeScroll(container,up:!above)
        }
        let diagnostic=XCTAttachment(string:app.debugDescription);diagnostic.name="Unreachable specialist control";diagnostic.lifetime = .keepAlways;add(diagnostic)
        XCTFail("Control did not fit inside the native container: \(element)")
        return element
    }
    private func menu(_ prefix:String,choose label:String,in container:String) {
        let picker=app.buttons.matching(NSPredicate(format:"label == %@ OR label BEGINSWITH %@ OR label BEGINSWITH %@ OR label BEGINSWITH %@",prefix,prefix+",",prefix+" ",prefix+"\n")).firstMatch
        reveal(picker,in:container).tap()
        let menuItem=app.menuItems[label].firstMatch
        if menuItem.waitForExistence(timeout:2) && menuItem.isHittable { menuItem.tap();return }
        let button=app.buttons.matching(NSPredicate(format:"label == %@",label)).allElementsBoundByIndex.first(where:{$0.isHittable})
        if let button { button.tap();return }
        let text=app.staticTexts[label].firstMatch
        XCTAssertTrue(text.waitForExistence(timeout:5));XCTAssertTrue(text.isHittable);text.tap()
    }
    // Adapted from the existing file-private CADHoleFormUI.replaceNumber.
    // Keep this test self-contained; no test/product visibility change needed.
    private func replaceNumber(_ id:String,with text:String) {
        let field=app.textFields[id]
        XCTAssertTrue(field.waitForExistence(timeout:10));XCTAssertTrue(field.isHittable)
        let seed=field.value as? String ?? ""
        field.coordinate(withNormalizedOffset:CGVector(dx:1,dy:0.5))
            .withOffset(CGVector(dx:-4,dy:0)).tap()
        let keypad=any("NumericKeypad")
        if keypad.waitForExistence(timeout:3) {
            let delete=app.buttons["KeypadDelete"]
            XCTAssertTrue(delete.waitForExistence(timeout:10))
            for _ in seed { delete.tap() }
            for character in text {
                let token=character == "-" ? "−":String(character)
                let key=app.buttons["Keypad-"+token]
                XCTAssertTrue(key.waitForExistence(timeout:10));key.tap()
            }
            let commit=app.buttons["KeypadCommit"]
            XCTAssertTrue(commit.waitForExistence(timeout:10));commit.tap();gone(keypad)
        } else {
            for _ in seed { field.typeText(XCUIKeyboardKey.delete.rawValue) }
            field.typeText(text);field.typeText(XCUIKeyboardKey.return.rawValue)
        }
        awaitValue(NSPredicate(format:"value == %@",text),field,timeout:10)
    }
    private func save() {
        let button=app.buttons["cad.host.save"]
        XCTAssertTrue(button.waitForExistence(timeout:15));enabled(button);button.tap()
        let outcome=any("cad.host.saveOutcome")
        awaitValue(NSPredicate(format:"exists == true AND label == %@","Saved"),outcome,timeout:60)
        enabled(button)
    }
    private func capture(_ name:String,container:String,controls:[String]) {
        let image=XCTAttachment(screenshot:app.screenshot());image.name=name;image.lifetime = .keepAlways;add(image)
        let frame=any(container).frame
        var text="app=\(app.frame)\ncontainer \(container)=\(frame)\n"
        for id in controls { let field=any(id);text += "\(id)=\(field.frame), hittable=\(field.isHittable), enabled=\(field.isEnabled)\n" }
        let layout=XCTAttachment(string:text);layout.name=name+" measured UI bounds";layout.lifetime = .keepAlways;add(layout)
    }
    private func gearRows() {
        toolbar("HistoryButton","History")
        XCTAssertTrue(any("HistoryPanel").waitForExistence(timeout:15))
        XCTAssertEqual(app.descendants(matching:.any).matching(identifier:"HistoryRow-Spur gear").count,1)
        XCTAssertFalse(any("HistoryError-Spur gear").exists)
        toolbar("HistoryButton","History");gone(any("HistoryPanel"))
        toolbar("ItemsButton","Items")
        XCTAssertTrue(any("ItemsPanel").waitForExistence(timeout:15))
        XCTAssertEqual(app.descendants(matching:.any).matching(identifier:"ItemRow-Spur gear · 20 teeth").count,1,"The actual output Body must exist, not only its feature row")
        XCTAssertEqual(any("ItemEye-Spur gear · 20 teeth").value as? String,"visible")
        toolbar("ItemsButton","Items");gone(any("ItemsPanel"))
    }
    func testSpurGearCreateRealApplySaveAndColdReopenRetainOneFeatureAndBody() {
        launch(["--ui-test-cad-uninstanced"])
        toolbar("HistoryButton","History");XCTAssertTrue(any("HistoryPanel").waitForExistence(timeout:15))
        XCTAssertFalse(any("HistoryRow-Spur gear").exists,"First launch seeds only the existing plate fixture")
        toolbar("HistoryButton","History");gone(any("HistoryPanel"))
        openTools();let parts=app.segmentedControls.buttons["Parts"].firstMatch;reveal(parts,in:"CADWorkbenchToolsPanel").tap()
        let type=app.segmentedControls.buttons["Spur gear"].firstMatch;reveal(type,in:"CADWorkbenchToolsPanel").tap()
        let create=app.buttons["Create part"].firstMatch;reveal(create,in:"CADWorkbenchToolsPanel");enabled(create);create.tap()
        let select=app.buttons["Select gear"].firstMatch
        XCTAssertTrue(select.waitForExistence(timeout:60),"A real created mechanical feature must be selected")
        awaitValue(NSPredicate(format:"exists == true AND label == %@","Applied"),any("CADMechanicalStatus"),timeout:60)
        reveal(any("CADMechanicalField.module"),in:"CADWorkbenchToolsPanel")
        replaceNumber("CADMechanicalField.module",with:"2.5")
        let apply=app.buttons["Apply changes"].firstMatch;reveal(apply,in:"CADWorkbenchToolsPanel");enabled(apply);apply.tap()
        enabled(apply);awaitValue(NSPredicate(format:"label == %@","Applied"),any("CADMechanicalStatus"),timeout:60)
        capture("M29 real gear edited through Parts",container:"CADWorkbenchToolsPanel",controls:["CADMechanicalField.module","CADMechanicalStatus"])
        closeTools();gearRows();save();app.terminate()
        launch(["--ui-test-cad-uninstanced","--ui-test-cad-reopen"])
        gearRows();openTools();reveal(app.segmentedControls.buttons["Parts"].firstMatch,in:"CADWorkbenchToolsPanel").tap()
        menu("Part",choose:"Spur gear",in:"CADWorkbenchToolsPanel")
        XCTAssertEqual(reveal(app.textFields["CADMechanicalField.module"],in:"CADWorkbenchToolsPanel").value as? String,"2.5")
        XCTAssertTrue(reveal(app.buttons["Select gear"].firstMatch,in:"CADWorkbenchToolsPanel").isEnabled)
        capture("M29 cold reopen same nondefault gear and actual body",container:"CADWorkbenchToolsPanel",controls:["CADMechanicalField.module","CADGearTeeth"])
        closeTools()
    }
    func testRigPanelBindsOriginalGridAndExposesJointWeightAndCapturedKeyControls() {
        launch(["--ui-test-cad-sculpt","--ui-test-cad-sculpt-reset","--ui-test-cad-compact"])
        openTools();reveal(app.buttons["CADRigOpen"],in:"CADWorkbenchToolsPanel").tap()
        XCTAssertTrue(any("CADRigPanel").waitForExistence(timeout:15))
        menu("Polygon mesh",choose:"Sculpt input",in:"CADWorkbenchToolsPanel")
        let bind=reveal(app.buttons["CADRigBind"],in:"CADWorkbenchToolsPanel");enabled(bind);bind.tap()
        let pose=app.buttons["CADRigApplyPose"]
        XCTAssertTrue(pose.waitForExistence(timeout:30));reveal(pose,in:"CADWorkbenchToolsPanel");enabled(pose)
        let child=app.buttons["Add child"].firstMatch;XCTAssertTrue(child.exists);XCTAssertTrue(child.isEnabled)
        pose.tap();enabled(pose)
        let weights=reveal(app.buttons["CADRigWeights"],in:"CADWorkbenchToolsPanel");enabled(weights);weights.tap();enabled(weights)
        let key=reveal(app.buttons["CADRigCaptureKey"],in:"CADWorkbenchToolsPanel");enabled(key);key.tap()
        XCTAssertTrue(app.staticTexts["0.00"].waitForExistence(timeout:30),"Real captured-key list must appear after the service save")
        let clip=reveal(app.buttons["CADRigCreateClip"],in:"CADWorkbenchToolsPanel");enabled(clip)
        capture("X26 compact native rig binding and key entry",container:"CADWorkbenchToolsPanel",controls:["CADRigCaptureKey","CADRigCreateClip"])
        // Two-key authoring/numerics/export are native-test contracts. The
        // existing time field has no stable ID; do not guess an index/tap.
        closeTools();save()
    }
    private func openMaterial() {
        let button=app.buttons["MaterialButton"]
        let palette=app.scrollViews["ToolPalette"]
        for _ in 0..<8 where !button.isHittable { XCTAssertTrue(palette.waitForExistence(timeout:10));edgeScroll(palette,up:true) }
        XCTAssertTrue(button.waitForExistence(timeout:20));XCTAssertTrue(button.isHittable);enabled(button);button.tap()
        XCTAssertTrue(any("CADMaterialInspectorForm").waitForExistence(timeout:20))
    }
    func testCompactMaterialAdvancedNativeSliderApplyAndRealNodePage() {
        launch(["--ui-test-cad-texture-paint","--ui-test-cad-texture-paint-reset","--ui-test-cad-compact"])
        openMaterial()
        let coat=app.sliders["CADMaterialClearcoat"]
        reveal(coat,in:"CADMaterialInspectorForm")
        let old=coat.value as? String ?? ""
        coat.adjust(toNormalizedSliderPosition:0.78)
        awaitValue(NSPredicate(format:"value != %@",old),coat)
        let edited=coat.value as? String ?? ""
        XCTAssertFalse(edited.isEmpty)
        capture("X11 compact actual native clearcoat slider",container:"CADMaterialInspectorForm",controls:["CADMaterialClearcoat"])
        let apply=app.buttons["CADMaterialApply"];enabled(apply);apply.tap();gone(any("CADMaterialInspectorForm"));save()
        openMaterial();let restored=reveal(app.sliders["CADMaterialClearcoat"],in:"CADMaterialInspectorForm")
        XCTAssertEqual(restored.value as? String,edited,"Reopened actual inspector reads the saved PBR value")
        let nodes=reveal(app.buttons["CADMaterialOpenNodes"],in:"CADMaterialInspectorForm");enabled(nodes);nodes.tap()
        XCTAssertTrue(any("CADMaterialGraphPanel").waitForExistence(timeout:20))
        reveal(any("CADMaterialNodeColor"),in:"CADMaterialGraphPanel")
        capture("X11 compact real declarative node editor",container:"CADMaterialGraphPanel",controls:["CADMaterialNodeColor"])
        let bake=reveal(app.buttons["CADMaterialGraphBake"],in:"CADMaterialGraphPanel");enabled(bake)
        capture("X11 actual graph output and bake entry fits",container:"CADMaterialGraphPanel",controls:["CADMaterialGraphBake"])
        // The current page has no persisted digest readback ID. An enabled
        // Bake button proves entry availability only; do not invent success.
    }
}
