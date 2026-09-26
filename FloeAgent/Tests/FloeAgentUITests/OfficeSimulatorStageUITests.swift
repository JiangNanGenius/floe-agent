// SPDX-License-Identifier: MPL-2.0
import XCTest
import UIKit

/// Cloud simulator stage run for the PPT/PPTX open and edit-entry chain.
///
/// The pinned Collabora engine and `FloeOfficeNative.framework` are built for
/// iphoneos arm64 only: the framework is a plain device framework and a
/// simulator link is refused by the linker. This run therefore never claims a
/// slide paint, an edit session, a save or a close. It drives every real entry
/// path — Notes library, Workspace preview, IDE Office tab — with genuinely
/// generated PPTX and DOCX fixtures, asserts the exact surface each path
/// reaches without an engine (no endless spinner, no fake success), captures
/// original screenshots and leaves the App's durable `[FloeOfficeStage]` trace
/// for the run receipt. Device Office acceptance remains a separate gate.
@MainActor
final class OfficeSimulatorStageUITests: XCTestCase {

    func testRealOfficeEntryPathsReachTheExactSimulatorHostBlocker() throws {
        #if !targetEnvironment(simulator)
        throw XCTSkip("the simulator-host blocker run is simulator-only; device Office acceptance is separate.")
        #else
        continueAfterFailure = false
        let ipad = ProcessInfo.processInfo.environment["SIMULATOR_MODEL_IDENTIFIER"]?.hasPrefix("iPad") == true
            || UIDevice.current.userInterfaceIdiom == .pad
        let app = XCUIApplication()
        app.terminate()
        XCUIDevice.shared.orientation = ipad ? .landscapeLeft : .portrait
        app.launchArguments = ["-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN", "-ui-testing",
                               "--ui-test-skip-onboarding", "--ui-test-batch-fixture",
                               "--ui-test-ide-fixture", "--ui-test-office-workspace-fixture",
                               "--ui-test-notes-office-thumbnail-fixture"]
        if ipad { app.launchArguments.append("-ui-testing-ipad") }
        app.launch()
        defer { app.terminate() }

        // 1) Notes library: the generated real PPTX opens the Notes Office
        //    surface. Without the engine the Notes-owned unavailable page must
        //    appear — not an unowned opening spinner.
        openNotesLibrary(app, ipad: ipad)
        let deckCard = revealCard(app, title: "封面验收-PPT")
        XCTAssertTrue(deckCard.isHittable, "the generated PPTX card must open")
        deckCard.tap()
        let header = app.descendants(matching: .any).matching(identifier: "notes.office.header").firstMatch
        XCTAssertTrue(header.waitForExistence(timeout: 30),
                      "the Notes Office surface must own the header")
        XCTAssertTrue(app.staticTexts["Office 编辑器不可用"].waitForExistence(timeout: 15),
                      "the simulator build must state the missing native engine instead of pretending to open")
        XCTAssertFalse(app.staticTexts["正在打开文档…"].exists,
                       "no Office session may sit on the opening spinner without an engine")
        capture("office-simulator-notes-pptx-unavailable")
        app.buttons["notes.back"].tap()
        XCTAssertTrue(app.buttons["notes.create"].waitForExistence(timeout: 30))

        // 2) Workspace preview: the real PPTX resolves through the same
        //    resolved local URL the device path uses, then falls back to the
        //    system renderer. No Office edit entry may be offered and no
        //    spinner may appear.
        openWorkspaceFile(app, ipad: ipad, workspaceLabel: "批量选择测试", name: "办公验收-演示.pptx")
        XCTAssertTrue(anyElement(app, "file.preview.binary.inline").waitForExistence(timeout: 30),
                      "the Workspace preview must reach the read-only fallback surface")
        XCTAssertFalse(app.buttons["file.preview.office.edit"].exists,
                       "a build without the engine must not offer an Office edit entry")
        XCTAssertFalse(app.staticTexts["正在打开文档…"].exists)
        capture("office-simulator-workspace-pptx-fallback")

        // 3) DOCX entry regression on the same surface: identical
        //    classification and fallback, no Office edit entry, no spinner.
        app.buttons["workspace.preview.backToFiles"].tap()
        let docx = app.staticTexts["办公验收-文稿.docx"].firstMatch
        XCTAssertTrue(docx.waitForExistence(timeout: 15), "the DOCX regression fixture must be listed")
        docx.tap()
        XCTAssertTrue(anyElement(app, "file.preview.binary.inline").waitForExistence(timeout: 30),
                      "DOCX must keep the same honest fallback")
        XCTAssertFalse(app.buttons["file.preview.office.edit"].exists)
        XCTAssertFalse(app.staticTexts["正在打开文档…"].exists)
        capture("office-simulator-workspace-docx-regression")
        app.buttons["workspace.preview.backToFiles"].tap()

        // 4) IDE Office tab: open the real PPTX from the IDE explorer. The
        //    shared Office session must reach its bounded unsupported surface
        //    with recovery, never an endless opening indicator.
        let text = app.staticTexts["IDE验收.txt"].firstMatch
        XCTAssertTrue(text.waitForExistence(timeout: 15), "the IDE text fixture must be listed")
        text.tap()
        XCTAssertTrue(app.textViews["workspace.ide.nativeEditor"].waitForExistence(timeout: 30))
        let openIDE = app.buttons["file.preview.openIDE"]
        XCTAssertTrue(openIDE.waitForExistence(timeout: 15)); openIDE.tap()
        XCTAssertTrue(app.textViews["workspace.ide.nativeEditor"].waitForExistence(timeout: 30),
                      "the IDE workbench must open before the Office tab is selected")
        let deckRow = app.staticTexts["办公验收-演示.pptx"].firstMatch
        XCTAssertTrue(deckRow.waitForExistence(timeout: 20),
                      "the IDE Explorer must list the generated PPTX")
        deckRow.tap()
        XCTAssertTrue(app.staticTexts["无法打开文档"].waitForExistence(timeout: 30),
                      "the IDE Office tab must show the bounded unavailable surface")
        XCTAssertTrue(anyElement(app, "workspace.ide.office.edit").waitForExistence(timeout: 15)
                      || app.buttons["恢复文档"].waitForExistence(timeout: 15),
                      "the bounded IDE office surface must offer an exit or a recovery action")
        XCTAssertFalse(app.staticTexts["正在打开文档…"].exists,
                       "the IDE Office tab must never rest on the opening spinner")
        capture("office-simulator-ide-pptx-bounded")
        #endif
    }

