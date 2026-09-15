// SPDX-License-Identifier: MPL-2.0
import XCTest
import UIKit

@MainActor
final class WorkspaceIDEUITests: XCTestCase {
    func testNativeWorkbenchSaveAndColdReopen() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        let ipad = ProcessInfo.processInfo.environment["SIMULATOR_MODEL_IDENTIFIER"]?.hasPrefix("iPad") == true || UIDevice.current.userInterfaceIdiom == .pad
        app.launchArguments = ["-ui-testing", "--ui-test-skip-onboarding", "--ui-test-batch-fixture", "--ui-test-ide-fixture"]
        if ipad { app.launchArguments.append("-ui-testing-ipad") }
        XCUIDevice.shared.orientation = ipad ? .landscapeLeft : .portrait
        app.launch()
        defer { app.terminate() }
        try openWorkbench(app, ipad: ipad)
        let editor = app.webViews.textViews.firstMatch
        XCTAssertTrue(editor.waitForExistence(timeout: 20))
        editor.tap()
        let marker = "saved-" + UUID().uuidString.prefix(8)
        editor.typeText(String(marker))
        let save = app.buttons["workspace.ide.save"]
        XCTAssertTrue(save.isEnabled)
        save.tap()
        wait(for: [expectation(for: NSPredicate(format: "enabled == true"), evaluatedWith: save)], timeout: 20)
        capture("ide-native-text-saved")
        app.buttons["workspace.ide.close"].tap()
        XCTAssertTrue(app.buttons["workspace.openIDE"].waitForExistence(timeout: 10))

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
        XCTAssertTrue(app.buttons["workspace.openIDE"].waitForExistence(timeout: 10))
    }

    private func openWorkbench(_ app: XCUIApplication, ipad: Bool, expectedSavedText: String? = nil) throws {
        if !ipad {
            let sidebar = app.buttons["phone.sidebar.open"]
            XCTAssertTrue(sidebar.waitForExistence(timeout: 15)); sidebar.tap()
        }
        let settings = app.buttons["sidebar.settings"]
        XCTAssertTrue(settings.waitForExistence(timeout: 15)); settings.tap()
        let files = app.descendants(matching: .any).matching(identifier: "settings.section.files").firstMatch
        XCTAssertTrue(files.waitForExistence(timeout: 10)); files.tap()
        let manage = app.buttons["settings.files.manage"]
        XCTAssertTrue(manage.waitForExistence(timeout: 10)); manage.tap()
        let workspace = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "聊天工作区")).firstMatch
        XCTAssertTrue(workspace.waitForExistence(timeout: 10)); workspace.tap()
        let file = app.staticTexts["IDE验收.txt"].firstMatch
        XCTAssertTrue(file.waitForExistence(timeout: 10)); file.tap()
        if let expectedSavedText {
            // Read through Floe's independent native preview after a cold
            // launch; Monaco's textarea exposes only its current input range.
            let savedText = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", expectedSavedText)).firstMatch
            XCTAssertTrue(savedText.waitForExistence(timeout: 10))
            capture("ide-native-disk-readback")
        }
        let expand = app.buttons["workspace.openIDE"]
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
