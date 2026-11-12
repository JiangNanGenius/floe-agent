// SPDX-License-Identifier: MPL-2.0
#if canImport(UIKit)
import Darwin
import Foundation
import XCTest
import FloeExecution
@testable import FloeApp

@MainActor final class StorageOptimizationDiagnosticsTests: XCTestCase {
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
}
#endif
