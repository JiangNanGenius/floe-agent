// FloeAppTests — exact bridge ownership for recovery copies (E33 follow-up).
//
// FilePreview closes the document it presented before reloading, and Canvas
// adopts a NEW recovered package that is not the node's binding. Both paths
// must never hand a closed session to a new presentation, and the adopted copy
// must be save+released through its own URL. These tests use real `.floecad`
// packages and the production bridge; no mock store or second owner registry.
//
// The release is awaited across a REAL detached commit. The tests suspend that
// commit through the existing session delivery hook, then either run a command
// or close+reopen the same path, so the post-await instance/dirty fences are
// exercised against the production document, not a mirrored policy helper.
//
// SPDX-License-Identifier: MPL-2.0

#if canImport(SwiftUI) && canImport(UIKit)
import Foundation
import XCTest
@testable import FloeCAD
@testable import FloeApp
import FloeCore

@MainActor
final class CADRecoveryBridgeOwnershipTests: XCTestCase {
    private var workDir: URL!

    override func setUp() async throws {
        workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("CADRecoveryBridge-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: workDir,
                                                withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        if let workDir { try? FileManager.default.removeItem(at: workDir) }
    }

    func testClosedBridgeSessionIsNeverHandedOutAgain() async throws {
        let url = workDir.appendingPathComponent("Closed.floecad")
        let created = try await FloeCADDocument.create(at: url, name: "Closed")
        created.close()

        let first = try await FloeCAD3DBridge.shared.openDocument(at: url)
        XCTAssertFalse(first.isClosed)
        // Simulate the FilePreview reload path: it flushes and closes its
        // document before releasing ownership. A later open must not reuse the
        // closed instance.
        first.close()

        let reopened = try await FloeCAD3DBridge.shared.openDocument(at: url)
        XCTAssertFalse(reopened === first,
                       "a closed bridge session must never become a new presentation's document")
        XCTAssertFalse(reopened.isClosed)
        _ = await FloeCAD3DBridge.shared.releaseDocumentOutcome(at: url)
    }

    func testReleaseOutcomeSavesTheCopyAndDropsOnlyThatOwner() async throws {
        let url = workDir.appendingPathComponent("Copy.floecad")
        let created = try await FloeCADDocument.create(at: url, name: "Copy")
        created.close()

        let live = try await FloeCAD3DBridge.shared.openDocument(at: url)
        let command = live.executeJSON(Data(
            #"{"op":"sketch.create","args":{"name":"Kept in the copy"}}"#.utf8))
        XCTAssertTrue(command.isOK, command.message ?? "")
        let sketchCount = live.summary().sketchCount

        let released = await FloeCAD3DBridge.shared.releaseDocumentOutcome(at: url)
        let outcome = try XCTUnwrap(released,
                                    "the bridge must own the session this editor opened")
        XCTAssertNil(outcome.error)
        XCTAssertTrue(live.isClosed,
                      "a successful release closes the exact adopted copy")

        let reopened = try await FloeCAD3DBridge.shared.openDocument(at: url)
        XCTAssertFalse(reopened === live,
                       "the released session must not be handed out again")
        XCTAssertEqual(reopened.summary().sketchCount, sketchCount,
                       "the release saved the copy's committed edits")
        _ = await FloeCAD3DBridge.shared.releaseDocumentOutcome(at: url)
    }

    func testReadOnlyReleaseNeverDiscardsAWriteableDraft() async throws {
        let url = workDir.appendingPathComponent("Writable.floecad")
        let created = try await FloeCADDocument.create(at: url, name: "Writable")
        created.close()

        let live = try await FloeCAD3DBridge.shared.openDocument(at: url)
        XCTAssertFalse(live.isReadOnly)
        XCTAssertFalse(FloeCAD3DBridge.shared.releaseReadOnlyDocument(live),
                       "a writable document must never be dropped by the read-only release")
        XCTAssertFalse(live.isClosed)
        _ = await FloeCAD3DBridge.shared.releaseDocumentOutcome(at: url)
        XCTAssertTrue(live.isClosed)
    }

    func testCleanReleasePreservesTheExactCommittedIdentityAndPackageBytes() async throws {
        let url = workDir.appendingPathComponent("CleanRelease.floecad")
        let created = try await FloeCADDocument.create(at: url, name: "Clean release")
        created.close()
        let live = try await FloeCAD3DBridge.shared.openDocument(at: url)
        let command = live.executeJSON(Data(
            #"{"op":"sketch.create","args":{"name":"Already committed"}}"#.utf8))
        XCTAssertTrue(command.isOK, command.message ?? "")
        let committed = await live.save()
        XCTAssertNil(committed.error, committed.error ?? "")
        XCTAssertFalse(live.hasUnsavedChanges)
        let manifest = try Data(contentsOf: url.appendingPathComponent("manifest.json"))
        let document = try Data(contentsOf: url.appendingPathComponent("document.json"))

        let released = await FloeCAD3DBridge.shared.releaseDocumentOutcome(at: url, expected: live)
        XCTAssertEqual(released, committed, "release must return the existing verified commit")
        XCTAssertTrue(live.isClosed)
        XCTAssertEqual(try Data(contentsOf: url.appendingPathComponent("manifest.json")), manifest)
        XCTAssertEqual(try Data(contentsOf: url.appendingPathComponent("document.json")), document)
        let reopened = try await FloeCADDocument.open(at: url)
        defer { reopened.close() }
        XCTAssertEqual(reopened.savedIdentity, committed)
        XCTAssertEqual(reopened.summary().sketchCount, 1)
    }

    // MARK: - Release racing a late edit or a replaced owner

    func testLateEditDuringReleaseKeepsTheDraftAndCanBeRetried() async throws {
        let url = workDir.appendingPathComponent("LateEdit.floecad")
        let created = try await FloeCADDocument.create(at: url, name: "Late Edit")
        created.close()

        let live = try await FloeCAD3DBridge.shared.openDocument(at: url)
        let committed = live.executeJSON(Data(
            #"{"op":"sketch.create","args":{"name":"Committed"}}"#.utf8))
        XCTAssertTrue(committed.isOK, committed.message ?? "")

        // The hook fires AFTER the real commit and BEFORE the session adopts
        // it. A command executed there is exactly a command that ran while the
        // release awaited its save: the committed payload does not contain it.
        let gate = ReleaseSaveGate()
        live.session.committedIdentityDeliveryForTesting = { _ in
            await gate.hold()
            let late = live.executeJSON(Data(
                #"{"op":"sketch.create","args":{"name":"Late edit"}}"#.utf8))
            XCTAssertTrue(late.isOK, late.message ?? "")
        }
        defer {
            live.session.committedIdentityDeliveryForTesting = nil
            gate.release()
        }

        let release = Task { @MainActor in
            await FloeCAD3DBridge.shared.releaseDocumentOutcome(at: url, expected: live)
        }
        let entered = await gate.waitUntilHeld()
        XCTAssertTrue(entered, "the real save must reach the delivery suspension")
        XCTAssertFalse(gate.timedOut)
        guard entered else {
            gate.release()
            _ = await release.value
            return
        }
        gate.release()
        let refused = await release.value
        live.session.committedIdentityDeliveryForTesting = nil

        let outcome = try XCTUnwrap(
            refused, "the bridge still owns the document and must report its real outcome")
        XCTAssertNotNil(outcome.error,
                        "closing after a late edit would silently discard it")
        XCTAssertFalse(live.isClosed,
                       "the document that has the newer draft must stay open")
        XCTAssertTrue(live.hasUnsavedChanges,
                      "the command that ran during the save must remain a real draft")
        XCTAssertEqual(live.summary().sketchCount, 2)

        let cached = try await FloeCAD3DBridge.shared.openDocument(at: url)
        XCTAssertTrue(cached === live,
                      "the only live owner must stay cached for the retry")

        let retriedValue = await FloeCAD3DBridge.shared
            .releaseDocumentOutcome(at: url, expected: live)
        let retried = try XCTUnwrap(retriedValue)
        XCTAssertNil(retried.error, retried.error ?? "")
        XCTAssertTrue(live.isClosed, "the retry saves and releases the exact owner")

        let reopened = try await FloeCAD3DBridge.shared.openDocument(at: url)
        XCTAssertEqual(reopened.summary().sketchCount, 2,
                       "the retry persists the edit that arrived during the first release")
        _ = await FloeCAD3DBridge.shared.releaseDocumentOutcome(at: url, expected: reopened)
    }

    func testStaleReleaseCannotDropAClosedReopenedReplacement() async throws {
        let url = workDir.appendingPathComponent("Replacement.floecad")
        let created = try await FloeCADDocument.create(at: url, name: "Replacement")
        created.close()

        let live = try await FloeCAD3DBridge.shared.openDocument(at: url)
        let edit = live.executeJSON(Data(
            #"{"op":"sketch.create","args":{"name":"Before replacement"}}"#.utf8))
        XCTAssertTrue(edit.isOK, edit.message ?? "")

        let gate = ReleaseSaveGate()
        live.session.committedIdentityDeliveryForTesting = { _ in await gate.hold() }
        defer {
            live.session.committedIdentityDeliveryForTesting = nil
            gate.release()
        }

        let release = Task { @MainActor in
            await FloeCAD3DBridge.shared.releaseDocumentOutcome(at: url, expected: live)
        }
        let entered = await gate.waitUntilHeld()
        XCTAssertTrue(entered, "the real save must reach the delivery suspension")
        XCTAssertFalse(gate.timedOut)
        guard entered else {
            gate.release()
            _ = await release.value
            return
        }

        // The old owner is closed and the SAME path is reopened while its
        // commit is still suspended: this is the newer cached instance a stale
        // completion could previously drop and close.
        live.close()
        let replacement = try await FloeCAD3DBridge.shared.openDocument(at: url)
        XCTAssertFalse(replacement === live)
        XCTAssertFalse(replacement.isClosed)

        gate.release()
        let staleValue = await release.value
        let stale = try XCTUnwrap(
            staleValue, "the old instance's own commit really succeeded")
        live.session.committedIdentityDeliveryForTesting = nil
        XCTAssertNil(stale.error, stale.error ?? "")

        XCTAssertFalse(replacement.isClosed,
                       "a stale completion must never close the newer cached owner")
        let cached = try await FloeCAD3DBridge.shared.openDocument(at: url)
        XCTAssertTrue(cached === replacement,
                      "the newer session must still be the bridge owner")
        XCTAssertEqual(replacement.summary().sketchCount, 1,
                       "the reopened session reads the committed replacement path")

        let releasedValue = await FloeCAD3DBridge.shared
            .releaseDocumentOutcome(at: url, expected: replacement)
        let released = try XCTUnwrap(releasedValue)
        XCTAssertNil(released.error, released.error ?? "")
        XCTAssertTrue(replacement.isClosed)
    }

    func testReleaseRefusesADifferentDocumentAtTheSamePath() async throws {
        let url = workDir.appendingPathComponent("Owned.floecad")
        let otherURL = workDir.appendingPathComponent("Other.floecad")
        let created = try await FloeCADDocument.create(at: url, name: "Owned")
        created.close()
        let other = try await FloeCADDocument.create(at: otherURL, name: "Other")
        defer { other.close() }

        let live = try await FloeCAD3DBridge.shared.openDocument(at: url)
        let edit = live.executeJSON(Data(
            #"{"op":"sketch.create","args":{"name":"Draft"}}"#.utf8))
        XCTAssertTrue(edit.isOK, edit.message ?? "")

        let refused = await FloeCAD3DBridge.shared
            .releaseDocumentOutcome(at: url, expected: other)
        XCTAssertNil(refused,
                     "a different instance must never be saved or released through this path")
        XCTAssertFalse(live.isClosed,
                       "the refused release must not close the cached owner")
        XCTAssertTrue(live.hasUnsavedChanges,
                      "the refused release must not save or drop the cached draft")
        XCTAssertFalse(other.isClosed,
                       "the foreign instance must not be closed by another path's release")

        let cached = try await FloeCAD3DBridge.shared.openDocument(at: url)
        XCTAssertTrue(cached === live)

        let releasedValue = await FloeCAD3DBridge.shared
            .releaseDocumentOutcome(at: url, expected: live)
        let released = try XCTUnwrap(releasedValue)
        XCTAssertNil(released.error, released.error ?? "")
        XCTAssertTrue(live.isClosed)
    }
}

/// Holds the REAL post-commit delivery hook until the test has observed it,
/// with a bounded wait so a fixture mistake cannot hang the suite. It does not
/// replace the store, the CAS fence or the session's identity adoption.
@MainActor
private final class ReleaseSaveGate {
    private(set) var timedOut = false
    private(set) var held = false
    private var enteredWaiters: [CheckedContinuation<Bool, Never>] = []
    private var released = false
    private var releaseWaiter: CheckedContinuation<Void, Never>?

    func hold() async {
        guard !held else { return }
        held = true
        let waiters = enteredWaiters
        enteredWaiters.removeAll()
        waiters.forEach { $0.resume(returning: true) }
        guard !released else { return }
        let timeout = Task { [weak self] in
            try? await Task.sleep(for: .seconds(10))
            guard !Task.isCancelled, let self, !self.released else { return }
            self.timedOut = true
            self.release()
        }
        await withCheckedContinuation { releaseWaiter = $0 }
        timeout.cancel()
    }

    func waitUntilHeld() async -> Bool {
        if held { return true }
        let timeout = Task { [weak self] in
            try? await Task.sleep(for: .seconds(10))
            guard !Task.isCancelled, let self, !self.held else { return }
            self.timedOut = true
            let waiters = self.enteredWaiters
            self.enteredWaiters.removeAll()
            waiters.forEach { $0.resume(returning: false) }
            self.release()
        }
        let result = await withCheckedContinuation { enteredWaiters.append($0) }
        timeout.cancel()
        return result
    }

    func release() {
        released = true
        releaseWaiter?.resume()
        releaseWaiter = nil
    }
}
#endif
