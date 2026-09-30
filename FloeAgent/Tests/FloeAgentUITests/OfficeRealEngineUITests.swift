// SPDX-License-Identifier: MPL-2.0
import XCTest
import UIKit

/// Real native Office qualification on the full Floe app (cloud simulator).
///
/// The genuine `FloeOfficeNative.framework` (arm64 iphonesimulator, built
/// from the pinned staged real engine with every current native overlay) is
/// linked into the real Floe app. This test drives ONE imported synthetic
/// fixture document through the App's actual Notes entry policy
/// (`NotesOfficeView.prepare` + `OfficeDocumentModeStore`): the first
/// completed entry is a read-only preview; from the second entry onwards
/// Notes remembers edit mode and `prepare()` itself drives the editable
/// generation — there is deliberately no Edit-button tap on a reopen, so the
/// test never fakes a same-session preview entry the real App would not
/// offer.
///
/// Sequence: import -> preview -> real host Edit (the preview native closes
/// and a NEW editable generation mounts) -> insert slide (2 -> 3) -> idle
/// 120 s -> save/close -> remembered reopen #1 (auto editable generation) ->
/// insert slide (3 -> 4) -> save/close -> remembered reopen #2 (its OWN
/// editable generation paints) -> verify the persisted 4-slide document ->
/// save/close. Render, generation handoff and persistence are judged by the
/// cloud gates (`office_floe_simulator`): pixel analysis of the attached
/// frames, the durable per-(session, generation) `[FloeOfficeStage]` trace
/// with revision continuity, and the content-addressed Notes resource.
///
/// This target runs only in the real-engine cloud workflow which installs
/// the framework and the fixture. A build without the engine, or a missing
/// fixture, FAILS here (it never skips to a pass-looking result); the
/// sibling OfficeSimulatorStageUITests owns the honest stage-only baseline.
@MainActor
final class OfficeRealEngineUITests: XCTestCase {
    static let receiptAttachmentName = "office-real-engine-receipt"
    static let fixtureStem = "floe-sim-qual"
    /// Exact phase coverage, in order. Single source of truth shared with
    /// verify_real_engine_trace.SCENARIO_PHASES.
    static let expectedPhases = [
        "import",
        "preview-open",
        "enter-edit",
        "insert-slide",
        "idle-120s",
        "save",
        "leave-edit",
        "close",
        "reopen",
        "edit-again",
        "insert-slide-again",
        "save-again",
        "close-after-reopen",
        "reopen-2",
        "verify-persisted",
        "save-final",
        "close-final",
    ]
    static var receipt: [String: Any] = [:]

    // MARK: - Receipt

    func mark(_ phase: String, _ ok: Bool, _ detail: String = "") {
        var phases = OfficeRealEngineUITests.receipt["phases"] as? [[String: Any]] ?? []
        var startedAt = phases.last(where: { ($0["phase"] as? String) == phase })?["startedAt"]
        let now = Date().timeIntervalSince1970
        if startedAt == nil { startedAt = now }
        phases.removeAll { ($0["phase"] as? String) == phase }
        phases.append(["phase": phase, "ok": ok, "detail": detail,
                       "startedAt": startedAt ?? now, "finishedAt": now])
        OfficeRealEngineUITests.receipt["phases"] = phases
    }

    func shot(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    func attachReceipt() {
        OfficeRealEngineUITests.receipt["expectedPhases"] = OfficeRealEngineUITests.expectedPhases
        OfficeRealEngineUITests.receipt["hostKind"] = "fullFloeAppSimulator"
        OfficeRealEngineUITests.receipt["fixture"] = OfficeRealEngineUITests.fixtureStem + ".pptx"
        var data: Data
        do {
            data = try JSONSerialization.data(
                withJSONObject: OfficeRealEngineUITests.receipt,
                options: [.prettyPrinted, .sortedKeys])
        } catch {
            data = Data("{\"serializationError\": \"\(error)\"}".utf8)
        }
        let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.json")
        attachment.name = OfficeRealEngineUITests.receiptAttachmentName
        attachment.lifetime = .keepAlways
        add(attachment)
        if let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first {
            try? data.write(to: docs.appendingPathComponent(
                OfficeRealEngineUITests.receiptAttachmentName + ".json"), options: .atomic)
        }
    }

    func require(_ condition: Bool, _ phase: String, _ message: String) throws {
        guard condition else {
            mark(phase, false, message)
            throw NSError(domain: "OfficeRealEngineUITests", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: message])
        }
    }

