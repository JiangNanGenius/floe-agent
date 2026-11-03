// SPDX-License-Identifier: MPL-2.0
//
// C08 B0 — Notes resource -> task workspace input staging.
//
// AUTHORED, NOT EXECUTED by this source-only lane. These tests use a REAL
// `NotesStore` (real SQLite schema, real content-addressed `Resources/` bytes,
// real `authorizeResourceRead` grant/reference rule) and the REAL
// `WorkspaceFileService.importUserFile` transaction on a synthetic task root.
// Only the task-workspace RESOLVER is injected; production uses the original
// `LinuxWorkspaceAuthority` (its own tests cover the persisted run/workspace
// binding). No fake permission table, no fake byte store.
//
// Coverage: exact resource identity/digest and revision receipts; grant
// requirement; revision/digest conflict; missing real task; cancelled input;
// idempotent re-stage; destination conflict without overwrite; sanitized
// destination confined under the document directory; Notes original bytes and
// revision unchanged in success and failure.

import XCTest
import Foundation
import FloeCore
import FloeNotes
import FloeTools
@testable import FloeAndroidCore

final class C08NotesResourceStagingTests: XCTestCase {
    private struct Fixture {
        let store: NotesStore
        let runtimeRoot: RuntimeStorageRoot
        let taskRoot: URL
        let resourceID: UUID
        let documentID: UUID
        let conversationID: UUID
        let resourceRecord: NoteResourceRecord
    }

    private var roots: [URL] = []

    override func tearDownWithError() throws {
        for root in roots {
            try? FileManager.default.removeItem(at: root)
        }
        roots.removeAll()
    }

