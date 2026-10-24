// SPDX-License-Identifier: MPL-2.0
//
// G04-R1 trusted provider SOURCE HOST — the narrow private C ABI the App's
// WorkspaceSourceHostController calls to run REAL provider-file ladders
// through the ORIGINAL native authorities. This is the missing inbound
// direction: the coordinator's methods existed but nothing inside the App
// could reach them. Model/tool/bridge payloads have NO route here — only
// the trusted JNI host (same discipline as `floe_g04_source_*` mailbox and
// the accepted attachment/skills folder host seams).
//
// What this file owns:
//   * a process-local SESSION TABLE (NSLock-guarded; tickets are opaque
//     positive Int64s; nothing reversible into a path ever crosses the C
//     boundary; every entry revalidates the EXACT live root epoch, so a
//     stale generation can never advance a session of another root);
//   * bounded CHUNKED staged-file ingress (64 KiB chunks, streaming
//     native-side SHA-256, aggregate + size + disk-freedom budgets from
//     the ORIGINAL G03 transfer entry budget — 1 GiB ordinary provider
//     file copy — NOT the 4 MiB editable-document mailbox budget, which
//     stays exactly as delivered for the mailbox transport);
//   * bounded chunked EGRESS snapshots of native working copies (the
//     replacement bytes a provider write may carry are frozen by native,
//     hashed by native, and streamed down in pages — no whole-file JSON/
//     base64 ever exists here);
//   * the file-backed journal-47 ladder: staged fresh provider backup ->
//     native verify -> `prepare` -> staged fresh observation -> native
//     ONE-TIME `claim` -> host destructive write (permitted once, token-
//     bound) -> staged provider read-back -> native `settle` decides
//     committed (binding CAS) / conflict with the OBSERVED digest. The
//     gateway's own receipts stay caller-owned; this lane never deletes
//     journaled recovery references. Retain/abandon keeps the row honest.
//   * metadata-only queries (source page/lookup, recovery page) that the
//     trusted host consumes for bootstrap reference reconciliation BEFORE
//     any grant release is offered, plus the transport-backed reconcile
//     run and its >4 MiB staged counterpart.
//
// Authority invariants (all enforced HERE or inside the coordinator, never
// by trust): digests entering journal 47 are computed by NATIVE over the
// bytes it actually holds; identity tuples revalidate against the original
// durable records before and after every await; workspace commits ride the
// ORIGINAL `WorkspaceFileService.importUserFile` atomic verified no-overwrite
// machinery under the exact private-task binding; a live `.conversation`
// owned-work lease spans every real file/transport IO step; empty results
// and success strings are never authority; every refusal is typed.
import Foundation
import Crypto
import FloeCore
import FloePersistence
import FloeTools
import FloeWorkspace
import FloeAndroidWorkspaceTools

// MARK: - JNI-visible status space (source-host-owned -5xx; additive and
// DISJOINT from the shared -105/-106 shape rules, the gateway -1xx space,
// the runtime-owner -2xx space, attachment -3xx and skills-folder -4xx).

public enum G04SourceHostStatus {
    public static let ok: Int32 = 0
    public static let invalidArguments: Int32 = -105   // shared shape rule
    public static let bufferTooSmall: Int32 = -106     // shared ASCII-copy rule
    public static let notInstalled: Int32 = -501       // no live root generation
    public static let generationFenced: Int32 = -502   // epoch/session belongs to another generation
    public static let sessionUnknown: Int32 = -503
    public static let stateConflict: Int32 = -504      // wrong ladder phase / empty file / non-reentrant op
    public static let identityRefused: Int32 = -505    // durable conversation/workspace revalidation failed
    public static let sourceMissing: Int32 = -506
    public static let staleRevision: Int32 = -507
    public static let transitionRefused: Int32 = -508  // journal grammar (open recovery, alreadyExists, replayed permit)
    public static let sizeExceeded: Int32 = -509
    public static let aggregateExceeded: Int32 = -510
    public static let diskFull: Int32 = -511
    public static let saturated: Int32 = -512
    public static let writeFailed: Int32 = -513
    public static let readFailed: Int32 = -514
    public static let digestMismatch: Int32 = -515
    public static let transportUnavailable: Int32 = -516 // mailbox pump not bound for this epoch
    public static let providerFailed: Int32 = -517       // typed provider verdict retained in the reply
    public static let hopTimeout: Int32 = -518           // bounded actor hop expired; staged bytes retained
    public static let `internal`: Int32 = -599
}

/// Transport budgets owned by this seam. Chunk size matches the frozen
/// gateway chunker; the copy ceiling is the ORIGINAL transfer entry budget;
/// the mailbox's 4 MiB document payload cap is untouched elsewhere.
public enum G04SourceHostLimits {
    public static let maximumChunkBytes = 65_536
    public static let maximumLiveSessions = 16
    public static let maximumAggregateStagedBytes = 4 * Int(Int64(1) << 30)
    public static let maximumReplyBytes = 32 * 1024
    public static let maximumRowsPerPage = 32
    public static let shortHopSeconds = 30      // metadata/DB-only hops
    public static let fileHopSeconds = 300      // snapshot/commit hops (streamed file IO)
    /// Free-space recheck cadence for streamed writes (every 16 MiB).
    public static let diskCheckEveryBytes = 16 * 1_048_576
}

// MARK: - Session table

/// Swift-6-safe one-shot result box for the bounded synchronous actor hops
/// (the caller's thread blocks on the semaphore; only the detached task
/// writes through this box before signalling) — the same reviewed shape the
/// accepted skills-folder host uses.
private final class HostHopBox<Value>: @unchecked Sendable {
    var value: Result<Value, any Error>?
}

public final class G04WorkspaceSourceHost: @unchecked Sendable {
    public static let shared = G04WorkspaceSourceHost()

    enum Purpose: String {
        case `import` = "import"
        case backupVerify = "backup-verify"
        case freshObserve = "fresh-observe"
        case readback = "readback"
        case exportVerify = "export-verify"
    }

    enum SavePhase: Int {
        case open            // snapshot frozen, no journal row yet
        case prepared        // journal `prepared` row exists (backup verified)
        case claimed         // journal `writing` permit exists (ONE-TIME claim)
        case permitted       // the caller-bound destructive permit was handed once
        case settled         // committed/conflict recorded
        case retained        // honest abandon recorded
    }

    final class StageSession {
        let ticket: Int64
        let createdEpoch: UInt64
        let purpose: Purpose
        let taskID: UUID
        let workspaceID: UUID
        let sourceID: UUID?
        let logicalPath: String?
        let sourceReference: String?
        let sourceDocumentID: String?
        let stagingURL: URL
        var handle: FileHandle?
        var digest = SHA256()
        var bytes: Int = 0
        var finishedSHA256: String?   // staged body frozen; no further writes
        var terminalCode: String?     // e.g. "workingCopyExists" after a failed commit
        var row: AndroidWorkspaceSource?   // import success receipt (bounded fields)
        var committedSHA256: String?
        var closed = false
        init(ticket: Int64, epoch: UInt64, purpose: Purpose, taskID: UUID, workspaceID: UUID,
             sourceID: UUID?, logicalPath: String?, sourceReference: String?,
             sourceDocumentID: String?, stagingURL: URL) {
            self.ticket = ticket; self.createdEpoch = epoch; self.purpose = purpose
            self.taskID = taskID; self.workspaceID = workspaceID; self.sourceID = sourceID
            self.logicalPath = logicalPath; self.sourceReference = sourceReference
            self.sourceDocumentID = sourceDocumentID; self.stagingURL = stagingURL
        }
    }

    final class EgressSession {
        let ticket: Int64
        let createdEpoch: UInt64
        let mode: String                 // "save" | "export"
        let taskID: UUID
        let workspaceID: UUID
        let sourceID: UUID?              // required for save (journal binding)
        let logicalPath: String
        let snapshotURL: URL
        let sha256: String               // native-observed snapshot digest
        let bytes: Int
        let recoveryID: UUID             // minted at open; journaled on prepare
        var sourceRevision: String?      // recorded at prepare success
        var recordedSHA256: String?
        var phase: SavePhase = .open
        var receiptToken: String?        // caller gateway receipt identity
        var permitIssued = false
        var closed = false
        init(ticket: Int64, epoch: UInt64, mode: String, taskID: UUID, workspaceID: UUID,
             sourceID: UUID?, logicalPath: String, snapshotURL: URL, sha256: String,
             bytes: Int, recoveryID: UUID) {
            self.ticket = ticket; self.createdEpoch = epoch; self.mode = mode
            self.taskID = taskID; self.workspaceID = workspaceID; self.sourceID = sourceID
            self.logicalPath = logicalPath; self.snapshotURL = snapshotURL
            self.sha256 = sha256; self.bytes = bytes; self.recoveryID = recoveryID
        }
    }

    private let lock = NSLock()
    private var counter: Int64 = 0
    private var stages: [Int64: StageSession] = [:]
    private var egresses: [Int64: EgressSession] = [:]
    private var retired: Set<Int64> = []
    private var retiredOrder: [Int64] = []
    private var aggregateStagedBytes = 0
    private var counters = (opens: 0, chunksWritten: 0, chunksRead: 0, finished: 0, aborted: 0,
                            fenced: 0, refused: 0, saturated: 0, permitsIssued: 0, hopsTimedOut: 0)

    /// Trusted fixture seam (same-module only; the accepted skills-folder
    /// pattern). Production never writes these; no command/envelope/JSON
    /// field can reach this lane either way. Tests drive the session table
    /// + ladder grammar without installing a full G02 generation.
    internal var liveEpochOverrideForTesting: UInt64?
    internal var coordinatorOverrideForTesting: G04WorkspaceSourceCoordinator?
    internal var stagingRootOverrideForTesting: URL?

    private init() {}

    // MARK: epoch truth (never the caller's claim)

    private func liveEpoch() -> UInt64? {
        if let override = liveEpochOverrideForTesting { return override }
        return G02NativeRootEpoch.readback()
    }

    private func requireCoordinator(epoch: UInt64) -> G04WorkspaceSourceCoordinator? {
        if let override = coordinatorOverrideForTesting { return override }
        guard liveEpoch() == epoch else { return nil }
        return G04WorkspaceHostRegistry.shared.coordinator(epoch: epoch)
    }

