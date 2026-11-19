// SPDX-License-Identifier: MPL-2.0
import XCTest

final class GameFlowUITests: XCTestCase {
    @MainActor func testCreateImportPlayTouchAndSettings() throws {
        continueAfterFailure = false
        let app = XCUIApplication(); app.launch(); XCUIDevice.shared.orientation = .landscapeLeft
        XCTAssertTrue(app.buttons["game.new"].waitForExistence(timeout: 15)); app.buttons["game.new"].tap()
        XCTAssertTrue(app.buttons["game.import"].waitForExistence(timeout: 10)); app.buttons["game.import"].tap()
        app.buttons["game.import.phaser"].tap()
        let play = app.buttons["game.overview.play"]
        XCTAssertTrue(play.waitForExistence(timeout: 10))
        let imported = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "已完整导入")).firstMatch
        XCTAssertTrue(imported.waitForExistence(timeout: 20)); play.tap()
        let x = app.staticTexts["game.run.x"]
        XCTAssertTrue(x.waitForExistence(timeout: 20))
        let ready = NSPredicate(format: "label != %@", "x: —")
        expectation(for: ready, evaluatedWith: x); waitForExpectations(timeout: 20)
        let initial = number(x.label)
        let button = app.buttons["game.touch.a"]
        XCTAssertTrue(button.waitForExistence(timeout: 10)); button.press(forDuration: 0.6)
        let moved = NSPredicate { _, _ in self.number(x.label) > initial + 30 }
        expectation(for: moved, evaluatedWith: nil); waitForExpectations(timeout: 10)
        let beforeStick = number(x.label)
        let stick = app.descendants(matching: .any).matching(identifier: "game.touch.stick").firstMatch
        XCTAssertTrue(stick.waitForExistence(timeout: 10))
        let center = stick.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        let right = stick.coordinate(withNormalizedOffset: CGVector(dx: 0.85, dy: 0.5))
        center.press(forDuration: 0.2, thenDragTo: right, withVelocity: .slow, thenHoldForDuration: 0.6)
        let stickMoved = NSPredicate { _, _ in self.number(x.label) > beforeStick + 20 }
        expectation(for: stickMoved, evaluatedWith: nil); waitForExpectations(timeout: 10)
        let attachment = XCTAttachment(screenshot: app.screenshot()); attachment.name = "Actual iPad Phaser touch controls"; attachment.lifetime = .keepAlways; add(attachment)
        app.buttons["game.touch.settings"].tap()
        let addKey = app.buttons["game.touch.settings.add"]
        reveal(addKey, in: app); addKey.tap()
        let keyLabel = app.textFields["game.touch.button.label"]
        XCTAssertTrue(keyLabel.waitForExistence(timeout: 10)); replace(keyLabel, with: "Quick move")
        app.buttons["game.touch.binding.key.0"].tap()
        XCTAssertTrue(app.buttons["game.touch.key.choose.right"].waitForExistence(timeout: 10)); app.buttons["game.touch.key.choose.right"].tap()
        app.buttons["game.touch.binding.add"].tap()
        let search = app.searchFields.firstMatch
        XCTAssertTrue(search.waitForExistence(timeout: 10)); search.tap(); search.typeText("Ctrl")
        app.buttons["game.touch.key.choose.control"].tap()
        app.buttons["game.touch.button.done"].tap()
        let handedness = app.switches["左手布局"]
        reveal(handedness, in: app); handedness.tap()
        app.buttons["game.touch.settings.save"].tap(); app.buttons["完成"].firstMatch.tap()
        let custom = app.buttons["Quick move"]
        XCTAssertTrue(custom.waitForExistence(timeout: 10))
        let beforeChord = number(x.label); custom.press(forDuration: 0.6)
        expectation(for: NSPredicate { _, _ in self.number(x.label) > beforeChord + 30 }, evaluatedWith: nil); waitForExpectations(timeout: 10)
        app.buttons["game.run.close"].tap()
        XCTAssertTrue(app.buttons["game.overview.play"].waitForExistence(timeout: 10))
        app.buttons["game.overview.play"].tap()
        XCTAssertTrue(custom.waitForExistence(timeout: 20))
        expectation(for: ready, evaluatedWith: x); waitForExpectations(timeout: 20)
        let reopenedX = number(x.label); custom.press(forDuration: 0.6)
        expectation(for: NSPredicate { _, _ in self.number(x.label) > reopenedX + 30 }, evaluatedWith: nil); waitForExpectations(timeout: 10)
        let keyboardImage = XCTAttachment(screenshot: app.screenshot()); keyboardImage.name = "Custom keyboard chord persisted and moves actual Phaser"; keyboardImage.lifetime = .keepAlways; add(keyboardImage)
        app.buttons["game.run.close"].tap()
    }
    private func number(_ text: String) -> Double { Double(text.replacingOccurrences(of: "x: ", with: "")) ?? -1 }

    @MainActor func testArrangeTwoKeysAndResumePlay() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launch()
        XCUIDevice.shared.orientation = .landscapeLeft
        app.buttons["game.new"].tap()
        app.buttons["game.import"].tap()
        app.buttons["game.import.phaser"].tap()
        let imported = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "已完整导入")).firstMatch
        XCTAssertTrue(imported.waitForExistence(timeout: 20))
        app.buttons["game.overview.play"].tap()
        let a = app.descendants(matching: .any).matching(identifier: "game.touch.a").firstMatch
        let b = app.descendants(matching: .any).matching(identifier: "game.touch.b").firstMatch
        XCTAssertTrue(a.waitForExistence(timeout: 20))
        app.buttons["game.touch.settings"].tap()
        let arrange = app.buttons["game.touch.settings.arrange"]
        reveal(arrange, in: app)
        arrange.tap()
        let done = app.buttons["game.touch.layout.done"]
        XCTAssertTrue(done.waitForExistence(timeout: 10))
        let center = CGVector(dx: 0.5, dy: 0.5)
        let initialA = a.frame
        let initialB = b.frame
        let x = app.staticTexts["game.run.x"]
        let beforeEditing = x.label
        let blank = app.coordinate(withNormalizedOffset: .init(dx: 0.42, dy: 0.4))
        blank.press(forDuration: 0.1, thenDragTo: blank.withOffset(.init(dx: 0, dy: 110)))
        XCTAssertTrue(done.isHittable)
        XCTAssertEqual(a.frame, initialA)
        XCTAssertEqual(b.frame, initialB)
        func move(_ key: XCUIElement, dx: CGFloat, dy: CGFloat) {
            let start = key.coordinate(withNormalizedOffset: center)
            start.press(forDuration: 0.15, thenDragTo: start.withOffset(.init(dx: dx, dy: dy)))
        }
        move(a, dx: -100, dy: -55)
        XCTAssertEqual(a.frame.midX, initialA.midX - 100, accuracy: 8)
        let movedA = a.frame
        move(b, dx: -40, dy: -100)
        XCTAssertEqual(b.frame.midY, initialB.midY - 100, accuracy: 8)
        XCTAssertEqual(a.frame.midX, movedA.midX, accuracy: 2)
        let movedB = b.frame
        XCTAssertEqual(x.label, beforeEditing)
        done.tap()
        XCTAssertTrue(a.waitForExistence(timeout: 10))
        app.buttons["game.run.close"].tap()
        app.buttons["game.overview.play"].tap()
        XCTAssertTrue(a.waitForExistence(timeout: 20))
        XCTAssertEqual(a.frame.midX, movedA.midX, accuracy: 3)
        XCTAssertEqual(b.frame.midY, movedB.midY, accuracy: 3)
        expectation(for: NSPredicate(format: "label != %@", "x: —"), evaluatedWith: x)
        waitForExpectations(timeout: 10)
        let before = number(x.label)
        a.press(forDuration: 0.6)
        expectation(for: NSPredicate { _, _ in self.number(x.label) > before + 20 }, evaluatedWith: nil)
        waitForExpectations(timeout: 10)
        app.buttons["game.run.close"].tap()
    }

    @MainActor func testRuntimeBrowserCapabilities() throws {
        continueAfterFailure = false
        let app = XCUIApplication(); app.launch(); XCUIDevice.shared.orientation = .landscapeLeft
        XCTAssertTrue(app.buttons["game.new"].waitForExistence(timeout: 15)); app.buttons["game.new"].tap()
        app.buttons["game.import"].tap(); app.buttons["game.import.phaser"].tap()
        let imported = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "已完整导入")).firstMatch
        XCTAssertTrue(imported.waitForExistence(timeout: 20)); app.buttons["game.overview.play"].tap()
        let features = app.staticTexts["game.run.browserFeatures"]
        XCTAssertTrue(features.waitForExistence(timeout: 20))
        expectation(for: NSPredicate(format: "label BEGINSWITH %@", "WASM:true"), evaluatedWith: features)
        waitForExpectations(timeout: 20)
        let record = XCTAttachment(string: features.label); record.name = "Actual iPad WebKit browser API availability"; record.lifetime = .keepAlways; add(record)
        print("ACTUAL IPAD WEBKIT FEATURES: " + features.label)
        app.buttons["game.run.close"].tap()
    }

    @MainActor func testNativeRPGParametersMapAndEvents() throws {
        continueAfterFailure = false
        let app = XCUIApplication(); app.launch(); XCUIDevice.shared.orientation = .landscapeLeft
        XCTAssertTrue(app.buttons["game.new"].waitForExistence(timeout: 15)); app.buttons["game.new"].tap()
        app.buttons["game.import"].tap(); app.buttons["game.import.rpg"].tap()
        let imported = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "已完整导入")).firstMatch
        XCTAssertTrue(imported.waitForExistence(timeout: 20))
        app.buttons["game.overview.simpleEdit"].tap()
        let actors = app.staticTexts["data/Actors.json"]
        XCTAssertTrue(actors.waitForExistence(timeout: 15)); actors.tap()
        let name = app.textFields.matching(NSPredicate(format: "identifier BEGINSWITH %@ AND identifier ENDSWITH %@", "game.edit.parameter.", ".name")).firstMatch
        XCTAssertTrue(name.waitForExistence(timeout: 10)); replace(name, with: "QA Hero")
        let save = app.buttons["game.edit.save"]
        expectation(for: NSPredicate(format: "enabled == true"), evaluatedWith: save); waitForExpectations(timeout: 10)
        save.tap()
        let mapFile = app.staticTexts["data/Map001.json"]
        XCTAssertTrue(mapFile.waitForExistence(timeout: 10)); mapFile.tap()
        let canvas = app.descendants(matching: .any).matching(identifier: "game.edit.map.canvas").firstMatch
        XCTAssertTrue(canvas.waitForExistence(timeout: 10)); app.buttons["填充"].tap()
        canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.15, dy: 0.15)).tap()
        expectation(for: NSPredicate(format: "enabled == true"), evaluatedWith: save); waitForExpectations(timeout: 10)
        app.buttons["事件"].tap()
        let line = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "你好，旅行者。")).firstMatch
        XCTAssertTrue(line.waitForExistence(timeout: 10)); line.tap()
        let text = app.textFields.matching(NSPredicate(format: "identifier BEGINSWITH %@", "game.edit.event.field.")).firstMatch
        XCTAssertTrue(text.waitForExistence(timeout: 10)); replace(text, with: "Hello from QA")
        app.buttons["game.edit.event.save"].tap()
        XCTAssertTrue(save.waitForExistence(timeout: 10)); save.tap()
        expectation(for: NSPredicate(format: "enabled == false"), evaluatedWith: save); waitForExpectations(timeout: 10)
        let image = XCTAttachment(screenshot: app.screenshot()); image.name = "Actual iPad native RPG event editor"; image.lifetime = .keepAlways; add(image)
        app.buttons["完成"].firstMatch.tap()
        let saved = app.staticTexts["game.verify.saved"]
        XCTAssertTrue(saved.waitForExistence(timeout: 10))
        XCTAssertTrue(saved.label.contains("名称=QA Hero"), saved.label); XCTAssertTrue(saved.label.contains("第二条目=商人"), saved.label)
        XCTAssertTrue(saved.label.contains("图块1=96"), saved.label); XCTAssertTrue(saved.label.contains("保留=true"), saved.label); XCTAssertTrue(saved.label.contains("事件=true"), saved.label)
        app.buttons["game.overview.simpleEdit"].tap()
        XCTAssertTrue(actors.waitForExistence(timeout: 10)); actors.tap()
        XCTAssertTrue(name.waitForExistence(timeout: 10)); XCTAssertEqual(name.value as? String, "QA Hero")
        app.buttons["完成"].firstMatch.tap()
    }
    @MainActor private func replace(_ field: XCUIElement, with value: String) {
        let old = field.value as? String ?? ""
        field.coordinate(withNormalizedOffset: CGVector(dx: 0.98, dy: 0.5)).tap()
        field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: old.count) + value)
    }
    @MainActor private func reveal(_ element: XCUIElement, in app: XCUIApplication) {
        for _ in 0..<4 {
            if element.exists && element.isHittable { return }
            app.swipeUp()
        }
        XCTAssertTrue(element.exists && element.isHittable)
    }
}
