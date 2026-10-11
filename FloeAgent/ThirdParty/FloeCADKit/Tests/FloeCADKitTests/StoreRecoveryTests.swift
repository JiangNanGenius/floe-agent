//
//  StoreRecoveryTests.swift
//  FloeCADKitTests
//
//  Failure-injection regressions for the document package (review
//  2026-10-09):
//    * an overwrite that fails AFTER moving the old package aside must
//      restore/keep the old document — a failed create never deletes data;
//    * a commit that fails before rotation keeps the previous package valid;
//    * a stale-payload commit is refused by the revision guard, not applied.
//

import XCTest
import UIKit
@testable import FloeCAD

final class StoreRecoveryTests: XCTestCase {

    private var workDir: URL!

    override func setUpWithError() throws {
        workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("FloeCADStore-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        CADDocumentFaultInjection.beforeCreateSwap = nil
        CADDocumentFaultInjection.beforeCommit = nil
        if let workDir { try? FileManager.default.removeItem(at: workDir) }
    }

    private func addBox(_ document: FloeCADDocument, size: Double,
                        file: StaticString = #filePath, line: UInt = #line) {
        let sketch = document.executeJSON(Data(#"{"op":"sketch.create","args":{"name":"S"}}"#.utf8))
        let object = (try? JSONSerialization.jsonObject(with: sketch.payload)) as? [String: Any]
        guard let sketchID = object?["sketchID"] as? String else {
            return XCTFail("no sketch id", file: file, line: line)
        }
        let outcome = document.executeJSON(Data("""
        {"op":"sketch.addEntities","args":{"sketchID":"\(sketchID)",
         "entities":[{"kind":"rect","min":[0,0],"max":[\(size),\(size)]}]}}
        """.utf8))
        XCTAssertTrue(outcome.isOK, "\(outcome.message ?? "")", file: file, line: line)
        let extrude = document.executeJSON(Data("""
        {"op":"feature.extrude","args":{"sketchID":"\(sketchID)","seedPoint":[1,1],"distance":\(size)}}
        """.utf8))
        XCTAssertTrue(extrude.isOK, "\(extrude.message ?? "")", file: file, line: line)
    }

    private func siblingDebris() -> [String] {
        let contents = (try? FileManager.default.contentsOfDirectory(atPath: workDir.path)) ?? []
        return contents.filter { $0.hasPrefix(".") || $0.contains(".staging-")
            || $0.contains(".old-") || $0.contains(".create-") || $0.contains(".rotate-") }
    }

    // MARK: Overwrite create failure

    func testOverwriteCreateFailureNeverDeletesExistingDocument() async throws {
        let url = workDir.appendingPathComponent("part.floecad")
        let original = try await FloeCADDocument.create(at: url, name: "Original")
        addBox(original, size: 10)
        let originalSave = await original.save()
        XCTAssertTrue(originalSave.succeeded, originalSave.error ?? "")
        let originalSHA = originalSave.contentSHA256
        let originalRevision = originalSave.revision
        original.close()

        CADDocumentFaultInjection.beforeCreateSwap = {
            throw NSError(domain: "FloeCADTest", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "injected create failure"])
        }
        do {
            _ = try await FloeCADDocument.create(at: url, name: "Replacement", overwrite: true)
            XCTFail("create must fail under fault injection")
        } catch {
            // expected
        }
        CADDocumentFaultInjection.beforeCreateSwap = nil

        // The original document must still be there, byte-identical in revision
        // and content identity.
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path),
                      "failed overwrite deleted the existing document")
        let reopened = try await FloeCADDocument.open(at: url)
        XCTAssertEqual(reopened.summary().name, "Original")
        XCTAssertEqual(reopened.summary().revision, originalRevision)
        XCTAssertEqual(reopened.summary().contentSHA256, originalSHA)
        XCTAssertEqual(reopened.summary().bodyCount, 1)
        reopened.close()
        XCTAssertTrue(siblingDebris().isEmpty,
                      "staging/backup debris left behind: \(siblingDebris())")
    }

