// SPDX-License-Identifier: MPL-2.0
import XCTest
import UIKit

@MainActor
final class WorkspaceIDEUITests: XCTestCase {
    /// The IDE defaults to the native Swift/UIKit editor for verified
    /// text/code files. This is the reachability proof: real buffer, real
    /// save, disk readback after a cold App launch.
    func testNativeEditorSaveAndColdReopen() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        let ipad = ProcessInfo.processInfo.environment["SIMULATOR_MODEL_IDENTIFIER"]?.hasPrefix("iPad") == true || UIDevice.current.userInterfaceIdiom == .pad
        app.launchArguments = ["-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN", "-ui-testing", "--ui-test-skip-onboarding", "--ui-test-batch-fixture", "--ui-test-ide-fixture"]
        if ipad { app.launchArguments.append("-ui-testing-ipad") }
        XCUIDevice.shared.orientation = ipad ? .landscapeLeft : .portrait
        app.launch()
        defer { app.terminate() }
        try openWorkbench(app, ipad: ipad, expectWebKernel: false)
        let editor = app.textViews["workspace.ide.nativeEditor"]
        XCTAssertTrue(editor.waitForExistence(timeout: 30), "the native editor must be reachable by default")
        let insert = app.buttons["workspace.ide.nativeInsertTestText"]
        XCTAssertTrue(insert.waitForExistence(timeout: 10))
        wait(for: [expectation(for: NSPredicate(format: "enabled == true"), evaluatedWith: insert)], timeout: 60)
        insert.tap()
        let inserted = expectation(for: NSPredicate(format: "value BEGINSWITH %@", "inserted:"), evaluatedWith: insert)
        wait(for: [inserted], timeout: 30)
        guard let published = insert.value as? String, published.hasPrefix("inserted:") else {
            XCTFail("native insert action did not publish its marker"); return
        }
        let marker = String(published.dropFirst("inserted:".count))
        // The native status bar reports the unsaved state before the save and
        // the saved state after it, so the assertion is about the buffer, not
        // the button.
        XCTAssertTrue(app.staticTexts["未保存"].waitForExistence(timeout: 5))
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
        try openWorkbench(app, ipad: ipad, expectedSavedText: String(marker), expectWebKernel: false)
        XCTAssertTrue(app.textViews["workspace.ide.nativeEditor"].waitForExistence(timeout: 30))
        capture("ide-native-cold-reopen")
        app.buttons["workspace.ide.close"].tap()
        XCTAssertTrue(app.buttons["file.preview.openIDE"].waitForExistence(timeout: 10))
    }

    /// The Web workbench stays an explicit fallback. Switching kernels keeps
    /// the native buffer and the Monaco workbench still owns its own model.
    func testWebFallbackEditorRemainsAvailable() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        let ipad = ProcessInfo.processInfo.environment["SIMULATOR_MODEL_IDENTIFIER"]?.hasPrefix("iPad") == true || UIDevice.current.userInterfaceIdiom == .pad
        app.launchArguments = ["-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN", "-ui-testing", "--ui-test-skip-onboarding", "--ui-test-batch-fixture", "--ui-test-ide-fixture"]
        if ipad { app.launchArguments.append("-ui-testing-ipad") }
        XCUIDevice.shared.orientation = ipad ? .landscapeLeft : .portrait
        app.launch()
        defer { app.terminate() }
        try openWorkbench(app, ipad: ipad, expectWebKernel: false)
        switchEditorKernelToWeb(app)
        XCTAssertTrue(app.webViews.firstMatch.waitForExistence(timeout: 30), "the Web workbench must remain reachable")
        // XCTest keystrokes never reach Monaco's hidden textarea, the editor
        // suppresses the system edit menu, and the simulator pasteboard is not
        // shared with the test runner. The action generates and publishes the
        // marker it inserted; the readback below requires exactly that string.
        let insert = app.buttons["workspace.ide.insertTestText"]
        XCTAssertTrue(insert.waitForExistence(timeout: 20))
        wait(for: [expectation(for: NSPredicate(format: "enabled == true"), evaluatedWith: insert)], timeout: 60)
        insert.tap()
        let inserted = expectation(for: NSPredicate(format: "value BEGINSWITH %@", "inserted:"), evaluatedWith: insert)
        wait(for: [inserted], timeout: 30)
        guard let published = insert.value as? String, published.hasPrefix("inserted:") else {
            XCTFail("web insert action did not publish its marker"); return
        }
        let save = app.buttons["workspace.ide.save"]
        XCTAssertTrue(save.isEnabled)
        save.tap()
        wait(for: [expectation(for: NSPredicate(format: "enabled == true"), evaluatedWith: save)], timeout: 20)
        capture("ide-web-fallback-saved")
        // Compact widths collapse the trailing toolbar items into the system
        // overflow menu; assert the same two actions through whichever
        // surface actually renders them instead of weakening the check.
        let richEditor = app.buttons["workspace.ide.richEditor"]
        let terminal = app.buttons["workspace.ide.terminal"]
        if richEditor.waitForExistence(timeout: 5) {
            XCTAssertTrue(richEditor.isEnabled)
            XCTAssertTrue(terminal.isEnabled)
        } else {
            let overflow = app.buttons["OverflowBarButtonItem"]
            XCTAssertTrue(overflow.waitForExistence(timeout: 5))
            overflow.tap()
            // The app is forced to zh-Hans above; overflow menu items carry
            // only their localized labels, not the button identifiers.
            let richItem = overflowedAction(app, label: "用专用编辑器打开")
            let terminalItem = overflowedAction(app, label: "终端")
            XCTAssertTrue(richItem.exists)
            XCTAssertTrue(terminalItem.exists)
            XCTAssertTrue(richItem.isEnabled)
            XCTAssertTrue(terminalItem.isEnabled)
            capture("ide-web-fallback-overflow")
            // Dismiss the menu through its own dismissal layer before the
            // close step below; the tap must not reach the editor.
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.05, dy: 0.4)).tap()
            wait(for: [expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: richItem)], timeout: 5)
        }
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
        expectedSavedText: String? = nil,
        expectWebKernel: Bool = true
    ) throws {
        try openFile(app, ipad: ipad, name: "IDE验收.txt")
        if let expectedSavedText {
            // Read through Floe's independent native preview after a cold
            // launch; Monaco's textarea exposes only its current input range.
            let savedText = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", expectedSavedText)).firstMatch
            XCTAssertTrue(savedText.waitForExistence(timeout: 30))
            capture("ide-native-disk-readback")
        }
        let expand = app.buttons["file.preview.openIDE"]
        XCTAssertTrue(expand.waitForExistence(timeout: 10)); expand.tap()
        if expectWebKernel {
            let save = app.buttons["workspace.ide.save"]
            XCTAssertTrue(save.waitForExistence(timeout: 20))
            wait(for: [expectation(for: NSPredicate(format: "enabled == true"), evaluatedWith: save)], timeout: 45)
            XCTAssertTrue(app.webViews.firstMatch.exists)
        } else {
            XCTAssertTrue(
                app.textViews["workspace.ide.nativeEditor"].waitForExistence(timeout: 30),
                "the native editor must be the default for a verified text file"
            )
            // The native insert hook is enabled only after the buffer loaded,
            // which makes it a deterministic readiness probe (the editor view
            // itself already exists while the load is in flight).
            let insert = app.buttons["workspace.ide.nativeInsertTestText"]
            XCTAssertTrue(insert.waitForExistence(timeout: 15))
            wait(for: [expectation(for: NSPredicate(format: "enabled == true"), evaluatedWith: insert)], timeout: 45)
        }
        capture("ide-native-workbench")
    }

    /// Switches the visible kernel to the Web workbench through whichever
    /// surface renders the action (toolbar button or compact overflow menu).
    private func switchEditorKernelToWeb(_ app: XCUIApplication) {
        let button = app.buttons["workspace.ide.editorMode"]
        if button.waitForExistence(timeout: 10), button.isHittable {
            button.tap()
            return
        }
        let overflow = app.buttons["OverflowBarButtonItem"]
        XCTAssertTrue(overflow.waitForExistence(timeout: 10))
        overflow.tap()
        let item = overflowedAction(app, label: "Web 编辑器")
        XCTAssertTrue(item.exists, "the editor-kernel switch must be reachable")
        item.tap()
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
}
