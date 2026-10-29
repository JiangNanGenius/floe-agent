// FloeAgentUITests — real-view fixtures for Skill Hub publication media.
//
// These drive the actual app on the reused iPad simulator and prove the
// product outcome on real catalog state: a featured skill detail renders its
// cover band, an ordinary non-featured row renders the compact square
// thumbnail, the detail gallery strip appears only from the signed
// publication's showcase, and no image state ever breaks or disables the
// verified install CTA. All assertions are accessibility-identifier based —
// no language-dependent label matching.
//
// Media layout is judged proportionally: the thumbnail must remain a square
// contained in its row and must not dominate the row or cover the CTA. There
// is deliberately no universal pixel-size rule; the actual compact artwork
// is a visual design decision owned by Main, while the tests defend the
// structural invariants and the honest fallback.
//
// The gallery fixture uses a skill that is actually part of the signed
// curated catalog (Impeccable), so its publication identity row proves the
// signed feed loaded before the gallery assertions run. A bundled-only row
// (e.g. floe-office) can carry showcase artwork but cannot prove the signed
// catalog itself; no fallback is ever treated as gallery evidence.
//
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

    /// Wait for an element and reveal it with a bounded number of swipes only
    /// when it is genuinely below the fold. Stops as soon as the element
    /// materializes, unlike a fixed swipe count that can overshoot a shelf
    /// and report a false absence.
    private func reveal(_ element: XCUIElement, maxSwipes: Int = 3) {
        if element.waitForExistence(timeout: 2) { return }
        for _ in 0..<maxSwipes {
            guard !element.exists else { return }
            app.swipeUp()
            if element.waitForExistence(timeout: 1) { return }
        }
    }

    private func keepScreenshot(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func element(_ identifier: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    /// Drive the real category filter instead of guessing a scroll offset.
    /// Selecting the shelf removes the featured hero and materializes that
    /// category's ordinary rows, which is the state these tests inspect.
    private func selectCategory(_ categoryID: String) {
        let category = app.buttons["skills.category.\(categoryID)"]
        if !category.exists {
            app.swipeUp()
        }
        XCTAssertTrue(category.waitForExistence(timeout: 10),
                      "\(categoryID) category filter exists")
        category.tap()
    }

    /// Open a detail page from either the featured card or an ordinary row.
    /// The featured surface and the directory row use different identifiers
    /// (`skills.featured.*` vs `skills.card.*`); this is the actual product
    /// contract, not an interchangeable test alias.
    @discardableResult
    private func openDetail(_ skillID: String) -> Bool {
        let card = app.buttons["skills.card.\(skillID)"]
        if card.waitForExistence(timeout: 5), card.isHittable {
            card.tap()
        } else {
            let featured = app.buttons["skills.featured.\(skillID)"]
            guard featured.waitForExistence(timeout: 5), featured.isHittable else {
                return false
            }
            featured.tap()
        }
        return element("skills.detail.\(skillID)").waitForExistence(timeout: 10)
    }

    /// Curated rows expose the signed publication identity. A bundled-only
    /// row does not render this row even when showcase artwork is present,
    /// so gallery coverage is anchored to a skill that is in the signed
    /// catalog. The row can sit below the first screen of the Form.
    private func curatedPublicationIsLoaded(skillID: String) -> Bool {
        let publication = element("skills.detail.publication.\(skillID)")
        if publication.waitForExistence(timeout: 10) { return true }
        reveal(publication, maxSwipes: 3)
        return publication.exists
    }

    /// The catalog failure state is a visible product affordance, not a test
    /// skip. Exercise the real retry once so a transient launch failure can
    /// recover before the gallery fixture is opened. A still-failing catalog
    /// is reported by the publication guard below, never silently accepted.
    private func retryCatalogIfVisible() {
        let retry = app.buttons["skills.catalog.retry"]
        guard retry.waitForExistence(timeout: 3) else { return }
        retry.tap()
        let error = app.staticTexts["skills.catalog.error"]
        let cleared = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == false"), object: error)
        _ = XCTWaiter.wait(for: [cleared], timeout: 30)
    }

    /// A compact thumbnail is square, stays inside the row card, and never
    /// dominates the row or overlaps the verified action. These are relative
    /// product invariants; 56pt is not a design constant.
    private func assertCompactThumbnail(_ thumbnail: XCUIElement, in row: XCUIElement) {
        XCTAssertEqual(thumbnail.frame.width, thumbnail.frame.height, accuracy: 2,
                       "the thumbnail stays a square tile")
        XCTAssertTrue(row.frame.contains(thumbnail.frame),
                      "the compact thumbnail stays inside the row card")
        XCTAssertLessThan(thumbnail.frame.width, row.frame.width / 2,
                          "leading media must not dominate the row")
        XCTAssertLessThan(thumbnail.frame.height, row.frame.height,
                          "leading media must stay smaller than the row it belongs to")
    }

    // MARK: - 1. Every official skill detail renders its cover band

    func testDetailCoverBandAlwaysRenders() throws {
        // floe-pdf is a featured card on Discover. The featured body button
        // is `skills.featured.<id>`; `skills.card.<id>` belongs to rows.
        XCTAssertTrue(openDetail("floe-pdf"), "the PDF featured card opens its detail")
        // The cover band exists whether or not the network delivered the
        // real artwork — the bundled category fallback is the honest base.
        let cover = element("skills.detail.cover.floe-pdf")
        XCTAssertTrue(cover.waitForExistence(timeout: 10),
                      "the detail page must render the cover band (real or bundled fallback)")
        // Media is presentation only: the verified action row is present and
        // unchanged regardless of image state.
        let cta = element("skills.detail.cta.floe-pdf")
        reveal(cta, maxSwipes: 4)
        XCTAssertTrue(cta.exists,
                      "cover rendering must never remove or break the detail CTA")
        keepScreenshot("Skill Hub detail cover band (floe-pdf)")
    }

    // MARK: - 2. Non-featured rows use the compact thumbnail when width allows

    func testDirectoryRowCompactThumbnailPresentInWideShelf() throws {
        selectCategory("office")
        let officeRow = element("skills.row.floe-office")
        XCTAssertTrue(officeRow.waitForExistence(timeout: 10), "office shelf row exists")
        let thumbnail = element("skills.thumbnail.floe-office")
        XCTAssertTrue(thumbnail.waitForExistence(timeout: 10),
                      "wide shelves render the compact thumbnail slot (image or glyph fallback)")
        assertCompactThumbnail(thumbnail, in: officeRow)
        // The CTA beside the row is untouched by media state.
        let get = app.buttons["skills.get.floe-office"]
        XCTAssertTrue(get.exists, "the ordinary row keeps its verified action")
        XCTAssertFalse(thumbnail.frame.intersects(get.frame),
                       "the compact thumbnail never covers the verified CTA")
        keepScreenshot("Skill Hub compact thumbnail row (floe-office)")
    }

    // MARK: - 3. Gallery strip only from the signed publication

    func testDetailGalleryRendersOnlyWhenPublicationDeclaresIt() throws {
        retryCatalogIfVisible()
        // Impeccable is a real signed-catalog entry with a declared gallery.
        // It is not a bundled fallback, so its publication identity row is
        // meaningful evidence that the signed feed loaded in this run.
        selectCategory("design")
        guard openDetail("impeccable") else {
            XCTFail("""
            ACTIONABLE, NOT SKIPPED: gallery coverage requires the live signed \
            curated catalog (or this install's last authenticated publication) \
            to list Impeccable. This run has no curated row, so the bundled \
            fallback proves nothing about gallery media. Do not accept gallery \
            coverage from this run.
            """)
            return
        }
        guard curatedPublicationIsLoaded(skillID: "impeccable") else {
            XCTFail("""
            ACTIONABLE, NOT SKIPPED: gallery coverage requires the signed curated \
            publication. This run rendered the bundled fallback but no verified \
            publication identity for Impeccable; the strip is not proven.
            """)
            return
        }
        // The gallery lives near the top of the detail page; the publication
        // row may have required a scroll into the About section.
        for _ in 0..<4 { app.swipeDown() }
        let gallery = element("skills.gallery.impeccable")
        XCTAssertTrue(gallery.waitForExistence(timeout: 10),
                      "a publication-declared gallery must surface on the detail page")
        let first = element("skills.gallery.item.impeccable.0")
        XCTAssertTrue(first.waitForExistence(timeout: 8))
        first.tap()
        XCTAssertTrue(element("skills.gallery.caption").waitForExistence(timeout: 8),
                      "the viewer shows the authored truthful caption")
        XCTAssertTrue(app.buttons["skills.gallery.close"].waitForExistence(timeout: 8))
        keepScreenshot("Skill Hub gallery viewer (impeccable)")
        app.buttons["skills.gallery.close"].tap()

        // A skill WITHOUT declared gallery media shows no strip at all. The
        // signed publication has already loaded, so the empty strip here is
        // negative evidence, not just an offline absence. Relaunch instead of
        // tapping `navigationBars.buttons.firstMatch`: the split view can
        // expose the sidebar toggle/add and the detail back button in
        // different bars, and firstMatch is not guaranteed to be the detail
        // back control.
        app.terminate()
        app.launch()
        let skills = app.staticTexts["sidebar.skills"]
        XCTAssertTrue(skills.waitForExistence(timeout: 15),
                      "relaunch returns to the shared app shell")
        skills.tap()
        XCTAssertTrue(app.scrollViews["skills.featured.carousel"].waitForExistence(timeout: 15),
                      "relaunch returns to Skill Hub discover")
        selectCategory("office")
        XCTAssertTrue(openDetail("floe-pdf"), "the PDF row opens from the office filter")
        XCTAssertFalse(element("skills.gallery.floe-pdf").waitForExistence(timeout: 3),
                       "no publication gallery data means the section stays hidden")
    }

    // MARK: - 4. Narrow layout keeps media honest and actions reachable

    func testNarrowLayoutKeepsThumbnailAndCTAsUsable() throws {
        XCUIDevice.shared.orientation = .portrait
        selectCategory("office")
        let officeRow = element("skills.row.floe-office")
        XCTAssertTrue(officeRow.waitForExistence(timeout: 10))
        let get = app.buttons["skills.get.floe-office"]
        XCTAssertTrue(get.exists, "portrait rows keep their verified CTA")
        XCTAssertTrue(officeRow.frame.contains(CGPoint(x: get.frame.midX, y: get.frame.midY)),
                      "the CTA stays inside the card background at narrow width")
        // Either the compact thumbnail slot (when the width rule allows) or
        // the unchanged glyph tile — both are square, both are honest.
        let thumbnail = element("skills.thumbnail.floe-office")
        if thumbnail.exists {
            assertCompactThumbnail(thumbnail, in: officeRow)
            XCTAssertFalse(thumbnail.frame.intersects(get.frame),
                           "the compact thumbnail never covers the narrow-row CTA")
        }
        keepScreenshot("Skill Hub portrait rows with media slots")
    }
}
#endif