    // MARK: - Helpers

    private func anyElement(_ app: XCUIApplication, _ identifier: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    private func openNotesLibrary(_ app: XCUIApplication, ipad: Bool) {
        if !ipad {
            let sidebar = app.buttons["phone.sidebar.open"]
            XCTAssertTrue(sidebar.waitForExistence(timeout: 15)); sidebar.tap()
        }
        let notes = app.staticTexts["sidebar.notes"].firstMatch
        XCTAssertTrue(notes.waitForExistence(timeout: 15)); notes.tap()
        XCTAssertTrue(app.buttons["notes.create"].waitForExistence(timeout: 20),
                      "the Notes library must load")
    }

    private func revealCard(_ app: XCUIApplication, title: String) -> XCUIElement {
        let card = app.scrollViews["notes.library.scroll"].buttons
            .matching(NSPredicate(format: "identifier BEGINSWITH %@", "notes.card.office.\(title)."))
            .element(boundBy: 0)
        if card.exists && card.isHittable { return card }
        let scroll = app.scrollViews["notes.library.scroll"]
        guard scroll.waitForExistence(timeout: 10) else { return card }
        for _ in 0..<8 where !(card.exists && card.isHittable) { scroll.swipeDown() }
        let deadline = Date().addingTimeInterval(60)
        while !(card.exists && card.isHittable) && Date() < deadline { scroll.swipeUp() }
        return card
    }

    /// Mirrors `WorkspaceIDEUITests.openFile`: Settings -> Files -> the batch
    /// fixture workspace -> the real file row.
    private func openWorkspaceFile(_ app: XCUIApplication, ipad: Bool, workspaceLabel: String, name: String) {
        if !ipad {
            let sidebar = app.buttons["phone.sidebar.open"]
            XCTAssertTrue(sidebar.waitForExistence(timeout: 15)); sidebar.tap()
        }
        let settings = app.buttons["sidebar.settings"]
        XCTAssertTrue(settings.waitForExistence(timeout: 15)); settings.tap()
        let files = ipad ? app.staticTexts["settings.section.files"].firstMatch
                         : app.buttons["settings.section.files"]
        if !ipad {
            let sections = app.collectionViews["settings.sections"]
            XCTAssertTrue(sections.waitForExistence(timeout: 10))
            for _ in 0..<6 where !(files.exists && files.isHittable) { sections.swipeUp() }
        }
        XCTAssertTrue(files.waitForExistence(timeout: 30)); files.tap()
        let manage = app.buttons["settings.files.manage"]
        XCTAssertTrue(manage.waitForExistence(timeout: 10)); manage.tap()
        let workspace = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", workspaceLabel)).firstMatch
        XCTAssertTrue(workspace.waitForExistence(timeout: 30)); workspace.tap()
        let file = app.staticTexts[name].firstMatch
        XCTAssertTrue(file.waitForExistence(timeout: 30)); file.tap()
    }

    private func capture(_ name: String) {
        let image = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        image.name = name
        image.lifetime = .keepAlways
        add(image)
    }
}
