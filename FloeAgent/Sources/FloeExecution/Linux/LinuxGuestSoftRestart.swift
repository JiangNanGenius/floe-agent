// FloeExecution — REAL ordered Linux guest soft restart.
//
// The soft-restart performer behind `environment.softRestartLinux`: an
// ordered, evidence-checked in-guest flush + orderly poweroff + verified
// new-boot reconnect, run under the SAME shared lifecycle transaction the
// hard restart uses. The manager (LinuxGuestLifecycle.swift) owns the
// per-environment serialization, the pre/post runtime verification and the
// transaction; this file owns the durable operation record, the stage
// protocol against the guest, the unknown-outcome reconciliation and the
// default performer implementation.
//
// Why this backend: the pinned guest pair has no SIFIVE test/reset device
// (CONFIG_POWER_RESET_RESTART is off, no reset driver), so an in-guest
// RB_AUTOBOOT reboot has no machine reset to land on. An orderly POWEROFF
// does: the kernel's machine poweroff reaches the HTIF shutdown
// (tohost == 1, the vendored poweroff-callback patch records it) and the
// emulator run loop exits — the actual guest leaving is observable host-side.
// The host then captures the flushed disk and boots the replacement under
// the still-held transaction. That is materially different from a hard
// restart: the guest shut ITSELF down after an explicit ordered filesystem
// flush, so the disk journal is clean and the stop is a capture, never a
// force-stop of a live VM. An unknown outcome is NEVER converted into a
// force reset: it stays reconcilable until authoritative state converges.
//
// Honesty invariants encoded here:
//
//  * A durable operation record (nonce + captured pre-state + per-stage
//    receipts) is written BEFORE any guest action. An interruption leaves a
//    reconcilable unknown, never a silent repeat: a retry first queries the
//    same operation against current boot truth and converges (committed
//    receipt, resuming completion, or a proven-failed restart) before any
//    new guest action. A blind repeat while the outcome is unresolved is
//    refused.
//  * An API success, an echo, or a lost console is never proof of a reboot.
//    The reboot is proven by the ordered chain: flush END 0, the poweroff
//    request accepted, the ACTUAL instance leaving, the launch generation
//    rotating on the replacement, and the pre-reboot nonce read back from
//    the persistent disk on the new boot.
//  * Cancellation is the caller's token propagated through every stage; no
//    fresh token is minted. Pre-submission cancellation is clean (nothing
//    destructive was submitted). Post-submission the outcome is reported as
//    committed or unknown, never as a clean cancel and never as a force
//    reset.
//  * Stage commands run on the transaction-owned session's console channel
//    through the low-level transaction seam: the transaction token is the
//    authority, the lifecycle lock is never re-acquired, so the ordered
//    sequence cannot deadlock on the lease it holds.

import Foundation
import FloeCore
import FloeTools

// MARK: - operation record

/// Ordered stages of one soft-restart operation, in execution order.
public enum LinuxGuestSoftRestartStage: String, Sendable, Codable, Equatable {
    /// Ordered filesystem flush (+ capability proof + durable nonce write).
    case flush
    /// The orderly poweroff request submitted to the guest.
    case rebootRequest
    /// The actual guest instance left after the poweroff.
    case guestExit
    /// The exited guest's flushed disk was captured into the environment.
    case diskCapture
    /// The replacement booted, the generation rotated and the nonce read back.
    case newBoot
}

/// One observed stage boundary. `outcome` is "ok", "failed" or "unknown";
/// the detail is audit-facing text, never model-authored proof.
public struct LinuxGuestSoftRestartStageReceipt: Sendable, Codable, Equatable {
    public var stage: LinuxGuestSoftRestartStage
    public var outcome: String
    public var detail: String
    public var observedAt: Date

    public init(
        stage: LinuxGuestSoftRestartStage,
        outcome: String,
        detail: String,
        observedAt: Date = Date()
    ) {
        self.stage = stage
        self.outcome = outcome
        self.detail = detail
        self.observedAt = observedAt
    }
}

/// How far one operation progressed. Persisted so an interrupted operation
/// can be resumed or proven-settled; the stage receipts carry the evidence.
public enum LinuxGuestSoftRestartProgress: String, Sendable, Codable, Equatable {
    /// Durable receipt captured; no guest action taken yet.
    case recorded
    /// Ordered flush + nonce write completed (END 0 observed).
    case flushProven
    /// The poweroff request was accepted by the guest.
    case poweroffSubmitted
    /// The actual instance left after the poweroff.
    case guestExitObserved
    /// The exited guest's disk capture committed.
    case diskCaptureCommitted

    /// Monotonic stage rank for "at least" comparisons.
    public var rank: Int {
        switch self {
        case .recorded: return 0
        case .flushProven: return 1
        case .poweroffSubmitted: return 2
        case .guestExitObserved: return 3
        case .diskCaptureCommitted: return 4
        }
    }

    public func isAtLeast(_ other: LinuxGuestSoftRestartProgress) -> Bool {
        rank >= other.rank
    }
}

public enum LinuxGuestSoftRestartStatus: String, Sendable, Codable, Equatable {
    /// Submitted but not settled: the outcome is unknown and blocks blind
    /// repeats until a query against current state converges it.
    case pending
    /// Verified end to end (including convergence after an interruption).
    case committed
    /// Settled with a known failure; a fresh attempt may proceed.
    case failed
}

/// The durable operation record for one environment's soft restart. Only the
/// LATEST operation is kept per environment; a settled record is overwritten
/// by the next operation. The nonce doubles as the guest-side receipt: the
/// guest writes it to the persistent disk before powering off, and the new
/// boot must read the identical value back.
public struct LinuxGuestSoftRestartOperation: Sendable, Codable, Equatable {
    public var operationID: String
    public var environmentID: String
    public var ownerTaskID: String?
    public var operationKey: String?
    public var requestedVCPUs: Int?
    public var requestedMemoryMB: Int?
    /// The resolved replacement shape (validated under the release gate
    /// BEFORE any disruption). On a resumed operation this recorded shape —
    /// not the retry's fresh resolution — boots the replacement.
    public var resolvedShape: GuestResourceRequest
    /// Captured pre-restart truth (the runtime's own session table, never
    /// the request).
    public var preLaunchGeneration: UInt64?
    public var preVCPUs: Int
    public var preMemoryMB: Int
    public var preImageID: String?
    public var progress: LinuxGuestSoftRestartProgress
    public var status: LinuxGuestSoftRestartStatus
    public var stageReceipts: [LinuxGuestSoftRestartStageReceipt]
    public var failure: String?
    /// The exact receipt rendered at commit time (never reconstructed from a
    /// later boot or from stage detail text). Present only when
    /// `status == .committed`; it is the authoritative copy a later exact
    /// retry returns when the bounded receipts journal was already evicted.
    public var committedReceipt: LinuxGuestLifecycleReceipt?
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        operationID: String,
        environmentID: String,
        ownerTaskID: String? = nil,
        operationKey: String? = nil,
        requestedVCPUs: Int? = nil,
        requestedMemoryMB: Int? = nil,
        resolvedShape: GuestResourceRequest,
        preLaunchGeneration: UInt64? = nil,
        preVCPUs: Int,
        preMemoryMB: Int,
        preImageID: String? = nil,
        progress: LinuxGuestSoftRestartProgress = .recorded,
        status: LinuxGuestSoftRestartStatus = .pending,
        stageReceipts: [LinuxGuestSoftRestartStageReceipt] = [],
        failure: String? = nil,
        committedReceipt: LinuxGuestLifecycleReceipt? = nil,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.operationID = operationID
        self.environmentID = environmentID
        self.ownerTaskID = ownerTaskID
        self.operationKey = operationKey
        self.requestedVCPUs = requestedVCPUs
        self.requestedMemoryMB = requestedMemoryMB
        self.resolvedShape = resolvedShape
        self.preLaunchGeneration = preLaunchGeneration
        self.preVCPUs = preVCPUs
        self.preMemoryMB = preMemoryMB
        self.preImageID = preImageID
        self.progress = progress
        self.status = status
        self.stageReceipts = stageReceipts
        self.failure = failure
        self.committedReceipt = committedReceipt
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

// MARK: - committed receipt journal

/// One COMMITTED soft-restart outcome recorded for durable idempotent retry.
/// The receipt is the exact value rendered at commit time; a later call with
/// the same trusted owner, the same operation key and the same canonical
/// payload receives this receipt verbatim — no stage re-runs, no duplicate
/// reboot. A same-key call from a different owner, or with a changed payload,
/// is refused instead of being silently deduplicated (see
/// `LinuxGuestLifecycleError.softRestartIdempotencyConflict`).
public struct LinuxGuestSoftRestartCommittedReceipt: Sendable, Codable, Equatable {
    public var environmentID: String
    public var operationKey: String
    public var ownerTaskID: String?
    /// The caller's requested shape dimensions (nil = preserved).
    public var requestedVCPUs: Int?
    public var requestedMemoryMB: Int?
    /// The resolved replacement shape the committed operation booted at.
    public var resolvedShape: GuestResourceRequest
    /// The receipt exactly as it was returned to the original caller.
    public var receipt: LinuxGuestLifecycleReceipt
    public var committedAt: Date

