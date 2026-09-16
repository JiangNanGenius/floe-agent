// SPDX-License-Identifier: MPL-2.0
import XCTest
import UIKit

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
        let create = app.buttons["notes.create"]
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
        let wheelDismissed = expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: app.buttons["notes.pencil.quickMenu.close"])
        wait(for: [wheelDismissed], timeout: 10)
        XCTAssertTrue(toolbarMarker.isSelected)
        XCTAssertFalse(app.buttons["notes.pencil.quickMenu.close"].exists)
        // Reopening highlights the current tool; the center cancels without changing it.
        quickMenu.tap()
        XCTAssertTrue(marker.waitForExistence(timeout: 5))
        XCTAssertTrue(marker.isSelected)
        capture("notes-pencil-quick-menu")
        app.buttons["notes.pencil.quickMenu.close"].tap()
        let cancelled = expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: app.buttons["notes.pencil.quickMenu.close"])
        wait(for: [cancelled], timeout: 10)
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
        XCTAssertTrue(app.staticTexts["预览验收"].firstMatch.waitForExistence(timeout: 10))
        // The title already existed before typing. Require the actual body-match
        // snippet so an unchanged library cannot pass as a working search.
        let snippet = app.staticTexts.matching(NSPredicate(format: "label CONTAINS[c] %@", "Inline reading")).firstMatch
        XCTAssertTrue(snippet.waitForExistence(timeout: 10))
        capture("notes-document-body-search")
        let result = app.buttons.containing(.staticText, identifier: "预览验收").firstMatch
        XCTAssertTrue(result.waitForExistence(timeout: 10))
        // Landscape iPad fits only a few rows above the keyboard; reveal the
        // match with a real scroll instead of assuming its initial position.
        if !result.isHittable { app.scrollViews.firstMatch.swipeUp() }
        XCTAssertTrue(result.isHittable)
        result.tap()
        XCTAssertTrue(back.waitForExistence(timeout: 10))
        XCTAssertTrue(back.isHittable)
        capture("notes-body-search-opened-document")
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
            XCUIDevice.shared.orientation = .landscapeLeft
            let landscape = expectation(for: NSPredicate { _, _ in app.frame.width > app.frame.height }, evaluatedWith: app)
            wait(for: [landscape], timeout: 10)
        }
        if !ipad {
            let sidebar = app.buttons["phone.sidebar.open"]
            XCTAssertTrue(sidebar.waitForExistence(timeout: 15))
            sidebar.tap()
        }
        let notes = app.staticTexts["sidebar.notes"].firstMatch
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
        // NavigationLink rows are buttons: an any-type descendant predicate scan
        // stalls AX snapshots on loaded runners.
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
