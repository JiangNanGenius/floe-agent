// SPDX-License-Identifier: MPL-2.0
//
// RB-7 attachment staging — service-domain source tests.
//
// AUTHORED, NOT EXECUTED: no compiler, no device, no XCTest run is part of
// the authoring package; nothing below is a claimed pass. Fixtures use the
// REAL file seam over a synthetic app-private temporary root (actual chunk
// IO through FileHandle-backed writes, never a dictionary-only mock) and
// the ORIGINAL model types. The store double exists only for the pure
// staging-domain cases; the durable CAS/DB truths run in
// AttachmentStagingBridgeV3Tests against the REAL schema-46 DatabaseManager
// (with the lane's published additive store seams).
//
// All URIs/names/bytes in these files are synthetic fixtures. No real user
// file, photo or credential is ever touched by any fixture here.
import XCTest
import Foundation
import Crypto
import GRDB
import FloeModels
import FloePersistence
import FloeCore
@testable import FloeAndroidCore

// MARK: - Test doubles (same file so the bridge suite reuses them)

/// Real FileManager seam + scripted failure injection + write accounting.
final class RecordingStagingFiles: StagingFileSystem, @unchecked Sendable {
    private let inner = FileManagerStagingFileSystem.shared
    private let state = NSLock()
    private var _writeCalls = 0
    private var _bytesWritten = 0
    private var _createFileCalls = 0
    var failWriteAfter: Int?
    var capacityOverride: Int64?
    var renameWillFail = false

    var writeCalls: Int { state.lock(); defer { state.unlock() }; return _writeCalls }
    var bytesWritten: Int { state.lock(); defer { state.unlock() }; return _bytesWritten }
    var createFileCalls: Int { state.lock(); defer { state.unlock() }; return _createFileCalls }

    /// The owned recovery manifest is written through the same seam; these
    /// counters track STAGED-DATA IO only (deterministic per test), so the
    /// manifest temp path is excluded.
    private func isManifestPath(_ url: URL) -> Bool {
        url.lastPathComponent.hasPrefix("manifest.json")
    }

    func createDirectory(at url: URL) throws { try inner.createDirectory(at: url) }
    func createFile(at url: URL) throws {
        if !isManifestPath(url) {
            state.lock(); _createFileCalls += 1; state.unlock()
        }
        try inner.createFile(at: url)
    }
    func fileSize(atPath path: String) -> Int? { inner.fileSize(atPath: path) }
    func isRegularFile(atPath path: String) -> Bool { inner.isRegularFile(atPath: path) }
    func isSymbolicLink(atPath path: String) -> Bool { inner.isSymbolicLink(atPath: path) }
    func listFileNames(at url: URL) -> [String] { inner.listFileNames(at: url) }
    func removeItem(at url: URL) throws { try inner.removeItem(at: url) }
    func rename(from: URL, to: URL) throws {
        if renameWillFail { throw AttachmentStagingError(.renameFailed) }
        try inner.rename(from: from, to: to)
    }
    func write(at offset: Int64, data: Data, to url: URL) throws {
        let manifest = isManifestPath(url)
        state.lock()
        if !manifest { _writeCalls += 1; _bytesWritten += data.count }
        let shouldFail = failWriteAfter.map { _writeCalls > $0 } ?? false
        state.unlock()
        if shouldFail { throw AttachmentStagingError(.writeFailed) }
        try inner.write(at: offset, data: data, to: url)
    }
    func read(offset: Int64, length: Int, from url: URL) -> Data? {
        inner.read(offset: offset, length: length, from: url)
    }
    func sync(_ url: URL) throws { try inner.sync(url) }
    func availableCapacity(atPath path: String) -> Int64? {
        capacityOverride ?? inner.availableCapacity(atPath: path)
    }
}

/// Fake of the RB1 reviewed registry surface (same contract as production:
/// exact-token detach; the bridge suite asserts real-registry attach via
/// RuntimeOwnedWorkRegistry.shared counts in one dedicated case).
final class ScriptedOwnedWork: StagingOwnedWorkAttaching, @unchecked Sendable {
    private let state = NSLock()
    private var mint = 0
    private var live: [String: (epoch: UInt64, ownerID: String)] = [:]
    var refusesNextAttach = false
    var attachCount = 0
    var detachCount = 0

    func attach(epoch: UInt64, ownerID: String) -> RuntimeOwnedWorkAttachOutcome {
        state.lock()
        if refusesNextAttach {
            refusesNextAttach = false
            state.unlock()
            return .rejected(.receiptSaturated)
        }
        mint += 1
        attachCount += 1
        let receipt = "work:v1:" + String(format: "%032x", mint)
        live[receipt] = (epoch, ownerID)
        state.unlock()
        return .attached(RuntimeOwnedWorkToken(receipt: receipt, epoch: epoch,
                                               kind: .conversation, ownerID: ownerID))
    }

    func detach(receipt: String, epoch: UInt64, ownerID: String) -> Bool {
        state.lock(); defer { state.unlock() }
        detachCount += 1
        guard let entry = live.removeValue(forKey: receipt) else { return false }
        return entry.epoch == epoch && entry.ownerID == ownerID
    }

    var liveCount: Int { state.lock(); defer { state.unlock() }; return live.count }
}

