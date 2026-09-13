// SPDX-License-Identifier: MPL-2.0
import XCTest
import Vision

@MainActor final class NativeNotesUITests: XCTestCase {
    func testReaderWindowScreenAndCloseInBothOrientations() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--linked-map-fixture"]
        XCUIDevice.shared.orientation = .portrait
        app.launch()
        defer { app.terminate(); XCUIDevice.shared.orientation = .portrait }
        let topic = app.webViews.staticTexts["Trade gains"]
        XCTAssertTrue(topic.waitForExistence(timeout: 30), "The real WebKit topic must be visible before screenshot capture")
        let portrait = XCTAttachment(screenshot: app.screenshot())
        portrait.name = "Notes PDF and independent map — portrait component scene"
        portrait.lifetime = .keepAlways; add(portrait)
        XCUIDevice.shared.orientation = .landscapeLeft
        let rotationDeadline = Date().addingTimeInterval(10)
        while app.frame.width <= app.frame.height && Date() < rotationDeadline { Thread.sleep(forTimeInterval: 0.1) }
        XCTAssertGreaterThan(app.frame.width, app.frame.height, "The app viewport must actually rotate before labeling a landscape screenshot")
        XCTAssertTrue(topic.waitForExistence(timeout: 10))
        let landscape = XCTAttachment(screenshot: app.screenshot())
        landscape.name = "Notes PDF and independent map — landscape component scene"
        landscape.lifetime = .keepAlways; add(landscape)
        let close = app.buttons["关闭小窗"]
        XCTAssertTrue(close.waitForExistence(timeout: 10))
        close.tap()
        XCTAssertTrue(close.waitForNonExistence(timeout: 10))
        XCTAssertTrue(app.descendants(matching: .any)["notes.pencil.page"].exists)
        let visiblePage = app.screenshot()
        let page = XCTAttachment(screenshot: visiblePage)
        page.name = "Notes PDF reader after closing linked map — component scene"
        page.lifetime = .keepAlways; add(page)
        let recognition = VNRecognizeTextRequest()
        recognition.recognitionLanguages = ["en-US", "zh-Hans"]
        recognition.recognitionLevel = .accurate
        try VNImageRequestHandler(data: visiblePage.pngRepresentation, options: [:]).perform([recognition])
        let text = (recognition.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: " ").lowercased()
        XCTAssertTrue(text.contains("lecture"), "The screen must contain rendered PDF text, not only the editor header: \(text)")
    }
}
