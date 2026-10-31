// FloeAgentUITests — native multi-image artifact gallery acceptance.
//
// Drives the REAL App chat over `--ui-test-multi-image-gallery-fixture`: two
// locally rendered PNGs are written into the managed GeneratedImages store and
// persisted as real ToolArtifactReference receipts on a completed synthetic
// run. The production ToolCallCardView verifies both files by size/type/hash
// and renders its own gallery. This test waits for both distinct thumbnails,
// opens each real full-screen preview, verifies the preview belongs to the
// tapped one-based image, returns to the same gallery, and checks count/order/
// no-duplicates. Screenshots are attached for the primary review.
//
// Proof boundary: controlled local bytes prove native display/preview. They do
// not prove paid generation, provider entitlement or batching (covered by the
// existing provider/controller fixtures).

import XCTest
import UIKit

@MainActor
final class MultiImageGalleryUITests: XCTestCase {

    private let fixtureArgument = "--ui-test-multi-image-gallery-fixture"
    private let thumbnailPrefix = "chat.artifact.image.thumbnail."
    private let galleryID = "chat.artifact.image.gallery"
    private let previewID = "chat.artifact.image.preview"
    private let previewDoneID = "chat.artifact.image.preview.done"

    private func launch() -> XCUIApplication {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments += [
            "-ui-testing",
            "--ui-test-skip-onboarding",
            fixtureArgument,
        ]
        if UIDevice.current.userInterfaceIdiom == .pad {
            app.launchArguments.append("-ui-testing-ipad")
        }
        app.launch()
        return app
    }

    private func attach(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func thumbnails(_ app: XCUIApplication) -> XCUIElementQuery {
        app.descendants(matching: .any).matching(
            NSPredicate(format: "identifier BEGINSWITH %@", thumbnailPrefix))
    }

    private func thumbnail(_ app: XCUIApplication, _ index: Int) -> XCUIElement {
        app.descendants(matching: .any)["\(thumbnailPrefix)\(index)"].firstMatch
    }

    /// The latest completed run starts expanded. If a layout/regression change
    /// collapses it, open the REAL run-records control rather than tapping a
    /// guessed coordinate; a missing gallery still fails the test.
    private func revealGallery(_ app: XCUIApplication) {
        if thumbnail(app, 0).waitForExistence(timeout: 20) { return }
        let toggle = app.descendants(matching: .any)["thread.steps.toggle"].firstMatch
        XCTAssertTrue(toggle.waitForExistence(timeout: 8),
                      "run records toggle must exist when the gallery is collapsed")
        toggle.tap()
    }

    /// Opens the tapped thumbnail through its real double-tap affordance and
    /// verifies the presented preview exposes the same one-based identity.
    private func openPreview(_ app: XCUIApplication, index: Int) -> String {
        let thumb = thumbnail(app, index)
        XCTAssertTrue(thumb.waitForExistence(timeout: 12), "thumbnail \(index) must exist")
        var scrolls = 0
        while !thumb.isHittable, scrolls < 3 {
            app.swipeUp()
            scrolls += 1
        }
        XCTAssertTrue(thumb.isHittable, "thumbnail \(index) must be directly tappable")
        let identity = thumb.label
        XCTAssertFalse(identity.isEmpty, "thumbnail \(index) must expose an accessible name")

        thumb.doubleTap()
        let preview = app.descendants(matching: .any)[previewID].firstMatch
        XCTAssertTrue(preview.waitForExistence(timeout: 12),
                      "full-screen preview for thumbnail \(index) must open")
        let previewIdentity = preview.label.isEmpty
            ? (preview.value as? String ?? "")
            : preview.label
        XCTAssertEqual(previewIdentity, identity,
                       "the preview must present the exact thumbnail that was tapped")
        return identity
    }

    private func closePreview(_ app: XCUIApplication) {
        let done = app.descendants(matching: .any)[previewDoneID].firstMatch
        XCTAssertTrue(done.waitForExistence(timeout: 8), "preview dismiss control")
        done.tap()
        let preview = app.descendants(matching: .any)[previewID].firstMatch
        XCTAssertTrue(preview.waitForNonExistence(timeout: 8),
                      "the full-screen preview must dismiss back to the same thread")
    }

    func testGalleryShowsBothVerifiedImagesAndEachPreviewKeepsItsOwnIdentity() {
        let app = launch()
        revealGallery(app)

        let gallery = app.descendants(matching: .any)[galleryID].firstMatch
        XCTAssertTrue(gallery.waitForExistence(timeout: 15), "production image gallery")
        XCTAssertTrue(thumbnail(app, 0).waitForExistence(timeout: 15), "first verified thumbnail")
        XCTAssertTrue(thumbnail(app, 1).waitForExistence(timeout: 15), "second verified thumbnail")

        let first = thumbnail(app, 0)
        let second = thumbnail(app, 1)
        XCTAssertEqual(thumbnails(app).count, 2,
                       "the gallery must expose exactly two verified images, no duplicates")
        XCTAssertFalse(thumbnail(app, 2).exists,
                       "no third gallery entry may be fabricated")
        XCTAssertNotEqual(first.label, second.label,
                          "adjacent images must have distinct accessible identities")
        XCTAssertLessThan(first.frame.minY, second.frame.minY,
                          "the gallery must keep artifact order")
        attach(app, "multi-image-gallery")

        let firstIdentity = openPreview(app, index: 0)
        attach(app, "multi-image-preview-1")
        closePreview(app)
        XCTAssertTrue(thumbnail(app, 0).waitForExistence(timeout: 10),
                      "the same gallery must be restored after the first preview")
        XCTAssertEqual(thumbnails(app).count, 2,
                       "returning must not duplicate or drop a gallery entry")
        attach(app, "multi-image-gallery-return-1")

        let secondIdentity = openPreview(app, index: 1)
        XCTAssertNotEqual(firstIdentity, secondIdentity,
                          "the second preview must be a distinct image, not the first")
        attach(app, "multi-image-preview-2")
        closePreview(app)
        XCTAssertTrue(thumbnail(app, 1).waitForExistence(timeout: 10),
                      "the same gallery must be restored after the second preview")
        XCTAssertEqual(thumbnails(app).count, 2,
                       "the final gallery must still expose exactly two images")
        XCTAssertEqual(thumbnail(app, 0).label, firstIdentity)
        XCTAssertEqual(thumbnail(app, 1).label, secondIdentity)
        attach(app, "multi-image-gallery-final")
    }
}
