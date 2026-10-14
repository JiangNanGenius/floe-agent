// FloeAgentUITests — actual OS-level notification tap qualification.
//
// SPDX-License-Identifier: MPL-2.0
//
// The App-hosted route suites (`BackgroundWorkNotificationRouteTests`) drive
// the real bridge and coordinator with a DEBUG persistence seam. This suite is
// the missing end-to-end step: it lets the SYSTEM deliver one synthetic Floe
// terminal notification (`--ui-test-notification-fixture` prepares a real
// persisted synthetic task and posts through the production
// `BackgroundRunCoordinator.enqueueTerminalNotification` path), then taps the
// actual SpringBoard banner and verifies the production delegate routes to the
// intended conversation. Nothing here calls the delegate directly: if the
// banner were not a real system delivery, or the tap were simulated, the
// assertion on the routed task could not pass.
//
// The durable redacted stage trail (`notificationResponseStage …`) written by
// the app is exported host-side after the run to prove exactly-once
// completion (`completionDelivered`).
import XCTest

@MainActor
final class NotificationTapUITests: XCTestCase {
    private let fixtureTitle = "通知路由合成任务"
    private let fixtureIdentifier = "floe.qualification.notification.tap"

    private func launchFixtureApp() -> XCUIApplication {
        let app = XCUIApplication()
        app.terminate()
        app.launchArguments = ["-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN", "-ui-testing",
                               "--ui-test-skip-onboarding", "--ui-test-notification-fixture"]
        app.launchEnvironment["FLOE_NOTIFICATION_QUALIFICATION_ID"] = fixtureIdentifier
        app.launch()
        return app
    }

    /// The first real `requestAuthorization` prompt. Answered through its own
    /// system UI; when the permission is already decided there is no prompt.
    private func answerNotificationPromptIfPresent(_ springboard: XCUIApplication) {
        let deadline = Date().addingTimeInterval(12)
        while Date() < deadline {
            let alert = springboard.alerts.firstMatch
            if alert.exists {
                for label in ["允许", "好", "Allow", "OK"] {
                    let button = alert.buttons[label]
                    if button.exists && button.isHittable {
                        button.tap()
                        return
                    }
                }
            }
            Thread.sleep(forTimeInterval: 0.25)
        }
    }

    private func bannerTitle(_ springboard: XCUIApplication) -> XCUIElement {
        springboard.staticTexts[fixtureTitle].firstMatch
    }

    @discardableResult
    private func waitForRoutedTask(_ app: XCUIApplication, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if app.state != .runningForeground {
                Thread.sleep(forTimeInterval: 0.25)
                continue
            }
            let navBar = app.navigationBars[fixtureTitle]
            if navBar.exists { return true }
            let title = app.staticTexts[fixtureTitle].firstMatch
            if title.exists && app.textViews["composer.input"].exists { return true }
            Thread.sleep(forTimeInterval: 0.5)
        }
        return false
    }

    private func attachEvidence(_ name: String) {
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }

    /// Real banner tap while the app is foreground: proves system delivery and
    /// the production `didReceive` route end-to-end.
    func testAWarmSystemNotificationTapRoutesToItsTask() throws {
        #if !targetEnvironment(simulator)
        throw XCTSkip("system-notification tap smoke is simulator-only")
        #else
        continueAfterFailure = false
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let app = launchFixtureApp()
        defer { app.terminate() }
        answerNotificationPromptIfPresent(springboard)

        let title = bannerTitle(springboard)
        XCTAssertTrue(title.waitForExistence(timeout: 45),
                      "the system did not deliver the synthetic terminal banner")
        attachEvidence("notification-01-banner-delivered")
        title.tap()
        XCTAssertTrue(waitForRoutedTask(app, timeout: 45),
                      "a real banner tap did not route to the intended synthetic task")
        attachEvidence("notification-02-warm-routed")
        #endif
    }

    /// The same real notification tapped while the app is gone: the system
    /// cold-launches the app and the deferred route must still open its own
    /// task exactly once.
    func testBColdSystemNotificationTapRoutesToItsTask() throws {
        #if !targetEnvironment(simulator)
        throw XCTSkip("system-notification tap smoke is simulator-only")
        #else
        continueAfterFailure = false
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let app = launchFixtureApp()
        defer { app.terminate() }
        answerNotificationPromptIfPresent(springboard)

        let title = bannerTitle(springboard)
        XCTAssertTrue(title.waitForExistence(timeout: 45),
                      "the system did not deliver the synthetic terminal banner")
        app.terminate()
        Thread.sleep(forTimeInterval: 0.8)
        // The delivered banner stays system-owned for a few seconds after the
        // app exits; tap it while it is still visible.
        if title.waitForExistence(timeout: 3) {
            attachEvidence("notification-03-banner-before-cold-tap")
            title.tap()
        } else {
            // Fell back to Notification Center: pull it down from the top edge
            // and tap the delivered notification there.
            let top = springboard.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.01))
            let below = springboard.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.6))
            top.press(forDuration: 0.1, thenDragTo: below)
            let centerTitle = bannerTitle(springboard)
            XCTAssertTrue(centerTitle.waitForExistence(timeout: 10),
                          "the delivered notification is not reachable in Notification Center")
            attachEvidence("notification-03-notification-center")
            centerTitle.tap()
        }
        XCTAssertTrue(waitForRoutedTask(app, timeout: 60),
                      "a cold system notification tap did not route to the intended synthetic task")
        attachEvidence("notification-04-cold-routed")
        #endif
    }
}
