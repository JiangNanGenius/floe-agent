// FloeAgentUITests — central Canvas unified-3D entry label.
//
// The Canvas creation menu exposes ONE unified 3D document entry (the legacy
// scene creator is retired for editing; CAD documents open in the same native
// workbench). That entry must read exactly "3D Workbench" / "3D 工作台" —
// no parenthetical suffix — in both languages, and it must stay a single
// unified creation route.
//
// The test walks the REAL product path: Creative destination → New canvas →
// (close onboarding) → the canvas bottom add button → the real creation menu.
// It deliberately does not use the CAD auto-open fixture, whose presented
// full-screen CAD editor covers the canvas toolbar.
//
// SPDX-License-Identifier: MPL-2.0

#if canImport(XCTest)
import XCTest

@MainActor
final class Canvas3DWorkbenchLabelUITests: XCTestCase {

    /// Launches the app in the requested language and opens a fresh canvas
    /// through the real navigation, returning the launched application.
    private func launchAndOpenCanvas(language: String, locale: String) -> XCUIApplication {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments += ["-AppleLanguages", "(\(language))", "-AppleLocale", locale,
                                "-ui-testing", "-ui-testing-ipad"]
        app.launch()

        // Reach the Creative destination (phone opens the sidebar first).
        let phoneSidebar = app.buttons["phone.sidebar.open"]
        if phoneSidebar.waitForExistence(timeout: 5) {
            phoneSidebar.tap()
        }
        let creative = app.staticTexts["sidebar.creative"]
        XCTAssertTrue(creative.waitForExistence(timeout: 20),
                      "the Creative destination must be reachable")
        creative.tap()

        let newCanvas = app.buttons["canvas.home.create"]
        XCTAssertTrue(newCanvas.waitForExistence(timeout: 15), "the new-canvas action must exist")
        newCanvas.tap()

        // A first-run onboarding overlay may cover the canvas; close it.
        let onboarding = app.otherElements["canvas.onboarding"]
        if onboarding.waitForExistence(timeout: 3) {
            let close = app.buttons.matching(
                NSPredicate(format: "label IN %@", ["关闭", "Close"])).firstMatch
            if close.waitForExistence(timeout: 3) { close.tap() }
        }
        return app
    }

    private func assertUnified3DEntry(
        _ app: XCUIApplication,
        expected: String,
        attachmentName: String
    ) {
        let addButton = app.buttons["canvas.node.create.bottom"]
        XCTAssertTrue(addButton.waitForExistence(timeout: 30), "the canvas add button must exist")
        XCTAssertTrue(addButton.isHittable, "the canvas add button must be hittable")
        addButton.tap()

        // Menu items are matched by their real localized label: SwiftUI menus
        // do not propagate per-item accessibility identifiers here (the
        // diagnostic dump shows identifier "" + the label).
        let menuItem = app.buttons.matching(NSPredicate(format: "label == %@", expected)).firstMatch
        if !menuItem.waitForExistence(timeout: 10) {
            let buttons = app.buttons.allElementsBoundByIndex.prefix(60)
                .map { "\($0.identifier)|\($0.label)" }
            XCTFail("the unified 3D entry must exist. Buttons: \(buttons)")
        }
        let label = menuItem.label
        XCTAssertEqual(label, expected,
                       "the unified 3D entry must display the clean name (got: \(label))")
        XCTAssertFalse(label.contains("("), "no parenthetical suffix may remain: \(label)")
        XCTAssertFalse(label.contains("（"), "no full-width parenthetical suffix may remain: \(label)")

        // No 3D/CAD entry in the real creation menu may carry a parenthetical
        // suffix, and exactly ONE unified 3D workbench entry is offered (the
        // retired legacy scene creator must not reappear as a second route).
        let labels = app.buttons.allElementsBoundByIndex.map(\.label)
        let parenthesised3D = labels.filter {
            $0.hasPrefix("3D") && ($0.contains("(") || $0.contains("（"))
        }
        XCTAssertTrue(parenthesised3D.isEmpty,
                      "no 3D menu entry may keep a parenthetical suffix: \(parenthesised3D)")
        let unified = labels.filter { $0.contains("3D") && ($0.contains("Workbench") || $0.contains("工作台")) }
        XCTAssertEqual(unified.count, 1,
                       "exactly one unified 3D workbench entry must be offered, got \(unified)")

        let screenshot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        screenshot.name = attachmentName
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }

    func testEnglishUnified3DEntryHasNoSuffix() {
        let app = launchAndOpenCanvas(language: "en", locale: "en_US")
        assertUnified3DEntry(app, expected: "3D Workbench", attachmentName: "canvas-create-menu-en")
        app.terminate()
    }

    func testChineseUnified3DEntryHasNoSuffix() {
        let app = launchAndOpenCanvas(language: "zh-Hans", locale: "zh_CN")
        assertUnified3DEntry(app, expected: "3D 工作台", attachmentName: "canvas-create-menu-zh")
        app.terminate()
    }
}
#endif
