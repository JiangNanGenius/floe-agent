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
        let name = "QA-Game-" + String(UUID().uuidString.prefix(8))
        title.typeText(name)
        app.buttons["创建"].tap()
        let setup = app.buttons["game.setup.open"]
        XCTAssertTrue(setup.waitForExistence(timeout: 25))
        let assistant = app.buttons["game.overview.aiModify"]
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
        app.buttons["完成"].firstMatch.tap()
        deleteGame(named: name, in: app)
    }

    func testGameRunsFromHomeAndIDEAndReturnsToItsCaller() {
        let app = application()
        app.launchArguments += ["-floe.settings.language", "zh-Hans"]
        app.launch()
        openNewFileMenu(app)
        app.buttons["space.new.game"].tap()
        let name = "QA-Game-Run-" + String(UUID().uuidString.prefix(8))
        let title = app.textFields["game.new.title"]
        XCTAssertTrue(title.waitForExistence(timeout: 10))
        title.tap()
        title.typeText(name)
        app.buttons["创建"].tap()
        let starter = app.buttons["创建起始模板"]
        XCTAssertTrue(starter.waitForExistence(timeout: 25))
        starter.tap()
        let engine = app.buttons["game.starter.engine.phaser"]
        let engines = app.collectionViews.firstMatch
        for _ in 0..<8 where !engine.isHittable { engines.swipeUp() }
        XCTAssertTrue(engine.isHittable)
        engine.tap()
        let create = app.buttons["game.starter.create"]
        XCTAssertEqual(XCTWaiter.wait(for: [
            XCTNSPredicateExpectation(predicate: NSPredicate(format: "enabled == true"), object: create)
        ], timeout: 10), .completed)
        create.tap()

        let homeRun = app.buttons["game.overview.play"]
        let ideRun = app.buttons["workspace.ide.run"]
        let stop = app.buttons["game.play.stop"]
        func runAndReturn(_ run: XCUIElement) {
            XCTAssertTrue(run.waitForExistence(timeout: 30))
            run.tap()
            XCTAssertTrue(stop.waitForExistence(timeout: 45), "The running game must expose its player controls")
            stop.tap()
            XCTAssertTrue(stop.waitForNonExistence(timeout: 20))
            XCTAssertTrue(run.waitForExistence(timeout: 15))
        }
        runAndReturn(homeRun)
        app.buttons["game.overview.ide"].tap()
        runAndReturn(ideRun)
        app.buttons["workspace.ide.close"].tap()
        XCTAssertTrue(homeRun.waitForExistence(timeout: 15))
        app.buttons["完成"].firstMatch.tap()
        deleteGame(named: name, in: app)
    }

    private func deleteGame(named name: String, in app: XCUIApplication) {
        let search = app.searchFields["查找作品和文件"]
        XCTAssertTrue(search.waitForExistence(timeout: 15))
        search.tap()
        search.typeText(name)
        let menu = app.buttons["更多操作：" + name]
        XCTAssertTrue(menu.waitForExistence(timeout: 15))
        menu.tap()
        app.buttons["space.files.delete"].tap()
        let confirmation = app.sheets.buttons["space.files.delete.confirm"].firstMatch
        XCTAssertTrue(confirmation.waitForExistence(timeout: 10))
        confirmation.tap()
        // Closing the game's owned operations and committing its library record are asynchronous.
        // The row must disappear even when the library contains many other projects.
        XCTAssertTrue(menu.waitForNonExistence(timeout: 60))
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
        let model = app.segmentedControls["building.model.mode"]
        model.buttons["三维模型"].tap()
        let viewport = app.descendants(matching: .any).matching(identifier: "building.model.3d").firstMatch
        XCTAssertTrue(viewport.waitForExistence(timeout: 20))
        XCTAssertTrue(app.buttons["building.close"].exists)
        model.buttons["二维平面"].tap()
        openWallPlan()
        expectWalls(2)
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
        let saveAs = app.buttons["building.saveAs"].firstMatch
        XCTAssertTrue(saveAs.waitForExistence(timeout: 10))
        saveAs.tap()
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

    func testBuildingDrawsWallByDraggingAndPansWithoutMovingIt() {
        continueAfterFailure = false
        let app = application()
        app.launchArguments += ["-floe.settings.language", "zh-Hans"]
        app.launch()
        openNewFileMenu(app)
        app.buttons["space.create.building"].tap()
        let name = app.textFields["space.creation.title"]
        XCTAssertTrue(name.waitForExistence(timeout: 10))
        name.tap()
        name.typeKey("a", modifierFlags: .command)
        name.typeText("QA-Plan-" + String(UUID().uuidString.prefix(8)))
        app.buttons["space.creation.create"].tap()
        let plan = app.descendants(matching: .any)["building.walls.plan"].firstMatch
        if !plan.waitForExistence(timeout: 8) {
            app.descendants(matching: .any)["building.section.model"].firstMatch.tap()
        }
        XCTAssertTrue(plan.waitForExistence(timeout: 20))
        app.buttons["building.walls.draw"].tap()
        let left = plan.coordinate(withNormalizedOffset: CGVector(dx: 0.32, dy: 0.5))
        let right = plan.coordinate(withNormalizedOffset: CGVector(dx: 0.68, dy: 0.5))
        left.press(forDuration: 0.08, thenDragTo: right)
        let hasWall = NSPredicate(format: "value CONTAINS %@", "1 面墙")
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: hasWall, object: plan)], timeout: 12), .completed)
        app.buttons["building.walls.finish"].tap()
        plan.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        let endpoint = app.descendants(matching: .any)["building.walls.handle.start"].firstMatch
        XCTAssertTrue(endpoint.waitForExistence(timeout: 12))
        let from = endpoint.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        let originalX = endpoint.frame.midX
        from.press(forDuration: 0.08, thenDragTo: from.withOffset(CGVector(dx: -40, dy: 0)))
        let moved = NSPredicate { _, _ in endpoint.exists && endpoint.frame.midX < originalX - 25 }
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: moved, object: endpoint)], timeout: 12), .completed)
        let editedX = endpoint.frame.midX
        let pan = app.descendants(matching: .any)["building.walls.pan"].firstMatch
        pan.tap()
        let blank = plan.coordinate(withNormalizedOffset: CGVector(dx: 0.42, dy: 0.34))
        blank.press(forDuration: 0.08, thenDragTo: blank.withOffset(CGVector(dx: 70, dy: 0)))
        pan.tap()
        XCTAssertTrue(endpoint.waitForExistence(timeout: 10))
        XCTAssertEqual(endpoint.frame.midX, editedX + 70, accuracy: 8)
        XCTAssertTrue(hasWall.evaluate(with: plan))
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
