import XCTest

@MainActor
final class ImageEditorUITests: XCTestCase {
    func testChineseTextSaveAndReturn() {
        let app = XCUIApplication()
        app.launchArguments = ["--image-editor", "-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN"]
        app.launch()
        let textTool = app.cells["image.editor.tool.textSticker"]
        XCTAssertTrue(textTool.waitForExistence(timeout: 15), app.debugDescription)
        let initial = XCTAttachment(screenshot: app.screenshot())
        initial.name = "image-editor-tools"
        initial.lifetime = .keepAlways
        add(initial)
        let compare = app.buttons["image.editor.compare"]
        compare.tap()
        XCTAssertEqual(compare.value as? String, "Original")
        compare.tap()
        XCTAssertEqual(compare.value as? String, "Edited")
        textTool.tap()
        let input = app.textViews.firstMatch
        XCTAssertTrue(input.waitForExistence(timeout: 5))
        input.tap()
        input.typeText("中文标注测试")
        app.buttons["image.editor.text.done"].tap()
        let done = app.buttons["image.editor.done"]
        XCTAssertTrue(done.waitForExistence(timeout: 5))
        let caption = XCTAttachment(screenshot: app.screenshot())
        caption.name = "image-editor-chinese-text"
        caption.lifetime = .keepAlways
        add(caption)
        done.tap()
        XCTAssertTrue(app.staticTexts["image.export.saved"].waitForExistence(timeout: 10), app.debugDescription)
    }

    func testLightToolsVisible() {
        let app = XCUIApplication()
        app.launchArguments = ["--image-editor", "--light", "-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN"]
        app.launch()
        XCTAssertTrue(app.buttons["image.editor.done"].waitForExistence(timeout: 15))
        for tool in ["draw", "clip", "textSticker", "mosaic", "filter", "adjust"] {
            let cell = app.cells["image.editor.tool." + tool]
            XCTAssertTrue(cell.exists, tool)
            XCTAssertTrue(cell.isHittable, tool)
            XCTAssertGreaterThanOrEqual(cell.frame.height, 44)
        }
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "image-editor-light-tools"
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }

    func testCancelReturnsWithoutSaving() {
        let app = XCUIApplication()
        app.launchArguments = ["--image-editor", "-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN"]
        app.launch()
        let cancel = app.buttons["image.editor.cancel"]
        XCTAssertTrue(cancel.waitForExistence(timeout: 15))
        cancel.tap()
        XCTAssertTrue(app.staticTexts["image.editor.closed"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["image.export.saved"].exists)
    }
}
