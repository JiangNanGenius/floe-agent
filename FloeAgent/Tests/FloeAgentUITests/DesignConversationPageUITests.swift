// FloeAgentUITests — Preview-first design conversation page acceptance.
//
// Drives the REAL app against the named synthetic fixtures seeded through
// the real stores (`--ui-test-design-workflow-fixture`): the current/
// candidate lens, the real family previews (web engine for the HTML
// fixture, system Quick Look for the DOCX fixture), the explicit candidate
// decision bar, the collapsed details inspector with draft retention, the
// unsent chat draft surviving fullscreen open/close, and the compact/wide
// rotation behavior. No provider network is required — the fixtures carry
// real revisions and a real pending candidate.
//
// Accessibility note: inside the page, native representables and merged
// containers absorb some container identifiers, so content proofs use
// user-visible labels (locale-stable in this test) plus the identifiers
// that demonstrably surface (buttons, text fields, the page root).

import XCTest
import notify

@MainActor
final class DesignConversationPageUITests: XCTestCase {
    private let modifyRowID = "sidebar.conversation.D3516001-7A21-4F03-9C5A-71D8E0B4F101"
    private let officeRowID = "sidebar.conversation.D3516001-7A21-4F03-9C5A-71D8E0B4F104"
    private let browserRowID = "sidebar.conversation.D3516001-7A21-4F03-9C5A-71D8E0B4F105"

    private func launchApp(_ app: XCUIApplication) {
        app.launchArguments += [
            "-ui-testing", "-ui-testing-ipad",
            "--ui-test-skip-onboarding",
            "--ui-test-design-workflow-fixture",
        ]
        app.launch()
    }

    private func openFixture(_ app: XCUIApplication, rowID: String, title: String) throws {
        // Launch can idle on storage.preparing while the offline WebKit fixture is seeded.
        let sidebar = app.descendants(matching: .any).matching(identifier: "sidebar.list").firstMatch
        let openLabels = ["Show Sidebar", "显示边栏", "显示侧边栏"]
        let ready = app.descendants(matching: .any).matching(NSPredicate(
            format: "identifier IN %@ OR label IN %@", ["sidebar.list", "phone.sidebar.open"], openLabels)).firstMatch
        guard ready.waitForExistence(timeout: 60) else {
            XCTFail("The task sidebar did not finish opening after bootstrap.\n\(app.debugDescription)")
            return
        }
        let window = app.windows.firstMatch
        let open = app.buttons.matching(NSPredicate(
            format: "identifier == %@ OR label IN %@", "phone.sidebar.open", openLabels)).firstMatch
        if (!sidebar.exists || !sidebar.frame.intersects(window.frame) || !sidebar.isHittable),
           open.exists && open.isHittable { open.tap() }
        guard sidebar.waitForExistence(timeout: 10), sidebar.frame.intersects(window.frame) else {
            XCTFail("The named task sidebar is not visible.\n\(app.debugDescription)")
            return
        }
        let bar = app.navigationBars.containing(.button, identifier: "globalSearch.open").firstMatch
        guard bar.waitForExistence(timeout: 8) else {
            XCTFail("The task sidebar is missing its navigation bar.")
            return
        }
        // The list extends under the navigation bar. A realized row there
        // can have a valid frame while its center hits the bar instead.
        let bounds = sidebar.frame.intersection(window.frame)
        let top = max(bounds.minY, bar.frame.maxY) + 8
        let bottom = bounds.maxY - 8
        let cell = sidebar.cells.containing(.any, identifier: rowID).firstMatch
        func readyToTap() -> Bool {
            guard cell.exists else { return false }
            let frame = cell.frame
            return !frame.isEmpty && frame.minY >= top && frame.maxY <= bottom
                && bounds.contains(CGPoint(x: frame.midX, y: frame.midY)) && cell.isHittable
        }
        // Controlled, overlapping drags keep a partly covered row in range
        // and stop deceleration before XCTest resolves the cell's hit point.
        let upper = sidebar.coordinate(withNormalizedOffset: CGVector(dx: 0.48, dy: 0.37))
        let lower = sidebar.coordinate(withNormalizedOffset: CGVector(dx: 0.48, dy: 0.76))
        for searchDown in [true, false] {
            for _ in 0..<20 {
                if readyToTap() { break }
                let moveDown = cell.exists ? cell.frame.midY > (top + bottom) / 2 : searchDown
                let start = moveDown ? lower : upper
                let end = moveDown ? upper : lower
                start.press(forDuration: 0.05, thenDragTo: end, withVelocity: .slow, thenHoldForDuration: 0.15)
            }
            if readyToTap() { break }
        }
        guard readyToTap() else {
            XCTFail("The sidebar has no tappable cell for the fixture task \(title).\n\(app.debugDescription)")
            return
        }
        cell.tap()
        XCTAssertTrue(app.navigationBars[title].firstMatch.waitForExistence(timeout: 10),
                      "The selected task must be \(title) before a draft is edited.")
    }

