// Synthetic counterpart of the M4 index: six namespaces, one physical anchor,
// two pending intents, ten convergence receipts. No customer metadata is used.
// Draft for Root's single combined native validation; not run by its author.
import Foundation
import Darwin
import XCTest
import FloeCore
@testable import FloeExecution

final class RuntimeV2MaintenanceBootstrapDiagnosticsTests: XCTestCase {
    func testObservedIndexShapeKeepsAllHistoriesAndDoesNotGrantClosure() throws {
        let fixture = try Fixture(); defer { fixture.cleanup() }
        let layout = try fixture.domain.authorityHistoryLayout()
        XCTAssertEqual(layout.directories.count, 6)
        XCTAssertEqual(layout.historicalDirectories.count, 2)
        XCTAssertEqual(layout.pendingIntentCount, 2)
        XCTAssertEqual(layout.primaryDirectory.lastPathComponent, fixture.domain.domainKey)
        XCTAssertEqual(try fixture.receiptBytes(), fixture.originalReceiptBytes)
        for directory in layout.historicalDirectories {
            XCTAssertTrue(try XCTUnwrap(RuntimeV2MaintenanceCoordinator.readHistoryIntent(directory: directory)).phase.isBlocking)
        }
        // Discovery neither resolves an intent nor turns a historical receipt
        // into a new live closure proof. No coordinator is installed here.
        XCTAssertEqual(try fixture.intentBytes(), fixture.originalIntentBytes)
    }

    func testDifferentPhysicalAnchorStaysRejectedWithClosedStage() throws {
        let fixture = try Fixture(); defer { fixture.cleanup() }
        let unexpected = fixture.authority.appendingPathComponent(".physical-" + String(repeating: "f", count: 64) + ".lock")
        try Data().write(to: unexpected)
        assertFailure(fixture, code: .historyShapeUnknown, stage: .physicalAnchorMismatch, hasErrno: false)
        XCTAssertEqual(try fixture.intentBytes(), fixture.originalIntentBytes)
        XCTAssertTrue(FileManager.default.fileExists(atPath: unexpected.path))
    }

    func testNamespaceSymlinkStaysRejectedAndRecordsOpenErrno() throws {
        let fixture = try Fixture(); defer { fixture.cleanup() }
        let target = fixture.lockOnlyDirectories[0]
        try FileManager.default.removeItem(at: target)
        try FileManager.default.createSymbolicLink(at: target, withDestinationURL: fixture.lockOnlyDirectories[1])
        assertFailure(fixture, code: .historyShapeUnknown, stage: .namespaceOpen, hasErrno: true)
        XCTAssertEqual(try fixture.intentBytes(), fixture.originalIntentBytes)
    }

    func testInvalidReceiptPayloadStaysRejectedWithoutLeakingIdentifiers() throws {
        let fixture = try Fixture(); defer { fixture.cleanup() }
        let file = try XCTUnwrap(fixture.receiptFiles.first)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
        object["pretendPermission"] = true
        let changed = try JSONSerialization.data(withJSONObject: object, options: .sortedKeys)
        try changed.write(to: file)
        assertFailure(fixture, code: .historyShapeUnknown, stage: .receiptSchema, hasErrno: false)
        XCTAssertEqual(try Data(contentsOf: file), changed)
        XCTAssertEqual(try fixture.intentBytes(), fixture.originalIntentBytes)
    }

    func testHardlinkedReceiptStaysRejectedAtStatWithoutStaleErrno() throws {
        let fixture = try Fixture(); defer { fixture.cleanup() }
        let first = fixture.receiptFiles[0], second = fixture.receiptFiles[1]
        try FileManager.default.removeItem(at: second)
        XCTAssertEqual(link(first.path, second.path), 0)
        assertFailure(fixture, code: .historyShapeUnknown, stage: .receiptLink, hasErrno: false)
        XCTAssertEqual(try fixture.intentBytes(), fixture.originalIntentBytes)
    }

    func testHeldNamespaceIdentityReplacementStaysRejectedAsChanged() throws {
        let fixture = try Fixture(); defer { fixture.cleanup() }
        let layout = try fixture.domain.authorityHistoryLayout().prepareNativeDirectories()
        let held = try RuntimeV2MaintenanceHistoryLocks.acquire(layout, operation: LOCK_EX)
        let directory = fixture.lockOnlyDirectories[0]
        let saved = fixture.work.appendingPathComponent("retained-native-test-namespace")
        try FileManager.default.moveItem(at: directory, to: saved)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        try Data().write(to: directory.appendingPathComponent("maintenance.lock"))
        XCTAssertThrowsError(try held.validate()) { error in
            guard let failure = error as? RuntimeV2MaintenanceBootstrapFailure else { return XCTFail("wrong error type") }
            XCTAssertEqual(failure.code, .historySetChanged)
            XCTAssertEqual(failure.stage, .namespaceChanged)
            XCTAssertNil(failure.posixErrno)
            self.assertClosedText(failure, fixture: fixture)
        }
        XCTAssertEqual(try fixture.intentBytes(), fixture.originalIntentBytes)
        XCTAssertTrue(FileManager.default.fileExists(atPath: saved.path))
    }