    private func makeDirectory(_ label: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("c08-notes-\(label)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        roots.append(url)
        return url
    }

    /// Real Notes store + real imported resource + real document reference.
    /// `grant` controls whether the task conversation holds the Notes grant.
    private func makeFixture(
        grant: Bool = true,
        resourceBytes: Data = Data((0..<4096).map { UInt8($0 % 251) }),
        fileName: String = "source.pdf"
    ) async throws -> Fixture {
        let storeRoot = try makeDirectory("store")
        let runtimeBase = try makeDirectory("runtime")
        let taskRoot = try makeDirectory("task")
        let sourceDirectory = try makeDirectory("source")
        let sourceURL = sourceDirectory.appendingPathComponent(fileName)
        try resourceBytes.write(to: sourceURL)
        let store = try NotesStore(root: storeRoot)
        let resourceID = try await store.importResource(
            from: sourceURL, mediaType: "application/pdf")
        let documentID = UUID()
        var document = NoteDocument(id: documentID, kind: .notebook, title: "C08 fixture")
        document.pages = [NotePage(backgroundResourceID: resourceID)]
        _ = try await store.create(document)
        let conversationID = UUID()
        if grant {
            try await store.grantAccess(
                conversationID: conversationID, documentID: documentID, canEdit: false)
        }
        let record = try await store.resourceRecord(resourceID)
        guard let runtimeRoot = RuntimeStorageRoot(
            validatingAbsoluteDirectory: runtimeBase.path) else {
            throw FloeError.internalError("fixture runtime root")
        }
        return Fixture(
            store: store, runtimeRoot: runtimeRoot,
            taskRoot: taskRoot, resourceID: resourceID,
            documentID: documentID, conversationID: conversationID,
            resourceRecord: record)
    }

    private func service(fixture: Fixture) -> NotesResourceStagingService {
        admittedService(
            notes: StoreNotesReader(store: fixture.store),
            runtimeRoot: { _ in fixture.runtimeRoot },
            taskWorkspace: { _, _ in fixture.taskRoot }
        )
    }

    private func serviceWithoutRealTask(fixture: Fixture) -> NotesResourceStagingService {
        admittedService(
            notes: StoreNotesReader(store: fixture.store),
            runtimeRoot: { _ in fixture.runtimeRoot },
            taskWorkspace: { _, _ in nil }
        )
    }

    /// File/grant tests isolate lifetime admission; denial is tested separately.
    private func admittedService(
        notes: any NotesResourceReading,
        runtimeRoot: @escaping NotesResourceStagingService.RuntimeRootResolver,
        taskWorkspace: @escaping NotesResourceStagingService.TaskWorkspaceResolver
    ) -> NotesResourceStagingService {
        NotesResourceStagingService(notes: notes, runtimeRoot: runtimeRoot,
            taskWorkspace: taskWorkspace,
            ownerAdmission: { epoch, conversationID in
                .attached(RuntimeOwnedWorkToken(receipt: "work:v1:" + String(repeating: "a", count: 32),
                    epoch: epoch, kind: .conversation, ownerID: conversationID.uuidString))
            }, ownerRelease: { _ in }, ownerAttached: { _ in true })
    }

    func testOwnerAdmissionRefusalCreatesNoStagingDirectory() async throws {
        let fixture = try await makeFixture()
        let input = try await request(fixture: fixture)
        let original = try await storedBytes(fixture)
        let subject = NotesResourceStagingService(notes: StoreNotesReader(store: fixture.store),
            runtimeRoot: { _ in fixture.runtimeRoot }, taskWorkspace: { _, _ in fixture.taskRoot },
            ownerAdmission: { _, _ in .invalidIdentity })
        await expectStagingError(.ownerAdmissionRefused) { _ = try await subject.stage(input) }
        XCTAssertFalse(FileManager.default.fileExists(atPath:
            fixture.runtimeRoot.artifactStoreURL.appendingPathComponent("NotesImports").path))
        let after = try await storedBytes(fixture)
        XCTAssertEqual(after, original)
    }

    func testStageAcceptsExactRunLeaseAndRefusesForeignRunLease() async throws {
        let fixture = try await makeFixture()
        let input = try await request(fixture: fixture)
        let subject = service(fixture: fixture)
        let wrong = RuntimeOwnedWorkToken(receipt: "work:v1:" + String(repeating: "b", count: 32),
            epoch: input.notesEpoch, kind: .run, ownerID: UUID().uuidString)
        await expectStagingError(.ownerAdmissionRefused) {
            _ = try await subject.stage(input, ownerLease: wrong)
        }
        let exact = RuntimeOwnedWorkToken(receipt: "work:v1:" + String(repeating: "c", count: 32),
            epoch: input.notesEpoch, kind: .run, ownerID: input.runID.uuidString)
        let receipt = try await subject.stage(input, ownerLease: exact)
        XCTAssertEqual(receipt.ownerRunID, input.runID)
    }

    private func request(
        fixture: Fixture,
        revision: Int? = nil,
        expectedSHA256: String? = nil
    ) async throws -> NotesResourceStagingRequest {
        let document = try await fixture.store.document(fixture.documentID)
        let actualRevision = document.revision
        return NotesResourceStagingRequest(
            notesEpoch: 7,
            runID: UUID(),
            conversationID: fixture.conversationID,
            documentID: fixture.documentID,
            resourceID: fixture.resourceID,
            expectedDocumentRevision: revision ?? actualRevision,
            expectedResourceSHA256: expectedSHA256
        )
    }

    private func storedBytes(_ fixture: Fixture) async throws -> Data {
        let url = try await fixture.store.resourceURL(fixture.resourceID)
        return try Data(contentsOf: url)
    }

    private func stagingParts(in fixture: Fixture) -> [String] {
        let dir = fixture.runtimeRoot.artifactStoreURL
            .appendingPathComponent("NotesImports", isDirectory: true)
            .appendingPathComponent("Staging", isDirectory: true)
        let entries = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        return entries.filter { $0.hasSuffix(".part") }
    }

    private func expectStagingError(
        _ expected: NotesResourceStagingErrorCode,
        file: StaticString = #filePath,
        line: UInt = #line,
        _ body: () async throws -> Void
    ) async {
        do {
            try await body()
            XCTFail("expected \(expected.rawValue)", file: file, line: line)
        } catch let error as NotesResourceStagingError {
            XCTAssertEqual(error.code, expected, file: file, line: line)
        } catch {
            XCTFail("expected NotesResourceStagingError, got \(error)", file: file, line: line)
        }
    }

    // MARK: - Success

    func testStagesExactResourceIntoRealTaskWorkspace() async throws {
        let fixture = try await makeFixture()
        let beforeDocument = try await fixture.store.document(fixture.documentID)
        let beforeDocumentRevision = beforeDocument.revision
        let beforeResource = try await storedBytes(fixture)
        let request = try await request(fixture: fixture)

        let receipt = try await service(fixture: fixture).stage(request)

        XCTAssertFalse(receipt.idempotent)
        XCTAssertEqual(receipt.documentID, fixture.documentID)
        XCTAssertEqual(receipt.documentRevision, beforeDocumentRevision)
        XCTAssertEqual(receipt.resourceID, fixture.resourceID)
        XCTAssertEqual(receipt.resourceSHA256, fixture.resourceRecord.hash)
        XCTAssertEqual(receipt.byteCount, fixture.resourceRecord.byteCount)
        XCTAssertEqual(receipt.ownerConversationID, fixture.conversationID)
        XCTAssertEqual(receipt.ownerRunID, request.runID)
        XCTAssertEqual(receipt.destinationRelativePath,
                       "NotesImports/\(fixture.documentID.uuidString)/source.pdf")

        let destination = fixture.taskRoot.appendingPathComponent(receipt.destinationRelativePath)
        let staged = try Data(contentsOf: destination)
        XCTAssertEqual(staged.count, Int(fixture.resourceRecord.byteCount))
        XCTAssertEqual(FloeDigest.sha256Hex(staged), fixture.resourceRecord.hash)
        XCTAssertEqual(staged, beforeResource)
        XCTAssertTrue(stagingParts(in: fixture).isEmpty)

        // The Notes original and its revision are untouched.
        let afterResource = try await storedBytes(fixture)
        XCTAssertEqual(afterResource, beforeResource)
        let afterDocument = try await fixture.store.document(fixture.documentID)
        XCTAssertEqual(afterDocument.revision, beforeDocumentRevision)
        let document = afterDocument
        XCTAssertTrue(document.resourceIDs.contains(fixture.resourceID))
    }

    func testIdempotentRestageDoesNotRewrite() async throws {
        let fixture = try await makeFixture()
        let service = service(fixture: fixture)
        let request = try await request(fixture: fixture)

        let first = try await service.stage(request)
        let destination = fixture.taskRoot.appendingPathComponent(first.destinationRelativePath)
        let firstBytes = try Data(contentsOf: destination)
        let firstAttributes = try FileManager.default.attributesOfItem(atPath: destination.path)

        let second = try await service.stage(request)

        XCTAssertTrue(second.idempotent)
        XCTAssertEqual(second.destinationRelativePath, first.destinationRelativePath)
        let secondBytes = try Data(contentsOf: destination)
        XCTAssertEqual(secondBytes, firstBytes)
        let secondAttributes = try FileManager.default.attributesOfItem(atPath: destination.path)
        XCTAssertEqual(firstAttributes[.modificationDate] as? Date,
                       secondAttributes[.modificationDate] as? Date)
        XCTAssertTrue(stagingParts(in: fixture).isEmpty)
    }

    // MARK: - Authority / identity failures

    func testRequiresRealConversationGrant() async throws {
        let fixture = try await makeFixture(grant: false)
        let request = try await request(fixture: fixture)
        await expectStagingError(.resourceAccessDenied) {
            _ = try await service(fixture: fixture).stage(request)
        }
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: fixture.taskRoot.appendingPathComponent(
                "NotesImports/\(fixture.documentID.uuidString)/source.pdf").path))
        XCTAssertTrue(stagingParts(in: fixture).isEmpty)
    }

    func testGrantRevokedDuringStagingWinsBeforeCommit() async throws {
        let fixture = try await makeFixture()
        let request = try await request(fixture: fixture)
        let counter = ReadCounter()
        let reader = RevokeOnSecondReadReader(
            base: StoreNotesReader(store: fixture.store),
            store: fixture.store,
            conversationID: fixture.conversationID,
            documentID: fixture.documentID,
            counter: counter
        )
        let service = admittedService(
            notes: reader,
            runtimeRoot: { _ in fixture.runtimeRoot },
            taskWorkspace: { _, _ in fixture.taskRoot }
        )
        await expectStagingError(.resourceAccessDenied) {
            _ = try await service.stage(request)
        }
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: fixture.taskRoot.appendingPathComponent(
                "NotesImports/\(fixture.documentID.uuidString)/source.pdf").path))
        XCTAssertTrue(stagingParts(in: fixture).isEmpty)
        let document = try await fixture.store.document(fixture.documentID)
        XCTAssertEqual(document.revision, 1)
    }

    func testChangedDocumentRevisionRefusesBeforeWrite() async throws {
        let fixture = try await makeFixture()
        let before = try await storedBytes(fixture)
        let request = try await request(fixture: fixture, revision: 999)
        await expectStagingError(.documentRevisionMismatch) {
            _ = try await service(fixture: fixture).stage(request)
        }
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: fixture.taskRoot.appendingPathComponent(
                "NotesImports/\(fixture.documentID.uuidString)/source.pdf").path))
        let afterResource = try await storedBytes(fixture)
        XCTAssertEqual(afterResource, before)
        let afterDocument = try await fixture.store.document(fixture.documentID)
        XCTAssertEqual(afterDocument.revision, 1)
        XCTAssertTrue(stagingParts(in: fixture).isEmpty)
    }

    func testSelectedDigestMismatchRefuses() async throws {
        let fixture = try await makeFixture()
        let request = try await request(
            fixture: fixture,
            expectedSHA256: String(repeating: "0", count: 64))
        await expectStagingError(.resourceDigestMismatch) {
            _ = try await service(fixture: fixture).stage(request)
        }
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: fixture.taskRoot.appendingPathComponent(
                "NotesImports/\(fixture.documentID.uuidString)/source.pdf").path))
        XCTAssertTrue(stagingParts(in: fixture).isEmpty)
    }

    func testNoRealTaskWorkspaceRefusesWithoutNotesReadOrWrite() async throws {
        let fixture = try await makeFixture()
        let request = try await request(fixture: fixture)
        await expectStagingError(.taskWorkspaceUnavailable) {
            _ = try await serviceWithoutRealTask(fixture: fixture).stage(request)
        }
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: fixture.taskRoot.appendingPathComponent(
                "NotesImports/\(fixture.documentID.uuidString)/source.pdf").path))
        XCTAssertTrue(stagingParts(in: fixture).isEmpty)
        let document = try await fixture.store.document(fixture.documentID)
        XCTAssertEqual(document.revision, 1)
    }

    func testCancelledInputCreatesNothing() async throws {
        let fixture = try await makeFixture()
        let request = try await request(fixture: fixture)
        let token = CancellationToken()
        token.cancel()
        await expectStagingError(.cancelled) {
            _ = try await service(fixture: fixture).stage(request, cancellation: token)
        }
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: fixture.taskRoot.appendingPathComponent(
                "NotesImports/\(fixture.documentID.uuidString)/source.pdf").path))
        XCTAssertTrue(stagingParts(in: fixture).isEmpty)
    }

    // MARK: - Destination ownership

    func testDifferentExistingDestinationIsNeverOverwritten() async throws {
        let fixture = try await makeFixture()
        let service = service(fixture: fixture)
        let request = try await request(fixture: fixture)
        let relative = "NotesImports/\(fixture.documentID.uuidString)/source.pdf"
        let destination = fixture.taskRoot.appendingPathComponent(relative)
        try FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        let foreign = Data("another writer's bytes".utf8)
        try foreign.write(to: destination)

        await expectStagingError(.destinationConflict) {
            _ = try await service.stage(request)
        }
        let afterConflict = try Data(contentsOf: destination)
        XCTAssertEqual(afterConflict, foreign)
        XCTAssertTrue(stagingParts(in: fixture).isEmpty)
    }

    func testSanitizedResourceNameStaysInsideDocumentDirectory() {
        let id = UUID()
        XCTAssertEqual(
            NotesResourceStagingService.sanitizedFileName("../evil.pdf", resourceID: id),
            "evil.pdf")
        XCTAssertEqual(
            NotesResourceStagingService.sanitizedFileName("..", resourceID: id),
            "resource-\(id.uuidString.prefix(8))")
        XCTAssertEqual(
            NotesResourceStagingService.sanitizedFileName(".env", resourceID: id),
            "_env")
        let long = String(repeating: "a", count: 300) + ".pdf"
        let sanitized = NotesResourceStagingService.sanitizedFileName(long, resourceID: id)
        XCTAssertLessThanOrEqual(sanitized.utf8.count, 180)
        XCTAssertTrue(sanitized.hasSuffix(".pdf"))
        XCTAssertFalse(sanitized.contains("/"))
        XCTAssertFalse(sanitized.contains("\\"))
        XCTAssertFalse(sanitized.contains(":"))
        XCTAssertFalse(sanitized.hasPrefix("."))
    }

    // MARK: - Valid request shape

    func testInvalidRequestShapeIsTyped() async throws {
        let fixture = try await makeFixture()
        var request = try await request(fixture: fixture)
        request.notesEpoch = 0
        await expectStagingError(.invalidRequest) {
            _ = try await service(fixture: fixture).stage(request)
        }
        var badDigest = try await self.request(fixture: fixture)
        badDigest.expectedResourceSHA256 = "not-a-digest"
        await expectStagingError(.invalidRequest) {
            _ = try await service(fixture: fixture).stage(badDigest)
        }
    }
}

