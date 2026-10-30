import XCTest
import UIKit

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
        // The reused simulator preserves many workspace groups above the
        // Chats section, so chat rows stay lazy until realized. Scroll only
        // the native sidebar list and tap the synthetic row's verified frame.
        let sidebar = app.descendants(matching: .any)
            .matching(identifier: "sidebar.list").firstMatch
        XCTAssertTrue(sidebar.waitForExistence(timeout: 30))
        let row = app.descendants(matching: .any)
            .matching(identifier: "sidebar.conversation.A1D4A0F2-6F2E-4E7A-9C31-0B7C51E6A003").firstMatch
        func rowIsVisible() -> Bool {
            guard row.exists else { return false }
            let frame = row.frame
            let point = CGPoint(x: frame.midX, y: frame.midY)
            return frame.width > 0 && frame.height > 0
                && point.x.isFinite && point.y.isFinite
                && sidebar.frame.contains(point) && app.windows.firstMatch.frame.contains(point)
        }
        for _ in 0..<20 where !rowIsVisible() { sidebar.swipeUp() }
        for _ in 0..<20 where !rowIsVisible() { sidebar.swipeDown() }
        XCTAssertTrue(rowIsVisible(),
                      "the synthetic linked-schedule conversation must be reachable in the sidebar")
        let screen = app.windows.firstMatch.frame
        app.windows.firstMatch.coordinate(withNormalizedOffset: .zero)
            .withOffset(CGVector(dx: row.frame.midX - screen.minX,
                                 dy: row.frame.midY - screen.minY))
            .tap()
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
        let findRow = app.buttons["thread.find.menu"]
        XCTAssertTrue(findRow.waitForExistence(timeout: 10))
        findRow.tap()
        // A synthesized tap at this SwiftUI menu row's exact centre can be
        // lost while the menu stays presented (UI4: (624, 59) pt was the
        // centre of the 224x38 row, yet the menu remained open and find
        // never opened; the identical tap worked in UI3). A retry is only
        // attempted while that menu is still on screen, which proves the
        // first activation never reached the row; the real find field must
        // still appear.
        if !app.textFields["thread.find.field"].waitForExistence(timeout: 3),
           findRow.exists {
            findRow.tap()
        }
        XCTAssertTrue(app.textFields["thread.find.field"].waitForExistence(timeout: 10))
        XCTAssertFalse(capsule.exists)
        app.buttons["thread.find.done"].tap()
        XCTAssertTrue(capsule.waitForExistence(timeout: 10))
    }
}
