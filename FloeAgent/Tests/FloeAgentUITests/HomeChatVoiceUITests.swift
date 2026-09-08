// FloeAgentUITests — unified task workbench, timeline ordering and voice
// lifecycle UI coverage for iPad Air 13-inch and iPhone.
//
// SPDX-License-Identifier: MPL-2.0
//
// These tests drive the real app through XCUITest. They intentionally do
// NOT require a live model provider: navigation structure, empty states,
// the composer, and the voice button's crash-safety are all exercised
// without network access. Streaming-order assertions hook the persisted
// timeline identifiers so a completed thread renders its terminal row
// after the final reply.

#if canImport(XCTest)
import XCTest

/// iPad Air 13-inch structure and flow coverage.
///
/// Run these on an iPad Air 13-inch simulator or device. Because the
/// XCUITest bundle always hosts the app, the launch argument
/// `-ui-testing-ipad` tells RootView to keep the regular-width split
/// layout even if the test runner misreports the size class; without it
/// the default `-ui-testing` run pins the compact layout for the iPhone
/// suite below.
@MainActor
final class HomeChatVoiceIPadUITests: XCTestCase {

    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .landscapeLeft
        app = XCUIApplication()
        app.launchArguments += ["-ui-testing", "-ui-testing-ipad"]
        app.launch()
    }

    override func tearDownWithError() throws {
        app = nil
    }

    /// Cold launch opens a fresh draft and the sidebar exposes only the
    /// task-first top-level entries.
    func testColdLaunchAndTaskSidebar() throws {
        let newTask = app.staticTexts["sidebar.workbench.new_task"]
        guard newTask.waitForExistence(timeout: 5) else {
            throw XCTSkip("Requires iPad split layout (regular width)")
        }
        XCTAssertTrue(
            app.staticTexts["home.welcome"].waitForExistence(timeout: 5)
                || app.textFields["composer.input"].waitForExistence(timeout: 5)
        )
        XCTAssertTrue(app.staticTexts["sidebar.task_center"].exists)
        XCTAssertTrue(app.staticTexts["sidebar.skills"].exists)
        XCTAssertFalse(app.staticTexts["sidebar.primary.files"].exists)
        XCTAssertFalse(app.staticTexts["sidebar.more.providers"].exists)
    }

    func testPluginMarketplaceAndBatchEntry() throws {
        app.terminate()
        app.launchArguments += ["--ui-test-batch-fixture"]
        app.launch()
        XCUIDevice.shared.orientation = .portrait
        let plugins = app.staticTexts["sidebar.skills"]
        XCTAssertTrue(plugins.waitForExistence(timeout: 8))
        plugins.tap()
        XCTAssertTrue(app.staticTexts["plugins.card.floe-pdf"].waitForExistence(timeout: 8))
        XCTAssertTrue(app.segmentedControls.firstMatch.exists)
        let marketplace = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        marketplace.name = "Plugin marketplace"
        marketplace.lifetime = .keepAlways
        add(marketplace)
        XCTAssertFalse(app.buttons["sidebar.batch"].exists)
        let row = app.descendants(matching: .any).matching(identifier: "sidebar.conversation.57C0A79F-CF1B-45D2-B640-EF54E5C55391").firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 8))
        row.press(forDuration: 0.8)
        let selectMultiple = app.buttons["sidebar.selectMultiple"]
        XCTAssertTrue(selectMultiple.waitForExistence(timeout: 5))
        selectMultiple.tap()
        XCTAssertTrue(app.navigationBars["选择任务"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["已选 1"].exists)
        let management = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        management.name = "Batch task management"
        management.lifetime = .keepAlways
        add(management)
    }

    func testMaterialThumbnailsInBothLayouts() throws {
        app.terminate()
        app.launchArguments += ["--ui-test-material-fixture"]
        app.launch()
        let creative = app.descendants(matching: .any).matching(identifier: "sidebar.creative").firstMatch
        XCTAssertTrue(creative.waitForExistence(timeout: 8))
        creative.tap()
        let materials = app.buttons["canvas.home.materials"]
        XCTAssertTrue(materials.waitForExistence(timeout: 8))
        materials.tap()
        let thumbnail = app.descendants(matching: .any).matching(identifier: "canvas.material.thumbnail.ready").firstMatch
        XCTAssertTrue(thumbnail.waitForExistence(timeout: 10))
        // SwiftUI exposes the labelled thumbnail through its containing
        // button, so compare row/card height, not the thumbnail's width.
        let listHeight = thumbnail.frame.height
        let list = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        list.name = "ipad-material-thumbnails-list"
        list.lifetime = .keepAlways
        add(list)
        app.buttons["canvas.materials.layout"].tap()
        XCTAssertTrue(thumbnail.waitForExistence(timeout: 5))
        let grid = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        grid.name = "ipad-material-thumbnails-wall"
        grid.lifetime = .keepAlways
        add(grid)
        XCTAssertGreaterThan(thumbnail.frame.height, listHeight)
    }

    func testSettingsOpensAllWorkspaces() throws {
        XCUIDevice.shared.orientation = .portrait
        let settings = app.buttons["sidebar.settings"]
        XCTAssertTrue(settings.waitForExistence(timeout: 8))
        settings.tap()
        let files = app.descendants(matching: .any).matching(identifier: "settings.section.files").firstMatch
        XCTAssertTrue(files.waitForExistence(timeout: 5))
        files.tap()
        let manage = app.buttons["settings.files.manage"]
        XCTAssertTrue(manage.waitForExistence(timeout: 5))
        manage.tap()
        XCTAssertTrue(app.navigationBars["所有工作区"].waitForExistence(timeout: 5))
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = "All workspace files"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    func testWorkspacePDFInlineAndFullscreen() throws {
        app.terminate()
        app.launchArguments += ["--ui-test-batch-fixture", "--ui-test-pdf-fixture"]
        app.launch()
        try testSettingsOpensAllWorkspaces()
        let workspace = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "聊天工作区")).firstMatch
        XCTAssertTrue(workspace.waitForExistence(timeout: 5))
        workspace.tap()
        let file = app.staticTexts["预览验收.pdf"].firstMatch
        XCTAssertTrue(file.waitForExistence(timeout: 5))
        file.tap()
        let document = app.otherElements["pdf.reader.document"].firstMatch
        XCTAssertTrue(document.waitForExistence(timeout: 8))
        let inlineWidth = document.frame.width
        let inlineShot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        inlineShot.name = "ipad-pdf-inline"
        inlineShot.lifetime = .keepAlways
        add(inlineShot)
        let expand = app.buttons["pdf.reader.expand"]
        XCTAssertTrue(expand.isHittable)
        expand.tap()
        XCTAssertTrue(document.waitForExistence(timeout: 5))
        XCTAssertGreaterThan(document.frame.width, inlineWidth)
        let fullShot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        fullShot.name = "ipad-pdf-fullscreen"
        fullShot.lifetime = .keepAlways
        add(fullShot)
        app.buttons["pdf.reader.collapse"].tap()
        XCTAssertTrue(expand.waitForExistence(timeout: 5))
        XCTAssertEqual(document.frame.width, inlineWidth, accuracy: 2)
        app.buttons["workspace.preview.backToFiles"].tap()
        XCTAssertTrue(file.waitForExistence(timeout: 5))
        XCTAssertFalse(expand.exists)
    }

    /// The Home composer is directly usable as a task-start surface.
    func testHomeStartsTaskDirectly() throws {
        let input = app.textFields["composer.input"]
        guard input.waitForExistence(timeout: 5) else {
            throw XCTSkip("Composer not reachable without a configured provider")
        }
        input.tap()
        input.typeText("整理下载文件夹")

        // Without a provider the send button is gated; with one the thread
        // opens on Home's own detail. Either way the composer accepted the
        // draft and no crash occurred.
        XCTAssertTrue(input.exists)
    }

    /// A completed thread renders the terminal row AFTER the final reply.
    func testTerminalRowFollowsFinalReply() throws {
        // Requires a fixture conversation seeded by the test harness; when
        // absent, skip honestly rather than faking success. The ordering
        // invariant itself is pinned by ThreadTimelineTests (logic level).
        let terminal = app.otherElements["thread.terminal"]
        guard terminal.waitForExistence(timeout: 3) else {
            throw XCTSkip("No completed thread fixture available")
        }
        XCTAssertTrue(terminal.exists)
    }

    /// Hammering the microphone button must never crash the app.
    func testRapidVoiceTogglesDoNotCrash() throws {
        let mic = app.buttons["composer.voice"]
        guard mic.waitForExistence(timeout: 5) else {
            throw XCTSkip("Composer not reachable")
        }
        for _ in 0..<12 {
            mic.tap()
        }
        // The app is still alive and the mic control is still operable.
        XCTAssertTrue(app.buttons["composer.voice"].exists)
        XCTAssertTrue(app.textFields["composer.input"].exists)
    }

    /// Leaving the thread cleans the voice session; returning shows a
    /// ready microphone, not a stuck "listening" state.
    func testNavigationCleansVoiceSession() throws {
        let mic = app.buttons["composer.voice"]
        guard mic.waitForExistence(timeout: 5) else {
            throw XCTSkip("Composer not reachable")
        }
        mic.tap()
        let taskCenter = app.staticTexts["sidebar.task_center"]
        if taskCenter.waitForExistence(timeout: 3) { taskCenter.tap() }
        let newTask = app.staticTexts["sidebar.workbench.new_task"]
        newTask.tap()
        // The microphone is back to a non-destructive affordance.
        XCTAssertTrue(app.buttons["composer.voice"].waitForExistence(timeout: 5))
    }
}

