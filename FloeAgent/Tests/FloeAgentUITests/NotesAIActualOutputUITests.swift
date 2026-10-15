// SPDX-License-Identifier: MPL-2.0
import XCTest
import UIKit

/// Normal-App acceptance for the ACTUAL live-AI Office outputs: the exact bytes
/// the R qualification run produced (independently validated by the owner) are
/// imported unchanged through the real Notes importer by
/// `NotesAIActualOutputFixture`, and this test opens each imported card in the
/// standard Notes document surface and captures the screen.
///
/// The bytes and their SHA-256 are injected through the xctestrun environment;
/// a missing payload is a hard failure, never a skip. Nothing is regenerated
/// and no fixture is swapped: the same actual bytes are presented.
@MainActor
final class NotesAIActualOutputUITests: XCTestCase {
    func testNormalNotesCardOpensActualAIOutputs() throws {
        #if !targetEnvironment(simulator)
        throw XCTSkip("the actual-output acceptance runs on the task iPad simulator")
        #else
        continueAfterFailure = false
        let environment = ProcessInfo.processInfo.environment
        let keys = ["FLOE_AI_OUTPUT_WORD_B64", "FLOE_AI_OUTPUT_WORD_SHA256",
                    "FLOE_AI_OUTPUT_XLSX_B64", "FLOE_AI_OUTPUT_XLSX_SHA256",
                    "FLOE_AI_OUTPUT_PPTX_B64", "FLOE_AI_OUTPUT_PPTX_SHA256"]
        for key in ["FLOE_AI_OUTPUT_WORD_B64", "FLOE_AI_OUTPUT_XLSX_B64", "FLOE_AI_OUTPUT_PPTX_B64"] {
            guard let value = environment[key], !value.isEmpty else {
                XCTFail("the actual AI output \(key) must be injected through the xctestrun environment")
                return
            }
        }

        let ipad = UIDevice.current.userInterfaceIdiom == .pad
        let app = XCUIApplication()
        app.terminate()
        XCUIDevice.shared.orientation = ipad ? .landscapeLeft : .portrait
        app.launchArguments = ["-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN", "-ui-testing",
                               "--ui-test-skip-onboarding", "--ui-test-notes-ai-output-fixture"]
        if ipad { app.launchArguments.append("-ui-testing-ipad") }
        for key in keys {
            if let value = environment[key] { app.launchEnvironment[key] = value }
        }
        app.launch()
        defer { app.terminate() }

        if !ipad {
            let sidebar = app.buttons["phone.sidebar.open"]
            if sidebar.waitForExistence(timeout: 15) { sidebar.tap() }
        }
        let notes = app.staticTexts["sidebar.notes"].firstMatch
        XCTAssertTrue(notes.waitForExistence(timeout: 20), "the Notes entry must be reachable")
        notes.tap()

        for title in ["AI 输出-表格", "AI 输出-表格数据", "AI 输出-演示"] {
            let card = cardElement(app, title: title)
            XCTAssertTrue(reveal(card, in: app),
                          "the imported actual-output card \(title) must exist in the Notes library")
            capture("ai-output-card-\(title)")
            card.tap()

            // The surface element exists as soon as the route mounts; the
            // product's own readiness predicate is its accessibility value
            // (文档已就绪 = documentActionsReady), and the opening spinner must
            // be gone. The tab identity is checked too: the previous evidence
            // captured a stale other-document tab because it only waited for
            // element existence.
            let state = waitDocumentReady(app, title: title, timeout: 90)
            XCTAssertTrue(state.ready,
                          "the actual AI output \(title) must reach the product's render-ready state "
                              + "(surfaceExists=\(state.surfaceExists) value=\(state.value) "
                              + "spinner=\(state.spinnerVisible) titlePresent=\(state.titlePresent) "
                              + "selection=\(state.selectionExposed ? String(state.tabSelected) : "n/a"))")
            XCTAssertTrue(state.titlePresent,
                          "the \(title) document identity must be on screen before capture")
            if state.selectionExposed {
                XCTAssertTrue(state.tabSelected,
                              "the \(title) tab exposes a selection and must be the selected one")
            }
            XCTAssertFalse(state.spinnerVisible, "the opening spinner must be gone before capture")
            // The body must be visible, not hidden behind the software
            // keyboard: dismiss it when the platform exposes a dismiss key,
            // then bring the document back to its beginning so the actual
            // paragraphs and the table are in the frame.
            dismissKeyboardIfPresent(app)
            scrollDocumentToBeginning(app)
            Thread.sleep(forTimeInterval: 1.5)
            capture("ai-output-ready-\(title)")
            Thread.sleep(forTimeInterval: 2)
            capture("ai-output-ready2-\(title)")

            closeDocument(app)
            _ = waitUntil(timeout: 30) { !descendant(app, prefix: "office.preview").exists
                && !descendant(app, prefix: "office.editor").exists }
        }
        #endif
    }

    // MARK: - helpers

    private func cardElement(_ app: XCUIApplication, title: String) -> XCUIElement {
        // Bounded-index query scoped to the library avoids the global
        // firstMatch traversal stall on cold relaunch (SDK27).
        app.scrollViews["notes.library.scroll"].buttons
            .matching(NSPredicate(format: "identifier BEGINSWITH %@", "notes.card.office.\(title)."))
            .element(boundBy: 0)
    }

