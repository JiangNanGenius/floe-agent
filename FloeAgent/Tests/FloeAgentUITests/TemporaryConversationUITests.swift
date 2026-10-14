// FloeAgentUITests — Temporary chat GUI acceptance.
//
// Lane job-79921607e2344107. These tests never send a message (no paid model
// calls) and never complete or fake a model response. Synthetic state comes
// from the DEBUG-only TemporaryChatUITestFixture (fixed synthetic UUIDs, real
// store/center paths, no user-history deletion).
//
// Coverage:
//  1. New Chat opens immediately — NO creation-time ordinary/temporary
//     selector, sheet or forced choice.
//  2. Launchpad top-header temporary entry (primary-implemented Home
//     integration): hosts a fresh RAM-only thread, carries the typed draft,
//     hides attachment/voice, shows badge + Keep + provider-policy hint.
//  3. Fixture: populated saved chat → separate temporary session; leaving to
//     New Task discards it; the saved history stays intact.
//  4. Fixture (preset session, seeded in-RAM messages): explicit End
//     discards everything and returns to the saved chat.
//  5. Fixture (preset session): Keep as saved promotes in place — badge gone,
//     messages still visible.
//  6. Rotation does not discard an active temporary chat.
//  7. Background/foreground retains the same temporary chat and RAM draft.

import XCTest
import UIKit

@MainActor
final class TemporaryConversationUITests: XCTestCase {

    private let savedRow = "sidebar.conversation.7A1E22C4-3B0F-4A5D-9E62-1C8F3D5B7A21"

    private func launch(
        _ app: XCUIApplication = XCUIApplication(),
        arguments: [String] = []
    ) -> XCUIApplication {
        continueAfterFailure = false
        app.launchArguments += ["-ui-testing"] + arguments
        if UIDevice.current.userInterfaceIdiom == .pad {
            app.launchArguments.append("-ui-testing-ipad")
        }
        app.launch()
        return app
    }

    /// Captures a SwiftUI menu row's verified on-screen center once.
    private final class MenuTapPoint: @unchecked Sendable {
        var center: CGPoint?
    }

    /// iOS 27 can expose a visible SwiftUI menu row with a valid frame while
    /// XCTest reports no usable AX activation point (the same quirk the notes
    /// import test documents). Tap the verified on-screen center; the
    /// destination assertion still requires the flow to open for real.
    private func tapMenuRow(
        _ app: XCUIApplication,
        _ element: XCUIElement,
        _ label: String
    ) {
        XCTAssertTrue(element.waitForExistence(timeout: 8), label)
        let holder = MenuTapPoint()
        let ready = NSPredicate { _, _ in
            let frame = element.frame
            let screen = app.windows.firstMatch.frame
            let candidate = CGPoint(x: frame.midX, y: frame.midY)
            guard frame.width > 0, frame.height > 0,
                  frame.origin.x.isFinite, frame.origin.y.isFinite,
                  screen.contains(candidate) else { return false }
            holder.center = candidate
            return true
        }
        let expectation = XCTNSPredicateExpectation(predicate: ready, object: element)
        XCTAssertEqual(XCTWaiter.wait(for: [expectation], timeout: 10), .completed, label)
        let screen = app.windows.firstMatch.frame
        guard let center = holder.center else {
            XCTFail(label)
            return
        }
        app.windows.firstMatch.coordinate(withNormalizedOffset: .zero)
            .withOffset(CGVector(dx: center.x - screen.minX, dy: center.y - screen.minY))
            .tap()
    }

    private func openSidebarRow(_ app: XCUIApplication, identifier: String) {
        let row = app.descendants(matching: .any)[identifier].firstMatch
        // The compact sidebar drawer keeps its rows in the AX tree while the
        // drawer is closed (off-screen): existence alone is not visibility.
        if !row.isHittable {
            let drawer = app.buttons["phone.sidebar.open"]
            if drawer.waitForExistence(timeout: 5) { drawer.tap() }
        }
        // The sidebar list (fixed entries + project workspaces + task
        // history) can be longer than the visible column: bounded scrolling
        // brings the row into the realized window instead of failing on a row
        // that exists in the store but is off-screen. Both directions are
        // tried because a previous reveal may have left a top entry (New
        // Task) above the fold.
        let sidebar = app.collectionViews.firstMatch
        var scrolls = 0
        while !row.isHittable, sidebar.exists, scrolls < 6 {
            sidebar.swipeUp()
            scrolls += 1
        }
        scrolls = 0
        while !row.isHittable, sidebar.exists, scrolls < 8 {
            sidebar.swipeDown()
            scrolls += 1
        }
        XCTAssertTrue(row.waitForExistence(timeout: 8))
        row.tap()
    }

