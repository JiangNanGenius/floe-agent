// SPDX-License-Identifier: MPL-2.0
//
// Deterministic lifecycle tests for the progressive two-tier Office cover.
//
// They drive the production `NotesDocumentCoverService` through its per-call
// Quick Look seam (never a process-global mock, never a simulator Quick Look
// request) and assert:
//  * a modern OOXML package publishes a real native content summary as the
//    first paint before the bounded Quick Look request settles, and upgrades
//    to the system content only when that request settles with content;
//  * a second card for the same resource joins the shared service flight and
//    receives the same staged summary image (one read, one Quick Look request);
//  * a failed, icon-only or timed-out Quick Look request keeps the summary as
//    the settled cover, is never retried after a timeout and never publishes
//    an icon;
//  * a cancelled waiter is never delivered a later first paint, and a
//    superseded flight cannot write into a newer flight for the same key
//    (the revision/cancellation no-overwrite guarantee);
//  * a real revision change keys a new flight, its first paint and final cover
//    stay its own, and the old flight's late completion cannot replace them;
//  * a legacy format never publishes a first paint and keeps the original
//    Quick Look-first path;
//  * the two-phase bounds are real and observable, not comment numbers: the
//    summary gate admits two summary copies at most, no summary copy is staged
//    before a slot is held, the summary copy and its parsed snapshot are gone
//    before the Quick Look wait, exactly one Quick Look copy exists at a time,
//    the summary gate is not held across a suspended system request (a third
//    card's first paint does not wait out another card's 45 s budget), the
//    over-cap non-coalesced fallback is bounded by the same gates, and
//    cancellation converges without leaking a slot, a waiter or a copy;
//  * the summary source-byte and field limits stay at 48 MiB / 240 fields.
import XCTest
import UIKit
import FloeNotes
import FloeDocuments
@testable import FloeNotesNativeQualification

@MainActor
final class NotesProgressiveCoverTests: XCTestCase {
    private let coverSize = CGSize(width: 320, height: 420)
    private let maximumSourceBytes = 128 * 1024 * 1024

    // MARK: - First paint and upgrade ordering

    /// The summary must be published while the system request is still in
    /// flight, and the settled outcome must be the system content. The seam
    /// holds the Quick Look request; the ordered event log makes an
    /// after-the-fact summary fail instead of silently passing.
    func testFirstPaintSummaryArrivesBeforeQuickLookAndUpgradesOnSuccess() async throws {
        let root = makeScratchDirectory("upgrade")
        defer { try? FileManager.default.removeItem(at: root) }
        let (store, document, sourceURL) = try await makeOfficeDocument(root: root, name: "progressive.docx")

        var paints: [NotesDocumentCoverOutcome] = []
        var events: [String] = []
        var calls = 0
        var release: CheckedContinuation<Void, Never>?
        var stagedURL: URL?
        let started = expectation(description: "quick look request in flight")
        let qlImage = makeImage(.systemRed)
        let seam: @MainActor (URL, CGSize, Duration) async -> NotesOfficeThumbnailGenerator.AttemptOutcome = { staged, _, _ in
            calls += 1
            stagedURL = staged
            events.append("qlStarted")
            started.fulfill()
            await withCheckedContinuation { release = $0 }
            events.append("qlReturned")
            return NotesOfficeThumbnailGenerator.AttemptOutcome(
                image: qlImage, diagnosis: "content", timedOut: false, elapsed: .zero)
        }
        let task = Task { @MainActor in
            await NotesDocumentCoverService.render(
                document: document, store: store, size: self.coverSize,
                maximumSourceBytes: self.maximumSourceBytes, request: seam,
                onFirstPaint: { paints.append($0) })
        }
        // A failed assertion must not leave the render suspended at the seam
        // (which would also leak the shared flight into later tests).
        defer {
            if let pending = release { release = nil; pending.resume() }
            task.cancel()
        }
        await fulfillment(of: [started], timeout: 10)

        // The summary first paint must already be here, before the system
        // request settles (the seam is still suspended).
        XCTAssertEqual(paints.count, 1, "exactly one provisional summary first paint")
        let paint = try XCTUnwrap(paints.first)
        XCTAssertEqual(paint.source, .officeContentSummary)
        XCTAssertNil(paint.diagnostics, "a provisional paint is not a settled Quick Look diagnosis")
        let paintImage = try XCTUnwrap(paint.image)
        XCTAssertFalse(events.contains("qlReturned"), "the seam must still be suspended")
        XCTAssertEqual(events, ["qlStarted"])

        // The first paint is the fixture's own text, rendered at the cover
        // size with the known paragraph layout.
        let snapshot = try OfficeDocumentService.inspect(url: sourceURL)
        XCTAssertEqual(snapshot.fields.first?.text, "渐进封面")
        NotesCoverAcceptanceSupport.assertSummaryGeometry(paintImage, snapshot: snapshot,
                                                          fileName: "progressive.docx")

        release?.resume()
        release = nil
        let final = await task.value
        XCTAssertEqual(final.source, .quickLookThumbnail)
        XCTAssertTrue(final.image === qlImage,
                      "the settled cover must be the system content, not the summary")
        XCTAssertEqual(calls, 1, "one bounded Quick Look request for the shared resource")
        let diagnostics = try XCTUnwrap(final.diagnostics)
        XCTAssertEqual(diagnostics.quickLookAttempts, 1)
        XCTAssertFalse(diagnostics.quickLookWasIconFallback)
        if let stagedURL {
            XCTAssertFalse(FileManager.default.fileExists(atPath: stagedURL.path),
                           "the staged copy must be removed after the render settles")
        }
    }

