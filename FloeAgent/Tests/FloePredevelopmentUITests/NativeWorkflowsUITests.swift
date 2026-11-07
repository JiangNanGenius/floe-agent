// SPDX-License-Identifier: MPL-2.0
import XCTest

/// These tests run only through the canonical Simulator wrapper. They never
/// send host mouse/keyboard input or select a physical device in Device Hub.
@MainActor final class NativeWorkflowsUITests: XCTestCase {
    private let app = XCUIApplication(bundleIdentifier: "org.floeagent.ios")
    override func setUpWithError() throws {
        continueAfterFailure = false
        app.launchArguments = ["-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN"]
        if name.contains("testPrintExportAndAssistantAreReachableAfterRealSlicing"),
           ProcessInfo.processInfo.environment["FLOE_QA_ENABLE_NATIVE_INPUT_OBSERVATION"] == "1" {
            app.launchArguments.append("--floe-native-input-observation")
        }
        app.launch()
    }
    override func tearDownWithError() throws {
        app.terminate()
        XCUIDevice.shared.orientation = .portrait
    }
    private func attachNativeInputObservation(_ phase: String) {
        guard app.launchArguments.contains("--floe-native-input-observation") else { return }
        // SwiftUI propagates printing.workbench onto the background native
        // element. Its own exact label survives; never read the parent value.
        var probes = app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", "Native input observation"))
        let sourceOnly = probes.count == 0
        if sourceOnly {
            probes = app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", "Native input handoff observation"))
        }
        var json: String?
        var diagnostic = ["Native probe JSON unavailable", "app -> native label matches: \(probes.count)"]
        for index in 0..<min(probes.count, 4) {
            let probe = probes.element(boundBy: index)
            if let raw = probe.value as? String, let data = raw.data(using: .utf8),
               let rows = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]],
               !rows.isEmpty, rows.allSatisfy({ $0["event"] is String && $0["sequence"] is NSNumber }),
               rows.contains(where: { ($0["event"] as? String)?.hasPrefix(sourceOnly ? "space." : "print.") == true }) {
                json = raw; break
            }
            // Restrict this to the known diagnostic element's short subtree;
            // no app-wide description, input text, paths or parent titles.
            diagnostic.append("probe[\(index)] value missing or invalid JSON\n" + probe.debugDescription.components(separatedBy: "\n").prefix(4).joined(separator: "\n"))
        }
        if json == nil {
            let roots = app.descendants(matching: .any).matching(identifier: "printing.workbench")
            diagnostic.append("app -> printing.workbench matches: \(roots.count)")
            for index in 0..<min(roots.count, 4) {
                let element = roots.element(boundBy: index)
                diagnostic.append("  node[\(index)] type=\(element.elementType.rawValue) frame=\(element.frame) nativeProbeLabel=\(element.label == "Native input observation")")
            }
        }
        let attachment = XCTAttachment(string: json ?? diagnostic.joined(separator: "\n"))
        attachment.name = "Print native input — " + phase
        attachment.lifetime = .keepAlways; add(attachment)
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
        let new = app.buttons["space.new"].firstMatch
        XCTAssertTrue(new.waitForExistence(timeout: 15)); new.tap()
        let choice = app.buttons[kind].firstMatch
        XCTAssertTrue(choice.waitForExistence(timeout: 5)); choice.tap()
        confirmWorkCreation()
    }
    func testPrintExportAndAssistantAreReachableAfterRealSlicing() {
        XCUIDevice.shared.orientation = .landscapeLeft
        openFiles()
        openSavedPrintFixture()
        assertPrintUsesAvailableWindow()
        let layerHeight = app.otherElements["printing.layerHeight"].firstMatch.textFields.firstMatch
        XCTAssertTrue(layerHeight.waitForExistence(timeout: 10)); XCTAssertTrue(layerHeight.isHittable)
        guard let originalLayerHeight = layerHeight.value as? String, !originalLayerHeight.isEmpty else {
            XCTFail("Read the actual saved layer height before exercising its input"); return
        }
        layerHeight.tap()
        let keyboardDone = app.buttons["printing.keyboard.done"].firstMatch
        XCTAssertTrue(keyboardDone.waitForExistence(timeout: 10)); XCTAssertTrue(keyboardDone.isHittable)
        let fieldSettled = XCTNSPredicateExpectation(predicate: NSPredicate { object, _ in
            guard let field = object as? XCUIElement else { return false }
            return field.exists && field.isHittable
        }, object: layerHeight)
        let fieldResult = XCTWaiter.wait(for: [fieldSettled], timeout: 10)
        let inputLayout = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        inputLayout.name = "Print focused setting after keyboard layout"; inputLayout.lifetime = .keepAlways; add(inputLayout)
        XCTAssertEqual(fieldResult, .completed, "The keyboard and inspector must settle with the actual setting operable")
        XCTAssertTrue(layerHeight.isHittable, "A real root setting must remain operable above its keyboard")
        layerHeight.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: originalLayerHeight.count))
        layerHeight.typeText(originalLayerHeight)
        attachNativeInputObservation("root setting keyboard open")
        capture("Print setting accepts input with its keyboard")
        keyboardDone.tap()
        XCTAssertTrue(keyboardDone.waitForNonExistence(timeout: 10))
        assertPrintUsesAvailableWindow()
        attachNativeInputObservation("root setting keyboard done")
        let addObject = app.buttons["printing.addObject"].firstMatch
        XCTAssertTrue(addObject.waitForExistence(timeout: 15)); XCTAssertTrue(addObject.isHittable); addObject.tap()
        let cube = app.buttons["添加 20 mm 立方体"].firstMatch
        XCTAssertTrue(cube.waitForExistence(timeout: 10)); cube.tap()
        let slice = app.buttons["printing.slice"]
        attachNativeInputObservation("before slice")
        XCTAssertTrue(slice.waitForExistence(timeout: 10)); XCTAssertTrue(slice.isEnabled); XCTAssertTrue(slice.isHittable); slice.tap()
        let previewReady = NSPredicate(format: "label == %@", "导出文件")
        _ = expectation(for: previewReady, evaluatedWith: slice)
        waitForExpectations(timeout: 90)
        XCTAssertEqual(app.buttons["printing.stage.preview"].label, "预览")
        XCTAssertTrue(app.buttons["printing.stage.preview"].isSelected)
        assertPrintUsesAvailableWindow()
        capture("Slice automatically enters Preview")
        slice.tap()
        let exportStage = app.buttons["printing.stage.export"]
        let enteredExport = XCTNSPredicateExpectation(predicate: NSPredicate { object, _ in
            (object as? XCUIElement)?.isSelected == true
        }, object: exportStage)
        XCTAssertEqual(XCTWaiter.wait(for: [enteredExport], timeout: 5), .completed,
                       "The footer must actually open Export before checking the saved file action")
        assertPrintUsesAvailableWindow()
        let exportScroll = app.scrollViews["printing.export.scroll"]
        XCTAssertTrue(exportScroll.waitForExistence(timeout: 10))
        let export = app.buttons["printing.export"]
        XCTAssertTrue(export.exists)
        // The central export scroll view and the right inspector scroll
        // independently. A window-relative swipe at x=0.9 scrolls the inspector.
        for _ in 0..<3 where !export.isHittable { exportScroll.swipeUp() }
        XCTAssertTrue(export.isHittable, "The saved result must not be covered by the assistant entry")
        XCTAssertTrue(app.buttons["space.editor.assistant"].isHittable)
        capture("Native print saved result and accessible export")
        closeEditor()
        let search = app.searchFields.firstMatch
        XCTAssertTrue(search.waitForExistence(timeout: 10))
        XCTAssertEqual(search.value as? String, "QA-Closure-Print-Preview",
                       "Restore this library filter only after its editor has closed")
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
    func testToolboxCarouselRoamingAndExportAreUsable() {
        XCUIDevice.shared.orientation = .landscapeLeft
        openFiles()
        app.segmentedControls["space.sections"].buttons["概览"].tap()
        capture("Space overview pinned covers and real recent use")
        app.segmentedControls["space.sections"].buttons["工具箱"].tap()
        let home = app.descendants(matching: .any)["toolbox.home"].firstMatch
        XCTAssertTrue(home.waitForExistence(timeout: 15))
        XCTAssertTrue(app.descendants(matching: .any)["toolbox.featured"].firstMatch.exists)
        capture("Toolbox draggable showcase and complete two column list")
        let roaming = app.buttons["toolbox.featured.roaming"].firstMatch
        XCTAssertTrue(roaming.exists); roaming.tap()
        let target = app.textFields["toolbox.roaming.target"].firstMatch
        XCTAssertTrue(target.waitForExistence(timeout: 15)); target.tap()
        target.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: (target.value as? String ?? "").count))
        target.typeText("127.0.0.1")
        app.buttons["toolbox.roaming.start"].tap()
        let stop = app.buttons["toolbox.roaming.stop"]
        XCTAssertTrue(stop.waitForExistence(timeout: 15))
        let export = app.buttons["toolbox.roaming.export"]
        _ = expectation(for: NSPredicate(format: "enabled == true"), evaluatedWith: export)
        waitForExpectations(timeout: 10)
        stop.tap(); export.tap()
        XCTAssertTrue(app.staticTexts["toolbox.export.filename"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["toolbox.export.share"].exists)
        capture("Roaming export contains filename and share action")
    }
    func testPersonalFilesThreeDotDeleteAndRestorePreservesItsOwnDocumentAndFolder() {
        XCUIDevice.shared.orientation = .landscapeLeft
        openFiles()
        let search = app.searchFields.firstMatch
        if search.waitForExistence(timeout: 5), let value = search.value as? String,
           !value.isEmpty, value != search.placeholderValue {
            search.tap(); search.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: value.count))
        }
        let continuationID = ProcessInfo.processInfo.environment["FLOE_QA_C47_CONTINUE_DOCUMENT"]
        let suffix = continuationID == nil ? String(UUID().uuidString.prefix(8)) : "B7F0DC20"
        let pinnedFolder = ProcessInfo.processInfo.environment["FLOE_QA_C47_EXISTING_EMPTY_FOLDER"]
        if let continuationID {
            XCTAssertEqual(continuationID, "68BEC9CD-602D-4E2D-96CF-4C2C7A34EE3A",
                           "Continuation is limited to the exact verified UI07 synthetic original")
            XCTAssertEqual(pinnedFolder, "C47-Folder-5E917A51")
        }
        let folderName = pinnedFolder ?? "C47-Folder-" + suffix
        let documentName = "C47-Document-" + suffix
        let body = "C47 recoverable original " + suffix
        app.buttons["space.viewOptions"].tap(); app.buttons["列表"].firstMatch.tap()
        if let pinnedFolder {
            // Explicit acceptance fixture, never a retry/fallback. UI04 created
            // this task-owned directory. Under the canonical lock, verify either
            // emptiness or the explicitly selected sole UI07 original before use.
            XCTAssertEqual(pinnedFolder, "C47-Folder-5E917A51",
                           "Only the independently verified task-owned fixture is allowed")
            let root = app.buttons["我的文件"].firstMatch
            XCTAssertTrue(root.waitForExistence(timeout: 10)); root.tap()
            let contract = XCTAttachment(string: continuationID == nil
                ? "C47 uses the verified empty UI04 folder " + pinnedFolder
                    + "; this run does not validate folder creation. The document is newly created through UI."
                : "C47 continues the exact verified UI07 synthetic document in " + pinnedFolder
                    + "; this run verifies its original text before Delete/Restore and does not validate creation.")
            contract.name = "C47 explicit fixture contract"
            contract.lifetime = .keepAlways; add(contract)
        } else {
            // Only new unique samples are touched. Existing QA originals stay intact.
            app.buttons["space.new"].tap(); app.buttons["文件夹"].firstMatch.tap()
            let alert = app.alerts["新建文件夹"]
            XCTAssertTrue(alert.waitForExistence(timeout: 10)); alert.textFields.firstMatch.tap()
            alert.textFields.firstMatch.typeText(folderName)
            // The iPad alert moves when its keyboard appears. Dismiss it through
            // the native control before resolving the final Create button frame.
            if app.keyboards.firstMatch.exists {
                let hideKeyboard = app.buttons["隐藏键盘"].firstMatch
                XCTAssertTrue(hideKeyboard.isHittable); hideKeyboard.tap()
                XCTAssertTrue(app.keyboards.firstMatch.waitForNonExistence(timeout: 10))
            }
            XCTAssertEqual(alert.textFields.firstMatch.value as? String, folderName)
            XCTAssertTrue(alert.buttons["创建"].isHittable)
            alert.buttons["创建"].tap()
            XCTAssertTrue(alert.waitForNonExistence(timeout: 10))
            XCTAssertFalse(app.alerts["未能完成"].exists, "Folder creation must not silently fail")
        }
        let folder = app.buttons["space.folder." + folderName].firstMatch
        if !folder.waitForExistence(timeout: 15) {
            capture("C47 folder creation not visible")
            let hierarchy = XCTAttachment(string: app.debugDescription)
            hierarchy.name = "C47 folder creation accessibility hierarchy"; hierarchy.lifetime = .keepAlways; add(hierarchy)
        }
        XCTAssertTrue(folder.exists, "The created folder must be visible as its actual native button")
        folder.tap()
        let editor = app.textViews["space.document.editor"]
        if let continuationID {
            // The run owner independently verifies this sole folder member,
            // original bytes and record ownership before selecting continuation.
            // Check the exact project through its actual native Files row too.
            let original = app.buttons.matching(identifier: "space.file." + continuationID)
                .containing(.staticText, identifier: documentName).firstMatch
            XCTAssertTrue(original.waitForExistence(timeout: 15)); original.tap()
            XCTAssertTrue(editor.waitForExistence(timeout: 20))
            XCTAssertTrue((editor.value as? String ?? "").contains(body),
                          "The UI07 original must be intact before any deletion")
            closeEditor()
        } else {
            if pinnedFolder != nil {
                XCTAssertTrue(app.staticTexts["还没有文件"].firstMatch.waitForExistence(timeout: 15),
                              "The pinned fixture must still be empty before creating this run's document")
            }
            app.buttons["space.new"].tap(); app.buttons["space.new.document"].tap()
            // UIKit's submenu exports its visible action title, not SwiftUI's
            // identifier (retained in the UI04 failure hierarchy).
            let plainText = app.buttons["纯文本"].firstMatch
            XCTAssertTrue(plainText.waitForExistence(timeout: 10)); plainText.tap()
            let title = app.textFields["space.creation.title"]
            XCTAssertTrue(title.waitForExistence(timeout: 10)); title.tap()
            title.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: (title.value as? String ?? "").count))
            title.typeText(documentName); confirmWorkCreation()
            XCTAssertTrue(editor.waitForExistence(timeout: 20)); editor.tap(); editor.typeText(body)
            closeEditor()
        }
        let documentMenu = app.buttons["更多操作：" + documentName].firstMatch
        XCTAssertTrue(documentMenu.waitForExistence(timeout: 15)); documentMenu.tap()
        // Native menu actions expose their user-visible titles on this SDK.
        let deleteAction = app.buttons["删除"].firstMatch
        XCTAssertTrue(deleteAction.waitForExistence(timeout: 10)); deleteAction.tap()
        let confirmationTitle = app.staticTexts["移到最近删除？"].firstMatch
        XCTAssertTrue(confirmationTitle.waitForExistence(timeout: 10))
        let confirm = app.buttons["删除"].firstMatch
        XCTAssertTrue(confirm.waitForExistence(timeout: 10)); confirm.tap()
        XCTAssertTrue(documentMenu.waitForNonExistence(timeout: 15))
        app.buttons["space.more"].tap(); app.buttons["最近删除"].tap()
        // The restored Files cell remains in the background accessibility tree.
        // Match only the actual Recently Deleted list for removal assertions.
        let trashList = app.collectionViews["space.files.trash.list"]
        XCTAssertTrue(trashList.waitForExistence(timeout: 15))
        let deletedDocument = trashList.cells.containing(.staticText, identifier: documentName).firstMatch
        XCTAssertTrue(deletedDocument.waitForExistence(timeout: 15))
        capture("C47 own document in Recently Deleted")
        deletedDocument.buttons["恢复"].firstMatch.tap()
        XCTAssertTrue(deletedDocument.waitForNonExistence(timeout: 15))
        app.buttons["space.files.recentlyDeleted.done"].tap()
        XCTAssertTrue(documentMenu.waitForExistence(timeout: 15))
        app.buttons.containing(.staticText, identifier: documentName).firstMatch.tap()
        XCTAssertTrue(editor.waitForExistence(timeout: 20))
        XCTAssertTrue((editor.value as? String ?? "").contains(body))
        closeEditor()
        app.buttons["我的文件"].firstMatch.tap()
        let folderMenu = app.buttons["space.folder.menu." + folderName].firstMatch
        XCTAssertTrue(folderMenu.waitForExistence(timeout: 15)); folderMenu.tap()
        XCTAssertTrue(deleteAction.waitForExistence(timeout: 10)); deleteAction.tap()
        XCTAssertTrue(confirmationTitle.waitForExistence(timeout: 10))
        XCTAssertTrue(confirm.waitForExistence(timeout: 10)); confirm.tap()
        XCTAssertTrue(folder.waitForNonExistence(timeout: 15))
        app.buttons["space.more"].tap(); app.buttons["最近删除"].tap()
        XCTAssertTrue(trashList.waitForExistence(timeout: 15))
        let deletedFolder = trashList.cells.containing(.staticText, identifier: folderName).firstMatch
        XCTAssertTrue(deletedFolder.waitForExistence(timeout: 15)); deletedFolder.buttons["恢复"].firstMatch.tap()
        XCTAssertTrue(deletedFolder.waitForNonExistence(timeout: 15))
        app.buttons["space.files.recentlyDeleted.done"].tap()
        XCTAssertTrue(folder.waitForExistence(timeout: 15)); folder.tap()
        XCTAssertTrue(documentMenu.waitForExistence(timeout: 15))
        capture("C47 restored own folder and original document")
    }

    func testQRCodeExportOpensTheActualPNGShareSheet() {
        XCUIDevice.shared.orientation = .landscapeLeft
        openFiles()
        app.segmentedControls["space.sections"].buttons["工具箱"].tap()
        let qr = app.buttons["toolbox.tool.qr"].firstMatch
        let directory = app.scrollViews.containing(.any, identifier: "toolbox.directory").firstMatch
        XCTAssertTrue(directory.waitForExistence(timeout: 15))
        for _ in 0..<6 {
            if qr.exists && qr.isHittable { break }
            directory.swipeUp()
        }
        XCTAssertTrue(qr.waitForExistence(timeout: 3)); XCTAssertTrue(qr.isHittable); qr.tap()
        let input = app.textFields["文本或网址"].firstMatch
        XCTAssertTrue(input.waitForExistence(timeout: 10)); input.tap(); input.typeText("Floe QA 中文二维码")
        app.buttons["生成二维码"].tap()
        XCTAssertTrue(app.images["生成的二维码"].waitForExistence(timeout: 10))
        app.buttons["导出图片"].tap()
        let file = app.staticTexts["toolbox.export.filename"]
        XCTAssertTrue(file.waitForExistence(timeout: 10)); XCTAssertTrue(file.label.lowercased().hasSuffix(".png"))
        XCTAssertTrue(app.buttons["toolbox.export.share"].exists)
        capture("QR export has actual PNG filename and share action")
    }

    func testCADBuildingUsesTheExpandedToolsSheet() {
        XCUIDevice.shared.orientation = .landscapeLeft
        openFiles(); openWorkbench("三维 CAD")
        app.buttons["CADWorkbenchToolsButton"].tap()
        let building = app.buttons["CADBuildingOpen"].firstMatch
        XCTAssertTrue(building.waitForExistence(timeout: 10)); building.tap()
        let bar = app.navigationBars["建筑"]
        XCTAssertTrue(bar.waitForExistence(timeout: 15))
        XCTAssertLessThan(bar.frame.minY, app.windows.firstMatch.frame.height * 0.25)
        XCTAssertTrue(app.buttons["building.addElement"].isHittable)
        capture("Building tools use the full available sheet height")
        bar.buttons.firstMatch.tap(); app.buttons["CADToolsSheetCloseButton"].tap(); closeEditor()
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
        for title in ["文件夹", "文档…", "绘画／图片", "视频", "CAD", "手记", "化学工程"] {
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
        assertPrintUsesAvailableWindow()
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
    private func assertPrintUsesAvailableWindow(file: StaticString = #filePath, line: UInt = #line) {
        let root = app.descendants(matching: .any)["printing.workbench"].firstMatch
        let footer = app.buttons["printing.slice"]
        let window = app.windows.firstMatch.frame, minimumHeight = window.height * 0.8
        let settled = XCTNSPredicateExpectation(predicate: NSPredicate { object, _ in
            guard let element = object as? XCUIElement else { return false }
            return element.exists && element.frame.height >= minimumHeight
                && footer.exists && footer.isHittable && footer.frame.maxY >= window.minY + minimumHeight
        }, object: root)
        let result = XCTWaiter.wait(for: [settled], timeout: 10)
        attachNativeInputObservation(result == .completed ? "layout ready" : "layout timeout")
        capture(result == .completed ? "Print settled workbench and footer" : "Print unresolved workbench or footer")
        XCTAssertEqual(result, .completed,
                       "The print workbench and footer must use the visible window after search dismissal. window=\(app.windows.firstMatch.frame), workbench=\(root.frame), footer=\(footer.frame)",
                       file: file, line: line)
        XCTAssertTrue(footer.isHittable, file: file, line: line)
        XCTAssertGreaterThanOrEqual(footer.frame.maxY, window.minY + minimumHeight, file: file, line: line)
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
        let onboarding = app.descendants(matching: .any)["canvas.onboarding"].firstMatch
        if onboarding.waitForExistence(timeout: 4) {
            capture("Original canvas first-use guidance")
            app.buttons["关闭"].firstMatch.tap()
        }
        capture("Creative blank canvas opened after first-use guidance")
        XCTAssertTrue(app.buttons["canvas.host.actions"].waitForExistence(timeout: 25))
        XCTAssertTrue(app.buttons["space.editor.done"].exists)
        XCTAssertTrue(app.buttons["canvas.tool.select"].waitForExistence(timeout: 10), "Creative must open in the established canvas framework.")
        capture("Creative original canvas framework opened")
        let add = app.buttons["canvas.node.create.bottom"].firstMatch
        XCTAssertTrue(add.exists); add.tap()
        capture("Original canvas insertion menu")
        let text = app.buttons["文本"].firstMatch
        XCTAssertTrue(text.waitForExistence(timeout: 5)); text.tap()
        let body = app.textViews["canvas.node.editor"].firstMatch
        XCTAssertTrue(body.waitForExistence(timeout: 10), "Text nodes must expose their actual body editor.")
        let navigationBottom = app.buttons["space.editor.done"].frame.maxY
        let visibleBody = XCTNSPredicateExpectation(predicate: NSPredicate { object, _ in
            guard let editor = object as? XCUIElement else { return false }
            return editor.exists && editor.isHittable && editor.frame.height >= 120
                && editor.frame.minY >= navigationBottom - 1
        }, object: body)
        XCTAssertEqual(XCTWaiter.wait(for: [visibleBody], timeout: 10), .completed,
                       "Inline text must remain readable below the navigation controls.")
        body.tap(); body.typeText("\n界面检查：正文可以输入。")
        XCTAssertTrue((body.value as? String ?? "").contains("正文可以输入"))
        let keyboard = app.keyboards.firstMatch
        let metrics = "window=\(app.windows.firstMatch.frame); body=\(body.frame); bodyHittable=\(body.isHittable); keyboard=\(keyboard.exists ? String(describing: keyboard.frame) : "remote AX unavailable")"
        let layout = XCTAttachment(string: metrics)
        layout.name = "Original canvas inline body visible frame"; layout.lifetime = .keepAlways; self.add(layout)
        capture("Original canvas text body editor")
        let finish = app.buttons.matching(identifier: "canvas.node.finishEditing").allElementsBoundByIndex.first(where: \.isHittable)
        XCTAssertNotNil(finish); finish?.tap()
        let select = app.buttons["canvas.tool.select"]
        XCTAssertTrue(select.waitForExistence(timeout: 10))
        XCTAssertTrue(select.isHittable, "The original canvas tools return after text editing.")
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
        app.buttons["space.new.cad"].tap()
        app.buttons["二维 CAD"].firstMatch.tap()
        confirmWorkCreation()
        XCTAssertTrue(app.descendants(matching: .any)["CAD2DDraftingBar"].firstMatch.waitForExistence(timeout: 30))
        capture("Native 2D CAD drafting controls")
        let rectangle = app.buttons["矩形"].firstMatch
        XCTAssertTrue(rectangle.waitForExistence(timeout: 10)); rectangle.tap()
        XCTAssertTrue(app.buttons["RectangleTypeMenu"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["RectangleTypeMenu"].label.contains("对角矩形"))
        XCTAssertTrue(app.staticTexts["在对角点之间绘制"].exists)
        XCTAssertTrue(app.staticTexts["约束"].firstMatch.exists)
        XCTAssertFalse(app.staticTexts["Constraints"].exists)
        capture("Localized CAD rectangle and constraint tools")
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
        openWorkbench("三维 CAD")
        app.buttons["cad.manufacturing.open"].tap()
        XCTAssertTrue(app.buttons["cad.manufacturing.printing"].waitForExistence(timeout: 15))
        app.buttons["cad.manufacturing.cutting"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["cad.manufacturing.machine"].firstMatch.waitForExistence(timeout: 15))
        capture("CAD machining starts with machine selection")
        let back = app.navigationBars["切削加工"].buttons.firstMatch
        XCTAssertTrue(back.waitForExistence(timeout: 10)); back.tap()
        let done = app.buttons.matching(NSPredicate(format: "label == %@", "完成")).allElementsBoundByIndex.first(where: \.isHittable)
        XCTAssertNotNil(done); done?.tap()
        app.buttons["CADWorkbenchToolsButton"].tap()
        let building = app.buttons["CADBuildingOpen"].firstMatch
        XCTAssertTrue(building.waitForExistence(timeout: 10)); building.tap()
        XCTAssertTrue(app.descendants(matching: .any)["building.plan.canvas"].firstMatch.waitForExistence(timeout: 15))
        XCTAssertTrue(app.buttons["building.addElement"].exists)
        capture("CAD Tools opens native Building on the same document")
        let buildingBack = app.navigationBars["建筑"].buttons.firstMatch
        XCTAssertTrue(buildingBack.exists); buildingBack.tap()
        app.buttons["CADToolsSheetCloseButton"].tap()
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
    private func openSavedPrintFixture() {
        let search = app.searchFields.firstMatch
        XCTAssertTrue(search.waitForExistence(timeout: 10)); search.tap()
        if let value = search.value as? String, !value.isEmpty, value != search.placeholderValue {
            search.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: value.count))
        }
        search.typeText("QA-Closure-Print-Preview")
        let original = app.buttons["space.file.B9827A3B-1D6A-496D-9591-DF33605FA9B7"].firstMatch
        XCTAssertTrue(original.waitForExistence(timeout: 15), "Find the saved print fixture through the actual Files search.")
        original.tap()
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
        if title == "3D 打印" {
            openSavedPrintFixture(); return
        }
        let menu = app.buttons["space.new"]
        XCTAssertTrue(menu.waitForExistence(timeout: 15)); menu.tap()
        if title == "三维 CAD" {
            app.buttons["space.new.cad"].tap(); app.buttons["三维 CAD"].firstMatch.tap(); confirmWorkCreation(); return
        }
        app.buttons[title].firstMatch.tap(); confirmWorkCreation()
    }
    private func closeEditor() {
        let done = app.buttons["space.editor.done"]
        XCTAssertTrue(done.waitForExistence(timeout: 10)); done.tap()
        XCTAssertTrue(done.waitForNonExistence(timeout: 15))
    }
}
