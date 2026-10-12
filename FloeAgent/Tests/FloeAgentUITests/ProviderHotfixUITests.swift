import XCTest
import UIKit

@MainActor
final class ProviderHotfixUITests: XCTestCase {
    func testPastedNameSaveAndRelaunch() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--ui-test-skip-onboarding", "-ui-testing", "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        if UIDevice.current.userInterfaceIdiom == .pad { app.launchArguments.append("-ui-testing-ipad") }
        app.launch()
        XCTAssertFalse(app.alerts.containing(NSPredicate(format: "label CONTAINS[c] 'Bluetooth'")).firstMatch.exists)
        openProviders(app)
        app.buttons["providers.add"].tap()
        let conversation = app.buttons["Chat model provider"]
        XCTAssertTrue(conversation.waitForExistence(timeout: 5))
        conversation.tap()
        let field = app.textFields["providers.display_name"]
        XCTAssertTrue(field.waitForExistence(timeout: 8))
        field.tap()
        let existing = field.value as? String ?? ""
        field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: existing.count))
        let originalClipboard = UIPasteboard.general.items
        defer { UIPasteboard.general.items = originalClipboard }
        UIPasteboard.general.string = "\u{FEFF}Hotfix 公司 👩‍💻\u{200B}"
        field.press(forDuration: 1)
        let paste = app.menuItems["Paste"].firstMatch
        if paste.waitForExistence(timeout: 3) { paste.tap() }
        else { app.buttons["Paste"].tap() }
        app.buttons["action.save"].tap()
        XCTAssertTrue(app.staticTexts["Hotfix 公司 👩‍💻"].waitForExistence(timeout: 12))
        let saved = XCTAttachment(screenshot: app.screenshot())
        saved.name = "Canonical provider saved"; saved.lifetime = .keepAlways
        add(saved)
        app.terminate(); app.launch()
        openProviders(app)
        XCTAssertTrue(app.staticTexts["Hotfix 公司 👩‍💻"].waitForExistence(timeout: 8))
        app.staticTexts["Hotfix 公司 👩‍💻"].firstMatch.tap()
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        XCTAssertEqual(field.value as? String, "Hotfix 公司 👩‍💻")
    }

    private func openProviders(_ app: XCUIApplication) {
        let settings = app.buttons["sidebar.settings"]
        XCTAssertTrue(settings.waitForExistence(timeout: 10))
        if !settings.isHittable {
            let drawer = app.buttons["phone.sidebar.open"]
            XCTAssertTrue(drawer.waitForExistence(timeout: 5))
            drawer.tap()
        }
        settings.tap()
        let providers = app.descendants(matching: .any).matching(identifier: "settings.section.providers").firstMatch
        XCTAssertTrue(providers.waitForExistence(timeout: 8))
        providers.tap()
        XCTAssertTrue(app.buttons["providers.add"].waitForExistence(timeout: 8))
    }
}
