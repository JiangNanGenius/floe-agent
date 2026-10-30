import XCTest

@MainActor
final class LinkedScheduleUITests: XCTestCase {
    func testLinkedCapsuleOpensRealDetailAndSearchReplacesIt() {
        continueAfterFailure = false
        let app = XCUIApplication()
        let common = ["-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN",
                      "-ui-testing", "-ui-testing-ipad", "--ui-test-skip-onboarding",
                      "--ui-test-task-management-fixture"]
        app.launchArguments = common + ["--ui-test-linked-schedule"]
        app.launch()
        defer {
            app.terminate()
            app.launchArguments = common + ["--ui-test-linked-schedule-cleanup"]
            app.launch()
            XCTAssertTrue(app.buttons["globalSearch.open"].waitForExistence(timeout: 30))
            app.terminate()
        }
        let row = app.descendants(matching: .any)
            .matching(identifier: "sidebar.conversation.A1D4A0F2-6F2E-4E7A-9C31-0B7C51E6A003").firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 30))
        row.tap()
        let capsule = app.buttons["thread.scheduleCapsule"]
        XCTAssertTrue(capsule.waitForExistence(timeout: 15))
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "Linked plan capsule with nearest time and additional plan count"
        attachment.lifetime = .keepAlways
        add(attachment)
        capsule.tap()
        XCTAssertTrue(app.buttons["schedule.detail.menu"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["UI 关联计划 1"].firstMatch.exists)
        app.buttons["取消"].firstMatch.tap()
        XCTAssertTrue(capsule.waitForExistence(timeout: 10))
        app.buttons["thread.inspector.menu"].tap()
        app.buttons["thread.find.menu"].tap()
        XCTAssertTrue(app.textFields["thread.find.field"].waitForExistence(timeout: 10))
        XCTAssertFalse(capsule.exists)
        app.buttons["thread.find.done"].tap()
        XCTAssertTrue(capsule.waitForExistence(timeout: 10))
    }
}
