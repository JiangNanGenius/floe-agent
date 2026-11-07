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
    func testRibbonDensityTreeAndActualToolEdits() throws {
        continueAfterFailure=false
        let app=XCUIApplication();app.launchArguments=["-AppleLanguages","(en)","-AppleLocale","en_AU"]
        XCUIDevice.shared.orientation = .portrait;app.launch();defer{app.terminate();XCUIDevice.shared.orientation = .portrait}
        createExamples(app,"BiologyClosure-"+String(UUID().uuidString.prefix(6)))
        select(app,"proteinStructure")
        app.segmentedControls["biology.structureRepresentation"].buttons["Ribbon"].tap()
        let ribbon=element(app,"biology.ribbonViewport");XCTAssertTrue(ribbon.waitForExistence(timeout:20));XCTAssertTrue(ribbon.isHittable)
        ribbon.swipeLeft();screenshot(app,"Biology-native-ribbon")
        func chooseFormat(_ format:String) {
            app.buttons["biology.materials"].tap();let row=element(app,"biology.assetFormat."+format);XCTAssertTrue(row.waitForExistence(timeout:10));row.tap()
        }
        chooseFormat("newick");XCTAssertTrue(element(app,"biology.treeViewport").waitForExistence(timeout:15));screenshot(app,"Biology-native-tree")
        chooseFormat("mrc");XCTAssertTrue(element(app,"biology.imageViewport").waitForExistence(timeout:15));screenshot(app,"Biology-density-slice")
        app.segmentedControls.buttons["Surface"].tap();XCTAssertTrue(element(app,"biology.densitySurface").waitForExistence(timeout:20));screenshot(app,"Biology-density-surface")
        try exerciseToolEdit(app)
    }
    func testToolEditsUpdateLiveView() throws {
        continueAfterFailure=false
        let app=XCUIApplication();app.launchArguments=["-AppleLanguages","(en)","-AppleLocale","en_AU"]
        XCUIDevice.shared.orientation = .portrait;app.launch();defer{app.terminate();XCUIDevice.shared.orientation = .portrait}
        createExamples(app,"BiologyTools-"+String(UUID().uuidString.prefix(6)))
        try exerciseToolEdit(app)
    }
    func testVisualWorkbenchPortraitAndLandscape() throws {
        continueAfterFailure=false
        let app=XCUIApplication();app.launchArguments=["-AppleLanguages","(en)","-AppleLocale","en_AU"]
        XCUIDevice.shared.orientation = .portrait;app.launch()
        defer{app.terminate();XCUIDevice.shared.orientation = .portrait}
        screenshot(app,"Biology-polish-library")
        createExamples(app,"BiologyVisual-"+String(UUID().uuidString.prefix(6)))
        select(app,"sequence");XCTAssertTrue(element(app,"biology.sequenceViewport").waitForExistence(timeout:10))
        screenshot(app,"Biology-polish-sequence")
        select(app,"proteinStructure")
        let structure=element(app,"biology.structureViewport");XCTAssertTrue(structure.waitForExistence(timeout:20))
        structure.swipeLeft();app.buttons["biology.structureFit"].tap()
        screenshot(app,"Biology-polish-backbone")
        app.segmentedControls["biology.structureRepresentation"].buttons["Atoms"].tap()
        XCTAssertTrue(structure.waitForExistence(timeout:20));structure.swipeLeft()
        screenshot(app,"Biology-polish-atoms")
        app.segmentedControls["biology.structureRepresentation"].buttons["Ribbon"].tap()
        let ribbon=element(app,"biology.ribbonViewport");XCTAssertTrue(ribbon.waitForExistence(timeout:20));ribbon.swipeLeft()
        screenshot(app,"Biology-polish-ribbon")
        XCUIDevice.shared.orientation = .landscapeLeft
        let wide=XCTNSPredicateExpectation(predicate:NSPredicate{_,_ in app.windows.firstMatch.frame.width>app.windows.firstMatch.frame.height},object:nil)
        XCTAssertEqual(XCTWaiter.wait(for:[wide],timeout:15),.completed)
        app.buttons["biology.structureFit"].tap();XCTAssertTrue(ribbon.isHittable)
        screenshot(app,"Biology-polish-ribbon-landscape")
        XCUIDevice.shared.orientation = .portrait
        let tall=XCTNSPredicateExpectation(predicate:NSPredicate{_,_ in app.windows.firstMatch.frame.height>app.windows.firstMatch.frame.width},object:nil)
        XCTAssertEqual(XCTWaiter.wait(for:[tall],timeout:15),.completed)
        select(app,"microscopyImage");XCTAssertTrue(element(app,"biology.imageViewport").waitForExistence(timeout:10))
        screenshot(app,"Biology-polish-image")
        select(app,"expressionMatrix");XCTAssertTrue(element(app,"biology.matrixHeatmap").waitForExistence(timeout:10))
        screenshot(app,"Biology-polish-matrix")
        select(app,"biochemicalNetwork");XCTAssertTrue(element(app,"biology.networkViewport").waitForExistence(timeout:10))
        screenshot(app,"Biology-polish-network");analyze(app)
        XCTAssertTrue(element(app,"biology.metric.final_A").exists);screenshot(app,"Biology-polish-result")
        func chooseFormat(_ name:String){app.buttons["biology.materials"].tap();let row=element(app,"biology.assetFormat."+name);XCTAssertTrue(row.waitForExistence(timeout:10));row.tap()}
        chooseFormat("newick");XCTAssertTrue(element(app,"biology.treeViewport").waitForExistence(timeout:10))
        screenshot(app,"Biology-polish-tree")
        chooseFormat("mrc");XCTAssertTrue(element(app,"biology.imageViewport").waitForExistence(timeout:15))
        app.segmentedControls.buttons["Surface"].tap()
        let surface=element(app,"biology.densitySurface");XCTAssertTrue(surface.waitForExistence(timeout:20));surface.swipeLeft()
        screenshot(app,"Biology-polish-density")
        XCTAssertEqual(app.webViews.count,0)
    }
    func testFramedControlsUseTheirFullHitArea() throws {
        continueAfterFailure=false
        let app=XCUIApplication();app.launchArguments=["-AppleLanguages","(en)","-AppleLocale","en_AU"]
        XCUIDevice.shared.orientation = .portrait;app.launch()
        defer{app.terminate();XCUIDevice.shared.orientation = .portrait}
        createExamples(app,"BiologyFields-"+String(UUID().uuidString.prefix(6)))
        select(app,"sequence")
        let record=app.buttons["biology.sequenceRecord"];XCTAssertTrue(record.waitForExistence(timeout:10))
        XCTAssertGreaterThanOrEqual(record.frame.height,44)
        record.coordinate(withNormalizedOffset:.init(dx:0.72,dy:0.5)).tap()
        let second=app.buttons.matching(NSPredicate(format:"label BEGINSWITH %@", "FLOE_SYNTHETIC_B")).firstMatch
        XCTAssertTrue(second.waitForExistence(timeout:5));second.tap()
        screenshot(app,"Biology-framed-record-selector")
        select(app,"expressionMatrix")
        let gene=app.buttons["biology.geneField"],cell=app.buttons["biology.cellField"]
        XCTAssertTrue(gene.waitForExistence(timeout:10));XCTAssertGreaterThanOrEqual(gene.frame.height,44)
        gene.coordinate(withNormalizedOffset:.init(dx:0.72,dy:0.5)).tap()
        XCTAssertTrue(app.buttons["GENE_C"].waitForExistence(timeout:5));app.buttons["GENE_C"].tap()
        cell.coordinate(withNormalizedOffset:.init(dx:0.72,dy:0.5)).tap()
        XCTAssertTrue(app.buttons["Cell_B2"].waitForExistence(timeout:5));app.buttons["Cell_B2"].tap()
        let value=element(app,"biology.matrixSelectedValue");XCTAssertTrue(value.waitForExistence(timeout:5))
        XCTAssertTrue(((value.value as? String) ?? value.label).contains("11"))
        screenshot(app,"Biology-framed-matrix-selectors")
        select(app,"proteinStructure");app.buttons["biology.analysis"].tap()
        let form=app.collectionViews.firstMatch
        for name in ["biology.modelField","biology.chainField","biology.environmentField","biology.methodField"] {
            let field=app.buttons[name]
            // Native Form creates rows as they enter its visible viewport.
            // Scroll the actual sheet, including past the pinned Run action.
            for _ in 0..<4 {if field.exists && field.isHittable{break};form.swipeUp()}
            XCTAssertTrue(field.waitForExistence(timeout:5));XCTAssertTrue(field.isHittable)
            XCTAssertGreaterThanOrEqual(field.frame.height,44)
            if name=="biology.chainField"{screenshot(app,"Biology-framed-model-controls")}
        }
        let method=app.buttons["biology.methodField"]
        method.coordinate(withNormalizedOffset:.init(dx:0.72,dy:0.5)).tap()
        XCTAssertTrue(app.buttons["Structure geometry"].waitForExistence(timeout:5));app.buttons["Structure geometry"].tap()
        XCTAssertEqual(method.value as? String,"Structure geometry")
        screenshot(app,"Biology-framed-analysis-controls")
        let run=app.buttons["biology.run"];XCTAssertTrue(run.isHittable);run.tap()
        app.buttons["biology.closeAnalysis"].tap()
        let show=app.buttons["biology.showResult"];XCTAssertTrue(show.waitForExistence(timeout:15));show.tap()
        XCTAssertTrue(element(app,"biology.metric.polymerAtoms").waitForExistence(timeout:10))
    }
    private func exerciseToolEdit(_ app:XCUIApplication) throws {
        select(app,"sequence")
        app.buttons["biology.more"].tap();app.buttons["biology.tools"].tap()
        let picker=element(app,"biology.toolName");XCTAssertTrue(picker.waitForExistence(timeout:10))
        let form=app.collectionViews.firstMatch
        func chooseTool(_ name:String) {
            for _ in 0..<8 {if picker.exists && picker.isHittable{break};form.swipeDown()}
            picker.tap()
            let choice=app.buttons["biology.toolChoice."+name]
            XCTAssertTrue(choice.waitForExistence(timeout:5));XCTAssertTrue(choice.isHittable);choice.tap()
            XCTAssertTrue(picker.waitForExistence(timeout:5))
        }
        let response=element(app,"biology.toolResponse")
        func revealResponse() {
            let run=app.buttons["biology.toolRun"]
            XCTAssertEqual(XCTWaiter.wait(for:[XCTNSPredicateExpectation(predicate:NSPredicate(format:"enabled == true"),object:run)],timeout:10),.completed)
            // Form virtualizes off-screen rows. A completed response below
            // the argument editor must be scrolled into view before querying.
            for _ in 0..<4 {if response.exists{break};form.swipeUp()}
            XCTAssertTrue(response.waitForExistence(timeout:5))
        }
        let input=app.textViews["biology.toolArguments"]
        func replaceArguments(_ object:[String:Any]) throws {
            let text=String(decoding:try JSONSerialization.data(withJSONObject:object,options:[.sortedKeys]),as:UTF8.self)
            app.buttons["biology.clearToolArguments"].tap()
            input.tap();input.typeText(text)
            XCTAssertEqual(input.value as? String,text,"Do not submit a partial replacement or malformed test request")
        }
        chooseTool("biology.read")
        let initial=try XCTUnwrap((input.value as? String)?.data(using:.utf8)),args=try XCTUnwrap(JSONSerialization.jsonObject(with:initial) as? [String:Any]),projectID=try XCTUnwrap(args["projectID"] as? String)
        app.buttons["biology.toolRun"].tap();revealResponse()
        let data=try XCTUnwrap(response.label.data(using:.utf8)),project=try XCTUnwrap(JSONSerialization.jsonObject(with:data) as? [String:Any]),assets=try XCTUnwrap(project["assets"] as? [[String:Any]]),dna=try XCTUnwrap(assets.first(where:{$0["kind"] as? String=="sequence"})),assetID=try XCTUnwrap(dna["id"] as? String)
        chooseTool("biology.edit")
        try replaceArguments(["projectID":projectID,"assetID":assetID,"expectedRevision":1,"record":0,"start":0,"end":3,"replacement":"TTG"])
        let finish=app.buttons["biology.finishToolEditing"]
        if finish.exists{finish.tap()}
        let run=app.buttons["biology.toolRun"];for _ in 0..<3 {if run.isHittable{break};form.swipeUp()};XCTAssertTrue(run.isHittable);run.tap();revealResponse()
        let returned=response.waitForExistence(timeout:10)
        if !returned {screenshot(app,"Biology-tool-submit-failure");let debug=XCTAttachment(string:app.debugDescription);debug.name="Biology-tool-submit-failure";debug.lifetime = .keepAlways;add(debug)}
        XCTAssertTrue(returned)
        let committed=XCTNSPredicateExpectation(predicate:NSPredicate{element,_ in (element as? XCUIElement)?.label.contains("\"revision\":2")==true},object:response)
        XCTAssertEqual(XCTWaiter.wait(for:[committed],timeout:15),.completed)
        screenshot(app,"Biology-AI-tool-actual-edit")
        app.buttons["Done"].tap()
        let changed=app.staticTexts.matching(NSPredicate(format:"label BEGINSWITH %@","TTGGCT")).firstMatch
        XCTAssertTrue(changed.waitForExistence(timeout:10),"Tool mutation must reach the live sequence viewport")
        screenshot(app,"Biology-tool-edit-live-view")
    }
    private func saveAndReopenNotes(_ app:XCUIApplication,_ token:String) {
        app.buttons["biology.more"].tap();app.buttons["Research notes"].tap()
        let notes=app.textViews["biology.notesDraft"]
        XCTAssertTrue(notes.waitForExistence(timeout:10))
        XCTAssertEqual(XCTWaiter.wait(for:[XCTNSPredicateExpectation(predicate:NSPredicate(format:"enabled == true"),object:notes)],timeout:10),.completed)
        notes.tap();notes.typeText(token)
        XCTAssertTrue((notes.value as? String ?? "").contains(token))
        let hideKeyboard=app.buttons["Hide keyboard"]
        if hideKeyboard.exists {hideKeyboard.tap()}
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
