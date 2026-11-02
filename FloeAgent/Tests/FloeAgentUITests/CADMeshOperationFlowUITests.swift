// FloeAgentUITests — native Mesh panel Cancel / disappearance /
// current-operation lifecycle flow.
//
// SPDX-License-Identifier: MPL-2.0
//
// The fixture launches the existing M19 mesh-only loft document
// (`--ui-test-cad-face-rotation`, an existing saved fixture whose body has no
// analytic B-rep) and installs the existing
// `CADMeshService.testHeavyComputeProbe` scheduling seam through
// `CADDebugFixtures.installMeshPanelComputeProbe`. The probe only holds the
// FIRST real detached compute of `repair`/`simplify`; result geometry is still
// produced by the real kernel, and the service's 10 s compute deadline starts
// after the hold. The hold is a bounded interaction window, not a performance
// measurement, and it is installed only when `--ui-test-cad-mesh-panel-flow`
// is present (DEBUG only).
//
// These tests drive the shipped Mesh panel controls: the real body checklist,
// Repair/Simplify, the busy Cancel button and the real CAD Tools mode picker.
// They pin the user-visible R2 lifecycle fences:
//   * Cancel drops `busy` immediately and no late preview/outcome appears;
//   * hiding and reopening the panel during an operation returns enabled
//     actions (the R1 stuck-busy regression) and a new real preview works;
//   * an older cancelled operation cannot replace a newer preview or publish
//     its cancelled outcome.
//
// Source only. Root owns the App build, the one canonical iPad Simulator run
// and visual acceptance.

import XCTest

@MainActor
final class CADMeshOperationFlowUITests: XCTestCase {
    private var app: XCUIApplication!

    /// Wait past the first operation's 30 s fixture hold plus margin for the
    /// detached worker's start and cancellation. This is a scheduling bound,
    /// not a performance threshold or a claim about compute time.
    private let latePublicationDeadline: TimeInterval = 38

    override func setUpWithError() throws {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .landscapeLeft
        app = XCUIApplication()
        app.launchArguments += [
            "-AppleLanguages", "(en)", "-AppleLocale", "en_US",
            "-ui-testing", "-ui-testing-ipad",
            "--ui-test-cad-fixture",
            // Existing saved mesh-only fixture: the plate fixture's analytic
            // B-rep cannot start Repair/Simplify previews because the shipped
            // panel passes forceMesh only on Apply, not on Preview.
            "--ui-test-cad-face-rotation",
            "--ui-test-cad-face-rotation-reset",
            "--ui-test-cad-mesh-panel-flow",
        ]
        if name.contains("testCleanupInspectionIsVisibleBeforeAndAfterApply") {
            app.launchArguments.removeAll { $0.hasPrefix("--ui-test-cad-face-rotation") || $0 == "--ui-test-cad-mesh-panel-flow" }
            app.launchArguments.append("--ui-test-cad-mesh-integrity")
        }
        app.launch()
    }

    override func tearDownWithError() throws {
        app.terminate()
        app = nil
    }

    // MARK: - Tests

    func testCleanupInspectionIsVisibleBeforeAndAfterApply() throws {
        guard openMeshPanel() else { return }
        let repair = app.buttons["Repair"].firstMatch
        guard reveal(repair, defaultDirection: .towardBottom) else { fail("Repair must be reachable"); return }
        repair.tap()
        guard waitForPendingPreview(titled: "Repair", timeout: 20) else { return }
        let previewWarning = app.staticTexts["Unresolved mesh issues were found."].firstMatch
        guard require(previewWarning.exists, "Preview must disclose the remaining defects"),
              reveal(pendingApplyButton, defaultDirection: .towardBottom) else { return }
        snapshot("Mesh inspection — preview keeps unresolved defects visible")
        pendingApplyButton.tap()
        let warning = app.descendants(matching: .any).matching(identifier: "CADMeshIntegrityWarning").firstMatch
        guard require(warning.waitForExistence(timeout: 20), "Cleanup must not claim a complete repair"),
              reveal(warning, defaultDirection: .towardBottom) else { return }
        let details = app.buttons["Inspection details"].firstMatch
        guard reveal(details, defaultDirection: .towardBottom) else { fail("Inspection details must be reachable"); return }
        details.tap()
        XCTAssertTrue(app.descendants(matching: .any).matching(NSPredicate(
            format: "label CONTAINS %@", "Self-intersections")).firstMatch.exists)
        snapshot("Mesh inspection — applied cleanup shows actual remaining issues")
    }