    private func stagingDirectory(epoch: UInt64) -> URL? {
        let root: URL
        if let override = stagingRootOverrideForTesting {
            root = override
        } else if let path = requireCoordinator(epoch: epoch)?.storageRootPath {
            root = URL(fileURLWithPath: path, isDirectory: true)
        } else {
            return nil
        }
        let directory = root.appendingPathComponent("SourceStaging", isDirectory: true)
            .appendingPathComponent(String(epoch), isDirectory: true)
        switch WorkspaceNoFollow.kind(directory.path) {
        case .directory:
            return directory
        case .missing:
            do {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
                                                        attributes: [.posixPermissions: 0o700])
            } catch {
                // The parent may also be missing exactly once (fresh root).
                do {
                    try FileManager.default.createDirectory(at: directory.deletingLastPathComponent(),
                                                            withIntermediateDirectories: true,
                                                            attributes: [.posixPermissions: 0o700])
                    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
                                                            attributes: [.posixPermissions: 0o700])
                } catch { return nil }
            }
            return WorkspaceNoFollow.kind(directory.path) == .directory ? directory : nil
        default:
            return nil   // symlink/file/special at a managed level: fail closed, touch nothing
        }
    }

    /// Sweep ONLY sessions created under an OLDER generation. Staged temps
    /// are this lane's own scratch (the journaled recovery bodies stay
    /// caller-owned and are never touched here); deleting them is the
    /// documented recoverable-cleanup rule for a superseded process lane.
    private func sweepStaleGenerationLocked(live: UInt64) {
        for session in stages.values where session.createdEpoch != live {
            closeStageLocked(session)
        }
        for session in egresses.values where session.createdEpoch != live {
            closeEgressLocked(session)
        }
    }

    // MARK: ticket plumbing

    private func newTicketLocked() -> Int64 {
        counter &+= 1
        return counter
    }

    private func retireLocked(_ ticket: Int64) {
        stages.removeValue(forKey: ticket)
        egresses.removeValue(forKey: ticket)
        retired.insert(ticket)
        retiredOrder.append(ticket)
        while retiredOrder.count > 512 { retired.remove(retiredOrder.removeFirst()) }
    }

    private func closeStageLocked(_ session: StageSession) {
        session.closed = true
        try? session.handle?.close()
        session.handle = nil
        aggregateStagedBytes -= session.bytes
        if session.bytes > 0 || session.finishedSHA256 != nil {
            // The journaled ladder never relies on these files surviving a
            // close; only `import` staging that successfully committed is
            // redundant (the workspace body is the authority). Everything is
            // this lane's own scratch, so removal is safe here.
            try? FileManager.default.removeItem(at: session.stagingURL)
        }
        retireLocked(session.ticket)
    }

    private func closeEgressLocked(_ session: EgressSession) {
        session.closed = true
        // Snapshot scratch is redundant only after the ladder settled or the
        // caller abandoned it; while a journal permit is still open
        // (`prepared`/`claimed`/`permitted`) the snapshot is the ONLY
        // in-process copy of the replacement bytes — retain it and let the
        // row stay honestly pending for reconcile instead of destroying
        // recoverable data.
        switch session.phase {
        case .settled, .retained, .open:
            try? FileManager.default.removeItem(at: session.snapshotURL)
            retireLocked(session.ticket)
        case .prepared, .claimed, .permitted:
            retireLocked(session.ticket)
        }
    }

    private func freeSpaceOK(path: String, additionalBytes: Int) -> Bool {
        guard let available = try? FileManager.default
            .attributesOfFileSystem(forPath: path)[.systemFreeSize] as? NSNumber else { return false }
        return available.uint64Value > UInt64(max(additionalBytes, 0)) + (32 * 1_048_576)
    }

    // MARK: - Stage (chunked ingress)

    func stageOpen(epoch: UInt64, purposeRaw: String, taskHex: String, workspaceHex: String,
                   sourceHex: String?, logicalPath: String?, sourceReference: String?,
                   sourceDocumentID: String?) -> Int64 {
        guard let live = liveEpoch(), live == epoch,
              let coordinator = requireCoordinator(epoch: epoch) else {
            lock.lock(); counters.refused += 1; lock.unlock()
            return epoch == 0 ? Int64(G04SourceHostStatus.notInstalled)
                              : Int64(G04SourceHostStatus.generationFenced)
        }
        guard let purpose = Purpose(rawValue: purposeRaw) else {
            return Int64(G04SourceHostStatus.invalidArguments)
        }
        guard let taskID = Self.canonicalUUID(taskHex), let workspaceID = Self.canonicalUUID(workspaceHex),
              (sourceHex == nil || Self.canonicalUUID(sourceHex!) != nil) else {
            return Int64(G04SourceHostStatus.invalidArguments)
        }
        let normalizedPath = logicalPath.flatMap { $0.isEmpty ? nil : $0 }
        let normalizedReference = sourceReference.flatMap { $0.isEmpty ? nil : $0 }
        let normalizedDocument = sourceDocumentID.flatMap { $0.isEmpty ? nil : $0 }
        if purpose == .import {
            guard let normalizedPath, Self.validLogicalPath(normalizedPath),
                  let normalizedReference, Self.validSourceReference(normalizedReference),
                  sourceHex != nil, Self.canonicalUUID(sourceHex!) != nil
            else { return Int64(G04SourceHostStatus.invalidArguments) }
            if let normalizedDocument, normalizedDocument.utf8.count > 8192 {
                return Int64(G04SourceHostStatus.invalidArguments)
            }
        } else if let normalizedPath, !Self.validLogicalPath(normalizedPath) {
            return Int64(G04SourceHostStatus.invalidArguments)
        }
        guard let directory = stagingDirectory(epoch: epoch) else {
            return Int64(G04SourceHostStatus.internal)
        }
        let stagingURL = directory.appendingPathComponent(UUID().uuidString + ".bin")
        lock.lock()
        sweepStaleGenerationLocked(live: live)
        guard stages.count + egresses.count < G04SourceHostLimits.maximumLiveSessions else {
            counters.saturated &+= 1
            lock.unlock()
            return Int64(G04SourceHostStatus.saturated)
        }
        _ = coordinator
        let session = StageSession(ticket: newTicketLocked(), epoch: epoch, purpose: purpose,
                                   taskID: taskID, workspaceID: workspaceID,
                                   sourceID: sourceHex.flatMap(Self.canonicalUUID),
                                   logicalPath: normalizedPath, sourceReference: normalizedReference,
                                   sourceDocumentID: normalizedDocument, stagingURL: stagingURL)
        do {
            guard FileManager.default.createFile(atPath: stagingURL.path, contents: nil,
                                                 attributes: [.posixPermissions: 0o600]),
                  let handle = try? FileHandle(forWritingTo: stagingURL) else {
                lock.unlock()
                return Int64(G04SourceHostStatus.diskFull)
            }
            session.handle = handle
        }
        stages[session.ticket] = session
        counters.opens += 1
        lock.unlock()
        return session.ticket
    }

    func stageWrite(ticket: Int64, data: Data) -> Int32 {
        guard !data.isEmpty, data.count <= G04SourceHostLimits.maximumChunkBytes else {
            return Int32(G04SourceHostStatus.invalidArguments)
        }
        lock.lock()
        guard let session = stages[ticket], !session.closed, session.finishedSHA256 == nil,
              let live = liveEpoch(), session.createdEpoch == live,
              let handle = session.handle else {
            lock.unlock()
            return Int32(stageFailureStatusLocked(ticket: ticket))
        }
        guard session.bytes + data.count <= G04WorkspaceSourceCoordinator.maximumProviderCopyBytes else {
            counters.refused += 1
            lock.unlock()
            return Int32(G04SourceHostStatus.sizeExceeded)
        }
        guard aggregateStagedBytes + data.count <= G04SourceHostLimits.maximumAggregateStagedBytes else {
            counters.refused += 1
            lock.unlock()
            return Int32(G04SourceHostStatus.aggregateExceeded)
        }
        let needsDiskCheck = session.bytes % G04SourceHostLimits.diskCheckEveryBytes < G04SourceHostLimits.maximumChunkBytes
        if needsDiskCheck, !freeSpaceOK(path: session.stagingURL.deletingLastPathComponent().path,
                                        additionalBytes: data.count) {
            lock.unlock()
            return Int32(G04SourceHostStatus.diskFull)
        }
        do {
            try handle.write(contentsOf: data)
            session.digest.update(data: data)
            session.bytes += data.count
            aggregateStagedBytes += data.count
            counters.chunksWritten += 1
            lock.unlock()
            return Int32(G04SourceHostStatus.ok)
        } catch {
            lock.unlock()
            return Int32(G04SourceHostStatus.writeFailed)
        }
    }

    private func stageFailureStatusLocked(ticket: Int64) -> Int32 {
        if retired.contains(ticket) { return G04SourceHostStatus.generationFenced }
        // A retained session that belongs to a DIFFERENT generation is the
        // documented -502 ("epoch/session belongs to another generation"),
        // exactly the typed branch `stageAbort` already returns for the same
        // cross-epoch session. Until the next open sweeps it into `retired`,
        // such late work must not masquerade as the same-generation ladder
        // phase -504 ("wrong ladder phase / empty file / non-reentrant op").
        if let session = stages[ticket], let live = liveEpoch(), session.createdEpoch != live {
            return G04SourceHostStatus.generationFenced
        }
        guard stages[ticket] != nil else { return G04SourceHostStatus.sessionUnknown }
        return G04SourceHostStatus.stateConflict
    }

    private func stageFailureStatus(ticket: Int64) -> Int32 {
        lock.lock(); defer { lock.unlock() }
        return stageFailureStatusLocked(ticket: ticket)
    }

    /// Freeze one staged body: flush+fsync, compute the streaming digest,
    /// then run the purpose-specific terminal. `import` commits through the
    /// ORIGINAL atomic verified machinery and binds journal 47 in the same
    /// bounded actor hop; every other purpose returns the digest only and
    /// the staged bytes are consumed by the caller's next ladder entry
    /// (they are re-verified from the live provider at claim anyway).
    func stageFinish(ticket: Int64, buffer: UnsafeMutablePointer<CChar>?,
                     capacity: Int32) -> Int32 {
        lock.lock()
        guard let session = stages[ticket], !session.closed, session.finishedSHA256 == nil,
              let live = liveEpoch(), session.createdEpoch == live else {
            let status = stageFailureStatusLocked(ticket: ticket)
            lock.unlock()
            return status
        }
        if let handle = session.handle {
            session.handle = nil
            do {
                try handle.synchronize()
                try handle.close()
            } catch {
                lock.unlock()
                return Int32(G04SourceHostStatus.writeFailed)
            }
        }
        let stagedDigest = session.digest.finalize().map { String(format: "%02x", $0) }.joined()
        let stagedBytes = session.bytes
        lock.unlock()
        guard stagedBytes > 0, stagedBytes <= G04WorkspaceSourceCoordinator.maximumProviderCopyBytes else {
            lock.lock()
            counters.refused += 1
            if let live = liveEpoch(), session.createdEpoch == live { closeStageLocked(session) }
            lock.unlock()
            return Int32(stagedBytes == 0 ? G04SourceHostStatus.stateConflict
                                          : G04SourceHostStatus.sizeExceeded)
        }
        // Re-hash the frozen file (the incremental digest must match the
        // bytes actually on disk — write corruption is a typed failure).
        let diskDigest: String
        do {
            diskDigest = try FloeDigest.sha256Hex(ofFileAt: session.stagingURL)
        } catch {
            return Int32(G04SourceHostStatus.readFailed)
        }
        guard diskDigest == stagedDigest else {
            lock.lock()
            counters.refused += 1
            if let live = liveEpoch(), session.createdEpoch == live { closeStageLocked(session) }
            lock.unlock()
            return Int32(G04SourceHostStatus.digestMismatch)
        }
        var reply: String
        if session.purpose == .import {
            guard let sourceID = session.sourceID, let logicalPath = session.logicalPath,
                  let reference = session.sourceReference,
                  let coordinator = requireCoordinator(epoch: session.createdEpoch) else {
                return Int32(G04SourceHostStatus.invalidArguments)
            }
            let box = HostHopBox<G04WorkspaceSourceCoordinator.ImportedFileOutcome>()
            let gate = DispatchSemaphore(value: 0)
            let taskID = session.taskID, workspaceID = session.workspaceID
            let documentID = session.sourceDocumentID
            let stagingURL = session.stagingURL
            Task.detached(priority: .userInitiated) {
                do {
                    let outcome = try await coordinator.importStagedFile(
                        sourceID: sourceID, taskID: taskID, workspaceID: workspaceID,
                        logicalPath: logicalPath, sourceReference: reference,
                        sourceDocumentID: documentID, stagedURL: stagingURL,
                        stagedBytes: stagedBytes)
                    box.value = .success(outcome)
                } catch {
                    box.value = .failure(error)
                }
                gate.signal()
            }
            if gate.wait(timeout: .now() + .seconds(G04SourceHostLimits.fileHopSeconds)) == .timedOut {
                lock.lock(); counters.hopsTimedOut += 1; lock.unlock()
                // The staged bytes stay (bounded session scratch); the retry
                // path is idempotent, and the late hop converges through
                // importStagedFile's existing-body rule.
                return Int32(G04SourceHostStatus.hopTimeout)
            }
            switch box.value {
            case .success(let outcome):
                reply = Self.json(["ok": 1, "sourceID": outcome.source.id.uuidString,
                                   "sha256": outcome.committedSHA256,
                                   "bytes": outcome.committedBytes,
                                   "revision": outcome.source.revision])
                lock.lock()
                guard !session.closed else {
                    counters.fenced += 1
                    lock.unlock()
                    return Int32(G04SourceHostStatus.generationFenced)
                }
                session.finishedSHA256 = stagedDigest
                session.row = outcome.source
                session.committedSHA256 = outcome.committedSHA256
                counters.finished += 1
                lock.unlock()
            case .failure(let error):
                reply = Self.json(["ok": 0, "errorCode": Self.errorToken(error),
                                   "reason": Self.errorReason(error)])
                lock.lock()
                guard !session.closed else {
                    counters.fenced += 1
                    lock.unlock()
                    return Int32(G04SourceHostStatus.generationFenced)
                }
                session.terminalCode = Self.errorToken(error)
                counters.refused += 1
                lock.unlock()
            case .none:
                return Int32(G04SourceHostStatus.internal)
            }
        } else {
            reply = Self.json(["ok": 1, "sha256": stagedDigest, "bytes": stagedBytes])
            lock.lock()
            guard !session.closed else {
                counters.fenced += 1
                lock.unlock()
                return Int32(G04SourceHostStatus.generationFenced)
            }
            session.finishedSHA256 = stagedDigest
            counters.finished += 1
            lock.unlock()
        }
        return Self.copy(reply, buffer: buffer, capacity: capacity)
    }

    func stageAbort(ticket: Int64) -> Int32 {
        lock.lock()
        guard let session = stages[ticket], !session.closed else {
            let status = stageFailureStatusLocked(ticket: ticket)
            lock.unlock()
            return status == G04SourceHostStatus.sessionUnknown ? Int32(G04SourceHostStatus.ok) : status
        }
        if let live = liveEpoch(), session.createdEpoch != live {
            lock.unlock()
            return Int32(G04SourceHostStatus.generationFenced)
        }
        counters.aborted += 1
        closeStageLocked(session)
        lock.unlock()
        return Int32(G04SourceHostStatus.ok)
    }

    // MARK: - Egress snapshots + journal ladder

    func egressOpen(epoch: UInt64, mode: String, taskHex: String, workspaceHex: String,
                    logicalPath: String, sourceHex: String?) -> Int64 {
        guard let live = liveEpoch(), live == epoch,
              mode == "save" || mode == "export" else {
            lock.lock(); counters.refused += 1; lock.unlock()
            return Int64(epoch == 0 ? G04SourceHostStatus.notInstalled
                                    : G04SourceHostStatus.generationFenced)
        }
        guard let taskID = Self.canonicalUUID(taskHex), let workspaceID = Self.canonicalUUID(workspaceHex),
              Self.validLogicalPath(logicalPath) else {
            return Int64(G04SourceHostStatus.invalidArguments)
        }
        let sourceID: UUID? = sourceHex.flatMap(Self.canonicalUUID)
        if sourceHex != nil, sourceID == nil { return Int64(G04SourceHostStatus.invalidArguments) }
        if mode == "save", sourceID == nil { return Int64(G04SourceHostStatus.invalidArguments) }
        guard let coordinator = requireCoordinator(epoch: epoch),
              let directory = stagingDirectory(epoch: epoch) else {
            return Int64(G04SourceHostStatus.notInstalled)
        }
        let snapshotURL = directory.appendingPathComponent(UUID().uuidString + ".snapshot")
        let box = HostHopBox<G04WorkspaceSourceCoordinator.WorkingCopySnapshot>()
        let gate = DispatchSemaphore(value: 0)
        Task.detached(priority: .userInitiated) {
            do {
                let snapshot = try await coordinator.snapshotWorkingCopy(
                    taskID: taskID, workspaceID: workspaceID,
                    logicalPath: logicalPath, snapshotURL: snapshotURL)
                box.value = .success(snapshot)
            } catch {
                box.value = .failure(error)
            }
            gate.signal()
        }
        if gate.wait(timeout: .now() + .seconds(G04SourceHostLimits.fileHopSeconds)) == .timedOut {
            try? FileManager.default.removeItem(at: snapshotURL)
            lock.lock(); counters.hopsTimedOut += 1; lock.unlock()
            return Int64(G04SourceHostStatus.hopTimeout)
        }
        let snapshot: G04WorkspaceSourceCoordinator.WorkingCopySnapshot
        switch box.value {
        case .success(let value): snapshot = value
        case .failure(let error):
            try? FileManager.default.removeItem(at: snapshotURL)
            let status = Self.errorStatus(error)
            lock.lock(); counters.refused += 1; lock.unlock()
            return Int64(status)
        case .none:
            try? FileManager.default.removeItem(at: snapshotURL)
            return Int64(G04SourceHostStatus.internal)
        }
        lock.lock()
        guard liveEpoch() == epoch, requireCoordinator(epoch: epoch) != nil else {
            counters.fenced += 1
            lock.unlock()
            try? FileManager.default.removeItem(at: snapshotURL)
            return Int64(G04SourceHostStatus.generationFenced)
        }
        sweepStaleGenerationLocked(live: epoch)
        guard stages.count + egresses.count < G04SourceHostLimits.maximumLiveSessions else {
            lock.unlock()
            try? FileManager.default.removeItem(at: snapshotURL)
            return Int64(G04SourceHostStatus.saturated)
        }
        let session = EgressSession(ticket: newTicketLocked(), epoch: epoch, mode: mode,
                                    taskID: taskID, workspaceID: workspaceID, sourceID: sourceID,
                                    logicalPath: logicalPath, snapshotURL: snapshotURL,
                                    sha256: snapshot.sha256, bytes: snapshot.bytes, recoveryID: UUID())
        egresses[session.ticket] = session
        counters.opens += 1
        lock.unlock()
        return session.ticket
    }

    func egressInfo(ticket: Int64, buffer: UnsafeMutablePointer<CChar>?, capacity: Int32) -> Int32 {
        lock.lock()
        guard let session = egresses[ticket], !session.closed,
              let live = liveEpoch(), session.createdEpoch == live else {
            lock.unlock()
            return egressFailureStatus(ticket: ticket)
        }
        var object: [String: Any] = [
            "ok": 1, "mode": session.mode, "sha256": session.sha256, "bytes": session.bytes,
            "logicalPath": session.logicalPath, "recoveryID": session.recoveryID.uuidString,
        ]
        if let sourceID = session.sourceID { object["sourceID"] = sourceID.uuidString }
        if let revision = session.sourceRevision { object["sourceRevision"] = revision }
        if let recorded = session.recordedSHA256 { object["recordedSHA256"] = recorded }
        lock.unlock()
        return Self.copy(Self.json(object), buffer: buffer, capacity: capacity)
    }

    func egressRead(ticket: Int64, offset: Int64, buffer: UnsafeMutablePointer<UInt8>?,
                    capacity: Int32) -> Int32 {
        guard let buffer, capacity > 0,
              capacity <= G04SourceHostLimits.maximumChunkBytes,
              offset >= 0 else {
            return Int32(G04SourceHostStatus.invalidArguments)
        }
        lock.lock()
        guard let session = egresses[ticket], !session.closed,
              let live = liveEpoch(), session.createdEpoch == live else {
            lock.unlock()
            return egressFailureStatus(ticket: ticket)
        }
        let size = session.bytes
        lock.unlock()
        guard offset < Int64(size) else { return 0 }   // clean EOF (0 bytes copied)
        let count = min(Int64(capacity), Int64(size) - offset)
        do {
            let handle = try FileHandle(forReadingFrom: session.snapshotURL)
            defer { try? handle.close() }
            try handle.seek(toOffset: UInt64(offset))
            let data = try handle.read(upToCount: Int(count)) ?? Data()
            guard data.count == count else {
                return Int32(G04SourceHostStatus.readFailed)
            }
            // count >= 1 here (clean EOF returns 0 above), so the source
            // pointer of our own non-empty buffer is real.
            data.withUnsafeBytes { raw in memcpy(buffer, raw.baseAddress!, data.count) }
            lock.lock(); counters.chunksRead += 1; lock.unlock()
            return Int32(data.count)
        } catch {
            return Int32(G04SourceHostStatus.readFailed)
        }
    }

    /// Compare one finished verification staging (provider read-back bytes
    /// streamed by the host) against this lane's frozen native snapshot.
    /// Non-journal counterpart used by export/save-as receipts: the MATCH
    /// verdict is computed from two native digests, never a Kotlin string.
    func egressVerify(egressTicket: Int64, stageTicket: Int64,
                      buffer: UnsafeMutablePointer<CChar>?, capacity: Int32) -> Int32 {
        lock.lock()
        guard let egress = egresses[egressTicket], !egress.closed,
              let stage = stages[stageTicket], !stage.closed,
              stage.finishedSHA256 != nil,
              let live = liveEpoch(), egress.createdEpoch == live, stage.createdEpoch == live,
              stage.purpose == .exportVerify || stage.purpose == .readback else {
            let egressPresent = egresses[egressTicket] != nil
            let stagePresent = stages[stageTicket] != nil
            lock.unlock()
            if !egressPresent || !stagePresent { return G04SourceHostStatus.sessionUnknown }
            return G04SourceHostStatus.stateConflict
        }
        let match = stage.finishedSHA256 == egress.sha256
        lock.unlock()
        Self.consumeStage(stageTicket)
        return Self.copy(Self.json(["ok": 1, "match": match ? 1 : 0,
                                    "snapshotSHA256": egress.sha256,
                                    "observedSHA256": stage.finishedSHA256 ?? ""]),
                         buffer: buffer, capacity: capacity)
    }

    func egressClose(ticket: Int64) -> Int32 {
        lock.lock()
        guard let session = egresses[ticket], !session.closed else {
            let wasRetired = retired.contains(ticket)
            lock.unlock()
            return wasRetired ? Int32(G04SourceHostStatus.generationFenced)
                              : Int32(G04SourceHostStatus.ok)
        }
        if let live = liveEpoch(), session.createdEpoch != live {
            lock.unlock()
            return Int32(G04SourceHostStatus.generationFenced)
        }
        closeEgressLocked(session)
        lock.unlock()
        return Int32(G04SourceHostStatus.ok)
    }

    private func egressFailureStatusLocked(ticket: Int64) -> Int32 {
        if retired.contains(ticket) { return G04SourceHostStatus.generationFenced }
        guard egresses[ticket] != nil else { return G04SourceHostStatus.sessionUnknown }
        return G04SourceHostStatus.stateConflict
    }

    private func egressFailureStatus(ticket: Int64) -> Int32 {
        lock.lock(); defer { lock.unlock() }
        return egressFailureStatusLocked(ticket: ticket)
    }

    /// Journal phase 1 entry: bind the NATIVE-verified staged backup digest
    /// and the frozen snapshot replacement into `prepareRecovery`.
    func savePrepare(saveTicket: Int64, backupStageTicket: Int64, receiptToken: String,
                     buffer: UnsafeMutablePointer<CChar>?, capacity: Int32) -> Int32 {
        lock.lock()
        guard let save = egresses[saveTicket], !save.closed, save.mode == "save",
              save.phase == .open, let sourceID = save.sourceID,
              let backup = stages[backupStageTicket], !backup.closed,
              backup.purpose == .backupVerify, backup.finishedSHA256 != nil,
              let live = liveEpoch(), save.createdEpoch == live, backup.createdEpoch == live,
              save.taskID == backup.taskID, save.workspaceID == backup.workspaceID,
              Self.validReceiptToken(receiptToken) else {
            let observedSave = egresses[saveTicket]
            let observedBackup = stages[backupStageTicket]
            lock.unlock()
            return jointFailure(save: observedSave, backup: observedBackup)
        }
        let coordinator = requireCoordinator(epoch: live)
        let backupDigest = backup.finishedSHA256!
        let workspaceID = save.workspaceID, taskID = save.taskID
        let logicalPath = save.logicalPath, recoveryID = save.recoveryID
        let replacementDigest = save.sha256
        lock.unlock()
        guard let coordinator else { return Int32(G04SourceHostStatus.notInstalled) }
        let box = HostHopBox<G04WorkspaceSourceCoordinator.ReplacementReceipt>()
        let gate = DispatchSemaphore(value: 0)
        Task.detached(priority: .userInitiated) {
            do {
                let receipt = try await coordinator.prepareReplacementStaged(
                    sourceID: sourceID, taskID: taskID, workspaceID: workspaceID,
                    logicalPath: logicalPath, recoveryID: recoveryID,
                    freshBackupSHA256: backupDigest,
                    backupRelativePath: Self.journalBackupPath(sourceID: sourceID, recoveryID: recoveryID),
                    replacementSHA256: replacementDigest)
                box.value = .success(receipt)
            } catch {
                box.value = .failure(error)
            }
            gate.signal()
        }
        if gate.wait(timeout: .now() + .seconds(G04SourceHostLimits.shortHopSeconds)) == .timedOut {
            lock.lock(); counters.hopsTimedOut += 1; lock.unlock()
            return Int32(G04SourceHostStatus.hopTimeout)
        }
        switch box.value {
        case .success(let receipt):
            lock.lock()
            guard !save.closed, save.phase == .open else {
                counters.fenced += 1
                lock.unlock()
                return Int32(G04SourceHostStatus.generationFenced)
            }
            save.phase = .prepared
            save.receiptToken = receiptToken
            save.sourceRevision = receipt.source.revision
            save.recordedSHA256 = receipt.source.sourceSHA256
            counters.finished += 1
            lock.unlock()
            Self.consumeStage(backupStageTicket)
            return Self.copy(Self.json(["ok": 1, "state": "prepared",
                                        "recoveryID": receipt.recovery.id.uuidString,
                                        "sourceRevision": receipt.source.revision]),
                             buffer: buffer, capacity: capacity)
        case .failure(let error):
            let status = Self.errorStatus(error)
            lock.lock(); counters.refused += 1; lock.unlock()
            Self.consumeStage(backupStageTicket)
            if status == G04SourceHostStatus.digestMismatch {
                return Self.copy(Self.json(["ok": 0, "errorCode": "sourceChangedSinceImport",
                                            "reason": Self.errorReason(error)]),
                                 buffer: buffer, capacity: capacity)
            }
            return status
        case .none:
            Self.consumeStage(backupStageTicket)
            return Int32(G04SourceHostStatus.internal)
        }
    }

    /// Journal phase 2 entry: the SECOND native-observed provider digest
    /// (`fresh-observe` staging) must equal the journaled backup, and the
    /// durable claim is ONE-TIME (the store refuses any replay).
    func saveClaim(saveTicket: Int64, freshStageTicket: Int64,
                   buffer: UnsafeMutablePointer<CChar>?, capacity: Int32) -> Int32 {
        lock.lock()
        guard let save = egresses[saveTicket], !save.closed, save.mode == "save",
              save.phase == .prepared, let sourceID = save.sourceID,
              let fresh = stages[freshStageTicket], !fresh.closed,
              fresh.purpose == .freshObserve, fresh.finishedSHA256 != nil,
              let live = liveEpoch(), save.createdEpoch == live, fresh.createdEpoch == live,
              save.taskID == fresh.taskID, save.workspaceID == fresh.workspaceID else {
            let observedSave = egresses[saveTicket]
            let observedFresh = stages[freshStageTicket]
            lock.unlock()
            return jointFailure(save: observedSave, backup: observedFresh)
        }
        let coordinator = requireCoordinator(epoch: live)
        let freshDigest = fresh.finishedSHA256!
        let taskID = save.taskID, workspaceID = save.workspaceID
        let logicalPath = save.logicalPath, recoveryID = save.recoveryID
        lock.unlock()
        guard let coordinator else { return Int32(G04SourceHostStatus.notInstalled) }
        let box = HostHopBox<AndroidWorkspaceRecovery>()
        let gate = DispatchSemaphore(value: 0)
        Task.detached(priority: .userInitiated) {
            do {
                let claimed = try await coordinator.claimReplacementStaged(
                    recoveryID: recoveryID, sourceID: sourceID, taskID: taskID,
                    workspaceID: workspaceID, logicalPath: logicalPath,
                    freshSHA256: freshDigest)
                box.value = .success(claimed)
            } catch {
                box.value = .failure(error)
            }
            gate.signal()
        }
        if gate.wait(timeout: .now() + .seconds(G04SourceHostLimits.shortHopSeconds)) == .timedOut {
            lock.lock(); counters.hopsTimedOut += 1; lock.unlock()
            return Int32(G04SourceHostStatus.hopTimeout)
        }
        Self.consumeStage(freshStageTicket)
        switch box.value {
        case .success(let recovery):
            if recovery.state == .writing {
                lock.lock()
                guard !save.closed, save.phase == .prepared else {
                    counters.fenced += 1
                    lock.unlock()
                    return Int32(G04SourceHostStatus.generationFenced)
                }
                save.phase = .claimed; counters.finished += 1; lock.unlock()
                return Self.copy(Self.json(["ok": 1, "state": "writing",
                                            "recoveryID": recovery.id.uuidString]),
                                 buffer: buffer, capacity: capacity)
            }
            lock.lock()
            guard !save.closed, save.phase == .prepared else {
                counters.fenced += 1
                lock.unlock()
                return Int32(G04SourceHostStatus.generationFenced)
            }
            // A non-`writing` claim terminal (the store recorded `conflict`
            // durably) settles the session — there is no second claim.
            save.phase = .settled
            counters.refused += 1
            lock.unlock()
            return Self.copy(Self.json(["ok": 0, "errorCode": "driftAtClaim",
                                        "state": recovery.state.rawValue]),
                             buffer: buffer, capacity: capacity)
        case .failure(let error):
            let status = Self.errorStatus(error)
            lock.lock(); counters.refused += 1; lock.unlock()
            if status == G04SourceHostStatus.digestMismatch {
                return Self.copy(Self.json(["ok": 0, "errorCode": "sourceChangedSinceImport",
                                            "reason": Self.errorReason(error)]),
                                 buffer: buffer, capacity: capacity)
            }
            if let typed = error as? G04SourceCoordinatorError,
               case .providerFailed(let code) = typed {
                return Self.copy(Self.json(["ok": 0, "errorCode": code]),
                                 buffer: buffer, capacity: capacity)
            }
            return status
        case .none:
            return Int32(G04SourceHostStatus.internal)
        }
    }

    /// The gateway's destructive permit hook: handed at most ONCE per save
    /// session, only while the durable row is `writing`, and only to the
    /// exact caller receipt identity journaled at prepare.
    func savePermit(saveTicket: Int64, receiptToken: String) -> Int32 {
        lock.lock()
        guard let save = egresses[saveTicket], !save.closed, save.mode == "save",
              save.phase == .claimed, !save.permitIssued,
              save.receiptToken == receiptToken,
              let live = liveEpoch(), save.createdEpoch == live else {
            let present = egresses[saveTicket] != nil
            let wasRetired = retired.contains(saveTicket)
            let phase = egresses[saveTicket]?.phase
            lock.unlock()
            if wasRetired || saveTicket <= 0 { return Int32(G04SourceHostStatus.generationFenced) }
            guard present else { return Int32(G04SourceHostStatus.sessionUnknown) }
            if phase == .permitted || phase == .settled || phase == .retained {
                return Int32(G04SourceHostStatus.transitionRefused)
            }
            return Int32(G04SourceHostStatus.stateConflict)
        }
        save.phase = .permitted
        save.permitIssued = true
        counters.permitsIssued += 1
        lock.unlock()
        return Int32(G04SourceHostStatus.ok)
    }

    /// Journal phase 3 terminal: the provider read-back bytes streamed into
    /// native staging decide committed (digest equals the journaled
    /// replacement, binding CAS inside the store) or conflict (everything
    /// else) — the OBSERVED digest is always recorded, never a claim.
    func saveSettle(saveTicket: Int64, readbackStageTicket: Int64,
                    buffer: UnsafeMutablePointer<CChar>?, capacity: Int32) -> Int32 {
        lock.lock()
        guard let save = egresses[saveTicket], !save.closed, save.mode == "save",
              save.phase == .permitted, let sourceID = save.sourceID,
              let readback = stages[readbackStageTicket], !readback.closed,
              readback.purpose == .readback, readback.finishedSHA256 != nil,
              let live = liveEpoch(), save.createdEpoch == live, readback.createdEpoch == live,
              save.taskID == readback.taskID, save.workspaceID == readback.workspaceID else {
            let observedSave = egresses[saveTicket]
            let observedReadback = stages[readbackStageTicket]
            lock.unlock()
            return jointFailure(save: observedSave, backup: observedReadback)
        }
        let coordinator = requireCoordinator(epoch: live)
        let observed = readback.finishedSHA256!
        let taskID = save.taskID, workspaceID = save.workspaceID
        let logicalPath = save.logicalPath, recoveryID = save.recoveryID
        lock.unlock()
        guard let coordinator else { return Int32(G04SourceHostStatus.notInstalled) }
        let settleBox = HostHopBox<AndroidWorkspaceRecovery>()
        let gate = DispatchSemaphore(value: 0)
        Task.detached(priority: .userInitiated) {
            do {
                let terminal = try await coordinator.settleReplacementStaged(
                    recoveryID: recoveryID, sourceID: sourceID, taskID: taskID,
                    workspaceID: workspaceID, logicalPath: logicalPath,
                    readbackSHA256: observed)
                settleBox.value = .success(terminal)
            } catch {
                settleBox.value = .failure(error)
            }
            gate.signal()
        }
        if gate.wait(timeout: .now() + .seconds(G04SourceHostLimits.shortHopSeconds)) == .timedOut {
            lock.lock(); counters.hopsTimedOut += 1; lock.unlock()
            return Int32(G04SourceHostStatus.hopTimeout)
        }
        Self.consumeStage(readbackStageTicket)
        switch settleBox.value {
        case .success(let recovery):
            lock.lock()
            guard !save.closed, save.phase == .permitted else {
                counters.fenced += 1
                lock.unlock()
                return Int32(G04SourceHostStatus.generationFenced)
            }
            save.phase = .settled; counters.finished += 1
            closeEgressLocked(save)
            lock.unlock()
            return Self.copy(Self.json(["ok": recovery.state == .committed ? 1 : 0,
                                        "state": recovery.state.rawValue,
                                        "recoveryID": recovery.id.uuidString,
                                        "observedSHA256": recovery.observedSHA256 ?? "",
                                        "errorCode": recovery.state == .committed ? "" : "providerReadbackMismatch"]),
                             buffer: buffer, capacity: capacity)
        case .failure(let error):
            let status = Self.errorStatus(error)
            lock.lock(); counters.refused += 1; lock.unlock()
            return status
        case .none:
            return Int32(G04SourceHostStatus.internal)
        }
    }

    /// Honest abandon at any live ladder phase BEFORE a destructive write
    /// started; once the host attempted (or completed) a provider write the
    /// ONLY terminal is `saveSettle` (a possibly-partial `writing` row is
    /// decided by the provider's actual bytes, never by abandon).
    func saveRetain(saveTicket: Int64, buffer: UnsafeMutablePointer<CChar>?, capacity: Int32) -> Int32 {
        lock.lock()
        guard let save = egresses[saveTicket], !save.closed, save.mode == "save",
              let live = liveEpoch(), save.createdEpoch == live else {
            lock.unlock()
            return egressFailureStatus(ticket: saveTicket)
        }
        guard !save.permitIssued else {
            lock.unlock()
            return Int32(G04SourceHostStatus.transitionRefused)
        }
        let coordinator = requireCoordinator(epoch: live)
        let taskID = save.taskID, workspaceID = save.workspaceID, recoveryID = save.recoveryID
        let journalStarted = save.phase != .open
        lock.unlock()
        guard let coordinator else { return Int32(G04SourceHostStatus.notInstalled) }
        if !journalStarted {
            // The ladder never entered the journal: honest local abandon.
            // The snapshot scratch is redundant (the workspace file was
            // never touched), and no `prepared` row exists to retain.
            lock.lock()
            guard !save.closed, !save.permitIssued, save.phase == .open else {
                counters.fenced += 1
                lock.unlock()
                return Int32(G04SourceHostStatus.generationFenced)
            }
            save.phase = .retained
            counters.finished += 1
            closeEgressLocked(save)
            lock.unlock()
            return Self.copy(Self.json(["ok": 1, "state": "abandoned",
                                        "recoveryID": recoveryID.uuidString]),
                             buffer: buffer, capacity: capacity)
        }
        let retainBox = HostHopBox<AndroidWorkspaceRecovery?>()
        let gate = DispatchSemaphore(value: 0)
        Task.detached(priority: .userInitiated) {
            do {
                let terminal = try await coordinator.retainReplacement(
                    recoveryID: recoveryID, taskID: taskID, workspaceID: workspaceID)
                retainBox.value = .success(terminal)
            } catch {
                retainBox.value = .failure(error)
            }
            gate.signal()
        }
        if gate.wait(timeout: .now() + .seconds(G04SourceHostLimits.shortHopSeconds)) == .timedOut {
            lock.lock(); counters.hopsTimedOut += 1; lock.unlock()
            return Int32(G04SourceHostStatus.hopTimeout)
        }
        switch retainBox.value {
        case .success(let recovery):
            lock.lock()
            guard !save.closed, !save.permitIssued else {
                counters.fenced += 1
                lock.unlock()
                return Int32(G04SourceHostStatus.generationFenced)
            }
            save.phase = .retained
            counters.finished += 1
            closeEgressLocked(save)
            lock.unlock()
            return Self.copy(Self.json(["ok": 1, "state": recovery?.state.rawValue ?? "retained",
                                        "recoveryID": recoveryID.uuidString]),
                             buffer: buffer, capacity: capacity)
        case .failure(let error):
            let status = Self.errorStatus(error)
            lock.lock(); counters.refused += 1; lock.unlock()
            return status
        case .none:
            return Int32(G04SourceHostStatus.internal)
        }
    }

    private func jointFailure(save: EgressSession?, backup: StageSession?) -> Int32 {
        if save == nil { return G04SourceHostStatus.sessionUnknown }
        if backup == nil { return G04SourceHostStatus.sessionUnknown }
        let live = liveEpoch()
        if save?.createdEpoch != live || backup?.createdEpoch != live {
            return G04SourceHostStatus.generationFenced
        }
        return G04SourceHostStatus.stateConflict
    }

    /// A finished non-import stage that already fed its digest into a
    /// ladder entry is consumed (its staged bytes were re-observed from the
    /// live provider at the next phase anyway; retention windows are the
    /// CALLER's recovery store, never this table).
    private static func consumeStage(_ ticket: Int64) {
        G04WorkspaceSourceHost.shared.lock.lock()
        defer { G04WorkspaceSourceHost.shared.lock.unlock() }
        if let stage = G04WorkspaceSourceHost.shared.stages[ticket], !stage.closed {
            G04WorkspaceSourceHost.shared.closeStageLocked(stage)
        }
    }

    // MARK: - Metadata-only queries (bootstrap reconciliation inputs)

    func sourcePage(epoch: UInt64, workspaceHex: String, afterID: String, limit: Int,
                    buffer: UnsafeMutablePointer<CChar>?, capacity: Int32) -> Int32 {
        guard let live = liveEpoch(), live == epoch, let workspaceID = Self.canonicalUUID(workspaceHex),
              let coordinator = requireCoordinator(epoch: epoch) else {
            return Int32(epoch == 0 ? G04SourceHostStatus.notInstalled
                                    : G04SourceHostStatus.generationFenced)
        }
        let cursor = afterID.isEmpty ? nil : afterID
        let bounded = min(max(limit, 1), G04SourceHostLimits.maximumRowsPerPage)
        let rows: [AndroidWorkspaceSource]
        switch Self.hop(short: true, coordinator: coordinator,
                        after: { coordinator in try await coordinator.sourcesPage(workspaceID: workspaceID,
                                                                   afterID: cursor, limit: bounded) }) {
        case .success(let value): rows = value
        case .failure(let error): return Int32(Self.errorStatus(error))
        case .timeout: return Int32(G04SourceHostStatus.hopTimeout)
        }
        var objects: [[String: Any]] = []
        var used = 64
        var next: String? = nil
        for row in rows {
            let object: [String: Any] = [
                "id": row.id.uuidString, "path": row.logicalPath, "kind": row.kind.rawValue,
                "reference": row.sourceReference, "documentID": row.sourceDocumentID ?? "",
                "sha256": row.sourceSHA256 ?? "", "revision": row.revision,
            ]
            let size = Self.json(object).utf8.count + 2
            guard used + size <= min(Int(capacity), G04SourceHostLimits.maximumReplyBytes) else {
                next = row.id.uuidString
                break
            }
            used += size
            objects.append(object)
        }
        var reply: [String: Any] = ["ok": 1, "rows": objects]
        if let next { reply["nextAfterID"] = next }
        if objects.isEmpty && !rows.isEmpty { return Int32(G04SourceHostStatus.bufferTooSmall) }
        return Self.copy(Self.json(reply), buffer: buffer, capacity: capacity)
    }

    func sourceLookup(epoch: UInt64, workspaceHex: String, logicalPath: String,
                      buffer: UnsafeMutablePointer<CChar>?, capacity: Int32) -> Int32 {
        guard let live = liveEpoch(), live == epoch, let workspaceID = Self.canonicalUUID(workspaceHex),
              Self.validLogicalPath(logicalPath),
              let coordinator = requireCoordinator(epoch: epoch) else {
            return Int32(epoch == 0 ? G04SourceHostStatus.notInstalled
                                    : G04SourceHostStatus.generationFenced)
        }
        let row: AndroidWorkspaceSource?
        switch Self.hop(short: true, coordinator: coordinator,
                        after: { coordinator in try await coordinator.sourceRecord(workspaceID: workspaceID,
                                                                    logicalPath: logicalPath) }) {
        case .success(let value): row = value
        case .failure(let error): return Int32(Self.errorStatus(error))
        case .timeout: return Int32(G04SourceHostStatus.hopTimeout)
        }
        guard let row else {
            return Self.copy(Self.json(["ok": 0, "errorCode": "sourceUnbound"]),
                             buffer: buffer, capacity: capacity)
        }
        return Self.copy(Self.json(["ok": 1, "id": row.id.uuidString, "path": row.logicalPath,
                                    "kind": row.kind.rawValue, "reference": row.sourceReference,
                                    "documentID": row.sourceDocumentID ?? "",
                                    "sha256": row.sourceSHA256 ?? "", "revision": row.revision]),
                         buffer: buffer, capacity: capacity)
    }

    func recoveryPage(epoch: UInt64, workspaceHex: String, afterID: String, limit: Int,
                      buffer: UnsafeMutablePointer<CChar>?, capacity: Int32) -> Int32 {
        guard let live = liveEpoch(), live == epoch,
              let coordinator = requireCoordinator(epoch: epoch) else {
            return Int32(epoch == 0 ? G04SourceHostStatus.notInstalled
                                    : G04SourceHostStatus.generationFenced)
        }
        let workspaceID = workspaceHex.isEmpty ? nil : Self.canonicalUUID(workspaceHex)
        if !workspaceHex.isEmpty, workspaceID == nil { return Int32(G04SourceHostStatus.invalidArguments) }
        let cursor = afterID.isEmpty ? nil : afterID
        let bounded = min(max(limit, 1), 64)
        let rows: [AndroidWorkspaceRecovery]
        switch Self.hop(short: true, coordinator: coordinator,
                        after: { coordinator in try await coordinator.recoveryJournal(workspaceID: workspaceID,
                                                                       afterID: cursor, limit: bounded) }) {
        case .success(let value): rows = value
        case .failure(let error): return Int32(Self.errorStatus(error))
        case .timeout: return Int32(G04SourceHostStatus.hopTimeout)
        }
        var objects: [[String: Any]] = []
        var used = 64
        var next: String? = nil
        for row in rows {
            let object: [String: Any] = [
                "id": row.id.uuidString, "sourceID": row.sourceID.uuidString,
                "state": row.state.rawValue, "backupSHA256": row.backupSHA256,
                "replacementSHA256": row.replacementSHA256,
                "observedSHA256": row.observedSHA256 ?? "",
                "reference": row.sourceReference, "revision": row.sourceRevision,
            ]
            let size = Self.json(object).utf8.count + 2
            guard used + size <= min(Int(capacity), G04SourceHostLimits.maximumReplyBytes) else {
                next = row.id.uuidString
                break
            }
            used += size
            objects.append(object)
        }
        var reply: [String: Any] = ["ok": 1, "rows": objects]
        if let next { reply["nextAfterID"] = next }
        if objects.isEmpty && !rows.isEmpty { return Int32(G04SourceHostStatus.bufferTooSmall) }
        return Self.copy(Self.json(reply), buffer: buffer, capacity: capacity)
    }

    /// The ORIGINAL transport-backed reconcile run (mailbox provider reads,
    /// bounded documents). >4 MiB receipts stay honestly pending until the
    /// staged counterpart below observes their bytes; the run never labels
    /// them settled.
    func reconcileRun(epoch: UInt64, workspaceHex: String,
                      buffer: UnsafeMutablePointer<CChar>?, capacity: Int32) -> Int32 {
        guard let live = liveEpoch(), live == epoch, let coordinator = requireCoordinator(epoch: epoch) else {
            return Int32(epoch == 0 ? G04SourceHostStatus.notInstalled
                                    : G04SourceHostStatus.generationFenced)
        }
        let workspaceID = workspaceHex.isEmpty ? nil : Self.canonicalUUID(workspaceHex)
        if !workspaceHex.isEmpty, workspaceID == nil { return Int32(G04SourceHostStatus.invalidArguments) }
        let settled: Int
        switch Self.hop(short: false, coordinator: coordinator,
                        after: { coordinator in try await coordinator.reconcileInterruptedReplacements(workspaceID: workspaceID) }) {
        case .success(let value): settled = value
        case .failure(G04SourceCoordinatorError.transportNotBound):
            return Self.copy(Self.json(["ok": 0, "errorCode": "transportNotBound"]),
                             buffer: buffer, capacity: capacity)
        case .failure(let error): return Int32(Self.errorStatus(error))
        case .timeout: return Int32(G04SourceHostStatus.hopTimeout)
        }
        return Self.copy(Self.json(["ok": 1, "settled": settled]), buffer: buffer, capacity: capacity)
    }

    /// The >4 MiB staged counterpart: the host streamed the current provider
    /// bytes into native staging (`observe` purpose) for ONE unfinished
    /// receipt; native's digest decides exactly like the transport run
    /// (replacement -> committed CAS, backup -> retained, else conflict).
    func reconcileStaged(epoch: UInt64, taskHex: String, workspaceHex: String,
                         recoveryHex: String, stageTicket: Int64,
                         buffer: UnsafeMutablePointer<CChar>?, capacity: Int32) -> Int32 {
        guard let live = liveEpoch(), live == epoch, let taskID = Self.canonicalUUID(taskHex),
              let workspaceID = Self.canonicalUUID(workspaceHex), let recoveryID = Self.canonicalUUID(recoveryHex),
              let coordinator = requireCoordinator(epoch: epoch) else {
            return Int32(epoch == 0 ? G04SourceHostStatus.notInstalled
                                    : G04SourceHostStatus.generationFenced)
        }
        lock.lock()
        guard let stage = stages[stageTicket], !stage.closed, stage.finishedSHA256 != nil,
              stage.createdEpoch == live, stage.taskID == taskID, stage.workspaceID == workspaceID else {
            let stagePresent = stages[stageTicket] != nil
            lock.unlock()
            return stagePresent ? Int32(G04SourceHostStatus.stateConflict)
                               : Int32(G04SourceHostStatus.sessionUnknown)
        }
        let observed = stage.finishedSHA256!
        lock.unlock()
        let recovery: AndroidWorkspaceRecovery
        switch Self.hop(short: true, coordinator: coordinator,
                        after: { coordinator in try await coordinator.reconcileReceiptStaged(
                            recoveryID: recoveryID, taskID: taskID, workspaceID: workspaceID,
                            observedSHA256: observed) }) {
        case .success(let value): recovery = value
        case .failure(let error):
            Self.consumeStage(stageTicket)
            return Int32(Self.errorStatus(error))
        case .timeout:
            return Int32(G04SourceHostStatus.hopTimeout)
        }
        Self.consumeStage(stageTicket)
        return Self.copy(Self.json(["ok": 1, "state": recovery.state.rawValue,
                                    "recoveryID": recovery.id.uuidString,
                                    "observedSHA256": recovery.observedSHA256 ?? observed]),
                         buffer: buffer, capacity: capacity)
    }

    // MARK: - Stats (typed counters only; no paths, bytes or identities)

    func statsJSON() -> String {
        lock.lock()
        let object: [String: Any] = [
            "live": stages.count + egresses.count,
            "retired": retired.count,
            "aggregateStagedBytes": aggregateStagedBytes,
            "counters": [
                "opens": counters.opens, "chunksWritten": counters.chunksWritten,
                "chunksRead": counters.chunksRead, "finished": counters.finished,
                "aborted": counters.aborted, "fenced": counters.fenced,
                "refused": counters.refused, "saturated": counters.saturated,
                "permitsIssued": counters.permitsIssued, "hopsTimedOut": counters.hopsTimedOut,
            ],
        ]
        lock.unlock()
        return Self.json(object)
    }

    func stats(buffer: UnsafeMutablePointer<CChar>?, capacity: Int32) -> Int32 {
        Self.copy(statsJSON(), buffer: buffer, capacity: capacity)
    }

    // MARK: - Grammar helpers

    private enum HopOutcome<Value> { case success(Value), failure(any Error), timeout }

    private static func hop<Value>(short: Bool, coordinator: G04WorkspaceSourceCoordinator,
                                   after: @escaping @Sendable (G04WorkspaceSourceCoordinator) async throws -> Value)
        -> HopOutcome<Value> {
        let box = HostHopBox<Value>()
        let gate = DispatchSemaphore(value: 0)
        Task.detached(priority: .userInitiated) {
            do { box.value = .success(try await after(coordinator)) }
            catch { box.value = .failure(error) }
            gate.signal()
        }
        let budget = short ? G04SourceHostLimits.shortHopSeconds : G04SourceHostLimits.fileHopSeconds
        if gate.wait(timeout: .now() + .seconds(budget)) == .timedOut {
            G04WorkspaceSourceHost.shared.lock.lock()
            G04WorkspaceSourceHost.shared.counters.hopsTimedOut += 1
            G04WorkspaceSourceHost.shared.lock.unlock()
            return .timeout
        }
        switch box.value {
        case .success(let value): return .success(value)
        case .failure(let error): return .failure(error)
        case .none: return .failure(G04SourceCoordinatorError.invalidMetadata("hop"))
        }
    }

    /// Canonical UUID acceptance exactly like the delivered mailbox pump
    /// descriptor check (case-insensitive canonical spelling, no reformat
    /// surprises).
    static func canonicalUUID(_ raw: String?) -> UUID? {
        guard let raw, !raw.isEmpty, let value = UUID(uuidString: raw) else { return nil }
        return value.uuidString.caseInsensitiveCompare(raw) == .orderedSame ? value : nil
    }

    /// Mirrors the ORIGINAL journal `validPath` grammar (relative, no
    /// dot-segments, no backslash/NUL, standardized).
    static func validLogicalPath(_ path: String) -> Bool {
        guard !path.isEmpty, path.utf8.count <= 4096, !path.hasPrefix("/"), !path.hasPrefix("~"),
              !path.contains("\\"), !path.contains("\0"),
              path == (path as NSString).standardizingPath else { return false }
        return path.split(separator: "/", omittingEmptySubsequences: false)
            .allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." }
    }

    /// Mirrors the ORIGINAL journal `validReference` SAF rules.
    static func validSourceReference(_ reference: String) -> Bool {
        guard reference.utf8.count <= 8192,
              let components = URLComponents(string: reference), components.scheme == "content",
              let host = components.host, !host.isEmpty,
              components.user == nil, components.password == nil, components.fragment == nil
        else { return false }
        return !reference.contains("\0") && !reference.contains("\n") && !reference.contains("\r")
    }

    /// The caller gateway's opaque receipt identity: `rec-<canonical uuid>`.
    static func validReceiptToken(_ token: String) -> Bool {
        guard token.count <= 80, token.hasPrefix("rec-") else { return false }
        return canonicalUUID(String(token.dropFirst(4))) != nil
    }

    static func journalBackupPath(sourceID: UUID, recoveryID: UUID) -> String {
        "Source Recovery/\(sourceID.uuidString)/\(recoveryID.uuidString).bin"
    }

    static func json(_ object: [String: Any]) -> String {
        guard JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
              let text = String(data: data, encoding: .utf8) else { return "{\"ok\":0,\"errorCode\":\"internal\"}" }
        return text
    }

    static func errorToken(_ error: any Error) -> String {
        if let coordinator = error as? G04SourceCoordinatorError {
            switch coordinator {
            case .retired: return "retired"
            case .conversationMissing, .purposeNotOrdinary, .workspaceUnbound, .ownerChanged:
                return "identityRefused"
            case .invalidMetadata: return "invalidMetadata"
            case .stagedBytesUnavailable: return "emptyFile"
            case .digestMismatch: return "digestMismatch"
            case .transportNotBound: return "transportNotBound"
            case .sourceMissing: return "sourceMissing"
            case .staleRevision: return "staleRevision"
            case .transitionRefused: return "transitionRefused"
            case .readbackMismatch: return "readbackMismatch"
            case .providerFailed(let code): return code
            case .tooLarge: return "sizeExceeded"
            case .diskFull: return "diskFull"
            case .invalidWorkingCopy: return "invalidWorkingCopy"
            }
        }
        if let store = error as? AndroidWorkspaceSourceError {
            switch store {
            case .invalidMetadata: return "invalidMetadata"
            case .missingSource: return "sourceMissing"
            case .staleRevision: return "staleRevision"
            case .receiptMismatch: return "receiptMismatch"
            case .invalidTransition: return "transitionRefused"
            @unknown default: return "transitionRefused"
            }
        }
        if let mailbox = error as? G04SourceMailboxError {
            return G04WorkspaceSourceMailboxTransport.relay(mailbox) == .transportNotBound
                ? "transportNotBound" : "providerFailed"
        }
        return "internal"
    }

    static func errorReason(_ error: any Error) -> String {
        if let coordinator = error as? G04SourceCoordinatorError {
            switch coordinator {
            case .transitionRefused(let reason): return String(reason.prefix(64))
            case .stagedBytesUnavailable(let reason): return String(reason.prefix(64))
            case .invalidWorkingCopy(let reason): return String(reason.prefix(64))
            case .providerFailed(let code): return String(code.prefix(64))
            default: return ""
            }
        }
        return ""
    }

    static func errorStatus(_ error: any Error) -> Int32 {
        if error is G04SourceCoordinatorError {
            switch error as? G04SourceCoordinatorError {
            case .retired: return G04SourceHostStatus.generationFenced
            case .conversationMissing, .purposeNotOrdinary, .workspaceUnbound, .ownerChanged:
                return G04SourceHostStatus.identityRefused
            case .invalidMetadata: return G04SourceHostStatus.invalidArguments
            case .stagedBytesUnavailable: return G04SourceHostStatus.stateConflict
            case .digestMismatch: return G04SourceHostStatus.digestMismatch
            case .transportNotBound: return G04SourceHostStatus.transportUnavailable
            case .sourceMissing: return G04SourceHostStatus.sourceMissing
            case .staleRevision: return G04SourceHostStatus.staleRevision
            case .transitionRefused: return G04SourceHostStatus.transitionRefused
            case .readbackMismatch: return G04SourceHostStatus.digestMismatch
            case .providerFailed: return G04SourceHostStatus.providerFailed
            case .tooLarge: return G04SourceHostStatus.sizeExceeded
            case .diskFull: return G04SourceHostStatus.diskFull
            case .invalidWorkingCopy: return G04SourceHostStatus.stateConflict
            case .none: return G04SourceHostStatus.internal
            }
        }
        if error is AndroidWorkspaceSourceError {
            switch error as? AndroidWorkspaceSourceError {
            case .invalidMetadata: return G04SourceHostStatus.invalidArguments
            case .missingSource: return G04SourceHostStatus.sourceMissing
            case .staleRevision: return G04SourceHostStatus.staleRevision
            case .receiptMismatch: return G04SourceHostStatus.transitionRefused
            case .invalidTransition: return G04SourceHostStatus.transitionRefused
            @unknown default: return G04SourceHostStatus.internal
            }
        }
        if error is G04SourceMailboxError { return G04SourceHostStatus.transportUnavailable }
        return G04SourceHostStatus.internal
    }

    static func copy(_ text: String, buffer: UnsafeMutablePointer<CChar>?, capacity: Int32) -> Int32 {
        let bytes = Array(text.utf8)
        guard bytes.count + 1 <= Int(capacity) else { return G04SourceHostStatus.bufferTooSmall }
        guard let buffer else { return G04SourceHostStatus.invalidArguments }
        for (index, byte) in bytes.enumerated() { buffer[index] = CChar(bitPattern: byte) }
        buffer[bytes.count] = 0
        return Int32(bytes.count)
    }
}

