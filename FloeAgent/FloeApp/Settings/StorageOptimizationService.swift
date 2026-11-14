// App lifetime owns start/cancel/result; a View never owns or cancels this task.
import Foundation

/// A tap during launch recovery is a single, process-local request. Merely
/// launching the App never grants permission to start a new optimization.
struct StorageOptimizationLaunchGate: Sendable {
    private(set) var recoveryActive = false
    private(set) var queued = false

    mutating func beginRecovery() { recoveryActive = true; queued = false }
    @discardableResult
    mutating func queueTap(operationActive: Bool, cancellationRequested: Bool) -> Bool {
        guard recoveryActive, operationActive, !queued, !cancellationRequested else { return false }
        queued = true
        return true
    }
    mutating func cancelQueuedTap() { queued = false }
    /// Consumes the tap once. A blocked or cancelled recovery cannot start an
    /// inventory, and no later callback can replay the same tap.
    mutating func completeRecovery(unblocked: Bool, cancelled: Bool) -> Bool {
        let continueRequested = queued && unblocked && !cancelled
        recoveryActive = false; queued = false
        return continueRequested
    }
}

/// Only an actual verified result or one of the adapter's narrowly classified
/// per-disk no-write outcomes permits trying another independent candidate.
/// Shared admission, root, busy, recovery-pending and unknown failures stop.
struct StorageOptimizationBatchGate {
    static func mayContinue(verified: Bool, retainedAndReleased: Bool, preclaimIneligible: Bool,
                            recoveryPending: Bool, cancelled: Bool) -> Bool {
        !recoveryPending && !cancelled && (verified || retainedAndReleased || preclaimIneligible)
    }
}

#if canImport(SwiftUI) && canImport(UIKit)
import Combine
import FloeCore
import FloeExecution

/// Closed diagnostic vocabulary only. Attributed owner suffixes are removed;
/// unknown strings are counted, never persisted or exported as text.
enum StorageOptimizationDiagnosticVocabulary {
    static let resultCodes: Set<String> = [
        "already-optimized", "busy", "cancelled", "cancelled-after-swap",
        "clone-unavailable", "compressed-source", "crash-injected",
        "directory-open-failed", "empty-source", "fsync-failed",
        "hard-linked", "identity-changed", "immutable-source",
        "injected-failure", "insufficient-reclaim", "insufficient-space",
        "invalid-request", "journal-conflict", "journal-corrupt",
        "journal-exists", "journal-open-failed", "journal-write-failed",
        "maintenance-unavailable", "metadata-failed", "metadata-unavailable",
        "metadata-verification-failed", "needs-inspection", "not-regular-file",
        "optimization-stopped", "optimized", "oversized-source",
        "owner-unknown", "punch-failed", "punch-unsupported",
        "read-failed", "recovery-pending", "recovery-required",
        "source-changed", "source-identity-mismatch", "source-not-eligible",
        "source-open-failed", "stage-create-failed", "stage-exists",
        "stage-identity-mismatch", "swap-unsupported", "symbolic-link",
        "truncate-failed", "unsupported-mode", "unsupported-platform",
        "verification-failed", "write-failed", "xattr-limit-exceeded"
    ]
    static let ownerCodes: Set<String> = [
        "closure_native_admission_not_exclusive", "closure_sources_incomplete", "coordinator_unavailable",
        "fd_audit_time_budget", "fd_audit_unsupported", "fd_flags_unknown",
        "fd_identity_unknown", "fd_instance_changed", "fd_path_unknown",
        "fd_table_bound_unknown", "filesystem_evidence_incomplete", "filesystem_lease_registry_unmeasured",
        "filesystem_lease_trace", "filesystem_runtime_trace", "fresh_owner_evidence_unavailable",
        "integrator_evidence_incomplete", "integrator_held_lease", "integrator_preparation_active",
        "integrator_provider_unavailable", "integrator_queued_admissions", "integrator_registry_lease",
        "integrator_scope_unknown", "legacy_lease_state_unknown", "legacy_native_fd_still_open",
        "legacy_queue_state_unknown", "legacy_readonly_connection_not_closed", "legacy_registry_bound_or_read_failed",
        "legacy_registry_field_unknown", "legacy_registry_identity_changed", "legacy_registry_identity_unknown",
        "legacy_registry_not_readonly", "legacy_registry_readonly_evidence_failed", "legacy_registry_readonly_open_failed",
        "legacy_registry_schema_unknown", "legacy_registry_shape_unknown", "legacy_registry_snapshot_failed",
        "legacy_registry_table_missing", "legacy_registry_table_unknown", "legacy_shm_identity_unknown",
        "legacy_shm_shape_unknown", "legacy_wal_identity_unknown", "legacy_wal_not_in_snapshot",
        "legacy_wal_shape_unknown", "native_closed_receipt_unavailable", "native_owner_close_unproven",
        "native_owner_sources_changed", "owner_evidence_incomplete",
        "migration_binding_unknown", "migration_preservation_unavailable", "migration_metadata_bound",
        "migration_manifest_unknown", "migration_target_unknown", "migration_metadata_unknown",
        "migration_inventory_unavailable", "reference-projection-changed",
        "reference_active_environment", "reference_active_unattributed", "reference_fingerprint_missing",
        "reference_live_unknown_unattributed", "reference_projection_incomplete", "reference_projection_threw",
        "reference_projection_unavailable", "reference_unknown_environment", "registry_evidence_incomplete",
        "registry_lifecycle_lock", "registry_lifecycle_transaction", "registry_owner_state_unknown",
        "registry_pending_stop", "registry_provider_unavailable", "registry_quarantined",
        "registry_session", "registry_shared_start", "registry_starting",
        "registry_teardown", "selected_disk_fd_open", "startup_recovery_active"
    ]
    static let serviceCodes: Set<String> = [
        "inventory-incomplete", "sources-not-eligible", "no-covered-sources", "recovery-resolved", "recovery-not-needed",
        "retained-disk", "preclaim-ineligible"
    ]
    static let stages: Set<String> = [
        "recovery-check", "inventory", "disk-admission", "counting", "staging", "verifying", "committing", "retiring"
    ]
    static func code(_ raw: String) -> String? {
        let head = String(raw.split(separator: ":", maxSplits: 1).first ?? "")
        return resultCodes.contains(head) || ownerCodes.contains(head) || serviceCodes.contains(head) ? head : nil
    }
}

