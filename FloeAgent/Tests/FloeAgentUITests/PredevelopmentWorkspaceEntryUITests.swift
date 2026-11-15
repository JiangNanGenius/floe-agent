// SPDX-License-Identifier: MPL-2.0
import XCTest

@MainActor
final class PredevelopmentWorkspaceEntryUITests: XCTestCase {
    private func application() -> XCUIApplication {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .landscapeLeft
        let app = XCUIApplication(bundleIdentifier: "org.floeagent.ios")
        app.launchArguments = ["-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN",
                               "-ui-testing", "-ui-testing-ipad", "--ui-test-skip-onboarding"]
        return app
    }

    private func openNewFileMenu(_ app: XCUIApplication) {
        let space = app.collectionViews["sidebar.list"].cells.containing(.staticText, identifier: "sidebar.notes").firstMatch
        XCTAssertTrue(space.waitForExistence(timeout: 25))
        space.tap()
        let files = app.segmentedControls["space.sections"].buttons["文件"]
        XCTAssertTrue(files.waitForExistence(timeout: 15))
        files.tap()
        let new = app.buttons["space.new"]
        XCTAssertTrue(new.waitForExistence(timeout: 10))
        new.tap()
    }

    func testSpaceOffersGameProjectCreation() {
        let app = application()
        app.launch()
        openNewFileMenu(app)
        app.buttons["space.new.game"].tap()
        let title = app.textFields["game.new.title"]
        XCTAssertTrue(title.waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["创建"].isEnabled)
        XCTAssertFalse(app.descendants(matching: .any)["引擎"].exists)
        title.tap()
        title.typeText("QA-Game-" + String(UUID().uuidString.prefix(8)))
        app.buttons["创建"].tap()
        let ask = app.buttons["game.setup.askAI"]
        XCTAssertTrue(ask.waitForExistence(timeout: 25))
        XCTAssertTrue(app.buttons["game.setup.import"].exists)
        ask.tap()
        XCTAssertTrue(app.buttons["studio.assistant.sessions"].waitForExistence(timeout: 15))
    }

    func testNewBuildingDrawsConnectedWallsAndChangesOneFinish() {
        let app = application()
        app.launch()
        openNewFileMenu(app)
        app.buttons["space.create.building"].tap()
        let name = app.textFields["space.creation.title"]
        XCTAssertTrue(name.waitForExistence(timeout: 10))
        name.tap()
        name.typeKey("a", modifierFlags: .command)
        name.typeText("QA-Walls-" + String(UUID().uuidString.prefix(8)))
        app.buttons["space.creation.create"].tap()
        let plan = app.descendants(matching: .any).matching(identifier: "building.walls.plan").firstMatch
        func openWallPlan() {
            if !plan.waitForExistence(timeout: 6) {
                let section = app.descendants(matching: .any).matching(identifier: "building.section.model").firstMatch
                XCTAssertTrue(section.waitForExistence(timeout: 20))
                section.tap()
            }
            XCTAssertTrue(plan.waitForExistence(timeout: 20))
        }
        openWallPlan()
        func expectWalls(_ count: Int) {
            let condition = NSPredicate(format: "value CONTAINS %@", "\(count) 面墙")
            XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: condition, object: plan)],
                                          timeout: 10), .completed)
        }
        expectWalls(0)
        app.buttons["building.walls.draw"].tap()
        plan.coordinate(withNormalizedOffset: CGVector(dx: 0.30, dy: 0.50)).tap()
        plan.coordinate(withNormalizedOffset: CGVector(dx: 0.70, dy: 0.50)).tap()
        expectWalls(1)
        plan.coordinate(withNormalizedOffset: CGVector(dx: 0.70, dy: 0.75)).tap()
        expectWalls(2)
        app.buttons["building.walls.finish"].tap()
        plan.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        let left = app.buttons["building.walls.finish.left"]
        XCTAssertTrue(left.waitForExistence(timeout: 10))
        left.tap()
        app.buttons["白色乳胶漆"].tap()
        let applied = NSPredicate(format: "label CONTAINS %@", "白色乳胶漆")
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: applied, object: left)], timeout: 10), .completed)
        XCTAssertFalse(app.buttons["building.walls.finish.right"].label.contains("白色乳胶漆"))
        let image = XCTAttachment(screenshot: app.screenshot())
        image.name = "建筑墙体与单侧饰面"
        image.lifetime = .keepAlways
        add(image)
        app.buttons["building.design.save"].tap()
        let saved = app.staticTexts.matching(NSPredicate(
            format: "identifier == %@ AND label == %@", "building.notice", "整个工程已保存。"
        )).firstMatch
        XCTAssertTrue(saved.waitForExistence(timeout: 25))

        func tapProjectCommand(_ identifier: String, title: String) {
            let more = app.buttons["building.more"]
            let ready = XCTNSPredicateExpectation(predicate: NSPredicate(format: "enabled == true AND hittable == true"), object: more)
            XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 10), .completed)
            more.tap()
            let command = app.descendants(matching: .any).matching(NSPredicate(
                format: "identifier == %@ OR label == %@", identifier, title
            )).firstMatch
            XCTAssertTrue(command.waitForExistence(timeout: 8))
            command.tap()
        }

        tapProjectCommand("building.reopen", title: "重新打开")
        // The integrated editor replaces its mount after loading the saved project.
        // A still-visible plan and its old wall count alone cannot prove that happened.
        let replaced = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: saved)
        XCTAssertEqual(XCTWaiter.wait(for: [replaced], timeout: 25), .completed)
        openWallPlan()
        expectWalls(2)
        tapProjectCommand("building.saveAs", title: "另存为…")
        let saveCopy = app.buttons["building.copy.confirm"]
        XCTAssertTrue(saveCopy.waitForExistence(timeout: 8))
        saveCopy.tap()
        XCTAssertTrue(app.buttons["分享或存储到文件"].waitForExistence(timeout: 25))
    }

    func testSavedCADDrawingOpensAnIndependentBuildingProject() {
        let app = application()
        app.launchEnvironment["FLOE_BUILDING_FIXTURE_ID"] = UUID().uuidString
        app.launchArguments += ["--ui-test-cad-fixture", "--ui-test-cad-building", "--ui-test-cad-building-reopen"]
        app.launch()
        let project = app.buttons["cad.building.project"]
        XCTAssertTrue(project.waitForExistence(timeout: 25))
        project.tap()
        let create = app.buttons["建立工程"]
        XCTAssertTrue(create.waitForExistence(timeout: 10))
        create.tap()
        let close = app.buttons["building.close"]
        XCTAssertTrue(close.waitForExistence(timeout: 30))
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "建筑工程"
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
