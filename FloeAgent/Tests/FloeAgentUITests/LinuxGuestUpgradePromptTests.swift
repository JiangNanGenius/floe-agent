// FloeAgentUITests — cold-start Linux environment upgrade consent prompt.
//
// The real app is launched with a DEBUG-only fixture that asks the PRODUCTION
// decision path for a synthetic older resident image. The test proves the
// prompt really renders over the ordinary app surface with both explicit
// choices and that either choice dismisses it. The synthetic ids never match
// the simulator's real resident disk, so the upgrade action cannot start a
// rebuild (and no download/VM is created by this test).
//
// NOT RUN by the boot-flow implementation worker: Simulator/App UI acceptance
// belongs to the primary owner. This file is source-compiled with the target
// so it can be executed on the pinned reused iPad simulator.

import XCTest

@MainActor
final class LinuxGuestUpgradePromptUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    private func launchApp() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = [
            "-ui-testing",
            "--ui-test-skip-onboarding",
            "--ui-test-linux-upgrade-prompt",
            "-AppleLanguages", "(en)",
            "-AppleLocale", "en_US",
        ]
        app.launch()
        return app
    }

    func testPromptOffersUpgradeAndKeepForThisStart() {
        let app = launchApp()
        let alert = app.alerts.firstMatch
        XCTAssertTrue(alert.waitForExistence(timeout: 30), "the cold-start Linux upgrade prompt did not appear")
        XCTAssertTrue(alert.buttons["Upgrade Linux environment"].exists)
        XCTAssertTrue(alert.buttons["Use current version for this start"].exists)

        alert.buttons["Use current version for this start"].tap()
        XCTAssertTrue(alert.waitForNonExistence(timeout: 10),
                      "the keep-current choice must dismiss the prompt")
    }

    func testUpgradeChoiceDismissesPrompt() {
        let app = launchApp()
        let alert = app.alerts.firstMatch
        XCTAssertTrue(alert.waitForExistence(timeout: 30), "the cold-start Linux upgrade prompt did not appear")
        alert.buttons["Upgrade Linux environment"].tap()
        XCTAssertTrue(alert.waitForNonExistence(timeout: 10),
                      "the upgrade choice must dismiss the prompt")
    }
}
