import XCTest

@MainActor
final class ComposerOverflowUITests: XCTestCase {
    func testSoftWrappedDraftExpandsWithoutLosingText() throws {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchArguments = ["-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN",
                               "-ui-testing", "-ui-testing-ipad", "--ui-test-skip-onboarding",
                               "--ui-test-task-management-fixture"]
        app.launch()
        defer { app.terminate() }

        // Only the fixed, synthetic task is edited. Never replace a user's
        // current draft, send a request or change a configured provider.
        let row = app.descendants(matching: .any)
            .matching(identifier: "sidebar.conversation.A1D4A0F2-6F2E-4E7A-9C31-0B7C51E6A003").firstMatch
        // The reused simulator preserves many workspace groups above the
        // Chats section and chat rows stay lazy until the sidebar scrolls
        // them into the realized window. Scroll only the sidebar list —
        // never workspace or user data — until the seeded fixture row is
        // visible. iOS 27 may report no AX activation point for a visible
        // drawer row; use its verified frame, as TemporaryConversation does.
        let sidebar = app.descendants(matching: .any)
            .matching(identifier: "sidebar.list").firstMatch
        XCTAssertTrue(sidebar.waitForExistence(timeout: 10))
        func rowIsVisible() -> Bool {
            guard row.exists else { return false }
            let frame = row.frame
            let point = CGPoint(x: frame.midX, y: frame.midY)
            return frame.width > 0 && frame.height > 0
                && point.x.isFinite && point.y.isFinite
                && sidebar.frame.contains(point) && app.windows.firstMatch.frame.contains(point)
        }
        for _ in 0..<20 where !rowIsVisible() { sidebar.swipeUp() }
        for _ in 0..<20 where !rowIsVisible() { sidebar.swipeDown() }
        XCTAssertTrue(rowIsVisible(),
                      "the seeded synthetic conversation must be reachable in the sidebar")
        let screen = app.windows.firstMatch.frame
        app.windows.firstMatch.coordinate(withNormalizedOffset: .zero)
            .withOffset(CGVector(dx: row.frame.midX - screen.minX, dy: row.frame.midY - screen.minY))
            .tap()
        XCTAssertTrue(app.navigationBars["任务管理测试-C"].waitForExistence(timeout: 10),
                      "Only the synthetic conversation may receive the test draft")
        let input = app.textViews["composer.input"]
        XCTAssertTrue(input.waitForExistence(timeout: 20))
        let text = String(repeating: "Soft wrapping must keep this complete sentence inside the composer. ", count: 16)
            + "https://example.invalid/" + String(repeating: "a", count: 220)
        input.tap()
        let previous = input.value as? String ?? ""
        if previous != text {
            if !previous.isEmpty {
                input.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: previous.count))
            }
            input.typeText(text)
        }
        let expand = app.buttons["composer.expand"]
        XCTAssertTrue(expand.waitForExistence(timeout: 15), "A genuinely overflowing soft-wrapped draft exposes Expand")
        // Direct editable-width evidence on the real viewport: the field owns
        // the row's usable width and the natural controls sit below it, not in
        // a ~100pt column beside the text.
        assertFieldOwnsComposerRow(app: app, input: input, rowIdentifier: "composer.row")
        let inline = XCTAttachment(screenshot: app.screenshot())
        inline.name = "Composer soft-wrapped overflow"
        inline.lifetime = .keepAlways
        add(inline)

        expand.tap()
        let editor = app.textViews["composer.editor.input"]
        XCTAssertTrue(editor.waitForExistence(timeout: 10))
        XCTAssertEqual(editor.value as? String, text, "Expanding must retain the whole draft")
        let expanded = XCTAttachment(screenshot: app.screenshot())
        expanded.name = "Composer full editor complete draft"
        expanded.lifetime = .keepAlways
        add(expanded)
        app.buttons["composer.editor.done"].tap()
        XCTAssertTrue(input.waitForExistence(timeout: 10))
        XCTAssertEqual(input.value as? String, text, "Closing the editor retains the same draft")
    }

    /// The shipped-build failure this round repairs: a long ONE-LINE mixed
    /// Chinese/Latin draft typed into the real New Task launchpad composer
    /// (HomeLaunchpadView → ThreadComposerView → ComposerReturnField, in
    /// the bottom `safeAreaInset` band) neither wrapped nor revealed
    /// Expand. This drives that exact production surface and width — not
    /// the thread fixture above, which passed before the repair.
    func testNewTaskLaunchpadComposerWrapsGrowsAndExpands() throws {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchArguments = ["-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN",
                               "-ui-testing", "-ui-testing-ipad", "--ui-test-skip-onboarding",
                               "--ui-test-task-management-fixture", "--ui-test-home-composer"]
        app.launch()
        defer { app.terminate() }

        let input = app.textViews["composer.input"]
        let homeToggle = app.buttons["home.temporary.toggle"]
        // Home's toolbar marker distinguishes the canonical New Task
        // launchpad from any thread that a previous session may have left
        // selected. Reach it explicitly when it is not already shown.
        if !(input.waitForExistence(timeout: 8) && homeToggle.waitForExistence(timeout: 1)) {
            let sidebar = app.descendants(matching: .any)
                .matching(identifier: "sidebar.list").firstMatch
            XCTAssertTrue(sidebar.waitForExistence(timeout: 10))
            let newTask = app.descendants(matching: .any)
                .matching(identifier: "sidebar.workbench.new_task").firstMatch
            for _ in 0..<10 where !newTask.isHittable { sidebar.swipeDown() }
            XCTAssertTrue(newTask.waitForExistence(timeout: 10),
                          "New Task must be reachable from the sidebar")
            newTask.tap()
        }
        XCTAssertTrue(input.waitForExistence(timeout: 15),
                      "The New Task composer must be on screen")
        XCTAssertTrue(homeToggle.exists,
                      "Acceptance is on the Home launchpad, never an existing thread")

        let restHeight = input.frame.height
        XCTAssertLessThan(restHeight, 120, "An empty launchpad composer rests near one line")

        // One logical line mixing CJK, spaced Latin and an unbroken URL —
        // the actual screenshot shape. Nothing is sent; send stays
        // hardware Cmd+Return-only.
        let mixed = String(
            repeating: "新建任务里这段中文mixed with English plus an unbroken https://example.invalid/",
            count: 24)
        input.tap()
        input.typeText(mixed)

        // 1. Dynamic growth: wrapping at the ROW'S ACTUAL width must grow
        //    the field past its resting line, through the shared budget.
        var grew = false
        for _ in 0..<40 {
            if input.frame.height > restHeight + 8 { grew = true; break }
            RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        }
        XCTAssertTrue(grew,
                      "A one-line mixed draft must wrap and grow the composer at the real row width")

        // 2. Beyond the collapsed visible area the Expand control appears
        //    at the cap (one third of the page, ≤ 8 lines).
        let expand = app.buttons["composer.expand"]
        XCTAssertTrue(expand.waitForExistence(timeout: 15),
                      "The launchpad composer must expose Expand once the draft passes its cap")
        XCTAssertLessThanOrEqual(input.frame.height, 400,
                                "Growth stays inside the composer height budget, then scrolls")

        // 2b. Direct editable-width evidence at the rejected layout: the
        //     shipped screenshot squeezed the text into ~100pt beside five
        //     44pt controls. The live field must now own the row's usable
        //     width and the controls must reflow below it.
        assertFieldOwnsComposerRow(app: app, input: input, rowIdentifier: "composer.row")
        XCTAssertGreaterThanOrEqual(input.frame.width, 240,
                                    "the launchpad's editable column must be practical, not a squeeze")
        let stacked = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        stacked.name = "New Task composer: field owns the row, controls below (device screenshot)"
        stacked.lifetime = .keepAlways
        add(stacked)

        // 3. The single logical line was never mutated by layout.
        XCTAssertEqual(input.value as? String, mixed,
                       "Wrapping and growth must not alter the draft")

        // 4. Expand preserves the whole draft; collapse retains it too.
        expand.tap()
        let editor = app.textViews["composer.editor.input"]
        XCTAssertTrue(editor.waitForExistence(timeout: 10))
        XCTAssertEqual(editor.value as? String, mixed, "Expanding retains the whole draft")
        let expandedShot = XCTAttachment(screenshot: app.screenshot())
        expandedShot.name = "New Task full editor complete draft"
        expandedShot.lifetime = .keepAlways
        add(expandedShot)
        app.buttons["composer.editor.done"].tap()
        XCTAssertTrue(input.waitForExistence(timeout: 10))
        XCTAssertEqual(input.value as? String, mixed, "Closing the editor retains the same draft")

        // 5. The preserved send policy: Return inserts a newline, never
        //    sends, on the launchpad surface too.
        input.tap()
        input.typeText(XCUIKeyboardKey.return.rawValue + "第二行")
        let after = input.value as? String ?? ""
        XCTAssertTrue(after.contains("\n第二行"), "Return must insert a newline, never send")
        XCTAssertTrue(input.exists, "Typing or Return on the launchpad composer sends nothing")
        let finalShot = XCTAttachment(screenshot: app.screenshot())
        finalShot.name = "New Task composer wrapped with newline"
        finalShot.lifetime = .keepAlways
        add(finalShot)
    }

    /// Direct measurement against the live host: the editable field must own
    /// (essentially) the whole composer row at a constrained width, and the
    /// natural controls must sit below the multiline field instead of beside
    /// it. The row's own accessibility frame is the width the real composer
    /// actually gives the field — a measured relation, not a screenshot
    /// guess and not a re-stated arithmetic.
    private func assertFieldOwnsComposerRow(
        app: XCUIApplication,
        input: XCUIElement,
        rowIdentifier: String
    ) {
        let row = app.descendants(matching: .any).matching(identifier: rowIdentifier).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 10),
                      "the composer row must expose its live width")
        XCTAssertGreaterThan(row.frame.width, 200, "the composer row must be measured on screen")
        XCTAssertGreaterThanOrEqual(input.frame.width / row.frame.width, 0.90,
            "the editable field must own the row's usable width, not a fraction beside the controls")
        XCTAssertGreaterThanOrEqual(input.frame.width, 200,
            "the editable text column must stay above the shared practical minimum")
        let send = app.buttons["composer.send"]
        XCTAssertTrue(send.exists)
        XCTAssertGreaterThanOrEqual(send.frame.minY, input.frame.maxY - 1,
            "natural controls must reflow below the multiline field")
    }
}