private enum StorageOptimizationCandidate: Sendable {
    case repair(LegacyRecoveryInventoryRecord)
    case migration(RuntimeV2MigrationSparseRecord)
}

struct StorageOptimizationState: Codable, Sendable {
    enum Phase: String, Codable, Sendable {
        case idle, checking, optimizing, cancelling, completed, cancelled, blocked, unavailable
    }
    var phase: Phase = .idle
    var total = 0
    var attempted = 0
    var optimized = 0
    var skipped = 0
    var corePhase: String?
    var fraction: Double?
    /// Actual before/after fstatfs observation, not the sum of inode savings.
    var observedHostFreeDelta: Int64?
    /// Non-additive file allocation metric; only shown in opened details.
    var fileAllocationReduction: Int64 = 0
    var details: [String: Int] = [:]
    var startedAt: Date?
    var finishedAt: Date?
    var appBuildFingerprint: String?
    var inventoryEvidence: StorageOptimizationInventoryEvidence?
    // Optional additions keep receipts written before this change readable.
    var lastStage: String?
    var lastStageObservedAt: Date?
    var lastProcessedBytes: Int64?
    var lastTotalBytes: Int64?
    var lastResultCode: String?
    var verifiedNoGainCount: Int?
    var coveredSourceCount: Int?
    var eligibleSourceCount: Int?
    var unrecognizedDiagnosticCodeCount: Int?
    var migrationRecordCount: Int?
    var migrationBlockedCount: Int?
    /// Closed per-candidate scope; older operation receipts simply omit it.
    var lastCandidateDisposition: String?

    enum TerminalDisposition: String {
        case notCovered, eligibilityBlocked, methodUnavailable, verifiedNoGain, recoveryPending, recovered
        case busy, stopped, optimized, retained, partiallyOptimized
    }

