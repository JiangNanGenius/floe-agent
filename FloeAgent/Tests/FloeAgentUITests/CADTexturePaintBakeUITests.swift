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
        for _ in 0..<5 where !element.exists || !element.isHittable { app.swipeUp() }
        for _ in 0..<7 where !element.exists || !element.isHittable { app.swipeDown() }
        XCTAssertTrue(element.waitForExistence(timeout:20),app.debugDescription)
        XCTAssertTrue(element.isHittable,app.debugDescription);return element
    }
    private func openPaint() {
        let material=app.buttons["MaterialButton"]
        for _ in 0..<6 where !material.isHittable { app.scrollViews["ToolPalette"].swipeUp() }
        XCTAssertTrue(material.waitForExistence(timeout:30));XCTAssertTrue(material.isEnabled);material.tap()
        reveal("CADMaterialOpenTexturePaint").tap()
        XCTAssertTrue(any("CADTexturePaintCanvas").waitForExistence(timeout:30))
    }
    private func digest(_ expected:String?=nil)->String {
        if !any("CADTexturePaintStoredDigest").exists { reveal("CADTexturePaintDetails").tap() }
        let field=reveal("CADTexturePaintStoredDigest")
        if let expected {
            let result=XCTWaiter.wait(for:[XCTNSPredicateExpectation(predicate:NSPredicate(format:"value == %@",expected),object:field)],timeout:30)
            XCTAssertEqual(result,.completed,app.debugDescription)
        }
        return field.value as? String ?? field.label
    }
    private func awaitNewDigest(_ old:String)->String {
        if !any("CADTexturePaintStoredDigest").exists { reveal("CADTexturePaintDetails").tap() }
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
