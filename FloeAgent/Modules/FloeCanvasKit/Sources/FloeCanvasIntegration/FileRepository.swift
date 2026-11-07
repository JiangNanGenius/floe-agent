import Foundation
import CryptoKit
import FloeCanvasCore

/// File-backed document authority at the explicit root supplied by the host.
/// The App binds each new canvas to its personal-project registry before
/// constructing this repository. Authorization and library moves remain host
/// responsibilities; legacy canvases retain their existing repository.
///
/// Design (aligned with FloeDiagramKit's FileDiagramRepository):
///
/// - Every load/mutation takes a
///   per-document `flock`, so two instances in one process or writers in
///   different processes serialize on the same revision check.
/// - The commit authority is a single `manifest.json` per canvas, written
///   atomically last. It binds the snapshot blob, the history blob and the
///   idempotency receipts of one commit into ONE record: a crash before the
///   manifest rename commits nothing, a crash after commits everything.
///   Recovery never guesses from uncommitted blobs.
/// - `blobs/<sha256>.json` are immutable, content-addressed payloads. After
///   a successful commit, best-effort GC under the SAME document lock keeps
///   the authoritative snapshot and COMPLETE history (both stacks), only
///   removing superseded regular blobs after successful durability barriers.
///
/// Layout:
///
///     <root>/canvases/<canvasID>/<canvasID>.lock
///     <root>/canvases/<canvasID>/manifest.json
///     <root>/canvases/<canvasID>/blobs/<sha256>.json
public final class FileCanvasRepository: CanvasDocumentStore, Sendable {
    public let root: URL
    private var encoder: JSONEncoder {
        let value = JSONEncoder()
        value.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return value
    }
    private var decoder: JSONDecoder { JSONDecoder() }
    /// Test hook: when true the next mutation fails just before the atomic
    /// manifest write, exercising crash-at-commit-point recovery.
    private let failureInjection = FailureInjection()
    private let gcBarrierFailureInjection = FailureInjection()

    private final class FailureInjection: @unchecked Sendable {
        private let lock = NSLock()
        private var failNext = false
        func set(_ value: Bool) { lock.withLock { failNext = value } }
        func consume() -> Bool {
            lock.withLock { let value = failNext; failNext = false; return value }
        }
    }

    public init(root: URL) throws {
        let standardized = root.standardizedFileURL
        // Refuse a filesystem/volume root: callers must choose a dedicated
        // directory so qualification data never spreads unbounded.
        guard standardized.pathComponents.count > 2 else {
            throw CanvasKitError.repositoryRootViolation("root too broad: \(root.path)")
        }
        self.root = standardized
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
        let snapshot = try decoder.decode(CanvasSnapshot.self, from: snapshotData)
        let history = try decoder.decode(CanvasHistoryState.self, from: historyData)
        guard snapshot.id == canvasID, snapshot.revision == manifest.snapshotRevision else {
            throw CanvasKitError.io("committed snapshot identity or revision mismatch")
        }
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
        try loadSynchronously(canvasID: canvasID)
    }