    func testDanglingIntentSymlinkIsUnreadableInsteadOfMissing() throws {
        let fixture = try Fixture(); defer { fixture.cleanup() }
        let directory = fixture.lockOnlyDirectories[0]
        let intent = directory.appendingPathComponent("intent.json")
        try FileManager.default.createSymbolicLink(atPath: intent.path, withDestinationPath: "missing-intent.json")
        assertFailure(fixture, code: .historyUnreadable, stage: .intentOpen, hasErrno: true)
        XCTAssertEqual(try fixture.intentBytes(), fixture.originalIntentBytes)
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: intent.path), "missing-intent.json")
    }

    func testReceiptFromDifferentPhysicalRootReportsRootPredicate() throws {
        let fixture = try Fixture(); defer { fixture.cleanup() }
        let file = try XCTUnwrap(fixture.receiptFiles.first)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
        object["rootInode"] = NSNumber(value: 1)
        let changed = try JSONSerialization.data(withJSONObject: object, options: .sortedKeys)
        try changed.write(to: file)
        assertFailure(fixture, code: .historyShapeUnknown, stage: .receiptRoot, hasErrno: false)
        XCTAssertEqual(try Data(contentsOf: file), changed)
        XCTAssertEqual(try fixture.intentBytes(), fixture.originalIntentBytes)
    }

    func testNativeReceiptInReusedHistoricalNamespaceIsRecognizedWithoutGrantingClosure() throws {
        let fixture = try Fixture(); defer { fixture.cleanup() }
        let oldDirectory = fixture.authority.appendingPathComponent(String(repeating: "c", count: 64))
        let receipt = try XCTUnwrap(fixture.receiptFiles.first { $0.deletingLastPathComponent().deletingLastPathComponent() == oldDirectory })
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: receipt)) as? [String: Any])
        object["domainKey"] = fixture.domain.domainKey
        let nativeBytes = try JSONSerialization.data(withJSONObject: object, options: .sortedKeys)
        try nativeBytes.write(to: receipt)
        let first = try fixture.domain.authorityHistoryLayout()
        let second = try fixture.domain.authorityHistoryLayout()
        XCTAssertEqual(first.historicalDirectories.count, 2)
        XCTAssertEqual(second.historicalDirectories.count, 2)
        XCTAssertEqual(first.pendingIntentCount, 2)
        XCTAssertEqual(try Data(contentsOf: receipt), nativeBytes)
        XCTAssertEqual(try fixture.intentBytes(), fixture.originalIntentBytes)
    }

    func testForeignReceiptDomainKeyRemainsRejected() throws {
        let fixture = try Fixture(); defer { fixture.cleanup() }
        let receipt = try XCTUnwrap(fixture.receiptFiles.first)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: receipt)) as? [String: Any])
        object["domainKey"] = String(repeating: "f", count: 64)
        try JSONSerialization.data(withJSONObject: object, options: .sortedKeys).write(to: receipt)
        assertFailure(fixture, code: .historyShapeUnknown, stage: .receiptNamespace, hasErrno: false)
        XCTAssertEqual(try fixture.intentBytes(), fixture.originalIntentBytes)
    }

    func testStageDefaultAndWhitelistRemainBackwardCompatible() {
        let oldCall = RuntimeV2MaintenanceBootstrapFailure(.historyShapeUnknown, rootCheck: .verified)
        XCTAssertNil(oldCall.stage)
        XCTAssertTrue(oldCall.diagnosticText.hasSuffix("stage=unrecorded"))
        let stages = RuntimeV2MaintenanceBootstrapFailure.Stage.allCases
        XCTAssertEqual(Set(stages.map(\.rawValue)).count, stages.count)
        for stage in stages {
            XCTAssertTrue(stage.rawValue.utf8.allSatisfy { (97...122).contains($0) || $0 == 95 })
            let failure = RuntimeV2MaintenanceBootstrapFailure(.historyShapeUnknown, rootCheck: .verified,
                histories: 2, pending: 2, posixErrno: EACCES, stage: stage)
            XCTAssertEqual(failure.diagnosticText,
                "legacyMaintenanceBootstrap code=history_shape_unknown rootCheck=verified histories=2 pending=2 errno=\(EACCES) stage=\(stage.rawValue)")
        }
    }

    private func assertFailure(_ fixture: Fixture, code: RuntimeV2MaintenanceBootstrapFailure.Code,
                               stage: RuntimeV2MaintenanceBootstrapFailure.Stage, hasErrno: Bool,
                               file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try fixture.domain.authorityHistoryLayout(), file: file, line: line) { error in
            guard let failure = error as? RuntimeV2MaintenanceBootstrapFailure else { return XCTFail("wrong error type", file: file, line: line) }
            XCTAssertEqual(failure.code, code, file: file, line: line)
            XCTAssertEqual(failure.stage, stage, file: file, line: line)
            XCTAssertEqual(failure.posixErrno != nil, hasErrno, file: file, line: line)
            if let code = failure.posixErrno { XCTAssertNotEqual(code, 0, file: file, line: line) }
            self.assertClosedText(failure, fixture: fixture, file: file, line: line)
        }
    }

    private func assertClosedText(_ failure: RuntimeV2MaintenanceBootstrapFailure, fixture: Fixture,
                                  file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertFalse(failure.diagnosticText.contains(fixture.work.path), file: file, line: line)
        for value in fixture.intentIDs + fixture.receiptFiles.map(\.lastPathComponent) {
            XCTAssertFalse(failure.diagnosticText.contains(value), file: file, line: line)
        }
    }

    private final class Fixture {
        let work: URL
        let domain: RuntimeV2MaintenanceDomain
        let authority: URL
        let intentIDs = [UUID().uuidString, UUID().uuidString]
        var lockOnlyDirectories: [URL] = []
        var receiptFiles: [URL] = []
        var originalReceiptBytes: [String: Data] = [:]
        var originalIntentBytes: [String: Data] = [:]

        init() throws {
            let fm = FileManager.default
            work = fm.temporaryDirectory.appendingPathComponent("bootstrap-stage-" + UUID().uuidString)
            let root = work.appendingPathComponent("Runtime/v2")
            try fm.createDirectory(at: root.appendingPathComponent("recovery/quarantine"), withIntermediateDirectories: true)
            domain = try RuntimeV2MaintenanceDomain(trustedLegacyRoot: root)
            authority = root.deletingLastPathComponent().appendingPathComponent("MaintenanceAuthority")
            try fm.createDirectory(at: authority, withIntermediateDirectories: false)
            let identity = try RuntimeV2DiskIdentity.read(at: root)
            let anchor = ".physical-" + FloeDigest.sha256Hex(Data("\(identity.device):\(identity.inode)".utf8)) + ".lock"
            try Data().write(to: authority.appendingPathComponent(anchor))
            let names = [domain.domainKey] + ["a", "b", "c", "d", "e"].map { String(repeating: $0, count: 64) }
            for (index, name) in names.enumerated() {
                let directory = authority.appendingPathComponent(name)
                try fm.createDirectory(at: directory, withIntermediateDirectories: false)
                try Data().write(to: directory.appendingPathComponent("maintenance.lock"))
                if index == 1 || index == 2 {
                    let record = RuntimeV2MaintenanceIntentRecord(intentID: intentIDs[index - 1],
                        holdGeneration: index == 1 ? 9 : 3, phase: index == 1 ? .recovering : .committing,
                        owner: "synthetic-native", reason: "synthetic-bootstrap", createdAt: Date(), updatedAt: Date(),
                        domainRoot: root.path, domainDevice: identity.device, domainInode: identity.inode)
                    let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
                    let bytes = try encoder.encode(record)
                    try bytes.write(to: directory.appendingPathComponent("intent.json"))
                    originalIntentBytes[name] = bytes
                    for child in ["closed-receipts", "sparse-journals", "sparse-receipts"] {
                        try fm.createDirectory(at: directory.appendingPathComponent(child), withIntermediateDirectories: false)
                    }
                } else if index == 0 || index == 3 {
                    let receipts = directory.appendingPathComponent("closed-receipts")
                    try fm.createDirectory(at: receipts, withIntermediateDirectories: false)
                    for ordinal in 0..<(index == 0 ? 6 : 4) {
                        let receipt = RuntimeV2RecoveryClosedReceipt(version: 1, proofID: UUID().uuidString,
                            isConvergenceProof: true, domainKey: name, rootDevice: identity.device, rootInode: identity.inode,
                            incarnation: UUID().uuidString, sourceGeneration: 1, intentID: intentIDs[ordinal % 2], holdGeneration: 9,
                            historicalLeaseEnvironmentIDs: (0..<57).map { "synthetic-lease-\($0)" }, historicalRegistryLeaseEnvironmentIDs: [],
                            ownerEvidenceFingerprint: String(repeating: "1", count: 64), legacyRegistryFingerprint: String(repeating: "2", count: 64),
                            inspectedDescriptorSlots: 4_864, readOnlyMetadataDescriptors: 0)
                        let file = receipts.appendingPathComponent("closure-" + receipt.intentID + "-" + receipt.proofID + ".json")
                        let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys
                        try encoder.encode(receipt).write(to: file)
                        receiptFiles.append(file)
                    }
                } else { lockOnlyDirectories.append(directory) }
            }
            originalReceiptBytes = try receiptBytes()
        }

        func receiptBytes() throws -> [String: Data] {
            try Dictionary(uniqueKeysWithValues: receiptFiles.map { ($0.lastPathComponent, try Data(contentsOf: $0)) })
        }
        func intentBytes() throws -> [String: Data] {
            try Dictionary(uniqueKeysWithValues: originalIntentBytes.keys.map { key in
                (key, try Data(contentsOf: authority.appendingPathComponent(key + "/intent.json")))
            })
        }
        func cleanup() { try? FileManager.default.removeItem(at: work) }
    }
}