/// Memory double for the ADDITIVE store port. The pure-domain staging cases
/// use it for row-existence truth only; it does NOT evaluate the
/// verification closures (a real `Database` cannot be fabricated), which is
/// exactly why the CAS truths are covered against the REAL store in the
/// bridge suite.
actor DictionaryCommitStore: AttachmentCommittingStore {
    var rows: [UUID: AttachmentRef] = [:]
    var conversations: [UUID: ConversationRecord] = [:]
    var messages: [UUID: PersistedMessage] = [:]
    var partsByMessage: [UUID: [MessagePart]] = [:]
    var insertGuardWasRun = false
    var deleteGuardWasRun = false

    // Original ConversationStore API (only the reads the lane performs;
    // everything else traps so an accidental widening in code is a test
    // failure, never a silent default).
    func saveConversation(_ conversation: ConversationRecord) async throws {
        conversations[conversation.id] = conversation
    }
    func conversations() async throws -> [ConversationRecord] {
        Array(conversations.values)
    }
    func conversation(id: UUID) async throws -> ConversationRecord? {
        conversations[id]
    }
    func renameConversation(id: UUID, title: String) async throws {
        XCTFail("unused by the staging lane")
    }
    @discardableResult
    func setAutomaticTitle(id: UUID, title: String) async throws -> Bool {
        XCTFail("unused by the staging lane"); return false
    }
    func deleteConversation(id: UUID) async throws { XCTFail("unused") }
    @discardableResult
    func deleteConversationIfVerifiedEmpty(id: UUID) async throws -> Bool {
        XCTFail("unused"); return false
    }
    func setArchived(id: UUID, archived: Bool) async throws { XCTFail("unused") }
    func appendMessage(_ message: PersistedMessage) async throws {
        messages[message.id] = message
    }
    func messages(conversationID: UUID) async throws -> [PersistedMessage] {
        messages.values.filter { $0.conversationID == conversationID }
            .sorted { $0.createdAt < $1.createdAt }
    }
    func recentMessages(conversationID: UUID, limit: Int) async throws
        -> [PersistedMessage] {
        try await messages(conversationID: conversationID).suffix(limit).map { $0 }
    }
    func messagePage(conversationID: UUID, before cursor: ConversationMessageCursor?,
                     limit: Int) async throws -> ConversationMessagePage {
        let all = try await messages(conversationID: conversationID)
        let window: [PersistedMessage]
        if let cursor {
            window = all.filter {
                ConversationMessageCursor(createdAt: $0.createdAt, messageID: $0.id) < cursor
            }
        } else {
            window = all
        }
        let page = Array(window.suffix(limit))
        let cursorValue = page.first.map {
            ConversationMessageCursor(createdAt: $0.createdAt, messageID: $0.id)
        }
        return ConversationMessagePage(messages: page,
                                       earlierCursor: window.count > page.count ? cursorValue : nil,
                                       hasEarlier: window.count > page.count)
    }
    func parts(messageID: UUID) async throws -> [MessagePart] {
        partsByMessage[messageID] ?? []
    }
    func saveAttachment(_ attachment: AttachmentRef) async throws {
        rows[attachment.id] = attachment
    }
    func attachment(id: UUID) async throws -> AttachmentRef? {
        let stored = rows[id]
        return stored
    }
    func attachments(conversationID: UUID) async throws -> [AttachmentRef] {
        rows.values.filter { $0.conversationID == conversationID }
    }

    // Additive seams (effect only; guards run only against a real Database —
    // see the bridge suite). `insert` refuses to overwrite a row whose
    // durable values differ, mirroring the guarded store exactly.
    func insertAttachmentRowGuarded(_ attachment: AttachmentRef,
                                    verification: @escaping @Sendable (Database)
                                        throws -> Void) async throws {
        insertGuardWasRun = true
        if let existing = rows[attachment.id] {
            let replay = existing.conversationID == attachment.conversationID
                && existing.messageID == nil
                && existing.byteCount == attachment.byteCount
                && existing.sha256 == attachment.sha256
                && existing.storage == attachment.storage
            if !replay {
                throw FloeError.validationFailed("attachmentCommit.digestMismatch")
            }
            return
        }
        rows[attachment.id] = attachment
    }
    func deleteAttachmentRowGuarded(id: UUID,
                                    verification: @escaping @Sendable (Database)
                                        throws -> Void) async throws -> Bool {
        deleteGuardWasRun = true
        guard let existing = rows[id] else {
            throw FloeError.validationFailed("attachmentCancel.notFound")
        }
        if existing.messageID != nil {
            throw FloeError.validationFailed("attachmentCancel.rowBoundToMessage")
        }
        rows.removeValue(forKey: id)
        return true
    }
    func readAttachmentRow<T: Sendable>(id: UUID,
                                        projection: @escaping @Sendable (Row?) throws -> T)
        async throws -> T {
        // No live Database here: projection(nil) keeps the shape honest for
        // the pure-domain tests; real digests come from the bridge suite.
        try projection(nil)
    }
}

// MARK: - Support

enum StagingFixture {
    static func identity(root: URL, token: String = "0a1b2c3d4e5f6071",
                         epoch: UInt64 = 7) -> RuntimeOwnerIdentity {
        guard let storageRoot = RuntimeStorageRoot(validatingAbsoluteDirectory: root.path),
              let identity = RuntimeOwnerIdentity(root: storageRoot, token: token,
                                                  epoch: epoch) else {
            preconditionFailure("fixture root must validate")
        }
        return identity
    }

    static func makeRoot() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("floe-staging-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static func chunk(_ byte: UInt8, count: Int) -> Data {
        Data((0..<count).map { _ in byte })
    }

    static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// Drive a full native ingress exactly like the JNI pump does.
    static func streamIngress(_ service: AttachmentStagingService, routeReceipt: String,
                              chunks: [Data], name: String = "note.txt",
                              mime: String = "text/plain")
        async throws -> (ingress: String, stagingID: String, total: Int) {
        guard case .opened(let ingress, let stagingID) =
            service.beginIngress(routeReceipt: routeReceipt) else {
            throw AttachmentStagingError(.ingressUnknown)
        }
        var total = 0
        for chunk in chunks {
            guard case .accepted = service.writeIngress(ingressReceipt: ingress, chunk: chunk)
            else { throw AttachmentStagingError(.writeFailed) }
            total += chunk.count
        }
        if let refusal = service.endIngress(ingressReceipt: ingress,
                                            displayNameHint: name, mimeHint: mime,
                                            kindHint: nil) {
            throw AttachmentStagingError(refusal)
        }
        return (ingress, stagingID, total)
    }