    public init(
        environmentID: String,
        operationKey: String,
        ownerTaskID: String? = nil,
        requestedVCPUs: Int? = nil,
        requestedMemoryMB: Int? = nil,
        resolvedShape: GuestResourceRequest,
        receipt: LinuxGuestLifecycleReceipt,
        committedAt: Date = Date()
    ) {
        self.environmentID = environmentID
        self.operationKey = operationKey
        self.ownerTaskID = ownerTaskID
        self.requestedVCPUs = requestedVCPUs
        self.requestedMemoryMB = requestedMemoryMB
        self.resolvedShape = resolvedShape
        self.receipt = receipt
        self.committedAt = committedAt
    }
}

// MARK: - store

/// Persistence seam for the durable operation record and the committed
/// receipt journal. Reads and removals are FAIL-CLOSED: corruption, I/O
/// errors, oversized or identity-mismatched content throw — the only nil
/// result is a genuinely absent (ENOENT) record. A caller that cannot read
/// the record must never treat that as "no operation" and reboot.
public protocol LinuxGuestSoftRestartStore: Sendable {
    /// The latest operation record for the environment; nil only when no
    /// record exists. Throws on any unreadable/corrupt/mismatched content.
    func load(environmentID: String) async throws -> LinuxGuestSoftRestartOperation?
    func save(_ operation: LinuxGuestSoftRestartOperation) async throws
    /// Removes the operation record. Absence (ENOENT) is success; every
    /// other failure throws.
    func remove(environmentID: String) async throws
    /// A committed receipt for the exact operation key, when one exists;
    /// nil only when the journal is absent or has no such key. Throws on
    /// unreadable/corrupt/mismatched content.
    func loadCommittedReceipt(
        environmentID: String, operationKey: String
    ) async throws -> LinuxGuestSoftRestartCommittedReceipt?
    /// Appends one committed receipt to the bounded journal (oldest committed
    /// entries are evicted past the bound; unresolved operation records are
    /// a separate file and are never pruned here).
    func recordCommittedReceipt(_ committed: LinuxGuestSoftRestartCommittedReceipt) async throws
}

/// Fail-closed persistence failures for the file-backed store.
public enum LinuxGuestSoftRestartStoreError: Error, LocalizedError, Sendable, Equatable {
    /// The environment id cannot name a file (empty, traversal or control
    /// characters): no path is ever built from it.
    case invalidEnvironmentID(String)
    case expiredReceipt(environmentID: String)
    /// The record exists but is not decodable as this environment's
    /// operation (corrupt bytes, wrong schema or a foreign environment's
    /// content). Recoverable bytes are preserved under a sibling name.
    case corruptRecord(environmentID: String, preservedName: String?)
    /// The record exceeds the hard size bound; never decoded, never trusted.
    case oversizedRecord(environmentID: String, bytes: Int64, limit: Int64)
    /// The environment directory or record file is a symbolic link (or
    /// resolves outside the store root): refused, never followed.
    case unsafeSymbolicLink(environmentID: String)
    /// Any other I/O failure, reported with the operation that failed.
    case io(environmentID: String, operation: String, detail: String)

    public var errorDescription: String? {
        switch self {
        case .expiredReceipt(let id):
            return "The original soft-restart receipt for environment \(id) has aged out. This retry is held; check the original operation before proceeding."
        case .invalidEnvironmentID(let id):
            return "invalid Linux guest soft-restart environment id '\(id)'; no store path was built from it"
        case .corruptRecord(let id, let preserved):
            return "the durable soft-restart record for environment \(id) is corrupt or foreign and was NOT trusted\(preserved.map { "; the recoverable bytes were preserved as \($0)" } ?? "")"
        case .oversizedRecord(let id, let bytes, let limit):
            return "the durable soft-restart record for environment \(id) is \(bytes) bytes, over the \(limit)-byte bound; it was refused, not decoded"
        case .unsafeSymbolicLink(let id):
            return "the durable soft-restart path for environment \(id) is a symbolic link or resolves outside the store root; it was refused"
        case .io(let id, let operation, let detail):
            return "the soft-restart store \(operation) for environment \(id) failed: \(detail)"
        }
    }
}

/// File-backed store: one JSON sidecar per environment under the given root,
/// plus one bounded committed-receipts journal per environment. Only a true
/// ENOENT reads as absence; corrupt, oversized, foreign, symlinked or
/// unreadable content throws (fail-closed) and recoverable bytes are
/// preserved under a sibling `.corrupt-<uuid>` name instead of being
/// deleted. Writes are atomic; environment ids are validated (no traversal,
/// no control characters, length-bounded) and every resolved path must stay
/// inside the store root.
public struct LinuxGuestFileSoftRestartStore: LinuxGuestSoftRestartStore {
    /// Hard bound for one record file. A soft-restart record is a few KiB;
    /// 1 MiB leaves orders of magnitude of headroom and stops a runaway or
    /// hostile file from ever being decoded.
    public static let maxRecordBytes: Int64 = 1_048_576
    /// Hard bound for committed receipts kept per environment. Only committed
    /// (fully resolved) entries are ever evicted, oldest first; the pending
    /// operation record is a separate file and is never pruned by eviction.
    public static let maxCommittedReceipts = 8

    private let directory: URL

    public init(directory: URL) {
        self.directory = directory
    }

    private static func validatedEnvironmentID(_ environmentID: String) throws -> String {
        guard !environmentID.isEmpty,
              environmentID != ".", environmentID != "..",
              environmentID.count <= 128,
              !environmentID.contains("/"), !environmentID.contains("\\"),
              !environmentID.contains("\0")
        else {
            throw LinuxGuestSoftRestartStoreError.invalidEnvironmentID(environmentID)
        }
        return environmentID
    }

    /// The environment's private directory, validated and symlink-contained:
    /// the id names no traversal and the resolved path must stay inside the
    /// (resolved) store root, so a planted symlink can never redirect I/O.
    private func environmentDirectory(for environmentID: String) throws -> URL {
        let id = try Self.validatedEnvironmentID(environmentID)
        let root = directory.standardizedFileURL
        let resolvedRoot = root.resolvingSymlinksInPath()
        let envDirectory = root.appendingPathComponent(id, isDirectory: true)
        let resolved = envDirectory.resolvingSymlinksInPath().standardizedFileURL
        guard resolved.path.hasPrefix(resolvedRoot.path.hasSuffix("/")
            ? resolvedRoot.path
            : resolvedRoot.path + "/")
        else {
            throw LinuxGuestSoftRestartStoreError.unsafeSymbolicLink(environmentID: environmentID)
        }
        try refuseSymbolicLink(envDirectory, environmentID: environmentID)
        return envDirectory
    }

    /// Refuses a path component that already exists as a symbolic link.
    private func refuseSymbolicLink(_ url: URL, environmentID: String) throws {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        let values = try url.resourceValues(forKeys: [.isSymbolicLinkKey])
        if values.isSymbolicLink == true {
            throw LinuxGuestSoftRestartStoreError.unsafeSymbolicLink(environmentID: environmentID)
        }
    }

    private func operationFileURL(for environmentID: String) throws -> URL {
        try environmentDirectory(for: environmentID)
            .appendingPathComponent("soft-restart-operation.json")
    }

    private func receiptsFileURL(for environmentID: String) throws -> URL {
        try environmentDirectory(for: environmentID)
            .appendingPathComponent("soft-restart-receipts.json")
    }

    /// Reads one bounded, non-symlinked record file. Throws on every failure
    /// mode; nil means only that the file does not exist (true ENOENT).
    private func readRecordFile(
        _ url: URL, environmentID: String
    ) throws -> Data? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        try refuseSymbolicLink(url, environmentID: environmentID)
        do {
            let values = try url.resourceValues(forKeys: [.isSymbolicLinkKey, .fileSizeKey])
            if values.isSymbolicLink == true {
                throw LinuxGuestSoftRestartStoreError.unsafeSymbolicLink(environmentID: environmentID)
            }
            let size = Int64(values.fileSize ?? 0)
            guard size <= Self.maxRecordBytes else {
                throw LinuxGuestSoftRestartStoreError.oversizedRecord(
                    environmentID: environmentID, bytes: size, limit: Self.maxRecordBytes
                )
            }
            return try Data(contentsOf: url)
        } catch let error as LinuxGuestSoftRestartStoreError {
            throw error
        } catch {
            throw LinuxGuestSoftRestartStoreError.io(
                environmentID: environmentID, operation: "read", detail: error.localizedDescription
            )
        }
    }

