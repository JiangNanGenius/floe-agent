// SPDX-License-Identifier: MPL-2.0
// Focused production tests for the Office -> Notes autosave owner
// transaction. The coordinator under test is the REAL
// OfficeAutosaveCoordinator; the Notes side runs through the REAL
// OfficeNotesDraftPromotion against a REAL on-disk NotesStore with REAL
// SHA-256 digests; drafts are REAL OOXML packages reopened through the REAL
// read-only OfficeDocumentService. The only test-owned seams are the owner's
// engine-side closures, which mutate real draft/working-copy bytes exactly
// like the production session's verified save (working copy -> draft copy),
// the production digest-injection seam on OfficeNotesDraftPromotion that
// exists for deterministic verification-failure tests, and a deterministic
// gate inside the real promotion closure so edits can be completed while the
// CAS await runs. What these tests can NOT prove — the engine-side pencil
// flush itself — belongs to the native host qualification
// (OfficeLiveInkAppQualificationTests idle test) and the primary's device
// acceptance.
#if canImport(UIKit)
import XCTest
import Foundation
import FloeCore
import FloeNotes
import FloeDocuments
@testable import FloeApp

@MainActor
final class OfficeAutosaveTests: XCTestCase {
    private var fixtures: [AutosaveFixture] = []

    override func tearDown() async throws {
        for fixture in fixtures { fixture.dispose() }
        fixtures.removeAll()
    }

    // MARK: - Coalescing + truthful dirty detection

    /// Two completed strokes inside the idle window drain as exactly ONE
    /// serialized transaction: one verified flush, one real Notes CAS
    /// promotion, one new revision, both strokes retained in the reopened
    /// package.
    func testTwoCompletedStrokesCoalesceIntoOneSerializedTransaction() async throws {
        let fixture = try await makeFixture()
        fixture.completeStroke("INK-1")
        fixture.coordinator.recheck(reason: "stroke1")
        fixture.completeStroke("INK-2")
        fixture.coordinator.recheck(reason: "stroke2")
        try await fixture.waitForSaved(timeout: .seconds(5))

        XCTAssertEqual(fixture.flushCount, 1, "Two strokes in one idle window must flush exactly once")
        XCTAssertEqual(fixture.promoteCount, 1, "Two strokes in one idle window must promote exactly once")
        let document = try await fixture.store.document(fixture.documentID)
        XCTAssertEqual(document.revision, fixture.baselineRevision)
        XCTAssertEqual(document.officeResourceID, fixture.baselineResourceID)
        XCTAssertGreaterThan(document.revision, fixture.initialRevision)
        let promotion = try XCTUnwrap(fixture.lastPromotionOutcome)
        guard case .promoted(let revision, let resourceID, let sha) = promotion else {
            return XCTFail("Expected a real promotion, got \(promotion)")
        }
        XCTAssertEqual(revision, document.revision)
        XCTAssertEqual(resourceID, document.officeResourceID)
        XCTAssertEqual(sha, try FloeDigest.sha256Hex(ofFileAt: fixture.draftURL))
        try await fixture.assertReopenedResourceContains(["ORIGINAL-CONTENT-KEEP", "INK-1", "INK-2"])
    }

    /// An active pen defers EVERY route, including the nominal clean/no-op
    /// claim: a just-started stroke can still read clean, so no
    /// current-saved proof may be issued while ink could be in flight.
    func testActivePenDefersEveryRouteIncludingCleanNoop() async throws {
        let fixture = try await makeFixture()
        fixture.penActive = true
        let deferred = await fixture.coordinator.requestTransaction(reason: "penDown")
        XCTAssertEqual(deferred.outcome, .deferred)
        XCTAssertEqual(deferred.reason, "autosave.penActive")
        XCTAssertEqual(fixture.flushCount, 0)
        XCTAssertEqual(fixture.promoteCount, 0)
        XCTAssertNil(deferred.packageSHA256)

        // Pen lifts with real edits pending: the retained dirty drains through
        // the same idle window and promotes truthfully.
        fixture.penActive = false
        fixture.completeStroke("INK-AFTER-PEN")
        fixture.coordinator.recheck(reason: "penUp")
        try await fixture.waitForSaved(timeout: .seconds(5))
        XCTAssertEqual(fixture.flushCount, 1)
        try await fixture.assertReopenedResourceContains(["ORIGINAL-CONTENT-KEEP", "INK-AFTER-PEN"])
    }

