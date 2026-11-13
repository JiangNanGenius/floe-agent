// Typed image-migration branch of the existing legacy maintenance service.
// One coordinator/handler owns both this branch and the unchanged repair branch.
import Foundation
import FloeCore

struct RuntimeV2MigrationSparseReceipt: Codable, Sendable {
    let schema: Int
    let producer: String
    let intentID: String
    let authorityGeneration: UInt64
    let coreHoldGeneration: Int64
    let domainKey: String
    let record: RuntimeV2MigrationSparseRecord
    let preservationFingerprint: String
    let closure: RuntimeV2RecoveryClosedReceipt
}

private enum RuntimeV2MigrationCompletedHistoryDecision: Sendable {
    case none
    case verified(RuntimeV2OptimizationCoreJournalBinding)
    case retainedUnverified
}

actor RuntimeV2MigrationSparseOptimizer {
    static let owner = "app-legacy-image-sparse-optimization"
    static let reason = "lossless-legacy-image-migration"
    private let domain: RuntimeV2MaintenanceDomain
    private let coordinator: RuntimeV2MaintenanceCoordinator
    private let closureAuthority: RuntimeV2RecoveryClosureAuthority
    private let admittedEvidence: RuntimeV2MaintenanceEvidenceProvider
    private let journals: URL
    private let receipts: URL
    private let core = RuntimeV2OptimizationWorker("floe.legacy-image-sparse.core", allowsSynchronousFence: true)
    private let metadata = RuntimeV2OptimizationWorker("floe.legacy-image-sparse.receipts")

    init(domain: RuntimeV2MaintenanceDomain, coordinator: RuntimeV2MaintenanceCoordinator,
         closureAuthority: RuntimeV2RecoveryClosureAuthority,
         admittedEvidence: @escaping RuntimeV2MaintenanceEvidenceProvider) {
        self.domain = domain; self.coordinator = coordinator
        self.closureAuthority = closureAuthority; self.admittedEvidence = admittedEvidence
        journals = coordinator.stateDirectory.appendingPathComponent("image-sparse-journals", isDirectory: true)
        receipts = coordinator.stateDirectory.appendingPathComponent("image-sparse-receipts", isDirectory: true)
    }

    static func owns(_ intent: RuntimeV2MaintenanceIntentRecord) -> Bool {
        intent.owner == owner && intent.reason == reason
    }

    func inventory() async throws -> RuntimeV2MigrationSparseInventoryReport {
        try await RuntimeV2MigrationSparseInventory.scan(domain: domain)
    }

    func optimize(_ input: RuntimeV2MigrationSparseRecord, cancellation: RuntimeV2OptimizationCancellation,
                  progress: (@Sendable (StorageSparseDiskRewriteProgress) -> Void)?)
        async -> RuntimeV2RecoveryOptimizationResult {
        let record: RuntimeV2MigrationSparseRecord
        do {
            let current = try await RuntimeV2MigrationSparseInventory.refresh(domain: domain, record: input)
            guard current.source.matchesFully(input.source),
                  try current.preservationFingerprint() == input.preservationFingerprint() else {
                throw RuntimeV2MaintenanceError.targetIdentityMismatch("migration candidate changed before admission")
            }
            // Each job binds CURRENT peer identities before taking EX. A prior
            // successfully committed sibling is not silently rewritten or
            // treated as the old inode; it is protected for this new job.
            record = current
        } catch {
            return .init(report: nil, code: RuntimeV2RecoveryOptimizationAdapter.code(error), recoveryPending: false,
                diagnosticCodes: RuntimeV2RecoveryOptimizationAdapter.diagnosticCodes(error))
        }
        guard RuntimeV2MigrationSparseCatalog.target(record.target.relativePath) == record.target else {
            return .init(report: nil, code: "source-not-eligible", recoveryPending: false)
        }
        if cancellation.isCancelled { return .init(report: nil, code: "cancelled", recoveryPending: false) }
        let root = domain.root, relative = record.target.relativePath
        let claim: RuntimeV2MaintenanceClaim
        do {
            let inspected = try await core.run {
                try StorageSparseDiskRewrite.inspectSource(rootURL: root, relativePath: relative)
            }
            guard inspected.identity.matchesFully(record.source),
                  domain.matchesRecordedRoot(record.rootPath, device: record.rootDevice, inode: record.rootInode) else {
                throw RuntimeV2MaintenanceError.targetIdentityMismatch("migration preflight changed")
            }
            guard inspected.volumeAvailableBytes >= 64 * 1_024 * 1_024 else {
                throw StorageSparseDiskRewriteError.insufficientSpace(required: 64 * 1_024 * 1_024,
                    available: inspected.volumeAvailableBytes, phase: "migration-preflight")
            }
            claim = try await coordinator.acquireExclusiveMaintenance(.init(owner: Self.owner, reason: Self.reason,
                targetRelativePath: relative, targetIdentity: RuntimeV2RecoveryOptimizationAdapter.runtimeIdentity(record.source)))
        } catch {
            return .init(report: nil, code: RuntimeV2RecoveryOptimizationAdapter.code(error),
                recoveryPending: RuntimeV2RecoveryOptimizationAdapter.code(error) == "recovery-pending",
                diagnosticCodes: RuntimeV2RecoveryOptimizationAdapter.diagnosticCodes(error))
        }
        do {
            let preservation = try record.preservationFingerprint()
            try await validate(claim: claim, record: record, preservation: preservation)
            try claim.validateTargetIdentity()
            let closed = try await closureAuthority.currentReceipt(intentID: claim.intentID)
            guard !closed.isConvergenceProof,
                  let coreGeneration = Int64(exactly: claim.holdGeneration), coreGeneration > 0 else {
                throw RuntimeV2MaintenanceError.claimInvalidated("migration requires fresh exclusive closure")
            }
            switch try await completed(record: record, preservation: preservation, closure: closed) {
            case .verified(let previous):
                try await validate(claim: claim, record: record, preservation: preservation)
                try claim.validateTargetIdentity()
                let current = try await metadata.run {
                    RuntimeV2RecoveryOptimizationAdapter.matchesCommittedSource(previous, root: root,
                        expected: record.source, rootDevice: closed.rootDevice, rootInode: closed.rootInode)
                }
                try await claim.abortAndRelease(reason: "completed migration sparse proof checked; no mutation")
                if current {
                    return .init(report: nil, code: "already-optimized", recoveryPending: false, verifiedUnchanged: true)
                }
                return .init(report: nil, code: "needs-inspection", recoveryPending: false)
            case .retainedUnverified:
                try await claim.abortAndRelease(reason: "historical migration success retained; current proof unverified")
                return .init(report: nil, code: "needs-inspection", recoveryPending: false)
            case .none:
                break
            }
            let receipt = RuntimeV2MigrationSparseReceipt(schema: 1, producer: "FloeMigrationSparse/1",
                intentID: claim.intentID, authorityGeneration: claim.holdGeneration,
                coreHoldGeneration: coreGeneration, domainKey: domain.domainKey, record: record,
                preservationFingerprint: preservation, closure: closed)
            let receipts = receipts, journals = journals
            try await metadata.run {
                try RuntimeV2OptimizationJournalIO.writeOnce(receipt, directory: receipts, name: receipt.intentID + ".json")
                try FileManager.default.createDirectory(at: journals, withIntermediateDirectories: true)
            }
            try await claim.markCommitting()
            let fence = StorageSparseDiskMaintenanceFence(leaseID: claim.intentID, generation: claim.holdGeneration) { [self] in
                try RuntimeV2OptimizationAsyncFence.check {
                    try await self.validate(claim: claim, record: record, preservation: preservation)
                }
            }
            let request = StorageSparseDiskRewriteRequest(rootURL: root, relativePath: relative,
                expectedSource: record.source, journalDirectoryURL: journals, jobID: claim.intentID,
                maintenanceLeaseID: claim.intentID, holdGeneration: coreGeneration, jobGeneration: claim.holdGeneration,
                mode: .cloneAndPunch, minimumReclaimBytes: 1, allowSparseCopyFallback: false)
            let report = try await core.run {
                try StorageSparseDiskRewrite.rewrite(request, fence: fence,
                    isCancelled: { cancellation.isCancelled }, progress: progress)
            }
            guard report.stageRetired, report.sourceDigestSHA512 == report.stageDigestSHA512,
                  report.modeUsed == .cloneAndPunch, report.fallbackReason == nil else {
                throw StorageSparseDiskRewriteError.needsInspection("migration helper is nonterminal")
            }
            try await validate(claim: claim, record: record, preservation: preservation)
            _ = try await claim.recordTargetIdentityAfterCommit()
            try await validate(claim: claim, record: record, preservation: preservation)
            try await claim.commitAndRelease()
            return .init(report: report, code: "optimized", recoveryPending: false)
        } catch {
            let code = RuntimeV2RecoveryOptimizationAdapter.code(error)
            await claim.handoffToRecovery()
            let resolution = await coordinator.recoverIfNeeded()
            let pending = resolution.outcome == .blocked
            var verifiedUnchanged = false
            if !pending, code == "insufficient-reclaim",
               let header = try? await header(jobID: claim.intentID), header.phase == "aborted",
               header.source.matchesFully(record.source),
               let digest = header.sourceDigestSHA512, RuntimeV2RecoveryOptimizationAdapter.isSHA512(digest),
               digest == header.stageDigestSHA512,
               header.jobID == claim.intentID, header.maintenanceLeaseID == claim.intentID,
               header.jobGeneration == claim.holdGeneration {
                verifiedUnchanged = true
            }
            return .init(report: nil, code: pending ? "recovery-pending" : code,
                recoveryPending: pending, verifiedUnchanged: verifiedUnchanged,
                diagnosticCodes: RuntimeV2RecoveryOptimizationAdapter.diagnosticCodes(error))
        }
    }

    private func header(jobID: String, storageDirectory: URL? = nil) async throws -> RuntimeV2OptimizationCoreJournalBinding? {
        let journals = storageDirectory?.appendingPathComponent("image-sparse-journals", isDirectory: true) ?? journals
        return try await metadata.run {
            try RuntimeV2OptimizationJournalIO.read(RuntimeV2OptimizationCoreJournalBinding.self,
                directory: journals, name: jobID + ".json")
        }
    }
    private func boundStage(jobID: String, generation: UInt64, record: RuntimeV2MigrationSparseRecord,
                            storageDirectory: URL? = nil) async throws -> String? {
        guard let header = try await header(jobID: jobID, storageDirectory: storageDirectory) else { return nil }
        guard header.schemaVersion == 2, header.jobID == jobID, header.maintenanceLeaseID == jobID,
              header.jobGeneration == generation, header.holdGeneration == Int64(exactly: generation),
              header.relativePath == record.target.relativePath, header.source.matchesFully(record.source),
              RuntimeV2RecoveryOptimizationAdapter.matchesPhysicalRoot(header.rootPath, root: domain.root,
                  device: record.rootDevice, inode: record.rootInode) else {
            throw RuntimeV2MaintenanceError.targetIdentityMismatch("migration Core journal changed")
        }
        guard let name = header.stageName, name.hasPrefix("."), name != ".", name != "..",
              !name.contains("/"), !name.utf8.contains(0), name.utf8.count <= 255 else {
            throw RuntimeV2MaintenanceError.targetIdentityMismatch("migration Core stage unbound")
        }
        return name
    }

    private func validate(claim: RuntimeV2MaintenanceClaim, record: RuntimeV2MigrationSparseRecord,
                          preservation: String) async throws {
        try await claim.validate()
        let before = await admittedEvidence()
        guard before.isComplete, before.quiescenceBlockers(domain: domain).isEmpty else {
            throw RuntimeV2MaintenanceError.ownerEvidenceIncomplete(["fresh_owner_evidence_unavailable"])
        }
        try claim.validateReferenceFingerprint(before.references.fingerprint)
        _ = try await closureAuthority.currentReceipt(intentID: claim.intentID)
        let stage = try await boundStage(jobID: claim.intentID, generation: claim.holdGeneration, record: record)
        try await preservationMatches(record, fingerprint: preservation, stage: stage)
        let after = await admittedEvidence()
        guard after.isComplete, after.quiescenceBlockers(domain: domain).isEmpty else {
            throw RuntimeV2MaintenanceError.ownerEvidenceIncomplete(["fresh_owner_evidence_unavailable"])
        }
        try claim.validateReferenceFingerprint(after.references.fingerprint)
        try await claim.validate()
    }
    private func preservationMatches(_ record: RuntimeV2MigrationSparseRecord, fingerprint: String,
                                     stage: String?) async throws {
        let current = try await RuntimeV2MigrationSparseInventory.refresh(domain: domain, record: record,
                                                                         excludingStage: stage)
        guard domain.matchesRecordedRoot(record.rootPath, device: record.rootDevice, inode: record.rootInode),
              try current.preservationFingerprint() == fingerprint, current.peerDisks == record.peerDisks else {
            throw RuntimeV2MaintenanceError.targetIdentityMismatch("migration binding or preserved metadata changed")
        }
    }

    func recover(_ intent: RuntimeV2MaintenanceIntentRecord) async -> RuntimeV2MaintenanceRecoveryOutcome {
        do {
            guard Self.owns(intent), let relative = intent.targetRelativePath,
                  RuntimeV2MigrationSparseCatalog.target(relative) != nil,
                  let rootDevice = intent.domainDevice, let rootInode = intent.domainInode,
                  domain.matchesRecordedRoot(intent.domainRoot, device: rootDevice, inode: rootInode) else {
                return .unresolved("not an exact image-migration sparse intent")
            }
            try await coordinator.validateRecoverySession(intentID: intent.intentID, holdGeneration: intent.holdGeneration)
            try await closureAuthority.beginRecovery(coordinator: coordinator, intentID: intent.intentID,
                                                      generation: intent.holdGeneration)
            let evidence = await admittedEvidence()
            guard evidence.isComplete,
                  RuntimeV2RecoveryClosureAuthority.convergenceBlockers(evidence, domain: domain).isEmpty else {
                return .unresolved("fresh migration closure unavailable")
            }
            let recoveryDirectory = try await coordinator.recoveryStorageDirectory(
                intentID: intent.intentID, holdGeneration: intent.holdGeneration)
            let receipts = recoveryDirectory.appendingPathComponent("image-sparse-receipts", isDirectory: true)
            let saved = try await metadata.run {
                try RuntimeV2OptimizationJournalIO.read(RuntimeV2MigrationSparseReceipt.self,
                    directory: receipts, name: intent.intentID + ".json")
            }
            let head = try await header(jobID: intent.intentID, storageDirectory: recoveryDirectory)
            guard let saved else {
                guard head == nil, let expected = intent.targetIdentity,
                      try RuntimeV2DiskIdentity.read(at: domain.root.appendingPathComponent(relative)) == expected else {
                    return .unresolved("missing migration receipt with ambiguous source")
                }
                return .resolved
            }
            guard Self.valid(saved), saved.intentID == intent.intentID,
                  saved.authorityGeneration == intent.holdGeneration,
                  saved.record.target.relativePath == relative,
                  saved.record.rootDevice == rootDevice, saved.record.rootInode == rootInode,
                  saved.closure.rootDevice == rootDevice, saved.closure.rootInode == rootInode else {
                return .unresolved("migration receipt identity/generation mismatch")
            }
            let stage = try await boundStage(jobID: intent.intentID, generation: intent.holdGeneration,
                record: saved.record, storageDirectory: recoveryDirectory)
            try await preservationMatches(saved.record, fingerprint: saved.preservationFingerprint, stage: stage)
            guard let head else {
                let original = try StorageSparseDiskRewrite.inspectSource(rootURL: domain.root, relativePath: relative)
                return original.identity.matchesFully(saved.record.source)
                    ? .resolved : .unresolved("migration original inode changed before Core")
            }
            let fingerprint = evidence.references.fingerprint
            let fence = StorageSparseDiskMaintenanceFence(leaseID: intent.intentID, generation: intent.holdGeneration) { [self] in
                try RuntimeV2OptimizationAsyncFence.check {
                    try await self.coordinator.validateRecoverySession(intentID: intent.intentID,
                                                                         holdGeneration: intent.holdGeneration)
                    let before = await self.admittedEvidence()
                    guard before.isComplete,
                          RuntimeV2RecoveryClosureAuthority.convergenceBlockers(before, domain: self.domain).isEmpty,
                          before.references.fingerprint == fingerprint else {
                        throw RuntimeV2MaintenanceError.claimInvalidated("migration recovery reference generation changed")
                    }
                    let stage = try await self.boundStage(jobID: intent.intentID,
                        generation: intent.holdGeneration, record: saved.record, storageDirectory: recoveryDirectory)
                    try await self.preservationMatches(saved.record, fingerprint: saved.preservationFingerprint, stage: stage)
                    let after = await self.admittedEvidence()
                    guard after.isComplete,
                          RuntimeV2RecoveryClosureAuthority.convergenceBlockers(after, domain: self.domain).isEmpty,
                          after.references.fingerprint == fingerprint else {
                        throw RuntimeV2MaintenanceError.claimInvalidated("migration recovery references changed after metadata")
                    }
                    try await self.coordinator.validateRecoverySession(intentID: intent.intentID,
                                                                         holdGeneration: intent.holdGeneration)
                }
            }
            let root = domain.root
            let journals = recoveryDirectory.appendingPathComponent("image-sparse-journals", isDirectory: true)
            let rootBinding = StorageSparseDiskRecoveryRootBinding(recordedRootPath: head.rootPath,
                                                                   device: rootDevice, inode: rootInode)
            let result = try await core.run {
                try StorageSparseDiskRewrite.recover(rootURL: root, relativePath: relative,
                    journalDirectoryURL: journals, jobID: intent.intentID, fence: fence,
                    recordedRootBinding: rootBinding, isCancelled: { false })
            }
            guard result.sourceIdentityVerified, result.resolution != .needsInspection,
                  result.resolution != .noJournal else { return .unresolved("migration Core recovery retained evidence") }
            try await coordinator.validateRecoverySession(intentID: intent.intentID, holdGeneration: intent.holdGeneration)
            return .resolved
        } catch { return .unresolved("migration sparse recovery requires inspection: " + RuntimeV2RecoveryOptimizationAdapter.code(error)) }
    }

    private static func valid(_ receipt: RuntimeV2MigrationSparseReceipt) -> Bool {
        guard let fingerprint = try? receipt.record.preservationFingerprint(),
              fingerprint == receipt.preservationFingerprint else { return false }
        return receipt.schema == 1 && receipt.producer == "FloeMigrationSparse/1"
            && RuntimeV2MigrationSparseCatalog.target(receipt.record.target.relativePath) == receipt.record.target
            && RuntimeV2RecoveryOptimizationAdapter.isDomainKey(receipt.domainKey)
            && receipt.domainKey == receipt.closure.domainKey && receipt.closure.version == 1
            && !receipt.closure.isConvergenceProof && receipt.closure.intentID == receipt.intentID
            && receipt.closure.holdGeneration == receipt.authorityGeneration
            && Int64(exactly: receipt.authorityGeneration) == receipt.coreHoldGeneration
            && receipt.record.rootDevice == receipt.closure.rootDevice && receipt.record.rootInode == receipt.closure.rootInode
    }

    private func completed(record: RuntimeV2MigrationSparseRecord, preservation: String,
                           closure: RuntimeV2RecoveryClosedReceipt)
        async throws -> RuntimeV2MigrationCompletedHistoryDecision {
        let contexts = try await coordinator.completedStorageDirectories(
            intentID: closure.intentID, holdGeneration: closure.holdGeneration)
        let domain = domain
        return try await metadata.run {
            var retiredTargetSeen = false
            var verified: [RuntimeV2OptimizationCoreJournalBinding] = []
            var totalReceipts = 0
            for context in contexts {
                let receipts = context.appendingPathComponent("image-sparse-receipts", isDirectory: true)
                let journals = context.appendingPathComponent("image-sparse-journals", isDirectory: true)
                for name in try RuntimeV2RecoveryOptimizationAdapter.completedReceiptNames(directory: receipts) {
                    totalReceipts += 1
                    guard totalReceipts <= 512 else { throw StorageSparseDiskRewriteError.needsInspection("all-history-image-receipt-budget") }
                    guard let saved = try RuntimeV2OptimizationJournalIO.read(RuntimeV2MigrationSparseReceipt.self,
                        directory: receipts, name: name), Self.valid(saved),
                          saved.intentID + ".json" == name, saved.record.target == record.target,
                          RuntimeV2RecoveryOptimizationAdapter.isDomainKey(saved.domainKey),
                          saved.domainKey == saved.closure.domainKey, saved.closure.version == 1,
                          !saved.closure.isConvergenceProof, saved.closure.intentID == saved.intentID,
                          saved.closure.holdGeneration == saved.authorityGeneration,
                          saved.closure.rootDevice == closure.rootDevice, saved.closure.rootInode == closure.rootInode,
                          let header = try RuntimeV2OptimizationJournalIO.read(RuntimeV2OptimizationCoreJournalBinding.self,
                            directory: journals, name: name), header.schemaVersion == 2,
                          header.jobID == saved.intentID, header.maintenanceLeaseID == saved.intentID,
                          header.jobGeneration == saved.authorityGeneration, header.holdGeneration == saved.coreHoldGeneration,
                          header.source.matchesFully(saved.record.source), header.relativePath == record.target.relativePath,
                          header.phase == "retired", header.stageRetired == true, header.stageRetained == false,
                          header.requestedMode == .cloneAndPunch, header.modeUsed == .cloneAndPunch, header.fallbackReason == nil,
                          let digest = header.sourceDigestSHA512, RuntimeV2RecoveryOptimizationAdapter.isSHA512(digest),
                          digest == header.stageDigestSHA512,
                          let metadataFingerprint = header.metadataFingerprint,
                          RuntimeV2RecoveryOptimizationAdapter.isSHA512(metadataFingerprint),
                          RuntimeV2RecoveryOptimizationAdapter.matchesPhysicalRoot(header.rootPath, root: domain.root,
                            device: closure.rootDevice, inode: closure.rootInode) else { continue }
                    // Classification for retention only: complete identity and
                    // preserved metadata remain mandatory for verified reuse.
                    if let old = header.postSwapSource,
                       old.device == record.source.device, old.inode == record.source.inode,
                       old.sizeBytes == record.source.sizeBytes,
                       old.modificationSeconds == record.source.modificationSeconds,
                       old.modificationNanoseconds == record.source.modificationNanoseconds {
                        retiredTargetSeen = true
                    }
                    guard saved.preservationFingerprint == preservation,
                          header.postSwapSource?.matchesFully(record.source) == true,
                          RuntimeV2RecoveryOptimizationAdapter.matchesCommittedSource(header, root: domain.root,
                            expected: record.source, rootDevice: closure.rootDevice, rootInode: closure.rootInode) else { continue }
                    verified.append(header)
                }
            }
            if verified.count == 1 { return .verified(verified[0]) }
            if retiredTargetSeen { return .retainedUnverified }
            return .none
        }
    }

}