    /// Two cards for the same resource share one service flight: the second
    /// receives the exact same first-paint image (no second read/render) and no
    /// independent Quick Look request is started.
    func testDuplicateCardsShareOneProgressiveFlightAndFirstPaint() async throws {
        let root = makeScratchDirectory("coalesce")
        defer { try? FileManager.default.removeItem(at: root) }
        let (store, document, _) = try await makeOfficeDocument(root: root, name: "shared.docx")

        var firstPaints: [NotesDocumentCoverOutcome] = []
        var secondPaints: [NotesDocumentCoverOutcome] = []
        var calls = 0
        var release: CheckedContinuation<Void, Never>?
        let started = expectation(description: "quick look request in flight")
        let qlImage = makeImage(.systemBlue)
        let seam: @MainActor (URL, CGSize, Duration) async -> NotesOfficeThumbnailGenerator.AttemptOutcome = { _, _, _ in
            calls += 1
            started.fulfill()
            await withCheckedContinuation { release = $0 }
            return NotesOfficeThumbnailGenerator.AttemptOutcome(
                image: qlImage, diagnosis: "content", timedOut: false, elapsed: .zero)
        }
        let first = Task { @MainActor in
            await NotesDocumentCoverService.render(
                document: document, store: store, size: self.coverSize,
                maximumSourceBytes: self.maximumSourceBytes, request: seam,
                onFirstPaint: { firstPaints.append($0) })
        }
        // A failed unwrap before the second card joins must not leave the
        // shared flight suspended at the seam.
        defer {
            if let pending = release { release = nil; pending.resume() }
            first.cancel()
        }
        await fulfillment(of: [started], timeout: 10)
        let sharedPaint = try XCTUnwrap(firstPaints.first)
        let sharedImage = try XCTUnwrap(sharedPaint.image)

        let second = Task { @MainActor in
            await NotesDocumentCoverService.render(
                document: document, store: store, size: self.coverSize,
                maximumSourceBytes: self.maximumSourceBytes, request: seam,
                onFirstPaint: { secondPaints.append($0) })
        }
        defer { second.cancel() }
        let joinDeadline = ContinuousClock.now + .seconds(5)
        while secondPaints.isEmpty, ContinuousClock.now < joinDeadline { await Task.yield() }

        XCTAssertEqual(secondPaints.count, 1, "the joining card must receive the stored first paint")
        XCTAssertTrue(secondPaints.first?.image === sharedImage,
                      "the joining card must share the same summary image, not re-read or re-render")
        XCTAssertEqual(calls, 1, "the joining card must not start an independent Quick Look request")

        release?.resume()
        release = nil
        let firstFinal = await first.value
        let secondFinal = await second.value
        XCTAssertEqual(calls, 1)
        XCTAssertTrue(firstFinal.image === qlImage)
        XCTAssertTrue(secondFinal.image === qlImage)
        XCTAssertEqual(secondFinal.source, .quickLookThumbnail)
    }

    // MARK: - Failure keeps the summary

    /// A timed-out request is terminal (the host may still hold it), so it is
    /// never restarted, and the already-rendered summary remains the cover.
    func testTimedOutQuickLookDoesNotRetryAndKeepsTheSummary() async throws {
        let root = makeScratchDirectory("timeout")
        defer { try? FileManager.default.removeItem(at: root) }
        let (store, document, _) = try await makeOfficeDocument(root: root, name: "timeout.docx")

        var paints: [NotesDocumentCoverOutcome] = []
        var calls = 0
        let seam: @MainActor (URL, CGSize, Duration) async -> NotesOfficeThumbnailGenerator.AttemptOutcome = { _, _, _ in
            calls += 1
            return NotesOfficeThumbnailGenerator.AttemptOutcome(
                image: nil, diagnosis: "request deadline", timedOut: true, elapsed: .zero)
        }
        let outcome = await NotesDocumentCoverService.render(
            document: document, store: store, size: coverSize,
            maximumSourceBytes: maximumSourceBytes, request: seam,
            onFirstPaint: { paints.append($0) })
        XCTAssertEqual(calls, 1, "a timed-out request must not be restarted")
        XCTAssertEqual(outcome.source, .officeContentSummary)
        let paint = try XCTUnwrap(paints.first)
        XCTAssertTrue(outcome.image === paint.image,
                      "the settled cover must be the first-paint summary, not a re-render")
        let diagnostics = try XCTUnwrap(outcome.diagnostics)
        XCTAssertTrue(diagnostics.quickLookTimedOut)
        XCTAssertEqual(diagnostics.quickLookAttempts, 1)
        XCTAssertFalse(diagnostics.quickLookWasIconFallback)
    }

    /// An icon-only representation is terminal and never becomes the cover: the
    /// card keeps its labeled summary instead of a generic file glyph.
    func testIconOnlyQuickLookKeepsTheSummaryAndNeverPublishesTheIcon() async throws {
        let root = makeScratchDirectory("icon")
        defer { try? FileManager.default.removeItem(at: root) }
        let (store, document, sourceURL) = try await makeOfficeDocument(root: root, name: "icon.docx")

        var paints: [NotesDocumentCoverOutcome] = []
        let seam: @MainActor (URL, CGSize, Duration) async -> NotesOfficeThumbnailGenerator.AttemptOutcome = { _, _, _ in
            NotesOfficeThumbnailGenerator.AttemptOutcome(
                image: self.makeImage(.systemGray), diagnosis: "generic icon representation",
                timedOut: false, elapsed: .zero, isIconFallback: true)
        }
        let outcome = await NotesDocumentCoverService.render(
            document: document, store: store, size: coverSize,
            maximumSourceBytes: maximumSourceBytes, request: seam,
            onFirstPaint: { paints.append($0) })
        XCTAssertEqual(outcome.source, .officeContentSummary)
        XCTAssertTrue(outcome.image === paints.first?.image)
        let diagnostics = try XCTUnwrap(outcome.diagnostics)
        XCTAssertTrue(diagnostics.quickLookWasIconFallback)
        XCTAssertEqual(diagnostics.quickLookAttempts, 1)
        // The kept cover is the fixture's real content summary, not the 8x8
        // generic icon the seam returned: prove it against the known authored
        // content and the renderer's documented layout. This pairs the recorded
        // icon failure with an independently verified summary cover; the
        // component functional test allows icon=true only for summary sources.
        let keptImage = try XCTUnwrap(outcome.image)
        let snapshot = try OfficeDocumentService.inspect(url: sourceURL)
        XCTAssertEqual(snapshot.fields.first?.text, "渐进封面")
        NotesCoverAcceptanceSupport.assertSummaryGeometry(keptImage, snapshot: snapshot,
                                                          fileName: "icon.docx")
    }