    func testOverwriteCreateSuccessKeepsPreviousSnapshot() async throws {
        let url = workDir.appendingPathComponent("part.floecad")
        let original = try await FloeCADDocument.create(at: url, name: "Original")
        original.close()
        let replacement = try await FloeCADDocument.create(at: url, name: "Replacement",
                                                           overwrite: true)
        XCTAssertEqual(replacement.summary().name, "Replacement")
        replacement.close()
        // The replaced package stays recoverable as the new package's
        // previous snapshot.
        let previous = url.appendingPathComponent("previous/snapshot/manifest.json")
        XCTAssertTrue(FileManager.default.fileExists(atPath: previous.path),
                      "replaced package must be retained as previous snapshot")
    }

    // MARK: Commit failure

    func testCommitFailureLeavesPreviousCommitValidAndRetrySucceeds() async throws {
        let url = workDir.appendingPathComponent("part.floecad")
        let document = try await FloeCADDocument.create(at: url, name: "Commit")
        addBox(document, size: 10)
        let first = await document.save()
        XCTAssertTrue(first.succeeded, first.error ?? "")

        addBox(document, size: 4)
        CADDocumentFaultInjection.beforeCommit = {
            throw NSError(domain: "FloeCADTest", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "injected commit failure"])
        }
        let failed = await document.save()
        CADDocumentFaultInjection.beforeCommit = nil
        XCTAssertFalse(failed.succeeded, "injected commit failure must be reported")
        document.close()

        // On disk the previous commit is untouched and reopens cleanly.
        let reopened = try await FloeCADDocument.open(at: url)
        XCTAssertEqual(reopened.summary().revision, first.revision)
        XCTAssertEqual(reopened.summary().contentSHA256, first.contentSHA256)
        reopened.close()

