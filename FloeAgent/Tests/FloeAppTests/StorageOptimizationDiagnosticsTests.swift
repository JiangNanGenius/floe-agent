// SPDX-License-Identifier: MPL-2.0
#if canImport(UIKit)
import Darwin
import Foundation
import XCTest
import FloeCore
import FloeExecution
import FloePersistence
@testable import FloeApp

@MainActor final class StorageOptimizationDiagnosticsTests: XCTestCase {
    func testOptimizeCanRetireImagesWithoutALegacyDiskStore() async throws {
        let store = try defaults()
        var refreshes = 0
        let service = StorageOptimizationService(adapter: nil, defaults: store, retireImages: { _ in
            LinuxImageRetirementResult(removed: 3, incomplete: false, hostAvailableBefore: 800, hostAvailableAfter: 920)
        }, settled: { refreshes += 1 })
        XCTAssertTrue(service.canStart)
        service.start()
        let deadline = ContinuousClock.now + .seconds(5)
        while service.isRunning && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(service.state.phase, .completed)
        XCTAssertEqual(service.state.removedObsoleteItems, 3)
        XCTAssertEqual(service.state.observedHostFreeDelta, 120)
        XCTAssertEqual(refreshes, 1)
        XCTAssertEqual(StorageOptimizationService.readSnapshot(from: store)?.removedObsoleteItems, 3)
    }