// MARK: - Trusted host C ABI (`floe_g04_source_host_*`; Kotlin JNI only)

/// Chunked staged ingress open. Positive = opaque ticket; negative = typed
/// status. `purpose` is the closed token set; `import` requires the exact
/// logicalPath + content reference + planned sourceID grammar.
@_cdecl("floe_g04_source_host_stage_open")
public func floeG04SourceHostStageOpen(
    _ epoch: UInt64, _ taskHex: UnsafeMutablePointer<CChar>?, _ workspaceHex: UnsafeMutablePointer<CChar>?,
    _ purpose: UnsafeMutablePointer<CChar>?, _ logicalPath: UnsafeMutablePointer<CChar>?,
    _ sourceReference: UnsafeMutablePointer<CChar>?, _ sourceDocumentID: UnsafeMutablePointer<CChar>?,
    _ sourceHex: UnsafeMutablePointer<CChar>?
) -> Int64 {
    G04WorkspaceSourceHost.shared.stageOpen(
        epoch: epoch, purposeRaw: G04HostC.string(purpose) ?? "",
        taskHex: G04HostC.string(taskHex) ?? "", workspaceHex: G04HostC.string(workspaceHex) ?? "",
        sourceHex: G04HostC.optionalString(sourceHex), logicalPath: G04HostC.optionalString(logicalPath),
        sourceReference: G04HostC.optionalString(sourceReference),
        sourceDocumentID: G04HostC.optionalString(sourceDocumentID))
}