    /// A settled non-timeout failure follows the unchanged bounded retry policy
    /// and then keeps the summary as the cover, with the numeric error identity
    /// preserved in the redacted diagnostics.
    func testSettledQuickLookFailureRetainsTheFirstPaintSummary() async throws {
        let root = makeScratchDirectory("failure")
        defer { try? FileManager.default.removeItem(at: root) }
        let (store, document, _) = try await makeOfficeDocument(root: root, name: "failure.docx")

        var paints: [NotesDocumentCoverOutcome] = []
        var calls = 0
        let seam: @MainActor (URL, CGSize, Duration) async -> NotesOfficeThumbnailGenerator.AttemptOutcome = { _, _, _ in
            calls += 1
            return NotesOfficeThumbnailGenerator.AttemptOutcome(
                image: nil, diagnosis: "injected failure", timedOut: false, elapsed: .zero,
                errorDomain: "QLThumbnailErrorDomain", errorCode: 102)
        }
        let outcome = await NotesDocumentCoverService.render(
            document: document, store: store, size: coverSize,
            maximumSourceBytes: maximumSourceBytes, request: seam,
            onFirstPaint: { paints.append($0) })
        XCTAssertEqual(calls, 3, "a settled failure retries up to the unchanged attempt bound")
        XCTAssertEqual(outcome.source, .officeContentSummary)
        XCTAssertTrue(outcome.image === paints.first?.image)
        let diagnostics = try XCTUnwrap(outcome.diagnostics)
        XCTAssertEqual(diagnostics.quickLookAttempts, 3)
        XCTAssertFalse(diagnostics.quickLookTimedOut)
        XCTAssertEqual(diagnostics.quickLookErrorDomain, "QLThumbnailErrorDomain")
        XCTAssertEqual(diagnostics.quickLookErrorCode, 102)
        XCTAssertEqual(diagnostics.fallbackStage, .quickLook,
                       "the summary succeeded after the system stage failed")
    }

    /// A phase-2 staging failure after the summary first paint must not clear
    /// the card. The CAS resource is deleted from inside the first-paint
    /// callback, so the summary copy succeeded but the fresh Quick Look copy
    /// cannot be staged. The settled cover must keep the exact first-paint
    /// summary object with `fallbackStage == .staging`, and the generator must
    /// never run. A removed-resource error is not a cancellation and must not
    /// take the cancel path.
    func testPhase2StagingFailureKeepsTheSummaryWithoutRunningQuickLook() async throws {
        let root = makeScratchDirectory("phase2-staging")
        defer { try? FileManager.default.removeItem(at: root) }
        let (store, document, _) = try await makeOfficeDocument(root: root, name: "staging.docx")
        let resourceID = try XCTUnwrap(document.officeResourceID)
        // Record the CAS path the service stages from, then delete it after the
        // summary first paint. Restoring is unnecessary: the whole fixture root
        // is removed by the defer above.
        let resource = try await store.resourceURL(resourceID)

        var paints: [NotesDocumentCoverOutcome] = []
        var calls = 0
        let seam: @MainActor (URL, CGSize, Duration) async -> NotesOfficeThumbnailGenerator.AttemptOutcome = { _, _, _ in
            calls += 1
            return NotesOfficeThumbnailGenerator.AttemptOutcome(
                image: self.makeImage(.systemRed), diagnosis: "content", timedOut: false, elapsed: .zero)
        }
        let outcome = await NotesDocumentCoverService.render(
            document: document, store: store, size: coverSize,
            maximumSourceBytes: maximumSourceBytes, request: seam,
            onFirstPaint: { paint in
                paints.append(paint)
                // Phase 2 stages its own copy from this exact CAS resource.
                try? FileManager.default.removeItem(at: resource)
            })

        XCTAssertEqual(paints.count, 1, "the summary first paint must have been published")
        let paint = try XCTUnwrap(paints.first)
        let paintImage = try XCTUnwrap(paint.image)
        XCTAssertFalse(FileManager.default.fileExists(atPath: resource.path),
                       "precondition: the CAS resource was removed after the first paint")
        XCTAssertEqual(calls, 0,
                       "a failed phase-2 staging must never run the Quick Look request")
        XCTAssertEqual(outcome.source, .officeContentSummary,
                       "the settled cover must keep the already-rendered summary, got \(outcome.source) (\(outcome.diagnosis))")
        XCTAssertTrue(outcome.image === paintImage,
                      "the settled summary must be the same object as the first paint, not a re-render")
        let diagnostics = try XCTUnwrap(outcome.diagnostics)
        XCTAssertEqual(diagnostics.fallbackStage, .staging,
                       "the staging failure must be recorded without replacing the summary")
        XCTAssertEqual(diagnostics.quickLookAttempts, 0,
                       "no generator attempt may be recorded when staging failed")
        XCTAssertFalse(diagnostics.quickLookWasIconFallback)
    }

    // MARK: - Cancel and supersession cannot overwrite

    /// A waiter that cancels before the shared operation publishes its first
    /// paint must never receive it afterwards.
    func testCancelledWaiterIsNeverDeliveredALaterFirstPaint() async {
        let key = "progressive-cancel-\(UUID().uuidString)"
        var delivered = false
        var release: CheckedContinuation<Void, Never>?
        let started = expectation(description: "shared operation started")
        let task = Task { @MainActor in
            await NotesOfficeCoverFlights.shared.outcome(key: key, onFirstPaint: { _ in delivered = true }) { emit in
                started.fulfill()
                await withCheckedContinuation { release = $0 }
                emit(.init(image: self.makeImage(.systemTeal), source: .officeContentSummary,
                           diagnosis: "first paint"))
                return .init(image: nil, source: .none, diagnosis: "final")
            }
        }
        defer {
            if let pending = release { release = nil; pending.resume() }
            task.cancel()
        }
        await fulfillment(of: [started], timeout: 10)
        task.cancel()
        let leaveDeadline = ContinuousClock.now + .seconds(5)
        while NotesOfficeCoverFlights.shared.waiterCount(forKey: key) > 0,
              ContinuousClock.now < leaveDeadline {
            await Task.yield()
        }
        XCTAssertEqual(NotesOfficeCoverFlights.shared.waiterCount(forKey: key), 0,
                       "the cancelled waiter must leave the flight")
        release?.resume()
        release = nil
        _ = await task.value
        XCTAssertFalse(delivered, "a cancelled waiter must not receive a later first paint")
    }

