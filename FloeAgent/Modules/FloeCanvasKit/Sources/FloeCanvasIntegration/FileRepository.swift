import Foundation
import FloeCanvasCore

/// File-backed document authority at the explicit root supplied by the host.
/// The App binds each new canvas to its personal-project registry before
/// constructing this repository. Authorization and library moves remain host
/// responsibilities; legacy canvases retain their existing repository.
///
/// Design (aligned with FloeDiagramKit's FileDiagramRepository):
///
/// - The repository is an actor; every load/mutation also takes a
///   per-document `flock`, so two instances in one process or writers in
///   different processes serialize on the same revision check.
/// - The commit authority is a single `manifest.json` per canvas, written
///   atomically last. It binds the snapshot blob, the history blob and the
///   idempotency receipts of one commit into ONE record: a crash before the
///   manifest rename commits nothing, a crash after commits everything.
///   Recovery never guesses from uncommitted blobs.
/// - `blobs/<sha256>.json` are immutable, content-addressed payloads. Failed
///   or superseded artifacts are left in place (nothing truncates the old
///   record); a later successful commit supersedes them.
///
/// Layout:
///
///     <root>/canvases/<canvasID>/<canvasID>.lock
///     <root>/canvases/<canvasID>/manifest.json
///     <root>/canvases/<canvasID>/blobs/<sha256>.json
public actor FileCanvasRepository: CanvasDocumentStore {
    public let root: URL
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    /// Test hook: when true the next mutation fails just before the atomic
    /// manifest write, exercising crash-at-commit-point recovery.
    private var failBeforeManifestWrite = false
    /// One decoded immutable record, bounded across documents. The live
    /// manifest and BOTH blob digests are still read/verified on every
    /// access; another writer or on-disk corruption cannot be hidden by it.
    private var decodedRecord: DecodedRecord?

    public init(root: URL) throws {
        let standardized = root.standardizedFileURL
        // Refuse a filesystem/volume root: callers must choose a dedicated
        // directory so qualification data never spreads unbounded.
        guard standardized.pathComponents.count > 2 else {
            throw CanvasKitError.repositoryRootViolation("root too broad: \(root.path)")
        }
        self.root = standardized
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        self.encoder = encoder
        self.decoder = JSONDecoder()
        try FileManager.default.createDirectory(
            at: standardized, withIntermediateDirectories: true)
    }

    // MARK: Records

    /// One atomic commit record: the ONLY authority for recovery.
    fileprivate struct Manifest: Codable {
        var schemaVersion: Int
        var canvasID: UUID
        var snapshotBlob: String
        var snapshotRevision: Int64
        var historyBlob: String
        var receipts: [CanvasCommitReceipt]
    }

    private func canvasDirectory(_ canvasID: UUID) -> URL {
        root.appendingPathComponent("canvases", isDirectory: true)
            .appendingPathComponent(canvasID.uuidString, isDirectory: true)
    }

    private func manifestURL(_ canvasID: UUID) -> URL {
        canvasDirectory(canvasID).appendingPathComponent("manifest.json")
    }

    // MARK: Locking

    /// Per-document exclusive flock. On Darwin, flock locks are per open
    /// file description, so separate instances in the same process serialize
    /// just like separate processes.
    private func withDocumentLock<T>(
        _ canvasID: UUID,
        _ operation: () throws -> T
    ) throws -> T {
        let directory = canvasDirectory(canvasID)
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true)
        let lockURL = directory.appendingPathComponent("\(canvasID.uuidString).lock")
        let fd = Darwin.open(lockURL.path, O_CREAT | O_RDWR | O_NOFOLLOW, S_IRUSR | S_IWUSR)
        guard fd >= 0 else {
            throw CanvasKitError.io("open document lock: \(errno)")
        }
        defer { _ = Darwin.close(fd) }
        while flock(fd, LOCK_EX) != 0 {
            if errno != EINTR {
                throw CanvasKitError.io("document lock: \(errno)")
            }
        }
        defer { _ = flock(fd, LOCK_UN) }
        return try operation()
    }

    /// Async variant for mutations that await the repository engine while
    /// still holding the per-document lock.
    private func withDocumentLock<T>(
        _ canvasID: UUID,
        operation: () async throws -> T
    ) async throws -> T {
        let directory = canvasDirectory(canvasID)
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true)
        let lockURL = directory.appendingPathComponent("\(canvasID.uuidString).lock")
        let fd = Darwin.open(lockURL.path, O_CREAT | O_RDWR | O_NOFOLLOW, S_IRUSR | S_IWUSR)
        guard fd >= 0 else {
            throw CanvasKitError.io("open document lock: \(errno)")
        }
        defer { _ = Darwin.close(fd) }
        while flock(fd, LOCK_EX) != 0 {
            if errno != EINTR {
                throw CanvasKitError.io("document lock: \(errno)")
            }
        }
        defer { _ = flock(fd, LOCK_UN) }
        return try await operation()
    }

    // MARK: Atomic file write (staged, fsynced, same-directory rename)

    /// Staged write: unique O_EXCL staging file, full write + fsync, atomic
    /// rename over any existing destination, then directory fsync. The
    /// staging file is unlinked on failure; other writers' staging files are
    /// never touched.
    fileprivate func atomicWrite(_ data: Data, to destination: URL) throws {
        let directory = destination.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true)
        let staging = directory.appendingPathComponent(
            ".\(destination.lastPathComponent).\(UUID().uuidString).tmp")
        let fd = Darwin.open(staging.path, O_CREAT | O_EXCL | O_WRONLY | O_NOFOLLOW, S_IRUSR | S_IWUSR)
        guard fd >= 0 else {
            throw CanvasKitError.io("stage output: \(errno)")
        }
        var open = true
        defer {
            if open { _ = Darwin.close(fd) }
            _ = unlink(staging.path)
        }
        try data.withUnsafeBytes { buffer in
            var offset = 0
            while offset < buffer.count {
                let count = Darwin.write(fd, buffer.baseAddress!.advanced(by: offset), buffer.count - offset)
                if count < 0 {
                    if errno == EINTR { continue }
                    throw CanvasKitError.io("write staged output: \(errno)")
                }
                guard count > 0 else {
                    throw CanvasKitError.io("short write")
                }
                offset += count
            }
        }
        guard fsync(fd) == 0 else {
            throw CanvasKitError.io("flush staged output: \(errno)")
        }
        _ = Darwin.close(fd)
        open = false
        guard rename(staging.path, destination.path) == 0 else {
            throw CanvasKitError.io("replace output: \(errno)")
        }
        let directoryFD = Darwin.open(directory.path, O_RDONLY)
        if directoryFD >= 0 {
            _ = fsync(directoryFD)
            _ = Darwin.close(directoryFD)
        }
    }

    // MARK: Read helpers

    private func verifiedBlob(hash: String, canvasID: UUID) throws -> Data {
        guard hash.count == 64, hash.allSatisfy({ $0.isHexDigit }) else {
            throw CanvasKitError.io("invalid committed blob identity")
        }
        let url = canvasDirectory(canvasID)
            .appendingPathComponent("blobs", isDirectory: true)
            .appendingPathComponent("\(hash).json")
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else {
            throw CanvasKitError.io("manifest references missing blob \(hash)")
        }
        guard CanvasBatchDigest.hash(data) == hash else {
            throw CanvasKitError.io("committed blob digest mismatch \(hash)")
        }
        return data
    }

    private struct DecodedRecord {
        var canvasID: UUID
        var snapshotHash: String
        var historyHash: String
        var snapshot: CanvasSnapshot
        var history: CanvasHistoryState
    }

    private struct PersistedState {
        var snapshot: CanvasSnapshot
        var history: CanvasHistoryState
        var receipts: [CanvasCommitReceipt]
    }

    /// Loads the committed state. A missing manifest is a missing canvas; a
    /// corrupt manifest is an I/O failure — the store never falls back to
    /// guessing from uncommitted blobs.
    private func readCommitted(_ canvasID: UUID) throws -> PersistedState {
        let url = manifestURL(canvasID)
        guard let data = FileManager.default.contents(atPath: url.path) else {
            // The canvas directory exists (blobs, lock) but its committed
            // record is gone: fail closed instead of guessing. A directory
            // that never existed is an ordinary missing canvas.
            var isDirectory: ObjCBool = false
            let exists = FileManager.default.fileExists(
                atPath: canvasDirectory(canvasID).path, isDirectory: &isDirectory)
            if exists, isDirectory.boolValue {
                throw CanvasKitError.io(
                    "manifest missing for canvas \(canvasID); committed record absent")
            }
            throw CanvasKitError.missingEntity("canvas \(canvasID) under \(root.path)")
        }
        guard let manifest = try? decoder.decode(Manifest.self, from: data) else {
            throw CanvasKitError.io("corrupt manifest for canvas \(canvasID); committed record unreadable")
        }
        guard manifest.schemaVersion == 1, manifest.canvasID == canvasID else {
            throw CanvasKitError.io("manifest schema or canvas mismatch")
        }
        let snapshotData = try verifiedBlob(hash: manifest.snapshotBlob, canvasID: canvasID)
        let historyData = try verifiedBlob(hash: manifest.historyBlob, canvasID: canvasID)
        let snapshot: CanvasSnapshot
        let history: CanvasHistoryState
        if let cached = decodedRecord, cached.canvasID == canvasID,
           cached.snapshotHash == manifest.snapshotBlob, cached.historyHash == manifest.historyBlob {
            snapshot = cached.snapshot
            history = cached.history
        } else {
            snapshot = try decoder.decode(CanvasSnapshot.self, from: snapshotData)
            history = try decoder.decode(CanvasHistoryState.self, from: historyData)
        }
        guard snapshot.id == canvasID, snapshot.revision == manifest.snapshotRevision else {
            throw CanvasKitError.io("committed snapshot identity or revision mismatch")
        }
        decodedRecord = DecodedRecord(canvasID: canvasID,
            snapshotHash: manifest.snapshotBlob, historyHash: manifest.historyBlob,
            snapshot: snapshot, history: history)
        return PersistedState(
            snapshot: snapshot, history: history, receipts: manifest.receipts)
    }

    /// Request IDs consumed by other canvases (unlocked best-effort scan;
    /// corrupt foreign manifests are skipped — data safety comes from the
    /// per-document CAS, this only prevents accidental cross-canvas replay).
    private func foreignRequestIDs(excluding canvasID: UUID) -> Set<UUID> {
        let canvases = root.appendingPathComponent("canvases", isDirectory: true)
        guard let dirs = try? FileManager.default.contentsOfDirectory(
            at: canvases, includingPropertiesForKeys: [.isDirectoryKey]) else {
            return []
        }
        var foreign: Set<UUID> = []
        for dir in dirs where dir.hasDirectoryPath && dir.lastPathComponent != canvasID.uuidString {
            guard let data = FileManager.default.contents(
                atPath: dir.appendingPathComponent("manifest.json").path),
                  let manifest = try? decoder.decode(Manifest.self, from: data) else { continue }
            foreign.formUnion(manifest.receipts.map(\.requestID))
        }
        return foreign
    }

    // MARK: CanvasDocumentStore

    public func load(canvasID: UUID) async throws -> CanvasSnapshot {
        try withDocumentLock(canvasID) {
            try readCommitted(canvasID).snapshot
        }
    }

    /// Creates a canvas at revision 0 from an explicit initial snapshot.
    /// The canvas must not exist yet; afterwards all edits go through
    /// `commit`. Edits never invent a base document.
    public func create(
        canvasID: UUID,
        snapshot: CanvasSnapshot,
        requestID: UUID
    ) async throws {
        try withDocumentLock(canvasID) {
            var initial = snapshot
            initial.id = canvasID
            initial.revision = 0
            guard !FileManager.default.fileExists(atPath: manifestURL(canvasID).path) else {
                throw CanvasKitError.requestIDConflict(requestID: requestID)
            }
            let receipt = CanvasCommitReceipt(
                requestID: requestID,
                canvasID: canvasID,
                previousRevision: 0,
                revision: 0,
                batchHash: "create"
            )
            try persist(
                snapshot: initial,
                history: CanvasHistoryState(),
                receipts: [receipt],
                canvasID: canvasID
            )
        }
    }

    public func commit(
        _ batch: CanvasEditBatch,
        canvasID: UUID,
        expectedRevision: Int64,
        requestID: UUID
    ) async throws -> CanvasCommitReceipt {
        try await mutate(canvasID: canvasID) { engine in
            try await engine.commit(
                batch, canvasID: canvasID,
                expectedRevision: expectedRevision, requestID: requestID)
        }
    }

    public func commitDocument(
        _ batch: CanvasDocumentBatch,
        canvasID: UUID,
        expectedRevision: Int64,
        requestID: UUID
    ) async throws -> CanvasCommitReceipt {
        try await mutate(canvasID: canvasID) { engine in
            try await engine.commitDocument(
                batch, canvasID: canvasID,
                expectedRevision: expectedRevision, requestID: requestID)
        }
    }

    public func undo(
        canvasID: UUID,
        expectedRevision: Int64,
        requestID: UUID
    ) async throws -> CanvasCommitReceipt {
        try await mutate(canvasID: canvasID) { engine in
            try await engine.undo(
                canvasID: canvasID,
                expectedRevision: expectedRevision, requestID: requestID)
        }
    }

    public func redo(
        canvasID: UUID,
        expectedRevision: Int64,
        requestID: UUID
    ) async throws -> CanvasCommitReceipt {
        try await mutate(canvasID: canvasID) { engine in
            try await engine.redo(
                canvasID: canvasID,
                expectedRevision: expectedRevision, requestID: requestID)
        }
    }

    public func undoHistory(canvasID: UUID) async throws -> [CanvasUndoEntry] {
        try withDocumentLock(canvasID) {
            try readCommitted(canvasID).history.appliedEntries
        }
    }
    public func historyAvailability(canvasID: UUID) async throws -> CanvasHistoryAvailability {
        try withDocumentLock(canvasID) {
            let history = try readCommitted(canvasID).history
            return .init(undoCount: history.undoStack.count, redoCount: history.redoStack.count)
        }
    }

    /// Test hook: make the next mutation fail right before the atomic
    /// manifest write, simulating a crash at the commit point.
    func setFailBeforeManifestWrite(_ value: Bool) {
        failBeforeManifestWrite = value
    }

    // MARK: Commit pipeline

    /// Serialized mutation: flock → read committed state → revision CAS via
    /// the engine → persist blobs → ONE atomic manifest write. Any failure
    /// before the manifest rename leaves the previous committed record
    /// fully intact, and all in-memory mutation state (including redo
    /// history) is discarded with the engine.
    private func mutate(
        canvasID: UUID,
        _ mutation: (CanvasRepositoryEngine) async throws -> CanvasCommitReceipt
    ) async throws -> CanvasCommitReceipt {
        try await withDocumentLock(canvasID) {
            let committed = try readCommitted(canvasID)
            var receiptsByID: [UUID: CanvasCommitReceipt] = [:]
            for receipt in committed.receipts {
                receiptsByID[receipt.requestID] = receipt
            }
            let engine = CanvasRepositoryEngine(
                snapshot: committed.snapshot,
                existingReceipts: receiptsByID,
                foreignRequestIDs: foreignRequestIDs(excluding: canvasID),
                historyState: committed.history)
            let receipt = try await mutation(engine)
            let finalSnapshot = await engine.snapshotForPersistence()
            let finalHistory = await engine.historyForPersistence()
            receiptsByID[receipt.requestID] = receipt
            if failBeforeManifestWrite {
                failBeforeManifestWrite = false
                throw CanvasKitError.io("injected failure before manifest write")
            }
            try persist(
                snapshot: finalSnapshot,
                history: finalHistory,
                receipts: Array(receiptsByID.values),
                canvasID: canvasID
            )
            return receipt
        }
    }

    /// Writes blobs (skipping existing) then the manifest last.
    private func persist(
        snapshot: CanvasSnapshot,
        history: CanvasHistoryState,
        receipts: [CanvasCommitReceipt],
        canvasID: UUID
    ) throws {
        let directory = canvasDirectory(canvasID)
        let blobs = directory.appendingPathComponent("blobs", isDirectory: true)
        try FileManager.default.createDirectory(
            at: blobs, withIntermediateDirectories: true)

        let snapshotData = try encoder.encode(snapshot)
        let snapshotHash = CanvasBatchDigest.hash(snapshotData)
        let snapshotBlob = blobs.appendingPathComponent("\(snapshotHash).json")
        if !FileManager.default.fileExists(atPath: snapshotBlob.path) {
            try atomicWrite(snapshotData, to: snapshotBlob)
        } else {
            _ = try verifiedBlob(hash: snapshotHash, canvasID: canvasID)
        }

        let historyData = try encoder.encode(history)
        let historyHash = CanvasBatchDigest.hash(historyData)
        let historyBlob = blobs.appendingPathComponent("\(historyHash).json")
        if !FileManager.default.fileExists(atPath: historyBlob.path) {
            try atomicWrite(historyData, to: historyBlob)
        } else {
            _ = try verifiedBlob(hash: historyHash, canvasID: canvasID)
        }

        let manifest = Manifest(
            schemaVersion: 1,
            canvasID: canvasID,
            snapshotBlob: snapshotHash,
            snapshotRevision: snapshot.revision,
            historyBlob: historyHash,
            receipts: receipts
        )
        let manifestData = try encoder.encode(manifest)
        try atomicWrite(manifestData, to: manifestURL(canvasID))
        decodedRecord = DecodedRecord(canvasID: canvasID,
            snapshotHash: snapshotHash, historyHash: historyHash,
            snapshot: snapshot, history: history)
    }
}