/// Append ONE bounded chunk (<= 64 KiB) to a live, unfrozen stage.
@_cdecl("floe_g04_source_host_stage_write")
public func floeG04SourceHostStageWrite(_ ticket: Int64, _ data: UnsafePointer<UInt8>?,
                                       _ length: Int32) -> Int32 {
    guard let data, length > 0, length <= Int32(G04SourceHostLimits.maximumChunkBytes) else {
        return Int32(G04SourceHostStatus.invalidArguments)
    }
    return G04WorkspaceSourceHost.shared.stageWrite(ticket: ticket,
                                                    data: Data(bytes: data, count: Int(length)))
}

/// Freeze + hash + run the purpose terminal; writes the bounded JSON reply.
@_cdecl("floe_g04_source_host_stage_finish")
public func floeG04SourceHostStageFinish(_ ticket: Int64, _ buffer: UnsafeMutablePointer<CChar>?,
                                         _ capacity: Int32) -> Int32 {
    G04WorkspaceSourceHost.shared.stageFinish(ticket: ticket, buffer: buffer, capacity: capacity)
}

@_cdecl("floe_g04_source_host_stage_abort")
public func floeG04SourceHostStageAbort(_ ticket: Int64) -> Int32 {
    G04WorkspaceSourceHost.shared.stageAbort(ticket: ticket)
}

