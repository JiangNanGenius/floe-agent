// SPDX-License-Identifier: MPL-2.0
import XCTest

/// These tests run only through the canonical Simulator wrapper. They never
/// send host mouse/keyboard input or select a physical device in Device Hub.
@MainActor final class NativeWorkflowsUITests: XCTestCase {
    private let app = XCUIApplication(bundleIdentifier: "org.floeagent.ios")
    override func setUpWithError() throws {
        continueAfterFailure = false
        app.launchArguments = ["-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN"]
        app.launch()
    }
    override func tearDownWithError() throws {
        app.terminate()
        XCUIDevice.shared.orientation = .portrait
    }
    private func capture(_ name: String) {
        Thread.sleep(forTimeInterval: 1)
        FileHandle.standardOutput.write(Data(("FLOE_UI_CAPTURE|" + name + "\n").utf8))
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
        // The host captures the same canonical device on the marker. Keep the
        // page visible until that capture finishes before dismissing it.
        Thread.sleep(forTimeInterval: 3)
    }
    private func create(_ kind: String) {
        // Tap the selectable native row. The label's accessibility frame can
        // span a recycled cell while the saved sidebar is being restored.
        let space = app.collectionViews["sidebar.list"].cells
            .containing(.staticText, identifier: "sidebar.notes").firstMatch
        XCTAssertTrue(space.waitForExistence(timeout: 20)); space.tap()
        let new = app.buttons["space.workbenches"].firstMatch
        XCTAssertTrue(new.waitForExistence(timeout: 15)); new.tap()
        let choice = app.buttons[kind].firstMatch
        XCTAssertTrue(choice.waitForExistence(timeout: 5)); choice.tap()
        confirmWorkCreation()
    }
    func testPrintExportAndAssistantAreReachableAfterRealSlicing() {
        create("3D 打印")
        let cube = app.buttons["printing.cube"]
        XCTAssertTrue(cube.waitForExistence(timeout: 10)); cube.tap()
        let slice = app.buttons["printing.slice"]
        XCTAssertTrue(slice.waitForExistence(timeout: 10)); XCTAssertTrue(slice.isEnabled); slice.tap()
        XCTAssertTrue(app.staticTexts["结果已保存"].waitForExistence(timeout: 90))
        let export = app.buttons["printing.export"]
        XCTAssertTrue(export.exists)
        if !export.isHittable {
            let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.85))
            let end = app.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5))
            start.press(forDuration: 0.05, thenDragTo: end)
        }
        XCTAssertTrue(export.isHittable, "The saved result must not be covered by the assistant entry")
        XCTAssertTrue(app.buttons["space.editor.assistant"].isHittable)
        capture("Native print saved result and accessible export")
    }
    func testMIDIEditingHasLabelsAndAssistantStaysOutOfOrdinaryHistory() {
        create("音乐")
        app.buttons["music.addTrack"].tap()
        let addClip = app.buttons["music.addMIDIClip"].firstMatch
        XCTAssertTrue(addClip.waitForExistence(timeout: 10)); addClip.tap()
        let addNote = app.buttons["添加音符"].firstMatch
        XCTAssertTrue(addNote.waitForExistence(timeout: 10)); addNote.tap()
        for title in ["音高", "起点", "时长", "力度"] {
            XCTAssertTrue(app.staticTexts[title].firstMatch.exists)
        }
        capture("Native MIDI editing labels")
        app.buttons["保存"].firstMatch.tap()
        let assistant = app.buttons["space.editor.assistant"]
        XCTAssertTrue(assistant.waitForExistence(timeout: 10)); assistant.tap()
        let composer = app.descendants(matching: .any).matching(identifier: "composer.input").firstMatch
        XCTAssertTrue(composer.waitForExistence(timeout: 20))
        let text = composer.value as? String ?? ""
        XCTAssertNil(text.range(of: #"[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}"#, options: .regularExpression))
        capture("Native work assistant empty composer")
        let done = app.buttons.matching(NSPredicate(format: "label == %@", "完成")).allElementsBoundByIndex.first { $0.isHittable }
        XCTAssertNotNil(done); done?.tap()
        let close = app.buttons["space.editor.done"]
        XCTAssertTrue(close.waitForExistence(timeout: 10)); close.tap()
        XCTAssertTrue(app.buttons["space.new"].waitForExistence(timeout: 10))
        let leaked = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "作品助手 · "))
        XCTAssertEqual(leaked.count, 0)
        capture("Ordinary history excludes work assistant")
    }

    /// This round intentionally checks navigation, visible controls and layout.
    /// It does not slice, record, render media or call a configured provider.
    func testIntegratedMenusAndNativePagesOpen() {
        XCUIDevice.shared.orientation = .landscapeLeft
        openAndCheckFilesAndTextDocument()
        openAndCheckPrintAndMusic()
        openAndCheckMeeting()
    }
    func testFilesLibraryAndOfficeMenuOpen() {
        XCUIDevice.shared.orientation = .landscapeLeft
        openAndCheckFilesAndTextDocument()
    }
    private func openAndCheckFilesAndTextDocument() {
        let space = app.collectionViews["sidebar.list"].cells.containing(.staticText, identifier: "sidebar.notes").firstMatch
        XCTAssertTrue(space.waitForExistence(timeout: 25)); space.tap()
        let files = app.segmentedControls.firstMatch.buttons["文件"]
        XCTAssertTrue(files.waitForExistence(timeout: 15)); files.tap()
        let view = app.buttons["space.viewOptions"]
        XCTAssertTrue(view.waitForExistence(timeout: 10))
        view.tap()
        XCTAssertTrue(app.buttons["缩略图"].firstMatch.waitForExistence(timeout: 5))
        app.buttons["缩略图"].firstMatch.tap()
        XCTAssertTrue(view.waitForExistence(timeout: 10)); view.tap()
        app.buttons["列表"].firstMatch.tap()
        capture("Space compact file list and view switch")
        app.buttons["space.new"].tap()
        for title in ["文件夹", "文档…", "绘画／图片", "视频", "二维 CAD", "手记", "化学工程"] {
            XCTAssertTrue(app.buttons[title].firstMatch.waitForExistence(timeout: 5), "Missing file creation item: \(title)")
        }
        XCTAssertFalse(app.buttons["混合画布"].exists)
        capture("Space Files original creation menu")
        app.buttons["space.new.document"].firstMatch.tap()
        capture("Files document format submenu opened")
        for title in ["Word 文档", "Excel 表格", "PowerPoint 演示文稿"] {
            XCTAssertTrue(app.buttons[title].firstMatch.waitForExistence(timeout: 5))
        }
        capture("Files document format submenu")
        app.buttons["纯文本"].firstMatch.tap()
        confirmWorkCreation()
        XCTAssertTrue(app.textViews["space.document.editor"].waitForExistence(timeout: 20))
        XCTAssertTrue(app.buttons["space.editor.assistant"].exists)
        capture("Native editable document")
        closeEditor()
    }
    func testPrintingAndMusicPagesOpen() {
        XCUIDevice.shared.orientation = .landscapeLeft
        openFiles()
        openAndCheckPrintAndMusic()
    }
    func testWorkbenchLayoutFrames() {
        XCUIDevice.shared.orientation = .landscapeLeft
        openFiles()
        let record = app.descendants(matching: .cell).containing(.staticText, identifier: "3D 打印").firstMatch
        XCTAssertTrue(record.waitForExistence(timeout: 15)); record.tap()
        let root = app.descendants(matching: .any)["printing.workbench"].firstMatch
        XCTAssertTrue(root.waitForExistence(timeout: 20))
        let sliceFrame = app.buttons["printing.slice"].frame
        let importFrame = app.buttons["printing.import"].frame
        let keyboardFrame = app.keyboards.firstMatch.exists ? app.keyboards.firstMatch.frame : .zero
        let metrics = "window=\(app.windows.firstMatch.frame); root=\(root.frame); slice=\(sliceFrame); import=\(importFrame); keyboard=\(keyboardFrame)"
        FileHandle.standardOutput.write(Data(("FLOE_UI_LAYOUT|" + metrics + "\n").utf8))
        let attachment = XCTAttachment(string: metrics)
        attachment.name = "Workbench frame diagnostic"; attachment.lifetime = .keepAlways; add(attachment)
        capture("Existing print project layout diagnostic")
        closeEditor()
    }
    private func openAndCheckPrintAndMusic() {
        openWorkbench("3D 打印")
        XCTAssertTrue(app.descendants(matching: .any)["printing.workbench"].firstMatch.waitForExistence(timeout: 20))
        capture("Printing initial opened surface")
        XCTAssertTrue(app.buttons["printing.import"].waitForExistence(timeout: 15))
        XCTAssertTrue(app.buttons["printing.addObject"].exists)
        XCTAssertTrue(app.buttons["printing.slice"].exists)
        capture("Printing three column preparation workbench")
        closeEditor()

        openWorkbench("音乐")
        XCTAssertTrue(app.buttons["music.play"].waitForExistence(timeout: 20))
        XCTAssertTrue(app.buttons["music.record"].exists)
        XCTAssertTrue(app.buttons["music.export.settings"].exists)
        capture("Music arrangement native professional workbench")
        if app.buttons["DJ"].firstMatch.exists { app.buttons["DJ"].firstMatch.tap(); capture("Music DJ controls") }
        closeEditor()
    }
    func testNotesMeetingPageOpens() {
        XCUIDevice.shared.orientation = .landscapeLeft
        openFiles()
        openAndCheckMeeting()
    }
    func testChemistryProjectPageOpens() {
        XCUIDevice.shared.orientation = .landscapeLeft
        openFiles()
        app.buttons["space.new"].tap()
        XCTAssertTrue(app.buttons["化学工程"].firstMatch.waitForExistence(timeout: 10))
        app.buttons["化学工程"].firstMatch.tap()
        confirmWorkCreation(appendTitle: "-QA")
        XCTAssertTrue(app.buttons["新建结构绘图"].firstMatch.waitForExistence(timeout: 20))
        XCTAssertTrue(app.buttons["属性与方法"].firstMatch.exists)
        XCTAssertTrue(app.buttons["历史版本"].firstMatch.exists)
        capture("Chemistry native project workbench and tools")
        let environment = app.buttons["chemistry.environment.open"]
        XCTAssertTrue(environment.exists); environment.tap()
        XCTAssertTrue(app.buttons["chemistry.environment.choose"].waitForExistence(timeout: 15))
        XCTAssertTrue(app.buttons["chemistry.environment.probe"].exists)
        XCTAssertTrue(app.buttons["chemistry.environment.start"].exists)
        capture("Chemistry actual execution environment panel")
        app.buttons["chemistry.environment.done"].tap()
        closeEditor()
    }
    private func openAndCheckMeeting() {
        app.segmentedControls["space.sections"].buttons["手记"].tap()
        let create = app.buttons["notes.create"]
        XCTAssertTrue(create.waitForExistence(timeout: 15)); create.tap()
        app.buttons["notes.create.meeting"].tap()
        let title = app.textFields["notes.create.title"]
        XCTAssertTrue(title.waitForExistence(timeout: 10)); title.tap(); title.typeText("会议界面检查")
        app.buttons["创建"].firstMatch.tap()
        XCTAssertTrue(app.descendants(matching: .any)["meeting.workbench"].firstMatch.waitForExistence(timeout: 25))
        capture("Meeting initial opened surface")
        XCTAssertTrue(app.descendants(matching: .any)["meeting.personalNotes"].firstMatch.waitForExistence(timeout: 20))
        XCTAssertTrue(app.buttons["meeting.record"].exists)
        capture("Notes meeting notebook and transcript sidebar")
        closeEditor()
    }
    func testCreativeCanvasEntryStaysInCreativeMode() {
        XCUIDevice.shared.orientation = .landscapeLeft
        let creative = app.collectionViews["sidebar.list"].cells.containing(.staticText, identifier: "sidebar.creative").firstMatch
        XCTAssertTrue(creative.waitForExistence(timeout: 25)); creative.tap()
        let new = app.buttons["canvas.home.create"]
        XCTAssertTrue(new.waitForExistence(timeout: 20)); new.tap()
        let blank = app.buttons["canvas.start.blank"]
        XCTAssertTrue(blank.waitForExistence(timeout: 15))
        XCTAssertTrue(app.textFields["canvas.start.goal"].exists || app.textViews["canvas.start.goal"].exists)
        capture("Creative canvas template and goal entry")
        blank.tap()
        XCTAssertTrue(app.buttons["canvas.host.actions"].waitForExistence(timeout: 25))
        XCTAssertTrue(app.buttons["space.editor.done"].exists)
        capture("Creative mixed canvas opened")
        closeEditor()
        XCUIDevice.shared.orientation = .portrait
    }
    func testMediaAndDraftingPagesOpenWithTheirTools() {
        XCUIDevice.shared.orientation = .landscapeLeft
        openFiles()
        for title in ["绘画／图片", "视频"] {
            app.buttons["space.new"].tap()
            app.buttons[title].firstMatch.tap()
            confirmWorkCreation()
            XCTAssertTrue(app.descendants(matching: .any)["media.v2.toolbox"].firstMatch.waitForExistence(timeout: 25))
            XCTAssertTrue(app.buttons["导入素材"].firstMatch.exists)
            XCTAssertTrue(app.buttons["导出"].firstMatch.exists)
            capture(title == "视频" ? "Native video editor and timeline" : "Native drawing image editor and tool categories")
            closeEditor()
        }
        app.buttons["space.new"].tap()
        app.buttons["二维 CAD"].firstMatch.tap()
        confirmWorkCreation()
        XCTAssertTrue(app.descendants(matching: .any)["CAD2DDraftingBar"].firstMatch.waitForExistence(timeout: 30))
        capture("Native 2D CAD drafting controls")
        closeEditor()
    }
    func testDiagramManufacturingAndToolboxPagesOpen() {
        XCUIDevice.shared.orientation = .landscapeLeft
        openFiles()
        openWorkbench("图示")
        XCTAssertTrue(app.buttons["diagram.addMenu"].waitForExistence(timeout: 20))
        XCTAssertTrue(app.buttons["diagram.fileMenu"].exists)
        capture("Native diagram editor tools")
        closeEditor()
        openWorkbench("加工")
        XCTAssertTrue(app.buttons["study.import"].waitForExistence(timeout: 25))
        XCTAssertTrue(app.buttons["study.stock"].exists)
        capture("Native manufacturing setup and viewport")
        closeEditor()
        app.segmentedControls["space.sections"].buttons["工具箱"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["toolbox.home"].firstMatch.waitForExistence(timeout: 20))
        for title in ["终端", "VNC 远程桌面", "浏览器", "Ping"] {
            XCTAssertTrue(app.buttons.containing(.staticText, identifier: title).firstMatch.exists,
                          "Missing toolbox entry: \(title)")
        }
        capture("Space Toolbox connection and diagnostic menu")
        app.buttons.containing(.staticText, identifier: "终端").firstMatch.tap()
        XCTAssertTrue(app.staticTexts["终端"].firstMatch.waitForExistence(timeout: 15))
        capture("Toolbox terminal machine selection")
    }
    private func openFiles() {
        let space = app.collectionViews["sidebar.list"].cells.containing(.staticText, identifier: "sidebar.notes").firstMatch
        XCTAssertTrue(space.waitForExistence(timeout: 25)); space.tap()
        let files = app.segmentedControls["space.sections"].buttons["文件"]
        XCTAssertTrue(files.waitForExistence(timeout: 15)); files.tap()
    }
    private func confirmWorkCreation(appendTitle: String? = nil) {
        let create = app.buttons["space.creation.create"]
        XCTAssertTrue(create.waitForExistence(timeout: 10))
        if let appendTitle {
            let title = app.textFields["space.creation.title"]
            XCTAssertTrue(title.exists); title.tap(); title.typeText(appendTitle)
        }
        create.tap()
        XCTAssertTrue(create.waitForNonExistence(timeout: 15))
        XCTAssertTrue(app.buttons["space.editor.done"].waitForExistence(timeout: 25))
    }
    private func openWorkbench(_ title: String) {
        let menu = app.buttons["space.workbenches"]
        XCTAssertTrue(menu.waitForExistence(timeout: 15)); menu.tap()
        app.buttons[title].firstMatch.tap(); confirmWorkCreation()
    }
    private func closeEditor() {
        let done = app.buttons["space.editor.done"]
        XCTAssertTrue(done.waitForExistence(timeout: 10)); done.tap()
        XCTAssertTrue(done.waitForNonExistence(timeout: 15))
    }
}
