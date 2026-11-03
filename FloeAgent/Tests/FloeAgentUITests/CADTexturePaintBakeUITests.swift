// SPDX-License-Identifier: MPL-2.0
import XCTest

/// Actual iPad controls. The fixture seeds only a real UV plane and an AO
/// occluder. Stored-image SHA readback comes from the applied Body snapshot.
@MainActor final class CADTexturePaintBakeUITests:XCTestCase {
    private let base=["-AppleLanguages","(en)","-AppleLocale","en_US","-ui-testing","-ui-testing-ipad","--ui-test-cad-fixture","--ui-test-cad-texture-paint"]
    private var app:XCUIApplication!
    override func tearDownWithError()throws { app?.terminate();app=nil }
    private func any(_ id:String)->XCUIElement { app.descendants(matching:.any).matching(identifier:id).firstMatch }
    private func reveal(_ id:String)->XCUIElement {
        let element=any(id)
        for _ in 0..<16 {
            let paint=any("CADTexturePaintForm"),material=any("CADMaterialInspectorForm")
            let form=paint.exists ? paint : material
            XCTAssertTrue(form.waitForExistence(timeout:10))
            var visible=form.frame.intersection(app.frame).insetBy(dx:8,dy:8)
            let bar=app.navigationBars["Texture painting"]
            if paint.exists && bar.exists {
                let top=max(visible.minY,bar.frame.maxY+4)
                visible=CGRect(x:visible.minX,y:top,width:visible.width,height:max(0,visible.maxY-top))
            }
            if element.exists && element.isHittable && visible.contains(element.frame) { return element }
            // Form virtualizes offscreen rows. The first canvas disappears
            // from AX after opening Details below it; its absence must scroll
            // back up, rather than repeatedly scroll farther down.
            let above=element.exists ? element.frame.minY<visible.minY : id=="CADTexturePaintCanvas"
            // The centre is the real painting canvas; scroll in the native
            // Form margin and only towards the currently missing row.
            form.coordinate(withNormalizedOffset:CGVector(dx:0.985,dy:above ? 0.6 : 0.9))
                .press(forDuration:0.05,thenDragTo:form.coordinate(withNormalizedOffset:CGVector(dx:0.985,dy:above ? 0.9 : 0.6)))
        }
        let diagnostic=XCTAttachment(string:app.debugDescription)
        diagnostic.name="Texture form control not visible: \(id)";diagnostic.lifetime = .keepAlways;add(diagnostic)
        XCTAssertTrue(element.exists && element.isHittable,"Missing visible real control \(id): \(app.debugDescription)")
        return element
    }
    private func openPaint() {
        let material=app.buttons["MaterialButton"]
        for _ in 0..<6 where !material.isHittable { app.scrollViews["ToolPalette"].swipeUp() }
        XCTAssertTrue(material.waitForExistence(timeout:30));XCTAssertTrue(material.isEnabled);material.tap()
        reveal("CADMaterialOpenTexturePaint").tap()
        XCTAssertTrue(any("CADTexturePaintCanvas").waitForExistence(timeout:30))
    }
    private func digest(_ expected:String?=nil)->String {
        if !any("CADTexturePaintStoredDigest").exists {
            reveal("CADTexturePaintDetails").tap()
            let expanded=XCTAttachment(string:app.debugDescription)
            expanded.name="Texture stored-detail disclosure expanded";expanded.lifetime = .keepAlways;add(expanded)
        }
        let field=reveal("CADTexturePaintStoredDigest")
        if let expected {
            let result=XCTWaiter.wait(for:[XCTNSPredicateExpectation(predicate:NSPredicate(format:"value == %@",expected),object:field)],timeout:30)
            XCTAssertEqual(result,.completed,app.debugDescription)
        }
        return field.value as? String ?? field.label
    }
    private func awaitNewDigest(_ old:String)->String {
        if !any("CADTexturePaintStoredDigest").exists {
            reveal("CADTexturePaintDetails").tap()
            let expanded=XCTAttachment(string:app.debugDescription)
            expanded.name="Texture stored-detail disclosure expanded";expanded.lifetime = .keepAlways;add(expanded)
        }
        let field=reveal("CADTexturePaintStoredDigest")
        let result=XCTWaiter.wait(for:[XCTNSPredicateExpectation(predicate:NSPredicate(format:"value != %@ AND value != %@",old,"none"),object:field)],timeout:60)
        XCTAssertEqual(result,.completed,app.debugDescription)
        XCTAssertFalse(any("CADTexturePaintError").exists,app.debugDescription)
        return field.value as? String ?? field.label
    }
    private func capture(_ name:String) { let a=XCTAttachment(screenshot:app.screenshot());a.name=name;a.lifetime = .keepAlways;add(a) }
    func testRealSurfaceStrokeUndoBakeSaveReopenUsesStoredPixels() {
        continueAfterFailure=false;app=XCUIApplication();app.launchArguments=base+["--ui-test-cad-texture-paint-reset"];app.launch()
        openPaint();XCTAssertEqual(digest("none"),"none")
        let canvas=reveal("CADTexturePaintCanvas")
        canvas.coordinate(withNormalizedOffset:CGVector(dx:0.43,dy:0.48)).press(forDuration:0.1,thenDragTo:canvas.coordinate(withNormalizedOffset:CGVector(dx:0.62,dy:0.57)))
        let painted=awaitNewDigest("none");XCTAssertEqual(painted.count,64);capture("X10 actual surface stroke")
        reveal("CADTexturePaintUndo").tap();XCTAssertEqual(digest("none"),"none")
        reveal("CADTexturePaintRedo").tap();XCTAssertEqual(digest(painted),painted)
        let others=reveal("CADTextureBakeOtherBodies");others.tap()
        let bake=reveal("CADTextureBakeAO");XCTAssertTrue(bake.isEnabled);bake.tap()
        let baked=awaitNewDigest(painted);XCTAssertNotEqual(baked,painted);capture("X10 geometry AO baked into current color")
        app.buttons["CADTexturePaintDone"].tap();app.buttons["CADMaterialCancel"].tap()
        let save=app.buttons["cad.host.save"];XCTAssertTrue(save.waitForExistence(timeout:20));save.tap()
        XCTAssertTrue(any("cad.host.saveOutcome").waitForExistence(timeout:30));XCTAssertEqual(any("cad.host.saveOutcome").label,"Saved")
        app.terminate();app.launchArguments=base;app.launch();openPaint()
        XCTAssertEqual(digest(baked),baked);capture("X10 fresh process retained actual baked PNG")
    }
}