/// Freeze one native working copy into a snapshot for chunked egress.
/// mode: "save" (journal ladder) | "export" (non-destructive send).
@_cdecl("floe_g04_source_host_egress_open")
public func floeG04SourceHostEgressOpen(_ epoch: UInt64, _ mode: UnsafeMutablePointer<CChar>?,
                                        _ taskHex: UnsafeMutablePointer<CChar>?,
                                        _ workspaceHex: UnsafeMutablePointer<CChar>?,
                                        _ logicalPath: UnsafeMutablePointer<CChar>?,
                                        _ sourceHex: UnsafeMutablePointer<CChar>?) -> Int64 {
    G04WorkspaceSourceHost.shared.egressOpen(
        epoch: epoch, mode: G04HostC.string(mode) ?? "",
        taskHex: G04HostC.string(taskHex) ?? "", workspaceHex: G04HostC.string(workspaceHex) ?? "",
        logicalPath: G04HostC.string(logicalPath) ?? "", sourceHex: G04HostC.optionalString(sourceHex))
}

@_cdecl("floe_g04_source_host_egress_info")
public func floeG04SourceHostEgressInfo(_ ticket: Int64, _ buffer: UnsafeMutablePointer<CChar>?,
                                        _ capacity: Int32) -> Int32 {
    G04WorkspaceSourceHost.shared.egressInfo(ticket: ticket, buffer: buffer, capacity: capacity)
}

