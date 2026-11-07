import XCTest

@MainActor final class BiologyHostUITests:XCTestCase {
    private func element(_ app:XCUIApplication,_ id:String)->XCUIElement {app.descendants(matching:.any).matching(identifier:id).firstMatch}
    private func screenshot(_ app:XCUIApplication,_ name:String) {
        // App-region captures in this Simulator/Xcode pair can carry a stale
        // rotated crop. Preserve the actual foreground screen pixels instead.
        let attachment=XCTAttachment(screenshot:XCUIScreen.main.screenshot());attachment.name=name;attachment.lifetime = .keepAlways;add(attachment)
    }
    private func createExamples(_ app:XCUIApplication,_ token:String) {
        let name=app.textFields["biology.projectName"]
        XCTAssertTrue(name.waitForExistence(timeout:20));name.tap();name.typeText(token)
        app.buttons["biology.examples"].tap()
        XCTAssertTrue(app.buttons["biology.materials"].waitForExistence(timeout:25))
        XCTAssertEqual(app.webViews.count,0)
    }
    private func select(_ app:XCUIApplication,_ kind:String) {
        if app.buttons["biology.materials"].exists {app.buttons["biology.materials"].tap()}
        let row=element(app,"biology.asset."+kind)
        XCTAssertTrue(row.waitForExistence(timeout:10));XCTAssertTrue(row.isHittable);row.tap()
    }
    private func analyze(_ app:XCUIApplication) {
        app.buttons["biology.analysis"].tap()
        let run=app.buttons["biology.run"].firstMatch
        XCTAssertTrue(run.waitForExistence(timeout:10));XCTAssertTrue(run.isHittable)
        let enabled=XCTNSPredicateExpectation(predicate:NSPredicate(format:"enabled == true"),object:run)
        let ready=XCTWaiter.wait(for:[enabled],timeout:10)
        if ready != .completed {
            let info=XCTAttachment(string:app.debugDescription);info.name="Biology-analysis-parameters";info.lifetime = .keepAlways;add(info)
        }
        XCTAssertEqual(ready,.completed);run.tap()
        app.buttons["biology.closeAnalysis"].tap()
        let result=app.buttons["biology.showResult"]
        let exists=result.waitForExistence(timeout:20)
        if !exists {
            let info=XCTAttachment(string:app.debugDescription);info.name="Biology-result-accessibility";info.lifetime = .keepAlways;add(info)
            screenshot(app,"Biology-result-accessibility")
        }
        XCTAssertTrue(exists);result.tap()
        XCTAssertTrue(element(app,"biology.resultView").waitForExistence(timeout:10))
    }
    func testAllDomainsCalculateAndReopen() throws {
        continueAfterFailure=false
        let app=XCUIApplication();app.launchArguments=["-AppleLanguages","(en)","-AppleLocale","en_AU"]
        XCUIDevice.shared.orientation = .portrait
        app.launch();defer{app.terminate();XCUIDevice.shared.orientation = .portrait}
        let token="BiologyQA-"+String(UUID().uuidString.prefix(8))
        createExamples(app,token)
        let cases=[("sequence","length","30"),("proteinStructure","polymerAtoms","602"),("microscopyImage","objects","2"),("expressionMatrix","cells","8"),("biochemicalNetwork","final_A","4.97871")]
        for (kind,key,expected) in cases {
            select(app,kind);analyze(app)
            let metric=element(app,"biology.metric."+key)
            XCTAssertTrue(metric.waitForExistence(timeout:10))
            let observed=(metric.value as? String) ?? metric.label
            XCTAssertTrue(observed.contains(expected),"Expected \(expected), got \(metric.debugDescription)")
            screenshot(app,"Biology-"+kind+"-actual-result")
        }
        saveAndReopenNotes(app,token)
    }
    private func saveAndReopenNotes(_ app:XCUIApplication,_ token:String) {
        app.buttons["biology.more"].tap();app.buttons["Research notes"].tap()
        let notes=app.textViews["biology.notesDraft"]
        XCTAssertTrue(notes.waitForExistence(timeout:10))
        XCTAssertEqual(XCTWaiter.wait(for:[XCTNSPredicateExpectation(predicate:NSPredicate(format:"enabled == true"),object:notes)],timeout:10),.completed)
        notes.tap();notes.typeText(token)
        XCTAssertTrue((notes.value as? String ?? "").contains(token))
        app.buttons["biology.saveNotes"].tap()
        let committed=XCTWaiter.wait(for:[XCTNSPredicateExpectation(predicate:NSPredicate(format:"exists == false"),object:notes)],timeout:15)
        if committed != .completed {let info=XCTAttachment(string:app.debugDescription);info.name="Biology-save-acknowledgement";info.lifetime = .keepAlways;add(info);screenshot(app,"Biology-save-acknowledgement")}
        XCTAssertEqual(committed,.completed,"Do not terminate before the actual save acknowledges completion")
        app.terminate();app.launch()
        let project=app.buttons.matching(NSPredicate(format:"label CONTAINS %@",token)).firstMatch
        XCTAssertTrue(project.waitForExistence(timeout:15));project.tap()
        app.buttons["biology.more"].tap();app.buttons["Research notes"].tap()
        XCTAssertTrue(app.textViews["biology.notesDraft"].waitForExistence(timeout:10))
        let restored=XCTNSPredicateExpectation(predicate:NSPredicate{element,_ in (element as? XCUIElement)?.value as? String == token},object:app.textViews["biology.notesDraft"])
        XCTAssertEqual(XCTWaiter.wait(for:[restored],timeout:10),.completed)
        screenshot(app,"Biology-notes-reopened")
    }
    func testNotesSaveAcknowledgedBeforeReopen() throws {
        continueAfterFailure=false
        let app=XCUIApplication();app.launchArguments=["-AppleLanguages","(en)","-AppleLocale","en_AU"]
        XCUIDevice.shared.orientation = .portrait
        app.launch();defer{app.terminate();XCUIDevice.shared.orientation = .portrait}
        let token="NotesQA-"+String(UUID().uuidString.prefix(8));createExamples(app,token)
        saveAndReopenNotes(app,token)
    }
    func testNativeEditingUndoAndLandscape() throws {
        continueAfterFailure=false
        let app=XCUIApplication();app.launchArguments=["-AppleLanguages","(en)","-AppleLocale","en_AU"]
        XCUIDevice.shared.orientation = .portrait
        app.launch();defer{app.terminate();XCUIDevice.shared.orientation = .portrait}
        createExamples(app,"EditQA-"+String(UUID().uuidString.prefix(8)))
        app.buttons["biology.analysis"].tap();app.buttons["biology.editSequence"].tap()
        let draft=app.textViews["biology.sequenceDraft"]
        XCTAssertTrue(draft.waitForExistence(timeout:15))
        let old=draft.value as? String ?? ""
        XCTAssertFalse(old.isEmpty)
        app.buttons["biology.clearSequenceDraft"].tap();draft.tap()
        let replacement="ATGGCTGACGAATTCTACGGTGCTAAATAA"
        draft.typeText(replacement)
        XCTAssertEqual(draft.value as? String,replacement)
        app.buttons["biology.saveSequence"].tap()
        XCTAssertTrue(app.staticTexts[replacement].firstMatch.waitForExistence(timeout:10))
        app.buttons["biology.undo"].tap()
        XCTAssertTrue(app.staticTexts[old].firstMatch.waitForExistence(timeout:10))
        app.buttons["biology.redo"].tap()
        XCTAssertTrue(app.staticTexts[replacement].firstMatch.waitForExistence(timeout:10))
        select(app,"proteinStructure")
        XCUIDevice.shared.orientation = .landscapeLeft
        let landscape=XCTNSPredicateExpectation(predicate:NSPredicate{_,_ in app.windows.firstMatch.frame.width>app.windows.firstMatch.frame.height},object:nil)
        XCTAssertEqual(XCTWaiter.wait(for:[landscape],timeout:15),.completed)
        let viewport=element(app,"biology.structureViewport")
        XCTAssertTrue(viewport.waitForExistence(timeout:10))
        viewport.coordinate(withNormalizedOffset:.init(dx:0.5,dy:0.5)).press(forDuration:0.05,thenDragTo:viewport.coordinate(withNormalizedOffset:.init(dx:0.7,dy:0.6)))
        XCTAssertTrue(app.buttons["biology.structureFit"].isHittable);app.buttons["biology.structureFit"].tap()
        XCTAssertEqual(app.webViews.count,0)
        screenshot(app,"Biology-native-protein-landscape")
    }
    func testChineseDarkAndExportSurface() throws {
        continueAfterFailure=false
        let app=XCUIApplication();app.launchArguments=["-AppleLanguages","(zh-Hans)","-AppleLocale","zh_CN","--biology-qa-dark","--biology-qa-contrast"]
        XCUIDevice.shared.orientation = .portrait
        app.launch();defer{app.terminate();XCUIDevice.shared.orientation = .portrait}
        createExamples(app,"中文QA-"+String(UUID().uuidString.prefix(8)))
        select(app,"microscopyImage")
        screenshot(app,"Biology-native-microscopy-dark-Chinese")
        select(app,"expressionMatrix")
        screenshot(app,"Biology-native-matrix-dark-Chinese")
        app.buttons["biology.export"].tap()
        XCTAssertTrue(app.buttons["导出项目"].waitForExistence(timeout:10))
        app.buttons["导出项目"].tap()
        screenshot(app,"Biology-native-export-dialog")
    }
}
