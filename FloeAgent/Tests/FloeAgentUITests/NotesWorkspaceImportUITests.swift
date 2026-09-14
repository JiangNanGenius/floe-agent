// SPDX-License-Identifier: MPL-2.0
import XCTest
import UIKit

@MainActor
final class NotesWorkspaceImportUITests: XCTestCase {
    func testWorkspaceImportTabsFocusAndBodySearch() throws {
        continueAfterFailure = false
        let ipad = UIDevice.current.userInterfaceIdiom == .pad
        let app = XCUIApplication()
        // A preceding runtime suite can leave its host process alive. Setting
        // orientation first waits for that unrelated event loop to become idle.
        app.terminate()
        XCUIDevice.shared.orientation = ipad ? .landscapeLeft : .portrait
        app.launchArguments = ["-ui-testing", "--ui-test-skip-onboarding", "--ui-test-batch-fixture", "--ui-test-pdf-fixture"]
        if ipad { app.launchArguments.append("-ui-testing-ipad") }
        app.launch()
        defer { app.terminate() }
        if !ipad {
            let sidebar = app.buttons["phone.sidebar.open"]
            XCTAssertTrue(sidebar.waitForExistence(timeout: 15))
            sidebar.tap()
        }
        let notes = app.descendants(matching: .any).matching(identifier: "sidebar.notes").firstMatch
        XCTAssertTrue(notes.waitForExistence(timeout: 15))
        notes.tap()
        let create = app.buttons["notes.create"]
        XCTAssertTrue(create.waitForExistence(timeout: 15))
        let ready = expectation(for: NSPredicate(format: "enabled == true"), evaluatedWith: create)
        wait(for: [ready], timeout: 10)
        capture("notes-library")
        create.tap()
        app.buttons["notes.import.workspace"].tap()
        // The phone's offscreen sidebar retains a conversation with this same
        // title. Select the import row's own identity, not a global text match.
        let workspace = app.descendants(matching: .any).matching(NSPredicate(
            format: "identifier BEGINSWITH %@ AND label CONTAINS %@",
            "workspace.import.source.", "批量选择测试"
        )).firstMatch
        XCTAssertTrue(workspace.waitForExistence(timeout: 10))
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
        let tree = XCTAttachment(string: app.debugDescription)
        tree.name = "notes-editor-after-import-tree"
        tree.lifetime = .keepAlways
        add(tree)
        XCTAssertTrue(editorAppeared)
        let editorReady = expectation(for: NSPredicate(format: "hittable == true"), evaluatedWith: back)
        wait(for: [editorReady], timeout: 10)
        XCTAssertEqual(app.buttons.matching(identifier: "notes.back").count, 1)
        XCTAssertTrue(back.isHittable)
        assertTouchTarget(back)
        XCTAssertFalse(app.navigationBars["从工作区导入"].exists)
        XCTAssertFalse(app.textFields["notes.search"].isHittable)
        XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "notes.pencil.page").firstMatch.waitForExistence(timeout: 10))
        capture("notes-imported-pdf-fullscreen")
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
        XCTAssertTrue(marker.isSelected)
        let paletteColor = app.buttons["notes.pencil.quickMenu.color.1"]
        paletteColor.tap(); XCTAssertTrue(paletteColor.isSelected)
        let paletteWidth = app.buttons["notes.pencil.quickMenu.width.32"]
        paletteWidth.tap(); XCTAssertTrue(paletteWidth.isSelected)
        capture("notes-pencil-quick-menu")
        app.buttons["notes.pencil.quickMenu.close"].tap()
        let toolbarMarker = app.buttons["notes.tool.highlighter"]
        let paletteDismissed = expectation(for: NSPredicate(format: "hittable == true"), evaluatedWith: toolbarMarker)
        wait(for: [paletteDismissed], timeout: 10)
        XCTAssertTrue(toolbarMarker.isSelected)
        let headerToggle = app.buttons["notes.header.toggle"]
        assertTouchTarget(headerToggle)
        let expandedPageY = app.descendants(matching: .any).matching(identifier: "notes.pencil.page").firstMatch.frame.minY
        headerToggle.tap()
        XCTAssertFalse(back.exists)
        XCTAssertTrue(quickMenu.isHittable)
        XCTAssertTrue(toolbarMarker.isHittable)
        XCTAssertLessThan(app.descendants(matching: .any).matching(identifier: "notes.pencil.page").firstMatch.frame.minY, expandedPageY)
        capture("notes-focused-writing")
        headerToggle.tap()
        XCTAssertTrue(back.waitForExistence(timeout: 5))
        XCTAssertTrue(back.isHittable)
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
        XCTAssertTrue(back.waitForExistence(timeout: 10))
        let original = app.buttons[originalID]
        // On narrow phones the selected tab is scrolled into view. Reveal its predecessor.
        if !original.isHittable { app.scrollViews.containing(.button, identifier: originalID).firstMatch.swipeRight() }
        XCTAssertTrue(original.isHittable)
        original.tap()
        XCTAssertTrue(toolbarMarker.waitForExistence(timeout: 10))
        XCTAssertTrue(toolbarMarker.isSelected)
        capture("notes-document-tabs")
        let closeOriginal = app.buttons[originalID.replacingOccurrences(of: "notes.tab.", with: "notes.tab.close.")]
        XCTAssertTrue(closeOriginal.isHittable)
        closeOriginal.tap()
        XCTAssertFalse(app.buttons[originalID].exists)
        XCTAssertTrue(back.waitForExistence(timeout: 10))
        // The same palette is opened by Pencil interactions; physical squeeze
        // delivery is a device check, not simulated by this button test.
        back.tap()
        let search = app.textFields["notes.search"]
        XCTAssertTrue(search.waitForExistence(timeout: 10))
        search.tap()
        search.typeText("Inline reading") // Text inside the PDF, absent from its filename.
        XCTAssertTrue(app.staticTexts["预览验收"].firstMatch.waitForExistence(timeout: 10))
        // The title already existed before typing. Require the actual body-match
        // snippet so an unchanged library cannot pass as a working search.
        let snippet = app.staticTexts.matching(NSPredicate(format: "label CONTAINS[c] %@", "Inline reading")).firstMatch
        XCTAssertTrue(snippet.waitForExistence(timeout: 10))
        capture("notes-document-body-search")
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