    func testCancelDuringRepairPublishesNoLatePreviewOrOutcome() throws {
        guard openMeshPanel(), let started = startHeavyPreview("Repair") else { return }
        guard tapBusyCancel() else { return }
        guard ensureMeshBodySelected(), assertPanelUsableAfterCancel() else { return }

        // The real held worker returns after the bounded scheduling hold. Its
        // cancelled reply, or any preview from a would-be late continuation,
        // must be discarded by the owner-task identity + Task.isCancelled
        // fence.
        guard assertNoLatePublication(until: started.addingTimeInterval(latePublicationDeadline)) else {
            return
        }
        snapshot("Mesh Cancel - no late preview or outcome")
    }

    func testHideAndReopenDuringOperationReturnsUsablePanel() throws {
        guard openMeshPanel(), let started = startHeavyPreview("Repair") else { return }
        guard hidePanelDuringOperation(), reopenPanelAfterOperation() else { return }

        // The hide runs the real CADMeshPanelView.onDisappear while its
        // operation-owned task is joined to the still-held real worker. The
        // returned panel must not show the R1 permanent spinner/disabled
        // actions, and it must not accept the old run's late result. The
        // shipped mode switch is used when it is reachable without leaving the
        // current viewport; otherwise the real sheet close/reopen path is used
        // (the retained-@State mode-switch case needs a different host).
        guard ensureMeshBodySelected(), assertPanelUsableAfterCancel() else { return }
        guard startHeavyPreview("Simplify") != nil else { return }
        guard waitForPendingPreview(titled: "Simplify", timeout: 15) else { return }
        guard assertNoLatePublication(until: started.addingTimeInterval(latePublicationDeadline),
                                      keepingPending: "Simplify") else {
            return
        }
        snapshot("Mesh panel hide/reopen - new real preview remains usable")
    }

    func testNewOperationIsNotOverwrittenByCancelledPreview() throws {
        guard openMeshPanel(), let started = startHeavyPreview("Repair") else { return }
        guard tapBusyCancel() else { return }
        guard ensureMeshBodySelected(), assertPanelUsableAfterCancel() else { return }
        guard startHeavyPreview("Simplify") != nil else { return }
        guard waitForPendingPreview(titled: "Simplify", timeout: 15) else { return }

        // The cancelled Repair task is still awaiting its held worker. When it
        // finally returns it must not publish its cancelled outcome into the
        // panel or replace the newer Simplify preview.
        guard assertNoLatePublication(until: started.addingTimeInterval(latePublicationDeadline),
                                      keepingPending: "Simplify") else {
            return
        }
        snapshot("Mesh current-operation fence - older cancellation discarded")
    }

    // MARK: - Real panel navigation

