// SPDX-License-Identifier: MPL-2.0
import XCTest

@MainActor final class NativeAnswerRenderingUITests:XCTestCase {
    private let app=XCUIApplication(bundleIdentifier:"org.floeagent.ios")
    override func setUpWithError() throws { continueAfterFailure=false;XCUIDevice.shared.orientation = .landscapeLeft }
    override func tearDownWithError() throws { app.terminate();XCUIDevice.shared.orientation = .portrait }
    override func record(_ issue:XCTIssue) {
        // XCTest calls this synchronous override outside the test actor.
        // Use its direct screenshot attachment API, as in NativeWorkflowsUITests.
        let attachment=XCTAttachment(screenshot:XCUIScreen.main.screenshot())
        attachment.name="Native answer issue";attachment.lifetime = .keepAlways
        add(attachment);super.record(issue)
    }
    private func capture(_ title:String) {
        let a=XCTAttachment(screenshot:XCUIScreen.main.screenshot());a.name=title;a.lifetime = .keepAlways;add(a)
    }
    private func launch(_ mode:String) {
        app.terminate()
        app.launchArguments=["-AppleLanguages","(zh-Hans)","-AppleLocale","zh_CN","-ui-testing","-ui-testing-ipad","--ui-test-skip-onboarding","--ui-test-native-answer-fixture",mode]
        app.launch()
        XCTAssertTrue(app.staticTexts["正文后段：内容显示在这两段之间。"].firstMatch.waitForExistence(timeout:35))
    }
    private func visible(_ id:String)->XCUIElement {
        let elements=app.descendants(matching:.any).matching(identifier:id)
        XCTAssertTrue(elements.firstMatch.waitForExistence(timeout:15),id)
        return elements.allElementsBoundByIndex.last(where:{$0.isHittable}) ?? elements.firstMatch
    }
    private func button(_ id:String)->XCUIElement {
        let elements=app.buttons.matching(identifier:id)
        XCTAssertTrue(elements.firstMatch.waitForExistence(timeout:15),id)
        return elements.allElementsBoundByIndex.last(where:{$0.isHittable}) ?? elements.firstMatch
    }
    private func labelled(_ text:String)->XCUIElement {
        let elements=app.descendants(matching:.any).matching(NSPredicate(format:"label == %@",text))
        XCTAssertTrue(elements.firstMatch.waitForExistence(timeout:15),text)
        return elements.allElementsBoundByIndex.last(where:{$0.isHittable}) ?? elements.firstMatch
    }
    private func namedButton(_ text:String)->XCUIElement {
        let elements=app.buttons.matching(NSPredicate(format:"label == %@",text))
        XCTAssertTrue(elements.firstMatch.waitForExistence(timeout:15),text)
        return elements.allElementsBoundByIndex.last(where:{$0.isHittable}) ?? elements.firstMatch
    }
    func testSixChartFamiliesRenderInsideTheSavedAnswer() {
        for mode in ["line","histogram","candlestick","treemap","sankey","gantt"] {
            launch(mode)
            let canvas=visible("chart.canvas")
            XCTAssertGreaterThan(canvas.frame.width,120);XCTAssertGreaterThan(canvas.frame.height,120)
            // Native virtual-group IDs are forwarded by SwiftUI. Verify the
            // actual plot's place in the persisted reply, not those groups.
            let before=app.staticTexts["正文前段：以下是已保存的本地内容。"].firstMatch
            let after=app.staticTexts["正文后段：内容显示在这两段之间。"].firstMatch
            XCTAssertTrue(before.exists && after.exists)
            XCTAssertLessThanOrEqual(before.frame.maxY,canvas.frame.minY)
            XCTAssertLessThanOrEqual(canvas.frame.maxY,after.frame.minY)
            XCTAssertEqual(canvas.label,"QA "+mode)
            capture("Saved answer native chart "+mode)
        }
        // Reopen the last fixture WITHOUT reseeding: the same saved receipt
        // must resolve through normal history and display its actual chart.
        app.terminate();app.launchArguments=["-AppleLanguages","(zh-Hans)","-AppleLocale","zh_CN","-ui-testing","-ui-testing-ipad","--ui-test-skip-onboarding"];app.launch()
        let row=app.descendants(matching:.any)["sidebar.conversation.95B20771-2CC4-4B96-9FCA-9437BC412A10"].firstMatch
        let sidebar=app.collectionViews["sidebar.list"].firstMatch
        XCTAssertTrue(sidebar.waitForExistence(timeout:15))
        // Existing projects can fill the sidebar before its conversation
        // section. Scroll the actual list; never reseed this saved reply.
        for _ in 0..<18 {
            if row.exists && row.isHittable { break }
            sidebar.swipeUp(velocity:.fast)
        }
        XCTAssertTrue(row.exists && row.isHittable);row.tap()
        XCTAssertTrue(app.descendants(matching:.any)["chart.canvas"].firstMatch.waitForExistence(timeout:20))
        capture("Saved native chart reopened through ordinary history")
    }
    func testNativeChartValuesFiltersZoomFullScreenAndExportActions() {
        launch("line")
        let original=button("chart.fit").value as? String
        button("chart.zoomIn").tap()
        XCTAssertNotEqual(button("chart.fit").value as? String,original)
        button("chart.fit").tap()
        button("chart.values").tap()
        XCTAssertTrue(app.navigationBars["数值"].waitForExistence(timeout:10))
        XCTAssertGreaterThan(app.cells.count,0);capture("Native chart actual values")
        app.navigationBars["数值"].buttons["完成"].tap()
        button("chart.filter").tap()
        XCTAssertTrue(app.navigationBars["筛选图表"].waitForExistence(timeout:10))
        let toggles=app.switches;XCTAssertGreaterThan(toggles.count,0)
        if toggles.count>0 { toggles.firstMatch.tap() }
        app.navigationBars["筛选图表"].buttons["完成"].tap()
        button("chart.fullScreen").tap()
        XCTAssertTrue(app.navigationBars["QA line"].waitForExistence(timeout:10))
        let expanded=visible("chart.canvas")
        XCTAssertGreaterThan(expanded.frame.height,300)
        capture("Native chart full screen after filter")
        button("chart.export").tap()
        XCTAssertTrue(app.buttons["图片（当前视图）"].waitForExistence(timeout:10))
        XCTAssertTrue(app.buttons["PDF（当前视图）"].exists)
        XCTAssertTrue(app.buttons["JSON（原始数据）"].exists)
        capture("Native chart original data and image PDF export actions")
        app.buttons["PDF（当前视图）"].tap()
        // The real FileDocument exporter must reach the system destination UI;
        // no unrelated user folder or cloud destination is written by QA.
        let save=app.buttons["存储"].firstMatch
        let saveCurrent=app.buttons["保存"].firstMatch
        let export=app.buttons["导出"].firstMatch
        XCTAssertTrue(saveCurrent.waitForExistence(timeout:15) || save.exists || export.exists)
        capture("Native PDF document reaches the system destination picker")
    }
    func testNativeDiffSmallRowsLargeSummaryAndBoundedScroll() {
        launch("small-diff")
        let smallLines=labelled("修改明细")
        XCTAssertTrue(smallLines.isHittable)
        XCTAssertFalse(app.buttons["展开差异"].exists)
        let lastSmall=app.descendants(matching:.any).matching(NSPredicate(format:"label CONTAINS %@ OR value == %@","new3","new3"))
        let visibleMessages=app.scrollViews["thread.messages.viewport"].frame.intersection(app.windows.firstMatch.frame)
        XCTAssertTrue(lastSmall.allElementsBoundByIndex.contains(where:{
            $0.frame.width > 0 && $0.frame.height > 0 && $0.frame.intersects(visibleMessages) && $0.isHittable
        }),"All five actual changes, including the final new line, must be visible")
        capture("Five changed lines directly in the saved answer")
        namedButton("打开完整差异").tap()
        XCTAssertTrue(app.navigationBars["文件差异"].waitForExistence(timeout:10))
        capture("Numbered native diff full view")
        app.navigationBars["文件差异"].buttons["完成"].tap()
        launch("large-diff")
        XCTAssertTrue(namedButton("展开差异").exists)
        let expand=namedButton("展开差异")
        // ViewThatFits can omit the virtual header node from AX even though
        // its actual labels/buttons are visible. Bind the duplicate cards by
        // the already selected expand action, then measure their real controls.
        let screen=app.windows.firstMatch.frame
        func nearestHeaderItem(_ label:String)->XCUIElement? {
            app.descendants(matching:.any).matching(NSPredicate(format:"label == %@",label))
                .allElementsBoundByIndex.filter { node in
                    node.frame.height > 0 && node.frame.intersects(screen) && node.isHittable
                }.min { abs($0.frame.midY-expand.frame.midY) < abs($1.frame.midY-expand.frame.midY) }
        }
        let file=nearestHeaderItem("answer-preview.txt")
        let added=nearestHeaderItem("新增80行")
        let removed=nearestHeaderItem("删除80行")
        let openFull=nearestHeaderItem("打开完整差异")
        XCTAssertNotNil(file,"The selected card must show its actual file name.")
        XCTAssertNotNil(added);XCTAssertNotNil(removed);XCTAssertNotNil(openFull)
        guard let file,let added,let removed,let openFull else { return }
        let header=[file,added,removed,expand,openFull].map(\.frame)
            .reduce(CGRect.null) { $0.union($1) }
        XCTAssertLessThanOrEqual(header.height,52,"The collapsed summary must use one row.")
        XCTAssertTrue(expand.isHittable);XCTAssertTrue(openFull.isHittable)
        for item in [file,added,removed,openFull] {
            XCTAssertLessThanOrEqual(abs(item.frame.midY-expand.frame.midY),12)
        }
        XCTAssertFalse(app.descendants(matching:.any).matching(NSPredicate(format:"label == %@","修改明细")).firstMatch.exists)
        capture("Large diff starts with actual additions and removals")
        namedButton("展开差异").tap()
        // Bind the actual code viewport below this expanded header. SwiftUI's
        // native ScrollView reports {-1,-1} for its own AX activation point;
        // scrolling is proved by a real drag and the actual final visible row.
        func text(_ node:XCUIElement)->[String] {
            [node.value as? String,node.label].compactMap { $0?.trimmingCharacters(in:.whitespacesAndNewlines) }
        }
        let bodyTop=namedButton("收起差异").frame.maxY
        let scrolls=app.tables.allElementsBoundByIndex+app.scrollViews.allElementsBoundByIndex
        let codeViewport=scrolls.filter { scroll in
            let viewport=scroll.frame
            guard viewport.height > 0 && viewport.height <= 320.5 && viewport.width > 0,
                  viewport.intersects(screen),abs(viewport.minY-bodyTop) <= 4 else { return false }
            let rows=scroll.textViews.allElementsBoundByIndex+scroll.staticTexts.allElementsBoundByIndex
            return rows.contains { row in
                let frame=row.frame
                return frame.height > 0 && frame.height <= 64 && frame.intersects(viewport)
            }
        }.min { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height }
        XCTAssertNotNil(codeViewport,"Expanded changes need the actual inner code viewport and initial native text rows")
        guard let codeViewport else { return }
        let lines=codeViewport
        XCTAssertGreaterThan(lines.frame.height,0)
        XCTAssertLessThanOrEqual(lines.frame.height,320.5)
        let viewport=lines.frame.intersection(app.windows.firstMatch.frame)
        XCTAssertGreaterThan(viewport.width,0);XCTAssertGreaterThan(viewport.height,0)
        func lastLineIsVisible() -> Bool {
            lines.descendants(matching:.any).matching(NSPredicate(format:
                "label == %@ OR label ENDSWITH %@ OR value == %@ OR value ENDSWITH %@",
                "new row 80",": new row 80","new row 80",": new row 80"))
                .allElementsBoundByIndex.contains { node in
                guard node.elementType == .textView || node.elementType == .staticText,
                      node.frame.height > 0 && node.frame.height <= 64,
                      node.frame.intersects(lines.frame),node.isHittable else { return false }
                return text(node).contains { value in
                    // Exclude a parent/value repeating the whole source: only
                    // one actual short row, exact content or its row label.
                    !value.contains("\n") && value.utf8.count <= 200
                        && (value == "new row 80" || value.hasSuffix(": new row 80"))
                }
            }
        }
        for _ in 0..<24 {
            if lastLineIsVisible() { break }
            let window=app.windows.firstMatch
            let visible=lines.frame.intersection(window.frame)
            XCTAssertGreaterThan(visible.width,0);XCTAssertGreaterThan(visible.height,0)
            let origin=window.coordinate(withNormalizedOffset:.zero)
            let from=origin.withOffset(CGVector(dx:visible.midX-window.frame.minX,dy:visible.minY+visible.height*0.9-window.frame.minY))
            let to=origin.withOffset(CGVector(dx:visible.midX-window.frame.minX,dy:visible.minY+visible.height*0.1-window.frame.minY))
            from.press(forDuration:0.01,thenDragTo:to,withVelocity:.fast,thenHoldForDuration:0)
        }
        if !lastLineIsVisible() {
            let diagnostic=XCTAttachment(string:app.debugDescription)
            diagnostic.name="Actual diff row accessibility after bounded scrolling";diagnostic.lifetime = .keepAlways;add(diagnostic)
        }
        XCTAssertTrue(lastLineIsVisible(),"Large diff must scroll to its actual final line inside the bounded area")
        capture("Large native diff internally scrolled to its last added line")
    }
}
