import XCTest

/// Component-host acceptance only. These tests never tap microphone/camera
/// Start or the document camera; the scanner uses its ordinary image import.
final class ToolboxSecondBatchUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    private func open(_ tool: String, anchor: String, extra: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--tool", tool, "-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN"] + extra
        app.launch()
        XCTAssertTrue(element(anchor, in: app).waitForExistence(timeout: 15), tool)
        XCTAssertFalse(app.staticTexts["Existing App tool"].exists)
        return app
    }

    @MainActor
    private func element(_ identifier: String, in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    @MainActor
    private func capture(_ app: XCUIApplication, _ name: String) {
        let screenshot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        screenshot.name = name
        screenshot.lifetime = .keepAlways
        add(screenshot)
        let hierarchy = XCTAttachment(string: app.debugDescription)
        hierarchy.name = name + "-hierarchy"
        hierarchy.lifetime = .keepAlways
        add(hierarchy)
    }

    @MainActor
    private func reveal(_ target: XCUIElement, in app: XCUIApplication) {
        for _ in 0..<5 where !target.isHittable {
            let scroll = app.scrollViews.firstMatch
            guard scroll.exists else { return }
            let start = scroll.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.85))
            start.press(forDuration: 0.1, thenDragTo: scroll.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.3)))
        }
    }

    @MainActor
    private func assertNoCaptureOrPermissionPrompt(in app: XCUIApplication) {
        XCTAssertFalse(element("toolbox.scanner.preview", in: app).exists)
        XCTAssertFalse(element("toolbox.magnifier.preview", in: app).exists)
        XCTAssertFalse(XCUIApplication(bundleIdentifier: "com.apple.springboard").alerts.firstMatch.exists)
    }

    @MainActor
    func testSecondBatchInitialSurfacesOnWideTablet() {
        XCUIDevice.shared.orientation = .landscapeLeft
        defer { XCUIDevice.shared.orientation = .portrait }
        let routes = [("barometer", "toolbox.pressure.start"),
                      ("sound", "toolbox.sound.start"),
                      ("magnifier", "toolbox.magnifier.start"),
                      ("scanner", "toolbox.scanner.import")]
        for (tool, anchor) in routes {
            let app = open(tool, anchor: anchor)
            defer { app.terminate() }
            if tool == "barometer" {
                #if targetEnvironment(simulator)
                XCTAssertTrue(element("toolbox.pressure.unavailable", in: app).waitForExistence(timeout: 5))
                XCTAssertFalse(app.buttons["toolbox.pressure.start"].isEnabled)
                XCTAssertFalse(app.buttons["toolbox.pressure.zero"].isEnabled)
                #endif
            } else if tool == "sound" {
                XCTAssertTrue(app.buttons["toolbox.sound.start"].label.contains("开始"))
                XCTAssertFalse(app.buttons["toolbox.sound.export"].isEnabled)
            } else if tool == "scanner" {
                XCTAssertTrue(app.buttons["toolbox.scanner.import"].isEnabled)
                XCTAssertFalse(element("qualification.scanner.exported", in: app).exists)
            }
            assertNoCaptureOrPermissionPrompt(in: app)
            capture(app, "second-batch-\(tool)-tablet-initial")
        }
    }

    @MainActor
    func testSoundAndScannerInCompactDarkAccessibilityType() {
        XCUIDevice.shared.orientation = .portrait
        for (tool, anchor) in [("sound", "toolbox.sound.start"), ("scanner", "toolbox.scanner.import")] {
            let app = open(tool, anchor: anchor, extra: ["--compact", "--dark", "--large-text"])
            defer { app.terminate() }
            XCTAssertTrue(element(anchor, in: app).isHittable, tool)
            assertNoCaptureOrPermissionPrompt(in: app)
            capture(app, "second-batch-\(tool)-compact-dark-accessibility")
        }
    }

    @MainActor
    func testScannerFixtureRecognizesBothLanguagesAndQRThenExportsActualText() {
        XCUIDevice.shared.orientation = .landscapeLeft
        defer { XCUIDevice.shared.orientation = .portrait }
        let app = open("scanner", anchor: "toolbox.scanner.import", extra: ["--scanner-fixture"])
        defer { app.terminate() }
        XCTAssertTrue(element("qualification.scanner.synthetic", in: app).exists)
        app.buttons["toolbox.scanner.import"].tap()
        XCTAssertTrue(element("qualification.scanner.imported", in: app).waitForExistence(timeout: 5))
        XCTAssertFalse(element("qualification.scanner.fixtureError", in: app).exists)

        // None of these payloads is exposed by the host before an actual
        // recognition result. In particular, the QR payload is not printed.
        let qrPayload = "FLOE-SYNTHETIC-QR-2026"
        let qr = app.staticTexts.matching(NSPredicate(format: "label == %@", qrPayload)).firstMatch
        let english = app.staticTexts.matching(NSPredicate(format: "label CONTAINS[c] %@", "LOCAL")).firstMatch
        let chinese = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "文字识别")).firstMatch
        XCTAssertTrue(qr.waitForExistence(timeout: 30), "Production QR recognition must decode the image")
        XCTAssertTrue(english.waitForExistence(timeout: 10), "Production OCR must recognize English")
        XCTAssertTrue(chinese.waitForExistence(timeout: 10), "Production OCR must recognize Chinese")
        XCTAssertTrue(app.staticTexts["二维码"].exists)
        assertNoCaptureOrPermissionPrompt(in: app)
        reveal(chinese, in: app)
        capture(app, "second-batch-scanner-fixture-local-ocr-qr")

        // Export through the existing menu. Saving to Notes is currently in
        // the live-camera results header, so this flow uses the available TXT
        // export instead of forcing a camera session or a hidden model action.
        app.buttons["toolbox.scanner.export"].tap()
        let exportText = app.buttons["导出文字"]
        XCTAssertTrue(exportText.waitForExistence(timeout: 5))
        exportText.tap()
        let receipt = element("qualification.scanner.exported", in: app)
        XCTAssertTrue(receipt.waitForExistence(timeout: 10))
        XCTAssertTrue(receipt.label.hasPrefix("TXT callback received:"), receipt.label)
        let payload = element("qualification.scanner.exportPayload", in: app)
        XCTAssertTrue(payload.exists)
        XCTAssertTrue(payload.label.contains(qrPayload), payload.label)
        XCTAssertTrue(payload.label.contains("LOCAL"), payload.label)
        XCTAssertTrue(payload.label.contains("文字识别"), payload.label)
        XCTAssertFalse(element("qualification.scanner.noteReceived", in: app).exists)
        assertNoCaptureOrPermissionPrompt(in: app)
        capture(app, "second-batch-scanner-actual-txt-export-callback")
    }
}
