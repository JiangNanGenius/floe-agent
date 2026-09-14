// SPDX-License-Identifier: MPL-2.0
import XCTest
import UIKit
import PencilKit

@MainActor final class PencilPaletteUITests: XCTestCase {
    func testPaletteControlsStayInsideWindowAtAllAnchors() {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = UIDevice.current.userInterfaceIdiom == .pad ? .landscapeLeft : .portrait
        let app = XCUIApplication()
        app.launch()
        defer { app.terminate() }
        for placement in ["above", "upperLeft", "upperRight"] {
            app.buttons["palette.placement.\(placement)"].tap()
            for location in ["top", "center", "bottom"] {
                app.buttons["palette.open.\(location)"].tap()
                let marker = app.buttons["notes.pencil.quickMenu.highlighter"]
                XCTAssertTrue(marker.waitForExistence(timeout: 5))
                let screenshot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
                screenshot.name = "palette-\(placement)-\(location)"
                screenshot.lifetime = .keepAlways
                add(screenshot)
                for identifier in ["pencil.tip", "highlighter", "eraser", "lasso", "viewfinder", "close"] {
                    let element = app.buttons["notes.pencil.quickMenu.\(identifier)"]
                    XCTAssertTrue(element.isHittable)
                    XCTAssertGreaterThanOrEqual(element.frame.width, 43.5)
                    XCTAssertGreaterThanOrEqual(element.frame.height, 43.5)
                    XCTAssertGreaterThanOrEqual(element.frame.minX, app.frame.minX)
                    XCTAssertLessThanOrEqual(element.frame.maxX, app.frame.maxX)
                    XCTAssertGreaterThanOrEqual(element.frame.minY, app.frame.minY)
                    XCTAssertLessThanOrEqual(element.frame.maxY, app.frame.maxY)
                }
                let tip = app.buttons["notes.pencil.quickMenu.close"].frame
                let pen = app.buttons["notes.pencil.quickMenu.pencil.tip"].frame
                let ai = app.buttons["notes.pencil.quickMenu.viewfinder"].frame
                if placement == "upperLeft" {
                    XCTAssertLessThan(pen.midX, tip.midX); XCTAssertGreaterThan(pen.midY, tip.midY)
                    XCTAssertGreaterThan(ai.midX, tip.midX); XCTAssertLessThan(ai.midY, tip.midY)
                } else if placement == "upperRight" {
                    XCTAssertLessThan(pen.midX, tip.midX); XCTAssertLessThan(pen.midY, tip.midY)
                    XCTAssertGreaterThan(ai.midX, tip.midX); XCTAssertGreaterThan(ai.midY, tip.midY)
                }
                if location != "center" {
                    app.buttons["notes.pencil.quickMenu.close"].tap()
                    XCTAssertFalse(marker.exists)
                    continue
                }
                // Moving toward a tool previews it but lifting must not commit it.
                let priorTool = app.staticTexts["palette.selectedTool"].label
                let center = app.buttons["notes.pencil.quickMenu.close"].coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
                center.press(forDuration: 0.1, thenDragTo: marker.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)))
                XCTAssertTrue(marker.exists)
                XCTAssertEqual(app.staticTexts["palette.selectedTool"].label, priorTool)
                XCTAssertEqual(marker.value as? String, "预览，轻触选择")
                marker.tap()
                let opener = app.buttons["palette.open.\(location)"]
                let dismissed = expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: app.buttons["notes.pencil.quickMenu.close"])
                wait(for: [dismissed], timeout: 10)
                XCTAssertTrue(opener.isHittable)
                XCTAssertFalse(app.buttons["notes.pencil.quickMenu.close"].exists)
                XCTAssertEqual(app.staticTexts["palette.selectedTool"].label, "荧光笔")
                opener.tap()
                XCTAssertTrue(marker.waitForExistence(timeout: 5))
                XCTAssertTrue(marker.isSelected)
                app.buttons["notes.pencil.quickMenu.close"].tap()
                let cancelled = expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: app.buttons["notes.pencil.quickMenu.close"])
                wait(for: [cancelled], timeout: 10)
                XCTAssertEqual(app.staticTexts["palette.selectedTool"].label, "荧光笔")
                // The same binding used by squeeze supports closing with a second invocation.
                opener.tap()
                XCTAssertTrue(marker.waitForExistence(timeout: 5))
                opener.tap()
                XCTAssertFalse(marker.exists)
                opener.tap()
                XCTAssertTrue(marker.waitForExistence(timeout: 5))
                app.coordinate(withNormalizedOffset: CGVector(dx: 0.05, dy: 0.6)).tap()
                XCTAssertFalse(marker.exists)
            }
        }
        app.terminate()
        app.launch()
        XCTAssertTrue(app.buttons["palette.placement.upperRight"].isSelected)
    }

    func testBrushParametersApplyAndPersistAcrossReopen() {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = UIDevice.current.userInterfaceIdiom == .pad ? .landscapeLeft : .portrait
        let app = XCUIApplication()
        app.launch()
        defer { app.terminate() }
        app.buttons["palette.brushes"].tap()
        app.buttons["notes.ink.brush.pen"].tap()
        let thin = app.buttons["notes.ink.width.preset.0"]
        let thick = app.buttons["notes.ink.width.preset.2"]
        XCTAssertTrue(thin.waitForExistence(timeout: 5))
        thin.tap()
        let thinValue = app.staticTexts["notes.ink.width.value"].label
        thick.tap()
        let thickValue = app.staticTexts["notes.ink.width.value"].label
        XCTAssertNotEqual(thinValue, thickValue)
        let opacity = app.sliders["notes.ink.opacity.slider"]
        if !opacity.isHittable { app.scrollViews["notes.ink.parameters"].swipeUp() }
        XCTAssertTrue(opacity.isHittable)
        opacity.adjust(toNormalizedSliderPosition: 0.35)
        let savedOpacity = opacity.value as? String
        let capture = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        capture.name = "native-brush-parameters"; capture.lifetime = .keepAlways; add(capture)
        app.buttons["palette.brushes.done"].tap()
        app.terminate()
        app.launch()
        app.buttons["palette.brushes"].tap()
        XCTAssertEqual(app.staticTexts["notes.ink.width.value"].label, thickValue)
        XCTAssertEqual(app.sliders["notes.ink.opacity.slider"].value as? String, savedOpacity)
        app.buttons["palette.brushes.done"].tap()
    }

    func testAllBrushesReachNativeCanvasAndRememberPen() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launch()
        defer { app.terminate() }
        let brushes: [(String, PKInkingTool.InkType)] = [
            ("pen", .pen), ("fountainPen", .fountainPen), ("monoline", .monoline),
            ("pencil", .pencil), ("crayon", .crayon), ("watercolor", .watercolor),
            ("reed", .reed), ("marker", .marker)
        ]
        for (name, inkType) in brushes {
            app.buttons["palette.brushes"].tap()
            let button = app.buttons["notes.ink.brush.\(name)"]
            XCTAssertTrue(button.waitForExistence(timeout: 5))
            if name == "pen" {
                let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
                shot.name = "native-brush-picker"; shot.lifetime = .keepAlways; add(shot)
            }
            button.tap()
            app.buttons["palette.brushes.done"].tap()
            let closed = expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: button)
            wait(for: [closed], timeout: 10)
            let canvas = app.descendants(matching: .any).matching(identifier: "palette.canvas").firstMatch
            XCTAssertTrue(canvas.waitForExistence(timeout: 5))
            let applied = expectation(for: NSPredicate(format: "value == %@", inkType.rawValue), evaluatedWith: canvas)
            wait(for: [applied], timeout: 5)
        }
        app.buttons["palette.brushes"].tap()
        app.buttons["notes.ink.brush.fountainPen"].tap()
        app.buttons["palette.brushes.done"].tap()
        app.terminate()
        app.launch()
        XCTAssertEqual(app.descendants(matching: .any).matching(identifier: "palette.canvas").firstMatch.value as? String, PKInkingTool.InkType.fountainPen.rawValue)
    }
}
