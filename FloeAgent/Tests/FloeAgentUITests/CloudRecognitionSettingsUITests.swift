import XCTest

@MainActor
final class CloudRecognitionSettingsUITests: XCTestCase {
    func testEveryProviderOpensAFormAndCancelLeavesTheSavedListUnchanged() {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .landscapeLeft
        let app = XCUIApplication()
        app.launchArguments = ["--ui-test-skip-onboarding", "-ui-testing", "-ui-testing-ipad",
                               "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()
        defer { app.terminate() }
        let settings = app.buttons["sidebar.settings"].firstMatch
        XCTAssertTrue(settings.waitForExistence(timeout: 15))
        settings.tap()
        let general = app.descendants(matching: .any)["settings.section.general"].firstMatch
        XCTAssertTrue(general.waitForExistence(timeout: 10))
        general.tap()
        let input = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Voice Input")).firstMatch
        XCTAssertTrue(input.waitForExistence(timeout: 10))
        input.tap()
        XCTAssertTrue(app.switches["voice.input.preload.toggle"].waitForExistence(timeout: 10))
        let open = app.buttons["voice.cloud.profiles.open"].firstMatch
        XCTAssertTrue(open.exists)
        open.tap()
        let add = app.buttons["voice.cloud.profiles.add"].firstMatch
        XCTAssertTrue(add.waitForExistence(timeout: 10))
        let savedRows = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "voice.cloud.profile."))
        let originalCount = savedRows.count
        let providers = ["OpenAI", "OpenAI-compatible relay", "Volcengine · Pay as you go",
                         "Volcengine Agent Plan", "Alibaba Cloud · Pay as you go", "Alibaba Cloud Token Plan"]
        for (index, title) in providers.enumerated() {
            add.tap()
            let provider = app.buttons[title].firstMatch
            XCTAssertTrue(provider.waitForExistence(timeout: 5), title)
            XCTAssertTrue(provider.isEnabled, "Provider configuration must not require an account probe")
            if index == 0 { capture("Cloud recognition provider choices", app: app) }
            provider.tap()
            XCTAssertTrue(app.textFields["Name"].waitForExistence(timeout: 5), title)
            XCTAssertTrue(app.textFields["File transcription URL"].exists, title)
            if index == 1 || index == 5 { capture("Cloud recognition form " + title, app: app) }
            let cancel = app.buttons["Cancel"].firstMatch
            XCTAssertTrue(cancel.exists)
            cancel.tap()
            XCTAssertTrue(add.waitForExistence(timeout: 5))
            XCTAssertEqual(savedRows.count, originalCount, "Cancel must not save an empty profile")
        }
        XCTAssertEqual(add.label, "Add service")
        XCTAssertTrue(add.isHittable)
        capture("Cloud recognition saved list after cancellations", app: app)
    }

    private func capture(_ name: String, app: XCUIApplication) {
        // App snapshots can clip landscape sheets and omit system menus.
        // Capture the actual display so visual review includes both.
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