    /// A superseded operation whose task outlives its registry entry must not
    /// publish into a newer flight for the same key. This is the deterministic
    /// no-overwrite guarantee behind revision/cancellation handling.
    func testSupersededFlightCannotPublishIntoANewerFlightForKey() async {
        let key = "progressive-replace-\(UUID().uuidString)"
        let oldImage = makeImage(.systemOrange)
        let newImage = makeImage(.systemGreen)

        var releaseOld: CheckedContinuation<Void, Never>?
        var releaseNew: CheckedContinuation<Void, Never>?
        let oldStarted = expectation(description: "old flight started")
        let old = Task { @MainActor in
            await NotesOfficeCoverFlights.shared.outcome(key: key, onFirstPaint: { _ in }) { emit in
                oldStarted.fulfill()
                await withCheckedContinuation { releaseOld = $0 }
                emit(.init(image: oldImage, source: .officeContentSummary, diagnosis: "old first paint"))
                return .init(image: oldImage, source: .officeContentSummary, diagnosis: "old final")
            }
        }
        defer {
            if let pending = releaseOld { releaseOld = nil; pending.resume() }
            old.cancel()
        }
        await fulfillment(of: [oldStarted], timeout: 10)
        old.cancel()
        let leaveDeadline = ContinuousClock.now + .seconds(5)
        while NotesOfficeCoverFlights.shared.waiterCount(forKey: key) > 0,
              ContinuousClock.now < leaveDeadline {
            await Task.yield()
        }
        XCTAssertEqual(NotesOfficeCoverFlights.shared.waiterCount(forKey: key), 0)

        var newPaints: [NotesDocumentCoverOutcome] = []
        let newStarted = expectation(description: "new flight started")
        let replacement = Task { @MainActor in
            await NotesOfficeCoverFlights.shared.outcome(key: key, onFirstPaint: { newPaints.append($0) }) { emit in
                newStarted.fulfill()
                await withCheckedContinuation { releaseNew = $0 }
                emit(.init(image: newImage, source: .officeContentSummary, diagnosis: "new first paint"))
                return .init(image: newImage, source: .quickLookThumbnail, diagnosis: "new final")
            }
        }
        defer {
            if let pending = releaseNew { releaseNew = nil; pending.resume() }
            replacement.cancel()
        }
        await fulfillment(of: [newStarted], timeout: 10)

        // The old operation completes after its entry was replaced. Its first
        // paint must not surface on the newer flight.
        releaseOld?.resume()
        releaseOld = nil
        _ = await old.value
        for _ in 0..<10 { await Task.yield() }
        XCTAssertTrue(newPaints.isEmpty,
                      "a superseded flight must not deliver into a newer flight for the same key")

        releaseNew?.resume()
        releaseNew = nil
        let replacementOutcome = await replacement.value
        XCTAssertEqual(newPaints.count, 1)
        XCTAssertTrue(newPaints.first?.image === newImage)
        XCTAssertTrue(replacementOutcome.image === newImage)
        XCTAssertEqual(replacementOutcome.source, .quickLookThumbnail)
    }

    /// A real revision change keys a distinct flight. The new revision's first
    /// paint and settled cover stay its own even when the previous revision's
    /// Quick Look request completes later.
    func testRevisionChangeKeepsItsOwnFirstPaintAndFinalCover() async throws {
        let root = makeScratchDirectory("revision")
        defer { try? FileManager.default.removeItem(at: root) }
        let (store, document, _) = try await makeOfficeDocument(root: root, name: "revision.docx")

        var oldPaints: [NotesDocumentCoverOutcome] = []
        var releaseOld: CheckedContinuation<Void, Never>?
        let oldStarted = expectation(description: "old revision request in flight")
        let seamOld: @MainActor (URL, CGSize, Duration) async -> NotesOfficeThumbnailGenerator.AttemptOutcome = { _, _, _ in
            oldStarted.fulfill()
            await withCheckedContinuation { releaseOld = $0 }
            return NotesOfficeThumbnailGenerator.AttemptOutcome(
                image: self.makeImage(.systemRed), diagnosis: "old content",
                timedOut: false, elapsed: .zero)
        }
        let old = Task { @MainActor in
            await NotesDocumentCoverService.render(
                document: document, store: store, size: self.coverSize,
                maximumSourceBytes: self.maximumSourceBytes, request: seamOld,
                onFirstPaint: { oldPaints.append($0) })
        }
        defer {
            if let pending = releaseOld { releaseOld = nil; pending.resume() }
            old.cancel()
        }
        await fulfillment(of: [oldStarted], timeout: 10)

        let renamed = try await store.apply(.init(
            documentID: document.id, expectedRevision: document.revision,
            title: "重命名文档", edits: [.rename("重命名文档")]))
        XCTAssertGreaterThan(renamed.revision, document.revision)
        let oldKey = NotesDocumentCoverService.officeResourceKey(
            document: document, store: store, fileExtension: "docx",
            size: coverSize, maximumSourceBytes: maximumSourceBytes)
        let newKey = NotesDocumentCoverService.officeResourceKey(
            document: renamed, store: store, fileExtension: "docx",
            size: coverSize, maximumSourceBytes: maximumSourceBytes)
        XCTAssertNotEqual(oldKey, newKey, "a revision change must key a distinct flight")

        let newFinalImage = makeImage(.systemIndigo)
        var newPaints: [NotesDocumentCoverOutcome] = []
        let seamNew: @MainActor (URL, CGSize, Duration) async -> NotesOfficeThumbnailGenerator.AttemptOutcome = { _, _, _ in
            NotesOfficeThumbnailGenerator.AttemptOutcome(
                image: newFinalImage, diagnosis: "new content", timedOut: false, elapsed: .zero)
        }
        let new = Task { @MainActor in
            await NotesDocumentCoverService.render(
                document: renamed, store: store, size: self.coverSize,
                maximumSourceBytes: self.maximumSourceBytes, request: seamNew,
                onFirstPaint: { newPaints.append($0) })
        }
        defer { new.cancel() }

        // The new revision's first paint arrives while the old revision's
        // system request is still suspended and holding the shared host slot.
        let paintDeadline = ContinuousClock.now + .seconds(5)
        while newPaints.isEmpty, ContinuousClock.now < paintDeadline { await Task.yield() }
        XCTAssertEqual(newPaints.count, 1)
        XCTAssertEqual(newPaints.first?.source, .officeContentSummary)

        releaseOld?.resume()
        releaseOld = nil
        let oldOutcome = await old.value
        let newOutcome = await new.value
        XCTAssertEqual(oldOutcome.source, .quickLookThumbnail)
        XCTAssertEqual(newOutcome.source, .quickLookThumbnail)
        XCTAssertTrue(newOutcome.image === newFinalImage,
                      "the new revision's settled cover must be its own")
        XCTAssertEqual(newPaints.count, 1,
                       "the old revision's late completion must not re-deliver a first paint")
    }

    // MARK: - Legacy path and pinned bounds

