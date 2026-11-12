import Foundation
import XCTest
@testable import FloeExecution

/// Actual small directories, raw disk bytes and POSIX claims. These tests do
/// not start a VM, download an image or change any existing runtime data.
final class LinuxResidentRecoveryTests: XCTestCase, @unchecked Sendable {
    private struct Fixture: Sendable {
        let root: URL
        let oldBytes = Data([0, 9, 0, 255, 3]) + Data("installed-software-and-user-state".utf8)
        let newBytes = Data("verified-fresh-runtime".utf8)
        var current: URL { LinuxResidentDiskStorage.directory(in: root) }
        var pending: URL { root.appendingPathComponent(".resident-recovery/pending.json") }

        init(existing: Bool = true) throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent("resident-recovery-tests-" + UUID().uuidString)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            if existing {
                try FileManager.default.createDirectory(at: current, withIntermediateDirectories: true)
                try oldBytes.write(to: current.appendingPathComponent("disk.img"))
                // Invalid/unknown provenance is intentionally retained verbatim.
                try Data("old-unreadable-origin".utf8).write(to: current.appendingPathComponent("origin.json"))
            }
        }
        func remove() { try? FileManager.default.removeItem(at: root) }
        func prepare(_ build: URL, origin: Bool = true) throws -> URL {
            let directory = LinuxResidentDiskStorage.directory(in: build)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try newBytes.write(to: directory.appendingPathComponent("disk.img"))
            if origin {
                let value = LinuxGuestRuntimeDiskOrigin(imageID: "trusted-new", artifactSHA512: String(repeating: "a", count: 128),
                    artifactBytes: Int64(newBytes.count), logicalCapacityBytes: Int64(newBytes.count))
                let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
                try encoder.encode(value).write(to: directory.appendingPathComponent("origin.json"))
            }
            return directory
        }
        func bytes(_ directory: URL) throws -> Data { try Data(contentsOf: directory.appendingPathComponent("disk.img")) }
        func operationID() throws -> String {
            let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: pending)) as? [String: Any])
            return try XCTUnwrap(object["id"] as? String).lowercased()
        }
        func previous(_ id: String) -> URL { root.appendingPathComponent("recovery/\(id)/previous") }
    }

    private final class StageTrace: @unchecked Sendable {
        private let lock = NSLock()
        private var events: [String] = []
        func record(_ value: String) { lock.withLock { events.append(value) } }
        var values: [String] { lock.withLock { events } }
    }

    func testProgressDescribesRealCandidateCreationAndOldDiskRetention() throws {
        let f = try Fixture(); defer { f.remove() }
        let trace = StageTrace()
        let store = try LinuxResidentRecoveryStore(root: f.root, hooks: .init(event: { event in
            switch event {
            case .candidateDurable: trace.record("candidate-durable")
            case .beforeExchange: trace.record("before-exchange")
            default: break
            }
        }))
        let transaction = try store.begin(imageID: "trusted-new")
        defer { transaction.endAdmission() }
        let receipt = try transaction.replace(onPhase: { trace.record($0.rawValue) }) { build in
            trace.record("prepare-actual-bytes")
            return try f.prepare(build)
        }
        XCTAssertEqual(trace.values, ["creatingEnvironment", "prepare-actual-bytes", "candidate-durable", "retainingEnvironment", "before-exchange"])
        XCTAssertEqual(try f.bytes(f.current), f.newBytes)
        let retained = f.root.appendingPathComponent(try XCTUnwrap(receipt.preservedRelativePath))
        XCTAssertEqual(try f.bytes(retained), f.oldBytes)
    }

    func testFailedPreparationNeverReportsOldDiskRetainedOrCompleted() throws {
        let f = try Fixture(); defer { f.remove() }
        let trace = StageTrace()
        let transaction = try LinuxResidentRecoveryStore(root: f.root).begin(imageID: "trusted-new")
        defer { transaction.endAdmission() }
        XCTAssertThrowsError(try transaction.replace(onPhase: { trace.record($0.rawValue) }) { _ in throw Fault.injected })
        XCTAssertEqual(trace.values, ["creatingEnvironment"])
        XCTAssertEqual(try f.bytes(f.current), f.oldBytes)
    }

    private enum Fault: Error { case injected }

    func testAtomicExchangeRetainsEveryOldByteAndSameDiskInode() throws {
        let f = try Fixture(); defer { f.remove() }
        let disk = f.current.appendingPathComponent("disk.img")
        let oldIdentity = try LinuxResidentRecoveryStore.Node.read(disk)
        try Data("additional-retained-state".utf8).write(to: f.current.appendingPathComponent("package-state.bin"))
        let store = try LinuxResidentRecoveryStore(root: f.root)
        let transaction = try store.begin(imageID: "trusted-new")
        defer { transaction.endAdmission() }
        let receipt = try transaction.replace(prepare: { try f.prepare($0) })
        let retained = f.root.appendingPathComponent(try XCTUnwrap(receipt.preservedRelativePath))
        XCTAssertEqual(try f.bytes(f.current), f.newBytes)
        XCTAssertEqual(try f.bytes(retained), f.oldBytes)
        XCTAssertEqual(try LinuxResidentRecoveryStore.Node.read(retained.appendingPathComponent("disk.img")), oldIdentity)
        XCTAssertEqual(try String(contentsOf: retained.appendingPathComponent("origin.json"), encoding: .utf8), "old-unreadable-origin")
        XCTAssertEqual(try String(contentsOf: retained.appendingPathComponent("package-state.bin"), encoding: .utf8), "additional-retained-state")
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.pending.path))
    }

    func testFreshRuntimeDoesNotInventARecoveryCopy() throws {
        let f = try Fixture(existing: false); defer { f.remove() }
        let transaction = try LinuxResidentRecoveryStore(root: f.root).begin(imageID: "trusted-new")
        defer { transaction.endAdmission() }
        let receipt = try transaction.replace(prepare: { try f.prepare($0) })
        XCTAssertNil(receipt.preservedRelativePath)
        XCTAssertEqual(try f.bytes(f.current), f.newBytes)
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.previous(receipt.recoveryID.uuidString.lowercased()).path))
    }

    func testSecondFactoryCannotOwnSamePhysicalDisk() throws {
        let f = try Fixture(); defer { f.remove() }
        let first = try LinuxResidentDiskBarrier.acquireUse(root: f.root)
        defer { first.releaseAfterConfirmedClose() }
        XCTAssertThrowsError(try LinuxResidentDiskBarrier.acquireUse(root: f.root)) {
            XCTAssertEqual($0 as? LinuxResidentRecoveryError, .busy)
        }
        XCTAssertEqual(try f.bytes(f.current), f.oldBytes)
    }

    func testPhysicalUseBlocksReplacementBeforePrepareOrAnySwap() throws {
        let f = try Fixture(); defer { f.remove() }
        let use = try LinuxResidentDiskBarrier.acquireUse(root: f.root)
        let transaction = try LinuxResidentRecoveryStore(root: f.root).begin(imageID: "trusted-new")
        var prepared = false
        XCTAssertThrowsError(try transaction.replace { build in prepared = true; return try f.prepare(build) }) {
            XCTAssertEqual($0 as? LinuxResidentRecoveryError, .busy)
        }
        XCTAssertFalse(prepared)
        XCTAssertEqual(try f.bytes(f.current), f.oldBytes)
        transaction.endAdmission()
        // Age or a closed view cannot release the physical use. The actual
        // machine owner must confirm close before another use may proceed.
        XCTAssertThrowsError(try LinuxResidentDiskBarrier.acquireUse(root: f.root))
        use.releaseAfterConfirmedClose()
        let next = try LinuxResidentDiskBarrier.acquireUse(root: f.root)
        next.releaseAfterConfirmedClose()
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.pending.path))
        XCTAssertEqual(try f.bytes(f.current), f.oldBytes)
    }

    func testDurableAdmissionIntentBlocksNewStartsBeforeShutdownFinishes() throws {
        let f = try Fixture(); defer { f.remove() }
        let transaction = try LinuxResidentRecoveryStore(root: f.root).begin(imageID: "trusted-new")
        XCTAssertTrue(FileManager.default.fileExists(atPath: f.pending.path))
        XCTAssertThrowsError(try LinuxResidentDiskBarrier.acquireUse(root: f.root))
        transaction.endAdmission()
        let next = try LinuxResidentDiskBarrier.acquireUse(root: f.root)
        next.releaseAfterConfirmedClose()
        XCTAssertEqual(try f.bytes(f.current), f.oldBytes)
    }

    func testFailureBeforeExchangeLeavesOriginalAndRetainsPreparedCandidate() throws {
        let f = try Fixture(); defer { f.remove() }
        let store = try LinuxResidentRecoveryStore(root: f.root, hooks: .init(event: {
            if case .beforeExchange = $0 { throw Fault.injected }
        }))
        let transaction = try store.begin(imageID: "trusted-new")
        defer { transaction.endAdmission() }
        let id = try f.operationID()
        XCTAssertThrowsError(try transaction.replace(prepare: { try f.prepare($0) }))
        XCTAssertEqual(try f.bytes(f.current), f.oldBytes)
        XCTAssertEqual(try f.bytes(f.previous(id)), f.newBytes)
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.pending.path))
    }

    func testInterruptedExchangeConvergesByInodesWithoutDeletingOldDisk() throws {
        let f = try Fixture(); defer { f.remove() }
        let store = try LinuxResidentRecoveryStore(root: f.root, hooks: .init(event: {
            if case .afterExchange = $0 { throw Fault.injected }
        }))
        let transaction = try store.begin(imageID: "trusted-new")
        let id = try f.operationID()
        XCTAssertThrowsError(try transaction.replace(prepare: { try f.prepare($0) }))
        XCTAssertEqual(try f.bytes(f.current), f.newBytes)
        XCTAssertEqual(try f.bytes(f.previous(id)), f.oldBytes)
        XCTAssertTrue(FileManager.default.fileExists(atPath: f.pending.path))
        transaction.endAdmission()
        let resumed = try LinuxResidentDiskBarrier.acquireUse(root: f.root)
        resumed.releaseAfterConfirmedClose()
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.pending.path))
        XCTAssertEqual(try f.bytes(f.previous(id)), f.oldBytes)
    }

    func testCommittedReceiptWithoutFenceRemovalRemainsRecoverable() throws {
        let f = try Fixture(); defer { f.remove() }
        let store = try LinuxResidentRecoveryStore(root: f.root, hooks: .init(event: {
            if case .committedRecordWritten = $0 { throw Fault.injected }
        }))
        let transaction = try store.begin(imageID: "trusted-new")
        let id = try f.operationID()
        XCTAssertThrowsError(try transaction.replace(prepare: { try f.prepare($0) }))
        XCTAssertTrue(FileManager.default.fileExists(atPath: f.pending.path))
        transaction.endAdmission()
        let resumed = try LinuxResidentDiskBarrier.acquireUse(root: f.root)
        resumed.releaseAfterConfirmedClose()
        XCTAssertEqual(try f.bytes(f.current), f.newBytes)
        XCTAssertEqual(try f.bytes(f.previous(id)), f.oldBytes)
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.pending.path))
    }

    func testUnknownReplacementDoesNotClearFenceOrDeleteEitherDirectory() throws {
        let f = try Fixture(); defer { f.remove() }
        let store = try LinuxResidentRecoveryStore(root: f.root, hooks: .init(event: { event in
            if case .afterExchange = event {
                try Data("unknown-later-writer".utf8).write(to: f.current.appendingPathComponent("disk.img"), options: .atomic)
                throw Fault.injected
            }
        }))
        let transaction = try store.begin(imageID: "trusted-new")
        let id = try f.operationID()
        XCTAssertThrowsError(try transaction.replace(prepare: { try f.prepare($0) }))
        transaction.endAdmission()
        XCTAssertThrowsError(try LinuxResidentDiskBarrier.acquireUse(root: f.root)) {
            XCTAssertEqual($0 as? LinuxResidentRecoveryError, .identityChanged)
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: f.pending.path))
        XCTAssertEqual(try f.bytes(f.previous(id)), f.oldBytes)
        XCTAssertEqual(try f.bytes(f.current), Data("unknown-later-writer".utf8))
    }

    func testCandidateWithoutOriginCannotReplaceExistingDisk() throws {
        let f = try Fixture(); defer { f.remove() }
        let transaction = try LinuxResidentRecoveryStore(root: f.root).begin(imageID: "trusted-new")
        defer { transaction.endAdmission() }
        XCTAssertThrowsError(try transaction.replace { try f.prepare($0, origin: false) })
        XCTAssertEqual(try f.bytes(f.current), f.oldBytes)
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.pending.path))
    }

    func testPreparingCancellationNeverRemovesOriginalDisk() throws {
        let f = try Fixture(); defer { f.remove() }
        let transaction = try LinuxResidentRecoveryStore(root: f.root).begin(imageID: "trusted-new")
        defer { transaction.endAdmission() }
        XCTAssertThrowsError(try transaction.replace { _ in throw CancellationError() })
        XCTAssertEqual(try f.bytes(f.current), f.oldBytes)
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.pending.path))
    }

    func testSymlinkCurrentIsRetainedWithoutFollowingOrSwappingIt() throws {
        let f = try Fixture(existing: false); defer { f.remove() }
        let outside = f.root.appendingPathComponent("outside")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try f.oldBytes.write(to: outside.appendingPathComponent("disk.img"))
        try FileManager.default.createDirectory(at: f.current.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: f.current, withDestinationURL: outside)
        let transaction = try LinuxResidentRecoveryStore(root: f.root).begin(imageID: "trusted-new")
        defer { transaction.endAdmission() }
        XCTAssertThrowsError(try transaction.replace(prepare: { try f.prepare($0) }))
        XCTAssertEqual(try f.bytes(outside), f.oldBytes)
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: f.current.path), outside.path)
    }

    func testExistingForeignCandidateIsNotOverwrittenOrDeleted() throws {
        let f = try Fixture(); defer { f.remove() }
        let transaction = try LinuxResidentRecoveryStore(root: f.root).begin(imageID: "trusted-new")
        defer { transaction.endAdmission() }
        let foreign = f.previous(try f.operationID())
        try FileManager.default.createDirectory(at: foreign, withIntermediateDirectories: true)
        let foreignBytes = Data("foreign-recovery-data".utf8)
        try foreignBytes.write(to: foreign.appendingPathComponent("disk.img"))
        XCTAssertThrowsError(try transaction.replace(prepare: { try f.prepare($0) }))
        XCTAssertEqual(try f.bytes(f.current), f.oldBytes)
        XCTAssertEqual(try f.bytes(foreign), foreignBytes)
    }

    func testUnknownProvenanceNeverBecomesExactDefaultRedownload() {
        for error in [LinuxResidentImageResolutionError.invalidOrigin, .unknownOrigin, .originMismatch, .ambiguousOrigin, .missingDisk] {
            XCTAssertNil(error.recoverableImageID)
            XCTAssertTrue(error.permitsPreservingRebuild)
        }
        XCTAssertEqual(LinuxResidentImageResolutionError.sourceUnavailable(imageID: "original-only").recoverableImageID, "original-only")
        XCTAssertFalse(LinuxResidentImageResolutionError.sourceUnavailable(imageID: "original-only").permitsPreservingRebuild)
        XCTAssertFalse(LinuxResidentImageResolutionError.storageUnavailable.permitsPreservingRebuild)
    }
}
