import XCTest

/// Synthetic native boundary, real production tool/store/card. This is UI
/// behavior evidence, separate from real AlarmKit SDK and system-timer tests.
final class InlineTimerUITests: XCTestCase {
    @MainActor func testTimerCardTicksPausesResumesAndReflectsAnExternalPause() {
        let app = launch()
        defer { app.terminate() }
        let clock = app.staticTexts.matching(NSPredicate(format: "label MATCHES %@", "[0-9]{2}:[0-9]{2}")).firstMatch
        XCTAssertTrue(clock.waitForExistence(timeout: 10))
        let first = clock.label
        let ticking = expectation(for: NSPredicate { _, _ in clock.label != first }, evaluatedWith: nil)
        wait(for: [ticking], timeout: 4)
        let pause = app.buttons.matching(NSPredicate(format: "label IN %@", ["暂停", "Pause"])).firstMatch
        XCTAssertTrue(pause.exists)
        pause.tap()
        let resume = app.buttons.matching(NSPredicate(format: "label IN %@", ["继续", "Resume"])).firstMatch
        XCTAssertTrue(resume.waitForExistence(timeout: 5))
        let pausedReading = clock.label
        let stable = expectation(for: NSPredicate { _, _ in clock.label != pausedReading }, evaluatedWith: nil)
        stable.isInverted = true
        wait(for: [stable], timeout: 2)
        resume.tap()
        XCTAssertTrue(pause.waitForExistence(timeout: 5))
        app.buttons["qualification.inlineTimer.externalPause"].tap()
        XCTAssertTrue(resume.waitForExistence(timeout: 6), "The card must refresh after the native state changes elsewhere")
        keep("inline-timer-body-paused")
    }

    @MainActor func testTimerCardInCompactDarkLargeText() {
        let app = launch(extra: ["--compact", "--dark", "--large-text"])
        defer { app.terminate() }
        XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "chat.inlineTimer").firstMatch.waitForExistence(timeout: 10))
        let pause = app.buttons.matching(NSPredicate(format: "label IN %@", ["暂停", "Pause"])).firstMatch
        XCTAssertTrue(pause.waitForExistence(timeout: 10))
        XCTAssertTrue(pause.isHittable)
        XCTAssertGreaterThanOrEqual(pause.frame.height, 44)
        keep("inline-timer-compact-dark-large-text")
    }

    @MainActor private func launch(extra: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--inline-card-fixture", "-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN"] + extra
        app.launch()
        return app
    }

    @MainActor private func keep(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
    }
}
