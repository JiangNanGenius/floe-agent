// SPDX-License-Identifier: MPL-2.0
import XCTest
import UIKit

@MainActor final class PencilPaletteUITests: XCTestCase {
    func testPaletteControlsStayInsideWindowAtAllAnchors() {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = UIDevice.current.userInterfaceIdiom == .pad ? .landscapeLeft : .portrait
        let app = XCUIApplication()
        app.launch()
        defer { app.terminate() }
        for location in ["top", "center", "bottom"] {
            app.buttons["palette.open.\(location)"].tap()
            let marker = app.buttons["notes.pencil.quickMenu.highlighter"]
            XCTAssertTrue(marker.waitForExistence(timeout: 5))
            let screenshot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
            screenshot.name = "palette-\(location)"
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
        }
    }
}