    /// The engine's accepted-content modified edge (what keyboard edits and
    /// strokes both post) only schedules a debounced recheck; the idle pass
    /// then proves dirty from the real draft bytes and promotes.
    func testKeyboardModifiedEdgeSchedulesIdleSave() async throws {
        let fixture = try await makeFixture()
        fixture.typeKeyboardText("KEYBOARD-1")
        fixture.coordinator.recheck(reason: "modified")
        try await fixture.waitForSaved(timeout: .seconds(5))
        XCTAssertEqual(fixture.flushCount, 1)
        XCTAssertEqual(fixture.promoteCount, 1)
        try await fixture.assertReopenedResourceContains(["ORIGINAL-CONTENT-KEEP", "KEYBOARD-1"])
    }

    // MARK: - Serialization against explicit triggers

    /// An explicit save arriving while the debounced pass is mid-promotion
    /// joins the running transaction and then claims a fresh pass: one flush
    /// for the dirty set, a truthful `alreadySaved` with the strict hash
    /// proof afterwards, never a double promotion.
    func testExplicitSaveJoinsRunningDebounceWithoutOverlappingFlush() async throws {
        let fixture = try await makeFixture()
        fixture.promoteGate = true
        fixture.completeStroke("INK-RACE")
        fixture.coordinator.recheck(reason: "stroke")
        try await fixture.waitForCondition("debounced pass parked before the promotion") {
            fixture.promoteGateSuspended
        }
        async let explicitProof = fixture.coordinator.requestTransaction(reason: "explicitRace")
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(fixture.flushCount, 1, "The running debounce already flushed; nothing overlaps")
        fixture.openPromoteGate()
        let proofs = await explicitProof
        try await fixture.waitForSaved(timeout: .seconds(5))

        XCTAssertEqual(proofs.outcome, .alreadySaved)
        XCTAssertEqual(proofs.revision, fixture.baselineRevision)
        XCTAssertEqual(proofs.packageSHA256, try FloeDigest.sha256Hex(ofFileAt: fixture.draftURL))
        XCTAssertEqual(proofs.dirtyAfterTransaction, false)
        XCTAssertEqual(fixture.flushCount, 1, "The joined explicit pass must not re-flush a verified draft")
        XCTAssertEqual(fixture.promoteCount, 2, "Second pass proves the strict clean no-op")
        let document = try await fixture.store.document(fixture.documentID)
        XCTAssertEqual(document.revision, fixture.initialRevision + 1, "Exactly one new revision for the dirty set")
        try await fixture.assertReopenedResourceContains(["INK-RACE"])
    }

    /// Edits completed while the promotion await runs are retained and
    /// drained by a follow-up pass: an old receipt never clears newer edits.
    func testDirtyArrivingDuringPromotionIsRetainedAndDrained() async throws {
        let fixture = try await makeFixture()
        fixture.promoteGate = true
        fixture.completeStroke("INK-DURING-1")
        fixture.coordinator.recheck(reason: "stroke1")
        try await fixture.waitForCondition("pass parked inside the promotion await") {
            fixture.promoteGateSuspended
        }
        fixture.completeStroke("INK-DURING-2")
        fixture.openPromoteGate()
        try await fixture.waitForCondition("both strokes promoted across the follow-up drain") {
            await fixture.storeRevision() >= fixture.initialRevision + 2
        }
        XCTAssertEqual(fixture.flushCount, 2)
        XCTAssertEqual(fixture.promoteCount, 2)
        try await fixture.assertReopenedResourceContains(["INK-DURING-1", "INK-DURING-2"])
    }

    // MARK: - Truthful failures + bounded retry