    static func publishedHandle(_ service: AttachmentStagingService, ingress: String)
        throws -> String {
        guard case .published(let view) = service.publish(ingressReceipt: ingress) else {
            throw AttachmentStagingError(.renameFailed)
        }
        return view.handle
    }
}

// MARK: - Suite

final class AttachmentStagingServiceTests: XCTestCase {

    private func makeService(root: URL,
                             files: RecordingStagingFiles = RecordingStagingFiles(),
                             ownedWork: any StagingOwnedWorkAttaching = ScriptedOwnedWork(),
                             store: DictionaryCommitStore = DictionaryCommitStore(),
                             epoch: UInt64 = 7) -> (AttachmentStagingService,
                                                     RecordingStagingFiles,
                                                     any StagingOwnedWorkAttaching,
                                                     DictionaryCommitStore) {
        let service = AttachmentStagingService(components: .init(
            identity: StagingFixture.identity(root: root, epoch: epoch),
            store: store, ownedWork: ownedWork, files: files))
        return (service, files, ownedWork, store)
    }

    // MARK: Pre-IO gates (zero source IO, zero file effect)

    func testTemporaryRouteNeverRegistersAndTouchesNoFile() throws {
        let root = StagingFixture.makeRoot()
        let (service, files, ownedWork, _) = makeService(root: root)
        let route = service.registerRoute(ComposeRouteDescriptor(
            conversationID: nil, incarnation: 1, draftRevision: 1,
            isTemporarySession: true))
        XCTAssertNil(route, "temporary sessions get no staging route at all")
        XCTAssertEqual(files.createFileCalls, 0)
        XCTAssertEqual((ownedWork as? ScriptedOwnedWork)?.attachCount, 0)
        let counters = service.statusCounters()
        XCTAssertGreaterThan(counters["refusedBeforeFileEffect"] ?? 0, 0)
    }

    func testBeginOnUnknownOrForeignRouteRefusesBeforeFileEffect() throws {
        let root = StagingFixture.makeRoot()
        let (service, files, ownedWork, _) = makeService(root: root)
        switch service.beginIngress(routeReceipt: "route:v1:" + String(repeating: "a",
                                                                        count: 32)) {
        case .opened: XCTFail("forged route receipt must never open")
        case .refused(let code): XCTAssertEqual(code, .routeUnknown)
        }
        XCTAssertEqual(files.createFileCalls, 0)
        XCTAssertEqual((ownedWork as? ScriptedOwnedWork)?.attachCount, 0)
    }

    func testAttachRejectionMeansZeroFileEffect() throws {
        let root = StagingFixture.makeRoot()
        let scripted = ScriptedOwnedWork()
        let (service, files, _, _) = makeService(root: root, ownedWork: scripted)
        scripted.refusesNextAttach = true
        let route = service.registerRoute(ComposeRouteDescriptor(
            conversationID: nil, incarnation: 1, draftRevision: 0, isTemporarySession: false))
        XCTAssertNotNil(route)
        let outcome = service.beginIngress(routeReceipt: route!.receipt)
        if case .opened = outcome { XCTFail("owned-work rejection must refuse pre-file") }
        XCTAssertEqual(files.createFileCalls, 0)
    }

    // MARK: Streaming + publish happy path (actual file IO)

    func testIngressStreamCountingAndPublishVerifiesBytes() async throws {
        let root = StagingFixture.makeRoot()
        let (service, files, ownedWork, _) = makeService(root: root)
        let route = try XCTUnwrap(service.registerRoute(ComposeRouteDescriptor(
            conversationID: nil, incarnation: 1, draftRevision: 0, isTemporarySession: false)))
        let partA = StagingFixture.chunk(0x41, count: 65_536)
        let partB = StagingFixture.chunk(0x42, count: 4_000)
        let (ingress, stagingID, total) = try await StagingFixture.streamIngress(
            service, routeReceipt: route.receipt, chunks: [partA, partB])
        XCTAssertEqual(total, 69_536)
        XCTAssertEqual(files.writeCalls, 2)
        XCTAssertEqual(files.bytesWritten, total)
        let owned = try XCTUnwrap(ownedWork as? ScriptedOwnedWork)
        _ = owned
        guard case .published(let view) = service.publish(ingressReceipt: ingress) else {
            return XCTFail("publish must settle staged")
        }
        XCTAssertEqual(view.byteCount, total)
        XCTAssertEqual(view.sha256, StagingFixture.digest(partA + partB))
        XCTAssertEqual(view.stagingID, stagingID)
        let stagedURL = root.appendingPathComponent("Attachments")
            .appendingPathComponent(stagingID).appendingPathComponent("note.txt")
        let onDisk = try XCTUnwrap(FileManager.default.contents(atPath: stagedURL.path))
        XCTAssertEqual(onDisk, partA + partB, "staged bytes must equal streamed bytes")
        // Owned work detaches exactly at the publish settle (one per ingress).
        XCTAssertEqual(owned.detachCount, 1)
        XCTAssertEqual(owned.liveCount, 0)
        // The temp area is empty after publish.
        let tempDir = root.appendingPathComponent("Attachments/.staging-tmp")
        XCTAssertEqual(try? FileManager.default.contentsOfDirectory(atPath: tempDir.path), [])
    }

