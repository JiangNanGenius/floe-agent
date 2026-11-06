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
    }
    private func capture(_ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
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
        let confirm = app.alerts.buttons["创建"].firstMatch
        XCTAssertTrue(confirm.waitForExistence(timeout: 5)); confirm.tap()
        XCTAssertTrue(app.buttons["space.editor.done"].waitForExistence(timeout: 15))
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
}