    private func pageElement(_ app: XCUIApplication) -> XCUIElement {
        // Page presence is proven by its controls: the lens bar is always
        // mounted in both layouts (the page carries no container identifier
        // at the root level — one there would override descendants).
        app.buttons["design.page.lens.current"]
    }

    private func openDesignPage(_ app: XCUIApplication) {
        // The entry-state refresh re-renders the toolbar: query fresh at
        // each step (cached elements invalidate across the rebuild).
        if !app.buttons["thread.designPage"].waitForExistence(timeout: 12) {
            print("DEBUG NOPAGE:\n\(app.debugDescription)")
        }
        XCTAssertTrue(app.buttons["thread.designPage"].exists)
        app.buttons["thread.designPage"].tap()
        if !pageElement(app).waitForExistence(timeout: 12) {
            print("DEBUG OPENPAGE HIERARCHY:\n\(app.debugDescription)")
        }
        XCTAssertTrue(pageElement(app).exists)
    }

    /// The page may spontaneously dismiss right after presentation when the
    /// hosting thread's live toolbar re-renders behind the iPad popover
    /// (a known SwiftUI popover-anchor quirk). Re-open until the page
    /// sticks; every real user interaction below keeps it alive.
    private func ensurePageOpen(_ app: XCUIApplication) {
        var attempts = 0
        // The root full-screen cover presentation is stable (the old
        // popover anchor is gone); re-open only when the page is not up.
        while !pageElement(app).exists && attempts < 4 {
            let button = app.buttons["thread.designPage"]
            if button.exists { button.tap() }
            _ = pageElement(app).waitForExistence(timeout: 4)
            attempts += 1
        }
        if !pageElement(app).exists {
            print("DEBUG NOPAGE AFTER TAPS:\n\(app.debugDescription)")
        }
        XCTAssertTrue(pageElement(app).exists)
    }

    private func openModifyFixture(_ app: XCUIApplication) throws {
        try openFixture(app, rowID: modifyRowID, title: "设计验收-网页修改")
    }