    /// Legacy formats never publish a first paint: they keep the original
    /// Quick Look-first path and the explicit unsupported type stage.
    func testLegacyFormatNeverPublishesAFirstPaint() async throws {
        let root = makeScratchDirectory("legacy")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let source = root.appendingPathComponent("legacy.rtf")
        try "{\\rtf1\\ansi\\deff0 synthetic legacy document}".write(to: source, atomically: true, encoding: .utf8)
        let store = try NotesStore(root: root.appendingPathComponent("store"))
        let draft = try await NoteFileImporter.importFile(source, notebookID: nil, store: store)
        let document = try await store.create(draft)
        XCTAssertEqual(document.kind, .office)

        var paints: [NotesDocumentCoverOutcome] = []
        let seam: @MainActor (URL, CGSize, Duration) async -> NotesOfficeThumbnailGenerator.AttemptOutcome = { _, _, _ in
            NotesOfficeThumbnailGenerator.AttemptOutcome(
                image: nil, diagnosis: "injected quick look failure", timedOut: false, elapsed: .zero,
                errorDomain: "QLThumbnailErrorDomain", errorCode: 102)
        }
        let outcome = await NotesDocumentCoverService.render(
            document: document, store: store, size: coverSize,
            maximumSourceBytes: maximumSourceBytes, request: seam,
            onFirstPaint: { paints.append($0) })
        XCTAssertTrue(paints.isEmpty, "a legacy format has no native summary first paint")
        XCTAssertEqual(outcome.source, .unsupported)
        XCTAssertNil(outcome.image)
        XCTAssertEqual(outcome.diagnostics?.fallbackStage, .unsupportedType)
    }

    /// The progressive summary keeps the existing bounded-read policy.
    func testProgressiveSummaryLimitsAndTypeRoutingAreUnchanged() {
        XCTAssertEqual(NotesDocumentCoverService.maximumSummarySourceBytes, 48 * 1024 * 1024)
        XCTAssertEqual(NotesDocumentCoverService.maximumSummaryFields, 240)
        XCTAssertEqual(NotesDocumentCoverService.summaryDocumentKind(for: "docx"), .word)
        XCTAssertEqual(NotesDocumentCoverService.summaryDocumentKind(for: "xlsx"), .workbook)
        XCTAssertEqual(NotesDocumentCoverService.summaryDocumentKind(for: "pptx"), .presentation)
        for legacy in ["doc", "xls", "ppt", "odt", "ods", "odp", "rtf", ""] {
            XCTAssertNil(NotesDocumentCoverService.summaryDocumentKind(for: legacy),
                         "\(legacy) must keep the original Quick Look-first path")
        }
    }

    // MARK: - Real two-phase summary/Quick Look resource bounds

    /// The summary phase is gated *before* it stages anything, its copy and
    /// parsed snapshot are gone before the Quick Look wait, and only one Quick
    /// Look copy exists while the system request is outstanding. Three cards
    /// for three different resources are driven against a held two-slot
    /// summary gate and one suspended system request; the staged copies are
    /// counted on disk, not inferred from comments.
    func testSummaryGateBoundsCopiesAndReleasesBeforeTheQuickLookWait() async throws {
        let root = makeScratchDirectory("bounds")
        defer { try? FileManager.default.removeItem(at: root) }
        var documents: [(NotesStore, NoteDocument, URL)] = []
        for name in ["bounds-a", "bounds-b", "bounds-c"] {
            documents.append(try await makeOfficeDocument(
                root: root.appendingPathComponent(name), name: "\(name).docx"))
        }
        let baseline = stagedCoverDirectoryCount()

        // Two external holders keep both summary slots busy. Every release in
        // this test is accounted for so a failed assertion cannot leak a slot
        // into the shared gate.
        var heldSlots = 0
        func holdSummarySlot() async {
            let acquired = await NotesOfficeThumbnailGate.summary.acquire(id: UUID())
            XCTAssertTrue(acquired, "precondition: the summary gate must be free for the test")
            heldSlots += 1
        }
        defer {
            for _ in 0..<heldSlots { NotesOfficeThumbnailGate.summary.release() }
        }
        await holdSummarySlot()
        await holdSummarySlot()

        var paints: [NotesDocumentCoverOutcome] = []
        var calls = 0
        var release: CheckedContinuation<Void, Never>?
        var stagedURL: URL?
        let started = expectation(description: "one Quick Look request in flight")
        let qlImage = makeImage(.systemPurple)
        let seam: @MainActor (URL, CGSize, Duration) async -> NotesOfficeThumbnailGenerator.AttemptOutcome = { staged, _, _ in
            calls += 1
            stagedURL = staged
            if calls == 1 {
                started.fulfill()
                await withCheckedContinuation { release = $0 }
            }
            return NotesOfficeThumbnailGenerator.AttemptOutcome(
                image: qlImage, diagnosis: "content", timedOut: false, elapsed: .zero)
        }
        let tasks = documents.map { entry in
            Task { @MainActor in
                await NotesDocumentCoverService.render(
                    document: entry.1, store: entry.0, size: self.coverSize,
                    maximumSourceBytes: self.maximumSourceBytes, request: seam,
                    onFirstPaint: { paints.append($0) })
            }
        }
        // A failed assertion must not leave a render suspended at the seam or
        // a card stuck in the summary queue for the next test.
        defer {
            if let pending = release { release = nil; pending.resume() }
            for task in tasks { task.cancel() }
        }

        // Both slots are held: no summary may stage a copy, no first paint may
        // arrive and no system request may start, however many cards ask.
        let allQueued = await waitUntil {
            NotesOfficeThumbnailGate.summary.activeCount == 2 &&
            NotesOfficeThumbnailGate.summary.waiterCount == 3
        }
        XCTAssertTrue(allQueued, "three cards must be queued behind the two summary slots")
        XCTAssertTrue(paints.isEmpty, "no first paint may bypass the summary gate")
        XCTAssertEqual(stagedCoverDirectoryCount(), baseline,
                       "a gated summary must not stage a copy before it owns a slot")
        XCTAssertEqual(calls, 0, "no Quick Look request may start before a summary phase ran")

        // One slot released: exactly one card summarizes, deletes its copy,
        // emits its first paint and only then waits for Quick Look.
        heldSlots -= 1
        NotesOfficeThumbnailGate.summary.release()
        await fulfillment(of: [started], timeout: 15)
        XCTAssertEqual(paints.count, 1)
        XCTAssertEqual(paints.first?.source, .officeContentSummary)
        XCTAssertEqual(NotesOfficeThumbnailGate.summary.activeCount, 2,
                       "the released slot must immediately serve the next queued summary")
        XCTAssertEqual(NotesOfficeThumbnailGate.summary.waiterCount, 1)
        XCTAssertEqual(stagedCoverDirectoryCount(), baseline + 1,
                       "only the Quick Look copy may exist: the summary copy is deleted before the wait")
        if let stagedURL {
            XCTAssertTrue(FileManager.default.fileExists(atPath: stagedURL.path))
            XCTAssertEqual(stagedURL.lastPathComponent, "preview.docx")
        }

        // The remaining slots are released while the system request is still
        // suspended. Both cards must get first paints without waiting for it,
        // and once their summaries are done no summary copy may exist while
        // their Quick Look requests queue behind the one in flight.
        heldSlots -= 1
        NotesOfficeThumbnailGate.summary.release()
        let allPainted = await waitUntil { paints.count == 3 }
        XCTAssertTrue(allPainted,
                      "later cards' first paints must not wait for the suspended Quick Look request")
        XCTAssertEqual(NotesOfficeThumbnailGate.summary.activeCount, 0,
                       "no summary slot may be held across the Quick Look wait")
        XCTAssertEqual(stagedCoverDirectoryCount(), baseline + 1,
                       "queued Quick Look requests must not stage copies while the host slot is held")

        release?.resume()
        release = nil
        for task in tasks { _ = await task.value }
        XCTAssertEqual(calls, 3, "one bounded Quick Look request per resource")
        await assertEventually("every staged copy must be removed after the renders settle") {
            self.stagedCoverDirectoryCount() == baseline
        }
        XCTAssertEqual(NotesOfficeThumbnailGate.summary.activeCount, 0)
        XCTAssertEqual(NotesOfficeThumbnailGate.shared.activeCount, 0)
    }

