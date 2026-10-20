// SPDX-License-Identifier: MPL-2.0
import XCTest
import UIKit
import Vision

/// Captures the verified on-screen tap point of a menu row so the tap never
/// depends on a second (potentially stale) accessibility frame read.
private final class AXMenuPoint: @unchecked Sendable {
    var center: CGPoint?
}

@MainActor
final class NotesWorkspaceImportUITests: XCTestCase {
    func testOfficeHeaderAssistantSaveAndReopen() throws {
        #if targetEnvironment(simulator)
        throw XCTSkip("FloeOfficeNative is linked only into iphoneos builds; native Office requires device acceptance.")
        #else
        continueAfterFailure = false
        let ipad = ProcessInfo.processInfo.environment["SIMULATOR_MODEL_IDENTIFIER"]?.hasPrefix("iPad") == true || UIDevice.current.userInterfaceIdiom == .pad
        let app = XCUIApplication()
        app.terminate()
        XCUIDevice.shared.orientation = ipad ? .landscapeLeft : .portrait
        app.launchArguments = ["-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN", "-ui-testing", "--ui-test-skip-onboarding", "--ui-test-batch-fixture"]
        if ipad { app.launchArguments.append("-ui-testing-ipad") }
        app.launch()
        defer { app.terminate() }
        if !ipad {
            let sidebar = app.buttons["phone.sidebar.open"]
            XCTAssertTrue(sidebar.waitForExistence(timeout: 15)); sidebar.tap()
        }
        let notes = app.staticTexts["sidebar.notes"].firstMatch
        XCTAssertTrue(notes.waitForExistence(timeout: 15)); notes.tap()
        let create = creationControl(app)
        XCTAssertTrue(create.waitForExistence(timeout: 15))
        wait(for: [expectation(for: NSPredicate(format: "enabled == true"), evaluatedWith: create)], timeout: 10)
        create.tap(); app.buttons["Office"].tap()
        // UIKit's nested menu retains the visible title but drops SwiftUI's
        // accessibilityIdentifier on its generated action buttons.
        let word = app.buttons["Word 文档"]
        XCTAssertTrue(word.waitForExistence(timeout: 5)); word.tap()
        let title = app.textFields["notes.create.title"]
        XCTAssertTrue(title.waitForExistence(timeout: 5))
        title.tap(); title.typeText("Office toolbar check")
        app.buttons["创建"].tap()
        let back = app.buttons["office.editor.back"]
        XCTAssertTrue(back.waitForExistence(timeout: 45))
        wait(for: [expectation(for: NSPredicate(format: "enabled == true AND hittable == true"), evaluatedWith: back)], timeout: 60)
        XCTAssertEqual(app.buttons.matching(identifier: "office.editor.back").count, 1)
        assertTouchTarget(back)
        let header = app.descendants(matching: .any).matching(identifier: "office.editor.header").firstMatch
        XCTAssertTrue(header.exists)
        XCTAssertLessThan(header.frame.height, 75)
        XCTAssertFalse(app.buttons["notes.header.toggle"].exists)
        capture("notes-office-single-header")
        let assistant = app.buttons["notes.office.assistant"]
        XCTAssertTrue(assistant.isHittable); assistant.tap()
        app.buttons["Floe 助手"].tap()
        let close = app.buttons["notes.assistant.close"]
        XCTAssertTrue(close.waitForExistence(timeout: 10))
        XCTAssertEqual(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "已选择手记文档")).count, 0)
        capture("notes-office-document-assistant")
        close.tap()
        wait(for: [expectation(for: NSPredicate(format: "hittable == true"), evaluatedWith: back)], timeout: 10)
        back.tap() // Native save followed by the Notes resource-revision commit.
        XCTAssertTrue(create.waitForExistence(timeout: 30))
        XCTAssertFalse(back.exists)
        let document = app.buttons.containing(.staticText, identifier: "Office toolbar check").firstMatch
        XCTAssertTrue(document.waitForExistence(timeout: 10)); document.tap()
        XCTAssertTrue(back.waitForExistence(timeout: 30))
        wait(for: [expectation(for: NSPredicate(format: "enabled == true AND hittable == true"), evaluatedWith: back)], timeout: 45)
        capture("notes-office-reopened")
        back.tap()
        XCTAssertTrue(create.waitForExistence(timeout: 30))
        #endif
    }

    /// Opt-in real-App regression for the two Office pen toolbar entries: the
    /// direct drawing toggle and the separate pen-settings panel. The App under
    /// test must link the native Office host (this workspace's
    /// `native-host.xcconfig`), so the test never assumes the simulator engine
    /// or silently degrades to a placeholder. It proves the App's real controls
    /// and their accessibility state only; no Pencil stroke is synthesized.
    func testOfficePencilToolbarToggleAndSettings() throws {
        guard ProcessInfo.processInfo.environment["FLOE_OFFICE_PENCIL_UI_QUALIFICATION"] == "1" else {
            throw XCTSkip("Opt-in Office pen toolbar UI qualification; set FLOE_OFFICE_PENCIL_UI_QUALIFICATION=1 in the test runner environment.")
        }
        continueAfterFailure = false
        let ipad = ProcessInfo.processInfo.environment["SIMULATOR_MODEL_IDENTIFIER"]?.hasPrefix("iPad") == true
            || UIDevice.current.userInterfaceIdiom == .pad
        let app = XCUIApplication()
        app.terminate()
        XCUIDevice.shared.orientation = ipad ? .landscapeLeft : .portrait
        app.launchArguments = ["-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN", "-ui-testing",
                               "--ui-test-skip-onboarding", "--ui-test-batch-fixture"]
        if ipad { app.launchArguments.append("-ui-testing-ipad") }
        app.launch()
        defer { app.terminate() }
        if !ipad {
            let sidebar = app.buttons["phone.sidebar.open"]
            XCTAssertTrue(sidebar.waitForExistence(timeout: 15)); sidebar.tap()
        }
        let notes = app.staticTexts["sidebar.notes"].firstMatch
        XCTAssertTrue(notes.waitForExistence(timeout: 15)); notes.tap()
        let create = creationControl(app)
        XCTAssertTrue(create.waitForExistence(timeout: 15))
        wait(for: [expectation(for: NSPredicate(format: "enabled == true"), evaluatedWith: create)], timeout: 10)
        create.tap()
        let office = app.buttons["Office"]
        XCTAssertTrue(office.waitForExistence(timeout: 10)); office.tap()
        // UIKit's nested menu retains the visible title but drops SwiftUI's
        // accessibilityIdentifier on its generated action buttons.
        let word = app.buttons["Word 文档"]
        XCTAssertTrue(word.waitForExistence(timeout: 10))
        // The nested UIKit menu exposes its AX button before its slide
        // animation finishes. Wait for the actual target frame to settle.
        var previousWordFrame = CGRect.null
        var wordFrameStableSince = Date()
        XCTAssertTrue(waitUntil(timeout: 10, {
            guard word.exists, word.isEnabled, word.isHittable else {
                previousWordFrame = .null
                return false
            }
            let frame = word.frame
            guard !frame.isEmpty else { return false }
            if frame != previousWordFrame {
                previousWordFrame = frame
                wordFrameStableSince = Date()
                return false
            }
            return Date().timeIntervalSince(wordFrameStableSince) >= 0.5
        }), "the Word menu action must settle before selection")
        word.tap()
        let title = app.textFields["notes.create.title"]
        XCTAssertTrue(title.waitForExistence(timeout: 10))
        title.tap()
        let token = UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(8)
        title.typeText("Pen UI \(token)")
        let createButton = app.buttons["创建"]
        XCTAssertTrue(createButton.waitForExistence(timeout: 10))
        wait(for: [expectation(for: NSPredicate(format: "enabled == true"), evaluatedWith: createButton)], timeout: 10)
        createButton.tap()

        let back = app.buttons["office.editor.back"]
        XCTAssertTrue(back.waitForExistence(timeout: 60),
                      "the native Office editor must open for the created Word document")
        wait(for: [expectation(for: NSPredicate(format: "enabled == true AND hittable == true"), evaluatedWith: back)], timeout: 60)

        let toggle = app.buttons["office.drawing.toggle"]
        let edit = app.buttons["office.preview.edit"]
        // A newly created document opens in the editor, while an existing
        // document can legitimately settle in the read-only preview first.
        // Accept either real product surface, then use the host Edit action
        // when the preview is the one that appeared.
        XCTAssertTrue(waitUntil(timeout: 60, { toggle.exists || edit.exists }),
                      "the Office surface must reach either the editable pen toolbar or the host Edit action")
        if !toggle.exists {
            XCTAssertTrue(edit.exists, "the Office preview must expose its Edit action")
            XCTAssertTrue(waitUntil(timeout: 30, { edit.isEnabled && edit.isHittable }),
                          "the preview's Edit action must become actionable")
            assertTouchTarget(edit)
            edit.tap()
        }
        XCTAssertTrue(toggle.waitForExistence(timeout: 60),
                      "the editable Office toolbar must expose the direct pen toggle after the native engine is ready")
        let settings = app.buttons["office.drawing.settings"]
        XCTAssertTrue(settings.waitForExistence(timeout: 15),
                      "the editable Office toolbar must expose the separate pen settings entry")
        XCTAssertTrue(waitUntil(timeout: 60, {
            toggle.exists && toggle.isEnabled && toggle.isHittable
                && settings.exists && settings.isEnabled && settings.isHittable
        }), "both pen entries must become actionable once editing is ready")
        assertTouchTarget(toggle)
        assertTouchTarget(settings)
        let windowFrame = app.windows.firstMatch.frame
        XCTAssertTrue(windowFrame.contains(CGPoint(x: toggle.frame.midX, y: toggle.frame.midY)),
                      "the direct pen toggle must be inside the visible App window")
        XCTAssertTrue(windowFrame.contains(CGPoint(x: settings.frame.midX, y: settings.frame.midY)),
                      "the pen settings entry must be inside the visible App window")
        XCTAssertEqual(app.buttons.matching(identifier: "office.drawing.toggle").count, 1)
        XCTAssertEqual(app.buttons.matching(identifier: "office.drawing.settings").count, 1)
        XCTAssertTrue(waitForDrawingValue(toggle, on: false, timeout: 15),
                      "the pen toggle must start in the real Off state")
        // The engine focuses its hidden text input on open. Require the real
        // software keyboard here so the dismissal below is actually exercised
        // instead of passing vacuously on a hardware-keyboard simulator.
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 15),
                      "the Office text input must show the software keyboard before drawing starts")
        recordPencilToolbarState(app, phase: "initial-off")
        Thread.sleep(forTimeInterval: 0.4)
        capture("office-pencil-toggle-off")

        toggle.tap()
        XCTAssertTrue(waitForDrawingValue(toggle, on: true, timeout: 30),
                      "one tap on the direct toggle must turn drawing on and publish On")
        XCTAssertTrue(waitUntil(timeout: 30, {
            toggle.exists && toggle.isEnabled && settings.exists && settings.isEnabled
        }), "the toolbar must finish applying the enabled pen state")
        // The engine autofocuses its hidden text input while opening. Enabling
        // drawing must end only that Office editing session, otherwise the
        // software keyboard keeps covering the page and squeezes the popover.
        XCTAssertTrue(app.keyboards.firstMatch.waitForNonExistence(timeout: 15),
                      "enabling drawing must dismiss the Office text keyboard")
        XCTAssertEqual(app.keyboards.count, 0, "no keyboard may remain after drawing is On")
        XCTAssertTrue(app.staticTexts["office.ink.panel"].waitForNonExistence(timeout: 2),
                      "turning drawing on must not open the pen settings popover")
        XCTAssertTrue(app.buttons["office.ink.startStop"].waitForNonExistence(timeout: 2),
                      "the redundant Start/End action must stay removed")
        recordPencilToolbarState(app, phase: "toggle-on")
        Thread.sleep(forTimeInterval: 0.4)
        capture("office-pencil-toggle-on")

        // Visible pinch acceptance uses the centered document in the separate
        // test below; the created document's top-left title leaves the viewport
        // under the public gesture. Creation and control checks stay here.

        settings.tap()
        let panel = app.staticTexts["office.ink.panel"]
        XCTAssertTrue(panel.waitForExistence(timeout: 15),
                      "the pen settings entry must present the actual control panel")
        let done = app.buttons["office.ink.done"]
        XCTAssertTrue(done.waitForExistence(timeout: 10),
                      "the pen settings panel must expose its explicit Done action")
        XCTAssertTrue(done.isHittable, "the explicit Done action must be tappable")
        assertTouchTarget(done)
        XCTAssertTrue(app.buttons["office.ink.color.black"].waitForExistence(timeout: 10),
                      "the pen settings panel must expose its real color controls")
        let width = app.descendants(matching: .any)
            .matching(identifier: "office.ink.width").firstMatch
        XCTAssertTrue(width.waitForExistence(timeout: 10),
                      "the pen settings panel must expose its real width slider")
        let extraFineWidth = app.buttons["office.ink.widthPreset.extraFine"]
        let hairlineWidth = app.buttons["office.ink.widthPreset.hairline"]
        let mediumWidth = app.buttons["office.ink.widthPreset.standard"]
        let boldWidth = app.buttons["office.ink.widthPreset.bold"]
        let extraBoldWidth = app.buttons["office.ink.widthPreset.extraBold"]
        for (name, control) in [("extra fine", extraFineWidth),
                                ("hairline", hairlineWidth),
                                ("medium", mediumWidth),
                                ("bold", boldWidth),
                                ("extra bold", extraBoldWidth)] {
            XCTAssertTrue(control.waitForExistence(timeout: 10),
                          "the \(name) one-tap width dot must exist")
            XCTAssertTrue(control.isHittable,
                          "the \(name) one-tap width dot must be tappable")
            assertTouchTarget(control)
        }
        XCTAssertTrue(width.exists, "the fine width slider must remain available")
        let widthPreview = app.descendants(matching: .any)
            .matching(identifier: "office.ink.widthPreview").firstMatch
        XCTAssertTrue(widthPreview.waitForExistence(timeout: 10),
                      "the width row must expose its live ink preview")
        let transparency = app.descendants(matching: .any)
            .matching(identifier: "office.ink.transparency").firstMatch
        XCTAssertTrue(transparency.waitForExistence(timeout: 10),
                      "the pen settings panel must expose its real transparency control")
        let typeRow = app.descendants(matching: .any)
            .matching(identifier: "office.ink.type").firstMatch
        XCTAssertTrue(typeRow.waitForExistence(timeout: 10),
                      "the pen settings panel must expose its single-row native style choices")
        let penType = app.buttons["office.ink.type.pen"]
        let markerType = app.buttons["office.ink.type.marker"]
        let highlighterType = app.buttons["office.ink.type.highlighter"]
        for (name, control) in [("pen", penType), ("marker", markerType), ("highlighter", highlighterType)] {
            XCTAssertTrue(control.waitForExistence(timeout: 10),
                          "the \(name) style choice must exist")
            XCTAssertTrue(control.isHittable, "the \(name) style choice must be tappable")
            assertTouchTarget(control)
        }
        XCTAssertTrue(waitUntil(timeout: 10, { penType.isSelected }),
                      "a document without an explicit style starts on the ordinary pen choice")
        // Exercise the actual controls, not a test-only setter. Every choice
        // keeps drawing On and only changes the real width/transparency the
        // engine applies to future strokes.
        markerType.tap()
        XCTAssertTrue(waitUntil(timeout: 10, { markerType.isSelected }),
                      "tapping the marker choice must select the marker style")
        XCTAssertFalse(penType.isSelected, "only one style choice may be selected")
        highlighterType.tap()
        XCTAssertTrue(waitUntil(timeout: 10, { highlighterType.isSelected }),
                      "tapping the highlighter choice must select the highlighter style")
        XCTAssertFalse(markerType.isSelected, "only one style choice may be selected")
        // The five size dots stay direct one-tap actions beside the style row;
        // the final state uses the selected 3.00 mm width and the real preview
        // must reflect it before Done/toggle/save continues.
        boldWidth.tap()
        XCTAssertTrue(waitUntil(timeout: 10, { boldWidth.isSelected }),
                      "one tap on the bold width dot must apply and select 3.00 mm")
        XCTAssertFalse(extraFineWidth.isSelected)
        XCTAssertFalse(hairlineWidth.isSelected)
        XCTAssertFalse(mediumWidth.isSelected)
        XCTAssertFalse(extraBoldWidth.isSelected)
        XCTAssertTrue(waitUntil(timeout: 10, {
            ((widthPreview.value as? String) ?? "").contains("3.00 mm")
        }), "the live preview must update to the selected 3.00 mm line width")
        let fineWidth = app.sliders["office.ink.width"]
        XCTAssertTrue(fineWidth.isHittable, "fine adjustment must remain directly available")
        fineWidth.adjust(toNormalizedSliderPosition: 0.2)
        XCTAssertTrue(waitUntil(timeout: 10, {
            let preview = (widthPreview.value as? String) ?? ""
            return preview.contains("mm") && !preview.contains("3.00 mm")
        }), "fine adjustment must update the live width preview")
        boldWidth.tap()
        XCTAssertTrue(waitUntil(timeout: 10, {
            boldWidth.isSelected && ((widthPreview.value as? String) ?? "").contains("3.00 mm")
        }), "a quick width dot must still apply after fine adjustment")
        XCTAssertFalse(app.buttons["office.ink.startStop"].exists,
                       "the settings panel must not duplicate the drawing on/off switch")
        XCTAssertEqual(app.keyboards.count, 0, "opening settings must not summon the keyboard")
        recordPencilToolbarState(app, phase: "settings-open")
        Thread.sleep(forTimeInterval: 0.4)
        capture("office-pencil-settings-open")
        closeOfficeInkPanel(app)
        XCTAssertTrue(waitForDrawingValue(toggle, on: true, timeout: 15),
                      "closing the settings panel must not change the drawing state")
        XCTAssertEqual(app.keyboards.count, 0, "closing settings must not summon the keyboard")
        XCTAssertTrue(waitUntil(timeout: 30, { toggle.exists && toggle.isEnabled && toggle.isHittable }),
                      "the direct pen toggle must be actionable again after the panel closes")

        toggle.tap()
        XCTAssertTrue(waitForDrawingValue(toggle, on: false, timeout: 30),
                      "one tap after closing settings must turn drawing off and publish Off")
        XCTAssertTrue(done.waitForNonExistence(timeout: 2))
        Thread.sleep(forTimeInterval: 0.4)
        capture("office-pencil-toggle-off-again")

        toggle.tap()
        XCTAssertTrue(waitForDrawingValue(toggle, on: true, timeout: 30))
        XCTAssertTrue(waitUntil(timeout: 30, { toggle.exists && toggle.isEnabled && toggle.isHittable }))
        toggle.tap()
        XCTAssertTrue(waitForDrawingValue(toggle, on: false, timeout: 30))
        XCTAssertTrue(waitUntil(timeout: 30, {
            toggle.exists && toggle.isEnabled && settings.exists && settings.isEnabled
        }))
        XCTAssertTrue(toggle.isHittable, "the direct pen toggle must remain available after repeated cycles")
        XCTAssertTrue(settings.isHittable, "the pen settings entry must remain available after repeated cycles")
        assertTouchTarget(toggle)
        assertTouchTarget(settings)
        recordPencilToolbarState(app, phase: "cycle-complete")
        Thread.sleep(forTimeInterval: 0.4)
        capture("office-pencil-toggle-cycle-complete")

        // Safe exit through the product's own back/save path. Notes owns the
        // exit decision for this surface: back saves the synthetic document in
        // place, commits it through the normal Notes resource route, and only
        // then returns to the library.
        XCTAssertTrue(waitUntil(timeout: 15, { back.isEnabled && back.isHittable }))
        back.tap()
        XCTAssertTrue(create.waitForExistence(timeout: 60),
                      "the Office editor must return to the Notes library through its safe exit")
        XCTAssertFalse(back.exists)
    }

    /// Real UIKit gestures must visibly scale a complete centered text target
    /// in both directions while drawing stays enabled. The ordinary creation
    /// and settings flow is qualified separately above. The same strict
    /// centered fixture is used for the ordinary (drawing Off) and pen
    /// (drawing On) cases; both retain the original full-title OCR,
    /// growth/shrink thresholds and safe exit, and additionally require the
    /// DEBUG-only probe's post-dispatch live-frame evidence before the
    /// last-finger touchend. This is not a substitute for root's external
    /// Simulator recording, which remains the presented-frame evidence.
    ///
    /// The current contract additionally ties the accepted frames to the
    /// input that produced them: every accepted live bubble frame must
    /// equal the scale implied by ITS OWN event's raw recorded
    /// finger-distance ratio against the gesture's immutable first-move
    /// reference; the end commit is the production
    /// `_limitZoom(Math.round(_limitZoom(rawTarget)))` policy evaluated
    /// against the LAST input-owned live move (frozen
    /// by the probe's monotonic passive dispatch sequence, so 0.1 ms
    /// event-time ties cannot misselect it; the probe also records the
    /// full-precision unclamped JS target and the consumer applies the
    /// production clamp/round/clamp order with exact Math.round semantics,
    /// floor(x + 0.5)); and the release's own
    /// after-target sample must observe the frame CLOSED (`iz` 0, no live
    /// scale) with the committed nearest level. A terminal frame that is
    /// still open is a contract failure and is rejected — never resolved
    /// through a later sample, a post-release record or a latest/global
    /// fallback. The historical ceil/floor commit of recorded old-host runs
    /// stays historical truth and is never relabelled; pairing this
    /// acceptance with an old host is exactly the mixed qualification that
    /// must fail. An explicitly marker-launched run also verifies the
    /// on-page badge tokens for the recorded video (bounded gesture tokens
    /// only).
    ///
    /// Word, Calc and Impress each have an owned centered fixture; every case
    /// runs the same strict helper and keeps the original full-title OCR,
    /// growth/shrink thresholds, drawing-state, no-finger-ink and safe-exit
    /// checks. Calc/Impress are not weaker variants: they only substitute the
    /// document whose measured line is placed for that layout.
    func testOfficePencilRealPinchOnCenteredFixture() throws {
        try runOfficeCenteredPinchAcceptance(drawingOn: true)
    }

    func testOfficePencilRealPinchDrawingOffOnCenteredFixture() throws {
        try runOfficeCenteredPinchAcceptance(drawingOn: false)
    }

    /// The real visible-keyboard branch is distinct from an already-hidden
    /// or stale offscreen keyboard. Enter it through public document input,
    /// then retain the shared hide/pinch/hidden-state acceptance unchanged.
    func testOfficePencilRealPinchAfterHidingVisibleWordKeyboard() throws {
        try runOfficeCenteredPinchAcceptance(
            drawingOn: false,
            casePrefix: "office-word-visible-keyboard",
            requireVisibleKeyboardBeforeHide: true)
    }

    /// Calc companion: the owned XLSX fixture with the measured line in G10.
    func testOfficePencilRealPinchOnCenteredCalcFixture() throws {
        try runOfficeCenteredPinchAcceptance(
            drawingOn: true,
            fixtureTitle: "捏合验收-居中-表格-2",
            fixtureLaunchArgument: "--ui-test-office-pinch-center-calc-fixture",
            measuredText: "Pen UI 7C3MV1K9",
            casePrefix: "office-pinch-calc")
    }

    func testOfficePencilRealPinchDrawingOffOnCenteredCalcFixture() throws {
        try runOfficeCenteredPinchAcceptance(
            drawingOn: false,
            fixtureTitle: "捏合验收-居中-表格-2",
            fixtureLaunchArgument: "--ui-test-office-pinch-center-calc-fixture",
            measuredText: "Pen UI 7C3MV1K9",
            casePrefix: "office-pinch-calc")
    }

    func testOfficeRealPinchWithCalcAssistantOpen() throws {
        try runOfficeCenteredPinchAcceptance(
            drawingOn: false,
            fixtureTitle: "捏合验收-居中-表格-2",
            fixtureLaunchArgument: "--ui-test-office-pinch-center-calc-fixture",
            measuredText: "Pen UI 7C3MV1K9",
            casePrefix: "office-pinch-calc-assistant",
            assistantOpen: true)
    }

    func testOfficePencilRealPinchWithCalcAssistantOpen() throws {
        try runOfficeCenteredPinchAcceptance(
            drawingOn: true,
            fixtureTitle: "捏合验收-居中-表格-2",
            fixtureLaunchArgument: "--ui-test-office-pinch-center-calc-fixture",
            measuredText: "Pen UI 7C3MV1K9",
            casePrefix: "office-pinch-calc-assistant-ink",
            assistantOpen: true)
    }

    /// Impress companion: the owned PPTX fixture whose measurement text object
    /// is centred on its single 16:9 slide.
    func testOfficePencilRealPinchOnCenteredPresentationFixture() throws {
        try runOfficeCenteredPinchAcceptance(
            drawingOn: true,
            fixtureTitle: "捏合验收-居中-演示-2",
            fixtureLaunchArgument: "--ui-test-office-pinch-center-presentation-fixture",
            measuredText: "Pen UI 2Q8WZ4R6",
            casePrefix: "office-pinch-ppt")
    }

    func testOfficePencilRealPinchDrawingOffOnCenteredPresentationFixture() throws {
        try runOfficeCenteredPinchAcceptance(
            drawingOn: false,
            fixtureTitle: "捏合验收-居中-演示-2",
            fixtureLaunchArgument: "--ui-test-office-pinch-center-presentation-fixture",
            measuredText: "Pen UI 2Q8WZ4R6",
            casePrefix: "office-pinch-ppt")
    }

    /// Shared strict acceptance for every centered fixture. The defaults are
    /// the Word case, so its two selectors keep their exact previous behavior;
    /// the Calc/Impress selectors pass their own owned title, launch argument,
    /// measured text and attachment prefix.
    private func runOfficeCenteredPinchAcceptance(
        drawingOn: Bool,
        fixtureTitle: String = "捏合验收-居中-3",
        fixtureLaunchArgument: String = "--ui-test-office-pinch-center-fixture",
        measuredText: String = "Pen UI 5X8KQ2M7",
        casePrefix: String = "office-pencil-center",
        requireVisibleKeyboardBeforeHide: Bool = false,
        assistantOpen: Bool = false
    ) throws {
        guard ProcessInfo.processInfo.environment["FLOE_OFFICE_PENCIL_UI_QUALIFICATION"] == "1" else {
            throw XCTSkip("Opt-in Office pen toolbar UI qualification; set FLOE_OFFICE_PENCIL_UI_QUALIFICATION=1 in the test runner environment.")
        }
        continueAfterFailure = false
        let ipad = ProcessInfo.processInfo.environment["SIMULATOR_MODEL_IDENTIFIER"]?.hasPrefix("iPad") == true
            || UIDevice.current.userInterfaceIdiom == .pad
        let app = XCUIApplication()
        app.terminate()
        XCUIDevice.shared.orientation = ipad ? .landscapeLeft : .portrait
        // The probe is DEBUG-only and activates only with its explicit launch
        // argument. A build without it fails the baseline gate below instead
        // of silently running without live-frame evidence.
        // The passive-only control is an explicit operator choice for the
        // runner: the SAME original case runs with the app-side probe
        // installed in passive mode (no call-site wrappers), while every
        // passive touch/geometry journal, the fixed DOM input-state facts
        // and the native input-state element stay active. Flag absent
        // means exactly the previous behaviour: call-site instrumentation
        // enabled; nothing is silently turned off.
        let probePassiveOnly = ProcessInfo.processInfo.environment["FLOE_OFFICE_TOUCH_PROBE_PASSIVE_ONLY"] == "1"
        app.launchArguments = ["-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN", "-ui-testing",
                               "--ui-test-preserve-animations", "--ui-test-skip-onboarding", fixtureLaunchArgument,
                               "--office-touch-qualification"]
        if probePassiveOnly {
            app.launchArguments.append("--office-touch-qualification-passive-only")
        }
        if ipad { app.launchArguments.append("-ui-testing-ipad") }
        // The on-page pinch marker badge is a separate, explicit opt-in:
        // the runner appends the app-side marker argument only when the
        // operator asked for recorded-video acceptance. Ordinary
        // qualification runs never create the badge node.
        if ProcessInfo.processInfo.environment["FLOE_OFFICE_PENCIL_VISIBLE_MARKER"] == "1" {
            app.launchArguments.append("--office-touch-qualification-visible-marker")
        }
        app.launch()
        defer { app.terminate() }
        if ipad { requireLandscapeAfterLaunch(app) }
        if !ipad {
            let sidebar = app.buttons["phone.sidebar.open"]
            XCTAssertTrue(sidebar.waitForExistence(timeout: 15)); sidebar.tap()
        }
        let notes = app.staticTexts["sidebar.notes"].firstMatch
        XCTAssertTrue(notes.waitForExistence(timeout: 15)); notes.tap()
        // The fixture is seeded at launch through the same Notes importer as a
        // user file import; open it through the real library card.
        let card = revealCard(app, kind: "office", title: fixtureTitle)
        XCTAssertTrue(card.isHittable, "the centered pinch fixture card must be reachable in the library")
        card.tap()

        let back = openedDocumentBackControl(app)
        let readyDeadline = Date().addingTimeInterval(60)
        while !(back.isEnabled && back.isHittable) && Date() < readyDeadline { Thread.sleep(forTimeInterval: 0.5) }
        XCTAssertTrue(back.isEnabled && back.isHittable,
                      "the native Office editor must finish opening the centered fixture")

        // An existing document can settle in the read-only preview first; use
        // the host Edit action exactly like the toolbar test, then require the
        // real pen toolbar.
        let toggle = app.buttons["office.drawing.toggle"]
        let edit = app.buttons["office.preview.edit"]
        XCTAssertTrue(waitUntil(timeout: 60, { toggle.exists || edit.exists }),
                      "the Office surface must reach either the editable pen toolbar or the host Edit action")
        if !toggle.exists {
            XCTAssertTrue(edit.exists, "the Office preview must expose its Edit action")
            XCTAssertTrue(waitUntil(timeout: 30, { edit.isEnabled && edit.isHittable }),
                          "the preview's Edit action must become actionable")
            assertTouchTarget(edit)
            edit.tap()
        }
        XCTAssertTrue(toggle.waitForExistence(timeout: 60),
                      "the editable Office toolbar must expose the direct pen toggle after the native engine is ready")
        XCTAssertTrue(waitUntil(timeout: 60, { toggle.exists && toggle.isEnabled && toggle.isHittable }),
                      "the pen toggle must become actionable once editing is ready")
        XCTAssertTrue(waitForDrawingValue(toggle, on: false, timeout: 15),
                      "the pen toggle must start in the real Off state for the fixture document")
        if drawingOn {
            toggle.tap()
            XCTAssertTrue(waitForDrawingValue(toggle, on: true, timeout: 30),
                          "one tap on the direct toggle must turn drawing on")
            XCTAssertTrue(app.keyboards.firstMatch.waitForNonExistence(timeout: 15),
                          "enabling drawing must dismiss the Office text keyboard")
        }
        if assistantOpen {
            let assistant = app.buttons["notes.assistant"]
            XCTAssertTrue(assistant.waitForExistence(timeout: 15))
            XCTAssertTrue(assistant.isHittable)
            assistant.tap()
            XCTAssertTrue(app.buttons["notes.assistant.close"].waitForExistence(timeout: 15),
                          "The document assistant must be open throughout the real pinch")
        }
        let mode = drawingOn ? "drawing-on" : "drawing-off"
        let prefix = drawingOn ? casePrefix : casePrefix + "-drawing-off"
        capture("\(prefix)-document-opened")

        // Ordinary mode can legitimately keep the Office text keyboard
        // onscreen after the document opens (the toolbar test asserts that
        // same opening state). A visibly covering keyboard shrinks the
        // layout viewport to the 160 px canvas recorded in the drawing-off
        // baseline, below the fixed visible-canvas floor, so the anchor
        // contract correctly refuses to pinch until it is dismissed.
        // Require the actual onscreen keyboard to leave through the
        // platform's own hide key before the probe/geometry baseline; the
        // readiness helper decides that from public onscreen geometry and
        // actionable state, so the retained zero-height offscreen AX node
        // seen in Word UI4 does not block an already-full canvas while a
        // real docked or floating keyboard still forces dismissal, and
        // unknown geometry fails closed. Drawing-on already asserts
        // dismissal when the pen toggle is tapped, so only ordinary mode
        // needs this public-UI step: no synthetic touch, no fixed sleep,
        // no lowered canvas floor and no product debug control.
        if !drawingOn {
            if requireVisibleKeyboardBeforeHide {
                try requireVisibleWordKeyboardBeforePinchHide(app, label: mode)
            }
            let didHideVisibleKeyboard = dismissSoftwareKeyboardBeforePinchBaseline(app, label: mode)
            if requireVisibleKeyboardBeforeHide {
                XCTAssertTrue(didHideVisibleKeyboard,
                              "the visible-keyboard regression must actually use the system Hide key and settle before pinching")
            }
        }

        // The real centered fixture and the public XCTest gesture are shared
        // by both modes. The probe must be installed before any evidence is
        // interpreted; it is read as a bounded, content-free AX value.
        let baselineRead = waitForIdleOfficeTouchProbe(app, timeout: 45)
        attachText(baselineRead.raw, name: "office-live-pinch-\(mode)-probe-baseline")
        XCTAssertTrue(baselineRead.ok,
                      "the DEBUG touch probe must publish ok=1 before the real pinch; last value: \(baselineRead.raw.prefix(200))")
        let baseline = try XCTUnwrap(baselineRead.dict, "the probe baseline must be valid JSON")
        try assertOfficeTouchProbeBaseline(baseline, drawingOn: drawingOn, label: mode)
        let nativeStateElement = app.descendants(matching: .any)
            .matching(identifier: "office.touch-qualification.input-state").firstMatch
        XCTAssertTrue(nativeStateElement.waitForExistence(timeout: 15))
        let nativeRaw = try XCTUnwrap(nativeStateElement.value as? String)
        attachText(nativeRaw, name: "office-live-pinch-\(mode)-animation-state")
        let nativeState = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(nativeRaw.utf8)) as? [String: Any])
        XCTAssertEqual(pinchNumber(nativeState["uiAnimationsEnabled"]), 1,
                       "Real gesture acceptance requires UIKit animations enabled")
        // Control integrity, asserted ONLY in the operator-requested
        // passive-only run: the page must report the mode and the call-site
        // counters must be honestly zero because nothing was wrapped. The
        // ordinary (wrappers-enabled) case above is completely unchanged.
        if probePassiveOnly {
            XCTAssertEqual(pinchNumber(baseline["po"]), 1,
                           "the passive-only launch must be reported by the probe (po=1)")
            XCTAssertEqual(pinchNumber(baseline["ctn"]), 0,
                           "passive-only must install zero call-site wrappers (ctn=0)")
            XCTAssertEqual(pinchNumber(baseline["clN"]), 0,
                           "passive-only keeps the trace/moment ring empty (clN=0)")
            attachNativeInputState(app, label: "office-live-pinch", phase: "passive-only-baseline")
        }

        // XCTest synthesizes real UIKit touches here. Require a change in the
        // document's rendered measured line, in addition to the separate
        // native tests of frontend TouchEvents and saved vectors.
        let web = app.webViews.firstMatch
        XCTAssertTrue(web.waitForExistence(timeout: 10))
        // A whole-WebView pinch is not a document gesture: the measured out
        // gesture started one finger on the Collabora toolbar. Pinch the
        // DEBUG-only passive anchor that publishes a safe sub-rectangle of the
        // real canvas so both trusted starts belong to the document canvas.
        let canvasAnchor = try waitForReadyCanvasAnchor(app, web: web, label: "\(mode)-before-in")
        let beforePinch = web.screenshot()
        canvasAnchor.pinch(withScale: 1.25, velocity: 1)
        Thread.sleep(forTimeInterval: 1.5)
        let afterPinch = web.screenshot()
        for (name, shot) in [("\(prefix)-before-real-pinch", beforePinch),
                             ("\(prefix)-after-real-pinch", afterPinch)] {
            let attachment = XCTAttachment(screenshot: shot)
            attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
        }
        let inRead = readOfficeTouchProbe(app, timeout: 15)
        attachText(inRead.raw, name: "office-live-pinch-\(mode)-probe-after-in")
        XCTAssertTrue(inRead.ok,
                      "the probe must still publish a snapshot after the real pinch-in; last value: \(inRead.raw.prefix(200))")
        let after = try XCTUnwrap(inRead.dict, "the post-pinch-in probe snapshot must be valid JSON")
        try assertOfficeLivePinch(baseline: baseline, after: after, direction: .inward,
                                  drawingOn: drawingOn, label: "\(mode)-pinch-in")
        try assertCanvasBoundedStarts(after: after, label: "\(mode)-pinch-in")
        if probePassiveOnly {
            XCTAssertEqual(pinchNumber(after["ctn"]), 0,
                           "\(mode)-pinch-in: passive-only must still report zero installed wrappers")
            XCTAssertEqual(pinchNumber(after["clN"]), 0,
                           "\(mode)-pinch-in: passive-only trace/moment ring must stay empty (clN=0)")
            XCTAssertEqual((after["cl"] as? [Any])?.count ?? -1, 0,
                           "\(mode)-pinch-in: passive-only exported trace ring must be empty")
            attachNativeInputState(app, label: "\(mode)", phase: "passive-only-after-pinch-in")
        }
        // Ordinary mode: once the baseline actually ended the keyboard's
        // onscreen occlusion through its own public hide key, the real pinch
        // must leave that state alone. Checked before the OCR phases so a
        // keyboard-driven relayout cannot contaminate the title evidence.
        if !drawingOn {
            assertKeyboardHiddenAfterPinch(app, label: mode, phase: "after-pinch-in")
        }
        let phaseSuffix = drawingOn ? "" : "-drawing-off"
        let beforeTitle = try officeMeasuredTitleBounds(
            in: beforePinch.image, phase: "before\(phaseSuffix)",
            expected: measuredText, attachmentPrefix: prefix)
        let afterTitle = try officeMeasuredTitleBounds(
            in: afterPinch.image, phase: "after-in\(phaseSuffix)",
            expected: measuredText, attachmentPrefix: prefix)
        XCTAssertGreaterThan(afterTitle.width, beforeTitle.width * 1.08,
                             "A UIKit pinch in \(drawingOn ? "drawing" : "ordinary") mode must visibly enlarge the document")
        XCTAssertTrue(waitForDrawingValue(toggle, on: drawingOn, timeout: 10),
                      "Pinching must leave the drawing state unchanged")

        // A second independent gesture must establish its own start after
        // the first ends; require visible zoom-out without leaving drawing.
        let outAnchor = try waitForReadyCanvasAnchor(app, web: web, label: "\(mode)-before-out")
        outAnchor.pinch(withScale: 0.8, velocity: -1)
        Thread.sleep(forTimeInterval: 1.5)
        let afterPinchOut = web.screenshot()
        let pinchOutAttachment = XCTAttachment(screenshot: afterPinchOut)
        pinchOutAttachment.name = "\(prefix)-after-real-pinch-out"
        pinchOutAttachment.lifetime = .keepAlways
        add(pinchOutAttachment)
        let outRead = readOfficeTouchProbe(app, timeout: 15)
        attachText(outRead.raw, name: "office-live-pinch-\(mode)-probe-after-out")
        XCTAssertTrue(outRead.ok,
                      "the probe must remain available after the outward real gesture; last value: \(outRead.raw.prefix(200))")
        let afterOut = try XCTUnwrap(outRead.dict, "the post-pinch-out probe snapshot must be valid JSON")
        try assertOfficeLivePinch(baseline: after, after: afterOut, direction: .outward,
                                  drawingOn: drawingOn, label: "\(mode)-pinch-out")
        try assertCanvasBoundedStarts(after: afterOut, label: "\(mode)-pinch-out")
        if probePassiveOnly {
            XCTAssertEqual(pinchNumber(afterOut["ctn"]), 0,
                           "\(mode)-pinch-out: passive-only must still report zero installed wrappers")
            XCTAssertEqual(pinchNumber(afterOut["clN"]), 0,
                           "\(mode)-pinch-out: passive-only trace/moment ring must stay empty (clN=0)")
            XCTAssertEqual((afterOut["cl"] as? [Any])?.count ?? -1, 0,
                           "\(mode)-pinch-out: passive-only exported trace ring must be empty")
            attachNativeInputState(app, label: "\(mode)", phase: "passive-only-after-pinch-out")
        }
        if !drawingOn {
            assertKeyboardHiddenAfterPinch(app, label: mode, phase: "after-pinch-out")
        }
        let afterOutTitle = try officeMeasuredTitleBounds(
            in: afterPinchOut.image, phase: "after-out\(phaseSuffix)",
            expected: measuredText, attachmentPrefix: prefix)
        XCTAssertLessThan(afterOutTitle.width, afterTitle.width * 0.95,
                          "A subsequent UIKit pinch must visibly shrink the document")
        XCTAssertTrue(waitForDrawingValue(toggle, on: drawingOn, timeout: 10),
                      "Repeated pinching must leave the drawing state unchanged")

        if requireVisibleKeyboardBeforeHide {
            // Blocking the consumed pinch click must preserve the next real
            // text-editing tap. Require hidden state before that fresh tap,
            // then actual visible input and a real Hide action afterward.
            let nextTap = "\(mode)-next-tap"
            try requireVisibleWordKeyboardBeforePinchHide(
                app, label: nextTap, requireFreshCanvasTap: true)
            XCTAssertTrue(dismissSoftwareKeyboardBeforePinchBaseline(app, label: nextTap),
                          "the genuine next tap must still open a keyboard that can be hidden through its system key")
        }

        // Safe exit through the product's own back/save path. This remains
        // the original save/reopen route check, not a replacement for the
        // separate live-ink/placement/save cases.
        XCTAssertTrue(waitUntil(timeout: 15, { back.isEnabled && back.isHittable }))
        back.tap()
        // The library's create control can exist behind the editor while
        // its asynchronous save/exit is still completing. Require the real
        // foreground destination and closed editor within the same deadline.
        let libraryCreate = creationControl(app)
        XCTAssertTrue(waitUntil(timeout: 60, {
            libraryCreate.exists && libraryCreate.isHittable && !back.exists
        }), "the Office editor must finish its safe exit into the actionable Notes library")
        XCTAssertFalse(back.exists)
        capture("\(prefix)-notes-library-returned")
        // Evaluate the retained in-flight-anchor evidence only after every
        // product/OCR/safe-exit assertion above has run, so an instrumentation
        // mismatch cannot truncate the original-case evidence.
        assertInFlightAnchorRetained(after: after, label: "\(mode)-pinch-in")
        assertInFlightAnchorRetained(after: afterOut, label: "\(mode)-pinch-out")
    }

    private enum OfficePinchDirection: Equatable {
        case inward
        case outward
    }

    private struct OfficeLiveFrame {
        let eventTime: Double
        let sampleTime: Double
        let scale: Double
        let committedZoom: Double
        let source: String
        /// Passive finger distance of the same event (`d`, recorded raw at
        /// full JSON double precision) and the gesture's immutable
        /// first-live-move reference (`d0`). The input-correlated contract
        /// derives the scale the engine must paint from them. `eventSeq` is
        /// the probe's monotonic passive dispatch sequence, which orders
        /// 0.1 ms event-time ties by real dispatch order.
        let distance: Double?
        let reference: Double?
        let eventSeq: Double?
    }

    private func assertOfficeTouchProbeBaseline(_ snapshot: [String: Any], drawingOn: Bool,
                                                label: String,
                                                file: StaticString = #filePath, line: UInt = #line) throws {
        XCTAssertEqual(pinchNumber(snapshot["ok"]), 1,
                       "\(label): the debug probe must report ok=1", file: file, line: line)
        XCTAssertEqual(pinchNumber(snapshot["v"]), 1,
                       "\(label): the probe schema version must remain 1", file: file, line: line)
        let state = try XCTUnwrap(snapshot["st"] as? [String: Any],
                                  "\(label): the probe snapshot must carry engine state")
        XCTAssertEqual(pinchNumber(state["iza"]), 0,
                       "\(label): no zoom frame may be active before the gesture", file: file, line: line)
        XCTAssertNil(pinchNumber(state["zfs"]),
                     "\(label): the zoom-frame scale must be absent before the gesture", file: file, line: line)
        let minZoom = try XCTUnwrap(pinchNumber(state["minz"]),
                                    "\(label): the probe must expose the engine minimum zoom")
        let maxZoom = try XCTUnwrap(pinchNumber(state["maxz"]),
                                    "\(label): the probe must expose the engine maximum zoom")
        XCTAssertLessThan(minZoom, maxZoom, "\(label): the zoom range must be ordered", file: file, line: line)
        let pen = try XCTUnwrap(snapshot["pen"] as? [String: Any],
                                "\(label): the pen gate state must be present")
        XCTAssertEqual(pinchNumber(pen["d"]), drawingOn ? 1.0 : 0.0,
                       "\(label): the drawing state must match the case", file: file, line: line)
        XCTAssertEqual(pinchNumber(pen["as"]), 0,
                       "\(label): no Pencil contact may be active before the gesture", file: file, line: line)
        XCTAssertNotNil(pinchNumber(pen["str"]),
                        "\(label): the baseline Pencil stroke count must be present", file: file, line: line)
    }

    private struct OfficeCanvasAnchorError: Error, CustomStringConvertible {
        let description: String
    }

    private struct OfficeCanvasGeometry {
        let expected: CGRect
        let visible: CGRect
    }

    private func finitePinchNumber(_ value: Any?) -> Double? {
        guard let number = pinchNumber(value), number.isFinite else { return nil }
        return number
    }

    /// Maps the page's CSS viewport canvas rectangle onto the CURRENT UIKit/
    /// accessibility geometry of the WebView. The scale uses the live
    /// `web.frame` and the page's live `innerWidth/innerHeight`; it never
    /// infers an orientation or scale from serialized injection coordinates.
    private func officeCanvasGeometry(snapshot: [String: Any], web: XCUIElement,
                                      label: String) throws -> OfficeCanvasGeometry {
        guard let ready = snapshot["rs"] as? String,
              ready == "interactive" || ready == "complete" else {
            throw OfficeCanvasAnchorError(description: "\(label): the page is not ready for canvas geometry")
        }
        guard let viewport = snapshot["vp"] as? [String: Any],
              let innerWidth = finitePinchNumber(viewport["iw"]), innerWidth > 0,
              let innerHeight = finitePinchNumber(viewport["ih"]), innerHeight > 0,
              let canvas = snapshot["cv"] as? [String: Any],
              let x = finitePinchNumber(canvas["x"]),
              let y = finitePinchNumber(canvas["y"]),
              let width = finitePinchNumber(canvas["w"]), width > 0,
              let height = finitePinchNumber(canvas["h"]), height > 0 else {
            throw OfficeCanvasAnchorError(description: "\(label): the page canvas rectangle is missing or non-finite")
        }
        let webFrame = web.frame
        guard webFrame.width > 0, webFrame.height > 0 else {
            throw OfficeCanvasAnchorError(description: "\(label): the WebView frame is empty")
        }
        let scaleX = webFrame.width / CGFloat(innerWidth)
        let scaleY = webFrame.height / CGFloat(innerHeight)
        guard scaleX.isFinite, scaleY.isFinite, scaleX > 0, scaleY > 0 else {
            throw OfficeCanvasAnchorError(description: "\(label): the viewport scale is non-finite")
        }
        let expected = CGRect(x: webFrame.minX + CGFloat(x) * scaleX,
                              y: webFrame.minY + CGFloat(y) * scaleY,
                              width: CGFloat(width) * scaleX,
                              height: CGFloat(height) * scaleY)
        let visible = expected.intersection(webFrame)
        guard !visible.isNull, visible.width >= 200, visible.height >= 160 else {
            throw OfficeCanvasAnchorError(description: "\(label): the visible canvas rectangle is too small")
        }
        return OfficeCanvasGeometry(expected: expected, visible: visible)
    }

    /// Waits for the page-reported canvas geometry and the passive anchor to
    /// be current, non-zero and stable across consecutive reads, then proves
    /// the anchor lies inside the visible canvas before any public pinch.
    private func waitForReadyCanvasAnchor(_ app: XCUIApplication, web: XCUIElement,
                                          label: String,
                                          timeout: TimeInterval = 20) throws -> XCUIElement {
        let anchor = app.descendants(matching: .any)
            .matching(identifier: "office.touch-qualification.canvas-anchor").firstMatch
        let deadline = Date().addingTimeInterval(timeout)
        var previousAnchorFrame = CGRect.null
        var previousCanvas: CGRect = .null
        var stableReads = 0
        var lastProblem = "the canvas anchor was not published"
        while Date() < deadline {
            let read = readOfficeTouchProbe(app, timeout: 0.75)
            guard read.ok, let snapshot = read.dict else {
                stableReads = 0
                previousAnchorFrame = .null
                previousCanvas = .null
                lastProblem = "the probe snapshot is not readable"
                Thread.sleep(forTimeInterval: 0.25)
                continue
            }
            let geometry: OfficeCanvasGeometry
            do {
                geometry = try officeCanvasGeometry(snapshot: snapshot, web: web, label: label)
            } catch let error as OfficeCanvasAnchorError {
                stableReads = 0
                previousAnchorFrame = .null
                previousCanvas = .null
                lastProblem = error.description
                Thread.sleep(forTimeInterval: 0.25)
                continue
            }
            guard anchor.exists else {
                stableReads = 0
                previousAnchorFrame = .null
                previousCanvas = .null
                lastProblem = "the canvas anchor accessibility element is not visible"
                Thread.sleep(forTimeInterval: 0.25)
                continue
            }
            let frame = anchor.frame
            guard !frame.isEmpty, frame.width >= 200, frame.height >= 160 else {
                stableReads = 0
                previousAnchorFrame = .null
                previousCanvas = .null
                lastProblem = "the canvas anchor frame is empty or too small: \(frame)"
                Thread.sleep(forTimeInterval: 0.25)
                continue
            }
            let stable = previousAnchorFrame != .null
                && previousCanvas != .null
                && abs(frame.minX - previousAnchorFrame.minX) <= 1
                && abs(frame.minY - previousAnchorFrame.minY) <= 1
                && abs(frame.width - previousAnchorFrame.width) <= 1
                && abs(frame.height - previousAnchorFrame.height) <= 1
                && abs(geometry.expected.minX - previousCanvas.minX) <= 1
                && abs(geometry.expected.minY - previousCanvas.minY) <= 1
                && abs(geometry.expected.width - previousCanvas.width) <= 1
                && abs(geometry.expected.height - previousCanvas.height) <= 1
            stableReads = stable ? stableReads + 1 : 0
            previousAnchorFrame = frame
            previousCanvas = geometry.expected
            if stableReads >= 1, canvasFrame(frame, isInside: geometry.visible) {
                return anchor
            }
            lastProblem = "the canvas anchor geometry has not stabilized inside the visible canvas"
            Thread.sleep(forTimeInterval: 0.25)
        }
        throw OfficeCanvasAnchorError(description: "\(label): \(lastProblem)")
    }

    private func canvasFrame(_ frame: CGRect, isInside canvas: CGRect) -> Bool {
        frame.minX >= canvas.minX - 2
            && frame.minY >= canvas.minY - 2
            && frame.maxX <= canvas.maxX + 2
            && frame.maxY <= canvas.maxY + 2
    }

    /// One strict trusted-terminal contract for both the ring record and the
    /// bounded terminal cache. A missing post-end sample is never replaced by
    /// `latest`; a cancel or duplicate end never satisfies this contract.
    private func assertStrictOfficeTerminal(_ record: [String: Any], endT: Double,
                                            endGesture: Double, label: String,
                                            file: StaticString = #filePath,
                                            line: UInt = #line) throws -> [String: Any] {
        XCTAssertEqual(record["k"] as? String, "te",
                       "\(label): the terminal record must be a trusted touchend",
                       file: file, line: line)
        XCTAssertEqual(pinchNumber(record["tr"]), 1,
                       "\(label): the terminal record must be trusted",
                       file: file, line: line)
        XCTAssertEqual(pinchNumber(record["n"]), 0,
                       "\(label): the terminal touchend must report zero remaining touches",
                       file: file, line: line)
        XCTAssertEqual(pinchNumber(record["gi"]), endGesture,
                       "\(label): the terminal record must belong to the ended gesture",
                       file: file, line: line)
        XCTAssertEqual(pinchNumber(record["t"]), endT,
                       "\(label): the terminal record must carry the recorded end time",
                       file: file, line: line)
        XCTAssertEqual(pinchNumber(record["term"]), 1,
                       "\(label): the terminal record must carry the terminal marker",
                       file: file, line: line)
        let sample = try XCTUnwrap(record["s"] as? [String: Any],
                                   "\(label): the terminal record must carry its own post-dispatch sample",
                                   file: file, line: line)
        XCTAssertEqual(pinchNumber(sample["post"]), 1,
                       "\(label): the terminal sample must be explicitly labelled post-end",
                       file: file, line: line)
        XCTAssertEqual(pinchNumber(sample["stale"]), 0,
                       "\(label): the terminal sample must belong to the current gesture",
                       file: file, line: line)
        let source = sample["src"] as? String
        XCTAssertTrue(source == "b" || source == "r",
                      "\(label): the terminal sample must name its source (bubble-after-target or render-step)",
                      file: file, line: line)
        // Current synchronous nearest contract: the release handler
        // closes the zoom frame and commits the nearest level, so the
        // terminal record's own after-target sample MUST observe the closed
        // frame. An open terminal frame is a contract failure — it is never
        // resolved by a later frame, a post-release record or latest/global
        // state.
        XCTAssertEqual(pinchNumber(sample["iz"]), 0,
                       "\(label): the terminal sample must observe the synchronously closed zoom frame",
                       file: file, line: line)
        XCTAssertNil(pinchNumber(sample["zfs"]),
                     "\(label): the terminal sample must not carry a live frame scale",
                     file: file, line: line)
        XCTAssertNotNil(pinchNumber(sample["z"]),
                        "\(label): the terminal sample must carry the committed zoom",
                        file: file, line: line)
        XCTAssertNotNil(pinchNumber(record["seq"]),
                        "\(label): the terminal record must carry its passive dispatch sequence",
                        file: file, line: line)
        let sampleAt = try XCTUnwrap(pinchNumber(sample["at"]),
                                     "\(label): the terminal sample time is missing",
                                     file: file, line: line)
        XCTAssertGreaterThanOrEqual(sampleAt, endT,
                                    "\(label): a post-end sample must not predate the terminal event",
                                    file: file, line: line)
        return sample
    }

    /// Both trusted touchstarts of the just-ended gesture must target the
    /// document canvas and lie inside the canvas geometry captured AT THEIR
    /// OWN DISPATCH. Each trusted start record carries `cg`: the page canvas
    /// rect plus layout-viewport inner sizes read synchronously inside the
    /// same passive capture handler, bound to the record's own time. The
    /// rounded client coordinates in `o` are CSS-viewport numbers for that
    /// same dispatch, so containment is proven against `cg` — never against
    /// the later snapshot `cv`: a keyboard re-presenting during or after the
    /// gesture legitimately resizes the layout viewport, and rebinding
    /// start-time coordinates to post-event geometry would be an event-time
    /// error that can both falsely fail a real canvas pinch and mask a real
    /// viewport change. Missing, non-finite or non-positive per-start
    /// geometry fails closed: this proof requires it. The snapshot's own
    /// `cv` keeps the previous finite-positive sanity guards, and the probe
    /// keeps only the first 16 starts with the all-start completeness
    /// contract unchanged. This is the actual-UIKit start proof, not a
    /// serialized injection hint.
    private func assertCanvasBoundedStarts(after: [String: Any], label: String,
                                           file: StaticString = #filePath,
                                           line: UInt = #line) throws {
        let gesture = try XCTUnwrap(pinchNumber(after["gid"]),
                                    "\(label): the gesture serial is missing",
                                    file: file, line: line)
        // The probe keeps only the first 16 starts. The start-target proof is
        // complete only when that bounded window holds every start this probe
        // session observed; otherwise an offending later start could be
        // invisible. These two fixture cases must fit the existing 16-entry
        // contract rather than enlarging or globalizing the buffer.
        let allStarts = try XCTUnwrap(pinchNumber(after["ns"]),
                                      "\(label): the all-start counter is missing",
                                      file: file, line: line)
        let starts = after["starts"] as? [[String: Any]] ?? []
        XCTAssertEqual(allStarts, Double(starts.count),
                       "\(label): the bounded start window must contain every observed start (ns=\(allStarts), kept=\(starts.count))",
                       file: file, line: line)
        XCTAssertLessThanOrEqual(allStarts, 16,
                                 "\(label): start-buffer completeness requires the probe session to stay within 16 starts (ns=\(allStarts))",
                                 file: file, line: line)
        // The snapshot canvas rectangle remains the current-state sanity
        // bound with the same finite-positive guards; it no longer serves as
        // the bound for start-time coordinates.
        let canvas = try XCTUnwrap(after["cv"] as? [String: Any],
                                   "\(label): the probe must expose the canvas rectangle",
                                   file: file, line: line)
        let snapshotWidth = try XCTUnwrap(finitePinchNumber(canvas["w"]),
                                          "\(label): canvas width is missing", file: file, line: line)
        let snapshotHeight = try XCTUnwrap(finitePinchNumber(canvas["h"]),
                                           "\(label): canvas height is missing", file: file, line: line)
        XCTAssertGreaterThan(snapshotWidth, 0,
                             "\(label): canvas width must be positive", file: file, line: line)
        XCTAssertGreaterThan(snapshotHeight, 0,
                             "\(label): canvas height must be positive", file: file, line: line)
        var provenPoints = 0
        for record in starts {
            guard (record["k"] as? String) == "ts",
                  pinchNumber(record["tr"]) == 1,
                  pinchNumber(record["gi"]) == gesture,
                  let target = record["g"] as? [String: Any],
                  let tag = target["g"] as? String else { continue }
            XCTAssertEqual(tag, "CANVAS",
                           "\(label): every trusted start must target the document canvas",
                           file: file, line: line)
            let seq = pinchNumber(record["seq"]).map { "#\(Int($0))" } ?? "<no-seq>"
            let geom = try XCTUnwrap(record["cg"] as? [String: Any],
                                     "\(label): trusted start \(seq) carries no canvas geometry captured at its own dispatch; refusing to bind start coordinates to later snapshot geometry",
                                     file: file, line: line)
            let recordT = try XCTUnwrap(finitePinchNumber(record["t"]),
                                        "\(label): trusted start \(seq) is missing a finite dispatch time",
                                        file: file, line: line)
            XCTAssertGreaterThan(recordT, 0,
                                 "\(label): trusted start \(seq) dispatch time must be positive",
                                 file: file, line: line)
            let geomT = try XCTUnwrap(finitePinchNumber(geom["t"]),
                                      "\(label): trusted start \(seq) geometry is missing a finite capture time",
                                      file: file, line: line)
            XCTAssertGreaterThan(geomT, 0,
                                 "\(label): trusted start \(seq) geometry capture time must be positive",
                                 file: file, line: line)
            XCTAssertEqual(geomT, recordT,
                           "\(label): trusted start \(seq) geometry must be captured at the record's own dispatch time",
                           file: file, line: line)
            let x = try XCTUnwrap(finitePinchNumber(geom["x"]),
                                  "\(label): trusted start \(seq) canvas x is missing", file: file, line: line)
            let y = try XCTUnwrap(finitePinchNumber(geom["y"]),
                                  "\(label): trusted start \(seq) canvas y is missing", file: file, line: line)
            let width = try XCTUnwrap(finitePinchNumber(geom["w"]),
                                      "\(label): trusted start \(seq) canvas width is missing", file: file, line: line)
            let height = try XCTUnwrap(finitePinchNumber(geom["h"]),
                                       "\(label): trusted start \(seq) canvas height is missing", file: file, line: line)
            let innerWidth = try XCTUnwrap(finitePinchNumber(geom["iw"]),
                                           "\(label): trusted start \(seq) layout viewport width is missing", file: file, line: line)
            let innerHeight = try XCTUnwrap(finitePinchNumber(geom["ih"]),
                                            "\(label): trusted start \(seq) layout viewport height is missing", file: file, line: line)
            XCTAssertGreaterThan(width, 0,
                                 "\(label): trusted start \(seq) canvas width must be positive", file: file, line: line)
            XCTAssertGreaterThan(height, 0,
                                 "\(label): trusted start \(seq) canvas height must be positive", file: file, line: line)
            XCTAssertGreaterThan(innerWidth, 0,
                                 "\(label): trusted start \(seq) layout viewport width must be positive", file: file, line: line)
            XCTAssertGreaterThan(innerHeight, 0,
                                 "\(label): trusted start \(seq) layout viewport height must be positive", file: file, line: line)
            for point in record["o"] as? [[Any]] ?? [] {
                guard point.count >= 2,
                      let px = finitePinchNumber(point[0]),
                      let py = finitePinchNumber(point[1]) else { continue }
                provenPoints += 1
                XCTAssertGreaterThanOrEqual(px, x - 2,
                                            "\(label): trusted start \(seq) x must be inside the canvas geometry captured at that start",
                                            file: file, line: line)
                XCTAssertLessThanOrEqual(px, x + width + 2,
                                         "\(label): trusted start \(seq) x must be inside the canvas geometry captured at that start",
                                         file: file, line: line)
                XCTAssertGreaterThanOrEqual(py, y - 2,
                                            "\(label): trusted start \(seq) y must be inside the canvas geometry captured at that start",
                                            file: file, line: line)
                XCTAssertLessThanOrEqual(py, y + height + 2,
                                         "\(label): trusted start \(seq) y must be inside the canvas geometry captured at that start",
                                         file: file, line: line)
            }
        }
        XCTAssertGreaterThanOrEqual(provenPoints, 2,
                                    "\(label): the gesture must expose both trusted touchstarts",
                                    file: file, line: line)
    }

    /// Consumes the probe's bounded in-flight anchor record (`ia`). The
    /// pinned engine clears `ZoomControl.pinchAnchor` at gesture start,
    /// creates it only in the first two-finger move target handler, and
    /// clears it again before the touchend bubble sample. Therefore the
    /// per-start `eg` and the settled snapshot `eg` must both report no
    /// anchor (`paN == 0`), while `ia` must retain the one actual anchor read
    /// from a post-target, genuinely pre-end move sample. `ia` carries its
    /// own event/sample times, phase, event key, dispatch sequence, move
    /// ordinal, sampling source, gesture serial and install
    /// owner/generation, so it cannot be confused with the later cleared
    /// state or another gesture. A null `ia` is accepted only as an honest
    /// unavailable result with at least one counted attempt; it is never
    /// replaced by invented coordinates. This is evidence collection and
    /// does not change any acceptance threshold.
    private func assertInFlightAnchorRetained(
        after: [String: Any], label: String,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        let gesture = pinchNumber(after["gid"])
        let startT = pinchNumber(after["gst"])
        let endT = pinchNumber(after["gend"])
        let endSeq = pinchNumber(after["eseq"])
        let snapshotT = pinchNumber(after["t"])
        let owner = pinchNumber(after["owner"])
        let generation = pinchNumber(after["gen"])
        let attempts = pinchNumber(after["iaT"]) ?? -1
        let unavailable = pinchNumber(after["iaN"]) ?? -1
        XCTAssertGreaterThanOrEqual(attempts, 0,
                                    "\(label): the in-flight anchor attempt counter must be present",
                                    file: file, line: line)
        XCTAssertGreaterThanOrEqual(unavailable, 0,
                                    "\(label): the honest null-anchor counter must be present",
                                    file: file, line: line)
        XCTAssertLessThanOrEqual(unavailable, attempts,
                                 "\(label): null in-flight reads cannot exceed attempted reads",
                                 file: file, line: line)

        guard let anchor = after["ia"] as? [String: Any] else {
            XCTAssertGreaterThan(attempts, 0,
                                 "\(label): a missing in-flight anchor must be an honestly attempted, counted result (iaT=\(attempts))",
                                 file: file, line: line)
            XCTAssertEqual(unavailable, attempts,
                           "\(label): every attempted null anchor read must be counted",
                           file: file, line: line)
            attachText("ia=null\niaT=\(attempts)\niaN=\(unavailable)\ngid=\(String(describing: gesture))"
                + "\nnote=engine exposed no pinchAnchor at any eligible post-target pre-end move sample",
                name: "\(label)-in-flight-anchor-unavailable")
            return
        }

        XCTAssertEqual(pinchNumber(anchor["paN"]), 1,
                       "\(label): a retained in-flight anchor must carry paN=1",
                       file: file, line: line)
        XCTAssertEqual(anchor["ph"] as? String, "m",
                       "\(label): the in-flight anchor must be captured in the move phase",
                       file: file, line: line)
        XCTAssertEqual(anchor["k"] as? String, "tm",
                       "\(label): the in-flight anchor must come from a touchmove record",
                       file: file, line: line)
        XCTAssertEqual(pinchNumber(anchor["gi"]), gesture,
                       "\(label): the in-flight anchor must belong to the just-ended gesture",
                       file: file, line: line)
        XCTAssertEqual(pinchNumber(anchor["og"]), owner,
                       "\(label): the in-flight anchor must carry the snapshot's install owner",
                       file: file, line: line)
        XCTAssertEqual(pinchNumber(anchor["ng"]), generation,
                       "\(label): the in-flight anchor must carry the snapshot's page generation",
                       file: file, line: line)
        let source = anchor["src"] as? String
        XCTAssertTrue(source == "b" || source == "r",
                      "\(label): the in-flight anchor must name its post-target sampling source",
                      file: file, line: line)
        let eventT = pinchNumber(anchor["t"])
        let sampleT = pinchNumber(anchor["at"])
        let seq = pinchNumber(anchor["seq"])
        let moveOrdinal = pinchNumber(anchor["mv"])
        XCTAssertNotNil(eventT, "\(label): the in-flight anchor event time is missing",
                        file: file, line: line)
        XCTAssertNotNil(sampleT, "\(label): the in-flight anchor sample time is missing",
                        file: file, line: line)
        XCTAssertNotNil(seq, "\(label): the in-flight anchor dispatch sequence is missing",
                        file: file, line: line)
        XCTAssertGreaterThanOrEqual(moveOrdinal ?? 0, 1,
                                    "\(label): the in-flight anchor must belong to a real move",
                                    file: file, line: line)
        if let eventT, let sampleT {
            XCTAssertGreaterThan(eventT, 0,
                                 "\(label): the in-flight anchor event time must be positive",
                                 file: file, line: line)
            XCTAssertGreaterThanOrEqual(sampleT, eventT,
                                        "\(label): the in-flight sample cannot predate its event",
                                        file: file, line: line)
            if let snapshotT {
                XCTAssertLessThanOrEqual(sampleT, snapshotT,
                                         "\(label): the in-flight sample cannot postdate the after snapshot",
                                         file: file, line: line)
            }
            if let startT {
                XCTAssertGreaterThanOrEqual(eventT, startT,
                                            "\(label): the in-flight anchor must be inside the gesture",
                                            file: file, line: line)
            }
            if let endT {
                XCTAssertLessThanOrEqual(eventT, endT,
                                         "\(label): the in-flight anchor must precede the release",
                                         file: file, line: line)
                // The producer only retains a sample that was genuinely
                // pre-end (`post == 0`), so its sample time must not postdate
                // the release. The accepted 0.1 ms rounding may tie; strict
                // event order stays with `seq < endSeq` below. This keeps an
                // after-end fallback independently rejectable even if its
                // event time is still inside the gesture.
                XCTAssertLessThanOrEqual(sampleT, endT,
                                         "\(label): the in-flight sample cannot postdate the release time",
                                         file: file, line: line)
            }
        }
        if let seq, let endSeq {
            XCTAssertLessThan(seq, endSeq,
                              "\(label): the move sample must precede the terminal release in dispatch order",
                              file: file, line: line)
        }
        for key in ["paX", "paY"] {
            XCTAssertNotNil(finitePinchNumber(anchor[key]),
                            "\(label): the in-flight anchor \(key) must be finite",
                            file: file, line: line)
        }
        if let dpi = pinchNumber(anchor["dpi"]) {
            XCTAssertGreaterThan(dpi, 0,
                                 "\(label): the in-flight anchor dpi must be positive",
                                 file: file, line: line)
        } else {
            XCTFail("\(label): the in-flight anchor dpi is missing", file: file, line: line)
        }

        // The start capture is BEFORE the engine clears its anchor, and the
        // settled capture is AFTER the release cleared it. For the first
        // gesture both are null; after a prior gesture the engine's start
        // handler still clears it. Either way, a non-null value here would
        // mean this is not the actual in-flight anchor.
        let gestureStarts = (after["starts"] as? [[String: Any]] ?? []).filter {
            (($0["k"] as? String) == "ts")
                && pinchNumber($0["tr"]) == 1
                && pinchNumber($0["gi"]) == gesture
        }
        for (index, record) in gestureStarts.enumerated() {
            guard let startGeo = record["eg"] as? [String: Any] else {
                XCTFail("\(label): start \(index) must carry the start-time numeric group",
                        file: file, line: line)
                continue
            }
            XCTAssertEqual(pinchNumber(startGeo["paN"]), 0,
                           "\(label): start \(index) must honestly report no engine anchor; the anchor is latched only on first move",
                           file: file, line: line)
        }
        guard let settled = after["eg"] as? [String: Any] else {
            XCTFail("\(label): the settled numeric group must be present", file: file, line: line)
            return
        }
        XCTAssertEqual(pinchNumber(settled["paN"]), 0,
                       "\(label): the settled snapshot must observe the cleared anchor after release",
                       file: file, line: line)
        attachText("ia=\(anchor)\niaT=\(attempts)\niaN=\(unavailable)"
            + "\ngid=\(String(describing: gesture)) startT=\(String(describing: startT))"
            + " endT=\(String(describing: endT)) endSeq=\(String(describing: endSeq))",
            name: "\(label)-in-flight-anchor")
    }

    /// Validates every entry of the bounded first-live window and returns the
    /// earliest owned-time sample. It accepts only a trusted move of the
    /// current pre-end gesture with a live finite frame scale.
    private func boundedFirstLiveFrame(after: [String: Any], endT: Double,
                                       endGesture: Double, gestureStart: Double,
                                       label: String,
                                       file: StaticString = #filePath,
                                       line: UInt = #line) throws -> OfficeLiveFrame? {
        guard let values = after["fl"] as? [[String: Any]] else { return nil }
        guard !values.isEmpty else {
            throw OfficeCanvasAnchorError(description: "\(label): the bounded first-live window is empty")
        }
        guard values.count <= 8 else {
            throw OfficeCanvasAnchorError(description: "\(label): the bounded first-live window exceeded eight samples")
        }
        var frames: [OfficeLiveFrame] = []
        for value in values {
            guard pinchNumber(value["tr"]) == 1,
                  pinchNumber(value["gi"]) == endGesture,
                  pinchNumber(value["post"]) == 0,
                  pinchNumber(value["stale"]) == 0,
                  pinchNumber(value["iz"]) == 1,
                  let source = value["src"] as? String,
                  source == "b" || source == "r",
                  let eventTime = finitePinchNumber(value["t"]),
                  let sampleTime = finitePinchNumber(value["at"]),
                  let scale = finitePinchNumber(value["zfs"]),
                  let committed = finitePinchNumber(value["z"]),
                  eventTime >= gestureStart, eventTime < endT,
                  sampleTime >= gestureStart, sampleTime < endT,
                  sampleTime >= eventTime else {
                throw OfficeCanvasAnchorError(description: "\(label): every bounded first-live sample must be a trusted pre-end move of this gesture")
            }
            frames.append(OfficeLiveFrame(eventTime: eventTime, sampleTime: sampleTime,
                                          scale: scale, committedZoom: committed, source: source,
                                          distance: finitePinchNumber(value["d"]),
                                          reference: finitePinchNumber(value["d0"]),
                                          eventSeq: finitePinchNumber(value["seq"])))
        }
        return frames.min {
            if $0.eventTime != $1.eventTime { return $0.eventTime < $1.eventTime }
            return $0.sampleTime < $1.sampleTime
        }
    }

    private func assertOfficeLivePinch(baseline: [String: Any], after: [String: Any],
                                       direction: OfficePinchDirection, drawingOn: Bool,
                                       label: String,
                                       file: StaticString = #filePath, line: UInt = #line) throws {
        let baseT = try XCTUnwrap(pinchNumber(baseline["t"]),
                                  "\(label): baseline probe time is missing")
        let baseGid = try XCTUnwrap(pinchNumber(baseline["gid"]),
                                    "\(label): baseline gesture serial is missing")
        let afterT = try XCTUnwrap(pinchNumber(after["t"]),
                                   "\(label): post-gesture probe time is missing")
        XCTAssertGreaterThan(afterT, baseT,
                             "\(label): the post-gesture snapshot must be newer than the baseline",
                             file: file, line: line)
        XCTAssertEqual(pinchNumber(after["gen"]), pinchNumber(baseline["gen"]),
                       "\(label): both snapshots must come from the same probe install",
                       file: file, line: line)
        XCTAssertEqual(pinchNumber(after["rtv"]), 0,
                       "\(label): the ring must not be transfer-shrunk for live-frame acceptance",
                       file: file, line: line)
        XCTAssertNotNil(pinchNumber(after["pd"]),
                        "\(label): the bounded fallback drop counter must be present",
                        file: file, line: line)
        let ring = try XCTUnwrap(after["ring"] as? [[String: Any]],
                                 "\(label): the probe ring must be present")
        let newEvents = ring.filter { (pinchNumber($0["t"]) ?? -1) > baseT }
        XCTAssertFalse(newEvents.isEmpty,
                       "\(label): the real gesture must produce new trusted records", file: file, line: line)
        let cancels = newEvents.filter { ($0["k"] as? String) == "tc" }
        XCTAssertTrue(cancels.isEmpty,
                      "\(label): a successful public pinch must not report touchcancel",
                      file: file, line: line)
        // The authoritative terminal is the one record the probe marked when
        // the gesture actually closed. WebKit can dispatch a second trusted
        // touches=0 end for the other finger; that duplicate never ends the
        // gesture. The bounded cache is a fallback only when the ring no
        // longer contains the matching terminal record. It never substitutes
        // for a missing post-end sample and never accepts a cancel.
        let cachedTerminal = try XCTUnwrap(after["terminal"] as? [String: Any],
                                           "\(label): the bounded terminal cache is missing")
        let endT = try XCTUnwrap(pinchNumber(after["gend"]),
                                 "\(label): the recorded gesture end time is missing")
        let endGesture = try XCTUnwrap(pinchNumber(after["gid"]),
                                       "\(label): the terminal record must carry the gesture serial")
        XCTAssertGreaterThanOrEqual(endGesture, 1,
                                    "\(label): the real pinch must have a trusted gesture birth",
                                    file: file, line: line)
        // The bounded cache describes the CURRENT gesture, so it must be
        // strictly newer than the baseline snapshot: same install, a later
        // gesture serial and a later end time. A stale cache paired with an
        // unrelated later event (or no fresh pinch at all) fails here.
        XCTAssertGreaterThan(endGesture, baseGid,
                             "\(label): the terminal gesture must be born after the baseline",
                             file: file, line: line)
        XCTAssertGreaterThan(endT, baseT,
                             "\(label): the terminal end must be newer than the baseline",
                             file: file, line: line)
        XCTAssertEqual(pinchNumber(after["gid"]), endGesture,
                       "\(label): the snapshot must describe the just-ended gesture",
                       file: file, line: line)
        XCTAssertEqual(pinchNumber(after["ga"]), 0,
                       "\(label): the gesture must be inactive after touchend", file: file, line: line)
        XCTAssertEqual(pinchNumber(after["gend"]), endT,
                       "\(label): the recorded last-finger end time must match the event",
                       file: file, line: line)
        let cachedSample = try assertStrictOfficeTerminal(
            cachedTerminal, endT: endT, endGesture: endGesture,
            label: "\(label)-cache", file: file, line: line)
        XCTAssertEqual(pinchNumber(cachedTerminal["seq"]), pinchNumber(after["eseq"]),
                       "\(label): the cached terminal must carry the gesture's recorded end sequence",
                       file: file, line: line)
        let ringTerminals = newEvents.filter {
            ($0["k"] as? String) == "te"
                && pinchNumber($0["tr"]) == 1
                && pinchNumber($0["gi"]) == endGesture
                && pinchNumber($0["term"]) == 1
        }
        let endSample: [String: Any]
        if let ringTerminal = ringTerminals.first {
            endSample = try assertStrictOfficeTerminal(
                ringTerminal, endT: endT, endGesture: endGesture,
                label: label, file: file, line: line)
            XCTAssertEqual(pinchNumber(ringTerminal["seq"]), pinchNumber(cachedTerminal["seq"]),
                           "\(label): the ring terminal must agree with the cached terminal's dispatch sequence",
                           file: file, line: line)
            XCTAssertEqual(pinchNumber(endSample["z"]), pinchNumber(cachedSample["z"]),
                           "\(label): the ring terminal and cache must agree on committed zoom",
                           file: file, line: line)
        } else {
            endSample = cachedSample
        }
        for duplicate in newEvents
        where (duplicate["k"] as? String) == "te"
            && pinchNumber(duplicate["tr"]) == 1
            && pinchNumber(duplicate["gi"]) == endGesture
            && pinchNumber(duplicate["t"]) != endT {
            XCTAssertNotEqual(pinchNumber(duplicate["term"]), 1,
                              "\(label): a duplicate touchend must never be terminal",
                              file: file, line: line)
        }
        let afterState = try XCTUnwrap(after["st"] as? [String: Any],
                                       "\(label): the post-gesture engine state is missing")
        XCTAssertEqual(pinchNumber(afterState["iza"]), 0,
                       "\(label): the zoom frame must be closed after touchend",
                       file: file, line: line)
        XCTAssertNil(pinchNumber(afterState["zfs"]),
                     "\(label): no zoom-frame scale may remain after touchend",
                     file: file, line: line)
        let endSeq = try XCTUnwrap(pinchNumber(after["eseq"]),
                                   "\(label): the release end sequence is missing")
        // The terminal sample must be closed (asserted above) and carries
        // the synchronous nearest commit directly.
        XCTAssertEqual(pinchNumber(endSample["iz"]), 0,
                       "\(label): the terminal sample must be closed at the synchronous commit",
                       file: file, line: line)
        let committedEnd = try XCTUnwrap(pinchNumber(endSample["z"]),
                                         "\(label): the committed end zoom is missing")
        XCTAssertEqual(pinchNumber(afterState["z"]), committedEnd,
                       "\(label): the end sample and the snapshot must agree on committed zoom",
                       file: file, line: line)

        let latest = try XCTUnwrap(after["latest"] as? [String: Any],
                                   "\(label): the bounded latest sample is missing")
        XCTAssertEqual(pinchNumber(latest["gi"]), endGesture,
                       "\(label): latest must describe the current gesture", file: file, line: line)
        XCTAssertEqual(pinchNumber(latest["post"]), 1,
                       "\(label): latest must label the post-end state", file: file, line: line)
        XCTAssertEqual(pinchNumber(latest["stale"]), 0,
                       "\(label): latest must belong to the current gesture", file: file, line: line)
        let latestSource = latest["src"] as? String
        XCTAssertTrue(latestSource == "b" || latestSource == "r",
                      "\(label): latest must name its sampling source",
                      file: file, line: line)
        XCTAssertEqual(pinchNumber(latest["iz"]), 0,
                       "\(label): latest must observe the closed zoom frame", file: file, line: line)
        XCTAssertEqual(pinchNumber(latest["z"]), committedEnd,
                       "\(label): latest must carry the committed end zoom", file: file, line: line)

        let gestures = after["gest"] as? [[String: Any]] ?? []
        let gesture = try XCTUnwrap(gestures.last,
                                    "\(label): the bounded gesture summary is missing")
        XCTAssertEqual(pinchNumber(gesture["g"]), endGesture,
                       "\(label): the summary must describe the current gesture", file: file, line: line)
        let gestureStart = try XCTUnwrap(pinchNumber(gesture["st"]),
                                         "\(label): the summary start time is missing")
        let gestureEnd = try XCTUnwrap(pinchNumber(gesture["en"]),
                                       "\(label): the summary end time is missing")
        XCTAssertGreaterThan(gestureStart, baseT,
                             "\(label): the gesture start must be newer than the baseline",
                             file: file, line: line)
        XCTAssertEqual(pinchNumber(after["gst"]), gestureStart,
                       "\(label): the snapshot and summary must agree on the gesture start",
                       file: file, line: line)
        XCTAssertLessThan(gestureStart, gestureEnd,
                          "\(label): the summary must preserve monotonic start/end order",
                          file: file, line: line)
        XCTAssertEqual(gestureEnd, endT,
                       "\(label): the summary end must match the touchend",
                       file: file, line: line)
        XCTAssertEqual(pinchNumber(gesture["ze"]), committedEnd,
                       "\(label): the summary must carry the committed end zoom",
                       file: file, line: line)

        // Only samples taken after the target handler (window bubble) or at a
        // later render step qualify, and only while they still belong to this
        // gesture and precede its last-finger end. `post`/`stale` make a
        // delayed callback ineligible instead of turning it into false
        // pre-end evidence.
        var live: [OfficeLiveFrame] = []
        for record in newEvents {
            guard (record["k"] as? String) == "tm",
                  pinchNumber(record["tr"]) == 1,
                  pinchNumber(record["gi"]) == endGesture,
                  pinchNumber(record["n"]) == 2,
                  let sample = record["s"] as? [String: Any],
                  pinchNumber(sample["post"]) == 0,
                  pinchNumber(sample["stale"]) == 0,
                  let source = sample["src"] as? String,
                  source == "b" || source == "r",
                  pinchNumber(sample["iz"]) == 1,
                  let scale = pinchNumber(sample["zfs"]),
                  let eventTime = pinchNumber(record["t"]),
                  let sampleTime = pinchNumber(sample["at"]),
                  let committed = pinchNumber(sample["z"]),
                  eventTime < endT,
                  sampleTime >= eventTime,
                  sampleTime <= endT + 0.5
            else { continue }
            live.append(OfficeLiveFrame(eventTime: eventTime, sampleTime: sampleTime,
                                        scale: scale, committedZoom: committed, source: source,
                                        distance: pinchNumber(sample["d"]),
                                        reference: pinchNumber(sample["d0"]),
                                        eventSeq: pinchNumber(record["seq"])))
        }
        XCTAssertGreaterThanOrEqual(live.count, 3,
                                    "\(label): at least three post-target live move samples must precede touchend; got \(live.count)",
                                    file: file, line: line)
        XCTAssertTrue(zip(live, live.dropFirst()).allSatisfy {
            $0.eventTime <= $1.eventTime && $0.sampleTime <= $1.sampleTime
        }, "\(label): live samples must follow monotonic event/sample order", file: file, line: line)

        var distinct: [OfficeLiveFrame] = []
        for frame in live {
            if let previous = distinct.last, previous.scale == frame.scale { continue }
            distinct.append(frame)
        }
        XCTAssertGreaterThanOrEqual(distinct.count, 3,
                                    "\(label): the gesture must publish at least three distinct live frame scales; got \(distinct.map { $0.scale })",
                                    file: file, line: line)
        // The ring is bounded (128) and can drop the gesture's first moves;
        // the probe's separate first-live window is reset at gesture birth
        // and keeps the earliest eight trusted pre-end samples. Use the
        // earliest owned-time entry so a mid-gesture ring record cannot be
        // relabelled as the start.
        let first: OfficeLiveFrame
        if let boundedFirst = try boundedFirstLiveFrame(
            after: after, endT: endT, endGesture: endGesture,
            gestureStart: gestureStart, label: label, file: file, line: line) {
            first = boundedFirst
        } else {
            first = try XCTUnwrap(distinct.first, "\(label): no live frames")
        }
        if first.source == "b" {
            // The event's own bubble sample follows the first move's
            // beginZoom/stepZoom(1) synchronously.
            XCTAssertEqual(first.scale, 1.0, accuracy: 0.01,
                           "\(label): the first bubble live frame must be the gesture-start scale",
                           file: file, line: line)
        } else {
            // A render-step fallback can already include more than one move
            // in the same frame. It must still be near the gesture start,
            // never a mid/late frame relabelled as the beginning.
            XCTAssertLessThanOrEqual(abs(first.scale - 1.0), 0.03,
                                     "\(label): the first fallback frame must be near the gesture start",
                                     file: file, line: line)
        }
        // The historical pairwise "every distinct scale must move
        // monotonically in the commanded direction" rule asserted a
        // property of the INPUT that the synthesized UIKit pinch does not
        // have: its first delivered touchmove can land mid an outward start
        // ramp, and the engine faithfully paints that ramp (the recorded
        // UI2 run: 1.0 → 1.0009). Under the current contract the live frames
        // must instead TRACK the input — verified per-event by the
        // input-correlation block below — while ordering is proven by the
        // probe's own arrival counters, which remain correct even when
        // event times tie at the 0.1 ms recording resolution.
        var lastArrival: Double?
        for frame in live {
            if let seq = frame.eventSeq {
                if let previous = lastArrival {
                    XCTAssertGreaterThan(seq, previous,
                                         "\(label): live move arrival counters must strictly increase in ring order",
                                         file: file, line: line)
                }
                lastArrival = seq
            }
        }
        let final = try XCTUnwrap(distinct.last, "\(label): no final live frame")
        if direction == .inward {
            XCTAssertGreaterThan(final.scale, 1.02,
                                 "\(label): pinch-in live frames must grow meaningfully before touchend",
                                 file: file, line: line)
        } else {
            XCTAssertLessThan(final.scale, 0.98,
                              "\(label): pinch-out live frames must shrink meaningfully before touchend",
                              file: file, line: line)
        }

        let startZoom = try XCTUnwrap(pinchNumber((baseline["st"] as? [String: Any])?["z"]),
                                      "\(label): the starting committed zoom is missing")
        let minZoom = try XCTUnwrap(pinchNumber(afterState["minz"]),
                                    "\(label): the supported minimum zoom is missing")
        let maxZoom = try XCTUnwrap(pinchNumber(afterState["maxz"]),
                                    "\(label): the supported maximum zoom is missing")
        // Input-correlated live scale (current contract). The pinned engine
        // computes the live frame scale as exactly this function of the
        // event's own finger distance: ratio = distance /
        // pinchStartDistance (ZoomControl.onMultiTouchMove), target =
        // getScaleZoom(ratio, pinchStartZoom) (the reviewed 1.2 log/pow
        // inverse pair in DocumentBase), clamped = map._limitZoom(target)
        // (a pure Math.min/max range clamp in Map.js), painted =
        // getZoomScale(clamped, pinchStartZoom), which ViewLayout.stepZoom
        // publishes and CanvasTileLayer.zoomFrameScale exposes. The probe
        // records the SAME event's distance at capture time with the
        // container's own sqrt(pow(abs(dx),2)+pow(abs(dy),2)) formula, RAW
        // and full-precision: touch lists are immutable during dispatch, so
        // the recorded value is bit-identical to the engine's input, and no
        // distance quantization must be bounded across the fixture
        // reference sizes. Only the synchronous window-bubble samples
        // (`src` "b") pair an event's own input with the engine state that
        // event produced; rAF fallback samples never serve as correlation
        // evidence. The remaining recorded quantization is num4 on zfs
        // (<= 5e-5 absolute); the consumer's Swift log/pow versus the
        // engine's JavaScript log/pow differ by a few ulps at these
        // magnitudes (|level delta| within the supported range), far below
        // that bound. 1e-4 absolute therefore covers the recorded
        // representation as a derived bound, not an observed delta.
        var bubbleLive = 0
        var bubbleReference: Double?
        for frame in live where frame.source == "b" {
            bubbleLive += 1
            let distance = try XCTUnwrap(frame.distance,
                                         "\(label): every bubble live frame must carry its event's passive finger distance")
            let reference = try XCTUnwrap(frame.reference,
                                          "\(label): every bubble live frame must carry the gesture's first-move reference")
            XCTAssertGreaterThan(distance, 0,
                                 "\(label): the recorded finger distance must be positive",
                                 file: file, line: line)
            XCTAssertGreaterThan(reference, 0,
                                 "\(label): the recorded first-move reference must be positive",
                                 file: file, line: line)
            if let existing = bubbleReference {
                XCTAssertEqual(reference, existing, accuracy: 0,
                               "\(label): d0 must be immutable across every verified consumer of the same gesture",
                               file: file, line: line)
            }
            bubbleReference = reference
            let ratio = distance / reference
            let target = startZoom + log(ratio) / log(1.2)
            let clamped = min(maxZoom, max(minZoom, target))
            let inputScale = pow(1.2, clamped - startZoom)
            XCTAssertEqual(frame.scale, inputScale, accuracy: 1e-4,
                           "\(label): bubble live scale must match the input-distance ratio (d=\(distance) d0=\(reference) ratio=\(ratio) expected=\(inputScale) recorded=\(frame.scale))",
                           file: file, line: line)
        }
        XCTAssertGreaterThanOrEqual(bubbleLive, 3,
                                    "\(label): at least three same-event bubble live frames must carry the input-correlation proof; got \(bubbleLive)",
                                    file: file, line: line)

        // Current sync commit policy, exactly as accepted in production:
        // range-clamp the FULL-PRECISION JS raw end target with the pinned
        // map._limitZoom, round with exact JavaScript Math.round semantics
        // (floor(x + 0.5), no epsilon), then range-clamp again —
        // _limitZoom(Math.round(_limitZoom(rawTarget))) — committed
        // synchronously in the release handler. The policy is evaluated
        // against the LAST actual input-owned live move: `lfin`, frozen by
        // the probe's monotonic passive dispatch sequence and retained
        // independently of the bounded ring, so event times that tie at the
        // 0.1 ms recording resolution (the recorded UI2 run has exactly such
        // a tie between the last move and the last-finger end) cannot
        // misselect it.
        let lfin = try XCTUnwrap(after["lfin"] as? [String: Any],
                                 "\(label): the probe must retain the last input-owned live move")
        XCTAssertEqual(pinchNumber(lfin["gi"]), endGesture,
                       "\(label): the commit input must belong to the accepted gesture", file: file, line: line)
        XCTAssertEqual(pinchNumber(lfin["tr"]), 1,
                       "\(label): the commit input must be trusted", file: file, line: line)
        XCTAssertEqual(lfin["src"] as? String, "b",
                       "\(label): the commit input must be the same-event synchronous bubble sample",
                       file: file, line: line)
        let lfinTime = try XCTUnwrap(finitePinchNumber(lfin["t"]),
                                     "\(label): the commit input time is missing")
        let lfinAt = try XCTUnwrap(finitePinchNumber(lfin["at"]),
                                   "\(label): the commit input sample time is missing")
        let lfinMove = try XCTUnwrap(finitePinchNumber(lfin["mv"]),
                                     "\(label): the commit input arrival counter is missing")
        let lfinDistance = try XCTUnwrap(finitePinchNumber(lfin["d"]),
                                         "\(label): the commit input must carry its raw finger distance")
        let lfinReference = try XCTUnwrap(finitePinchNumber(lfin["d0"]),
                                          "\(label): the commit input must carry the gesture reference")
        let lfinScale = try XCTUnwrap(finitePinchNumber(lfin["zfs"]),
                                      "\(label): the commit input must carry the live frame scale")
        let lfinSeq = try XCTUnwrap(finitePinchNumber(lfin["seq"]),
                                    "\(label): the commit input must carry its passive dispatch sequence")
        let lfinStartZoom = try XCTUnwrap(finitePinchNumber(lfin["z0"]),
                                          "\(label): the commit input must carry the raw start zoom")
        let lfinTarget = try XCTUnwrap(finitePinchNumber(lfin["rt"]),
                                       "\(label): the commit input must carry the unclamped JS target")
        XCTAssertTrue(lfinStartZoom.isFinite && lfinTarget.isFinite,
                      "\(label): the commit input's zoom/target values must be finite",
                      file: file, line: line)
        XCTAssertGreaterThan(lfinDistance, 0,
                             "\(label): the commit input distance must be positive", file: file, line: line)
        XCTAssertGreaterThan(lfinReference, 0,
                             "\(label): the commit input reference must be positive", file: file, line: line)
        XCTAssertLessThanOrEqual(lfinTime, endT,
                                 "\(label): the commit input must not postdate the release", file: file, line: line)
        XCTAssertGreaterThanOrEqual(lfinAt, lfinTime,
                                   "\(label): the commit input sample must not predate its own event",
                                   file: file, line: line)
        if let existing = bubbleReference {
            XCTAssertEqual(lfinReference, existing, accuracy: 0,
                           "\(label): the commit input must share the gesture's immutable reference",
                           file: file, line: line)
        }
        // The frozen commit input must precede the input end in the
        // probe's monotonic passive dispatch sequence, even when both
        // records round to the same 0.1 ms timestamp; and it must be the
        // gesture's LAST trusted move, otherwise the engine's raw end
        // target came from a move the probe could not correlate and the
        // exact policy is unverifiable.
        XCTAssertLessThan(lfinSeq, endSeq,
                          "\(label): the frozen commit input must precede the release in dispatch sequence",
                          file: file, line: line)
        XCTAssertEqual(pinchNumber(after["lmseq"]), lfinSeq,
                       "\(label): the commit input must be the gesture's last trusted move sequence (a later move without a same-event bubble distance makes the exact policy unverifiable)",
                       file: file, line: line)
        XCTAssertEqual(pinchNumber(gesture["mv"]), lfinMove,
                       "\(label): no trusted move may arrive after the commit input",
                       file: file, line: line)
        // The engine's own unclamped target must equal the full-precision
        // JS value the probe recorded (same Math.log formula). Recompute it
        // independently from the raw distance and the immutable reference:
        // a mismatch means the recorded target does not describe this input
        // and the commit cannot be verified.
        XCTAssertEqual(lfinStartZoom, startZoom, accuracy: 1e-9,
                       "\(label): the frozen input's start zoom must match the baseline commit level",
                       file: file, line: line)
        let recomputedTarget = lfinStartZoom + log(lfinDistance / lfinReference) / log(1.2)
        XCTAssertEqual(lfinTarget, recomputedTarget, accuracy: 1e-9,
                       "\(label): the recorded unclamped JS target must match the independent input-math recomputation",
                       file: file, line: line)
        let rawTarget = lfinTarget
        let lfinClamped = min(maxZoom, max(minZoom, rawTarget))
        XCTAssertEqual(lfinScale, pow(1.2, lfinClamped - startZoom), accuracy: 1e-4,
                       "\(label): the commit input's live scale must match its own distance ratio",
                       file: file, line: line)
        let expectedSync = expectedCommittedZoomSync(rawTarget: rawTarget,
                                                     minZoom: minZoom, maxZoom: maxZoom)
        XCTAssertEqual(committedEnd, expectedSync, accuracy: 1e-6,
                       "\(label): the synchronous commit must equal _limitZoom(Math.round(_limitZoom(raw))) (raw \(rawTarget), live \(lfinScale), recorded \(committedEnd))",
                       file: file, line: line)
        // CONTRACT CHANGE (root decision, superseding the old outward
        // ceil/floor rule): the pinch-end commit is produced by the
        // production _limitZoom(Math.round(_limitZoom(rawTarget))) order —
        // range-clamp the raw target, round to the nearest integer, then
        // range-clamp again; the ordinary programmatic zoom and the legacy
        // Overview pre-clamp guard are unchanged (production-owned, b334
        // lane). The historical UI2 host
        // recorded the outward commit (pinch-out z12 where the current
        // nearest rule is 13) and that data stays historical truth under the
        // OLD rule; it is never relabelled. Running this acceptance against
        // an old host must fail exactly here — that is the intended
        // protection against mixed old-host/new-nearest qualification, not
        // a loosened threshold.
        let impliedFinal = startZoom + log(final.scale) / log(1.2)
        let legacyExpected = expectedCommittedZoom(implied: impliedFinal, direction: direction,
                                                   minZoom: minZoom, maxZoom: maxZoom)
        for frame in distinct {
            let implied = startZoom + log(frame.scale) / log(1.2)
            XCTAssertGreaterThanOrEqual(implied, minZoom - 1e-6,
                                        "\(label): live scale must stay clamped at the minimum",
                                        file: file, line: line)
            XCTAssertLessThanOrEqual(implied, maxZoom + 1e-6,
                                     "\(label): live scale must stay clamped at the maximum",
                                     file: file, line: line)
        }

        let baselinePen = baseline["pen"] as? [String: Any]
        let pen = try XCTUnwrap(after["pen"] as? [String: Any],
                                "\(label): the post-gesture pen state is missing")
        XCTAssertEqual(pinchNumber(pen["d"]), drawingOn ? 1.0 : 0.0,
                       "\(label): the drawing state must be unchanged", file: file, line: line)
        XCTAssertEqual(pinchNumber(pen["as"]), 0,
                       "\(label): no Pencil contact may be active after the gesture",
                       file: file, line: line)
        let strokesBefore = try XCTUnwrap(pinchNumber(baselinePen?["str"]),
                                          "\(label): the baseline Pencil stroke count is missing")
        XCTAssertEqual(pinchNumber(pen["str"]), strokesBefore,
                       "\(label): finger touches must not create Pencil ink", file: file, line: line)
        // Marker-badge machine check. The badge itself is for the recorded
        // video (a human-readable, bounded gesture overlay in the same frame
        // as the canvas); the snapshot's `mk` tokens let the SAME gesture be
        // verified numerically here. Asserted only when the run explicitly
        // enabled the badge, because then the badge is part of the evidence
        // chain; ordinary probe runs leave `mk` present with node=0 and are
        // not judged on it.
        let markerRequested = ProcessInfo.processInfo.environment["FLOE_OFFICE_PENCIL_VISIBLE_MARKER"] == "1"
        var markerDescription = "not-requested"
        if markerRequested {
            let mk = try XCTUnwrap(after["mk"] as? [String: Any],
                                   "\(label): the marker-enabled probe must publish the marker state")
            XCTAssertEqual(pinchNumber(mk["n"]), 1,
                           "\(label): the marker-enabled probe must have created the badge node",
                           file: file, line: line)
            XCTAssertEqual(pinchNumber(mk["g"]), endGesture,
                           "\(label): the badge must describe the just-ended gesture", file: file, line: line)
            XCTAssertEqual(pinchNumber(mk["mv"]), lfinMove,
                           "\(label): the badge move counter must equal the commit input's arrival counter",
                           file: file, line: line)
            XCTAssertEqual(pinchNumber(mk["t"]), 0,
                           "\(label): the badge must show the actual touch count 0 at read time",
                           file: file, line: line)
            XCTAssertEqual(pinchNumber(mk["c"]), 1,
                           "\(label): the badge must show the closed frame/map-commit phase at read time",
                           file: file, line: line)
            markerDescription = "node=1 g=\(pinchNumber(mk["g"]) ?? -1) mv=\(pinchNumber(mk["mv"]) ?? -1) t=\(pinchNumber(mk["t"]) ?? -1) c=\(pinchNumber(mk["c"]) ?? -1)"
        } else if let mk = after["mk"] as? [String: Any] {
            markerDescription = "node=\(pinchNumber(mk["n"]) ?? -1) g=\(pinchNumber(mk["g"]) ?? -1) mv=\(pinchNumber(mk["mv"]) ?? -1) t=\(pinchNumber(mk["t"]) ?? -1) c=\(pinchNumber(mk["c"]) ?? -1)"
        }

        func penSummary(_ value: [String: Any]?) -> String {
            guard let value else { return "missing" }
            return "drawing=\(pinchNumber(value["d"]) ?? -1) activeStroke=\(pinchNumber(value["as"]) ?? -1) strokes=\(pinchNumber(value["str"]) ?? -1)"
        }
        let sources = Dictionary(grouping: distinct) { $0.source }.mapValues { $0.count }
        let frames = distinct.map {
            let scale = String(format: "%.4f", $0.scale)
            let times = String(format: "t=%.1f,at=%.1f,z=%.3f",
                               $0.eventTime, $0.sampleTime, $0.committedZoom)
            return "\(scale)[src=\($0.source),\(times)]"
        }.joined(separator: " ; ")
        attachText("""
        label=\(label)
        direction=\(direction == .inward ? "inward" : "outward")
        baseline-t=\(baseT) after-t=\(afterT)
        gesture=\(endGesture) start=\(gestureStart) end=\(gestureEnd)
        start-zoom=\(startZoom) committed-end=\(committedEnd)
        sync-nearest=\(expectedSync) raw-target=\(rawTarget) legacy-outward=\(legacyExpected)
        lfin=seq=\(lfinSeq)<end-seq=\(endSeq) t=\(lfinTime),at=\(lfinAt),mv=\(lfinMove),d=\(lfinDistance),d0=\(lfinReference),z0=\(lfinStartZoom),zfs=\(lfinScale)
        commit=synchronous-_limitZoom(Math.round(_limitZoom(raw)))
        marker=\(markerDescription)
        bubble-frames=\(bubbleLive) live-samples=\(live.count) distinct-scales=\(distinct.count)
        dropped-fallback-samples=\(pinchNumber(after["pd"]) ?? -1)
        sample-sources=\(sources)
        frames=\(frames)
        pen-before=\(penSummary(baselinePen))
        pen-after=\(penSummary(pen))
        """, name: "office-live-pinch-\(label.replacingOccurrences(of: " ", with: "-"))-evidence")
    }

    private func expectedCommittedZoom(implied: Double, direction: OfficePinchDirection,
                                       minZoom: Double, maxZoom: Double) -> Double {
        // HISTORICAL interpretation helper only: the old host's outward
        // ceil/floor commit (recorded UI2 runs executed exactly this rule,
        // and their stored evidence is described by it — including the old
        // host's z12 where the current nearest rule gives 13; that
        // difference is an intentional contract change, never a relabelling
        // of past data). The current acceptance path uses
        // `expectedCommittedZoomSync`; this helper survives only so the
        // evidence attachment can state the delta.
        // The epsilon only absorbs floating-point noise from
        // log(scale)/log(1.2), so an exact integer boundary is not turned
        // into the next level.
        let epsilon = 1e-6
        let level = direction == .inward ? ceil(implied - epsilon) : floor(implied + epsilon)
        return min(max(level, minZoom), maxZoom)
    }

    /// The current synchronous pinch commit policy, exactly as accepted in
    /// the production lane: `_limitZoom(Math.round(_limitZoom(rawTarget)))`.
    /// The FULL-PRECISION JS raw end target of the last owned input move is
    /// FIRST range-clamped with the pinned map._limitZoom, then rounded with
    /// exact JavaScript `Math.round` semantics — `floor(x + 0.5)` — and then
    /// range-clamped again. Clamping first is the production order and keeps
    /// fractional range edges (for example a fractional minimum) faithful;
    /// the legacy Overview pre-clamp guard and the ordinary programmatic
    /// zoom stay untouched in the product lane. No epsilon window is used:
    /// the probe records the same full-precision target the engine computes
    /// with the same Math.log formula, the consumer validates that target
    /// independently, and a constructed harness half-integer still rounds
    /// deterministically upward exactly as the engine's Math.round does.
    private func expectedCommittedZoomSync(rawTarget: Double, minZoom: Double,
                                           maxZoom: Double) -> Double {
        let clampedRaw = min(maxZoom, max(minZoom, rawTarget))
        let nearest = (clampedRaw + 0.5).rounded(.down)
        return min(maxZoom, max(minZoom, nearest))
    }

    private struct OfficeTouchProbeRead {
        let ok: Bool
        let raw: String
        let dict: [String: Any]?
    }

    private func waitForIdleOfficeTouchProbe(_ app: XCUIApplication,
                                             timeout: TimeInterval) -> OfficeTouchProbeRead {
        // A just-opened document may still be finishing its own programmatic
        // zoom animation. Wait (bounded) for the probe to report a closed
        // frame before the baseline; a real pinch must never be accepted with
        // a stale animation slot.
        let deadline = Date().addingTimeInterval(timeout)
        var last = OfficeTouchProbeRead(ok: false, raw: "missing", dict: nil)
        while Date() < deadline {
            last = readOfficeTouchProbe(app, timeout: 0.75)
            if last.ok,
               let state = last.dict?["st"] as? [String: Any],
               pinchNumber(state["iza"]) == 0,
               pinchNumber(state["zfs"]) == nil,
               pinchNumber(last.dict?["ga"]) == 0 {
                return last
            }
            Thread.sleep(forTimeInterval: 0.25)
        }
        return last
    }

    private func readOfficeTouchProbe(_ app: XCUIApplication, timeout: TimeInterval) -> OfficeTouchProbeRead {
        let probe = app.descendants(matching: .any)
            .matching(identifier: "office.touch-qualification.snapshot").firstMatch
        let deadline = Date().addingTimeInterval(timeout)
        var last = "missing"
        while Date() < deadline {
            if probe.exists, let raw = probe.value as? String {
                last = raw
                if let dict = parseOfficeProbeJSON(raw), pinchNumber(dict["ok"]) == 1 {
                    return OfficeTouchProbeRead(ok: true, raw: raw, dict: dict)
                }
            }
            Thread.sleep(forTimeInterval: 0.25)
        }
        return OfficeTouchProbeRead(ok: false, raw: last, dict: parseOfficeProbeJSON(last))
    }

    private func parseOfficeProbeJSON(_ raw: String) -> [String: Any]? {
        guard let data = raw.data(using: .utf8) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    /// Read-only attachment of the FIXED native input-state element
    /// published by the DEBUG probe under its own identifier
    /// `office.touch-qualification.input-state` (label FLOE_INPUT_STATE).
    /// One bounded accessibility read of a fixed primitive JSON value: it
    /// never waits, taps, focuses or forces anything, derives no acceptance
    /// threshold and never fails the case on its own — it is the honest
    /// native key-window/scene/first-responder/GCKeyboard evidence the
    /// visible-keyboard precondition question needs, attached at the same
    /// decision points as the existing keyboard-visibility facts. Without
    /// the qualification launch the element simply does not exist and the
    /// attachment records the fixed missing marker.
    private func attachNativeInputState(_ app: XCUIApplication, label: String, phase: String) {
        let element = app.descendants(matching: .any)
            .matching(identifier: "office.touch-qualification.input-state").firstMatch
        let raw: String
        if element.exists, let value = element.value as? String {
            raw = value
        } else {
            raw = "{\"v\":1,\"ok\":0,\"reason\":\"element-missing\"}"
        }
        attachText(raw, name: "\(label)-native-input-state-\(phase)")
    }

    private func pinchNumber(_ value: Any?) -> Double? {
        if let number = value as? NSNumber { return number.doubleValue }
        return nil
    }

    private func attachText(_ text: String, name: String) {
        let attachment = XCTAttachment(string: text)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    /// Bounds of the centered fixture's measured line. The match requires the
    /// COMPLETE deterministic fixture title after whitespace-and-case
    /// normalization only — no confusable substitution, no partial-ID
    /// acceptance and no widened probe — so the cropped-title failure the
    /// diagnosis recorded still fails here rather than passing softly.
    /// Keep the default in sync with `OfficeWorkspaceStageFixture.pinchCenterMeasuredText`
    /// and the Calc/Impress selectors in sync with
    /// `pinchCenterCalcMeasuredText` / `pinchCenterPresentationMeasuredText`.
    ///
    /// `image.cgImage` is the stored raster and does not carry the UIImage's
    /// display orientation. Landscape screenshots exported from the failing
    /// run are stored as 1278x2266 portrait pixels with EXIF orientation
    /// `.left`, so OCR must receive that orientation explicitly; otherwise
    /// Vision reads sideways text and the exact whole-title contract fails on
    /// confusables even though the target is fully visible.
    private func officeMeasuredTitleBounds(in image: UIImage, phase: String,
                                           expected: String = "Pen UI 5X8KQ2M7",
                                           attachmentPrefix: String = "office-pencil-center") throws -> CGRect {
        let normalizedExpected = expected.replacingOccurrences(of: " ", with: "").lowercased()
        let cg = try XCTUnwrap(image.cgImage)
        let cgOrientation = cgImagePropertyOrientation(for: image.imageOrientation)
        // Content-free input diagnostics: the next real-App run records the
        // actual UIImage orientation and extents instead of inferring them.
        attachText("""
        phase=\(phase)
        uiOrientation=\(String(describing: image.imageOrientation)) raw=\(image.imageOrientation.rawValue)
        cgOrientation=\(String(describing: cgOrientation)) raw=\(cgOrientation.rawValue)
        cgPixelWidth=\(cg.width) cgPixelHeight=\(cg.height)
        uiWidth=\(image.size.width) uiHeight=\(image.size.height) scale=\(image.scale)
        """, name: "\(attachmentPrefix)-ocr-input-\(phase)")
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.recognitionLanguages = ["en-US"]
        request.usesLanguageCorrection = false
        try VNImageRequestHandler(cgImage: cg, orientation: cgOrientation).perform([request])
        let observations = request.results ?? []
        let details = observations.map { observation in
            "\(observation.topCandidates(1).first?.string ?? "") bounds=\(observation.boundingBox)"
        }.joined(separator: "\n")
        let ocrAttachment = XCTAttachment(string: details)
        ocrAttachment.name = "\(attachmentPrefix)-ocr-\(phase)"
        ocrAttachment.lifetime = .keepAlways
        add(ocrAttachment)
        let title = observations.first { observation in
            guard let text = observation.topCandidates(1).first?.string else { return false }
            return text.replacingOccurrences(of: " ", with: "").lowercased() == normalizedExpected
        }
        return try XCTUnwrap(title, "The complete centered fixture title must be visible for the pinch comparison").boundingBox
    }

    /// Semantic UIImage.Orientation → CGImagePropertyOrientation mapping. The
    /// two enums use different numeric values, so this must not cast rawValue.
    /// It covers all eight cases exactly as documented in ImageIO's
    /// `CGImageProperties.h` compatibility note.
    private func cgImagePropertyOrientation(for orientation: UIImage.Orientation) -> CGImagePropertyOrientation {
        switch orientation {
        case .up: return .up
        case .upMirrored: return .upMirrored
        case .down: return .down
        case .downMirrored: return .downMirrored
        case .left: return .left
        case .leftMirrored: return .leftMirrored
        case .right: return .right
        case .rightMirrored: return .rightMirrored
        @unknown default: return .up
        }
    }

    func testWorkspaceImportAndDocumentAssistant() throws {
        let (app, _, _) = try openImportedDocument()
        defer { app.terminate() }
        let assistant = app.buttons["notes.assistant"]
        XCTAssertTrue(assistant.isHittable)
        assistant.tap()
        let closeAssistant = app.buttons["notes.assistant.close"]
        XCTAssertTrue(closeAssistant.waitForExistence(timeout: 10))
        XCTAssertEqual(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "已选择手记文档")).count, 0)
        let restartAssistant = app.buttons["notes.assistant.restart"]
        XCTAssertTrue(restartAssistant.waitForExistence(timeout: 10))
        let restartReady = XCTNSPredicateExpectation(predicate: NSPredicate(format: "enabled == true"), object: restartAssistant)
        wait(for: [restartReady], timeout: 10)
        assertTouchTarget(restartAssistant)
        capture("notes-document-assistant")
        restartAssistant.tap()
        let restartCompleted = XCTNSPredicateExpectation(predicate: NSPredicate(format: "enabled == true"), object: restartAssistant)
        wait(for: [restartCompleted], timeout: 30)
        XCTAssertEqual(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "已选择手记文档")).count, 0)
        capture("notes-document-assistant-restarted")
        closeAssistant.tap()
        XCTAssertTrue(assistant.waitForExistence(timeout: 5))

    }

    func testPencilToolsAndFocusedLayout() throws {
        let (app, back, _) = try openImportedDocument()
        defer { app.terminate() }
        // Navigation and document actions share one row; no empty navigation
        // strip above the editor. This also catches phone header wrapping.
        let tools = app.scrollViews["notes.writing.tools"].firstMatch
        XCTAssertTrue(tools.exists)
        XCTAssertLessThan(tools.frame.maxY - back.frame.minY, 120)
        let quickMenu = app.buttons["notes.pencil.quickMenu"]
        XCTAssertTrue(quickMenu.isHittable)
        assertTouchTarget(quickMenu)
        quickMenu.tap()
        let marker = app.buttons["notes.pencil.quickMenu.highlighter"]
        XCTAssertTrue(marker.waitForExistence(timeout: 5))
        capture("notes-pencil-quick-menu-open")
        assertTouchTarget(marker)
        XCTAssertTrue(marker.isHittable)
        XCTAssertGreaterThanOrEqual(marker.frame.minY, app.frame.minY)
        marker.tap()
        let toolbarMarker = app.buttons["notes.tool.highlighter"]
        // Use XCTest's disappearance primitive: the legacy KVC predicate can
        // retain an obsolete SwiftUI snapshot after the wheel has closed.
        XCTAssertTrue(app.buttons["notes.pencil.quickMenu.close"].waitForNonExistence(timeout: 10))
        XCTAssertTrue(toolbarMarker.isSelected)
        XCTAssertFalse(app.buttons["notes.pencil.quickMenu.close"].exists)
        // Reopening highlights the current tool; the center cancels without changing it.
        quickMenu.tap()
        XCTAssertTrue(marker.waitForExistence(timeout: 5))
        XCTAssertTrue(marker.isSelected)
        capture("notes-pencil-quick-menu")
        app.buttons["notes.pencil.quickMenu.close"].tap()
        XCTAssertTrue(app.buttons["notes.pencil.quickMenu.close"].waitForNonExistence(timeout: 10))
        XCTAssertTrue(toolbarMarker.isSelected)
        let inkOptions = app.buttons["notes.ink.options"]
        let writingTools = app.scrollViews["notes.writing.tools"]
        if !inkOptions.isHittable { writingTools.swipeLeft() }
        XCTAssertTrue(inkOptions.isHittable)
        inkOptions.tap()
        let fountain = app.buttons["notes.ink.brush.fountainPen"]
        XCTAssertTrue(fountain.waitForExistence(timeout: 5))
        capture("notes-native-brushes")
        fountain.tap()
        for index in 0..<5 {
            let dot = app.buttons["notes.ink.width.preset.\(index)"]
            XCTAssertTrue(dot.waitForExistence(timeout: 5))
            XCTAssertTrue(dot.isHittable)
            assertTouchTarget(dot)
        }
        let preview = app.descendants(matching: .any)
            .matching(identifier: "notes.ink.preview").firstMatch
        XCTAssertTrue(preview.waitForExistence(timeout: 5))
        app.buttons["notes.ink.width.preset.4"].tap()
        let quickPreview = try XCTUnwrap(preview.value as? String)
        let widthSlider = app.sliders["notes.ink.width.slider"]
        XCTAssertTrue(widthSlider.isHittable)
        widthSlider.adjust(toNormalizedSliderPosition: 0.3)
        XCTAssertTrue(waitUntil(timeout: 5, {
            preview.value as? String != quickPreview
        }), "PDF handwriting fine adjustment must update its stroke preview")
        let savedPreview = try XCTUnwrap(preview.value as? String)
        capture("notes-pdf-five-width-dots-and-preview")
        app.buttons["notes.ink.done"].tap()
        let inkClosed = expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: fountain)
        wait(for: [inkClosed], timeout: 10)
        let writingPen = app.buttons["notes.tool.pencil.tip"]
        if !writingPen.isHittable { writingTools.swipeRight() }
        XCTAssertTrue(writingPen.isSelected)
        if !inkOptions.isHittable { writingTools.swipeLeft() }
        inkOptions.tap()
        XCTAssertTrue(fountain.waitForExistence(timeout: 5))
        XCTAssertTrue(fountain.isSelected)
        XCTAssertEqual(preview.value as? String, savedPreview,
                       "PDF handwriting must retain the fine width after reopening settings")
        app.buttons["notes.ink.brush.marker"].tap()
        app.buttons["notes.ink.done"].tap()
        let markerPanelClosed = expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: fountain)
        wait(for: [markerPanelClosed], timeout: 10)
        if !quickMenu.isHittable { writingTools.swipeRight() }
        let headerToggle = app.buttons["notes.header.toggle"]
        assertTouchTarget(headerToggle)
        let expandedPageY = app.scrollViews.matching(identifier: "notes.pencil.page").firstMatch.frame.minY
        headerToggle.tap()
        XCTAssertFalse(back.exists)
        XCTAssertTrue(quickMenu.isHittable)
        XCTAssertTrue(toolbarMarker.isHittable)
        XCTAssertLessThan(app.scrollViews.matching(identifier: "notes.pencil.page").firstMatch.frame.minY, expandedPageY)
        capture("notes-focused-writing")
        headerToggle.tap()
        XCTAssertTrue(back.waitForExistence(timeout: 5))
        XCTAssertTrue(back.isHittable)
    }

    func testDocumentTabsAndBodySearch() throws {
        let (app, back, create) = try openImportedDocument()
        defer { app.terminate() }
        let toolbarMarker = app.buttons["notes.tool.highlighter"]
        XCTAssertTrue(toolbarMarker.waitForExistence(timeout: 10))
        XCTAssertTrue(toolbarMarker.isHittable)
        toolbarMarker.tap()
        XCTAssertTrue(toolbarMarker.isSelected)
        // Create a second document, then switch back through retained tabs.
        let tabs = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@ AND NOT identifier BEGINSWITH %@", "notes.tab.", "notes.tab.close.")).allElementsBoundByIndex
        let originalTab = try XCTUnwrap(tabs.first { $0.isSelected })
        let originalID = originalTab.identifier
        back.tap()
        create.tap()
        app.buttons["空白手记"].tap()
        let title = app.textFields["notes.create.title"]
        XCTAssertTrue(title.waitForExistence(timeout: 5))
        title.tap(); title.typeText("标签验收")
        app.buttons["创建"].tap()
        // Document creation indexes the new note before the editor appears;
        // the async store work outlives ten seconds on loaded runners.
        XCTAssertTrue(back.waitForExistence(timeout: 30))
        let original = app.buttons[originalID]
        // Repeated runs retain genuine Notes data. The original tab is not
        // necessarily one swipe from the new selection on a narrow phone.
        let tabStrip = app.scrollViews.containing(.button, identifier: originalID).firstMatch
        for _ in 0..<max(6, tabs.count * 3) {
            if original.isHittable { break }
            let targetFrame = original.frame
            let stripFrame = tabStrip.frame
            // A full swipe can skip a 90pt tab in the phone's 150pt strip
            // and oscillate around it. Drag a short distance without a fling.
            // Retained tabs can span thousands of points. Cover distant tabs
            // with larger drags, then use short drags near the viewport.
            let towardLeft = targetFrame.midX < stripFrame.midX
            let distant = abs(targetFrame.midX - stripFrame.midX) > stripFrame.width
            let startX: CGFloat = distant ? (towardLeft ? 0.15 : 0.85) : 0.5
            let start = tabStrip.coordinate(withNormalizedOffset: CGVector(dx: startX, dy: 0.5))
            let endX: CGFloat = distant ? (towardLeft ? 0.85 : 0.15) : (towardLeft ? 0.8 : 0.2)
            let end = tabStrip.coordinate(withNormalizedOffset: CGVector(dx: endX, dy: 0.5))
            start.press(forDuration: 0.1, thenDragTo: end, withVelocity: .slow, thenHoldForDuration: 0.1)
        }
        XCTAssertTrue(original.isHittable)
        original.tap()
        XCTAssertTrue(toolbarMarker.waitForExistence(timeout: 10))
        XCTAssertTrue(toolbarMarker.isSelected)
        capture("notes-document-tabs")
        let closeOriginal = app.buttons[originalID.replacingOccurrences(of: "notes.tab.", with: "notes.tab.close.")]
        XCTAssertTrue(closeOriginal.isHittable)
        closeOriginal.tap()
        // Closing runs through the async session: save guards, then selection
        // of the remaining tab. Require the tab to actually disappear instead
        // of sampling the accessibility tree mid-switch.
        let originalClosed = expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: app.buttons[originalID])
        wait(for: [originalClosed], timeout: 10)
        XCTAssertTrue(back.waitForExistence(timeout: 30))
        // The same palette is opened by Pencil interactions; physical squeeze
        // delivery is a device check, not simulated by this button test.
        back.tap()
        let search = app.textFields["notes.search"]
        XCTAssertTrue(search.waitForExistence(timeout: 10))
        search.tap()
        search.typeText("Inline reading\n") // Submit body text; the keyboard must yield to the results.
        capture("notes-search-query-entered")
        // Retained keyboard AX frames can use stale portrait coordinates on
        // landscape iPad after the keyboard has visibly dismissed. Validate
        // the actual result interaction instead of offscreen keyboard geometry.
        // Query the actual result card instead of a global lazy firstMatch:
        // retained failure screenshots showed both title and body match while
        // XCTest stalled enumerating all StaticText descendants on iPad.
        let result = cardElement(app, kind: "notebook", title: "预览验收")
        XCTAssertTrue(result.waitForExistence(timeout: 10))
        // The title existed before typing. Still require the body-match snippet
        // inside this result, then open this same card below.
        let snippet = result.staticTexts.matching(
            NSPredicate(format: "label CONTAINS[c] %@", "Inline reading")
        ).element(boundBy: 0)
        XCTAssertTrue(snippet.waitForExistence(timeout: 10))
        capture("notes-document-body-search")
        // Landscape iPad fits only a few rows above the keyboard; reveal the
        // match with a real scroll instead of assuming its initial position.
        if !result.isHittable { app.scrollViews["notes.library.scroll"].swipeUp() }
        XCTAssertTrue(result.isHittable)
        result.tap()
        XCTAssertTrue(back.waitForExistence(timeout: 10))
        XCTAssertTrue(back.isHittable)
        capture("notes-body-search-opened-document")
    }

    /// End-to-end library-cover acceptance for real generated Office packages
    /// (Word/Excel/PowerPoint), a notebook page, a mind map and bundled DXF/DWG
    /// drawings. The debug fixture imports them through the same
    /// `NoteFileImporter` path as workspace import; the test then asserts each
    /// library card reports a real content-cover source instead of the explicit
    /// unsupported/placeholder state.
    ///
    /// Office accepts the two-tier product behavior: a real system Quick Look
    /// content representation, or the source-identified native content summary
    /// while the non-guaranteed system host produced no content. A summary card
    /// must additionally publish the diagnostic `summary=content` marker.
    /// The card image stays free of explanatory labels. A settled `quickLook`
    /// card must never report a generic icon fallback; a summary card may record the Quick Look
    /// icon failure in its diagnostics while the published cover remains the
    /// real content summary. CAD must satisfy the bundled viewer
    /// (`engineeringPreview`); `unsupported` and `quickLook` are not accepted
    /// for CAD.
    func testNotesLibraryCardsShowRealContentCovers() throws {
        continueAfterFailure = false
        let ipad = ProcessInfo.processInfo.environment["SIMULATOR_MODEL_IDENTIFIER"]?.hasPrefix("iPad") == true
            || UIDevice.current.userInterfaceIdiom == .pad
        var app = launchNotesWithOfficeCoverFixture(ipad: ipad, resetWord: true)
        defer { app.terminate() }

        let officeSources: Set<String> = ["quickLook", "officeContentSummary"]
        let cases: [CoverCase] = [
            .init(kind: "office", title: "封面验收-Word", allowed: officeSources),
            .init(kind: "office", title: "封面验收-Excel", allowed: officeSources),
            // The 9x25 workbook cannot be represented by the system whole-page
            // render at card size; the bounded content summary is its settled
            // cover and no system request is started.
            .init(kind: "office", title: "封面验收-Excel-宽表", allowed: ["officeContentSummary"]),
            // The first tab is a hidden helper sheet: the bounded summary must
            // show the second (visible) tab and never the hidden data.
            .init(kind: "office", title: "封面验收-Excel-隐藏表", allowed: ["officeContentSummary"]),
            // The visible sheet declares hidden rows/columns; the filtered
            // bounded summary stays the settled cover so the system render
            // cannot show the hidden cells.
            .init(kind: "office", title: "封面验收-Excel-隐藏行列", allowed: ["officeContentSummary"]),
            .init(kind: "office", title: "封面验收-PPT", allowed: officeSources),
            .init(kind: "notebook", title: "封面验收 手写页", allowed: ["notePage"]),
            .init(kind: "mindMap", title: "封面验收 导图", allowed: ["mindMap"]),
            .init(kind: "engineering", title: "封面验收-图纸", allowed: ["engineeringPreview"]),
            .init(kind: "engineering", title: "封面验收-图纸-DWG", allowed: ["engineeringPreview"])
        ]

        var firstWordRevision: Int?
        for cover in cases {
            let parsed = assertContentCover(app, cover: cover)
            if cover.title == "封面验收-Word" { firstWordRevision = parsed.revision }
            if ["封面验收-Excel-宽表", "封面验收-Excel-隐藏表", "封面验收-Excel-隐藏行列"].contains(cover.title) {
                // These cards must retain their summary source diagnostics
                // (a hidden-workbook card must also
                // report the tab-order fallback).
                let card = revealCard(app, kind: cover.kind, title: cover.title)
                let value = card.value as? String ?? ""
                XCTAssertTrue(value.contains("officeContentSummary"),
                              "\(cover.title) cover must be the bounded summary: \(value)")
                XCTAssertTrue(value.contains("summary=content"),
                              "\(cover.title) summary must retain its source diagnostics: \(value)")
                if cover.title == "封面验收-Excel-隐藏表" {
                    XCTAssertTrue(value.contains("workbookEarlierSheet"),
                                  "the hidden first tab must be reported as an earlier-sheet fallback: \(value)")
                }
            }
            capture("notes-cover-\(cover.kind)-\(cover.title)")
        }
        capture("notes-content-covers")

        // Revision-keyed invalidation: rename the Word card through the real
        // Notes store (a save that advances the document revision), then assert
        // the reloaded card reports a strictly newer revision and still a real
        // content cover. A stale cached cover from the pre-rename revision
        // would fail this. The loop above already asserted the Word cover, so
        // reuse its revision instead of paying for a second reveal+poll.
        let originalRevision = firstWordRevision ?? assertContentCover(
            app, cover: .init(kind: "office", title: "封面验收-Word", allowed: officeSources)).revision
        let renamedTitle = "封面验收-Word 修订"
        renameDocument(app, kind: "office", title: "封面验收-Word", to: renamedTitle)
        let renamed = assertContentCover(
            app, cover: .init(kind: "office", title: renamedTitle, allowed: officeSources))
        XCTAssertGreaterThan(renamed.revision, originalRevision,
                             "renaming must invalidate the revision-keyed cover")
        capture("notes-content-cover-renamed")

        // Open the renamed card and return: the regenerated cover survives a
        // real open/close cycle.
        let word = revealCard(app, kind: "office", title: renamedTitle)
        XCTAssertTrue(word.isHittable, "the renamed cover must open a document")
        word.tap()
        // This simulator build has no native Office engine, so the Notes-owned
        // compact header must supply `notes.back`. A device build mounts the
        // native editor's own `office.editor.back` instead (including its
        // document-load-failed state); both are the real product control and
        // both run the same Notes leave guard.
        let back = openedDocumentBackControl(app)
        XCTAssertTrue(back.isHittable)
        let editorReadyDeadline = Date().addingTimeInterval(60)
        while !back.isEnabled && Date() < editorReadyDeadline { Thread.sleep(forTimeInterval: 0.5) }
        XCTAssertTrue(back.isEnabled, "the Office editor must finish opening before its back action is used")
        capture("notes-content-cover-opened")
        back.tap()
        let closeDeadline = Date().addingTimeInterval(60)
        while back.exists && Date() < closeDeadline { Thread.sleep(forTimeInterval: 0.5) }
        XCTAssertFalse(back.exists, "the Office editor must close after its back action")
        XCTAssertTrue(creationControl(app).waitForExistence(timeout: 15),
                      "returning from the opened document must resume the Notes library")
        assertContentCover(app, cover: .init(kind: "office", title: renamedTitle, allowed: officeSources))

        // Quit and relaunch: in-memory covers are gone, so every card must
        // regenerate from the persisted documents. The renamed Word document is
        // kept; only the missing exact fixture ids are re-seeded (never a wipe,
        // never an overwrite of an existing card).
        app.terminate()
        app = launchNotesWithOfficeCoverFixture(ipad: ipad)
        for cover in cases where cover.title != "封面验收-Word" { assertContentCover(app, cover: cover) }
        assertContentCover(app, cover: .init(kind: "office", title: renamedTitle, allowed: officeSources))
        capture("notes-content-covers-relaunch")
    }

    /// Focused VISIBLE-card evidence for the hidden-workbook fixtures. The
    /// exact synthetic title is searched so only that card remains, the card
    /// must be actually hittable in the real frame (a stale frame can survive
    /// while the grid resorts), and the screenshot then proves the hidden-sheet
    /// / hidden-row workbook card itself. The cover matrix above is the
    /// behavioral gate; this is its pixel proof.
    func testHiddenWorkbookCardsShowContentWithoutSummaryLabels() throws {
        continueAfterFailure = false
        let ipad = ProcessInfo.processInfo.environment["SIMULATOR_MODEL_IDENTIFIER"]?.hasPrefix("iPad") == true
            || UIDevice.current.userInterfaceIdiom == .pad
        let app = launchNotesWithOfficeCoverFixture(ipad: ipad)
        defer { app.terminate() }

        let search = app.textFields["notes.search"]
        XCTAssertTrue(search.waitForExistence(timeout: 20), "the Notes search field must exist")
        for title in ["封面验收-Excel-隐藏表", "封面验收-Excel-隐藏行列"] {
            search.tap()
            let existing = (search.value as? String) ?? ""
            if !existing.isEmpty, existing != "搜索所有文档的名称与内容" {
                search.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: existing.count))
            }
            search.typeText(title + "\n")
            let card = cardElement(app, kind: "office", title: title)
            XCTAssertTrue(card.waitForExistence(timeout: 20),
                          "\(title) must remain after its exact search")
            let deadline = Date().addingTimeInterval(30)
            while !(card.exists && card.isHittable) && Date() < deadline {
                app.scrollViews.firstMatch.swipeUp()
                Thread.sleep(forTimeInterval: 0.3)
            }
            XCTAssertTrue(card.isHittable, "\(title) must be visible for the pixel proof")
            let value = card.value as? String ?? ""
            XCTAssertTrue(card.identifier.contains("officeContentSummary"),
                          "\(title) must settle as the bounded summary: \(card.identifier)")
            XCTAssertTrue(value.contains("summary=content"),
                          "\(title) must retain its summary source diagnostics: \(value)")
            Thread.sleep(forTimeInterval: 0.8)
            capture("hidden-card-\(title)")
            // Element-scoped proof: the card's own frame, so the PNG is the
            // card (cover + title) and never a scrolled grid.
            let cardImage = XCTAttachment(screenshot: card.screenshot())
            cardImage.name = "hidden-card-frame-\(title)"
            cardImage.lifetime = .keepAlways
            add(cardImage)
        }
    }

    private struct CoverCase {
        let kind: String
        let title: String
        let allowed: Set<String>
    }

    private struct ParsedCover {
        let source: String
        let revision: Int
    }

    /// Renames a library document through the same context menu a person uses,
    /// committing a real store revision.
    private func renameDocument(_ app: XCUIApplication, kind: String, title: String, to newTitle: String,
                                file: StaticString = #filePath, line: UInt = #line) {
        let card = revealCard(app, kind: kind, title: title, file: file, line: line)
        card.press(forDuration: 1.2)
        let rename = app.buttons["重命名"]
        XCTAssertTrue(rename.waitForExistence(timeout: 10), "rename action must appear", file: file, line: line)
        rename.tap()
        let field = app.textFields["notes.rename.title"]
        XCTAssertTrue(field.waitForExistence(timeout: 10), "rename field must appear", file: file, line: line)
        field.tap()
        let existing = (field.value as? String) ?? ""
        if !existing.isEmpty {
            field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: existing.count))
        }
        field.typeText(newTitle)
        // Commit the field and drop the software keyboard: with a zh-Hans IME
        // the composing state can be pending here, and a still-visible keyboard
        // can eat the confirmation tap.
        field.typeText("\n")
        let save = app.buttons["notes.rename.save"]
        XCTAssertTrue(save.isHittable, "rename save must be tappable", file: file, line: line)
        save.tap()
        // A zh-Hans software keyboard can swallow the first confirmation tap
        // (observed on 2026-10-16: the sheet stayed open, a later gesture typed
        // into the still-focused field, and the store never saw the rename).
        // Confirm the sheet actually closed and retry the real save control;
        // the caller still asserts the rename persisted with a newer revision.
        if !waitUntil(timeout: 5, { !field.exists }) {
            save.tap()
            XCTAssertTrue(waitUntil(timeout: 15, { !field.exists }),
                          "rename sheet must close after saving", file: file, line: line)
        }
    }

    /// Synchronous bounded poll for UI interactions that must settle.
    private func waitUntil(timeout: TimeInterval, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            Thread.sleep(forTimeInterval: 0.25)
        }
        return condition()
    }

    private func launchNotesWithOfficeCoverFixture(ipad: Bool, resetWord: Bool = false) -> XCUIApplication {
        let app = XCUIApplication()
        app.terminate()
        XCUIDevice.shared.orientation = ipad ? .landscapeLeft : .portrait
        app.launchArguments = ["-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN", "-ui-testing",
                               "--ui-test-skip-onboarding", "--ui-test-batch-fixture",
                               "--ui-test-notes-office-thumbnail-fixture"]
        if resetWord { app.launchArguments.append("--ui-test-notes-office-thumbnail-reset-word") }
        if ipad { app.launchArguments.append("-ui-testing-ipad") }
        app.launch()
        if ipad {
            requireLandscapeAfterLaunch(app)
        }
        if !ipad {
            let sidebar = app.buttons["phone.sidebar.open"]
            XCTAssertTrue(sidebar.waitForExistence(timeout: 15))
            sidebar.tap()
        }
        let notes = app.staticTexts["sidebar.notes"].firstMatch
        XCTAssertTrue(notes.waitForExistence(timeout: 15))
        notes.tap()
        XCTAssertTrue(creationControl(app).waitForExistence(timeout: 15))
        return app
    }

    private func creationControl(_ app: XCUIApplication) -> XCUIElement {
        // NotesRootView owns this control in its NavigationStack toolbar. Keep
        // readiness polling inside navigation bars instead of enumerating all
        // document-card descendants. The enabled assertion and its deadline
        // remain unchanged; a missing or disabled control must still fail.
        app.navigationBars.buttons.matching(identifier: "notes.create").element(boundBy: 0)
    }

    private func cardElement(_ app: XCUIApplication, kind: String, title: String) -> XCUIElement {
        // Scope enumeration to the library. SDK27's global firstMatch query
        // stalled inside XCTFilteringTransformerIterator after cold relaunch,
        // while the recording showed the library continuing to render. A
        // bounded-index query avoids that lazy global traversal without
        // changing which card, cover source or revision must be verified.
        app.scrollViews["notes.library.scroll"].buttons
            .matching(NSPredicate(format: "identifier BEGINSWITH %@", "notes.card.\(kind).\(title)."))
            .element(boundBy: 0)
    }

    /// The library is a `LazyVGrid` inside a `ScrollView`, so an offscreen card
    /// is not in the accessibility tree at all. Scroll the grid until the card
    /// is realized instead of assuming every row exists on first query. The
    /// search starts from the top so a card scrolled past during a previous case
    /// is still reachable.
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
        // Reset to the top, then sweep up. The grid re-sorts while covers
        // regenerate (cards can move between cases), so a fixed start point is
        // the only reliable order; a forward-first variant measured 2x slower
        // on a fresh iPhone 17 Pro (219s vs 111s) because it swept away from
        // the target and still needed the reset.
        //
        // The reset itself was the dominant cost on a loaded CI runner (up to
        // eight swipeDowns at ~4s each per case). Use the system status-bar
        // scroll-to-top gesture first; keep a bounded swipe fallback for
        // layouts where the tap does not reach the scroll view.
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

    /// Polls until the card's identifier suffix (the settled cover source plus
    /// `#<revision>`) is one of the allowed real sources. `none`/`placeholder`
    /// and any unexpected source fail; a generic icon is never a source. The
    /// card's accessibility value comes directly from its thumbnail state and must
    /// agree with the source; a summary source additionally requires the
    /// `summary=content` diagnostic marker, so a fallback cannot pass as an
    /// original-layout render.
    @discardableResult
    private func assertContentCover(_ app: XCUIApplication, cover: CoverCase,
                                    file: StaticString = #filePath, line: UInt = #line) -> ParsedCover {
        let card = revealCard(app, kind: cover.kind, title: cover.title, file: file, line: line)
        let deadline = Date().addingTimeInterval(90)
        var parsed = ParsedCover(source: "missing", revision: 0)
        var thumbnailValue = "unavailable"
        while Date() < deadline {
            if card.exists {
                let candidate = parseCover(card.identifier)
                let value = card.value as? String ?? "unavailable"
                parsed = candidate
                thumbnailValue = value
                if cover.allowed.contains(candidate.source) {
                    if value == candidate.source || value.hasPrefix(candidate.source + ";") {
                        break
                    }
                }
            }
            Thread.sleep(forTimeInterval: 0.5)
        }
        // Bounded, redacted generator identity (attempts, timeout, numeric
        // error identity, fallback stage) plus the summary source marker.
        // Never a path, file name or content.
        let attachment = XCTAttachment(string: "\(cover.kind) \(cover.title) coverSource=\(parsed.source) revision=\(parsed.revision) allowed=\(cover.allowed.sorted()) thumbnailValue=[\(thumbnailValue)]")
        attachment.name = "cover-source-\(cover.kind)-\(cover.title)"
        attachment.lifetime = .keepAlways
        add(attachment)
        XCTAssertTrue(cover.allowed.contains(parsed.source),
                      "\(cover.kind) \(cover.title) cover source '\(parsed.source)' is not a real content source \(cover.allowed.sorted())",
                      file: file, line: line)
        XCTAssertGreaterThan(parsed.revision, 0,
                             "\(cover.kind) \(cover.title) must report its document revision",
                             file: file, line: line)
        // `icon=true` records a failed Quick Look attempt, not the published
        // cover. It is only rejected when the settled source is the Quick Look
        // content itself; a summary source keeps the real, source-identified
        // content render and may legitimately carry the recorded icon failure.
        if parsed.source == "quickLook" {
            XCTAssertFalse(thumbnailValue.contains("icon=true"),
                           "\(cover.kind) \(cover.title) is a Quick Look cover and must never report a generic icon fallback",
                           file: file, line: line)
        }
        if parsed.source == "officeContentSummary" {
            XCTAssertTrue(thumbnailValue.contains("summary=content"),
                          "\(cover.kind) \(cover.title) is a summary cover and must publish its summary source identity, got [\(thumbnailValue)]",
                          file: file, line: line)
        } else {
            XCTAssertFalse(thumbnailValue.contains("summary=content"),
                           "\(cover.kind) \(cover.title) is not a summary cover and must not carry the summary source marker",
                           file: file, line: line)
        }
        return parsed
    }

    /// The opened document exposes the Notes-owned compact header back control
    /// when this build has no native Office engine, or the native editor's own
    /// back control when it does (including its load-failed state). Both are
    /// matched in one predicate so the device path never pays a false 45 s wait
    /// for the other control.
    private func openedDocumentBackControl(_ app: XCUIApplication,
                                           file: StaticString = #filePath, line: UInt = #line) -> XCUIElement {
        let backControls = app.buttons.matching(NSPredicate(
            format: "identifier == %@ OR identifier == %@", "notes.back", "office.editor.back"))
        let control = backControls.firstMatch
        XCTAssertTrue(control.waitForExistence(timeout: 45),
                      "an opened Office document must expose a usable back control (notes.back or office.editor.back)",
                      file: file, line: line)
        return control
    }

    /// The card identifier ends in `<source>#<revision>` (see `NotesRootView`).
    private func parseCover(_ identifier: String) -> ParsedCover {
        let suffix = identifier.components(separatedBy: ".").last ?? "none"
        let parts = suffix.components(separatedBy: "#")
        return ParsedCover(source: parts.first ?? "none",
                           revision: Int(parts.dropFirst().first ?? "") ?? 0)
    }

    /// A freshly booted CI iPad can report a portrait App frame after the
    /// pre-launch landscape request. Force one real orientation transition and
    /// still require the final App frame to be landscape before interacting.
    private func requireLandscapeAfterLaunch(_ app: XCUIApplication,
                                             file: StaticString = #filePath, line: UInt = #line) {
        XCUIDevice.shared.orientation = .landscapeLeft
        // XCUIApplication's AX frame can retain portrait bounds after the
        // visible scene rotates. Read the actual window in one snapshot.
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

    private func openImportedDocument() throws -> (XCUIApplication, XCUIElement, XCUIElement) {
        continueAfterFailure = false
        let ipad = ProcessInfo.processInfo.environment["SIMULATOR_MODEL_IDENTIFIER"]?.hasPrefix("iPad") == true || UIDevice.current.userInterfaceIdiom == .pad
        let app = XCUIApplication()
        // A preceding runtime suite can leave its host process alive. Setting
        // orientation first waits for that unrelated event loop to become idle.
        app.terminate()
        XCUIDevice.shared.orientation = ipad ? .landscapeLeft : .portrait
        app.launchArguments = ["-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN", "-ui-testing", "--ui-test-skip-onboarding", "--ui-test-batch-fixture", "--ui-test-pdf-fixture"]
        if ipad { app.launchArguments.append("-ui-testing-ipad") }
        app.launch()
        if ipad {
            requireLandscapeAfterLaunch(app)
        }
        if !ipad {
            let sidebar = app.buttons["phone.sidebar.open"]
            XCTAssertTrue(sidebar.waitForExistence(timeout: 15))
            sidebar.tap()
        }
        let notes = app.staticTexts["sidebar.notes"].firstMatch
        XCTAssertTrue(notes.waitForExistence(timeout: 15))
        notes.tap()
        let create = creationControl(app)
        XCTAssertTrue(create.waitForExistence(timeout: 15))
        capture("notes-library")
        create.tap()
        let importWorkspace = app.buttons["notes.import.workspace"]
        XCTAssertTrue(importWorkspace.waitForExistence(timeout: 15),
                      "the visible creation control must open its import menu")
        if ipad {
            importWorkspace.tap()
        } else {
            // iOS 27 can expose this visible SwiftUI menu row with a valid
            // frame while XCTest reports no suggested AX activation point.
            // Tap the verified on-screen center; the destination assertions
            // below still require the import flow to open for real.
            let menuPoint = AXMenuPoint()
            let menuReady = NSPredicate { _, _ in
                let row = importWorkspace.frame
                let screen = app.windows.firstMatch.frame
                let candidate = CGPoint(x: row.midX, y: row.midY)
                guard row.width > 0, row.height > 0,
                      row.origin.x.isFinite, row.origin.y.isFinite,
                      screen.contains(candidate) else { return false }
                menuPoint.center = candidate
                return true
            }
            let readiness = XCTNSPredicateExpectation(predicate: menuReady, object: importWorkspace)
            XCTAssertEqual(XCTWaiter.wait(for: [readiness], timeout: 10), .completed,
                           "the import menu must finish presenting before its coordinate tap")
            // Reuse the point the readiness predicate just verified: a second
            // frame read can race the menu's layout and return a stale origin
            // (observed as an on-screen assertion failure on a loaded runner
            // even though the row was present).
            let screen = app.windows.firstMatch.frame
            guard let center = menuPoint.center else {
                XCTFail("the workspace import menu row must be visible on screen")
                throw CocoaError(.featureUnsupported)
            }
            app.windows.firstMatch.coordinate(withNormalizedOffset: .zero)
                .withOffset(CGVector(dx: center.x - screen.minX, dy: center.y - screen.minY))
                .tap()
        }
        // The phone's offscreen sidebar retains a conversation with this same
        // title. Select the import row's own identity, not a global text match.
        // NavigationLink rows are buttons: an any-type descendant predicate scan
        // stalls AX snapshots on loaded runners.
        // The shared simulator retains many independent test workspaces. Use
        // the picker's real search instead of assuming this fixture is in the
        // first realized List rows; never clear the user's or other tests' data.
        let workspaceSearch = app.searchFields["搜索工作区"]
        XCTAssertTrue(workspaceSearch.waitForExistence(timeout: 10))
        workspaceSearch.tap()
        workspaceSearch.typeText("批量选择测试\n")
        let workspace = app.buttons.matching(NSPredicate(
            format: "identifier BEGINSWITH %@ AND label CONTAINS %@",
            "workspace.import.source.", "批量选择测试"
        )).firstMatch
        XCTAssertTrue(workspace.waitForExistence(timeout: 30))
        workspace.tap()
        let file = app.buttons["office.attachment.workspace.file.预览验收.pdf"]
        XCTAssertTrue(file.waitForExistence(timeout: 10))
        capture("notes-workspace-import")
        file.tap()
        let back = app.buttons["notes.back"]
        let editorAppeared = back.waitForExistence(timeout: 20)
        // Full-screen presentation can expose a control before its transition
        // makes it interactive. Require the foreground control, not a covered
        // library navigation item, and retain the tree for a failing transition.
        if !editorAppeared {
            let tree = XCTAttachment(string: app.debugDescription)
            tree.name = "notes-editor-after-import-tree"
            tree.lifetime = .keepAlways
            add(tree)
        }
        XCTAssertTrue(editorAppeared)
        let editorReady = expectation(for: NSPredicate(format: "hittable == true"), evaluatedWith: back)
        wait(for: [editorReady], timeout: 10)
        XCTAssertEqual(app.buttons.matching(identifier: "notes.back").count, 1)
        XCTAssertTrue(back.isHittable)
        assertTouchTarget(back)
        XCTAssertFalse(app.navigationBars["从工作区导入"].exists)
        XCTAssertFalse(app.textFields["notes.search"].isHittable)
        XCTAssertTrue(app.scrollViews.matching(identifier: "notes.pencil.page").firstMatch.waitForExistence(timeout: 10))
        capture("notes-imported-pdf-fullscreen")

        return (app, back, create)
    }

    /// Polls the toggle's published accessibility value. The App localizes the
    /// value, so both the zh-Hans and English spellings of the same real state
    /// are accepted; no synthetic state is manufactured.
    private func waitForDrawingValue(_ toggle: XCUIElement, on: Bool, timeout: TimeInterval) -> Bool {
        waitUntil(timeout: timeout) {
            guard toggle.exists else { return false }
            let value = ((toggle.value as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            return on ? (value == "已开启" || value == "On") : (value == "已关闭" || value == "Off")
        }
    }

    /// Establishes that no software keyboard visibly occludes the Office
    /// canvas before the pinch baseline, dismissing an actually onscreen
    /// keyboard through the platform's own hide key. Ordinary mode can
    /// legitimately open with this keyboard onscreen (the toolbar test
    /// asserts the same opening state); pinching a keyboard-shrunk
    /// viewport would fail the fixed visible-canvas floor by design.
    /// Readiness is judged from public onscreen geometry and actionable
    /// state, never raw node existence or count: a retained zero-height
    /// offscreen AX node (Word UI4 recorded keyboard (0,744,1133,0)
    /// against app (0,0,1133,744) with every key offscreen and
    /// non-hittable while the layout already reported the full 568 px
    /// canvas) does not block the pinch, but a real docked or floating
    /// keyboard must still be dismissed through its exposed public hide
    /// key, and unknown or invalid geometry fails closed instead of
    /// silently passing. This is public UI input only: no synthetic
    /// touch, no fixed sleep, no lowered canvas bound and no product
    /// debug control. The hide lookup stays fail-closed: when an
    /// onscreen keyboard exposes no hittable public hide key the test
    /// fails with a bounded dump of the keyboard's actually exposed
    /// identifiers and labels instead of guessing coordinates or edges.
    /// After the hide tap the wait is for onscreen occlusion to end, so
    /// the hide animation's retained offscreen node cannot re-fail an
    /// otherwise clean canvas; two consecutive samples keep a transient
    /// mid-animation reading from settling early.
    /// A genuine positive-area software keyboard is required for the
    /// visible-hide regression. If opening Word left it hidden, tap the real
    /// document through the existing canvas anchor once. No text insertion,
    /// programmatic focus, keyboard preference change or skip can substitute
    /// for this precondition; failure leaves decision-point evidence.
    private func requireVisibleWordKeyboardBeforePinchHide(
        _ app: XCUIApplication, label: String, requireFreshCanvasTap: Bool = false,
        file: StaticString = #filePath, line: UInt = #line
    ) throws {
        if requireFreshCanvasTap && !officeKeyboardOnscreenReadiness(app).endsOnscreenOcclusion {
            attachKeyboardVisibilityFacts(app, label: label, phase: "before-required-fresh-tap")
            attachNativeInputState(app, label: label, phase: "before-required-fresh-tap")
            XCTFail("\(label): the keyboard must still be hidden before the next genuine document tap",
                    file: file, line: line)
            return
        }
        switch officeKeyboardOnscreenReadiness(app) {
        case .noKeyboard, .offscreenStale:
            let web = app.webViews.firstMatch
            XCTAssertTrue(web.waitForExistence(timeout: 10), file: file, line: line)
            let anchor = try waitForReadyCanvasAnchor(
                app, web: web, label: "\(label)-show-visible-word-keyboard")
            anchor.tap()
        case .onscreen:
            break
        case .invalidGeometry(let reason):
            attachKeyboardVisibilityFacts(app, label: label, phase: "required-visible-invalid-geometry")
            attachNativeInputState(app, label: label, phase: "required-visible-invalid-geometry")
            XCTFail("\(label): cannot establish keyboard input precondition from invalid geometry: \(reason)",
                    file: file, line: line)
            return
        }
        var last: OfficeKeyboardReadiness = .noKeyboard
        let visible = waitUntil(timeout: 15) {
            last = officeKeyboardOnscreenReadiness(app)
            guard case .onscreen = last else { return false }
            let overlap = app.keyboards.firstMatch.frame.intersection(app.frame)
            return !overlap.isNull && overlap.width > 0 && overlap.height > 0
        }
        attachKeyboardVisibilityFacts(app, label: label, phase: "required-visible-before-hide")
        // The native key-window/scene/first-responder/GCKeyboard facts are
        // attached on BOTH paths (pass and fail) at this exact decision
        // point: they are evidence for interpretation, never a new gate.
        attachNativeInputState(app, label: label, phase: "required-visible-before-hide")
        XCTAssertTrue(visible,
                      "\(label): the visible-hide regression requires an actual positive-area software keyboard before using its public Hide key; last state: \(last)",
                      file: file, line: line)
    }

    private func dismissSoftwareKeyboardBeforePinchBaseline(
        _ app: XCUIApplication, label: String,
        file: StaticString = #filePath, line: UInt = #line
    ) -> Bool {
        let keyboard = app.keyboards.firstMatch
        guard keyboard.waitForExistence(timeout: 5) else { return false }
        switch officeKeyboardOnscreenReadiness(app) {
        case .noKeyboard:
            return false
        case .offscreenStale:
            attachKeyboardVisibilityFacts(app, label: label, phase: "before-hide-lookup-offscreen-stale")
            return false
        case .invalidGeometry(let reason):
            attachKeyboardVisibilityFacts(app, label: label, phase: "before-hide-lookup-invalid-geometry")
            XCTFail("\(label): the keyboard node's onscreen readiness could not be established from public geometry (\(reason)); refusing to guess",
                    file: file, line: line)
            return false
        case .onscreen(let visibleHeight, let hittable):
            attachKeyboardVisibilityFacts(app, label: label, phase: "before-hide-lookup")
            attachNativeInputState(app, label: label, phase: "before-hide-lookup")
            attachText("onscreen-keyboard visible-height=\(visibleHeight) hittable=\(hittable)",
                       name: "\(label)-keyboard-readiness-onscreen")
            var hideKey: XCUIElement?
            for identifier in ["UIKeyboardDismissButton", "keyboard.dismiss"] {
                let candidate = keyboard.buttons[identifier]
                if candidate.exists && candidate.isHittable { hideKey = candidate; break }
            }
            if hideKey == nil {
                for text in ["隐藏键盘", "Hide Keyboard", "Hide keyboard"] {
                    let candidate = keyboard.buttons
                        .matching(NSPredicate(format: "label == %@", text)).firstMatch
                    if candidate.exists && candidate.isHittable { hideKey = candidate; break }
                }
            }
            if hideKey == nil {
                let compactDown = app.buttons["keyboard.chevron.compact.down"]
                if compactDown.exists && compactDown.isHittable { hideKey = compactDown }
            }
            guard let hideKey else {
                attachKeyboardVisibilityFacts(app, label: label, phase: "hide-key-not-hittable")
                attachNativeInputState(app, label: label, phase: "hide-key-not-hittable")
                let exposed = keyboard.buttons.allElementsBoundByIndex.prefix(24)
                    .map { "\($0.identifier)|\($0.label)" }.joined(separator: ", ")
                attachText("keyboard-hide-key-missing: \(exposed)", name: "\(label)-keyboard-keys")
                XCTFail("\(label): the software keyboard is onscreen but its public hide key was not exposed; refusing to pinch a keyboard-shrunk canvas",
                        file: file, line: line)
                return false
            }
            hideKey.tap()
            var last: OfficeKeyboardReadiness = .noKeyboard
            var settled = 0
            let cleared = waitUntil(timeout: 15) {
                last = officeKeyboardOnscreenReadiness(app)
                if last.endsOnscreenOcclusion { settled += 1 } else { settled = 0 }
                return settled >= 2
            }
            attachKeyboardVisibilityFacts(app, label: label, phase: "after-hide")
            // Post-hide native facts: with App12's genuinely positive
            // keyboard this records the state the public Hide actually left
            // behind; with an App13-style zero-height node it is attached
            // the same way. Evidence only, no new gate.
            attachNativeInputState(app, label: label, phase: "after-hide")
            XCTAssertTrue(cleared,
                          "\(label): the keyboard's own hide key must end its onscreen occlusion before the pinch canvas baseline; last readiness: \(last)",
                          file: file, line: line)
            return cleared
        }
    }

    /// Ordinary-mode keyboard RETENTION proof. Once
    /// `dismissSoftwareKeyboardBeforePinchBaseline` has actually ended the
    /// onscreen occlusion through the platform's own hide key (or no
    /// keyboard was ever onscreen), a real canvas pinch must not bring the
    /// software keyboard back: a pinch is not text entry, and the user
    /// expects ordinary-mode zoom to work naturally. A keyboard that becomes
    /// visible again is therefore a product focus regression, not a test
    /// artifact — this is asserted at the decision point using the same
    /// public positive-area/actionable classifier as the pre-baseline gate.
    /// It never taps Hide again, never waits for the keyboard to leave, and
    /// never re-reads an earlier decision: the state AT the assertion is the
    /// state proven. `.noKeyboard` and the retained zero-overlap
    /// `.offscreenStale` node remain allowed (both end onscreen occlusion);
    /// a newly onscreen keyboard or invalid geometry fails closed with the
    /// actual decision-point facts, a whole-screen capture and the live
    /// viewport probe snapshot attached via the existing fact collector.
    /// Drawing-on mode never reaches this: the pen toggle already asserts
    /// its own dismissal path, unchanged.
    private func assertKeyboardHiddenAfterPinch(
        _ app: XCUIApplication, label: String, phase: String,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        let readiness = officeKeyboardOnscreenReadiness(app)
        guard !readiness.endsOnscreenOcclusion else { return }
        attachKeyboardVisibilityFacts(app, label: label, phase: phase)
        XCTFail("\(label)/\(phase): the pinch must not re-present the software keyboard after the baseline ended its onscreen occlusion; decision-point readiness: \(readiness)",
                file: file, line: line)
    }

    /// Readiness of the software keyboard from public onscreen geometry
    /// and actionable state only. Raw `.exists`/`.count` cannot decide:
    /// a dismissed keyboard can leave a retained offscreen node, while
    /// an actually covering keyboard must block the pinch until its own
    /// public hide key has been used.
    private enum OfficeKeyboardReadiness {
        case noKeyboard
        case offscreenStale
        case onscreen(visibleHeight: CGFloat, hittable: Bool)
        case invalidGeometry(reason: String)

        /// True when nothing visibly occludes the canvas: no node at all,
        /// or only a retained node with no positive-area onscreen overlap.
        /// Onscreen and unknown-geometry states never satisfy readiness.
        var endsOnscreenOcclusion: Bool {
            switch self {
            case .noKeyboard, .offscreenStale: return true
            case .onscreen, .invalidGeometry: return false
            }
        }
    }

    private func officeKeyboardOnscreenReadiness(
        _ app: XCUIApplication
    ) -> OfficeKeyboardReadiness {
        let keyboard = app.keyboards.firstMatch
        guard keyboard.exists else { return .noKeyboard }
        let appFrame = app.frame
        let keyboardFrame = keyboard.frame
        let components = [appFrame.origin.x, appFrame.origin.y,
                          appFrame.size.width, appFrame.size.height,
                          keyboardFrame.origin.x, keyboardFrame.origin.y,
                          keyboardFrame.size.width, keyboardFrame.size.height]
        // Raw stored sizes: CGRect's .width/.height standardize away a
        // negative size, which would hide invalid geometry behind a
        // plausible positive extent.
        guard components.allSatisfy({ $0.isFinite }),
              appFrame.size.width > 0, appFrame.size.height > 0,
              keyboardFrame.size.width >= 0, keyboardFrame.size.height >= 0 else {
            return .invalidGeometry(reason: "app=\(appFrame) keyboard=\(keyboardFrame)")
        }
        let overlap = keyboardFrame.intersection(appFrame)
        let visibleHeight = overlap.isNull ? 0 : max(overlap.height, 0)
        // The public actionable state outranks geometry: a hittable
        // keyboard node is treated as live even if its window-frame
        // snapshot momentarily reads degenerate.
        let hittable = keyboard.isHittable
        let hasVisibleArea = !overlap.isNull && overlap.width > 0 && overlap.height > 0
        if hittable || hasVisibleArea {
            return .onscreen(visibleHeight: visibleHeight, hittable: hittable)
        }
        return .offscreenStale
    }

    /// Bounded public AX facts from the actual decision point. Earlier tap
    /// snapshots cannot establish a later keyboard's frame or hittability.
    /// This collects evidence only; it changes no readiness or pinch guard.
    private func attachKeyboardVisibilityFacts(
        _ app: XCUIApplication, label: String, phase: String
    ) {
        let keyboard = app.keyboards.firstMatch
        var facts = ["phase=\(phase)", "wall=\(Date().timeIntervalSince1970)",
                     "app-frame=\(app.frame)", "keyboard-count=\(app.keyboards.count)",
                     "keyboard-exists=\(keyboard.exists)"]
        if keyboard.exists {
            facts.append("keyboard-frame=\(keyboard.frame)")
            facts.append("keyboard-hittable=\(keyboard.isHittable)")
            facts.append("keyboard-enabled=\(keyboard.isEnabled)")
            for button in keyboard.buttons.allElementsBoundByIndex.prefix(24) {
                facts.append("key=\(button.identifier.prefix(96))|\(button.label.prefix(96))"
                    + " frame=\(button.frame) hittable=\(button.isHittable) enabled=\(button.isEnabled)")
            }
        }
        attachText(facts.joined(separator: "\n"), name: "\(label)-keyboard-visibility-\(phase)")
        let screen = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        screen.name = "\(label)-whole-screen-\(phase)"; screen.lifetime = .keepAlways
        add(screen)
        let viewport = readOfficeTouchProbe(app, timeout: 3)
        attachText(viewport.raw, name: "\(label)-keyboard-viewport-\(phase)")
    }

    /// Redacted, bounded toolbar evidence for the visual host: identities,
    /// actionable state, published state and touch-target frames only.
    private func recordPencilToolbarState(_ app: XCUIApplication, phase: String) {
        let toggle = app.buttons["office.drawing.toggle"]
        let settings = app.buttons["office.drawing.settings"]
        let toggleValue = toggle.exists ? ((toggle.value as? String) ?? "missing") : "missing"
        let panel = app.staticTexts["office.ink.panel"]
        let done = app.buttons["office.ink.done"]
        let popover = app.popovers.firstMatch
        let typeRow = app.descendants(matching: .any)
            .matching(identifier: "office.ink.type").firstMatch
        let facts = XCTAttachment(string: """
            phase=\(phase)
            toggle: exists=\(toggle.exists) enabled=\(toggle.exists && toggle.isEnabled) hittable=\(toggle.exists && toggle.isHittable) value=\(toggleValue) frame=\(toggle.exists ? "\(toggle.frame)" : "missing")
            settings: exists=\(settings.exists) enabled=\(settings.exists && settings.isEnabled) hittable=\(settings.exists && settings.isHittable) frame=\(settings.exists ? "\(settings.frame)" : "missing")
            panel: header exists=\(panel.exists) done exists=\(done.exists) typeRow exists=\(typeRow.exists) popover exists=\(popover.exists) frame=\(popover.exists ? "\(popover.frame)" : "missing")
            types: pen=\(app.buttons["office.ink.type.pen"].exists) marker=\(app.buttons["office.ink.type.marker"].exists) highlighter=\(app.buttons["office.ink.type.highlighter"].exists)
            keyboard: exists=\(app.keyboards.firstMatch.exists)
            """)
        facts.name = "office-pencil-state-\(phase)"
        facts.lifetime = .keepAlways
        add(facts)
    }

    /// Closes the real pen settings popover through its own explicit Done
    /// action. No outside/coordinate tap is accepted: a panel whose Done
    /// action is missing or unreachable is a real defect, not a test problem.
    private func closeOfficeInkPanel(_ app: XCUIApplication,
                                     file: StaticString = #filePath, line: UInt = #line) {
        let done = app.buttons["office.ink.done"]
        guard done.waitForExistence(timeout: 10) else {
            XCTFail("the pen settings panel must expose its explicit Done action", file: file, line: line)
            return
        }
        XCTAssertTrue(done.isHittable, "the explicit Done action must be tappable", file: file, line: line)
        assertTouchTarget(done, file: file, line: line)
        done.tap()
        XCTAssertTrue(app.staticTexts["office.ink.panel"].waitForNonExistence(timeout: 10),
                      "Done must close the pen settings panel", file: file, line: line)
        XCTAssertTrue(app.buttons["office.ink.done"].waitForNonExistence(timeout: 10),
                      "the closed panel must not keep its Done action on screen", file: file, line: line)
    }

    private func capture(_ name: String) {
        let image = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        image.name = name
        image.lifetime = .keepAlways
        add(image)
    }

    private func assertTouchTarget(_ element: XCUIElement, file: StaticString = #filePath, line: UInt = #line) {
        // AX screen-coordinate conversion can return 43.999999999999986 for
        // a 44-point label. Allow subpixel rounding, not a smaller touch target.
        XCTAssertGreaterThanOrEqual(element.frame.width, 43.5, file: file, line: line)
        XCTAssertGreaterThanOrEqual(element.frame.height, 43.5, file: file, line: line)
    }
}