    /// The original native canvas has synchronous transaction callbacks.
    /// Both entry points use this same locked manifest authority.
    public func loadSynchronously(canvasID: UUID) throws -> CanvasSnapshot {
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
        try mutate(canvasID: canvasID) { engine in
            try engine.commit(
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
        try commitDocumentSynchronously(batch, canvasID: canvasID, expectedRevision: expectedRevision, requestID: requestID)
    }

    public func commitDocumentSynchronously(
        _ batch: CanvasDocumentBatch, canvasID: UUID,
        expectedRevision: Int64, requestID: UUID
    ) throws -> CanvasCommitReceipt {
        try mutate(canvasID: canvasID) { engine in
            try engine.commitDocument(
                batch, canvasID: canvasID,
                expectedRevision: expectedRevision, requestID: requestID)
        }
    }

    public func undo(
        canvasID: UUID,
        expectedRevision: Int64,
        requestID: UUID
    ) async throws -> CanvasCommitReceipt {
        try undoSynchronously(canvasID: canvasID, expectedRevision: expectedRevision, requestID: requestID)
    }

    public func undoSynchronously(canvasID: UUID, expectedRevision: Int64, requestID: UUID) throws -> CanvasCommitReceipt {
        try mutate(canvasID: canvasID) { engine in
            try engine.undo(
                canvasID: canvasID,
                expectedRevision: expectedRevision, requestID: requestID)
        }
    }

    public func redo(
        canvasID: UUID,
        expectedRevision: Int64,
        requestID: UUID
    ) async throws -> CanvasCommitReceipt {
        try redoSynchronously(canvasID: canvasID, expectedRevision: expectedRevision, requestID: requestID)
    }

    public func redoSynchronously(canvasID: UUID, expectedRevision: Int64, requestID: UUID) throws -> CanvasCommitReceipt {
        try mutate(canvasID: canvasID) { engine in
            try engine.redo(
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
        try historyAvailabilitySynchronously(canvasID: canvasID)
    }
    public func historyAvailabilitySynchronously(canvasID: UUID) throws -> CanvasHistoryAvailability {
        try withDocumentLock(canvasID) {
            let history = try readCommitted(canvasID).history
            return .init(undoCount: history.undoStack.count, redoCount: history.redoStack.count)
        }
    }

    /// Test hook: make the next mutation fail right before the atomic
    /// manifest write, simulating a crash at the commit point.
    func setFailBeforeManifestWrite(_ value: Bool) {
        failureInjection.set(value)
    }
    /// Internal qualification seam: unsupported/failed durability must skip
    /// maintenance without changing a successfully committed receipt.
    func setFailGarbageCollectionBarrier(_ value: Bool) { gcBarrierFailureInjection.set(value) }

    /// Internal maintenance/qualification entry. Public reads retain their
    /// existing behavior; this uses the exact same document flock and fails
    /// closed on any current-manifest/snapshot/history validation error.
    func collectUnreferencedBlobsSynchronously(canvasID: UUID) throws {
        try withDocumentLock(canvasID) {
            _ = try readCommitted(canvasID)
            let data = try Data(contentsOf: manifestURL(canvasID))
            let manifest = try decoder.decode(Manifest.self, from: data)
            let blobs = canvasDirectory(canvasID).appendingPathComponent("blobs", isDirectory: true)
            func size(_ hash: String) throws -> Int {
                let attributes = try FileManager.default.attributesOfItem(atPath: blobs.appendingPathComponent(hash + ".json").path)
                guard let n = attributes[.size] as? NSNumber, n.int64Value >= 0, let size = Int(exactly: n.int64Value) else { throw CanvasKitError.io("invalid current blob size") }
                return size
            }
            reclaimUnreferencedBlobs(canvasID: canvasID, manifest: manifest, manifestData: data,
                snapshotBytes: try size(manifest.snapshotBlob), historyBytes: try size(manifest.historyBlob))
        }
    }

    // MARK: Commit pipeline

    /// Serialized mutation: flock → read committed state → revision CAS via
    /// the engine → persist blobs → ONE atomic manifest write. Any failure
    /// before the manifest rename leaves the previous committed record
    /// fully intact, and all in-memory mutation state (including redo
    /// history) is discarded with the engine.
    private func mutate(
        canvasID: UUID,
        _ mutation: (inout CanvasRepositoryEngine) throws -> CanvasCommitReceipt
    ) throws -> CanvasCommitReceipt {
        try withDocumentLock(canvasID) {
            let committed = try readCommitted(canvasID)
            var receiptsByID: [UUID: CanvasCommitReceipt] = [:]
            for receipt in committed.receipts {
                receiptsByID[receipt.requestID] = receipt
            }
            var engine = CanvasRepositoryEngine(
                snapshot: committed.snapshot,
                existingReceipts: receiptsByID,
                foreignRequestIDs: foreignRequestIDs(excluding: canvasID),
                historyState: committed.history)
            let receipt = try mutation(&engine)
            let finalSnapshot = engine.snapshotForPersistence()
            let finalHistory = engine.historyForPersistence()
            receiptsByID[receipt.requestID] = receipt
            if failureInjection.consume() {
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
        // The commit is already authoritative. Maintenance never converts
        // this success into failure, drops history, or changes the receipt.
        reclaimUnreferencedBlobs(canvasID: canvasID, manifest: manifest, manifestData: manifestData,
            snapshotBytes: snapshotData.count, historyBytes: historyData.count)
    }

    /// Called ONLY while this canvas's existing exclusive flock is held.
    /// Typed state was validated/encoded by persist (or readCommitted above).
    /// Re-verify ALL on-disk bytes with bounded buffers, then durably pin the
    /// current file names before touching any obsolete payload. Readers use
    /// this same flock; history frames contain inline snapshots, not old hashes.
    private func reclaimUnreferencedBlobs(canvasID: UUID, manifest: Manifest, manifestData: Data,
                                           snapshotBytes: Int, historyBytes: Int) {
        guard manifest.schemaVersion == 1, manifest.canvasID == canvasID else { return }
        let directory = canvasDirectory(canvasID)
        let parent = Darwin.open(directory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard parent >= 0 else { return }; defer { _ = Darwin.close(parent) }
        let blobs = Darwin.openat(parent, "blobs", O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard blobs >= 0 else { return }; defer { _ = Darwin.close(blobs) }
        func regular(_ dir: Int32, _ name: String, bytes: Int, digest: String) -> Int32? {
            let fd = Darwin.openat(dir, name, O_RDWR | O_NOFOLLOW | O_NONBLOCK)
            guard fd >= 0 else { return nil }
            var info = stat()
            guard fstat(fd, &info) == 0, info.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
                  info.st_size == Int64(bytes), garbageCollectionDigest(fd) == digest else { _ = Darwin.close(fd); return nil }
            return fd
        }
        guard let record = regular(parent, "manifest.json", bytes: manifestData.count, digest: CanvasBatchDigest.hash(manifestData)) else { return }
        defer { _ = Darwin.close(record) }
        guard let snapshot = regular(blobs, manifest.snapshotBlob + ".json", bytes: snapshotBytes, digest: manifest.snapshotBlob) else { return }
        defer { _ = Darwin.close(snapshot) }
        guard let history = regular(blobs, manifest.historyBlob + ".json", bytes: historyBytes, digest: manifest.historyBlob) else { return }
        defer { _ = Darwin.close(history) }
        // atomicWrite's historical directory fsync is best-effort. GC needs
        // positive barriers: payload files+names first, manifest file+name
        // last. An error/unsupported filesystem leaves ALL old blobs intact.
        guard !gcBarrierFailureInjection.consume(),
              [snapshot, history, blobs, record, parent].allSatisfy({ fsync($0) == 0 }),
              let names = try? FileManager.default.contentsOfDirectory(atPath: directory.appendingPathComponent("blobs").path) else { return }
        let keep: Set<String> = [manifest.snapshotBlob, manifest.historyBlob]
        for name in names {
            guard name.utf8.count == 69, name.hasSuffix(".json") else { continue }
            let hash = String(name.dropLast(5))
            guard !keep.contains(hash), hash.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else { continue }
            var info = stat()
            guard fstatat(blobs, name, &info, AT_SYMLINK_NOFOLLOW) == 0,
                  info.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG) else { continue }
            _ = unlinkat(blobs, name, 0)
        }
        // A failure here can only leave dead files present after a crash;
        // the already-synced current snapshot/history/receipt stay complete.
        _ = fsync(blobs)
    }
    private func garbageCollectionDigest(_ fd: Int32) -> String? {
        var hasher = SHA256(), buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let count = buffer.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, $0.count) }
            if count < 0 { if errno == EINTR { continue }; return nil }
            if count == 0 { return CanvasBatchDigest.hex(hasher.finalize()) }
            hasher.update(data: Data(buffer.prefix(count)))
        }
    }
}
