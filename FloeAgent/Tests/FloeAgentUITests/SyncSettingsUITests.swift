import XCTest

final class SyncSettingsUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testMacSyncHasOneSwitchAndKeepsICloudIndependent() throws {
        XCUIDevice.shared.orientation = .landscapeLeft
        let app = XCUIApplication()
        app.launchArguments = [
            "--ui-test-skip-onboarding", "-ui-testing", "-ui-testing-ipad",
            "-AppleLanguages", "(en)", "-AppleLocale", "en_US"
        ]
        app.launch()

        let settings = app.buttons["sidebar.settings"]
        XCTAssertTrue(settings.waitForExistence(timeout: 15))
        settings.tap()
        let sync = app.descendants(matching: .any).matching(identifier: "settings.section.sync").firstMatch
        XCTAssertTrue(sync.waitForExistence(timeout: 8))
        sync.tap()

        let macSync = app.switches["settings.sync.device_history.enabled"]
        let iCloud = app.switches["settings.sync.master"]
        let pairing = app.descendants(matching: .any).matching(identifier: "settings.sync.device_history.devices").firstMatch
        XCTAssertTrue(macSync.waitForExistence(timeout: 8))
        XCTAssertTrue(iCloud.exists)
        let initialICloud = try XCTUnwrap(iCloud.value as? String)
        let initialMacSync = try XCTUnwrap(macSync.value as? String) == "1"
        defer {
            let back = app.navigationBars["Pairing and Sharing"].buttons.firstMatch
            if !macSync.exists, back.exists {
                back.tap()
            }
            if macSync.exists {
                setSwitch(macSync, enabled: initialMacSync)
            }
        }

        setSwitch(macSync, enabled: false)
        XCTAssertFalse(pairing.exists)
        setSwitch(macSync, enabled: true)
        XCTAssertEqual(wait(forValue: initialICloud, element: iCloud), .completed)
        XCTAssertTrue(pairing.waitForExistence(timeout: 8))
        pairing.tap()
        XCTAssertTrue(app.buttons["deviceHistorySync.addDevice"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.switches["deviceHistorySync.enabled"].exists)
        XCTAssertFalse(macSync.exists)
    }

    @MainActor
    func testDedicatedSyncMenuAndIndependentConfigurationSwitch() throws {
        XCUIDevice.shared.orientation = .landscapeLeft
        let app = XCUIApplication()
        app.launchArguments = [
            "--ui-test-reset-sync",
            "--ui-test-skip-onboarding",
            "-ui-testing",
            "-ui-testing-ipad",
            "-AppleLanguages", "(zh-Hans)",
            "-AppleLocale", "zh_CN"
        ]
        app.launch()

        XCTAssertTrue(app.buttons["sidebar.settings"].waitForExistence(timeout: 8))
        app.buttons["sidebar.settings"].tap()

        let syncSection = app.descendants(matching: .any)
            .matching(identifier: "settings.section.sync")
            .firstMatch
        XCTAssertTrue(syncSection.waitForExistence(timeout: 8))
        syncSection.tap()

        let master = app.switches["settings.sync.master"]
        let configuration = app.switches["settings.sync.configuration"]
        let syncNow = app.buttons["settings.sync.now"]
        XCTAssertTrue(master.waitForExistence(timeout: 5))
        XCTAssertTrue(configuration.exists)
        XCTAssertTrue(syncNow.exists)
        XCTAssertTrue(configuration.isEnabled)
        XCTAssertEqual(wait(forValue: "1", element: master), .completed)
        XCTAssertEqual(wait(forValue: "1", element: configuration), .completed)

        XCTAssertEqual(wait(forEnabled: true, element: configuration), .completed)
        XCTAssertEqual(wait(forValue: "available", element: syncNow), .completed)
        turnOff(configuration)
        XCTAssertEqual(wait(forEnabled: true, element: configuration), .completed)
        XCTAssertEqual(wait(forValue: "disabled", element: syncNow), .completed)
    }

    @MainActor
    func testMasterSwitchDisablesConfigurationSync() throws {
        XCUIDevice.shared.orientation = .landscapeLeft
        let app = XCUIApplication()
        app.launchArguments = [
            "--ui-test-reset-sync",
            "--ui-test-skip-onboarding",
            "-ui-testing",
            "-ui-testing-ipad",
            "-AppleLanguages", "(zh-Hans)",
            "-AppleLocale", "zh_CN"
        ]
        app.launch()

        XCTAssertTrue(app.buttons["sidebar.settings"].waitForExistence(timeout: 8))
        app.buttons["sidebar.settings"].tap()
        let syncSection = app.descendants(matching: .any)
            .matching(identifier: "settings.section.sync")
            .firstMatch
        XCTAssertTrue(syncSection.waitForExistence(timeout: 8))
        syncSection.tap()

        let master = app.switches["settings.sync.master"]
        let configuration = app.switches["settings.sync.configuration"]
        let syncNow = app.buttons["settings.sync.now"]
        XCTAssertTrue(master.waitForExistence(timeout: 5))
        XCTAssertEqual(wait(forValue: "1", element: master), .completed)
        turnOff(master)
        XCTAssertEqual(wait(forEnabled: false, element: configuration), .completed)
        XCTAssertEqual(wait(forValue: "disabled", element: syncNow), .completed)
    }

    @MainActor
    private func wait(forEnabled enabled: Bool, element: XCUIElement) -> XCTWaiter.Result {
        let expectation = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "isEnabled == %@", NSNumber(value: enabled)),
            object: element
        )
        return XCTWaiter.wait(for: [expectation], timeout: 8)
    }

    @MainActor
    private func wait(forValue value: String, element: XCUIElement) -> XCTWaiter.Result {
        let expectation = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "value == %@", value),
            object: element
        )
        return XCTWaiter.wait(for: [expectation], timeout: 8)
    }

    @MainActor
    private func turnOff(_ element: XCUIElement) {
        setSwitch(element, enabled: false)
    }

    @MainActor
    private func setSwitch(_ element: XCUIElement, enabled: Bool) {
        let value = enabled ? "1" : "0"
        guard (element.value as? String) != value else { return }
        // iOS Simulator occasionally drops the first synthesized event while
        // a three-column Form is settling. Retry at distinct points within
        // the native trailing UISwitch; the operation is idempotent because
        // we re-read the accessibility value after every attempt.
        for x in [0.90, 0.94, 0.87] {
            element.coordinate(withNormalizedOffset: CGVector(dx: x, dy: 0.50))
                .press(forDuration: 0.08)
            let changed = XCTNSPredicateExpectation(
                predicate: NSPredicate(format: "value == %@", value),
                object: element
            )
            if XCTWaiter.wait(for: [changed], timeout: 2) == .completed { return }
        }
        XCTFail("Switch did not reach the requested value after three control attempts")
    }

}
