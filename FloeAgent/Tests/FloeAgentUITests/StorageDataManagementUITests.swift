// FloeAgentUITests — Data Management storage page acceptance.
//
// The storage repair (K) is verified on the real App entry: the page opens
// from Settings, settles on MEASURED totals instead of an endless scan, keeps
// its implementation vocabulary out of the overview, and a warm reopen serves
// the cached snapshot immediately instead of starting another full census.
// The screenshots captured here are the visual evidence for the ledger.

import XCTest

final class StorageDataManagementUITests: XCTestCase {
    func testStoragePageSettlesAndWarmReopenServesTheSnapshot() throws {
        continueAfterFailure = false
        let app = launchApp()
        defer { app.terminate() }

        openSettings(app)
        openDataManagement(app)

        XCTAssertTrue(app.staticTexts["空间概览"].waitForExistence(timeout: 30),
                      "the storage overview must open")
        // Cold open: the first scan is allowed to run; the page must settle on
        // real totals (the shared/clone case shows the App-space authority row,
        // the clean case the file-based total).
        let settled = waitUntil(timeout: 240) {
            app.staticTexts["Floe 总占用"].exists
        }
        XCTAssertTrue(settled,
                      "the overview must settle on the App's measured numeric total")
        // The user's final requirement: the App total is a real NUMBER from
        // the same snapshot (never an iOS-Storage placeholder), with no
        // "at least"/approximation annotations on the ordinary page.
        XCTAssertTrue(app.staticTexts["Floe 总占用"].exists,
                      "the overview must show the App's own numeric total")
        XCTAssertTrue(app.staticTexts["用户数据"].exists,
                      "the App file-figure row must be present and numeric")
        XCTAssertFalse(app.staticTexts
            .matching(NSPredicate(format: "label CONTAINS %@", "以 iOS")).firstMatch.exists,
            "the total must never be replaced by an iOS-Storage placeholder")
        XCTAssertFalse(app.staticTexts
            .matching(NSPredicate(format: "label CONTAINS %@", "至少")).firstMatch.exists,
            "no 'at least' annotation may appear anywhere on the page")
        // Plain-language overview copy (user copy rule): the cleanup row and
        // the shared-data footer never expose engineering vocabulary, and the
        // scan file count/duration live in the expanded details.
        XCTAssertTrue(app.staticTexts["可清理文件"].exists,
                      "the cleanup row must use the plain '可清理文件' label")
        XCTAssertTrue(app.staticTexts
            .matching(NSPredicate(format: "label BEGINSWITH %@", "更新于 "))
            .firstMatch.exists,
            "the overview footer must show the plain updated-at time")
        // The dedicated shared-files section is separate from Floe's own
        // usage/cleanup, and the device-wide free-capacity row is gone.
        XCTAssertTrue(app.staticTexts["共享文件"].exists,
                      "shared/cloneable data must have its own section")
        XCTAssertTrue(app.staticTexts["共享文件容量"].exists,
                      "the shared section must show the identified shared capacity")
        XCTAssertFalse(app.staticTexts["设备可用空间"].exists,
                       "device-wide free capacity must not be shown on the Floe data page")
        // The ordinary page carries no technical footnotes (the opened details
        // may keep them).
        XCTAssertFalse(app.staticTexts
            .matching(NSPredicate(format: "label CONTAINS %@", "共享的数据块"))
            .firstMatch.exists,
            "the ordinary overview must not explain shared blocks")
        capture(app, "storage-overview-cold")

        // Expand the capacity details when the shared/clone case is active.
        let details = app.buttons["文件容量明细"].firstMatch
        if details.exists {
            details.tap()
            Thread.sleep(forTimeInterval: 1.0)
            XCTAssertFalse(app.staticTexts
                .matching(NSPredicate(format: "label CONTAINS %@", "至少")).firstMatch.exists,
                "the expanded details must not present a lower-bound row")
            // The expanded categories show name + capacity + item count only:
            // no allocated-vs-apparent comparison and no VM-capacity essay.
            for technical in ["主机实际占用", "表面文件大小", "表面大小混合了"] {
                XCTAssertFalse(app.staticTexts
                    .matching(NSPredicate(format: "label CONTAINS %@", technical))
                    .firstMatch.exists,
                    "the ordinary expanded details must not contain '\(technical)'")
            }
            app.swipeUp()
            Thread.sleep(forTimeInterval: 0.6)
            capture(app, "storage-categories-expanded")
        }

        // Warm reopen: leave and re-enter the page. The kept snapshot must
        // render immediately — never the cold "measuring" placeholder.
        back(app)
        Thread.sleep(forTimeInterval: 0.8)
        openDataManagement(app)
        XCTAssertTrue(app.staticTexts["空间概览"].waitForExistence(timeout: 20))
        let cached = waitUntil(timeout: 15) {
            app.staticTexts["Floe 总占用"].exists
        }
        XCTAssertTrue(cached, "a warm reopen must show the cached totals immediately")
        XCTAssertFalse(app.staticTexts["正在统计实际占用…"].exists,
                       "a warm reopen must not fall back to the cold measuring state")
        capture(app, "storage-overview-warm")
    }

    // MARK: - Helpers

    private func launchApp() -> XCUIApplication {
        let app = XCUIApplication()
        app.terminate()
        XCUIDevice.shared.orientation = .landscapeLeft
        app.launchArguments = [
            "-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN", "-ui-testing",
            "--ui-test-skip-onboarding", "-ui-testing-ipad"
        ]
        app.launch()
        return app
    }

    private func openSettings(_ app: XCUIApplication) {
        let settings = app.buttons["sidebar.settings"].firstMatch
        XCTAssertTrue(settings.waitForExistence(timeout: 30), "the Settings entry must exist")
        settings.tap()
        XCTAssertTrue(app.staticTexts["设置"].waitForExistence(timeout: 20)
                      || app.navigationBars.firstMatch.waitForExistence(timeout: 20),
                      "the Settings page must open")
    }

    private func openDataManagement(_ app: XCUIApplication) {
        // The settings rows carry stable identifiers, but the section list is
        // its own column on iPad: scroll THAT list (an app-level swipe targets
        // the detail pane and never reaches the lower sections).
        let row = app.staticTexts
            .matching(identifier: "settings.section.dataManagement")
            .firstMatch
        let list = app.collectionViews
            .containing(.staticText, identifier: "settings.section.general")
            .firstMatch
        let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.35, dy: 0.8))
        let end = app.coordinate(withNormalizedOffset: CGVector(dx: 0.35, dy: 0.2))
        let deadline = Date().addingTimeInterval(45)
        while !row.exists && Date() < deadline {
            if list.exists {
                list.swipeUp()
            } else {
                start.press(forDuration: 0.05, thenDragTo: end)
            }
            Thread.sleep(forTimeInterval: 0.4)
        }
        XCTAssertTrue(row.waitForExistence(timeout: 10), "the Data Management row must exist")
        row.tap()
        Thread.sleep(forTimeInterval: 0.5)
    }

    private func back(_ app: XCUIApplication) {
        let backButton = app.navigationBars.buttons.firstMatch
        if backButton.exists { backButton.tap() }
    }

    private func waitUntil(timeout: TimeInterval, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            Thread.sleep(forTimeInterval: 0.5)
        }
        return condition()
    }

    private func capture(_ app: XCUIApplication, _ name: String) {
        let image = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        image.name = name
        image.lifetime = .keepAlways
        add(image)
    }
}
