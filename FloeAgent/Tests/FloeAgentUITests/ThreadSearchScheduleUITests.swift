// FloeAgentUITests — in-chat find and visible scheduled-task UI acceptance.
//
// SYNTHETIC ONLY: the find test launches the existing DEBUG-only
// TemporaryChatUITestFixture (a fixed saved conversation with two synthetic
// messages, no paid model request). The schedule test navigates the real
// sidebar Task Center, creates one fixed synthetic plan through the existing
// schedule sheet, exercises skip/cancel (which never launch a model task), and
// removes only that synthetic plan again. No user data is read or written and
// no physical device is used.
//
// These tests are authored for the primary integration run. They depend on the
// app's `-ui-testing` launch path and the existing fixture flag; they create no
// new fixture of their own.

import XCTest
import UIKit

@MainActor
final class ThreadSearchScheduleUITests: XCTestCase {
    private let savedConversationID = "7A1E22C4-3B0F-4A5D-9E62-1C8F3D5B7A21"

    private func launch(arguments: [String]) -> XCUIApplication {
        continueAfterFailure = false
        let app = XCUIApplication()
        // Match the other native UI lanes: an explicit language, no global
        // preference reset, and onboarding skipped only for this launch.
        app.launchArguments += [
            "-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN",
            "-ui-testing", "--ui-test-skip-onboarding"
        ] + arguments
        if UIDevice.current.userInterfaceIdiom == .pad {
            app.launchArguments.append("-ui-testing-ipad")
        }
        app.launch()
        return app
    }

    private func waitForLabel(_ element: XCUIElement, _ label: String, timeout: TimeInterval = 10) -> Bool {
        let predicate = NSPredicate(format: "label == %@", label)
        let expectation = XCTNSPredicateExpectation(predicate: predicate, object: element)
        return XCTWaiter.wait(for: [expectation], timeout: timeout) == .completed
    }

    private func anyLabel(_ app: XCUIApplication, _ labels: [String]) -> XCUIElement? {
        for label in labels {
            let element = app.buttons[label]
            if element.waitForExistence(timeout: 5) { return element }
        }
        return nil
    }

    /// The reused simulator preserves many workspace groups above the Chats
    /// section. Chat rows are lazy until realized, so scroll only the native
    /// sidebar list and tap the fixed synthetic row's verified frame.
    private func revealSidebarRow(_ app: XCUIApplication,
                                  identifier: String) -> Bool {
        let sidebar = app.descendants(matching: .any)
            .matching(identifier: "sidebar.list").firstMatch
        XCTAssertTrue(sidebar.waitForExistence(timeout: 15), "sidebar list is missing")
        let row = app.descendants(matching: .any).matching(identifier: identifier).firstMatch
        func isVisible() -> Bool {
            guard row.exists else { return false }
            let frame = row.frame
            let point = CGPoint(x: frame.midX, y: frame.midY)
            return frame.width > 0 && frame.height > 0
                && point.x.isFinite && point.y.isFinite
                && sidebar.frame.contains(point) && app.windows.firstMatch.frame.contains(point)
        }
        for _ in 0..<20 where !isVisible() { sidebar.swipeUp() }
        for _ in 0..<20 where !isVisible() { sidebar.swipeDown() }
        guard isVisible() else { return false }
        let screen = app.windows.firstMatch.frame
        app.windows.firstMatch.coordinate(withNormalizedOffset: .zero)
            .withOffset(CGVector(dx: row.frame.midX - screen.minX,
                                 dy: row.frame.midY - screen.minY))
            .tap()
        return true
    }

    private func openSavedSyntheticChat(_ app: XCUIApplication) {
        XCTAssertTrue(
            revealSidebarRow(app, identifier: "sidebar.conversation.\(savedConversationID)"),
            "seeded conversation is missing")
        XCTAssertTrue(
            app.navigationBars["临时会话合成任务"].waitForExistence(timeout: 10),
            "thread did not open")
    }