    var safeDetails: [String: Int] {
        var result: [String: Int] = [:]
        for (raw, value) in details {
            guard let code = StorageOptimizationDiagnosticVocabulary.code(raw), value > 0 else { continue }
            result[code] = min(1_000_000, (result[code] ?? 0) + min(1_000_000, value))
        }
        return result
    }
    var terminalDisposition: TerminalDisposition? {
        guard phase == .completed || phase == .blocked else { return nil }
        let codes = Set(safeDetails.keys)
        let retained = retainedCandidateCount
        if lastResultCode == "recovery-resolved" { return .recovered }
        if !codes.isDisjoint(with: ["recovery-pending", "recovery-required"])
            || (phase == .blocked && lastResultCode == "needs-inspection"
                && lastCandidateDisposition != "retained-and-released") { return .recoveryPending }
        if optimized > 0 && (retained > 0 || phase == .blocked) { return .partiallyOptimized }
        if codes.contains("busy") { return .busy }
        if !codes.isDisjoint(with: ["unsupported-platform", "unsupported-mode", "clone-unavailable", "punch-unsupported", "swap-unsupported"]) { return .methodUnavailable }
        if coveredSourceCount == 0, attempted == 0 { return .notCovered }
        if phase == .blocked {
            return !codes.isDisjoint(with: ["inventory-incomplete", "sources-not-eligible", "source-not-eligible", "owner-unknown",
                "migration_inventory_unavailable", "migration_binding_unknown", "migration_preservation_unavailable"])
                ? .eligibilityBlocked : .stopped
        }
        if attempted > 0, optimized == 0, retained > 0,
           attempted == retained + max(0, verifiedNoGainCount ?? 0) { return .retained }
        if attempted > 0, optimized == 0, verifiedNoGainCount == attempted { return .verifiedNoGain }
        let alreadyVerified = safeDetails["already-optimized"] ?? 0
        let completed = min(1_000_000, max(0, optimized)) + alreadyVerified
        if completed > 0, attempted >= completed + retained,
           attempted - completed - retained == max(0, verifiedNoGainCount ?? 0) { return .optimized }
        return .stopped
    }
    var retainedCandidateCount: Int {
        min(1_000_000, (safeDetails["retained-disk"] ?? 0) + (safeDetails["preclaim-ineligible"] ?? 0))
    }
    var terminalNotice: String? {
        switch terminalDisposition {
        case .notCovered:
            return FloeL10n.isChinese ? "此入口未发现可整理的历史磁盘，其他资料未改动。" : "This tool found no historical disks it can optimize. Other data was left unchanged."
        case .eligibilityBlocked:
            return FloeL10n.isChinese ? "历史资料仍需核对，尚未优化。请上传反馈日志。" : "Historical data needs further checks before optimization. Send a diagnostic report."
        case .methodUnavailable:
            return FloeL10n.isChinese ? "当前无法使用所需的无损整理方式，资料已保留。请上传反馈日志。" : "The required lossless optimization method is unavailable. Data was kept; send a diagnostic report."
        case .verifiedNoGain:
            return FloeL10n.isChinese ? "已核对这些磁盘，未发现可无损缩减的空间。资料已保留。" : "These disks were verified, with no space that could be reduced losslessly. Data was kept."
        case .recoveryPending:
            return FloeL10n.isChinese ? "有未完成的整理需要恢复，资料已保留。请稍后重试；若仍失败，请上传反馈日志。" : "An unfinished optimization needs recovery. Data was kept. Try again later; if it persists, send a diagnostic report."
        case .recovered:
            return FloeL10n.isChinese ? "上次中断的整理已恢复，资料已保留。可再次整理以继续检查。" : "The interrupted optimization was recovered and data was kept. Start again to continue checking."
        case .retained:
            return FloeL10n.isChinese ? "已检查 \(attempted) 项；资料均已保留，尚未整理磁盘。" : "Checked \(attempted) items. Data was kept; no disks were optimized."
        case .partiallyOptimized:
            return phase == .blocked
                ? (FloeL10n.isChinese ? "已整理 \(optimized) 项；其余未完成，资料已保留。" : "Optimized \(optimized) items. The rest could not finish; data was kept.")
                : (FloeL10n.isChinese ? "已整理 \(optimized) 项，保留 \(skipped) 项。" : "Optimized \(optimized) items; kept \(skipped) unchanged.")
        case .busy:
            return FloeL10n.isChinese ? "环境仍在使用，尚未优化。请结束相关运行后重试。" : "The environment is still in use. End the related activity, then try again."
        case .stopped:
            return FloeL10n.isChinese ? "本次整理未完成或结果详情未记录，资料已保留。请上传反馈日志。" : "Optimization did not finish or its detailed result was not recorded. Data was kept; send a diagnostic report."
        case .optimized, .none: return nil
        }
    }
    mutating func recordDiagnostic(_ raw: String) {
        guard let code = StorageOptimizationDiagnosticVocabulary.code(raw) else {
            unrecognizedDiagnosticCodeCount = min(1_000_000, max(0, min(1_000_000, unrecognizedDiagnosticCodeCount ?? 0)) + 1)
            return
        }
        details[code] = min(1_000_000, max(0, min(1_000_000, details[code] ?? 0)) + 1)
    }
    mutating func recordResult(code: String, diagnosticCodes: [String] = [], verifiedUnchanged: Bool = false) {
        lastResultCode = StorageOptimizationDiagnosticVocabulary.code(code)
        lastCandidateDisposition = nil
        recordDiagnostic(code)
        for code in diagnosticCodes.prefix(32) { recordDiagnostic(code) }
        // Only the adapter's full verification + converged unchanged receipt
        // establishes no gain. The error string alone never does.
        if code == "insufficient-reclaim", verifiedUnchanged {
            verifiedNoGainCount = min(1_000_000, max(0, min(1_000_000, verifiedNoGainCount ?? 0)) + 1)
        }
    }
    mutating func recordCandidateDisposition(_ disposition: RuntimeV2RecoveryOptimizationResult.CandidateDisposition) {
        switch disposition {
        case .ordinary:
            lastCandidateDisposition = "ordinary"
        case .retainedAndReleased:
            lastCandidateDisposition = "retained-and-released"
            recordDiagnostic("retained-disk")
        case .preclaimIneligible:
            lastCandidateDisposition = "preclaim-ineligible"
            recordDiagnostic("preclaim-ineligible")
        }
    }
    @discardableResult
    mutating func recordStage(_ stage: String, processed: Int64? = nil, total: Int64? = nil) -> Bool {
        guard StorageOptimizationDiagnosticVocabulary.stages.contains(stage) else { return false }
        let changed = lastStage != stage
        lastStage = stage; lastStageObservedAt = Date()
        if processed == nil, total == nil { lastProcessedBytes = nil; lastTotalBytes = nil }
        if let total { lastTotalBytes = max(0, total) }
        if let processed { lastProcessedBytes = min(max(0, processed), lastTotalBytes ?? Int64.max) }
        return changed
    }
    func sanitizedDiagnostics() -> Self {
        var copy = self
        let unknown = details.keys.filter { StorageOptimizationDiagnosticVocabulary.code($0) == nil }.count
        copy.details = safeDetails
        copy.unrecognizedDiagnosticCodeCount = min(1_000_000, max(0, min(1_000_000, unrecognizedDiagnosticCodeCount ?? 0)) + min(1_000_000, unknown))
        copy.lastResultCode = lastResultCode.flatMap(StorageOptimizationDiagnosticVocabulary.code)
        if let lastStage, !StorageOptimizationDiagnosticVocabulary.stages.contains(lastStage) { copy.lastStage = nil }
        copy.verifiedNoGainCount = verifiedNoGainCount.map { max(0, min(1_000_000, $0)) }
        copy.coveredSourceCount = coveredSourceCount.map { max(0, min(1_000_000, $0)) }
        copy.eligibleSourceCount = eligibleSourceCount.map { max(0, min(1_000_000, $0)) }
        copy.migrationRecordCount = migrationRecordCount.map { max(0, min(6, $0)) }
        copy.migrationBlockedCount = migrationBlockedCount.map { max(0, min(6, $0)) }
        if let lastCandidateDisposition,
           !["ordinary", "retained-and-released", "preclaim-ineligible"].contains(lastCandidateDisposition) {
            copy.lastCandidateDisposition = nil
        }
        if let value = lastProcessedBytes { copy.lastProcessedBytes = max(0, min(value, lastTotalBytes.map { max(0, $0) } ?? Int64.max)) }
        if let value = lastTotalBytes { copy.lastTotalBytes = max(0, value) }
        return copy
    }

    /// Capture only fixed vocabulary and aggregates. A partial inventory is
    /// useful fault evidence, never permission to optimize any of its entries.
    mutating func admitInventory(_ report: LegacyRecoveryInventoryReport,
                                 cancellationRequested: Bool) -> Bool {
        inventoryEvidence = StorageOptimizationInventoryEvidence(report)
        if cancellationRequested || report.stopReasons.contains("cancelled") {
            details["cancelled", default: 0] += 1
            phase = .cancelled
            return false
        }
        guard !report.summary.isPartial, report.rootIdentity != nil else {
            details["inventory-incomplete", default: 0] += 1
            phase = .blocked
            return false
        }
        return true
    }

    var inventoryNotice: String? {
        guard phase == .blocked, let inventoryEvidence else { return nil }
        if inventoryEvidence.stopReasons.contains("rootChangedDuringScan") {
            return FloeL10n.isChinese
                ? "环境正在变化，尚未优化。请等待环境准备完成后重试。"
                : "The environment changed during checking. Wait for preparation to finish, then try again."
        }
        guard inventoryEvidence.isPartial || !inventoryEvidence.rootAvailable else { return nil }
        return FloeL10n.isChinese
            ? "暂未完成环境清点，尚未优化。请稍后重试；若仍失败，请上传反馈日志。"
            : "The environment could not be fully checked, so optimization has not started. Try again later; if it keeps failing, send a diagnostic report."
    }
}