    private func reveal(_ card: XCUIElement, in app: XCUIApplication) -> Bool {
        if card.exists && card.isHittable { return true }
        guard app.scrollViews["notes.library.scroll"].waitForExistence(timeout: 10) else {
            return card.waitForExistence(timeout: 30)
        }
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.02)).tap()
        Thread.sleep(forTimeInterval: 0.4)
        if card.exists && card.isHittable { return true }
        let scroll = app.scrollViews["notes.library.scroll"]
        for _ in 0..<8 where !(card.exists && card.isHittable) { scroll.swipeUp() }
        return card.waitForExistence(timeout: 10) && card.isHittable
    }

    private func descendant(_ app: XCUIApplication, prefix: String) -> XCUIElement {
        app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH %@", prefix))
            .element(boundBy: 0)
    }

    private struct DocumentState {
        let surfaceExists: Bool
        let value: String
        let spinnerVisible: Bool
        let titlePresent: Bool
        let selectionExposed: Bool
        let tabSelected: Bool
        let ready: Bool
    }

    /// Waits for the product's own render-ready predicate:
    /// `office.preview.native`/`office.editor.native` carries
    /// `文档已就绪`/`Document ready` once `documentActionsReady`, and the
    /// `正在打开文档…` opening spinner is gone. The selected document tab is
    /// checked as the target identity, so a stale restored tab can never be
    /// captured as the AI output.
    private func waitDocumentReady(_ app: XCUIApplication, title: String,
                                   timeout: TimeInterval) -> DocumentState {
        let surface = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier == %@ OR identifier == %@",
                                  "office.preview.native", "office.editor.native"))
            .element(boundBy: 0)
        let spinnerText = app.staticTexts.matching(
            NSPredicate(format: "label CONTAINS %@ OR label CONTAINS %@",
                        "正在打开文档", "Opening document")).firstMatch
        let tab = app.buttons[title].firstMatch
        let tabText = app.staticTexts[title].firstMatch
        let deadline = Date().addingTimeInterval(timeout)
        var lastValue = ""
        var titlePresent = false
        var selectionExposed = false
        var tabSelected = false
        while Date() < deadline {
            let value = (surface.value as? String) ?? ""
            if !value.isEmpty { lastValue = value }
            let ready = surface.exists
                && (value.contains("已就绪") || value.lowercased().contains("ready"))
                && !(value.contains("尚未就绪") || value.lowercased().contains("not ready"))
            titlePresent = tab.exists || tabText.exists
            tabSelected = (tab.exists && tab.isSelected) || (tabText.exists && tabText.isSelected)
            // Some platforms report AXSelected for tab buttons and some do
            // not: only claim a selection gate when any of this run's tabs
            // actually exposes one; otherwise the title identity plus the
            // product's ready predicate carry the gate and the captured image
            // is the final content check.
            selectionExposed = tabSelected || ["AI 输出-表格", "AI 输出-表格数据", "AI 输出-演示"].contains { other in
                let button = app.buttons[other].firstMatch
                if button.exists { return button.isSelected }
                let text = app.staticTexts[other].firstMatch
                return text.exists && text.isSelected
            }
            if ready && titlePresent && !spinnerText.exists {
                return DocumentState(surfaceExists: true, value: value,
                                     spinnerVisible: spinnerText.exists,
                                     titlePresent: titlePresent,
                                     selectionExposed: selectionExposed,
                                     tabSelected: tabSelected, ready: true)
            }
            Thread.sleep(forTimeInterval: 0.5)
        }
        return DocumentState(surfaceExists: surface.exists, value: lastValue,
                             spinnerVisible: spinnerText.exists,
                             titlePresent: titlePresent,
                             selectionExposed: selectionExposed,
                             tabSelected: tabSelected, ready: false)
    }

    private func closeDocument(_ app: XCUIApplication) {
        let back = app.buttons["office.editor.back"]
        if back.exists && back.isHittable { back.tap(); return }
        let close = app.buttons.matching(
            NSPredicate(format: "identifier BEGINSWITH %@", "office.preview.close")).firstMatch
        if close.exists && close.isHittable { close.tap(); return }
        let navBack = app.navigationBars.buttons.element(boundBy: 0)
        if navBack.exists { navBack.tap() }
    }

    /// Hides the software keyboard when the platform exposes a dismiss
    /// control; a missing control is not a failure (the next scroll still
    /// brings the beginning of the document into the frame).
    private func dismissKeyboardIfPresent(_ app: XCUIApplication) {
        let keyboard = app.keyboards.firstMatch
        guard keyboard.exists else { return }
        let dismissIdentifiers = ["UIKeyboardDismissButton", "keyboard.dismiss", "Hide keyboard"]
        for identifier in dismissIdentifiers {
            let key = keyboard.buttons[identifier]
            if key.exists && key.isHittable { key.tap(); return }
        }
        let compactDown = app.buttons["keyboard.chevron.compact.down"]
        if compactDown.exists && compactDown.isHittable { compactDown.tap(); return }
        // iPad keyboards also expose the dismiss key as the last button of
        // the bottom row; tap it by position only when it is a real key.
        let lastKey = keyboard.buttons.element(boundBy: keyboard.buttons.count - 1)
        if lastKey.exists && lastKey.isHittable && lastKey.frame.width < 60 { lastKey.tap() }
    }

    /// Scrolls the document surface back to its start with real drags (the
    /// Office surface is a web view; a blind sleep would not move it).
    private func scrollDocumentToBeginning(_ app: XCUIApplication) {
        let surface = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier == %@ OR identifier == %@",
                                  "office.preview.native", "office.editor.native"))
            .element(boundBy: 0)
        guard surface.exists else { return }
        let start = surface.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.35))
        let end = surface.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.8))
        // Two frames may now show different compositions; keep the capture set
        // identical for both.
        for _ in 0..<2 { start.press(forDuration: 0.05, thenDragTo: end) }
    }

    private func waitUntil(timeout: TimeInterval, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            Thread.sleep(forTimeInterval: 0.4)
        }
        return condition()
    }

    private func capture(_ name: String) {
        let image = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        image.name = name
        image.lifetime = .keepAlways
        add(image)
    }
}
