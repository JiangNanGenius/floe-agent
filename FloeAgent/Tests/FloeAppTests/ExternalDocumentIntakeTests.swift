// FloeAppTests — system document-open intake (S5 P3).
//
// PREPARED DEFINITIONS — deliberately NOT executed in this source lane.
// The unified qualification run owns execution after the primary registers
// this file in the FloeAppTests source list, applies the document-type/URL
// scheme metadata and the bilingual catalog entries.
//
// Coverage:
// * real coordinated staging, streaming copy, digest and original-byte proof
// * directory/symlink/alias/empty/oversize/unsupported/traversal rejection
// * manifest-last atomic publication, restart recovery, FIFO claim and CAS
// * duplicate in-flight/cold callbacks, changed reimport, two-window routing
// * cold input before readiness, cancellation before/after commit
// * real isolated NotesStore + NotesArchive + NoteFileImporter commit identity
// * commit-before-ack restart without a second document (Notes and Canvas)
// * interrupted Canvas restore: exact committed identity recovery, owned
//   partial-payload cleanup and bounded requeue (no duplicate, no clobber)
// * required queue state transitions surface a real save failure while the
//   durable input stays recoverable (retry/discard/recovery damaged mark)
// * routing eligibility: a user who navigated away keeps a real Open offer
//   instead of the import stealing the current task/editor; explicit Open
//   re-arms the once-only, scene-bound presentation
// * compact localized copy uses no queue identity or filesystem path
//
// Synthetic content only. No provider is contacted and no real user file is
// read. Filesystem work uses unique temporary roots.

#if canImport(UIKit)
import Foundation
import Testing
import UIKit
import UniformTypeIdentifiers
import FloeCore
import FloeNotes
import FloeWorkspace
@testable import FloeApp

// MARK: - Fixtures

private func intakeRoot(_ name: String = "document-intake") -> URL {
    FileManager.default.temporaryDirectory
        .appendingPathComponent("\(name)-\(UUID().uuidString)", isDirectory: true)
}

@discardableResult
private func intakeFile(_ bytes: Data, name: String, in directory: URL) throws -> URL {
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let url = directory.appendingPathComponent(name, isDirectory: false)
    try bytes.write(to: url, options: .atomic)
    return url
}

private func intakeBytes(_ count: Int, seed: UInt8 = 7) -> Data {
    Data((0..<count).map { UInt8((Int($0) + Int(seed)) % 251) })
}

private func intakeRequest(
    eventID: UUID = UUID(),
    plannedRootID: UUID = UUID(),
    sceneID: String? = "scene-a",
    sequence: UInt64 = 1
) -> DocumentIntakeStagingRequest {
    DocumentIntakeStagingRequest(
        eventID: eventID,
        plannedRootDocumentID: plannedRootID,
        sceneID: sceneID,
        requestSequence: sequence,
        receivedAt: Date()
    )
}

@MainActor
private func expectIntakeError(
    _ expected: DocumentIntakeError,
    _ body: () async throws -> Void
) async {
    do {
        try await body()
        Issue.record("Expected \(expected), but the operation succeeded")
    } catch let error as DocumentIntakeError {
        #expect(error == expected)
    } catch {
        Issue.record("Expected \(expected), received \(error)")
    }
}

@MainActor
private func waitUntil(
    _ timeout: TimeInterval = 8,
    _ condition: @MainActor () -> Bool
) async -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(20))
    }
    return condition()
}

// MARK: - Fake Notes importer

private actor DocumentIntakeTestNotesLibrary {
    private var documents: [UUID: NoteDocument] = [:]
    private var importCount = 0
    private var nextTitle = 1

    func existing(_ id: UUID) -> NoteDocument? { documents[id] }
    func importedCount() -> Int { importCount }
    func recordImport() -> Int {
        importCount += 1
        let value = nextTitle
        nextTitle += 1
        return value
    }
    func store(_ document: NoteDocument) { documents[document.id] = document }
}

private struct DocumentIntakeTestNotesImporter: NotesDocumentImporting {
    let library: DocumentIntakeTestNotesLibrary
    let gate: DocumentIntakeTestGate?
    let unavailable: Bool

    init(
        library: DocumentIntakeTestNotesLibrary,
        gate: DocumentIntakeTestGate? = nil,
        unavailable: Bool = false
    ) {
        self.library = library
        self.gate = gate
        self.unavailable = unavailable
    }

    func existingDocument(id: UUID) async throws -> NoteDocument? {
        if unavailable { throw DocumentIntakeError.notesUnavailable }
        return await library.existing(id)
    }

    func documentIDs(inBundle rootID: UUID) async throws -> [UUID] {
        if unavailable { throw DocumentIntakeError.notesUnavailable }
        return [rootID]
    }

    func importNotes(
        from url: URL,
        kind: DocumentIntakeKind,
        plannedRootID: UUID,
        displayName: String
    ) async throws -> NotesImportOutcome {
        if unavailable { throw DocumentIntakeError.notesUnavailable }
        let titleIndex = await library.recordImport()
        if let gate { try await gate.wait() }
        try Task.checkCancellation()
        var document = NoteDocument(id: plannedRootID, title: "Imported \(titleIndex)")
        document.pages = [NotePage()]
        await library.store(document)
        return NotesImportOutcome(
            rootDocumentID: plannedRootID,
            documentIDs: [plannedRootID],
            title: document.title
        )
    }
}

