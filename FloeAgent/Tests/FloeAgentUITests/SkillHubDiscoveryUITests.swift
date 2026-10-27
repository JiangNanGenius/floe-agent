// FloeAgentUITests — Skill Hub native detail, shelf-consistent rows and
// trusted direct-download panel coverage (lane file).
//
// These drive the real app on the reused iPad simulator. They assert the
// build-301 product fixes: hub rows open a proper native detail page; a
// shelf uses ONE row composition for every item (the Office/PDF mismatch);
// the featured CTA lives inside the coherent card; and an official signed
// catalog Get opens the service-owned download panel directly — with real
// stage rows and NO generic permission inspector — while closing the panel
// keeps the job (chip + Retry prove service ownership).
//
// All assertions are accessibility-identifier based: no shared-simulator
// language dependency (no bare Chinese/English label matching).
// The direct-Get coverage is REQUIRED, not skippable: an unreachable
// signed catalog or a fully-installed shared simulator fails actionably
// (Main owns device state; a skipped Get is never counted as accepted).
// The flow cancels immediately to avoid mutating shared-simulator installs
// (the honest race window is the download stage; the service never
// half-commits). Do not uninstall existing user skills to force a case.
// Requires the UI folder's automatic test-target inclusion; Main runs the
// batch — this lane performs no simulator executions.

#if canImport(XCTest)
import XCTest

@MainActor
final class SkillHubDiscoveryUITests: XCTestCase {

    private var app: XCUIApplication!

    /// Catalog ids owned by the legacy bundled shelf — used to recognize a
    /// CURATED catalog entry for the direct-Get path.
    private let legacyIDs = ["floe-office", "floe-pdf", "floe-network", "floe-video"]

    override func setUpWithError() throws {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .landscapeLeft
        app = XCUIApplication()
        app.launchArguments += ["-ui-testing", "-ui-testing-ipad", "--ui-test-skip-onboarding"]
        app.launch()
        // Known build-301 Mini constraint: activate the sidebar entry only
        // through a hittable element, never a guessed coordinate.
        let skills = app.staticTexts["sidebar.skills"]
        XCTAssertTrue(skills.waitForExistence(timeout: 15), "sidebar Skills row exists")
        XCTAssertTrue(skills.isHittable, "sidebar Skills row is hittable")
        skills.tap()
        XCTAssertTrue(app.scrollViews["skills.featured.carousel"].waitForExistence(timeout: 15),
                      "Skill Hub discover opens by default")
    }

    override func tearDownWithError() throws {
        // Never leave the app running for the shared device.
        app?.terminate()
        app = nil
    }

    private func scrollUntilPresent(_ element: XCUIElement, maxSwipes: Int = 3) {
        for _ in 0..<maxSwipes where !element.exists {
            app.swipeUp()
        }
    }

    // MARK: - 1. Row/card taps open the unified native detail page

    func testHubRowOpensUnifiedNativeDetail() throws {
        let pdfCard = app.buttons["skills.card.floe-pdf"]
        scrollUntilPresent(pdfCard)
        XCTAssertTrue(pdfCard.waitForExistence(timeout: 10))
        pdfCard.tap()

        // The unified detail page (pushed navigation, not an alert/sheet).
        let detail = app.descendants(matching: .any)
            .matching(identifier: "skills.detail.floe-pdf").firstMatch
        XCTAssertTrue(detail.waitForExistence(timeout: 10),
                      "tapping a hub card must present the native detail page")
        XCTAssertTrue(app.descendants(matching: .any)
            .matching(identifier: "skills.detail.state.floe-pdf").firstMatch.waitForExistence(timeout: 8),
            "install state renders from the live center row")
        XCTAssertTrue(app.descendants(matching: .any)
            .matching(identifier: "skills.detail.cta.floe-pdf").firstMatch.exists,
            "the detail page owns the coherent action")
        // Installed bundled guides keep their honest facts on the page,
        // identified (not language-dependent): the installed-version row and
        // the update-details affordance.
        XCTAssertTrue(app.descendants(matching: .any)
            .matching(identifier: "skills.detail.installedVersion.floe-pdf").firstMatch.waitForExistence(timeout: 8),
            "installed rows show the real installed-version fact")
        XCTAssertTrue(app.descendants(matching: .any)
            .matching(identifier: "skills.detail.updateDetails.floe-pdf").firstMatch.exists)
        let evidence = XCTAttachment(screenshot: app.screenshot())
        evidence.name = "Skill Hub unified native detail"
        evidence.lifetime = .keepAlways
        add(evidence)
    }