    /// The schedule add entry lives on the REAL Task Center overview, not on
    /// the former launchpad duplicate. Navigate through the existing sidebar
    /// entry and never restore another add button.
    private func openTaskCenter(_ app: XCUIApplication) {
        let sidebar = app.descendants(matching: .any)
            .matching(identifier: "sidebar.list").firstMatch
        XCTAssertTrue(sidebar.waitForExistence(timeout: 15), "sidebar list is missing")
        let entry = app.descendants(matching: .any)
            .matching(identifier: "sidebar.task_center").firstMatch
        for _ in 0..<10 where !(entry.exists && entry.isHittable) { sidebar.swipeDown() }
        XCTAssertTrue(entry.waitForExistence(timeout: 10), "Task Center entry is missing")
        if entry.isHittable { entry.tap() } else {
            let screen = app.windows.firstMatch.frame
            app.windows.firstMatch.coordinate(withNormalizedOffset: .zero)
                .withOffset(CGVector(dx: entry.frame.midX - screen.minX,
                                     dy: entry.frame.midY - screen.minY))
                .tap()
        }
        XCTAssertTrue(app.buttons["home.schedule.add"].waitForExistence(timeout: 15),
                      "Task Center did not open")
    }

    /// Delete ONLY this test's synthetic plans (fixed title and the schedule
    /// row identity). User rows are never pressed or removed.
    @discardableResult
    private func deleteSyntheticPlans(_ app: XCUIApplication) -> Bool {
        if app.buttons["schedule.detail.menu"].waitForExistence(timeout: 2) {
            let cancel = anyLabel(app, ["取消", "Cancel"])
            cancel?.tap()
            let gone = XCTNSPredicateExpectation(
                predicate: NSPredicate(format: "exists == false"),
                object: app.buttons["schedule.detail.menu"])
            _ = XCTWaiter.wait(for: [gone], timeout: 5)
        }
        if !app.buttons["home.schedule.add"].waitForExistence(timeout: 2) {
            openTaskCenter(app)
        }
        var removed = false
        for _ in 0..<4 {
            let predicate = NSPredicate(
                format: "identifier BEGINSWITH %@ AND label CONTAINS %@",
                "home.schedule.row.", "UI 合成计划")
            let rows = app.buttons.matching(predicate)
            for _ in 0..<12 where rows.count == 0 { app.swipeUp() }
            if rows.count == 0 {
                for _ in 0..<12 where rows.count == 0 { app.swipeDown() }
            }
            guard rows.count > 0 else { break }
            let row = rows.element(boundBy: 0)
            row.press(forDuration: 1.2)
            guard let delete = anyLabel(app, ["删除安排", "Delete schedule"]) else { break }
            delete.tap()
            removed = true
            let gone = XCTNSPredicateExpectation(
                predicate: NSPredicate(format: "exists == false"), object: row)
            _ = XCTWaiter.wait(for: [gone], timeout: 10)
        }
        return removed
    }

