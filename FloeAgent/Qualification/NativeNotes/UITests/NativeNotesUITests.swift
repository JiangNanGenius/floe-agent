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
        let portrait = XCTAttachment(screenshot: capture(app, landscape: false))
        portrait.name = "Notes PDF and independent map — portrait component scene"
        portrait.lifetime = .keepAlways; add(portrait)
        XCUIDevice.shared.orientation = .landscapeLeft
        let rotationDeadline = Date().addingTimeInterval(10)
        while app.frame.width <= app.frame.height && Date() < rotationDeadline { Thread.sleep(forTimeInterval: 0.1) }
        XCTAssertGreaterThan(app.frame.width, app.frame.height, "The app viewport must actually rotate before labeling a landscape screenshot")
        XCTAssertTrue(topic.waitForExistence(timeout: 10))
        let landscape = XCTAttachment(screenshot: capture(app, landscape: true))
        landscape.name = "Notes PDF and independent map — landscape component scene"
        landscape.lifetime = .keepAlways; add(landscape)
        let close = app.buttons["关闭小窗"]
        XCTAssertTrue(close.waitForExistence(timeout: 10))
        close.tap()
        XCTAssertTrue(close.waitForNonExistence(timeout: 10))
        XCTAssertTrue(app.descendants(matching: .any)["notes.pencil.page"].exists)
        let visiblePage = capture(app, landscape: true)
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

    // XCUIScreen can retain the portrait screen canvas after the app rotates
    // (observed in run 35180990348). Capture the actual app and verify the image
    // dimensions as well as the accessibility frame before labeling evidence.
    private func capture(_ app: XCUIApplication, landscape: Bool) -> XCUIScreenshot {
        let deadline = Date().addingTimeInterval(10)
        var shot = app.screenshot()
        while (shot.image.size.width > shot.image.size.height) != landscape && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.2)
            shot = app.screenshot()
        }
        XCTAssertEqual(shot.image.size.width > shot.image.size.height, landscape,
                       "Capture orientation must match its label; image=\(shot.image.size), app=\(app.frame)")
        return shot
    }
}
