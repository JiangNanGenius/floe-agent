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
//     keeps attachment staging hidden while the normal voice entry stays
//     available, and shows the compact badge menu (explanation + Keep +
//     End) instead of the removed persistent banner. The ordinary saved
//     conversation's thread exposes NO temporary switch: the launchpad entry
//     is the only way into a temporary chat.
//  3. Fixture: launchpad entry next to a populated saved chat; leaving to
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

    /// Frame-based visibility. iOS 27 can raise "Activation point invalid"
    /// when `isHittable` is queried on a drawer row whose frame the AX layer
    /// has not settled, so the helper never asks for hittability.
    private func rowIsVisible(_ app: XCUIApplication, _ row: XCUIElement) -> Bool {
        guard row.exists else { return false }
        let frame = row.frame
        let screen = app.windows.firstMatch.frame
        guard frame.width > 0, frame.height > 0,
              frame.origin.x.isFinite, frame.origin.y.isFinite else { return false }
        return screen.contains(CGPoint(x: frame.midX, y: frame.midY))
    }

    private func openSidebarRow(_ app: XCUIApplication, identifier: String) {
        let row = app.descendants(matching: .any)[identifier].firstMatch
        // The compact sidebar drawer keeps its rows in the AX tree while the
        // drawer is closed (off-screen): existence alone is not visibility.
        if !rowIsVisible(app, row) {
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
        while !rowIsVisible(app, row), sidebar.exists, scrolls < 6 {
            sidebar.swipeUp()
            scrolls += 1
        }
        scrolls = 0
        while !rowIsVisible(app, row), sidebar.exists, scrolls < 8 {
            sidebar.swipeDown()
            scrolls += 1
        }
        XCTAssertTrue(row.waitForExistence(timeout: 8))
        // Tap the verified on-screen center: the destination assertions still
        // require the conversation to open for real.
        let frame = row.frame
        let screen = app.windows.firstMatch.frame
        let candidate = CGPoint(x: frame.midX, y: frame.midY)
        guard frame.width > 0, frame.height > 0,
              frame.origin.x.isFinite, frame.origin.y.isFinite,
              screen.contains(candidate) else {
            XCTFail("sidebar row \(identifier) has no reachable activation point")
            return
        }
        app.windows.firstMatch.coordinate(withNormalizedOffset: .zero)
            .withOffset(CGVector(dx: candidate.x - screen.minX, dy: candidate.y - screen.minY))
            .tap()
    }

    /// New Chat must open immediately with no creation-time selector.
    func testNewChatHasNoCreationTimeSelector() {
        let app = launch()
        let input = app.textViews["composer.input"]
        XCTAssertTrue(input.waitForExistence(timeout: 10))
        XCTAssertFalse(app.sheets.firstMatch.exists)
        XCTAssertFalse(app.alerts.firstMatch.exists)
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = "New Chat — no creation-time selector"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    /// Launchpad toggle hosts an ephemeral thread with the carried draft and
    /// the no-attachment composer (attachment staging hidden; the normal
    /// voice entry is available).
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
        // The persistent banner was replaced by the compact header menu.
        XCTAssertFalse(app.descendants(matching: .any)["chat.temporary.banner"].firstMatch.exists)
        let threadInput = app.textViews["composer.input"]
        XCTAssertTrue(threadInput.waitForExistence(timeout: 8))
        XCTAssertEqual(threadInput.value as? String, draft)
        // No-attachment composer: attachment staging stays hidden; the
        // normal voice entry is available in a temporary chat.
        XCTAssertFalse(app.buttons["composer.attach"].exists)
        XCTAssertTrue(app.buttons["composer.voice"].waitForExistence(timeout: 8))
        // Keep-as-saved is offered before any message exists, inside the menu.
        badge.tap()
        XCTAssertTrue(app.descendants(matching: .any)["chat.temporary.hint"].firstMatch.waitForExistence(timeout: 8))
        XCTAssertTrue(app.descendants(matching: .any)["chat.temporary.keep"].firstMatch.exists)
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = "Temporary thread — badge menu with short lifecycle header"
        attachment.lifetime = .keepAlways
        add(attachment)
        // The full lifecycle/tool/cloud/voice explanation stays readable
        // behind the enabled About action (no clipped 3-line menu row).
        let about = app.descendants(matching: .any)["chat.temporary.about"].firstMatch
        XCTAssertTrue(about.waitForExistence(timeout: 8), "temporary About action")
        about.tap()
        XCTAssertTrue(app.descendants(matching: .any)["chat.temporary.about.tools"].firstMatch
            .waitForExistence(timeout: 8), "readable tool/cloud disclosure")
        XCTAssertTrue(app.descendants(matching: .any)["chat.temporary.about.lifecycle"].firstMatch.exists)
        let aboutShot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        aboutShot.name = "Temporary chat — About sheet with full disclosures"
        aboutShot.lifetime = .keepAlways
        add(aboutShot)
        app.buttons["chat.temporary.about.done"].firstMatch.tap()
    }

    /// Fixture: the launchpad entry hosts a SEPARATE ephemeral session next to
    /// a populated saved chat; leaving to New Task discards it; the saved
    /// history stays intact. The ordinary saved chat itself never offers a
    /// temporary switch — the launchpad bubble entry is the only way in.
    /// iPad additionally keeps a real ordinary workspace inspector open while
    /// viewing the saved chat: the temporary chat owns no workspace and must
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

        // The ordinary saved chat keeps NO temporary switch in its toolbar:
        // its thread must never convert a populated saved conversation.
        XCTAssertFalse(app.descendants(matching: .any)["chat.temporary.toggle"].firstMatch.exists)

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

        // The launchpad entry hosts the ephemeral session. The saved chat is
        // left first, so the ordinary workspace inspector unmounts with it.
        openSidebarRow(app, identifier: "sidebar.workbench.new_task")
        let toggle = app.descendants(matching: .any)["home.temporary.toggle"].firstMatch
        XCTAssertTrue(toggle.waitForExistence(timeout: 8))
        toggle.tap()
        let badge = app.descendants(matching: .any)["chat.temporary.badge"].firstMatch
        XCTAssertTrue(badge.waitForExistence(timeout: 8))
        // The saved messages are not inside the ephemeral session.
        XCTAssertFalse(app.staticTexts["合成历史消息-1"].exists)
        if isPad {
            // The temporary identity owns no workspace/browser/terminal
            // binding: no ordinary files inspector may remain mounted for it.
            XCTAssertFalse(app.descendants(matching: .any)["ipad.inspector.column"].firstMatch.exists)
        }
        // Capture readiness: wait until the toggle transition has settled and
        // the active badge is really on screen/hittable, so the frame is the
        // stable final layout rather than a mid-transition crop.
        XCTAssertTrue(badge.isHittable, "the active temporary badge must be on screen before capture")
        let settled = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in
                !app.descendants(matching: .any)["ipad.inspector.column"].firstMatch.exists
            },
            object: nil
        )
        XCTAssertEqual(XCTWaiter.wait(for: [settled], timeout: 8), .completed,
                       "the inspector transition must settle before capture")
        let openAttachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        openAttachment.name = "Temporary chat after launchpad entry"
        openAttachment.lifetime = .keepAlways
        add(openAttachment)

        // Leaving to New Task discards the temporary session.
        openSidebarRow(app, identifier: "sidebar.workbench.new_task")
        XCTAssertFalse(app.descendants(matching: .any)["chat.temporary.badge"].firstMatch.exists)

        // The saved chat and its history are untouched.
        openSidebarRow(app, identifier: savedRow)
        XCTAssertTrue(app.staticTexts["合成历史消息-1"].waitForExistence(timeout: 8))
        XCTAssertFalse(app.descendants(matching: .any)["chat.temporary.badge"].firstMatch.exists)
        XCTAssertFalse(app.descendants(matching: .any)["chat.temporary.toggle"].firstMatch.exists)
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

        // The explicit End action exists because messages are present; it
        // lives in the compact header menu.
        badge.tap()
        let end = app.descendants(matching: .any)["chat.temporary.end"].firstMatch
        XCTAssertTrue(end.waitForExistence(timeout: 8))
        end.tap()

        // Back on the saved chat: temporary content is gone, history intact.
        XCTAssertTrue(app.staticTexts["合成历史消息-1"].waitForExistence(timeout: 8))
        XCTAssertFalse(app.staticTexts["合成临时提问"].exists)
        XCTAssertFalse(app.descendants(matching: .any)["chat.temporary.badge"].firstMatch.exists)
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
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

        badge.tap()
        let keep = app.descendants(matching: .any)["chat.temporary.keep"].firstMatch
        XCTAssertTrue(keep.waitForExistence(timeout: 8))
        keep.tap()

        // Promotion completes in place: no resend, same visible thread.
        XCTAssertTrue(app.staticTexts["合成临时提问"].waitForExistence(timeout: 8))
        XCTAssertFalse(app.descendants(matching: .any)["chat.temporary.badge"].firstMatch.exists)
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
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
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = "Background return — same temporary chat and RAM draft"
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
