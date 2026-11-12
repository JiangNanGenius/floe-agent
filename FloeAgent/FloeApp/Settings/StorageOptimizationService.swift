// App lifetime owns start/cancel/result; a View never owns or cancels this task.
#if canImport(SwiftUI) && canImport(UIKit)
import Foundation
import Combine
import FloeCore
import FloeExecution

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
    private let adapter: RuntimeV2RecoveryOptimizationAdapter?
    private let defaults: UserDefaults
    private let settled: @MainActor @Sendable () async -> Void
    let hasLegacyRecoveryTree: Bool
    private var operation: Task<Void, Never>?
    private var cancellation: RuntimeV2OptimizationCancellation?
    private var generation: UUID?
    private static let savedResultKey = "floe.storage.legacyOptimization.lastResult.v1"
    private static let maximumSnapshotBytes = 16_384

    var isRunning: Bool { operation != nil }
    var canStart: Bool { adapter != nil && !isRunning }
    var canCancel: Bool { cancellation != nil && isRunning && state.phase != .cancelling }

    init(adapter: RuntimeV2RecoveryOptimizationAdapter?, defaults: UserDefaults = .standard,
         settled: @escaping @MainActor @Sendable () async -> Void = {
             StorageDiagnosticService.shared.invalidate(.other("legacyRecoveryOptimization"))
             _ = await StorageDiagnosticService.shared.refresh(explicit: true)
         }) {
        self.adapter = adapter; self.defaults = defaults; self.settled = settled
        self.hasLegacyRecoveryTree = RuntimeV2MaintenanceDomain.trustedLegacyRoot().map {
            FileManager.default.fileExists(atPath: $0.appendingPathComponent("recovery").path)
        } ?? false
        if let previous = Self.readSnapshot(from: defaults) { state = previous }
        guard let adapter else { state.phase = .unavailable; return }
        // Installs a REAL Core recovery handler on every process launch before
        // converging pending intent. No forever-nil recovery closure is shipped.
        let id = UUID(); generation = id
        let previousPhase = state.phase
        state.phase = .checking
        operation = Task { [weak self] in
            guard let self else { return }
            let report = await adapter.recoverBeforeUse()
            guard self.generation == id else { return }
            if report.outcome == .blocked { self.state.phase = .blocked }
            else if report.outcome == .resolved { self.state.phase = .completed }
            else {
                // A launch-time no-op recovery must not relabel the last
                // failed/cancelled optimization as an idle/successful one.
                switch previousPhase {
                case .checking, .optimizing, .cancelling: self.state.phase = .idle
                default: self.state.phase = previousPhase
                }
            }
            if report.outcome == .resolved { self.state.details["recovery-resolved", default: 0] += 1 }
            self.operation = nil
            self.persistResult()
            if report.outcome != .notNeeded, report.intentID != nil { await self.settled() }
        }
    }

    func start() {
        guard let adapter, operation == nil else { return }
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
        cancellation.cancel()
        state.phase = .cancelling
        // Do not cancel the service task/authority/recovery. Core's cooperative
        // flag stops its bounded phase; the service still converges its journal.
    }

    private func run(adapter: RuntimeV2RecoveryOptimizationAdapter,
                     cancellation: RuntimeV2OptimizationCancellation, generation: UUID) async {
        var refreshNeeded = false
        var firstHostFree: Int64?
        var lastHostFree: Int64?
        do {
            let recovery = await adapter.recoverBeforeUse()
            guard self.generation == generation else { return }
            refreshNeeded = recovery.outcome != .notNeeded && recovery.intentID != nil
            guard recovery.outcome != .blocked else {
                state.phase = .blocked; finish(generation: generation)
                if refreshNeeded { await settled() }
                return
            }
            if cancellation.isCancelled {
                state.phase = .cancelled; finish(generation: generation)
                if refreshNeeded { await settled() }
                return
            }
            let report = try await adapter.inventory()
            guard self.generation == generation else { return }
            guard state.admitInventory(report, cancellationRequested: cancellation.isCancelled) else {
                finish(generation: generation)
                if refreshNeeded { await settled() }
                return
            }
            let candidates = report.records.filter {
                $0.isReviewableForBytePreservingMaintenance
                    && $0.relativeDirectory.hasPrefix("recovery/quarantine/runtime-vm-")
            }
            state.total = report.records.count
            state.skipped = report.records.count - candidates.count
            if candidates.isEmpty && !report.records.isEmpty {
                state.phase = .blocked
                state.details["sources-not-eligible", default: 0] += report.records.count
            }
            var verifiedOne = false
            for record in candidates {
                if cancellation.isCancelled { break }
                state.phase = .optimizing; state.corePhase = nil; state.fraction = nil
                state.attempted += 1
                refreshNeeded = true
                let progressGate = StorageOptimizationProgressGate()
                let result = await adapter.optimize(record, cancellation: cancellation) { [weak self] progress in
                    guard progressGate.accepts(progress) else { return }
                    Task { @MainActor [weak self] in
                        guard let self, self.generation == generation, self.operation != nil else { return }
                        self.state.corePhase = progress.phase.rawValue
                        self.state.fraction = progress.totalBytes > 0
                            ? min(1, max(0, Double(progress.processedBytes) / Double(progress.totalBytes))) : nil
                    }
                }
                guard self.generation == generation else { return }
                state.details[result.code, default: 0] += 1
                for code in result.diagnosticCodes { state.details[code, default: 0] += 1 }
                if let measured = result.report {
                    state.optimized += 1
                    if firstHostFree == nil { firstHostFree = measured.volumeAvailableBytesBefore }
                    lastHostFree = measured.volumeAvailableBytesAfter
                    let delta = measured.sourceAllocatedBytesBefore - measured.stageAllocatedBytesAtVerification
                    let sum = state.fileAllocationReduction.addingReportingOverflow(max(0, delta))
                    if !sum.overflow { state.fileAllocationReduction = sum.partialValue }
                } else { state.skipped += 1 }
                if result.recoveryPending { state.phase = .blocked; break }
                if cancellation.isCancelled { state.phase = .cancelled; break }
                verifiedOne = verifiedOne || result.verifiedFirstDisk
                // Validate one REAL disk first. A fully verified no-gain stage
                // converged to unchanged S also qualifies; an unknown/busy/
                // unsupported first disk cannot silently enable the batch.
                if !verifiedOne { state.phase = .blocked; break }
            }
            if let before = firstHostFree, let after = lastHostFree {
                let difference = after.subtractingReportingOverflow(before)
                if !difference.overflow { state.observedHostFreeDelta = difference.partialValue }
            }
            if state.phase != .blocked {
                state.phase = cancellation.isCancelled ? .cancelled : .completed
            }
        } catch {
            state.phase = cancellation.isCancelled || error is CancellationError ? .cancelled : .blocked
            state.details[RuntimeV2RecoveryOptimizationAdapter.code(error), default: 0] += 1
        }
        finish(generation: generation)
        // Exactly one mutation invalidation/refresh after this owned operation,
        // including cancellation/recovery. Views do not add a second hook.
        if refreshNeeded { await settled() }
    }

    private func finish(generation: UUID) {
        guard self.generation == generation else { return }
        state.corePhase = nil; state.fraction = nil; state.finishedAt = Date()
        cancellation = nil; operation = nil
        persistResult()
    }
    private func persistResult() {
        // UI cache only, never a lease/closure/idle attestation. No ids/paths,
        // sidecars, content, credentials or per-disk digest are persisted here.
        Self.persistSnapshot(state, to: defaults)
    }

    static func persistSnapshot(_ state: StorageOptimizationState, to defaults: UserDefaults) {
        guard let data = try? JSONEncoder().encode(state), data.count <= maximumSnapshotBytes else { return }
        defaults.set(data, forKey: savedResultKey)
    }
    static func readSnapshot(from defaults: UserDefaults) -> StorageOptimizationState? {
        guard let data = defaults.data(forKey: savedResultKey), data.count <= maximumSnapshotBytes else { return nil }
        return try? JSONDecoder().decode(StorageOptimizationState.self, from: data)
    }

    /// Only the already-persisted operation receipt is exported. Reading a
    /// diagnostic report never starts inventory, preparation or optimization.
    static func diagnosticText(defaults: UserDefaults = .standard) -> String {
        guard let value = readSnapshot(from: defaults) else {
            return "optimization_evidence: unavailable\noptimization_live_measurement: false"
        }
        func date(_ value: Date?) -> String {
            guard let value, value.timeIntervalSince1970.isFinite else { return "unrecorded" }
            return ISO8601DateFormatter().string(from: value)
        }
        func count(_ value: Int) -> String { String(max(0, value)) }
        let rawBuild = value.appBuildFingerprint ?? ""
        let build = !rawBuild.isEmpty && rawBuild.utf8.count <= 40
            && rawBuild.utf8.allSatisfy { (48...57).contains($0) || $0 == 46 } ? rawBuild : "unrecorded"
        var lines = ["optimization_evidence: persisted_operation_summary", "optimization_live_measurement: false",
            "optimization_build: \(build)", "optimization_started_at: \(date(value.startedAt))",
            "optimization_finished_at: \(date(value.finishedAt))", "optimization_phase: \(value.phase.rawValue)",
            "optimization_attempted: \(count(value.attempted))", "optimization_optimized: \(count(value.optimized))",
            "optimization_skipped: \(count(value.skipped))"]
        guard let inventory = value.inventoryEvidence else {
            return (lines + ["optimization_inventory: not_recorded_in_this_receipt"]).joined(separator: "\n")
        }
        lines += ["optimization_inventory_at: \(date(inventory.capturedAt))",
            "optimization_inventory_partial: \(inventory.isPartial)", "optimization_root_available: \(inventory.rootAvailable)",
            "optimization_inventory_entries: \(count(inventory.directoryEntriesVisited))",
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