    /// The two-slot summary gate must never be held across the Quick Look
    /// wait: with one system request suspended and a second card queued behind
    /// it, a third card's first paint must still arrive immediately. The build
    /// 186 regression was exactly this head-of-line wait (third first frame
    /// still blocked on the 45 s system budget).
    func testThirdCardsFirstPaintDoesNotWaitForTwoSuspendedQuickLookRequests() async throws {
        let root = makeScratchDirectory("no-head-of-line")
        defer { try? FileManager.default.removeItem(at: root) }
        let (storeA, documentA, _) = try await makeOfficeDocument(
            root: root.appendingPathComponent("a"), name: "first.docx")
        let (storeB, documentB, _) = try await makeOfficeDocument(
            root: root.appendingPathComponent("b"), name: "second.docx")
        let (storeC, documentC, _) = try await makeOfficeDocument(
            root: root.appendingPathComponent("c"), name: "third.docx")

        var calls = 0
        var release: CheckedContinuation<Void, Never>?
        let started = expectation(description: "first Quick Look request in flight")
        let seam: @MainActor (URL, CGSize, Duration) async -> NotesOfficeThumbnailGenerator.AttemptOutcome = { _, _, _ in
            calls += 1
            if calls == 1 {
                started.fulfill()
                await withCheckedContinuation { release = $0 }
            }
            return NotesOfficeThumbnailGenerator.AttemptOutcome(
                image: self.makeImage(.systemBlue), diagnosis: "content", timedOut: false, elapsed: .zero)
        }
        var paintsA: [NotesDocumentCoverOutcome] = []
        var paintsB: [NotesDocumentCoverOutcome] = []
        var paintsC: [NotesDocumentCoverOutcome] = []
        let first = Task { @MainActor in
            await NotesDocumentCoverService.render(
                document: documentA, store: storeA, size: self.coverSize,
                maximumSourceBytes: self.maximumSourceBytes, request: seam,
                onFirstPaint: { paintsA.append($0) })
        }
        await fulfillment(of: [started], timeout: 15)
        XCTAssertEqual(paintsA.count, 1)

        let second = Task { @MainActor in
            await NotesDocumentCoverService.render(
                document: documentB, store: storeB, size: self.coverSize,
                maximumSourceBytes: self.maximumSourceBytes, request: seam,
                onFirstPaint: { paintsB.append($0) })
        }
        await assertEventually("the second card's first paint must not wait for the first card's system request") {
            paintsB.count == 1
        }
        XCTAssertEqual(NotesOfficeThumbnailGate.summary.activeCount, 0,
                       "the second card must release its summary slot before queueing for Quick Look")

        let third = Task { @MainActor in
            await NotesDocumentCoverService.render(
                document: documentC, store: storeC, size: self.coverSize,
                maximumSourceBytes: self.maximumSourceBytes, request: seam,
                onFirstPaint: { paintsC.append($0) })
        }
        defer {
            if let pending = release { release = nil; pending.resume() }
            first.cancel()
            second.cancel()
            third.cancel()
        }
        await assertEventually("the third card's first paint must not wait out two suspended Quick Look requests") {
            paintsC.count == 1
        }
        XCTAssertNotNil(release, "the first system request must still be suspended")
        XCTAssertEqual(calls, 1, "only the first card's system request may have started")
        XCTAssertEqual(NotesOfficeThumbnailGate.summary.activeCount, 0)

        release?.resume()
        release = nil
        _ = await first.value
        _ = await second.value
        _ = await third.value
        XCTAssertEqual(calls, 3)
        XCTAssertEqual(paintsA.count, 1)
        XCTAssertEqual(paintsB.count, 1)
        XCTAssertEqual(paintsC.count, 1)
    }

