import XCTest

@MainActor
final class ChemistryNativePreviewUITests: XCTestCase {
    private let structureView = "chemistry.structureView"

    func testClosingAssistantKeepsTheSpaceEditorOpenUntilDone() {
        let app = launchApp()
        createProject(newTitle("Assistant"), in: app)
        let done = app.buttons["space.editor.done"]
        tap(app.buttons["space.editor.assistant"])
        let close = app.buttons["studio.assistant.close"]
        XCTAssertTrue(close.waitForExistence(timeout: 10))
        XCTAssertEqual(close.label, "Close Assistant")
        XCTAssertEqual(done.label, "Done")
        XCTAssertTrue(done.isHittable)
        XCTAssertLessThan(done.frame.midX, close.frame.midX)

        tap(close)
        XCTAssertTrue(close.waitForNonExistence(timeout: 10))
        XCTAssertTrue(app.buttons["New drawing"].firstMatch.isHittable)
        tap(done)
        XCTAssertTrue(app.segmentedControls["space.sections"].waitForExistence(timeout: 15))
    }

    func testSpaceDrawingRegeneratesAndRestoresNativePreview() {
        let app = launchApp()
        let title = newTitle("ChemSpace")
        createProject(title, in: app)
        startDrawing(in: app)
        drawRing(6, in: app)
        showPreview(in: app)
        requireScene("generated", atoms: 18, bonds: 18, in: app)

        showDrawing(in: app)
        requireDrawingCount(6, in: app)
        clearDrawing(in: app)
        drawRing(3, in: app)
        showPreview(in: app)
        requireScene("generated", atoms: 9, bonds: 9, in: app)
        capture("Space-edited-3D", in: app)

        tap(app.buttons["space.editor.done"])
        XCTAssertTrue(app.segmentedControls["space.sections"].waitForExistence(timeout: 15))
        app.terminate()
        app.launch()
        openFiles(in: app)
        openProject(title, in: app)
        showDrawing(in: app)
        requireDrawingCount(3, in: app)
        showPreview(in: app)
        requireScene("cached", atoms: 9, bonds: 9, in: app)
        capture("Space-reopened-3D", in: app)
    }

    func testNotesLinkedProjectEditsAndReopensItsNativePreview() {
        let app = launchApp()
        let title = newTitle("ChemNote")
        createProject(title, in: app)
        startDrawing(in: app)
        requireDrawingCount(0, in: app)
        tap(app.buttons["space.editor.done"])

        tap(app.segmentedControls["space.sections"].buttons["Overview"])
        tap(app.buttons["space.quick.newNote"])
        let noteName = app.alerts["New note"]
        replaceText(in: noteName.textFields.firstMatch, with: newTitle("PreviewNote"))
        tap(noteName.buttons["Create"])
        openNoteTool("Insert", in: app)
        tap(app.buttons["notes.insert.chemistry"])
        let projectPicker = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Chemistry project")).firstMatch
        XCTAssertTrue(projectPicker.waitForExistence(timeout: 15))
        if !projectPicker.label.contains(title) {
            tap(projectPicker)
            tap(app.buttons[title])
        }
        XCTAssertTrue(projectPicker.label.contains(title))
        let linkOnly = app.segmentedControls["notes.chemistry.contentMode"].buttons["Link only"]
        tap(linkOnly)
        XCTAssertTrue(linkOnly.isSelected)
        tap(app.buttons["notes.chemistry.insert"])

        openNoteReference(title, in: app)
        showDrawing(in: app)
        requireDrawingCount(0, in: app)
        drawRing(3, in: app)
        showPreview(in: app)
        requireScene("generated", atoms: 9, bonds: 9, in: app)
        showDrawing(in: app)
        clearDrawing(in: app)
        drawRing(6, in: app)
        showPreview(in: app)
        requireScene("generated", atoms: 18, bonds: 18, in: app)
        tap(app.buttons["space.editor.done"])

        openNoteReference(title, in: app)
        showDrawing(in: app)
        requireDrawingCount(6, in: app)
        showPreview(in: app)
        requireScene("cached", atoms: 18, bonds: 18, in: app)
        capture("Notes-linked-project-reopened-3D", in: app)
    }

    func testInvalidDrawingReportsErrorAndRecovers() {
        let app = launchApp()
        createProject(newTitle("ChemError"), in: app)
        startDrawing(in: app)
        requireDrawingCount(0, in: app)
        showPreview(in: app)
        let error = app.staticTexts["chemistry.preview.error"]
        XCTAssertTrue(error.waitForExistence(timeout: 20))
        XCTAssertFalse(element("chemistry.preview.ready", in: app).exists)
        XCTAssertFalse(element("chemistry.preview.counts", in: app).exists)
        tap(app.buttons["chemistry.preview.retry"])
        XCTAssertTrue(error.waitForExistence(timeout: 20))
        capture("Empty-drawing-error", in: app)

        showDrawing(in: app)
        drawRing(3, in: app)
        showPreview(in: app)
        requireScene("generated", atoms: 9, bonds: 9, in: app)
        XCTAssertFalse(error.exists)
    }

    private func launchApp() -> XCUIApplication {
        continueAfterFailure = false
        let device = XCUIDevice.shared
        let initialOrientation = device.orientation
        device.orientation = .landscapeLeft
        let app = XCUIApplication(bundleIdentifier: "org.floeagent.ios")
        app.launchArguments = ["-ui-testing", "-ui-testing-ipad", "--ui-test-skip-onboarding",
                               "-AppleLanguages", "(en)", "-AppleLocale", "en_US", "-floe.settings.language", "en"]
        app.launch()
        addTeardownBlock { @MainActor in
            app.terminate()
            device.orientation = initialOrientation
        }
        return app
    }