/// Cancellation-aware gate for the pre-commit window. Polling keeps the test
/// deterministic without storing continuations across the actor boundary.
private actor DocumentIntakeTestGate {
    private var opened = false

    func wait() async throws {
        while !opened {
            try Task.checkCancellation()
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    func open() { opened = true }
}

// MARK: - Fake Canvas importer

private actor DocumentIntakeTestCanvasLibrary {
    private(set) var calls = 0
    private(set) var plannedIDs: [UUID] = []
    private(set) var existingIDs: Set<UUID> = []
    private(set) var cleanupCalls: [UUID] = []
    /// Simulates a restore that committed its owned payload but died before
    /// the registry write: `exists` stays false and a partial payload exists.
    private var ownsPartialPayload: Set<UUID> = []

    func markOwnedPartialPayload(_ id: UUID) { ownsPartialPayload.insert(id) }

    func importCanvas(plannedID: UUID) -> UUID {
        calls += 1
        plannedIDs.append(plannedID)
        existingIDs.insert(plannedID)
        return plannedID
    }

    func exists(_ id: UUID) -> Bool { existingIDs.contains(id) }

    func cleanup(_ id: UUID) -> Bool {
        cleanupCalls.append(id)
        return ownsPartialPayload.remove(id) != nil
    }
}

private struct DocumentIntakeTestCanvasImporter: CanvasDocumentImporting {
    let library: DocumentIntakeTestCanvasLibrary

    func importCanvas(from url: URL, plannedCanvasID: UUID) async throws -> CanvasImportOutcome {
        let id = await library.importCanvas(plannedID: plannedCanvasID)
        return CanvasImportOutcome(canvasID: id, name: "Imported Canvas")
    }

    func canvasExists(id: UUID) async -> Bool {
        await library.exists(id)
    }

    func removePartialRestoreArtifacts(canvasID: UUID) async -> Bool {
        await library.cleanup(canvasID)
    }
}

// MARK: - Staging

@Suite("External document intake staging")
@MainActor
struct ExternalDocumentIntakeStagingTests {
    @Test func stagesRealBytesWithDigestAndPreservesTheOriginal() async throws {
        let root = intakeRoot("staging-root")
        let sourceRoot = intakeRoot("staging-source")
        defer { try? FileManager.default.removeItem(at: root) }
        defer { try? FileManager.default.removeItem(at: sourceRoot) }

        let bytes = intakeBytes(1_200_000)
        let source = try intakeFile(bytes, name: "Synthetic.floenote", in: sourceRoot)
        let before = try DocumentIntakeStorage.sha256(of: source)
        let request = intakeRequest()
        let queue = try DocumentIntakeQueue(root: root)

        let staged = try await DocumentIntakeStager.stage(
            source,
            root: root,
            limits: .production,
            request: request
        )
        #expect(staged.record.id == request.eventID)
        #expect(staged.record.kind == .floeNote)
        #expect(staged.record.byteCount == before.byteCount)
        #expect(staged.record.sha256 == before.digest)
        #expect(staged.record.plannedRootDocumentID == request.plannedRootDocumentID)
        #expect(DocumentIntakeStorage.isRegularFileNotSymlink(staged.payloadURL))

        let after = try DocumentIntakeStorage.sha256(of: source)
        #expect(after.digest == before.digest)
        #expect(after.byteCount == before.byteCount)
        let original = try Data(contentsOf: source)
        #expect(original == bytes)

        let published = try await queue.enqueue(staged)
        #expect(published.state == .pending)
        let stored = try await queue.record(id: request.eventID)
        #expect(stored?.state == .pending)
    }

    @Test func rejectsDirectorySymlinkEmptyOversizeAndUnsupportedInputs() async throws {
        let root = intakeRoot("staging-rejects")
        let sourceRoot = intakeRoot("staging-rejects-source")
        defer { try? FileManager.default.removeItem(at: root) }
        defer { try? FileManager.default.removeItem(at: sourceRoot) }
        try FileManager.default.createDirectory(at: sourceRoot, withIntermediateDirectories: true)

        let folder = sourceRoot.appendingPathComponent("Folder.floenote", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        await expectIntakeError(.notAFile) {
            _ = try await DocumentIntakeStager.stage(folder, root: root, limits: .production, request: intakeRequest())
        }

        let target = try intakeFile(intakeBytes(64), name: "Target.floenote", in: sourceRoot)
        let link = sourceRoot.appendingPathComponent("Link.floenote", isDirectory: false)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        await expectIntakeError(.linkNotAllowed) {
            _ = try await DocumentIntakeStager.stage(link, root: root, limits: .production, request: intakeRequest())
        }

        let empty = try intakeFile(Data(), name: "Empty.txt", in: sourceRoot)
        await expectIntakeError(.emptyFile) {
            _ = try await DocumentIntakeStager.stage(empty, root: root, limits: .production, request: intakeRequest())
        }

        let oversized = try intakeFile(Data(repeating: 1, count: 2_000_001), name: "Large.txt", in: sourceRoot)
        await expectIntakeError(.tooLarge(2_000_000)) {
            _ = try await DocumentIntakeStager.stage(oversized, root: root, limits: .production, request: intakeRequest())
        }

        let unknown = try intakeFile(intakeBytes(32), name: "Unknown.bin", in: sourceRoot)
        await expectIntakeError(.unsupportedType) {
            _ = try await DocumentIntakeStager.stage(unknown, root: root, limits: .production, request: intakeRequest())
        }
    }

    @Test func rejectsAFileAlreadyInsideTheOwnedQueueRoot() async throws {
        let root = intakeRoot("staging-self")
        defer { try? FileManager.default.removeItem(at: root) }
        let inside = try intakeFile(
            intakeBytes(64),
            name: "Copy.floenote",
            in: root.appendingPathComponent("staging", isDirectory: true)
        )
        await expectIntakeError(.notAFile) {
            _ = try await DocumentIntakeStager.stage(inside, root: root, limits: .production, request: intakeRequest())
        }
    }

    @Test func stagedDigestRejectsChangedOrTruncatedBytes() async throws {
        let root = intakeRoot("staging-digest")
        let sourceRoot = intakeRoot("staging-digest-source")
        defer { try? FileManager.default.removeItem(at: root) }
        defer { try? FileManager.default.removeItem(at: sourceRoot) }
        let bytes = intakeBytes(8_192)
        let source = try intakeFile(bytes, name: "Digest.txt", in: sourceRoot)
        let staged = try await DocumentIntakeStager.stage(
            source, root: root, limits: .production, request: intakeRequest()
        )
        let intact = try DocumentIntakeStorage.verifySHA256(
            at: staged.payloadURL,
            expectedDigest: staged.record.sha256,
            expectedByteCount: staged.record.byteCount
        )
        #expect(intact)

        var changed = bytes
        changed[0] = changed[0] &+ 1
        try changed.write(to: staged.payloadURL, options: .atomic)
        let afterChange = try DocumentIntakeStorage.verifySHA256(
            at: staged.payloadURL,
            expectedDigest: staged.record.sha256,
            expectedByteCount: staged.record.byteCount
        )
        #expect(!afterChange)

        try Data(bytes.prefix(16)).write(to: staged.payloadURL, options: .atomic)
        let afterTruncate = try DocumentIntakeStorage.verifySHA256(
            at: staged.payloadURL,
            expectedDigest: staged.record.sha256,
            expectedByteCount: staged.record.byteCount
        )
        #expect(!afterTruncate)
        staged.activeLock?.close()
    }

    @Test func acceptsCanonicalAndLegacyCanvasExtensionsAndRejectsUnknownTypes() throws {
        #expect(DocumentIntakeKind.classify(fileExtension: "floecanvas", contentType: nil) == .floeCanvas)
        #expect(DocumentIntakeKind.classify(fileExtension: "floeCanvas", contentType: nil) == .floeCanvas)
        #expect(DocumentIntakeKind.classify(fileExtension: "FLOENOTE", contentType: nil) == .floeNote)
        #expect(DocumentIntakeKind.classify(fileExtension: "pdf", contentType: nil) == .pdf)
        #expect(DocumentIntakeKind.classify(fileExtension: "docx", contentType: nil) == .office)
        #expect(DocumentIntakeKind.classify(fileExtension: "dxf", contentType: nil) == .engineering)
        #expect(DocumentIntakeKind.classify(fileExtension: "md", contentType: nil) == .text)
        #expect(DocumentIntakeKind.classify(fileExtension: "png", contentType: nil) == .image)
        #expect(DocumentIntakeKind.classify(fileExtension: "bin", contentType: nil) == nil)

        #expect(DocumentIntakeKind.isValidStagedFileName("payload.floecanvas", kind: .floeCanvas))
        #expect(!DocumentIntakeKind.isValidStagedFileName("../payload", kind: .floeCanvas))
        #expect(!DocumentIntakeKind.isValidStagedFileName("payload.floeCanvas", kind: .floeCanvas))
        #expect(DocumentIntakeKind.stagedFileName(for: .office, originalExtension: "XLSX") == "payload.xlsx")
        #expect(DocumentIntakeKind.stagedFileName(for: .engineering, originalExtension: "DXF") == "payload.dxf")
        #expect(DocumentIntakeKind.stagedFileName(for: .text, originalExtension: "MD") == "payload.md")
        #expect(DocumentIntakeKind.stagedFileName(for: .image, originalExtension: "HEIC") == "payload.heic")
        #expect(DocumentIntakeKind.isValidStagedFileName("payload.xlsx", kind: .office))
        #expect(!DocumentIntakeKind.isValidStagedFileName("payload.exe", kind: .office))

        let encoded = try #require(URL(string: "file:///tmp/Synthetic%0AName.floenote"))
        #expect(DocumentIntakeKind.displayName(from: encoded) == "SyntheticName.floenote")
    }
}

// MARK: - Queue

@Suite("External document intake durable queue")
@MainActor
struct ExternalDocumentIntakeQueueTests {
    @Test func stagingBecomesVisibleOnlyAfterEnqueueAndSurvivesRestart() async throws {
        let root = intakeRoot("queue-restart")
        let sourceRoot = intakeRoot("queue-restart-source")
        defer { try? FileManager.default.removeItem(at: root) }
        defer { try? FileManager.default.removeItem(at: sourceRoot) }

        let source = try intakeFile(intakeBytes(32_768), name: "Restart.floenote", in: sourceRoot)
        let request = intakeRequest()
        let firstQueue = try DocumentIntakeQueue(root: root)
        let staged = try await DocumentIntakeStager.stage(
            source, root: root, limits: .production, request: request
        )
        let beforePublish = try await firstQueue.snapshot()
        #expect(beforePublish.records.isEmpty)

        // Crash before the atomic rename: release the live staging lock.
        staged.activeLock?.close()
        let restartQueue = try DocumentIntakeQueue(root: root)
        let report = try await restartQueue.maintain(now: Date())
        #expect(report.recoveredStaging == 1)
        let pending = try await restartQueue.snapshot()
        #expect(pending.records.count == 1)
        #expect(pending.records.first?.id == request.eventID)

        let claimed = try await restartQueue.claimNext()
        let claim = try #require(claimed)
        let commit = DocumentIntakeCommit(
            rootDocumentID: request.plannedRootDocumentID,
            documentIDs: [request.plannedRootDocumentID],
            title: "Recovered",
            committedAt: Date()
        )
        try await restartQueue.markCommitted(claim, commit: commit)
        let receipt = try await restartQueue.record(id: request.eventID)
        #expect(receipt?.state == .committed)
        #expect(receipt?.commit?.rootDocumentID == request.plannedRootDocumentID)

        let thirdQueue = try DocumentIntakeQueue(root: root)
        let completed = try await thirdQueue.record(id: request.eventID)
        #expect(completed?.state == .committed)
        let payload = root.appendingPathComponent("pending")
            .appendingPathComponent(request.eventID.uuidString)
            .appendingPathComponent("payload.floenote")
        #expect(!FileManager.default.fileExists(atPath: payload.path))
    }

    @Test func duplicateCallbacksCoalesceButChangedAndLaterReimportsAreNew() async throws {
        let root = intakeRoot("queue-duplicates")
        let sourceRoot = intakeRoot("queue-duplicates-source")
        defer { try? FileManager.default.removeItem(at: root) }
        defer { try? FileManager.default.removeItem(at: sourceRoot) }
        let queue = try DocumentIntakeQueue(root: root)
        let bytes = intakeBytes(4_096)

        let first = try intakeFile(bytes, name: "First.txt", in: sourceRoot)
        let second = try intakeFile(bytes, name: "Second.txt", in: sourceRoot)
        let firstStaged = try await DocumentIntakeStager.stage(
            first, root: root, limits: .production, request: intakeRequest()
        )
        let secondStaged = try await DocumentIntakeStager.stage(
            second, root: root, limits: .production, request: intakeRequest()
        )
        let firstRecord = try await queue.enqueue(firstStaged)
        let secondRecord = try await queue.enqueue(secondStaged)
        #expect(firstRecord.id == secondRecord.id)
        #expect(!FileManager.default.fileExists(atPath: secondStaged.directory.path))
        let afterDuplicate = try await queue.snapshot()
        #expect(afterDuplicate.records.count == 1)

        let changedBytes = intakeBytes(4_096, seed: 11)
        let changed = try intakeFile(changedBytes, name: "Changed.txt", in: sourceRoot)
        let changedStaged = try await DocumentIntakeStager.stage(
            changed, root: root, limits: .production, request: intakeRequest()
        )
        let changedRecord = try await queue.enqueue(changedStaged)
        #expect(changedRecord.id != firstRecord.id)

        let claimed = try await queue.claimNext()
        let claim = try #require(claimed)
        try await queue.markCommitted(
            claim,
            commit: DocumentIntakeCommit(
                rootDocumentID: firstRecord.plannedRootDocumentID,
                documentIDs: [firstRecord.plannedRootDocumentID],
                title: "First",
                committedAt: Date()
            )
        )
        let sameAgain = try intakeFile(bytes, name: "SameAgain.txt", in: sourceRoot)
        let sameStaged = try await DocumentIntakeStager.stage(
            sameAgain, root: root, limits: .production, request: intakeRequest()
        )
        let reimport = try await queue.enqueue(sameStaged)
        #expect(reimport.id != firstRecord.id)
    }

    @Test func claimIsExclusiveAndCompletedEntriesRejectAStaleToken() async throws {
        let root = intakeRoot("queue-claims")
        let sourceRoot = intakeRoot("queue-claims-source")
        defer { try? FileManager.default.removeItem(at: root) }
        defer { try? FileManager.default.removeItem(at: sourceRoot) }
        let source = try intakeFile(intakeBytes(2_048), name: "Claim.txt", in: sourceRoot)
        let queue = try DocumentIntakeQueue(root: root)
        let staged = try await DocumentIntakeStager.stage(
            source, root: root, limits: .production, request: intakeRequest()
        )
        let record = try await queue.enqueue(staged)
        let claimed = try await queue.claimNext()
        let claim = try #require(claimed)
        let secondClaim = try await queue.claimNext()
        #expect(secondClaim == nil)

        let failure = DocumentIntakeFailure.damaged
        try await queue.markFailed(claim, code: failure, detail: nil)
        do {
            try await queue.markFailed(claim, code: failure, detail: nil)
            Issue.record("A stale claim must not mutate the entry twice")
        } catch let error as DocumentIntakeError {
            #expect(error == .claimLost)
        }
        let after = try await queue.record(id: record.id)
        #expect(after?.state == .failed)
        let retried = try await queue.retry(id: record.id)
        #expect(retried)
        let pending = try await queue.record(id: record.id)
        #expect(pending?.state == .pending)
    }

    @Test func cancellationKeepsThePayloadAndNeverTouchesOtherOwners() async throws {
        let root = intakeRoot("queue-cancel")
        let sourceRoot = intakeRoot("queue-cancel-source")
        defer { try? FileManager.default.removeItem(at: root) }
        defer { try? FileManager.default.removeItem(at: sourceRoot) }
        let source = try intakeFile(intakeBytes(4_096), name: "Cancel.txt", in: sourceRoot)
        let queue = try DocumentIntakeQueue(root: root)
        let staged = try await DocumentIntakeStager.stage(
            source, root: root, limits: .production, request: intakeRequest()
        )
        let record = try await queue.enqueue(staged)
        let claimed = try await queue.claimNext()
        let claim = try #require(claimed)
        try await queue.markCancelled(claim)
        let cancelled = try await queue.record(id: record.id)
        #expect(cancelled?.state == .cancelled)
        let payload = root.appendingPathComponent("pending")
            .appendingPathComponent(record.id.uuidString)
            .appendingPathComponent(record.stagedFileName)
        #expect(FileManager.default.fileExists(atPath: payload.path))
        let payloadDigest = try DocumentIntakeStorage.sha256(of: payload)
        #expect(payloadDigest.digest == record.sha256)

        // Another owner's non-UUID directory and file must survive both
        // maintenance and explicit discard.
        let otherOwner = root.appendingPathComponent("staging", isDirectory: true)
            .appendingPathComponent("not-an-intake", isDirectory: true)
        try FileManager.default.createDirectory(at: otherOwner, withIntermediateDirectories: true)
        let otherFile = try intakeFile(intakeBytes(8), name: "keep.txt", in: otherOwner)
        let discarded = try await queue.discard(id: record.id)
        #expect(discarded)
        #expect(FileManager.default.fileExists(atPath: otherFile.path))
    }

    @Test func interruptedClaimIsReportedAndCanBeRecoveredWithoutDuplication() async throws {
        let root = intakeRoot("queue-interrupted")
        let sourceRoot = intakeRoot("queue-interrupted-source")
        defer { try? FileManager.default.removeItem(at: root) }
        defer { try? FileManager.default.removeItem(at: sourceRoot) }
        let source = try intakeFile(intakeBytes(8_192), name: "Interrupted.txt", in: sourceRoot)
        let queue = try DocumentIntakeQueue(root: root)
        let request = intakeRequest()
        let staged = try await DocumentIntakeStager.stage(
            source, root: root, limits: .production, request: request
        )
        _ = try await queue.enqueue(staged)
        let claimed = try await queue.claimNext()
        let claim = try #require(claimed)
        // Simulate process death after the importer returned but before ack.
        claim.lock.close()
        let restarted = try DocumentIntakeQueue(root: root)
        let interrupted = try await restarted.interrupted()
        #expect(interrupted.count == 1)
        #expect(interrupted.first?.state == .importing)
        let recovered = try await restarted.takeRecoveryClaim(id: request.eventID)
        let recovery = try #require(recovered)
        try await restarted.markCommitted(
            recovery,
            commit: DocumentIntakeCommit(
                rootDocumentID: request.plannedRootDocumentID,
                documentIDs: [request.plannedRootDocumentID],
                title: "Recovered",
                committedAt: Date()
            )
        )
        let committed = try await restarted.record(id: request.eventID)
        #expect(committed?.state == .committed)
        let stillInterrupted = try await restarted.interrupted()
        #expect(stillInterrupted.isEmpty)
    }

    @Test func stagingDuplicateOfACommittedEntryIsRemovedByMaintenance() async throws {
        let root = intakeRoot("queue-staging-duplicate")
        let sourceRoot = intakeRoot("queue-staging-duplicate-source")
        defer { try? FileManager.default.removeItem(at: root) }
        defer { try? FileManager.default.removeItem(at: sourceRoot) }
        let bytes = intakeBytes(2_048)
        let source = try intakeFile(bytes, name: "One.txt", in: sourceRoot)
        let queue = try DocumentIntakeQueue(root: root)
        let request = intakeRequest()
        let first = try await DocumentIntakeStager.stage(
            source, root: root, limits: .production, request: request
        )
        _ = try await queue.enqueue(first)
        let claimed = try await queue.claimNext()
        let claim = try #require(claimed)
        try await queue.markCommitted(
            claim,
            commit: DocumentIntakeCommit(
                rootDocumentID: request.plannedRootDocumentID,
                documentIDs: [request.plannedRootDocumentID],
                title: "One",
                committedAt: Date()
            )
        )

        // A second copy of the same bytes is left in staging (for example a
        // refused queue publication). It must not become a second import.
        let duplicate = try intakeFile(bytes, name: "Two.txt", in: sourceRoot)
        let duplicateStaged = try await DocumentIntakeStager.stage(
            duplicate, root: root, limits: .production, request: intakeRequest()
        )
        duplicateStaged.activeLock?.close()
        let report = try await queue.maintain(now: Date())
        #expect(report.removedDuplicateStaging == 1)
        #expect(!FileManager.default.fileExists(atPath: duplicateStaged.directory.path))
        let snapshot = try await queue.snapshot()
        #expect(snapshot.records.filter { $0.state == .pending }.isEmpty)
    }

    @Test func capacityRefusesNewEntriesWithoutDeletingTheirStaging() async throws {
        let root = intakeRoot("queue-capacity")
        let sourceRoot = intakeRoot("queue-capacity-source")
        defer { try? FileManager.default.removeItem(at: root) }
        defer { try? FileManager.default.removeItem(at: sourceRoot) }
        var limits = DocumentIntakeLimits.production
        limits.maximumPendingEntries = 1
        let queue = try DocumentIntakeQueue(root: root, limits: limits)
        let first = try intakeFile(intakeBytes(1_024), name: "First.txt", in: sourceRoot)
        let second = try intakeFile(intakeBytes(1_024, seed: 3), name: "Second.txt", in: sourceRoot)
        let firstStaged = try await DocumentIntakeStager.stage(
            first, root: root, limits: limits, request: intakeRequest()
        )
        _ = try await queue.enqueue(firstStaged)
        let secondStaged = try await DocumentIntakeStager.stage(
            second, root: root, limits: limits, request: intakeRequest()
        )
        await expectIntakeError(.queueFull) {
            _ = try await queue.enqueue(secondStaged)
        }
        #expect(FileManager.default.fileExists(atPath: secondStaged.directory.path))
    }
}

// MARK: - Center

@Suite("External document intake center")
@MainActor
struct ExternalDocumentIntakeCenterTests {
    @Test func coldInputQueuesBeforeReadinessAndImportsAfterward() async throws {
        let root = intakeRoot("center-cold")
        let sourceRoot = intakeRoot("center-cold-source")
        defer { try? FileManager.default.removeItem(at: root) }
        defer { try? FileManager.default.removeItem(at: sourceRoot) }
        let source = try intakeFile(intakeBytes(1_024), name: "Cold.txt", in: sourceRoot)
        let library = DocumentIntakeTestNotesLibrary()
        let center = DocumentIntakeCenter(
            root: root,
            notes: DocumentIntakeTestNotesImporter(library: library)
        )

        let eventID = try #require(center.submit(source, sceneID: "scene-a"))
        let queued = await waitUntil { center.queueSnapshot.records.count == 1 }
        #expect(queued)
        let beforeReadyCount = await library.importedCount()
        #expect(beforeReadyCount == 0)
        #expect(center.isReady == false)

        center.markStoresReady()
        let committed = await waitUntil { center.lastReceipt != nil }
        #expect(committed)
        let afterReadyCount = await library.importedCount()
        #expect(afterReadyCount == 1)
        let queue = try #require(center.queue)
        let record = try await queue.record(id: eventID)
        #expect(record?.state == .committed)
        #expect(record?.commit?.rootDocumentID == record?.plannedRootDocumentID)
    }

    @Test func duplicateSceneCallbacksImportExactlyOnce() async throws {
        let root = intakeRoot("center-duplicate")
        let sourceRoot = intakeRoot("center-duplicate-source")
        defer { try? FileManager.default.removeItem(at: root) }
        defer { try? FileManager.default.removeItem(at: sourceRoot) }
        let source = try intakeFile(intakeBytes(1_024), name: "Duplicate.txt", in: sourceRoot)
        let library = DocumentIntakeTestNotesLibrary()
        let center = DocumentIntakeCenter(
            root: root,
            notes: DocumentIntakeTestNotesImporter(library: library)
        )
        center.start()
        center.markStoresReady()
        let first = center.submit(source, sceneID: "scene-a")
        let second = center.submit(source, sceneID: "scene-b")
        #expect(first == second)
        let committed = await waitUntil { center.lastReceipt != nil }
        #expect(committed)
        let count = await library.importedCount()
        #expect(count == 1)
        #expect(center.queueSnapshot.records.count == 1)
    }

    @Test func presentationIsClaimedOnceByTheOriginatingWindow() async throws {
        let root = intakeRoot("center-presentation")
        let sourceRoot = intakeRoot("center-presentation-source")
        defer { try? FileManager.default.removeItem(at: root) }
        defer { try? FileManager.default.removeItem(at: sourceRoot) }
        let source = try intakeFile(intakeBytes(1_024), name: "Present.txt", in: sourceRoot)
        let center = DocumentIntakeCenter(
            root: root,
            notes: DocumentIntakeTestNotesImporter(library: DocumentIntakeTestNotesLibrary())
        )
        center.start()
        center.markStoresReady()
        _ = center.submit(source, sceneID: "scene-a")
        let ready = await waitUntil { center.presentation != nil }
        #expect(ready)
        #expect(center.takePresentation(sceneID: "scene-b") == nil)
        let claimed = center.takePresentation(sceneID: "scene-a")
        #expect(claimed != nil)
        #expect(center.takePresentation(sceneID: "scene-a") == nil)
    }

    @Test func cancellationBeforeCommitKeepsTheInputRecoverable() async throws {
        let root = intakeRoot("center-cancel")
        let sourceRoot = intakeRoot("center-cancel-source")
        defer { try? FileManager.default.removeItem(at: root) }
        defer { try? FileManager.default.removeItem(at: sourceRoot) }
        let bytes = intakeBytes(2_048)
        let source = try intakeFile(bytes, name: "Cancel.txt", in: sourceRoot)
        let gate = DocumentIntakeTestGate()
        let library = DocumentIntakeTestNotesLibrary()
        let center = DocumentIntakeCenter(
            root: root,
            notes: DocumentIntakeTestNotesImporter(library: library, gate: gate)
        )
        center.start()
        center.markStoresReady()
        let eventID = try #require(center.submit(source, sceneID: "scene-a"))
        let importing = await waitUntil { center.activity?.phase == .importing }
        #expect(importing)

        let outcome = await center.cancel(eventID)
        if case .alreadyCommitted = outcome {
            Issue.record("Cancellation raced a real commit; the fixture must block before commit")
        }
        let queue = try #require(center.queue)
        let stored = try await queue.record(id: eventID)
        let record = try #require(stored)
        #expect(record.state == .cancelled)
        #expect(center.lastReceipt == nil)
        let payload = root.appendingPathComponent("pending")
            .appendingPathComponent(eventID.uuidString)
            .appendingPathComponent(record.stagedFileName)
        #expect(FileManager.default.fileExists(atPath: payload.path))
        let original = try Data(contentsOf: source)
        #expect(original == bytes)

        await center.discard(eventID)
        let discarded = try await queue.record(id: eventID)
        #expect(discarded == nil)
    }

    @Test func changedReimportAfterCommitIsNotSuppressed() async throws {
        let root = intakeRoot("center-reimport")
        let sourceRoot = intakeRoot("center-reimport-source")
        defer { try? FileManager.default.removeItem(at: root) }
        defer { try? FileManager.default.removeItem(at: sourceRoot) }
        var bytes = intakeBytes(1_024)
        let source = try intakeFile(bytes, name: "Reimport.txt", in: sourceRoot)
        let library = DocumentIntakeTestNotesLibrary()
        let center = DocumentIntakeCenter(
            root: root,
            notes: DocumentIntakeTestNotesImporter(library: library)
        )
        center.start()
        center.markStoresReady()
        let firstID = try #require(center.submit(source, sceneID: "scene-a"))
        let firstCommitted = await waitUntil { center.lastReceipt != nil }
        #expect(firstCommitted)
        let firstReceipt = try #require(center.lastReceipt)

        bytes = intakeBytes(1_024, seed: 41)
        try bytes.write(to: source, options: .atomic)
        // The 2 s in-process duplicate coalescing window is intentionally
        // short; a deliberate later reimport must not be suppressed.
        try await Task.sleep(for: .milliseconds(3_200))
        let secondID = try #require(center.submit(source, sceneID: "scene-a"))
        #expect(secondID != firstID)
        let secondCommitted = await waitUntil {
            center.queueSnapshot.records.filter { $0.state == .committed }.count == 2
        }
        #expect(secondCommitted)
        let importCount = await library.importedCount()
        #expect(importCount == 2)
        #expect(firstReceipt.documentID != center.lastReceipt?.documentID)
    }
}

// MARK: - Real Notes importer

@Suite("External document intake real Notes importer")
@MainActor
struct ExternalDocumentIntakeNotesImportTests {
    @Test func floenoteCommitsTheExactPlannedIdentityAndRecoversWithoutDuplication() async throws {
        let notesRoot = intakeRoot("notes-store")
        let queueRoot = intakeRoot("notes-queue")
        let sourceRoot = intakeRoot("notes-source")
        defer { try? FileManager.default.removeItem(at: notesRoot) }
        defer { try? FileManager.default.removeItem(at: queueRoot) }
        defer { try? FileManager.default.removeItem(at: sourceRoot) }

        let store = try NotesStore(root: notesRoot)
        let inkSource = try intakeFile(intakeBytes(256), name: "ink.bin", in: sourceRoot)
        let ink = try await store.importResource(
            from: inkSource,
            mediaType: "application/vnd.apple.pencilkit"
        )
        var fixture = NoteDocument(title: "Archive Fixture")
        fixture.pages[0].drawingResourceID = ink
        let created = try await store.create(fixture)
        let archive = notesRoot.appendingPathComponent("Fixture.floenote", isDirectory: false)
        try await NotesArchive.export(document: created, store: store, to: archive)
        let archiveDigest = try DocumentIntakeStorage.sha256(of: archive).digest

        let queue = try DocumentIntakeQueue(root: queueRoot)
        let request = intakeRequest()
        let staged = try await DocumentIntakeStager.stage(
            archive, root: queueRoot, limits: .production, request: request
        )
        _ = try await queue.enqueue(staged)
        let claimed = try await queue.claimNext()
        let claim = try #require(claimed)
        let importer = LiveNotesDocumentImporter(storeProvider: { store })
        let outcome = try await importer.importNotes(
            from: claim.payloadURL,
            kind: .floeNote,
            plannedRootID: request.plannedRootDocumentID,
            displayName: "Fixture.floenote"
        )
        #expect(outcome.rootDocumentID == request.plannedRootDocumentID)
        let afterImport = try await store.documents()
        #expect(afterImport.count == 2)
        let imported = try await store.document(request.plannedRootDocumentID)
        #expect(imported.pages.count == created.pages.count)
        #expect(imported.pages[0].drawingResourceID != nil)
        let untouchedDigest = try DocumentIntakeStorage.sha256(of: archive).digest
        #expect(untouchedDigest == archiveDigest)

        // Commit-before-ack crash: the importer already committed, the queue
        // still says importing, and the process lock is gone.
        claim.lock.close()
        let restarted = try DocumentIntakeQueue(root: queueRoot)
        let interrupted = try await restarted.interrupted()
        #expect(interrupted.count == 1)
        let recovered = try await restarted.takeRecoveryClaim(id: request.eventID)
        let recovery = try #require(recovered)
        let existing = try await importer.existingDocument(id: request.plannedRootDocumentID)
        #expect(existing?.id == request.plannedRootDocumentID)
        let ids = try await importer.documentIDs(inBundle: request.plannedRootDocumentID)
        try await restarted.markCommitted(
            recovery,
            commit: DocumentIntakeCommit(
                rootDocumentID: request.plannedRootDocumentID,
                documentIDs: ids,
                title: existing?.title,
                committedAt: Date()
            )
        )
        let finalCount = try await store.documents()
        #expect(finalCount.count == 2)
        let committed = try await restarted.record(id: request.eventID)
        #expect(committed?.state == .committed)
        #expect(committed?.commit?.rootDocumentID == request.plannedRootDocumentID)
    }

    @Test func corruptArchiveIsRejectedWithoutCreatingADocument() async throws {
        let notesRoot = intakeRoot("notes-corrupt")
        let sourceRoot = intakeRoot("notes-corrupt-source")
        defer { try? FileManager.default.removeItem(at: notesRoot) }
        defer { try? FileManager.default.removeItem(at: sourceRoot) }
        let store = try NotesStore(root: notesRoot)
        let importer = LiveNotesDocumentImporter(storeProvider: { store })
        let corrupt = try intakeFile(intakeBytes(4_096), name: "Broken.floenote", in: sourceRoot)
        do {
            _ = try await importer.importNotes(
                from: corrupt,
                kind: .floeNote,
                plannedRootID: UUID(),
                displayName: "Broken.floenote"
            )
            Issue.record("A non-archive .floenote must not create a document")
        } catch {
            // Expected: the real NotesArchive validation rejects it.
        }
        let documents = try await store.documents()
        #expect(documents.isEmpty)
    }

    @Test func textAndPDFUseTheRealImporterLimitsAndPlannedIdentity() async throws {
        let notesRoot = intakeRoot("notes-imports")
        let sourceRoot = intakeRoot("notes-imports-source")
        defer { try? FileManager.default.removeItem(at: notesRoot) }
        defer { try? FileManager.default.removeItem(at: sourceRoot) }
        let store = try NotesStore(root: notesRoot)
        let importer = LiveNotesDocumentImporter(storeProvider: { store })

        let text = try intakeFile(Data("First line\nSecond line\n".utf8), name: "Synthetic.txt", in: sourceRoot)
        let textID = UUID()
        let textOutcome = try await importer.importNotes(
            from: text, kind: .text, plannedRootID: textID, displayName: "Synthetic.txt"
        )
        #expect(textOutcome.rootDocumentID == textID)
        let textDocument = try await store.document(textID)
        #expect(textDocument.title == "Synthetic")
        #expect(!textDocument.pages.isEmpty)

        let office = try intakeFile(intakeBytes(64), name: "Workbook.XLSX", in: sourceRoot)
        let officeID = UUID()
        _ = try await importer.importNotes(
            from: office,
            kind: .office,
            plannedRootID: officeID,
            displayName: "Workbook.XLSX"
        )
        let officeDocument = try await store.document(officeID)
        #expect(officeDocument.title == "Workbook")
        #expect(officeDocument.officeFileName == "Workbook.xlsx")

        let oversized = try intakeFile(
            Data(repeating: 65, count: 2_000_001),
            name: "TooLarge.txt",
            in: sourceRoot
        )
        do {
            _ = try await importer.importNotes(
                from: oversized, kind: .text, plannedRootID: UUID(), displayName: "TooLarge.txt"
            )
            Issue.record("The real text importer must reject a file over 2 MB")
        } catch let error as NoteError {
            if case .invalidOperation = error {
                // Expected: the existing 2 MB text bound is preserved.
            } else {
                Issue.record("Unexpected NoteError: \(error)")
            }
        } catch {
            Issue.record("Unexpected error: \(error)")
        }

        let renderer = UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 320, height: 480))
        let pdfData = renderer.pdfData { context in
            context.beginPage()
            ("Floe intake PDF" as NSString).draw(
                at: CGPoint(x: 24, y: 24),
                withAttributes: [.font: UIFont.systemFont(ofSize: 18)]
            )
        }
        let pdf = try intakeFile(pdfData, name: "Synthetic.pdf", in: sourceRoot)
        let pdfID = UUID()
        let pdfOutcome = try await importer.importNotes(
            from: pdf, kind: .pdf, plannedRootID: pdfID, displayName: "Synthetic.pdf"
        )
        #expect(pdfOutcome.rootDocumentID == pdfID)
        let pdfDocument = try await store.document(pdfID)
        #expect(pdfDocument.pages.count == 1)
        #expect(pdfDocument.pages[0].pdfPageIndex == 0)
    }
}

// MARK: - Recovery and copy

@Suite("External document intake recovery decisions")
@MainActor
struct ExternalDocumentIntakeRecoveryTests {
    @Test func interruptedCanvasImportRecoversTheExactCommittedIdentity() async throws {
        let root = intakeRoot("canvas-recovery")
        let sourceRoot = intakeRoot("canvas-recovery-source")
        defer { try? FileManager.default.removeItem(at: root) }
        defer { try? FileManager.default.removeItem(at: sourceRoot) }
        let source = try intakeFile(intakeBytes(4_096), name: "Canvas.floecanvas", in: sourceRoot)
        let canvasLibrary = DocumentIntakeTestCanvasLibrary()
        let notesLibrary = DocumentIntakeTestNotesLibrary()

        let firstQueue = try DocumentIntakeQueue(root: root)
        let request = intakeRequest()
        let staged = try await DocumentIntakeStager.stage(
            source, root: root, limits: .production, request: request
        )
        _ = try await firstQueue.enqueue(staged)
        let claimed = try await firstQueue.claimNext()
        let claim = try #require(claimed)
        let canvasImporter = DocumentIntakeTestCanvasImporter(library: canvasLibrary)
        _ = try await canvasImporter.importCanvas(
            from: claim.payloadURL,
            plannedCanvasID: request.plannedRootDocumentID
        )
        let plannedIDs = await canvasLibrary.plannedIDs
        #expect(plannedIDs == [request.plannedRootDocumentID])
        // Crash after the restore finalized, before the durable receipt.
        claim.lock.close()

        let center = DocumentIntakeCenter(
            root: root,
            notes: DocumentIntakeTestNotesImporter(library: notesLibrary),
            canvas: canvasImporter
        )
        center.start()
        center.markStoresReady()
        let committed = await waitUntil {
            center.queueSnapshot.records.first?.state == .committed
        }
        #expect(committed)
        // The exact committed identity is recovered without a second import.
        let recoveryCallCount = await canvasLibrary.calls
        #expect(recoveryCallCount == 1)
        let cleanupCount = await canvasLibrary.cleanupCalls.count
        #expect(cleanupCount == 0)
        let receipt = try #require(center.lastReceipt)
        #expect(receipt.canvasID == request.plannedRootDocumentID)
        #expect(receipt.documentID == nil)
        let record = center.queueSnapshot.records.first
        #expect(record?.commit?.canvasID == request.plannedRootDocumentID)
    }

    @Test func interruptedCanvasImportWithOwnedPartialPayloadCleansAndRequeues() async throws {
        let root = intakeRoot("canvas-partial")
        let sourceRoot = intakeRoot("canvas-partial-source")
        defer { try? FileManager.default.removeItem(at: root) }
        defer { try? FileManager.default.removeItem(at: sourceRoot) }
        let source = try intakeFile(intakeBytes(4_096), name: "Canvas.floecanvas", in: sourceRoot)
        let canvasLibrary = DocumentIntakeTestCanvasLibrary()
        let notesLibrary = DocumentIntakeTestNotesLibrary()

        let firstQueue = try DocumentIntakeQueue(root: root)
        let request = intakeRequest()
        // The interrupted attempt left an owned partial payload behind.
        await canvasLibrary.markOwnedPartialPayload(request.plannedRootDocumentID)
        let staged = try await DocumentIntakeStager.stage(
            source, root: root, limits: .production, request: request
        )
        _ = try await firstQueue.enqueue(staged)
        let claimed = try await firstQueue.claimNext()
        let claim = try #require(claimed)
        // Crash after the payload commit, before the registry write: the
        // canvas does not exist yet, but this attempt owns a partial payload.
        claim.lock.close()

        let center = DocumentIntakeCenter(
            root: root,
            notes: DocumentIntakeTestNotesImporter(library: notesLibrary),
            canvas: DocumentIntakeTestCanvasImporter(library: canvasLibrary)
        )
        center.start()
        center.markStoresReady()
        let committed = await waitUntil {
            center.queueSnapshot.records.first?.state == .committed
        }
        #expect(committed)
        // Exactly one cleanup of the owned partial payload and a single
        // re-import under the same planned identity: no duplicate, no clobber.
        let cleanupCalls = await canvasLibrary.cleanupCalls
        #expect(cleanupCalls == [request.plannedRootDocumentID])
        let plannedIDs = await canvasLibrary.plannedIDs
        #expect(plannedIDs == [request.plannedRootDocumentID])
        let receipt = try #require(center.lastReceipt)
        #expect(receipt.canvasID == request.plannedRootDocumentID)
    }

    @Test func retryAndDiscardSurfaceARealSaveFailureAndKeepTheInputRecoverable() async throws {
        let root = intakeRoot("queue-save-failure")
        let sourceRoot = intakeRoot("queue-save-failure-source")
        defer { try? FileManager.default.removeItem(at: root) }
        defer { try? FileManager.default.removeItem(at: sourceRoot) }
        let source = try intakeFile(intakeBytes(2_048), name: "Save.txt", in: sourceRoot)

        // Build a failed pending entry directly; the center under test shares
        // the durable queue root.
        let request = intakeRequest()
        let queue = try DocumentIntakeQueue(root: root)
        let staged = try await DocumentIntakeStager.stage(
            source, root: root, limits: .production, request: request
        )
        _ = try await queue.enqueue(staged)
        let claimed = try await queue.claimNext()
        let claim = try #require(claimed)
        try await queue.markFailed(claim, code: .damaged, detail: nil)

        let center = DocumentIntakeCenter(
            root: root,
            notes: DocumentIntakeTestNotesImporter(library: DocumentIntakeTestNotesLibrary())
        )
        // Make the record directory unwritable so the required state
        // transition cannot persist, then ask for a retry.
        let recordDirectory = root
            .appendingPathComponent("pending", isDirectory: true)
            .appendingPathComponent(request.eventID.uuidString, isDirectory: true)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o555], ofItemAtPath: recordDirectory.path
        )
        await center.retry(request.eventID)
        let saveFailure = await waitUntil {
            guard let notice = center.notice else { return false }
            return notice.kind == .failure
                && notice.message == DocumentIntakeFailure.ioFailure.message
                && notice.eventID == request.eventID
        }
        #expect(saveFailure)
        // The durable input was preserved by the failed transition and an
        // explicit discard still works once the directory is writable again.
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: recordDirectory.path
        )
        await center.discard(request.eventID)
        let discarded = try await queue.record(id: request.eventID)
        #expect(discarded == nil)
    }

    @Test func recoveryClaimDamagedMarkWriteFailureIsSurfaced() async throws {
        let root = intakeRoot("queue-damaged-save")
        let sourceRoot = intakeRoot("queue-damaged-save-source")
        defer { try? FileManager.default.removeItem(at: root) }
        defer { try? FileManager.default.removeItem(at: sourceRoot) }
        let source = try intakeFile(intakeBytes(2_048), name: "Damaged.txt", in: sourceRoot)
        let queue = try DocumentIntakeQueue(root: root)
        let request = intakeRequest()
        let staged = try await DocumentIntakeStager.stage(
            source, root: root, limits: .production, request: request
        )
        _ = try await queue.enqueue(staged)
        let claimed = try await queue.claimNext()
        let claim = try #require(claimed)
        let directory = root
            .appendingPathComponent("pending", isDirectory: true)
            .appendingPathComponent(request.eventID.uuidString, isDirectory: true)
        // Damage the payload, then make the entry directory unwritable so the
        // required `.needsReview` state transition cannot persist.
        try Data(intakeBytes(8)).write(
            to: directory.appendingPathComponent("payload.txt", isDirectory: false),
            options: .atomic
        )
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o555], ofItemAtPath: directory.path
        )
        defer {
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o755], ofItemAtPath: directory.path
            )
        }
        claim.lock.close()
        let restarted = try DocumentIntakeQueue(root: root)
        let interrupted = try await restarted.interrupted()
        #expect(interrupted.count == 1)
        await expectIntakeError(.ioFailure) {
            _ = try await restarted.takeRecoveryClaim(id: request.eventID)
        }
    }

    @Test func compactCopyIsRegisteredAndNeverContainsInternalIdentity() {
        let keys = [
            "document.intake.opening",
            "document.intake.saved_in_notes",
            "document.intake.saved_in_canvas",
            "document.intake.busy_switch",
            "document.intake.unsupported",
            "document.intake.not_a_file",
            "document.intake.link_not_allowed",
            "document.intake.empty",
            "document.intake.too_large",
            "document.intake.access_denied",
            "document.intake.damaged",
            "document.intake.import_failed",
            "document.intake.notes_unavailable",
            "document.intake.canvas_unavailable",
            "document.intake.queue_full",
            "document.intake.queue_unavailable",
            "document.intake.io_failed",
            "document.intake.cancelled",
            "document.intake.interrupted",
        ]
        for key in keys {
            let value = FloeL10n.l(key)
            #expect(value != key)
            #expect(!value.contains("document.intake."))
            #expect(!value.contains("payload."))
        }
        // The retained-result Open action is registered copy too.
        let open = FloeL10n.l("document.intake.open_result")
        #expect(open != "document.intake.open_result")
        #expect(!open.contains("document.intake."))
    }
}

