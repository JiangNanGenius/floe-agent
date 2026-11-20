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

    // MARK: - Reboot-stable committed identity (volume UUID + inode)

    private func node(device: UInt64, inode: UInt64, mode: UInt32 = UInt32(S_IFDIR) | 0o755, volumeUUID: String? = nil) -> LinuxResidentRecoveryStore.Node {
        LinuxResidentRecoveryStore.Node(device: device, inode: inode, mode: mode, size: 128,
            modificationSeconds: 1, modificationNanoseconds: 0, volumeUUID: volumeUUID)
    }

    /// A host reboot remounts the same volume under a new `st_dev`. New
    /// receipts carry the volume UUID, so the same disk must still be
    /// recognized; the historical device+inode check would refuse it here.
    func testCommittedIdentityAcceptsSameVolumeAndInodeAcrossDeviceRenumbering() {
        let before = node(device: 16777231, inode: 147868626, volumeUUID: "EB0E1FF7-34D6-48EB-B16C-1BE038E1E803")
        let after = node(device: 16777230, inode: 147868626, volumeUUID: "EB0E1FF7-34D6-48EB-B16C-1BE038E1E803")
        XCTAssertTrue(before.sameDirectory(as: after))
        XCTAssertTrue(before.sameFile(as: after))
    }

    /// A different volume reusing an inode is not the same filesystem object.
    func testCommittedIdentityRefusesSameInodeOnDifferentVolume() {
        let first = node(device: 16777231, inode: 147868626, volumeUUID: "EB0E1FF7-34D6-48EB-B16C-1BE038E1E803")
        let second = node(device: 16777231, inode: 147868626, volumeUUID: "992012D2-29F9-4B6B-827E-ECD7A284F2AA")
        XCTAssertFalse(first.sameDirectory(as: second))
        XCTAssertFalse(first.sameFile(as: second))
    }

    /// A replaced disk has a new inode on the same volume and must be refused.
    func testCommittedIdentityRefusesReplacedInode() {
        let original = node(device: 16777230, inode: 147868627, mode: UInt32(S_IFREG) | 0o644, volumeUUID: "EB0E1FF7-34D6-48EB-B16C-1BE038E1E803")
        let replaced = node(device: 16777230, inode: 150000001, mode: UInt32(S_IFREG) | 0o644, volumeUUID: "EB0E1FF7-34D6-48EB-B16C-1BE038E1E803")
        XCTAssertFalse(original.sameFile(as: replaced))
        XCTAssertFalse(original.sameDirectory(as: replaced))
    }

    /// Old committed receipts have no volume UUID: they keep the historical
    /// device+inode comparison and are never silently matched against a new
    /// observation from a renumbered volume.
    func testOldReceiptWithoutVolumeUUIDFallsBackToDeviceAndRefusesRenumbering() {
        let oldReceipt = node(device: 16777231, inode: 147868626, volumeUUID: nil)
        let renumbered = node(device: 16777230, inode: 147868626, volumeUUID: "EB0E1FF7-34D6-48EB-B16C-1BE038E1E803")
        let sameBoot = node(device: 16777231, inode: 147868626, volumeUUID: nil)
        XCTAssertTrue(oldReceipt.sameDirectory(as: sameBoot))
        XCTAssertFalse(oldReceipt.sameDirectory(as: renumbered))
        // Upgrade compatibility: a persisted legacy receipt (no UUID) against
        // a fresh observation of the same device and inode must pass.
        let freshKnownSameDevice = node(device: 16777231, inode: 147868626, volumeUUID: "EB0E1FF7-34D6-48EB-B16C-1BE038E1E803")
        XCTAssertTrue(oldReceipt.sameDirectory(as: freshKnownSameDevice))
        XCTAssertTrue(oldReceipt.sameFile(as: freshKnownSameDevice))
        XCTAssertFalse(freshKnownSameDevice.sameFile(as: sameBoot))
        // A renumbered device with only one UUID present is never accepted.
        XCTAssertFalse(oldReceipt.sameFile(as: renumbered))
    }

    /// Receipts persisted before volume-UUID capture decode with a nil field.
    func testLegacyNodeJSONWithoutVolumeUUIDDecodesAsNil() throws {
        let legacy = """
        {"device":16777231,"inode":147868626,"mode":16877,"size":128,"modificationSeconds":1794685712,"modificationNanoseconds":727593709}
        """
        let nodeValue = try JSONDecoder().decode(LinuxResidentRecoveryStore.Node.self, from: Data(legacy.utf8))
        XCTAssertNil(nodeValue.volumeUUID)
        XCTAssertEqual(nodeValue.inode, 147868626)
    }

    /// A real committed receipt is accepted by the recovery guard, and a disk
    /// replaced afterwards (new inode) is refused as tampering.
    func testCommittedReceiptRoundTripsAndRefusesReplacedDisk() throws {
        let f = try Fixture(); defer { f.remove() }
        let store = try LinuxResidentRecoveryStore(root: f.root)
        let transaction = try store.begin(imageID: "trusted-new")
        defer { transaction.endAdmission() }
        _ = try transaction.replace(prepare: { try f.prepare($0) })
        let guard1 = try LinuxResidentDiskBarrier.acquireRecoveryGuard(root: f.root)
        XCTAssertEqual(guard1.receipt?.imageID, "trusted-new")
        guard1.finish()
        // Replace the disk through a new path (new inode): identity changed.
        try Data("tampered-replacement".utf8).write(to: f.current.appendingPathComponent("disk.img"), options: .atomic)
        XCTAssertThrowsError(try LinuxResidentDiskBarrier.acquireRecoveryGuard(root: f.root)) {
            XCTAssertEqual($0 as? LinuxResidentRecoveryError, .identityChanged)
        }
    }
}