    /// Moves an unreadable record aside so a human (or support) can recover
    /// it; the store itself never deletes content it could not decode.
    private func preserveCorruptRecord(
        _ url: URL, environmentID: String
    ) -> String? {
        let name = "\(url.lastPathComponent).corrupt-\(UUID().uuidString)"
        let destination = url.deletingLastPathComponent().appendingPathComponent(name)
        do {
            try FileManager.default.moveItem(at: url, to: destination)
            return name
        } catch {
            FloeLogger(category: .tools).error(
                "Linux guest soft-restart: could not preserve the corrupt record for environment=\(environmentID): \(error.localizedDescription)"
            )
            return nil
        }
    }

    public func load(environmentID: String) async throws -> LinuxGuestSoftRestartOperation? {
        let url = try operationFileURL(for: environmentID)
        guard let data = try readRecordFile(url, environmentID: environmentID) else { return nil }
        do {
            let operation = try JSONDecoder().decode(
                LinuxGuestSoftRestartOperation.self, from: data
            )
            // Identity check: a record that decodes but belongs to another
            // environment is foreign content, never trusted.
            guard operation.environmentID == environmentID else {
                let preserved = preserveCorruptRecord(url, environmentID: environmentID)
                throw LinuxGuestSoftRestartStoreError.corruptRecord(
                    environmentID: environmentID, preservedName: preserved
                )
            }
            return operation
        } catch let error as LinuxGuestSoftRestartStoreError {
            throw error
        } catch {
            let preserved = preserveCorruptRecord(url, environmentID: environmentID)
            throw LinuxGuestSoftRestartStoreError.corruptRecord(
                environmentID: environmentID, preservedName: preserved
            )
        }
    }

    public func save(_ operation: LinuxGuestSoftRestartOperation) async throws {
        let url = try operationFileURL(for: operation.environmentID)
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            let data = try JSONEncoder().encode(operation)
            guard Int64(data.count) <= Self.maxRecordBytes else {
                throw LinuxGuestSoftRestartStoreError.oversizedRecord(
                    environmentID: operation.environmentID,
                    bytes: Int64(data.count),
                    limit: Self.maxRecordBytes
                )
            }
            try data.write(to: url, options: .atomic)
        } catch let error as LinuxGuestSoftRestartStoreError {
            throw error
        } catch {
            throw LinuxGuestSoftRestartStoreError.io(
                environmentID: operation.environmentID,
                operation: "write",
                detail: error.localizedDescription
            )
        }
    }

    public func remove(environmentID: String) async throws {
        let url = try operationFileURL(for: environmentID)
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        do {
            try FileManager.default.removeItem(at: url)
        } catch {
            throw LinuxGuestSoftRestartStoreError.io(
                environmentID: environmentID,
                operation: "remove",
                detail: error.localizedDescription
            )
        }
    }

    public func loadCommittedReceipt(
        environmentID: String, operationKey: String
    ) async throws -> LinuxGuestSoftRestartCommittedReceipt? {
        let url = try receiptsFileURL(for: environmentID)
        guard let data = try readRecordFile(url, environmentID: environmentID) else { return nil }
        do {
            let envelope = try JSONDecoder().decode(
                SoftRestartReceiptsEnvelope.self, from: data
            )
            guard envelope.environmentID == environmentID,
                  envelope.receipts.count <= Self.maxCommittedReceipts,
                  envelope.evictedKeyFilter == nil || envelope.evictedKeyFilter?.count == Self.evictedFilterBytes,
                  Set(envelope.receipts.map(\.operationKey)).count == envelope.receipts.count,
                  envelope.receipts.allSatisfy({ $0.environmentID == environmentID && !$0.operationKey.isEmpty })
            else {
                let preserved = preserveCorruptRecord(url, environmentID: environmentID)
                throw LinuxGuestSoftRestartStoreError.corruptRecord(
                    environmentID: environmentID, preservedName: preserved
                )
            }
            if let receipt = envelope.receipts.first(where: { $0.operationKey == operationKey }) {
                return receipt
            }
            if Self.evictedKeyMayExist(operationKey, filter: envelope.evictedKeyFilter) {
                throw LinuxGuestSoftRestartStoreError.expiredReceipt(environmentID: environmentID)
            }
            return nil
        } catch let error as LinuxGuestSoftRestartStoreError {
            throw error
        } catch {
            let preserved = preserveCorruptRecord(url, environmentID: environmentID)
            throw LinuxGuestSoftRestartStoreError.corruptRecord(
                environmentID: environmentID, preservedName: preserved
            )
        }
    }

    public func recordCommittedReceipt(
        _ committed: LinuxGuestSoftRestartCommittedReceipt
    ) async throws {
        let environmentID = committed.environmentID
        let url = try receiptsFileURL(for: environmentID)
        do {
            var receipts: [LinuxGuestSoftRestartCommittedReceipt] = []
            var evictedKeyFilter: Data?
            if let data = try readRecordFile(url, environmentID: environmentID) {
                let envelope = try JSONDecoder().decode(
                    SoftRestartReceiptsEnvelope.self, from: data
                )
                guard envelope.environmentID == environmentID,
                      envelope.receipts.count <= Self.maxCommittedReceipts,
                  envelope.evictedKeyFilter == nil || envelope.evictedKeyFilter?.count == Self.evictedFilterBytes,
                  Set(envelope.receipts.map(\.operationKey)).count == envelope.receipts.count,
                  envelope.receipts.allSatisfy({ $0.environmentID == environmentID && !$0.operationKey.isEmpty })
                else {
                    let preserved = preserveCorruptRecord(url, environmentID: environmentID)
                    throw LinuxGuestSoftRestartStoreError.corruptRecord(
                        environmentID: environmentID, preservedName: preserved
                    )
                }
                receipts = envelope.receipts
                evictedKeyFilter = envelope.evictedKeyFilter
            }
            if let existing = receipts.first(where: { $0.operationKey == committed.operationKey }) {
                guard existing == committed else {
                    throw LinuxGuestSoftRestartStoreError.io(environmentID: environmentID,
                        operation: "record receipt", detail: "An immutable operation key already has a different receipt")
                }
                return
            }
            guard !Self.evictedKeyMayExist(committed.operationKey, filter: evictedKeyFilter) else {
                throw LinuxGuestSoftRestartStoreError.expiredReceipt(environmentID: environmentID)
            }
            receipts.append(committed)
            // Explicit bound: only resolved (committed) entries are ever
            // evicted, oldest first; unresolved receipts live in the
            // operation record and are never pruned here.
            if receipts.count > Self.maxCommittedReceipts {
                receipts.sort { $0.committedAt < $1.committedAt }
                let count = receipts.count - Self.maxCommittedReceipts
                for receipt in receipts.prefix(count) {
                    Self.rememberEvictedKey(receipt.operationKey, filter: &evictedKeyFilter)
                }
                receipts.removeFirst(count)
            }
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            let data = try JSONEncoder().encode(
                SoftRestartReceiptsEnvelope(environmentID: environmentID, receipts: receipts,
                                           evictedKeyFilter: evictedKeyFilter)
            )
            guard Int64(data.count) <= Self.maxRecordBytes else {
                throw LinuxGuestSoftRestartStoreError.oversizedRecord(
                    environmentID: environmentID,
                    bytes: Int64(data.count),
                    limit: Self.maxRecordBytes
                )
            }
            try data.write(to: url, options: .atomic)
        } catch let error as LinuxGuestSoftRestartStoreError {
            throw error
        } catch {
            throw LinuxGuestSoftRestartStoreError.io(
                environmentID: environmentID,
                operation: "write receipts",
                detail: error.localizedDescription
            )
        }
    }

    // Fixed-size conservative tombstone filter. It never forgets an evicted
    // key. A hash collision refuses a new operation rather than repeating an
    // old reboot. Exact recent receipts remain authoritative. This bounds
    // history without silently turning an old retry into a fresh action.
    private static let evictedFilterBytes = 8192

    private static func evictedKeyPositions(_ key: String) -> [Int] {
        let digest = FloeDigest.sha256Hex(Data(key.utf8))
        return stride(from: 0, to: 16, by: 4).map { start in
            let lower = digest.index(digest.startIndex, offsetBy: start)
            let upper = digest.index(lower, offsetBy: 4)
            return Int(digest[lower..<upper], radix: 16)!
        }
    }

    private static func evictedKeyMayExist(_ key: String, filter: Data?) -> Bool {
        guard let filter else { return false }
        guard filter.count == evictedFilterBytes else { return true }
        return evictedKeyPositions(key).allSatisfy { filter[$0 / 8] & (1 << ($0 % 8)) != 0 }
    }

    private static func rememberEvictedKey(_ key: String, filter: inout Data?) {
        var bytes = filter ?? Data(repeating: 0, count: evictedFilterBytes)
        for position in evictedKeyPositions(key) { bytes[position / 8] |= 1 << (position % 8) }
        filter = bytes
    }

    /// On-disk shape of the bounded committed-receipts journal.
    private struct SoftRestartReceiptsEnvelope: Sendable, Codable, Equatable {
        var environmentID: String
        var receipts: [LinuxGuestSoftRestartCommittedReceipt]
        var evictedKeyFilter: Data?
    }
}