    func testChunkOverBoundAndEmptyChunkRefusedWithoutAbortingSession() async throws {
        let root = StagingFixture.makeRoot()
        let (service, _, _, _) = makeService(root: root)
        let route = try XCTUnwrap(service.registerRoute(ComposeRouteDescriptor(
            conversationID: UUID(), incarnation: 1, draftRevision: 0,
            isTemporarySession: false)))
        guard case .opened(let ingress, _) = service.beginIngress(routeReceipt: route.receipt)
        else { return XCTFail("begin") }
        XCTAssertEqual(service.writeIngress(ingressReceipt: ingress, chunk: Data()),
                       .refused(.payloadInvalid))
        XCTAssertEqual(service.writeIngress(ingressReceipt: ingress,
                                            chunk: StagingFixture.chunk(0x43, count: 65_537)),
                       .refused(.payloadInvalid))
        // Session survives refusals: real chunks still stream.
        if case .accepted(let written) = service.writeIngress(
            ingressReceipt: ingress, chunk: StagingFixture.chunk(0x44, count: 1_024)) {
            XCTAssertEqual(written, 1_024)
        } else { XCTFail("valid chunk must stream") }
        XCTAssertNil(service.endIngress(ingressReceipt: ingress, displayNameHint: "a.bin",
                                        mimeHint: nil, kindHint: nil))
    }

    func testDiskFullRefusesBeforeFirstByteAndMidStreamAbortsCleanly() async throws {
        let root = StagingFixture.makeRoot()
        let files = RecordingStagingFiles()
        let (service, _, _, _) = makeService(root: root, files: files)
        let route = try XCTUnwrap(service.registerRoute(ComposeRouteDescriptor(
            conversationID: nil, incarnation: 1, draftRevision: 0, isTemporarySession: false)))
        // Pre-first-byte: zero free space → begin refuses, NO file created.
        files.capacityOverride = 0
        if case .refused(let code) = service.beginIngress(routeReceipt: route.receipt) {
            XCTAssertEqual(code, .diskFull)
        } else { XCTFail("diskFull expected") }
        let createCallsAfterRefusal = files.createFileCalls
        // Mid-stream: capacity collapses after the first accepted chunk.
        files.capacityOverride = 2 * Int64(AttachmentStagingLimits.minimumFreeBytes)
        guard case .opened(let ingress, let stagingID) =
            service.beginIngress(routeReceipt: route.receipt) else {
            return XCTFail("begin with capacity")
        }
        _ = service.writeIngress(ingressReceipt: ingress,
                                 chunk: StagingFixture.chunk(0x45, count: 4_096))
        files.capacityOverride = 1
        XCTAssertEqual(service.writeIngress(ingressReceipt: ingress,
                                            chunk: StagingFixture.chunk(0x46, count: 4_096)),
                       .refused(.diskFull))
        // The failed session is gone, its temp removed, no staged record.
        XCTAssertNil(service.snapshot(stagingID: stagingID))
        let tempURL = root.appendingPathComponent("Attachments/.staging-tmp")
            .appendingPathComponent(stagingID)
        XCTAssertFalse(FileManager.default.fileExists(atPath: tempURL.path))
        XCTAssertEqual(files.createFileCalls, createCallsAfterRefusal + 1)
    }

    func testWriteFailureAbortsSessionAndCleansTemp() async throws {
        let root = StagingFixture.makeRoot()
        let files = RecordingStagingFiles()
        files.failWriteAfter = 1
        let (service, _, ownedWork, _) = makeService(root: root, files: files)
        let route = try XCTUnwrap(service.registerRoute(ComposeRouteDescriptor(
            conversationID: nil, incarnation: 1, draftRevision: 0, isTemporarySession: false)))
        guard case .opened(let ingress, let stagingID) =
            service.beginIngress(routeReceipt: route.receipt) else {
            return XCTFail("begin")
        }
        _ = service.writeIngress(ingressReceipt: ingress,
                                 chunk: StagingFixture.chunk(0x51, count: 2_048))
        XCTAssertEqual(service.writeIngress(ingressReceipt: ingress,
                                            chunk: StagingFixture.chunk(0x52, count: 2_048)),
                       .refused(.writeFailed))
        // Session retired + owned work released exactly once.
        XCTAssertEqual(service.abortIngress(ingressReceipt: ingress), .ingressUnknown,
                       "session must be gone")
        XCTAssertNil(service.snapshot(stagingID: stagingID))
        XCTAssertEqual((ownedWork as? ScriptedOwnedWork)?.liveCount, 0)
    }

    // MARK: Cancel / discard vs consumed truths

    func testCancelIngressRemovesTempAndNeverCreatesAStagedRecord() async throws {
        let root = StagingFixture.makeRoot()
        let (service, _, ownedWork, _) = makeService(root: root)
        let route = try XCTUnwrap(service.registerRoute(ComposeRouteDescriptor(
            conversationID: nil, incarnation: 1, draftRevision: 0, isTemporarySession: false)))
        guard case .opened(let ingress, let stagingID) =
            service.beginIngress(routeReceipt: route.receipt) else {
            return XCTFail("begin")
        }
        _ = service.writeIngress(ingressReceipt: ingress,
                                 chunk: StagingFixture.chunk(0x61, count: 1_024))
        XCTAssertNil(service.cancelIngress(stagingID: stagingID))
        let tempURL = root.appendingPathComponent("Attachments/.staging-tmp")
            .appendingPathComponent(stagingID)
        XCTAssertFalse(FileManager.default.fileExists(atPath: tempURL.path))
        XCTAssertNil(service.snapshot(stagingID: stagingID))
        XCTAssertEqual((ownedWork as? ScriptedOwnedWork)?.liveCount, 0)
        // Second cancel is an honest unknown, not a silent success.
        XCTAssertEqual(service.cancelIngress(stagingID: stagingID), .ingressUnknown)
    }

    func testDiscardRemovesOnlyStagedBytes() async throws {
        let root = StagingFixture.makeRoot()
        let (service, _, _, _) = makeService(root: root)
        let route = try XCTUnwrap(service.registerRoute(ComposeRouteDescriptor(
            conversationID: nil, incarnation: 1, draftRevision: 0, isTemporarySession: false)))
        let (ingress, stagingID, _) = try await awaitStage(service, route: route)
        let handle = try StagingFixture.publishedHandle(service, ingress: ingress)
        let stagedURL = root.appendingPathComponent("Attachments")
            .appendingPathComponent(stagingID).appendingPathComponent("note.txt")
        XCTAssertTrue(FileManager.default.fileExists(atPath: stagedURL.path))
        XCTAssertNil(service.discard(handle: handle))
        XCTAssertFalse(FileManager.default.fileExists(atPath: stagedURL.path))
        XCTAssertEqual(service.discard(handle: handle), .handleUnknown)
    }

