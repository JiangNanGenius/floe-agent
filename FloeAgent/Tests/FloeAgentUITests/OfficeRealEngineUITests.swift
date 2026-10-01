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
/// and a NEW editable generation mounts) -> insert slide (2 -> 3) -> real
/// presentation of the resulting [fixture slide 1, inserted blank, fixture
/// slide 2] deck (document-region markers for each page, slideshow letterbox
/// required at every step, touch quit proven by the letterbox gone, the
/// editable surface ready and the real thumbnail rail interactive on the
/// SAME document identity) -> idle
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
        "slideshow-start",
        "slideshow-page1",
        "slideshow-blank-page",
        "slideshow-page2",
        "slideshow-exit",
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

    // MARK: - Slideshow pixel evidence (real presentation frames)

    /// Facts about one simulator frame, measured in the same document region
    /// the cloud pixel gate analyses. Presentation frames are identified by
    /// the slideshow letterbox (black fraction) so editor chrome behind a
    /// still-active canvas can never satisfy "presentation exited", and page
    /// identity comes from the pinned fixture markers INSIDE the document
    /// region: blue title + orange bar (fixture slide 1), the green oval
    /// (fixture slide 2). Chrome/UI accent pixels outside the region are
    /// deliberately ignored.
    struct SlideshowFrameFacts {
        var cropBlue = 0
        var cropOrange = 0
        var cropGreen = 0
        var colored = 0
        var total = 0
        var blackFraction = 0.0
        var whiteFraction = 0.0
        var rgba: [UInt8] = []

        var cropMarkerCount: Int { cropBlue + cropOrange + cropGreen }
        var isPresenting: Bool { blackFraction > 0.04 && whiteFraction > 0.5 }
        var isFixtureSlideOne: Bool { cropBlue > 50 && cropOrange > 100 && cropGreen < 2000 }
        var isFixtureSlideTwo: Bool { cropGreen > 2000 && cropOrange < 50 }
        var isInsertedBlank: Bool { cropMarkerCount < 20 }
    }

    func slideshowFrameFacts(_ image: UIImage, divisor: Int = 4) -> SlideshowFrameFacts {
        var facts = SlideshowFrameFacts()
        guard let cg = image.cgImage else { return facts }
        let width = max(1, cg.width / divisor), height = max(1, cg.height / divisor)
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        guard let context = CGContext(data: &bytes, width: width, height: height,
                                      bitsPerComponent: 8, bytesPerRow: width * 4,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            return facts
        }
        context.draw(cg, in: CGRect(x: 0, y: 0, width: width, height: height))
        let x0 = Int(Double(width) * 0.20), x1 = Int(Double(width) * 0.80)
        let y0 = Int(Double(height) * 0.22), y1 = Int(Double(height) * 0.90)
        var black = 0, white = 0
        for y in 0..<height {
            for x in 0..<width {
                let index = (y * width + x) * 4
                let r = Int(bytes[index]), g = Int(bytes[index + 1]), b = Int(bytes[index + 2])
                if r <= 16 && g <= 16 && b <= 16 { black += 1 }
                if r >= 245 && g >= 245 && b >= 245 { white += 1 }
                if max(r, g, b) - min(r, g, b) > 40 { facts.colored += 1 }
                if x >= x0 && x < x1 && y >= y0 && y < y1 {
                    if abs(r - 234) + abs(g - 88) + abs(b - 12) <= 36 { facts.cropOrange += 1 }
                    if abs(r - 29) + abs(g - 78) + abs(b - 216) <= 36 { facts.cropBlue += 1 }
                    if abs(r - 16) + abs(g - 160) + abs(b - 64) <= 36 { facts.cropGreen += 1 }
                }
            }
        }
        facts.total = width * height
        facts.blackFraction = Double(black) / Double(max(1, facts.total))
        facts.whiteFraction = Double(white) / Double(max(1, facts.total))
        facts.rgba = bytes
        return facts
    }

    func slideshowDiffRatio(_ first: [UInt8], _ second: [UInt8]) -> Double {
        guard !first.isEmpty, first.count == second.count else { return 0 }
        var changed = 0, total = 0
        var index = 0
        while index < first.count {
            let delta = abs(Int(first[index]) - Int(second[index]))
                + abs(Int(first[index + 1]) - Int(second[index + 1]))
                + abs(Int(first[index + 2]) - Int(second[index + 2]))
            if delta > 90 { changed += 1 }
            total += 1
            index += 4
        }
        return total > 0 ? Double(changed) / Double(total) : 0
    }

    /// Advance exactly one slideshow page through the real canvas tap. The
    /// first tap can be consumed as a pointer move that only reveals the
    /// slideshow controls, so an unchanged frame is retried (bounded); the
    /// first observed change returns immediately, therefore a verified step
    /// never skips a page. `nil` means no verified single-page advance.
    func advanceOneSlideshowPage(_ app: XCUIApplication,
                                 from previous: SlideshowFrameFacts) -> SlideshowFrameFacts? {
        let deadline = Date().addingTimeInterval(24)
        var taps = 0
        while Date() < deadline {
            if taps < 3 {
                app.coordinate(withNormalizedOffset: CGVector(dx: 0.55, dy: 0.45)).tap()
                taps += 1
            }
            Thread.sleep(forTimeInterval: 2.0)
            let facts = slideshowFrameFacts(XCUIScreen.main.screenshot().image)
            if slideshowDiffRatio(previous.rgba, facts.rgba) > 0.01 && facts.isPresenting {
                return facts
            }
        }
        return nil
    }

    /// Poll the real editor frame until the fixture slide 1 markers are
    /// inside the document region. The canvas can repaint white for a moment
    /// right after an insertion; a captioned frame must show the document,
    /// not that transient blank state. Fails closed when the markers never
    /// appear.
    func waitForFixtureSlideMarkers(_ app: XCUIApplication, timeout: TimeInterval,
                                    phase: String) throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            try require(app.state == .runningForeground, phase,
                        "Floe left the foreground waiting for the fixture slide")
            let facts = slideshowFrameFacts(XCUIScreen.main.screenshot().image)
            if facts.cropBlue > 50 && facts.cropOrange > 100 { return }
            Thread.sleep(forTimeInterval: 1.0)
        }
        try require(false, phase,
                    "fixture slide markers did not appear in the editor document region")
    }

    /// Stable per-document tab identity from the Notes tab chrome. The uuid
    /// suffix is shared by `notes.tab.<uuid>` and `notes.tab.close.<uuid>`;
    /// the presentation must return to the SAME document identity.
    func documentTabIDs(_ app: XCUIApplication) -> Set<String> {
        let prefix = "notes.tab."
        return Set(app.buttons
            .matching(NSPredicate(format: "identifier BEGINSWITH %@", prefix))
            .allElementsBoundByIndex
            .compactMap { element -> String? in
                let identifier = element.identifier
                guard identifier.hasPrefix(prefix) else { return nil }
                return String(identifier.dropFirst(prefix.count))
                    .components(separatedBy: ".").last
            })
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
            // The actual zh-Hans mobile Impress accessibility tree labels
            // thumbnail nodes "页面预览 N". Keep the exact page-number label;
            // "页面预览 3" must never match page 30 or a toolbar tooltip.
            let localizedPage = "页面预览 \(expected)"
            let predicate = NSPredicate(
                format: "label CONTAINS %@ OR label CONTAINS %@ OR label == %@",
                page, slide, localizedPage)
            if app.descendants(matching: .any).matching(predicate).firstMatch.exists {
                return true
            }
            Thread.sleep(forTimeInterval: 0.5)
        }
        return false
    }

    /// New Page inserts a deliberately blank slide. Select the original
    /// fixture slide through the real thumbnail rail before render evidence,
    /// so every frame proves preserved document content rather than a blank
    /// inserted page. Page-count and persisted-file gates still prove edits.
    func showFixtureSlide(_ app: XCUIApplication, phase: String) throws {
        let thumbnail = app.descendants(matching: .any).matching(
            NSPredicate(format: "label == %@ OR label == %@",
                        "页面预览 1", "preview of page 1")).firstMatch
        try require(thumbnail.waitForExistence(timeout: 30) && thumbnail.isHittable,
                    phase, "original fixture slide thumbnail unavailable")
        thumbnail.tap()
        let deadline = Date().addingTimeInterval(30)
        while Date() < deadline {
            try require(app.state == .runningForeground, phase,
                        "Floe left the foreground selecting the fixture slide")
            if thumbnail.isSelected { return }
            Thread.sleep(forTimeInterval: 0.25)
        }
        try require(false, phase, "original fixture slide was not selected")
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

    /// The App's document-action readiness includes real same-generation
    /// render evidence. A mounted canvas or recoverable notice cannot pass.
    func documentIsReady(_ surface: XCUIElement) -> Bool {
        guard let value = surface.value as? String else { return false }
        return value == "文档已就绪" || value == "Document ready"
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
            if editor.exists && documentIsReady(editor) {
                try require(!expectPreview, phase,
                            "first entry opened directly in edit; the real entry policy requires a preview")
                return true
            }
            if preview.exists && expectPreview {
                // Mounting the controller precedes its first render. The
                // real App exposes Edit only after readiness; wait for that
                // existing affordance before capturing the preview frame.
                // Pixel and per-generation trace gates still judge the paint.
                let edit = anyElement(app, "office.preview.edit")
                if documentIsReady(preview) && edit.exists && edit.isEnabled && edit.isHittable { return false }
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
        try require(app.buttons.matching(identifier: "office.preview.edit").count == 1,
                    phase, "preview must expose exactly one host Edit button")
        edit.tap()
        let editor = anyElement(app, "office.editor.native")
        let back = anyElement(app, "office.editor.back")
        let deadline = Date().addingTimeInterval(120)
        while Date() < deadline {
            try require(app.state == .runningForeground, phase,
                        "Floe left the foreground during native edit entry")
            // The controller mounts before permission and paint settle. The
            // host back action stays disabled until the real session canAct;
            // a mounted view alone cannot acknowledge a working editor.
            if editor.exists && documentIsReady(editor) && back.exists && back.isEnabled && !edit.exists { return }
            Thread.sleep(forTimeInterval: 0.5)
        }
        try require(false, phase,
                    "editable native canvas did not become ready after the host Edit action")
    }

    /// Insert one Impress slide through the real notebookbar control and
    /// require the slide count to advance.
    func insertSlide(_ app: XCUIApplication, expected: Int, phase: String) throws {
        let insert = firstElementWaiting(
            app, ["Insert Slide", "New Slide", "Insert Page", "New Page", "insertpage",
                  "插入幻灯片", "新建幻灯片", "新建页面"], timeout: 60)
        // The pinned mobile bottom toolbar labels .uno:InsertPage "New Page";
        // the presentation sidebar uses "Insert Slide". Drive the existing UI
        // in either layout, then require the real document count to advance.
        let hierarchy = XCTAttachment(string: app.debugDescription)
        hierarchy.name = "office-controls-\(phase)"
        hierarchy.lifetime = .keepAlways
        add(hierarchy)
        try require(app.state == .runningForeground, phase,
                    "Floe left the foreground before inserting a slide")
        try require(insert != nil, phase, "Impress Insert Slide control missing")
        try require(insert!.isEnabled && insert!.isHittable, phase,
                    "Impress Insert Slide control is not actionable")
        insert!.tap()
        let advanced = waitForSlideCount(app, expected: expected, timeout: 30)
        // The toolbar changes after insertion. Do not iterate a live query
        // using a count from an earlier snapshot: shrinking controls can abort
        // XCTest before the document-count assertion and receipt are written.
        // The pre-tap hierarchy above already retains the control inventory.
        try require(advanced, phase,
                    "slide count did not reach \(expected) after Insert Slide")
        try showFixtureSlide(app, phase: phase)
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
        let deadline = Date().addingTimeInterval(60)
        var dismissed = false
        while Date() < deadline {
            try require(app.state == .runningForeground, closePhase,
                        "Floe left the foreground during save-and-close")
            // Notes remains in the outer split-view accessibility tree behind
            // its editor. Existence alone falsely acknowledged a refused save.
            if !anyElement(app, "office.editor.native").exists
                && !anyElement(app, "office.preview.native").exists
                && !back.exists && library.exists && library.isHittable {
                dismissed = true
                break
            }
            Thread.sleep(forTimeInterval: 0.5)
        }
        try require(dismissed, closePhase,
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
            // Make the preview frame deterministic: select the fixture's
            // FIRST slide through the real thumbnail rail (the generation
            // can mount mid-carousel), so the marker pixels really live in
            // the analysed document region.
            try showFixtureSlide(app, phase: "preview-open")
            shot("01-preview")

            // 2) Real host Edit action: the preview native closes and a NEW
            //    editable generation mounts and acknowledges edit.
            try enterEdit(app, phase: "enter-edit")
            mark("enter-edit", true)

            // 3) Real content change: insert a slide (2 -> 3).
            try insertSlide(app, expected: 3, phase: "insert-slide")
            mark("insert-slide", true)
            try waitForFixtureSlideMarkers(app, timeout: 20, phase: "insert-slide")
            shot("02-edit")

            // 3b) Real presentation: the App's 放映 action drives the
            //     genuine slideshow. The real insert order is
            //     [fixture slide 1, inserted blank slide, fixture slide 2]
            //     (Insert Page adds after the current page), so the
            //     presentation must be observed deterministically as:
            //       page 1  = fixture slide 1 (blue title + orange bar)
            //       page 2  = the inserted blank slide (negative control,
            //                 never accepted as content)
            //       page 3  = fixture slide 2 (green oval)
            //     Every step requires the slideshow letterbox (still
            //     presenting) and markers INSIDE the document region, so app
            //     chrome, an editor frame behind the canvas, or tapping to an
            //     arbitrary colored page can never satisfy the phase.
            let presentationStart = anyElement(app, "office.presentation.start")
            try require(presentationStart.waitForExistence(timeout: 20) && presentationStart.isEnabled
                        && presentationStart.isHittable, "slideshow-start",
                        "the real presentation control is not actionable")
            let tabsBeforePresentation = documentTabIDs(app)
            try require(!tabsBeforePresentation.isEmpty, "slideshow-start",
                        "the document tab identity is missing before presenting")
            presentationStart.tap()
            mark("slideshow-start", true)
            Thread.sleep(forTimeInterval: 5)

            let pageOneFacts = slideshowFrameFacts(XCUIScreen.main.screenshot().image)
            shot("10-slideshow-page1")
            try require(app.state == .runningForeground, "slideshow-page1",
                        "Floe left the foreground while presenting")
            try require(pageOneFacts.isPresenting && pageOneFacts.isFixtureSlideOne,
                        "slideshow-page1",
                        "presented fixture slide 1 is missing in its document region: "
                            + "black=\(pageOneFacts.blackFraction) blue=\(pageOneFacts.cropBlue) "
                            + "orange=\(pageOneFacts.cropOrange) green=\(pageOneFacts.cropGreen)")
            mark("slideshow-page1", true,
                 "blue=\(pageOneFacts.cropBlue) orange=\(pageOneFacts.cropOrange) "
                    + "black=\(pageOneFacts.blackFraction)")

            guard let blankFacts = advanceOneSlideshowPage(app, from: pageOneFacts) else {
                throw NSError(domain: "OfficeRealEngineUITests", code: 3,
                              userInfo: [NSLocalizedDescriptionKey:
                                            "no verified single-page advance from fixture slide 1"])
            }
            shot("11-slideshow-blank-page")
            try require(app.state == .runningForeground, "slideshow-blank-page",
                        "Floe left the foreground while presenting")
            try require(blankFacts.isPresenting && blankFacts.isInsertedBlank,
                        "slideshow-blank-page",
                        "page 2 is not the expected inserted blank page (wrong page or chrome): "
                            + "black=\(blankFacts.blackFraction) blue=\(blankFacts.cropBlue) "
                            + "orange=\(blankFacts.cropOrange) green=\(blankFacts.cropGreen)")
            mark("slideshow-blank-page", true,
                 "inserted blank page observed as page 2 (no fixture markers)")

            guard let pageTwoFacts = advanceOneSlideshowPage(app, from: blankFacts) else {
                throw NSError(domain: "OfficeRealEngineUITests", code: 3,
                              userInfo: [NSLocalizedDescriptionKey:
                                            "no verified single-page advance from the blank page"])
            }
            shot("12-slideshow-page2")
            try require(app.state == .runningForeground, "slideshow-page2",
                        "Floe left the foreground while presenting")
            try require(pageTwoFacts.isPresenting && pageTwoFacts.isFixtureSlideTwo,
                        "slideshow-page2",
                        "presented fixture slide 2 green oval missing in its document region: "
                            + "black=\(pageTwoFacts.blackFraction) blue=\(pageTwoFacts.cropBlue) "
                            + "orange=\(pageTwoFacts.cropOrange) green=\(pageTwoFacts.cropGreen)")
            try require(slideshowDiffRatio(pageOneFacts.rgba, pageTwoFacts.rgba) > 0.01,
                        "slideshow-page2",
                        "fixture slide 2 frame is identical to slide 1 (wrong page)")
            mark("slideshow-page2", true,
                 "green=\(pageTwoFacts.cropGreen) black=\(pageTwoFacts.blackFraction)")

            // Touch quit path of the real slideshow: a vertical swipe ends
            // the presentation (Escape is unavailable to XCUITest on iOS).
            // Exit is proven by the letterbox being GONE (the editor chrome
            // mounted behind a still-active canvas cannot satisfy this), the
            // editable surface ready, and the real edit thumbnail rail being
            // interactive (tap + selected) on the SAME document identity.
            let editorSurface = anyElement(app, "office.editor.native")
            let editorBack = anyElement(app, "office.editor.back")
            var presentationExited = false
            let exitAttempts: [(CGFloat, CGFloat)] = [(0.25, 0.92), (0.92, 0.25)]
            let exitDeadline = Date().addingTimeInterval(45)
            var exitAttempt = 0
            var exitFacts = blankFacts
            while Date() < exitDeadline && !presentationExited {
                if exitAttempt < exitAttempts.count {
                    let from = app.coordinate(withNormalizedOffset:
                                                CGVector(dx: 0.5, dy: exitAttempts[exitAttempt].0))
                    let to = app.coordinate(withNormalizedOffset:
                                              CGVector(dx: 0.5, dy: exitAttempts[exitAttempt].1))
                    from.press(forDuration: 0.05, thenDragTo: to)
                    exitAttempt += 1
                }
                Thread.sleep(forTimeInterval: 2.5)
                exitFacts = slideshowFrameFacts(XCUIScreen.main.screenshot().image)
                if app.state == .runningForeground && !exitFacts.isPresenting
                    && exitFacts.blackFraction < 0.02
                    && editorSurface.exists && documentIsReady(editorSurface)
                    && editorBack.exists && editorBack.isEnabled {
                    presentationExited = true
                }
            }
            try require(presentationExited, "slideshow-exit",
                        "presentation letterbox/overlay did not exit (black=\(exitFacts.blackFraction))")
            // Real edit rail interaction: the fixture slide 1 thumbnail must
            // be visible, hittable and become SELECTED through the app's own
            // thumbnail control after the presentation exits.
            try showFixtureSlide(app, phase: "slideshow-exit")
            let tabsAfterPresentation = documentTabIDs(app)
            try require(!tabsAfterPresentation.isEmpty
                        && tabsAfterPresentation == tabsBeforePresentation,
                        "slideshow-exit",
                        "document identity changed across the presentation: "
                            + "\(tabsBeforePresentation) -> \(tabsAfterPresentation)")
            shot("13-slideshow-exit")
            mark("slideshow-exit", true, "same document, editable rail selected")

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
            // The canvas repaints white for a moment after the insertion;
            // capture only after the real fixture content is back.
            try waitForFixtureSlideMarkers(app, timeout: 20, phase: "insert-slide-again")
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
            try showFixtureSlide(app, phase: "verify-persisted")
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