/// Copy snapshot bytes [offset, offset+capacity) into the caller buffer.
/// Returns copied length (0 = clean EOF) or a typed negative status.
@_cdecl("floe_g04_source_host_egress_read")
public func floeG04SourceHostEgressRead(_ ticket: Int64, _ offset: Int64,
                                        _ buffer: UnsafeMutablePointer<UInt8>?,
                                        _ capacity: Int32) -> Int32 {
    G04WorkspaceSourceHost.shared.egressRead(ticket: ticket, offset: offset, buffer: buffer,
                                             capacity: capacity)
}

/// Native-vs-native digest comparison for provider read-back staging.
@_cdecl("floe_g04_source_host_egress_verify")
public func floeG04SourceHostEgressVerify(_ egressTicket: Int64, _ stageTicket: Int64,
                                          _ buffer: UnsafeMutablePointer<CChar>?,
                                          _ capacity: Int32) -> Int32 {
    G04WorkspaceSourceHost.shared.egressVerify(egressTicket: egressTicket, stageTicket: stageTicket,
                                               buffer: buffer, capacity: capacity)
}

@_cdecl("floe_g04_source_host_egress_close")
public func floeG04SourceHostEgressClose(_ ticket: Int64) -> Int32 {
    G04WorkspaceSourceHost.shared.egressClose(ticket: ticket)
}