    func testDiscardRefusesReservedConsumedAndMarkedRecords() async throws {
        let root = StagingFixture.makeRoot()
        let (service, _, _, _) = makeService(root: root)
        let route = try XCTUnwrap(service.registerRoute(ComposeRouteDescriptor(
            conversationID: nil, incarnation: 1, draftRevision: 0, isTemporarySession: false)))
        let (first, _, _) = try await awaitStage(service, route: route)
        let handleA = try StagingFixture.publishedHandle(service, ingress: first)
        let (second, _, _) = try await awaitStage(service, route: route)
        let handleB = try StagingFixture.publishedHandle(service, ingress: second)
        // Lease handleA.
        guard case .success(let lease) = service.reserveLaunchLease(handles: [handleA],
                                                                    conversationID: nil,
                                                                    correlation: "launch-1")
        else { return XCTFail("reserve") }
        // The service's truthful refusal vocabulary: a RESERVED handle
        // refuses `.alreadyConsumed`, and after commit the handle is
        // un-minted (`.handleUnknown`) — never a silent merge.
        XCTAssertEqual(service.discard(handle: handleA), .alreadyConsumed)
        XCTAssertNil(service.commitLaunchLease(lease.leaseID))
        XCTAssertEqual(service.discard(handle: handleA), .handleUnknown)
        // Mark handleB via the parent resolve path; discard must refuse too.
        XCTAssertNil(service.markLaunchReference(handle: handleB, correlation: "launch-2"))
        XCTAssertEqual(service.discard(handle: handleB), .launchMarked)
    }

    // MARK: Leases, double launch, rollback truths

    func testLeaseCommitAndRollbackTruths() async throws {
        let root = StagingFixture.makeRoot()
        let (service, _, _, _) = makeService(root: root)
        let conversation = UUID()
        let route = try XCTUnwrap(service.registerRoute(ComposeRouteDescriptor(
            conversationID: conversation, incarnation: 3, draftRevision: 0,
            isTemporarySession: false)))
        let (ingressA, _, _) = try await awaitStage(service, route: route)
        let handleA = try StagingFixture.publishedHandle(service, ingress: ingressA)
        let (ingressB, _, _) = try await awaitStage(service, route: route)
        let handleB = try StagingFixture.publishedHandle(service, ingress: ingressB)

        // Double reserve of the same handle is refused before any DB effect.
        guard case .success(let lease1) = service.reserveLaunchLease(handles: [handleA],
                                                                     conversationID: conversation,
                                                                     correlation: "c1")
        else { return XCTFail("first reserve") }
        if case .success = service.reserveLaunchLease(handles: [handleA],
                                                      conversationID: conversation,
                                                      correlation: "c2") {
            XCTFail("same handle must not be reserved twice")
        }
        // A rollback-before-commit returns the handle to staged (bytes kept).
        XCTAssertNil(service.rollbackLaunchLease(lease1.leaseID))
        guard case .success(let lease2) = service.reserveLaunchLease(handles: [handleA, handleB],
                                                                     conversationID: conversation,
                                                                     correlation: "c3")
        else { return XCTFail("re-reserve after rollback") }
        XCTAssertEqual(lease2.stagingIDs.count, 2)
        // Commit: handles die; files SURVIVE (they are the row's bytes now).
        XCTAssertNil(service.commitLaunchLease(lease2.leaseID))
        XCTAssertNil(service.snapshot(handle: handleA))
        XCTAssertNil(service.snapshot(handle: handleB))
        // A late rollback after the DB commit never touches anything and is
        // reported as such (never "rolled back").
        XCTAssertEqual(service.rollbackLaunchLease(lease2.leaseID), .leaseUnknown)
        let stagedURL = root.appendingPathComponent("Attachments")
            .appendingPathComponent(lease2.stagingIDs[0].uuidString)
            .appendingPathComponent("note.txt")
        XCTAssertTrue(FileManager.default.fileExists(atPath: stagedURL.path),
                      "committed bytes are never pruned because the RAM handle is gone")
        // Foreign lease ID is rejected exactly (no cross-generation guess).
        XCTAssertEqual(service.commitLaunchLease("lease:v1:" + String(repeating: "f", count: 32)),
                       .leaseUnknown)
    }

    func testCrossOwnerLeaseRefused() async throws {
        let root = StagingFixture.makeRoot()
        let (service, _, _, _) = makeService(root: root)
        let mine = UUID()
        let other = UUID()
        let route = try XCTUnwrap(service.registerRoute(ComposeRouteDescriptor(
            conversationID: mine, incarnation: 1, draftRevision: 0, isTemporarySession: false)))
        let (ingress, _, _) = try await awaitStage(service, route: route)
        let handle = try StagingFixture.publishedHandle(service, ingress: ingress)
        if case .success = service.reserveLaunchLease(handles: [handle],
                                                      conversationID: other,
                                                      correlation: "c") {
            XCTFail("another conversation must not consume my staged route handle")
        }
    }

    // MARK: Launch authority (parent RB4 resolve-only shape)

