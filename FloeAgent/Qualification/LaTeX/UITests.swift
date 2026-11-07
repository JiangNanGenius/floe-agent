import XCTest
final class LaTeXUITests:XCTestCase {
    func testSourceCompletionAndVisualAbstractPersist() throws {
        continueAfterFailure=false
        let app=XCUIApplication();app.launchArguments=["--qualification-project",UUID().uuidString,"--qualification-events"];app.launch()
        let mode=app.segmentedControls["latex.mode"]
        XCTAssertTrue(mode.waitForExistence(timeout:20));mode.buttons["源码"].tap()
        let source=app.textViews["latex.sourceEditor"]
        XCTAssertTrue(source.waitForExistence(timeout:10));source.tap();app.buttons["开头"].tap()
        source.typeText("\\se")
        app.buttons["补全"].tap();app.buttons["\\section{}"].tap()
        XCTAssertTrue((source.value as? String)?.hasPrefix("\\section{}")==true)
        let fixture="\\documentclass{article}\n\\begin{document}\n\\begin{abstract}Abstract fixture text.\\end{abstract}\nParagraph fixture text.\n\\begin{itemize}\n\\item First item\n\\item Second item\n\\end{itemize}\n\\end{document}\n"
        app.buttons["全选"].tap();source.typeText(fixture)
        mode.buttons["可视化"].tap()
        let abstract=app.textViews.matching(NSPredicate(format:"value CONTAINS %@","Abstract fixture text.")).firstMatch
        XCTAssertTrue(abstract.waitForExistence(timeout:10));abstract.coordinate(withNormalizedOffset:CGVector(dx:0.98,dy:0.5)).tap();abstract.typeText(" Added in visual mode.")
        let paragraph=app.textViews.matching(NSPredicate(format:"value CONTAINS %@","Paragraph fixture text.")).firstMatch
        XCTAssertTrue(paragraph.exists);paragraph.coordinate(withNormalizedOffset:CGVector(dx:0.98,dy:0.5)).tap();paragraph.typeText(" More text.")
        let item=app.textViews.matching(NSPredicate(format:"value CONTAINS %@","First item")).firstMatch
        XCTAssertTrue(item.exists);item.coordinate(withNormalizedOffset:CGVector(dx:0.98,dy:0.5)).tap();item.typeText(" More text.")
        let evidence=XCTAttachment(screenshot:app.screenshot());evidence.name="actual-visual-abstract-and-list";evidence.lifetime = .keepAlways;add(evidence)
        mode.buttons["源码"].tap()
        XCTAssertTrue(source.waitForExistence(timeout:10));XCTAssertTrue((source.value as? String)?.contains("Abstract fixture text. Added in visual mode.")==true)
        XCTAssertTrue((source.value as? String)?.contains("Paragraph fixture text. More text.")==true)
        XCTAssertTrue((source.value as? String)?.contains("First item More text.")==true)
        XCTAssertTrue(app.staticTexts["已保存"].waitForExistence(timeout:10))
        app.terminate();app.launch();XCTAssertTrue(mode.waitForExistence(timeout:15));mode.buttons["源码"].tap()
        XCTAssertTrue(source.waitForExistence(timeout:10));XCTAssertTrue((source.value as? String)?.contains("Added in visual mode.")==true)
    }
    func testWritingFormulaTypesettingAndReopen() throws {
        continueAfterFailure=false
        let app=XCUIApplication();app.launchArguments=["--qualification-project",UUID().uuidString,"--qualification-events"];app.launch()
        let mode=app.segmentedControls["latex.mode"]
        XCTAssertTrue(mode.waitForExistence(timeout:20))
        mode.buttons["源码"].tap()
        let source=app.textViews["latex.sourceEditor"]
        XCTAssertTrue(source.waitForExistence(timeout:10));source.tap();app.buttons["开头"].tap()
        source.typeText("% QA persistent source\n")
        XCTAssertTrue((source.value as? String)?.hasPrefix("% QA persistent source\n\\documentclass")==true,"The fixture must retain a valid document preamble before typesetting")
        mode.buttons["可视化"].tap()
        app.buttons["插入"].tap();app.buttons["公式"].tap()
        let formula=app.textViews["latex.formulaInput"]
        XCTAssertTrue(formula.waitForExistence(timeout:5));formula.tap();formula.typeText("x^2+y^2=z^2")
        app.buttons["latex.insertConfirm"].tap()
        app.buttons["latex.compile"].tap()
        let status=app.buttons["latex.buildStatus"]
        let finished=XCTNSPredicateExpectation(predicate:NSPredicate(format:"label == %@ OR label CONTAINS %@","PDF 已更新","排版遇到问题"),object:status)
        XCTAssertEqual(XCTWaiter.wait(for:[finished],timeout:180),.completed)
        XCTAssertEqual(status.label,"PDF 已更新")
        XCTAssertTrue(app.otherElements["latex.pdfPreview"].exists || app.scrollViews["latex.pdfPreview"].exists)
        let screenshot=XCTAttachment(screenshot:app.screenshot());screenshot.name="actual-native-writing-and-pdf";screenshot.lifetime = .keepAlways;add(screenshot)
        app.terminate();app.launch()
        XCTAssertTrue(mode.waitForExistence(timeout:15));mode.buttons["源码"].tap()
        XCTAssertTrue(source.waitForExistence(timeout:10))
        XCTAssertTrue((source.value as? String)?.contains("QA persistent source")==true)
        XCTAssertTrue((source.value as? String)?.contains("x^2+y^2=z^2")==true)
    }
}