    /// Multiple cards for one resource converge on one shared operation: one
    /// summary phase, one first-paint image, one Quick Look request. Cancelling
    /// waiters never cancels work another waiter still needs; when the last
    /// waiter cancels, both gates and every staged copy converge back to zero
    /// and a new flight for the same key starts cleanly.
    func testMultiWaiterCancellationConvergesGatesAndCopies() async throws {
        let root = makeScratchDirectory("multi-waiter")
        defer { try? FileManager.default.removeItem(at: root) }
        let (store, document, _) = try await makeOfficeDocument(
            root: root.appendingPathComponent("doc"), name: "shared.docx")
        let key = NotesDocumentCoverService.officeResourceKey(
            document: document, store: store, fileExtension: "docx",
            size: coverSize, maximumSourceBytes: maximumSourceBytes)
        let baseline = stagedCoverDirectoryCount()

        var calls = 0
        var release: CheckedContinuation<Void, Never>?
        var stagedURL: URL?
        var paintCounts = [0, 0, 0]
        var firstPaintImage: UIImage?
        let started = expectation(description: "shared Quick Look request in flight")
        let seam: @MainActor (URL, CGSize, Duration) async -> NotesOfficeThumbnailGenerator.AttemptOutcome = { staged, _, _ in
            calls += 1
            stagedURL = staged
            started.fulfill()
            await withCheckedContinuation { release = $0 }
            return NotesOfficeThumbnailGenerator.AttemptOutcome(
                image: self.makeImage(.systemBlue), diagnosis: "content", timedOut: false, elapsed: .zero)
        }
        let tasks = (0..<3).map { index in
            Task { @MainActor in
                await NotesDocumentCoverService.render(
                    document: document, store: store, size: self.coverSize,
                    maximumSourceBytes: self.maximumSourceBytes, request: seam,
                    onFirstPaint: { paint in
                        paintCounts[index] += 1
                        if firstPaintImage == nil { firstPaintImage = paint.image }
                    })
            }
        }
        defer {
            if let pending = release { release = nil; pending.resume() }
            for task in tasks { task.cancel() }
        }
        await fulfillment(of: [started], timeout: 15)
        await assertEventually("all three cards must join the one shared flight") {
            NotesOfficeCoverFlights.shared.waiterCount(forKey: key) == 3
        }
        await assertEventually("every joined waiter must receive the shared first paint") {
            paintCounts == [1, 1, 1]
        }
        XCTAssertEqual(calls, 1, "the shared operation must issue exactly one system request")
        XCTAssertNotNil(firstPaintImage)

        // Two waiters cancel; the shared operation must survive for the last
        // one and keep its staged copy.
        tasks[0].cancel()
        tasks[1].cancel()
        try? await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(calls, 1, "cancelling waiters must not restart the shared request")
        if let stagedURL {
            let stagedExists = FileManager.default.fileExists(atPath: stagedURL.path)
            XCTAssertTrue(stagedExists,
                          "the shared staged copy must survive until the last waiter leaves")
        }

        // The last waiter cancels: the shared task is cancelled and both gates
        // and the staged copy must converge back to zero.
        tasks[2].cancel()
        await assertEventually("the cancelled flight must leave the registry") {
            NotesOfficeCoverFlights.shared.waiterCount(forKey: key) == 0
        }
        release?.resume()
        release = nil
        for task in tasks { _ = await task.value }
        await assertEventually("cancellation must release both gates and remove every staged copy") {
            NotesOfficeThumbnailGate.shared.activeCount == 0 &&
            NotesOfficeThumbnailGate.summary.activeCount == 0 &&
            self.stagedCoverDirectoryCount() == baseline
        }

        // A fresh flight for the same key must not be blocked by the cancelled
        // one, and must deliver both a first paint and the system content.
        var newPaints = 0
        var newCalls = 0
        let settled = await NotesDocumentCoverService.render(
            document: document, store: store, size: coverSize,
            maximumSourceBytes: maximumSourceBytes,
            request: { _, _, _ in
                newCalls += 1
                return NotesOfficeThumbnailGenerator.AttemptOutcome(
                    image: self.makeImage(.systemGreen), diagnosis: "content",
                    timedOut: false, elapsed: .zero)
            },
            onFirstPaint: { _ in newPaints += 1 })
        XCTAssertEqual(newPaints, 1)
        XCTAssertEqual(newCalls, 1)
        XCTAssertEqual(settled.source, .quickLookThumbnail)
        await assertEventually("the fresh flight must clean up its copy too") {
            self.stagedCoverDirectoryCount() == baseline
        }
    }

    /// A card cancelled while it is queued for a summary slot must not consume
    /// a slot or leave a copy; the freed slots must serve the next card.
    func testCancelledSummaryWaiterDoesNotConsumeASlotOrStageACopy() async throws {
        let root = makeScratchDirectory("cancel-gate")
        defer { try? FileManager.default.removeItem(at: root) }
        let (store, document, _) = try await makeOfficeDocument(
            root: root.appendingPathComponent("doc"), name: "cancel.docx")
        let baseline = stagedCoverDirectoryCount()

        var heldSlots = 0
        func holdSummarySlot() async {
            let acquired = await NotesOfficeThumbnailGate.summary.acquire(id: UUID())
            XCTAssertTrue(acquired)
            heldSlots += 1
        }
        defer {
            for _ in 0..<heldSlots { NotesOfficeThumbnailGate.summary.release() }
        }
        await holdSummarySlot()
        await holdSummarySlot()

        var cancelledPaints = 0
        let cancelled = Task { @MainActor in
            await NotesDocumentCoverService.render(
                document: document, store: store, size: self.coverSize,
                maximumSourceBytes: self.maximumSourceBytes,
                onFirstPaint: { _ in cancelledPaints += 1 })
        }
        await assertEventually("the card must be queued for a summary slot") {
            NotesOfficeThumbnailGate.summary.waiterCount == 1
        }
        XCTAssertEqual(stagedCoverDirectoryCount(), baseline)

        cancelled.cancel()
        await assertEventually("a cancelled summary waiter must leave the queue") {
            NotesOfficeThumbnailGate.summary.waiterCount == 0
        }
        _ = await cancelled.value
        XCTAssertEqual(cancelledPaints, 0)
        XCTAssertEqual(stagedCoverDirectoryCount(), baseline,
                       "a cancelled gated card must not have staged a copy")

        heldSlots = 0
        NotesOfficeThumbnailGate.summary.release()
        NotesOfficeThumbnailGate.summary.release()
        var paints = 0
        let outcome = await NotesDocumentCoverService.render(
            document: document, store: store, size: coverSize,
            maximumSourceBytes: maximumSourceBytes,
            request: { _, _, _ in
                NotesOfficeThumbnailGenerator.AttemptOutcome(
                    image: self.makeImage(.systemOrange), diagnosis: "content",
                    timedOut: false, elapsed: .zero)
            },
            onFirstPaint: { _ in paints += 1 })
        XCTAssertEqual(paints, 1, "the freed summary slots must serve the next card")
        XCTAssertEqual(outcome.source, .quickLookThumbnail)
        await assertEventually("the next card must clean up its staged copy too") {
            self.stagedCoverDirectoryCount() == baseline
        }
    }