// MARK: - Grant-revocation reader

private actor ReadCounter {
    private var count = 0
    func next() -> Int {
        count += 1
        return count
    }
}

/// Revokes the real Notes grant just before the SECOND resource read (the
/// service's final pre-commit authority probe), proving a mid-staging revoke
/// wins instead of a cached authorization.
private struct RevokeOnSecondReadReader: NotesResourceReading {
    let base: StoreNotesReader
    let store: NotesStore
    let conversationID: UUID
    let documentID: UUID
    let counter: ReadCounter

    func documentRevision(notesEpoch: UInt64, documentID: UUID) async throws -> Int {
        try await base.documentRevision(notesEpoch: notesEpoch, documentID: documentID)
    }

    func resourceMetadata(
        notesEpoch: UInt64,
        resourceID: UUID
    ) async throws -> NotesResourceStagingMetadata {
        try await base.resourceMetadata(notesEpoch: notesEpoch, resourceID: resourceID)
    }

    func readResource(
        notesEpoch: UInt64,
        resourceID: UUID,
        conversationID: UUID,
        documentID: UUID,
        offset: Int64,
        maxBytes: Int
    ) async throws -> NotesResourceStagingChunk {
        if await counter.next() == 2 {
            try await store.revokeAccess(
                conversationID: self.conversationID, documentID: self.documentID)
        }
        return try await base.readResource(
            notesEpoch: notesEpoch, resourceID: resourceID,
            conversationID: conversationID, documentID: documentID,
            offset: offset, maxBytes: maxBytes)
    }
}