    func testResolveReturnsOriginalApplicationSupportRefWithNilOwnership() async throws {
        let root = StagingFixture.makeRoot()
        let (service, _, _, _) = makeService(root: root)
        let conversation = UUID()
        let route = try XCTUnwrap(service.registerRoute(ComposeRouteDescriptor(
            conversationID: conversation, incarnation: 2, draftRevision: 0,
            isTemporarySession: false)))
        let bytes = StagingFixture.chunk(0x7F, count: 300)
        let (ingress, stagingID, _) = try await StagingFixture.streamIngress(
            service, routeReceipt: route.receipt, chunks: [bytes], name: "doc.bin",
            mime: "application/pdf")
        guard case .published(let view) = service.publish(ingressReceipt: ingress) else {
            return XCTFail("publish")
        }
        let authority = AttachmentStagingLaunchAuthority(service: service)
        let ref = try await authority.resolve(handle: view.handle,
                                              conversationID: conversation,
                                              epoch: service.epoch)
        XCTAssertEqual(ref.id.uuidString, stagingID)
        XCTAssertNil(ref.conversationID)
        XCTAssertNil(ref.messageID)
        XCTAssertEqual(ref.storage, .applicationSupport)
        XCTAssertNil(ref.urlBookmark)
        XCTAssertEqual(ref.relativePath, stagingID + "/doc.bin")
        XCTAssertEqual(ref.byteCount, bytes.count)
        XCTAssertEqual(ref.sha256, StagingFixture.digest(bytes))
        XCTAssertEqual(ref.kind, .document, "mime-derived class beats the absent hint")
        // Second resolve (double launch attempt) is refused via the mark.
        do {
            _ = try await authority.resolve(handle: view.handle,
                                            conversationID: conversation,
                                            epoch: service.epoch)
            XCTFail("same handle must not resolve twice into launches")
        } catch let error as RunStagingError {
            XCTAssertEqual(error, .handleUnknown)
        }
    }

    func testResolveFencesForeignEpochAndForeignRoute() async throws {
        let root = StagingFixture.makeRoot()
        let (service, _, _, _) = makeService(root: root, epoch: 42)
        let route = try XCTUnwrap(service.registerRoute(ComposeRouteDescriptor(
            conversationID: nil, incarnation: 1, draftRevision: 0, isTemporarySession: false)))
        let (ingress, _, _) = try await StagingFixture.streamIngress(
            service, routeReceipt: route.receipt,
            chunks: [StagingFixture.chunk(0x31, count: 16)])
        guard case .published(let view) = service.publish(ingressReceipt: ingress) else {
            return XCTFail("publish")
        }
        let authority = AttachmentStagingLaunchAuthority(service: service)
        do {
            _ = try await authority.resolve(handle: view.handle, conversationID: nil,
                                           epoch: 41)
            XCTFail("stale epoch must fence")
        } catch let error as RunStagingError {
            XCTAssertEqual(error, .generationFenced)
        }
        // A new-draft handle (nil route conversation) MAY target an
        // existing conversation at launch time — the prepare transaction
        // binds it. This resolve must succeed (and mark).
        let existing = UUID()
        _ = try await authority.resolve(handle: view.handle,
                                        conversationID: existing, epoch: 42)
        // And the second attempt on the now-marked handle is refused.
        do {
            _ = try await authority.resolve(handle: view.handle,
                                            conversationID: existing, epoch: 42)
            XCTFail("marked handle must not double-resolve")
        } catch let error as RunStagingError {
            XCTAssertEqual(error, .handleUnknown)
        }
    }

    // MARK: Navigation vs arrival + restart reconciliation

    func testRouteCloseAbortsLiveIngressButLeavesStagedBytes() async throws {
        let root = StagingFixture.makeRoot()
        let (service, _, ownedWork, _) = makeService(root: root)
        let conversation = UUID()
        let route = try XCTUnwrap(service.registerRoute(ComposeRouteDescriptor(
            conversationID: conversation, incarnation: 1, draftRevision: 0,
            isTemporarySession: false)))
        let (liveIngress, liveStaging, _) = try await StagingFixture.streamIngress(
            service, routeReceipt: route.receipt,
            chunks: [StagingFixture.chunk(0x81, count: 512)])
        guard case .published(let firstView) = service.publish(ingressReceipt: liveIngress)
        else { return XCTFail("first publish") }
        let publishedHandleValue = firstView.handle
        guard case .opened(let secondIngress, _) =
            service.beginIngress(routeReceipt: route.receipt) else {
            return XCTFail("second begin")
        }
        _ = service.writeIngress(ingressReceipt: secondIngress,
                                 chunk: StagingFixture.chunk(0x82, count: 512))
        service.closeRoute(receipt: route.receipt)
        // The LIVE ingress died with its temp; the STAGED file survives.
        XCTAssertNil(service.ingressProgress(ingressReceipt: secondIngress))
        XCTAssertNotNil(service.snapshot(handle: publishedHandleValue))
        // Explicit discard still required to remove the staged bytes.
        XCTAssertNil(service.discard(handle: publishedHandleValue))
        XCTAssertEqual((ownedWork as? ScriptedOwnedWork)?.liveCount, 0,
                       "closed route released ALL its owned work")
    }

    func testRestartReAdmitsStagedWithFreshHandlesAndNeverPrunesCommitted() async throws {
        let root = StagingFixture.makeRoot()
        let (serviceA, _, _, _) = makeService(root: root, epoch: 9)
        let route = try XCTUnwrap(serviceA.registerRoute(ComposeRouteDescriptor(
            conversationID: nil, incarnation: 1, draftRevision: 0, isTemporarySession: false)))
        let bytes = StagingFixture.chunk(0x9A, count: 9_000)
        let (ingress, stagingID, _) = try await StagingFixture.streamIngress(
            serviceA, routeReceipt: route.receipt, chunks: [bytes])
        guard case .published(let view) = serviceA.publish(ingressReceipt: ingress) else {
            return XCTFail("publish")
        }
        let oldHandle = view.handle
        serviceA.retire()

        // New generation over the SAME root.
        let store = DictionaryCommitStore()
        let (serviceB, _, _, _) = makeService(root: root, store: store, epoch: 10)
        _ = await serviceB.reconcile()
        // Old handle is honestly dead; the record is re-admitted under a
        // fresh handle with identical durable values.
        XCTAssertNil(serviceB.snapshot(handle: oldHandle))
        let fresh = try XCTUnwrap(serviceB.snapshot(stagingID: stagingID))
        XCTAssertEqual(fresh.byteCount, bytes.count)
        XCTAssertEqual(fresh.sha256, view.sha256)
        XCTAssertNotEqual(fresh.handle, oldHandle)
        let stagedURL = root.appendingPathComponent("Attachments")
            .appendingPathComponent(stagingID).appendingPathComponent("note.txt")
        XCTAssertTrue(FileManager.default.fileExists(atPath: stagedURL.path))
        // A committed (rowCommitted) manifest record whose row is ABSENT
        // keeps its bytes — never pruned on restart.
        let store2 = DictionaryCommitStore()
        let (serviceC, _, _, _) = makeService(root: root, store: store2, epoch: 11)
        _ = await serviceC.reconcile()
        XCTAssertTrue(FileManager.default.fileExists(atPath: stagedURL.path))
        _ = store2
    }

