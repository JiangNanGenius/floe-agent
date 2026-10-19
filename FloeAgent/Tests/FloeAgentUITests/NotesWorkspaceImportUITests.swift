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
        fixtureTitle: String = "捏合验收-居中-2",
        fixtureLaunchArgument: String = "--ui-test-office-pinch-center-fixture",
        measuredText: String = "Pen UI 5X8KQ2M7",
        casePrefix: String = "office-pencil-center"
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
        app.launchArguments = ["-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN", "-ui-testing",
                               "--ui-test-skip-onboarding", fixtureLaunchArgument,
                               "--office-touch-qualification"]
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
            dismissSoftwareKeyboardBeforePinchBaseline(app, label: mode)
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
        let afterOutTitle = try officeMeasuredTitleBounds(
            in: afterPinchOut.image, phase: "after-out\(phaseSuffix)",
            expected: measuredText, attachmentPrefix: prefix)
        XCTAssertLessThan(afterOutTitle.width, afterTitle.width * 0.95,
                          "A subsequent UIKit pinch must visibly shrink the document")
        XCTAssertTrue(waitForDrawingValue(toggle, on: drawingOn, timeout: 10),
                      "Repeated pinching must leave the drawing state unchanged")

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
        XCTAssertEqual(pinchNumber(sample["iz"]), 0,
                       "\(label): the terminal sample must observe the closed zoom frame",
                       file: file, line: line)
        XCTAssertNil(pinchNumber(sample["zfs"]),
                     "\(label): the terminal sample must not carry a live frame scale",
                     file: file, line: line)
        XCTAssertNotNil(pinchNumber(sample["z"]),
                        "\(label): the terminal sample must carry the committed zoom",
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
    /// document canvas and lie inside the page-reported canvas rectangle.
    /// This is the actual-UIKit start proof, not a serialized injection hint.
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
        var points: [(String, Double, Double)] = []
        for record in starts {
            guard (record["k"] as? String) == "ts",
                  pinchNumber(record["tr"]) == 1,
                  pinchNumber(record["gi"]) == gesture,
                  let target = record["g"] as? [String: Any],
                  let tag = target["g"] as? String else { continue }
            for point in record["o"] as? [[Any]] ?? [] {
                guard point.count >= 2,
                      let px = finitePinchNumber(point[0]),
                      let py = finitePinchNumber(point[1]) else { continue }
                points.append((tag, px, py))
            }
        }
        XCTAssertGreaterThanOrEqual(points.count, 2,
                                    "\(label): the gesture must expose both trusted touchstarts",
                                    file: file, line: line)
        let canvas = try XCTUnwrap(after["cv"] as? [String: Any],
                                   "\(label): the probe must expose the canvas rectangle",
                                   file: file, line: line)
        let x = try XCTUnwrap(finitePinchNumber(canvas["x"]),
                              "\(label): canvas x is missing", file: file, line: line)
        let y = try XCTUnwrap(finitePinchNumber(canvas["y"]),
                              "\(label): canvas y is missing", file: file, line: line)
        let width = try XCTUnwrap(finitePinchNumber(canvas["w"]),
                                  "\(label): canvas width is missing", file: file, line: line)
        let height = try XCTUnwrap(finitePinchNumber(canvas["h"]),
                                   "\(label): canvas height is missing", file: file, line: line)
        XCTAssertGreaterThan(width, 0,
                             "\(label): canvas width must be positive", file: file, line: line)
        XCTAssertGreaterThan(height, 0,
                             "\(label): canvas height must be positive", file: file, line: line)
        for (tag, px, py) in points {
            XCTAssertEqual(tag, "CANVAS",
                           "\(label): every trusted start must target the document canvas",
                           file: file, line: line)
            XCTAssertGreaterThanOrEqual(px, x - 2,
                                        "\(label): trusted start x must be inside the canvas",
                                        file: file, line: line)
            XCTAssertLessThanOrEqual(px, x + width + 2,
                                     "\(label): trusted start x must be inside the canvas",
                                     file: file, line: line)
            XCTAssertGreaterThanOrEqual(py, y - 2,
                                        "\(label): trusted start y must be inside the canvas",
                                        file: file, line: line)
            XCTAssertLessThanOrEqual(py, y + height + 2,
                                     "\(label): trusted start y must be inside the canvas",
                                     file: file, line: line)
        }
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
                                          scale: scale, committedZoom: committed, source: source))
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
                                        scale: scale, committedZoom: committed, source: source))
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
        for index in 1..<distinct.count {
            if direction == .inward {
                XCTAssertGreaterThan(distinct[index].scale, distinct[index - 1].scale,
                                     "\(label): live frames must increase during a pinch-in",
                                     file: file, line: line)
            } else {
                XCTAssertLessThan(distinct[index].scale, distinct[index - 1].scale,
                                  "\(label): live frames must decrease during a pinch-out",
                                  file: file, line: line)
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
        let impliedFinal = startZoom + log(final.scale) / log(1.2)
        let expected = expectedCommittedZoom(implied: impliedFinal, direction: direction,
                                             minZoom: minZoom, maxZoom: maxZoom)
        XCTAssertEqual(committedEnd, expected, accuracy: 1e-6,
                       "\(label): the end commit must keep the original outward integer-level rule (last live scale \(final.scale), implied \(impliedFinal))",
                       file: file, line: line)
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
        start-zoom=\(startZoom) committed-end=\(committedEnd) expected-end=\(expected)
        live-samples=\(live.count) distinct-scales=\(distinct.count)
        dropped-fallback-samples=\(pinchNumber(after["pd"]) ?? -1)
        sample-sources=\(sources)
        frames=\(frames)
        pen-before=\(penSummary(baselinePen))
        pen-after=\(penSummary(pen))
        """, name: "office-live-pinch-\(label.replacingOccurrences(of: " ", with: "-"))-evidence")
    }

    private func expectedCommittedZoom(implied: Double, direction: OfficePinchDirection,
                                       minZoom: Double, maxZoom: Double) -> Double {
        // The source keeps the original outward ceil/floor commit. The
        // epsilon only absorbs floating-point noise from log(scale)/log(1.2),
        // so an exact integer boundary is not turned into the next level.
        let epsilon = 1e-6
        let level = direction == .inward ? ceil(implied - epsilon) : floor(implied + epsilon)
        return min(max(level, minZoom), maxZoom)
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
    /// content representation, or the explicitly labeled native content summary
    /// while the non-guaranteed system host produced no content. A summary card
    /// must additionally publish the `badge=summary` marker (the identity of
    /// the visible "Summary" capsule). A settled `quickLook` card must never
    /// report a generic icon fallback; a summary card may record the Quick Look
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
            // render at card size; the bounded labeled summary is its settled
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
                // These cards must publish the visible summary badge and their
                // real accessibility value (a hidden-workbook card must also
                // report the tab-order fallback).
                let card = revealCard(app, kind: cover.kind, title: cover.title)
                let value = card.value as? String ?? ""
                XCTAssertTrue(value.contains("officeContentSummary"),
                              "\(cover.title) cover must be the bounded summary: \(value)")
                XCTAssertTrue(value.contains("badge=summary"),
                              "\(cover.title) summary must carry the summary badge: \(value)")
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
    func testHiddenWorkbookCardsAreVisibleWithTheSummaryBadge() throws {
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
            XCTAssertTrue(value.contains("badge=summary"),
                          "\(title) must carry the summary badge: \(value)")
            Thread.sleep(forTimeInterval: 0.8)
            capture("hidden-card-\(title)")
            // Element-scoped proof: the card's own frame, so the PNG is the
            // card (cover + title + badge) and never a scrolled grid.
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
    /// `badge=summary` marker, so an unlabelled summary cannot pass as a
    /// correct two-tier cover.
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
        // error identity, fallback stage) plus the summary badge marker.
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
        // content itself; a summary source keeps the real, badge-labeled
        // content render and may legitimately carry the recorded icon failure.
        if parsed.source == "quickLook" {
            XCTAssertFalse(thumbnailValue.contains("icon=true"),
                           "\(cover.kind) \(cover.title) is a Quick Look cover and must never report a generic icon fallback",
                           file: file, line: line)
        }
        if parsed.source == "officeContentSummary" {
            XCTAssertTrue(thumbnailValue.contains("badge=summary"),
                          "\(cover.kind) \(cover.title) is a summary cover and must publish the Summary badge identity, got [\(thumbnailValue)]",
                          file: file, line: line)
        } else {
            XCTAssertFalse(thumbnailValue.contains("badge=summary"),
                           "\(cover.kind) \(cover.title) is not a summary cover and must not carry the Summary badge",
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
    private func dismissSoftwareKeyboardBeforePinchBaseline(
        _ app: XCUIApplication, label: String,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        let keyboard = app.keyboards.firstMatch
        guard keyboard.waitForExistence(timeout: 5) else { return }
        switch officeKeyboardOnscreenReadiness(app) {
        case .noKeyboard:
            return
        case .offscreenStale:
            attachKeyboardVisibilityFacts(app, label: label, phase: "before-hide-lookup-offscreen-stale")
            return
        case .invalidGeometry(let reason):
            attachKeyboardVisibilityFacts(app, label: label, phase: "before-hide-lookup-invalid-geometry")
            XCTFail("\(label): the keyboard node's onscreen readiness could not be established from public geometry (\(reason)); refusing to guess",
                    file: file, line: line)
            return
        case .onscreen(let visibleHeight, let hittable):
            attachKeyboardVisibilityFacts(app, label: label, phase: "before-hide-lookup")
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
                let exposed = keyboard.buttons.allElementsBoundByIndex.prefix(24)
                    .map { "\($0.identifier)|\($0.label)" }.joined(separator: ", ")
                attachText("keyboard-hide-key-missing: \(exposed)", name: "\(label)-keyboard-keys")
                XCTFail("\(label): the software keyboard is onscreen but its public hide key was not exposed; refusing to pinch a keyboard-shrunk canvas",
                        file: file, line: line)
                return
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
            XCTAssertTrue(cleared,
                          "\(label): the keyboard's own hide key must end its onscreen occlusion before the pinch canvas baseline; last readiness: \(last)",
                          file: file, line: line)
        }
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