    /// A real Notes CAS conflict (another revision replaced the captured
    /// resource) fails truthfully, keeps the verified draft retained, retries
    /// within the bounded budget while demand is retained, and a re-baselined
    /// owner promotes the preserved draft AND the newer edits afterwards.
    func testNotesCASConflictRetriesWithinBudgetAndPreservesDraftAndNewerEdits() async throws {
        let fixture = try await makeFixture()
        fixture.promoteGate = true
        fixture.completeStroke("INK-HELD-1")
        fixture.coordinator.recheck(reason: "stroke1")
        try await fixture.waitForCondition("pass parked inside the promotion await") {
            fixture.promoteGateSuspended
        }
        // A REAL external Notes change lands while the promotion is gated:
        // the pending CAS must now refuse to protect the newer revision.
        try await fixture.replaceResourceExternally(marker: "EXTERNAL")
        fixture.completeStroke("INK-HELD-2")
        fixture.openPromoteGate()
        let conflict = try await fixture.waitForProof(timeout: .seconds(5)) {
            $0.outcome == .failed && $0.reason == "autosave.notesResourceConflict"
        }
        XCTAssertTrue(conflict.retryScheduled, "Retained demand (pending draft + newer edits) schedules a bounded retry")

        try await fixture.waitForCondition("bounded retry exhausts on the same failed dirty set") {
            fixture.stageCount("autosave.retryHeld") == 1 && fixture.stageCount("autosave.saved") == 0
        }
        let midDocument = try await fixture.store.document(fixture.documentID)
        XCTAssertEqual(midDocument.revision, fixture.initialRevision + 1, "Only the external change advanced the revision")
        let midResource = try await fixture.store.resourceURL(try XCTUnwrap(midDocument.officeResourceID))
        XCTAssertNotEqual(try FloeDigest.sha256Hex(ofFileAt: fixture.draftURL),
                          try FloeDigest.sha256Hex(ofFileAt: midResource),
                          "The retained draft must still carry the user's unsaved edits")

        // Consumer re-baselines (like the external-refresh route), then fresh
        // demand promotes the preserved draft plus the newer stroke.
        try await fixture.rebaselineToCurrentStoreState()
        let manual = await fixture.coordinator.requestTransaction(reason: "manualRetry")
        XCTAssertEqual(manual.outcome, .saved)
        XCTAssertEqual(manual.dirtyAfterTransaction, false)
        try await fixture.assertReopenedResourceContains(["INK-HELD-1", "INK-HELD-2"])
    }

    /// Close/reopen fencing: a stale owner can never promote after the view or
    /// generation moved on, and an invalidated coordinator answers cancelled.
    func testCloseReopenStaleOwnerCannotPromote() async throws {
        let fixture = try await makeFixture()
        fixture.completeStroke("INK-BEFORE-CLOSE")
        fixture.coordinator.recheck(reason: "stroke")
        try await fixture.waitForSaved(timeout: .seconds(5))

        fixture.isCurrent = false
        let refused = await fixture.coordinator.requestTransaction(reason: "staleView")
        XCTAssertEqual(refused.outcome, .refused)
        XCTAssertEqual(refused.reason, "autosave.staleDocument")
        XCTAssertEqual(fixture.promoteCount, 1, "The stale owner must not promote again")
        XCTAssertNil(refused.packageSHA256)

        fixture.coordinator.invalidate()
        let cancelled = await fixture.coordinator.requestTransaction(reason: "afterInvalidate")
        XCTAssertEqual(cancelled.outcome, .cancelled)
        XCTAssertEqual(cancelled.reason, "autosave.invalidated")

        // Reopen: a new generation installs the owner again and the document
        // promotes normally; nothing from the old coordinator leaks into it.
        let reopened = try await makeFixture(documentID: fixture.documentID,
                                             store: fixture.store,
                                             session: fixture.session,
                                             draftURL: fixture.draftURL,
                                             baselineResourceID: fixture.baselineResourceID,
                                             baselineRevision: fixture.baselineRevision)
        reopened.completeStroke("INK-AFTER-REOPEN")
        reopened.coordinator.recheck(reason: "stroke")
        try await reopened.waitForSaved(timeout: .seconds(5))
        try await reopened.assertReopenedResourceContains(["INK-BEFORE-CLOSE", "INK-AFTER-REOPEN"])
    }

