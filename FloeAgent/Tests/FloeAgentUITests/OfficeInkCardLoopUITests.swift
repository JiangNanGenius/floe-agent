// SPDX-License-Identifier: MPL-2.0
import XCTest
import UIKit

/// The actual Main-App saved-ink library-card UI loop — Word, Calc and PPT.
///
/// What this suite IS (the full loop, nothing substituted):
///   * The REAL app under `-ui-testing` with a UNIQUE task-owned Office
///     document seeded through the existing production `NoteFileImporter`
///     path at launch (`OfficeInkCardLoopFixture`; same convention as the
///     accepted pinch fixtures). The fixture identity strings below are
///     duplicated verbatim from `OfficeInkCardLoopFixture.swift` because the
///     UI-test target cannot import the app target — keep them in sync.
///   * REAL UIKit navigation only: the real library card is tapped, the real
///     preview/Edit entry runs, the real `office.drawing.toggle` turns
///     drawing on, the REAL owned `office.editor.back` control performs the
///     production save/exit, and the ACTUAL displayed library card is read
///     from `notes.library.scroll` — no `session.select(nil)`, no alternate
///     window/runtime, no manually seeded cover and no direct cover-renderer
///     call as a substitute for what the library shows.
///   * The ink itself is one clearly labeled injected native pen fixture:
///     the DEBUG + launch-flag-gated `office.ink-fixture.*` seam dispatches
///     exactly one synthetic pen PointerEvent curve through the production
///     canvas-capture bridge of THIS editor's own WKWebView, with the red
///     2.0 mm opaque stroke applied through the production
///     `OfficeInkPreferences`/`applyInkPreferences()` path (saved and
///     restored). XCUITest cannot synthesize a physical Pencil; this is a
///     labeled fixture, never a physical-device-feel claim.
///   * Readiness is state-observed: the seam must publish
///     `ink-dirty-verified`, which the app produces only after the
///     production bridge reports the contact drained AND the engine's own
///     `.uno:ModifiedStatus` probe (TRUE, never unknown) plus the session's
///     production `hasLocalEditsToProtect()` predicate both report these
///     edits worth protecting; the on-disk `hasUncommittedChanges` flag is
///     receipt evidence only, never a pass condition.
///     There is no fixed sleep standing in for the flush, and the real Back
///     guard still performs its own asynchronous save.
///   * Final proof: the settled card identity must be
///     `officeSavedPreview#<revision>` with the revision strictly greater
///     than the baseline revision bound during the first (preview-only)
///     visit, the post-save card pixels must contain saved red ink, and the
///     pre-save baseline card must be ink-free. The whole-card dark-pixel
///     gate is SUPPORTING only — the crop includes the card's title/chrome,
///     so it is not independent proof of original text inside the preview;
///     root's actual card-preview inspection plus the read-only postflight
///     marker check carry that claim. `postflight_ink_card.py` additionally
///     verifies the committed resource's vector count/color/marker and the
///     preview-source binding; the UI pass alone never claims file truth.
///
/// Explicit non-goals: zero-motion dots (separate Deep task), event-time
/// probe/pinch geometry and the Word keyboard-hide regression (separate
/// jobs), Calc clipping (separate job). This suite launches WITHOUT the
/// touch-probe argument, so the passive probe family is untouched.
///
/// Opt-in: FLOE_OFFICE_INK_CARD_UI=1. Serial on the canonical device.
@MainActor
final class OfficeInkCardLoopUITests: XCTestCase {

    // MARK: Fixture identity convention (keep in sync with OfficeInkCardLoopFixture)

    private enum Format {
        case word, calc, presentation

        var launchArgument: String {
            switch self {
            case .word: return "--ui-test-office-ink-card-word-fixture"
            case .calc: return "--ui-test-office-ink-card-calc-fixture"
            case .presentation: return "--ui-test-office-ink-card-presentation-fixture"
            }
        }
        var fileSuffix: String {
            switch self {
            case .word: return "Word"
            case .calc: return "Calc"
            case .presentation: return "Deck"
            }
        }
    }

