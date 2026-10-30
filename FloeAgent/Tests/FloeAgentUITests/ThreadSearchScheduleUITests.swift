// FloeAgentUITests — in-chat find and visible scheduled-task UI acceptance.
//
// SYNTHETIC ONLY: the find test launches the existing DEBUG-only
// TemporaryChatUITestFixture (a fixed saved conversation with two synthetic
// messages, no paid model request). The schedule test creates a durable plan
// through the real Home sheet and exercises skip/cancel, which never launch a
// model task. No user data is read or written and no physical device is used.
//
// These tests are authored for the primary integration run. They depend on the
// app's `-ui-testing` launch path and the existing fixture flag; they create no
// new fixture of their own.

import XCTest

@MainActor
final class ThreadSearchScheduleUITests: XCTestCase {
    private let savedConversationID = "7A1E22C4-3B0F-4A5D-9E62-1C8F3D5B7A21"

    private func launch(arguments: [String]) -> XCUIApplication {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments += ["-ui-testing"] + arguments
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

    private func openSavedSyntheticChat(_ app: XCUIApplication) {
        let row = app.buttons["sidebar.conversation.\(savedConversationID)"]
        if !row.waitForExistence(timeout: 10) {
            // The sidebar may group rows as static text on some layouts.
            let text = app.staticTexts["临时会话合成任务"]
            XCTAssertTrue(text.waitForExistence(timeout: 10), "seeded conversation is missing")
            text.tap()
        } else {
            row.tap()
        }
        XCTAssertTrue(
            app.staticTexts["临时会话合成任务"].waitForExistence(timeout: 10),
            "thread did not open")
    }

    func testInChatFindCountsNavigatesAndPreservesDraft() {
        let app = launch(arguments: ["--ui-test-temporary-chat-fixture"])
        openSavedSyntheticChat(app)

        // A real draft that find must not disturb.
        let composer = app.textViews["composer.input"].firstMatch
        XCTAssertTrue(composer.waitForExistence(timeout: 10))
        composer.tap()
        composer.typeText("draft-keep")

        let menu = app.buttons["thread.inspector.menu"]
        XCTAssertTrue(menu.waitForExistence(timeout: 10))
        menu.tap()
        let find = anyLabel(app, ["在对话中查找", "Find in chat"])
        XCTAssertNotNil(find, "Find in chat menu row is missing")
        find?.tap()

        let field = app.textFields["thread.find.field"].firstMatch
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
        let add = app.buttons["home.schedule.add"]
        XCTAssertTrue(add.waitForExistence(timeout: 10))
        add.tap()

        let prompt = app.textViews["home.schedule.prompt"].firstMatch
        XCTAssertTrue(prompt.waitForExistence(timeout: 10))
        prompt.tap()
        prompt.typeText("UI 合成计划")

        // A repeating plan so Skip next keeps it enabled and Cancel future is
        // still available afterwards. The picker shows the current value.
        let cadence = app.buttons["home.schedule.cadence"]
        XCTAssertTrue(cadence.waitForExistence(timeout: 5))
        cadence.tap()
        let daily = anyLabel(app, ["每天", "Daily"])
        XCTAssertNotNil(daily, "Daily cadence row is missing")
        daily?.tap()

        let save = app.buttons["home.schedule.save"]
        XCTAssertTrue(save.waitForExistence(timeout: 5))
        save.tap()

        let row = app.staticTexts["UI 合成计划"].firstMatch
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
    }

    func testUnlinkedChatHasNoSchedulePill() {
        let app = launch(arguments: ["--ui-test-temporary-chat-fixture"])
        openSavedSyntheticChat(app)
        // The synthetic plan in this fixture was not created from this chat,
        // so there is no trusted origin and no ledger conversation: no pill.
        XCTAssertFalse(app.buttons["thread.scheduleCapsule"].exists)
    }
}