    /// Foreground-inactive/background/exit drains share the same serialized
    /// coordinator: they defer an active pen safely and drain real edits once
    /// the pen lifts. No platform background-time promise is made or checked.
    func testLifecycleDrainDefersActivePenThenDrains() async throws {
        let fixture = try await makeFixture()
        fixture.completeStroke("INK-LIFECYCLE")
        fixture.penActive = true
        let deferred = await fixture.coordinator.requestTransaction(reason: "lifecyclePen")
        XCTAssertEqual(deferred.outcome, .deferred)
        XCTAssertEqual(deferred.reason, "autosave.penActive")
        XCTAssertEqual(fixture.flushCount, 0, "No save underneath an active pen")

        fixture.penActive = false
        fixture.coordinator.drainForLifecycle()
        try await fixture.waitForSaved(timeout: .seconds(5))
        XCTAssertEqual(fixture.flushCount, 1)
        try await fixture.assertReopenedResourceContains(["INK-LIFECYCLE"])
    }

    /// A clean no-op still requires the strict hash proof: the existing
    /// revision/resource are reported with the real package digest, no new
    /// revision is claimed, and the reopened resource matches the reported
    /// hash byte for byte.
    func testCleanNoopRequiresStrictHashProof() async throws {
        let fixture = try await makeFixture()
        fixture.coordinator.recheck(reason: "noopProbe")
        try await fixture.waitForCondition("clean no-op proof published") {
            fixture.stageCount("autosave.alreadySaved") >= 1
        }
        let promotion = try XCTUnwrap(fixture.lastPromotionOutcome)
        guard case .alreadySaved(let revision, let resourceID, let sha) = promotion else {
            return XCTFail("Expected the strict clean no-op proof, got \(promotion)")
        }
        XCTAssertEqual(revision, fixture.initialRevision)
        XCTAssertEqual(resourceID, fixture.initialResourceID)
        XCTAssertEqual(fixture.flushCount, 0, "A no-op must never flush the engine")
        let document = try await fixture.store.document(fixture.documentID)
        XCTAssertEqual(document.revision, fixture.initialRevision, "A no-op must never advance the revision")
        let current = try await fixture.store.resourceURL(try XCTUnwrap(document.officeResourceID))
        XCTAssertEqual(sha, try FloeDigest.sha256Hex(ofFileAt: current),
                       "The reported hash must be the real current resource digest")
    }

    /// Missing proof is an explicit failure, never a swallowed success: an
    /// unreadable imported-resource digest fails verification, discards the
    /// orphan import, leaves the original resource and revision untouched,
    /// and reports the real coordinator outcome.
    func testFailedProofIsExplicitFailureNeverSuccess() async throws {
        let fixture = try await makeFixture()
        fixture.failImportedResourceDigest = true
        fixture.completeStroke("INK-UNPROVEN")
        fixture.coordinator.recheck(reason: "stroke")
        let proof = try await fixture.waitForProof(timeout: .seconds(5)) {
            $0.outcome == .failedVerification
        }
        XCTAssertEqual(proof.reason, "notes.promotionProofUnavailable")
        XCTAssertNil(proof.packageSHA256)
        XCTAssertEqual(fixture.flushCount, 1, "The engine flush really ran; only the proof failed")
        try await fixture.waitForCondition("bounded retry held on the same failed dirty set") {
            fixture.stageCount("autosave.retryHeld") >= 1
        }
        let document = try await fixture.store.document(fixture.documentID)
        XCTAssertEqual(document.revision, fixture.initialRevision)
        XCTAssertEqual(document.officeResourceID, fixture.initialResourceID,
                       "A failed verification must never publish into the document")
        let original = try await fixture.store.resourceURL(fixture.initialResourceID)
        XCTAssertTrue(FileManager.default.fileExists(atPath: original.path))
        _ = try FloeDigest.sha256Hex(ofFileAt: original)
    }

    // MARK: - Fixture

