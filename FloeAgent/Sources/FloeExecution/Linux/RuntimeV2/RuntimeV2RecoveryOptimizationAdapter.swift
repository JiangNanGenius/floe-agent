import Foundation
import Dispatch
import FloeCore

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
private struct RuntimeV2OptimizationCoreJournalBinding: Decodable, Sendable {
    let schemaVersion: Int
    let jobID: String
    let maintenanceLeaseID: String
    let holdGeneration: Int64
    let jobGeneration: UInt64
    let rootPath: String
    let relativePath: String
    let source: StorageSparseDiskIdentity
    let sourceDigestSHA512: String?
    let stageDigestSHA512: String?
    let phase: String
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
    private let core = RuntimeV2OptimizationWorker("floe.legacy-recovery.core", allowsSynchronousFence: true)
    private let metadata = RuntimeV2OptimizationWorker("floe.legacy-recovery.metadata")
    private var installTask: Task<Void, Never>?
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
    }

    public func recoverBeforeUse() async -> RuntimeV2MaintenanceRecoveryReport {
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

    private func scan(evidence: RuntimeV2MaintenanceOwnerEvidence) async throws -> LegacyRecoveryInventoryReport {
        let references = LegacyRecoveryReferenceSnapshot(
            capturedAt: evidence.capturedAt,
            isComplete: evidence.isComplete && evidence.references.isComplete
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
            let receipt = RuntimeV2OptimizationJobReceipt(
                version: 1, intentID: claim.intentID, authorityGeneration: claim.holdGeneration,
                domainKey: domain.domainKey, relativePath: relative, expectedSource: inspection.identity,
                preservationFingerprint: preservation,
                repairHoldGeneration: record.reviewSnapshot.observedRepairGeneration ?? 0, closure: closure)
            let receipts = receipts
            let journals = journals
            try await metadata.run {
                try RuntimeV2OptimizationJournalIO.writeOnce(
                    receipt, directory: receipts, name: receipt.intentID + ".json")
                try FileManager.default.createDirectory(at: journals, withIntermediateDirectories: true)
            }
            // Conservative transition BEFORE entering Core: after this point
            // cancellation/error must converge a Core terminal state, never abort
            // merely because the View or the worker task was cancelled.
            try await claim.markCommitting()
            let fence = liveFence(claim: claim, receipt: receipt)
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

    private func liveFence(claim: RuntimeV2MaintenanceClaim, receipt: RuntimeV2OptimizationJobReceipt)
        -> StorageSparseDiskMaintenanceFence {
        .init(leaseID: claim.intentID, generation: claim.holdGeneration) { [self] in
            try RuntimeV2OptimizationAsyncFence.check {
                try await self.validate(claim: claim, relative: receipt.relativePath,
                                        preservation: receipt.preservationFingerprint)
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
        guard !observed.summary.isPartial,
              let record = observed.records.first(where: { $0.relativeDirectory + "/disk.img" == relative }) else {
            throw RuntimeV2MaintenanceError.targetIdentityMismatch("repair preservation could not be observed")
        }
        let futureReferenceOnly: Set<LegacyRecoveryPlanningBlocker> = [
            .currentReferencesUnknown, .currentReferenceExists, .currentReferenceActive
        ]
        let blockers = forRecovery ? record.planningBlockers.filter { !futureReferenceOnly.contains($0) }
            : record.planningBlockers
        guard blockers.isEmpty,
              try RuntimeV2OptimizationPreservation(record).fingerprint() == fingerprint else {
            throw RuntimeV2MaintenanceError.targetIdentityMismatch("repair preservation generation changed")
        }
    }

    private func recoverIntent(_ intent: RuntimeV2MaintenanceIntentRecord) async -> RuntimeV2MaintenanceRecoveryOutcome {
        do {
            guard intent.owner == Self.owner, intent.reason == Self.reason,
                  intent.domainRoot == domain.root.path, let relative = intent.targetRelativePath,
                  relative.hasPrefix("recovery/quarantine/runtime-vm-"),
                  relative.split(separator: "/").count == 4, relative.hasSuffix("/disk.img") else {
                return .unresolved("not an exact optimizer-owned intent")
            }
            _ = try domain.validateTargetRelativePath(relative)
            try await coordinator.validateRecoverySession(intentID: intent.intentID, holdGeneration: intent.holdGeneration)
            try await closureAuthority.beginRecovery(
                coordinator: coordinator, intentID: intent.intentID, generation: intent.holdGeneration)
            let evidence = await admittedEvidence()
            guard evidence.isComplete,
                  RuntimeV2RecoveryClosureAuthority.convergenceBlockers(evidence, domain: domain).isEmpty else {
                return .unresolved("fresh native closure/reference proof unavailable")
            }
            let receipts = receipts
            let saved = try await metadata.run {
                try RuntimeV2OptimizationJournalIO.read(
                    RuntimeV2OptimizationJobReceipt.self, directory: receipts, name: intent.intentID + ".json")
            }
            let journals = journals; let root = domain.root
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
                  saved.domainKey == domain.domainKey, saved.relativePath == relative,
                  saved.closure.intentID == intent.intentID,
                  saved.closure.holdGeneration == intent.holdGeneration,
                  !saved.closure.isConvergenceProof,
                  saved.closure.domainKey == domain.domainKey,
                  saved.closure.rootDevice == intent.domainDevice,
                  saved.closure.rootInode == intent.domainInode else {
                return .unresolved("adapter receipt generation mismatch")
            }
            try await validatePreservation(relative: relative, fingerprint: saved.preservationFingerprint,
                                           evidence: evidence, forRecovery: true)
            if let header {
                guard header.schemaVersion == 2, header.jobID == intent.intentID,
                      header.maintenanceLeaseID == intent.intentID,
                      header.jobGeneration == intent.holdGeneration,
                      header.holdGeneration == saved.repairHoldGeneration,
                      header.relativePath == relative,
                      header.rootPath == RuntimeV2RecoveryAdmission.key(root),
                      header.source.matchesFully(saved.expectedSource) else {
                    return .unresolved("Core journal identity/generation mismatch")
                }
            } else {
                let original = try await core.run {
                    try StorageSparseDiskRewrite.inspectSource(rootURL: root, relativePath: relative)
                }
                guard original.identity.matchesFully(saved.expectedSource) else {
                    return .unresolved("journal absent and original inode changed")
                }
                return .resolved
            }
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
                        relative: relative, fingerprint: saved.preservationFingerprint, evidence: fresh,
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
            // Recovery is service-owned and must finish its bounded phase even
            // if the user's batch cancellation was requested.
            let result = try await core.run {
                try StorageSparseDiskRewrite.recover(
                    rootURL: root, relativePath: relative, journalDirectoryURL: journals,
                    jobID: intent.intentID, fence: fence, isCancelled: { false })
            }
            guard result.sourceIdentityVerified,
                  result.resolution != .needsInspection, result.resolution != .noJournal else {
                return .unresolved("Core recovery retained ambiguous evidence")
            }
            try await coordinator.validateRecoverySession(intentID: intent.intentID, holdGeneration: intent.holdGeneration)
            return .resolved
        } catch { return .unresolved("native recovery requires inspection: " + Self.code(error)) }
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
    static func diagnosticCodes(_ error: Error) -> [String] {
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