    /// New Chat must open immediately with no creation-time selector.
    func testNewChatHasNoCreationTimeSelector() {
        let app = launch()
        let input = app.textViews["composer.input"]
        XCTAssertTrue(input.waitForExistence(timeout: 10))
        XCTAssertFalse(app.sheets.firstMatch.exists)
        XCTAssertFalse(app.alerts.firstMatch.exists)
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "New Chat — no creation-time selector"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    /// Launchpad toggle hosts an ephemeral thread with the carried draft and
    /// the text-only composer (attachment/voice hidden).
    func testLaunchpadTemporaryEntryHostsEphemeralThread() {
        let app = launch()
        let input = app.textViews["composer.input"]
        XCTAssertTrue(input.waitForExistence(timeout: 10))
        let toggle = app.descendants(matching: .any)["home.temporary.toggle"].firstMatch
        XCTAssertTrue(toggle.waitForExistence(timeout: 8))

        let draft = "只留在内存里的草稿"
        input.tap()
        input.typeText(draft)
        toggle.tap()

        let badge = app.descendants(matching: .any)["chat.temporary.badge"].firstMatch
        XCTAssertTrue(badge.waitForExistence(timeout: 8))
        XCTAssertTrue(app.descendants(matching: .any)["chat.temporary.banner"].firstMatch.exists)
        XCTAssertTrue(app.descendants(matching: .any)["chat.temporary.hint"].firstMatch.exists)
        let threadInput = app.textViews["composer.input"]
        XCTAssertTrue(threadInput.waitForExistence(timeout: 8))
        XCTAssertEqual(threadInput.value as? String, draft)
        // Text-only composer: attachment and voice entries are hidden.
        XCTAssertFalse(app.buttons["composer.attach"].exists)
        XCTAssertFalse(app.buttons["composer.voice"].exists)
        // Keep-as-saved is offered before any message exists.
        XCTAssertTrue(app.descendants(matching: .any)["chat.temporary.keep"].firstMatch.exists)
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "Temporary thread — badge, carried draft, text-only"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    /// Fixture: toggling on a populated saved chat starts a SEPARATE session;
    /// leaving to New Task discards it; the saved history stays intact.
    /// iPad additionally keeps a real ordinary workspace inspector open
    /// across the toggle: the temporary chat owns no workspace and must
    /// never mount a resource pane bound to the ordinary conversation.
    /// The compact idiom presents the inspector as a drawer that covers the
    /// toolbar, so the pane assertion stays with the iPad projection where
    /// the ordinary pane and the thread are visible at the same time.
    func testPopulatedChatSeparateSessionLeaveDiscardsAndHistoryIntact() {
        let isPad = UIDevice.current.userInterfaceIdiom == .pad
        if isPad { XCUIDevice.shared.orientation = .landscapeLeft }
        defer { XCUIDevice.shared.orientation = .portrait }
        let app = launch(arguments: ["--ui-test-temporary-chat-fixture"])
        openSidebarRow(app, identifier: savedRow)
        let savedMessage = app.staticTexts["合成历史消息-1"]
        XCTAssertTrue(savedMessage.waitForExistence(timeout: 8))

        if isPad {
            // A real workspace inspector open in an ordinary conversation must
            // never be rebound to a temporary conversation's nonexistent workspace.
            let inspector = app.descendants(matching: .any)["thread.inspector.menu"].firstMatch
            XCTAssertTrue(inspector.waitForExistence(timeout: 8))
            inspector.tap()
            let files = app.descendants(matching: .any)["thread.inspector.open.workspaceFiles"].firstMatch
            tapMenuRow(app, files, "the files inspector row must be tappable")
            XCTAssertTrue(app.descendants(matching: .any)["ipad.inspector.column"].firstMatch.waitForExistence(timeout: 8))
        }

        let toggle = app.descendants(matching: .any)["chat.temporary.toggle"].firstMatch
        XCTAssertTrue(toggle.waitForExistence(timeout: 8))
        toggle.tap()
        // A separate fresh temporary chat opens; the saved messages are not
        // inside it and its badge is visible.
        let badge = app.descendants(matching: .any)["chat.temporary.badge"].firstMatch
        XCTAssertTrue(badge.waitForExistence(timeout: 8))
        XCTAssertFalse(app.staticTexts["合成历史消息-1"].exists)
        if isPad {
            // The temporary identity owns no workspace/browser/terminal
            // binding: the ordinary files inspector must not remain mounted
            // for it.
            XCTAssertFalse(app.descendants(matching: .any)["ipad.inspector.column"].firstMatch.exists)
        }
        let openAttachment = XCTAttachment(screenshot: app.screenshot())
        openAttachment.name = "Temporary chat after inspector toggle"
        openAttachment.lifetime = .keepAlways
        add(openAttachment)

        // Leaving to New Task discards the temporary session.
        openSidebarRow(app, identifier: "sidebar.workbench.new_task")
        XCTAssertFalse(app.descendants(matching: .any)["chat.temporary.badge"].firstMatch.exists)

        // The saved chat and its history are untouched.
        openSidebarRow(app, identifier: savedRow)
        XCTAssertTrue(app.staticTexts["合成历史消息-1"].waitForExistence(timeout: 8))
        XCTAssertFalse(app.descendants(matching: .any)["chat.temporary.badge"].firstMatch.exists)
    }

    /// Fixture (preset session with seeded in-RAM messages): explicit End
    /// discards the temporary content and returns to the saved chat.
    func testExplicitEndWithMessagesDiscardsAndReturnsToSavedChat() {
        let app = launch(arguments: [
            "--ui-test-temporary-chat-fixture",
            "--ui-test-temporary-chat-preset-session",
        ])
        // The app lands directly on the separate temporary thread.
        let badge = app.descendants(matching: .any)["chat.temporary.badge"].firstMatch
        XCTAssertTrue(badge.waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["合成临时提问"].waitForExistence(timeout: 8))
        XCTAssertTrue(app.staticTexts["合成临时回答"].exists)

        // The explicit End button exists because messages are present.
        let end = app.descendants(matching: .any)["chat.temporary.end"].firstMatch
        XCTAssertTrue(end.waitForExistence(timeout: 8))
        end.tap()

        // Back on the saved chat: temporary content is gone, history intact.
        XCTAssertTrue(app.staticTexts["合成历史消息-1"].waitForExistence(timeout: 8))
        XCTAssertFalse(app.staticTexts["合成临时提问"].exists)
        XCTAssertFalse(app.descendants(matching: .any)["chat.temporary.badge"].firstMatch.exists)
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "After End — saved chat intact, temporary content gone"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    /// Fixture (preset session): Keep as saved promotes atomically — the
    /// badge disappears and the messages stay visible in the ordinary chat.
    func testKeepAsSavedPromotesInPlaceAndKeepsMessages() {
        let app = launch(arguments: [
            "--ui-test-temporary-chat-fixture",
            "--ui-test-temporary-chat-preset-session",
        ])
        let badge = app.descendants(matching: .any)["chat.temporary.badge"].firstMatch
        XCTAssertTrue(badge.waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["合成临时提问"].waitForExistence(timeout: 8))

        let keep = app.descendants(matching: .any)["chat.temporary.keep"].firstMatch
        XCTAssertTrue(keep.waitForExistence(timeout: 8))
        keep.tap()

        // Promotion completes in place: no resend, same visible thread.
        XCTAssertTrue(app.staticTexts["合成临时提问"].waitForExistence(timeout: 8))
        XCTAssertFalse(app.descendants(matching: .any)["chat.temporary.badge"].firstMatch.exists)
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "After Keep — ordinary saved chat with promoted messages"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    /// Rotation does not discard an active temporary chat.
    func testRotationKeepsTemporarySession() {
        let app = launch(arguments: [
            "--ui-test-temporary-chat-fixture",
            "--ui-test-temporary-chat-preset-session",
        ])
        let badge = app.descendants(matching: .any)["chat.temporary.badge"].firstMatch
        XCTAssertTrue(badge.waitForExistence(timeout: 10))
        XCUIDevice.shared.orientation = .landscapeLeft
        XCTAssertTrue(badge.waitForExistence(timeout: 8))
        XCUIDevice.shared.orientation = .portrait
        XCTAssertTrue(badge.waitForExistence(timeout: 8))
        XCTAssertTrue(app.staticTexts["合成临时提问"].exists)
    }

    func testBackgroundReturnRetainsTemporaryChatAndDraft() {
        let app = launch(arguments: [
            "--ui-test-temporary-chat-fixture",
            "--ui-test-temporary-chat-preset-session",
        ])
        let badge = app.descendants(matching: .any)["chat.temporary.badge"].firstMatch
        XCTAssertTrue(badge.waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["合成临时提问"].waitForExistence(timeout: 8))
        let draft = "Temporary RAM draft \(UUID().uuidString)"
        let input = app.textViews["composer.input"]
        XCTAssertTrue(input.waitForExistence(timeout: 8))
        input.tap()
        input.typeText(draft)

        XCUIDevice.shared.press(.home)
        let backgrounded = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in
                app.state == .runningBackground || app.state == .runningBackgroundSuspended
            },
            object: app
        )
        XCTAssertEqual(XCTWaiter.wait(for: [backgrounded], timeout: 8), .completed)
        // Activate the live process; launching again would recreate the fixture
        // and could hide a destruction bug. The unique draft also detects that.
        app.activate()
        XCTAssertTrue(badge.waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["合成临时提问"].exists)
        XCTAssertTrue(app.staticTexts["合成临时回答"].exists)
        XCTAssertEqual(app.textViews["composer.input"].value as? String, draft)
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "Background return — same temporary chat and RAM draft"
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