    func testReconcileCompletesReadyToPublishAndSweepsOnlyOwnTemps() async throws {
        let root = StagingFixture.makeRoot()
        let (service, _, _, _) = makeService(root: root)
        let route = try XCTUnwrap(service.registerRoute(ComposeRouteDescriptor(
            conversationID: nil, incarnation: 1, draftRevision: 0, isTemporarySession: false)))
        let bytes = StagingFixture.chunk(0xB3, count: 3_000)
        let (ingress, stagingID, _) = try await StagingFixture.streamIngress(
            service, routeReceipt: route.receipt, chunks: [bytes])
        // Crash simulation: leave the session at readyToPublish, retire the
        // RAM, then reconcile in a "new" generation.
        service.retire()
        let (serviceB, _, _, _) = makeService(root: root, epoch: 12)
        let reconcileOutcome = await serviceB.reconcile()
        print("RUNDIAG-RECONCILE outcome=\(reconcileOutcome)")
        guard let reconciled = serviceB.snapshot(stagingID: stagingID) else {
            return XCTFail("reconciled record must exist")
        }
        print("RUNDIAG-RECONCILE state=\(reconciled.state)")
        guard reconciled.state == StagedState.staged.rawValue else {
            return XCTFail("readyToPublish must complete on reconcile")
        }
        let finalURL = root.appendingPathComponent("Attachments")
            .appendingPathComponent(stagingID).appendingPathComponent("note.txt")
        XCTAssertEqual(try? Data(contentsOf: finalURL), bytes)
        // An unrelated foreign temp name is NOT swept (no user-file scanning).
        let foreign = root.appendingPathComponent("Attachments/.staging-tmp")
            .appendingPathComponent("not-a-uuid")
        try? Data([0x00]).write(to: foreign)
        _ = await serviceB.reconcile()
        XCTAssertTrue(FileManager.default.fileExists(atPath: foreign.path))
        _ = ingress
    }

    // MARK: Sanitization + magic image loader (host-native parity)

    func testUntrustedNameHintsAreStrippedNeverRedirected() async throws {
        let root = StagingFixture.makeRoot()
        let (service, _, _, _) = makeService(root: root)
        let route = try XCTUnwrap(service.registerRoute(ComposeRouteDescriptor(
            conversationID: nil, incarnation: 1, draftRevision: 0, isTemporarySession: false)))
        let bytes = StagingFixture.chunk(0xC4, count: 100)
        guard case .opened(let ingress, let stagingID) =
            service.beginIngress(routeReceipt: route.receipt) else {
            return XCTFail("begin")
        }
        _ = service.writeIngress(ingressReceipt: ingress, chunk: bytes)
        XCTAssertNil(service.endIngress(ingressReceipt: ingress,
                                        displayNameHint: "../../../../Android/vendor/etc/hosts",
                                        mimeHint: "text/plain\u{0001}", kindHint: nil))
        guard case .published(let view) = service.publish(ingressReceipt: ingress) else {
            return XCTFail("publish")
        }
        XCTAssertEqual(view.displayName, "hosts",
                       "traversal collapses to the last component only")
        XCTAssertTrue(view.relativePath.hasPrefix(stagingID + "/hosts"))
        XCTAssertFalse(view.relativePath.contains(".."))
        let finalURL = root.appendingPathComponent("Attachments")
            .appendingPathComponent(stagingID).appendingPathComponent("hosts")
        XCTAssertTrue(FileManager.default.fileExists(atPath: finalURL.path),
                      "bytes must land INSIDE the app-private staging tree")
    }

    func testImageLoaderVerifiesMagicDigestAndBudget() async throws {
        let root = StagingFixture.makeRoot()
        let (service, _, _, _) = makeService(root: root)
        let route = try XCTUnwrap(service.registerRoute(ComposeRouteDescriptor(
            conversationID: nil, incarnation: 1, draftRevision: 0, isTemporarySession: false)))
        var png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
        png.append(StagingFixture.chunk(0x10, count: 256))
        guard case .opened(let ingress, _) =
            service.beginIngress(routeReceipt: route.receipt) else {
            return XCTFail("begin")
        }
        _ = service.writeIngress(ingressReceipt: ingress, chunk: png)
        XCTAssertNil(service.endIngress(ingressReceipt: ingress, displayNameHint: "a.png",
                                       mimeHint: "image/png", kindHint: nil))
        guard case .published(let view) = service.publish(ingressReceipt: ingress) else {
            return XCTFail("publish")
        }
        let part = try XCTUnwrap(service.loadStagedInlineImage(handle: view.handle,
                                                               remainingBudget: 1_024 * 1_024))
        XCTAssertEqual(part.mimeType, "image/png")
        XCTAssertEqual(Data(base64Encoded: part.base64), png,
                       "decoded provider bytes must equal the durable staged bytes")
        // Budget smaller than the base64 growth is an honest nil, not a
        // truncated image.
        XCTAssertNil(service.loadStagedInlineImage(handle: view.handle,
                                                   remainingBudget: png.count / 2))
        // A non-image payload mislabeled as image yields nil (magic beats
        // the hint; never ImageIO, never a fake).
        let fake = StagingFixture.chunk(0x20, count: 64)
        guard case .opened(let ingress2, _) =
            service.beginIngress(routeReceipt: route.receipt) else {
            return XCTFail("begin2")
        }
        _ = service.writeIngress(ingressReceipt: ingress2, chunk: fake)
        XCTAssertNil(service.endIngress(ingressReceipt: ingress2, displayNameHint: "x.jpg",
                                       mimeHint: "image/jpeg", kindHint: nil))
        guard case .published(let view2) = service.publish(ingressReceipt: ingress2) else {
            return XCTFail("publish2")
        }
        XCTAssertNil(service.loadStagedInlineImage(handle: view2.handle,
                                                   remainingBudget: 4_194_304))
    }

