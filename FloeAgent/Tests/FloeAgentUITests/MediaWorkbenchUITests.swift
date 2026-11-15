// FloeAgentUITests — image workbench canvas selection and feather.
//
// The workbench must now open directly in the integrated image workspace on a
// freshly persisted prepared document; the old toolbar screen is a regression.
// This walks the real fixture: portrait layout -> complete tool list ->
// rectangular marquee -> drag on the real artboard -> feather editor -> apply
// -> invert/deselect -> a replacing selection. Screenshots of the default
// surface and the feather parameters are kept as exportable attachments.
//
// SPDX-License-Identifier: MPL-2.0

#if canImport(XCTest)
import XCTest

@MainActor
final class MediaWorkbenchUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    func testRectangleSelectionFeatherAndSelectionActionRoundTrip() {
        let app = XCUIApplication()
        app.launchArguments += ["-ui-testing", "-ui-testing-ipad", "--ui-test-workbench-fixture",
                                "-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN"]
        app.launch()
        XCUIDevice.shared.orientation = .portrait

        // The prepared document is created on first persistence, so the real
        // editing surface must be the first screen. There is deliberately no
        // tap on the retired "professional workspace" entry.
        let options = any(app, "media.v2.toolOptions")
        XCTAssertTrue(options.waitForExistence(timeout: 60),
                      "the fixture must enter the integrated image workspace directly")
        XCTAssertTrue(any(app, "media.v2.imageToolRail").waitForExistence(timeout: 10),
                      "the 744pt portrait layout keeps the tool rail visible")
        XCTAssertTrue(app.buttons["media.v2.targetLayer"].waitForExistence(timeout: 10),
                      "the current layer stays visible in the compact portrait layout")
        keepScreenshot(app, "media-workbench-default-portrait")

        // Choose the marquee through the complete list so the test does not
        // depend on which sibling the rail group last remembered.
        let search = app.buttons["media.v2.tools.search"].firstMatch
        XCTAssertTrue(search.waitForExistence(timeout: 10))
        search.tap()
        let rectangle = app.buttons["media.v2.pickTool.image.rectangle"]
        XCTAssertTrue(rectangle.waitForExistence(timeout: 10))
        rectangle.tap()

        let feather = app.buttons["media.v2.selection.feather"]
        XCTAssertTrue(feather.waitForExistence(timeout: 10))
        XCTAssertFalse(feather.isEnabled, "feather is disabled until an actual selection exists")

        let canvas = any(app, "media.v2.canvas")
        XCTAssertTrue(canvas.waitForExistence(timeout: 10), "the real artboard is present")
        drawRectangle(in: canvas)

        XCTAssertTrue(feather.isEnabled, "the drag commits a real rectangular selection")
        XCTAssertEqual(text(feather.value) ?? "", "0 px", "a new selection starts unfeathered")

        feather.tap()
        let slider = app.sliders["media.v2.feather.slider"]
        XCTAssertTrue(slider.waitForExistence(timeout: 10), "the feather editor exposes its radius")
        slider.adjust(toNormalizedSliderPosition: 0.2)
        keepScreenshot(app, "media-workbench-feather-parameters")
        let apply = app.buttons["media.v2.feather.apply"]
        XCTAssertTrue(apply.waitForExistence(timeout: 10))
        XCTAssertTrue(apply.isEnabled, "the adjusted radius is applicable")
        apply.tap()

        let nonzero = NSPredicate { object, _ in
            guard let value = (object as? XCUIElement)?.value as? String else { return false }
            return value != "0 px" && value != "0.0 px"
        }
        expectation(for: nonzero, evaluatedWith: feather)
        waitForExpectations(timeout: 10)
        keepScreenshot(app, "media-workbench-feathered-selection")

        let invert = app.buttons["media.v2.selection.inverse"]
        XCTAssertTrue(invert.isEnabled)
        invert.tap()
        let deselect = app.buttons["media.v2.selection.deselect"]
        XCTAssertTrue(deselect.isEnabled)
        deselect.tap()
        XCTAssertFalse(feather.isEnabled, "deselect clears the active selection")

        drawRectangle(in: canvas, from: 0.3, to: 0.62)
        XCTAssertTrue(feather.isEnabled)
        XCTAssertEqual(text(feather.value) ?? "", "0 px",
                       "a replacing selection does not inherit the previous feather")
    }

    private func any(_ app: XCUIApplication, _ identifier: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    private func text(_ value: Any?) -> String? {
        guard var value = (value as? String)?.trimmingCharacters(in: .whitespaces) else { return nil }
        // `formatted(.fractionLength(0...1))` is locale-independent here, but
        // accept an explicit ".0" so the assertion tracks the radius, not
        // number formatting.
        if value.hasSuffix(".0 px") { value = value.replacingOccurrences(of: ".0 px", with: " px") }
        return value
    }

    /// Kept with the result bundle so the default surface and the feather
    /// parameters can be exported for visual review.
    private func keepScreenshot(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    /// The artboard is centered in the preview and narrower than the preview;
    /// a vertical band around the centre stays inside it on iPad portrait.
    private func drawRectangle(in canvas: XCUIElement, from startX: CGFloat = 0.25,
                               to endX: CGFloat = 0.65) {
        let frame = canvas.frame
        let origin = canvas.coordinate(withNormalizedOffset: .zero)
        let start = origin.withOffset(CGVector(dx: frame.width * startX, dy: frame.height * 0.42))
        let end = origin.withOffset(CGVector(dx: frame.width * endX, dy: frame.height * 0.58))
        start.press(forDuration: 0.15, thenDragTo: end)
    }
}
#endif