// MARK: - Presentation fences

@Suite("External document intake presentation fences")
@MainActor
struct ExternalDocumentIntakePresentationFenceTests {
    @Test func navigationAwayDuringImportRetainsAResultWithARealOpenAction() async throws {
        let root = intakeRoot("fence-navigation")
        let sourceRoot = intakeRoot("fence-navigation-source")
        defer { try? FileManager.default.removeItem(at: root) }
        defer { try? FileManager.default.removeItem(at: sourceRoot) }
        let source = try intakeFile(intakeBytes(1_024), name: "Navigate.txt", in: sourceRoot)
        let center = DocumentIntakeCenter(
            root: root,
            notes: DocumentIntakeTestNotesImporter(library: DocumentIntakeTestNotesLibrary())
        )
        // The root captured the origin selection at submit time; the user
        // navigates away before the import completes.
        var selection: String? = "origin"
        center.setRoutingEligibility { _ in selection == "origin" }
        center.start()
        center.markStoresReady()
        _ = try #require(center.submit(source, sceneID: "scene-a"))
        selection = "elsewhere"
        let retained = await waitUntil { center.openOffer != nil }
        #expect(retained)
        // No automatic presentation was armed: the current task/editor is not
        // stolen, but the committed result is reachable through the notice.
        #expect(center.presentation == nil)
        #expect(center.notice?.canOpen == true)
        let offer = try #require(center.openOffer)
        #expect(offer.reason == .userNavigated)

        // The explicit user Open bypasses the fence and re-arms the once-only,
        // scene-bound presentation for the originating scene.
        center.openCommittedResult()
        #expect(center.openOffer == nil)
        #expect(center.presentation != nil)
        #expect(center.takePresentation(sceneID: "scene-b") == nil)
        let claimed = center.takePresentation(sceneID: "scene-a")
        #expect(claimed?.documentID == offer.documentID)
        #expect(center.takePresentation(sceneID: "scene-a") == nil)
    }

