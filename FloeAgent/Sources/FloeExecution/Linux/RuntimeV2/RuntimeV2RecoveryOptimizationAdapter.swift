import Foundation
import Dispatch
import FloeCore
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

public final class RuntimeV2OptimizationCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var requested = false
    public init() {}
    public func cancel() { lock.lock(); requested = true; lock.unlock() }
    public var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return requested }
}

// Core runs on this GCD queue, never on MainActor or a cooperative Swift task.
// Its synchronous fence waits for async authority/DB/metadata checks elsewhere.
// Those checks NEVER dispatch back to the waiting Core queue.
final class RuntimeV2OptimizationWorker: @unchecked Sendable {
    private final class QueueKey: @unchecked Sendable {
        let value = DispatchSpecificKey<UInt8>()
    }
    private static let key = QueueKey()
    private let queue: DispatchQueue
    init(_ name: String, allowsSynchronousFence: Bool = false) {
        queue = DispatchQueue(label: name, qos: .utility)
        queue.setSpecific(key: Self.key.value, value: allowsSynchronousFence ? 1 : 0)
    }
    static var canWaitForFence: Bool { DispatchQueue.getSpecific(key: key.value) == 1 }
    func run<T: Sendable>(_ body: @escaping @Sendable () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                do { continuation.resume(returning: try body()) }
                catch { continuation.resume(throwing: error) }
            }
        }
    }
}

enum RuntimeV2OptimizationAsyncFence {
    private final class Reply: @unchecked Sendable {
        private let lock = NSLock()
        private let semaphore = DispatchSemaphore(value: 0)
        private var result: Result<Void, Error>?
        private var expired = false
        func complete(_ value: Result<Void, Error>) {
            lock.lock(); defer { lock.unlock() }
            guard !expired else { return }
            result = value; semaphore.signal()
        }
        func wait() throws {
            // DispatchTime is monotonic; a device clock change cannot turn
            // the bounded fence wait into an unbounded wall-clock wait.
            if semaphore.wait(timeout: .now() + .seconds(30)) == .timedOut {
                lock.withLock { expired = true }
                throw RuntimeV2MaintenanceError.claimInvalidated("authority validation timed out")
            }
            try lock.withLock {
                guard let result else { throw RuntimeV2MaintenanceError.claimInvalidated("authority reply absent") }
                try result.get()
            }
        }
    }
    static func check(_ body: @escaping @Sendable () async throws -> Void) throws {
        guard !Thread.isMainThread, RuntimeV2OptimizationWorker.canWaitForFence else {
            throw RuntimeV2MaintenanceError.claimInvalidated("fence wait requires its owned GCD Core queue")
        }
        let reply = Reply()
        let validation = Task.detached(priority: .utility) {
            do { try await body(); reply.complete(.success(())) }
            catch { reply.complete(.failure(error)) }
        }
        do { try reply.wait() }
        catch { validation.cancel(); throw error }
    }
}

struct RuntimeV2OptimizationPreservation: Codable, Sendable {
    let rootDevice: UInt64
    let rootInode: UInt64
    let directoryDevice: UInt64?
    let directoryInode: UInt64?
    let environmentID: String?
    let runtimeID: String?
    let runtime: LegacyRecoverySidecarObservation
    let environment: LegacyRecoverySidecarObservation
    let marker: LegacyRecoverySidecarObservation
    let generation: LegacyRecoverySidecarObservation
    let holdID: String?
    let holdGeneration: Int64?
    init(_ record: LegacyRecoveryInventoryRecord) {
        let source = record.reviewSnapshot
        rootDevice = source.rootIdentity.device; rootInode = source.rootIdentity.inode
        directoryDevice = source.directoryIdentity?.device; directoryInode = source.directoryIdentity?.inode
        environmentID = record.environmentID; runtimeID = record.runtimeID
        runtime = source.runtimeMetadata; environment = source.environmentMetadata
        marker = source.repairMarker; generation = source.repairGeneration
        holdID = source.observedHoldID; holdGeneration = source.observedRepairGeneration
    }
    func fingerprint() throws -> String {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return FloeDigest.sha256Hex(try encoder.encode(self))
    }
}

struct RuntimeV2OptimizationJobReceipt: Codable, Sendable {
    let version: Int
    let intentID: String
    let authorityGeneration: UInt64
    let domainKey: String
    let relativePath: String
    let expectedSource: StorageSparseDiskIdentity
    let preservationFingerprint: String
    let repairHoldGeneration: Int64
    let closure: RuntimeV2RecoveryClosedReceipt
}

// Decode only the public contract fields the adapter MUST bind. Core owns the
// rest of schema v2 and is the sole code allowed to converge its S/T journal.
struct RuntimeV2OptimizationCoreJournalBinding: Decodable, Sendable {
    let schemaVersion: Int
    let jobID: String
    let maintenanceLeaseID: String
    let holdGeneration: Int64
    let jobGeneration: UInt64
    let rootPath: String
    let relativePath: String
    let source: StorageSparseDiskIdentity
    let stage: StorageSparseDiskIdentity?
    let sourceDigestSHA512: String?
    let stageDigestSHA512: String?
    let phase: String
    let parentDevice: UInt64?
    let parentInode: UInt64?
    let stageName: String?
    let postSwapSource: StorageSparseDiskIdentity?
    let stageRetired: Bool?
    let stageRetained: Bool?
    let requestedMode: StorageSparseDiskRewriteMode?
    let modeUsed: StorageSparseDiskRewriteMode?
    let fallbackReason: String?
    let metadataFingerprint: String?
}

private enum RuntimeV2CompletedHistoryDecision: Sendable {
    case none
    case verified(RuntimeV2OptimizationCoreJournalBinding)
    case verifyCurrentContent(RuntimeV2CompletedHistoryCandidate)
    case retainedUnverified
}

private struct RuntimeV2CompletedHistoryCandidate: Sendable {
    let context: URL
    let header: RuntimeV2OptimizationCoreJournalBinding
    let receiptBytes: Data
    let journalBytes: Data
    func matches(_ other: Self) -> Bool {
        context == other.context && header.jobID == other.header.jobID
            && receiptBytes == other.receiptBytes && journalBytes == other.journalBytes
    }
}

public struct RuntimeV2RecoveryOptimizationResult: Sendable {
    public let report: StorageSparseDiskRewriteReport?
    public let code: String
    public let recoveryPending: Bool
    public let verifiedUnchanged: Bool
    public let diagnosticCodes: [String]
    init(report: StorageSparseDiskRewriteReport?, code: String, recoveryPending: Bool,
         verifiedUnchanged: Bool = false, diagnosticCodes: [String] = []) {
        self.report = report; self.code = code; self.recoveryPending = recoveryPending
        self.verifiedUnchanged = verifiedUnchanged
        self.diagnosticCodes = diagnosticCodes
    }
    public var verifiedFirstDisk: Bool {
        if verifiedUnchanged { return true }
        guard let report else { return false }
        return report.stageRetired && report.sourceDigestSHA512 == report.stageDigestSHA512
            && report.modeUsed == .cloneAndPunch && report.fallbackReason == nil
    }
}