// MARK: - transport seam

/// Outcome of the orderly-poweroff stage. `poweredOff` means the actual
/// instance left after the request; `refused`/`completedWithoutPoweringOff`
/// mean the guest answered (the request demonstrably did not power the
/// machine off); `unconfirmed` means the boundary was not observed inside
/// the budget — an unknown outcome, never a force reset.
public enum LinuxGuestSoftRestartPoweroffOutcome: Sendable, Equatable {
    case poweredOff
    case refused(exitCode: Int32, detail: String)
    case completedWithoutPoweringOff(exitCode: Int32)
    case unconfirmed(detail: String)
}

/// Read-only reconciliation facts about the current boot.
public struct LinuxGuestSoftRestartBootProbe: Sendable, Equatable {
    public var running: Bool
    public var vcpus: Int
    public var ramMB: Int
    public var launchGeneration: UInt64?
    public var imageID: String?
    /// The nonce file currently readable on the guest disk, when reachable.
    public var bootNonce: String?

    public init(
        running: Bool,
        vcpus: Int = 0,
        ramMB: Int = 0,
        launchGeneration: UInt64? = nil,
        imageID: String? = nil,
        bootNonce: String? = nil
    ) {
        self.running = running
        self.vcpus = vcpus
        self.ramMB = ramMB
        self.launchGeneration = launchGeneration
        self.imageID = imageID
        self.bootNonce = bootNonce
    }
}

/// Post-replacement boot truth, read back from the runtime's own table.
public struct LinuxGuestSoftRestartPostBoot: Sendable, Equatable {
    public var vcpus: Int
    public var ramMB: Int
    public var launchGeneration: UInt64?
    public var imageID: String?

    public init(vcpus: Int, ramMB: Int, launchGeneration: UInt64?, imageID: String?) {
        self.vcpus = vcpus
        self.ramMB = ramMB
        self.launchGeneration = launchGeneration
        self.imageID = imageID
    }
}

/// Low-level guest primitives the soft-restart stage protocol consumes.
/// The production implementation wraps `LinuxGuestControlling` +
/// `LinuxCommandRunning`; tests substitute scripted fakes. Every stage runs
/// under the caller's lifecycle transaction: the token — never a second lock
/// acquisition — is the authority, so the ordered sequence cannot deadlock
/// on the lease it holds.
public protocol LinuxGuestSoftRestartTransport: Sendable {
    /// Read-only probe of the current boot (liveness, granted shape,
    /// generation, nonce readback). Used for reconciliation before any
    /// retry; never mutates anything.
    func probeBoot(_ transaction: LinuxGuestLifecycleTransaction) async
        -> LinuxGuestSoftRestartBootProbe

    /// Runs the ordered capability + flush + durable nonce write as ONE
    /// bounded in-guest command. Exit 0 proves all three (the script is
    /// all-or-nothing); exit 127 reports the missing ordered-restart
    /// capability; any other exit is an honest stage failure.
    func flushAndRecordNonce(
        _ transaction: LinuxGuestLifecycleTransaction,
        nonce: String,
        timeout: TimeInterval,
        cancellation: CancellationToken?
    ) async throws -> LinuxCommandResult

    /// Submits the orderly poweroff and observes the boundary. Expected
    /// success is `poweredOff` — the command intentionally never answers
    /// END because the machine goes down.
    func requestOrderlyPoweroff(
        _ transaction: LinuxGuestLifecycleTransaction,
        poweroffPath: String,
        deadline: TimeInterval,
        cancellation: CancellationToken?
    ) async -> LinuxGuestSoftRestartPoweroffOutcome

    /// Captures the exited guest's flushed disk into the environment delta
    /// (the transaction-owned stop; a dead guest confirms instantly and is
    /// never force-stopped here).
    func captureExitedGuest(_ transaction: LinuxGuestLifecycleTransaction) async

    /// Boots the replacement at the recorded shape under the transaction and
    /// returns the post-boot truth once the runtime reports it running.
    func startReplacement(
        _ transaction: LinuxGuestLifecycleTransaction,
        taskID: String?,
        shape: GuestResourceRequest?,
        timeout: TimeInterval,
        cancellation: CancellationToken?
    ) async throws -> LinuxGuestSoftRestartPostBoot

    /// Reads the nonce file back from the (replacement) guest disk. A
    /// missing file reads as nil; transport failures throw.
    func readNonce(
        _ transaction: LinuxGuestLifecycleTransaction,
        noncePath: String,
        timeout: TimeInterval,
        cancellation: CancellationToken?
    ) async throws -> String?
}

// MARK: - production transport

/// Transport over the real guest service: stage commands run on the
/// transaction-owned session's console channel; probes and readbacks use the
/// same transaction-scoped seam so a reconciliation query never needs the
/// external command path (which the transaction itself refuses).
public struct LinuxGuestServiceSoftRestartTransport: LinuxGuestSoftRestartTransport {
    public static let defaultNoncePath = "/var/lib/floe/soft-restart.nonce"

    private let controller: any LinuxGuestControlling
    private let noncePath: String

    public init(
        controller: any LinuxGuestControlling,
        noncePath: String = Self.defaultNoncePath
    ) {
        self.controller = controller
        self.noncePath = noncePath
    }

    public func probeBoot(
        _ transaction: LinuxGuestLifecycleTransaction
    ) async -> LinuxGuestSoftRestartBootProbe {
        let states = await controller.runtimeStates()
        guard let state = states.first(where: {
            $0.environmentID == transaction.environmentID
        }), state.running else {
            return LinuxGuestSoftRestartBootProbe(running: false)
        }
        let nonce = try? await readNonce(
            transaction, noncePath: noncePath, timeout: 15, cancellation: nil
        )
        return LinuxGuestSoftRestartBootProbe(
            running: true,
            vcpus: state.vcpus,
            ramMB: state.ramMB,
            launchGeneration: state.identity.launchGeneration,
            imageID: await controller.guestStatus(environmentID: transaction.environmentID).imageID,
            bootNonce: nonce
        )
    }

    public func flushAndRecordNonce(
        _ transaction: LinuxGuestLifecycleTransaction,
        nonce: String,
        timeout: TimeInterval,
        cancellation: CancellationToken?
    ) async throws -> LinuxCommandResult {
        try await controller.runForLifecycleTransaction(
            transaction,
            argv: ["/bin/sh", "-c", Self.flushScript(nonce: nonce, noncePath: noncePath)],
            timeout: timeout,
            cancellation: cancellation
        )
    }

    public func requestOrderlyPoweroff(
        _ transaction: LinuxGuestLifecycleTransaction,
        poweroffPath: String,
        deadline: TimeInterval,
        cancellation: CancellationToken?
    ) async -> LinuxGuestSoftRestartPoweroffOutcome {
        do {
            return try await controller.requestOrderlyPoweroffForLifecycleTransaction(
                transaction,
                poweroffPath: poweroffPath,
                deadline: deadline,
                cancellation: cancellation
            )
        } catch {
            // The request could not even be submitted (stale token, dead
            // session): the outcome is unknown — the record stays pending
            // and blocks a blind repeat rather than guessing.
            return .unconfirmed(detail:
                "the poweroff request could not be observed to completion: \(error.localizedDescription)"
            )
        }
    }

    public func captureExitedGuest(
        _ transaction: LinuxGuestLifecycleTransaction
    ) async {
        await controller.stopForLifecycleTransaction(transaction)
    }