    @Test func unchangedSelectionStillPresentsAutomatically() async throws {
        let root = intakeRoot("fence-unchanged")
        let sourceRoot = intakeRoot("fence-unchanged-source")
        defer { try? FileManager.default.removeItem(at: root) }
        defer { try? FileManager.default.removeItem(at: sourceRoot) }
        let source = try intakeFile(intakeBytes(1_024), name: "Stay.txt", in: sourceRoot)
        let center = DocumentIntakeCenter(
            root: root,
            notes: DocumentIntakeTestNotesImporter(library: DocumentIntakeTestNotesLibrary())
        )
        var selection: String? = "origin"
        center.setRoutingEligibility { _ in selection == "origin" }
        center.start()
        center.markStoresReady()
        _ = try #require(center.submit(source, sceneID: "scene-a"))
        let presented = await waitUntil { center.presentation != nil }
        #expect(presented)
        #expect(center.openOffer == nil)
        #expect(center.notice?.canOpen != true)
    }

    @Test func deferredBusyTargetKeepsAKindCorrectOpenOffer() async throws {
        let root = intakeRoot("fence-busy")
        let sourceRoot = intakeRoot("fence-busy-source")
        defer { try? FileManager.default.removeItem(at: root) }
        defer { try? FileManager.default.removeItem(at: sourceRoot) }
        let center = DocumentIntakeCenter(
            root: root,
            notes: DocumentIntakeTestNotesImporter(library: DocumentIntakeTestNotesLibrary())
        )
        center.start()
        center.markStoresReady()
        let documentID = UUID()
        let deferred = DocumentIntakePresentation(
            id: UUID(),
            kind: .floeNote,
            documentID: documentID,
            canvasID: nil,
            title: "Busy Target",
            sceneID: "scene-a"
        )
        center.deferPresentation(deferred)
        // A deferred NOTES result must not claim the Canvas success copy and
        // must carry a real Open action.
        let offer = try #require(center.openOffer)
        #expect(offer.reason == .targetBusy)
        #expect(offer.documentID == documentID)
        #expect(center.notice?.canOpen == true)
        #expect(center.notice?.message == FloeL10n.l("document.intake.saved_in_notes"))
    }

