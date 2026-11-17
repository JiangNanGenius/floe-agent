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
        app.launchArguments += ["-floe.settings.language", "zh-Hans"]
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
        let setup = app.buttons["game.setup.open"]
        XCTAssertTrue(setup.waitForExistence(timeout: 25))
        let assistant = app.buttons["game.assistant.open"]
        XCTAssertTrue(assistant.waitForExistence(timeout: 10))
        assistant.tap()
        let panel = app.descendants(matching: .any).matching(identifier: "studio.assistant.content").firstMatch
        XCTAssertTrue(panel.waitForExistence(timeout: 15))
        let close = app.buttons["studio.assistant.close"]
        XCTAssertTrue(close.waitForExistence(timeout: 10))
        XCTAssertTrue(setup.isHittable, "The game remains interactive while the assistant is open")
        XCTAssertGreaterThan(panel.frame.minX, setup.frame.midX, "The assistant is shown to the right of the game")
        close.tap()
        XCTAssertTrue(close.waitForNonExistence(timeout: 10))
        setup.tap()
        let ask = app.buttons["game.setup.askAI"]
        XCTAssertTrue(ask.waitForExistence(timeout: 25))
        XCTAssertTrue(app.buttons["game.setup.import"].exists)
        ask.tap()
        XCTAssertTrue(app.buttons["studio.assistant.sessions"].waitForExistence(timeout: 15))
        XCTAssertTrue(close.waitForExistence(timeout: 10))
        XCTAssertEqual(close.label, "关闭助手")
        close.tap()
        XCTAssertTrue(close.waitForNonExistence(timeout: 10))
        XCTAssertTrue(setup.isHittable)
    }

    func testNewBuildingDrawsConnectedWallsAndChangesOneFinish() {
        let app = application()
        app.launchArguments += ["-floe.settings.language", "zh-Hans"]
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
        let done = app.navigationBars["另存为"].buttons["完成"]
        XCTAssertTrue(done.waitForExistence(timeout: 8))
        done.tap()

        let closeButtons = app.buttons.matching(identifier: "building.close")
        let close = closeButtons.firstMatch
        let available = NSPredicate(format: "exists == true AND enabled == true AND hittable == true")
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: available, object: close)],
                                      timeout: 15), .completed)
        XCTAssertEqual(closeButtons.count, 1)
        XCTAssertEqual(close.label, "退出工程")
        XCTAssertGreaterThanOrEqual(close.frame.height, 44)
        XCTAssertLessThan(close.frame.midX, app.frame.midX)
        close.tap()
        let gone = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: close)
        let space = XCTNSPredicateExpectation(predicate: available, object: app.buttons["space.new"])
        XCTAssertEqual(XCTWaiter.wait(for: [gone, space], timeout: 25), .completed)
        XCTAssertTrue(app.segmentedControls["space.sections"].buttons["文件"].isSelected)
    }

    func testSpaceBuildingFixedExitReturnsToFiles() {
        let app = application()
        app.launchArguments += ["-floe.settings.language", "zh-Hans"]
        app.launch()
        openNewFileMenu(app)
        app.buttons["space.create.building"].tap()
        let name = app.textFields["space.creation.title"]
        XCTAssertTrue(name.waitForExistence(timeout: 10))
        name.tap()
        name.typeKey("a", modifierFlags: .command)
        name.typeText("QA-Exit-" + String(UUID().uuidString.prefix(8)))
        app.buttons["space.creation.create"].tap()

        let exits = app.buttons.matching(identifier: "building.close")
        let exit = exits.firstMatch
        let available = NSPredicate(format: "exists == true AND enabled == true AND hittable == true")
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: available, object: exit)],
                                      timeout: 30), .completed)
        XCTAssertEqual(exits.count, 1)
        XCTAssertEqual(exit.label, "退出工程")
        XCTAssertGreaterThanOrEqual(exit.frame.height, 44)
        XCTAssertLessThan(exit.frame.midX, app.frame.midX)
        let projectSave = app.buttons["building.design.save"]
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: available, object: projectSave)],
                                      timeout: 15), .completed)
        XCTAssertLessThanOrEqual(exit.frame.maxY, projectSave.frame.minY)
        exit.tap()

        let save = app.buttons["building.reopen.save"]
        let exitResponse = NSPredicate { _, _ in !exit.exists || (save.exists && save.isHittable) }
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: exitResponse, object: app)],
                                      timeout: 20), .completed)
        if save.exists {
            XCTAssertEqual(save.label, "保存并关闭")
            XCTAssertTrue(save.isEnabled)
            save.tap()
        }
        XCTAssertTrue(exit.waitForNonExistence(timeout: 20))
        let space = XCTNSPredicateExpectation(predicate: available, object: app.buttons["space.new"])
        XCTAssertEqual(XCTWaiter.wait(for: [space], timeout: 15), .completed)
        XCTAssertTrue(app.segmentedControls["space.sections"].buttons["文件"].isSelected)
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