    private func openMeshPanel() -> Bool {
        guard waitFor(app.otherElements["CADFixtureHarness"],
                      "the real CAD fixture must launch", timeout: 60) else { return false }
        guard openToolsSheet() else { return false }
        guard tapMode("Mesh") else { return false }
        guard waitFor(meshBodyRow(), "the mesh-only fixture body must appear",
                      timeout: 30) else { return false }
        return ensureMeshBodySelected()
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

    /// The shipped panel hide path. The mode picker is used when it is still
    /// hittable during the operation (the same CADMeshPanelView instance is
    /// removed); otherwise the real sheet Close control is used. Both run the
    /// same onDisappear fence and are ordinary user actions.
    private func hidePanelDuringOperation() -> Bool {
        let assembly = app.buttons["Assembly"].firstMatch
        if assembly.exists && assembly.isHittable {
            note("Mesh panel hide path: in-sheet mode switch to Assembly")
            guard tapMode("Assembly") else { return false }
            guard waitUntilGone(meshBodyRow(), timeout: 10) else {
                fail("switching to Assembly must hide the Mesh panel")
                return false
            }
            return true
        }
        note("Mesh panel hide path: close/reopen the CAD Tools sheet")
        return closeToolsSheet()
    }

    private func reopenPanelAfterOperation() -> Bool {
        if app.otherElements["CADWorkbenchToolsPanel"].exists {
            let mesh = app.buttons["Mesh"].firstMatch
            if mesh.exists && mesh.isHittable {
                guard tapMode("Mesh") else { return false }
            } else {
                // Do not drag a long panel to the top just to reach the mode
                // picker: the fixed sheet Close control is the safe return.
                guard closeToolsSheet(), openToolsSheet() else { return false }
                guard tapMode("Mesh") else { return false }
            }
        } else {
            guard openToolsSheet() else { return false }
            guard tapMode("Mesh") else { return false }
        }
        return waitFor(meshBodyRow(), "the Mesh panel must return after being hidden",
                       timeout: 20)
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

    // MARK: - Real body and operation controls

    private func meshBodyRow() -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@",
                                          "CADMeshBody-")).firstMatch
    }

    private func ensureMeshBodySelected() -> Bool {
        if app.staticTexts["1 bodies selected"].exists { return true }
        let row = meshBodyRow()
        guard reveal(row, defaultDirection: .towardTop) else {
            fail("the real fixture body row must be reachable in the Mesh panel")
            return false
        }
        // Reveal the top of the panel before reading the selection badge, so a
        // retained selection is not toggled off by a blind row tap.
        if app.staticTexts["1 bodies selected"].exists { return true }
        row.tap()
        return waitFor(app.staticTexts["1 bodies selected"],
                       "the Mesh panel must report the actual selected body", timeout: 5)
    }

    /// Tap a shipped heavy-action control and wait for its real busy state.
    /// Returns the tap time so a later assertion can wait past the bounded
    /// scheduling hold.
    private func startHeavyPreview(_ title: String) -> Date? {
        let button = app.buttons[title].firstMatch
        guard reveal(button, defaultDirection: .towardBottom) else {
            fail("the shipped \(title) action must be reachable in the Mesh panel")
            return nil
        }
        guard require(button.isEnabled,
                      "the shipped \(title) action must be enabled for the selected mesh body")
        else { return nil }
        let started = Date()
        button.tap()
        guard waitUntilDisabled(button, timeout: 8) else {
            let why = panelOutcome.exists
                ? "the panel showed: \(panelOutcome.label)"
                : "the action never entered its real busy state"
            fail("tapping \(title) must start the real operation; \(why)")
            return nil
        }
        // Let the real detached worker enter the installed scheduling probe
        // before the user interaction. This is a scheduling wait, not compute
        // time or a performance measurement.
        RunLoop.current.run(until: Date().addingTimeInterval(0.5))
        return started
    }

    private func tapBusyCancel() -> Bool {
        let cancel = app.buttons["CADMeshCancelOperation"].firstMatch
        // The busy control lives at the bottom of the real panel; reveal may
        // need to scroll it into existence as well as into the viewport.
        guard reveal(cancel, defaultDirection: .towardBottom, attempts: 12) else {
            fail("the busy Cancel control must exist and be reachable")
            return false
        }
        cancel.tap()
        guard waitUntilGone(cancel, timeout: 10) else {
            fail("Cancel must drop the panel's busy state immediately")
            return false
        }
        return true
    }

    private func assertPanelUsableAfterCancel() -> Bool {
        guard waitUntilGone(app.buttons["CADMeshCancelOperation"].firstMatch, timeout: 5) else {
            fail("the busy Cancel control must be gone after the operation stops")
            return false
        }
        guard require(!pendingIsPresent(),
                      "a cancelled/disappeared operation must not leave a pending preview")
        else { return false }
        guard require(!panelOutcome.exists,
                      "a cancelled/disappeared operation must not publish an outcome")
        else { return false }

        let repair = app.buttons["Repair"].firstMatch
        let simplify = app.buttons["Simplify"].firstMatch
        guard reveal(repair, defaultDirection: .towardTop) else {
            fail("Repair must be reachable after the panel returns")
            return false
        }
        guard require(repair.isEnabled, "Repair must be enabled after the panel returns")
        else { return false }
        guard require(simplify.exists && simplify.isEnabled,
                      "Simplify must be enabled after the panel returns") else {
            return false
        }
        return true
    }

    // MARK: - Preview / outcome assertions

    /// The real panel container. `WorkbenchPanelChrome` applies this identifier
    /// to the shipped panel scroll view (the same pattern the assembly test
    /// uses for `CADAssemblyPanel`).
    private var meshPanel: XCUIElement {
        app.descendants(matching: .any)["CADMeshPanel"].firstMatch
    }

    private var pendingSection: XCUIElement {
        if meshPanel.exists {
            return meshPanel.descendants(matching: .any)["CADMeshPending"].firstMatch
        }
        return app.descendants(matching: .any)["CADMeshPending"].firstMatch
    }

    /// The pending section's real Apply action, scoped to the Mesh panel so an
    /// unrelated underlying editor "Apply" can never satisfy the marker.
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
        fail("the real \(title) preview must appear after the held worker returns; \(seen)")
        return false
    }

    /// The pending `PanelSection` carries an accessibility identifier on a
    /// container. Depending on how SwiftUI merges that subtree, the title is
    /// either a child static text or part of the container label; accept the
    /// real rendered title in either shape, never a source string. This is
    /// scoped to the pending section so the adjacent Simplify *button* cannot
    /// satisfy the check.
    private func pendingSectionHasTitle(_ title: String) -> Bool {
        let section = pendingSection
        if section.exists {
            if section.staticTexts[title].exists { return true }
            if section.label.contains(title) { return true }
            // The identified pending section is authoritative: a different
            // real title is a failed overwrite, not a reason to fall back.
            return false
        }
        // Fallback for hosts that keep the identified container's children
        // flat: the real pending Apply control plus the rendered section
        // title, both scoped to the Mesh panel.
        guard meshPanel.exists, pendingApplyButton.exists else { return false }
        return meshPanel.staticTexts[title].exists
    }

    /// Fail as soon as the cancelled operation publishes anything. When
    /// `keepingPending` is set, the newer preview must remain the visible one
    /// until the older held worker has returned.
    private func assertNoLatePublication(until deadline: Date,
                                         keepingPending expected: String? = nil) -> Bool {
        while Date() < deadline {
            if pendingIsPresent() {
                if let expected {
                    guard require(pendingSectionHasTitle(expected),
                                  "the newer \(expected) preview must survive the older cancellation")
                    else { return false }
                } else {
                    fail("a cancelled operation published a late pending preview")
                    return false
                }
            }
            if panelOutcome.exists || app.descendants(matching: .any).matching(identifier: "CADMeshIntegrityWarning").firstMatch.exists {
                let message = panelOutcome.exists ? panelOutcome.label : "remaining mesh issues warning"
                fail("a cancelled operation published a late outcome: \(message)")
                return false
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.25))
        }
        return true
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
        if element.exists && element.isHittable { return true }
        for _ in 0..<attempts {
            let direction = scrollDirection(for: element, fallback: defaultDirection)
            swipeSheet(direction)
            RunLoop.current.run(until: Date().addingTimeInterval(0.25))
            if element.exists && element.isHittable { return true }
        }
        return element.exists && element.isHittable
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

    private func waitUntilDisabled(_ element: XCUIElement, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if element.exists && !element.isEnabled { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        }
        return element.exists && !element.isEnabled
    }

    @discardableResult
    private func require(_ condition: Bool, _ message: String) -> Bool {
        if condition { return true }
        fail(message)
        return false
    }

    private func fail(_ message: String) {
        let hierarchy = XCTAttachment(string: app.debugDescription)
        hierarchy.name = "Mesh panel flow failure hierarchy"
        hierarchy.lifetime = .keepAlways
        add(hierarchy)
        let screenshot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        screenshot.name = "Mesh panel flow failure"
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

    private func note(_ text: String) {
        let attachment = XCTAttachment(string: text)
        attachment.name = "Mesh panel hide path"
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
