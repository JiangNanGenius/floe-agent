// FloeAgentUITests — final representative UI round.
//
// Two captures for the primary's visual review, both on real screens:
//  * the provider settings entry (capability/input-vs-output copy and the
//    add-provider catalog where the unsupported presets are not offered);
//  * a completed task with the rich checklist content rendered in the real
//    streaming message layout (wide/no-truncation spot check).
//
// These are evidence captures, not gates: the behavioral suites already cover
// the capability metadata, hidden presets and message rendering.

import XCTest

final class FinalUIReviewUITests: XCTestCase {
    func testProviderSettingsEntryCapture() throws {
        continueAfterFailure = false
        let app = launch(fixtures: [])
        defer { app.terminate() }
        openSettings(app)

        let providers = app.staticTexts["模型与供应商"].firstMatch
        let deadline = Date().addingTimeInterval(30)
        while !providers.exists && Date() < deadline {
            app.swipeUp()
            Thread.sleep(forTimeInterval: 0.3)
        }
        XCTAssertTrue(providers.waitForExistence(timeout: 10), "the provider settings entry must exist")
        providers.tap()
        XCTAssertTrue(app.buttons["providers.add"].firstMatch.waitForExistence(timeout: 20),
                      "the provider list must open")
        capture("providers-settings-entry")

        app.buttons["providers.add"].firstMatch.tap()
        // The single Add entry asks for the intended use first; the catalog
        // search is embedded in the editor's supplier field (the current
        // product path — there is no independent catalog page).
        let chatProvider = app.buttons["对话模型服务商"].firstMatch
        XCTAssertTrue(chatProvider.waitForExistence(timeout: 15),
                      "the add dialog must offer the chat-model provider")
        chatProvider.tap()
        let supplier = app.buttons["providers.supplier_field"].firstMatch
        XCTAssertTrue(supplier.waitForExistence(timeout: 20),
                      "the provider editor must open with its supplier field")
        supplier.tap()
        let search = app.textFields["providers.catalog.search"].firstMatch
        XCTAssertTrue(search.waitForExistence(timeout: 15),
                      "the embedded catalog picker must offer its search field")
        capture("providers-editor-embedded-catalog")
        // Hidden unsupported presets are never offered as selectable rows.
        search.tap()
        search.typeText("Copilot")
        Thread.sleep(forTimeInterval: 0.8)
        XCTAssertFalse(app.buttons
            .matching(NSPredicate(format: "identifier BEGINSWITH %@", "providers.catalog.row."))
            .firstMatch.exists,
            "a hidden unsupported preset must not be offered as a selectable row")
        capture("providers-hidden-preset-search")
    }

    func testRichStreamingContentLayoutCapture() throws {
        continueAfterFailure = false
        let app = launch(fixtures: ["--ui-test-checklist-fixture"])
        defer { app.terminate() }

        // The batch fixture's task carries the synthetic durable checklist;
        // its sidebar row is the stable entry used by the existing suite.
        let task = app.descendants(matching: .any)
            .matching(identifier: "sidebar.conversation.57C0A79F-CF1B-45D2-B640-EF54E5C55391")
            .firstMatch
        XCTAssertTrue(task.waitForExistence(timeout: 30), "the fixture task must be listed")
        task.tap()
        let checklist = app.descendants(matching: .any)
            .matching(identifier: "thread.checklist").firstMatch
        XCTAssertTrue(checklist.waitForExistence(timeout: 30),
                      "the rich checklist content must render in the message layout")
        checklist.tap()
        Thread.sleep(forTimeInterval: 0.6)
        capture("chat-rich-content-layout")
        XCTAssertTrue(checklist.exists, "the expanded checklist stays in the message flow")
    }

    // MARK: - Helpers

    private func launch(fixtures: [String]) -> XCUIApplication {
        let app = XCUIApplication()
        app.terminate()
        XCUIDevice.shared.orientation = .landscapeLeft
        app.launchArguments = [
            "-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN", "-ui-testing",
            "--ui-test-skip-onboarding", "--ui-test-batch-fixture", "-ui-testing-ipad"
        ] + fixtures
        app.launch()
        return app
    }

    private func openSettings(_ app: XCUIApplication) {
        let settings = app.buttons["sidebar.settings"].firstMatch
        XCTAssertTrue(settings.waitForExistence(timeout: 30), "the Settings entry must exist")
        // A hidden/collapsed sidebar reports off-screen frames; open it first.
        if !settings.isHittable {
            let openSidebar = app.buttons["phone.sidebar.open"].firstMatch
            if openSidebar.exists { openSidebar.tap() }
        }
        XCTAssertTrue(settings.waitForExistence(timeout: 15))
        settings.tap()
        XCTAssertTrue(app.navigationBars.firstMatch.waitForExistence(timeout: 20))
    }

    private func capture(_ name: String) {
        let image = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        image.name = name
        image.lifetime = .keepAlways
        add(image)
    }
}