    public func startReplacement(
        _ transaction: LinuxGuestLifecycleTransaction,
        taskID: String?,
        shape: GuestResourceRequest?,
        timeout: TimeInterval,
        cancellation: CancellationToken?
    ) async throws -> LinuxGuestSoftRestartPostBoot {
        let started = try await controller.startForLifecycleTransaction(
            transaction, taskID: taskID, shape: shape
        )
        guard started else {
            throw LinuxGuestLifecycleError.notOwned(
                environmentID: transaction.environmentID
            )
        }
        // Bounded wait for the runtime to register the running replacement.
        // A late caller cancellation never abandons the boot mid-poll: the
        // outcome is settled on the truth, not on the race.
        let deadline = Date().addingTimeInterval(max(0.05, timeout))
        while Date() < deadline {
            let states = await controller.runtimeStates()
            if let state = states.first(where: {
                $0.environmentID == transaction.environmentID
            }), state.running {
                return LinuxGuestSoftRestartPostBoot(
                    vcpus: state.vcpus,
                    ramMB: state.ramMB,
                    launchGeneration: state.identity.launchGeneration,
                    imageID: await controller.guestStatus(
                        environmentID: transaction.environmentID
                    ).imageID
                )
            }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        throw LinuxGuestLifecycleError.capabilityUnsupported(
            environmentID: transaction.environmentID,
            requestedVCPUs: shape?.vcpus.count ?? 1,
            reason: "the replacement guest did not report running within \(Int(timeout))s of the ordered soft restart"
        )
    }

    public func readNonce(
        _ transaction: LinuxGuestLifecycleTransaction,
        noncePath: String,
        timeout: TimeInterval,
        cancellation: CancellationToken?
    ) async throws -> String? {
        let result = try await controller.runForLifecycleTransaction(
            transaction,
            argv: ["/bin/cat", noncePath],
            timeout: timeout,
            cancellation: cancellation
        )
        guard result.exitCode == 0 else { return nil }
        let nonce = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        return nonce.isEmpty ? nil : nonce
    }

    /// One bounded, all-or-nothing in-guest stage: prove the ordered-restart
    /// capability exists (sync + a poweroff binary), flush the filesystems,
    /// write the host-minted nonce durably, flush again. The resolved
    /// poweroff path is echoed as `poweroff=<path>` for the next stage.
    /// Exit 127 is the honest "this image cannot soft restart" answer; the
    /// nonce is a host-minted hex UUID, safe to single-quote.
    static func flushScript(nonce: String, noncePath: String) -> String {
        """
        p=""; \
        for c in /sbin/poweroff /usr/sbin/poweroff /bin/poweroff /usr/bin/poweroff; do \
        if [ -x "$c" ]; then p="$c"; break; fi; done; \
        if [ -z "$p" ]; then echo "no poweroff binary in the guest image" >&2; exit 127; fi; \
        sync || exit 90; \
        mkdir -p "$(dirname "\(noncePath)")" || exit 91; \
        printf '%s' '\(nonce)' > '\(noncePath)' || exit 92; \
        sync || exit 93; \
        echo "poweroff=$p"
        """
    }
}

// MARK: - request

/// Captured pre-restart truth, read from the runtime's own session table
/// under the lifecycle transaction before any guest action.
public struct LinuxGuestSoftRestartPreBoot: Sendable, Equatable {
    public var vcpus: Int
    public var ramMB: Int
    public var launchGeneration: UInt64?
    public var imageID: String?

    public init(vcpus: Int, ramMB: Int, launchGeneration: UInt64?, imageID: String?) {
        self.vcpus = vcpus
        self.ramMB = ramMB
        self.launchGeneration = launchGeneration
        self.imageID = imageID
    }
}

/// Trusted identity and context of one soft-restart call. The environment id
/// comes from the tool context (never the model), the task/run identity from
/// the run context, and the operation key from the durable tool-call
/// idempotency key — all host-minted, none model-authored.
public struct LinuxGuestSoftRestartRequest: Sendable {
    public var environmentID: String
    public var ownerTaskID: String?
    public var operationKey: String?
    public var config: LinuxGuestLifecycleConfig?
    /// Replacement shape resolved under the release gate BEFORE disruption.
    public var shape: GuestResourceRequest?
    public var transaction: LinuxGuestLifecycleTransaction?
    public var preBoot: LinuxGuestSoftRestartPreBoot?
    public var servicesActive: Int
    public var cancellation: CancellationToken?

    public init(
        environmentID: String,
        ownerTaskID: String? = nil,
        operationKey: String? = nil,
        config: LinuxGuestLifecycleConfig? = nil,
        shape: GuestResourceRequest? = nil,
        transaction: LinuxGuestLifecycleTransaction? = nil,
        preBoot: LinuxGuestSoftRestartPreBoot? = nil,
        servicesActive: Int = 0,
        cancellation: CancellationToken? = nil
    ) {
        self.environmentID = environmentID
        self.ownerTaskID = ownerTaskID
        self.operationKey = operationKey
        self.config = config
        self.shape = shape
        self.transaction = transaction
        self.preBoot = preBoot
        self.servicesActive = servicesActive
        self.cancellation = cancellation
    }
}

// MARK: - orchestrator (the default performer)

/// The real ordered soft restart: persists the durable operation record,
/// executes the ordered guest stages through the transport, verifies the
/// new-boot reconnect and reconciles interrupted operations before any
/// retry. This is the value AppEnvironment injects as the manager's
/// `softRestartPerformer`.
public struct LinuxGuestSoftRestartOrchestrator: Sendable {
    private let transport: any LinuxGuestSoftRestartTransport
    private let store: any LinuxGuestSoftRestartStore
    private let noncePath: String
    private let flushTimeout: TimeInterval
    private let poweroffDeadline: TimeInterval
    private let bootTimeout: TimeInterval

    public init(
        transport: any LinuxGuestSoftRestartTransport,
        store: any LinuxGuestSoftRestartStore,
        noncePath: String = LinuxGuestServiceSoftRestartTransport.defaultNoncePath,
        flushTimeout: TimeInterval = 60,
        poweroffDeadline: TimeInterval = 60,
        bootTimeout: TimeInterval = 180
    ) {
        self.transport = transport
        self.store = store
        self.noncePath = noncePath
        self.flushTimeout = flushTimeout
        self.poweroffDeadline = poweroffDeadline
        self.bootTimeout = bootTimeout
    }

    /// Pure durable receipt lookup; no guest lock, liveness probe, shutdown or
    /// shape admission is needed to return an already committed operation.
    public func committedReceipt(for request: LinuxGuestSoftRestartRequest) async throws -> LinuxGuestLifecycleReceipt? {
        try request.cancellation?.throwIfCancelled()
        guard let key = request.operationKey, !key.isEmpty,
              let receipt = try await loadCommittedReceipt(environmentID: request.environmentID, operationKey: key) else {
            return nil
        }
        return try matchedCommittedReceipt(receipt, request: request)
    }

