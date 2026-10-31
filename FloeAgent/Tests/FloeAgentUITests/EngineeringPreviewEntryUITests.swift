// SPDX-License-Identifier: MPL-2.0
// FloeAgentUITests — native engineering preview entry-route qualification.
//
// These tests drive the six REAL product entry surfaces over ONE owned,
// asymmetric FloeCAD GLB export:
//   1. ordinary chat attachment chip -> ChatAttachmentOpenSheet -> FilePreviewView
//   2. tool-output card -> RunOutputFilesCard -> EngineeringPreviewURLView
//   3. Files tab row -> preview action -> EngineeringPreviewURLView
//   4. workspace file tree -> FileInspectorView -> FilePreviewView
//   5. IDE document tab -> FilePreviewView
//   6. Canvas file node -> explicit preview action -> EngineeringPreviewURLView
//
// The App fixture seeds only its own synthetic conversation/workspace, run
// receipt, Files recent attachment and canvas node. The readiness assertion
// reads the live scene state published by the bundled WebGL page (ready flag,
// parsed node/mesh count and source SHA-256), so a title-only navigation or a
// Quick Look window cannot pass. Root owns the actual visual judgment and the
// before/after source-byte inspection; this file records screenshots only.

#if canImport(XCTest)
import XCTest

@MainActor
final class EngineeringPreviewEntryUITests: XCTestCase {
    private let attachmentID = "E1A6C0DE-7E31-4A10-9E8D-3A2B6C4D5E03"
    private let canvasNodeID = "E1A6C0DE-7E31-4A10-9E8D-3A2B6C4D5E06"

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    override func tearDownWithError() throws {
        // Each test owns its launched process; terminate even on failure.
        if let app {
            app.terminate()
        }
        app = nil
    }

    private var app: XCUIApplication?

    func test01OrdinaryAttachmentUsesSharedEngineeringPreview() throws {
        let app = launch("attachment")
        let chip = app.buttons["thread.attachment.\(attachmentID)"]
        for _ in 0..<3 where !chip.exists {
            app.swipeDown()
        }
        XCTAssertTrue(chip.waitForExistence(timeout: 90),
                      "the real chat attachment chip must be reachable")
        chip.tap()
        assertSharedEngineeringPreview(app, screenshotName: "entry-01-attachment")
    }

    func test02ToolOutputCardUsesSharedEngineeringPreview() throws {
        let app = launch("toolOutput")
        let preview = app.buttons["chat.runOutput.preview"].firstMatch
        for _ in 0..<4 where !preview.exists {
            app.swipeDown()
        }
        XCTAssertTrue(preview.waitForExistence(timeout: 90),
                      "the verified run-output card must expose its preview action")
        preview.tap()
        assertSharedEngineeringPreview(app, screenshotName: "entry-02-tool-output")
        dismissURLPreview(app)
    }

    func test03FilesRecentRowUsesSharedEngineeringPreview() throws {
        let app = launch("files")
        var menu = app.buttons["files.row.menu"].firstMatch
        if !menu.waitForExistence(timeout: 10) {
            menu = app.buttons["More"].firstMatch
        }
        XCTAssertTrue(menu.waitForExistence(timeout: 90),
                      "the Files recent row menu must be reachable")
        menu.tap()
        var preview = app.buttons["files.row.preview"].firstMatch
        if !preview.waitForExistence(timeout: 5) {
            preview = app.buttons.matching(
                NSPredicate(format: "label CONTAINS[c] %@", "Preview")).firstMatch
        }
        XCTAssertTrue(preview.waitForExistence(timeout: 20),
                      "the Files row must direct engineering files to preview")
        preview.tap()
        assertSharedEngineeringPreview(app, screenshotName: "entry-03-files")
        dismissURLPreview(app)
    }