    // MARK: - Element helpers

    func firstElement(_ app: XCUIApplication, _ labels: [String],
                      includeMenuItems: Bool = false) -> XCUIElement? {
        for label in labels {
            let direct = app.buttons[label]
            if direct.exists { return direct }
            let identified = app.buttons.matching(identifier: label).firstMatch
            if identified.exists { return identified }
            let byLabel = app.buttons.matching(NSPredicate(format: "label == %@", label)).firstMatch
            if byLabel.exists { return byLabel }
            let text = app.staticTexts.matching(NSPredicate(format: "label == %@", label)).firstMatch
            if text.exists { return text }
            if includeMenuItems {
                let menu = app.menuItems[label]
                if menu.exists { return menu }
                let menuByLabel = app.menuItems.matching(
                    NSPredicate(format: "label == %@", label)).firstMatch
                if menuByLabel.exists { return menuByLabel }
            }
        }
        return nil
    }

    func firstElementWaiting(_ app: XCUIApplication, _ labels: [String],
                             timeout: TimeInterval) -> XCUIElement? {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let element = firstElement(app, labels, includeMenuItems: true) { return element }
            Thread.sleep(forTimeInterval: 0.5)
        }
        return nil
    }

    /// Real slide-count verification through the Impress accessibility tree.
    func waitForSlideCount(_ app: XCUIApplication, expected: Int,
                           timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        let ofCount = "of \(expected)"
        let page = "preview of page \(expected)"
        let slide = "Slide \(expected)"
        while Date() < deadline {
            if app.staticTexts.matching(
                NSPredicate(format: "label CONTAINS %@", ofCount)).firstMatch.exists {
                return true
            }
            let predicate = NSPredicate(format: "label CONTAINS %@ OR label CONTAINS %@",
                                        page, slide)
            if app.descendants(matching: .any).matching(predicate).firstMatch.exists {
                return true
            }
            Thread.sleep(forTimeInterval: 0.5)
        }
        return false
    }

    func anyElement(_ app: XCUIApplication, _ identifier: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    // MARK: - Notes navigation

    func openNotesLibrary(_ app: XCUIApplication, ipad: Bool) {
        if !ipad {
            let sidebar = app.buttons["phone.sidebar.open"]
            XCTAssertTrue(sidebar.waitForExistence(timeout: 15)); sidebar.tap()
        }
        let notes = app.staticTexts["sidebar.notes"].firstMatch
        XCTAssertTrue(notes.waitForExistence(timeout: 15)); notes.tap()
        XCTAssertTrue(app.buttons["notes.create"].waitForExistence(timeout: 20),
                      "the Notes library must load")
    }

    func revealCard(_ app: XCUIApplication) -> XCUIElement {
        let title = OfficeRealEngineUITests.fixtureStem
        let card = app.scrollViews["notes.library.scroll"].buttons
            .matching(NSPredicate(format: "identifier BEGINSWITH %@", "notes.card.office.\(title)."))
            .element(boundBy: 0)
        if card.exists && card.isHittable { return card }
        let scroll = app.scrollViews["notes.library.scroll"]
        if scroll.waitForExistence(timeout: 10) {
            for _ in 0..<8 where !(card.exists && card.isHittable) { scroll.swipeDown() }
            let deadline = Date().addingTimeInterval(60)
            while !(card.exists && card.isHittable) && Date() < deadline { scroll.swipeUp() }
        }
        return card
    }

    /// Open the imported fixture card. `expectPreview` enforces the App's
    /// real entry policy: the first entry MUST be the read-only preview; a
    /// remembered reopen MUST present the editable surface directly (no Edit
    /// button is tapped). A build without the engine is a hard failure.
    @discardableResult
    func openFixture(_ app: XCUIApplication, expectPreview: Bool,
                     phase: String) throws -> Bool {
        let card = revealCard(app)
        try require(card.isHittable, phase, "fixture card is not hittable")
        card.tap()
        let editor = anyElement(app, "office.editor.native")
        let preview = anyElement(app, "office.preview.native")
        let deadline = Date().addingTimeInterval(240)
        while Date() < deadline {
            if editor.exists {
                try require(!expectPreview, phase,
                            "first entry opened directly in edit; the real entry policy requires a preview")
                return true
            }
            if preview.exists && expectPreview {
                return false
            }
            // prepare() must first open a preview before requestEditing()
            // mounts the remembered editable generation. On a reopen, wait
            // through that intermediate surface; only the editor satisfies
            // this phase. A preview that never advances still times out.
            // Hard failure: this workflow installs the real engine. Its
            // absence can never be skipped into a pass-looking qualification.
            if app.staticTexts["Office 编辑器不可用"].exists {
                throw NSError(domain: "OfficeRealEngineUITests", code: 2,
                              userInfo: [NSLocalizedDescriptionKey:
                                            "real Floe Office engine not linked/available in this build"])
            }
            Thread.sleep(forTimeInterval: 0.5)
        }
        try require(false, phase, "native Office canvas did not appear")
        return false
    }

    /// First entry only: enter edit through the preview's real host Edit
    /// action and require the editable native surface (the preview native
    /// closes and a NEW generation mounts).
    func enterEdit(_ app: XCUIApplication, phase: String) throws {
        let edit = anyElement(app, "office.preview.edit")
        try require(edit.waitForExistence(timeout: 30), phase,
                    "preview Edit action missing")
        edit.tap()
        let editor = anyElement(app, "office.editor.native")
        try require(editor.waitForExistence(timeout: 120), phase,
                    "editable native canvas did not appear after the host Edit action")
    }

    /// Insert one Impress slide through the real notebookbar control and
    /// require the slide count to advance.
    func insertSlide(_ app: XCUIApplication, expected: Int, phase: String) throws {
        let insert = firstElementWaiting(
            app, ["Insert Slide", "New Slide", "Insert Page", "insertpage",
                  "插入幻灯片", "新建幻灯片"], timeout: 60)
        try require(insert != nil, phase, "Impress Insert Slide control missing")
        insert!.tap()
        let advanced = waitForSlideCount(app, expected: expected, timeout: 30)
        var inventory: [String] = []
        let allButtons = app.descendants(matching: .button)
        if allButtons.firstMatch.waitForExistence(timeout: 5) {
            for index in 0..<min(allButtons.count, 120) {
                inventory.append(allButtons.element(boundBy: index).label)
            }
        }
        OfficeRealEngineUITests.receipt["buttonInventory.\(phase)"] = inventory
        try require(advanced, phase,
                    "slide count did not reach \(expected) after Insert Slide")
    }

    /// Save through the real editor back action (save-and-dismiss in the
    /// Notes-owned surface). The library only returns after the Notes commit
    /// succeeded, so both phases are marked only then.
    func saveAndClose(_ app: XCUIApplication, savePhase: String, closePhase: String) throws {
        let back = anyElement(app, "office.editor.back")
        try require(back.waitForExistence(timeout: 15), savePhase,
                    "editor back action missing")
        back.tap()
        let library = app.buttons["notes.create"]
        try require(library.waitForExistence(timeout: 60), closePhase,
                    "Notes library did not return after save-and-close")
        mark(savePhase, true, "save-and-dismiss committed")
        mark(closePhase, true)
    }

    // MARK: - Scenario

    func testRealEnginePPPreviewEditIdleSaveReopenTwice() throws {
        #if !targetEnvironment(simulator)
        throw XCTSkip("the real-engine simulator qualification is simulator-only")
        #else
        continueAfterFailure = false
        let ipad = ProcessInfo.processInfo.environment["SIMULATOR_MODEL_IDENTIFIER"]?.hasPrefix("iPad") == true
            || UIDevice.current.userInterfaceIdiom == .pad
        let app = XCUIApplication()
        app.terminate()
        XCUIDevice.shared.orientation = ipad ? .landscapeLeft : .portrait

        guard let fixtureURL = Bundle(for: OfficeRealEngineUITests.self)
            .url(forResource: OfficeRealEngineUITests.fixtureStem, withExtension: "pptx"),
              let fixture = try? Data(contentsOf: fixtureURL) else {
            // A missing fixture is a hard qualification failure, never a skip.
            XCTFail("pinned fixture missing from the test bundle")
            return
        }
        app.launchArguments = ["-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN", "-ui-testing",
                               "--ui-test-skip-onboarding", "--ui-test-office-real-engine"]
        if ipad { app.launchArguments.append("-ui-testing-ipad") }
        app.launchEnvironment["FLOE_OFFICE_REAL_ENGINE_FIXTURE_B64"] = fixture.base64EncodedString()
        app.launch()
        defer { app.terminate() }
        let scenarioStart = Date()
        defer {
            OfficeRealEngineUITests.receipt["seconds"] = Date().timeIntervalSince(scenarioStart)
            attachReceipt()
        }

        do {
            openNotesLibrary(app, ipad: ipad)
            let card = revealCard(app)
            try require(card.waitForExistence(timeout: 60), "import",
                        "imported fixture card never appeared")
            mark("import", true)

            // 1) First entry MUST be the read-only preview (real entry policy).
            _ = try openFixture(app, expectPreview: true, phase: "preview-open")
            mark("preview-open", true)
            shot("01-preview")

            // 2) Real host Edit action: the preview native closes and a NEW
            //    editable generation mounts and acknowledges edit.
            try enterEdit(app, phase: "enter-edit")
            mark("enter-edit", true)

            // 3) Real content change: insert a slide (2 -> 3).
            try insertSlide(app, expected: 3, phase: "insert-slide")
            mark("insert-slide", true)
            shot("02-edit")

            // 4) Idle 120 s with the editable canvas still alive.
            mark("idle-120s", true, "idle start")
            Thread.sleep(forTimeInterval: 120)
            try require(anyElement(app, "office.editor.native").exists, "idle-120s",
                        "editable native canvas disappeared during the 120 s idle")
            mark("idle-120s", true, "idle complete")
            shot("03-idle-120s")

            // 5) Save through the real save-and-dismiss path, then close.
            try saveAndClose(app, savePhase: "save", closePhase: "leave-edit")
            mark("close", true)

            // 6) Remembered reopen #1: prepare() auto-drives the editable
            //    generation; do NOT tap Edit. Insert the second slide (3 -> 4).
            try require(try openFixture(app, expectPreview: false, phase: "reopen"),
                        "reopen", "remembered reopen did not present the editable canvas")
            mark("reopen", true)
            try require(anyElement(app, "office.editor.native").exists, "edit-again",
                        "editable canvas missing on the remembered reopen")
            mark("edit-again", true)
            try insertSlide(app, expected: 4, phase: "insert-slide-again")
            mark("insert-slide-again", true)
            shot("04-reopen")
            try saveAndClose(app, savePhase: "save-again", closePhase: "close-after-reopen")

            // 7) Remembered reopen #2: its OWN editable generation paints and
            //    the persisted 4-slide document is verified; no new insertion.
            try require(try openFixture(app, expectPreview: false, phase: "reopen-2"),
                        "reopen-2", "second remembered reopen did not present the editable canvas")
            mark("reopen-2", true)
            try require(waitForSlideCount(app, expected: 4, timeout: 60),
                        "verify-persisted",
                        "persisted document did not show the four saved slides")
            mark("verify-persisted", true)
            shot("05-persisted")
            try saveAndClose(app, savePhase: "save-final", closePhase: "close-final")

            // Receipt self-check: exact coverage, all ok.
            let phases = OfficeRealEngineUITests.receipt["phases"] as? [[String: Any]] ?? []
            let names = Set(phases.compactMap { $0["phase"] as? String })
            let allOk = phases.allSatisfy { ($0["ok"] as? Bool) == true }
            try require(names == Set(OfficeRealEngineUITests.expectedPhases) && allOk,
                        "coverage", "receipt coverage mismatch: got \(names.sorted())")
        } catch {
            mark("scenario", false, "\(error)")
            shot("99-failure")
            throw error
        }
        #endif
    }
}
