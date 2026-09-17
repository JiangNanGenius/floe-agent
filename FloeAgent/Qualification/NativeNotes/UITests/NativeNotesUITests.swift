// SPDX-License-Identifier: MPL-2.0
import XCTest
import Vision
import ImageIO

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
        // Feed Vision the PNG's own EXIF orientation explicitly. The orientation
        // initializer supersedes embedded metadata (VNRequestHandler.h), so the
        // rotated buffer is corrected exactly once and the stored attachment is
        // never rewritten, rotated or cropped in place.
        let orientation = pngOrientation(of: visiblePage.pngRepresentation)
        try VNImageRequestHandler(data: visiblePage.pngRepresentation, orientation: orientation, options: [:]).perform([recognition])
        let text = (recognition.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: " ").lowercased()
        XCTAssertTrue(text.contains("lecture"), "The screen must contain rendered PDF text, not only the editor header: \(text)")
    }

    // XCUIScreen.main.screenshot() captures the whole screen; XCTest stores it as a
    // PNG carrying EXIF orientation metadata instead of rotating the pixels. The
    // previous XCUIApplication.screenshot() path was observed clipping the landscape
    // scene to a portrait frame (run 35184454030), so capture the screen and verify
    // the live app viewport before labeling evidence.
    private func capture(_ app: XCUIApplication, landscape: Bool) -> XCUIScreenshot {
        let deadline = Date().addingTimeInterval(10)
        var shot = XCUIScreen.main.screenshot()
        while (shot.image.size.width > shot.image.size.height) != landscape && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.2)
            shot = XCUIScreen.main.screenshot()
        }
        XCTAssertEqual(shot.image.size.width > shot.image.size.height, landscape,
                       "Capture orientation must match its label; image=\(shot.image.size), app=\(app.frame)")

        // UIImage.size already reflects EXIF orientation (UIImage.h), so compare the
        // oriented point extent with the actual viewport, not a hard-coded device size.
        let viewport = app.frame
        XCTAssertEqual(shot.image.size.width, viewport.width, accuracy: 1,
                       "Oriented capture width must match the app viewport; image=\(shot.image.size), app=\(viewport)")
        XCTAssertEqual(shot.image.size.height, viewport.height, accuracy: 1,
                       "Oriented capture height must match the app viewport; image=\(shot.image.size), app=\(viewport)")

        // Full-screen extent: decode the PNG through ImageIO, honoring its EXIF
        // orientation, and require it to cover the viewport at the capture scale.
        // A shortfall means the capture is clipped. Pixel-color probing is
        // deliberately avoided because legitimate dark UI is not evidence of padding.
        guard let pixels = orientedPixelSize(of: shot.pngRepresentation) else {
            XCTFail("Captured PNG must decode through ImageIO; image=\(shot.image.size), app=\(viewport)")
            return shot
        }
        let scale = max(shot.image.scale, 1)
        XCTAssertGreaterThanOrEqual(pixels.width, viewport.width * scale - 1,
                                    "Capture must not clip the viewport; pixels=\(pixels), viewport=\(viewport.size), scale=\(scale)")
        XCTAssertGreaterThanOrEqual(pixels.height, viewport.height * scale - 1,
                                    "Capture must not clip the viewport; pixels=\(pixels), viewport=\(viewport.size), scale=\(scale)")
        return shot
    }

    // ImageIO reports the stored (unrotated) pixel extent plus the EXIF orientation;
    // transposing the extent yields the dimensions a conforming viewer displays.
    private func orientedPixelSize(of png: Data) -> CGSize? {
        guard let source = CGImageSourceCreateWithData(png as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.doubleValue,
              let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.doubleValue else { return nil }
        switch pngOrientation(of: png) {
        case .left, .leftMirrored, .right, .rightMirrored:
            return CGSize(width: height, height: width)
        default:
            return CGSize(width: width, height: height)
        }
    }

    private func pngOrientation(of png: Data) -> CGImagePropertyOrientation {
        guard let source = CGImageSourceCreateWithData(png as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let raw = (properties[kCGImagePropertyOrientation] as? NSNumber)?.uint32Value,
              let orientation = CGImagePropertyOrientation(rawValue: raw) else { return .up }
        return orientation
    }
}