/// Journal phase 1 (staged fresh backup verify -> `prepared`).
@_cdecl("floe_g04_source_host_save_prepare")
public func floeG04SourceHostSavePrepare(_ saveTicket: Int64, _ backupStageTicket: Int64,
                                         _ receiptToken: UnsafeMutablePointer<CChar>?,
                                         _ buffer: UnsafeMutablePointer<CChar>?,
                                         _ capacity: Int32) -> Int32 {
    G04WorkspaceSourceHost.shared.savePrepare(saveTicket: saveTicket,
                                              backupStageTicket: backupStageTicket,
                                              receiptToken: G04HostC.string(receiptToken) ?? "",
                                              buffer: buffer, capacity: capacity)
}

/// Journal phase 2 (second fresh observation -> ONE-TIME `writing`).
@_cdecl("floe_g04_source_host_save_claim")
public func floeG04SourceHostSaveClaim(_ saveTicket: Int64, _ freshStageTicket: Int64,
                                       _ buffer: UnsafeMutablePointer<CChar>?,
                                       _ capacity: Int32) -> Int32 {
    G04WorkspaceSourceHost.shared.saveClaim(saveTicket: saveTicket, freshStageTicket: freshStageTicket,
                                            buffer: buffer, capacity: capacity)
}

/// Destructive permit: 0 = exactly one permit handed; negative = typed
/// refusal (`transitionRefused` for a replayed/foreign token).
@_cdecl("floe_g04_source_host_save_permit")
public func floeG04SourceHostSavePermit(_ saveTicket: Int64,
                                        _ receiptToken: UnsafeMutablePointer<CChar>?) -> Int32 {
    G04WorkspaceSourceHost.shared.savePermit(saveTicket: saveTicket,
                                             receiptToken: G04HostC.string(receiptToken) ?? "")
}