// MARK: - Real-store Notes reader

/// Test adapter over the REAL NotesStore. It deliberately uses the store's
/// own `authorizeResourceRead` + content-addressed `resourceURL`; the staging
/// service still performs the digest/size/revision/commit checks, so these
/// tests exercise the real authority and the real file transaction rather than
/// a byte-dictionary double.
private struct StoreNotesReader: NotesResourceReading {
    let store: NotesStore

    func documentRevision(notesEpoch: UInt64, documentID: UUID) async throws -> Int {
        let document = try await store.document(documentID)
        return document.revision
    }

    func resourceMetadata(
        notesEpoch: UInt64,
        resourceID: UUID
    ) async throws -> NotesResourceStagingMetadata {
        let record = try await store.resourceRecord(resourceID)
        return NotesResourceStagingMetadata(
            resourceID: record.id,
            sha256: record.hash,
            byteCount: record.byteCount,
            fileName: record.fileName,
            mediaType: record.mediaType
        )
    }

    func readResource(
        notesEpoch: UInt64,
        resourceID: UUID,
        conversationID: UUID,
        documentID: UUID,
        offset: Int64,
        maxBytes: Int
    ) async throws -> NotesResourceStagingChunk {
        // The SAME store rule used by the Notes assistant/resource channel.
        try await store.authorizeResourceRead(
            resourceID: resourceID,
            conversationID: conversationID,
            documentID: documentID
        )
        let url = try await store.resourceURL(resourceID)
        let data = try Data(contentsOf: url)
        let total = Int64(data.count)
        guard offset >= 0, offset <= total else {
            return NotesResourceStagingChunk(
                data: Data(), nextOffset: total, totalBytes: total, eof: true)
        }
        let upper = min(total, offset + Int64(maxBytes))
        let slice = data[Int(offset)..<Int(upper)]
        return NotesResourceStagingChunk(
            data: Data(slice), nextOffset: upper, totalBytes: total, eof: upper >= total)
    }
}