/// A bounded diagnostic receipt: no root/path, environment/runtime identity,
/// sidecar bytes or disk digest is retained. Error vocabulary comes from the
/// actual inventory, not a second scan or an inferred provenance diagnosis.
struct StorageOptimizationInventoryEvidence: Codable, Sendable {
    static let allowedStopReasons: Set<String> = ["unsupportedPlatform", "cancelled", "timeBudget", "entryBudget",
        "sidecarReadBudget", "sidecarByteBudget", "recordBudget", "rootUnavailable", "supportedParentUnavailable",
        "directoryReadFailed", "rootChangedDuringScan", "aggregateOverflow"]
    let capturedAt: Date
    let rootAvailable: Bool
    let isPartial: Bool
    let stopReasons: [String]
    let unrecognizedStopReasonCount: Int
    let rootDiagnostic: LegacyRecoveryRootDiagnostic?
    let directoryEntriesVisited: Int
    let sidecarReadsAttempted: Int
    let sidecarBytesRead: Int
    let diskContentBytesRead: Int
    let recordCount: Int
    let reviewableCount: Int
    let currentReferenceUnknownCount: Int
    let currentReferenceActiveCount: Int
    let planningBlockerCounts: [String: Int]

    init(_ report: LegacyRecoveryInventoryReport) {
        capturedAt = report.capturedAt; rootAvailable = report.rootIdentity != nil
        isPartial = report.summary.isPartial
        stopReasons = Array(Set(report.stopReasons.filter { Self.allowedStopReasons.contains($0) })).sorted()
        unrecognizedStopReasonCount = report.stopReasons.filter { !Self.allowedStopReasons.contains($0) }.count
        rootDiagnostic = report.rootDiagnostic
        directoryEntriesVisited = report.directoryEntriesVisited; sidecarReadsAttempted = report.sidecarReadsAttempted
        sidecarBytesRead = report.sidecarBytesRead; diskContentBytesRead = report.diskContentBytesRead
        recordCount = report.records.count; reviewableCount = report.summary.reviewableCount
        currentReferenceUnknownCount = report.summary.currentReferenceUnknownCount
        currentReferenceActiveCount = report.summary.currentReferenceActiveCount
        var counts: [String: Int] = [:]
        for record in report.records {
            for blocker in Set(record.planningBlockers) { counts[blocker.rawValue, default: 0] += 1 }
        }
        planningBlockerCounts = counts
    }
}

private final class StorageOptimizationProgressGate: @unchecked Sendable {
    private let lock = NSLock()
    private var last: TimeInterval = -.infinity
    private var phase: StorageSparseDiskRewriteProgress.Phase?
    func accepts(_ value: StorageSparseDiskRewriteProgress) -> Bool {
        lock.withLock {
            let now = ProcessInfo.processInfo.systemUptime
            guard phase != value.phase || now - last >= 0.25 || value.processedBytes == value.totalBytes else { return false }
            phase = value.phase; last = now; return true
        }
    }
}

@MainActor
final class StorageOptimizationService: ObservableObject {
    @Published private(set) var state = StorageOptimizationState()
    @Published private(set) var launchGate = StorageOptimizationLaunchGate()
    let bootstrapFailure: RuntimeV2MaintenanceBootstrapFailure?
    private let adapter: RuntimeV2RecoveryOptimizationAdapter?
    private let defaults: UserDefaults
    private let settled: @MainActor @Sendable () async -> Void
    let hasLegacyRecoveryTree: Bool
    private var operation: Task<Void, Never>?
    private var cancellation: RuntimeV2OptimizationCancellation?
    private var generation: UUID?
    private var recoveryProgressGeneration: UUID?
    private var lastDiagnosticPersistUptime: TimeInterval = 0
    private static let savedResultKey = "floe.storage.legacyOptimization.lastResult.v1"
    private static let launchRecoveryKey = "floe.storage.legacyOptimization.launchRecovery.v1"
    private static let bootstrapFailureKey = "floe.storage.legacyOptimization.bootstrapFailure.v1"
    private static let maximumSnapshotBytes = 16_384

    var isRunning: Bool { operation != nil }
    var canStart: Bool {
        adapter != nil && (!isRunning || (launchGate.recoveryActive && !launchGate.queued
                                         && cancellation?.isCancelled != true))
    }
    var canCancel: Bool { cancellation != nil && isRunning && state.phase != .cancelling }