    @Test func noteOpenRequestClaimsOnceAcrossWindows() async throws {
        let root = intakeRoot("fence-note-claim")
        defer { try? FileManager.default.removeItem(at: root) }
        let center = DocumentIntakeCenter(
            root: root,
            notes: DocumentIntakeTestNotesImporter(library: DocumentIntakeTestNotesLibrary())
        )
        let presentation = DocumentIntakePresentation(
            id: UUID(),
            kind: .floeNote,
            documentID: UUID(),
            canvasID: nil,
            title: "Cross Window",
            sceneID: "scene-a"
        )
        center.presentNotes(presentation)
        let request = try #require(center.noteOpenRequest)
        #expect(request.sceneID == "scene-a")
        // A second window (or a late replay) cannot adopt the same request.
        #expect(center.claimNoteOpen(request) == true)
        #expect(center.claimNoteOpen(request) == false)
        #expect(center.noteOpenRequest == nil)
    }

    @Test func nonLatestCompletionStillReportsSuccessWithoutPresentation() async throws {
        let root = intakeRoot("fence-late-callback")
        let sourceRoot = intakeRoot("fence-late-callback-source")
        defer { try? FileManager.default.removeItem(at: root) }
        defer { try? FileManager.default.removeItem(at: sourceRoot) }
        let first = try intakeFile(intakeBytes(1_024), name: "First.txt", in: sourceRoot)
        let second = try intakeFile(intakeBytes(1_024, seed: 9), name: "Second.txt", in: sourceRoot)
        let center = DocumentIntakeCenter(
            root: root,
            notes: DocumentIntakeTestNotesImporter(library: DocumentIntakeTestNotesLibrary())
        )
        center.start()
        center.markStoresReady()
        _ = try #require(center.submit(first, sceneID: "scene-a"))
        // A newer request supersedes the first while it is still queued.
        try await Task.sleep(for: .milliseconds(2_200))
        _ = try #require(center.submit(second, sceneID: "scene-a"))
        let presented = await waitUntil { center.presentation != nil }
        #expect(presented)
        // Both commit; only the latest arms a presentation, and the earlier
        // completion still reports its success without stealing the route.
        let allCommitted = await waitUntil {
            center.queueSnapshot.records.filter { $0.state == .committed }.count == 2
        }
        #expect(allCommitted)
        let presentation = try #require(center.presentation)
        let records = center.queueSnapshot.records
        let firstRecord = try #require(records.first { $0.displayName == "First.txt" })
        #expect(presentation.id != firstRecord.id)
    }
}

