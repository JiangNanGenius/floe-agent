import Foundation
import Observation
import XCTest
@testable import FloeCAD

/// Regression coverage for durable save identity publication, observation,
/// failure isolation and exact per-call receipts under competing completions.
@MainActor
final class CADSavedIdentityObservationTests: XCTestCase {
    private var directory: URL!
    private var documents: [FloeCADDocument] = []
    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("CADSavedIdentity-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }
    override func tearDown() async throws {
        CADDocumentFaultInjection.beforeCommit = nil
        for document in documents { document.close() }
        documents.removeAll()
        if let directory { try? FileManager.default.removeItem(at: directory) }
    }
    private func fixture() async throws -> FloeCADDocument {
        let doc = try await FloeCADDocument.create(at: directory.appendingPathComponent("\(UUID().uuidString).floecad"), name: "Identity")
        documents.append(doc)
        let node = FeatureNode(name: "Source", kind: .primitive(spec: .box(width: 40, depth: 30, height: 10),
            placement: .identity), outputBodyIDs: [BodyID()])
        doc.session.recordAndRebuild([node], title: "Source")
        let saved = await doc.save()
        XCTAssertTrue(saved.succeeded, saved.error ?? "")
        return doc
    }
    private func assertIdentity(_ doc: FloeCADDocument,
                                file: StaticString = #filePath, line: UInt = #line) async throws {
        let receipt = doc.session.savedIdentity
        let manifest = try CADAssociativeFormatFixture.manifest(doc.url)
        let stored = await FloeCADDocument.storedIdentity(at: doc.url)
        let disk = try XCTUnwrap(stored, file: file, line: line)
        XCTAssertEqual(doc.revision, manifest.revision, file: file, line: line)
        XCTAssertEqual(doc.contentSHA256, manifest.contentSHA256, file: file, line: line)
        XCTAssertEqual(receipt.revision, disk.revision, file: file, line: line)
        XCTAssertEqual(receipt.contentSHA256, disk.contentSHA256, file: file, line: line)
        XCTAssertEqual(receipt.modelSHA256, try XCTUnwrap(manifest.modelSHA256), file: file, line: line)
        XCTAssertEqual(receipt.modelSHA256, disk.modelSHA256, file: file, line: line)
        XCTAssertTrue(receipt.succeeded, file: file, line: line)
        let scene = doc.sceneSnapshot()
        XCTAssertEqual(scene.documentRevision, doc.revision, file: file, line: line)
        XCTAssertEqual(scene.contentSHA256, doc.contentSHA256, file: file, line: line)
        XCTAssertEqual(scene.modelSHA256, receipt.modelSHA256, file: file, line: line)
        XCTAssertEqual(doc.assistantSelectionContext().documentRevision, Int64(doc.revision), file: file, line: line)
    }

    func testActualNativeEditorSynchronousSavePublishesFacadeAndQueryIdentity() async throws {
        let doc = try await fixture()
        let before = doc.revision
        let callback = Counter()
        withObservationTracking { _ = doc.revision; _ = doc.contentSHA256 } onChange: { callback.increment() }
        // This real editor path routes through parameter service, then calls
        // Session.save directly; there is NO explicit facade save afterward.
        let name = doc.viewModel().createVariable(holding: "7", preferredName: "nativeGap")
        XCTAssertEqual(name, "nativeGap")
        XCTAssertNil(doc.viewModel().errorMessage)
        XCTAssertGreaterThan(doc.revision, before)
        XCTAssertEqual(callback.value, 1)
        XCTAssertFalse(doc.hasUnsavedChanges)
        let result = doc.nativeQueryJSON(["scope": "variables"])
        let query = try XCTUnwrap(JSONSerialization.jsonObject(with: result.payload) as? [String: Any])
        XCTAssertEqual(query["revision"] as? Int, doc.revision)
        try await assertIdentity(doc)
    }

    func testNativeAsyncSessionSavePublishesReceiptWithoutChangingGeometryGeneration() async throws {
        let doc = try await fixture()
        let before = doc.revision
        doc.session.perform(AddConstructionPlaneCommand(plane: ConstructionPlane(plane: .ground, size: 10)))
        let generation = doc.liveChangeCount
        XCTAssertTrue(doc.hasUnsavedChanges)
        let error = await doc.session.saveAsync()
        XCTAssertNil(error)
        XCTAssertGreaterThan(doc.revision, before)
        XCTAssertEqual(doc.liveChangeCount, generation)
        XCTAssertFalse(doc.hasUnsavedChanges)
        try await assertIdentity(doc)
    }

    func testRealDebouncedAutosaveNotifiesRevisionAndBindsDiskDigestWithoutFacadeSave() async throws {
        let doc = try await fixture()
        doc.session.perform(AddConstructionPlaneCommand(plane: ConstructionPlane(plane: .ground, size: 11)))
        let generation = doc.liveChangeCount
        let before = doc.revision
        let saved = XCTestExpectation(description: "actual debounced Session autosave publishes durable revision")
        withObservationTracking { _ = doc.revision } onChange: { saved.fulfill() }
        // Wait for the actual existing debounce save event; no sleep/yield or
        // direct save/SceneStore refresh is used to manufacture notification.
        await fulfillment(of: [saved], timeout: 10)
        XCTAssertGreaterThan(doc.revision, before)
        XCTAssertEqual(doc.liveChangeCount, generation)
        XCTAssertFalse(doc.hasUnsavedChanges)
        try await assertIdentity(doc)
    }

    func testExplicitCleanSaveOnlyRevisionIsAnObservableDependency() async throws {
        let doc = try await fixture()
        let before = doc.revision
        let generation = doc.liveChangeCount
        let marker = doc.session.persistenceChangeCount
        let modelSHA = doc.session.savedIdentity.modelSHA256
        let notified = XCTestExpectation(description: "save-only revision observable without any view refresh")
        withObservationTracking { _ = doc.revision } onChange: { notified.fulfill() }
        let saved = await doc.save()
        XCTAssertTrue(saved.succeeded, saved.error ?? "")
        await fulfillment(of: [notified], timeout: 10)
        XCTAssertGreaterThan(doc.revision, before)
        XCTAssertEqual(doc.liveChangeCount, generation)
        XCTAssertEqual(doc.session.persistenceChangeCount, marker)
        XCTAssertEqual(doc.session.savedIdentity.modelSHA256, modelSHA, "clean path must preserve opaque model bytes")
        XCTAssertFalse(doc.hasUnsavedChanges)
        try await assertIdentity(doc)
    }

    func testFailedNativeSaveDoesNotPublishSuccessIdentityOrRevisionEvent() async throws {
        let doc = try await fixture()
        let before = doc.session.savedIdentity
        let oldMarker = doc.session.persistenceChangeCount
        doc.session.perform(AddConstructionPlaneCommand(plane: ConstructionPlane(plane: .ground, size: 12)))
        let counter = Counter()
        withObservationTracking { _ = doc.revision; _ = doc.contentSHA256 } onChange: { counter.increment() }
        CADDocumentFaultInjection.beforeCommit = {
            throw NSError(domain: "CADIdentity", code: 1, userInfo: [NSLocalizedDescriptionKey: "Synthetic commit failure"])
        }
        let error = await doc.session.saveAsync()
        CADDocumentFaultInjection.beforeCommit = nil
        XCTAssertNotNil(error)
        XCTAssertEqual(doc.session.savedIdentity, before)
        XCTAssertEqual(counter.value, 0, "Observation on receipt is synchronous; failed save must not set it")
        let ioError = doc.session.lastSaveError
        XCTAssertFalse(doc.session.adoptCommittedIdentity(before, persistenceCount: oldMarker))
        XCTAssertEqual(doc.session.lastSaveError, ioError, "old equal-revision success cannot erase the newer failure")
        XCTAssertTrue(doc.hasUnsavedChanges)
        let manifest = try CADAssociativeFormatFixture.manifest(doc.url)
        XCTAssertEqual(manifest.revision, before.revision)
        XCTAssertEqual(manifest.contentSHA256, before.contentSHA256)
        let retried = await doc.session.saveAsync()
        XCTAssertNil(retried)
        XCTAssertGreaterThan(doc.revision, before.revision)
        try await assertIdentity(doc)
    }

    func testStaleCASDoesNotPublishForeignOrFailedIdentityAsThisSessionSuccess() async throws {
        let doc = try await fixture()
        let before = doc.session.savedIdentity
        let foreign = FileCADDocumentStore(packageURL: doc.url)
        let project = try foreign.read()
        project.name = "External committed metadata"
        try foreign.write(project)
        XCTAssertGreaterThan(foreign.revision, before.revision)
        doc.session.perform(AddConstructionPlaneCommand(plane: ConstructionPlane(plane: .ground, size: 13)))
        let counter = Counter()
        withObservationTracking { _ = doc.revision; _ = doc.contentSHA256 } onChange: { counter.increment() }
        let failed = await doc.save()
        XCTAssertFalse(failed.succeeded)
        XCTAssertEqual(doc.session.savedIdentity, before)
        XCTAssertEqual(failed.revision, before.revision)
        XCTAssertEqual(failed.contentSHA256, before.contentSHA256)
        XCTAssertEqual(counter.value, 0)
        XCTAssertTrue(doc.hasUnsavedChanges)
        XCTAssertEqual(try CADAssociativeFormatFixture.manifest(doc.url).revision, foreign.revision)
    }

    func testOlderActualSuccessfulReceiptCannotDowngradeIdentityOrDirtyAcknowledgement() async throws {
        let doc = try await fixture()
        let older = doc.session.savedIdentity
        let oldMarker = doc.session.persistenceChangeCount
        doc.session.perform(AddConstructionPlaneCommand(plane: ConstructionPlane(plane: .ground, size: 14)))
        let savedError = await doc.session.saveAsync()
        XCTAssertNil(savedError)
        let current = doc.session.savedIdentity
        XCTAssertGreaterThan(current.revision, older.revision)
        XCTAssertFalse(doc.hasUnsavedChanges)
        let counter = Counter()
        withObservationTracking { _ = doc.revision } onChange: { counter.increment() }
        // Simulates delayed delivery using a real earlier successful receipt,
        // not fabricated revision/hash data or a separate identity store.
        XCTAssertFalse(doc.session.adoptCommittedIdentity(older, persistenceCount: oldMarker))
        XCTAssertEqual(doc.session.savedIdentity, current)
        XCTAssertFalse(doc.hasUnsavedChanges)
        XCTAssertEqual(counter.value, 0)
        try await assertIdentity(doc)
    }

    func testFileReceiptIsAtomicAndLegacyGenericTupleProtocolRemainsUsable() async throws {
        let url = directory.appendingPathComponent("receipt.floecad")
        let initial = FileCADDocumentStore(packageURL: url)
        let seed = try initial.makePayload(Project(name: "Receipt"))
        try FileCADDocumentStore.createPackage(at: url, payload: seed, overwrite: false)
        let store = FileCADDocumentStore(packageURL: url)
        let project = try store.read()
        project.name = "A"
        let first = try store.performWriteWithIdentity(store.makePayload(project))
        let firstManifest = try CADAssociativeFormatFixture.manifest(url)
        XCTAssertEqual(first.revision, firstManifest.revision)
        XCTAssertEqual(first.contentSHA256, firstManifest.contentSHA256)
        XCTAssertEqual(first.modelSHA256, try XCTUnwrap(firstManifest.modelSHA256))
        project.name = "B"
        let second = try store.performWriteWithIdentity(store.makePayload(project))
        XCTAssertGreaterThan(second.revision, first.revision)
        XCTAssertEqual(store.committedIdentity, second)
        XCTAssertEqual(first.modelSHA256, firstManifest.modelSHA256, "earlier receipt stays bound to its own payload")
        let generic: any CADDocumentStore = store
        project.name = "Legacy tuple path"
        let legacy: (revision: Int, contentSHA256: String) = try generic.performWrite(store.makePayload(project))
        XCTAssertEqual(legacy.revision, second.revision + 1)
        XCTAssertEqual(legacy.contentSHA256, store.committedIdentity.contentSHA256)
    }
    func testTwoRealCommitsKeepExactPerCallOutcomeWhenOlderDeliveryArrivesLast() async throws {
        let doc = try await fixture()
        let firstRevision = doc.revision + 1
        doc.session.perform(AddConstructionPlaneCommand(plane: ConstructionPlane(plane: .ground, size: 21)))
        let gate = ReceiptDeliveryGate()
        doc.session.committedIdentityDeliveryForTesting = { receipt in await gate.holdFirst(receipt) }
        defer { gate.release(); doc.session.committedIdentityDeliveryForTesting = nil }
        let firstSave = Task { await doc.save() }
        let entered = await gate.waitUntilEntered()
        XCTAssertTrue(entered)
        guard entered else { gate.release(); _ = await firstSave.value; return }
        let actualFirstReceipt = try XCTUnwrap(gate.firstReceipt)
        XCTAssertEqual(actualFirstReceipt.revision, firstRevision)
        let firstDisk = try CADAssociativeFormatFixture.manifest(doc.url)
        XCTAssertEqual(actualFirstReceipt.contentSHA256, firstDisk.contentSHA256)
        XCTAssertEqual(actualFirstReceipt.modelSHA256, try XCTUnwrap(firstDisk.modelSHA256))
        // A has really committed, but its Session receipt is deliberately not
        // delivered. B must prepare at the existing store CAS revision, commit
        // and publish before A resumes. No fake hashes or guessed timing.
        doc.session.perform(AddConstructionPlaneCommand(plane: ConstructionPlane(plane: .ground, size: 22)))
        let secondReceipt = await doc.save()
        XCTAssertTrue(secondReceipt.succeeded, secondReceipt.error ?? "")
        XCTAssertEqual(secondReceipt.revision, firstRevision + 1)
        XCTAssertEqual(doc.session.savedIdentity, secondReceipt)
        XCTAssertFalse(doc.hasUnsavedChanges)
        gate.release()
        let deliveredFirst = await firstSave.value
        XCTAssertEqual(deliveredFirst, actualFirstReceipt, "facade must return A's own successful receipt, not shared B")
        XCTAssertEqual(doc.session.savedIdentity, secondReceipt, "late A cannot downgrade B or dirty acknowledgement")
        XCTAssertEqual(doc.revision, secondReceipt.revision)
        XCTAssertFalse(doc.hasUnsavedChanges)
        XCTAssertFalse(gate.timedOut)
        try await assertIdentity(doc)
    }

}

private nonisolated final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func increment() { lock.withLock { count += 1 } }
    var value: Int { lock.withLock { count } }
}


