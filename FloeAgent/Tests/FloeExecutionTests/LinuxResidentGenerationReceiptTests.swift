import Foundation
import XCTest
import FloeCore
@testable import FloeExecution

final class LinuxResidentGenerationReceiptTests: XCTestCase, @unchecked Sendable {
    private struct Fixture: Sendable {
        let root: URL
        let oldBytes = Data("old-installed-software".utf8)
        let newBytes = Data("fresh-linux".utf8)
        var current: URL { LinuxResidentDiskStorage.directory(in: root) }

        init() throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent("resident-generation-" + UUID().uuidString)
            try FileManager.default.createDirectory(at: current, withIntermediateDirectories: true)
            try oldBytes.write(to: current.appendingPathComponent("disk.img"))
            try writeOrigin(current, imageID: "trusted-old", count: oldBytes.count)
        }
        func remove() { try? FileManager.default.removeItem(at: root) }
        func writeOrigin(_ directory: URL, imageID: String, count: Int) throws {
            let origin = LinuxGuestRuntimeDiskOrigin(imageID: imageID, artifactSHA512: String(repeating: "a", count: 128),
                artifactBytes: Int64(count), logicalCapacityBytes: Int64(count))
            let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
            try encoder.encode(origin).write(to: directory.appendingPathComponent("origin.json"))
        }
        func readOrigin(_ directory: URL) throws -> LinuxGuestRuntimeDiskOrigin {
            let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
            return try decoder.decode(LinuxGuestRuntimeDiskOrigin.self, from: Data(contentsOf: directory.appendingPathComponent("origin.json")))
        }
        func prepare(_ build: URL) throws -> URL {
            let directory = LinuxResidentDiskStorage.directory(in: build)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try newBytes.write(to: directory.appendingPathComponent("disk.img"))
            try writeOrigin(directory, imageID: "trusted-new", count: newBytes.count)
            return directory
        }
        func rebuild(hooks: LinuxResidentRecoveryStore.Hooks = .init()) throws -> LinuxResidentRecoveryReceipt {
            let transaction = try LinuxResidentRecoveryStore(root: root, hooks: hooks).begin(imageID: "trusted-new")
            defer { transaction.endAdmission() }
            return try transaction.replace { try prepare($0) }
        }
    }
    private enum Fault: Error { case injected }

    func testOnlyCommittedSwapPublishesRecoveryGeneration() throws {
        let f = try Fixture(); defer { f.remove() }
        XCTAssertNil(try LinuxResidentDiskBarrier.currentRecoveryReceipt(root: f.root))
        let oldOrigin = try Data(contentsOf: f.current.appendingPathComponent("origin.json"))
        let receipt = try f.rebuild()
        let observed = try XCTUnwrap(LinuxResidentDiskBarrier.currentRecoveryReceipt(root: f.root))
        XCTAssertEqual(observed.recoveryID, receipt.recoveryID)
        XCTAssertEqual(observed.runtimeGeneration, LinuxResidentRuntimeGeneration.value(recoveryID: receipt.recoveryID))
        XCTAssertEqual(try f.readOrigin(f.current).residentRecoveryID, receipt.recoveryID)
        let retained = f.root.appendingPathComponent(try XCTUnwrap(receipt.preservedRelativePath))
        XCTAssertEqual(try Data(contentsOf: retained.appendingPathComponent("origin.json")), oldOrigin)
        XCTAssertEqual(try Data(contentsOf: retained.appendingPathComponent("disk.img")), f.oldBytes)
    }

    func testPrecommitCancellationDoesNotMintAGeneration() throws {
        let f = try Fixture(); defer { f.remove() }
        let transaction = try LinuxResidentRecoveryStore(root: f.root).begin(imageID: "trusted-new")
        XCTAssertThrowsError(try transaction.replace { _ in throw CancellationError() })
        transaction.endAdmission()
        XCTAssertNil(try f.readOrigin(f.current).residentRecoveryID)
        XCTAssertNil(try LinuxResidentDiskBarrier.currentRecoveryReceipt(root: f.root))
        XCTAssertEqual(try Data(contentsOf: f.current.appendingPathComponent("disk.img")), f.oldBytes)
    }

    func testInterruptedPostSwapIsConvergedBeforeReceiptPublication() throws {
        let f = try Fixture(); defer { f.remove() }
        XCTAssertThrowsError(try f.rebuild(hooks: .init(event: { event in
            if case .afterExchange = event { throw Fault.injected }
        })))
        let marker = try XCTUnwrap(f.readOrigin(f.current).residentRecoveryID)
        let receipt = try XCTUnwrap(LinuxResidentDiskBarrier.currentRecoveryReceipt(root: f.root))
        XCTAssertEqual(receipt.recoveryID, marker)
        let retained = f.root.appendingPathComponent(try XCTUnwrap(receipt.preservedRelativePath))
        XCTAssertEqual(try Data(contentsOf: retained.appendingPathComponent("disk.img")), f.oldBytes)
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.root.appendingPathComponent(".resident-recovery/pending.json").path))
    }

    func testOrdinaryGuestWritesAndGrowthRetainThePhysicalGeneration() throws {
        let f = try Fixture(); defer { f.remove() }
        let receipt = try f.rebuild()
        let handle = try FileHandle(forWritingTo: f.current.appendingPathComponent("disk.img"))
        try handle.seekToEnd(); try handle.write(contentsOf: Data("user-writes-and-growth".utf8)); try handle.close()
        let observed = try XCTUnwrap(LinuxResidentDiskBarrier.currentRecoveryReceipt(root: f.root))
        XCTAssertEqual(observed.runtimeGeneration, receipt.runtimeGeneration)
    }

    func testReplacingPhysicalDiskCannotReuseThePreviousReceipt() throws {
        let f = try Fixture(); defer { f.remove() }
        _ = try f.rebuild()
        try f.newBytes.write(to: f.current.appendingPathComponent("disk.img"), options: .atomic)
        XCTAssertThrowsError(try LinuxResidentDiskBarrier.currentRecoveryReceipt(root: f.root)) {
            XCTAssertEqual($0 as? LinuxResidentRecoveryError, .identityChanged)
        }
        XCTAssertEqual(try Data(contentsOf: f.current.appendingPathComponent("disk.img")), f.newBytes)
    }

    func testOrdinaryFreshOriginDoesNotSelectAnOldHistoryRecord() throws {
        let f = try Fixture(); defer { f.remove() }
        _ = try f.rebuild()
        try FileManager.default.moveItem(at: f.current, to: f.root.appendingPathComponent("test-retired-current"))
        try FileManager.default.createDirectory(at: f.current, withIntermediateDirectories: true)
        try f.newBytes.write(to: f.current.appendingPathComponent("disk.img"))
        try f.writeOrigin(f.current, imageID: "trusted-new", count: f.newBytes.count)
        XCTAssertNil(try LinuxResidentDiskBarrier.currentRecoveryReceipt(root: f.root))
    }

    func testMissingCommittedRecordDoesNotBecomeAnUnknownGeneration() throws {
        let f = try Fixture(); defer { f.remove() }
        let receipt = try f.rebuild()
        let record = f.root.appendingPathComponent("recovery/\(receipt.recoveryID.uuidString.lowercased())/record.json")
        try FileManager.default.moveItem(at: record, to: record.appendingPathExtension("held-test"))
        XCTAssertThrowsError(try LinuxResidentDiskBarrier.currentRecoveryReceipt(root: f.root))
        XCTAssertEqual(try Data(contentsOf: f.current.appendingPathComponent("disk.img")), f.newBytes)
    }

    func testConfirmedGenerationGuardBlocksAnotherRebuildUntilItFinishes() throws {
        let f = try Fixture(); defer { f.remove() }
        let receipt = try f.rebuild()
        let physicalGuard = try LinuxResidentDiskBarrier.acquireRecoveryGuard(root: f.root)
        XCTAssertEqual(try XCTUnwrap(physicalGuard.receipt).runtimeGeneration, receipt.runtimeGeneration)
        XCTAssertThrowsError(try LinuxResidentRecoveryStore(root: f.root).begin(imageID: "trusted-new")) {
            XCTAssertEqual($0 as? LinuxResidentRecoveryError, .busy)
        }
        physicalGuard.finish()
        let next = try LinuxResidentRecoveryStore(root: f.root).begin(imageID: "trusted-new")
        next.endAdmission()
        let observed = try XCTUnwrap(LinuxResidentDiskBarrier.currentRecoveryReceipt(root: f.root))
        XCTAssertEqual(observed.runtimeGeneration, receipt.runtimeGeneration)
    }

    func testNestedToolReadGuardAllowsActualStartClaimWithoutAnExclusiveUpgrade() throws {
        let f = try Fixture(); defer { f.remove() }
        let receipt = try f.rebuild()
        let toolGuard = try LinuxResidentDiskBarrier.acquireRecoveryGuard(root: f.root)
        defer { toolGuard.finish() }
        let use = try LinuxResidentDiskBarrier.acquireUse(root: f.root)
        use.releaseAfterConfirmedClose()
        XCTAssertEqual(try XCTUnwrap(toolGuard.receipt).runtimeGeneration, receipt.runtimeGeneration)
        XCTAssertEqual(try LinuxResidentDiskBarrier.currentRecoveryReceipt(root: f.root)?.runtimeGeneration, receipt.runtimeGeneration)
        XCTAssertThrowsError(try LinuxResidentRecoveryStore(root: f.root).begin(imageID: "trusted-new"))
    }

    func testUnexpectedIntentUnderAHeldReadGuardFailsClosedWithoutAnUpgrade() throws {
        let f = try Fixture(); defer { f.remove() }
        _ = try f.rebuild()
        let toolGuard = try LinuxResidentDiskBarrier.acquireRecoveryGuard(root: f.root)
        defer { toolGuard.finish() }
        // Simulates an uncooperative/corrupt writer. Cooperating begin() is
        // already blocked by SH. A readonly call must not try a blocking upgrade.
        let pending = f.root.appendingPathComponent(".resident-recovery/pending.json")
        try Data("{\"version\":1,\"id\":\"\(UUID().uuidString)\"}".utf8).write(to: pending)
        XCTAssertThrowsError(try LinuxResidentDiskBarrier.currentRecoveryReceipt(root: f.root)) {
            XCTAssertEqual($0 as? LinuxResidentRecoveryError, .busy)
        }
        XCTAssertEqual(try Data(contentsOf: f.current.appendingPathComponent("disk.img")), f.newBytes)
    }

    func testSymlinkedCurrentIsNotReadAsACommittedEnvironment() throws {
        let f = try Fixture(); defer { f.remove() }
        _ = try f.rebuild()
        let outside = f.root.appendingPathComponent("test-preserved-outside")
        try FileManager.default.moveItem(at: f.current, to: outside)
        try FileManager.default.createSymbolicLink(at: f.current, withDestinationURL: outside)
        XCTAssertThrowsError(try LinuxResidentDiskBarrier.currentRecoveryReceipt(root: f.root))
        XCTAssertEqual(try Data(contentsOf: outside.appendingPathComponent("disk.img")), f.newBytes)
    }
}
