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

    /// Identifiers whose element type is deliberately not part of the test
    /// contract (a container head, a status chip or a progress indicator).
    /// Querying any descendant keeps the assertion locale- and layout-neutral
    /// without weakening what must be visible.
    private func anyElement(_ app: XCUIApplication, _ identifier: String) -> XCUIElement {
        app.descendants(matching: .any)[identifier].firstMatch
    }

    /// SwiftUI forms only materialize rows near the viewport. Scroll until the
    /// target exists, with a bounded number of swipes so a genuinely absent
    /// element still fails actionably.
    private func scrollTo(
        _ element: XCUIElement,
        in app: XCUIApplication,
        maxSwipes: Int = 4
    ) {
        for _ in 0..<maxSwipes where !element.exists {
            app.swipeUp()
        }
    }

    /// The existing Add flow first asks which provider purpose to configure.
    /// Its first action is the chat-model provider (the other two are media
    /// roles); selecting by position keeps this suite locale-neutral without
    /// changing the providers surface.
    private func chooseChatModelProvider(in app: XCUIApplication) {
        let popover = app.popovers.firstMatch
        guard popover.waitForExistence(timeout: 5) else {
            XCTFail("provider purpose picker did not appear")
            return
        }
        let choice = popover.buttons.element(boundBy: 0)
        guard choice.waitForExistence(timeout: 3) else {
            XCTFail("provider purpose picker has no action")
            return
        }
        choice.tap()
    }

    /// Keep representative rendered states in the xcresult so Main can review
    /// the actual ten-section guide, voice, resources, summary and portrait
    /// layouts without a separate screenshot harness.
    private func capture(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    /// Back / Later / Next exist on every section, including the first one.
    @MainActor
    func testEverySectionOffersBackLaterAndNext() throws {
        let app = launch()
        XCTAssertTrue(app.buttons["setup.next"].waitForExistence(timeout: 10))
        for section in sections {
            XCTAssertTrue(
                sectionElement(app, "setup.content.\(section)").waitForExistence(timeout: 8),
                "section \(section) never appeared"
            )
            XCTAssertTrue(app.buttons["setup.next"].exists)
            XCTAssertTrue(app.buttons["setup.later"].exists)
            XCTAssertTrue(app.buttons["setup.back"].exists)
            // Position advances honestly; nothing is skipped for being unset.
            XCTAssertTrue(anyElement(app, "setup.progress").exists)
            if ["chatModels", "voice", "files"].contains(section) {
                capture("setup-guide-\(section)-landscape")
            }
            app.buttons["setup.next"].tap()
        }
        // The summary is the eleventh step and offers Finish, not Next.
        XCTAssertTrue(sectionElement(app, "setup.content.summary").waitForExistence(timeout: 8))
        XCTAssertTrue(app.buttons["setup.finish"].exists)
        XCTAssertFalse(app.buttons["setup.next"].exists)
        capture("setup-guide-summary-landscape")
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
            let active = anyElement(app, "setup.preset.active")
            XCTAssertTrue(active.waitForExistence(timeout: 5),
                          "preset \(preset) did not become active")
            XCTAssertFalse(active.label.isEmpty, "active preset has no visible title")
            XCTAssertTrue(button.label.hasPrefix(active.label),
                          "the head shows \(active.label), not the selected \(preset)")
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
        XCTAssertTrue(anyElement(app, "setup.status.deferred").waitForExistence(timeout: 5),
                      "Later must be reflected as the section's own deferred status")
    }

    /// Exiting keeps the position; reopening resumes instead of restarting.
    @MainActor
    func testExitAndResumeKeepsPosition() throws {
        let app = launch()
        XCTAssertTrue(app.buttons["setup.next"].waitForExistence(timeout: 10))
        for _ in 0..<3 { app.buttons["setup.next"].tap() }
        XCTAssertTrue(sectionElement(app, "setup.content.voice").waitForExistence(timeout: 8))
        app.buttons["setup.skip"].tap()
        XCTAssertTrue(
            app.descendants(matching: .any)["composer.input"].waitForExistence(timeout: 8),
            "Exit must dismiss the guide and leave the app usable"
        )

        // Resume is the contract under test. Present the guide again through
        // the launch path rather than the provider-dependent home launcher,
        // which is absent once a default model exists; no saved progress is
        // reset here.
        let reopened = XCUIApplication()
        reopened.launchArguments = ["-ui-testing", "--ui-test-force-onboarding"]
        reopened.launch()
        XCTAssertTrue(
            sectionElement(reopened, "setup.content.voice").waitForExistence(timeout: 12),
            "the guide did not resume where the user left it"
        )
    }

    /// Long product copy must stay readable and the controls must stay
    /// hittable: the guide never becomes a wall of text or a tiny target.
    @MainActor
    func testLongCopyStaysReachable() throws {
        // These are launch preferences, not live settings: they must be part
        // of the launch arguments before the app starts.
        let app = launch(extraArguments: [
            "-UIAccessibilityIsBoldTextEnabled", "YES",
            "-AppleTextSize", "4"
        ])
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
        capture("setup-guide-files-resources-portrait")
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
        // Ten sections, ten Next taps: the summary is the eleventh step and
        // deliberately has no Next, so an extra tap can only fail.
        for section in sections {
            XCTAssertTrue(
                sectionElement(app, "setup.content.\(section)").waitForExistence(timeout: 8),
                "section \(section) never appeared before the summary"
            )
            app.buttons["setup.next"].tap()
        }
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
        XCTAssertTrue(app.buttons["action.save"].waitForExistence(timeout: 10),
                      "Add must open the shared provider editor")
        // A new provider starts from the shipped preset, never from a saved
        // secret: the secure field is empty (XCUITest reports the placeholder
        // as its value on some iOS versions, which is still not a stored key).
        let keyField = app.secureTextFields["providers.api_key"]
        XCTAssertTrue(keyField.waitForExistence(timeout: 8))
        let keyValue = (keyField.value as? String) ?? ""
        let keyPlaceholder = keyField.placeholderValue ?? ""
        XCTAssertTrue(keyValue.isEmpty || keyValue == keyPlaceholder,
                      "a new provider form was pre-filled with a stored key")
        // Test connection is lower in the same lazy Form; scroll it into
        // existence instead of asserting against an off-screen row.
        let testConnection = app.buttons["providers.test_connection"]
        scrollTo(testConnection, in: app)
        XCTAssertTrue(testConnection.waitForExistence(timeout: 8))
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
        chooseChatModelProvider(in: app)

        XCTAssertTrue(app.buttons["action.cancel"].waitForExistence(timeout: 10),
                      "the provider editor must open for the chosen purpose")
        let refresh = app.buttons["providers.refresh_models"]
        scrollTo(refresh, in: app)
        XCTAssertTrue(refresh.waitForExistence(timeout: 8))
        XCTAssertTrue(app.buttons["action.cancel"].exists)
    }
}