    /// The performer seam entry point (see `LinuxGuestSoftRestartPerformer`).
    public func perform(
        _ request: LinuxGuestSoftRestartRequest
    ) async throws -> LinuxGuestLifecycleReceipt {
        let environmentID = request.environmentID
        // The caller's token, propagated; no fresh token anywhere below.
        try request.cancellation?.throwIfCancelled()

        // A backend that cannot hold the environment across the reboot
        // window cannot deliver an ordered soft restart: external work could
        // slip into the capture → boot window. Refuse honestly.
        guard let transaction = request.transaction else {
            throw LinuxGuestLifecycleError.capabilityUnsupported(
                environmentID: environmentID,
                requestedVCPUs: request.config?.vcpus ?? 1,
                reason: "this guest backend cannot hold the environment across an ordered soft restart window"
            )
        }

        // 1. Durable committed-receipt dedup: an exact retry of a COMMITTED
        //    operation (same trusted owner, same operation key, same
        //    canonical payload) receives the original receipt verbatim — a
        //    successful call is never re-executed just because the latest
        //    operation record moved on. A same-key call from a different
        //    owner or with a changed payload refuses; a store failure
        //    fails closed (no reboot on unreadable state).
        if let operationKey = request.operationKey {
            if let committed = try await loadCommittedReceipt(
                environmentID: environmentID, operationKey: operationKey
            ) {
                return try matchedCommittedReceipt(committed, request: request)
            }
        }

        // 2. Reconcile an interrupted operation BEFORE any new guest action.
        // A blind repeat while the earlier outcome is unresolved is refused;
        // a query that converges returns the settled receipt or resumes.
        if let existing = try await loadOperation(environmentID: environmentID),
           existing.status == .pending {
            if let receipt = try await reconcile(existing, request: request, transaction: transaction) {
                return receipt
            }
            // Reconcile settled the record as provably failed: a fresh
            // attempt proceeds below and overwrites it.
        }

        // 3. A fresh operation requires the captured running guest.
        guard let preBoot = request.preBoot else {
            throw LinuxGuestLifecycleError.guestNotRunning(environmentID: environmentID)
        }

        var operation = LinuxGuestSoftRestartOperation(
            operationID: UUID().uuidString,
            environmentID: environmentID,
            ownerTaskID: request.ownerTaskID,
            operationKey: request.operationKey,
            requestedVCPUs: request.config?.vcpus,
            requestedMemoryMB: request.config?.memoryMB,
            resolvedShape: request.shape ?? GuestResourceRequest(),
            preLaunchGeneration: preBoot.launchGeneration,
            preVCPUs: preBoot.vcpus,
            preMemoryMB: preBoot.ramMB,
            preImageID: preBoot.imageID
        )
        // Durable BEFORE any guest action: from here on, an interruption is
        // a reconcilable unknown, never a silent or blind repeat.
        try await persist(operation)

        // 4. Ordered flush + capability + durable nonce write.
        let flush: LinuxCommandResult
        do {
            flush = try await transport.flushAndRecordNonce(
                transaction,
                nonce: operation.operationID,
                timeout: flushTimeout,
                cancellation: request.cancellation
            )
        } catch {
            // Pre-submission: nothing destructive was submitted, so no
            // unknown outcome can exist. Remove the record (a plain
            // cancellation lands here too). A removal failure is reported
            // truthfully: the original error still surfaces, and the stale
            // pending record is left for the next call's reconciliation
            // instead of being silently dropped.
            do {
                try await removeRecord(environmentID: environmentID)
            } catch {
                FloeLogger(category: .tools).error(
                    "Linux guest soft restart: the pre-submission record removal failed environment=\(environmentID); a stale pending record remains and a later call reconciles it: \(error.localizedDescription)"
                )
            }
            throw error
        }
        if flush.exitCode == 127 {
            let detail = flush.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            try await settleFailed(&operation, failure:
                "the guest image lacks the ordered soft-restart capability (sync/poweroff missing)\(detail.isEmpty ? "" : ": \(detail)")")
            throw LinuxGuestLifecycleError.capabilityUnsupported(
                environmentID: environmentID,
                requestedVCPUs: request.config?.vcpus ?? 1,
                reason: "the guest image provides no ordered flush+poweroff capability; stderr: \(detail.isEmpty ? "none" : detail)"
            )
        }
        guard flush.exitCode == 0,
              let poweroffPath = Self.parsePoweroffPath(flush.stdout) else {
            let detail = flush.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            try await settleFailed(&operation, failure:
                "the ordered flush stage failed with exit \(flush.exitCode)\(detail.isEmpty ? "" : ": \(detail)")")
            throw LinuxGuestLifecycleError.softRestartStageFailed(
                environmentID: environmentID,
                stage: LinuxGuestSoftRestartStage.flush.rawValue,
                detail: "exit \(flush.exitCode)\(detail.isEmpty ? "" : ", stderr: \(detail)")"
            )
        }
        operation.progress = .flushProven
        operation.stageReceipts.append(LinuxGuestSoftRestartStageReceipt(
            stage: .flush,
            outcome: "ok",
            detail: "ordered filesystem flush completed and the operation nonce was written durably to \(noncePath); poweroff resolved to \(poweroffPath)"
        ))
        try await persist(operation)

        // 5. The orderly poweroff request. The submission is journaled BEFORE
        //    the request crosses the boundary: an interruption after this
        //    point leaves a durable SUBMITTED record, which reconciliation
        //    must hold unknown (a late poweroff can still land) — never a
        //    proven failure inferred from simple liveness.
        operation.progress = .poweroffSubmitted
        operation.updatedAt = Date()
        try await persist(operation)
        // After the submission boundary the outcome is reported as committed
        // or unknown — never a clean cancel and never a host force reset.
        // Caller cancellation still reaches the bounded transport. Once
        // submission is journaled, cancellation is an unknown outcome until
        // authoritative poweroff/boot evidence settles it, never a clean undo.
        let poweroff = await transport.requestOrderlyPoweroff(
            transaction,
            poweroffPath: poweroffPath,
            deadline: poweroffDeadline,
            cancellation: request.cancellation
        )
        switch poweroff {
        case .poweredOff:
            operation.progress = .guestExitObserved
            operation.stageReceipts.append(LinuxGuestSoftRestartStageReceipt(
                stage: .rebootRequest,
                outcome: "ok",
                detail: "the guest accepted the orderly poweroff request (\(poweroffPath) -f); the command intentionally never answered END because the machine powered down"
            ))
            operation.stageReceipts.append(LinuxGuestSoftRestartStageReceipt(
                stage: .guestExit,
                outcome: "ok",
                detail: "the actual guest instance left after the ordered poweroff; no host force stop was involved"
            ))
            try await persist(operation)
        case .refused(let exitCode, let detail):
            try await settleFailed(&operation, failure:
                "the guest refused the orderly poweroff (exit \(exitCode)): \(detail)")
            throw LinuxGuestLifecycleError.softRestartStageFailed(
                environmentID: environmentID,
                stage: LinuxGuestSoftRestartStage.rebootRequest.rawValue,
                detail: "exit \(exitCode): \(detail)"
            )
        case .completedWithoutPoweringOff(let exitCode):
            try await settleFailed(&operation, failure:
                "the poweroff command returned exit \(exitCode) without powering the machine off")
            throw LinuxGuestLifecycleError.softRestartStageFailed(
                environmentID: environmentID,
                stage: LinuxGuestSoftRestartStage.rebootRequest.rawValue,
                detail: "the poweroff command completed with exit \(exitCode) without a machine poweroff"
            )
        case .unconfirmed(let detail):
            operation.stageReceipts.append(LinuxGuestSoftRestartStageReceipt(
                stage: .rebootRequest,
                outcome: "unknown",
                detail: detail
            ))
            do {
                try await persist(operation)
            } catch {
                // The outcome is already unknown; the persistence failure is
                // reported with it, never silently dropped.
                throw LinuxGuestLifecycleError.softRestartOutcomeUnknown(
                    environmentID: environmentID,
                    operationID: operation.operationID,
                    detail: "the poweroff request was submitted but the guest exit was not confirmed (\(detail)); additionally the stage receipt failed to persist: \(error.localizedDescription); no force reset was attempted and the outcome stays reconcilable"
                )
            }
            throw LinuxGuestLifecycleError.softRestartOutcomeUnknown(
                environmentID: environmentID,
                operationID: operation.operationID,
                detail: "the poweroff request was submitted but the guest exit was not confirmed (\(detail)); no force reset was attempted and the outcome stays reconcilable — a later call converges it against current state before any retry"
            )
        }

        // 6. Capture the exited guest's flushed disk.
        await transport.captureExitedGuest(transaction)
        operation.progress = .diskCaptureCommitted
        operation.stageReceipts.append(LinuxGuestSoftRestartStageReceipt(
            stage: .diskCapture,
            outcome: "ok",
            detail: "the exited guest's flushed disk was captured into the environment delta"
        ))
        try await persist(operation)

        // 7. Boot the replacement at the recorded shape and verify the
        //    reconnect with the generation rotation and the nonce readback.
        return try await bootReplacementAndVerify(
            &operation, request: request, transaction: transaction
        )
    }