// MARK: - Canvas package exact identity (module level)

@Suite("Canvas package exact identity restore")
@MainActor
struct CanvasPackageExactIdentityRestoreTests {
    /// Builds a real `.floecanvas` package with one bound child project and
    /// restores it through the real staged verifier against a real layout.
    @Test func suppliedIdentityIsUsedVerbatimAndRepeatedRestoresLeaveNoOrphans() throws {
        let base = intakeRoot("canvas-restore-module")
        defer { try? FileManager.default.removeItem(at: base) }
        let manager = FileManager.default
        let projectsRoot = base.appendingPathComponent("MediaProjects", isDirectory: true)
        let materialsRoot = base.appendingPathComponent("Materials", isDirectory: true)
        let workbenchRoot = base.appendingPathComponent("WorkbenchRoot", isDirectory: true)
        let draftsRoot = base.appendingPathComponent("CanvasDrafts", isDirectory: true)
        let cadRoot = base.appendingPathComponent("CanvasCAD", isDirectory: true)
        for directory in [projectsRoot, materialsRoot, workbenchRoot, draftsRoot, cadRoot] {
            try manager.createDirectory(at: directory, withIntermediateDirectories: true)
        }

        // One archived child media project bound from a canvas node.
        let archivedChildID = UUID()
        let childJSON = try JSONSerialization.data(withJSONObject: [
            "id": archivedChildID.uuidString,
            "schemaVersion": 1,
            "assets": [],
        ])
        try childJSON.write(
            to: projectsRoot.appendingPathComponent(
                "media-project-\(archivedChildID.uuidString.lowercased()).json"),
            options: .atomic
        )
        var node = CanvasNode(
            kind: .text,
            position: CanvasPoint(x: 0, y: 0),
            size: CanvasSize(width: 120, height: 80)
        )
        node.childProjectBinding = CanvasChildProjectBinding(
            projectID: archivedChildID,
            appliedRevision: 0
        )
        let document = CanvasDocument(name: "Sheet", nodes: [node])
        let project = CanvasProject(
            id: UUID(),
            name: "Exact Identity Package",
            documents: [document],
            selectedDocumentID: document.id
        )
        let package = base.appendingPathComponent("Exact Identity.floecanvas")
        try CanvasBackupPackage.exportToURL(
            project: project,
            destination: package,
            layout: CanvasBackupPackage.ExportLayout(
                projectsRoot: projectsRoot,
                materialsRoot: materialsRoot,
                fallbackMediaRoot: workbenchRoot,
                cadDraftsRoot: draftsRoot,
                nativeCADRoot: cadRoot
            )
        )

        func restoredChildFiles(in restoreRoot: URL) throws -> [URL] {
            try manager.contentsOfDirectory(
                at: restoreRoot.appendingPathComponent("MediaProjects", isDirectory: true),
                includingPropertiesForKeys: nil
            ).filter { $0.lastPathComponent.hasPrefix("media-project-") }
        }

        let restoreRoot = base.appendingPathComponent("restore", isDirectory: true)
        let plannedID = UUID()
        let first = try CanvasBackupPackage.restore(
            fileURL: package, floeRoot: restoreRoot, canvasID: plannedID
        )
        // The caller-supplied identity is used verbatim, never rematched.
        #expect(first.project.id == plannedID)
        // The archived child identity is never reused either.
        #expect(first.project.documents[0].nodes[0].childProjectBinding?.projectID != archivedChildID)
        let firstChildren = try restoredChildFiles(in: restoreRoot)
        #expect(firstChildren.count == 1)

        // A retried restore for the same planned identity reuses the exact
        // same child paths: no orphan child projects accumulate.
        let second = try CanvasBackupPackage.restore(
            fileURL: package, floeRoot: restoreRoot, canvasID: plannedID
        )
        #expect(second.project.id == plannedID)
        #expect(second.project.documents[0].nodes[0].childProjectBinding?.projectID
                == first.project.documents[0].nodes[0].childProjectBinding?.projectID)
        let secondChildren = try restoredChildFiles(in: restoreRoot)
        #expect(secondChildren.count == 1)

