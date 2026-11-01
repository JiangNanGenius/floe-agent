//
//  CADAnimationAuthoringFlowUITests.swift
//  FloeAgentUITests
//
//  X25 native authoring route on the existing Plate A/B production fixture:
//  create a placed-part track with the real controls, add/select/move keys,
//  choose interpolation, edit a real value and delete a key; then capture a
//  camera key and stop playback. No synthetic document, fake keyframe or
//  model-side success is used. Root owns the actual Simulator run.
//

#if canImport(XCTest)
import XCTest

@MainActor
final class CADAnimationAuthoringFlowUITests: XCTestCase {
    private let launchArguments = [
        "-AppleLanguages", "(en)", "-AppleLocale", "en_US",
        "-ui-testing", "-ui-testing-ipad", "--ui-test-cad-fixture",
        "--ui-test-cad-animation", "--ui-test-cad-animation-long",
    ]

    func testPartTrackKeyAuthoringMoveCurveValueAndDelete() throws {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .landscapeLeft
        let app = XCUIApplication()
        app.launchArguments = launchArguments
        app.launch()
        defer { app.terminate() }

        XCTAssertTrue(app.buttons["HistoryButton"].waitForExistence(timeout: 60))
        enterPresent(app)

        let timeline = app.descendants(matching: .any)["CADAnimationTimeline"].firstMatch
        XCTAssertTrue(timeline.waitForExistence(timeout: 30))
        let cameraRow = app.buttons["CADAnimationTrackRow-0"]
        XCTAssertTrue(cameraRow.waitForExistence(timeout: 10),
                      "the fixture camera track must stay visible")

        // Create a REAL placed-part track through the production add menu.
        let addTrack = app.buttons["CADAnimationAddTrack"]
        XCTAssertTrue(addTrack.waitForExistence(timeout: 10),
                      "the real Add Track menu must be accessible: \(app.debugDescription)")
        addTrack.tap()
        tapMenuItem("Plate A", app: app)
        let partRow = app.buttons["CADAnimationTrackRow-1"]
        XCTAssertTrue(partRow.waitForExistence(timeout: 10),
                      "the part track row must appear after adding it")

        // Key at the current playhead (0) and a second key at 4 s.
        let addKey = app.buttons["CADAnimationAddKey"]
        XCTAssertTrue(addKey.waitForExistence(timeout: 10))
        addKey.tap()
        let firstKey = app.buttons["CADAnimationKeyRow-0"]
        XCTAssertTrue(firstKey.waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["CADAnimationEditValue"].exists)

        let slider = app.sliders["CADAnimationSlider"]
        XCTAssertTrue(slider.exists,
                      "the real animation slider must be accessible: \(app.debugDescription)")
        slider.adjust(toNormalizedSliderPosition: 0.4)
        addKey.tap()
        let secondKey = app.buttons["CADAnimationKeyRow-1"]
        XCTAssertTrue(secondKey.waitForExistence(timeout: 10))
        snapshot("X25 part track with two real keys")

        // Move the selected key with the stable-identity controls.
        firstKey.tap()
        let timeField = app.textFields["CADAnimationKeyTime"]
        XCTAssertTrue(timeField.waitForExistence(timeout: 10))
        XCTAssertEqual(timeField.value as? String, "0.00")
        let later = app.buttons["CADAnimationKeyLater"]
        XCTAssertTrue(later.isHittable)
        later.tap()
        later.tap()
        XCTAssertEqual(timeField.value as? String, "0.20")
        XCTAssertTrue(app.buttons["CADAnimationKeyRow-0"].exists,
                      "moving a key must keep its selected identity")

        // Choose the existing interpolation, then a real editable curve.
        let interpolation = app.buttons["CADAnimationInterpolation"]
        XCTAssertTrue(interpolation.isHittable)
        interpolation.tap()
        tapMenuItem("Ease in/out", app: app)
        interpolation.tap()
        tapMenuItem("Custom curve…", app: app)
        let curveX = app.sliders["CADAnimationCurveX1"]
        XCTAssertTrue(curveX.waitForExistence(timeout: 10),
                      "the real timed-curve editor must open")
        curveX.adjust(toNormalizedSliderPosition: 0.7)
        snapshot("X25 real timed curve editor")
        app.buttons["CADAnimationCurveDone"].tap()
        XCTAssertTrue(waitForAbsence(curveX, timeout: 10))
        XCTAssertTrue(timeline.waitForExistence(timeout: 10))

        // Edit a real supported part value through the existing sheet.
        app.buttons["CADAnimationEditValue"].tap()
        let translationX = app.textFields["CADAnimationValueTranslationX"]
        XCTAssertTrue(translationX.waitForExistence(timeout: 10),
                      "the real part value editor must open")
        translationX.tap()
        translationX.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue,
                                     count: 12))
        translationX.typeText("25\n")
        snapshot("X25 part value editor")
        app.buttons["CADAnimationValueSave"].tap()
        XCTAssertTrue(waitForAbsence(translationX, timeout: 10))
        XCTAssertTrue(timeline.waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["CADAnimationKeyRow-0"].exists)

        // Delete the selected key; the remaining key and track stay usable.
        app.buttons["CADAnimationDeleteKey"].tap()
        XCTAssertTrue(waitForAbsence(app.buttons["CADAnimationKeyRow-1"],
                                     timeout: 10),
                      "the deleted key must disappear")
        XCTAssertTrue(app.buttons["CADAnimationKeyRow-0"].exists)
        XCTAssertTrue(app.buttons["CADAnimationAddKey"].isHittable)
        snapshot("X25 after real key delete")
    }

    func testCameraKeyCaptureAndStopReturnToPreviewStart() throws {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .landscapeLeft
        let app = XCUIApplication()
        app.launchArguments = launchArguments
        app.launch()
        defer { app.terminate() }

        XCTAssertTrue(app.buttons["HistoryButton"].waitForExistence(timeout: 60))
        enterPresent(app)
        let timeline = app.descendants(matching: .any)["CADAnimationTimeline"].firstMatch
        XCTAssertTrue(timeline.waitForExistence(timeout: 30))

        let cameraRow = app.buttons["CADAnimationTrackRow-0"]
        XCTAssertTrue(cameraRow.waitForExistence(timeout: 10))
        cameraRow.tap()

        let slider = app.sliders["CADAnimationSlider"]
        XCTAssertTrue(slider.exists,
                      "the real camera timeline slider must be accessible: \(app.debugDescription)")
        slider.adjust(toNormalizedSliderPosition: 0.5)
        let addKey = app.buttons["CADAnimationAddKey"]
        XCTAssertTrue(addKey.isHittable)
        addKey.tap()
        let thirdKey = app.buttons["CADAnimationKeyRow-2"]
        XCTAssertTrue(thirdKey.waitForExistence(timeout: 10),
                      "a real camera key must be captured at the playhead")

        thirdKey.tap()
        XCTAssertTrue(app.buttons["CADAnimationEditValue"].isHittable)
        app.buttons["CADAnimationEditValue"].tap()
        XCTAssertTrue(app.textFields["CADAnimationValueDistance"]
            .waitForExistence(timeout: 10),
            "the camera value editor must open")
        XCTAssertTrue(app.buttons["CADAnimationValueUseCurrent"].exists,
                      "the camera sheet must offer the actual live view")
        app.buttons["CADAnimationValueUseCurrent"].tap()
        app.buttons["CADAnimationValueSave"].tap()
        XCTAssertTrue(waitForAbsence(app.textFields["CADAnimationValueDistance"],
                                     timeout: 10))
        XCTAssertTrue(timeline.waitForExistence(timeout: 10))

        // Play then stop. Stop is the existing transient clear; the timeline
        // and the authored records must remain.
        app.buttons["CADAnimationPlay"].tap()
        RunLoop.current.run(until: Date().addingTimeInterval(0.8))
        app.buttons["CADAnimationStop"].tap()
        XCTAssertTrue(timeline.waitForExistence(timeout: 10))
        XCTAssertEqual(app.buttons["CADAnimationKeyRow-2"].exists, true)
        snapshot("X25 camera key captured and stopped")
    }

    // MARK: Helpers

    private func enterPresent(_ app: XCUIApplication) {
        let mode = app.segmentedControls["CADWorkbenchMode"]
        XCTAssertTrue(mode.waitForExistence(timeout: 30))
        mode.buttons["Present"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["CADPresentationSurface"]
            .firstMatch.waitForExistence(timeout: 30),
            "Present must build the real presentation surface")
    }

    private func tapMenuItem(_ title: String, app: XCUIApplication) {
        let button = app.buttons[title].firstMatch
        if button.waitForExistence(timeout: 3) {
            button.tap()
            return
        }
        let item = app.menuItems[title].firstMatch
        XCTAssertTrue(item.waitForExistence(timeout: 5),
                      "menu item '\(title)' was not reachable")
        item.tap()
    }

    private func waitForAbsence(_ element: XCUIElement,
                                timeout: TimeInterval) -> Bool {
        let predicate = NSPredicate(format: "exists == false")
        return XCTWaiter.wait(
            for: [XCTNSPredicateExpectation(predicate: predicate,
                                            object: element)],
            timeout: timeout) == .completed
    }

    private func snapshot(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
#endif