    /// Boots the replacement for `operation` and verifies the new boot.
    /// Shared by the fresh path and the interrupted-operation resume.
    private func bootReplacementAndVerify(
        _ operation: inout LinuxGuestSoftRestartOperation,
        request: LinuxGuestSoftRestartRequest,
        transaction: LinuxGuestLifecycleTransaction
    ) async throws -> LinuxGuestLifecycleReceipt {
        let post: LinuxGuestSoftRestartPostBoot
        do {
            post = try await transport.startReplacement(
                transaction,
                taskID: request.ownerTaskID,
                shape: operation.resolvedShape,
                timeout: bootTimeout,
                cancellation: request.cancellation
            )
        } catch {
            // The capture is committed (progress persisted): the operation
            // stays resumable from exactly this point — a retry boots the
            // replacement without re-running any guest stage.
            throw LinuxGuestLifecycleError.softRestartStageFailed(
                environmentID: operation.environmentID,
                stage: LinuxGuestSoftRestartStage.newBoot.rawValue,
                detail: "the replacement boot did not report running: \(error.localizedDescription)"
            )
        }
        guard post.vcpus == operation.resolvedShape.vcpus.count,
              post.ramMB == operation.resolvedShape.memory.mb else {
            try await settleFailed(&operation, failure:
                "the replacement booted at \(post.vcpus) vCPU / \(post.ramMB) MiB, not the recorded \(operation.resolvedShape.vcpus.count) / \(operation.resolvedShape.memory.mb)")
            throw LinuxGuestLifecycleError.softRestartStageFailed(
                environmentID: operation.environmentID,
                stage: LinuxGuestSoftRestartStage.newBoot.rawValue,
                detail: "the replacement booted at \(post.vcpus) vCPU / \(post.ramMB) MiB, not the recorded shape"
            )
        }
        if let preGeneration = operation.preLaunchGeneration,
           let postGeneration = post.launchGeneration,
           preGeneration == postGeneration {
            try await settleFailed(&operation, failure:
                "the launch generation did not rotate (\(preGeneration)); the old instance may still be running")
            throw LinuxGuestLifecycleError.softRestartStageFailed(
                environmentID: operation.environmentID,
                stage: LinuxGuestSoftRestartStage.newBoot.rawValue,
                detail: "the launch generation did not rotate from \(preGeneration); the reboot is unproven"
            )
        }
        let nonce: String?
        do {
            nonce = try await transport.readNonce(
                transaction, noncePath: noncePath, timeout: flushTimeout,
                cancellation: request.cancellation
            )
        } catch {
            // The replacement is already running; only the disk-continuity
            // proof is missing. The record stays pending (resumable): a
            // retry converges on the probe — generation + nonce — instead
            // of rebooting the fresh instance.
            throw LinuxGuestLifecycleError.softRestartOutcomeUnknown(
                environmentID: operation.environmentID,
                operationID: operation.operationID,
                detail: "the new boot reported running but the nonce readback failed: \(error.localizedDescription); the outcome stays reconcilable"
            )
        }
        guard nonce == operation.operationID else {
            try await settleFailed(&operation, failure:
                "the pre-reboot nonce was not read back from the persistent disk on the new boot (disk continuity is unproven)")
            throw LinuxGuestLifecycleError.softRestartStageFailed(
                environmentID: operation.environmentID,
                stage: LinuxGuestSoftRestartStage.newBoot.rawValue,
                detail: "the pre-reboot nonce was not read back from the persistent disk; the reboot is unproven and the disk continuity is unverified"
            )
        }
        return try await commit(&operation, post: post, servicesStopped: request.servicesActive)
    }

    /// Settles one verified operation as committed: the exact rendered
    /// receipt is embedded in the operation record AND appended to the
    /// bounded committed-receipts journal, so an exact later retry returns
    /// the original receipt even after further operations overwrote the
    /// latest record. A journal failure is reported truthfully (the reboot
    /// itself is committed and durable in the operation record).
    private func commit(
        _ operation: inout LinuxGuestSoftRestartOperation,
        post: LinuxGuestSoftRestartPostBoot,
        servicesStopped: Int
    ) async throws -> LinuxGuestLifecycleReceipt {
        let rendered = receipt(
            for: operation, post: post, servicesStopped: servicesStopped
        )
        operation.status = .committed
        operation.updatedAt = Date()
        operation.committedReceipt = rendered
        operation.stageReceipts.append(LinuxGuestSoftRestartStageReceipt(
            stage: .newBoot,
            outcome: "ok",
            detail: "the replacement reported running at the recorded shape with launch generation \(post.launchGeneration.map(String.init) ?? "unknown") and the pre-reboot nonce was read back from the persistent disk"
        ))
        try await persist(operation)
        if let key = operation.operationKey, !key.isEmpty {
            do {
                try await recordCommitted(LinuxGuestSoftRestartCommittedReceipt(
                    environmentID: operation.environmentID,
                    operationKey: key,
                    ownerTaskID: operation.ownerTaskID,
                    requestedVCPUs: operation.requestedVCPUs,
                    requestedMemoryMB: operation.requestedMemoryMB,
                    resolvedShape: operation.resolvedShape,
                    receipt: rendered,
                    committedAt: Date()
                ))
            } catch {
                throw LinuxGuestLifecycleError.softRestartPersistenceFailed(
                    environmentID: operation.environmentID,
                    detail: "the reboot completed and was verified, but the committed idempotency receipt could not be journaled: \(error.localizedDescription); the operation record carries the receipt and a later exact retry converges on it"
                )
            }
        }
        return rendered
    }

    /// Reconciles one persisted pending operation against current boot truth
    /// BEFORE any retry. Returns the settled receipt when the earlier attempt
    /// converges committed (or is resumed to completion); returns nil when it
    /// settles provably failed and a fresh attempt may proceed; throws while
    /// the outcome stays unresolved, so a blind repeat is blocked.
    private func reconcile(
        _ operation: LinuxGuestSoftRestartOperation,
        request: LinuxGuestSoftRestartRequest,
        transaction: LinuxGuestLifecycleTransaction
    ) async throws -> LinuxGuestLifecycleReceipt? {
        var operation = operation
        let probe = await transport.probeBoot(transaction)

        if probe.running {
            // The machine is up: distinguish "rebooted and reconnected"
            // (generation rotated + nonce present) from "never rebooted"
            // (same generation). Without both generations the comparison
            // cannot be made — stay unresolved (safe direction).
            guard let preGeneration = operation.preLaunchGeneration else {
                throw LinuxGuestLifecycleError.softRestartOutcomeUnknown(
                    environmentID: operation.environmentID,
                    operationID: operation.operationID,
                    detail: "the recorded pre-restart generation is missing; the outcome stays unresolved"
                )
            }
            if let postGeneration = probe.launchGeneration,
               postGeneration != preGeneration {
                guard probe.bootNonce == operation.operationID else {
                    throw LinuxGuestLifecycleError.softRestartOutcomeUnknown(
                        environmentID: operation.environmentID,
                        operationID: operation.operationID,
                        detail: "the launch generation rotated but the pre-reboot nonce was not read back; the outcome stays unresolved"
                    )
                }
                // Converged committed: the earlier attempt completed the
                // reboot; settle and report — no duplicate guest action.
                return try await commit(
                    &operation,
                    post: LinuxGuestSoftRestartPostBoot(
                        vcpus: probe.vcpus,
                        ramMB: probe.ramMB,
                        launchGeneration: probe.launchGeneration,
                        imageID: probe.imageID
                    ),
                    servicesStopped: request.servicesActive
                )
            }
            // Same generation (or an unreadable one): the machine demonstrably
            // did not reboot.
            if probe.launchGeneration == nil {
                throw LinuxGuestLifecycleError.softRestartOutcomeUnknown(
                    environmentID: operation.environmentID,
                    operationID: operation.operationID,
                    detail: "the running guest's launch generation could not be read; the outcome stays unresolved"
                )
            }
            switch operation.progress {
            case .recorded:
                try await settleFailed(&operation, failure:
                    "interrupted before the ordered flush completed; the guest was never asked to restart")
                return nil
            case .flushProven:
                // No submission was ever persisted: the flush completed and
                // the machine demonstrably never rebooted (same generation).
                // The nonce still being present proves the disk is intact —
                // this is a proven-failed operation and a fresh attempt may
                // proceed. (Had the submission been journaled, liveness could
                // never settle this — see the next case.)
                guard probe.bootNonce == operation.operationID else {
                    throw LinuxGuestLifecycleError.softRestartOutcomeUnknown(
                        environmentID: operation.environmentID,
                        operationID: operation.operationID,
                        detail: "the flush was proven but the nonce file is missing without a reboot; the guest state is inconsistent and the outcome stays unresolved"
                    )
                }
                try await settleFailed(&operation, failure:
                    "the ordered flush completed but no poweroff was submitted; the guest demonstrably never restarted")
                return nil
            case .poweroffSubmitted, .guestExitObserved:
                // The poweroff submission is durable. A machine that reports
                // alive at the same generation is NOT proof the request
                // failed: the request may still land late (that is exactly
                // what "submitted, unconfirmed" means). Never infer refusal
                // from simple liveness — hold the unknown and block another
                // reboot until an authoritative boundary (the machine
                // leaves, or the generation rotates with the nonce readback).
                // The explicit recovery is environment.hardRestartLinux.
                throw LinuxGuestLifecycleError.softRestartOutcomeUnknown(
                    environmentID: operation.environmentID,
                    operationID: operation.operationID,
                    detail: "the poweroff was submitted but the guest still reports alive at the pre-restart generation; a late poweroff can still land, so the outcome stays unresolved and another reboot is blocked until the machine leaves or the generation rotates with the nonce readback (environment.hardRestartLinux remains the explicit disruptive recovery)"
                )
            case .diskCaptureCommitted:
                // The capture committed and the environment is running again
                // at the old generation: an external actor restarted the old
                // disk while our operation was interrupted. The capture is
                // durable; completing the boot protocol now would rotate the
                // generation under that external boot — refuse and let the
                // owner decide (status / hard restart).
                throw LinuxGuestLifecycleError.softRestartOutcomeUnknown(
                    environmentID: operation.environmentID,
                    operationID: operation.operationID,
                    detail: "the disk capture committed but the environment is running again at the pre-restart generation; an external actor owns the current boot, so the interrupted operation refuses to restart it"
                )
            }
        }

        // The machine is down. From a proven guest exit (or a proven flush
        // whose machine later went down) the recovery is deterministic and
        // safe: capture the quiet disk, boot the recorded shape, verify.
        // The exit itself is only attributed to this operation when a
        // submission was journaled; in every case the nonce readback on the
        // new boot is the authoritative disk-continuity proof.
        switch operation.progress {
        case .recorded:
            try await settleFailed(&operation, failure:
                "interrupted before any guest action while the guest is now stopped; nothing of this operation remains")
            return nil
        case .flushProven, .poweroffSubmitted, .guestExitObserved, .diskCaptureCommitted:
            if !operation.progress.isAtLeast(.diskCaptureCommitted) {
                let exitWasSubmitted = operation.progress.isAtLeast(.poweroffSubmitted)
                await transport.captureExitedGuest(transaction)
                operation.progress = .diskCaptureCommitted
                operation.stageReceipts.append(LinuxGuestSoftRestartStageReceipt(
                    stage: .diskCapture,
                    outcome: "ok",
                    detail: exitWasSubmitted
                        ? "resumed after an interruption: the quiet disk was captured before the replacement boot"
                        : "resumed after an interruption: the machine is down (the exit was not confirmed as this operation's poweroff) and the quiet disk was captured before the replacement boot"
                ))
                try await persist(operation)
            }
            return try await bootReplacementAndVerify(
                &operation, request: request, transaction: transaction
            )
        }
    }