    private func ownedTitle(format: Format, token: String) -> String {
        "墨卡闭环-\(format.fileSuffix)-\(token)"
    }

    func testWordSavedInkReachesActualLibraryCardFromMainApp() throws {
        try runInkCardLoop(format: .word, casePrefix: "ink-card-word")
    }

    func testCalcSavedInkReachesActualLibraryCardFromMainApp() throws {
        try runInkCardLoop(format: .calc, casePrefix: "ink-card-calc")
    }

    func testPresentationSavedInkReachesActualLibraryCardFromMainApp() throws {
        try runInkCardLoop(format: .presentation, casePrefix: "ink-card-presentation")
    }

    // MARK: - The loop

    private func runInkCardLoop(format: Format, casePrefix: String) throws {
        guard ProcessInfo.processInfo.environment["FLOE_OFFICE_INK_CARD_UI"] == "1" else {
            throw XCTSkip("Opt-in Main-App ink-card UI qualification; set FLOE_OFFICE_INK_CARD_UI=1 in the test runner environment.")
        }
        continueAfterFailure = false
        let ipad = ProcessInfo.processInfo.environment["SIMULATOR_MODEL_IDENTIFIER"]?.hasPrefix("iPad") == true
            || UIDevice.current.userInterfaceIdiom == .pad
        // Handshake override for the output-proof flow (bounded, opt-in):
        // the runner may pin the fixture token with FLOE_OFFICE_INK_CARD_TOKEN
        // so it can pre-launch the seeding, freeze the pre-drawing baseline
        // for the SAME uniquely titled document, and only then start the
        // suite. The ENTIRE string is validated as 4...12 lowercase hex
        // characters; any other value (empty, malformed, wrong length,
        // uppercase, non-hex) falls back to the original random token with
        // no silent character deletion. The suite is already opt-in via
        // FLOE_OFFICE_INK_CARD_UI, and the App-side fixture re-validates the
        // token strictly before anything seeds.
        let hexDigits = Set("0123456789abcdef")
        let pinned = ProcessInfo.processInfo.environment["FLOE_OFFICE_INK_CARD_TOKEN"] ?? ""
        let token = (4...12).contains(pinned.count) && pinned.allSatisfy { hexDigits.contains($0) }
            ? pinned
            : String(UUID().uuidString.lowercased().filter { $0.isHexDigit }.prefix(8))
        XCTAssertGreaterThanOrEqual(token.count, 4, "the run token must be parseable by the fixture")
        let title = ownedTitle(format: format, token: token)

        let app = XCUIApplication()
        app.terminate()
        XCUIDevice.shared.orientation = ipad ? .landscapeLeft : .portrait
        app.launchArguments = ["-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN", "-ui-testing",
                               "--ui-test-skip-onboarding", "--ui-test-batch-fixture",
                               format.launchArgument,
                               "--ui-test-office-ink-card-token", token]
        if ipad { app.launchArguments.append("-ui-testing-ipad") }
        app.launch()
        defer { app.terminate() }
        if ipad { requireLandscapeAfterLaunch(app) }
        if !ipad {
            let sidebar = app.buttons["phone.sidebar.open"]
            XCTAssertTrue(sidebar.waitForExistence(timeout: 15)); sidebar.tap()
        }
        let notes = app.staticTexts["sidebar.notes"].firstMatch
        XCTAssertTrue(notes.waitForExistence(timeout: 15)); notes.tap()

        // The seed ran at launch through the real importer; the card must
        // appear through the ordinary library path (bounded). Enter through
        // the real card, not any programmatic selection.
        revealCard(app, kind: "office", title: title).tap()

        // MARK: Visit 1 — the production rule: the first entry is the preview.
        // Opening it lets the read-only editor backfill the generated saved
        // preview for the ORIGINAL resource, giving an honest ink-free
        // baseline card. The exit is the real Back control (read-only: no
        // save is performed by the guard).
        let back = app.buttons["office.editor.back"]
        XCTAssertTrue(back.waitForExistence(timeout: 60),
                      "the native Office editor surface must open for the owned fixture")
        XCTAssertTrue(waitUntil(timeout: 60, { back.isEnabled && back.isHittable }),
                      "the fixture document must finish opening before the baseline visit exits")
        XCTAssertEqual(app.buttons.matching(identifier: "office.editor.back").count, 1,
                       "exactly one owned editor back control may exist")
        XCTAssertFalse(app.buttons["notes.back"].exists,
                       "the Office editor exit must be owned by office.editor.back, not the hidden Notes header")
        assertTouchTarget(back)
        XCTAssertTrue(app.webViews.count >= 1,
                      "the real native engine surface (WKWebView) must be mounted for the fixture")
        back.tap()
        let libraryCreate = creationControl(app)
        XCTAssertTrue(waitUntil(timeout: 60, {
            libraryCreate.exists && libraryCreate.isHittable && !back.exists
        }), "the preview visit must exit into the actionable Notes library")
        XCTAssertFalse(back.exists)

        // Baseline cover: the backfill must bind the ORIGINAL resource's
        // generated saved preview, and the baseline card must contain no red
        // ink (the fixture document is created without any drawing object).
        let card = cardElement(app, kind: "office", title: title)
        var baseline = ParsedCover(source: "missing", revision: 0)
        XCTAssertTrue(waitUntil(timeout: 90) {
            guard card.exists else { return false }
            baseline = parseCover(card.identifier)
            return baseline.source == "officeSavedPreview" && baseline.revision >= 1
        }, "the baseline card must settle on the generated officeSavedPreview of the original resource")
        let baselineCover = baseline
        let baselineShot = card.screenshot().image
        attach(baselineShot, name: "\(casePrefix)-baseline-library-card")
        XCTAssertEqual(redPixels(baselineShot), 0,
                       "the pre-save library card must contain no ink")
        let baselinePNG = baselineShot.pngData()

        // MARK: Visit 2 — the real editor, real drawing controls.
        _ = revealCard(app, kind: "office", title: title)
        card.tap()
        XCTAssertTrue(back.waitForExistence(timeout: 60))
        XCTAssertTrue(waitUntil(timeout: 60, { back.isEnabled && back.isHittable }))
        let toggle = app.buttons["office.drawing.toggle"]
        let edit = app.buttons["office.preview.edit"]
        XCTAssertTrue(waitUntil(timeout: 60, { toggle.exists || edit.exists }),
                      "the Office surface must reach the editable pen toolbar or the host Edit action")
        if !toggle.exists {
            XCTAssertTrue(waitUntil(timeout: 30, { edit.isEnabled && edit.isHittable }),
                          "the preview's Edit action must become actionable")
            assertTouchTarget(edit)
            edit.tap()
        }
        XCTAssertTrue(toggle.waitForExistence(timeout: 60),
                      "the editable Office toolbar must expose the direct pen toggle")
        XCTAssertTrue(waitUntil(timeout: 60, { toggle.exists && toggle.isEnabled && toggle.isHittable }))
        XCTAssertTrue(waitForDrawingValue(toggle, on: false, timeout: 15),
                      "the pen toggle must start in the real Off state for the fixture document")

        // The seam is invisible while drawing is off (negative control).
        XCTAssertFalse(app.buttons["office.ink-fixture.inject"].exists,
                       "the labeled ink fixture control must not exist before the real drawing toggle is on")

        toggle.tap()
        XCTAssertTrue(waitForDrawingValue(toggle, on: true, timeout: 30),
                      "one tap on the direct toggle must turn drawing on")
        XCTAssertTrue(app.keyboards.firstMatch.waitForNonExistence(timeout: 15),
                      "enabling drawing must dismiss the Office text keyboard")

        // The gated seam attached to THIS editor must now be present.
        let inject = app.buttons["office.ink-fixture.inject"]
        XCTAssertTrue(inject.waitForExistence(timeout: 30),
                      "the launch-flag-gated ink fixture seam must attach to the owned editable drawing-on editor")
        let statusElement = app.staticTexts["office.ink-fixture.status"]
        XCTAssertTrue(statusElement.waitForExistence(timeout: 15))
        XCTAssertEqual(seamStatus(statusElement), "ready",
                       "the seam must idle in the ready state until the explicit tap")

        // Editor ink baseline on the real screen (before the contact).
        let web = app.webViews.firstMatch
        XCTAssertTrue(web.waitForExistence(timeout: 10))
        let editorBefore = web.screenshot().image
        attach(editorBefore, name: "\(casePrefix)-editor-before-contact")
        let redBeforeEditor = redPixels(editorBefore)

        // Trigger exactly one labeled injected pen curve through the
        // production canvas-capture bridge of the current editor.
        inject.tap()
        var finalStatus = ""
        let seamDeadline = Date().addingTimeInterval(90)
        while Date() < seamDeadline {
            finalStatus = seamStatus(statusElement)
            if finalStatus == "ink-dirty-verified" || finalStatus == "cancelled"
                || finalStatus.hasPrefix("failed") { break }
            Thread.sleep(forTimeInterval: 0.25)
        }
        let factsElement = app.staticTexts["office.ink-fixture.facts"]
        attachText("status=\(finalStatus) facts=\(factsElement.exists ? factsElement.label : "none") token=\(token) title=\(title)",
                   name: "\(casePrefix)-seam-receipt")
        XCTAssertEqual(finalStatus, "ink-dirty-verified",
                       "the seam must drain the contact through the production bridge and observe BOTH the engine's TRUE modified state and the session's production protection predicate before the Back save")

        // Visible red ink in the REAL editor before any navigation.
        let editorAfter = web.screenshot().image
        attach(editorAfter, name: "\(casePrefix)-editor-after-contact")
        XCTAssertGreaterThan(redPixels(editorAfter) - redBeforeEditor, 80,
                             "the injected pen contact must be visibly red in the editor before the save")
        XCTAssertTrue(waitForDrawingValue(toggle, on: true, timeout: 10),
                      "the ink fixture must leave the real drawing state unchanged")

        // MARK: The real Back/save through the product's own exit path.
        XCTAssertTrue(waitUntil(timeout: 15, { back.isEnabled && back.isHittable }))
        back.tap()

        // Root-corrected genuine-foreground exit gate (App10 shape, preserved
        // exactly, plus the companion's chrome/webview absence): the owned
        // editor must leave the FOREGROUND; background existence of library
        // chrome is not acceptance.
        let editorGone = waitUntil(timeout: 60) {
            libraryCreate.exists && libraryCreate.isHittable && !back.exists
                && !app.descendants(matching: .any).matching(identifier: "office.editor.header").firstMatch.exists
                && app.webViews.count == 0
        }
        if !editorGone {
            let tree = XCTAttachment(string: app.debugDescription)
            tree.name = "\(casePrefix)-still-foreground-tree"; tree.lifetime = .keepAlways
            add(tree)
            capture(app, name: "\(casePrefix)-still-foreground")
        }
        XCTAssertTrue(editorGone,
                      "the owned Office editor must finish its asynchronous save/exit into the actionable foreground Notes library")
        XCTAssertFalse(back.exists)
        capture(app, name: "\(casePrefix)-notes-library-returned")

        // MARK: The ACTUAL displayed library card.
        var settled = ParsedCover(source: "missing", revision: 0)
        _ = revealCard(app, kind: "office", title: title)
        XCTAssertTrue(waitUntil(timeout: 90) {
            guard card.exists else { return false }
            settled = parseCover(card.identifier)
            return settled.source == "officeSavedPreview" && settled.revision > baselineCover.revision
        }, "the library card must rebind to the freshly saved preview at a revision greater than \(baselineCover.revision)")
        let cardShot = card.screenshot().image
        attach(cardShot, name: "\(casePrefix)-final-library-card-ink")
        XCTAssertGreaterThan(redPixels(cardShot), 10,
                             "the actual displayed library card must retain the saved red ink")
        // Supporting signal ONLY: the whole-card crop includes the card's
        // title/chrome text, so this threshold cannot by itself prove that
        // original document content is inside the preview region. Original
        // content retention is verified by root's actual card-preview image
        // inspection and independently by the postflight marker check.
        XCTAssertGreaterThan(darkPixels(cardShot), 40,
                             "supporting only (card chrome/title included): the card must still render dark content")
        if let baselinePNG, let finalPNG = cardShot.pngData() {
            XCTAssertNotEqual(baselinePNG, finalPNG,
                              "the post-save card must be fresh bytes, not a re-labeled cache entry")
        }
        // The bounded POSTFLIGHT identity now also carries the UI-OBSERVED
        // card source rule ids: the production officeSavedPreview rule can
        // only render when the saved preview is bound to the document's
        // CURRENT office resource (NoteModels.matchingOfficePreviewResourceID
        // requires officePreviewSourceID == officeResourceID), so the runner
        // postflight can pin the frozen baseline resource against the exact
        // pre-contact generation via the persisted edit-history lineage.
        attachText("POSTFLIGHT title=\(title) baseline-source=\(baselineCover.source) baseline-revision=\(baselineCover.revision) final-source=\(settled.source) final-revision=\(settled.revision) marker=INKCARD-ORIG-\(format.fileSuffix)-\(token)",
                   name: "\(casePrefix)-postflight-instructions")
    }