    private func makeFixture(documentID: UUID? = nil, store: NotesStore? = nil,
                             session: NotesSession? = nil, draftURL: URL? = nil,
                             baselineResourceID: UUID? = nil,
                             baselineRevision: Int? = nil) async throws -> AutosaveFixture {
        let fixture: AutosaveFixture
        if let documentID, let store, let session, let draftURL,
           let baselineResourceID, let baselineRevision {
            let rows = try await AutosaveFixture.rowsSnapshot(store: store, resourceID: baselineResourceID)
            fixture = try AutosaveFixture(adoptingDocumentID: documentID, store: store, session: session,
                                          draftURL: draftURL, baselineResourceID: baselineResourceID,
                                          baselineRevision: baselineRevision, rows: rows)
        } else {
            fixture = try await AutosaveFixture()
        }
        fixtures.append(fixture)
        return fixture
    }
}

// MARK: - Test fixture (file-backed, real store CAS)

/// Deterministic switch behind the production digest-injection seam. Only
/// digest reads of files inside the store root can be failed; the draft's
/// own digest always computes from real bytes.
private final class ImportedDigestFailureSwitch: @unchecked Sendable {
    var fail = false
    let storeRootPrefix: String
    init(storeRootPrefix: String) { self.storeRootPrefix = storeRootPrefix }

    lazy var digest: OfficeNotesDraftPromotion.PackageDigest = { [weak self] url in
        guard let self else {
            throw OfficeNotesDraftPromotion.Failure.proofUnavailable("digest switch released")
        }
        if self.fail && url.path.hasPrefix(self.storeRootPrefix) {
            throw OfficeNotesDraftPromotion.Failure.proofUnavailable("injected imported-resource digest failure")
        }
        return try FloeDigest.sha256Hex(ofFileAt: url)
    }
}

@MainActor
private final class AutosaveFixture {
    struct StageEntry {
        let name: String
        let facts: [String: String]
    }

    let root: URL
    let store: NotesStore
    let session: NotesSession
    let documentID: UUID
    let draftURL: URL
    let workingURL: URL
    var baselineResourceID: UUID
    var baselineRevision: Int
    let initialResourceID: UUID
    let initialRevision: Int
    let coordinator: OfficeAutosaveCoordinator
    private let digestSwitch: ImportedDigestFailureSwitch
    private var lastSavedDigest: String
    private var rows: [[String]]

    var penActive = false
    var isCurrent = true
    var busy = false
    var ready = true
    var invalidated = false
    var flushFailuresRemaining = 0
    var promoteGate = false
    var failImportedResourceDigest: Bool {
        get { digestSwitch.fail }
        set { digestSwitch.fail = newValue }
    }
    private(set) var flushCount = 0
    private(set) var promoteCount = 0
    private(set) var promoteGateSuspended = false
    private(set) var pendingPromotion = false
    private(set) var lastPromotionOutcome: OfficeNotesPromotionOutcome?
    private var gateContinuation: CheckedContinuation<Void, Never>?
    private var observedProofs: [OfficeSavedProof] = []
    private var stages: [StageEntry] = []

    /// Fresh document: real builder package, real import, real create, real
    /// draft copy. Everything downstream operates on these real bytes.
    init() async throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("office-autosave-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let source = root.appendingPathComponent("Autosave.xlsx")
        rows = [["ORIGINAL-CONTENT-KEEP"]]
        try OfficeDocumentBuilder.createWorkbook(at: source, sheets: [
            .init(name: "Ink", rows: rows)
        ])
        let store = try NotesStore(root: root.appendingPathComponent("store"))
        self.store = store
        let session = NotesSession()
        self.session = session
        await session.open(using: store)
        let imported = try await NoteFileImporter.importFile(source, notebookID: nil, store: store)
        let document = try await store.create(imported)
        guard let resourceID = document.officeResourceID else {
            throw CocoaError(.coderInvalidValue)
        }
        documentID = document.id
        initialResourceID = resourceID
        initialRevision = document.revision
        baselineResourceID = resourceID
        baselineRevision = document.revision
        draftURL = root.appendingPathComponent("draft.xlsx")
        workingURL = root.appendingPathComponent("working.xlsx")
        try FileManager.default.copyItem(at: source, to: draftURL)
        try FileManager.default.copyItem(at: source, to: workingURL)
        lastSavedDigest = try FloeDigest.sha256Hex(ofFileAt: draftURL)
        digestSwitch = ImportedDigestFailureSwitch(storeRootPrefix: root.appendingPathComponent("store").path)
        coordinator = makeCoordinator(generation: 1)
        coordinator.installOwner(makeOwner())
    }

