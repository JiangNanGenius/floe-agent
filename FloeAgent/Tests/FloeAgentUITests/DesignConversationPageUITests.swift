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

@MainActor
final class DesignConversationPageUITests: XCTestCase {
    private let modifyRowID = "sidebar.conversation.D3516001-7A21-4F03-9C5A-71D8E0B4F101"
    private let officeRowID = "sidebar.conversation.D3516001-7A21-4F03-9C5A-71D8E0B4F104"

    private func launchApp(_ app: XCUIApplication) {
        app.launchArguments += [
            "-ui-testing", "-ui-testing-ipad",
            "--ui-test-skip-onboarding",
            "--ui-test-design-workflow-fixture",
        ]
        app.launch()
    }

    private func openFixture(_ app: XCUIApplication, rowID: String, title: String) throws {
        // Fixture conversations live in the sidebar's always-visible chat
        // section (their private-task workspace grouping). The sidebar is a
        // lazy collection: scroll within it until the row materializes.
        var row = app.descendants(matching: .any)
            .matching(identifier: rowID).firstMatch
        var attempts = 0
        while !row.exists && attempts < 6 {
            app.collectionViews.firstMatch.swipeUp()
            attempts += 1
        }
        XCTAssertTrue(row.waitForExistence(timeout: 8))
        if !row.isHittable {
            let drawer = app.buttons["phone.sidebar.open"]
            XCTAssertTrue(drawer.waitForExistence(timeout: 5))
            drawer.tap()
        }
        row.tap()
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