    func testLongPressUserAndAssistantTextUsesSystemSelection() {
        XCUIDevice.shared.orientation = .portrait
        // Keep app actions localized as 复制 while the UIKit edit menu uses
        // 拷贝/Copy. This prevents matching the assistant's existing copy-all
        // button and mistaking it for native selection.
        let app = launch(arguments: ["--ui-test-temporary-chat-fixture", "-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN"])
        defer { app.terminate() }
        openSavedSyntheticChat(app)
        for index in [0, 1] {
            let text = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "合成历史消息-\(index)")).firstMatch
            XCTAssertTrue(text.waitForExistence(timeout: 10))
            text.press(forDuration: 1.2)
            XCTAssertFalse(app.buttons["thread.find.fromMessage"].exists,
                           "The message must not intercept native selection with a search context menu")
            let nativeCopy = NSPredicate(format: "label IN %@", ["拷贝", "Copy"])
            let menu = app.menuItems.matching(nativeCopy).firstMatch
            let button = app.buttons.matching(nativeCopy).firstMatch
            XCTAssertTrue(menu.waitForExistence(timeout: 2) || button.waitForExistence(timeout: 5),
                          "The system selection menu must offer Copy, not the assistant's copy-all action")
            let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
            attachment.name = index == 0 ? "native-user-message-selection" : "native-assistant-message-selection"
            attachment.lifetime = .keepAlways; add(attachment)
            if menu.exists { menu.tap() } else { button.tap() }
        }
    }

    func testHistoricalDateAndOneTapUserCopy() {
        XCUIDevice.shared.orientation = .portrait
        let app = launch(arguments: ["--ui-test-temporary-chat-fixture", "--ui-test-history-date-copy"])
        defer { app.terminate() }
        XCTAssertTrue(revealSidebarRow(app, identifier: "sidebar.conversation.9289330B-91EB-4617-81B2-ABA312B98801"))
        let dates = app.staticTexts.matching(NSPredicate(format: "identifier BEGINSWITH %@", "thread.message.date."))
        XCTAssertTrue(dates.firstMatch.waitForExistence(timeout: 10))
        XCTAssertEqual(dates.count, 2)
        for date in dates.allElementsBoundByIndex {
            XCTAssertTrue(date.label.contains("2022") && date.label.contains("7月") && date.label.contains("19"),
                          "Stored July 19, 2022 date missing from \(date.label)")
        }
        let button = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "thread.user.copy.")).firstMatch
        XCTAssertTrue(button.isHittable)
        button.tap()
        XCTAssertTrue(waitForLabel(button, "已复制", timeout: 2))
        let input = app.textViews["composer.input"].firstMatch
        XCTAssertTrue(input.waitForExistence(timeout: 10))
        let expected = "第一行  \n第二行"
        input.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        func removeFixturePaste() {
            let value = input.value as? String ?? ""
            guard !value.isEmpty else { return }
            guard value == expected else {
                XCTFail("Only text pasted by this test may be removed from its historical fixture")
                return
            }
            // The trailing edge of the last line places the insertion point after
            // this short two-line fixture, including when a prior run left it saved.
            input.coordinate(withNormalizedOffset: CGVector(dx: 0.93, dy: 0.86)).tap()
            input.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: expected.count))
            let empty = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", ""), object: input)
            XCTAssertEqual(XCTWaiter.wait(for: [empty], timeout: 6), .completed)
        }
        removeFixturePaste()
        tapEditingCommand(["粘贴", "Paste"], in: input, app: app)
        let pasted = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", expected), object: input)
        XCTAssertEqual(XCTWaiter.wait(for: [pasted], timeout: 6), .completed,
                       "The UIKit composer must contain the copied text with its spaces and newline intact")
        removeFixturePaste()
    }

    func testLatestMessageRemainsReachableAfterLateRowsLoad() {
        XCUIDevice.shared.orientation = .portrait
        let app = launch(arguments: ["--ui-test-native-answer-fixture", "message-burst"])
        defer { app.terminate() }

        let transcript = app.scrollViews["thread.messages.viewport"].firstMatch
        XCTAssertTrue(transcript.waitForExistence(timeout: 15))
        let latest = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "QA burst marker 95")).firstMatch
        func expectHittable(_ element: XCUIElement, timeout: TimeInterval) {
            let predicate = NSPredicate { _, _ in element.exists && element.isHittable }
            let expectation = XCTNSPredicateExpectation(predicate: predicate, object: element)
            XCTAssertEqual(XCTWaiter.wait(for: [expectation], timeout: timeout), .completed)
        }
        // The saved conversation receives 96 new rows of varying heights
        // after opening, through the same store and notification as live chat.
        expectHittable(latest, timeout: 18)

        let arrow = app.buttons["thread.jumpToLatest"].firstMatch
        for _ in 0..<3 {
            transcript.swipeDown(velocity: .fast)
            XCTAssertTrue(arrow.waitForExistence(timeout: 3), "Scrolling into history must expose the return arrow")
            XCTAssertFalse(latest.exists && latest.isHittable)
            arrow.tap()
            expectHittable(latest, timeout: 3)
            let arrived = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: arrow)
            XCTAssertEqual(XCTWaiter.wait(for: [arrived], timeout: 2), .completed,
                           "The arrow should disappear once the last message is in view")
        }
    }

    private func tapEditingCommand(_ labels: [String], in editor: XCUIElement, app: XCUIApplication) {
        editor.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).press(forDuration: 1.2)
        let match = NSPredicate(format: "label IN %@", labels)
        let item = app.menuItems.matching(match).firstMatch
        if item.waitForExistence(timeout: 2) {
            item.tap()
        } else {
            let button = app.buttons.matching(match).firstMatch
            XCTAssertTrue(button.waitForExistence(timeout: 5), "UIKit must offer " + labels[0])
            button.tap()
        }
    }

    private func clearOwnedDraft(_ editor: XCUIElement, in app: XCUIApplication) {
        if !((editor.value as? String) ?? "").isEmpty {
            tapEditingCommand(["全选", "Select All"], in: editor, app: app)
            editor.typeText(XCUIKeyboardKey.delete.rawValue)
        }
        let empty = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", ""), object: editor)
        XCTAssertEqual(XCTWaiter.wait(for: [empty], timeout: 5), .completed,
                       "The synthetic chat draft must be empty before the next edit")
    }

    func testInChatFindCountsNavigatesAndPreservesDraft() {
        let app = launch(arguments: ["--ui-test-temporary-chat-fixture"])
        openSavedSyntheticChat(app)

        // A real draft that find must not disturb.
        let composer = app.textViews["composer.input"].firstMatch
        XCTAssertTrue(composer.waitForExistence(timeout: 10))
        // Use the visible field centre. Its AX activation point is on the
        // leading edge, where a restored draft can place the caret at zero.
        composer.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        // The reused simulator persists this fixed synthetic chat's unsent
        // draft across app launches (ComposerDraftStore). An earlier
        // interrupted invocation can therefore leave the same test-owned
        // text in the slot; clear only that slot through the real editor
        // before typing this run's draft.
        clearOwnedDraft(composer, in: app)
        composer.typeText("draft-keep")

        let menu = app.buttons["thread.inspector.menu"]
        XCTAssertTrue(menu.waitForExistence(timeout: 10))
        menu.tap()
        let find = anyLabel(app, ["在对话中查找", "Find in chat"])
        XCTAssertNotNil(find, "Find in chat menu row is missing")
        find?.tap()

        let field = app.textFields["thread.find.field"].firstMatch
        // Reuse the linked-schedule test's native-menu recovery: a lost
        // synthesized tap leaves the actual menu row presented. Only then
        // activate that row once more; never bypass the real find UI.
        if !field.waitForExistence(timeout: 3),
           let find, find.exists {
            find.tap()
        }
        XCTAssertTrue(field.waitForExistence(timeout: 10))
        field.tap()
        field.typeText("历史")

        let count = app.staticTexts["thread.find.count"].firstMatch
        XCTAssertTrue(count.waitForExistence(timeout: 10))
        XCTAssertTrue(waitForLabel(count, "2/2"))

        app.buttons["thread.find.previous"].tap()
        XCTAssertTrue(waitForLabel(count, "1/2"))
        app.buttons["thread.find.next"].tap()
        XCTAssertTrue(waitForLabel(count, "2/2"))

        app.buttons["thread.find.done"].tap()
        let gone = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == false"),
            object: app.textFields["thread.find.field"])
        XCTAssertEqual(XCTWaiter.wait(for: [gone], timeout: 5), .completed)
        // Done stays at the hit: the composer still holds the untouched draft.
        XCTAssertEqual(composer.value as? String, "draft-keep")

        // Cmd+F is a second, discoverable entry.
        app.typeKey("f", modifierFlags: .command)
        XCTAssertTrue(field.waitForExistence(timeout: 10), "Cmd+F did not open find")
        app.buttons["thread.find.done"].tap()
    }

    func testScheduleDetailSkipAndCancelUseDurablePlan() {
        let app = launch(arguments: [])
        var createdPlan = false
        defer { if createdPlan { _ = deleteSyntheticPlans(app) } }
        openTaskCenter(app)
        let add = app.buttons["home.schedule.add"]
        XCTAssertTrue(add.waitForExistence(timeout: 10))
        add.tap()

        let prompt = app.textViews["home.schedule.prompt"].firstMatch
        XCTAssertTrue(prompt.waitForExistence(timeout: 10))

        // Choose the repeating cadence before typing. The sheet resizes by
        // about 128 pt when the software keyboard appears/disappears on iPad.
        // A Picker element resolved in the keyboard-up layout then receives
        // its tap at that stale activation point in the keyboard-down layout,
        // which re-focuses the prompt instead of opening the menu. Select the
        // cadence while the form is keyboard-free, and tap its trailing value.
        let cadence = app.buttons["home.schedule.cadence"]
        XCTAssertTrue(cadence.waitForExistence(timeout: 5))
        cadence.coordinate(withNormalizedOffset: CGVector(dx: 0.94, dy: 0.5)).tap()
        let daily = anyLabel(app, ["每天", "Daily"])
        XCTAssertNotNil(daily, "Daily cadence row is missing")
        daily?.tap()

        prompt.tap()
        prompt.typeText("UI 合成计划")

        let save = app.buttons["home.schedule.save"]
        XCTAssertTrue(save.waitForExistence(timeout: 5))
        save.tap()
        // Save must actually commit and dismiss its sheet before inspecting
        // the underlying list. Keep a missed native tap visible at its real
        // boundary instead of swiping a still-present form and failing later.
        let saved = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == false"), object: save)
        XCTAssertEqual(XCTWaiter.wait(for: [saved], timeout: 10), .completed,
                       "Save must finish and dismiss the schedule sheet")
        createdPlan = true

        let row = app.staticTexts["UI 合成计划"].firstMatch
        for _ in 0..<12 where !row.exists { app.swipeUp() }
        XCTAssertTrue(row.waitForExistence(timeout: 10), "created plan is not listed")
        row.tap()

        XCTAssertTrue(app.buttons["schedule.detail.menu"].waitForExistence(timeout: 10))
        // The durable prompt is shown verbatim.
        XCTAssertTrue(app.staticTexts["UI 合成计划"].exists)
        let state = app.staticTexts["schedule.detail.state"].firstMatch
        XCTAssertTrue(state.waitForExistence(timeout: 5))

        // Skip next records the occurrence without launching a task.
        app.buttons["schedule.detail.menu"].tap()
        let skip = anyLabel(app, ["跳过下一次", "Skip next"])
        XCTAssertNotNil(skip, "Skip next is missing from the action menu")
        skip?.tap()
        XCTAssertTrue(app.staticTexts["schedule.detail.notice"].waitForExistence(timeout: 10))

        // Cancel future pauses the plan and keeps it in the list/history.
        app.buttons["schedule.detail.menu"].tap()
        let cancel = anyLabel(app, ["取消后续运行", "Cancel future runs"])
        XCTAssertNotNil(cancel, "Cancel future runs is missing from the action menu")
        cancel?.tap()
        let confirm = anyLabel(app, ["取消后续运行", "Cancel future runs"])
        confirm?.tap()
        let paused = app.staticTexts["schedule.detail.state"].firstMatch
        XCTAssertTrue(paused.waitForExistence(timeout: 10))
        XCTAssertTrue(paused.label.contains("已暂停") || paused.label.contains("Paused"))

        // Owned cleanup: remove ONLY this fixed synthetic plan. A failed
        // assertion still reaches this point through defer.
        XCTAssertTrue(deleteSyntheticPlans(app),
                      "the synthetic plan must be removed from the real store")
        XCTAssertFalse(app.staticTexts["UI 合成计划"].exists,
                       "the synthetic plan must not remain listed")
    }

    func testUnlinkedChatHasNoSchedulePill() {
        let app = launch(arguments: ["--ui-test-temporary-chat-fixture"])
        openSavedSyntheticChat(app)
        // The synthetic plan in this fixture was not created from this chat,
        // so there is no trusted origin and no ledger conversation: no pill.
        XCTAssertFalse(app.buttons["thread.scheduleCapsule"].exists)
    }
}