        // A different supplied identity derives a different child identity.
        let otherID = UUID()
        let third = try CanvasBackupPackage.restore(
            fileURL: package, floeRoot: restoreRoot, canvasID: otherID
        )
        #expect(third.project.id == otherID)
        let thirdChildren = try restoredChildFiles(in: restoreRoot)
        #expect(thirdChildren.count == 2)

        // Callers that pass no identity keep the fresh random default.
        let fresh = try CanvasBackupPackage.restore(fileURL: package, floeRoot: restoreRoot)
        #expect(fresh.project.id != plannedID)
        #expect(fresh.project.id != otherID)
        let freshChildren = try restoredChildFiles(in: restoreRoot)
        #expect(freshChildren.count == 3)
    }
}
@Suite("Document intake actual route identity")
@MainActor
struct DocumentIntakeRouteIdentityTests {
    private func presentation(_ eventID: UUID, scene: String = "a") -> DocumentIntakePresentation {
        DocumentIntakePresentation(id: eventID, kind: .floeNote,
            documentID: UUID(), canvasID: nil, title: "Imported", sceneID: scene)
    }

    @Test func settingsAndMoreNavigationFenceUnchangedTaskSelection() {
        let registry = DocumentIntakeRoutingRegistry()
        registry.setActive(true, sceneID: "a")
        let initial = DocumentIntakeRouteSnapshot(workbench: .conversation(UUID()))
        let event = UUID()
        registry.capture(initial, sceneID: "a", eventID: event)
        var current = initial
        current.settingsPresented = true
        #expect(!registry.canPresent(presentation(event), currentRoute: current))
        registry.capture(initial, sceneID: "a", eventID: event)
        current = initial
        current.selection = .more
        current.morePath = [.settings]
        #expect(!registry.canPresent(presentation(event), currentRoute: current))
    }

