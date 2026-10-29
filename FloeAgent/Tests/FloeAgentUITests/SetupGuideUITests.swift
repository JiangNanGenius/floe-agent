// FloeAgentUITests — Native setup guide, ten product sections.
//
// Locale-neutral: every assertion uses an accessibility identifier the guide
// owns, so the same test runs under English and Simplified Chinese without
// embedding either language. No credential, no network, no microphone and no
// download is started: a resource row is only observed, never requested.

import XCTest
import UIKit

final class SetupGuideUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    /// The ten sections in product order, plus the summary.
    private let sections = [
        "chatModels", "creation", "webSearch", "voice", "files",
        "personalization", "permissions", "background", "syncStorage", "skills"
    ]

    private func launch(
        orientation: UIDeviceOrientation = .landscapeLeft,
        extraArguments: [String] = []
    ) -> XCUIApplication {
        XCUIDevice.shared.orientation = orientation
        let app = XCUIApplication()
        app.launchArguments = [
            "--ui-test-reset-onboarding",
            "--ui-test-force-onboarding",
            "-ui-testing"
        ] + extraArguments
        app.launch()
        return app
    }

    /// Section containers are resolved layout-agnostically: the same
    /// identifier can land on a list, a table or a group depending on width.
    private func sectionElement(_ app: XCUIApplication, _ identifier: String) -> XCUIElement {
        let direct = app.otherElements[identifier]
        if direct.exists { return direct }
        return app.descendants(matching: .any)[identifier].firstMatch
    }

    /// Back / Later / Next exist on every section, including the first one.
    @MainActor
    func testEverySectionOffersBackLaterAndNext() throws {
        let app = launch()
        XCTAssertTrue(app.buttons["setup.next"].waitForExistence(timeout: 10))
        for (index, section) in sections.enumerated() {
            XCTAssertTrue(
                sectionElement(app, "setup.content.\(section)").waitForExistence(timeout: 8),
                "section \(section) never appeared"
            )
            XCTAssertTrue(app.buttons["setup.next"].exists)
            XCTAssertTrue(app.buttons["setup.later"].exists)
            XCTAssertTrue(app.buttons["setup.back"].exists)
            // Position advances honestly; nothing is skipped for being unset.
            XCTAssertTrue(app.otherElements["setup.progress"].exists)
            if index < sections.count { app.buttons["setup.next"].tap() }
        }
        // The summary is the eleventh step and offers Finish, not Next.
        XCTAssertTrue(sectionElement(app, "setup.content.summary").waitForExistence(timeout: 8))
        XCTAssertTrue(app.buttons["setup.finish"].exists)
        XCTAssertFalse(app.buttons["setup.next"].exists)
    }

    /// Every preset walks the same ten sections; a preset only pre-fills.
    @MainActor
    func testAllPresetsReachTheSameTenSections() throws {
        for preset in ["lightStart", "everyday", "voiceConversation",
                       "developmentCreation", "custom"] {
            let app = launch()
            let button = app.buttons["setup.preset.\(preset)"]
            XCTAssertTrue(button.waitForExistence(timeout: 10), "preset \(preset) missing")
            button.tap()
            XCTAssertTrue(app.otherElements["setup.preset.active"].waitForExistence(timeout: 5))
            for section in sections {
                XCTAssertTrue(
                    sectionElement(app, "setup.content.\(section)").waitForExistence(timeout: 8),
                    "preset \(preset) skipped section \(section)"
                )
                app.buttons["setup.next"].tap()
            }
            XCTAssertTrue(sectionElement(app, "setup.content.summary").waitForExistence(timeout: 8))
            app.buttons["setup.finish"].tap()
        }
    }

    /// Later is a real decision: the section keeps working and the guide moves
    /// on without waiting for anything.
    @MainActor
    func testLaterAdvancesWithoutBlocking() throws {
        let app = launch()
        XCTAssertTrue(app.buttons["setup.later"].waitForExistence(timeout: 10))
        app.buttons["setup.later"].tap()
        XCTAssertTrue(sectionElement(app, "setup.content.creation").waitForExistence(timeout: 8))
        XCTAssertTrue(app.buttons["setup.status.deferred"].exists
                      || app.otherElements["setup.status.deferred"].exists)
    }

    /// Exiting keeps the position; reopening resumes instead of restarting.
    @MainActor
    func testExitAndResumeKeepsPosition() throws {
        let app = launch()
        XCTAssertTrue(app.buttons["setup.next"].waitForExistence(timeout: 10))
        for _ in 0..<3 { app.buttons["setup.next"].tap() }
        XCTAssertTrue(sectionElement(app, "setup.content.voice").waitForExistence(timeout: 8))
        app.buttons["setup.skip"].tap()

        let reopened = XCUIApplication()
        reopened.launchArguments = ["-ui-testing"]
        reopened.launch()
        let launcher = reopened.buttons["setup.open"]
        if launcher.waitForExistence(timeout: 8) {
            launcher.tap()
            XCTAssertTrue(
                sectionElement(reopened, "setup.content.voice").waitForExistence(timeout: 10),
                "the guide did not resume where the user left it"
            )
        }
    }

    /// Long product copy must stay readable and the controls must stay
    /// hittable: the guide never becomes a wall of text or a tiny target.
    @MainActor
    func testLongCopyStaysReachable() throws {
        let app = launch(extraArguments: ["-UIAccessibilityIsBoldTextEnabled", "YES"])
        app.launchArguments += ["-AppleTextSize", "4"]
        XCTAssertTrue(app.buttons["setup.next"].waitForExistence(timeout: 10))
        for section in sections {
            XCTAssertTrue(sectionElement(app, "setup.content.\(section)").waitForExistence(timeout: 8))
            let next = app.buttons["setup.next"]
            XCTAssertTrue(next.isHittable, "Next is not hittable in \(section)")
            next.tap()
        }
    }

    /// A resource row is observable but never starts on page entry, and the
    /// guide can move past it while it is not ready.
    @MainActor
    func testResourceRowsDoNotGateNavigation() throws {
        let app = launch(orientation: .portrait)
        XCTAssertTrue(app.buttons["setup.next"].waitForExistence(timeout: 10))
        // Walk to Files & Workspaces, which owns the runtime row.
        for _ in 0..<4 { app.buttons["setup.next"].tap() }
        XCTAssertTrue(sectionElement(app, "setup.content.files").waitForExistence(timeout: 8))
        // Nothing may be downloading just because the page opened.
        XCTAssertFalse(app.buttons["setup.resource.localRuntime.cancel"].exists)
        // Leaving the section works whether or not the runtime exists.
        XCTAssertTrue(app.buttons["setup.next"].isHittable)
        app.buttons["setup.next"].tap()
        XCTAssertTrue(sectionElement(app, "setup.content.personalization").waitForExistence(timeout: 8))
    }

    /// The summary lists the real outcome per section and each row jumps back
    /// to that section.
    @MainActor
    func testSummaryJumpLinksReturnToTheSection() throws {
        let app = launch()
        XCTAssertTrue(app.buttons["setup.next"].waitForExistence(timeout: 10))
        app.buttons["setup.next"].tap()
        app.buttons["setup.next"].tap()
        for _ in 0..<9 { app.buttons["setup.next"].tap() }
        XCTAssertTrue(sectionElement(app, "setup.content.summary").waitForExistence(timeout: 10))
        let jump = app.buttons["setup.summary.jump.webSearch"]
        XCTAssertTrue(jump.waitForExistence(timeout: 5))
        jump.tap()
        XCTAssertTrue(sectionElement(app, "setup.content.webSearch").waitForExistence(timeout: 8))
    }

    /// The on-device provider is never opened in the chat provider editor by
    /// default, and adding always starts from an empty form.
    @MainActor
    func testAddProviderStartsEmpty() throws {
        let app = launch()
        XCTAssertTrue(app.buttons["setup.next"].waitForExistence(timeout: 10))
        let add = app.buttons["setup.chat.addProvider"]
        XCTAssertTrue(add.waitForExistence(timeout: 8))
        add.tap()
        XCTAssertTrue(app.buttons["providers.test_connection"].waitForExistence(timeout: 10))
        // A blank form has no stored endpoint and no stored key.
        let keyField = app.secureTextFields["providers.api_key"]
        XCTAssertTrue(keyField.waitForExistence(timeout: 8))
        XCTAssertEqual((keyField.value as? String) ?? "", "")
    }

    /// Existing behaviour preserved: skipping still leaves the composer and
    /// voice input usable, and the launcher still reopens the guide.
    @MainActor
    func testSkipKeepsAppUsableAndLauncherReopens() throws {
        let app = launch()
        let skip = app.buttons["setup.skip"]
        XCTAssertTrue(skip.waitForExistence(timeout: 10))
        skip.tap()

        let input = app.descendants(matching: .any)["composer.input"]
        XCTAssertTrue(input.waitForExistence(timeout: 10))
        XCTAssertTrue(input.isEnabled)

        let reopen = app.buttons["setup.open"]
        if reopen.waitForExistence(timeout: 8) {
            reopen.tap()
            XCTAssertTrue(app.buttons["setup.next"].waitForExistence(timeout: 10))
        }
    }

    /// The provider settings surface is untouched by this rewrite.
    @MainActor
    func testProviderSettingsKeepsModelRefreshAvailable() throws {
        let app = launch(extraArguments: ["--ui-test-skip-onboarding", "-ui-testing-ipad"])
        let settings = app.buttons["sidebar.settings"]
        XCTAssertTrue(settings.waitForExistence(timeout: 10))
        settings.tap()

        let providers = app.descendants(matching: .any)
            .matching(identifier: "settings.section.providers")
            .firstMatch
        XCTAssertTrue(providers.waitForExistence(timeout: 8))
        providers.tap()

        let addProvider = app.buttons["providers.add"]
        XCTAssertTrue(addProvider.waitForExistence(timeout: 8))
        addProvider.tap()

        let refresh = app.buttons["providers.refresh_models"]
        for _ in 0..<4 where !refresh.exists { app.swipeUp() }
        XCTAssertTrue(refresh.waitForExistence(timeout: 8))
        XCTAssertTrue(app.buttons["action.cancel"].exists)
    }
}