    init(adapter: RuntimeV2RecoveryOptimizationAdapter?,
         bootstrapFailure: RuntimeV2MaintenanceBootstrapFailure? = nil, defaults: UserDefaults = .standard,
         settled: @escaping @MainActor @Sendable () async -> Void = {
             StorageDiagnosticService.shared.invalidate(.other("legacyRecoveryOptimization"))
             _ = await StorageDiagnosticService.shared.refresh(explicit: true)
         }) {
        self.adapter = adapter; self.defaults = defaults; self.settled = settled
        self.bootstrapFailure = adapter == nil ? bootstrapFailure : nil
        Self.persistBootstrapFailure(self.bootstrapFailure, to: defaults)
        self.hasLegacyRecoveryTree = RuntimeV2MaintenanceDomain.trustedLegacyRoot().map {
            FileManager.default.fileExists(atPath: $0.appendingPathComponent("recovery").path)
        } ?? false
        let previousOperation = Self.readSnapshot(from: defaults)
        defaults.removeObject(forKey: Self.launchRecoveryKey)
        guard let adapter else { state.phase = .unavailable; return }
        // Installs a REAL Core recovery handler on every process launch before
        // converging pending intent. No forever-nil recovery closure is shipped.
        let id = UUID(); generation = id
        let cancellation = RuntimeV2OptimizationCancellation()
        self.cancellation = cancellation
        launchGate.beginRecovery()
        state = StorageOptimizationState(phase: .checking, startedAt: Date(),
            appBuildFingerprint: StorageDiagnosticService.appBuildFingerprint())
        state.recordStage("recovery-check")
        persistLaunchRecovery()
        operation = Task { [weak self] in
            guard let self else { return }
            let report = await self.recover(adapter: adapter, cancellation: cancellation, generation: id)
            guard self.generation == id else { return }
            let continueAfterRecovery = self.launchGate.completeRecovery(
                unblocked: report.outcome != .blocked, cancelled: cancellation.isCancelled)
            if cancellation.isCancelled {
                self.state.phase = .cancelled
                self.state.recordResult(code: "cancelled")
                if report.outcome == .blocked { self.state.recordDiagnostic("recovery-pending") }
            } else if report.outcome == .blocked {
                self.state.phase = .blocked
                self.state.recordStage("recovery-check")
                self.state.recordResult(code: "recovery-pending")
            } else if report.outcome == .resolved {
                self.state.phase = .completed
                self.state.recordStage("recovery-check")
                self.state.recordResult(code: "recovery-resolved")
            } else {
                self.state.phase = .completed
                self.state.recordResult(code: "recovery-not-needed")
            }
            self.state.corePhase = nil; self.state.fraction = nil
            self.state.finishedAt = Date()
            self.persistLaunchRecovery()
            if continueAfterRecovery {
                // The same owned task and cancellation token continue into a
                // fresh operation receipt. The completed recovery result is
                // reused; no second long source digest or concurrent recovery.
                self.state = StorageOptimizationState(phase: .checking, startedAt: Date(),
                    appBuildFingerprint: StorageDiagnosticService.appBuildFingerprint())
                await self.run(adapter: adapter, cancellation: cancellation, generation: id,
                               completedRecovery: report)
                return
            }
            if report.outcome == .notNeeded, !cancellation.isCancelled {
                self.state = previousOperation ?? StorageOptimizationState()
                if [.checking, .optimizing, .cancelling].contains(self.state.phase) { self.state.phase = .idle }
            }
            self.cancellation = nil; self.operation = nil
            if Self.recoveryNeedsRefresh(report) { await self.settled() }
        }
    }

    func start() {
        guard let adapter else { return }
        if operation != nil {
            _ = launchGate.queueTap(operationActive: true, cancellationRequested: cancellation?.isCancelled == true)
            return
        }
        let id = UUID()
        let cancellation = RuntimeV2OptimizationCancellation()
        self.generation = id; self.cancellation = cancellation
        self.state = StorageOptimizationState(phase: .checking, startedAt: Date(),
            appBuildFingerprint: StorageDiagnosticService.appBuildFingerprint())
        operation = Task { [weak self] in
            guard let self else { return }
            await self.run(adapter: adapter, cancellation: cancellation, generation: id)
        }
    }

    func cancel() {
        guard operation != nil, let cancellation else { return }
        launchGate.cancelQueuedTap()
        cancellation.cancel()
        state.phase = .cancelling
        // Do not cancel the service task/authority/recovery. Core's cooperative
        // flag stops its bounded phase; the service still converges its journal.
    }

    static func recoveryNeedsRefresh(_ report: RuntimeV2MaintenanceRecoveryReport) -> Bool {
        report.outcome != .notNeeded
    }

