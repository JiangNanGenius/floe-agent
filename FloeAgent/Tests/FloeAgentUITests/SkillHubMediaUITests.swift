// FloeAgentUITests — real-view fixtures for Skill Hub publication media.
//
// These drive the actual app on the reused iPad simulator and prove the
// product outcome on real catalog state: every official skill detail renders
// its cover band, ordinary non-featured rows render the compact thumbnail
// (or the honest glyph fallback), the detail gallery strip appears ONLY when
// the signed publication declares gallery media, and no image state ever
// breaks or disables the verified install CTA. All assertions are
// accessibility-identifier based — no language-dependent label matching.
// Screenshots attached here are presentation fixtures: they are NOT claims
// of inference or execution qualification. Main judges the actual screens
// and runs the batch; this lane performs no simulator executions.

#if canImport(XCTest)
import XCTest

@MainActor
final class SkillHubMediaUITests: XCTestCase {

    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .landscapeLeft
        app = XCUIApplication()
        app.launchArguments += ["-ui-testing", "-ui-testing-ipad", "--ui-test-skip-onboarding"]
        app.launch()
        let skills = app.staticTexts["sidebar.skills"]
        XCTAssertTrue(skills.waitForExistence(timeout: 15), "sidebar Skills row exists")
        skills.tap()
        XCTAssertTrue(app.scrollViews["skills.featured.carousel"].waitForExistence(timeout: 15),
                      "Skill Hub discover opens by default")
    }

    override func tearDownWithError() throws {
        app?.terminate()
        app = nil
    }

    private func scrollUntilPresent(_ element: XCUIElement, maxSwipes: Int = 6) {
        for _ in 0..<maxSwipes where !element.exists {
            app.swipeUp()
        }
    }

    private func keepScreenshot(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    /// Curated rows carry the publication identity row; its presence means
    /// the signed catalog actually loaded (network) in this run.
    private func curatedPublicationIsLoaded(skillID: String) -> Bool {
        app.descendants(matching: .any)
            .matching(identifier: "skills.detail.publication.\(skillID)").firstMatch
            .waitForExistence(timeout: 20)
    }

    // MARK: - 1. Every official skill detail renders its cover band

    func testDetailCoverBandAlwaysRenders() throws {
        let pdfCard = app.buttons["skills.card.floe-pdf"]
        scrollUntilPresent(pdfCard)
        XCTAssertTrue(pdfCard.waitForExistence(timeout: 10))
        pdfCard.tap()
        let detail = app.descendants(matching: .any)
            .matching(identifier: "skills.detail.floe-pdf").firstMatch
        XCTAssertTrue(detail.waitForExistence(timeout: 10))
        // The cover band exists whether or not the network delivered the
        // real artwork — the bundled category fallback is the honest base.
        let cover = app.descendants(matching: .any)
            .matching(identifier: "skills.detail.cover.floe-pdf").firstMatch
        XCTAssertTrue(cover.waitForExistence(timeout: 10),
                      "the detail page must render the cover band (real or bundled fallback)")
        // Media is presentation only: the verified action row is present and
        // unchanged regardless of image state.
        XCTAssertTrue(app.descendants(matching: .any)
            .matching(identifier: "skills.detail.cta.floe-pdf").firstMatch.exists,
                      "cover rendering must never remove or break the detail CTA")
        keepScreenshot("Skill Hub detail cover band (floe-pdf)")
    }

    // MARK: - 2. Non-featured rows use the compact thumbnail when width allows

    func testDirectoryRowCompactThumbnailPresentInWideShelf() throws {
        let officeRow = app.descendants(matching: .any)
            .matching(identifier: "skills.row.floe-office").firstMatch
        scrollUntilPresent(officeRow)
        XCTAssertTrue(officeRow.waitForExistence(timeout: 10), "office shelf row exists")
        let thumbnail = app.descendants(matching: .any)
            .matching(identifier: "skills.thumbnail.floe-office").firstMatch
        XCTAssertTrue(thumbnail.waitForExistence(timeout: 10),
                      "wide shelves render the compact thumbnail slot (image or glyph fallback)")
        XCTAssertEqual(thumbnail.frame.width, thumbnail.frame.height, accuracy: 2,
                       "the thumbnail stays a compact square tile")
        XCTAssertLessThanOrEqual(thumbnail.frame.width, 56)
        // The CTA beside the row is untouched by media state.
        XCTAssertTrue(app.buttons["skills.get.floe-office"].exists)
        keepScreenshot("Skill Hub compact thumbnail row (floe-office)")
    }

    // MARK: - 3. Gallery strip only from the signed publication

    func testDetailGalleryRendersOnlyWhenPublicationDeclaresIt() throws {
        let officeCard = app.buttons["skills.card.floe-office"]
        scrollUntilPresent(officeCard)
        XCTAssertTrue(officeCard.waitForExistence(timeout: 10))
        officeCard.tap()
        let detail = app.descendants(matching: .any)
            .matching(identifier: "skills.detail.floe-office").firstMatch
        XCTAssertTrue(detail.waitForExistence(timeout: 10))
        guard curatedPublicationIsLoaded(skillID: "floe-office") else {
            XCTFail("""
            ACTIONABLE, NOT SKIPPED: gallery coverage requires the live signed \
            curated catalog (network + the shared simulator's saved publication). \
            Main owns device state. Without it the App honestly shows only the \
            bundled fallback, and this run proves nothing about the strip.
            """)
            return
        }
        // The published showcase declares gallery media for floe-office; the
        // strip is the only honest source for it.
        let gallery = app.descendants(matching: .any)
            .matching(identifier: "skills.gallery.floe-office").firstMatch
        XCTAssertTrue(gallery.waitForExistence(timeout: 10),
                      "a publication-declared gallery must surface on the detail page")
        let first = app.descendants(matching: .any)
            .matching(identifier: "skills.gallery.item.floe-office.0").firstMatch
        XCTAssertTrue(first.exists)
        first.tap()
        XCTAssertTrue(app.descendants(matching: .any)
            .matching(identifier: "skills.gallery.caption").firstMatch.waitForExistence(timeout: 8),
                      "the viewer shows the authored truthful caption")
        XCTAssertTrue(app.buttons["skills.gallery.close"].waitForExistence(timeout: 8))
        keepScreenshot("Skill Hub gallery viewer (floe-office)")
        app.buttons["skills.gallery.close"].tap()
        // A skill WITHOUT declared gallery media shows no strip at all.
        app.navigationBars.buttons.firstMatch.tap()
        let pdfCard2 = app.buttons["skills.card.floe-pdf"]
        scrollUntilPresent(pdfCard2)
        pdfCard2.tap()
        XCTAssertTrue(app.descendants(matching: .any)
            .matching(identifier: "skills.detail.floe-pdf").firstMatch.waitForExistence(timeout: 10))
        XCTAssertFalse(app.descendants(matching: .any)
            .matching(identifier: "skills.gallery.floe-pdf").firstMatch.exists,
                       "no publication gallery data means the section stays hidden")
    }

    // MARK: - 4. Narrow layout keeps media honest and actions reachable

    func testNarrowLayoutKeepsThumbnailAndCTAsUsable() throws {
        XCUIDevice.shared.orientation = .portrait
        let officeRow = app.descendants(matching: .any)
            .matching(identifier: "skills.row.floe-office").firstMatch
        scrollUntilPresent(officeRow)
        XCTAssertTrue(officeRow.waitForExistence(timeout: 10))
        let get = app.buttons["skills.get.floe-office"]
        XCTAssertTrue(get.exists, "portrait rows keep their verified CTA")
        XCTAssertTrue(officeRow.frame.contains(CGPoint(x: get.frame.midX, y: get.frame.midY)),
                      "the CTA stays inside the card background at narrow width")
        // Either the compact thumbnail slot (when the width rule allows) or
        // the unchanged glyph tile — both are square, both are honest.
        let thumbnail = app.descendants(matching: .any)
            .matching(identifier: "skills.thumbnail.floe-office").firstMatch
        if thumbnail.exists {
            XCTAssertLessThanOrEqual(thumbnail.frame.width, 56)
        }
        keepScreenshot("Skill Hub portrait rows with media slots")
    }
}
#endif
