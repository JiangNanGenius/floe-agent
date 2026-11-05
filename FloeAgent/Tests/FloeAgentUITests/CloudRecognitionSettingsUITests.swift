import XCTest

@MainActor
final class CloudRecognitionSettingsUITests: XCTestCase {
    func testGeneralHardwareReturnChoicePersists() {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .landscapeLeft
        let app = XCUIApplication()
        app.launchArguments = ["--ui-test-skip-onboarding", "-ui-testing", "-ui-testing-ipad",
                               "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        func openGeneral() {
            app.launch()
            let settings = app.buttons["sidebar.settings"].firstMatch
            XCTAssertTrue(settings.waitForExistence(timeout: 15)); settings.tap()
            let general = app.descendants(matching: .any)["settings.section.general"].firstMatch
            XCTAssertTrue(general.waitForExistence(timeout: 10)); general.tap()
        }
        func row() -> XCUIElement { app.buttons["settings.general.hardwareReturn"].firstMatch }
        func revealRow() {
            for _ in 0..<6 {
                if row().exists && row().isHittable { return }
                guard let form = app.collectionViews.allElementsBoundByIndex.last(where: {
                    $0.exists && $0.isHittable && $0.frame.width > 300
                }) else { break }
                form.swipeUp()
            }
        }
        func choose(_ label: String) {
            revealRow()
            XCTAssertTrue(row().waitForExistence(timeout: 10)); row().tap()
            let item = app.buttons[label].firstMatch
            XCTAssertTrue(item.waitForExistence(timeout: 5)); item.tap()
        }
        func assertValue(_ value: String) {
            let match = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value CONTAINS %@ OR label CONTAINS %@", value, value), object: row())
            XCTAssertEqual(XCTWaiter.wait(for: [match], timeout: 5), .completed)
        }
        openGeneral(); revealRow()
        XCTAssertTrue(row().waitForExistence(timeout: 10))
        let original = (row().value as? String ?? row().label).contains("Send") ? "Send" : "New Line"
        defer { if row().exists { choose(original) }; app.terminate() }
        choose("Send"); assertValue("Send")
        app.terminate(); openGeneral(); revealRow(); assertValue("Send")
        let image = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        image.name = "General hardware Return preference"; image.lifetime = .keepAlways; add(image)
        choose("New Line"); assertValue("New Line")
    }

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
        let providers = ["OpenAI", "Volcengine",
                         "Volcengine Agent Plan", "Alibaba Cloud", "Alibaba Cloud Token Plan"]
        for (index, title) in providers.enumerated() {
            add.tap()
            let provider = app.buttons[title].firstMatch
            XCTAssertTrue(provider.waitForExistence(timeout: 5), title)
            XCTAssertTrue(provider.isEnabled, "Provider configuration must not require an account probe")
            if index == 0 { capture("Cloud recognition provider choices", app: app) }
            provider.tap()
            XCTAssertTrue(app.textFields["Name"].waitForExistence(timeout: 5), title)
            XCTAssertTrue(app.textFields["File transcription URL"].exists, title)
            if index == 0 {
                XCTAssertEqual(app.textFields["File transcription URL"].value as? String,
                               "https://api.openai.com/v1")
            }
            if index == 1 || index == 2 {
                let streaming = app.switches["voice.cloud.profile.streaming"].firstMatch
                XCTAssertTrue(streaming.exists, "Volcengine streaming must be directly configurable")
                XCTAssertEqual(streaming.value as? String, "1")
                setStreaming(streaming, enabled: false)
                setStreaming(streaming, enabled: true)
            }
            if index == 0 || index == 2 || index == 4 { capture("Cloud recognition form " + title, app: app) }
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

    private func setStreaming(_ element: XCUIElement, enabled: Bool) {
        // Match the existing native Form switch tests: the AX Switch spans
        // the labeled row, while the actual UISwitch is at the trailing end.
        element.coordinate(withNormalizedOffset: CGVector(dx: 0.92, dy: 0.5)).tap()
        let expected = NSPredicate(format: "value == %@", enabled ? "1" : "0")
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(
            predicate: expected, object: element)], timeout: 5), .completed)
    }
}
