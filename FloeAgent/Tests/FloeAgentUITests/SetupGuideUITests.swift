import XCTest

final class SetupGuideUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testFirstLaunchCanSkipAndReopenSetup() throws {
        let app = XCUIApplication()
        app.launchArguments = [
            "--ui-test-reset-onboarding",
            "--ui-test-force-onboarding",
            "-AppleLanguages", "(zh-Hans)",
            "-AppleLocale", "zh_CN"
        ]
        app.launch()

        let skip = app.buttons["setup.skip"]
        XCTAssertTrue(skip.waitForExistence(timeout: 8))
        skip.tap()

        let reopen = app.buttons["setup.open"]
        XCTAssertTrue(reopen.waitForExistence(timeout: 5))
        reopen.tap()
        XCTAssertTrue(skip.waitForExistence(timeout: 5))
    }

    @MainActor
    func testPullDownDismissalPersistsSkippedState() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-test-reset-onboarding", "--ui-test-force-onboarding"]
        app.launch()
        XCTAssertTrue(app.buttons["setup.skip"].waitForExistence(timeout: 8))

        app.swipeDown(velocity: .fast)
        XCTAssertTrue(app.buttons["setup.open"].waitForExistence(timeout: 5))

        app.terminate()
        app.launchArguments = []
        app.launch()
        XCTAssertFalse(app.buttons["setup.skip"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.buttons["setup.open"].exists)
    }

    @MainActor
    func testSkippingSetupKeepsComposerAndVoiceInputAvailable() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-test-reset-onboarding", "--ui-test-force-onboarding"]
        app.launch()

        let skip = app.buttons["setup.skip"]
        XCTAssertTrue(skip.waitForExistence(timeout: 8))
        skip.tap()

        let input = app.descendants(matching: .any)["composer.input"]
        XCTAssertTrue(input.waitForExistence(timeout: 5))
        XCTAssertTrue(input.isEnabled)
        XCTAssertTrue(app.buttons["composer.voice"].exists)
    }

    @MainActor
    func testProviderSettingsKeepsModelRefreshAvailable() throws {
        XCUIDevice.shared.orientation = .landscapeLeft
        let app = XCUIApplication()
        app.launchArguments = ["--ui-test-reset-onboarding"]
        app.launch()

        if app.buttons["setup.skip"].waitForExistence(timeout: 4) {
            app.buttons["setup.skip"].tap()
        }

        let providers = app.staticTexts["sidebar.more.providers"]
        XCTAssertTrue(providers.waitForExistence(timeout: 5))
        providers.tap()

        let addProvider = app.buttons["providers.add"]
        XCTAssertTrue(addProvider.waitForExistence(timeout: 5))
        addProvider.tap()

        let refresh = app.buttons["providers.refresh_models"]
        for _ in 0..<4 where !refresh.exists {
            app.swipeUp()
        }
        XCTAssertTrue(refresh.waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["action.cancel"].exists)
    }

    /// Opt-in end-to-end smoke test. The credential is supplied by the local
    /// test runner only and is persisted by the app into its Keychain through
    /// the same provider editor path a user follows.
    @MainActor
    func testLiveVolcengineProviderCanDiscoverSelectAndSaveModel() throws {
        // Xcode does not consistently forward the host shell environment to
        // an iOS UI-test runner. A one-shot runner preference is therefore a
        // local-only fallback; remove it immediately after reading so the
        // credential cannot linger in simulator preferences. Production app
        // code never reads this key.
        let preferenceKey = "FLOE_LIVE_VOLCENGINE_API_KEY"
        let apiKey = ProcessInfo.processInfo.environment[preferenceKey]
            ?? UserDefaults.standard.string(forKey: preferenceKey)
        UserDefaults.standard.removeObject(forKey: preferenceKey)
        guard let apiKey,
              !apiKey.isEmpty else {
            throw XCTSkip("Live Volcengine credential is not present")
        }

        XCUIDevice.shared.orientation = .landscapeLeft
        let app = XCUIApplication()
        app.launchArguments = [
            "--ui-test-reset-onboarding",
            "-ui-testing",
            "-ui-testing-ipad"
        ]
        app.launch()

        // The reset is best-effort because a simulator can restore an
        // already-skipped onboarding marker before the async database reset
        // has finished. Both states are legitimate entry points for this
        // provider/settings smoke test: skip the sheet when it is present,
        // otherwise continue from the fully available shell.
        let setupSkip = app.buttons["setup.skip"]
        if setupSkip.waitForExistence(timeout: 4) {
            setupSkip.tap()
        }
        XCTAssertTrue(app.staticTexts["sidebar.more.providers"].waitForExistence(timeout: 8))
        app.staticTexts["sidebar.more.providers"].tap()
        XCTAssertTrue(app.buttons["providers.add"].waitForExistence(timeout: 8))
        app.buttons["providers.add"].tap()

        let preset = app.buttons["providers.preset"]
        XCTAssertTrue(preset.waitForExistence(timeout: 8))
        preset.tap()
        let ark = app.buttons["Volcengine Ark"]
        XCTAssertTrue(ark.waitForExistence(timeout: 5))
        ark.tap()

        let keyField = app.secureTextFields["providers.api_key"]
        XCTAssertTrue(keyField.waitForExistence(timeout: 5))
        keyField.tap()
        keyField.typeText(apiKey)

        let testConnection = app.buttons["providers.test_connection"]
        XCTAssertTrue(testConnection.exists)
        testConnection.tap()
        let connectionFinished = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "isEnabled == true"),
            object: testConnection
        )
        XCTAssertEqual(XCTWaiter.wait(for: [connectionFinished], timeout: 30), .completed)

        app.buttons["providers.manage_models"].tap()
        let callableModelID = "doubao-seed-2-1-pro-260628"
        let modelSearch = app.searchFields.firstMatch
        XCTAssertTrue(modelSearch.waitForExistence(timeout: 5))
        modelSearch.tap()
        modelSearch.typeText(callableModelID)
        let candidate = app.switches["providers.model.\(callableModelID)"]
        XCTAssertTrue(candidate.waitForExistence(timeout: 10))
        // A SwiftUI Toggle exposes the full labeled row as its accessibility
        // frame; activate the switch control at the trailing edge.
        candidate.coordinate(withNormalizedOffset: CGVector(dx: 0.92, dy: 0.5)).tap()
        let selected = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "value == %@", "selected"),
            object: candidate
        )
        XCTAssertEqual(XCTWaiter.wait(for: [selected], timeout: 5), .completed)
        app.buttons["action.done"].tap()

        let save = app.buttons["action.save"]
        XCTAssertTrue(save.waitForExistence(timeout: 5))
        save.tap()
        XCTAssertTrue(app.staticTexts["Volcengine Ark"].waitForExistence(timeout: 15))

        let home = app.staticTexts["sidebar.primary.home"]
        XCTAssertTrue(home.waitForExistence(timeout: 5))
        home.tap()
        let input = app.descendants(matching: .any)["composer.input"]
        XCTAssertTrue(input.waitForExistence(timeout: 8))
        input.tap()
        input.typeText("Reply with exactly: FLOE_LIVE_UI_OK")
        let send = app.buttons["composer.send"]
        XCTAssertTrue(send.waitForExistence(timeout: 5))
        XCTAssertTrue(send.isEnabled)
        send.tap()

        XCTAssertTrue(app.staticTexts["thread.run_state.completed"].waitForExistence(timeout: 60))
        XCTAssertTrue(
            app.descendants(matching: .any)["thread.assistant_message"]
                .waitForExistence(timeout: 10)
        )
    }
}