        // A retry after the injected failure commits normally.
        let second = try await FloeCADDocument.open(at: url)
        addBox(second, size: 4)
        // Clear the cache-independent failure path: no injection set.
        let retried = await second.save()
        XCTAssertTrue(retried.succeeded, retried.error ?? "")
        XCTAssertGreaterThan(retried.revision, first.revision)
        second.close()
        XCTAssertTrue(siblingDebris().isEmpty, "debris: \(siblingDebris())")
    }

    // MARK: Preview artifact (T7S)

    /// Real PNG bytes (CoreGraphics), standing in for the viewport thumbnail
    /// `EditorViewModel.saveThumbnail()` records from the live renderer. Not a
    /// fabricated header: the save/reopen assertions compare actual bytes.
    private func previewPNGBytes() throws -> Data {
        let size = CGSize(width: 96, height: 72)
        let renderer = UIGraphicsImageRenderer(size: size)
        let image = renderer.image { context in
            UIColor.systemTeal.setFill()
            context.fill(CGRect(origin: .zero, size: size))
        }
        return try XCTUnwrap(image.pngData())
    }

    /// Regression (T7S, actual iPhone fullscreen return): the workbench records
    /// the live viewport thumbnail when the fullscreen editor disappears and
    /// saves the SAME session. A brand-new CAD document has no mesh/brep/image
    /// payloads, so its package has no `blobs/` directory yet — the thumbnail
    /// write used to fail with NSCocoaError 4 (“thumbnail.img doesn’t exist”),
    /// the workbench surfaced a save-failure alert, and the preview was never
    /// committed. The save must commit the preview and reopen byte-identical.
    func testEmptyDocumentThumbnailSaveCommitsPreviewAndReopensIdentical() async throws {
        let url = workDir.appendingPathComponent("Empty.floecad")
        let document = try await FloeCADDocument.create(at: url, name: "Empty")
        XCTAssertEqual(document.summary().bodyCount, 0)
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: url.appendingPathComponent("blobs/thumbnail.img").path),
            "a brand-new package carries no preview yet")

        // The exact production close/fullscreen-return sequence:
        // ViewportView installs `thumbnailProvider`, FloeCADEditorView
        // .onDisappear calls `saveThumbnail()` (which writes
        // `session.project.thumbnail`), then `document.save()`.
        let png = try previewPNGBytes()
        XCTAssertEqual(png.prefix(2), Data([0x89, 0x50]), "PNG signature")
        let model = document.viewModel()
        XCTAssertTrue(model === document.viewModel(),
                      "the fullscreen toggle must reuse one editor view model/session")
        model.thumbnailProvider = { png }
        model.saveThumbnail()
        XCTAssertEqual(document.session.project.thumbnail, png)

        let save = await document.save()
        XCTAssertTrue(save.succeeded, save.error ?? "the empty package must commit its preview")
        XCTAssertNil(document.session.lastSaveError)
        XCTAssertGreaterThan(save.revision, 0)
        XCTAssertEqual(save.contentSHA256.count, 64)

        // The preview artifact really landed in the committed package.
        let thumbnailURL = url.appendingPathComponent("blobs/thumbnail.img")
        XCTAssertTrue(FileManager.default.fileExists(atPath: thumbnailURL.path),
                      "the committed package must carry blobs/thumbnail.img")
        XCTAssertEqual(try Data(contentsOf: thumbnailURL), png)

        // Reopen: the registered preview comes back byte-identical.
        document.close()
        let reopened = try await FloeCADDocument.open(at: url)
        XCTAssertEqual(reopened.session.project.thumbnail, png,
                       "reopening must read the committed preview bytes")
        XCTAssertEqual(reopened.summary().revision, save.revision)
        XCTAssertEqual(reopened.summary().contentSHA256, save.contentSHA256)
        XCTAssertEqual(reopened.summary().bodyCount, 0)
        reopened.close()
        XCTAssertTrue(siblingDebris().isEmpty, "debris: \(siblingDebris())")
    }

    /// A genuinely failing preview save must surface the error, keep the draft
    /// (and its preview) alive in the same session, leave the on-disk package
    /// untouched, and commit normally on retry — never a silent success and
    /// never a half-written package.
    func testThumbnailSaveFailureKeepsDraftAndRetryCommitsPreview() async throws {
        let url = workDir.appendingPathComponent("Retry.floecad")
        let document = try await FloeCADDocument.create(at: url, name: "Retry")
        addBox(document, size: 6)
        let png = try previewPNGBytes()
        let model = document.viewModel()
        model.thumbnailProvider = { png }
        model.saveThumbnail()
        let revisionBefore = document.revision

        CADDocumentFaultInjection.beforeCommit = {
            throw NSError(domain: "FloeCADTest", code: 3,
                          userInfo: [NSLocalizedDescriptionKey: "injected preview-save failure"])
        }
        let failed = await document.save()
        CADDocumentFaultInjection.beforeCommit = nil

        XCTAssertFalse(failed.succeeded, "an injected failure must be reported")
        XCTAssertNotNil(document.session.lastSaveError,
                        "the failure must be surfaced, never swallowed")
        // The draft and its preview stay alive for retry; disk did not move.
        XCTAssertTrue(document.hasUnsavedChanges)
        XCTAssertEqual(document.session.project.thumbnail, png)
        XCTAssertEqual(document.revision, revisionBefore)
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: url.appendingPathComponent("blobs/thumbnail.img").path))
        let onDisk = await FloeCADDocument.storedIdentity(at: url)
        XCTAssertEqual(onDisk?.revision, revisionBefore,
                       "a failed preview save must not move the committed revision")

        // Retry after the fault clears: the same session commits the preview.
        let retried = await document.save()
        XCTAssertTrue(retried.succeeded, retried.error ?? "")
        XCTAssertNil(document.session.lastSaveError)
        XCTAssertFalse(document.hasUnsavedChanges)
        XCTAssertEqual(try Data(contentsOf: url.appendingPathComponent("blobs/thumbnail.img")), png)
        document.close()

        let reopened = try await FloeCADDocument.open(at: url)
        XCTAssertEqual(reopened.session.project.thumbnail, png)
        XCTAssertEqual(reopened.summary().bodyCount, 1)
        reopened.close()
        XCTAssertTrue(siblingDebris().isEmpty, "debris: \(siblingDebris())")
    }

    /// The package-level staged create (`FloeCADDocument.create` and the
    /// overwrite/import routes) shares the same rule as an in-place commit: a
    /// payload with a preview but no mesh/brep/image blobs must create its
    /// `blobs/` directory while staging, or the create fails with
    /// “thumbnail.img doesn’t exist”.
    func testStagedCreateWithThumbnailAndNoBlobsCommitsPreview() async throws {
        let url = workDir.appendingPathComponent("Created.floecad")
        let store = FileCADDocumentStore(packageURL: url)
        let project = Project(name: "Created")
        let png = try previewPNGBytes()
        project.thumbnail = png
        let payload = try store.makePayload(project)
        try FileCADDocumentStore.createPackage(at: url, payload: payload, overwrite: false)

        let reopened = try await FloeCADDocument.open(at: url)
        XCTAssertEqual(reopened.session.project.thumbnail, png)
        XCTAssertEqual(reopened.summary().bodyCount, 0)
        reopened.close()
        XCTAssertTrue(siblingDebris().isEmpty, "debris: \(siblingDebris())")
    }

    // MARK: Creation identity vs preview-only commits (T7T)

    /// The ADDITIVE `modelSHA256` is deterministic and stable across repeated
    /// saves. Swift's default `JSONEncoder` emits an UNSPECIFIED key order
    /// (observed: a different order for every encode of the same value on
    /// Xcode 27 / Swift 6), so the legacy `contentSHA256` alone cannot express
    /// “semantically unchanged” across commits; the canonical model identity
    /// is what the creation/cancel guard uses for that proof, while the
    /// legacy content identity keeps its existing inputs and semantics.
    func testModelIdentityIsStableAcrossRepeatedUntouchedSaves() async throws {
        let url = workDir.appendingPathComponent("Stable.floecad")
        let document = try await FloeCADDocument.create(at: url, name: "Stable")
        let first = await document.save()
        XCTAssertTrue(first.succeeded, first.error ?? "")
        XCTAssertFalse(first.modelSHA256.isEmpty)
        let second = await document.save()
        XCTAssertTrue(second.succeeded, second.error ?? "")
        let third = await document.save()
        XCTAssertTrue(third.succeeded, third.error ?? "")

        XCTAssertGreaterThan(second.revision, first.revision)
        XCTAssertGreaterThan(third.revision, second.revision)
        XCTAssertEqual(second.modelSHA256, first.modelSHA256,
                       "the canonical model identity must be deterministic")
        XCTAssertEqual(third.modelSHA256, first.modelSHA256)

        // The manifest persists the additive identity; a fresh (off-main)
        // store read returns it.
        let stored = await FloeCADDocument.storedIdentity(at: url)
        XCTAssertEqual(stored?.modelSHA256, first.modelSHA256)
        document.close()
        XCTAssertTrue(siblingDebris().isEmpty, "debris: \(siblingDebris())")
    }

    /// The workbench's REAL close/fullscreen-return flush — provider records
    /// the viewport thumbnail, the same session saves — is a PREVIEW-only
    /// commit: the artifact lands and the revision advances; the legacy
    /// `contentSHA256` keeps its existing preview-inclusive semantics while
    /// the semantic model identity the creation recorded stays EXACT, so an
    /// untouched new model survives any number of fullscreen round trips
    /// while a real edit still moves the model identity.
    func testPreviewFlushKeepsModelIdentityAndRealEditMovesIt() async throws {
        let url = workDir.appendingPathComponent("Preview.floecad")
        let document = try await FloeCADDocument.create(at: url, name: "Preview")
        let created = await document.save()
        XCTAssertTrue(created.succeeded, created.error ?? "")
        let creationContent = created.contentSHA256
        let creationModel = created.modelSHA256
        XCTAssertFalse(creationModel.isEmpty)

        let png = try previewPNGBytes()
        let model = document.viewModel()
        model.thumbnailProvider = { png }
        model.saveThumbnail()
        let preview = await document.save()
        XCTAssertTrue(preview.succeeded, preview.error ?? "")
        XCTAssertGreaterThan(preview.revision, created.revision)
        XCTAssertEqual(preview.modelSHA256, creationModel,
                       "a preview-only commit must not move the model identity")
        XCTAssertNotEqual(preview.contentSHA256, creationContent,
                          "the legacy content identity keeps its preview-inclusive semantics")
        XCTAssertEqual(try Data(contentsOf: url.appendingPathComponent("blobs/thumbnail.img")), png)

        // The creation's model identity is still re-verifiable from disk.
        let stored = await FloeCADDocument.storedIdentity(at: url)
        XCTAssertEqual(stored?.modelSHA256, creationModel)

        // A real edit moves the model identity.
        addBox(document, size: 8)
        let edited = await document.save()
        XCTAssertTrue(edited.succeeded, edited.error ?? "")
        XCTAssertNotEqual(edited.modelSHA256, creationModel,
                          "a real body edit must move the model identity")
        document.close()
        XCTAssertTrue(siblingDebris().isEmpty, "debris: \(siblingDebris())")
    }

    /// The model identity covers the USER-EDITABLE manifest metadata: a
    /// rename, a unit change or a tolerance change is semantic content, not a
    /// preview, and must move the digest — otherwise a metadata-only edit
    /// could be classified as a preview-only commit and discarded.
    func testModelIdentityCoversUserEditableMetadata() async throws {
        let url = workDir.appendingPathComponent("Metadata.floecad")
        let document = try await FloeCADDocument.create(at: url, name: "Metadata")
        let base = await document.save()
        XCTAssertTrue(base.succeeded, base.error ?? "")

        document.project.unitRaw = "in"
        let unit = await document.save()
        XCTAssertTrue(unit.succeeded, unit.error ?? "")
        XCTAssertNotEqual(unit.modelSHA256, base.modelSHA256, "a unit change is an edit")

        document.project.name = "Renamed"
        let name = await document.save()
        XCTAssertTrue(name.succeeded, name.error ?? "")
        XCTAssertNotEqual(name.modelSHA256, unit.modelSHA256, "a rename is an edit")

        document.project.tolerance = 0.05
        let tolerance = await document.save()
        XCTAssertTrue(tolerance.succeeded, tolerance.error ?? "")
        XCTAssertNotEqual(tolerance.modelSHA256, name.modelSHA256,
                          "a tolerance change is an edit")

        // A preview-only commit still keeps the CURRENT (edited) identity.
        let png = try previewPNGBytes()
        let model = document.viewModel()
        model.thumbnailProvider = { png }
        model.saveThumbnail()
        let preview = await document.save()
        XCTAssertTrue(preview.succeeded, preview.error ?? "")
        XCTAssertEqual(preview.modelSHA256, tolerance.modelSHA256,
                       "a preview refresh must not look like another edit")
        document.close()
        XCTAssertTrue(siblingDebris().isEmpty, "debris: \(siblingDebris())")
    }

    /// A store that read an older revision must NOT overwrite a foreign
    /// commit: the on-disk revision is part of the commit fence, so a
    /// concurrent edit is preserved and surfaced as a save failure instead of
    /// being silently clobbered (T7T cancellation-boundary review).
    func testForeignCommitIsPreservedNotOverwrittenByStaleStore() async throws {
        let url = workDir.appendingPathComponent("Concurrent.floecad")
        let stale = try await FloeCADDocument.create(at: url, name: "Concurrent")
        addBox(stale, size: 4)
        let first = await stale.save()
        XCTAssertTrue(first.succeeded, first.error ?? "")

        // A second live instance reads the same package and commits.
        let foreign = try await FloeCADDocument.open(at: url)
        addBox(foreign, size: 7)
        let foreignSave = await foreign.save()
        XCTAssertTrue(foreignSave.succeeded, foreignSave.error ?? "")

        // The stale session must refuse, not clobber the foreign revision.
        addBox(stale, size: 2)
        let staleSave = await stale.save()
        XCTAssertFalse(staleSave.succeeded,
                       "a stale store must not commit over a foreign revision")
        let stored = await FloeCADDocument.storedIdentity(at: url)
        XCTAssertEqual(stored?.revision, foreignSave.revision,
                       "the foreign commit must still be the committed revision")
        XCTAssertEqual(stored?.contentSHA256, foreignSave.contentSHA256,
                       "the foreign content must be untouched")
        stale.close()
        foreign.close()
        XCTAssertTrue(siblingDebris().isEmpty, "debris: \(siblingDebris())")
    }

    /// The in-process package gate serializes every supported writer with the
    /// cancellation route's verify→delete critical section: a commit started
    /// while the gate is held cannot land until it is released.
    func testPackageGateSerializesSupportedWriters() async throws {
        let url = workDir.appendingPathComponent("Gate.floecad")
        let document = try await FloeCADDocument.create(at: url, name: "Gate")
        addBox(document, size: 4)
        let first = await document.save()
        XCTAssertTrue(first.succeeded, first.error ?? "")

        // Hold the gate exactly like the cancellation critical section does.
        CADPackageGate.acquire(url)
        let completed = DispatchSemaphore(value: 0)
        let writer = Task { () -> CADSaveOutcome in
            let outcome = await document.save()
            completed.signal()
            return outcome
        }
        // Give the writer time to reach the store; it must not pass the gate.
        try await Task.sleep(for: .milliseconds(400))
        XCTAssertEqual(completed.wait(timeout: .now()), .timedOut,
                       "a gated save must not commit while the gate is held")

        CADPackageGate.release(url)
        let outcome = await writer.value
        XCTAssertTrue(outcome.succeeded, outcome.error ?? "")
        XCTAssertGreaterThan(outcome.revision, first.revision)
        document.close()
        XCTAssertTrue(siblingDebris().isEmpty, "debris: \(siblingDebris())")
    }

    /// A released document must never write again: after the Cancel path
    /// deleted the package, the editor's late `onDisappear` flush is a no-op
    /// instead of re-creating the package from the still-cached session.
    /// `saveViewportPreview` must also refuse BEFORE mutating the session.
    func testClosedDocumentSaveDoesNotRecreateThePackage() async throws {
        let url = workDir.appendingPathComponent("Closed.floecad")
        let document = try await FloeCADDocument.create(at: url, name: "Closed")
        let saved = await document.save()
        XCTAssertTrue(saved.succeeded, saved.error ?? "")
        let png = try previewPNGBytes()
        document.close()

        // The exact post-Cancel state: released session, package removed.
        try FileManager.default.removeItem(at: url)
        let late = await document.save()
        XCTAssertFalse(late.succeeded, "a closed document must never save")
        XCTAssertNotNil(late.error)
        let latePreview = await document.saveViewportPreview(png)
        XCTAssertFalse(latePreview.succeeded,
                       "a closed document must reject a preview flush")
        XCTAssertNil(document.session.project.thumbnail,
                     "the rejected flush must not even mutate the session preview")
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path),
                       "a late flush must not resurrect a deleted package")
    }

    /// A save ALREADY IN FLIGHT when `close()`/delete happens must be fenced:
    /// `close()` waits out the writer and revokes the store under the same
    /// lock, so no late write can land after the package was removed.
    func testSaveInFlightIsFencedByCloseAndCannotResurrectThePackage() async throws {
        let url = workDir.appendingPathComponent("Inflight.floecad")
        let document = try await FloeCADDocument.create(at: url, name: "InFlight")
        addBox(document, size: 5)

        // Park the writer INSIDE the commit (holding the store lock). The
        // expectation suspends the test, so the main actor stays free for the
        // save task; only the writer's own thread blocks on the gate.
        let entered = expectation(description: "writer in flight")
        let gate = DispatchSemaphore(value: 0)
        CADDocumentFaultInjection.beforeCommit = {
            entered.fulfill()
            gate.wait()
        }
        let saveTask = Task { await document.save() }
        await fulfillment(of: [entered], timeout: 5)

        // Close while the write is parked. `revoke()` shares the commit lock,
        // so it waits the writer out; release the gate from a background
        // thread (the main actor is inside `close()`).
        let closeTask = Task { document.close() }
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.3) { gate.signal() }
        await closeTask.value
        try FileManager.default.removeItem(at: url)
        _ = await saveTask.value
        CADDocumentFaultInjection.beforeCommit = nil

        // No later write may resurrect the removed package.
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path),
                       "the fenced store must not re-create a removed package")
        let after = await document.save()
        XCTAssertFalse(after.succeeded, "the revoked store must refuse later writes")
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    // MARK: Revision guard

    func testStalePayloadIsRefusedByRevisionGuard() async throws {
        let url = workDir.appendingPathComponent("part.floecad")
        let document = try await FloeCADDocument.create(at: url, name: "Guard")
        addBox(document, size: 10)
        let store = document.store

        // Build a payload at the current revision, then commit something else.
        let stale = try store.makePayload(document.project)
        addBox(document, size: 3)
        let fresh = await document.save()
        XCTAssertTrue(fresh.succeeded, fresh.error ?? "")

        XCTAssertThrowsError(try store.performWrite(stale)) { error in
            guard case CADDocumentStoreError.revisionMoved = error else {
                return XCTFail("expected revisionMoved, got \(error)")
            }
        }
        document.close()
    }
}