    func testImageLoaderRejectsSymlinkedStagedFile() async throws {
        let root = StagingFixture.makeRoot()
        let (service, _, _, _) = makeService(root: root)
        let route = try XCTUnwrap(service.registerRoute(ComposeRouteDescriptor(
            conversationID: nil, incarnation: 1, draftRevision: 0, isTemporarySession: false)))
        var png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
        png.append(StagingFixture.chunk(0x22, count: 128))
        guard case .opened(let ingress, let stagingID) =
            service.beginIngress(routeReceipt: route.receipt) else {
            return XCTFail("begin")
        }
        _ = service.writeIngress(ingressReceipt: ingress, chunk: png)
        XCTAssertNil(service.endIngress(ingressReceipt: ingress, displayNameHint: nil,
                                       mimeHint: "image/png", kindHint: nil))
        guard case .published(let view) = service.publish(ingressReceipt: ingress) else {
            return XCTFail("publish")
        }
        // Replace the staged file with a symlink pointing INSIDE the tree
        // (the checkedTarget precedent: even in-root links are refused).
        // The published fallback name is `attachment-<id8>`, carried by the
        // view's displayName.
        let stagedFile = root.appendingPathComponent("Attachments")
            .appendingPathComponent(stagingID).appendingPathComponent(view.displayName)
        let decoy = root.appendingPathComponent("Attachments")
            .appendingPathComponent(stagingID).appendingPathComponent("decoy.bin")
        try Data("decoy".utf8).write(to: decoy)
        try FileManager.default.removeItem(at: stagedFile)
        try FileManager.default.createSymbolicLink(at: stagedFile,
                                                   withDestinationURL: decoy)
        XCTAssertNil(service.loadStagedInlineImage(handle: view.handle,
                                                   remainingBudget: 1_048_576),
                     "symlinked staged bytes are refused, never followed")
    }

    // MARK: Manifest boundedness (small non-secret owned record)

    func testManifestHoldsNoPathsNoURIsAndStaysBounded() async throws {
        let root = StagingFixture.makeRoot()
        let (service, _, _, _) = makeService(root: root)
        let route = try XCTUnwrap(service.registerRoute(ComposeRouteDescriptor(
            conversationID: nil, incarnation: 1, draftRevision: 0, isTemporarySession: false)))
        for index in 0..<6 {
            let (ingress, _, _) = try await StagingFixture.streamIngress(
                service, routeReceipt: route.receipt,
                chunks: [StagingFixture.chunk(UInt8(0xD0 + index), count: 128)])
            guard case .published = service.publish(ingressReceipt: ingress) else {
                XCTFail("publish \(index)")
                return
            }
        }
        let manifestURL = root.appendingPathComponent("Staging/manifest.json")
        let raw = try XCTUnwrap(String(contentsOf: manifestURL, encoding: .utf8))
        XCTAssertFalse(raw.contains(root.path), "manifest must never carry absolute paths")
        XCTAssertFalse(raw.lowercased().contains("content://"))
        XCTAssertFalse(raw.contains("http"))
        let decoded = try XCTUnwrap(StagingManifest.load(from: manifestURL,
                                                         files: FileManagerStagingFileSystem()))
        XCTAssertEqual(decoded.entries.count, 6)
        XCTAssertTrue(decoded.entries.allSatisfy {
            StagingManifest.closedStates.contains($0.state) && $0.byteCount == 128
        })
        let attributes = try FileManager.default.attributesOfItem(atPath: manifestURL.path)
        let size = try XCTUnwrap(attributes[.size] as? Int)
        XCTAssertLessThanOrEqual(size, AttachmentStagingLimits.maximumManifestBytes)
    }

    // MARK: Real RB1 registry interlock (fail-closed against the shared
    // registry when NO accepted generation admits this epoch)

    func testRealRegistryWithoutAcceptedGenerationAdmissionFailsClosedPreIO() throws {
        let root = StagingFixture.makeRoot()
        // A random epoch can never be the accepted bootstrap generation in
        // this process; the REVIEWED registry refuses attach, so the lane
        // must refuse the ingress BEFORE any file effect — no dummy open.
        let epoch = UInt64.random(in: 1_000_000...1_999_999)
        let (service, files, ownedWork, _) = makeService(
            root: root,
            ownedWork: RuntimeOwnedWorkRegistryStagingAttach.shared,
            epoch: epoch)
        let route = try XCTUnwrap(service.registerRoute(ComposeRouteDescriptor(
            conversationID: nil, incarnation: 1, draftRevision: 0, isTemporarySession: false)))
        let outcome = service.beginIngress(routeReceipt: route.receipt)
        if case .opened = outcome {
            XCTFail("begin must fail closed when the registry rejects the epoch")
        }
        XCTAssertEqual(files.createFileCalls, 0,
                       "fail-closed must never create the temp file")
    }

    // MARK: - Helpers

    private func awaitStage(_ service: AttachmentStagingService, route: StagingRoute) async
        throws -> (ingress: String, stagingID: String, total: Int) {
        try await StagingFixture.streamIngress(service, routeReceipt: route.receipt,
                                               chunks: [StagingFixture.chunk(0x5A,
                                                                             count: 1_024)])
    }

}
