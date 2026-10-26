import XCTest

@MainActor
final class BackgroundAudioSettingsUITests: XCTestCase {
    /// POLICY CHANGE (user-approved plan, 2026-10-27): the toggles are no
    /// longer three fully independent switches with a one-way PiP→feedback
    /// cascade. The approved prerequisite chain is
    /// enhanced → audio → PiP → screen feedback:
    ///  • enabling a capability enables every prerequisite above it;
    ///  • disabling a prerequisite while a dependent is still enabled is
    ///    REFUSED — the row is disabled with an actionable caption, and no
    ///    other choice is ever silently cascaded off.
    /// This test replaced `testIndependentSwitchesAndScreenFeedbackDependency`,
    /// whose cascade-off/independence expectations the new plan overrides.
    func testPrerequisiteChainRefusalAndScreenFeedbackDependency() throws {
        continueAfterFailure = false
        let app = launchSettings()
        defer { app.terminate() }
        let enhanced = app.switches["background.enhanced.toggle"].firstMatch
        let audio = app.switches["background.audio.toggle"].firstMatch
        let pip = app.switches["background.pip.toggle"].firstMatch
        let feedback = app.switches["background.screenFeedback.toggle"].firstMatch
        XCTAssertTrue(enhanced.waitForExistence(timeout: 15))
        XCTAssertTrue(audio.exists)
        XCTAssertTrue(pip.exists)
        XCTAssertTrue(feedback.exists)
        let original = (enabled(enhanced), enabled(audio), enabled(pip), enabled(feedback))
        try XCTSkipIf(!original.0 && (original.1 || original.2 || original.3),
                      "Retain the saved legacy combination: UI policy cannot reconstruct it after mutation")
        defer {
            // Restore deepest-first so no restore step is refused.
            set(feedback, to: original.3)
            set(pip, to: original.2)
            set(audio, to: original.1)
            set(enhanced, to: original.0)
        }

        // Enabling screen feedback pulls in the whole prerequisite chain.
        set(feedback, to: true)
        assertValue(pip, true)
        assertValue(audio, true)
        assertValue(enhanced, true)

        // With dependents active, every prerequisite row is refused: the
        // switch is disabled (actionable, not silently cascading) and the
        // explanatory caption is present.
        XCTAssertFalse(pip.isEnabled)
        XCTAssertFalse(audio.isEnabled)
        XCTAssertFalse(enhanced.isEnabled)
        XCTAssertTrue(
            app.descendants(matching: .any)["background.pip.policyCaption"].firstMatch.exists)

        // Clearing the deepest dependent unlocks PiP; turning PiP off then
        // leaves the audio prerequisite exactly as chosen (no cascade-off).
        set(feedback, to: false)
        XCTAssertTrue(pip.isEnabled)
        set(pip, to: false)
        assertValue(feedback, false)
        assertValue(audio, true)

        // Audio still on ⇒ enhanced stays refused; clearing audio unlocks it.
        XCTAssertFalse(enhanced.isEnabled)
        set(audio, to: false)
        XCTAssertTrue(enhanced.isEnabled)
        set(enhanced, to: false)
        assertValue(enhanced, false)

        // Enabling PiP alone pulls the full chain back up.
        set(pip, to: true)
        assertValue(audio, true)
        assertValue(enhanced, true)
        capture("background-prerequisite-chain-refusals")
    }

    func testPiPAudioChildSettingsAreReachableWithoutStartingPlayback() {
        continueAfterFailure = false
        let app = launchSettings()
        defer { app.terminate() }
        let child = app.descendants(matching: .any)["background.pip.audio.settings"].firstMatch
        XCTAssertTrue(child.waitForExistence(timeout: 15))
        child.tap()
        XCTAssertTrue(app.switches["pip.audio.ambient.toggle"].firstMatch.waitForExistence(timeout: 10))
        XCTAssertTrue(app.sliders["pip.audio.ambient.volume"].firstMatch.exists)
        XCTAssertTrue(app.switches["pip.audio.speech.toggle"].firstMatch.exists)
        XCTAssertTrue(app.switches["pip.audio.cues.toggle"].firstMatch.exists)
        XCTAssertTrue(app.buttons["pip.audio.preview"].firstMatch.exists)
        capture("pip-audio-child-settings")
    }