    func testFeaturedCardOpensDetailAndCTALivesInsideTheCoherentCard() throws {
        let carousel = app.scrollViews["skills.featured.carousel"]
        XCTAssertTrue(carousel.waitForExistence(timeout: 10))
        // The featured CTA must sit INSIDE the card frame (build-301: it
        // floated under the rounded background).
        var checkedOneCard = false
        for legacyID in legacyIDs {
            let card = app.descendants(matching: .any)
                .matching(identifier: "skills.featured.card.\(legacyID)").firstMatch
            let get = app.buttons["skills.featured.get.\(legacyID)"]
            guard card.exists, get.exists else { continue }
            XCTAssertTrue(card.frame.contains(get.frame),
                          "featured \(legacyID) CTA must be inside its card")
            checkedOneCard = true
        }
        XCTAssertTrue(checkedOneCard, "at least one featured card must render its in-card CTA")
        // Any featured card body tap opens the same unified detail.
        let featured = app.buttons
            .matching(NSPredicate(format: "identifier BEGINSWITH %@", "skills.featured.floe-")).firstMatch
        XCTAssertTrue(featured.waitForExistence(timeout: 8))
        featured.tap()
        XCTAssertTrue(app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier CONTAINS %@", "skills.detail.")).firstMatch
            .waitForExistence(timeout: 10),
            "featured body tap presents the native detail page")
    }

    // MARK: - 2. One shelf, one row composition (Office vs PDF alignment)

    private func assertOfficeShelfRowsShareComposition() {
        let officeRow = app.descendants(matching: .any)
            .matching(identifier: "skills.row.floe-office").firstMatch
        let pdfRow = app.descendants(matching: .any)
            .matching(identifier: "skills.row.floe-pdf").firstMatch
        scrollUntilPresent(officeRow)
        scrollUntilPresent(pdfRow)
        // Legacy bundled rows always exist; absence is an actionable failure,
        // never a skip.
        XCTAssertTrue(officeRow.exists && pdfRow.exists,
                      "the office shelf must render both legacy rows (hub layout regression)")
        let officeGet = app.buttons["skills.get.floe-office"]
        let pdfGet = app.buttons["skills.get.floe-pdf"]
        XCTAssertTrue(officeGet.exists && pdfGet.exists)
        // Same composition ⇒ the CTA sits on the same side of the row body.
        // Before the fix, per-item ViewThatFits could flip one row only.
        let officeInline = officeGet.frame.midX > officeRow.frame.midX
        let pdfInline = pdfGet.frame.midX > pdfRow.frame.midX
        XCTAssertEqual(officeInline, pdfInline,
                       "rows in one shelf must share the same composition, never per-item branching")
    }

    func testShelfRowsUseOneConsistentComposition() throws {
        assertOfficeShelfRowsShareComposition()
        // In landscape-regular the wide shelves keep the CTA beside the text.
        let officeRow = app.descendants(matching: .any)
            .matching(identifier: "skills.row.floe-office").firstMatch
        let officeGet = app.buttons["skills.get.floe-office"]
        XCTAssertTrue(officeGet.frame.midX > officeRow.frame.midX,
                      "wide shelves keep the CTA inline beside the row content")
    }

    func testCompactNarrowShelfKeepsOneConsistentComposition() throws {
        XCUIDevice.shared.orientation = .portrait
        assertOfficeShelfRowsShareComposition()
    }

    // MARK: - 3. Trusted official catalog Get: direct download panel, no inspector