    private func newTitle(_ prefix: String) -> String {
        prefix + "-" + UUID().uuidString.prefix(8)
    }

    private func element(_ id: String, in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: id).firstMatch
    }

    private func tap(_ control: XCUIElement, file: StaticString = #filePath, line: UInt = #line) {
        let available = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == true AND enabled == true AND hittable == true"), object: control)
        XCTAssertEqual(XCTWaiter.wait(for: [available], timeout: 20), .completed,
                       control.debugDescription, file: file, line: line)
        control.tap()
    }

    private func replaceText(in field: XCUIElement, with title: String) {
        tap(field)
        field.typeKey("a", modifierFlags: .command)
        field.typeText(title)
    }

    private func openFiles(in app: XCUIApplication) {
        let files = app.segmentedControls["space.sections"].buttons["Files"]
        if !files.exists || !files.isHittable {
            tap(app.collectionViews["sidebar.list"].cells.containing(.staticText, identifier: "sidebar.notes").firstMatch)
        }
        tap(files)
    }

    private func createProject(_ title: String, in app: XCUIApplication) {
        openFiles(in: app)
        tap(app.buttons["space.new"])
        tap(app.buttons["Chemistry project"])
        replaceText(in: app.textFields["space.creation.title"], with: title)
        tap(app.buttons["space.creation.create"])
        XCTAssertTrue(app.buttons["space.editor.done"].waitForExistence(timeout: 20))
    }

    private func openProject(_ title: String, in app: XCUIApplication) {
        let project = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", title)).firstMatch
        if !project.isHittable {
            let search = app.searchFields["Find works and files"]
            if search.exists { tap(search); search.typeText(title) }
        }
        tap(project)
        XCTAssertTrue(app.buttons["space.editor.done"].waitForExistence(timeout: 20))
    }

    private func startDrawing(in app: XCUIApplication) {
        tap(app.buttons["New drawing"].firstMatch)
        showDrawing(in: app)
    }

    private func showDrawing(in app: XCUIApplication) {
        tap(app.segmentedControls[structureView].buttons["2D drawing"])
        XCTAssertTrue(app.otherElements["chemistry.nativeCanvas"].firstMatch.waitForExistence(timeout: 15))
    }

    private func showPreview(in app: XCUIApplication) {
        let preview = app.segmentedControls[structureView].buttons["3D preview"]
        tap(preview)
        let selected = NSPredicate(format: "selected == true")
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: selected, object: preview)], timeout: 10), .completed)
    }

    private func requireDrawingCount(_ size: Int, in app: XCUIApplication) {
        let counts = app.staticTexts["chemistry.drawingCounts"]
        let expected = NSPredicate(format: "label == %@", "\(size) atoms · \(size) bonds")
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: expected, object: counts)], timeout: 15), .completed)
    }

    private func drawRing(_ size: Int, in app: XCUIApplication) {
        let canvas = app.otherElements["chemistry.nativeCanvas"].firstMatch
        let finger = element("chemistry.drawing.fingerDrawing", in: app)
        let pans = app.staticTexts["Finger pans"].exists
        if pans { tap(finger) }
        XCTAssertTrue(app.staticTexts["Finger draws"].waitForExistence(timeout: 8))
        tap(app.buttons["Ring \(size)"])
        canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.46)).tap()
        requireDrawingCount(size, in: app)
        if pans { tap(finger) }
        let saved = NSPredicate(format: "label == %@", "Saved")
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: saved, object: app.staticTexts["chemistry.saveStatus"])],
                                      timeout: 25), .completed)
    }

    private func clearDrawing(in app: XCUIApplication) {
        let options = app.buttons["Drawing options"]
        let commands = app.scrollViews.containing(.button, identifier: "Undo").firstMatch
        reveal(options, in: commands)
        tap(options)
        tap(app.buttons["Clear drawing"])
        requireDrawingCount(0, in: app)
    }

    private func requireScene(_ source: String, atoms: Int, bonds: Int, in app: XCUIApplication) {
        let ready = element("chemistry.preview.ready", in: app)
        let counts = element("chemistry.preview.counts", in: app)
        let status = NSPredicate(format: "exists == true AND value == %@", source)
        let geometry = NSPredicate(format: "exists == true AND value == %@", "\(atoms)/\(bonds)")
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: status, object: ready),
                                            XCTNSPredicateExpectation(predicate: geometry, object: counts)], timeout: 30), .completed,
                       "Expected \(source) scene with \(atoms) atoms and \(bonds) bonds.")
        XCTAssertTrue(app.buttons["Fit structure"].waitForExistence(timeout: 10))
    }

    private func reveal(_ control: XCUIElement, in strip: XCUIElement) {
        for _ in 0..<3 where !control.isHittable && strip.exists { strip.swipeLeft() }
    }

    private func openNoteTool(_ name: String, in app: XCUIApplication) {
        let strip = app.scrollViews["notes.writing.tools"].firstMatch
        XCTAssertTrue(strip.waitForExistence(timeout: 20))
        let button = strip.buttons[name].firstMatch
        reveal(button, in: strip)
        tap(button)
    }

    private func openNoteReference(_ title: String, in app: XCUIApplication) {
        openNoteTool("More", in: app)
        let caption = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "1. \(title)")).firstMatch
        tap(caption)
        tap(app.buttons["Open project"])
        XCTAssertTrue(app.buttons["space.editor.done"].waitForExistence(timeout: 20))
    }

    private func capture(_ name: String, in app: XCUIApplication) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