    private func liveButton(_ app: XCUIApplication, _ identifier: String, labels: [String]) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "identifier == %@ OR label IN %@", identifier, labels)).firstMatch
    }

    private func liveImage(_ app: XCUIApplication) -> XCUIElement {
        app.images.matching(identifier: "browser.live.image").firstMatch
    }

    @discardableResult
    private func assertReadOnlyPage(_ app: XCUIApplication) -> XCUIElement {
        let viewer = app.descendants(matching: .any).matching(identifier: "browser.live.zoom").firstMatch
        XCTAssertTrue(viewer.waitForExistence(timeout: 10))
        XCTAssertTrue(viewer.images.matching(identifier: "browser.live.page").firstMatch.waitForExistence(timeout: 10))
        XCTAssertFalse(viewer.images.matching(identifier: "browser.live.image").firstMatch.exists)
        XCTAssertFalse(app.webViews.buttons["30°"].firstMatch.exists)
        return viewer
    }

    private func assertWatchingPresentation(_ app: XCUIApplication, expanded: Bool = false) {
        if expanded {
            assertReadOnlyPage(app)
        } else if #available(iOS 27.0, *) {
            XCTAssertTrue(liveImage(app).waitForExistence(timeout: 10))
        } else {
            XCTAssertFalse(liveImage(app).exists)
            XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label IN %@",
                ["AI 正在操作网页", "AI is using the page"])).firstMatch.waitForExistence(timeout: 8))
        }
    }

    private func exerciseSpectatorZoom(_ app: XCUIApplication) throws {
        let viewer = app.descendants(matching: .any).matching(identifier: "browser.live.zoom").firstMatch
        XCTAssertTrue(viewer.waitForExistence(timeout: 10))
        let fitted = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", "100%"), object: viewer)
        XCTAssertEqual(XCTWaiter.wait(for: [fitted], timeout: 6), .completed)
        let page = viewer.images.matching(identifier: "browser.live.page").firstMatch
        let original = page.frame.size
        XCTAssertGreaterThan(original.width, 0)
        XCTAssertGreaterThan(original.height, 0)
        viewer.tap()
        viewer.pinch(withScale: 5, velocity: 3)
        let zoomed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value != %@", "100%"), object: viewer)
        XCTAssertEqual(XCTWaiter.wait(for: [zoomed], timeout: 6), .completed)
        let value = try XCTUnwrap(viewer.value as? String)
        XCTAssertTrue(value.hasSuffix("%"))
        XCTAssertGreaterThan(try XCTUnwrap(Int(value.dropLast())), 120)
        XCTAssertTrue(page.frame.width > original.width * 1.2 || page.frame.height > original.height * 1.2,
                      "The underlying read-only page must visibly enlarge with the outer viewer.")
        viewer.swipeUp()
        XCTAssertFalse(app.textFields["browser.address"].exists)
    }

    private struct PageSize: Decodable {
        let page: String
        let viewport: [Int]
    }

    private struct HeldPage: Decodable {
        let page: String
        let start: [Int]
        let end: [Int]
        let startScroll: [Int]
        let endScroll: [Int]
        let viewportChanges: Int
        let scrollChanges: Int
        let inputEvents: Int
    }

    private func pageRecord<T: Decodable>(_ type: T.Type, prefix: String, in web: XCUIElement) throws -> T {
        let element = web.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", prefix)).firstMatch
        XCTAssertTrue(element.waitForExistence(timeout: 8), "The original page did not display \(prefix).")
        return try JSONDecoder().decode(type, from: Data(element.label.dropFirst(prefix.count).utf8))
    }

    private func assertHeldPage(_ web: XCUIElement) throws -> PageSize {
        let recorded = try pageRecord(HeldPage.self, prefix: "Held page ", in: web)
        let live = try pageRecord(PageSize.self, prefix: "Current page ", in: web)
        XCTAssertFalse(recorded.page.isEmpty)
        XCTAssertEqual(live.page, recorded.page)
        XCTAssertEqual(recorded.start.count, 7)
        XCTAssertTrue(recorded.start.allSatisfy { $0 > 0 })
        XCTAssertEqual(recorded.end, recorded.start)
        XCTAssertEqual(recorded.viewportChanges, 0)
        XCTAssertEqual(recorded.startScroll.count, 2)
        XCTAssertEqual(recorded.endScroll, recorded.startScroll)
        XCTAssertEqual(recorded.scrollChanges, 0)
        XCTAssertEqual(recorded.inputEvents, 0)
        XCTAssertEqual(live.viewport.count, 7)
        return live
    }

    func testBrowserPreviewInChatAndFileInspectorPreservesDraftAndExplicitTakeover() throws {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .landscapeLeft
        let app = XCUIApplication()
        app.launchArguments += ["--ui-test-live-browser-preview", "--ui-test-live-browser-request"]
        launchApp(app)
        defer { app.terminate() }
        try openFixture(app, rowID: browserRowID, title: "浏览器旁观验收")
        let composer = app.textViews["composer.input"].firstMatch
        XCTAssertTrue(composer.waitForExistence(timeout: 15))
        let marker = "live-preview-reading-draft"
        if (composer.value as? String)?.contains(marker) != true {
            composer.tap()
            composer.typeText(marker)
        }
        let draft = try XCTUnwrap(composer.value as? String)
        XCTAssertTrue(draft.contains(marker))
        let watch = liveButton(app, "browser.live.watch", labels: ["放大观看", "Enlarge preview"])
        XCTAssertTrue(watch.waitForExistence(timeout: 15))
        watch.tap()
        assertWatchingPresentation(app, expanded: true)
        try exerciseSpectatorZoom(app)
        liveButton(app, "browser.live.back", labels: ["返回", "Back"]).tap()
        XCTAssertEqual(composer.value as? String ?? "", draft)

        composer.tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 8))
        app.buttons["thread.inspector.menu"].firstMatch.tap()
        app.buttons["thread.inspector.open.workspaceFiles"].firstMatch.tap()
        let closeInspector = app.buttons["inspector.collapse"].firstMatch
        XCTAssertTrue(closeInspector.waitForExistence(timeout: 10))
        let keyboard = app.keyboards.firstMatch
        XCTAssertTrue(keyboard.exists)
        XCTAssertGreaterThan(keyboard.frame.height, 100)
        let composerYWithKeyboard = composer.frame.minY
        XCTAssertTrue(watch.isHittable)
        XCTAssertTrue(liveButton(app, "browser.live.takeover", labels: ["我来操作", "Take over"]).isHittable)
        XCTAssertTrue(liveImage(app).waitForNonExistence(timeout: 6))
        let filename = "Browser-preview-reading.md"
        let file = app.buttons.matching(NSPredicate(format: "label == %@ OR identifier == %@", filename, "fileTree.row." + filename)).firstMatch
        if !file.waitForExistence(timeout: 2) {
            let backToFiles = app.buttons.matching(NSPredicate(format: "identifier == %@ OR label IN %@",
                "fileInspector.back", ["Back", "返回"])).firstMatch
            XCTAssertTrue(backToFiles.waitForExistence(timeout: 8))
            backToFiles.tap()
        }
        XCTAssertTrue(file.waitForExistence(timeout: 8))
        let fileList = app.collectionViews.containing(.button, identifier: "fileTree.row." + filename).firstMatch
        XCTAssertGreaterThanOrEqual(fileList.frame.height, 44, "The file list needs a real row while the keyboard is up.")
        XCTAssertTrue(file.isHittable)
        file.tap()
        let headings = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "Reading position "))
        XCTAssertTrue(headings.firstMatch.waitForExistence(timeout: 10))
        if app.keyboards.firstMatch.exists {
            let hideKeyboard = app.keyboards.buttons.matching(NSPredicate(
                format: "label IN %@", ["隐藏键盘", "Hide Keyboard", "Hide keyboard"])).firstMatch
            XCTAssertTrue(hideKeyboard.waitForExistence(timeout: 6))
            hideKeyboard.tap()
        }
        assertWatchingPresentation(app)
        XCTAssertFalse(keyboard.exists)
        XCTAssertGreaterThan(composer.frame.minY - composerYWithKeyboard, 60)
        let reader = app.scrollViews.containing(NSPredicate(format: "label BEGINSWITH %@", "Reading position ")).firstMatch
        XCTAssertTrue(reader.waitForExistence(timeout: 8))
        reader.swipeUp()
        let anchor = try XCTUnwrap(headings.allElementsBoundByIndex.first(where: {
            $0.isHittable && $0.frame.midY > reader.frame.minY + 30 && $0.frame.midY < reader.frame.midY
        }))
        let heading = anchor.label
        let sourceY = anchor.frame.midY
        XCTAssertNotEqual(heading, "Reading position 1")
        XCTAssertEqual(notify_post("org.floeagent.uitest.browser-preview.request"), UInt32(NOTIFY_STATUS_OK))
        let request = app.staticTexts.matching(NSPredicate(format: "label IN %@", ["浏览器需要你操作", "The browser needs your input"])).firstMatch
        XCTAssertTrue(request.waitForExistence(timeout: 8))
        XCTAssertTrue(liveImage(app).waitForNonExistence(timeout: 8))
        XCTAssertTrue(app.staticTexts[heading].isHittable)
        XCTAssertEqual(app.staticTexts[heading].frame.midY, sourceY, accuracy: 12)
        XCTAssertFalse(app.textFields["browser.address"].exists)
        let takeOver = liveButton(app, "browser.live.takeover", labels: ["去操作", "Open browser"])
        takeOver.tap()
        XCTAssertTrue(app.textFields["browser.address"].firstMatch.waitForExistence(timeout: 10))
        let web = app.webViews.containing(.staticText, identifier: "Angles in geometry").firstMatch
        XCTAssertTrue(web.waitForExistence(timeout: 8))
        XCTAssertTrue(app.images.matching(identifier: "browser.live.page").firstMatch.waitForNonExistence(timeout: 8))
        XCTAssertTrue(web.buttons["30°"].isHittable)
        XCTAssertFalse(liveImage(app).exists)
        let original = try assertHeldPage(web)
        web.buttons["Open worksheet"].tap()
        let note = web.textFields["Angle note"].firstMatch
        XCTAssertTrue(note.waitForExistence(timeout: 8))
        note.tap()
        XCTAssertTrue(keyboard.waitForExistence(timeout: 8), "The original page's note field must receive the software keyboard.")
        XCTAssertTrue(app.buttons["browser.live.back"].isHittable, "Opening the web keyboard must keep the takeover sheet on screen.")
        XCTAssertTrue(app.textFields["browser.address"].exists)
        let noteText = "thirty degrees"
        note.typeText(noteText)
        let completeInput = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", noteText), object: note)
        XCTAssertEqual(XCTWaiter.wait(for: [completeInput], timeout: 8), .completed,
                       "The original web input must contain the full note before it is submitted.")
        let save = web.buttons["Save note"].firstMatch
        XCTAssertTrue(save.isHittable)
        save.tap()
        XCTAssertTrue(web.staticTexts["Saved note: " + noteText].firstMatch.waitForExistence(timeout: 8))
        let nativeBack = app.buttons["browser.back"].firstMatch
        XCTAssertTrue(nativeBack.waitForExistence(timeout: 8))
        let canGoBack = XCTNSPredicateExpectation(predicate: NSPredicate { item, _ in
            (item as? XCUIElement)?.isEnabled == true
        }, object: nativeBack)
        XCTAssertEqual(XCTWaiter.wait(for: [canGoBack], timeout: 8), .completed,
                       "WebKit must have a real history entry for the guide before returning to it.")
        web.buttons["Previous page"].tap()
        XCTAssertTrue(web.buttons["Open worksheet"].firstMatch.waitForExistence(timeout: 8))
        web.buttons["Open worksheet"].tap()
        XCTAssertEqual(note.value as? String, noteText)
        XCTAssertEqual(try pageRecord(PageSize.self, prefix: "Current page ", in: web).page, original.page)
        let closeOnly = app.buttons.matching(identifier: "browser.live.back").firstMatch
        XCTAssertTrue(["仅收起", "Close for now"].contains(closeOnly.label))
        closeOnly.tap()
        XCTAssertTrue(closeInspector.waitForExistence(timeout: 8))
        XCTAssertTrue(app.staticTexts[heading].isHittable)
        XCTAssertEqual(app.staticTexts[heading].frame.midY, sourceY, accuracy: 12)
        XCTAssertFalse(liveImage(app).exists)
        XCTAssertTrue(liveButton(app, "browser.live.takeover", labels: ["去操作", "Open browser"]).exists)
        XCTAssertEqual(composer.value as? String ?? "", draft)
        XCTAssertTrue(app.buttons["browser.live.return"].isHittable)
        takeOver.tap()
        XCTAssertTrue(note.waitForExistence(timeout: 8))
        XCTAssertEqual(note.value as? String, noteText)
        let handback = app.buttons.matching(identifier: "browser.handoff.return").firstMatch
        XCTAssertTrue(handback.isHittable)
        handback.tap()
        XCTAssertTrue(app.textFields["browser.address"].firstMatch.waitForNonExistence(timeout: 10))
        XCTAssertTrue(app.buttons["browser.live.return"].firstMatch.waitForNonExistence(timeout: 8))
        // This offline fixture has no running task. Recovery belongs to the original task.
        let taskStatus = app.staticTexts.matching(identifier: "browser.handoff.taskStatus").firstMatch
        XCTAssertTrue(taskStatus.waitForExistence(timeout: 8))
        XCTAssertTrue(taskStatus.label.contains("原任务未运行") || taskStatus.label.contains("not running"))
        XCTAssertTrue(taskStatus.label.contains("返回原任务查看") || taskStatus.label.contains("Check the original task"))
        XCTAssertFalse(app.buttons.matching(NSPredicate(format: "label IN %@", ["继续原任务", "Continue original task"])).firstMatch.exists)
        XCTAssertTrue(app.staticTexts[heading].isHittable)
        XCTAssertEqual(app.staticTexts[heading].frame.midY, sourceY, accuracy: 12)
        XCTAssertEqual(composer.value as? String ?? "", draft)
        closeInspector.tap()
        XCTAssertTrue(closeInspector.waitForNonExistence(timeout: 8))
    }

    func testQuietReadingOffersHandbackWhileKeepingUserControl() throws {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .landscapeLeft
        let app = XCUIApplication()
        app.launchArguments.append("--ui-test-live-browser-preview")
        launchApp(app)
        defer { app.terminate() }
        try openFixture(app, rowID: browserRowID, title: "浏览器旁观验收")
        let take = app.buttons.matching(identifier: "browser.live.takeover").firstMatch
        XCTAssertTrue(take.waitForExistence(timeout: 15))
        take.tap()
        let angle = app.webViews.buttons["30°"].firstMatch
        XCTAssertTrue(angle.waitForExistence(timeout: 10))
        let keep = app.buttons.matching(identifier: "browser.handoff.keep").firstMatch
        XCTAssertFalse(keep.waitForExistence(timeout: 3))
        XCTAssertTrue(keep.waitForExistence(timeout: 130), "Two minutes of foreground reading should offer a handback.")
        XCTAssertTrue(angle.isHittable)
        keep.tap()
        XCTAssertTrue(keep.waitForNonExistence(timeout: 5))
        app.webViews.buttons["Open worksheet"].firstMatch.tap()
        XCTAssertTrue(app.webViews.textFields["Angle note"].firstMatch.waitForExistence(timeout: 8))
    }

    func testFixedBrowserViewportSurvivesFullscreenRotationAndModelRelease() throws {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .landscapeLeft
        let app = XCUIApplication()
        app.launchArguments += ["--ui-test-live-browser-preview", "--ui-test-live-browser-release"]
        launchApp(app)
        defer { app.terminate(); XCUIDevice.shared.orientation = .landscapeLeft }
        try openFixture(app, rowID: browserRowID, title: "浏览器旁观验收")
        XCTAssertTrue(liveButton(app, "browser.live.watch", labels: ["放大观看", "Enlarge preview"])
            .waitForExistence(timeout: 15))
        app.buttons["thread.inspector.menu"].tap()
        app.buttons["thread.inspector.open.browser"].tap()
        let viewer = assertReadOnlyPage(app)
        let inspectorWidth = viewer.frame.width
        XCTAssertGreaterThan(inspectorWidth, 100)
        let full = liveButton(app, "browser.fullscreen", labels: ["切换全屏", "Toggle full screen"])
        XCTAssertTrue(full.isHittable)
        full.tap()
        let expanded = XCTNSPredicateExpectation(predicate: NSPredicate { item, _ in
            guard let view = item as? XCUIElement else { return false }
            return view.exists && view.frame.width > inspectorWidth + 100
        }, object: viewer)
        XCTAssertEqual(XCTWaiter.wait(for: [expanded], timeout: 8), .completed)
        let wideWidth = viewer.frame.width
        XCUIDevice.shared.orientation = .portrait
        let narrower = XCTNSPredicateExpectation(predicate: NSPredicate { item, _ in
            guard let view = item as? XCUIElement else { return false }
            return view.exists && view.frame.width < wideWidth - 100
        }, object: viewer)
        XCTAssertEqual(XCTWaiter.wait(for: [narrower], timeout: 8), .completed)
        assertReadOnlyPage(app)
        try exerciseSpectatorZoom(app)

        XCTAssertEqual(notify_post("org.floeagent.uitest.browser-preview.release"), UInt32(NOTIFY_STATUS_OK))
        XCTAssertTrue(app.textFields["browser.address"].firstMatch.waitForExistence(timeout: 10))
        let web = app.webViews.containing(.staticText, identifier: "Angles in geometry").firstMatch
        XCTAssertTrue(web.waitForExistence(timeout: 8))
        XCTAssertTrue(app.images.matching(identifier: "browser.live.page").firstMatch.waitForNonExistence(timeout: 8))
        let portrait = try assertHeldPage(web)
        let width = try XCTUnwrap(portrait.viewport.first)
        let prefix = "Current page "
        let reading = web.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", prefix)).firstMatch
        XCUIDevice.shared.orientation = .landscapeLeft
        let reflow = XCTNSPredicateExpectation(predicate: NSPredicate { item, _ in
            guard let node = item as? XCUIElement, node.exists,
                  let current = try? JSONDecoder().decode(PageSize.self,
                      from: Data(node.label.dropFirst(prefix.count).utf8)),
                  let currentWidth = current.viewport.first else { return false }
            return current.page == portrait.page && currentWidth > width + 100
        }, object: reading)
        XCTAssertEqual(XCTWaiter.wait(for: [reflow], timeout: 10), .completed,
                       "The released, still-open webpage must reflow with the real window.")
        XCTAssertTrue(web.buttons["Open worksheet"].isHittable)
        web.buttons["Open worksheet"].tap()
        XCTAssertTrue(web.textFields["Angle note"].firstMatch.waitForExistence(timeout: 8))
    }

    func testDesignBrowserPreviewKeepsOriginalFileAndNarrowViewingReadOnly() throws {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .landscapeLeft
        let app = XCUIApplication()
        app.launchArguments.append("--ui-test-live-browser-preview")
        launchApp(app)
        defer { app.terminate(); XCUIDevice.shared.orientation = .landscapeLeft }
        try openFixture(app, rowID: browserRowID, title: "浏览器旁观验收")
        let input = app.textViews["composer.input"].firstMatch
        XCTAssertTrue(input.waitForExistence(timeout: 12))
        let draft = input.value as? String ?? ""
        openDesignPage(app)
        app.buttons["design.page.lens.current"].tap()
        let stage = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "HTML ·")).firstMatch
        XCTAssertTrue(stage.waitForExistence(timeout: 12))
        let source = app.webViews.firstMatch
        XCTAssertTrue(source.waitForExistence(timeout: 12))
        assertWatchingPresentation(app)
        let paragraphs = source.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "滚动区 "))
        XCTAssertTrue(paragraphs.firstMatch.waitForExistence(timeout: 8))
        func visibleParagraph() throws -> XCUIElement {
            try XCTUnwrap(paragraphs.allElementsBoundByIndex.first(where: {
                $0.frame.midY > source.frame.minY + 16 && $0.frame.midY < source.frame.midY
            }), "The original design document needs a visible reading anchor.")
        }
        let before = try visibleParagraph().label
        source.swipeUp()
        let original = try visibleParagraph()
        let anchorLabel = original.label
        XCTAssertNotEqual(anchorLabel, before, "The real original page must scroll.")
        let sourceY = original.frame.midY
        let watch = liveButton(app, "browser.live.watch", labels: ["放大观看", "Enlarge preview"])
        watch.tap()
        assertWatchingPresentation(app, expanded: true)
        XCTAssertFalse(app.textFields["browser.address"].exists)
        liveButton(app, "browser.live.back", labels: ["返回", "Back"]).tap()
        XCTAssertTrue(stage.waitForExistence(timeout: 8))
        XCTAssertEqual(source.staticTexts[anchorLabel].frame.midY, sourceY, accuracy: 4)
        XCUIDevice.shared.orientation = .portrait
        XCTAssertTrue(app.segmentedControls.firstMatch.waitForExistence(timeout: 8))
        XCTAssertTrue(watch.waitForExistence(timeout: 8))
        XCTAssertTrue(liveImage(app).waitForNonExistence(timeout: 8))
        watch.tap()
        assertWatchingPresentation(app, expanded: true)
        XCTAssertFalse(app.textFields["browser.address"].exists)
        liveButton(app, "browser.live.back", labels: ["返回", "Back"]).tap()
        app.buttons["design.page.close"].tap()
        XCTAssertTrue(input.waitForExistence(timeout: 8))
        XCTAssertEqual(input.value as? String ?? "", draft)
    }

    /// Types into an element on iPad, where the software keyboard often
    /// refuses first-responder via plain taps: paste through the edit menu,
    /// falling back to direct typing.
    private func typeInto(_ element: XCUIElement, text: String, app: XCUIApplication) {
        UIPasteboard.general.string = text
        for _ in 0..<3 {
            element.press(forDuration: 1.2)
            let paste = app.menuItems["Paste"].firstMatch
            if paste.waitForExistence(timeout: 2) {
                paste.tap()
                return
            }
        }
        // Last resort: direct typing once the keyboard is actually up.
        element.tap()
        _ = app.keyboards.firstMatch.waitForExistence(timeout: 3)
        element.typeText(text)
    }

    func testPreviewFirstLensCandidateDecisionsAndFullscreenRetention() throws {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .landscapeLeft
        let app = XCUIApplication()
        launchApp(app)
        try openModifyFixture(app)

        // 0. Unsent chat draft in the SAME conversation BEFORE the page
        //    opens (the page floats over the composer on iPad; the draft
        //    must survive the whole page lifecycle below).
        let composer = app.textViews["composer.input"]
        XCTAssertTrue(composer.waitForExistence(timeout: 12))
        // The composer draft persists across runs by design: seed it only
        // when absent so repeated acceptance runs stay idempotent.
        if (composer.value as? String)?.contains("draft-retention-check") != true {
            typeInto(composer, text: "draft-retention-check", app: app)
        }
        openDesignPage(app)
        ensurePageOpen(app)

        // 1. Preview-first: the stage renders the REAL retained HTML bytes
        //    in the web engine (family caption "HTML · <n> B"), and the
        //    details Form is NOT the landing surface.
        let caption = app.staticTexts.matching(
            NSPredicate(format: "label BEGINSWITH %@", "HTML ·")).firstMatch
        XCTAssertTrue(caption.waitForExistence(timeout: 15))
        XCTAssertFalse(app.descendants(matching: .any)
            .matching(identifier: "design.page.detailsClose").firstMatch.exists,
            "the details inspector must be collapsed — no Form landing")

        // 2. Current vs candidate lens, both explicit and tappable.
        XCTAssertTrue(app.buttons["design.page.lens.current"].waitForExistence(timeout: 6))
        let candidateLens = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH %@", "design.page.lens.candidate"))
            .firstMatch
        XCTAssertTrue(candidateLens.waitForExistence(timeout: 6))
        candidateLens.tap()
        // Candidate decision surface — ON DEMAND, not resident: visible only
        // while a PENDING candidate lens is selected. ONE primary action
        // plus a compact "更多" menu holding variant/reject/authorize.
        let candidateLensEarly = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH %@", "design.page.lens.candidate")).firstMatch
        candidateLensEarly.tap()
        // ONE primary action…
        XCTAssertTrue(app.buttons["采纳"].waitForExistence(timeout: 6))
        // …plus a compact "更多" menu holding compare/variant/reject.
        // The compact menu surfaces by its label (container identifiers can
        // merge inside the page).
        let candidateMenu = app.buttons["更多操作"]
        if !candidateMenu.waitForExistence(timeout: 4) {
            print("DEBUG NOMENU:\n\(app.debugDescription)")
        }
        XCTAssertTrue(candidateMenu.exists)
        candidateMenu.tap()
        // Menu items surface by label (identifiers merge inside menus).
        XCTAssertTrue(app.buttons["拒绝"].waitForExistence(timeout: 3),
                      "reject lives in the compact menu")
        XCTAssertTrue(app.buttons["作为分支采纳（新内容，保留原文）"].exists)
        XCTAssertTrue(app.buttons["对比"].exists)
        // Close the menu without consuming the fixture candidate: tap the
        // preview whitespace well away from the bar and the menu popover.
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.2, dy: 0.3)).tap()
        // Back to the current lens.
        app.buttons["design.page.lens.current"].tap()

        // 3. Fullscreen is a STABLE surface (unlike the iPad popover, which
        //    churns during re-renders): the details draft flow runs inside
        //    the cover, proving shared presentation state end to end.
        ensurePageOpen(app)
        var coverUp = false
        for _ in 0..<4 where !coverUp {
            let fullscreen = app.buttons["design.page.fullscreen"]
            if fullscreen.waitForExistence(timeout: 6) { fullscreen.tap() }
            coverUp = app.buttons["design.page.done"].waitForExistence(timeout: 6)
        }
        if !coverUp {
            print("DEBUG NOFULLSCREEN:\n\(app.debugDescription)")
        }
        XCTAssertTrue(coverUp)
        // In-page fullscreen: ONE explicit exit (Done) and NO nested
        // fullscreen entry — the page is one view tree, so the underlying
        // conversation/draft/preview are literally the same objects.
        XCTAssertFalse(app.buttons["design.page.fullscreen"].exists)
        XCTAssertTrue(app.buttons["design.page.done"].isHittable)
        XCTAssertTrue(app.staticTexts.matching(
            NSPredicate(format: "label BEGINSWITH %@", "HTML ·")).firstMatch.waitForExistence(timeout: 8))

        // Details inspector inside the cover: edits survive close/reopen
        // (the drafts live in the SHARED presentation state).
        app.buttons["design.page.details"].tap()
        if !app.textFields["design.page.brief.goal"].waitForExistence(timeout: 6) {
            print("DEBUG NODETAILFIELD:\n\(app.debugDescription)")
        }
        XCTAssertTrue(app.textFields["design.page.brief.goal"].exists)
        if (app.textFields["design.page.brief.goal"].value as? String)?
            .contains("验收目标：标题更有冲击力") != true {
            typeInto(app.textFields["design.page.brief.goal"], text: "验收目标：标题更有冲击力", app: app)
        }
        app.buttons["design.page.detailsClose"].tap()
        XCTAssertFalse(app.buttons["design.page.detailsClose"].exists)
        app.buttons["design.page.details"].tap()
        if !app.textFields["design.page.brief.goal"].waitForExistence(timeout: 6) {
            print("DEBUG NODETAILFIELD:\n\(app.debugDescription)")
        }
        XCTAssertTrue(app.textFields["design.page.brief.goal"].exists)
        XCTAssertTrue((app.textFields["design.page.brief.goal"].value as? String ?? "")
            .contains("验收目标：标题更有冲击力"),
            "unsaved brief edits must survive panel close/reopen")
        app.buttons["design.page.detailsClose"].tap()

        // Done returns to the split; the SAME conversation draft underneath.
        app.buttons["design.page.done"].tap()
        if !pageElement(app).waitForExistence(timeout: 8) {
            print("DEBUG DONE-NOLENS:\n\(app.debugDescription)")
        }
        XCTAssertTrue(pageElement(app).waitForExistence(timeout: 8))
        XCTAssertTrue((app.textViews["composer.input"].value as? String ?? "")
            .contains("draft-retention-check"),
            "the unsent chat draft must survive fullscreen open/close")

        // 4. Compact rotation: the segmented picker appears and the preview
        //    stays reachable; rotating back keeps the draft.
        XCUIDevice.shared.orientation = .portrait
        let picker = app.descendants(matching: .any)
            .matching(identifier: "design.page.sectionPicker").firstMatch
        XCTAssertTrue(picker.waitForExistence(timeout: 8))
        XCTAssertTrue(app.staticTexts.matching(
            NSPredicate(format: "label BEGINSWITH %@", "HTML ·")).firstMatch.waitForExistence(timeout: 8))
        XCUIDevice.shared.orientation = .landscapeLeft
        XCTAssertTrue(app.buttons["design.page.lens.current"].waitForExistence(timeout: 8))
        XCTAssertTrue((app.textViews["composer.input"].value as? String ?? "")
            .contains("draft-retention-check"))

        // 5. Explicit close dismisses the page; the conversation stays.
        app.buttons["design.page.close"].tap()
        // The sidebar row may be scrolled out of the visible window (the
        // same offscreen-row phenomenon documented in the primary review —
        // not a product regression): scroll the sidebar exactly like the
        // entry helper does, then require the row.
        let closedRow = app.descendants(matching: .any)
            .matching(identifier: modifyRowID).firstMatch
        var closeAttempts = 0
        while !closedRow.exists && closeAttempts < 6 {
            app.collectionViews.firstMatch.swipeUp()
            closeAttempts += 1
        }
        XCTAssertTrue(closedRow.waitForExistence(timeout: 8))
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "Design conversation page acceptance"
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }

    /// Office family: the retained DOCX renders as a truthful read-only
    /// system preview with an explicit handoff into the app's EXISTING
    /// professional editor surface (FilePreviewView host) — a real editing
    /// path, no parallel editor, and candidate lenses stay immutable.
    func testOfficePreviewReadonlyNoteAndEditorHandoff() throws {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .landscapeLeft
        let app = XCUIApplication()
        launchApp(app)
        try openFixture(app, rowID: officeRowID, title: "设计验收-演示文稿")
        ensurePageOpen(app)

        // Read-only system preview of the REAL retained bytes: the family
        // caption proves the Quick Look branch rendered the docx payload.
        if !app.staticTexts.matching(
            NSPredicate(format: "label BEGINSWITH %@", "DOCX ·")).firstMatch
            .waitForExistence(timeout: 15) {
            print("DEBUG DOCX HIERARCHY:\n\(app.debugDescription)")
        }
        XCTAssertTrue(app.staticTexts.matching(
            NSPredicate(format: "label BEGINSWITH %@", "DOCX ·")).firstMatch.exists)
        XCTAssertTrue(app.staticTexts["只读预览 — 编辑请在专业编辑器中进行。"].waitForExistence(timeout: 6))

        // Current lens: the explicit professional-editor handoff opens the
        // app's existing FilePreviewView surface for the SAME file identity.
        ensurePageOpen(app)
        app.buttons["design.page.lens.current"].tap()
        // (Container identifiers merge inside the page; the handoff button
        // is proven by its label, which always surfaces.)
        let handoff = app.buttons["在专业编辑器中打开"]
        XCTAssertTrue(handoff.waitForExistence(timeout: 6))
        handoff.tap()
        // The handoff presents the app's existing FilePreviewView host; the
        // explicit Done button (a control whose identifier surfaces)
        // proves the real surface opened.
        let handoffDone = app.buttons["design.page.editorHandoffDone"]
        XCTAssertTrue(handoffDone.waitForExistence(timeout: 12))
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "Office readonly preview + editor handoff"
        screenshot.lifetime = .keepAlways
        add(screenshot)
        handoffDone.tap()
        XCTAssertTrue(pageElement(app).waitForExistence(timeout: 8))

        // Candidate lens: immutable — the handoff is replaced by an honest
        // note and no editing entry is offered.
        let candidateLens = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH %@", "design.page.lens.candidate"))
            .firstMatch
        XCTAssertTrue(candidateLens.waitForExistence(timeout: 6))
        candidateLens.tap()
        XCTAssertTrue(app.staticTexts["候选内容不可编辑 — 先采用，再编辑原件。"].waitForExistence(timeout: 6))
        XCTAssertFalse(app.buttons["design.page.openInEditor"].exists)
    }
}
