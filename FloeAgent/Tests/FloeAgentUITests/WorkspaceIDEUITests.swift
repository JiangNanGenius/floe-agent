// SPDX-License-Identifier: MPL-2.0
import XCTest
import UIKit

@MainActor
final class WorkspaceIDEUITests: XCTestCase {
    func testNativeWorkbenchSaveAndColdReopen() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        let ipad = ProcessInfo.processInfo.environment["SIMULATOR_MODEL_IDENTIFIER"]?.hasPrefix("iPad") == true || UIDevice.current.userInterfaceIdiom == .pad
        app.launchArguments = ["-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN", "-ui-testing", "--ui-test-skip-onboarding", "--ui-test-batch-fixture", "--ui-test-ide-fixture"]
        if ipad { app.launchArguments.append("-ui-testing-ipad") }
        XCUIDevice.shared.orientation = ipad ? .landscapeLeft : .portrait
        app.launch()
        defer { app.terminate() }
        try openWorkbench(app, ipad: ipad)
        let editor = app.webViews.textViews.firstMatch
        XCTAssertTrue(editor.waitForExistence(timeout: 20))
        editor.tap()
        // Monaco only accepts text once its hidden textarea owns the keyboard;
        // a tap that lands before the WebKit focus handshake types into the void.
        let keyboard = app.keyboards.firstMatch
        if !keyboard.waitForExistence(timeout: 5) {
            editor.tap()
            _ = keyboard.waitForExistence(timeout: 5)
        }
        let marker = "saved-" + UUID().uuidString.prefix(8)
        editor.typeText(String(marker))
        // Synthetic keystrokes can silently miss WKWebView text input. Prove the
        // marker reached the Monaco buffer before saving; retry the focus once.
        if !((editor.value as? String) ?? "").contains(marker) {
            editor.tap()
            _ = keyboard.waitForExistence(timeout: 5)
            editor.typeText(String(marker))
        }
        XCTAssertTrue(((editor.value as? String) ?? "").contains(marker), "typed marker must reach the Monaco buffer")
        let save = app.buttons["workspace.ide.save"]
        XCTAssertTrue(save.isEnabled)
        save.tap()
        wait(for: [expectation(for: NSPredicate(format: "enabled == true"), evaluatedWith: save)], timeout: 20)
        capture("ide-native-text-saved")
        app.buttons["workspace.ide.close"].tap()
        XCTAssertTrue(app.buttons["file.preview.openIDE"].waitForExistence(timeout: 10))

        // A cold App + new nonpersistent WebKit session must read from disk.
        app.terminate()
        app.launch()
        try openWorkbench(app, ipad: ipad, expectedSavedText: String(marker))
        let reopened = app.webViews.textViews.firstMatch
        XCTAssertTrue(reopened.waitForExistence(timeout: 20))
        XCTAssertTrue(app.buttons["workspace.ide.richEditor"].isEnabled)
        XCTAssertTrue(app.buttons["workspace.ide.terminal"].isEnabled)
        capture("ide-native-cold-reopen")
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

    private func openWorkbench(_ app: XCUIApplication, ipad: Bool, expectedSavedText: String? = nil) throws {
        try openFile(app, ipad: ipad, name: "IDE验收.txt")
        if let expectedSavedText {
            // Read through Floe's independent native preview after a cold
            // launch; Monaco's textarea exposes only its current input range.
            let savedText = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", expectedSavedText)).firstMatch
            XCTAssertTrue(savedText.waitForExistence(timeout: 10))
            capture("ide-native-disk-readback")
        }
        let expand = app.buttons["file.preview.openIDE"]
        XCTAssertTrue(expand.waitForExistence(timeout: 10)); expand.tap()
        let save = app.buttons["workspace.ide.save"]
        XCTAssertTrue(save.waitForExistence(timeout: 20))
        wait(for: [expectation(for: NSPredicate(format: "enabled == true"), evaluatedWith: save)], timeout: 45)
        XCTAssertTrue(app.webViews.firstMatch.exists)
        capture("ide-native-workbench")
    }

    private func capture(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