    private func run(adapter: RuntimeV2RecoveryOptimizationAdapter,
                     cancellation: RuntimeV2OptimizationCancellation, generation: UUID,
                     completedRecovery: RuntimeV2MaintenanceRecoveryReport? = nil) async {
        var refreshNeeded = false
        var firstHostFree: Int64?
        var lastHostFree: Int64?
        do {
            let recovery: RuntimeV2MaintenanceRecoveryReport
            if let completedRecovery {
                recovery = completedRecovery
            } else {
                state.recordStage("recovery-check")
                persistResult()
                recovery = await recover(adapter: adapter, cancellation: cancellation, generation: generation)
            }
            guard self.generation == generation else { return }
            refreshNeeded = Self.recoveryNeedsRefresh(recovery)
            if cancellation.isCancelled {
                state.recordResult(code: "cancelled")
                if recovery.outcome == .blocked { state.recordDiagnostic("recovery-pending") }
                state.phase = .cancelled; finish(generation: generation)
                if refreshNeeded { await settled() }
                return
            }
            guard recovery.outcome != .blocked else {
                state.recordResult(code: "recovery-pending")
                state.phase = .blocked; finish(generation: generation)
                if refreshNeeded { await settled() }
                return
            }
            state.recordStage("inventory")
            persistResult()
            let report = try await adapter.inventory()
            guard self.generation == generation else { return }
            let inventoryAdmitted = state.admitInventory(report, cancellationRequested: cancellation.isCancelled)
            persistResult()
            guard inventoryAdmitted else {
                finish(generation: generation)
                if refreshNeeded { await settled() }
                return
            }
            let repairCandidates = report.records.filter {
                $0.isReviewableForBytePreservingMaintenance
                    && $0.relativeDirectory.hasPrefix("recovery/quarantine/runtime-vm-")
            }
            var candidates = repairCandidates.map(StorageOptimizationCandidate.repair)
            var migrationBlocked = 0
            do {
                let migrations = try await adapter.migrationInventory()
                state.migrationRecordCount = migrations.records.count + migrations.blockedPaths
                state.migrationBlockedCount = migrations.blockedPaths
                migrationBlocked = migrations.blockedPaths
                for code in migrations.codes { state.recordDiagnostic(code) }
                candidates.append(contentsOf: migrations.records.map(StorageOptimizationCandidate.migration))
            } catch {
                // New migration proof is opt-in and does not turn existing
                // repair records into fake migration records or erase their
                // receipts. Unknown migration state stays untouched.
                migrationBlocked = 6
                state.migrationRecordCount = 6; state.migrationBlockedCount = 6
                state.recordDiagnostic("migration_inventory_unavailable")
            }
            // Observation only: this does not broaden the existing candidate
            // filter or authorize retirement of other legacy environment data.
            state.coveredSourceCount = report.records.filter {
                $0.relativeDirectory.hasPrefix("recovery/quarantine/runtime-vm-")
            }.count
            state.coveredSourceCount = (state.coveredSourceCount ?? 0) + (state.migrationRecordCount ?? 0)
            state.eligibleSourceCount = candidates.count
            if state.coveredSourceCount == 0 { state.recordDiagnostic("no-covered-sources") }
            state.total = report.records.count + (state.migrationRecordCount ?? 0)
            state.skipped = report.records.count - repairCandidates.count + migrationBlocked
            if candidates.isEmpty && !report.records.isEmpty {
                state.phase = .blocked
                state.details["sources-not-eligible", default: 0] += report.records.count
            }
            for record in candidates {
                if cancellation.isCancelled { break }
                state.phase = .optimizing; state.corePhase = nil; state.fraction = nil
                state.attempted += 1
                let attempt = state.attempted
                state.recordStage("disk-admission")
                persistResult()
                refreshNeeded = true
                let progressGate = StorageOptimizationProgressGate()
                let onProgress: @Sendable (StorageSparseDiskRewriteProgress) -> Void = { [weak self] progress in
                    guard progressGate.accepts(progress) else { return }
                    Task { @MainActor [weak self] in
                        guard let self, self.generation == generation, self.operation != nil,
                              (self.state.phase == .optimizing || self.state.phase == .cancelling),
                              self.state.attempted == attempt else { return }
                        self.state.corePhase = progress.phase.rawValue
                        self.state.fraction = progress.totalBytes > 0
                            ? min(1, max(0, Double(progress.processedBytes) / Double(progress.totalBytes))) : nil
                        let changed = self.state.recordStage(progress.phase.rawValue,
                            processed: progress.processedBytes, total: progress.totalBytes)
                        // Persist a real phase boundary or coarse heartbeat,
                        // never every progress tick or a synthetic phase.
                        if changed || ProcessInfo.processInfo.systemUptime - self.lastDiagnosticPersistUptime >= 5 {
                            self.persistResult()
                        }
                    }
                }
                let result: RuntimeV2RecoveryOptimizationResult
                switch record {
                case .repair(let value):
                    result = await adapter.optimize(value, cancellation: cancellation, progress: onProgress)
                case .migration(let value):
                    result = await adapter.optimizeMigration(value, cancellation: cancellation, progress: onProgress)
                }
                guard self.generation == generation else { return }
                state.recordResult(code: result.code, diagnosticCodes: result.diagnosticCodes,
                    verifiedUnchanged: result.verifiedUnchanged)
                state.recordCandidateDisposition(result.candidateDisposition)
                if let measured = result.report {
                    state.optimized += 1
                    if firstHostFree == nil { firstHostFree = measured.volumeAvailableBytesBefore }
                    lastHostFree = measured.volumeAvailableBytesAfter
                    let delta = measured.sourceAllocatedBytesBefore - measured.stageAllocatedBytesAtVerification
                    let sum = state.fileAllocationReduction.addingReportingOverflow(max(0, delta))
                    if !sum.overflow { state.fileAllocationReduction = sum.partialValue }
                } else { state.skipped += 1 }
                persistResult()
                if result.recoveryPending { state.phase = .blocked; break }
                if cancellation.isCancelled { state.phase = .cancelled; break }
                // A retained-and-released history or a preclaim rejection is
                // local to this disk. It does not certify a first disk, but it
                // can leave the next independent candidate available. Every
                // other failure stops regardless of earlier successes.
                let mayContinue = StorageOptimizationBatchGate.mayContinue(
                    verified: result.verifiedFirstDisk,
                    retainedAndReleased: result.candidateDisposition == .retainedAndReleased,
                    preclaimIneligible: result.candidateDisposition == .preclaimIneligible,
                    recoveryPending: result.recoveryPending, cancelled: cancellation.isCancelled)
                if !mayContinue { state.phase = .blocked; break }
            }
            if let before = firstHostFree, let after = lastHostFree {
                let difference = after.subtractingReportingOverflow(before)
                if !difference.overflow { state.observedHostFreeDelta = difference.partialValue }
            }
            if state.phase != .blocked {
                state.phase = cancellation.isCancelled ? .cancelled : (migrationBlocked > 0 ? .blocked : .completed)
            }
        } catch {
            state.phase = cancellation.isCancelled || error is CancellationError ? .cancelled : .blocked
            let ownerCodes: [String]
            if case RuntimeV2MaintenanceError.ownerEvidenceIncomplete(let codes) = error { ownerCodes = codes }
            else { ownerCodes = [] }
            state.recordResult(code: RuntimeV2RecoveryOptimizationAdapter.code(error), diagnosticCodes: ownerCodes)
        }
        finish(generation: generation)
        // Exactly one mutation invalidation/refresh after this owned operation,
        // including cancellation/recovery. Views do not add a second hook.
        if refreshNeeded { await settled() }
    }

    private func recover(adapter: RuntimeV2RecoveryOptimizationAdapter,
                         cancellation: RuntimeV2OptimizationCancellation,
                         generation: UUID) async -> RuntimeV2MaintenanceRecoveryReport {
        recoveryProgressGeneration = generation
        let gate = StorageOptimizationProgressGate()
        let onProgress: @Sendable (StorageSparseDiskRewriteProgress) -> Void = { [weak self] value in
            guard gate.accepts(value) else { return }
            Task { @MainActor [weak self] in
                guard let self, self.generation == generation, self.operation != nil,
                      self.recoveryProgressGeneration == generation,
                      (self.state.phase == .checking || self.state.phase == .cancelling) else { return }
                self.state.corePhase = value.phase.rawValue
                self.state.fraction = value.totalBytes > 0
                    ? min(1, max(0, Double(value.processedBytes) / Double(value.totalBytes))) : nil
                let changed = self.state.recordStage(value.phase.rawValue,
                    processed: value.processedBytes, total: value.totalBytes)
                if changed || ProcessInfo.processInfo.systemUptime - self.lastDiagnosticPersistUptime >= 5 {
                    if self.launchGate.recoveryActive { self.persistLaunchRecovery() }
                    else { self.persistResult() }
                }
            }
        }
        let report = await adapter.recoverBeforeUse(cancellation: cancellation, progress: onProgress)
        // Enqueued progress from the completed read cannot overwrite the next
        // inventory/disk admission, even within this same service generation.
        if recoveryProgressGeneration == generation { recoveryProgressGeneration = nil }
        return report
    }