    // MARK: - Seam status (raw diagnostic tokens are intentionally unlocalized)

    private func seamStatus(_ element: XCUIElement) -> String {
        let value = element.value as? String
        let text = element.label
        let candidate = ((value?.isEmpty == false) ? value! : text)
        return candidate.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Pixel facts (fixture-card and fixture-editor only; synthetic content)

    private func redPixels(_ image: UIImage?) -> Int {
        countPixels(image) { r, g, b in r > 140 && r > g * 3 / 2 && r > b * 3 / 2 }
    }

    private func darkPixels(_ image: UIImage?) -> Int {
        countPixels(image) { r, g, b in r < 90 && g < 90 && b < 90 }
    }

    private func countPixels(_ image: UIImage?, _ match: (Int, Int, Int) -> Bool) -> Int {
        guard let cg = image?.cgImage else { return 0 }
        let width = cg.width, height = cg.height
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        let flags = CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
        let rendered = bytes.withUnsafeMutableBytes { storage -> Bool in
            guard let context = CGContext(data: storage.baseAddress, width: width, height: height,
                                          bitsPerComponent: 8, bytesPerRow: width * 4,
                                          space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: flags) else { return false }
            context.draw(cg, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard rendered else { return 0 }
        return stride(from: 0, to: bytes.count, by: 4).reduce(into: 0) { count, offset in
            if match(Int(bytes[offset]), Int(bytes[offset + 1]), Int(bytes[offset + 2])) { count += 1 }
        }
    }

    // MARK: - Helpers (self-contained; shapes copied verbatim from the current
    // NotesWorkspaceImportUITests conventions, incl. the SDK27 bounded-index
    // card query. This suite deliberately does NOT modify that root-owned file.)

    private struct ParsedCover {
        let source: String
        let revision: Int
    }

    private func waitUntil(timeout: TimeInterval, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            Thread.sleep(forTimeInterval: 0.25)
        }
        return condition()
    }

    private func creationControl(_ app: XCUIApplication) -> XCUIElement {
        app.navigationBars.buttons.matching(identifier: "notes.create").element(boundBy: 0)
    }

    private func cardElement(_ app: XCUIApplication, kind: String, title: String) -> XCUIElement {
        app.scrollViews["notes.library.scroll"].buttons
            .matching(NSPredicate(format: "identifier BEGINSWITH %@", "notes.card.\(kind).\(title)."))
            .element(boundBy: 0)
    }

    @discardableResult
    private func revealCard(_ app: XCUIApplication, kind: String, title: String,
                            file: StaticString = #filePath, line: UInt = #line) -> XCUIElement {
        let card = cardElement(app, kind: kind, title: title)
        if card.exists && card.isHittable { return card }
        let scroll = app.scrollViews["notes.library.scroll"]
        guard scroll.waitForExistence(timeout: 5) else {
            XCTAssertTrue(card.waitForExistence(timeout: 30), "card \(title) must exist", file: file, line: line)
            return card
        }
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.02)).tap()
        Thread.sleep(forTimeInterval: 0.4)
        if !(card.exists && card.isHittable) {
            for _ in 0..<6 where !(card.exists && card.isHittable) { scroll.swipeDown() }
        }
        let deadline = Date().addingTimeInterval(60)
        while !(card.exists && card.isHittable) && Date() < deadline { scroll.swipeUp() }
        XCTAssertTrue(card.exists && card.isHittable,
                      "card \(title) must be reachable in the library grid", file: file, line: line)
        return card
    }

