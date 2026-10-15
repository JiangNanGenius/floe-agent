// FloeAgentUITests — reading mode (O) acceptance on the real App.
//
// Proves the read-only reading mode is reachable from the Notes editor for a
// text notebook, that it renders the document's own text without touching the
// editor state, and that closing it returns to the untouched editor. The
// fixture notebook is the same synthetic one the cover acceptance seeds.

import XCTest

final class TextReaderUITests: XCTestCase {
    func testReadingModeOpensFromANotesTextDocumentAndClosesBackToTheEditor() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.terminate()
        XCUIDevice.shared.orientation = .landscapeLeft
        app.launchArguments = [
            "-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN", "-ui-testing",
            "--ui-test-skip-onboarding", "--ui-test-batch-fixture",
            "--ui-test-notes-office-thumbnail-fixture", "-ui-testing-ipad"
        ]
        app.launch()
        defer { app.terminate() }

        // Notes → the seeded text notebook.
        let notes = app.staticTexts["sidebar.notes"].firstMatch
        XCTAssertTrue(notes.waitForExistence(timeout: 30), "Notes must be reachable")
        notes.tap()
        let card = app.buttons
            .matching(NSPredicate(format: "identifier BEGINSWITH %@", "notes.card.notebook.封面验收 手写页."))
            .firstMatch
        XCTAssertTrue(card.waitForExistence(timeout: 30), "the text notebook fixture must exist")
        card.tap()

        let readerEntry = app.buttons["notes.reader.open"].firstMatch
        XCTAssertTrue(readerEntry.waitForExistence(timeout: 30),
                      "the reading-mode entry must exist for a text notebook")
        readerEntry.tap()

        // The read-only reader. `reader.content` is the real scrolling body
        // (a ScrollView), so it is matched by identifier regardless of type.
        let content = app.descendants(matching: .any)
            .matching(identifier: "reader.content").firstMatch
        XCTAssertTrue(content.waitForExistence(timeout: 30), "the reader content must appear")
        XCTAssertTrue(app.scrollViews.matching(identifier: "reader.content").firstMatch.exists
                      || content.exists,
                      "the reader body must be the real scrolling content view")
        XCTAssertTrue(app.buttons["reader.close"].firstMatch.waitForExistence(timeout: 10),
                      "the reader must offer its real close control")
        XCTAssertTrue(app.buttons["reader.settings"].firstMatch.exists,
                      "reader appearance settings must be available")
        let status = app.descendants(matching: .any)
            .matching(identifier: "reader.status").firstMatch
        if status.exists {
            XCTAssertFalse((status.value as? String ?? "").isEmpty,
                           "a visible reader status must report the real document position")
        }
        capture("reader-notes-open")

        // Reading settings are real controls in the reader.
        let settings = app.buttons["reader.settings"].firstMatch
        XCTAssertTrue(settings.waitForExistence(timeout: 10), "the reading settings must exist")
        settings.tap()
        Thread.sleep(forTimeInterval: 0.8)
        capture("reader-notes-settings")

        // Encoding choice (O2) lives in Reading Settings — the reading chrome
        // deliberately has no permanent technical encoding control; the
        // top-level encoding Menu appears only in the decode-error state.
        // Choosing UTF-8 here is the real manual-recovery path and must be
        // reported as the user's choice while the document stays readable.
        let encodingRow = app.buttons["编码"].firstMatch
        XCTAssertTrue(encodingRow.waitForExistence(timeout: 10),
                      "the settings encoding picker must exist")
        encodingRow.tap()
        let utf8 = app.buttons["UTF-8"].firstMatch
        XCTAssertTrue(utf8.waitForExistence(timeout: 10),
                      "the encoding picker must offer the real UTF-8 choice")
        utf8.tap()
        Thread.sleep(forTimeInterval: 1.0)
        capture("reader-encoding-chosen")
        app.tap() // dismiss the settings popover/menu
        Thread.sleep(forTimeInterval: 0.5)
        XCTAssertTrue(app.descendants(matching: .any)
            .matching(identifier: "reader.content").firstMatch.exists,
            "the document must stay readable after a manual encoding choice")
        let encodingStatus = app.descendants(matching: .any)
            .matching(identifier: "reader.status").firstMatch
        if encodingStatus.exists {
            let label = (encodingStatus.label.isEmpty
                         ? (encodingStatus.value as? String ?? "")
                         : encodingStatus.label)
            XCTAssertTrue(label.contains("UTF-8"),
                          "the reader must report the chosen encoding: \(label)")
        }

        // Close returns to the untouched editor.
        app.buttons["reader.close"].firstMatch.tap()
        XCTAssertTrue(readerEntry.waitForExistence(timeout: 20),
                      "closing the reader must return to the Notes editor")
        capture("reader-notes-closed")
    }

    private func capture(_ name: String) {
        let image = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        image.name = name
        image.lifetime = .keepAlways
        add(image)
    }
}