    private func finish(generation: UUID) {
        guard self.generation == generation else { return }
        recoveryProgressGeneration = nil
        state.corePhase = nil; state.fraction = nil; state.finishedAt = Date()
        cancellation = nil; operation = nil
        persistResult()
    }
    private func persistResult() {
        // UI cache only, never a lease/closure/idle attestation. No ids/paths,
        // sidecars, content, credentials or per-disk digest are persisted here.
        Self.persistSnapshot(state, to: defaults)
        lastDiagnosticPersistUptime = ProcessInfo.processInfo.systemUptime
    }
    private func persistLaunchRecovery() {
        Self.persistLaunchRecoverySnapshot(state, to: defaults)
        lastDiagnosticPersistUptime = ProcessInfo.processInfo.systemUptime
    }

    static func persistLaunchRecoverySnapshot(_ state: StorageOptimizationState, to defaults: UserDefaults) {
        guard let data = try? JSONEncoder().encode(state.sanitizedDiagnostics()),
              data.count <= maximumSnapshotBytes else { return }
        defaults.set(data, forKey: launchRecoveryKey)
    }
    static func readLaunchRecoverySnapshot(from defaults: UserDefaults) -> StorageOptimizationState? {
        guard let data = defaults.data(forKey: launchRecoveryKey), data.count <= maximumSnapshotBytes else { return nil }
        return (try? JSONDecoder().decode(StorageOptimizationState.self, from: data))?.sanitizedDiagnostics()
    }

    static func persistSnapshot(_ state: StorageOptimizationState, to defaults: UserDefaults) {
        guard let data = try? JSONEncoder().encode(state.sanitizedDiagnostics()), data.count <= maximumSnapshotBytes else { return }
        defaults.set(data, forKey: savedResultKey)
    }
    static func readSnapshot(from defaults: UserDefaults) -> StorageOptimizationState? {
        guard let data = defaults.data(forKey: savedResultKey), data.count <= maximumSnapshotBytes else { return nil }
        return (try? JSONDecoder().decode(StorageOptimizationState.self, from: data))?.sanitizedDiagnostics()
    }

    /// A failed bootstrap is not an optimization attempt. Preserve the old
    /// operation receipt byte for byte and record this launch separately.
    private static func persistBootstrapFailure(_ failure: RuntimeV2MaintenanceBootstrapFailure?,
                                                to defaults: UserDefaults) {
        guard let failure else { defaults.removeObject(forKey: bootstrapFailureKey); return }
        var value: [String: Any] = [
            "build": StorageDiagnosticService.appBuildFingerprint(), "observedAt": Date().timeIntervalSince1970,
            "code": failure.code.rawValue, "rootCheck": failure.rootCheck.rawValue,
            "histories": max(0, min(1_000_000, failure.histories)),
            "pending": max(0, min(1_000_000, failure.pending))
        ]
        value["stage"] = failure.stage?.rawValue
        value["errno"] = failure.posixErrno
        guard let data = try? JSONSerialization.data(withJSONObject: value), data.count <= 2_048 else { return }
        defaults.set(data, forKey: bootstrapFailureKey)
    }

    private static func bootstrapDiagnosticLines(defaults: UserDefaults) -> [String] {
        guard let data = defaults.data(forKey: bootstrapFailureKey), data.count <= 2_048,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rawCode = object["code"] as? String,
              let code = RuntimeV2MaintenanceBootstrapFailure.Code(rawValue: rawCode),
              let rawRoot = object["rootCheck"] as? String,
              let root = RuntimeV2MaintenanceBootstrapFailure.RootCheck(rawValue: rawRoot),
              let observed = object["observedAt"] as? Double, observed.isFinite else { return [] }
        let rawBuild = object["build"] as? String ?? ""
        let build = !rawBuild.isEmpty && rawBuild.utf8.count <= 40
            && rawBuild.utf8.allSatisfy { (48...57).contains($0) || $0 == 46 } ? rawBuild : "unrecorded"
        let stage = (object["stage"] as? String)
            .flatMap(RuntimeV2MaintenanceBootstrapFailure.Stage.init(rawValue:))?.rawValue ?? "unrecorded"
        let posix = (object["errno"] as? Int32).map { String($0) } ?? "unrecorded"
        func count(_ key: String) -> String { String(max(0, min(1_000_000, object[key] as? Int ?? 0))) }
        return ["optimization_bootstrap_evidence: persisted_bootstrap_failure",
            "optimization_bootstrap_build: \(build)",
            "optimization_bootstrap_observed_at: \(ISO8601DateFormatter().string(from: Date(timeIntervalSince1970: observed)))",
            "optimization_bootstrap_code: \(code.rawValue)", "optimization_bootstrap_root_check: \(root.rawValue)",
            "optimization_bootstrap_stage: \(stage)", "optimization_bootstrap_errno: \(posix)",
            "optimization_bootstrap_histories: \(count("histories"))", "optimization_bootstrap_pending: \(count("pending"))"]
    }

    private static func launchRecoveryDiagnosticLines(defaults: UserDefaults) -> [String] {
        guard let value = readLaunchRecoverySnapshot(from: defaults) else {
            return ["optimization_launch_recovery_evidence: unavailable"]
        }
        let observed = value.finishedAt ?? value.lastStageObservedAt ?? value.startedAt
        let date = observed.flatMap { $0.timeIntervalSince1970.isFinite
            ? ISO8601DateFormatter().string(from: $0) : nil } ?? "unrecorded"
        return ["optimization_launch_recovery_evidence: persisted_recovery_summary",
            "optimization_launch_recovery_phase: \(value.phase.rawValue)",
            "optimization_launch_recovery_result: \(value.lastResultCode ?? "unrecorded")",
            "optimization_launch_recovery_stage: \(value.lastStage ?? "unrecorded")",
            "optimization_launch_recovery_observed_at: \(date)",
            "optimization_launch_recovery_attempted: \(max(0, min(1_000_000, value.attempted)))"]
    }

