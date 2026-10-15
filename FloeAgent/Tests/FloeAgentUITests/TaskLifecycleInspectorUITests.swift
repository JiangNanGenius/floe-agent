// FloeAgentUITests — task-lifecycle inspector acceptance.
//
// Drives the REAL App UI over the synthetic lifecycle fixture
// (`--ui-test-lifecycle-fixture`): the delegate card must open the SPECIFIC
// durable child transcript (not the list), the long child finding must be
// expandable, and the progress inspector must show the retained job output
// through the bounded pager. Screenshots are attached for the primary review.

import XCTest
import UIKit

@MainActor
final class TaskLifecycleInspectorUITests: XCTestCase {

    private let fixtureRow = "sidebar.conversation.7A1E22C4-3B0F-4A5D-9E62-1C8F3D5B7B32"
    private let jobID = "7A1E22C4-3B0F-4A5D-9E62-1C8F3D5B7E65"

    private func launch() -> XCUIApplication {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments += ["-ui-testing", "--ui-test-lifecycle-fixture"]
        if UIDevice.current.userInterfaceIdiom == .pad {
            app.launchArguments.append("-ui-testing-ipad")
        }
        app.launch()
        return app
    }

    private func attach(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    /// Opens the fixture conversation from the sidebar (drawer-aware).
    private func openFixtureThread(_ app: XCUIApplication) {
        let row = app.descendants(matching: .any)[fixtureRow].firstMatch
        if !row.isHittable {
            let drawer = app.buttons["phone.sidebar.open"]
            if drawer.waitForExistence(timeout: 5) { drawer.tap() }
        }
        let sidebar = app.collectionViews.firstMatch
        var scrolls = 0
        while !row.isHittable, sidebar.exists, scrolls < 6 {
            sidebar.swipeUp()
            scrolls += 1
        }
        scrolls = 0
        while !row.isHittable, sidebar.exists, scrolls < 8 {
            sidebar.swipeDown()
            scrolls += 1
        }
        XCTAssertTrue(row.waitForExistence(timeout: 10), "fixture conversation row")
        row.tap()
    }

    func testDelegateCardOpensTheSpecificChildTranscriptAndExpandsTheFinding() {
        let app = launch()
        openFixtureThread(app)

        // The card is not an accessibility container: the View action is the
        // single element with this identifier (a duplicate container element
        // used to swallow the hit target).
        let viewChild = app.buttons["thread.delegate.viewChild.action"].firstMatch
        XCTAssertTrue(viewChild.waitForExistence(timeout: 15), "delegate card view action")
        XCTAssertTrue(viewChild.isHittable, "View action must be tappable")
        attach(app, "ipad-thread-delegate-card")
        viewChild.tap()

        // The destination must be the SPECIFIC child transcript (its own
        // navigation title), never the child-agents list.
        let transcriptZH = app.navigationBars["记录"].firstMatch
        let transcriptEN = app.navigationBars["Transcript"].firstMatch
        let arrived = transcriptZH.waitForExistence(timeout: 8) || transcriptEN.exists
        XCTAssertTrue(arrived, "child transcript sheet must open")
        attach(app, "ipad-child-transcript")

        // The SPECIFIC durable child transcript (not the child list): its
        // tool pair and 14-line result are visible.
        let toggle = app.descendants(matching: .any)["inspector.childEntry.toggle"].firstMatch
        XCTAssertTrue(toggle.waitForExistence(timeout: 10), "child result expand control")
        XCTAssertTrue(app.staticTexts.containing(
            NSPredicate(format: "label CONTAINS %@", "发现 1：")).firstMatch
            .waitForExistence(timeout: 8), "child finding preview")
        attach(app, "ipad-child-transcript-collapsed")
        toggle.tap()
        XCTAssertTrue(app.staticTexts.containing(
            NSPredicate(format: "label CONTAINS %@", "发现 14：")).firstMatch
            .waitForExistence(timeout: 8), "expanded child finding must reach the last line")
        attach(app, "ipad-child-transcript-expanded")
    }

    func testProgressInspectorShowsTheRetainedJobOutput() {
        let app = launch()
        openFixtureThread(app)

        let menu = app.descendants(matching: .any)["thread.inspector.menu"].firstMatch
        XCTAssertTrue(menu.waitForExistence(timeout: 15), "inspector menu entry")
        menu.tap()
        let progress = app.descendants(matching: .any)["thread.inspector.open.progress"].firstMatch
        XCTAssertTrue(progress.waitForExistence(timeout: 8), "progress inspector entry")
        progress.tap()

        let openOutput = app.descendants(matching: .any)["inspector.job.fullOutput.\(jobID)"].firstMatch
        XCTAssertTrue(openOutput.waitForExistence(timeout: 15), "retained output action")
        attach(app, "ipad-progress-inspector-jobs")
        openOutput.tap()

        // The complete retained output is reachable through the bounded pager.
        let nextPage = app.descendants(matching: .any)["inspector.job.fullOutput.nextPage"].firstMatch
        XCTAssertTrue(nextPage.waitForExistence(timeout: 10), "full-output pager")
        attach(app, "ipad-job-output-page1")
        nextPage.tap()
        XCTAssertTrue(app.staticTexts.containing(
            NSPredicate(format: "label CONTAINS %@", "第")).firstMatch
            .waitForExistence(timeout: 8), "second output page")
        attach(app, "ipad-job-output-page2")
    }
}
