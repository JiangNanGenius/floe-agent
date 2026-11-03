// SPDX-License-Identifier: MPL-2.0
// One real iPad material-import workflow. The DEBUG fixture only supplies a
// real saved document and two real synthetic PNG inputs; every choice and
// transaction below uses the shipped inspector and workbench controls.
import XCTest

@MainActor
final class CADTextureImportUITests: XCTestCase {
    private var app: XCUIApplication!
    private let base = ["-AppleLanguages", "(en)", "-AppleLocale", "en_US",
                        "-ui-testing", "-ui-testing-ipad", "--ui-test-cad-fixture",
                        "--ui-test-cad-texture-import"]

    override func setUpWithError() throws {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .landscapeLeft
        app = XCUIApplication()
        app.launchArguments = base + ["--ui-test-cad-texture-import-reset"]
        app.launch()
    }

    override func tearDownWithError() throws {
        app?.terminate()
        app = nil
    }

    func testTwoLargePNGChoicesReadbackApplyUndoAndActualPackageReopen() throws {
        XCTAssertTrue(app.navigationBars["Import textures"].waitForExistence(timeout: 60))
        expandImportSheet()
        // The actual 4096x2048 PNGs are individually supported, but their
        // combined full-resolution mip chains exceed the actual image budget.
        let budgetError = any("CADTextureImportError")
        XCTAssertTrue(revealInImportSheet(budgetError))
        XCTAssertTrue(budgetError.label.contains("64 MB"), budgetError.label)
        XCTAssertFalse(app.buttons["CADTextureImportUse"].isEnabled)

        // A bounded cancellation on the same document. The real Cancel action
        // discards the starting batch; closing Material returns to the exact
        // unchanged real document rather than loading a second fixture.
        app.buttons["CADTextureImportCancel"].tap()
        XCTAssertTrue(app.buttons["CADMaterialCancel"].waitForExistence(timeout: 15))
        app.buttons["CADMaterialCancel"].tap()
        let cancelled = try state(containing: ["state=empty", "base=none", "normal=none",
                                                "sources=unchanged", "document=texture-import.floecad"])
        let baselineUndo = try integer("undo", from: cancelled)
        snapshot("X12 cancel keeps the same synthetic document and sources")

        // Re-enter through the production Material palette action. Its new
        // real draft receives the fixture's starting input, not prepared maps.
        let material = app.buttons["MaterialButton"]
        for _ in 0..<6 where !material.isHittable {
            let palette = app.scrollViews["ToolPalette"]
            guard palette.exists && palette.isHittable else { break }
            palette.swipeUp()
        }
        XCTAssertTrue(material.waitForExistence(timeout: 15))
        XCTAssertTrue(material.isHittable)
        XCTAssertTrue(material.isEnabled)
        material.tap()
        XCTAssertTrue(app.navigationBars["Import textures"].waitForExistence(timeout: 20))
        expandImportSheet()

        choose("Color map", using: "CADTextureImportChannel-0")
        choose("8-bit PNG · up to 1024 px", using: "CADTextureImportChoice-0")
        choose("Normal map", using: "CADTextureImportChannel-1")
        choose("8-bit PNG · up to 512 px", using: "CADTextureImportChoice-1")
        let prepare = app.buttons["CADTextureImportPrepare"]
        XCTAssertTrue(revealInImportSheet(prepare))
        XCTAssertTrue(waitEnabled(prepare))
        prepare.tap()
        let use = app.buttons["CADTextureImportUse"]
        XCTAssertTrue(waitEnabled(use, timeout: 30), app.debugDescription)
        // These are the actual read-back images from final encoded bytes in
        // CADTextureImportReviewView, not a fixture-supplied preview canvas.
        XCTAssertTrue(app.images["Synthetic color.png"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.images["Synthetic normal.png"].waitForExistence(timeout: 10))
        snapshot("X12 real encoded read-back preview before draft confirmation")
        use.tap()
        let apply = app.buttons["CADMaterialApply"]
        XCTAssertTrue(apply.waitForExistence(timeout: 15))
        XCTAssertTrue(apply.isEnabled)
        apply.tap()
        let expected = ["state=applied", "base=1024x512", "normal=512x256", "colors=match",
                        "data=match", "alpha=128/128", "metadata=verified", "library=match", "sources=unchanged"]
        let applied = try state(containing: expected)
        XCTAssertEqual(try integer("undo", from: applied), baselineUndo + 1,
                       "The two imported maps must apply as one existing material transaction")
        snapshot("X12 real applied pixels and document library readback")

        let undo = app.buttons["UndoButton"], redo = app.buttons["RedoButton"]
        XCTAssertTrue(undo.isEnabled)
        undo.tap()
        let undone = try state(containing: ["state=empty", "base=none", "normal=none", "sources=unchanged"])
        XCTAssertEqual(try integer("undo", from: undone), baselineUndo)
        XCTAssertTrue(redo.isEnabled)
        redo.tap()
        _ = try state(containing: expected)

        let save = app.buttons["cad.host.save"]
        XCTAssertTrue(save.waitForExistence(timeout: 15))
        XCTAssertTrue(save.isEnabled)
        save.tap()
        let saved = any("cad.host.saveOutcome")
        XCTAssertTrue(saved.waitForExistence(timeout: 20))
        XCTAssertTrue(saved.label.contains("Saved"), saved.label)
        app.terminate()
        app.launchArguments = base + ["--ui-test-cad-texture-import-reopen"]
        app.launch()
        // A new process opens the production .floecad package. The read-only
        // panel decodes material bytes from that document independently of
        // prepared receipts, including alpha and all four spatial quadrants.
        _ = try state(containing: expected + ["document=texture-import.floecad"], timeout: 60)
        XCTAssertFalse(app.buttons["CADTextureImportUse"].exists)
        snapshot("X12 fresh process reopens actual saved texture pixels")
    }

    private func any(_ identifier: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    @discardableResult
    private func state(containing fragments: [String], timeout: TimeInterval = 20) throws -> String {
        let element = any("CADTextureImportState")
        XCTAssertTrue(element.waitForExistence(timeout: timeout), app.debugDescription)
        let predicate = NSPredicate { object, _ in
            guard let element = object as? XCUIElement else { return false }
            return fragments.allSatisfy { element.label.contains($0) }
        }
        let result = XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: predicate, object: element)], timeout: timeout)
        XCTAssertEqual(result, .completed, "Expected \(fragments); actual readback: \(element.label)")
        return element.label
    }

    private func integer(_ key: String, from report: String) throws -> Int {
        let value = report.split(separator: "|").first { $0.hasPrefix(key + "=") }
            .flatMap { Int($0.dropFirst(key.count + 1)) }
        return try XCTUnwrap(value, "Readback must include actual \(key): \(report)")
    }

    private func choose(_ label: String, using identifier: String) {
        let picker = any(identifier)
        XCTAssertTrue(revealInImportSheet(picker), "The native picker must remain reachable: \(identifier)")
        picker.tap()
        let options = app.buttons.matching(NSPredicate(format: "label == %@", label))
        let option = options.firstMatch
        XCTAssertTrue(option.waitForExistence(timeout: 8), "The native menu must offer \(label)")
        // A native menu can expose its accessibility elements before its
        // spring placement finishes. Tap its settled actual row, then wait
        // for both selection readback and dismissal before the next picker.
        var previous = CGRect.null
        var stable = 0
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline, stable < 2 {
            let current = option.frame
            stable = option.isHittable && current == previous ? stable + 1 : 0
            previous = current
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        XCTAssertEqual(stable, 2, "The native menu row must finish positioning")
        option.tap()
        let selected = NSPredicate { _, _ in
            picker.exists && picker.label.contains(label) && !option.exists
        }
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: selected, object: picker)], timeout: 8),
                       .completed, "The actual picker must show \(label) after selection, got \(picker.label)")
    }

    private func expandImportSheet() {
        let bar = app.navigationBars["Import textures"]
        bar.coordinate(withNormalizedOffset: .init(dx: 0.5, dy: 0.5)).press(forDuration: 0.1,
            thenDragTo: app.coordinate(withNormalizedOffset: .init(dx: 0.5, dy: 0.1)))
    }

    private func revealInImportSheet(_ element: XCUIElement) -> Bool {
        for _ in 0..<8 {
            if element.exists && element.isHittable { return true }
            let scrolls = app.collectionViews.allElementsBoundByIndex
                + app.tables.allElementsBoundByIndex + app.scrollViews.allElementsBoundByIndex
            // The native front Form is the scroll target; the background
            // workbench's narrow ToolPalette must never receive this gesture.
            guard let form = scrolls.filter({ $0.isHittable && $0.identifier != "ToolPalette" && $0.frame.width > 300 })
                .max(by: { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height }) else { return false }
            if element.exists && element.frame.midY < form.frame.minY { form.swipeDown() }
            else { form.swipeUp() }
        }
        return element.exists && element.isHittable
    }

    private func waitEnabled(_ element: XCUIElement, timeout: TimeInterval = 15) -> Bool {
        let predicate = NSPredicate(format: "exists == true AND enabled == true")
        return XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: predicate, object: element)], timeout: timeout) == .completed
    }

    private func snapshot(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