    func testMusicChoicesPreviewAndPersistence() throws {
        continueAfterFailure = false
        let choices = ["Meditation", "First Light", "Deep Blue", "Starfield"]
        let language = ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        let app = launchSettings(extraArguments: language)
        defer { app.terminate() }
        openAudioSettings(app)
        let picker = app.buttons["pip.audio.sound"].firstMatch
        XCTAssertTrue(picker.waitForExistence(timeout: 10))
        // Native SwiftUI menu pickers expose the selected title in their
        // compound label, while their value is empty on this SDK.
        let selected = choices.filter { picker.label == "Sound, \($0)" }
        XCTAssertEqual(selected.count, 1, "The native picker must expose exactly one current music choice: \(picker.debugDescription)")
        let original = try XCTUnwrap(selected.first)
        defer {
            if picker.exists && picker.isHittable {
                selectMusic(original, app: app)
                let preview = app.buttons["pip.audio.preview"].firstMatch
                if preview.label == "Stop preview" { preview.tap() }
            }
        }

        // Inspect every menu item, then switch the existing bounded preview.
        picker.tap()
        for choice in choices {
            XCTAssertTrue(app.buttons[choice].firstMatch.waitForExistence(timeout: 5),
                          "The native music menu must offer \(choice)")
        }
        capture("pip-music-four-choice-menu")
        app.buttons[original].firstMatch.tap()
        let preview = app.buttons["pip.audio.preview"].firstMatch
        XCTAssertEqual(preview.label, "Preview")
        preview.tap()
        XCTAssertTrue(waitForLabel(preview, "Stop preview"))
        for choice in choices {
            selectMusic(choice, app: app)
            XCTAssertTrue(waitForLabel(preview, "Stop preview"),
                          "Selecting \(choice) must keep the current preview open")
        }
        capture("pip-music-starfield-preview")
        preview.tap()
        XCTAssertTrue(waitForLabel(preview, "Preview"))

        // Reload the real preference store in a fresh process, without any
        // testing reset or a different settings instance.
        app.terminate()
        _ = launchSettings(extraArguments: language)
        openAudioSettings(app)
        XCTAssertTrue(picker.waitForExistence(timeout: 10))
        let persisted = NSPredicate(format: "label == %@", "Sound, Starfield")
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: persisted, object: picker)], timeout: 10), .completed)
        XCTAssertTrue(waitForLabel(app.buttons["pip.audio.preview"].firstMatch, "Preview"),
                      "Relaunching Settings must not resume a preview")
        capture("pip-music-choice-restored-after-relaunch")
    }

    private func openAudioSettings(_ app: XCUIApplication) {
        let child = app.descendants(matching: .any)["background.pip.audio.settings"].firstMatch
        XCTAssertTrue(child.waitForExistence(timeout: 15))
        child.tap()
        XCTAssertTrue(app.buttons["pip.audio.preview"].firstMatch.waitForExistence(timeout: 10))
    }

    private func selectMusic(_ choice: String, app: XCUIApplication) {
        let picker = app.buttons["pip.audio.sound"].firstMatch
        XCTAssertTrue(picker.isHittable)
        picker.tap()
        let option = app.buttons[choice].firstMatch
        XCTAssertTrue(option.waitForExistence(timeout: 5))
        option.tap()
        let predicate = NSPredicate(format: "label == %@", "Sound, \(choice)")
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: predicate, object: picker)], timeout: 10), .completed)
    }

    private func waitForLabel(_ element: XCUIElement, _ label: String) -> Bool {
        let predicate = NSPredicate(format: "label == %@", label)
        return XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: predicate, object: element)], timeout: 10) == .completed
    }

    private func launchSettings(extraArguments: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-test-skip-onboarding", "-ui-testing-ipad"] + extraArguments
        app.launch()
        let settings = app.buttons["sidebar.settings"].firstMatch
        XCTAssertTrue(settings.waitForExistence(timeout: 30))
        if !settings.isHittable {
            let drawer = app.buttons["phone.sidebar.open"].firstMatch
            if drawer.exists { drawer.tap() }
        }
        settings.tap()
        let category = app.descendants(matching: .any)["settings.section.backgroundExecution"].firstMatch
        let sections = app.descendants(matching: .any)["settings.sections"].firstMatch
        XCTAssertTrue(sections.waitForExistence(timeout: 15))
        for _ in 0..<8 {
            if category.exists && category.isHittable { break }
            sections.swipeUp()
        }
        XCTAssertTrue(category.waitForExistence(timeout: 15))
        category.tap()
        return app
    }

    private func enabled(_ element: XCUIElement) -> Bool {
        (element.value as? String) == "1"
    }

    private func set(_ element: XCUIElement, to value: Bool) {
        guard element.exists else { return }
        if enabled(element) != value {
            // SwiftUI exposes the full labeled row as the Switch element;
            // its native switch control occupies the trailing end.
            element.coordinate(withNormalizedOffset: CGVector(dx: 0.92, dy: 0.5)).tap()
        }
        assertValue(element, value)
    }

    private func assertValue(_ element: XCUIElement, _ value: Bool) {
        let predicate = NSPredicate(format: "value == %@", value ? "1" : "0")
        let result = XCTWaiter.wait(
            for: [XCTNSPredicateExpectation(predicate: predicate, object: element)], timeout: 5
        )
        XCTAssertEqual(result, .completed)
    }

    private func capture(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