    /// The card identifier ends in `<source>#<revision>` (see `NotesRootView`).
    private func parseCover(_ identifier: String) -> ParsedCover {
        let suffix = identifier.components(separatedBy: ".").last ?? "none"
        let parts = suffix.components(separatedBy: "#")
        return ParsedCover(source: parts.first ?? "none",
                           revision: Int(parts.dropFirst().first ?? "") ?? 0)
    }

    private func waitForDrawingValue(_ toggle: XCUIElement, on: Bool, timeout: TimeInterval) -> Bool {
        waitUntil(timeout: timeout) {
            guard toggle.exists else { return false }
            let value = ((toggle.value as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            return on ? (value == "已开启" || value == "On") : (value == "已关闭" || value == "Off")
        }
    }

    private func requireLandscapeAfterLaunch(_ app: XCUIApplication,
                                             file: StaticString = #filePath, line: UInt = #line) {
        XCUIDevice.shared.orientation = .landscapeLeft
        let landscape = NSPredicate { _, _ in
            let frame = app.windows.firstMatch.frame
            return frame.width > frame.height && frame.height > 0
        }
        if XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: landscape, object: app)],
                          timeout: 10) == .completed { return }
        XCUIDevice.shared.orientation = .portrait
        let portrait = NSPredicate { _, _ in
            let frame = app.windows.firstMatch.frame
            return frame.height > frame.width && frame.width > 0
        }
        _ = XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: portrait, object: app)], timeout: 5)
        XCUIDevice.shared.orientation = .landscapeLeft
        let result = XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: landscape, object: app)],
                                   timeout: 15)
        XCTAssertEqual(result, .completed, "the iPad App must settle in landscape", file: file, line: line)
    }

    private func assertTouchTarget(_ element: XCUIElement, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertGreaterThanOrEqual(element.frame.width, 43.5, file: file, line: line)
        XCTAssertGreaterThanOrEqual(element.frame.height, 43.5, file: file, line: line)
    }

    private func capture(_ app: XCUIApplication, name: String) {
        let image = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        image.name = name
        image.lifetime = .keepAlways
        add(image)
    }

    /// Attaches an ALREADY-captured element image through the public XCTest
    /// image initializer. `XCUIScreenshot(image:)` does not exist in the
    /// Xcode 27 SDK (XCUIScreenshot only exposes captured screenshots), so
    /// no screenshot object is fabricated here.
    private func attach(_ image: UIImage, name: String) {
        let attachment = XCTAttachment(image: image)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func attachText(_ text: String, name: String) {
        let attachment = XCTAttachment(string: text)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