/// A single-disk native adapter. The App service owns its lifetime/queue.
/// Paths come only from the bounded inventory; no tool/model input is accepted.
public actor RuntimeV2RecoveryOptimizationAdapter {
    public let domain: RuntimeV2MaintenanceDomain
    private let coordinator: RuntimeV2MaintenanceCoordinator
    private let closureAuthority: RuntimeV2RecoveryClosureAuthority
    private let rawEvidence: RuntimeV2MaintenanceEvidenceProvider
    private let admittedEvidence: RuntimeV2MaintenanceEvidenceProvider
    private let journals: URL
    private let receipts: URL
    private let migrationOptimizer: RuntimeV2MigrationSparseOptimizer
    private let core = RuntimeV2OptimizationWorker("floe.legacy-recovery.core", allowsSynchronousFence: true)
    private let metadata = RuntimeV2OptimizationWorker("floe.legacy-recovery.metadata")
    private var installTask: Task<Void, Never>?
    private var recoveryInProgress = false
    private var recoveryCancellation: RuntimeV2OptimizationCancellation?
    private var recoveryProgress: (@Sendable (StorageSparseDiskRewriteProgress) -> Void)?
    private static let owner = "app-legacy-storage-optimization"
    private static let reason = "lossless-legacy-recovery"

    public init(domain: RuntimeV2MaintenanceDomain, coordinator: RuntimeV2MaintenanceCoordinator,
                closureAuthority: RuntimeV2RecoveryClosureAuthority,
                rawEvidence: @escaping RuntimeV2MaintenanceEvidenceProvider,
                admittedEvidence: @escaping RuntimeV2MaintenanceEvidenceProvider) {
        self.domain = domain; self.coordinator = coordinator; self.closureAuthority = closureAuthority
        self.rawEvidence = rawEvidence; self.admittedEvidence = admittedEvidence
        self.journals = coordinator.stateDirectory.appendingPathComponent("sparse-journals", isDirectory: true)
        self.receipts = coordinator.stateDirectory.appendingPathComponent("sparse-receipts", isDirectory: true)
        self.migrationOptimizer = RuntimeV2MigrationSparseOptimizer(domain: domain, coordinator: coordinator,
            closureAuthority: closureAuthority, admittedEvidence: admittedEvidence)
    }

    public func recoverBeforeUse(
        cancellation: RuntimeV2OptimizationCancellation? = nil,
        progress: (@Sendable (StorageSparseDiskRewriteProgress) -> Void)? = nil
    ) async -> RuntimeV2MaintenanceRecoveryReport {
        // One service invocation owns observation/cancellation for this batch.
        // A later caller may not replace the token while an awaited handler
        // is still hashing under the original recovery session.
        guard !recoveryInProgress else {
            return .init(outcome: .blocked, reason: "optimizer recovery already in progress")
        }
        recoveryInProgress = true
        recoveryCancellation = cancellation; recoveryProgress = progress
        defer {
            recoveryInProgress = false
            recoveryCancellation = nil; recoveryProgress = nil
        }
        if installTask == nil {
            let coordinator = coordinator
            installTask = Task { [weak self] in
                await coordinator.installRecoveryHandler { [weak self] intent in
                    guard let self else { return .unresolved("optimizer owner unavailable") }
                    return await self.recoverIntent(intent)
                }
            }
        }
        await installTask?.value
        return await coordinator.recoverIfNeeded()
    }

    public func inventory() async throws -> LegacyRecoveryInventoryReport {
        let evidence = await rawEvidence()
        return try await scan(evidence: evidence)
    }

    public func migrationInventory() async throws -> RuntimeV2MigrationSparseInventoryReport {
        try await migrationOptimizer.inventory()
    }
    public func optimizeMigration(_ record: RuntimeV2MigrationSparseRecord,
        cancellation: RuntimeV2OptimizationCancellation,
        progress: (@Sendable (StorageSparseDiskRewriteProgress) -> Void)? = nil)
        async -> RuntimeV2RecoveryOptimizationResult {
        await migrationOptimizer.optimize(record, cancellation: cancellation, progress: progress)
    }

    private func scan(evidence: RuntimeV2MaintenanceOwnerEvidence) async throws -> LegacyRecoveryInventoryReport {
        let references = LegacyRecoveryReferenceSnapshot(
            capturedAt: evidence.capturedAt,
            // This readonly inventory answers the DB reference question, not
            // owner admission. A missing registry/integrator/closure source
            // must not turn a complete reference projection into "unknown".
            // optimize() still acquires exclusive native admission and a fresh
            // closed-owner receipt before any rewrite can start.
            isComplete: evidence.references.isComplete && evidence.references.blockers.isEmpty
                && !evidence.references.fingerprint.isEmpty
                && evidence.references.unattributedActiveCount == 0
                && evidence.references.unattributedLiveUnknownCount == 0,
            referencedEnvironmentIDs: Set(evidence.references.activeEnvironmentIDs + evidence.references.unknownEnvironmentIDs),
            activeEnvironmentIDs: Set(evidence.references.activeEnvironmentIDs))
        let request = LegacyRecoveryInventoryRequest(legacyRoot: domain.root, currentReferences: references)
        return try await metadata.run { LegacyRecoveryInventory.scan(request) }
    }

    public func optimize(
        _ record: LegacyRecoveryInventoryRecord,
        cancellation: RuntimeV2OptimizationCancellation,
        progress: (@Sendable (StorageSparseDiskRewriteProgress) -> Void)? = nil
    ) async -> RuntimeV2RecoveryOptimizationResult {
        guard record.isReviewableForBytePreservingMaintenance,
              record.relativeDirectory.split(separator: "/").count == 3,
              record.relativeDirectory.hasPrefix("recovery/quarantine/runtime-vm-") else {
            return .init(report: nil, code: "source-not-eligible", recoveryPending: false)
        }
        if cancellation.isCancelled { return .init(report: nil, code: "cancelled", recoveryPending: false) }
        let relative = record.relativeDirectory + "/disk.img"
        let root = domain.root
        let inspection: StorageSparseDiskInspection
        let claim: RuntimeV2MaintenanceClaim
        do {
            _ = try domain.validateTargetRelativePath(relative)
            inspection = try await core.run {
                try StorageSparseDiskRewrite.inspectSource(rootURL: root, relativePath: relative)
            }
            guard Self.matches(inspection.identity, record.reviewSnapshot.diskIdentity) else {
                throw RuntimeV2MaintenanceError.targetIdentityMismatch("inventory source changed")
            }
            guard inspection.volumeAvailableBytes >= 64 * 1_024 * 1_024 else {
                throw StorageSparseDiskRewriteError.insufficientSpace(
                    required: 64 * 1_024 * 1_024, available: inspection.volumeAvailableBytes,
                    phase: "service-preflight")
            }
            claim = try await coordinator.acquireExclusiveMaintenance(.init(
                owner: Self.owner, reason: Self.reason, targetRelativePath: relative,
                targetIdentity: Self.runtimeIdentity(inspection.identity)))
        } catch {
            return .init(report: nil, code: Self.code(error), recoveryPending: Self.code(error) == "recovery-pending",
                         diagnosticCodes: Self.diagnosticCodes(error))
        }

        do {
            let preservation = try RuntimeV2OptimizationPreservation(record).fingerprint()
            try await validate(claim: claim, relative: relative, preservation: preservation)
            try claim.validateTargetIdentity()
            let closure = try await closureAuthority.currentReceipt(intentID: claim.intentID)
            guard !closure.isConvergenceProof else {
                throw RuntimeV2MaintenanceError.claimInvalidated("recovery proof cannot start optimization")
            }
            // Reuse only a completed, byte-verified commit whose exact current
            // inode/metadata and preserved sidecars still match. This is not
            // owner admission: the fresh exclusive claim/closure above remains
            // mandatory. A known retired artifact without current complete
            // proof is retained instead of falling through to Core.
            let completedDecision = try await completedJournal(relative: relative,
                source: inspection.identity, preservation: preservation, closure: closure)
            var contentHistory: RuntimeV2CompletedHistoryCandidate?
            switch completedDecision {
            case .verified(let completed):
                try await validate(claim: claim, relative: relative, preservation: preservation)
                try claim.validateTargetIdentity()
                let stillMatches = try await metadata.run {
                    Self.matchesCommittedSource(completed, root: root, expected: inspection.identity,
                        rootDevice: closure.rootDevice, rootInode: closure.rootInode)
                }
                try await claim.abortAndRelease(reason: "historical completed proof checked; no mutation")
                if stillMatches {
                    return .init(report: nil, code: "already-optimized", recoveryPending: false, verifiedUnchanged: true)
                }
                return .init(report: nil, code: "needs-inspection", recoveryPending: false)
            case .retainedUnverified:
                // Retired provenance exists, but CURRENT complete identity /
                // sidecar proof is insufficient. Keep it, never reread/rewrite
                // the large body merely to refresh an older success receipt.
                try await claim.abortAndRelease(reason: "historical success retained; current proof unverified")
                FloeLogger(category: .tools).info("legacyHistoryReuse decision=retained_unverified")
                return .init(report: nil, code: "needs-inspection", recoveryPending: false)
            case .verifyCurrentContent(let candidate):
                try await verifyCompletedContent(candidate, claim: claim, source: inspection.identity,
                    preservation: preservation, closure: closure, cancellation: cancellation, progress: progress)
                contentHistory = candidate
                // Equal bytes do NOT prove today's zero runs remain sparse.
                // Continue the existing fresh rewrite and its actual gain /
                // no-gain validation; never label this read as optimization.
            case .none:
                break
            }
            let receipt = RuntimeV2OptimizationJobReceipt(
                version: 1, intentID: claim.intentID, authorityGeneration: claim.holdGeneration,
                domainKey: domain.domainKey, relativePath: relative, expectedSource: inspection.identity,
                preservationFingerprint: preservation,
                repairHoldGeneration: record.reviewSnapshot.observedRepairGeneration ?? 0, closure: closure)
            let receipts = receipts
            let journals = journals
            try await metadata.run {
                if cancellation.isCancelled { throw CancellationError() }
                try RuntimeV2OptimizationJournalIO.writeOnce(
                    receipt, directory: receipts, name: receipt.intentID + ".json")
                try FileManager.default.createDirectory(at: journals, withIntermediateDirectories: true)
            }
            // Conservative transition BEFORE entering Core: after this point
            // cancellation/error must converge a Core terminal state, never abort
            // merely because the View or the worker task was cancelled.
            try await claim.markCommitting()
            let fence = liveFence(claim: claim, receipt: receipt, contentHistory: contentHistory)
            let request = StorageSparseDiskRewriteRequest(
                rootURL: root, relativePath: relative, expectedSource: inspection.identity,
                journalDirectoryURL: journals, jobID: claim.intentID, maintenanceLeaseID: claim.intentID,
                holdGeneration: receipt.repairHoldGeneration, jobGeneration: claim.holdGeneration,
                mode: .cloneAndPunch, minimumReclaimBytes: 1, allowSparseCopyFallback: false)
            let report = try await core.run {
                try StorageSparseDiskRewrite.rewrite(
                    request, fence: fence, isCancelled: { cancellation.isCancelled }, progress: progress)
            }
            guard report.stageRetired, report.sourceDigestSHA512 == report.stageDigestSHA512,
                  report.modeUsed == .cloneAndPunch, report.fallbackReason == nil else {
                throw StorageSparseDiskRewriteError.needsInspection("nonterminal-helper-report")
            }
            try await validate(claim: claim, relative: relative, preservation: preservation)
            if let contentHistory {
                try await validateCompletedEvidence(contentHistory, source: receipt.expectedSource,
                    preservation: preservation, closure: closure)
            }
            _ = try await claim.recordTargetIdentityAfterCommit()
            try await validate(claim: claim, relative: relative, preservation: preservation)
            try await claim.commitAndRelease()
            return .init(report: report, code: "optimized", recoveryPending: false)
        } catch {
            // Every Core handle has returned/closed before this handoff.
            // The durable gate remains blocking until the installed real
            // recovery handler proves convergence. No unchecked abort-to-idle.
            let originalCode = Self.code(error)
            await claim.handoffToRecovery()
            let resolution = await coordinator.recoverIfNeeded()
            let pending = resolution.outcome == .blocked
            var verifiedUnchanged = false
            if !pending, originalCode == "insufficient-reclaim" {
                let journals = journals
                if let header = try? await metadata.run({
                    try RuntimeV2OptimizationJournalIO.read(
                        RuntimeV2OptimizationCoreJournalBinding.self, directory: journals, name: claim.intentID + ".json")
                }), header.phase == "aborted",
                   header.source.matchesFully(inspection.identity),
                   let digest = header.sourceDigestSHA512, digest.utf8.count == 128,
                   digest == header.stageDigestSHA512,
                   header.jobID == claim.intentID, header.maintenanceLeaseID == claim.intentID,
                   header.jobGeneration == claim.holdGeneration {
                    // Core's strictly-positive-gain gate occurs AFTER complete
                    // stage byte/metadata verification. Recovery then retained
                    // exact S and retired only its redundant job-owned T.
                    verifiedUnchanged = true
                }
            }
            return .init(report: nil, code: pending ? "recovery-pending" : originalCode,
                         recoveryPending: pending, verifiedUnchanged: verifiedUnchanged,
                         diagnosticCodes: Self.diagnosticCodes(error))
        }
    }

    private func liveFence(claim: RuntimeV2MaintenanceClaim, receipt: RuntimeV2OptimizationJobReceipt,
                           contentHistory: RuntimeV2CompletedHistoryCandidate? = nil)
        -> StorageSparseDiskMaintenanceFence {
        .init(leaseID: claim.intentID, generation: claim.holdGeneration) { [self] in
            try RuntimeV2OptimizationAsyncFence.check {
                try await self.validate(claim: claim, relative: receipt.relativePath,
                                        preservation: receipt.preservationFingerprint)
                if let contentHistory {
                    try await self.validateCompletedEvidence(contentHistory, source: receipt.expectedSource,
                        preservation: receipt.preservationFingerprint, closure: receipt.closure)
                    try await self.validate(claim: claim, relative: receipt.relativePath,
                                            preservation: receipt.preservationFingerprint)
                }
            }
        }
    }

    private func validate(claim: RuntimeV2MaintenanceClaim, relative: String, preservation: String) async throws {
        try await claim.validate()
        let evidence = await admittedEvidence()
        guard evidence.isComplete, evidence.quiescenceBlockers(domain: domain).isEmpty else {
            throw RuntimeV2MaintenanceError.ownerEvidenceIncomplete(["fresh_owner_evidence_unavailable"])
        }
        try claim.validateReferenceFingerprint(evidence.references.fingerprint)
        _ = try await closureAuthority.currentReceipt(intentID: claim.intentID)
        try await validatePreservation(relative: relative, fingerprint: preservation, evidence: evidence)
        let refreshed = await admittedEvidence()
        guard refreshed.isComplete, refreshed.quiescenceBlockers(domain: domain).isEmpty else {
            throw RuntimeV2MaintenanceError.ownerEvidenceIncomplete(["fresh_owner_evidence_unavailable"])
        }
        try claim.validateReferenceFingerprint(refreshed.references.fingerprint)
        try await claim.validate()
        // Disk inode is intentionally NOT compared to the old inode here:
        // Core checks exact S/T before/after swap. The sidecars/hold stay bound.
    }

    private func validatePreservation(relative: String, fingerprint: String,
                                      evidence: RuntimeV2MaintenanceOwnerEvidence,
                                      forRecovery: Bool = false) async throws {
        let observed = try await scan(evidence: evidence)
        guard !observed.summary.isPartial else {
            throw RuntimeV2MaintenanceError.targetIdentityMismatch("repair preservation inventory incomplete")
        }
        guard let record = observed.records.first(where: { $0.relativeDirectory + "/disk.img" == relative }) else {
            throw RuntimeV2MaintenanceError.targetIdentityMismatch("repair preservation could not be observed")
        }
        try Self.validatePreservationRecord(record, fingerprint: fingerprint, forRecovery: forRecovery)
    }

    // One predicate for normal admission and the existing recovery exception
    // for future references. Diagnostic separation does not rebind metadata or
    // turn a matching content digest into matching inode/ctime evidence.
    static func validatePreservationRecord(_ record: LegacyRecoveryInventoryRecord,
                                           fingerprint: String, forRecovery: Bool) throws {
        let futureReferenceOnly: Set<LegacyRecoveryPlanningBlocker> = [
            .currentReferencesUnknown, .currentReferenceExists, .currentReferenceActive
        ]
        let blockers = forRecovery ? record.planningBlockers.filter { !futureReferenceOnly.contains($0) }
            : record.planningBlockers
        guard blockers.isEmpty else {
            throw RuntimeV2MaintenanceError.targetIdentityMismatch("repair preservation metadata blocked")
        }
        guard try RuntimeV2OptimizationPreservation(record).fingerprint() == fingerprint else {
            throw RuntimeV2MaintenanceError.targetIdentityMismatch("repair preservation generation changed")
        }
    }

    private func captureAbortPreservation(relative: String, holdGeneration: Int64,
                                          evidence: RuntimeV2MaintenanceOwnerEvidence) async throws -> String {
        let observed = try await scan(evidence: evidence)
        guard !observed.summary.isPartial else {
            throw RuntimeV2MaintenanceError.targetIdentityMismatch("repair preservation inventory incomplete")
        }
        guard let record = observed.records.first(where: { $0.relativeDirectory + "/disk.img" == relative }) else {
            throw RuntimeV2MaintenanceError.targetIdentityMismatch("repair preservation could not be observed")
        }
        let fingerprint = try RuntimeV2OptimizationPreservation(record).fingerprint()
        try Self.validatePreservationRecord(record, fingerprint: fingerprint, forRecovery: true)
        let observedGeneration = record.reviewSnapshot.observedRepairGeneration
        let sameGeneration = observedGeneration.map { $0 == holdGeneration }
            ?? (holdGeneration == 0 && record.reviewSnapshot.repairGeneration.state == .missing)
        guard sameGeneration else {
            throw RuntimeV2MaintenanceError.targetIdentityMismatch("repair hold generation changed")
        }
        // This is a temporary fence on CURRENT metadata for cleanup of a
        // generated copy. It is never written over the old v1 receipt and
        // grants no permission to commit, rollback or optimize the source.
        return fingerprint
    }

    static func isSourcePreservingAbortPhase(_ phase: String) -> Bool {
        ["intent", "counting", "staging", "verified", "swapIntent", "aborted", "failed"].contains(phase)
    }

    private enum RecoveryPhase: String {
        case authority, nativeClosure = "native-closure", historyContext = "history-context"
        case savedMetadata = "saved-metadata", preservation, journalBinding = "journal-binding"
        case coreRecovery = "core-recovery", finalAuthority = "final-authority"
    }

    private func recoverIntent(_ intent: RuntimeV2MaintenanceIntentRecord) async -> RuntimeV2MaintenanceRecoveryOutcome {
        let cancellation = recoveryCancellation
        let progress = recoveryProgress
        if RuntimeV2MigrationSparseOptimizer.owns(intent) {
            return await migrationOptimizer.recover(intent)
        }
        var phase = RecoveryPhase.authority
        do {
            guard intent.owner == Self.owner, intent.reason == Self.reason,
                  let rootDevice = intent.domainDevice, let rootInode = intent.domainInode,
                  domain.matchesRecordedRoot(intent.domainRoot, device: rootDevice, inode: rootInode),
                  let relative = intent.targetRelativePath,
                  relative.hasPrefix("recovery/quarantine/runtime-vm-"),
                  relative.split(separator: "/").count == 4, relative.hasSuffix("/disk.img") else {
                return .unresolved("not an exact optimizer-owned intent")
            }
            _ = try domain.validateTargetRelativePath(relative)
            try await coordinator.validateRecoverySession(intentID: intent.intentID, holdGeneration: intent.holdGeneration)
            phase = .nativeClosure
            try await closureAuthority.beginRecovery(
                coordinator: coordinator, intentID: intent.intentID, generation: intent.holdGeneration)
            let evidence = await admittedEvidence()
            guard evidence.isComplete,
                  RuntimeV2RecoveryClosureAuthority.convergenceBlockers(evidence, domain: domain).isEmpty else {
                return .unresolved("fresh native closure/reference proof unavailable")
            }
            phase = .historyContext
            let recoveryDirectory = try await coordinator.recoveryStorageDirectory(
                intentID: intent.intentID, holdGeneration: intent.holdGeneration)
            phase = .savedMetadata
            let receipts = recoveryDirectory.appendingPathComponent("sparse-receipts", isDirectory: true)
            let saved = try await metadata.run {
                try RuntimeV2OptimizationJournalIO.read(
                    RuntimeV2OptimizationJobReceipt.self, directory: receipts, name: intent.intentID + ".json")
            }
            let journals = recoveryDirectory.appendingPathComponent("sparse-journals", isDirectory: true)
            let root = domain.root
            let header = try await metadata.run {
                try RuntimeV2OptimizationJournalIO.read(
                    RuntimeV2OptimizationCoreJournalBinding.self, directory: journals, name: intent.intentID + ".json")
            }
            guard let saved else {
                // A crash between authority acquisition and receipt creation
                // cannot have entered Core. Require no Core journal and the
                // exact original target, never a time/pid inference.
                guard header == nil, let expected = intent.targetIdentity,
                      try RuntimeV2DiskIdentity.read(at: root.appendingPathComponent(relative)) == expected else {
                    return .unresolved("missing adapter receipt with ambiguous source")
                }
                return .resolved
            }
            guard saved.version == 1, saved.intentID == intent.intentID,
                  saved.authorityGeneration == intent.holdGeneration,
                  Self.isDomainKey(saved.domainKey), saved.domainKey == saved.closure.domainKey,
                  saved.relativePath == relative,
                  saved.closure.version == 1, saved.closure.intentID == intent.intentID,
                  saved.closure.holdGeneration == intent.holdGeneration,
                  !saved.closure.isConvergenceProof,
                  saved.closure.rootDevice == intent.domainDevice,
                  saved.closure.rootInode == intent.domainInode else {
                return .unresolved("adapter receipt generation mismatch")
            }
            phase = .journalBinding
            if let header {
                guard header.schemaVersion == 2, header.jobID == intent.intentID,
                      header.maintenanceLeaseID == intent.intentID,
                      header.jobGeneration == intent.holdGeneration,
                      header.holdGeneration == saved.repairHoldGeneration,
                      header.relativePath == relative,
                      Self.matchesPhysicalRoot(header.rootPath, root: root,
                          device: rootDevice, inode: rootInode),
                      header.source.matchesFully(saved.expectedSource) else {
                    return .unresolved("Core journal identity/generation mismatch")
                }
            } else {
                // No Core journal is not proof of a classified S/T cleanup.
                // Retain the original strict metadata/source checks here.
                phase = .preservation
                try await validatePreservation(relative: relative, fingerprint: saved.preservationFingerprint,
                                               evidence: evidence, forRecovery: true)
                let original = try await core.run {
                    try StorageSparseDiskRewrite.inspectSource(rootURL: root, relativePath: relative)
                }
                guard original.identity.matchesFully(saved.expectedSource) else {
                    return .unresolved("journal absent and original inode changed")
                }
                return .resolved
            }
            guard let recoveringHeader = header else { return .unresolved("Core journal disappeared") }
            var policy: StorageSparseDiskRecoveryPolicy = .complete
            if Self.isSourcePreservingAbortPhase(recoveringHeader.phase) {
                policy = .abortUnchangedSourceOnly
                if recoveringHeader.phase == "swapIntent", let staged = recoveringHeader.stage {
                    // The atomic swap can finish before its next journal save.
                    // A positively observed T at the original path must keep
                    // the existing strict, byte-verified complete recovery.
                    // Unknown/S/changed identities never fall back from the
                    // restricted policy to this more capable path.
                    let current = try await core.run {
                        try StorageSparseDiskRewrite.inspectSource(rootURL: root, relativePath: relative)
                    }
                    if current.identity.matchesInode(staged),
                       !current.identity.matchesInode(recoveringHeader.source) {
                        policy = .complete
                    }
                }
            }
            let recoveryPolicy = policy
            phase = .preservation
            let preservationToFence: String
            if policy == .abortUnchangedSourceOnly {
                preservationToFence = try await captureAbortPreservation(
                    relative: relative, holdGeneration: saved.repairHoldGeneration, evidence: evidence)
            } else {
                preservationToFence = saved.preservationFingerprint
                try await validatePreservation(relative: relative, fingerprint: preservationToFence,
                                               evidence: evidence, forRecovery: true)
            }
            let rootBinding = StorageSparseDiskRecoveryRootBinding(
                recordedRootPath: recoveringHeader.rootPath, device: rootDevice, inode: rootInode)
            let fingerprint = evidence.references.fingerprint
            let fence = StorageSparseDiskMaintenanceFence(
                leaseID: intent.intentID, generation: intent.holdGeneration) { [self] in
                try RuntimeV2OptimizationAsyncFence.check {
                    try await self.coordinator.validateRecoverySession(
                        intentID: intent.intentID, holdGeneration: intent.holdGeneration)
                    let fresh = await self.admittedEvidence()
                    guard fresh.isComplete,
                          RuntimeV2RecoveryClosureAuthority.convergenceBlockers(fresh, domain: self.domain).isEmpty,
                          fresh.references.fingerprint == fingerprint else {
                        throw RuntimeV2MaintenanceError.claimInvalidated("recovery owner/reference generation changed")
                    }
                    try await self.validatePreservation(
                        relative: relative, fingerprint: preservationToFence, evidence: fresh,
                        forRecovery: true)
                    let afterMetadata = await self.admittedEvidence()
                    guard afterMetadata.isComplete,
                          RuntimeV2RecoveryClosureAuthority.convergenceBlockers(afterMetadata, domain: self.domain).isEmpty,
                          afterMetadata.references.fingerprint == fingerprint else {
                        throw RuntimeV2MaintenanceError.claimInvalidated("recovery references changed after metadata read")
                    }
                    try await self.coordinator.validateRecoverySession(
                        intentID: intent.intentID, holdGeneration: intent.holdGeneration)
                }
            }
            // Only the abort-only pre-mutation read accepts cancellation.
            // Core finishes its short unlink/journal phase once begun; the
            // existing complete/swap/rollback convergence stays service-owned.
            phase = .coreRecovery
            let result = try await core.run {
                try StorageSparseDiskRewrite.recover(
                    rootURL: root, relativePath: relative, journalDirectoryURL: journals,
                    jobID: intent.intentID, fence: fence,
                    recordedRootBinding: rootBinding,
                    policy: recoveryPolicy,
                    isCancelled: {
                        recoveryPolicy == .abortUnchangedSourceOnly && (cancellation?.isCancelled ?? false)
                    },
                    progress: recoveryPolicy == .abortUnchangedSourceOnly ? progress : nil)
            }
            guard result.sourceIdentityVerified,
                  result.resolution != .needsInspection, result.resolution != .noJournal else {
                if policy == .abortUnchangedSourceOnly {
                    FloeLogger(category: .tools).error("legacyHistoryRecovery code=needs-inspection phase=core-recovery reason="
                        + Self.abortDiagnosticReason(result.detail))
                }
                return .unresolved("Core recovery retained ambiguous evidence")
            }
            if policy == .abortUnchangedSourceOnly {
                guard result.resolution == .abortedBeforeSwap, result.phase == "aborted" else {
                    return .unresolved("restricted recovery did not prove an untouched source")
                }
                if result.sourceContentDigestVerified {
                    FloeLogger(category: .tools).info("legacyHistoryRecovery code=source-content-verified phase=core-recovery")
                }
            }
            phase = .finalAuthority
            try await coordinator.validateRecoverySession(intentID: intent.intentID, holdGeneration: intent.holdGeneration)
            if policy == .abortUnchangedSourceOnly {
                let finalEvidence = await admittedEvidence()
                guard finalEvidence.isComplete,
                      RuntimeV2RecoveryClosureAuthority.convergenceBlockers(finalEvidence, domain: domain).isEmpty,
                      finalEvidence.references.fingerprint == fingerprint else {
                    throw RuntimeV2MaintenanceError.claimInvalidated("recovery owner/reference generation changed")
                }
                try await validatePreservation(relative: relative, fingerprint: preservationToFence,
                                               evidence: finalEvidence, forRecovery: true)
                let afterFinalMetadata = await admittedEvidence()
                guard afterFinalMetadata.isComplete,
                      RuntimeV2RecoveryClosureAuthority.convergenceBlockers(afterFinalMetadata, domain: domain).isEmpty,
                      afterFinalMetadata.references.fingerprint == fingerprint else {
                    throw RuntimeV2MaintenanceError.claimInvalidated("recovery references changed after metadata read")
                }
                try await coordinator.validateRecoverySession(intentID: intent.intentID, holdGeneration: intent.holdGeneration)
            }
            return .resolved
        } catch {
            // Only closed vocabulary: no errorDescription, path, owner, id,
            // document text or sidecar contents enter normal logs or UI.
            FloeLogger(category: .tools).error("legacyHistoryRecovery code=" + Self.code(error)
                + " phase=" + phase.rawValue + " reason=" + Self.recoveryDiagnosticReason(error))
            return .unresolved("native recovery requires inspection: " + Self.code(error))
        }
    }

    private func verifyCompletedContent(
        _ candidate: RuntimeV2CompletedHistoryCandidate, claim: RuntimeV2MaintenanceClaim,
        source: StorageSparseDiskIdentity, preservation: String, closure: RuntimeV2RecoveryClosedReceipt,
        cancellation: RuntimeV2OptimizationCancellation,
        progress: (@Sendable (StorageSparseDiskRewriteProgress) -> Void)?
    ) async throws {
        let relative = candidate.header.relativePath
        let fence = StorageSparseDiskMaintenanceFence(leaseID: claim.intentID, generation: claim.holdGeneration) { [self] in
            try RuntimeV2OptimizationAsyncFence.check {
                try await self.validate(claim: claim, relative: relative, preservation: preservation)
                try claim.validateTargetIdentity()
                try await self.validateCompletedEvidence(candidate, source: source,
                    preservation: preservation, closure: closure)
                try await self.validate(claim: claim, relative: relative, preservation: preservation)
                try claim.validateTargetIdentity()
            }
        }
        let root = domain.root
        let binding = StorageSparseDiskRecoveryRootBinding(recordedRootPath: candidate.header.rootPath,
            device: closure.rootDevice, inode: closure.rootInode)
        let report = try await core.run {
            try StorageSparseDiskRewrite.verifyRetiredSource(rootURL: root, relativePath: relative,
                expectedSource: source, journalDirectoryURL: candidate.context.appendingPathComponent("sparse-journals"),
                jobID: candidate.header.jobID, fence: fence, recordedRootBinding: binding,
                isCancelled: { cancellation.isCancelled }, progress: progress)
        }
        guard report.resolution == .alreadyCommitted, report.sourceIdentityVerified,
              report.sourceContentDigestVerified, report.phase == "retired", !report.stageRemoved else {
            throw StorageSparseDiskRewriteError.needsInspection("completed-current-content-unverified")
        }
        try await validate(claim: claim, relative: relative, preservation: preservation)
        try claim.validateTargetIdentity()
        try await validateCompletedEvidence(candidate, source: source, preservation: preservation, closure: closure)
        if cancellation.isCancelled { throw CancellationError() }
        FloeLogger(category: .tools).info("legacyHistoryReuse decision=content_revalidated_fresh_rewrite_required")
    }

    private func validateCompletedEvidence(_ candidate: RuntimeV2CompletedHistoryCandidate,
        source: StorageSparseDiskIdentity, preservation: String, closure: RuntimeV2RecoveryClosedReceipt
    ) async throws {
        guard case .verifyCurrentContent(let fresh) = try await completedJournal(
            relative: candidate.header.relativePath, source: source, preservation: preservation, closure: closure),
              candidate.matches(fresh) else {
            throw RuntimeV2MaintenanceError.claimInvalidated("completed history evidence changed")
        }
    }

    private func completedJournal(
        relative: String, source: StorageSparseDiskIdentity, preservation: String,
        closure: RuntimeV2RecoveryClosedReceipt
    ) async throws -> RuntimeV2CompletedHistoryDecision {
        let contexts = try await coordinator.completedStorageDirectories(
            intentID: closure.intentID, holdGeneration: closure.holdGeneration)
        let domain = domain
        return try await metadata.run {
            var retiredTargetSeen = false
            var matchingRetiredRecords = 0
            var verified: [RuntimeV2OptimizationCoreJournalBinding] = []
            var candidates: [RuntimeV2CompletedHistoryCandidate] = []
            var totalReceipts = 0
            for context in contexts {
                let receipts = context.appendingPathComponent("sparse-receipts", isDirectory: true)
                let journals = context.appendingPathComponent("sparse-journals", isDirectory: true)
                for name in try Self.completedReceiptNames(directory: receipts) {
                    totalReceipts += 1
                    guard totalReceipts <= 512 else { throw StorageSparseDiskRewriteError.needsInspection("all-history-receipt-budget") }
                    let receiptBytes = try Self.completedEvidenceData(directory: receipts, name: name)
                    let saved = try JSONDecoder().decode(RuntimeV2OptimizationJobReceipt.self, from: receiptBytes)
                    guard saved.version == 1, Self.isDomainKey(saved.domainKey),
                          saved.domainKey == saved.closure.domainKey, saved.relativePath == relative,
                          saved.intentID + ".json" == name,
                          saved.closure.version == 1, !saved.closure.isConvergenceProof,
                          saved.closure.intentID == saved.intentID,
                          saved.closure.holdGeneration == saved.authorityGeneration,
                          saved.closure.rootDevice == closure.rootDevice,
                          saved.closure.rootInode == closure.rootInode else { continue }
                    // Preserve the existing legitimate receipt-before-journal
                    // no-op case; corrupt/changed present evidence still throws.
                    guard let _ = try RuntimeV2OptimizationJournalIO.read(
                        RuntimeV2OptimizationCoreJournalBinding.self, directory: journals, name: name) else { continue }
                    let journalBytes = try Self.completedEvidenceData(directory: journals, name: name)
                    let header = try JSONDecoder().decode(RuntimeV2OptimizationCoreJournalBinding.self, from: journalBytes)
                    let matchesRetiredTarget = header.phase == "retired" && header.relativePath == relative
                        && header.postSwapSource.map { old in
                            old.device == source.device && old.inode == source.inode
                                && old.sizeBytes == source.sizeBytes
                                && old.modificationSeconds == source.modificationSeconds
                                && old.modificationNanoseconds == source.modificationNanoseconds
                        } == true
                    if matchesRetiredTarget { retiredTargetSeen = true; matchingRetiredRecords += 1 }
                    guard header.schemaVersion == 2, header.jobID == saved.intentID,
                          header.maintenanceLeaseID == saved.intentID,
                          header.jobGeneration == saved.authorityGeneration,
                          header.holdGeneration == saved.repairHoldGeneration,
                          header.source.matchesFully(saved.expectedSource), header.relativePath == relative,
                          header.phase == "retired", header.stageRetired == true, header.stageRetained == false,
                          header.requestedMode == .cloneAndPunch, header.modeUsed == .cloneAndPunch,
                          header.fallbackReason == nil,
                          let digest = header.sourceDigestSHA512, Self.isSHA512(digest),
                          digest == header.stageDigestSHA512,
                          let metadataFingerprint = header.metadataFingerprint,
                          Self.isSHA512(metadataFingerprint),
                          Self.matchesPhysicalRoot(header.rootPath, root: domain.root,
                            device: closure.rootDevice, inode: closure.rootInode) else { continue }
                    // Later aborted/insufficient-reclaim records do not hide
                    // this retired artifact, nor certify current bytes for it.
                    if matchesRetiredTarget {
                        // Only classifies a historical inode for RETENTION.
                        // It never certifies bytes or removes the full guards
                        // below. A genuinely changed mtime/new inode keeps the
                        // normal task-authorized new-source behavior.
                        candidates.append(.init(context: context, header: header,
                            receiptBytes: receiptBytes, journalBytes: journalBytes))
                    }
                    guard saved.preservationFingerprint == preservation,
                          header.postSwapSource?.matchesFully(source) == true,
                          Self.matchesCommittedSource(header, root: domain.root, expected: source,
                            rootDevice: closure.rootDevice, rootInode: closure.rootInode) else { continue }
                    verified.append(header)
                }
            }
            if verified.count == 1 && matchingRetiredRecords == 1 { return .verified(verified[0]) }
            if verified.isEmpty, matchingRetiredRecords == 1, candidates.count == 1, let candidate = candidates.first,
               candidate.header.postSwapSource?.matchesStable(source) == true {
                return .verifyCurrentContent(candidate)
            }
            // Multiple current proofs are not resolved by filename/date order.
            if retiredTargetSeen { return .retainedUnverified }
            return .none
        }
    }

    /// Exact bounded bytes for the selected historical receipt/journal CAS.
    /// Follows the held coordinator context; never follows a leaf symlink or
    /// accepts linked, changed, oversized or differently named evidence.
    private static func completedEvidenceData(directory: URL, name: String) throws -> Data {
        #if canImport(Darwin)
        guard name.hasSuffix(".json"), UUID(uuidString: String(name.dropLast(5))) != nil else {
            throw StorageSparseDiskRewriteError.journalCorrupt("completed-evidence-name")
        }
        let dir = open(directory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard dir >= 0 else { throw StorageSparseDiskRewriteError.directoryOpenFailed(errno: errno) }
        defer { close(dir) }
        let fd = openat(dir, name, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        guard fd >= 0 else { throw StorageSparseDiskRewriteError.journalOpenFailed(errno: errno) }
        defer { close(fd) }
        var before = stat()
        guard fstat(fd, &before) == 0, before.st_mode & S_IFMT == S_IFREG,
              before.st_nlink == 1, before.st_size > 0, before.st_size <= 65_536 else {
            throw StorageSparseDiskRewriteError.journalCorrupt("completed-evidence-shape")
        }
        func same(_ other: stat) -> Bool {
            other.st_dev == before.st_dev && other.st_ino == before.st_ino
                && other.st_mode == before.st_mode && other.st_nlink == before.st_nlink
                && other.st_uid == before.st_uid && other.st_gid == before.st_gid
                && other.st_size == before.st_size && other.st_flags == before.st_flags
                && other.st_mtimespec.tv_sec == before.st_mtimespec.tv_sec
                && other.st_mtimespec.tv_nsec == before.st_mtimespec.tv_nsec
                && other.st_ctimespec.tv_sec == before.st_ctimespec.tv_sec
                && other.st_ctimespec.tv_nsec == before.st_ctimespec.tv_nsec
        }
        var bytes = [UInt8](repeating: 0, count: Int(before.st_size)), offset = 0
        while offset < bytes.count {
            let remaining = bytes.count - offset
            let count = bytes.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress!.advanced(by: offset), remaining) }
            if count < 0 && errno == EINTR { continue }
            guard count > 0 else { throw StorageSparseDiskRewriteError.journalCorrupt("completed-evidence-read") }
            offset += count
        }
        var after = stat(), named = stat()
        guard fstat(fd, &after) == 0, same(after),
              fstatat(dir, name, &named, AT_SYMLINK_NOFOLLOW) == 0, same(named) else {
            throw StorageSparseDiskRewriteError.journalCorrupt("completed-evidence-changed")
        }
        return Data(bytes)
        #else
        throw StorageSparseDiskRewriteError.unsupportedPlatform
        #endif
    }

    static func isSHA512(_ value: String) -> Bool {
        value.utf8.count == 128 && value.utf8.allSatisfy {
            (48...57).contains($0) || (97...102).contains($0) || (65...70).contains($0)
        }
    }

    static func isDomainKey(_ key: String) -> Bool {
        key.utf8.count == 64 && key.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }

    // Existing aliases still require realpath equality. A disappeared path
    // additionally requires the exact durable physical directory identity.
    static func matchesPhysicalRoot(_ recorded: String, root: URL, device: UInt64, inode: UInt64) -> Bool {
        guard let domain = try? RuntimeV2MaintenanceDomain(trustedLegacyRoot: root) else { return false }
        return domain.matchesRecordedRoot(recorded, device: device, inode: inode)
    }

    static func completedReceiptNames(directory: URL) throws -> [String] {
        let fd = open(directory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        if fd < 0, errno == ENOENT { return [] }
        guard fd >= 0 else { throw StorageSparseDiskRewriteError.needsInspection("receipt-directory") }
        guard let stream = fdopendir(fd) else {
            close(fd); throw StorageSparseDiskRewriteError.needsInspection("receipt-directory")
        }
        defer { closedir(stream) }
        var names: [String] = [], count = 0
        while true {
            errno = 0
            guard let entry = readdir(stream) else {
                guard errno == 0 else { throw StorageSparseDiskRewriteError.needsInspection("receipt-enumeration") }
                break
            }
            count += 1
            guard count <= 512 else { throw StorageSparseDiskRewriteError.needsInspection("receipt-budget") }
            let name = withUnsafePointer(to: entry.pointee.d_name) {
                String(cString: UnsafeRawPointer($0).assumingMemoryBound(to: CChar.self))
            }
            guard name.hasSuffix(".json"), UUID(uuidString: String(name.dropLast(5))) != nil else { continue }
            names.append(name)
        }
        return names.sorted()
    }

    static func matchesCommittedSource(
        _ header: RuntimeV2OptimizationCoreJournalBinding, root: URL,
        expected: StorageSparseDiskIdentity, rootDevice: UInt64, rootInode: UInt64
    ) -> Bool {
        guard let parentDevice = header.parentDevice, let parentInode = header.parentInode,
              let stage = header.stageName, !stage.isEmpty, stage != ".", stage != "..",
              stage.utf8.count <= 255, !stage.contains("/"), !stage.utf8.contains(0),
              matchesPhysicalRoot(header.rootPath, root: root, device: rootDevice, inode: rootInode),
              let canonical = root.path.withCString({ realpath($0, nil) }) else { return false }
        defer { free(canonical) }
        var parent = open(canonical, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard parent >= 0 else { return false }; defer { close(parent) }
        var identity = stat()
        guard fstat(parent, &identity) == 0, UInt64(bitPattern: Int64(identity.st_dev)) == rootDevice,
              UInt64(identity.st_ino) == rootInode else { return false }
        let parts = header.relativePath.split(separator: "/").map(String.init)
        let repairPath = parts.count == 4 && parts[0] == "recovery" && parts[1] == "quarantine"
            && parts[2].hasPrefix("runtime-vm-")
        let migrationPath = RuntimeV2MigrationSparseCatalog.target(header.relativePath) != nil
        guard repairPath || migrationPath, parts.last == "disk.img",
              parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." && !$0.utf8.contains(0) }) else { return false }
        for name in parts.dropLast() {
            let child = openat(parent, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard child >= 0 else { return false }
            close(parent); parent = child
        }
        guard fstat(parent, &identity) == 0, UInt64(bitPattern: Int64(identity.st_dev)) == parentDevice,
              UInt64(identity.st_ino) == parentInode else { return false }
        let sourceFD = openat(parent, "disk.img", O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        guard sourceFD >= 0 else { return false }; defer { close(sourceFD) }
        func matches(_ info: stat) -> Bool {
            #if canImport(Darwin)
            let modified = info.st_mtimespec, changed = info.st_ctimespec
            let flags = UInt32(info.st_flags)
            #else
            let modified = info.st_mtim, changed = info.st_ctim
            let flags: UInt32 = 0
            #endif
            return UInt64(bitPattern: Int64(info.st_dev)) == expected.device && UInt64(info.st_ino) == expected.inode
                && Int64(info.st_size) == expected.sizeBytes && UInt32(info.st_nlink) == expected.linkCount
                && UInt32(info.st_mode) == expected.mode && UInt32(info.st_uid) == expected.ownerUID
                && UInt32(info.st_gid) == expected.ownerGID && flags == expected.fileFlags
                && Int64(modified.tv_sec) == expected.modificationSeconds
                && Int64(modified.tv_nsec) == expected.modificationNanoseconds
                && Int64(changed.tv_sec) == expected.changeSeconds && Int64(changed.tv_nsec) == expected.changeNanoseconds
                && info.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG)
        }
        guard fstat(sourceFD, &identity) == 0, matches(identity) else { return false }
        var absent = stat()
        guard fstatat(parent, stage, &absent, AT_SYMLINK_NOFOLLOW) == -1, errno == ENOENT else { return false }
        return fstatat(parent, "disk.img", &identity, AT_SYMLINK_NOFOLLOW) == 0 && matches(identity)
            && fstat(sourceFD, &identity) == 0 && matches(identity)
    }

    static func runtimeIdentity(_ source: StorageSparseDiskIdentity) -> RuntimeV2DiskIdentity {
        .init(device: source.device, inode: source.inode, size: source.sizeBytes,
              linkCount: UInt64(source.linkCount), mode: source.mode,
              modificationSeconds: source.modificationSeconds, modificationNanoseconds: source.modificationNanoseconds,
              changeSeconds: source.changeSeconds, changeNanoseconds: source.changeNanoseconds)
    }
    static func matches(_ source: StorageSparseDiskIdentity, _ observed: LegacyRecoveryFileIdentity?) -> Bool {
        guard let observed else { return false }
        return source.device == observed.device && source.inode == observed.inode
            && source.sizeBytes == observed.logicalBytes && UInt64(source.linkCount) == observed.linkCount
            && source.mode == observed.mode && source.modificationSeconds == observed.modification.seconds
            && source.modificationNanoseconds == observed.modification.nanoseconds
            && source.changeSeconds == observed.change.seconds && source.changeNanoseconds == observed.change.nanoseconds
    }
    public static func code(_ error: Error) -> String {
        if error is CancellationError { return "cancelled" }
        if let core = error as? StorageSparseDiskRewriteError { return core.code }
        if let authority = error as? RuntimeV2MaintenanceError {
            switch authority {
            case .maintenanceActive, .crossProcessOwner: return "busy"
            case .ownerEvidenceIncomplete: return "owner-unknown"
            case .recoveryPending, .recoveryHandlerUnavailable: return "recovery-pending"
            case .targetIdentityMismatch, .claimInvalidated: return "identity-changed"
            default: return "maintenance-unavailable"
            }
        }
        return "optimization-stopped"
    }
    static func recoveryDiagnosticReason(_ error: Error) -> String {
        guard let authority = error as? RuntimeV2MaintenanceError else { return "native-error" }
        switch authority {
        case .targetIdentityMismatch(let reason):
            switch reason {
            case "repair preservation inventory incomplete": return "preservation-inventory-incomplete"
            case "repair preservation could not be observed": return "preservation-record-unavailable"
            case "repair preservation metadata blocked": return "preservation-metadata-blocked"
            case "repair preservation generation changed": return "preservation-fingerprint-changed"
            case "repair hold generation changed": return "preservation-hold-generation-changed"
            default: return "target-identity-unverified"
            }
        case .claimInvalidated(let reason):
            switch reason {
            case "recovery authority is not held": return "recovery-session-changed"
            case "recovery owner/reference generation changed": return "recovery-owner-or-reference-changed"
            case "recovery references changed after metadata read": return "recovery-reference-changed-after-read"
            case "authority validation timed out": return "authority-validation-timeout"
            case "authority reply absent": return "authority-reply-unavailable"
            case "fence wait requires its owned GCD Core queue": return "core-worker-unverified"
            default: return "authority-generation-unverified"
            }
        default: return "authority-refused"
        }
    }
    private static func abortDiagnosticReason(_ detail: String) -> String {
        let allowed: Set<String> = [
            "source-preserving-abort-phase", "source-preserving-abort-stage-name",
            "source-preserving-abort-path-unverified", "source-preserving-abort-source-identity",
            "source-preserving-abort-source-ctime", "source-preserving-abort-stage-identity",
            "source-preserving-abort-digest-unavailable", "source-preserving-abort-source-digest",
            "source-preserving-abort-source-changed",
            "source-preserving-abort-journal-changed", "source-preserving-abort-identity-changed",
            "source-preserving-abort-unlink", "source-preserving-abort-postcheck",
            "source-preserving-abort-finalcheck"
        ]
        return allowed.contains(detail) ? detail : "source-preserving-abort-unverified"
    }
    static func diagnosticCodes(_ error: Error) -> [String] {
        if case RuntimeV2MaintenanceError.claimInvalidated(let reason) = error,
           reason == "the environment reference projection changed" {
            return ["reference-projection-changed"]
        }
        guard case RuntimeV2MaintenanceError.ownerEvidenceIncomplete(let codes) = error else { return [] }
        return Array(Set(codes.compactMap { value -> String? in
            // Remove attributed ids. The manual UI gets fixed reason codes,
            // never owner names, paths or diagnostic strings from NSError.
            let head = String(value.split(separator: ":", maxSplits: 1).first ?? "")
            guard !head.isEmpty, head.utf8.count <= 64,
                  head.utf8.allSatisfy({ (48...57).contains($0) || (65...90).contains($0)
                      || (97...122).contains($0) || $0 == 45 || $0 == 95 }) else { return nil }
            return head
        })).sorted().prefix(32).map { $0 }
    }
}