    /// Reopened editor for an existing document: the caller seeds the visible
    /// rows from the REAL current resource (`rowsSnapshot`), matching what a
    /// reopened editor renders from the committed package.
    init(adoptingDocumentID: UUID, store: NotesStore, session: NotesSession,
         draftURL: URL, baselineResourceID: UUID, baselineRevision: Int,
         rows: [[String]]) throws {
        self.root = draftURL.deletingLastPathComponent()
        self.store = store
        self.session = session
        self.documentID = adoptingDocumentID
        self.draftURL = draftURL
        self.workingURL = root.appendingPathComponent("working-adopt-\(UUID().uuidString).xlsx")
        self.baselineResourceID = baselineResourceID
        self.baselineRevision = baselineRevision
        self.initialResourceID = baselineResourceID
        self.initialRevision = baselineRevision
        self.rows = rows
        try FileManager.default.copyItem(at: draftURL, to: workingURL)
        lastSavedDigest = try FloeDigest.sha256Hex(ofFileAt: draftURL)
        digestSwitch = ImportedDigestFailureSwitch(storeRootPrefix: "/autosave-adopted-store")
        coordinator = makeCoordinator(generation: 2)
        coordinator.installOwner(makeOwner())
    }

    static func rowsSnapshot(store: NotesStore, resourceID: UUID) async throws -> [[String]] {
        let resource = try await store.resourceURL(resourceID)
        let temp = FileManager.default.temporaryDirectory
            .appendingPathComponent("autosave-seed-\(UUID().uuidString).xlsx")
        try FileManager.default.copyItem(at: resource, to: temp)
        defer { try? FileManager.default.removeItem(at: temp) }
        let snapshot = try OfficeDocumentService.inspect(url: temp)
        let ordered = snapshot.fields
            .filter { $0.id.hasSuffix("|c|A") }
            .sorted {
                (Int($0.id.drop(while: { !$0.isNumber })) ?? 0)
                    < (Int($1.id.drop(while: { !$0.isNumber })) ?? 0)
            }
        return ordered.isEmpty ? [["AUTOSAVE-SEED"]] : ordered.map { [$0.text] }
    }

    private func makeCoordinator(generation: Int) -> OfficeAutosaveCoordinator {
        let controllerID = ObjectIdentifier(self)
        return OfficeAutosaveCoordinator(
            binding: OfficeAutosaveCoordinator.Binding(
                generation: generation,
                controllerID: controllerID,
                workingCopyPath: workingURL.path,
                sessionCorrelationID: "autosave-tests-\(UUID().uuidString)"),
            signals: OfficeAutosaveSignals(
                sessionState: { [weak self] in
                    guard let self, !self.invalidated else { return .closed }
                    guard self.ready else { return .notReady }
                    if self.busy { return .busy }
                    return .ready
                },
                fenceCurrent: { [weak self] in self?.isCurrent == true && self?.invalidated != true },
                recordStage: { [weak self] stage, facts in
                    self?.stages.append(StageEntry(name: stage, facts: facts))
                },
                lastFlushError: { [weak self] in
                    (self?.flushFailuresRemaining ?? 0) > 0 ? "autosave-tests.flushFailed" : nil
                }),
            idleDebounceNanoseconds: 50_000_000)
    }

