// SPDX-License-Identifier: MPL-2.0
// Real persisted conversation + production Markdown + real PNG producer.
#if targetEnvironment(simulator)
import XCTest
import UIKit

@MainActor
final class SVGChatPageUITests: XCTestCase {
    private let app = XCUIApplication(bundleIdentifier: "org.floeagent.ios")
    private let svg = """
    <svg xmlns="http://www.w3.org/2000/svg" width="240" height="120" viewBox="0 0 240 120">
      <rect x="20" y="20" width="80" height="60" fill="#ff0000"/>
    </svg>
    """

    override func setUpWithError() throws {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .landscapeLeft
        app.launchArguments = ["-ui-testing", "-ui-testing-ipad", "--ui-test-skip-onboarding",
            "--ui-test-svg-chat-fixture", "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()
    }

    override func tearDownWithError() throws {
        app.terminate()
        XCUIDevice.shared.orientation = .portrait
    }

    override func record(_ issue: XCTIssue) {
        let picture = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        picture.name = "SVG chat issue"; picture.lifetime = .keepAlways
        add(picture)
        super.record(issue)
    }

    private func element(_ id: String) -> XCUIElement { app.descendants(matching: .any)[id].firstMatch }

    private func attach(_ name: String) {
        let picture = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        picture.name = name
        picture.lifetime = .keepAlways
        add(picture)
    }

    /// Scroll the actual chat viewport. No host input, simulator creation or
    /// guessed tap coordinates; centering uses the current AX frames.
    private func reveal(_ target: XCUIElement, earlier: Bool, center: Bool = false) {
        let viewport = element("thread.messages.viewport")
        XCTAssertTrue(viewport.waitForExistence(timeout: 20))
        for _ in 0..<8 {
            if target.exists, target.isHittable {
                guard center else { return }
                let delta = target.frame.midY - viewport.frame.midY
                if abs(delta) < 16 { return }
                let origin = viewport.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
                origin.press(forDuration: 0.05, thenDragTo: origin.withOffset(CGVector(dx: 0, dy: max(-220, min(220, -delta)))))
            } else if earlier { viewport.swipeDown() }
            else { viewport.swipeUp() }
        }
        XCTAssertTrue(target.exists, "the real chat element must exist")
        XCTAssertTrue(target.isHittable, "the real chat element must be visible and usable")
    }

    private static func redPixelCount(in image: UIImage) throws -> Int {
        let source = try XCTUnwrap(image.cgImage)
        let context = try XCTUnwrap(CGContext(data: nil, width: source.width, height: source.height,
            bitsPerComponent: 8, bytesPerRow: source.width * 4,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(source, in: CGRect(x: 0, y: 0, width: source.width, height: source.height))
        let bytes = try XCTUnwrap(context.data).assumingMemoryBound(to: UInt8.self)
        var red = 0
        for y in 0..<source.height {
            for x in 0..<source.width {
                let offset = y * context.bytesPerRow + x * 4
                if bytes[offset] > 200, bytes[offset + 1] < 80, bytes[offset + 2] < 80,
                   bytes[offset + 3] > 200 { red += 1 }
            }
        }
        return red
    }

    func testSavedChatShowsOrderedSVGSourceCopyAndRealPNGExport() throws {
        defer { attach("SVG chat final state") }
        let leading = app.staticTexts["SVG chat before the picture."].firstMatch
        let trailing = app.staticTexts["SVG chat after the picture."].firstMatch
        let image = element("chat.svgPreview.image")
        XCTAssertTrue(element("thread.messages.viewport").waitForExistence(timeout: 40))
        reveal(leading, earlier: true)
        XCTAssertTrue(leading.exists, "the persisted assistant lead-in must render")
        XCTAssertTrue(element("chat.svgBlock").waitForExistence(timeout: 20))
        XCTAssertTrue(image.waitForExistence(timeout: 30), "the production SVG renderer must reach its image state")
        reveal(image, earlier: true, center: true)
        XCTAssertFalse(element("chat.svgPreview.fallback").exists)
        XCTAssertTrue(trailing.exists, "the persisted assistant paragraph after SVG must render")
        XCTAssertLessThan(leading.frame.minY, image.frame.minY)
        XCTAssertLessThan(image.frame.maxY, trailing.frame.maxY)
        XCTAssertEqual(app.staticTexts.matching(identifier: "SVG chat before the picture.").count, 1,
            "the stored assistant message and run event must not duplicate the reply")
        XCTAssertGreaterThanOrEqual(try Self.redPixelCount(in: image.screenshot().image), 64,
            "the displayed SVG must contain real red pixels, not only an image identifier")
        XCTAssertEqual(element("chat.svgPreview.size").label, "240×120")
        attach("Saved chat — before, red SVG, after")

        let toggle = element("chat.svgPreview.sourceToggle")
        reveal(toggle, earlier: false)
        toggle.tap()
        let source = element("chat.svgPreview.sourceText")
        XCTAssertTrue(source.waitForExistence(timeout: 8))
        XCTAssertEqual(source.label.trimmingCharacters(in: .whitespacesAndNewlines), svg)
        XCTAssertFalse(image.exists, "showing source must replace the picture surface")
        attach("Saved chat — actual SVG source")
        let copy = element("chat.svgPreview.copy")
        reveal(copy, earlier: true)
        copy.tap()
        let copied = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label IN %@", ["Copied", "已复制"]), object: copy)
        XCTAssertEqual(XCTWaiter.wait(for: [copied], timeout: 1.5), .completed,
            "the real source-copy action must report success")
        reveal(toggle, earlier: false)
        toggle.tap()
        XCTAssertTrue(image.waitForExistence(timeout: 8))
        XCTAssertTrue(element("chat.svgPreview.share").isEnabled, "in-memory PNG sharing must remain available")

        // This card resolves the REAL saved outputFilesJSON receipt; no local
        // URL, prebuilt UIImage or fake ready-state is injected into the chat.
        let inline = element("chat.inlineContent")
        reveal(inline, earlier: false)
        let fileShare = inline.descendants(matching: .button)["chat.runOutput.share"].firstMatch
        XCTAssertTrue(fileShare.waitForExistence(timeout: 20), "the verified producer PNG must have its real export action")
        reveal(fileShare, earlier: false)
        XCTAssertTrue(fileShare.isEnabled)
        attach("Saved chat — verified PNG output card")
        fileShare.tap()
        let activity = element("ActivityListView")
        let saveActivity = app.buttons.matching(NSPredicate(format: "label IN %@",
            ["Save to Files", "Save Image", "存储到‘文件’", "存储到“文件”", "存储图像"])).firstMatch
        var presented = false
        for _ in 0..<50 {
            if activity.exists || app.sheets.firstMatch.exists || (saveActivity.exists && saveActivity.isHittable) {
                presented = true
                break
            }
            Thread.sleep(forTimeInterval: 0.1)
        }
        XCTAssertTrue(presented, "sharing must present the actual system export sheet")
        attach("Saved chat — system PNG export sheet (no external send)")
    }
}
#endif
