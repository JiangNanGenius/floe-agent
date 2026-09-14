// SPDX-License-Identifier: MPL-2.0
import XCTest
import UIKit

@MainActor
final class NotesWorkspaceImportUITests: XCTestCase {
    func testWorkspacePDFImportOpensFullscreenAndSearchesBody() throws {
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
        let workspace = app.staticTexts["批量选择测试"].firstMatch
        XCTAssertTrue(workspace.waitForExistence(timeout: 10))
        workspace.tap()
        let file = app.buttons["office.attachment.workspace.file.预览验收.pdf"]
        XCTAssertTrue(file.waitForExistence(timeout: 10))
        capture("notes-workspace-import")
        file.tap()
        let back = app.buttons["notes.back"].firstMatch
        XCTAssertTrue(back.waitForExistence(timeout: 20))
        XCTAssertTrue(back.isHittable)
        XCTAssertFalse(app.navigationBars["从工作区导入"].exists)
        XCTAssertFalse(app.textFields["notes.search"].isHittable)
        XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "notes.pencil.page").firstMatch.waitForExistence(timeout: 10))
        capture("notes-imported-pdf-fullscreen")
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
}
