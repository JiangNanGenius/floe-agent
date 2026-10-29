// FloeAgentUITests — unified supplier selector integration on iPad and iPhone.
//
// Drives the REAL app: Settings → Providers → Add (chat role) → tapping the
// supplier FIELD itself opens ONE searchable selector where the built-in
// presets (including the explicit manual/custom choice) and the verified
// catalog entries live together (no separate preset row, no "add from
// catalog" button, no standalone catalog page). Verifies local alias search,
// selection that preserves a custom display name, and the one-time multi-role
// opt-in prompt (the accept path is covered by the view-model suite; here the
// visible decline path and its no-repeat memory are exercised). Screenshots
// are attached for the primary's GUI review; a real paid provider call is
// never made (no key is entered, nothing saved).

import XCTest

@MainActor
final class ProviderCatalogPickerUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    private func launchApp(iPad: Bool) -> XCUIApplication {
        let app = XCUIApplication()
        // NON-DESTRUCTIVE: the reused FloeMiniCheck / iPhone 17 Pro simulators
        // hold protected user configuration. This test never passes
        // `--ui-test-delete-all-providers` (which really deletes every saved
        // provider/model); it only skips onboarding and works additively with
        // a synthetic custom name inside a new provider editor that is
        // cancelled without saving.
        app.launchArguments = [
            "-ui-testing",
            "--ui-test-skip-onboarding",
            "-AppleLanguages", "(en)",
            "-AppleLocale", "en_US",
        ]
        if iPad { app.launchArguments.append("-ui-testing-ipad") }
        app.launch()
        return app
    }

    private func openProviderEditor(_ app: XCUIApplication, roleTitle: String = "Chat model provider") {
        let settings = app.buttons["sidebar.settings"]
        XCTAssertTrue(settings.waitForExistence(timeout: 15), "settings entry missing")
        if !settings.isHittable {
            let drawer = app.buttons["phone.sidebar.open"]
            XCTAssertTrue(drawer.waitForExistence(timeout: 5))
            drawer.tap()
        }
        settings.tap()
        let providers = app.descendants(matching: .any)
            .matching(identifier: "settings.section.providers").firstMatch
        XCTAssertTrue(providers.waitForExistence(timeout: 10), "providers settings section missing")
        providers.tap()
        XCTAssertTrue(app.buttons["providers.add"].waitForExistence(timeout: 10))
        app.buttons["providers.add"].tap()
        // The single Add entry chooses the initiating role first.
        let chat = app.buttons[roleTitle]
        XCTAssertTrue(chat.waitForExistence(timeout: 8), "role chooser missing")
        chat.tap()
        XCTAssertTrue(app.textFields["providers.display_name"].waitForExistence(timeout: 10))
    }

    private func attach(_ app: XCUIApplication, _ name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }

    /// Dismisses the software keyboard so a following tap cannot land on it.
    private func dismissKeyboard(_ app: XCUIApplication) {
        guard app.keyboards.count > 0 else { return }
        let returnKey = app.keyboards.buttons["return"]
        if returnKey.exists {
            returnKey.tap()
        } else {
            // Fall back to a neutral tap on the navigation bar area.
            app.navigationBars.firstMatch.tap()
        }
        _ = app.keyboards.firstMatch.waitForNonExistence(timeout: 3)
    }

    /// The unified selector's persistent search bar.
    private func searchField(in app: XCUIApplication) -> XCUIElement {
        let identified = app.searchFields["providers.catalog.searchField"]
        return identified.exists ? identified : app.searchFields.firstMatch
    }

    /// Scrolls the form until `element` is hittable, then taps it.
    private func tapWhenHittable(_ element: XCUIElement, in app: XCUIApplication) {
        XCTAssertTrue(element.waitForExistence(timeout: 8), "element never appeared")
        var attempts = 0
        while !element.isHittable, attempts < 6 {
            app.swipeUp()
            attempts += 1
        }
        XCTAssertTrue(element.isHittable, "element never became hittable")
        element.tap()
    }

    private func replaceField(_ field: XCUIElement, with text: String) {
        field.tap()
        let existing = field.value as? String ?? ""
        if !existing.isEmpty, existing != "Display name" {
            field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: existing.count))
        }
        field.typeText(text)
    }

    /// Clears a text field regardless of whether its `value` is real text or
    /// the placeholder (extra deletes on an empty field are a no-op).
    private func clearText(_ field: XCUIElement) {
        field.tap()
        let existing = field.value as? String ?? ""
        if !existing.isEmpty {
            field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: min(existing.count, 40)))
        }
    }

    func testSubscriptionAndAlibabaFormsUseTheirOwnModelCandidates() throws {
        XCUIDevice.shared.orientation = .landscapeLeft
        defer { XCUIDevice.shared.orientation = .portrait }
        let cases = [
            ("Chat model provider", "volc", "volcengine-agent-plan", "ark-code-latest", true),
            ("Image generation/editing provider", "volc", "volcengine-agent-plan", "doubao-seedream-5.0-flash", true),
            ("Image generation/editing provider", "alibaba", "alibabaStudio", "qwen-image-3.0-pro", false),
            ("Video generation provider", "alibaba", "alibabaStudio", "wan3.0-video", false),
            ("Image generation/editing provider", "token", "alibaba-token-plan", "qwen-image-3.0-pro", true),
            ("Video generation provider", "token", "alibaba-token-plan", "wan3.0-video", true),
        ]
        for (title, query, presetID, modelID, noDiscovery) in cases {
            let app = launchApp(iPad: true)
            openProviderEditor(app, roleTitle: title)
            tapWhenHittable(app.buttons["providers.supplier_field"], in: app)
            let search = searchField(in: app)
            XCTAssertTrue(search.waitForExistence(timeout: 8))
            search.tap()
            search.typeText(query)
            let preset = app.buttons["providers.supplier.preset.\(presetID)"]
            XCTAssertTrue(preset.waitForExistence(timeout: 8))
            preset.tap()
            let notNow = app.buttons["providers.service_offers.not_now"]
            if notNow.waitForExistence(timeout: 2) { notNow.tap() }
            dismissKeyboard(app)
            tapWhenHittable(app.buttons["providers.manage_models"], in: app)
            let model = app.switches["providers.model.\(modelID)"]
            for _ in 0..<8 where !model.exists { app.swipeUp() }
            XCTAssertTrue(model.waitForExistence(timeout: 8),
                          "The selected billing channel and purpose must offer \(modelID)")
            if noDiscovery {
                XCTAssertFalse(app.buttons["providers.refresh_models"].exists,
                               "A plan without model discovery must not offer a discovery request")
            }
            attach(app, "\(presetID)-\(modelID)-candidates")
            // No credentials, Save, connection test or Generate action.
            app.terminate()
        }
    }

    func testMediaProviderFormsReachPrefilledModelsWithoutGeneration() throws {
        XCUIDevice.shared.orientation = .landscapeLeft
        defer { XCUIDevice.shared.orientation = .portrait }
        for (role, title) in [("image", "Image generation/editing provider"),
                              ("video", "Video generation provider")] {
            let app = launchApp(iPad: true)
            openProviderEditor(app, roleTitle: title)
            let supplier = app.buttons["providers.supplier_field"]
            tapWhenHittable(supplier, in: app)
            let search = searchField(in: app)
            XCTAssertTrue(search.waitForExistence(timeout: 8))
            search.tap()
            search.typeText("volc")
            let preset = app.buttons["providers.supplier.preset.volcengineArk"]
            XCTAssertTrue(preset.waitForExistence(timeout: 8))
            preset.tap()
            let notNow = app.buttons["providers.service_offers.not_now"]
            if notNow.waitForExistence(timeout: 2) { notNow.tap() }
            dismissKeyboard(app)
            attach(app, role + " provider form")
            let models = app.buttons["providers.manage_models"]
            for _ in 0..<8 where !models.isHittable { app.swipeUp() }
            XCTAssertTrue(models.isHittable, "The media form must allow reaching model selection")
            models.tap()
            let candidates = app.switches.matching(NSPredicate(format: "identifier BEGINSWITH %@", "providers.model."))
            XCTAssertTrue(candidates.firstMatch.waitForExistence(timeout: 8), "Reviewed media model candidates must be prefilled")
            attach(app, role + " provider prefilled model selection")
            // No key, Save, Test or Generate action: no provider configuration
            // is persisted and no paid media request is sent.
            app.terminate()
        }
    }

    func testEmbeddedPickerSearchSelectAndOneTimeOfferOnIPad() throws {
        let app = launchApp(iPad: true)
        openProviderEditor(app)

        // A custom display name typed BEFORE selection must survive it.
        let name = app.textFields["providers.display_name"]
        replaceField(name, with: "Custom Floe Name")
        dismissKeyboard(app)
        attach(app, "01-editor-provider-field")

        // The catalog search lives inside this form (anchored popover on iPad).
        let supplierField = app.buttons["providers.supplier_field"]
        tapWhenHittable(supplierField, in: app)
        let search = searchField(in: app)
        if !search.waitForExistence(timeout: 8) {
            print("DEBUG PICKER HIERARCHY:\n\(app.debugDescription)")
        }
        XCTAssertTrue(search.waitForExistence(timeout: 4), "catalog search field missing")
        // There is no standalone catalog page: the form stays behind the popover.
        XCTAssertTrue(name.exists, "provider form must stay mounted behind the picker")
        // The same selector offers every built-in preset, including the
        // explicit manual/custom choice — with no query at all.
        XCTAssertTrue(app.buttons["providers.supplier.preset.custom"].waitForExistence(timeout: 6),
                      "built-in manual/custom choice missing from the unified selector")
        XCTAssertTrue(app.buttons["providers.supplier.preset.openAI"].exists,
                      "built-in OpenAI preset missing from the unified selector")
        attach(app, "02-embedded-picker-open")

        // Local alias search narrows the list and marks the alias.
        search.tap()
        search.typeText("mist")
        let mistral = app.buttons["providers.catalog.row.mistral"]
        XCTAssertTrue(mistral.waitForExistence(timeout: 6), "alias search did not find mistral")
        XCTAssertFalse(app.buttons["providers.catalog.row.openai"].exists,
                       "search results must be filtered locally")
        attach(app, "03-local-search-alias")

        // Selecting a single-role vendor closes the picker and keeps the name.
        mistral.tap()
        XCTAssertTrue(app.textFields["providers.display_name"].waitForExistence(timeout: 6))
        XCTAssertEqual(name.value as? String, "Custom Floe Name",
                       "a custom display name must survive catalog selection")
        attach(app, "04-selection-preserved-custom-name")

        // A genuinely multi-role vendor raises the ONE-TIME native prompt.
        tapWhenHittable(supplierField, in: app)
        XCTAssertTrue(search.waitForExistence(timeout: 6))
        clearText(search)
        search.typeText("openai")
        let openai = app.buttons["providers.catalog.row.openai"]
        XCTAssertTrue(openai.waitForExistence(timeout: 6), "openai row missing")
        openai.tap()
        let notNow = app.buttons["providers.service_offers.not_now"]
        let confirm = app.buttons["providers.service_offers.confirm"]
        let promptAppeared = notNow.waitForExistence(timeout: 8)
        XCTAssertTrue(promptAppeared, "multi-role opt-in prompt did not appear for openai")
        XCTAssertTrue(confirm.exists, "prompt must offer Configure selected")
        attach(app, "05-one-time-role-prompt")

        // Decline: the prompt closes, the form is intact, nothing was saved.
        notNow.tap()
        XCTAssertTrue(name.waitForExistence(timeout: 6))
        XCTAssertFalse(notNow.waitForExistence(timeout: 2), "declined prompt must dismiss")
        attach(app, "06-after-decline")

        // Re-selecting the same vendor must NOT raise the prompt again.
        tapWhenHittable(supplierField, in: app)
        XCTAssertTrue(search.waitForExistence(timeout: 6))
        clearText(search)
        search.typeText("openai")
        XCTAssertTrue(openai.waitForExistence(timeout: 6))
        openai.tap()
        XCTAssertTrue(name.waitForExistence(timeout: 6))
        XCTAssertFalse(notNow.waitForExistence(timeout: 3),
                       "a declined role must not be offered again")
        attach(app, "07-decline-not-repeated")
    }

    func testEmbeddedPickerAdaptsToSheetOnIPhone() throws {
        let app = launchApp(iPad: false)
        openProviderEditor(app)

        let supplierField = app.buttons["providers.supplier_field"]
        XCTAssertTrue(supplierField.waitForExistence(timeout: 8), "supplier field missing on iPhone")
        tapWhenHittable(supplierField, in: app)
        let search = searchField(in: app)
        if !search.waitForExistence(timeout: 8) {
            print("DEBUG PHONE SHEET HIERARCHY:\n\(app.debugDescription)")
        }
        XCTAssertTrue(search.waitForExistence(timeout: 4),
                      "adaptive sheet search field missing on iPhone")
        search.tap()
        search.typeText("goog")
        // The built-in section may match "goog" first; scroll the small sheet
        // until the verified catalog row materializes in the lazy list.
        let google = app.buttons["providers.catalog.row.google"]
        var attempts = 0
        while !google.exists, attempts < 6 {
            app.swipeUp()
            attempts += 1
        }
        XCTAssertTrue(google.waitForExistence(timeout: 6), "google row missing on iPhone")
        attach(app, "11-iphone-adaptive-sheet")

        // Cancel/dismiss returns to the same editor form without side effects.
        // While the iPhone system search bar is active it occupies the
        // navigation bar, hiding the toolbar Cancel item; the standard sheet
        // drag is the dismissal path there. Assert the same outcome (the form
        // returns, nothing is saved) rather than a particular chrome control.
        let cancel = app.buttons["providers.catalog.cancel"]
        if cancel.exists {
            cancel.tap()
        } else {
            let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.06))
            let end = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.7))
            start.press(forDuration: 0.05, thenDragTo: end)
        }
        XCTAssertTrue(app.textFields["providers.display_name"].waitForExistence(timeout: 8))
        attach(app, "12-iphone-form-after-cancel")
    }
}
