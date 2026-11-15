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
        addConversationProvider(app)
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

    func testCustomHTTPShowsActionableConfirmationAndCancelKeepsDraft() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--ui-test-skip-onboarding", "-ui-testing", "-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN"]
        if UIDevice.current.userInterfaceIdiom == .pad { app.launchArguments.append("-ui-testing-ipad") }
        app.launch()
        openProviders(app)
        addConversationProvider(app)
        let endpoint = app.textFields["providers.base_url"]
        XCTAssertTrue(endpoint.waitForExistence(timeout: 8))
        endpoint.tap()
        let length = (endpoint.value as? String)?.count ?? 0
        endpoint.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: length))
        let address = "http://10.0.0.25:8080/v1"
        endpoint.typeText(address)
        let save = app.buttons["action.save"]
        save.tap()
        let confirmation = app.alerts["HTTP 连接不安全"]
        XCTAssertTrue(confirmation.waitForExistence(timeout: 6))
        XCTAssertTrue(confirmation.buttons["验证并继续"].exists)
        XCTAssertTrue(confirmation.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "10.0.0.25")).firstMatch.exists)
        let evidence = XCTAttachment(screenshot: app.screenshot())
        evidence.name = "局域网 HTTP 端点二次确认"; evidence.lifetime = .keepAlways
        add(evidence)
        confirmation.buttons["取消"].tap()
        XCTAssertEqual(endpoint.value as? String, address)
        XCTAssertFalse(app.alerts.firstMatch.exists)
        save.tap()
        XCTAssertTrue(confirmation.waitForExistence(timeout: 4))
        confirmation.buttons["取消"].tap()
        app.buttons["action.cancel"].tap()
    }

    private func addConversationProvider(_ app: XCUIApplication) {
        app.buttons["providers.add"].tap()
        // The iPad confirmation dialog exposes the action as a button nested
        // in another button with the same identifier and the same hit target.
        let conversation = app.sheets.buttons.matching(identifier: "providers.add.conversation").firstMatch
        XCTAssertTrue(conversation.waitForExistence(timeout: 8))
        conversation.tap()
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