    /// Only already-persisted bootstrap, launch recovery and operation receipts are exported. Reading a
    /// diagnostic report never starts inventory, preparation or optimization.
    static func diagnosticText(defaults: UserDefaults = .standard) -> String {
        let bootstrapLines = bootstrapDiagnosticLines(defaults: defaults)
            + launchRecoveryDiagnosticLines(defaults: defaults)
        guard let value = readSnapshot(from: defaults) else {
            return (bootstrapLines + ["optimization_evidence: unavailable", "optimization_live_measurement: false"])
                .joined(separator: "\n")
        }
        func date(_ value: Date?) -> String {
            guard let value, value.timeIntervalSince1970.isFinite else { return "unrecorded" }
            return ISO8601DateFormatter().string(from: value)
        }
        func count(_ value: Int) -> String { String(max(0, value)) }
        func optionalCount(_ value: Int?) -> String { value.map(count) ?? "unrecorded" }
        func bytes(_ value: Int64?) -> String { value.map { String(max(0, $0)) } ?? "unrecorded" }
        let rawBuild = value.appBuildFingerprint ?? ""
        let build = !rawBuild.isEmpty && rawBuild.utf8.count <= 40
            && rawBuild.utf8.allSatisfy { (48...57).contains($0) || $0 == 46 } ? rawBuild : "unrecorded"
        var lines = bootstrapLines + ["optimization_evidence: persisted_operation_summary", "optimization_live_measurement: false",
            "optimization_build: \(build)", "optimization_started_at: \(date(value.startedAt))",
            "optimization_finished_at: \(date(value.finishedAt))", "optimization_phase: \(value.phase.rawValue)",
            "optimization_attempted: \(count(value.attempted))", "optimization_optimized: \(count(value.optimized))",
            "optimization_skipped: \(count(value.skipped))"]
        // Include pre-inventory and adapter failures before the early return.
        // All strings come from the closed vocabulary; attributed values,
        // NSError text, paths and disk identities are never exported.
        lines += ["optimization_last_stage: \(value.lastStage ?? "unrecorded")",
            "optimization_last_stage_at: \(date(value.lastStageObservedAt))",
            "optimization_last_processed_bytes: \(bytes(value.lastProcessedBytes))",
            "optimization_last_total_bytes: \(bytes(value.lastTotalBytes))",
            "optimization_last_result_code: \(value.lastResultCode ?? "unrecorded")",
            "optimization_last_candidate_disposition: \(value.lastCandidateDisposition ?? "unrecorded")",
            "optimization_terminal_disposition: \(value.terminalDisposition?.rawValue ?? "unrecorded")",
            "optimization_covered_sources: \(optionalCount(value.coveredSourceCount))",
            "optimization_eligible_sources: \(optionalCount(value.eligibleSourceCount))",
            "optimization_verified_no_gain: \(optionalCount(value.verifiedNoGainCount))",
            "optimization_unknown_diagnostic_codes: \(optionalCount(value.unrecognizedDiagnosticCodeCount))"]
        for key in value.safeDetails.keys.sorted() {
            lines.append("optimization_result.\(key): \(count(value.safeDetails[key] ?? 0))")
        }
        guard let inventory = value.inventoryEvidence else {
            return (lines + ["optimization_inventory: not_recorded_in_this_receipt"]).joined(separator: "\n")
        }
        lines += ["optimization_inventory_at: \(date(inventory.capturedAt))",
            "optimization_inventory_partial: \(inventory.isPartial)", "optimization_root_available: \(inventory.rootAvailable)",
            "optimization_inventory_entries: \(count(inventory.directoryEntriesVisited))",
            "optimization_migration_records: \(optionalCount(value.migrationRecordCount))",
            "optimization_migration_blocked: \(optionalCount(value.migrationBlockedCount))",
            "optimization_inventory_sidecar_reads: \(count(inventory.sidecarReadsAttempted))",
            "optimization_inventory_sidecar_bytes: \(count(inventory.sidecarBytesRead))",
            "optimization_inventory_disk_content_bytes: \(count(inventory.diskContentBytesRead))",
            "optimization_inventory_records: \(count(inventory.recordCount))",
            "optimization_inventory_reviewable: \(count(inventory.reviewableCount))",
            "optimization_inventory_reference_unknown: \(count(inventory.currentReferenceUnknownCount))",
            "optimization_inventory_reference_active: \(count(inventory.currentReferenceActiveCount))"]
        let reasons = inventory.stopReasons.filter { StorageOptimizationInventoryEvidence.allowedStopReasons.contains($0) }
        lines.append("optimization_inventory_stop_reasons: " + (reasons.isEmpty ? "none" : reasons.joined(separator: ",")))
        lines.append("optimization_inventory_unknown_reason_count: \(count(inventory.unrecognizedStopReasonCount))")
        if let root = inventory.rootDiagnostic {
            lines += ["optimization_root_failure_stage: \(root.stage.rawValue)",
                "optimization_root_failure_errno: \(root.posixErrno)",
                "optimization_root_failure_component: \(root.componentIndex.map(count) ?? "unrecorded")"]
        }
        let allowedBlockers: Set<String> = ["unsupportedDirectory", "diskUnavailable", "diskChanged", "linkedDisk",
            "runtimeMetadataUnavailable", "runtimeIdentityMismatch", "environmentMetadataUnavailable", "environmentIdentityMismatch",
            "unreadableRepairMarker", "repairIdentityMismatch", "unsafeRepairPath", "generationUnmeasured", "currentReferencesUnknown",
            "currentReferenceExists", "currentReferenceActive", "inventoryIncomplete"]
        for key in inventory.planningBlockerCounts.keys.sorted() where allowedBlockers.contains(key) {
            lines.append("optimization_inventory_blocker.\(key): \(count(inventory.planningBlockerCounts[key] ?? 0))")
        }
        return lines.joined(separator: "\n")
    }
}
#endif