    /// The bounded fallback used when the registry is at capacity runs the
    /// same resource body, so its summary copy and Quick Look copy are bounded
    /// by the same gates as a coalesced flight.
    func testOverCapacityUncoalescedRenderIsStillBoundedByTheSameGates() async throws {
        let root = makeScratchDirectory("over-cap")
        defer { try? FileManager.default.removeItem(at: root) }
        let (store, document, _) = try await makeOfficeDocument(
            root: root.appendingPathComponent("doc"), name: "over-cap.docx")
        let realKey = NotesDocumentCoverService.officeResourceKey(
            document: document, store: store, fileExtension: "docx",
            size: coverSize, maximumSourceBytes: maximumSourceBytes)

        // Fill the registry to its hard cap with suspended flights. The next
        // resource cannot coalesce and must take the direct bounded path.
        var fillerReleases: [CheckedContinuation<Void, Never>] = []
        var fillerTasks: [Task<Void, Never>] = []
        let fillerKeys = (0..<NotesOfficeCoverFlights.maximumEntries).map { _ in
            "over-cap-filler-\(UUID().uuidString)"
        }
        let fillersStarted = fillerKeys.map { key in
            expectation(description: "filler flight \(key) started")
        }
        for (index, key) in fillerKeys.enumerated() {
            let task = Task { @MainActor in
                _ = await NotesOfficeCoverFlights.shared.outcome(key: key) { _ in } perform: { _ in
                    fillersStarted[index].fulfill()
                    await withCheckedContinuation { fillerReleases.append($0) }
                    return .init(image: nil, source: .none, diagnosis: "over-cap filler")
                }
            }
            fillerTasks.append(task)
        }
        // A failed assertion must release the filler flights and the render
        // instead of leaving 16 suspended entries for later tests.
        defer {
            for continuation in fillerReleases { continuation.resume() }
            fillerReleases.removeAll()
            for task in fillerTasks { task.cancel() }
        }
        await fulfillment(of: fillersStarted, timeout: 15)
        for key in fillerKeys {
            XCTAssertEqual(NotesOfficeCoverFlights.shared.waiterCount(forKey: key), 1)
        }
        let baseline = stagedCoverDirectoryCount()

        // Two external holders occupy the summary gate; the over-cap render
        // must still be bound by it and must not register a coalesced flight.
        var heldSlots = 0
        func holdSummarySlot() async {
            let acquired = await NotesOfficeThumbnailGate.summary.acquire(id: UUID())
            XCTAssertTrue(acquired)
            heldSlots += 1
        }
        defer {
            for _ in 0..<heldSlots { NotesOfficeThumbnailGate.summary.release() }
        }
        await holdSummarySlot()
        await holdSummarySlot()

        var paints = 0
        var calls = 0
        var release: CheckedContinuation<Void, Never>?
        let started = expectation(description: "over-cap Quick Look request in flight")
        let render = Task { @MainActor in
            await NotesDocumentCoverService.render(
                document: document, store: store, size: self.coverSize,
                maximumSourceBytes: self.maximumSourceBytes,
                request: { _, _, _ in
                    calls += 1
                    started.fulfill()
                    await withCheckedContinuation { release = $0 }
                    return NotesOfficeThumbnailGenerator.AttemptOutcome(
                        image: self.makeImage(.systemTeal), diagnosis: "content",
                        timedOut: false, elapsed: .zero)
                },
                onFirstPaint: { _ in paints += 1 })
        }
        defer {
            if let pending = release { release = nil; pending.resume() }
            render.cancel()
        }
        await assertEventually("the over-cap render must queue behind the summary gate") {
            NotesOfficeThumbnailGate.summary.waiterCount == 1
        }
        XCTAssertEqual(NotesOfficeCoverFlights.shared.waiterCount(forKey: realKey), 0,
                       "a registry at capacity must run without a coalesced entry")
        XCTAssertEqual(paints, 0)
        XCTAssertEqual(stagedCoverDirectoryCount(), baseline,
                       "the over-cap render must not stage before owning a summary slot")

        heldSlots -= 1
        NotesOfficeThumbnailGate.summary.release()
        await fulfillment(of: [started], timeout: 15)
        XCTAssertEqual(paints, 1)
        XCTAssertEqual(calls, 1)
        XCTAssertEqual(stagedCoverDirectoryCount(), baseline + 1,
                       "once summarizing is done only the Quick Look copy may exist")
        heldSlots -= 1
        NotesOfficeThumbnailGate.summary.release()

        release?.resume()
        release = nil
        let outcome = await render.value
        XCTAssertEqual(outcome.source, .quickLookThumbnail)
        await assertEventually("the over-cap render must clean up its copy") {
            self.stagedCoverDirectoryCount() == baseline
        }

        // Release the filler flights so the shared registry returns to zero.
        for task in fillerTasks { task.cancel() }
        for continuation in fillerReleases { continuation.resume() }
        fillerReleases.removeAll()
        for task in fillerTasks { _ = await task.value }
        await assertEventually("cancelled filler flights must leave the registry") {
            fillerKeys.allSatisfy {
                NotesOfficeCoverFlights.shared.waiterCount(forKey: $0) == 0
            }
        }
    }

    // MARK: - Helpers

    /// Counts the app's transient Office staging directories. The component
    /// tests run serially on the host, so the delta from a test-local baseline
    /// is exactly the copies that test's renders created. This observes real
    /// files, not a comment or an internal counter.
    private func stagedCoverDirectoryCount() -> Int {
        let temporary = FileManager.default.temporaryDirectory
        let names = (try? FileManager.default.contentsOfDirectory(atPath: temporary.path)) ?? []
        return names.filter { $0.hasPrefix("floe-notes-thumb-") }.count
    }

    /// Bounded wait for main-actor state without a fixed sleep assumption.
    private func waitUntil(timeout: Duration = .seconds(15),
                           _ condition: @MainActor () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return condition()
    }

    /// `waitUntil` as an assertion; the async result is bound before the
    /// autoclosure so an `await` is never nested inside `XCTAssertTrue`.
    private func assertEventually(_ message: String, timeout: Duration = .seconds(15),
                                  _ condition: @MainActor () -> Bool,
                                  file: StaticString = #filePath, line: UInt = #line) async {
        let satisfied = await waitUntil(timeout: timeout, condition)
        XCTAssertTrue(satisfied, message, file: file, line: line)
    }

    private func makeScratchDirectory(_ label: String) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("notes-progressive-\(label)-\(UUID().uuidString)", isDirectory: true)
    }

    private func makeOfficeDocument(root: URL, name: String) async throws -> (NotesStore, NoteDocument, URL) {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let source = root.appendingPathComponent(name)
        try OfficeDocumentBuilder.createWord(at: source, title: "渐进封面",
                                             paragraphs: ["第一段真实内容", "第二个段落"])
        let store = try NotesStore(root: root.appendingPathComponent("store"))
        let draft = try await NoteFileImporter.importFile(source, notebookID: nil, store: store)
        return (store, try await store.create(draft), source)
    }

    private func makeImage(_ color: UIColor) -> UIImage {
        UIGraphicsImageRenderer(size: CGSize(width: 8, height: 8)).image { context in
            color.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
        }
    }
}