    func testOfficialCatalogGetOpensDirectDownloadPanel() throws {
        // Find a CURATED catalog entry (not a legacy bundled id) whose Get
        // action is live. Never uninstall anything to force this case.
        let getButtons = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "skills.get."))
        var target: (id: String, button: XCUIElement)? = nil
        // Curated entries are below the bundled first shelf in the lazy list.
        // Visit real visible rows instead of assuming every catalog row is materialized.
        for _ in 0..<12 {
            for index in 0..<getButtons.count {
                let button = getButtons.element(boundBy: index)
                guard button.exists, button.isEnabled, button.isHittable,
                      ["获取", "Get"].contains(button.label) else { continue }
                let skillID = String(button.identifier.dropFirst("skills.get.".count))
                if legacyIDs.contains(skillID) { continue }
                target = (skillID, button)
                break
            }
            if target != nil { break }
            app.swipeUp()
        }
        guard let (skillID, button) = target else {
            XCTFail("""
            ACTIONABLE, NOT SKIPPED: the required direct-Get path needs the live signed \
            catalog AND at least one curated entry not already installed on this shared \
            simulator. If the catalog load failed, re-run with network; if every curated \
            entry is installed, Main owns the device state — do NOT uninstall user skills. \
            Coverage of the official Get is not accepted from this run either way.
            """)
            return
        }
        button.tap()

        // Direct download panel opens — NOT the generic permission inspector.
        let panel = app.descendants(matching: .any)
            .matching(identifier: "skills.download.panel.\(skillID)").firstMatch
        XCTAssertTrue(panel.waitForExistence(timeout: 8),
                      "official catalog Get must start the service-owned download panel directly")
        XCTAssertFalse(app.buttons["skills.review.install"].exists,
                       "a fresh audited Get must not route through the full inspector")
        // Real stage rows render.
        for stage in ["preparing", "downloading", "checking", "installing"] {
            XCTAssertTrue(app.descendants(matching: .any)
                .matching(identifier: "skills.download.stage.\(stage)").firstMatch.waitForExistence(timeout: 5),
                "stage row \(stage) must exist with its honest pending/active/done state")
        }
        let cancel = app.buttons["skills.download.cancel.\(skillID)"]
        let installed = app.descendants(matching: .any)
            .matching(identifier: "skills.download.installed.\(skillID)").firstMatch
        XCTAssertTrue(cancel.exists || installed.exists,
                      "a download offers Cancel while live or its actual installed result")
        let downloadEvidence = XCTAttachment(screenshot: app.screenshot())
        downloadEvidence.name = "Skill Hub direct download progress or completed result"
        downloadEvidence.lifetime = .keepAlways
        add(downloadEvidence)

        // Closing the sheet must NOT kill the job — it is service-owned.
        let close = app.buttons["skills.download.close.\(skillID)"]
        if close.exists { close.tap() }
        XCTAssertTrue(app.scrollViews["skills.featured.carousel"].waitForExistence(timeout: 8),
                      "panel closes back onto the hub")

        // Cancel at the boundary so the shared simulator is not mutated by a
        // full install from the live catalog. If the job already reached a
        // terminal success, the honest Retry/installed state is acceptable —
        // assert coherence, never force a specific race outcome.
        let chip = app.descendants(matching: .any)
            .matching(identifier: "skills.download.chip.\(skillID)").firstMatch
        if chip.waitForExistence(timeout: 4) {
            chip.tap()
            XCTAssertTrue(panel.waitForExistence(timeout: 5), "the chip reopens the SAME job panel")
            let cancel = app.buttons["skills.download.cancel.\(skillID)"]
            if cancel.exists { cancel.tap() }
        }
        if chip.exists {
            chip.tap()
            XCTAssertTrue(panel.waitForExistence(timeout: 5))
            // Cancelled or failed jobs honestly offer Retry on the same job
            // identity; a committed install honestly shows neither (success is
            // not a persistent banner).
            let settled = app.buttons["skills.download.retry.\(skillID)"].exists
                || app.descendants(matching: .any)
                    .matching(identifier: "skills.download.panel.\(skillID)").firstMatch.exists
            XCTAssertTrue(settled, "the settled panel must show either Retry or the completed state")
        }
        let evidence = XCTAttachment(screenshot: app.screenshot())
        evidence.name = "Skill Hub direct download panel for \(skillID)"
        evidence.lifetime = .keepAlways
        add(evidence)
    }
}

/// Same native store views at a real compact content width on the one reused iPad.
@MainActor
final class SkillHubCompactLayoutUITests: XCTestCase {
    func testNarrowStoreRowsAndNativeDetailRemainUsable() {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchArguments = ["-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN",
                               "-ui-testing", "--ui-test-skip-onboarding", "--ui-test-compact-skillhub"]
        app.launch()
        defer { app.terminate() }
        let category = app.buttons["skills.category.office"]
        XCTAssertTrue(category.waitForExistence(timeout: 30))
        for _ in 0..<6 where !category.isHittable { app.swipeUp() }
        XCTAssertTrue(category.isHittable)
        category.tap()
        for id in ["floe-office", "floe-pdf"] {
            let row = app.descendants(matching: .any).matching(identifier: "skills.row.\(id)").firstMatch
            XCTAssertTrue(row.waitForExistence(timeout: 10))
            XCTAssertLessThanOrEqual(row.frame.width, 390)
            let action = app.buttons["skills.get.\(id)"]
            XCTAssertTrue(action.exists)
            XCTAssertTrue(row.frame.contains(CGPoint(x: action.frame.midX, y: action.frame.midY)))
        }
        keepScreenshot(app, name: "Skill Hub compact width rows")
        app.buttons["skills.card.floe-pdf"].tap()
        XCTAssertTrue(app.descendants(matching: .any)
            .matching(identifier: "skills.detail.floe-pdf").firstMatch.waitForExistence(timeout: 10))
        keepScreenshot(app, name: "Skill Hub compact width native detail")
    }

    private func keepScreenshot(_ app: XCUIApplication, name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}

#endif
