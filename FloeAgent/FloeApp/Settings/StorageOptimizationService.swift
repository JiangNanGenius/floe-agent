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
        if let data = defaults.data(forKey: Self.savedResultKey),
           let previous = try? JSONDecoder().decode(StorageOptimizationState.self, from: data) {
            state = previous
        }
        guard let adapter else { state.phase = .unavailable; return }
        // Installs a REAL Core recovery handler on every process launch before
        // converging pending intent. No forever-nil recovery closure is shipped.
        let id = UUID(); generation = id
        state.phase = .checking
        operation = Task { [weak self] in
            guard let self else { return }
            let report = await adapter.recoverBeforeUse()
            guard self.generation == id else { return }
            self.state.phase = report.outcome == .blocked ? .blocked
                : (self.state.attempted > 0 || report.outcome == .resolved ? .completed : .idle)
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
        self.state = StorageOptimizationState(phase: .checking)
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
            let report = try await adapter.inventory()
            guard self.generation == generation else { return }
            guard !report.summary.isPartial, report.rootIdentity != nil else {
                state.details["inventory-incomplete", default: 0] += 1
                state.phase = .blocked; finish(generation: generation)
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
            state.phase = .blocked
            state.details[RuntimeV2RecoveryOptimizationAdapter.code(error), default: 0] += 1
        }
        finish(generation: generation)
        // Exactly one mutation invalidation/refresh after this owned operation,
        // including cancellation/recovery. Views do not add a second hook.
        if refreshNeeded { await settled() }
    }

    private func finish(generation: UUID) {
        guard self.generation == generation else { return }
        state.corePhase = nil; state.fraction = nil
        cancellation = nil; operation = nil
        persistResult()
    }
    private func persistResult() {
        // UI cache only, never a lease/closure/idle attestation. No ids/paths,
        // sidecars, content, credentials or per-disk digest are persisted here.
        if let data = try? JSONEncoder().encode(state) {
            defaults.set(data, forKey: Self.savedResultKey)
        }
    }
}
#endif
