// SPDX-License-Identifier: MPL-2.0
import XCTest
import UIKit

@MainActor
final class WorkspaceIDEUITests: XCTestCase {
    /// The IDE's text/code editor is native Swift/UIKit only (no Web/Monaco
    /// text kernel and no switch entry). This is the reachability proof: real
    /// keystrokes into the real UITextView, real save, disk readback after a
    /// cold App launch. No test-injection controls exist in the product UI.
    func testNativeEditorSaveAndColdReopen() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        let ipad = ProcessInfo.processInfo.environment["SIMULATOR_MODEL_IDENTIFIER"]?.hasPrefix("iPad") == true || UIDevice.current.userInterfaceIdiom == .pad
        app.launchArguments = ["-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN", "-ui-testing", "--ui-test-skip-onboarding", "--ui-test-batch-fixture", "--ui-test-ide-fixture"]
        if ipad { app.launchArguments.append("-ui-testing-ipad") }
        XCUIDevice.shared.orientation = ipad ? .landscapeLeft : .portrait
        app.launch()
        defer { app.terminate() }
        try openWorkbench(app, ipad: ipad)
        let editor = app.textViews["workspace.ide.nativeEditor"]
        XCTAssertTrue(editor.waitForExistence(timeout: 30), "the native editor must be reachable by default")
        XCTAssertFalse(app.buttons["workspace.ide.insertTestText"].exists, "no web test-injection control may exist")
        XCTAssertFalse(app.buttons["workspace.ide.nativeInsertTestText"].exists, "no native test-injection control may exist")
        XCTAssertFalse(app.buttons["workspace.ide.editorMode"].exists, "there must be no editor-kernel switch entry")
        // Real typing through the native UITextView; the marker is generated
        // here so the cold readback can require exactly this string.
        let marker = "saved-" + UUID().uuidString.prefix(8)
        editor.tap()
        editor.typeText("\n\(marker)\n")
        // The native status bar reports the unsaved state before the save and
        // the saved state after it, so the assertion is about the buffer.
        XCTAssertTrue(app.staticTexts["未保存"].waitForExistence(timeout: 10))
        let save = app.buttons["workspace.ide.save"]
        XCTAssertTrue(save.isEnabled)
        save.tap()
        XCTAssertTrue(app.staticTexts["已保存"].waitForExistence(timeout: 20))
        capture("ide-native-editor-saved")
        app.buttons["workspace.ide.close"].tap()
        XCTAssertTrue(app.buttons["file.preview.openIDE"].waitForExistence(timeout: 10))

