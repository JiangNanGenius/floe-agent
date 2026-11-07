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
        if name.contains("testMeetingUsesOneNativeAssistantSidebarAndKeepsItsUnsentDraft"),
           ProcessInfo.processInfo.environment["FLOE_QA_ENABLE_MEETING_LAYOUT_OBSERVATION"] == "1" {
            // Logger-only, own-window geometry; no accessibility probe element.
            app.launchArguments.append("--floe-meeting-layout-observation")
        }
        if name.contains("testSavedEngineeringLayoutUsesAvailableHeightAndOwnKeyboard"),
           ProcessInfo.processInfo.environment["FLOE_QA_ENABLE_ENGINEERING_LAYOUT_OBSERVATION"] == "1" {
            app.launchArguments.append("--floe-engineering-layout-observation")
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
    func testPrintNumericKeyboardKeepsFocusedSettingVisibleAndValue() {
        XCUIDevice.shared.orientation = .landscapeLeft
        openFiles(); openSavedPrintFixture(); assertPrintUsesAvailableWindow()
        let field = app.otherElements["printing.layerHeight"].firstMatch.textFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 10)); XCTAssertTrue(field.isHittable)
        guard let original = field.value as? String, !original.isEmpty else {
            XCTFail("Read the saved numeric setting before replacement"); return
        }
        field.tap()
        let done = app.buttons["printing.keyboard.done"].firstMatch
        XCTAssertTrue(done.waitForExistence(timeout: 10)); XCTAssertTrue(done.isHittable)
        // A delete count at an unknown caret did not replace the old string.
        // Require the native Select All action; do not assume a selected range.
        field.press(forDuration: 1)
        let allLabels = NSPredicate(format: "label IN %@", ["全选", "Select All"])
        let button = app.buttons.matching(allLabels).firstMatch
        let selectAll = button.waitForExistence(timeout: 3) ? button : app.menuItems.matching(allLabels).firstMatch
        XCTAssertTrue(selectAll.waitForExistence(timeout: 5)); XCTAssertTrue(selectAll.isHittable); selectAll.tap()
        field.typeText(original)
        // Keep the same numeric/Chinese keyboard transition visible through
        // the existing capture interval before checking the final state.
        capture("C54 numeric setting after input and keyboard layout change")
        let settled = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            field.exists && field.isHittable && done.exists && done.isHittable && (field.value as? String) == original
        }, object: field)
        let result = XCTWaiter.wait(for: [settled], timeout: 10)
        let screenshot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        screenshot.name = "C54 final numeric keyboard and setting"; screenshot.lifetime = .keepAlways; add(screenshot)
        XCTAssertEqual(result, .completed, "The actual final keyboard must keep the original numeric field visible and correctly replaced")
        XCTAssertTrue(field.isHittable); XCTAssertEqual(field.value as? String, original)
        done.tap(); XCTAssertTrue(done.waitForNonExistence(timeout: 10))
        assertPrintUsesAvailableWindow()
        XCTAssertEqual(field.value as? String, original)
        closeEditor()
    }
    func testEngineeringExamplesKeepTheirOwnAnalysisAndSolve() {
        XCUIDevice.shared.orientation = .landscapeLeft
        openFiles()
        let reusedSketch = ProcessInfo.processInfo.environment["FLOE_QA_C55_OWNED_SKETCH_TITLE"]
        let reusedSolid = ProcessInfo.processInfo.environment["FLOE_QA_C55_OWNED_SOLID_TITLE"]
        guard reusedSketch == nil || reusedSolid == nil else {
            XCTFail("Supply exactly one Root-owned sketch or proven positive-extrude fixture"); return
        }
        let fixtureSuffix: String
        if let title = reusedSolid ?? reusedSketch {
            guard title.hasPrefix("三维设计C55-"), title.count <= 160, !title.contains("\n") else {
                XCTFail("Require Root's exact task-owned C55 sketch title and its preserved creation receipt"); return
            }
            fixtureSuffix = String(title.dropFirst("三维设计".count))
            let search = app.searchFields.firstMatch
            XCTAssertTrue(search.waitForExistence(timeout: 10)); search.tap(); search.typeText(title + "\n")
            let rows = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "space.file."))
                .containing(.staticText, identifier: title)
            XCTAssertTrue(rows.firstMatch.waitForExistence(timeout: 15)); XCTAssertEqual(rows.count, 1)
            XCTAssertTrue(rows.firstMatch.isHittable); rows.firstMatch.tap()
        } else {
            app.buttons["space.new"].tap(); app.buttons["space.new.cad"].tap()
            app.buttons["三维 CAD"].firstMatch.tap()
            fixtureSuffix = "C55-" + String(UUID().uuidString.prefix(8))
            confirmWorkCreation(appendTitle: fixtureSuffix)
        }
        let ownership = XCTAttachment(string: "UI-created CAD fixture suffix: " + fixtureSuffix)
        ownership.name = "C55 task-owned fixture"; ownership.lifetime = .keepAlways; add(ownership)
        // A unique, UI-created CAD work is the fixture. Never reuse the M4
        // reporter's document or substitute an empty model for this path.
        let ownBars = app.navigationBars.matching(NSPredicate(format:
            "identifier CONTAINS %@ OR label CONTAINS %@", fixtureSuffix, fixtureSuffix))
        XCTAssertTrue(ownBars.firstMatch.waitForExistence(timeout: 15))
        guard ownBars.count == 1 else { XCTFail("Require the exact newly created CAD title"); return }
        let cadBar = ownBars.element(boundBy: 0)
        let ownedTitle = cadBar.identifier
        let viewport = app.descendants(matching: .any)["CADEditorViewport"].firstMatch
        XCTAssertTrue(viewport.waitForExistence(timeout: 10)); XCTAssertGreaterThan(viewport.frame.width, 200)
        let sketch = app.buttons["SketchGroup"].firstMatch
        XCTAssertTrue(sketch.waitForExistence(timeout: 10))
        XCTAssertGreaterThanOrEqual(sketch.frame.minY, cadBar.frame.maxY - 2,
            "The palette must occupy the real content area below its parent navigation bar")
        XCTAssertLessThanOrEqual(sketch.frame.maxY, viewport.frame.maxY)
        capture("C55 actual CAD palette below parent navigation before sketch")
        guard sketch.isHittable && sketch.isEnabled else { XCTFail("The visible Sketch tool must be tappable"); return }
        if reusedSolid == nil {
        if reusedSketch == nil {
        sketch.tap()
        let rectangle = app.buttons["Rect"].firstMatch
        XCTAssertTrue(rectangle.waitForExistence(timeout: 10))
        guard rectangle.isHittable else { XCTFail("The actual rectangle tool must be visible after opening Sketch"); return }
        rectangle.tap()
        // Origin planes are picked in the native viewport; HistoryPlane IDs
        // refer to user-created construction planes, absent in this new work.
        capture("C55 native sketch plane selection on own CAD fixture")
        viewport.coordinate(withNormalizedOffset: CGVector(dx: 0.65, dy: 0.65)).tap()
        let exitSketch = app.buttons["ExitSketchingButton"].firstMatch
        XCTAssertTrue(exitSketch.waitForExistence(timeout: 10))
        capture("C55 own CAD sketch fixture before drawing")
        viewport.coordinate(withNormalizedOffset: CGVector(dx: 0.4, dy: 0.4)).tap()
        viewport.coordinate(withNormalizedOffset: CGVector(dx: 0.6, dy: 0.6)).tap()
        exitSketch.tap()
        }
        app.buttons["ModifyGroup"].tap()
        let extrude = app.buttons["ExtrudeButton"].firstMatch
        XCTAssertTrue(extrude.waitForExistence(timeout: 10)); XCTAssertTrue(extrude.isEnabled); extrude.tap()
        // Modify arms the tool; it does not choose a profile. The two drawn
        // corners straddle this point, and exiting sketch preserves the camera.
        viewport.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        let end = app.buttons["ExtrudeEndMenu"].firstMatch
        XCTAssertTrue(end.waitForExistence(timeout: 10))
        let distanceLabels = ["距离", "Distance"]
        let distance = app.textFields.matching(NSPredicate(format: "label IN %@ OR placeholderValue IN %@", distanceLabels, distanceLabels)).firstMatch
        XCTAssertTrue(distance.waitForExistence(timeout: 10)); XCTAssertTrue(distance.isHittable)
        XCTAssertEqual(distance.value as? String, "0", "A newly picked profile starts at zero, without a solid")
        distance.tap(); distance.press(forDuration: 1)
        let allLabels = NSPredicate(format: "label IN %@", ["全选", "Select All"])
        let allButton = app.buttons.matching(allLabels).firstMatch
        let selectAll = allButton.waitForExistence(timeout: 3) ? allButton : app.menuItems.matching(allLabels).firstMatch
        XCTAssertTrue(selectAll.waitForExistence(timeout: 5)); XCTAssertTrue(selectAll.isHittable); selectAll.tap()
        distance.typeText("10")
        XCTAssertEqual(distance.value as? String, "10", "Commit an explicit positive distance, not a zero-height cancellation")
        nativeHideKeyboard()
        XCTAssertTrue(end.exists, "Hiding the keyboard must preserve the active extrude until normal Commit")
        capture("C55 selected actual profile with positive distance before native extrude commit")
        let commit = app.buttons.matching(NSPredicate(format: "label == %@", "拉伸"))
            .allElementsBoundByIndex.first(where: { $0.isHittable && $0.identifier != "ExtrudeButton" })
        XCTAssertNotNil(commit); commit?.tap()
        XCTAssertTrue(end.waitForNonExistence(timeout: 20))
        }
        app.buttons["cad.manufacturing.open"].tap()
        app.buttons["cad.manufacturing.cutting"].tap()
        let next = app.buttons["cad.manufacturing.continue"].firstMatch
        XCTAssertTrue(next.waitForExistence(timeout: 30)); XCTAssertTrue(next.isEnabled); next.tap()
        let tools = app.buttons["机床与工程工具"].firstMatch
        revealOwnedCADControl(tools); tools.tap()
        let engineering = app.buttons["research.engineering"].firstMatch
        revealOwnedCADControl(engineering); engineering.tap()
        let kind = app.staticTexts["engineering.analysis.kind"].firstMatch
        XCTAssertTrue(kind.waitForExistence(timeout: 15)); XCTAssertEqual(kind.label, "分析类型、线弹性静力")
        func showEngineeringPage(_ title: String) {
            let pages = app.segmentedControls["engineering.pages"].firstMatch
            if pages.exists {
                let page = pages.buttons[title]
                XCTAssertTrue(page.exists); page.tap()
            } else {
                // Form/List decorative IDs can be flattened by SwiftUI.
                // Verify the real settings field and visible results heading.
                let name = app.textFields["engineering.name"].firstMatch
                let resultHeading = app.staticTexts.matching(NSPredicate(format: "label == %@", "结果"))
                    .allElementsBoundByIndex.first(where: { $0.isHittable })
                XCTAssertTrue(name.exists && name.isHittable)
                XCTAssertGreaterThan(name.frame.width, 200)
                XCTAssertNotNil(resultHeading)
                if let resultHeading { XCTAssertGreaterThan(resultHeading.frame.minX, name.frame.maxX) }
            }
        }
        for thermal in [false, true, false] {
            showEngineeringPage("设置")
            let button = app.buttons[thermal ? "engineering.example.thermal" : "engineering.example.static"].firstMatch
            XCTAssertTrue(button.isHittable); button.tap()
            XCTAssertEqual(kind.label, thermal ? "分析类型、稳态导热" : "分析类型、线弹性静力")
            app.buttons["engineering.solve"].tap()
            let resultTitle = app.staticTexts[thermal ? "导热结果" : "静力结果"].firstMatch
            XCTAssertTrue(resultTitle.waitForExistence(timeout: 30))
            XCTAssertFalse(app.staticTexts[thermal ? "静力结果" : "导热结果"].exists)
            if thermal {
                XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "20 °C")).firstMatch.exists)
                XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "80 °C")).firstMatch.exists)
            } else {
                XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "最大位移")).firstMatch.exists)
                XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "最大等效应力")).firstMatch.exists)
            }
            capture(thermal ? "C55 actual thermal solve" : "C55 actual static solve")
        }
        app.buttons["engineering.file"].tap(); app.buttons["保存结果"].firstMatch.tap()
        XCTAssertTrue(app.staticTexts["已保存分析"].waitForExistence(timeout: 10))
        app.navigationBars["材料与工程分析"].buttons["完成"].tap()
        XCTAssertTrue(engineering.waitForExistence(timeout: 10)); engineering.tap()
        showEngineeringPage("结果")
        XCTAssertTrue(app.staticTexts["尚无分析结果"].waitForExistence(timeout: 10))
        let openSaved = app.buttons["engineering.savedResult.open"].firstMatch
        XCTAssertTrue(openSaved.waitForExistence(timeout: 10)); XCTAssertTrue(openSaved.isHittable)
        openSaved.tap()
        XCTAssertTrue(app.staticTexts["分析已加载"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["静力结果"].exists)
        XCTAssertFalse(app.staticTexts["导热结果"].exists)
        capture("C55 saved static result reopens from actual archive")
        app.navigationBars["材料与工程分析"].buttons["完成"].tap()
        FileHandle.standardOutput.write(Data(("FLOE_QA_SUCCESSFUL_OWNED_CAD|" + ownedTitle + "\n").utf8))
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

    /// Cancel-only coverage of the two real workspace deletion menus. Root
    /// verifies the supplied project UUID/bookmark and
    /// synthetic source bytes/hash before running; no task or fixture is made.
    func testOwnedProjectSearchAndPreviewDeletionCanBeCancelled() {
        let inputs = ProcessInfo.processInfo.environment
        guard let rawID = inputs["FLOE_QA_C47_OWNED_PROJECT_ID"],
              let projectID = UUID(uuidString: rawID), rawID.uppercased() == projectID.uuidString,
              let path = inputs["FLOE_QA_C47_WORKSPACE_RELATIVE_PATH"],
              !path.isEmpty, path.count <= 1024, !path.hasPrefix("/"), !path.hasPrefix("~"),
              !path.contains("\\"), !path.contains("\n"), !path.contains("\r"), !path.contains("\0"),
              path.split(separator: "/", omittingEmptySubsequences: false)
                .allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else {
            XCTFail("Require Root's exact owned project UUID and relative source path; no task, fixture or first-row fallback")
            return
        }
        XCUIDevice.shared.orientation = .landscapeLeft
        let projectRowID = "files.workspace." + projectID.uuidString
        let filename = (path as NSString).lastPathComponent
        let menuID = "fileTree.search.menu." + path
        func tap(_ control: XCUIElement) -> Bool {
            guard control.exists, control.isHittable else { XCTFail("C47 project control must be visible and hittable"); return false }
            control.tap(); return true
        }
        func button(_ id: String, labels: [String] = []) -> XCUIElement? {
            let identified = app.buttons.matching(identifier: id)
            if identified.firstMatch.waitForExistence(timeout: 3) {
                guard identified.count == 1 else { XCTFail("Ambiguous C47 project control: " + id); return nil }
                return identified.firstMatch
            }
            guard !labels.isEmpty else { XCTFail("Missing C47 project control: " + id); return nil }
            let native = app.buttons.matching(NSPredicate(format: "label IN %@", labels))
            guard native.firstMatch.waitForExistence(timeout: 5), native.count == 1 else {
                XCTFail("Require the unique native C47 project action: " + id); return nil
            }
            return native.firstMatch
        }
        func searchSource() -> Bool {
            let query = app.textFields.matching(NSPredicate(format: "label IN %@",
                ["搜索文件名与文本内容", "Search filenames and text contents", "inspector.search.placeholder"]))
            guard query.firstMatch.waitForExistence(timeout: 15), query.count == 1, tap(query.firstMatch) else {
                XCTFail("Require this managed project's native file-search field"); return false
            }
            let field = query.firstMatch
            let old = field.value as? String ?? ""
            if !old.isEmpty && !["搜索文件名与文本内容", "Search filenames and text contents"].contains(old) {
                field.press(forDuration: 1)
                let labels = NSPredicate(format: "label IN %@", ["全选", "Select All"])
                let native = app.buttons.matching(labels).firstMatch
                let all = native.waitForExistence(timeout: 2) ? native : app.menuItems.matching(labels).firstMatch
                guard all.waitForExistence(timeout: 5), tap(all) else { XCTFail("Require native Select All for the search query"); return false }
                field.typeText(XCUIKeyboardKey.delete.rawValue)
            }
            field.typeText(path)
            guard field.value as? String == path else { XCTFail("Search must use the frozen relative path"); return false }
            nativeHideKeyboard(); return true
        }
        func sourceRow() -> XCUIElement? {
            let rows = app.cells.containing(.staticText, identifier: path)
            guard rows.firstMatch.waitForExistence(timeout: 20), rows.count == 1 else {
                XCTFail("Require exactly one filename hit for the owned project source"); return nil
            }
            return rows.firstMatch
        }

        // Use the normal existing manager, whose independent WorkspaceCenter
        // opens the real record behind this exact UUID NavigationLink. Duplicate
        // display names never select a different project or a private task.
        openFiles()
        guard let more = button("space.more"), tap(more),
              let locations = button("C47.native.otherLocations", labels: ["浏览其他位置…", "Browse other locations…"]), tap(locations) else { return }
        let allWorkspaces = app.navigationBars.matching(NSPredicate(format: "identifier IN %@", ["所有工作区", "All workspaces"]))
        guard allWorkspaces.firstMatch.waitForExistence(timeout: 15), allWorkspaces.count == 1 else {
            XCTFail("Open the actual All Workspaces file manager"); return
        }
        let filters = app.segmentedControls.containing(.button, identifier: "项目")
        guard filters.count == 1, tap(filters.firstMatch.buttons["项目"]) else {
            XCTFail("Require the native project filter, not private chat workspaces"); return
        }
        let projectButtons = app.buttons.matching(identifier: projectRowID)
        var projectRow: XCUIElement?
        if projectButtons.firstMatch.waitForExistence(timeout: 5) {
            guard projectButtons.count == 1 else { XCTFail("Ambiguous exact project UUID button"); return }
            projectRow = projectButtons.firstMatch
        } else {
            // Native List may surface its NavigationLink as the cell itself.
            // This is still the exact record UUID, never a label/first row.
            let cells = app.cells.matching(identifier: projectRowID)
            guard cells.firstMatch.waitForExistence(timeout: 10), cells.count == 1 else {
                XCTFail("Require the exact Root-owned project UUID row; duplicate names are not a fallback"); return
            }
            projectRow = cells.firstMatch
        }
        guard let projectRow, tap(projectRow), searchSource(), let original = sourceRow() else {
            XCTFail("Require the exact UUID's managed FileTree and its frozen relative source"); return
        }
        let idMenu = app.buttons.matching(identifier: menuID)
        let nativeMenu = original.buttons.matching(NSPredicate(format: "label IN %@", ["更多", "More"]))
        let menus = idMenu.count > 0 ? idMenu : nativeMenu
        guard menus.count == 1, tap(menus.firstMatch),
              let remove = button("fileTree.row.delete", labels: ["删除", "Delete"]), tap(remove) else {
            XCTFail("Require Delete from the exact source's search-hit More menu"); return
        }
        let confirm = app.alerts.matching(NSPredicate(format: "label IN %@", ["确认删除？", "Confirm deletion?"])).firstMatch
        guard confirm.waitForExistence(timeout: 15),
              confirm.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", filename)).firstMatch.exists else {
            XCTFail("Search deletion must show the real guarded confirmation for the owned filename"); return
        }
        capture("C47 owned project search More shows Delete confirmation")
        let cancels = confirm.buttons.matching(NSPredicate(format: "label IN %@", ["取消", "Cancel"]))
        guard cancels.count == 1, tap(cancels.firstMatch), confirm.waitForNonExistence(timeout: 10),
              let retained = sourceRow() else { XCTFail("Search Cancel must preserve the same source"); return }
        let open = retained.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", path))
        guard open.count == 1, tap(open.firstMatch),
              app.buttons["workspace.preview.backToFiles"].waitForExistence(timeout: 15),
              let previewMore = button("file.preview.more", labels: ["更多", "More"]), tap(previewMore),
              let previewDelete = button("file.preview.delete", labels: ["删除", "Delete"]), tap(previewDelete) else {
            XCTFail("Open the real standalone managed FilePreview for the same project source"); return
        }
        let message = app.staticTexts.matching(NSPredicate(format:
            "label CONTAINS %@ AND (label CONTAINS %@ OR label CONTAINS %@)",
            filename, "将从当前工作区删除", "will be deleted from this workspace")).firstMatch
        guard message.waitForExistence(timeout: 15) else {
            XCTFail("Preview Delete must show its own guarded confirmation; an ownership/save error is not success"); return
        }
        capture("C47 owned project standalone preview shows Delete confirmation")
        // Bind cancellation to the confirmation containing THIS file's
        // message. A background editor/menu may also expose Cancel.
        let title = NSPredicate(format: "label IN %@", ["删除文件？", "Delete file?"])
        let sheets = app.sheets.containing(.staticText, identifier: message.label).matching(title)
        let alerts = app.alerts.containing(.staticText, identifier: message.label).matching(title)
        guard sheets.count + alerts.count == 1 else {
            XCTFail("Require one actual confirmation containing the frozen source message"); return
        }
        let fileConfirmation = sheets.count == 1 ? sheets.firstMatch : alerts.firstMatch
        let cancelButtons = fileConfirmation.buttons.matching(NSPredicate(format: "label IN %@", ["取消", "Cancel"]))
        if cancelButtons.count == 1 {
            guard tap(cancelButtons.firstMatch) else { return }
        } else if cancelButtons.count == 0 {
            // UI19: iPad's native confirmation popover omits a Cancel row.
            // Its own native outside-dismiss region performs cancellation.
            let popovers = app.descendants(matching: .popover).containing(.staticText, identifier: message.label)
            let dismissers = app.otherElements.matching(identifier: "PopoverDismissRegion")
            guard popovers.count == 1, app.descendants(matching: .popover).count == 1,
                  dismissers.count == 1, dismissers.firstMatch.isHittable else {
                XCTFail("Require this sole file-confirmation popover's native dismissal region"); return
            }
            let region = dismissers.firstMatch
            let outside = CGPoint(x: region.frame.midX, y: region.frame.midY)
            guard region.frame.width > 0, region.frame.height > 0,
                  !popovers.firstMatch.frame.insetBy(dx: -12, dy: -12).contains(outside) else {
                XCTFail("Native cancellation point must remain safely outside the destructive popover"); return
            }
            region.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        } else {
            XCTFail("Ambiguous Cancel inside the owned file confirmation"); return
        }
        guard fileConfirmation.waitForNonExistence(timeout: 10),
              message.waitForNonExistence(timeout: 10),
              let back = button("workspace.preview.backToFiles"), tap(back), searchSource(),
              let restored = sourceRow() else { XCTFail("Preview Cancel must return to the same existing project source"); return }
        XCTAssertTrue(restored.isHittable)
        capture("C47 both workspace Delete confirmations cancelled; original source still listed")
        FileHandle.standardOutput.write(Data("FLOE_QA_C47_PROJECT_CANCELS|passed\n".utf8))
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

    func testToolboxMQTTAndWebSocketEmptyInputsShowFieldErrorsWithoutConnecting() {
        XCUIDevice.shared.orientation = .landscapeLeft
        openFiles()
        app.segmentedControls["space.sections"].buttons["工具箱"].tap()
        openToolboxDirectoryTool("mqtt")
        let address = app.textFields["toolbox.address"].firstMatch
        let port = app.textFields["toolbox.port"].firstMatch
        XCTAssertTrue(address.waitForExistence(timeout: 10));XCTAssertTrue(port.exists)
        // The actual setup defaults both fields to empty. Refuse a restored
        // endpoint rather than clearing it or risking a real connection.
        XCTAssertTrue((address.value as? String ?? "").isEmpty || address.value as? String == address.placeholderValue)
        XCTAssertTrue((port.value as? String ?? "").isEmpty || port.value as? String == port.placeholderValue)
        app.buttons["toolbox.connect"].tap()
        let addressError = app.descendants(matching: .any).matching(identifier: "toolbox.address.error").firstMatch
        let portError = app.descendants(matching: .any).matching(identifier: "toolbox.port.error").firstMatch
        XCTAssertTrue(addressError.waitForExistence(timeout: 10));XCTAssertTrue(portError.exists)
        XCTAssertTrue(addressError.label.contains("请输入") && addressError.label.contains("地址"))
        XCTAssertTrue(portError.label.contains("端口") && portError.label.contains("1–65535"))
        XCTAssertFalse(addressError.label.contains("权限"));XCTAssertFalse(portError.label.contains("权限"))
        XCTAssertFalse(app.descendants(matching: .any).matching(identifier: "toolbox.connection.error").firstMatch.exists)
        XCTAssertFalse(app.buttons["toolbox.assistant"].exists);XCTAssertFalse(app.buttons["断开"].exists)
        XCTAssertEqual(app.alerts.count, 0)
        capture("C62 MQTT empty hostname and port show red field errors")

        let back = app.navigationBars.buttons["工具箱"].firstMatch
        XCTAssertTrue(back.waitForExistence(timeout: 10));back.tap()
        openToolboxDirectoryTool("webSocket")
        let url = app.textFields["toolbox.address"].firstMatch
        XCTAssertTrue(url.waitForExistence(timeout: 10))
        XCTAssertTrue((url.value as? String ?? "").isEmpty || url.value as? String == url.placeholderValue)
        XCTAssertFalse(app.textFields["toolbox.port"].exists,"WebSocket embeds an optional port in its URL; it has no separate required-port field")
        app.buttons["toolbox.connect"].tap()
        let urlError = app.descendants(matching: .any).matching(identifier: "toolbox.address.error").firstMatch
        XCTAssertTrue(urlError.waitForExistence(timeout: 10))
        XCTAssertTrue(urlError.label.contains("WebSocket") && urlError.label.contains("ws://"))
        XCTAssertFalse(urlError.label.contains("权限"))
        XCTAssertFalse(app.descendants(matching: .any).matching(identifier: "toolbox.port.error").firstMatch.exists)
        XCTAssertFalse(app.descendants(matching: .any).matching(identifier: "toolbox.connection.error").firstMatch.exists)
        XCTAssertFalse(app.buttons["toolbox.assistant"].exists);XCTAssertFalse(app.buttons["断开"].exists)
        XCTAssertEqual(app.alerts.count, 0)
        capture("C62 WebSocket empty URL shows red address feedback without connection")
    }

    func testMeetingUsesOneNativeAssistantSidebarAndKeepsItsUnsentDraft() {
        XCUIDevice.shared.orientation = .landscapeLeft
        let suffix = String(UUID().uuidString.prefix(8)),title = "QA-C63-OneAssistant-" + suffix
        let draft = "C63 unsent draft " + suffix
        openFiles()
        if let ownedTitle = ProcessInfo.processInfo.environment["FLOE_QA_C63_OWNED_MEETING_TITLE"] {
            guard ownedTitle.hasPrefix("QA-C63-OneAssistant-"), ownedTitle.count <= 160, !ownedTitle.contains("\n") else {
                XCTFail("Require Root's exact task-owned meeting title and preserved creation receipt"); return
            }
            app.segmentedControls["space.sections"].buttons["手记"].tap()
            let search = app.textFields["notes.search"].firstMatch
            XCTAssertTrue(search.waitForExistence(timeout: 10)); search.tap(); search.typeText(ownedTitle + "\n")
            let rows = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "notes.meeting."))
                .containing(.staticText, identifier: ownedTitle)
            XCTAssertTrue(rows.firstMatch.waitForExistence(timeout: 15)); XCTAssertEqual(rows.count, 1)
            XCTAssertTrue(rows.firstMatch.isHittable); rows.firstMatch.tap()
            XCTAssertTrue(app.navigationBars[ownedTitle].waitForExistence(timeout: 20))
        } else { createMeetingFixture(title: title) }
        let notebook = app.otherElements["meeting.personalNotes"].firstMatch
        XCTAssertTrue(notebook.waitForExistence(timeout: 20))
        let topAssistant = app.buttons["space.editor.assistant"].firstMatch
        XCTAssertTrue(topAssistant.waitForExistence(timeout: 10));topAssistant.tap()
        let tabs = app.segmentedControls.containing(.button, identifier: "会议助手").firstMatch
        XCTAssertTrue(tabs.waitForExistence(timeout: 15))
        for label in ["转写", "重点", "会议助手"] { XCTAssertTrue(tabs.buttons[label].exists) }
        XCTAssertEqual(tabs.buttons.count, 3,"The native sidebar selects transcript/highlights/one assistant, not a question/write mode")

        func assertOneAssistantAndNotebook() {
            let sidebar = app.descendants(matching: .any).matching(identifier: "meeting.assistant").firstMatch
            let composers = app.textViews.matching(identifier: "composer.input")
            XCTAssertTrue(sidebar.waitForExistence(timeout: 15))
            XCTAssertTrue(composers.firstMatch.waitForExistence(timeout: 20));XCTAssertEqual(composers.count, 1)
            let evidence = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
            evidence.name = "C63 actual notebook and one assistant before geometry assertions"; evidence.lifetime = .keepAlways; add(evidence)
            XCTAssertTrue(notebook.exists && notebook.isHittable,"The current notebook stays visible beside the assistant, without a covering modal")
            let window = app.windows.firstMatch.frame
            XCTAssertGreaterThan(notebook.frame.width, window.width * 0.30)
            XCTAssertGreaterThan(notebook.frame.height, window.height * 0.50,"The recorder must not consume the notebook's working height")
            XCTAssertGreaterThan(sidebar.frame.height, window.height * 0.50)
            XCTAssertLessThanOrEqual(notebook.frame.maxX, sidebar.frame.minX + 4)
            XCTAssertGreaterThanOrEqual(composers.firstMatch.frame.minX, sidebar.frame.minX - 4)
            XCTAssertLessThanOrEqual(composers.firstMatch.frame.maxX, sidebar.frame.maxX + 4)
            XCTAssertTrue(composers.firstMatch.isHittable)
            // The native safe-area inset flattens its decorative AX wrapper.
            // Check the actual recording control and bottom placement instead.
            let record = app.buttons["meeting.record"].firstMatch
            XCTAssertTrue(record.exists && record.isHittable)
            XCTAssertLessThan(record.frame.height, window.height * 0.20)
            // The compound notebook AX frame includes its clipped canvas.
            // Verify that the real input control stays above recording instead.
            XCTAssertGreaterThanOrEqual(record.frame.minY, composers.firstMatch.frame.maxY - 4)
            XCTAssertGreaterThan(record.frame.midY, window.maxY - window.height * 0.15)
            XCTAssertLessThanOrEqual(record.frame.maxY, window.maxY)
        }
        assertOneAssistantAndNotebook()
        let composer = app.textViews["composer.input"].firstMatch
        let previousDraft = composer.value as? String ?? ""
        composer.tap()
        if !previousDraft.isEmpty {
            guard let ownedTitle = ProcessInfo.processInfo.environment["FLOE_QA_C63_OWNED_MEETING_TITLE"],
                  ownedTitle.hasPrefix("QA-C63-OneAssistant-"), app.navigationBars[ownedTitle].exists,
                  previousDraft.range(of: "^C63 unsent draft [A-F0-9]{8}$", options: .regularExpression) == (previousDraft.startIndex..<previousDraft.endIndex) else {
                XCTFail("Preserve unrelated composer content; only the exact owned C63 fixture draft may be replaced"); return
            }
            composer.press(forDuration: 1)
            let labels = NSPredicate(format: "label IN %@", ["全选", "Select All"])
            let allButton = app.buttons.matching(labels).firstMatch
            let selectAll = allButton.waitForExistence(timeout: 3) ? allButton : app.menuItems.matching(labels).firstMatch
            XCTAssertTrue(selectAll.waitForExistence(timeout: 5)); XCTAssertTrue(selectAll.isHittable); selectAll.tap()
        }
        composer.typeText(draft) // No newline, Send, cloud, recording or playback.
        XCTAssertEqual(composer.value as? String, draft)
        let pencil = notebook.descendants(matching: .any).matching(identifier: "notes.pencil.page").firstMatch
        let assistant = app.descendants(matching: .any).matching(identifier: "meeting.assistant").firstMatch
        let messages = assistant.scrollViews["thread.messages.viewport"].firstMatch
        let keyboard = app.keyboards.firstMatch
        let window = app.windows.firstMatch.frame
        let keyboardContent = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            guard keyboard.exists, pencil.exists, messages.exists, composer.isHittable else { return false }
            let visible = CGRect(x: window.minX, y: window.minY, width: window.width,
                                 height: max(0, keyboard.frame.minY - window.minY))
            return pencil.frame.intersection(notebook.frame).intersection(visible).height >= 120
                && messages.frame.intersection(assistant.frame).intersection(visible).height >= 72
                && (composer.value as? String) == draft
        }, object: composer)
        let contentSettled = XCTWaiter.wait(for: [keyboardContent], timeout: 10)
        capture("C63 keyboard with actual notebook page and message viewport visible")
        XCTAssertEqual(contentSettled, .completed, "The keyboard must leave readable notebook content and conversation, not only chrome")
        XCTAssertTrue(app.buttons["notes.compact.tools"].firstMatch.isHittable)
        XCTAssertTrue(app.buttons["meeting.compact.sections"].firstMatch.isHittable)
        nativeHideKeyboard()
        capture("C63 one native meeting assistant beside the current notebook")
        tabs.buttons["转写"].tap()
        XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "meeting.transcript").firstMatch.waitForExistence(timeout: 10))
        XCTAssertTrue(notebook.isHittable)
        tabs.buttons["会议助手"].tap()
        assertOneAssistantAndNotebook()
        let returned = app.textViews["composer.input"].firstMatch
        let retained = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", draft), object: returned)
        XCTAssertEqual(XCTWaiter.wait(for: [retained], timeout: 10), .completed)
        // The top editor entry and the sidebar tab return to the same native
        // assistant. Neither opens another conversation surface or mode.
        tabs.buttons["转写"].tap();topAssistant.tap()
        assertOneAssistantAndNotebook()
        let topReturned = app.textViews["composer.input"].firstMatch
        let sameDraft = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", draft), object: topReturned)
        XCTAssertEqual(XCTWaiter.wait(for: [sameDraft], timeout: 10), .completed)
        tabs.buttons["转写"].tap()
        let notebookAssistant = app.buttons["notes.assistant"].firstMatch
        XCTAssertTrue(notebookAssistant.exists && notebookAssistant.isHittable); notebookAssistant.tap()
        assertOneAssistantAndNotebook()
        let notebookReturned = app.textViews["composer.input"].firstMatch
        let notebookDraft = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", draft), object: notebookReturned)
        XCTAssertEqual(XCTWaiter.wait(for: [notebookDraft], timeout: 10), .completed)
        capture("C63 sidebar and top entry retain one unsent meeting draft")
        closeEditor()
    }

    /// Reuses only Root's already solved/saved owned CAD; never calls Calculate.
    func testSavedEngineeringLayoutUsesAvailableHeightAndOwnKeyboard() {
        guard let ownedTitle = ProcessInfo.processInfo.environment["FLOE_QA_OWNED_CAD_TITLE"],
              ownedTitle.hasPrefix("三维设计C55-"), ownedTitle.count <= 160, !ownedTitle.contains("\n") else {
            XCTFail("Require the exact Root-owned C55 success fixture title; no new CAD or solver fallback"); return
        }
        XCUIDevice.shared.orientation = .landscapeLeft
        openFiles()
        let search = app.searchFields.firstMatch
        XCTAssertTrue(search.waitForExistence(timeout:10));search.tap()
        if let old = search.value as? String, !old.isEmpty, old != search.placeholderValue {
            search.press(forDuration:1)
            let labels = NSPredicate(format:"label IN %@",["全选","Select All"])
            let button = app.buttons.matching(labels).firstMatch
            let all = button.waitForExistence(timeout:3) ? button : app.menuItems.matching(labels).firstMatch
            XCTAssertTrue(all.waitForExistence(timeout:5));XCTAssertTrue(all.isHittable);all.tap()
        }
        search.typeText(ownedTitle);nativeHideKeyboard();XCTAssertEqual(search.value as? String,ownedTitle)
        let rows = app.buttons.matching(NSPredicate(format:"identifier BEGINSWITH %@","space.file."))
            .containing(.staticText,identifier:ownedTitle)
        XCTAssertTrue(rows.firstMatch.waitForExistence(timeout:15));XCTAssertEqual(rows.count,1)
        guard rows.count == 1 else { return };rows.firstMatch.tap()
        XCTAssertTrue(app.navigationBars[ownedTitle].waitForExistence(timeout:20))
        app.buttons["cad.manufacturing.open"].tap();app.buttons["cad.manufacturing.cutting"].tap()
        let next = app.buttons["cad.manufacturing.continue"].firstMatch
        XCTAssertTrue(next.waitForExistence(timeout:30));XCTAssertTrue(next.isEnabled);next.tap()
        let tools = app.buttons["机床与工程工具"].firstMatch
        revealOwnedCADControl(tools);tools.tap()
        let engineering = app.buttons["research.engineering"].firstMatch
        revealOwnedCADControl(engineering);engineering.tap()
        let saved = app.buttons["engineering.savedResult.open"].firstMatch
        XCTAssertTrue(saved.waitForExistence(timeout:15));saved.tap()
        let heading = app.staticTexts["静力结果"].firstMatch
        XCTAssertTrue(heading.waitForExistence(timeout:15))
        let name = app.textFields["engineering.name"].firstMatch
        let settings = app.collectionViews.containing(.textField,identifier:"engineering.name").firstMatch
        let results = app.collectionViews.containing(.staticText,identifier:"静力结果").firstMatch
        let window = app.windows.firstMatch.frame
        let fullHeight = NSPredicate { _,_ in
            settings.exists && results.exists && name.exists && heading.exists
                && settings.frame.height > window.height * 0.55 && results.frame.height > window.height * 0.55
                && name.frame.maxX < heading.frame.minX
        }
        let opened = XCTNSPredicateExpectation(predicate:fullHeight,object:name)
        let openResult = XCTWaiter.wait(for:[opened],timeout:10)
        capture("Engineering saved static result actual Form and List full height")
        XCTAssertEqual(openResult,.completed,"The real native Form/List must use the available window, not a flattened decorative AX identifier")
        guard let originalName = name.value as? String,!originalName.isEmpty else { XCTFail("Read the saved name before focus-only input check");return }
        name.tap() // Focus only: no setter, input edit, new solve or saved-file write.
        let keyboard = app.keyboards.firstMatch
        let focused = XCTNSPredicateExpectation(predicate:NSPredicate { _,_ in
            keyboard.exists && name.isHittable && name.frame.maxY <= keyboard.frame.minY
        },object:name)
        let focusResult = XCTWaiter.wait(for:[focused],timeout:10)
        capture("Engineering actual name field above its own keyboard")
        XCTAssertEqual(focusResult,.completed);XCTAssertEqual(name.value as? String,originalName)
        nativeHideKeyboard()
        let restored = XCTNSPredicateExpectation(predicate:fullHeight,object:name)
        let restoreResult = XCTWaiter.wait(for:[restored],timeout:10)
        capture("Engineering saved result full height restored after keyboard hide")
        XCTAssertEqual(restoreResult,.completed);XCTAssertEqual(name.value as? String,originalName)
        app.buttons["engineering.done"].tap()
    }

    func testOwnedCADBuildingMeshStockAndResearchMenuContinuation() {
        guard let ownedTitle = ProcessInfo.processInfo.environment["FLOE_QA_OWNED_CAD_TITLE"],
              !ownedTitle.isEmpty, ownedTitle == ownedTitle.trimmingCharacters(in: .whitespacesAndNewlines),
              ownedTitle.count <= 160, ownedTitle.contains("C55-"), !ownedTitle.contains("\n") else {
            XCTFail("Require Root's exact unique title from the successful C55 task-owned CAD receipt in FLOE_QA_OWNED_CAD_TITLE; no new CAD or first-row fallback")
            return
        }
        XCUIDevice.shared.orientation = .landscapeLeft
        openFiles()
        let search = app.searchFields.firstMatch
        XCTAssertTrue(search.waitForExistence(timeout: 10));search.tap()
        if let value = search.value as? String, !value.isEmpty, value != search.placeholderValue {
            search.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: value.count))
        }
        search.typeText(ownedTitle);nativeHideKeyboard();XCTAssertEqual(search.value as? String, ownedTitle)
        let exact = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "space.file."))
            .containing(.staticText, identifier: ownedTitle)
        XCTAssertTrue(exact.firstMatch.waitForExistence(timeout: 15))
        guard exact.count == 1 else { XCTFail("The supplied owned title must match exactly one actual file row");return }
        exact.element(boundBy: 0).tap()
        let cadTitle = app.navigationBars[ownedTitle]
        XCTAssertTrue(cadTitle.waitForExistence(timeout: 25), "Verify the exact opened native CAD title")
        let cadViewport = app.descendants(matching: .any).matching(identifier: "CADEditorViewport").firstMatch
        XCTAssertTrue(cadViewport.waitForExistence(timeout: 15));XCTAssertTrue(cadViewport.isHittable)
        let receipt = XCTAttachment(string: "Continuation uses only Root-supplied successful C55 CAD: " + ownedTitle
            + "\nNo CAD creation, Apply, calculation, mesh conversion, sculpt or model edit is requested.")
        receipt.name = "Owned CAD menu continuation fixture";receipt.lifetime = .keepAlways;add(receipt)
        FileHandle.standardOutput.write(Data(("FLOE_QA_OWNED_CAD_CONTINUATION|" + ownedTitle + "\n").utf8))
        app.buttons["cad.manufacturing.open"].tap();app.buttons["cad.manufacturing.cutting"].tap()
        let next = app.buttons["cad.manufacturing.continue"].firstMatch
        XCTAssertTrue(next.waitForExistence(timeout: 30));XCTAssertTrue(next.isEnabled);next.tap()
        let stockOpen = app.buttons["study.stock"].firstMatch
        XCTAssertTrue(stockOpen.waitForExistence(timeout: 15));stockOpen.tap()
        let stock = app.otherElements["stock.inspector"].firstMatch
        let preview = app.descendants(matching: .any).matching(identifier: "manufacturing.viewport").firstMatch
        assertOwnedInspectorBesideViewport(stock, viewport: preview)
        let sampling = app.textFields["采样单元边长"].firstMatch
        XCTAssertTrue(sampling.waitForExistence(timeout: 10))
        guard let originalSampling = sampling.value as? String, !originalSampling.isEmpty else {
            XCTFail("Read the actual current stock field before editing its unsaved draft");return
        }
        sampling.tap();sampling.typeText(originalSampling == "1" ? "2" : "1");nativeHideKeyboard()
        guard let draftSampling = sampling.value as? String, draftSampling != originalSampling else {
            XCTFail("The stock draft must actually change before testing Hide/Cancel");return
        }
        capture("Owned CAD Stock edited draft beside live preview without Apply")
        let hide = app.buttons["stock.hide"].firstMatch
        XCTAssertTrue(hide.waitForExistence(timeout: 10));hide.tap()
        XCTAssertTrue(app.buttons["stock.cancel"].waitForNonExistence(timeout: 10));XCTAssertTrue(preview.isHittable)
        stockOpen.tap();XCTAssertTrue(app.buttons["stock.cancel"].waitForExistence(timeout: 10))
        XCTAssertEqual(app.textFields["采样单元边长"].firstMatch.value as? String, draftSampling)
        assertOwnedInspectorBesideViewport(app.otherElements["stock.inspector"].firstMatch, viewport: preview)
        capture("Owned CAD Stock Hide and reopen retain unapplied draft")
        app.buttons["stock.cancel"].tap()
        XCTAssertTrue(app.buttons["stock.cancel"].waitForNonExistence(timeout: 10));stockOpen.tap()
        XCTAssertTrue(app.buttons["stock.cancel"].waitForExistence(timeout: 10))
        XCTAssertEqual(app.textFields["采样单元边长"].firstMatch.value as? String, originalSampling)
        capture("Owned CAD Stock Cancel restores original sampling")
        app.buttons["stock.cancel"].tap()
        let tools = app.buttons["机床与工程工具"].firstMatch
        revealOwnedCADControl(tools);tools.tap()
        for kind in ["virtual", "cell"] {
            let entry = app.buttons["research." + kind].firstMatch
            revealOwnedCADControl(entry);entry.tap()
            let title = kind == "virtual" ? "虚拟机床配置" : "多主轴与多刀塔"
            let done = app.buttons[kind + ".done"].firstMatch
            XCTAssertTrue(done.waitForExistence(timeout: 15));XCTAssertTrue(done.isHittable)
            XCTAssertTrue(app.buttons[kind + ".calculate"].exists) // Observe only; never calculate.
            let bar = app.navigationBars[title]
            XCTAssertTrue(bar.exists);XCTAssertLessThan(bar.frame.minY, app.windows.firstMatch.frame.height * 0.25)
            if kind == "virtual" {
                // Inspect the real native page before asserting; a containing
                // GeometryReader can replace a descendant's decorative ID.
                capture("Owned CAD virtual page before native replay and drive controls")
                let pageControls = XCTAttachment(string: String(app.segmentedControls.debugDescription.prefix(8000)))
                pageControls.name = "Virtual native segmented controls"; pageControls.lifetime = .keepAlways; add(pageControls)
                let pages = app.segmentedControls.containing(.button, identifier: "三维回放").firstMatch
                XCTAssertTrue(pages.waitForExistence(timeout: 10))
                let compact = pages.buttons["设置"].exists
                if compact { pages.buttons["设置"].tap() }
                let radiusTitle = "主轴箱半径 · mm"
                let radius = app.textFields.matching(NSPredicate(format: "label == %@", radiusTitle)).firstMatch
                XCTAssertTrue(radius.waitForExistence(timeout: 10));XCTAssertTrue(radius.isHittable)
                for caption in [radiusTitle, "主轴箱长度 · mm", "卡盘半径 · mm", "卡盘长度 · mm"] {
                    let label = app.staticTexts.matching(NSPredicate(format: "label == %@", caption)).firstMatch
                    XCTAssertTrue(label.exists, "The parameter name and unit must remain visible beside its value")
                }
                if compact { pages.buttons["三维回放"].tap() }
                let emptyReplay = app.staticTexts.matching(NSPredicate(format: "label == %@", "准备虚拟机床")).firstMatch
                let replayTime = app.sliders.matching(NSPredicate(format: "label == %@", "回放时间")).firstMatch
                let replayReady = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
                    emptyReplay.exists || replayTime.exists
                }, object: pages)
                XCTAssertEqual(XCTWaiter.wait(for: [replayReady], timeout: 10), .completed,
                    "The actual empty replay or real replay slider must be present without calculating")
                let replay = emptyReplay.exists ? emptyReplay : replayTime
                if !compact { XCTAssertLessThanOrEqual(radius.frame.maxX, replay.frame.minX + 4) }
                capture("Owned CAD virtual real labelled parameters beside actual replay content")
                pages.buttons["驱动估算"].tap()
                let drive = app.staticTexts.matching(NSPredicate(format: "label == %@",
                    "尚无驱动估算。可在设置中加入显式参数。")).firstMatch
                XCTAssertTrue(drive.waitForExistence(timeout: 10), "Observe the actual Drive estimate page without calculating")
                if !compact {
                    XCTAssertTrue(radius.exists && radius.isHittable)
                    XCTAssertLessThanOrEqual(radius.frame.maxX, drive.frame.minX + 4)
                }
                capture("Owned CAD virtual real drive empty state without calculation")
            } else {
                let pages = app.segmentedControls.containing(.button, identifier: "通道与排程").firstMatch
                XCTAssertTrue(pages.exists)
                if pages.buttons["设置"].exists {
                    pages.buttons["设置"].tap();XCTAssertTrue(app.textFields["名称"].firstMatch.exists)
                } else {
                    let name = app.textFields["名称"].firstMatch
                    XCTAssertTrue(name.exists && name.isHittable);XCTAssertLessThanOrEqual(name.frame.maxX, pages.frame.minX + 4)
                }
                pages.buttons["结果"].tap();XCTAssertTrue(app.buttons["cell.calculate"].exists)
                let result = app.staticTexts.matching(NSPredicate(format: "label == %@ OR label == %@ OR label == %@",
                    "尚无结果", "已保存结果尚未打开", "保存的结果暂不可用")).firstMatch
                XCTAssertTrue(result.waitForExistence(timeout: 10), "The actual Results surface opens without calculating")
                if !pages.buttons["设置"].exists {
                    XCTAssertLessThanOrEqual(app.textFields["名称"].firstMatch.frame.maxX, result.frame.minX + 4)
                }
            }
            capture("Owned CAD " + kind + " native parameters and results without recalculation")
            nativeOwnedCADBack(from: title, parentTitle: "加工预览")
            XCTAssertTrue(preview.waitForExistence(timeout: 10));XCTAssertTrue(preview.isHittable)
            revealOwnedCADControl(entry);entry.tap()
            XCTAssertTrue(done.waitForExistence(timeout: 10));done.tap()
            XCTAssertTrue(done.waitForNonExistence(timeout: 10));XCTAssertTrue(preview.exists)
        }
        // The same Done ID also exists on the covered original CAD. Scope it
        // to the current full-screen preview, then require an operable parent.
        let previewBar = app.navigationBars["加工预览"]
        let machiningDone = previewBar.buttons["space.editor.done"].firstMatch
        let closeReady = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            machiningDone.exists && machiningDone.isHittable
        }, object: machiningDone)
        XCTAssertEqual(XCTWaiter.wait(for: [closeReady], timeout: 10), .completed)
        machiningDone.tap()
        let cuttingReady = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            !previewBar.exists && next.exists && next.isHittable
        }, object: next)
        XCTAssertEqual(XCTWaiter.wait(for: [cuttingReady], timeout: 15), .completed,
            "The preview must close; an existing control underneath it is not a returned page")
        nativeOwnedCADBack(from: "切削加工", parentTitle: "加工")
        let manufacture = app.navigationBars["加工"]
        let homeDone = manufacture.buttons["完成"].firstMatch
        let homeReady = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            homeDone.exists && homeDone.isHittable && !next.isHittable
        }, object: homeDone)
        XCTAssertEqual(XCTWaiter.wait(for: [homeReady], timeout: 10), .completed);homeDone.tap()
        let originalReady = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            cadTitle.exists && cadViewport.exists && cadViewport.isHittable
                && self.app.buttons["CADWorkbenchToolsButton"].isHittable
        }, object: cadViewport)
        XCTAssertEqual(XCTWaiter.wait(for: [originalReady], timeout: 15), .completed)
        inspectOwnedCADBuildingAndMesh(ownedTitle: ownedTitle, viewport: cadViewport)
    }

    /// UI19 already exercised Stock, Virtual and Cell. This continuation opens
    /// only Root's existing owned CAD and does not repeat those flows.
    func testOwnedCADBuildingAndMeshOnlyContinuation() {
        guard let ownedTitle = ProcessInfo.processInfo.environment["FLOE_QA_OWNED_CAD_TITLE"],
              ownedTitle.range(of: "^三维设计C55-[A-F0-9]{8}$", options: .regularExpression) != nil else {
            XCTFail("Require the exact Root-owned C55 native CAD title; no new or first-row fixture fallback");return
        }
        XCUIDevice.shared.orientation = .landscapeLeft
        openFiles()
        let search = app.searchFields.firstMatch
        XCTAssertTrue(search.waitForExistence(timeout: 10));search.tap()
        if let old = search.value as? String, !old.isEmpty, old != search.placeholderValue, old != ownedTitle {
            search.press(forDuration: 1)
            let labels = NSPredicate(format: "label IN %@", ["全选", "Select All"])
            let button = app.buttons.matching(labels).firstMatch
            let selectAll = button.waitForExistence(timeout: 3) ? button : app.menuItems.matching(labels).firstMatch
            XCTAssertTrue(selectAll.waitForExistence(timeout: 5));XCTAssertTrue(selectAll.isHittable);selectAll.tap()
        }
        if search.value as? String != ownedTitle { search.typeText(ownedTitle) }
        nativeHideKeyboard();XCTAssertEqual(search.value as? String, ownedTitle)
        let rows = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "space.file."))
            .containing(.staticText, identifier: ownedTitle)
        XCTAssertTrue(rows.firstMatch.waitForExistence(timeout: 15))
        guard rows.count == 1 else { XCTFail("Require exactly one actual owned CAD file row");return }
        XCTAssertTrue(rows.firstMatch.isHittable);rows.firstMatch.tap()
        let title = app.navigationBars[ownedTitle]
        let viewport = app.descendants(matching: .any).matching(identifier: "CADEditorViewport").firstMatch
        let tools = app.buttons["CADWorkbenchToolsButton"]
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            title.exists && viewport.exists && viewport.isHittable && viewport.frame.width > 200
                && tools.exists && tools.isHittable && self.app.buttons["cad.manufacturing.open"].isHittable
        }, object: viewport)
        XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 25), .completed,
            "Require the exact current native CAD and operable viewport, not a covered editor")
        capture("Owned CAD native title and operable viewport before Building and Mesh only")
        inspectOwnedCADBuildingAndMesh(ownedTitle: ownedTitle, viewport: viewport)
    }

    private func inspectOwnedCADBuildingAndMesh(ownedTitle: String, viewport cadViewport: XCUIElement) {
        let cadTitle = app.navigationBars[ownedTitle]
        XCTAssertTrue(cadTitle.exists && cadViewport.isHittable)
        app.buttons["CADWorkbenchToolsButton"].tap()
        let building = app.buttons["CADBuildingOpen"].firstMatch
        revealOwnedCADControl(building, scrollIdentifier: "CADWorkbenchToolsScroll");building.tap()
        XCTAssertTrue(app.buttons["building.addElement"].waitForExistence(timeout: 15));XCTAssertTrue(app.buttons["CADBuildingSave"].exists)
        XCTAssertFalse(app.buttons["CADToolsSheetCloseButton"].exists,"Building is a native child after closing the tools sheet")
        capture("Owned CAD Building full child page with genuine Back")
        nativeOwnedCADBack(from: "建筑", parentTitle: ownedTitle)
        XCTAssertTrue(cadTitle.waitForExistence(timeout: 10));XCTAssertTrue(cadViewport.isHittable)
        let beforeMesh = cadViewport.frame
        app.buttons["CADWorkbenchToolsButton"].tap()
        let meshTab = app.segmentedControls.containing(.button, identifier: "网格").firstMatch.buttons["网格"]
        XCTAssertTrue(meshTab.waitForExistence(timeout: 10));meshTab.tap()
        let meshCloseButtons = app.buttons.matching(identifier: "CADMeshInspectorClose")
        let meshClose = meshCloseButtons.firstMatch
        XCTAssertTrue(meshClose.waitForExistence(timeout: 15));XCTAssertTrue(meshClose.isHittable)
        XCTAssertEqual(meshCloseButtons.count, 1, "Require the one current native Mesh inspector")
        XCTAssertTrue(cadViewport.exists && cadViewport.isHittable);XCTAssertGreaterThan(cadViewport.frame.width, 200)
        // UI20's native recording shows two columns, while the Metal viewport
        // AX node keeps its fullbleed frame. It cannot measure visible width.
        XCTAssertTrue(app.windows.firstMatch.frame.contains(meshClose.frame), "The actual inspector close must be inside the visible app window")
        XCTAssertTrue(cadTitle.exists);XCTAssertTrue(app.buttons["cad.manufacturing.open"].isHittable)
        capture("Owned CAD Mesh inspector beside original viewport without conversion or sculpt")
        meshClose.tap();XCTAssertTrue(meshClose.waitForNonExistence(timeout: 10))
        XCTAssertTrue(cadViewport.isHittable);XCTAssertGreaterThanOrEqual(cadViewport.frame.width, beforeMesh.width - 4)
        XCTAssertTrue(cadTitle.exists);capture("Owned CAD Mesh return restores original viewport")
        let done = cadTitle.buttons["space.editor.done"].firstMatch
        XCTAssertTrue(done.exists && done.isHittable);done.tap()
        XCTAssertTrue(cadTitle.waitForNonExistence(timeout: 15))
    }
    private func assertOwnedInspectorBesideViewport(_ inspector: XCUIElement, viewport: XCUIElement) {
        XCTAssertTrue(inspector.waitForExistence(timeout: 10));XCTAssertTrue(viewport.waitForExistence(timeout: 10))
        XCTAssertTrue(viewport.isHittable);XCTAssertGreaterThan(viewport.frame.width, 200);XCTAssertGreaterThan(inspector.frame.width, 280)
        XCTAssertLessThanOrEqual(viewport.frame.maxX, inspector.frame.minX + 4)
    }
    private func revealOwnedCADControl(_ element: XCUIElement, scrollIdentifier: String? = nil) {
        for _ in 0..<8 {
            if element.exists && element.isHittable { break }
            if let scrollIdentifier {
                let scroll = app.scrollViews[scrollIdentifier].firstMatch
                XCTAssertTrue(scroll.exists);scroll.swipeUp()
            } else {
                let sidebar = app.descendants(matching: .any).matching(identifier: "manufacturing.sidebar").firstMatch
                XCTAssertTrue(sidebar.waitForExistence(timeout: 5)); sidebar.swipeUp()
            }
        }
        XCTAssertTrue(element.waitForExistence(timeout: 3));XCTAssertTrue(element.isHittable)
    }
    private func nativeOwnedCADBack(from title: String, parentTitle: String) {
        let bar = app.navigationBars[title]
        XCTAssertTrue(bar.waitForExistence(timeout: 10))
        let back = bar.buttons.allElementsBoundByIndex.first { button in
            button.identifier == "BackButton" || button.label == parentTitle || button.label == "返回" || button.label == "Back"
        }
        XCTAssertNotNil(back,"Require genuine native Back; Done is not a fallback");back?.tap()
    }

    private func openToolboxDirectoryTool(_ rawValue: String) {
        let tool = app.buttons["toolbox.tool." + rawValue].firstMatch
        let directory = app.scrollViews.containing(.any, identifier: "toolbox.directory").firstMatch
        XCTAssertTrue(directory.waitForExistence(timeout: 15))
        for _ in 0..<6 {
            if tool.exists && tool.isHittable { break }
            directory.swipeUp()
        }
        XCTAssertTrue(tool.waitForExistence(timeout: 3));XCTAssertTrue(tool.isHittable);tool.tap()
    }
    private func nativeHideKeyboard() {
        guard app.keyboards.firstMatch.exists else { return }
        let hide = app.buttons["隐藏键盘"].firstMatch
        XCTAssertTrue(hide.waitForExistence(timeout: 5));XCTAssertTrue(hide.isHittable);hide.tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForNonExistence(timeout: 10))
    }
    private func createMeetingFixture(title: String) {
        app.segmentedControls["space.sections"].buttons["手记"].tap()
        let create = app.buttons["notes.create"].firstMatch
        XCTAssertTrue(create.waitForExistence(timeout: 15));create.tap()
        app.buttons["notes.create.meeting"].tap()
        let name = app.textFields["notes.create.title"].firstMatch
        XCTAssertTrue(name.waitForExistence(timeout: 10))
        XCTAssertTrue((name.value as? String ?? "").isEmpty || name.value as? String == name.placeholderValue)
        name.tap();name.typeText(title);XCTAssertEqual(name.value as? String, title)
        nativeHideKeyboard()
        app.buttons["创建"].firstMatch.tap()
        XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "meeting.workbench").firstMatch.waitForExistence(timeout: 25))
        XCTAssertTrue(app.buttons["space.editor.done"].waitForExistence(timeout: 15))
        let receipt = XCTAttachment(string: "C63 uniquely created native meeting: " + title + "\nRoute: Notes > New > Meeting notes. No message was sent, no recording/playback was started.")
        receipt.name = "C63 unique task-owned meeting fixture";receipt.lifetime = .keepAlways;add(receipt)
        FileHandle.standardOutput.write(Data(("FLOE_QA_C63_FIXTURE|" + title + "\n").utf8))
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
        confirmWorkCreation(appendTitle: " QA-N10-" + UUID().uuidString.prefix(8))
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
        app.buttons["新建结构绘图"].firstMatch.tap()
        XCTAssertTrue(app.otherElements["chemistry.nativeCanvas"].firstMatch.waitForExistence(timeout: 20))
        let eraser = app.buttons["chemistry.drawing.eraser"].firstMatch
        XCTAssertTrue(eraser.waitForExistence(timeout: 10))
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate(format: "enabled == true"), object: eraser)
        XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 10), .completed)
        eraser.tap()
        let finger = app.descendants(matching: .any)["chemistry.drawing.fingerDrawing"].firstMatch
        XCTAssertTrue(finger.waitForExistence(timeout: 5)); XCTAssertTrue(finger.isHittable)
        let drewWithFinger = app.staticTexts["手指绘图"].exists
        finger.tap()
        XCTAssertTrue(app.staticTexts[drewWithFinger ? "手指平移" : "手指绘图"].waitForExistence(timeout: 5))
        finger.tap()
        capture("Chemistry native eraser and explicit touch drawing control")
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
    func testCanvasUsesOneMoreMenuAndKeepsItsNativeActionsAndFormats() {
        XCUIDevice.shared.orientation = .landscapeLeft
        let creative = app.collectionViews["sidebar.list"].cells.containing(.staticText, identifier: "sidebar.creative").firstMatch
        XCTAssertTrue(creative.waitForExistence(timeout: 25));creative.tap()
        let create = app.buttons["canvas.home.create"].firstMatch
        XCTAssertTrue(create.waitForExistence(timeout: 20));create.tap()
        let blank = app.buttons["canvas.start.blank"].firstMatch
        XCTAssertTrue(blank.waitForExistence(timeout: 15));blank.tap()
        let onboarding = app.descendants(matching: .any)["canvas.onboarding"].firstMatch
        if onboarding.waitForExistence(timeout: 4) { app.buttons["关闭"].firstMatch.tap() }
        // A fresh blank uses the existing framework and has no selection or
        // graph. Only inspect menus; never add/edit a node or run a workflow.
        XCTAssertTrue(app.buttons["canvas.tool.select"].waitForExistence(timeout: 20))
        app.buttons["canvas.tool.select"].tap()
        XCTAssertTrue(app.buttons["canvas.node.create.bottom"].exists)
        XCTAssertTrue(app.buttons["space.editor.done"].exists)
        let moreButtons = app.buttons.matching(identifier: "canvas.more")
        XCTAssertTrue(moreButtons.firstMatch.waitForExistence(timeout: 20));XCTAssertEqual(moreButtons.count, 1)
        let more = moreButtons.firstMatch
        XCTAssertTrue(more.isHittable);XCTAssertGreaterThan(more.frame.midX, app.windows.firstMatch.frame.width * 0.6)
        XCTAssertFalse(app.buttons["canvas.host.actions"].exists,"The module must not add a second top-right ellipsis")
        capture("Canvas original framework has one top-right More menu")
        let fixture = XCTAttachment(string: "Fresh blank created through Creative > Canvas > Blank; no nodes, selection, imported media, edits or flow run. Menu inspection only.")
        fixture.name = "Canvas More menu no-selection fixture";fixture.lifetime = .keepAlways;add(fixture)

        func expectMenuLabel(_ title: String) {
            let item = app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", title)).firstMatch
            XCTAssertTrue(item.waitForExistence(timeout: 5), "The current no-selection menu must retain: " + title)
        }
        more.tap()
        for title in ["画布与编辑", "同步此画布", "画布背景", "外观", "显示缩略导航", "设计流程", "画布入门", "自动整理关系图"] {
            expectMenuLabel(title)
        }
        for title in ["素材与流程", "导入素材", "引用资料或作品", "加入场景与流程", "从目标生成初稿", "存为我的流程", "添加流程步骤", "询问选区"] {
            expectMenuLabel(title)
        }
        let export = app.buttons["canvas.export"].firstMatch
        XCTAssertTrue(export.waitForExistence(timeout: 5))
        XCTAssertEqual(app.buttons.matching(identifier: "canvas.export").count, 1)
        XCTAssertEqual(app.buttons.matching(NSPredicate(format: "label == %@", "导出")).count, 1,
                       "The hosted native and old export entries must be one submenu")
        capture("Canvas one More groups original editor and media-workflow actions")
        XCTAssertTrue(export.waitForExistence(timeout: 5));export.tap()
        for title in ["原生画布工程", "Obsidian Canvas", "Excalidraw", "draw.io", "PDF", "SVG", "PNG", "画布 JSON（不含素材）"] {
            expectMenuLabel(title)
        }
        capture("Canvas single Export retains all seven formats plus snapshot JSON")
        // No export button is tapped. No file, share sheet, cloud, recording,
        // assistant send or workflow execution is requested by this test.
        // Dismiss at the far-left window margin, outside the right-hand menu;
        // never tap the centre of a menu or one of its export actions.
        app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.01, dy: 0.50)).tap()
        XCTAssertTrue(app.buttons["canvas.tool.select"].isHittable)
        XCTAssertEqual(app.buttons.matching(identifier: "canvas.more").count, 1)
        XCTAssertFalse(app.buttons["canvas.host.actions"].exists)
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
    func test2DCADOffersPlanarNavigationAndDrawingInputControls() {
        XCUIDevice.shared.orientation = .landscapeLeft
        openFiles()
        app.buttons["space.new"].tap()
        app.buttons["space.new.cad"].tap()
        app.buttons["二维 CAD"].firstMatch.tap()
        confirmWorkCreation(appendTitle: " QA-N17-" + UUID().uuidString.prefix(8))
        XCTAssertTrue(app.descendants(matching: .any)["CAD2DDraftingBar"].firstMatch.waitForExistence(timeout: 30))
        XCTAssertTrue(app.buttons["CADFingerDrawingToggle"].firstMatch.exists)
        let views = app.buttons["ViewsMenu"].firstMatch
        XCTAssertTrue(views.waitForExistence(timeout: 10)); XCTAssertTrue(views.isHittable); views.tap()
        let plane = app.buttons["CAD2DDrawingPlane"].firstMatch
        XCTAssertTrue(plane.waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["Front"].exists)
        XCTAssertFalse(app.buttons["Right"].exists)
        XCTAssertFalse(app.switches["Orthographic"].exists)
        plane.tap()
        XCTAssertTrue(app.descendants(matching: .any)["CAD2DDraftingBar"].firstMatch.exists)
        capture("2D CAD uses the drawing plane and keeps its editing controls")
        closeEditor()
    }

    func testNextRoundSpaceBiologyAndFileSelectionUseTheExistingWorkspace() {
        XCUIDevice.shared.orientation = .landscapeLeft
        openFiles()
        app.segmentedControls["space.sections"].buttons["概览"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["space.quickEntries"].firstMatch.waitForExistence(timeout: 15))
        XCTAssertTrue(app.descendants(matching: .any)["space.workbenches"].firstMatch.exists)
        capture("Space horizontal quick access and grouped workbenches")
        app.segmentedControls["space.sections"].buttons["文件"].tap()
        XCTAssertTrue(app.buttons["space.viewOptions"].waitForExistence(timeout: 10))
        app.buttons["space.new"].tap()
        let biology = app.buttons["生物工程"].firstMatch
        XCTAssertTrue(biology.waitForExistence(timeout: 10)); biology.tap()
        let title = app.textFields["space.creation.title"]
        XCTAssertTrue(title.waitForExistence(timeout: 10))
        let originalTitle = title.value as? String ?? ""
        let suffix = " QA-N02-" + UUID().uuidString.prefix(8)
        let createdTitle = originalTitle + suffix
        confirmWorkCreation(appendTitle: suffix)
        XCTAssertTrue(app.descendants(matching: .any)["biology.personalEditor"].firstMatch.waitForExistence(timeout: 25))
        for id in ["biology.add", "biology.analysis", "biology.export", "biology.more"] {
            XCTAssertTrue(app.buttons[id].firstMatch.exists)
        }
        app.buttons["biology.add"].firstMatch.tap()
        let sample = app.buttons["序列比较 · 合成示例"].firstMatch
        XCTAssertTrue(sample.waitForExistence(timeout: 10)); sample.tap()
        XCTAssertTrue(app.descendants(matching: .any)["biology.sequenceViewport"].firstMatch.waitForExistence(timeout: 20))
        app.buttons["biology.analysis"].firstMatch.tap()
        XCTAssertTrue(app.buttons["biology.run"].firstMatch.waitForExistence(timeout: 10))
        capture("Actual Biology original with sequence data and analysis controls")
        closeEditor()
        // The default name sort can put this record outside the lazy list's
        // loaded rows. Search the unique fixture through the actual Files UI.
        let search = app.searchFields.firstMatch
        XCTAssertTrue(search.waitForExistence(timeout: 10)); search.tap(); search.typeText(suffix)
        // The native file button combines its title and subtitle for AX.
        let row = app.buttons.matching(NSPredicate(format:
            "identifier BEGINSWITH %@ AND label CONTAINS %@ AND NOT label BEGINSWITH %@",
            "space.file.", createdTitle, "更多操作：")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 15)); row.press(forDuration: 1)
        let select = app.buttons["选择"].firstMatch
        XCTAssertTrue(select.waitForExistence(timeout: 10)); select.tap()
        let remove = app.buttons["space.files.batchDelete"]
        XCTAssertTrue(remove.waitForExistence(timeout: 10)); XCTAssertTrue(remove.isEnabled)
        XCTAssertTrue(app.buttons["space.files.selectAll"].exists)
        XCTAssertTrue(app.buttons["space.files.cancelSelection"].exists)
        capture("Files long press selection and batch actions")
        // Only this newly created, uniquely titled fixture is removed.
        remove.tap()
        XCTAssertTrue(app.staticTexts["将所选项目移到最近删除？"].firstMatch.waitForExistence(timeout: 10))
        app.buttons["删除"].firstMatch.tap()
        XCTAssertTrue(row.waitForNonExistence(timeout: 15))
        app.buttons["space.more"].tap()
        XCTAssertTrue(app.buttons["导入…"].firstMatch.waitForExistence(timeout: 10))
        capture("Import lives in the Files More menu")
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
            // The naming sheet moves when its keyboard opens. Use the real
            // iPad keyboard control before resolving the confirmation target.
            if app.keyboards.firstMatch.exists {
                let hide = app.buttons["隐藏键盘"].firstMatch
                XCTAssertTrue(hide.waitForExistence(timeout: 5)); XCTAssertTrue(hide.isHittable); hide.tap()
                XCTAssertTrue(app.keyboards.firstMatch.waitForNonExistence(timeout: 10))
            }
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
