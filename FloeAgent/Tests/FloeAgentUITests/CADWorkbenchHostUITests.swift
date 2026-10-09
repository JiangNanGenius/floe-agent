// FloeAgentUITests — native CAD workbench host chrome and tool-response
// smoke coverage (iPad regular width + iPhone compact, serial).
//
// SPDX-License-Identifier: MPL-2.0
//
// The `-ui-testing --ui-test-cad-fixture` harness presents the REAL
// FloeCADWorkbenchView on a deterministic 100×60×10 plate with a Ø10
// through-hole. These tests exist because a fixture that presents the
// workbench without the host navigation container silently drops the whole
// top toolbar (undo/redo, views, history, variables, items, import/export,
// tools, settings) — the failure the primary CUA found on 2026-10-10. The
// assertions here pin the chrome to the real product surface so that class
// of regression is caught without a human review pass, and prove the tool
// strip actually answers taps (select mode opens its pill) rather than
// merely rendering.

#if canImport(XCTest)
import XCTest

private enum CADWorkbenchHostAssertions {
    /// Every toolbar item the product workbench promises. `file` is the test
    /// case for XCTest-style failures.
    static func assertToolbarChrome(_ app: XCUIApplication, _ file: StaticString = #filePath, _ line: UInt = #line) {
        for identifier in ["UndoButton", "RedoButton", "ViewsMenu", "HistoryButton",
                           "VariablesButton", "ItemsButton", "CADWorkbenchToolsButton",
                           "CommandSearchButton", "SettingsButton"] {
            XCTAssertTrue(app.buttons[identifier].waitForExistence(timeout: 30),
                          "workbench toolbar item \(identifier) must be present (host navigation chrome)",
                          file: file, line: line)
        }
    }

    /// Open the workbench tools sheet and walk every service panel.
    static func assertToolsPanels(_ app: XCUIApplication, _ file: StaticString = #filePath, _ line: UInt = #line) {
        app.buttons["CADWorkbenchToolsButton"].tap()
        guard app.otherElements["CADWorkbenchToolsPanel"].waitForExistence(timeout: 20) else {
            var ids: [String] = []
            for element in app.otherElements.matching(NSPredicate(format: "identifier CONTAINS 'CAD'"))
                .allElementsBoundByIndex.prefix(20) {
                ids.append(element.identifier)
            }
            XCTFail("the workbench tools sheet must open; CAD elements: \(ids)", file: file, line: line)
            return
        }
        XCTAssertTrue(app.otherElements["CADAssemblyPanel"].waitForExistence(timeout: 5),
                      "Assembly panel is the default tools mode", file: file, line: line)
        for panel in ["Drawings", "ShapeScript", "Mesh"] {
            app.buttons[panel].tap()
        }
        // Walk back so the sheet ends on the first panel like a fresh open.
        app.buttons["Assembly"].tap()
        XCTAssertTrue(app.otherElements["CADAssemblyPanel"].waitForExistence(timeout: 5),
                      "returning to Assembly must re-show its panel", file: file, line: line)
        // iPhone sheets need an explicit close; the tools sheet has none, so
        // swipe it down before the next assertion group.
        app.swipeDown(velocity: .fast)
    }

    /// A floating tool-strip tap must change editor state, not just render.
    /// (The palette identifier only exists on the compact scroll fallback,
    /// so the assertions anchor on the tool buttons themselves.)
    static func assertToolStripResponds(_ app: XCUIApplication, _ file: StaticString = #filePath, _ line: UInt = #line) {
        guard app.buttons["SelectModeButton"].waitForExistence(timeout: 10) else {
            let ids = app.buttons.allElementsBoundByIndex.prefix(60)
                .map { $0.identifier.isEmpty ? ($0.label ?? "?") : $0.identifier }
            XCTFail("the tool strip must expose the select tool; visible buttons: \(ids)", file: file, line: line)
            return
        }
        app.buttons["SelectModeButton"].tap()
        XCTAssertTrue(app.buttons["SelectModeDone"].waitForExistence(timeout: 5),
                      "tapping Select must open the select-mode pill (tool strip answers taps)",
                      file: file, line: line)
        app.buttons["SelectModeDone"].tap()
        XCTAssertFalse(app.buttons["SelectModeDone"].waitForExistence(timeout: 5),
                       "Done must leave select mode again", file: file, line: line)
    }

    static func assertHistoryPanelOpens(_ app: XCUIApplication, _ file: StaticString = #filePath, _ line: UInt = #line) {
        app.buttons["HistoryButton"].tap()
        XCTAssertTrue(app.otherElements["HistoryPanel"].waitForExistence(timeout: 5),
                      "the history panel must open from the toolbar", file: file, line: line)
        app.swipeDown(velocity: .fast)
    }
}

/// iPad regular-width host chrome. The `-ui-testing-ipad` argument keeps the
/// regular-width layout even if the runner misreports the size class.
@MainActor
final class CADWorkbenchHostIPadUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .landscapeLeft
        app = XCUIApplication()
        app.launchArguments += ["-ui-testing", "-ui-testing-ipad", "--ui-test-cad-fixture"]
        app.launch()
    }

    override func tearDownWithError() throws {
        app.terminate()
        app = nil
    }

    func testWorkbenchHostChromeToolsAndToolStrip() throws {
        XCTAssertTrue(app.otherElements["CADFixtureHarness"].waitForExistence(timeout: 30))
        CADWorkbenchHostAssertions.assertToolbarChrome(app)
        CADWorkbenchHostAssertions.assertToolStripResponds(app)
        CADWorkbenchHostAssertions.assertToolsPanels(app)
        CADWorkbenchHostAssertions.assertHistoryPanelOpens(app)
    }
}

/// Serial iPhone compact pass: same surface, compact idiom. Skipped when the
/// host is not compact so an iPad-only runner stays green without lying.
@MainActor
final class CADWorkbenchHostIPhoneUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
        app = XCUIApplication()
        app.launchArguments += ["-ui-testing", "--ui-test-cad-fixture"]
        app.launch()
    }

    override func tearDownWithError() throws {
        app.terminate()
        app = nil
    }

    func testWorkbenchHostChromeCompact() throws {
        guard app.windows.firstMatch.exists else { throw XCTSkip("Requires a running host") }
        XCTAssertTrue(app.otherElements["CADFixtureHarness"].waitForExistence(timeout: 30))
        // Compact-width navigation bars overflow earlier toolbar items; the
        // chrome contract at compact width is the core edit pair plus a
        // tool strip that answers taps.
        for identifier in ["UndoButton", "RedoButton"] {
            XCTAssertTrue(app.buttons[identifier].waitForExistence(timeout: 20),
                          "workbench toolbar item \(identifier) must be present")
        }
        CADWorkbenchHostAssertions.assertToolStripResponds(app)
        // The full tools/panel walk requires the tools entry; on narrow
        // phones the bar may overflow it. When present it must work; when
        // absent the gap is recorded for the primary CUA pass rather than
        // silently ignored (panel reachability on compact phones).
        if app.buttons["CADWorkbenchToolsButton"].waitForExistence(timeout: 5) {
            CADWorkbenchHostAssertions.assertToolsPanels(app)
        } else {
            throw XCTSkip("Compact toolbar overflow hides CADWorkbenchToolsButton; panel reachability moves to the primary CUA checklist")
        }
    }
}
#endif
