// FloeAgentUITests — native Mesh panel explicit destructive-consent flow.
//
// SPDX-License-Identifier: MPL-2.0
//
// The canonical `--ui-test-cad-fixture` launch opens the real 100×60×10 plate
// with a Ø10 through-hole, whose body carries a real analytic B-rep. This flow
// drives the shipped Mesh panel on that precise body:
//
//   1. with "Allow destructive mesh edits" off (the default), Simplify is
//      refused by the real service and nothing is previewed;
//   2. after the user explicitly toggles that control on, the next Simplify
//      submits the consent with the preview request and the real transient
//      result appears (a bounded mesh snapshot + result triangle count);
//   3. Cancel drops the preview; a second consented preview is dismissed by
//      closing the real tools sheet, and reopening it leaves the same body
//      tessellation, feature history and undo affordance.
//
// This file is intentionally separate from CADPresentationFlowUITests and from
// the R1 CADMeshOperationFlowUITests: it uses the precise fixture and no
// scheduling probe. Exact B-rep identity, undo-stack depth and change count are
// not exposed by the Mesh panel UI; CADMeshPreviewConsentTests asserts those on
// the same production request shape and CADExactnessPreservationTests carries
// the existing forced-preview/undo coverage.
//
// Source only. Root owns the App build, the one reused canonical iPad
// Simulator run and visual acceptance.

import XCTest