    private func makeOwner() -> OfficeAutosaveOwner {
        OfficeAutosaveOwner(
            documentID: documentID,
            isCurrent: { [weak self] in
                guard let self, !self.invalidated else { return false }
                return self.isCurrent
                    && FileManager.default.fileExists(atPath: self.draftURL.path)
            },
            hasPendingPromotion: { [weak self] in self?.pendingPromotion ?? true },
            markPendingPromotion: { [weak self] in self?.pendingPromotion = true },
            isContentDirty: { [weak self] in
                guard let self else { return true }
                if self.pendingPromotion { return true }
                do {
                    return try FloeDigest.sha256Hex(ofFileAt: self.workingURL) != self.lastSavedDigest
                } catch {
                    return true
                }
            },
            hasActivePen: { [weak self] in self?.penActive ?? true },
            flushEngine: { [weak self] in
                guard let self else { return false }
                if self.flushFailuresRemaining > 0 {
                    self.flushFailuresRemaining -= 1
                    return false
                }
                do {
                    if FileManager.default.fileExists(atPath: self.draftURL.path) {
                        try FileManager.default.removeItem(at: self.draftURL)
                    }
                    try FileManager.default.copyItem(at: self.workingURL, to: self.draftURL)
                    self.lastSavedDigest = try FloeDigest.sha256Hex(ofFileAt: self.draftURL)
                    self.flushCount += 1
                    return true
                } catch {
                    return false
                }
            },
            promote: { [weak self] in
                guard let self else {
                    return .failed(reason: "notes.ownerViewInactive", message: "Owner fixture is gone.")
                }
                if self.promoteGate {
                    self.promoteGate = false
                    self.promoteGateSuspended = true
                    await withCheckedContinuation { continuation in
                        self.gateContinuation = continuation
                    }
                    self.promoteGateSuspended = false
                }
                self.promoteCount += 1
                guard self.isCurrent, !self.invalidated else {
                    return .failed(reason: "notes.ownerViewInactive",
                                   message: "The owner view is no longer current; nothing was promoted.")
                }
                if !self.pendingPromotion {
                    do {
                        let receipt = try await OfficeNotesDraftPromotion.verifySavedNoop(
                            documentID: self.documentID, draftURL: self.draftURL,
                            resourceID: self.baselineResourceID, expectedRevision: self.baselineRevision,
                            session: self.session)
                        let outcome = OfficeNotesPromotionOutcome.alreadySaved(
                            revision: receipt.revision, resourceID: receipt.resourceID,
                            packageSHA256: receipt.resourceSHA256)
                        self.lastPromotionOutcome = outcome
                        return outcome
                    } catch OfficeNotesDraftPromotion.Failure.draftDiverged {
                        // The verified draft quietly differs: run the real
                        // promotion below instead of claiming a no-op.
                    } catch {
                        let outcome = OfficeNotesPromotionOutcome.verificationFailed(
                            reason: "notes.noopProofMissing", message: String(describing: error))
                        self.lastPromotionOutcome = outcome
                        return outcome
                    }
                }
                do {
                    let receipt = try await OfficeNotesDraftPromotion.promote(
                        documentID: self.documentID, draftURL: self.draftURL,
                        expectedResourceID: self.baselineResourceID, session: self.session,
                        packageDigest: self.digestSwitch.digest)
                    self.baselineResourceID = receipt.resourceID
                    self.baselineRevision = receipt.revision
                    self.pendingPromotion = false
                    let outcome = OfficeNotesPromotionOutcome.promoted(
                        revision: receipt.revision, resourceID: receipt.resourceID,
                        packageSHA256: receipt.resourceSHA256)
                    self.lastPromotionOutcome = outcome
                    return outcome
                } catch OfficeNotesDraftPromotion.Failure.postCommitProofUnavailable(let revision, let resourceID, let detail) {
                    self.baselineResourceID = resourceID
                    self.baselineRevision = revision
                    self.pendingPromotion = false
                    let outcome = OfficeNotesPromotionOutcome.verificationFailed(
                        reason: "notes.postCommitProofUnavailable", message: detail)
                    self.lastPromotionOutcome = outcome
                    return outcome
                } catch OfficeNotesDraftPromotion.Failure.resourceConflict {
                    let outcome = OfficeNotesPromotionOutcome.conflict(
                        message: "The Notes document no longer carries the expected Office resource; the newer revision was protected.")
                    self.lastPromotionOutcome = outcome
                    return outcome
                } catch OfficeNotesDraftPromotion.Failure.proofUnavailable(let detail) {
                    let outcome = OfficeNotesPromotionOutcome.verificationFailed(
                        reason: "notes.promotionProofUnavailable", message: detail)
                    self.lastPromotionOutcome = outcome
                    return outcome
                } catch {
                    let outcome = OfficeNotesPromotionOutcome.failed(
                        reason: "notes.commitFailed", message: String(describing: error))
                    self.lastPromotionOutcome = outcome
                    return outcome
                }
            },
            publishScheduledOutcome: { [weak self] proof in
                self?.observedProofs.append(proof)
            })
    }