    /// Fails closed: a store read/write failure is reported as a persistence
    /// failure — never as "no record" and never as a settled state.
    private func loadOperation(
        environmentID: String
    ) async throws -> LinuxGuestSoftRestartOperation? {
        do {
            return try await store.load(environmentID: environmentID)
        } catch {
            throw LinuxGuestLifecycleError.softRestartPersistenceFailed(
                environmentID: environmentID,
                detail: "the durable operation record could not be read: \(error.localizedDescription)"
            )
        }
    }

    private func persist(_ operation: LinuxGuestSoftRestartOperation) async throws {
        do {
            try await store.save(operation)
        } catch {
            throw LinuxGuestLifecycleError.softRestartPersistenceFailed(
                environmentID: operation.environmentID,
                detail: "the durable operation record could not be written: \(error.localizedDescription)"
            )
        }
    }

    private func removeRecord(environmentID: String) async throws {
        do {
            try await store.remove(environmentID: environmentID)
        } catch {
            throw LinuxGuestLifecycleError.softRestartPersistenceFailed(
                environmentID: environmentID,
                detail: "the durable operation record could not be removed: \(error.localizedDescription)"
            )
        }
    }

    /// Committed-receipt lookup: the bounded journal first, then the latest
    /// operation record (a committed receipt embedded there covers a journal
    /// append that failed right after the operation record committed).
    private func loadCommittedReceipt(
        environmentID: String, operationKey: String
    ) async throws -> LinuxGuestSoftRestartCommittedReceipt? {
        do {
            if let committed = try await store.loadCommittedReceipt(
                environmentID: environmentID, operationKey: operationKey
            ) {
                return committed
            }
            guard let operation = try await store.load(environmentID: environmentID),
                  operation.status == .committed,
                  operation.operationKey == operationKey,
                  let receipt = operation.committedReceipt
            else { return nil }
            return LinuxGuestSoftRestartCommittedReceipt(
                environmentID: operation.environmentID,
                operationKey: operationKey,
                ownerTaskID: operation.ownerTaskID,
                requestedVCPUs: operation.requestedVCPUs,
                requestedMemoryMB: operation.requestedMemoryMB,
                resolvedShape: operation.resolvedShape,
                receipt: receipt,
                committedAt: operation.updatedAt
            )
        } catch let error as LinuxGuestLifecycleError {
            throw error
        } catch {
            throw LinuxGuestLifecycleError.softRestartPersistenceFailed(
                environmentID: environmentID,
                detail: "the committed idempotency receipts could not be read: \(error.localizedDescription)"
            )
        }
    }

    private func recordCommitted(
        _ committed: LinuxGuestSoftRestartCommittedReceipt
    ) async throws {
        do {
            try await store.recordCommittedReceipt(committed)
        } catch {
            throw LinuxGuestLifecycleError.softRestartPersistenceFailed(
                environmentID: committed.environmentID,
                detail: "the committed idempotency receipt could not be written: \(error.localizedDescription)"
            )
        }
    }

    /// Validates one committed receipt against a retry: the trusted owner
    /// must match (the existing logical-run identity API, not a model label)
    /// and the canonical payload (requested shape + resolved replacement
    /// shape) must be identical. Returns the original receipt on a match;
    /// refuses an idempotency conflict otherwise. Never fabricates anything
    /// from current boot state.
    private func matchedCommittedReceipt(
        _ committed: LinuxGuestSoftRestartCommittedReceipt,
        request: LinuxGuestSoftRestartRequest
    ) throws -> LinuxGuestLifecycleReceipt {
        guard LinuxGuestActivityDetail.runIDsMatch(
            committed.ownerTaskID, request.ownerTaskID
        ) else {
            throw LinuxGuestLifecycleError.softRestartIdempotencyConflict(
                environmentID: committed.environmentID,
                operationKey: committed.operationKey,
                detail: "a committed soft restart with this operation key belongs to a different owner; the receipt is not shared across owners"
            )
        }
        let samePayload =
            committed.requestedVCPUs == request.config?.vcpus
                && committed.requestedMemoryMB == request.config?.memoryMB
        guard samePayload else {
            throw LinuxGuestLifecycleError.softRestartIdempotencyConflict(
                environmentID: committed.environmentID,
                operationKey: committed.operationKey,
                detail: "a committed soft restart with this operation key carried a different requested configuration; a changed payload is refused instead of silently deduplicated"
            )
        }
        return committed.receipt
    }

    private func settleFailed(
        _ operation: inout LinuxGuestSoftRestartOperation,
        failure: String
    ) async throws {
        operation.status = .failed
        operation.failure = failure
        operation.updatedAt = Date()
        do {
            try await store.save(operation)
        } catch {
            // The failed settlement itself is unproven durable: report the
            // persistence failure truthfully instead of silently converging.
            FloeLogger(category: .tools).error(
                "Linux guest soft restart: the failure settlement failed to persist environment=\(operation.environmentID) operation=\(operation.operationID) originalFailure=\(failure) persistenceError=\(error.localizedDescription)"
            )
            throw LinuxGuestLifecycleError.softRestartPersistenceFailed(
                environmentID: operation.environmentID,
                detail: "the failed outcome could not be persisted and must not be assumed settled: \(error.localizedDescription)"
            )
        }
        FloeLogger(category: .tools).info(
            "Linux guest soft restart settled failed environment=\(operation.environmentID) operation=\(operation.operationID) failure=\(failure)"
        )
    }

    private func receipt(
        for operation: LinuxGuestSoftRestartOperation,
        post: LinuxGuestSoftRestartPostBoot,
        servicesStopped: Int
    ) -> LinuxGuestLifecycleReceipt {
        LinuxGuestLifecycleReceipt(
            phase: .running,
            environmentID: operation.environmentID,
            requestedVCPUs: operation.requestedVCPUs,
            requestedMemoryMB: operation.requestedMemoryMB,
            actualVCPUs: post.vcpus,
            actualMemoryMB: post.ramMB,
            reused: false,
            imageID: post.imageID ?? operation.preImageID,
            launchGeneration: post.launchGeneration.flatMap { Int(exactly: $0) },
            servicesStopped: servicesStopped,
            operationID: operation.operationID,
            capability: LinuxGuestLifecycleManager.capabilitySummary,
            detail: "soft restart completed in order (flush → poweroff request → guest exit → disk capture → new boot); the launch generation moved from \(operation.preLaunchGeneration.map(String.init) ?? "unknown") to \(post.launchGeneration.map(String.init) ?? "unknown") and the pre-reboot nonce was read back from the persistent disk; the environment, its disk and shares are preserved; services terminated: \(servicesStopped)"
        )
    }

    private static func parsePoweroffPath(_ stdout: String) -> String? {
        for line in stdout.split(whereSeparator: { $0 == "\n" || $0 == "\r" }) {
            guard line.hasPrefix("poweroff=") else { continue }
            let path = line.dropFirst("poweroff=".count).trimmingCharacters(in: .whitespaces)
            if !path.isEmpty { return path }
        }
        return nil
    }
}