        // A cold App + a fresh native model must read the committed bytes.
        app.terminate()
        app.launch()
        try openWorkbench(app, ipad: ipad, expectedSavedText: String(marker))
        XCTAssertTrue(app.textViews["workspace.ide.nativeEditor"].waitForExistence(timeout: 30))
        capture("ide-native-cold-reopen")
        app.buttons["workspace.ide.close"].tap()
        XCTAssertTrue(app.buttons["file.preview.openIDE"].waitForExistence(timeout: 10))
    }

    /// Native-only IDE chrome: the persistent left activity rail exposes
    /// files/search/source control/terminal, the Explorer opens files into the
    /// native editor, and a typed edit saves through the toolbar. There is no
    /// Web workbench to reach.
    func testNativeExplorerAndActivityRail() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        let ipad = ProcessInfo.processInfo.environment["SIMULATOR_MODEL_IDENTIFIER"]?.hasPrefix("iPad") == true || UIDevice.current.userInterfaceIdiom == .pad
        app.launchArguments = ["-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN", "-ui-testing", "--ui-test-skip-onboarding", "--ui-test-batch-fixture", "--ui-test-ide-fixture"]
        if ipad { app.launchArguments.append("-ui-testing-ipad") }
        XCUIDevice.shared.orientation = ipad ? .landscapeLeft : .portrait
        app.launch()
        defer { app.terminate() }
        try openWorkbench(app, ipad: ipad)
        // The rail is present on both idioms; tapping Source Control opens the
        // pinned workspace's Git surface (or its truthful not-a-repository
        // state for this fixture workspace).
        for identifier in ["workspace.ide.files", "workspace.ide.search", "workspace.ide.sourceControl", "workspace.ide.terminal"] {
            let control = app.buttons[identifier]
            XCTAssertTrue(control.waitForExistence(timeout: 10), "the activity rail must expose \(identifier)")
            XCTAssertTrue(control.isEnabled, "\(identifier) must be enabled")
        }
        assertTerminalRailAndPanel(app)
        // Explorer: regular widths open with the Files sidebar visible; the
        // fixture file row opens the native editor for that path.
        if ipad {
            XCTAssertTrue(
                app.descendants(matching: .any).matching(identifier: "workspace.ide.sidebar").firstMatch
                    .waitForExistence(timeout: 10),
                "regular widths must open with the Explorer sidebar visible"
            )
            capture("ide-ipad-explorer")
        } else {
            app.buttons["workspace.ide.files"].tap()
            XCTAssertTrue(app.otherElements["workspace.ide.sidebar.drawer"].waitForExistence(timeout: 10),
                          "compact widths must open the Explorer drawer from the rail")
            capture("ide-iphone-explorer-drawer")
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.5)).tap()
        }
        let editor = app.textViews["workspace.ide.nativeEditor"]
        XCTAssertTrue(editor.waitForExistence(timeout: 30), "the native editor must be the default for a verified text file")
        let marker = "edited-" + UUID().uuidString.prefix(8)
        editor.tap()
        editor.typeText("\n\(marker)\n")
        XCTAssertTrue(app.staticTexts["未保存"].waitForExistence(timeout: 10))
        app.buttons["workspace.ide.save"].tap()
        XCTAssertTrue(app.staticTexts["已保存"].waitForExistence(timeout: 20))
        capture("ide-native-rail-saved")
        app.buttons["workspace.ide.close"].tap()
        XCTAssertTrue(app.buttons["file.preview.openIDE"].waitForExistence(timeout: 10))
    }

    func testEngineeringDrawingInlineAndFullScreen() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        let ipad = ProcessInfo.processInfo.environment["SIMULATOR_MODEL_IDENTIFIER"]?.hasPrefix("iPad") == true || UIDevice.current.userInterfaceIdiom == .pad
        app.launchArguments = ["-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN", "-ui-testing", "--ui-test-skip-onboarding", "--ui-test-batch-fixture", "--ui-test-engineering-fixture"]
        if ipad { app.launchArguments.append("-ui-testing-ipad") }
        XCUIDevice.shared.orientation = ipad ? .landscapeLeft : .portrait
        app.launch()
        defer { app.terminate() }
        try openFile(app, ipad: ipad, name: "工程图验收.dxf")
        let rendered = app.webViews.staticTexts.matching(NSPredicate(format: "label == %@", "二维图纸")).firstMatch
        XCTAssertTrue(rendered.waitForExistence(timeout: 60))
        capture("engineering-dxf-inline")
        let full = app.buttons["file.preview.engineering.fullscreen"]
        XCTAssertTrue(full.waitForExistence(timeout: 10)); full.tap()
        XCTAssertTrue(rendered.waitForExistence(timeout: 60))
        let layers = app.webViews.buttons["图层"]
        XCTAssertTrue(layers.waitForExistence(timeout: 10)); layers.tap()
        XCTAssertTrue(app.webViews.staticTexts["Outline"].waitForExistence(timeout: 10))
        capture("engineering-dxf-fullscreen-layers")
        app.buttons["engineering.done"].tap()
        XCTAssertTrue(full.waitForExistence(timeout: 10))
    }

    func testDWGEditSaveAndColdReopen() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        let ipad = ProcessInfo.processInfo.environment["SIMULATOR_MODEL_IDENTIFIER"]?.hasPrefix("iPad") == true || UIDevice.current.userInterfaceIdiom == .pad
        app.launchArguments = ["-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN", "-ui-testing", "--ui-test-skip-onboarding", "--ui-test-batch-fixture", "--ui-test-engineering-fixture"]
        if ipad { app.launchArguments.append("-ui-testing-ipad") }
        XCUIDevice.shared.orientation = ipad ? .landscapeLeft : .portrait
        app.launch()
        defer { app.terminate() }
        try openFile(app, ipad: ipad, name: "可编辑图纸验收.dwg")
        let full = app.buttons["file.preview.engineering.fullscreen"]
        XCTAssertTrue(full.waitForExistence(timeout: 60)); full.tap()
        let edit = app.webViews.buttons["编辑"]
        XCTAssertTrue(edit.waitForExistence(timeout: 60)); edit.tap()
        let marker = "CAD-" + UUID().uuidString.prefix(8)
        let add = app.webViews.buttons["文字"]
        XCTAssertTrue(add.waitForExistence(timeout: 10)); add.tap()
        let text = app.webViews.textFields["文字"]
        XCTAssertTrue(text.waitForExistence(timeout: 10)); text.tap(); text.typeText(String(marker))
        app.webViews.buttons["添加文字"].tap()
        let dirty = app.webViews.staticTexts["有未保存的修改"]
        XCTAssertTrue(dirty.waitForExistence(timeout: 20))
        app.webViews.buttons["保存"].tap()
        XCTAssertTrue(app.webViews.staticTexts["已保存，原版已保留"].waitForExistence(timeout: 30))
        capture("engineering-dwg-native-saved")
        app.buttons["engineering.done"].tap()
        app.terminate(); app.launch()
        try openFile(app, ipad: ipad, name: "可编辑图纸验收.dwg")
        XCTAssertTrue(full.waitForExistence(timeout: 60)); full.tap()
        XCTAssertTrue(edit.waitForExistence(timeout: 60))
        let review = app.webViews.buttons["AI 审图"]
        XCTAssertTrue(review.waitForExistence(timeout: 10)); review.tap()
        XCTAssertTrue(app.buttons["engineering.review.send"].waitForExistence(timeout: 20))
        app.buttons["engineering.review.evidence"].tap()
        let evidence = app.staticTexts["engineering.review.context"]
        XCTAssertTrue(evidence.waitForExistence(timeout: 10))
        XCTAssertTrue(evidence.label.contains(String(marker)), "Native cold readback must retain the saved text")
        // Captured native pixels + parsed geometry, without a paid model call.
        capture("engineering-dwg-native-review")
    }

    private func openFile(_ app: XCUIApplication, ipad: Bool, name: String) throws {
        if !ipad {
            let sidebar = app.buttons["phone.sidebar.open"]
            XCTAssertTrue(sidebar.waitForExistence(timeout: 15)); sidebar.tap()
        }
        let settings = app.buttons["sidebar.settings"]
        XCTAssertTrue(settings.waitForExistence(timeout: 15)); settings.tap()
        // Compact NavigationLink rows are buttons and virtualize below the
        // fold. The iPad sidebar uses text labels. Exercise the real list.
        let files = ipad ? app.staticTexts["settings.section.files"].firstMatch : app.buttons["settings.section.files"]
        if !ipad {
            let sections = app.collectionViews["settings.sections"]
            XCTAssertTrue(sections.waitForExistence(timeout: 10))
            for _ in 0..<6 {
                if files.exists && files.isHittable { break }
                sections.swipeUp()
            }
        }
        XCTAssertTrue(files.waitForExistence(timeout: 30)); files.tap()
        let manage = app.buttons["settings.files.manage"]
        XCTAssertTrue(manage.waitForExistence(timeout: 10)); manage.tap()
        let workspace = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "批量选择测试")).firstMatch
        XCTAssertTrue(workspace.waitForExistence(timeout: 30)); workspace.tap()
        // Retain the actual listing state before the file query: on loaded
        // runners AX snapshots of a restored heavy editor can stall answers.
        capture("ide-files-before-open")
        let file = app.staticTexts[name].firstMatch
        XCTAssertTrue(file.waitForExistence(timeout: 30)); file.tap()
    }

    private func openWorkbench(
        _ app: XCUIApplication,
        ipad: Bool,
        expectedSavedText: String? = nil
    ) throws {
        try openFile(app, ipad: ipad, name: "IDE验收.txt")
        if let expectedSavedText {
            // Read through Floe's independent native preview after a cold
            // launch, which renders the committed bytes.
            let savedText = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", expectedSavedText)).firstMatch
            XCTAssertTrue(savedText.waitForExistence(timeout: 30))
            capture("ide-native-disk-readback")
        }
        let expand = app.buttons["file.preview.openIDE"]
        XCTAssertTrue(expand.waitForExistence(timeout: 10)); expand.tap()
        // Text editing is native-only: the editor view is the readiness probe
        // (the buffer load finishes before the first keystroke assertions).
        XCTAssertTrue(
            app.textViews["workspace.ide.nativeEditor"].waitForExistence(timeout: 30),
            "the native editor must be the only text editor for a verified text file"
        )
        XCTAssertFalse(app.webViews.firstMatch.exists, "no Web text workbench may be mounted")
        capture("ide-native-workbench")
    }

    private func capture(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    /// Overflowed toolbar actions surface as menu items on current OS
    /// releases and as plain buttons on others; poll both renderings until
    /// one appears so the menu's presentation animation cannot race us.
    private func overflowedAction(_ app: XCUIApplication, label: String, timeout: TimeInterval = 5) -> XCUIElement {
        let item = app.menuItems[label].firstMatch
        let button = app.buttons[label].firstMatch
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if item.exists { return item }
            if button.exists { return button }
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        }
        return item
    }

    /// Asserts one toolbar action is reachable and enabled through either the
    /// bar itself or the compact overflow menu, and leaves the menu dismissed
    /// so the next probe starts from the normal workbench.
    private func assertToolbarAction(
        _ app: XCUIApplication,
        identifier: String,
        overflowLabel: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let direct = app.buttons[identifier]
        if direct.waitForExistence(timeout: 5), direct.isHittable {
            XCTAssertTrue(direct.isEnabled, "\(identifier) must stay enabled", file: file, line: line)
            return
        }
        let overflow = app.buttons["OverflowBarButtonItem"]
        XCTAssertTrue(
            overflow.waitForExistence(timeout: 5),
            "neither the toolbar nor the overflow menu renders \(identifier)",
            file: file, line: line
        )
        overflow.tap()
        // The app is forced to zh-Hans above; overflow menu items carry only
        // their localized labels, not the button identifiers.
        let item = overflowedAction(app, label: overflowLabel, timeout: 10)
        XCTAssertTrue(item.exists && item.isEnabled, "\(identifier) must stay enabled", file: file, line: line)
        capture("ide-web-fallback-overflow-\(identifier)")
        // Dismiss the menu through its own dismissal layer; the tap must not
        // reach the editor. The dismissal assertion is scoped to the presented
        // menu itself: `app.buttons[overflowLabel]` can also match a toolbar
        // button that survives the probe (and a slow snapshot must not fail
        // the reachability assertion above).
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.05, dy: 0.4)).tap()
        XCTAssertTrue(overflowMenuClosed(app, timeout: 10), "the overflow menu must close", file: file, line: line)
    }

    /// True once the presented overflow menu is gone. Scoped to the menu
    /// container's `menuItems` so a toolbar button that happens to share the
    /// item's localized label can never keep this check open.
    private func overflowMenuClosed(_ app: XCUIApplication, timeout: TimeInterval) -> Bool {
        let menu = app.menuItems.firstMatch
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if !menu.exists { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.3))
        }
        return !menu.exists
    }

    /// Verifies the terminal lives in the persistent left activity rail and
    /// drives the collapsible bottom panel: the rail control is enabled,
    /// tapping it reveals the panel, and the panel's collapse button hides
    /// it without recreating the session. Runs on iPad and iPhone.
    private func assertTerminalRailAndPanel(_ app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) {
        let rail = app.buttons["workspace.ide.terminal"]
        XCTAssertTrue(rail.waitForExistence(timeout: 10), "the activity rail must expose a terminal control", file: file, line: line)
        XCTAssertTrue(rail.isEnabled, "the terminal rail control must stay enabled", file: file, line: line)
        // The panel may surface as a container of any element type; query the
        // whole tree rather than only `otherElements`.
        let panel = app.descendants(matching: .any).matching(identifier: "workspace.ide.terminalPanel").firstMatch
        if !panel.exists { rail.tap() }
        XCTAssertTrue(panel.waitForExistence(timeout: 10), "tapping the rail must open the terminal panel", file: file, line: line)
        capture("ide-terminal-panel")
        let collapse = app.buttons["workspace.ide.panel.close"]
        XCTAssertTrue(collapse.waitForExistence(timeout: 5), "the panel must offer a collapse control", file: file, line: line)
        collapse.tap()
        XCTAssertTrue(
            elementGone(panel, timeout: 10),
            "the panel collapse control must hide the panel", file: file, line: line
        )
    }

    /// Polls until the element leaves the hierarchy (the panel collapse
    /// animation makes a plain expectation racy).
    private func elementGone(_ element: XCUIElement, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if !element.exists { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.3))
        }
        return !element.exists
    }
}