    @Test func noteChangedWithinSameRouteDoesNotLoseUserSelection() {
        let registry = DocumentIntakeRoutingRegistry()
        registry.setActive(true, sceneID: "a")
        registry.noteSelectionChanged(UUID(), sceneID: "a")
        let route = DocumentIntakeRouteSnapshot(selection: .more,
            sidebar: .more(.notes), morePath: [.notes])
        let event = UUID()
        registry.capture(route, sceneID: "a", eventID: event)
        registry.noteSelectionChanged(UUID(), sceneID: "a")
        #expect(!registry.canPresent(presentation(event), currentRoute: route))
    }

    @Test func correctSceneClaimsOnceAndMissingOrInactiveOriginDoesNotOpen() {
        let registry = DocumentIntakeRoutingRegistry()
        let route = DocumentIntakeRouteSnapshot()
        let event = UUID()
        registry.setActive(true, sceneID: "a")
        registry.capture(route, sceneID: "a", eventID: event)
        #expect(!registry.canPresent(presentation(event, scene: "b"), currentRoute: route))
        #expect(registry.canPresent(presentation(event), currentRoute: route))
        #expect(!registry.canPresent(presentation(event), currentRoute: route))
        registry.capture(route, sceneID: "a", eventID: event)
        registry.setActive(false, sceneID: "a")
        registry.setActive(true, sceneID: "b")
        #expect(!registry.canPresent(presentation(event), currentRoute: route))
        #expect(!registry.canPresent(presentation(UUID()), currentRoute: route))
    }

    @Test func boundedOriginEvictionDefersOldestInsteadOfGuessing() {
        let registry = DocumentIntakeRoutingRegistry()
        let route = DocumentIntakeRouteSnapshot()
        registry.setActive(true, sceneID: "a")
        let events = (0..<65).map { _ in UUID() }
        for event in events { registry.capture(route, sceneID: "a", eventID: event) }
        #expect(!registry.canPresent(presentation(events[0]), currentRoute: route))
        #expect(registry.canPresent(presentation(events[64]), currentRoute: route))
    }

    @Test func explicitOpenBelongsToWindowWhereUserPressedOpen() throws {
        let root = intakeRoot("explicit-window")
        defer { try? FileManager.default.removeItem(at: root) }
        let center = DocumentIntakeCenter(root: root,
            notes: DocumentIntakeTestNotesImporter(library: DocumentIntakeTestNotesLibrary()))
        let offer = presentation(UUID())
        center.deferPresentation(offer)
        center.openCommittedResult(sceneID: "b")
        #expect(center.takePresentation(sceneID: "a") == nil)
        let opened = try #require(center.takePresentation(sceneID: "b"))
        #expect(opened.documentID == offer.documentID)
        #expect(center.takePresentation(sceneID: "b") == nil)
    }
}
#endif