    func test04WorkspaceTreeUsesSharedEngineeringPreview() throws {
        let app = launch("workspace")
        let row = app.buttons["fileTree.row.EngineeringEntryPlate.glb"].firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 90),
                      "the workspace file tree must list the fixture model")
        row.tap()
        assertSharedEngineeringPreview(app, screenshotName: "entry-04-workspace")
    }

    func test05IDEDocumentTabUsesSharedEngineeringPreview() throws {
        let app = launch("ide")
        let documentTab = app.buttons["workspace.ide.tab.document"].firstMatch
        XCTAssertTrue(documentTab.waitForExistence(timeout: 90),
                      "the IDE must route the model to a document tab, not the code editor")
        assertSharedEngineeringPreview(app, screenshotName: "entry-05-ide")
    }

    func test06CanvasFileNodeUsesExplicitSharedPreview() throws {
        let app = launch("canvas")
        let onboarding = app.descendants(matching: .any)["canvas.onboarding"].firstMatch
        if onboarding.waitForExistence(timeout: 5) {
            app.buttons["Close"].firstMatch.tap()
        }
        let node = app.descendants(matching: .any)["canvas.node.\(canvasNodeID)"].firstMatch
        XCTAssertTrue(node.waitForExistence(timeout: 90),
                      "the canvas must present its real file node")
        node.tap()
        let previewAction = app.buttons["canvas.toolbar.previewEngineering"].firstMatch
        XCTAssertTrue(previewAction.waitForExistence(timeout: 30),
                      "the selected canvas file node must expose the shared preview action")
        previewAction.tap()
        assertSharedEngineeringPreview(app, screenshotName: "entry-06-canvas")
        dismissURLPreview(app)
    }

    // MARK: - Launch / assertions

    private func launch(_ route: String) -> XCUIApplication {
        XCUIDevice.shared.orientation = .landscapeLeft
        let app = XCUIApplication()
        app.launchArguments = [
            "-AppleLanguages", "(en)",
            "-AppleLocale", "en_US",
            "-ui-testing",
            "-ui-testing-ipad",
            "--ui-test-engineering-entry-fixture",
            "--ui-test-engineering-entry-route=\(route)",
        ]
        app.launchEnvironment[EngineeringPreviewEntryFixtureAsset.environmentKey] =
            EngineeringPreviewEntryFixtureAsset.base64
        app.launchEnvironment[EngineeringPreviewEntryFixtureAsset.shaEnvironmentKey] =
            EngineeringPreviewEntryFixtureAsset.sha256
        app.launch()
        self.app = app
        let fixture = app.descendants(matching: .any)["engineeringEntryFixture"].firstMatch
        XCTAssertTrue(fixture.waitForExistence(timeout: 60),
                      "the engineering entry fixture must launch")
        let failure = app.descendants(matching: .any)["engineeringEntryFixture.error"].firstMatch
        if failure.waitForExistence(timeout: 3) {
            XCTFail("engineering entry fixture failed: \(failure.label)")
        }
        return app
    }

    private func assertSharedEngineeringPreview(
        _ app: XCUIApplication,
        screenshotName: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let preview = app.descendants(matching: .any)["file.preview.engineering"].firstMatch
        XCTAssertTrue(preview.waitForExistence(timeout: 120),
                      "the shared engineering preview must be mounted",
                      file: file, line: line)
        XCTAssertTrue(app.webViews.firstMatch.waitForExistence(timeout: 60),
                      "the preview must contain its real WKWebView, not a title-only stub",
                      file: file, line: line)

        let readiness = app.descendants(matching: .any)["engineering.scene.readiness"].firstMatch
        XCTAssertTrue(readiness.waitForExistence(timeout: 60),
                      "the live scene state probe must be mounted",
                      file: file, line: line)
        let expectedSHA = EngineeringPreviewEntryFixtureAsset.sha256
        let predicate = NSPredicate { object, _ in
            guard let element = object as? XCUIElement,
                  let value = element.value as? String else { return false }
            return value.contains("ready=true")
                && value.contains("source=\(expectedSHA)")
                && value.contains("geometry=true")
        }
        let expectation = XCTNSPredicateExpectation(predicate: predicate, object: readiness)
        let result = XCTWaiter.wait(for: [expectation], timeout: 120)
        XCTAssertEqual(result, .completed,
                       "the real WebGL scene did not report the intended source and geometry; value=\(String(describing: readiness.value))",
                       file: file, line: line)

        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        shot.name = screenshotName
        shot.lifetime = .keepAlways
        add(shot)
    }

    private func dismissURLPreview(_ app: XCUIApplication) {
        let done = app.buttons["engineering.preview.done"].firstMatch
        if done.waitForExistence(timeout: 10) {
            done.tap()
            XCTAssertFalse(app.descendants(matching: .any)["file.preview.engineering"]
                .firstMatch.waitForExistence(timeout: 8),
                           "dismissing the read-only preview must return to its entry surface")
        }
    }
}
#endif