@MainActor
final class CADMeshPanelConsentUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .landscapeLeft
        app = XCUIApplication()
        app.launchArguments += [
            "-AppleLanguages", "(en)", "-AppleLocale", "en_US",
            "-ui-testing", "-ui-testing-ipad",
            "--ui-test-cad-fixture",
        ]
        app.launch()
    }

    override func tearDownWithError() throws {
        app.terminate()
        app = nil
    }

    // MARK: - Test

    func testPreciseBodySimplifyPreviewNeedsExplicitConsentAndCancelLeavesBodyAndHistoryUntouched() throws {
        guard waitFor(app.otherElements["CADFixtureHarness"],
                      "the real CAD fixture must launch", timeout: 90) else { return }

        // Capture the real workbench state that must survive a preview/cancel:
        // the undo/redo affordances and the parametric feature history.
        guard require(app.buttons["UndoButton"].waitForExistence(timeout: 30),
                      "the workbench must expose its undo control") else { return }
        guard require(app.buttons["RedoButton"].waitForExistence(timeout: 10),
                      "the workbench must expose its redo control") else { return }
        let undoWasEnabled = app.buttons["UndoButton"].isEnabled
        let redoWasEnabled = app.buttons["RedoButton"].isEnabled
        guard let historyBefore = featureHistoryRowCount() else { return }
        guard require(historyBefore > 0,
                      "the canonical plate fixture must expose its feature history")
        else { return }

        guard openMeshPanel() else { return }
        guard selectMeshBody() else { return }
        guard let bodyTrianglesBefore = bodyTriangleCountText() else { return }
        guard let bodyTriangleCount = triangleCount(in: bodyTrianglesBefore) else {
            fail("the shipped body row must render its real tessellation count")
            return
        }

        // The canonical consent control exists and starts off.
        guard reveal(consentToggle, defaultDirection: .towardBottom, attempts: 14) else {
            fail("the shipped Allow destructive mesh edits control must be reachable")
            return
        }
        guard require(!consentIsOn,
                      "destructive mesh consent must start off for a fresh panel")
        else { return }

        // 1. Default refusal: no consent, so the real service must refuse the
        // precise B-rep before any compute or document change.
        guard tapMeshAction("Simplify", direction: .towardTop) else { return }
        guard waitFor(panelOutcome, "the refused precise preview must report its outcome",
                      timeout: 30) else { return }
        guard outcomeTextContains("rebuilds meshes and would drop the"),
              outcomeTextContains("Pass forceMesh:true to acknowledge the downgrade.") else {
            fail("the refusal must be the real brep_body_refused message")
            return
        }
        guard require(!pendingIsPresent(),
                      "a refused precise preview must not publish a pending preview")
        else { return }
        guard require(waitUntilGone(app.buttons["CADMeshCancelOperation"].firstMatch, timeout: 8),
                      "the refused preview must clear the busy state")
        else { return }
        guard assertBodyRowUnchanged(bodyTrianglesBefore) else { return }

        // 2. Explicit consent: the user toggles the shipped control; the next
        // Simplify must include that consent in the submitted preview request
        // and show the real transient result for the precise body.
        guard setConsent(on: true) else { return }
        guard tapMeshAction("Simplify", direction: .towardTop) else { return }
        guard waitForPendingPreview(titled: "Simplify", timeout: 30) else { return }
        guard require(!panelOutcome.exists,
                      "a successful consented preview must replace the earlier refusal line")
        else { return }
        guard revealPendingPreview() else {
            fail("the consented pending preview must be reachable in the Mesh panel")
            return
        }
        guard require(meshPanel.descendants(matching: .any)["CADTransientPreview"]
                        .firstMatch.exists,
                      "the consented preview must draw the real transient result mesh")
        else { return }
        guard let previewTriangles = pendingResultTriangleCount() else {
            fail("the pending preview must render its real result triangle count")
            return
        }
        guard require(previewTriangles > 0 && previewTriangles <= bodyTriangleCount,
                      "the consented preview must carry real result geometry for this body "
                      + "(got \(previewTriangles) triangles for a \(bodyTriangleCount)-triangle body)")
        else { return }
        snapshot("Mesh precise consent - real transient preview")
        guard assertBodyRowUnchanged(bodyTrianglesBefore) else { return }

        // 3. Cancel: the transient preview disappears without changing the
        // body, and the workbench remains usable.
        guard cancelPendingPreview() else { return }
        guard require(!pendingIsPresent(), "Cancel must remove the pending preview")
        else { return }
        guard require(!panelOutcome.exists,
                      "Cancel must not publish an outcome or a replacement")
        else { return }
        guard require(!app.buttons["CADMeshCancelOperation"].exists,
                      "Cancel must leave no busy control behind")
        else { return }
        guard assertMeshActionsEnabled() else { return }
        guard assertBodyRowUnchanged(bodyTrianglesBefore) else { return }

        // 4. Sheet-close dismissal: start a second consented preview and close
        // the real tools sheet while that pending preview is still visible.
        // The precise body, feature history and undo stack must stay as they
        // were captured before the first preview.
        guard tapMeshAction("Simplify", direction: .towardBottom) else { return }
        guard waitForPendingPreview(titled: "Simplify", timeout: 30) else { return }
        guard revealPendingPreview() else {
            fail("the second consented preview must be reachable before the sheet is closed")
            return
        }
        guard closeToolsSheet() else { return }
        guard require(app.buttons["UndoButton"].waitForExistence(timeout: 10)
                      && app.buttons["RedoButton"].waitForExistence(timeout: 10),
                      "the workbench undo/redo controls must still exist") else { return }
        guard require(app.buttons["UndoButton"].isEnabled == undoWasEnabled,
                      "closing the panel must not change the undo affordance")
        else { return }
        guard require(app.buttons["RedoButton"].isEnabled == redoWasEnabled,
                      "closing the panel must not change the redo affordance")
        else { return }
        guard let historyAfter = featureHistoryRowCount() else { return }
        guard require(historyAfter == historyBefore,
                      "a refused/previewed/closed operation must not add or remove "
                      + "feature history rows (before \(historyBefore), after \(historyAfter))")
        else { return }

        guard openToolsSheet(), tapMode("Mesh"),
              waitFor(meshBodyRow(), "the precise body must return after reopening",
                      timeout: 20),
              selectMeshBody(),
              assertBodyRowUnchanged(bodyTrianglesBefore) else { return }
        guard assertMeshActionsEnabled() else { return }
        snapshot("Mesh precise consent - body and history unchanged after cancel/close")
    }

    // MARK: - Real panel navigation

    private func openMeshPanel() -> Bool {
        guard openToolsSheet() else { return false }
        guard tapMode("Mesh") else { return false }
        return waitFor(meshBodyRow(), "the precise fixture body must appear in the Mesh panel",
                       timeout: 30)
    }

    private func openToolsSheet() -> Bool {
        var tools = app.buttons["CADWorkbenchToolsButton"].firstMatch
        if !tools.exists || !tools.isHittable {
            let overflow = app.navigationBars.buttons["OverflowBarButtonItem"].firstMatch
            if overflow.waitForExistence(timeout: 5) {
                overflow.tap()
            }
            let labeled = app.buttons["CAD Tools"].firstMatch
            if labeled.waitForExistence(timeout: 5) {
                tools = labeled
            }
        }
        guard require(tools.waitForExistence(timeout: 30),
                      "the workbench must expose its CAD Tools entry") else { return false }
        guard require(tools.isHittable, "the CAD Tools entry must be reachable") else {
            return false
        }
        tools.tap()
        guard waitFor(app.otherElements["CADWorkbenchToolsPanel"],
                      "the native CAD tools sheet must open", timeout: 20) else {
            return false
        }
        expandSheet()
        return true
    }

    private func closeToolsSheet() -> Bool {
        let done = app.buttons["CADToolsSheetCloseButton"].firstMatch
        guard waitFor(done, "the native CAD tools sheet must expose its Close control",
                      timeout: 10) else { return false }
        guard reveal(done, defaultDirection: .towardTop) else {
            fail("the sheet Close control must be reachable")
            return false
        }
        done.tap()
        guard waitUntilGone(app.otherElements["CADWorkbenchToolsPanel"], timeout: 15) else {
            fail("closing the CAD tools sheet must hide the Mesh panel")
            return false
        }
        return true
    }

    private func tapMode(_ title: String) -> Bool {
        let segment = app.buttons[title].firstMatch
        guard reveal(segment, defaultDirection: .towardTop) else {
            fail("the real CAD Tools mode \(title) must be reachable")
            return false
        }
        guard require(segment.isHittable, "the CAD Tools mode \(title) must be tappable")
        else { return false }
        segment.tap()
        RunLoop.current.run(until: Date().addingTimeInterval(0.3))
        return true
    }

    private func expandSheet() {
        let bar = app.navigationBars["CAD Tools"].firstMatch
        guard bar.waitForExistence(timeout: 10) else { return }
        bar.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            .press(forDuration: 0.1,
                   thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.12)))
        RunLoop.current.run(until: Date().addingTimeInterval(0.5))
    }

    // MARK: - Real body, consent and operation controls

    private func meshBodyRow() -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@",
                                          "CADMeshBody-")).firstMatch
    }

    private func selectMeshBody() -> Bool {
        if app.staticTexts["1 bodies selected"].exists { return true }
        let row = meshBodyRow()
        guard reveal(row, defaultDirection: .towardTop) else {
            fail("the precise fixture body row must be reachable in the Mesh panel")
            return false
        }
        if app.staticTexts["1 bodies selected"].exists { return true }
        row.tap()
        return waitFor(app.staticTexts["1 bodies selected"],
                       "the Mesh panel must report the actual selected body", timeout: 5)
    }

    /// The shipped consent control. It is a SwiftUI Toggle rendered as a real
    /// switch; the identifier is applied to the Toggle itself. Some host
    /// builds place the identifier on the wrapping row, so resolve the actual
    /// switch inside it when needed.
    private var consentToggle: XCUIElement {
        let direct = app.switches["CADMeshForceDowngrade"].firstMatch
        if direct.exists { return direct }
        let identified = app.descendants(matching: .any)["CADMeshForceDowngrade"].firstMatch
        if identified.exists, identified.elementType != .switch {
            let inner = identified.switches.firstMatch
            if inner.exists { return inner }
        }
        return identified
    }

    private var consentIsOn: Bool {
        guard let value = consentToggle.value as? String else { return false }
        switch value.lowercased() {
        case "1", "on", "true", "yes":
            return true
        default:
            return false
        }
    }

    /// Explicitly toggle the shipped control (never a model/API shortcut) and
    /// prove its rendered state changed before the preview is attempted.
    private func setConsent(on: Bool) -> Bool {
        let toggle = consentToggle
        guard reveal(toggle, defaultDirection: .towardBottom, attempts: 14) else {
            fail("the shipped Allow destructive mesh edits control must be reachable")
            return false
        }
        // The toggle starts off in this launch; turning it on is the explicit
        // user action under test. If a host ever reuses retained state, the
        // desired state is already true and no extra tap is needed.
        if consentIsOn == on { return true }
        // Flip the real trailing switch control: a SwiftUI Toggle's row can be
        // one semantic element, and a synthesized midpoint tap is not a
        // reliable switch flip (the live `CADSheetProbe.setToggle` pins the
        // same behavior). This is still an ordinary user tap on the shipped
        // control, never a model/API shortcut.
        toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.92, dy: 0.5)).tap()
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            if consentIsOn == on { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        }
        fail("the shipped consent control did not change its rendered state to \(on ? "on" : "off")")
        return false
    }

    private func tapMeshAction(_ title: String,
                               direction: SheetScroll = .towardBottom) -> Bool {
        let button = app.buttons[title].firstMatch
        guard reveal(button, defaultDirection: direction) else {
            fail("the shipped \(title) action must be reachable in the Mesh panel")
            return false
        }
        guard require(button.isEnabled,
                      "the shipped \(title) action must be enabled for the selected body")
        else { return false }
        button.tap()
        return true
    }

    private func assertMeshActionsEnabled() -> Bool {
        let repair = app.buttons["Repair"].firstMatch
        let simplify = app.buttons["Simplify"].firstMatch
        guard reveal(repair, defaultDirection: .towardTop) else {
            fail("Repair must be reachable after the preview is cancelled")
            return false
        }
        guard require(repair.isEnabled, "Repair must be enabled after the preview is cancelled")
        else { return false }
        guard require(simplify.exists && simplify.isEnabled,
                      "Simplify must be enabled after the preview is cancelled") else {
            return false
        }
        return true
    }

    /// Reveal the pending card through its real Apply control. The identified
    /// `PanelSection` container itself is not hit-testable, so the card is
    /// brought into view by the shipped action inside it.
    private func revealPendingPreview() -> Bool {
        guard pendingApplyButton.exists else { return false }
        return reveal(pendingApplyButton, defaultDirection: .towardBottom, attempts: 12)
    }

    private func cancelPendingPreview() -> Bool {
        let section = pendingSection
        let cancel = section.buttons["Cancel"].firstMatch
        guard reveal(cancel, defaultDirection: .towardBottom) else {
            // Some hosts expose the pending card's controls as flat siblings.
            let flat = meshPanel.buttons["Cancel"].firstMatch
            guard reveal(flat, defaultDirection: .towardBottom) else {
                fail("the pending preview must expose its real Cancel control")
                return false
            }
            flat.tap()
            return waitUntilGone(pendingSection, timeout: 10)
        }
        cancel.tap()
        return waitUntilGone(pendingSection, timeout: 10)
    }

    // MARK: - Body row and history observables

    /// The body row's rendered `<n> △` text, read from the shipped row. It is
    /// the document's real render triangle count, not a test-provided label.
    private func bodyTriangleCountText() -> String? {
        let row = meshBodyRow()
        guard reveal(row, defaultDirection: .towardTop) else { return nil }
        let texts = row.staticTexts.allElementsBoundByIndex.map(\.label) + [row.label]
        for text in texts where text.contains("△") {
            return text
        }
        return nil
    }

    private func triangleCount(in text: String) -> Int? {
        guard let marker = text.range(of: "△") else { return nil }
        let prefix = text[..<marker.lowerBound].trimmingCharacters(in: .whitespacesAndNewlines)
        let digits = prefix.reversed().prefix { $0.isNumber }.reversed()
        return Int(String(digits))
    }

    private func assertBodyRowUnchanged(_ expected: String) -> Bool {
        guard let current = bodyTriangleCountText() else {
            fail("the precise fixture body row must remain readable")
            return false
        }
        guard require(current == expected,
                      "the precise body tessellation must be unchanged after preview/cancel "
                      + "(expected “\(expected)”, got “\(current)”)")
        else { return false }
        return true
    }

    /// Count of real `HistoryRow-*` rows in the shipped History panel. Opened
    /// and closed through the real toolbar button; no feature is edited.
    private func featureHistoryRowCount() -> Int? {
        let button = app.buttons["HistoryButton"].firstMatch
        guard button.waitForExistence(timeout: 20) else {
            fail("the workbench must expose its real History control")
            return nil
        }
        button.tap()
        let panel = app.otherElements["HistoryPanel"].firstMatch
        let scroll = app.scrollViews["HistoryPanel"].firstMatch
        let deadline = Date().addingTimeInterval(15)
        while Date() < deadline && !panel.exists && !scroll.exists {
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        }
        guard require(panel.exists || scroll.exists,
                      "the shipped History panel must open from the toolbar") else {
            return nil
        }
        let rows = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH %@", "HistoryRow-"))
        let count = rows.count
        button.tap()
        let closeDeadline = Date().addingTimeInterval(10)
        while Date() < closeDeadline && (panel.exists || scroll.exists) {
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        }
        guard require(!panel.exists && !scroll.exists,
                      "the shipped History panel must close from the toolbar") else {
            return nil
        }
        return count
    }

    // MARK: - Pending preview and outcome assertions

    private var meshPanel: XCUIElement {
        app.descendants(matching: .any)["CADMeshPanel"].firstMatch
    }

    private var pendingSection: XCUIElement {
        if meshPanel.exists {
            return meshPanel.descendants(matching: .any)["CADMeshPending"].firstMatch
        }
        return app.descendants(matching: .any)["CADMeshPending"].firstMatch
    }

    private var pendingApplyButton: XCUIElement {
        meshPanel.buttons["Apply"].firstMatch
    }

    private var panelOutcome: XCUIElement {
        if meshPanel.exists {
            return meshPanel.descendants(matching: .any)["CADPanelOutcome"].firstMatch
        }
        return app.descendants(matching: .any)["CADPanelOutcome"].firstMatch
    }

    private func pendingIsPresent() -> Bool {
        if pendingSection.exists { return true }
        return meshPanel.exists && pendingApplyButton.exists
    }

    private func waitForPendingPreview(titled title: String,
                                       timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if pendingSectionHasTitle(title) { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.25))
        }
        let seen = pendingIsPresent()
            ? "the pending section exists without its \(title) title"
            : "no pending section was published"
        fail("the real \(title) preview must appear after the user consents; \(seen)")
        return false
    }

    private func pendingSectionHasTitle(_ title: String) -> Bool {
        let section = pendingSection
        if section.exists {
            if section.staticTexts[title].exists { return true }
            if section.label.contains(title) { return true }
            return false
        }
        guard meshPanel.exists, pendingApplyButton.exists else { return false }
        return meshPanel.staticTexts[title].exists
    }

    /// The pending preview's rendered "N triangles in the result" line.
    private func pendingResultTriangleCount() -> Int? {
        var labels = meshPanel.staticTexts.allElementsBoundByIndex.map(\.label)
        if pendingSection.exists, !pendingSection.label.isEmpty {
            labels.append(pendingSection.label)
        }
        for label in labels where label.contains("triangles in the result") {
            guard let marker = label.range(of: " triangles in the result") else { continue }
            let prefix = label[..<marker.lowerBound]
            let digits = prefix.reversed().prefix { $0.isNumber }.reversed()
            if let count = Int(String(digits)) { return count }
        }
        return nil
    }

    private func outcomeTextContains(_ fragment: String) -> Bool {
        let outcome = panelOutcome
        guard outcome.exists else { return false }
        if outcome.label.contains(fragment) { return true }
        return outcome.staticTexts.allElementsBoundByIndex.contains {
            $0.label.contains(fragment)
        }
    }

    // MARK: - Scrolling, waits and diagnostics

    private enum SheetScroll {
        /// Finger moves up; lower content is revealed.
        case towardBottom
        /// Finger moves down; upper content is revealed.
        case towardTop
    }

    private func reveal(_ element: XCUIElement,
                        defaultDirection: SheetScroll,
                        attempts: Int = 10) -> Bool {
        for _ in 0..<attempts {
            if isVisibleAndHittable(element) { return true }
            let direction = scrollDirection(for: element, fallback: defaultDirection)
            swipeSheet(direction)
            RunLoop.current.run(until: Date().addingTimeInterval(0.25))
        }
        return isVisibleAndHittable(element)
    }

    /// Never ask `isHittable` for an element whose frame is outside the
    /// window. The live OBJ UI139 run showed that an offscreen control can
    /// raise an invalid activation point instead of simply returning false.
    private func isVisibleAndHittable(_ element: XCUIElement) -> Bool {
        guard element.exists else { return false }
        let frame = element.frame
        let window = app.windows.firstMatch.frame
        guard !frame.isEmpty, !window.isEmpty else { return false }
        let center = CGPoint(x: frame.midX, y: frame.midY)
        guard window.contains(center) else { return false }
        return element.isHittable
    }

    private func scrollDirection(for element: XCUIElement,
                                 fallback: SheetScroll) -> SheetScroll {
        guard element.exists else { return fallback }
        let frame = element.frame
        let window = app.windows.firstMatch.frame
        guard !frame.isEmpty, !window.isEmpty else { return fallback }
        if frame.maxY <= window.minY + 40 { return .towardTop }
        if frame.minY >= window.maxY - 40 { return .towardBottom }
        return fallback
    }

    private func swipeSheet(_ direction: SheetScroll) {
        let sheet = app.otherElements["CADWorkbenchToolsPanel"].firstMatch
        guard sheet.exists else {
            if direction == .towardBottom { app.swipeUp() } else { app.swipeDown() }
            return
        }
        let startY: CGFloat = direction == .towardBottom ? 0.72 : 0.28
        let endY: CGFloat = direction == .towardBottom ? 0.30 : 0.70
        sheet.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: startY))
            .press(forDuration: 0.05,
                   thenDragTo: sheet.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: endY)))
    }

    @discardableResult
    private func waitFor(_ element: XCUIElement, _ message: String,
                         timeout: TimeInterval = 15) -> Bool {
        if element.waitForExistence(timeout: timeout) { return true }
        fail(message)
        return false
    }

    private func waitUntilGone(_ element: XCUIElement, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if !element.exists { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        }
        return !element.exists
    }

    @discardableResult
    private func require(_ condition: Bool, _ message: String) -> Bool {
        if condition { return true }
        fail(message)
        return false
    }

    private func fail(_ message: String) {
        let hierarchy = XCTAttachment(string: app.debugDescription)
        hierarchy.name = "Mesh consent failure hierarchy"
        hierarchy.lifetime = .keepAlways
        add(hierarchy)
        let screenshot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        screenshot.name = "Mesh consent failure"
        screenshot.lifetime = .keepAlways
        add(screenshot)
        XCTFail(message)
    }

    private func snapshot(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
