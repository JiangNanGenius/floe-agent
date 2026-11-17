import XCTest

@MainActor
final class CreativeConversationEntryUITests: XCTestCase {
    func testNewCanvasCanBeMovedToRecentlyDeletedFromCreativeHome() throws {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .landscapeLeft
        defer { XCUIDevice.shared.orientation = .portrait }
        let app = XCUIApplication()
        app.launchArguments += ["-ui-testing", "-ui-testing-ipad"]
        app.launch()
        let creative = app.descendants(matching: .any).matching(identifier: "sidebar.creative").firstMatch
        XCTAssertTrue(creative.waitForExistence(timeout: 10))
        if !creative.isHittable {
            let drawer = app.buttons["phone.sidebar.open"]
            XCTAssertTrue(drawer.waitForExistence(timeout: 5))
            drawer.tap()
        }
        creative.tap()
        let create = app.buttons["canvas.home.create"]
        XCTAssertTrue(create.waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["creative.folder.create"].exists)
        XCTAssertTrue(app.buttons["creative.workspace.choose"].exists)
        let rows = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "creative.canvas.personal."))
        let previous = Set(rows.allElementsBoundByIndex.map(\.identifier))
        create.tap()
        let blank = app.buttons["canvas.start.blank"]
        XCTAssertTrue(blank.waitForExistence(timeout: 10))
        blank.tap()
        let done = app.buttons["space.editor.done"]
        XCTAssertTrue(done.waitForExistence(timeout: 20))
        done.tap()
        XCTAssertTrue(create.waitForExistence(timeout: 20))

        let appeared = expectation(for: NSPredicate { _, _ in
            !Set(rows.allElementsBoundByIndex.map(\.identifier)).subtracting(previous).isEmpty
        }, evaluatedWith: nil)
        wait(for: [appeared], timeout: 20)
        let newID = try XCTUnwrap(Set(rows.allElementsBoundByIndex.map(\.identifier)).subtracting(previous).first)
        let row = app.buttons[newID]
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        row.press(forDuration: 1)
        let delete = app.buttons["creative.canvas.delete"]
        XCTAssertTrue(delete.waitForExistence(timeout: 5))
        delete.tap()
        let alert = app.alerts.firstMatch
        XCTAssertTrue(alert.waitForExistence(timeout: 5))
        let confirm = alert.buttons.matching(NSPredicate(format: "label IN %@", ["删除", "Delete"])).firstMatch
        XCTAssertTrue(confirm.exists)
        confirm.tap()
        let removed = expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: row)
        wait(for: [removed], timeout: 20)
        let progress = app.descendants(matching: .any).matching(identifier: "creative.canvas.deleting").firstMatch
        let finished = expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: progress)
        wait(for: [finished], timeout: 20)
        let deletionError = app.descendants(matching: .any).matching(identifier: "creative.canvas.delete.error").firstMatch
        if deletionError.exists { XCTFail(deletionError.label) }

        let projectID = String(newID.suffix(36))
        XCTAssertNotNil(UUID(uuidString: projectID))
        func assertInTrash() {
            let space = app.descendants(matching: .any).matching(identifier: "sidebar.notes").firstMatch
            XCTAssertTrue(space.waitForExistence(timeout: 15))
            if !space.isHittable {
                let drawer = app.buttons["phone.sidebar.open"]
                XCTAssertTrue(drawer.waitForExistence(timeout: 5))
                drawer.tap()
            }
            space.tap()
            let files = app.buttons.matching(NSPredicate(format: "label IN %@", ["文件", "Files"])).firstMatch
            XCTAssertTrue(files.waitForExistence(timeout: 10))
            files.tap()
            let more = app.buttons["space.more"]
            XCTAssertTrue(more.waitForExistence(timeout: 10))
            more.tap()
            let trash = app.buttons["space.files.recentlyDeleted"]
            XCTAssertTrue(trash.waitForExistence(timeout: 5))
            trash.tap()
            let list = app.descendants(matching: .any).matching(identifier: "space.files.trash.list").firstMatch
            XCTAssertTrue(list.waitForExistence(timeout: 10))
            let projectPath = list.staticTexts.matching(NSPredicate(format: "label CONTAINS[cd] %@", String(projectID.prefix(8)))).firstMatch
            XCTAssertTrue(projectPath.waitForExistence(timeout: 10), "The deleted canvas must be present in Trash")
        }
        // A list identity refresh can temporarily remove every row. Verify the
        // exact project in Trash before and after relaunch, so we neither kill
        // an in-flight operation nor treat a transient disappearance as a commit.
        assertInTrash()
        app.terminate()
        app.launch()
        assertInTrash()
    }

    func testCreativeStartUsesConversationAndRetainsUnsentDraft() throws {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .landscapeLeft
        let app = XCUIApplication()
        app.launchArguments += ["-ui-testing", "-ui-testing-ipad", "--ui-test-reset-creative-draft"]
        app.launch()
        let creative = app.descendants(matching: .any)
            .matching(identifier: "sidebar.creative").firstMatch
        XCTAssertTrue(creative.waitForExistence(timeout: 10))
        if !creative.isHittable {
            let drawer = app.buttons["phone.sidebar.open"]
            XCTAssertTrue(drawer.waitForExistence(timeout: 5))
            drawer.tap()
        }
        creative.tap()
        let start = app.buttons["canvas.home.design"]
        XCTAssertTrue(start.waitForExistence(timeout: 8))
        start.tap()
        let input = app.textViews["composer.input"]
        XCTAssertTrue(input.waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["design.owner.creativeStart"].exists)
        XCTAssertFalse(app.buttons["canvas.home.design.presentation"].exists)
        let prompt = "Create a presentation with editable charts"
        input.tap()
        let old = input.value as? String ?? ""
        if !old.isEmpty { input.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: old.count)) }
        input.typeText(prompt)
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "Creative natural-language start"
        attachment.lifetime = .keepAlways
        add(attachment)
        // No send: this UI acceptance must never trigger a paid model call.
        app.terminate()
        // Relaunch WITHOUT the draft-reset flag: retention is the assertion.
        let relaunched = XCUIApplication()
        relaunched.launchArguments += ["-ui-testing", "-ui-testing-ipad"]
        relaunched.launch()
        let reopened = relaunched.descendants(matching: .any).matching(identifier: "sidebar.creative").firstMatch
        XCTAssertTrue(reopened.waitForExistence(timeout: 10))
        if !reopened.isHittable {
            let drawer = relaunched.buttons["phone.sidebar.open"]
            XCTAssertTrue(drawer.waitForExistence(timeout: 5))
            drawer.tap()
        }
        reopened.tap()
        let restarted = relaunched.buttons["canvas.home.design"]
        XCTAssertTrue(restarted.waitForExistence(timeout: 8))
        restarted.tap()
        let retainedInput = relaunched.textViews["composer.input"]
        XCTAssertTrue(retainedInput.waitForExistence(timeout: 10))
        XCTAssertEqual(retainedInput.value as? String, prompt)
    }
}
