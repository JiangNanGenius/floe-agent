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
        XCTAssertTrue(word.waitForExistence(timeout: 10)); word.tap()
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

        // XCTest synthesizes real UIKit touches here. Require a change in
        // the document's rendered title, in addition to the separate native
        // tests of frontend TouchEvents and saved vectors.
        let web = app.webViews.firstMatch
        XCTAssertTrue(web.waitForExistence(timeout: 10))
        let beforePinch = web.screenshot()
        web.pinch(withScale: 1.25, velocity: 1)
        Thread.sleep(forTimeInterval: 1)
        let afterPinch = web.screenshot()
        for (name, shot) in [("office-pencil-before-real-pinch", beforePinch),
                             ("office-pencil-after-real-pinch", afterPinch)] {
            let attachment = XCTAttachment(screenshot: shot)
            attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
        }
        let beforeTitle = try officeTitleBounds(in: beforePinch.image)
        let afterTitle = try officeTitleBounds(in: afterPinch.image)
        XCTAssertGreaterThan(afterTitle.width, beforeTitle.width * 1.08,
                             "A UIKit pinch in drawing mode must visibly enlarge the document")
        XCTAssertTrue(waitForDrawingValue(toggle, on: true, timeout: 10),
                      "Pinching must leave the drawing tool enabled")

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

    private func officeTitleBounds(in image: UIImage) throws -> CGRect {
        let cg = try XCTUnwrap(image.cgImage)
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.recognitionLanguages = ["en-US"]
        request.usesLanguageCorrection = false
        try VNImageRequestHandler(cgImage: cg).perform([request])
        let title = request.results?.first { observation in
            guard let text = observation.topCandidates(1).first?.string else { return false }
            return text.replacingOccurrences(of: " ", with: "").lowercased().contains("penui")
        }
        return try XCTUnwrap(title, "The synthetic document title must be visible for the pinch comparison").boundingBox
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