/// Journal phase 3 terminal (actual read-back digest decides).
@_cdecl("floe_g04_source_host_save_settle")
public func floeG04SourceHostSaveSettle(_ saveTicket: Int64, _ readbackStageTicket: Int64,
                                        _ buffer: UnsafeMutablePointer<CChar>?,
                                        _ capacity: Int32) -> Int32 {
    G04WorkspaceSourceHost.shared.saveSettle(saveTicket: saveTicket,
                                             readbackStageTicket: readbackStageTicket,
                                             buffer: buffer, capacity: capacity)
}

/// Honest abandon BEFORE any destructive write started; typed refusal
/// after a permit was handed (only `save_settle`/reconcile may decide).
@_cdecl("floe_g04_source_host_save_retain")
public func floeG04SourceHostSaveRetain(_ saveTicket: Int64, _ buffer: UnsafeMutablePointer<CChar>?,
                                        _ capacity: Int32) -> Int32 {
    G04WorkspaceSourceHost.shared.saveRetain(saveTicket: saveTicket, buffer: buffer, capacity: capacity)
}

/// Metadata-only bounded page of durable source rows (bootstrap
/// reconciliation input; release UI stays disabled until consumed).
@_cdecl("floe_g04_source_host_source_page")
public func floeG04SourceHostSourcePage(_ epoch: UInt64, _ workspaceHex: UnsafeMutablePointer<CChar>?,
                                        _ afterID: UnsafeMutablePointer<CChar>?, _ limit: Int32,
                                        _ buffer: UnsafeMutablePointer<CChar>?,
                                        _ capacity: Int32) -> Int32 {
    G04WorkspaceSourceHost.shared.sourcePage(
        epoch: epoch, workspaceHex: G04HostC.string(workspaceHex) ?? "",
        afterID: G04HostC.string(afterID) ?? "", limit: Int(max(1, min(limit, 64))),
        buffer: buffer, capacity: capacity)
}

@_cdecl("floe_g04_source_host_source_lookup")
public func floeG04SourceHostSourceLookup(_ epoch: UInt64, _ workspaceHex: UnsafeMutablePointer<CChar>?,
                                          _ logicalPath: UnsafeMutablePointer<CChar>?,
                                          _ buffer: UnsafeMutablePointer<CChar>?,
                                          _ capacity: Int32) -> Int32 {
    G04WorkspaceSourceHost.shared.sourceLookup(
        epoch: epoch, workspaceHex: G04HostC.string(workspaceHex) ?? "",
        logicalPath: G04HostC.string(logicalPath) ?? "", buffer: buffer, capacity: capacity)
}

@_cdecl("floe_g04_source_host_recovery_page")
public func floeG04SourceHostRecoveryPage(_ epoch: UInt64, _ workspaceHex: UnsafeMutablePointer<CChar>?,
                                          _ afterID: UnsafeMutablePointer<CChar>?, _ limit: Int32,
                                          _ buffer: UnsafeMutablePointer<CChar>?,
                                          _ capacity: Int32) -> Int32 {
    G04WorkspaceSourceHost.shared.recoveryPage(
        epoch: epoch, workspaceHex: G04HostC.string(workspaceHex) ?? "",
        afterID: G04HostC.string(afterID) ?? "", limit: Int(limit), buffer: buffer, capacity: capacity)
}

@_cdecl("floe_g04_source_host_reconcile_run")
public func floeG04SourceHostReconcileRun(_ epoch: UInt64, _ workspaceHex: UnsafeMutablePointer<CChar>?,
                                          _ buffer: UnsafeMutablePointer<CChar>?,
                                          _ capacity: Int32) -> Int32 {
    G04WorkspaceSourceHost.shared.reconcileRun(
        epoch: epoch, workspaceHex: G04HostC.string(workspaceHex) ?? "",
        buffer: buffer, capacity: capacity)
}

@_cdecl("floe_g04_source_host_reconcile_staged")
public func floeG04SourceHostReconcileStaged(_ epoch: UInt64, _ taskHex: UnsafeMutablePointer<CChar>?,
                                             _ workspaceHex: UnsafeMutablePointer<CChar>?,
                                             _ recoveryHex: UnsafeMutablePointer<CChar>?,
                                             _ stageTicket: Int64,
                                             _ buffer: UnsafeMutablePointer<CChar>?,
                                             _ capacity: Int32) -> Int32 {
    G04WorkspaceSourceHost.shared.reconcileStaged(
        epoch: epoch, taskHex: G04HostC.string(taskHex) ?? "",
        workspaceHex: G04HostC.string(workspaceHex) ?? "", recoveryHex: G04HostC.string(recoveryHex) ?? "",
        stageTicket: stageTicket, buffer: buffer, capacity: capacity)
}

/// Typed counters JSON only (no paths, no bytes, no identities).
@_cdecl("floe_g04_source_host_stats")
public func floeG04SourceHostStats(_ buffer: UnsafeMutablePointer<CChar>?, _ capacity: Int32) -> Int32 {
    G04WorkspaceSourceHost.shared.stats(buffer: buffer, capacity: capacity)
}

enum G04HostC {
    static func string(_ pointer: UnsafeMutablePointer<CChar>?) -> String? {
        guard let pointer else { return nil }
        return String(cString: pointer)
    }

    static func optionalString(_ pointer: UnsafeMutablePointer<CChar>?) -> String? {
        guard let value = string(pointer), !value.isEmpty else { return nil }
        return value
    }
}