    // MARK: - Stimulus (real byte transitions)

    /// A completed stroke: the engine's working copy now holds new real
    /// bytes, exactly like an accepted committed stroke.
    func completeStroke(_ marker: String) {
        rows.append([marker])
        rewriteWorkingCopy()
    }

    /// A keyboard edit posts the same accepted-content modified edge; the
    /// byte transition is identical (real working-copy bytes change).
    func typeKeyboardText(_ marker: String) {
        rows.append([marker])
        rewriteWorkingCopy()
    }

    private func rewriteWorkingCopy() {
        try? FileManager.default.removeItem(at: workingURL)
        try? OfficeDocumentBuilder.createWorkbook(at: workingURL, sheets: [
            .init(name: "Ink", rows: rows)
        ])
    }

    func replaceResourceExternally(marker: String) async throws {
        let external = root.appendingPathComponent("external-\(UUID().uuidString).xlsx")
        try OfficeDocumentBuilder.createWorkbook(at: external, sheets: [
            .init(name: "Ink", rows: rows + [[marker]])
        ])
        let resource = try await store.importResource(from: external, mediaType: "application/octet-stream")
        let current = try await store.document(documentID)
        _ = try await session.commit([.replaceOfficeResource(resource)],
                                     documentID: documentID, expectedRevision: current.revision)
        try? FileManager.default.removeItem(at: external)
    }

    func rebaselineToCurrentStoreState() async throws {
        let current = try await store.document(documentID)
        guard let resourceID = current.officeResourceID else { throw CocoaError(.coderInvalidValue) }
        baselineResourceID = resourceID
        baselineRevision = current.revision
    }

    // MARK: - Observation

    func storeRevision() async -> Int {
        let document = try? await store.document(documentID)
        return document?.revision ?? -1
    }

    func stageCount(_ name: String) -> Int {
        stages.reduce(0) { $0 + ($1.name == name ? 1 : 0) }
    }

    func waitForSaved(timeout: Duration = .seconds(5)) async throws {
        try await waitForCondition("autosave transaction saved", timeout: timeout) {
            self.stageCount("autosave.saved") >= 1
        }
    }

    func waitForProof(timeout: Duration = .seconds(5),
                      _ predicate: (OfficeSavedProof) -> Bool) async throws -> OfficeSavedProof {
        try await waitForCondition("expected autosave proof", timeout: timeout) {
            self.observedProofs.contains(where: predicate)
        }
        return observedProofs.first(where: predicate)!
    }

    func waitForCondition(_ message: @autoclosure () -> String,
                          timeout: Duration = .seconds(5),
                          condition: () async -> Bool) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now + timeout
        while await condition() == false {
            if clock.now >= deadline {
                XCTFail(message())
                throw CocoaError(.coderInvalidValue)
            }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
    }

    /// Reopen the REAL promoted package through the REAL read-only service
    /// and assert the accepted content survived the save transaction.
    func assertReopenedResourceContains(_ markers: [String]) async throws {
        let document = try await store.document(documentID)
        guard let resourceID = document.officeResourceID else { throw CocoaError(.coderInvalidValue) }
        let resource = try await store.resourceURL(resourceID)
        let reopened = root.appendingPathComponent("reopen-\(UUID().uuidString).xlsx")
        try FileManager.default.copyItem(at: resource, to: reopened)
        defer { try? FileManager.default.removeItem(at: reopened) }
        let snapshot = try OfficeDocumentService.inspect(url: reopened)
        let texts = snapshot.fields.map(\.text)
        for marker in markers {
            XCTAssertTrue(texts.contains(marker),
                          "Reopened package must retain \(marker); got \(texts)")
        }
    }

    // MARK: - Teardown

    func openPromoteGate() {
        gateContinuation?.resume()
        gateContinuation = nil
    }

    func dispose() {
        coordinator.invalidate()
        openPromoteGate()
        try? FileManager.default.removeItem(at: root)
    }
}
#endif