    private func root() throws -> URL {
        let support = try XCTUnwrap(FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first)
        let value = support.appendingPathComponent("StorageOptimizationDiagnosticTests-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: value, withIntermediateDirectories: true)
        addTeardownBlock { try FileManager.default.removeItem(at: value) }
        return value
    }
    private func scan(_ root: URL, limits: LegacyRecoveryInventoryLimits = .init()) -> LegacyRecoveryInventoryReport {
        LegacyRecoveryInventory.scan(.init(legacyRoot: root, currentReferences: nil, limits: limits))
    }
    private func defaults() throws -> UserDefaults {
        let name = "StorageOptimizationDiagnosticTests." + UUID().uuidString
        let value = try XCTUnwrap(UserDefaults(suiteName: name))
        addTeardownBlock { UserDefaults(suiteName: name)?.removePersistentDomain(forName: name) }
        return value
    }
    private func changing(_ report: LegacyRecoveryInventoryReport,
                          _ change: (inout [String: Any]) -> Void) throws -> LegacyRecoveryInventoryReport {
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(report)) as? [String: Any])
        change(&object)
        return try JSONDecoder().decode(LegacyRecoveryInventoryReport.self, from: JSONSerialization.data(withJSONObject: object))
    }

    private func bootstrapFailure() throws -> RuntimeV2MaintenanceBootstrapFailure {
        let directory = try root(), legacy = directory.appendingPathComponent("v2")
        let authority = directory.appendingPathComponent("MaintenanceAuthority")
        try FileManager.default.createDirectory(at: legacy, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: authority, withIntermediateDirectories: true)
        // An unknown physical anchor must stay refused; diagnostics do not
        // adopt it or turn old metadata into permission to rewrite a disk.
        try Data().write(to: authority.appendingPathComponent(".physical-" + String(repeating: "f", count: 64) + ".lock"))
        do {
            _ = try RuntimeV2MaintenanceDomain(trustedLegacyRoot: legacy).authorityHistoryLayout()
            XCTFail("An unknown anchor must not be admitted")
            throw CocoaError(.fileReadUnknown)
        } catch let failure as RuntimeV2MaintenanceBootstrapFailure { return failure }
    }

    func testBootstrapFailureKeepsOldOperationAndExportsThisLaunchSeparately() throws {
        let store = try defaults()
        var previous = StorageOptimizationState(phase: .blocked, details: ["recovery-pending": 1],
                                              appBuildFingerprint: "1.8.22.343")
        previous.recordStage("recovery-check")
        StorageOptimizationService.persistSnapshot(previous, to: store)
        let original = try XCTUnwrap(store.data(forKey: "floe.storage.legacyOptimization.lastResult.v1"))
        let service = StorageOptimizationService(adapter: nil, bootstrapFailure: try bootstrapFailure(), defaults: store)
        XCTAssertFalse(service.canStart)
        XCTAssertFalse(service.isRunning)
        XCTAssertEqual(service.state.phase, .unavailable)
        XCTAssertEqual(service.bootstrapFailure?.stage, .physicalAnchorMismatch)
        XCTAssertEqual(store.data(forKey: "floe.storage.legacyOptimization.lastResult.v1"), original)
        XCTAssertEqual(StorageOptimizationService.readSnapshot(from: store)?.phase, .blocked)
        let text = StorageOptimizationService.diagnosticText(defaults: store)
        XCTAssertTrue(text.contains("optimization_bootstrap_code: history_shape_unknown"))
        XCTAssertTrue(text.contains("optimization_bootstrap_stage: physical_anchor_mismatch"))
        XCTAssertTrue(text.contains("optimization_bootstrap_errno: unrecorded"))
        XCTAssertTrue(text.contains("optimization_build: 1.8.22.343"))
        XCTAssertTrue(text.contains("optimization_attempted: 0"))
        let bounded = FeedbackUploadService.boundedDiagnostics(DiagnosticsExporter.render(sections: [
            .init(id: .storageSnapshot, body: text),
            .init(id: .recentLog, body: String(repeating: "bounded log\n", count: 20_000))
        ]))
        XCTAssertTrue(bounded.contains("optimization_bootstrap_stage: physical_anchor_mismatch"))
        XCTAssertEqual(store.data(forKey: "floe.storage.legacyOptimization.lastResult.v1"), original)
    }

    func testLaunchWithoutBootstrapFailureDoesNotReuseAnOldFailure() throws {
        let store = try defaults()
        _ = StorageOptimizationService(adapter: nil, bootstrapFailure: try bootstrapFailure(), defaults: store)
        XCTAssertTrue(StorageOptimizationService.diagnosticText(defaults: store).contains("optimization_bootstrap_code:"))
        let service = StorageOptimizationService(adapter: nil, defaults: store)
        XCTAssertNil(service.bootstrapFailure)
        XCTAssertFalse(service.canStart)
        XCTAssertFalse(StorageOptimizationService.diagnosticText(defaults: store).contains("optimization_bootstrap_code:"))
        XCTAssertNil(StorageOptimizationService.readSnapshot(from: store), "A failed bootstrap never fabricates an operation")
    }

    func testLaunchRecoveryOnlyContinuesAfterOneExplicitTapAndSuccessfulRecovery() {
        var gate = StorageOptimizationLaunchGate()
        gate.beginRecovery()
        XCTAssertFalse(gate.completeRecovery(unblocked: true, cancelled: false),
                       "Launch recovery alone cannot start optimization")

        gate.beginRecovery()
        XCTAssertTrue(gate.queueTap(operationActive: true, cancellationRequested: false))
        XCTAssertFalse(gate.queueTap(operationActive: true, cancellationRequested: false),
                       "Repeated taps must not queue another inventory")
        XCTAssertTrue(gate.completeRecovery(unblocked: true, cancelled: false))
        XCTAssertFalse(gate.completeRecovery(unblocked: true, cancelled: false),
                       "The same tap must not be replayed")

        gate.beginRecovery()
        XCTAssertTrue(gate.queueTap(operationActive: true, cancellationRequested: false))
        XCTAssertFalse(gate.completeRecovery(unblocked: false, cancelled: false))
        gate.beginRecovery()
        XCTAssertTrue(gate.queueTap(operationActive: true, cancellationRequested: false))
        XCTAssertFalse(gate.completeRecovery(unblocked: true, cancelled: true))
        gate.beginRecovery()
        XCTAssertTrue(gate.queueTap(operationActive: true, cancellationRequested: false))
        gate.cancelQueuedTap()
        XCTAssertFalse(gate.completeRecovery(unblocked: true, cancelled: false))
    }

    func testLaunchRecoveryReceiptPreservesPreviousOperationMetrics() throws {
        let store = try defaults()
        var old = StorageOptimizationState(phase: .blocked, attempted: 2, optimized: 1, skipped: 1,
                                           appBuildFingerprint: "1.8.25.346")
        old.recordStage("disk-admission")
        old.recordResult(code: "busy")
        StorageOptimizationService.persistSnapshot(old, to: store)
        let original = try XCTUnwrap(store.data(forKey: "floe.storage.legacyOptimization.lastResult.v1"))

        var recovered = StorageOptimizationState(phase: .completed, startedAt: Date())
        recovered.recordStage("recovery-check")
        recovered.recordResult(code: "recovery-resolved")
        recovered.finishedAt = Date()
        StorageOptimizationService.persistLaunchRecoverySnapshot(recovered, to: store)

        XCTAssertEqual(store.data(forKey: "floe.storage.legacyOptimization.lastResult.v1"), original)
        XCTAssertEqual(StorageOptimizationService.readSnapshot(from: store)?.attempted, 2)
        XCTAssertEqual(StorageOptimizationService.readLaunchRecoverySnapshot(from: store)?.attempted, 0)
        let text = StorageOptimizationService.diagnosticText(defaults: store)
        XCTAssertTrue(text.contains("optimization_launch_recovery_result: recovery-resolved"))
        XCTAssertTrue(text.contains("optimization_launch_recovery_attempted: 0"))
        XCTAssertTrue(text.contains("optimization_attempted: 2"))
        XCTAssertTrue(text.contains("optimization_last_result_code: busy"))
    }

    func testMultiHistoryRecoveryRefreshesWithoutSingleIntentID() {
        XCTAssertTrue(StorageOptimizationService.recoveryNeedsRefresh(
            .init(outcome: .resolved, intentID: nil)))
        XCTAssertTrue(StorageOptimizationService.recoveryNeedsRefresh(
            .init(outcome: .blocked, intentID: nil)))
        XCTAssertFalse(StorageOptimizationService.recoveryNeedsRefresh(
            .init(outcome: .notNeeded, intentID: nil)))
    }

    func testBatchGateRetainedFirstAllowsSecondCandidateButSharedFailureStops() {
        let outcomes: [(verified: Bool, retained: Bool, preclaim: Bool, pending: Bool)] = [
            (false, true, false, false), (true, false, false, false)
        ]
        var attempted = 0
        for outcome in outcomes {
            attempted += 1
            guard StorageOptimizationBatchGate.mayContinue(
                verified: outcome.verified, retainedAndReleased: outcome.retained,
                preclaimIneligible: outcome.preclaim, recoveryPending: outcome.pending,
                cancelled: false) else { break }
        }
        XCTAssertEqual(attempted, 2, "A retained first disk does not certify it, but must not hide the second")
        XCTAssertTrue(StorageOptimizationBatchGate.mayContinue(verified: false,
            retainedAndReleased: false, preclaimIneligible: true, recoveryPending: false, cancelled: false))
        XCTAssertFalse(StorageOptimizationBatchGate.mayContinue(verified: false,
            retainedAndReleased: false, preclaimIneligible: false, recoveryPending: false, cancelled: false),
            "Unknown, root, owner and busy failures are batch-wide regardless of prior success")
        XCTAssertFalse(StorageOptimizationBatchGate.mayContinue(verified: true,
            retainedAndReleased: false, preclaimIneligible: false, recoveryPending: true, cancelled: false))
        XCTAssertFalse(StorageOptimizationBatchGate.mayContinue(verified: true,
            retainedAndReleased: false, preclaimIneligible: false, recoveryPending: false, cancelled: true))
    }

    func testLocalNeedsInspectionStaysOriginalResultAndIsNotPendingRecovery() throws {
        var retained = StorageOptimizationState(phase: .completed, attempted: 1, skipped: 1)
        retained.recordResult(code: "needs-inspection")
        retained.recordCandidateDisposition(.retainedAndReleased)
        XCTAssertEqual(retained.lastResultCode, "needs-inspection")
        XCTAssertEqual(retained.terminalDisposition, .retained)
        XCTAssertEqual(retained.retainedCandidateCount, 1)
        XCTAssertFalse(try XCTUnwrap(retained.terminalNotice).isEmpty)

        var partial = retained
        partial.attempted = 2; partial.optimized = 1
        partial.recordResult(code: "optimized")
        partial.recordCandidateDisposition(.ordinary)
        XCTAssertEqual(partial.terminalDisposition, .partiallyOptimized)
        XCTAssertTrue(try XCTUnwrap(partial.terminalNotice).contains("1"))

        var sharedFailure = retained
        sharedFailure.phase = .blocked; sharedFailure.attempted = 2; sharedFailure.skipped = 2
        sharedFailure.recordResult(code: "busy")
        sharedFailure.recordCandidateDisposition(.ordinary)
        XCTAssertEqual(sharedFailure.terminalDisposition, .busy)
        XCTAssertEqual(sharedFailure.lastResultCode, "busy")

        var legacyPending = StorageOptimizationState(phase: .blocked, attempted: 1)
        legacyPending.details["recovery-pending"] = 1
        XCTAssertEqual(legacyPending.terminalDisposition, .recoveryPending,
                       "Old receipts can carry only a recovery detail without a last-result field")
    }

    func testBootstrapDiagnosticSnapshotOnlyExportsClosedValues() throws {
        let store = try defaults(), key = "floe.storage.legacyOptimization.bootstrapFailure.v1"
        let marker = "/synthetic-private/" + UUID().uuidString
        var object: [String: Any] = ["code": "history_shape_unknown", "rootCheck": "verified",
            "build": marker, "stage": marker, "observedAt": Date().timeIntervalSince1970,
            "histories": -10, "pending": Int.max, "errno": marker, "extra": marker]
        store.set(try JSONSerialization.data(withJSONObject: object), forKey: key)
        var text = StorageOptimizationService.diagnosticText(defaults: store)
        XCTAssertFalse(text.contains(marker))
        XCTAssertTrue(text.contains("optimization_bootstrap_build: unrecorded"))
        XCTAssertTrue(text.contains("optimization_bootstrap_stage: unrecorded"))
        XCTAssertTrue(text.contains("optimization_bootstrap_histories: 0"))
        XCTAssertTrue(text.contains("optimization_bootstrap_pending: 1000000"))
        object["code"] = marker
        store.set(try JSONSerialization.data(withJSONObject: object), forKey: key)
        text = StorageOptimizationService.diagnosticText(defaults: store)
        XCTAssertFalse(text.contains("optimization_bootstrap_code:"))
        XCTAssertFalse(text.contains(marker))
        store.set(Data(repeating: 65, count: 2_049), forKey: key)
        XCTAssertFalse(StorageOptimizationService.diagnosticText(defaults: store).contains("optimization_bootstrap_code:"))
    }

    func testUnrelatedBoundNativeTaskDoesNotInvalidateLegacyReferenceClaim() async throws {
        let directory = try root(), legacyRoot = directory.appendingPathComponent("v2")
        try FileManager.default.createDirectory(at: legacyRoot.appendingPathComponent("environments/legacy-env"),
                                               withIntermediateDirectories: true)
        let domain = try RuntimeV2MaintenanceDomain(trustedLegacyRoot: legacyRoot)
        let legacy = EnvironmentReference(source: .runBinding, ownerID: UUID(), conversationID: UUID(),
            environmentID: "legacy-env", backend: .linuxVM, bindingGeneration: 3,
            runtimeGeneration: "legacy-generation", state: "completed", classification: .retained, isLive: false)
        let before = EnvironmentReferenceProjection(isComplete: true, blockers: [], references: [legacy])
        // A native Workspace task still has a fully attributed resident Linux
        // binding; it never owns this retired legacy root.
        let nativeTask = EnvironmentReference(source: .taskBinding, ownerID: UUID(), conversationID: UUID(),
            environmentID: "resident-current", backend: .linuxVM, bindingGeneration: 1,
            runtimeGeneration: "resident-generation", state: "running", classification: .active, isLive: true)
        let after = EnvironmentReferenceProjection(isComplete: true, blockers: [], references: [legacy, nativeTask])
        XCTAssertNotEqual(before.fingerprint, after.fingerprint) // reproduces the old global invalidation
        let first = makeLegacyMaintenanceReferenceEvidence(from: before, domain: domain)
        let fresh = makeLegacyMaintenanceReferenceEvidence(from: after, domain: domain)
        XCTAssertEqual(first.fingerprint, fresh.fingerprint)
        XCTAssertEqual(fresh.activeEnvironmentIDs, ["resident-current"])
        let evidence = RuntimeV2MaintenanceOwnerEvidence(isComplete: true,
            integrator: .init(storeRootPath: domain.root.path), references: first)
        let coordinator = try RuntimeV2MaintenanceCoordinator(domain: domain,
            stateDirectory: directory.appendingPathComponent("authority"), evidenceProvider: { evidence })
        let claim = try await coordinator.acquireExclusiveMaintenance(.init(owner: "synthetic-ref-test", reason: "fingerprint"))
        XCTAssertNoThrow(try claim.validateReferenceFingerprint(fresh.fingerprint))
        var refreshedEvidence = evidence; refreshedEvidence.references = fresh
        XCTAssertTrue(refreshedEvidence.quiescenceBlockers(domain: domain).isEmpty)
        try await claim.abortAndRelease(reason: "synthetic check; no mutation")

        var state = StorageOptimizationState(phase: .completed)
        state.coveredSourceCount = 13; state.total = 13; state.attempted = 13
        state.optimized = 5; state.skipped = 8
        for _ in 0..<8 { state.recordResult(code: "already-optimized", verifiedUnchanged: true) }
        for _ in 0..<5 { state.recordResult(code: "optimized") }
        XCTAssertEqual(state.safeDetails["already-optimized"], 8)
        XCTAssertEqual(state.terminalDisposition, .optimized)
        XCTAssertEqual(state.fileAllocationReduction, 0) // no old saving is added a second time
    }

    func testLegacyReferenceGenerationAndUnknownLiveOwnersStillInvalidateOrBlock() async throws {
        let directory = try root(), legacyRoot = directory.appendingPathComponent("v2")
        try FileManager.default.createDirectory(at: legacyRoot.appendingPathComponent("environments/legacy-env"),
                                               withIntermediateDirectories: true)
        let domain = try RuntimeV2MaintenanceDomain(trustedLegacyRoot: legacyRoot)
        let legacy = EnvironmentReference(source: .runBinding, ownerID: UUID(), conversationID: UUID(),
            environmentID: "legacy-env", backend: .linuxVM, bindingGeneration: 3,
            runtimeGeneration: "old-generation", state: "completed", classification: .retained, isLive: false)
        func project(_ row: EnvironmentReference) -> RuntimeV2MaintenanceReferenceEvidence {
            makeLegacyMaintenanceReferenceEvidence(from: .init(isComplete: true, blockers: [], references: [row]), domain: domain)
        }
        let first = project(legacy)
        let evidence = RuntimeV2MaintenanceOwnerEvidence(isComplete: true,
            integrator: .init(storeRootPath: domain.root.path), references: first)
        let coordinator = try RuntimeV2MaintenanceCoordinator(domain: domain,
            stateDirectory: directory.appendingPathComponent("authority"), evidenceProvider: { evidence })
        let claim = try await coordinator.acquireExclusiveMaintenance(.init(owner: "synthetic-ref-test", reason: "fingerprint"))
        var variants: [EnvironmentReference] = []
        var changed = legacy; changed.bindingGeneration = 4; variants.append(changed)
        changed = legacy; changed.runtimeGeneration = "new-generation"; variants.append(changed)
        changed = legacy; changed.ownerID = UUID(); variants.append(changed)
        changed = legacy; changed.conversationID = UUID(); variants.append(changed)
        changed = legacy; changed.state = "failed"; variants.append(changed)
        for value in variants {
            let fresh = project(value)
            XCTAssertNotEqual(first.fingerprint, fresh.fingerprint)
            XCTAssertThrowsError(try claim.validateReferenceFingerprint(fresh.fingerprint))
        }
        try await claim.abortAndRelease(reason: "synthetic check; no mutation")
        changed = legacy; changed.classification = .unknown; changed.isLive = true
        var unknown = evidence; unknown.references = project(changed)
        XCTAssertFalse(unknown.quiescenceBlockers(domain: domain).isEmpty)
        changed.environmentID = nil
        let unattributed = project(changed)
        XCTAssertEqual(unattributed.unattributedLiveUnknownCount, 1)
        unknown.references = unattributed
        XCTAssertFalse(unknown.quiescenceBlockers(domain: domain).isEmpty)
        let incomplete = makeLegacyMaintenanceReferenceEvidence(from: .init(isComplete: false,
            blockers: ["run_binding_unreadable"], references: [legacy]), domain: domain)
        XCTAssertFalse(incomplete.isComplete)
        XCTAssertEqual(incomplete.blockers, ["run_binding_unreadable"])
        XCTAssertNotEqual(incomplete.fingerprint, first.fingerprint)
    }

    func testActualPartialInventoryKeepsCauseAndNeverAdmitsOptimization() throws {
        let directory = try root(), vm = directory.appendingPathComponent("runtime/vm", isDirectory: true)
        try FileManager.default.createDirectory(at: vm, withIntermediateDirectories: true)
        for index in 0..<3 {
            try Data("keep-\(index)".utf8).write(to: vm.appendingPathComponent("unrecognized-\(index)"))
        }
        let report = scan(directory, limits: .init(maximumDirectoryEntries: 1))
        XCTAssertTrue(report.summary.isPartial)
        XCTAssertTrue(report.stopReasons.contains("entryBudget"), "Actual scan: \(report.stopReasons)")
        var state = StorageOptimizationState(phase: .checking)
        XCTAssertFalse(state.admitInventory(report, cancellationRequested: false))
        XCTAssertEqual(state.phase, .blocked)
        XCTAssertEqual(state.details["inventory-incomplete"], 1)
        XCTAssertEqual(state.inventoryEvidence?.stopReasons, ["entryBudget"])
        XCTAssertNotNil(state.inventoryNotice)
        XCTAssertEqual(state.attempted, 0)
        for index in 0..<3 {
            XCTAssertEqual(try Data(contentsOf: vm.appendingPathComponent("unrecognized-\(index)")), Data("keep-\(index)".utf8))
        }
    }

    func testMissingRootStillRefusesEvenIfPartialFlagIsIncorrect() throws {
        let directory = try root().appendingPathComponent("not-created", isDirectory: true)
        let observed = scan(directory)
        XCTAssertNil(observed.rootIdentity)
        XCTAssertEqual(observed.rootDiagnostic?.stage, .posixCanonicalization)
        XCTAssertEqual(observed.rootDiagnostic?.posixErrno, ENOENT)
        let report = try changing(observed) { object in
            var summary = object["summary"] as! [String: Any]
            summary["isPartial"] = false
            object["summary"] = summary
        }
        var state = StorageOptimizationState(phase: .checking)
        XCTAssertFalse(state.admitInventory(report, cancellationRequested: false))
        XCTAssertEqual(state.phase, .blocked)
        XCTAssertEqual(state.inventoryEvidence?.rootAvailable, false)
        XCTAssertEqual(state.inventoryEvidence?.rootDiagnostic?.posixErrno, ENOENT)
        XCTAssertEqual(state.attempted, 0)
    }

    func testActualCancelledScanIsCancelledRatherThanInventoryFailure() async throws {
        let directory = try root()
        let worker = Task.detached { () -> LegacyRecoveryInventoryReport in
            do { try await Task.sleep(for: .seconds(30)) } catch {}
            return LegacyRecoveryInventory.scan(.init(legacyRoot: directory, currentReferences: nil))
        }
        worker.cancel()
        let report = await worker.value
        XCTAssertTrue(report.stopReasons.contains("cancelled"))
        var state = StorageOptimizationState(phase: .checking)
        XCTAssertFalse(state.admitInventory(report, cancellationRequested: false))
        XCTAssertEqual(state.phase, .cancelled)
        XCTAssertNil(state.details["inventory-incomplete"])
        XCTAssertEqual(state.attempted, 0)
        XCTAssertNil(state.inventoryNotice)
    }

    func testCancellationAfterACompleteScanStillPreventsAdmission() throws {
        let report = scan(try root())
        XCTAssertFalse(report.summary.isPartial, "Actual scan: \(report.stopReasons)")
        XCTAssertNotNil(report.rootIdentity)
        var state = StorageOptimizationState(phase: .checking)
        XCTAssertFalse(state.admitInventory(report, cancellationRequested: true))
        XCTAssertEqual(state.phase, .cancelled)
        XCTAssertNil(state.details["inventory-incomplete"])
        XCTAssertEqual(state.attempted, 0)
    }

    func testPersistedActualRootFailureSurvivesBoundedFeedbackWithoutPaths() throws {
        let directory = try root().appendingPathComponent("not-created", isDirectory: true)
        let observed = scan(directory)
        let report = try changing(observed) { object in
            object["stopReasons"] = ["rootUnavailable", "untrusted-path-or-secret-marker"]
        }
        var state = StorageOptimizationState(phase: .checking, startedAt: Date(), appBuildFingerprint: "1.8.15.336")
        XCTAssertFalse(state.admitInventory(report, cancellationRequested: false))
        state.finishedAt = Date()
        let store = try defaults()
        StorageOptimizationService.persistSnapshot(state, to: store)
        let persisted = try XCTUnwrap(StorageOptimizationService.readSnapshot(from: store))
        XCTAssertEqual(persisted.inventoryEvidence?.rootDiagnostic?.posixErrno, ENOENT)
        XCTAssertEqual(persisted.inventoryEvidence?.unrecognizedStopReasonCount, 1)
        let body = StorageOptimizationService.diagnosticText(defaults: store)
        XCTAssertTrue(body.contains("optimization_root_failure_stage: posixCanonicalization"))
        XCTAssertTrue(body.contains("optimization_root_failure_errno: \(ENOENT)"))
        XCTAssertTrue(body.contains("optimization_inventory_stop_reasons: rootUnavailable"))
        XCTAssertTrue(body.contains("optimization_build: 1.8.15.336"))
        XCTAssertFalse(body.contains(directory.path))
        XCTAssertFalse(body.contains("untrusted-path-or-secret-marker"))
        let input = DiagnosticsExporter.render(sections: [
            .init(id: .storageSnapshot, body: body + "\n" + String(repeating: "cached-aggregate\n", count: 2_000)),
            .init(id: .recentLog, body: String(repeating: "bounded log\n", count: 20_000))
        ])
        let bounded = FeedbackUploadService.boundedDiagnostics(input)
        XCTAssertTrue(bounded.contains("optimization_root_failure_errno: \(ENOENT)"))
        XCTAssertTrue(bounded.contains("optimization_inventory_stop_reasons: rootUnavailable"))
        XCTAssertFalse(bounded.contains(directory.path))
        XCTAssertEqual(StorageOptimizationService.readSnapshot(from: store)?.phase, .blocked)
    }

    func testLegacyReceiptWithoutInventoryIsReportedAsUnrecorded() throws {
        let store = try defaults()
        let state = StorageOptimizationState(phase: .blocked, details: ["inventory-incomplete": 1])
        StorageOptimizationService.persistSnapshot(state, to: store)
        let text = StorageOptimizationService.diagnosticText(defaults: store)
        XCTAssertTrue(text.contains("optimization_inventory: not_recorded_in_this_receipt"))
        XCTAssertFalse(text.contains("optimization_root_failure_errno"))
        XCTAssertFalse(text.contains("optimization_inventory_stop_reasons"))
        let empty = try defaults()
        XCTAssertTrue(StorageOptimizationService.diagnosticText(defaults: empty).contains("optimization_evidence: unavailable"))
    }

    /// Actual App sandbox probe, not a macOS component substitute. Directly
    /// reading our own empty support directory must agree with inventory's
    /// anchor admission. No user environment, migration or disk is accessed.
    func testApplicationSandboxRootAgreesWithDirectNoFollowOpen() throws {
        let directory = try root()
        let canonical = try XCTUnwrap(directory.path.withCString { realpath($0, nil) })
        defer { free(canonical) }
        let fd = open(canonical, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        XCTAssertGreaterThanOrEqual(fd, 0, "Direct App-owned root errno=\(errno)")
        guard fd >= 0 else { return }
        defer { close(fd) }
        var identity = stat()
        XCTAssertEqual(fstat(fd, &identity), 0)
        let report = scan(directory)
        let note = XCTAttachment(string: "App sandbox actual rootAvailable=\(report.rootIdentity != nil) partial=\(report.summary.isPartial) reasons=\(report.stopReasons) stage=\(report.rootDiagnostic?.stage.rawValue ?? "none") errno=\(report.rootDiagnostic?.posixErrno ?? 0) component=\(report.rootDiagnostic?.componentIndex ?? -1)")
        note.name = "Actual App sandbox inventory anchor"; note.lifetime = .keepAlways; add(note)
        XCTAssertNotNil(report.rootIdentity, "Direct own-root read worked but inventory did not: \(report.stopReasons)")
        XCTAssertFalse(report.summary.isPartial)
        XCTAssertNil(report.rootDiagnostic)
        XCTAssertEqual(report.rootIdentity?.inode, UInt64(identity.st_ino))
        XCTAssertEqual(report.rootIdentity?.device, UInt64(bitPattern: Int64(identity.st_dev)))
        XCTAssertEqual(report.diskContentBytesRead, 0)
    }

    func testAdapterOwnerFailuresPersistAndReachBoundedFeedbackWithoutAttribution() throws {
        let marker = "synthetic-private-attribution/5BF7D933-7736-4675-BB2D-B10520710D82"
        var state = StorageOptimizationState(phase: .blocked, attempted: 1, appBuildFingerprint: "1.8.16.337")
        state.recordStage("disk-admission")
        state.recordResult(code: "owner-unknown", diagnosticCodes: [
            "legacy_registry_identity_changed:" + marker,
            "registry_session:" + marker,
            "unknown-" + marker
        ])
        let store = try defaults()
        StorageOptimizationService.persistSnapshot(state, to: store)
        let persisted = try XCTUnwrap(StorageOptimizationService.readSnapshot(from: store))
        XCTAssertEqual(persisted.details["owner-unknown"], 1)
        XCTAssertEqual(persisted.details["legacy_registry_identity_changed"], 1)
        XCTAssertEqual(persisted.details["registry_session"], 1)
        XCTAssertEqual(persisted.unrecognizedDiagnosticCodeCount, 1)
        XCTAssertEqual(persisted.terminalDisposition, .eligibilityBlocked)
        let text = StorageOptimizationService.diagnosticText(defaults: store)
        // These must survive even if failure preceded a completed inventory.
        XCTAssertTrue(text.contains("optimization_inventory: not_recorded_in_this_receipt"))
        XCTAssertTrue(text.contains("optimization_last_stage: disk-admission"))
        XCTAssertTrue(text.contains("optimization_last_result_code: owner-unknown"))
        XCTAssertTrue(text.contains("optimization_result.legacy_registry_identity_changed: 1"))
        XCTAssertFalse(text.contains(marker))
        let bounded = FeedbackUploadService.boundedDiagnostics(DiagnosticsExporter.render(sections: [
            .init(id: .storageSnapshot, body: text),
            .init(id: .recentLog, body: String(repeating: "bounded log\n", count: 20_000))
        ]))
        XCTAssertTrue(bounded.contains("optimization_result.legacy_registry_identity_changed: 1"))
        XCTAssertTrue(bounded.contains("optimization_last_result_code: owner-unknown"))
        XCTAssertFalse(bounded.contains(marker))
    }

    func testActualCoreProgressVocabularySurvivesLiveProgressClearAndRelaunch() throws {
        var state = StorageOptimizationState(phase: .optimizing, attempted: 1)
        let counting = StorageSparseDiskRewriteProgress(phase: .counting, processedBytes: 32, totalBytes: 128)
        XCTAssertTrue(state.recordStage(counting.phase.rawValue, processed: counting.processedBytes, total: counting.totalBytes))
        let verifying = StorageSparseDiskRewriteProgress(phase: .verifying, processedBytes: 96, totalBytes: 128)
        XCTAssertTrue(state.recordStage(verifying.phase.rawValue, processed: verifying.processedBytes, total: verifying.totalBytes))
        state.corePhase = verifying.phase.rawValue; state.fraction = 0.75
        state.recordResult(code: "write-failed")
        state.phase = .blocked
        // finish clears only live UI progress, not the observed phase receipt.
        state.corePhase = nil; state.fraction = nil; state.finishedAt = Date()
        let store = try defaults()
        StorageOptimizationService.persistSnapshot(state, to: store)
        let persisted = try XCTUnwrap(StorageOptimizationService.readSnapshot(from: store))
        XCTAssertNil(persisted.corePhase)
        XCTAssertNil(persisted.fraction)
        XCTAssertEqual(persisted.lastStage, "verifying")
        XCTAssertNotNil(persisted.lastStageObservedAt)
        XCTAssertEqual(persisted.lastProcessedBytes, 96)
        XCTAssertEqual(persisted.lastTotalBytes, 128)
        let text = StorageOptimizationService.diagnosticText(defaults: store)
        XCTAssertTrue(text.contains("optimization_last_stage: verifying"))
        XCTAssertTrue(text.contains("optimization_last_processed_bytes: 96"))
        XCTAssertTrue(text.contains("optimization_last_total_bytes: 128"))
        XCTAssertTrue(text.contains("optimization_last_result_code: write-failed"))
        XCTAssertFalse(state.recordStage("synthetic-untrusted-stage"))
        XCTAssertEqual(state.lastStage, "verifying")
        XCTAssertTrue(state.recordStage("disk-admission"))
        XCTAssertNil(state.lastProcessedBytes, "A new disk must not inherit the previous disk's counters")
        XCTAssertNil(state.lastTotalBytes)
    }

    func testTerminalOutcomesDistinguishCoverageEligibilityPrimitiveAndVerifiedNoGain() {
        var uncovered = StorageOptimizationState(phase: .completed)
        uncovered.coveredSourceCount = 0; uncovered.eligibleSourceCount = 0
        uncovered.recordDiagnostic("no-covered-sources")
        XCTAssertEqual(uncovered.terminalDisposition, .notCovered)

        var ineligible = StorageOptimizationState(phase: .blocked, details: ["sources-not-eligible": 1])
        ineligible.coveredSourceCount = 1; ineligible.eligibleSourceCount = 0
        XCTAssertEqual(ineligible.terminalDisposition, .eligibilityBlocked)

        var unsupported = StorageOptimizationState(phase: .blocked, attempted: 1)
        unsupported.recordResult(code: "clone-unavailable")
        XCTAssertEqual(unsupported.terminalDisposition, .methodUnavailable)

        var unverified = StorageOptimizationState(phase: .completed, attempted: 1)
        unverified.recordResult(code: "insufficient-reclaim")
        XCTAssertEqual(unverified.terminalDisposition, .stopped)
        XCTAssertNil(unverified.verifiedNoGainCount)

        var noGain = StorageOptimizationState(phase: .completed, attempted: 1)
        noGain.recordResult(code: "insufficient-reclaim", verifiedUnchanged: true)
        XCTAssertEqual(noGain.terminalDisposition, .verifiedNoGain)
        XCTAssertEqual(noGain.verifiedNoGainCount, 1)
        for state in [uncovered, ineligible, unsupported, unverified, noGain] {
            XCTAssertNotNil(state.terminalNotice)
        }
    }

    func testRecoveryReceiptDoesNotKeepShowingResolvedPendingFailure() {
        var state = StorageOptimizationState(phase: .blocked)
        state.recordResult(code: "recovery-pending")
        XCTAssertEqual(state.terminalDisposition, .recoveryPending)
        state.phase = .completed
        state.recordStage("recovery-check")
        state.recordResult(code: "recovery-resolved")
        XCTAssertEqual(state.terminalDisposition, .recovered)
        XCTAssertEqual(state.details["recovery-pending"], 1, "Preserve the original failure evidence")
        XCTAssertNotNil(state.terminalNotice)
    }

    func testOldCompletedReceiptDoesNotInventCoverageStageOrVerifiedNoGain() throws {
        let state = StorageOptimizationState(phase: .completed, attempted: 1, details: ["insufficient-reclaim": 1])
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(state)) as? [String: Any])
        for key in ["lastStage", "lastStageObservedAt", "lastProcessedBytes", "lastTotalBytes", "lastResultCode",
                    "verifiedNoGainCount", "coveredSourceCount", "eligibleSourceCount", "unrecognizedDiagnosticCodeCount"] {
            object.removeValue(forKey: key)
        }
        let store = try defaults()
        store.set(try JSONSerialization.data(withJSONObject: object), forKey: "floe.storage.legacyOptimization.lastResult.v1")
        let persisted = try XCTUnwrap(StorageOptimizationService.readSnapshot(from: store))
        XCTAssertEqual(persisted.phase, .completed)
        XCTAssertEqual(persisted.details["insufficient-reclaim"], 1)
        XCTAssertNil(persisted.lastStage)
        XCTAssertNil(persisted.coveredSourceCount)
        XCTAssertNil(persisted.verifiedNoGainCount)
        XCTAssertEqual(persisted.terminalDisposition, .stopped)
        let text = StorageOptimizationService.diagnosticText(defaults: store)
        XCTAssertTrue(text.contains("optimization_last_stage: unrecorded"))
        XCTAssertTrue(text.contains("optimization_covered_sources: unrecorded"))
        XCTAssertTrue(text.contains("optimization_verified_no_gain: unrecorded"))
        XCTAssertTrue(text.contains("optimization_result.insufficient-reclaim: 1"))
    }

    func testUntrustedDiagnosticKeysAreRemovedBeforeBoundedSnapshotStorage() throws {
        var state = StorageOptimizationState(phase: .blocked, details: ["owner-unknown": Int.max])
        for index in 0..<400 { state.details["synthetic-private-key-\(index)"] = 1 }
        state.unrecognizedDiagnosticCodeCount = Int.max
        state.recordDiagnostic("synthetic-private-added")
        state.recordDiagnostic("owner-unknown:synthetic-private-attribute")
        state.lastResultCode = "untrusted-result:synthetic-private-value"
        state.lastStage = "synthetic-private-stage"
        let store = try defaults()
        StorageOptimizationService.persistSnapshot(state, to: store)
        let encoded = try XCTUnwrap(store.data(forKey: "floe.storage.legacyOptimization.lastResult.v1"))
        XCTAssertLessThanOrEqual(encoded.count, 16_384)
        XCTAssertFalse(String(decoding: encoded, as: UTF8.self).contains("synthetic-private"))
        let persisted = try XCTUnwrap(StorageOptimizationService.readSnapshot(from: store))
        XCTAssertEqual(persisted.details, ["owner-unknown": 1_000_000])
        XCTAssertEqual(persisted.unrecognizedDiagnosticCodeCount, 1_000_000)
        XCTAssertNil(persisted.lastResultCode)
        XCTAssertNil(persisted.lastStage)
        XCTAssertFalse(StorageOptimizationService.diagnosticText(defaults: store).contains("synthetic-private"))
    }
}
#endif