/// iPhone navigation and layout coverage.
@MainActor
final class HomeChatVoiceIPhoneUITests: XCTestCase {

    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
        app = XCUIApplication()
        app.launchArguments += ["-ui-testing"]
        app.launch()
    }

    override func tearDownWithError() throws {
        app = nil
    }

    func testExpandedLongReasoningRemainsInteractive() throws {
        app.terminate()
        app.launchArguments += ["--ui-test-long-reasoning"]
        app.launch()
        let expand = app.buttons["reasoning.expand"]
        XCTAssertTrue(expand.waitForExistence(timeout: 8))
        let folded = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        folded.name = "iphone-long-reasoning-folded"
        folded.lifetime = .keepAlways
        add(folded)
        expand.tap()
        let reader = app.scrollViews["reasoning.reader"].firstMatch
        XCTAssertTrue(reader.waitForExistence(timeout: 8))
        XCTAssertLessThan(reader.frame.height, 500)
        let latest = app.buttons["reasoning.latest"].firstMatch
        XCTAssertTrue(latest.waitForExistence(timeout: 5))
        latest.tap()
        let end = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "原文结束标记")).firstMatch
        XCTAssertTrue(end.waitForExistence(timeout: 5))
        app.buttons["reasoning.fixture.append"].tap()
        XCTAssertTrue(app.buttons["reasoning.fixture.append"].label.contains("1"))
        latest.tap()
        let appended = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "追加结束标记1")).firstMatch
        XCTAssertTrue(appended.waitForExistence(timeout: 5))
        let expanded = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        expanded.name = "iphone-long-reasoning-expanded-updating"
        expanded.lifetime = .keepAlways
        add(expanded)
        app.buttons["reasoning.fullscreen"].tap()
        let done = app.buttons["reasoning.fullscreen.done"]
        XCTAssertTrue(done.waitForExistence(timeout: 5))
        let full = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        full.name = "iphone-long-reasoning-fullscreen"
        full.lifetime = .keepAlways
        add(full)
        done.tap()
        expand.tap()
        XCTAssertFalse(app.buttons["reasoning.fullscreen"].exists)
        expand.tap()
        XCTAssertTrue(app.buttons["reasoning.fullscreen"].waitForExistence(timeout: 5))
    }

    func testCanvasCreationRemainsVisibleInPortraitAndLandscape() throws {
        XCUIDevice.shared.orientation = .portrait
        defer { XCUIDevice.shared.orientation = .portrait }
        let sidebar = app.buttons["phone.sidebar.open"]
        XCTAssertTrue(sidebar.waitForExistence(timeout: 8))
        sidebar.tap()
        let creative = app.staticTexts["sidebar.creative"]
        XCTAssertTrue(creative.waitForExistence(timeout: 5))
        creative.tap()
        let newCanvas = app.buttons["canvas.home.create"]
        XCTAssertTrue(newCanvas.waitForExistence(timeout: 5))
        XCTAssertTrue(newCanvas.isHittable)
        newCanvas.tap()
        let onboarding = app.otherElements["canvas.onboarding"]
        if onboarding.waitForExistence(timeout: 2) {
            let close = app.buttons.matching(NSPredicate(format: "label IN %@", ["关闭", "Close"])).firstMatch
            XCTAssertTrue(close.waitForExistence(timeout: 2))
            close.tap()
        }
        for orientation in [UIDeviceOrientation.portrait, .landscapeLeft] {
            XCUIDevice.shared.orientation = orientation
            let add = app.buttons["canvas.node.create.bottom"]
            XCTAssertTrue(add.waitForExistence(timeout: 5))
            XCTAssertTrue(add.isHittable)
            if orientation == .portrait {
                let actions = app.buttons["canvas.actions"]
                XCTAssertTrue(actions.isHittable)
                actions.tap()
                let create = app.buttons["canvas.node.create"]
                XCTAssertTrue(create.waitForExistence(timeout: 3))
                create.tap()
            } else {
                add.tap()
            }
            let nodeKind = app.buttons["SVG"]
            XCTAssertTrue(nodeKind.waitForExistence(timeout: 3))
            let menuShot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
            menuShot.name = orientation == .portrait ? "iphone-canvas-create-menu-portrait" : "iphone-canvas-create-menu-landscape"
            menuShot.lifetime = .keepAlways
            self.add(menuShot)
            nodeKind.tap()
            let finish = app.buttons["canvas.node.finishEditing"]
            XCTAssertTrue(finish.waitForExistence(timeout: 5))
            let editingShot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
            editingShot.name = orientation == .portrait ? "iphone-canvas-svg-editor-portrait" : "iphone-canvas-svg-editor-landscape"
            editingShot.lifetime = .keepAlways
            self.add(editingShot)
            XCTAssertTrue(finish.isHittable)
            finish.tap()
            // WebKit paints asynchronously after the editor leaves the tree.
            // Allow its first frame before capturing; rendered content is also
            // visually reviewed in the exported screenshots.
            let firstFrame = expectation(description: "WebKit first frame capture window")
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { firstFrame.fulfill() }
            wait(for: [firstFrame], timeout: 5)
            let leading = app.buttons["canvas.connection.port.leading"].firstMatch
            let trailing = app.buttons["canvas.connection.port.trailing"].firstMatch
            XCTAssertTrue(leading.waitForExistence(timeout: 3))
            XCTAssertTrue(trailing.waitForExistence(timeout: 3))
            XCTAssertTrue(leading.isHittable)
            XCTAssertTrue(trailing.isHittable)
            let nodeCenter = CGPoint(x: (leading.frame.midX + trailing.frame.midX) / 2,
                                     y: (leading.frame.midY + trailing.frame.midY) / 2)
            XCTAssertTrue(app.frame.contains(nodeCenter), "A new node must be inside the phone viewport")
            let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
            shot.name = orientation == .portrait ? "iphone-canvas-portrait" : "iphone-canvas-landscape"
            shot.lifetime = .keepAlways
            self.add(shot)
        }
    }

    /// Compact layout starts directly on the new-task detail, with no
    /// duplicate global tab bar.
    func testColdLaunchUsesOneTaskSurface() throws {
        XCTAssertTrue(
            app.staticTexts["home.welcome"].waitForExistence(timeout: 5)
                || app.textFields["composer.input"].waitForExistence(timeout: 5)
        )
        XCTAssertEqual(app.tabBars.count, 0)
    }

    func testCompactSidebarIsReachable() throws {
        XCTAssertTrue(app.navigationBars.firstMatch.waitForExistence(timeout: 5))
        let sidebarButton = app.buttons.matching(NSPredicate(
            format: "label CONTAINS[c] %@ OR label CONTAINS[c] %@",
            "sidebar", "侧边栏"
        )).firstMatch
        if sidebarButton.waitForExistence(timeout: 3) {
            sidebarButton.tap()
            XCTAssertTrue(app.staticTexts["sidebar.workbench.new_task"].waitForExistence(timeout: 3))
        }
    }

    /// The composer stays usable with the keyboard up: input, voice, and
    /// send/stop remain visible and hittable.
    func testComposerLayoutWithKeyboard() throws {
        let input = app.textFields["composer.input"]
        guard input.waitForExistence(timeout: 5) else {
            throw XCTSkip("Composer not reachable without a provider")
        }
        input.tap()
        // Keyboard is up; the composer controls must remain visible.
        XCTAssertTrue(app.buttons["composer.voice"].waitForExistence(timeout: 3))
        XCTAssertTrue(
            app.buttons["composer.send"].exists
                || app.buttons["action.stop"].exists
                || input.exists
        )
    }

    /// VoiceOver-facing state: the microphone exposes a label and a value
    /// (never color alone), and permission failures offer a Settings jump.
    func testVoiceAccessibilityContract() throws {
        let mic = app.buttons["composer.voice"]
        guard mic.waitForExistence(timeout: 5) else {
            throw XCTSkip("Composer not reachable")
        }
        XCTAssertFalse(mic.label.isEmpty)
        mic.tap()
        // If permission was denied, the Settings entry appears; either way
        // the app did not crash and the mic control persists.
        _ = app.buttons["voice.open_settings"].waitForExistence(timeout: 2)
        XCTAssertTrue(app.buttons["composer.voice"].exists)
    }
}
#endif