@MainActor
private final class ReceiptDeliveryGate {
    private(set) var firstReceipt: CADSaveOutcome?
    private(set) var timedOut = false
    private var enteredWaiters: [CheckedContinuation<Bool, Never>] = []
    private var released = false
    private var releaseWaiter: CheckedContinuation<Void, Never>?
    func holdFirst(_ receipt: CADSaveOutcome) async {
        guard firstReceipt == nil else { return }
        firstReceipt = receipt
        let waiters = enteredWaiters; enteredWaiters.removeAll()
        waiters.forEach { $0.resume(returning: true) }
        guard !released else { return }
        let timeout = Task { [weak self] in
            try? await Task.sleep(for: .seconds(10))
            guard !Task.isCancelled, let self, !self.released else { return }
            self.timedOut = true; self.release()
        }
        await withCheckedContinuation { releaseWaiter = $0 }
        timeout.cancel()
    }
    func waitUntilEntered() async -> Bool {
        if firstReceipt != nil { return true }
        let timeout = Task { [weak self] in
            try? await Task.sleep(for: .seconds(10))
            guard !Task.isCancelled, let self, self.firstReceipt == nil else { return }
            self.timedOut = true
            let waiters = self.enteredWaiters; self.enteredWaiters.removeAll()
            waiters.forEach { $0.resume(returning: false) }; self.release()
        }
        let result = await withCheckedContinuation { enteredWaiters.append($0) }
        timeout.cancel(); return result
    }
    func release() { released = true; releaseWaiter?.resume(); releaseWaiter = nil }
}
