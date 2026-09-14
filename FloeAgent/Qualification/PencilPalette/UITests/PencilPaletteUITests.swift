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
            for element in [marker, app.buttons["notes.pencil.quickMenu.close"]] {
                XCTAssertTrue(element.isHittable)
                XCTAssertGreaterThanOrEqual(element.frame.width, 43.5)
                XCTAssertGreaterThanOrEqual(element.frame.height, 43.5)
                XCTAssertGreaterThanOrEqual(element.frame.minY, app.frame.minY)
                XCTAssertLessThanOrEqual(element.frame.maxY, app.frame.maxY)
            }
            marker.tap()
            XCTAssertTrue(marker.isSelected)
            let color = app.buttons["notes.pencil.quickMenu.color.1"]
            color.tap(); XCTAssertTrue(color.isSelected)
            let width = app.buttons["notes.pencil.quickMenu.width.32"]
            width.tap(); XCTAssertTrue(width.isSelected)
            app.buttons["notes.pencil.quickMenu.close"].tap()
            let opener = app.buttons["palette.open.\(location)"]
            let dismissed = expectation(for: NSPredicate(format: "hittable == true"), evaluatedWith: opener)
            wait(for: [dismissed], timeout: 10)
            XCTAssertTrue(opener.isHittable)
        }
    }
}
