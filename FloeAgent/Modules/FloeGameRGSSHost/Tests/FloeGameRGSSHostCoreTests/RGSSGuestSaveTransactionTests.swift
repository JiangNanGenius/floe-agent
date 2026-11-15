// SPDX-License-Identifier: MPL-2.0
import Foundation
import XCTest
import FloeGameCore
import FloeGameRGSS
@testable import FloeGameRGSSHostCore

// Focused source-only regression tests for the journaled save transaction
// layer. They use real temporary directories and injected failpoints; they are
// not executed under the current native HOLD.

private struct SaveTransactionFixture: Sendable {
    let source: URL
    let saveRoot: URL
    let projectID: UUID
    let owner: GameProjectOwner
    let checkpointRoot: URL
    let store: RGSSGuestSaveStore
    let repository: FileGameSaveRepository
    let manager: RGSSGuestSaveManager
}

private func makeFixture(
    hooks: RGSSGuestSaveTransactionHooks = .none,
    limits: RGSSGuestSaveLimitsOverride = .standard
) throws -> SaveTransactionFixture {
    let source = try RGSSGuestTestSupport.makeProject()
    let saveRoot = try RGSSGuestTestSupport.temporaryDirectory("rgss-save-transactions")
    let projectID = UUID()
    let owner = RGSSGuestTestOwner.space(projectID)
    let checkpointRoot = try RGSSGuestTestSupport.temporaryDirectory("rgss-checkpoints")
    let store = try RGSSGuestSaveStore(root: saveRoot, engine: .rpgMakerXP,
                                       sourceRoot: source,
                                       qualificationLimits: limits,
                                       hooks: hooks)
    let repository = try FileGameSaveRepository(
        directory: checkpointRoot, projectID: projectID, owner: owner,
        maximumStateBytes: 4_194_304)
    let manager = RGSSGuestSaveManager(store: store,
                                       checkpointRepository: repository)
    return SaveTransactionFixture(
        source: source, saveRoot: saveRoot, projectID: projectID, owner: owner,
        checkpointRoot: checkpointRoot, store: store, repository: repository,
        manager: manager)
}

private func text(_ value: String) -> Data { Data(value.utf8) }
private func sha(_ data: Data) -> String { GameDigest.sha256(data) }

private struct TestCheckpointFile: Codable {
    let name: String
    let sha256: String
    let data: String
}
private struct TestCheckpoint: Codable {
    let format: String
    let version: Int
    let engine: GameEngineID
    let files: [TestCheckpointFile]
}

private func checkpointEnvelope(
    _ files: [(String, Data)],
    engine: GameEngineID = .rpgMakerXP,
    forcedDigest: String? = nil
) throws -> Data {
    let records = files.map { (name, data) in
        TestCheckpointFile(name: name, sha256: forcedDigest ?? sha(data),
                           data: data.base64EncodedString())
    }
    return try JSONEncoder().encode(TestCheckpoint(
        format: "floe-rgss-guest-saves", version: 1,
        engine: engine, files: records))
}

@discardableResult
private func persistCheckpoint(_ data: Data,
                               in fixture: SaveTransactionFixture) async throws -> UInt64 {
    let saved = try await fixture.repository.save(data, expectedRevision: 0)
    return saved.revision
}

private func controlDirectory(for store: RGSSGuestSaveStore) -> URL {
    let digest = String(GameDigest.sha256(Data(store.root.path.utf8)).prefix(24))
    return store.root.deletingLastPathComponent()
        .appendingPathComponent(".floe-rgss-save-control", isDirectory: true)
        .appendingPathComponent(digest, isDirectory: true)
}

private func transactionNames(for store: RGSSGuestSaveStore) throws -> [String] {
    let root = controlDirectory(for: store)
        .appendingPathComponent("transactions", isDirectory: true)
    guard FileManager.default.fileExists(atPath: root.path) else { return [] }
    return try FileManager.default.contentsOfDirectory(atPath: root.path).sorted()
}

private func crashHook(at point: RGSSGuestSaveFailpoint,
                       name: String? = nil) -> RGSSGuestSaveTransactionHooks {
    RGSSGuestSaveTransactionHooks(failpoint: { candidate, candidateName in
        guard candidate == point else { return }
        if let name, candidateName != name { return }
        throw RGSSGuestSaveInjectedCrash()
    })
}

private enum SaveSignalWaitError: Error { case timedOut }

private func waitForSignal(_ semaphore: DispatchSemaphore,
                           seconds: Double = 3) async -> DispatchTimeoutResult {
    await withCheckedContinuation { continuation in
        DispatchQueue.global().async {
            continuation.resume(returning: semaphore.wait(timeout: .now() + seconds))
        }
    }
}

private func requireSignal(_ semaphore: DispatchSemaphore) async throws {
    guard case .success = await waitForSignal(semaphore) else { throw SaveSignalWaitError.timedOut }
}

private final class SaveTransactionSignal: @unchecked Sendable {
    let started = DispatchSemaphore(value: 0)
    let entered = DispatchSemaphore(value: 0)
    let release = DispatchSemaphore(value: 0)
    let finished = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var armed = false
    func arm() { lock.withLock { armed = true } }
    func pauseIfArmed() throws {
        guard lock.withLock({ armed }) else { return }
        entered.signal()
        guard case .success = release.wait(timeout: .now() + 5) else { throw SaveSignalWaitError.timedOut }
    }
}

final class RGSSGuestSaveTransactionTests: XCTestCase {
    func testSaveLimitsRemainTheDeclaredCeilings() throws {
        XCTAssertEqual(RGSSGuestSaveLimits.maximumFiles, 64)
        XCTAssertEqual(RGSSGuestSaveLimits.maximumFileBytes, 16 * 1_024 * 1_024)
        XCTAssertEqual(RGSSGuestSaveLimits.maximumTotalBytes, 128 * 1_024 * 1_024)
        let fixture = try makeFixture(hooks: .init(failpoint: { point, _ in
            if point == .renameLinked { throw RGSSGuestSaveInjectedIOFailure() }
        }))
        for number in 1...RGSSGuestSaveLimits.maximumFiles {
            try fixture.store.write(text("slot-\(number)"), name: "Save\(number).rxdata")
        }
        let renamed = try fixture.store.renameTransaction("Save1.rxdata", to: "Save65.rxdata",
            expectedSHA256: sha(text("slot-1")))
        XCTAssertEqual(renamed.outcome, .committed)
        XCTAssertEqual(try fixture.store.list().count, RGSSGuestSaveLimits.maximumFiles)
        XCTAssertEqual(try fixture.store.read("Save65.rxdata"), text("slot-1"))
    }

    func testRestoreCheckpointPreservesUnrelatedUnknownAndCheckpointDirectory() async throws {
        let fixture = try makeFixture()
        try fixture.store.write(text("checkpoint-one"), name: "Save1.rxdata")
        try fixture.store.write(text("checkpoint-two"), name: "Save2.rxdata")
        let maybeRevision = try await fixture.manager.checkpoint()
        let revision = try XCTUnwrap(maybeRevision)

        try fixture.store.write(text("live-one"), name: "Save1.rxdata")
        try fixture.store.delete("Save2.rxdata")
        try fixture.store.write(text("unrelated"), name: "Save3.rxdata")

        let unknown = fixture.saveRoot.appendingPathComponent("notes.txt")
        try text("unknown").write(to: unknown)
        let checkpointDirectory = fixture.saveRoot
            .appendingPathComponent("Checkpoints", isDirectory: true)
        try FileManager.default.createDirectory(at: checkpointDirectory,
                                                withIntermediateDirectories: true)
        let checkpointMarker = checkpointDirectory.appendingPathComponent("marker.json")
        try text("marker").write(to: checkpointMarker)

        let receipt = try await fixture.manager.restoreCheckpointTransaction()
        XCTAssertEqual(receipt.outcome, .committed)
        XCTAssertEqual(receipt.checkpointRevision, revision)
        XCTAssertEqual(receipt.replacedNames, ["Save1.rxdata"])
        XCTAssertEqual(receipt.createdNames, ["Save2.rxdata"])
        XCTAssertTrue(receipt.preservedNames.contains("Save3.rxdata"))
        XCTAssertEqual(try fixture.store.read("Save1.rxdata"), text("checkpoint-one"))
        XCTAssertEqual(try fixture.store.read("Save2.rxdata"), text("checkpoint-two"))
        XCTAssertEqual(try fixture.store.read("Save3.rxdata"), text("unrelated"))
        XCTAssertEqual(try Data(contentsOf: unknown), text("unknown"))
        XCTAssertEqual(try Data(contentsOf: checkpointMarker), text("marker"))
        XCTAssertEqual(Set(receipt.inventory.map(\.name)),
                       Set(["Save1.rxdata", "Save2.rxdata", "Save3.rxdata"]))
    }

    func testDuplicateCheckpointIdentityFailsBeforeWriting() async throws {
        let fixture = try makeFixture()
        try fixture.store.write(text("old"), name: "Save1.rxdata")
        let duplicate = text("new")
        let envelope = try checkpointEnvelope([
            ("Save1.rxdata", duplicate),
            ("save1.rxdata", duplicate),
        ])
        _ = try await persistCheckpoint(envelope, in: fixture)
        do {
            _ = try await fixture.manager.restoreCheckpointTransaction()
            XCTFail("duplicate checkpoint names must fail")
        } catch let error as RGSSGuestRunError {
            guard case .saveCheckpointDuplicateName = error else {
                return XCTFail("unexpected \(error)")
            }
        }
        XCTAssertEqual(try fixture.store.read("Save1.rxdata"), text("old"))
        XCTAssertEqual(try fixture.store.list().map(\.name), ["Save1.rxdata"])
    }

    func testCheckpointAvailabilityMissingAndCorruptAreActionable() async throws {
        let source = try RGSSGuestTestSupport.makeProject()
        let saveRoot = try RGSSGuestTestSupport.temporaryDirectory("rgss-no-checkpoints")
        let store = try RGSSGuestSaveStore(root: saveRoot, engine: .rpgMakerXP,
                                           sourceRoot: source)
        let manager = RGSSGuestSaveManager(store: store)
        XCTAssertFalse(manager.supportsCheckpoints)
        if case .unsupported = manager.checkpointAvailability {
        } else {
            XCTFail("a store without a checkpoint repository must report unsupported")
        }
        let revision = try await manager.checkpoint()
        XCTAssertNil(revision)
        do {
            _ = try await manager.restoreCheckpointTransaction()
            XCTFail("restore without a repository must fail")
        } catch let error as RGSSGuestRunError {
            guard case .saveCheckpointUnsupported = error else {
                return XCTFail("unexpected \(error)")
            }
        }

        let fixture = try makeFixture()
        do {
            _ = try await fixture.manager.restoreCheckpointTransaction()
            XCTFail("restore without a checkpoint must fail")
        } catch let error as RGSSGuestRunError {
            guard case .saveCheckpointMissing = error else {
                return XCTFail("unexpected \(error)")
            }
        }
        _ = try await persistCheckpoint(Data("{}".utf8), in: fixture)
        do {
            _ = try await fixture.manager.restoreCheckpointTransaction()
            XCTFail("damaged checkpoint JSON must fail")
        } catch let error as RGSSGuestRunError {
            guard case .saveCheckpointCorrupt = error else {
                return XCTFail("unexpected \(error)")
            }
        }
    }

    func testCheckpointDigestMismatchFailsBeforeWriting() async throws {
        let fixture = try makeFixture()
        try fixture.store.write(text("old"), name: "Save1.rxdata")
        let envelope = try checkpointEnvelope(
            [("Save1.rxdata", text("new"))],
            forcedDigest: sha(text("different")))
        _ = try await persistCheckpoint(envelope, in: fixture)
        do {
            _ = try await fixture.manager.restoreCheckpointTransaction()
            XCTFail("a checkpoint digest mismatch must fail")
        } catch let error as RGSSGuestRunError {
            guard case .saveBytesMismatch = error else {
                return XCTFail("unexpected \(error)")
            }
        }
        XCTAssertEqual(try fixture.store.read("Save1.rxdata"), text("old"))
    }

    func testCheckpointEnvelopeLimitFailsWithoutTruncating() async throws {
        let source = try RGSSGuestTestSupport.makeProject()
        let saveRoot = try RGSSGuestTestSupport.temporaryDirectory("rgss-envelope-limit")
        let checkpointRoot = try RGSSGuestTestSupport.temporaryDirectory("rgss-envelope-repo")
        let projectID = UUID()
        let owner = RGSSGuestTestOwner.space(projectID)
        let store = try RGSSGuestSaveStore(root: saveRoot, engine: .rpgMakerXP,
                                           sourceRoot: source)
        let repository = try FileGameSaveRepository(
            directory: checkpointRoot, projectID: projectID, owner: owner,
            maximumStateBytes: 1_024)
        let manager = RGSSGuestSaveManager(store: store,
                                           checkpointRepository: repository)
        let payload = Data(repeating: 0x5a, count: 2_048)
        try store.write(payload, name: "Save1.rxdata")
        do {
            _ = try await manager.checkpoint()
            XCTFail("the checkpoint envelope must respect its state ceiling")
        } catch let error as RGSSGuestRunError {
            guard case .saveLimitExceeded = error else {
                return XCTFail("unexpected \(error)")
            }
        }
        XCTAssertEqual(try store.read("Save1.rxdata"), payload)
    }

    func testImportCollisionRequiresCASAndRetainsRawBackup() async throws {
        let fixture = try makeFixture()
        let importDirectory = try RGSSGuestTestSupport.temporaryDirectory("rgss-import")
        let source = importDirectory.appendingPathComponent("Save1.rxdata")
        try text("first").write(to: source)

        let first = try await fixture.manager.importFile(from: source,
                                                         policy: .rejectExisting)
        XCTAssertEqual(first.outcome, .committed)
        XCTAssertEqual(first.createdNames, ["Save1.rxdata"])
        XCTAssertEqual(try fixture.store.read("Save1.rxdata"), text("first"))

        try text("second").write(to: source)
        do {
            _ = try await fixture.manager.importFile(from: source)
            XCTFail("an existing save must not be silently overwritten")
        } catch let error as RGSSGuestRunError {
            guard case .saveDestinationExists = error else {
                return XCTFail("unexpected \(error)")
            }
        }
        XCTAssertEqual(try fixture.store.read("Save1.rxdata"), text("first"))

        do {
            _ = try await fixture.manager.importFile(
                from: source, expectedSHA256: sha(text("stale")))
            XCTFail("a stale expected digest must fail")
        } catch let error as RGSSGuestRunError {
            guard case .savePreconditionFailed = error else {
                return XCTFail("unexpected \(error)")
            }
        }
        XCTAssertEqual(try fixture.store.read("Save1.rxdata"), text("first"))

        let replaced = try await fixture.manager.importFile(
            from: source, expectedSHA256: sha(text("first")), keepBackup: true)
        XCTAssertEqual(replaced.outcome, .committed)
        XCTAssertEqual(replaced.replacedNames, ["Save1.rxdata"])
        let backupID = try XCTUnwrap(replaced.rawBackupID)
        let backupDirectory = try XCTUnwrap(replaced.backupDirectory)
        XCTAssertEqual(try Data(contentsOf: backupDirectory
            .appendingPathComponent("Save1.rxdata")), text("first"))
        XCTAssertEqual(try fixture.store.read("Save1.rxdata"), text("second"))
        let rawBackups = try await fixture.manager.listRawBackups()
        XCTAssertTrue(rawBackups.contains { $0.id == backupID })

        // The unconditional form remains available for explicit callers and
        // still retains the bytes it replaced.
        try text("third").write(to: source)
        let plain = try await fixture.manager.importFile(
            from: source, policy: .replaceKeepingBackup)
        XCTAssertEqual(plain.replacedNames, ["Save1.rxdata"])
        XCTAssertNotNil(plain.rawBackupID)
        XCTAssertEqual(try fixture.store.read("Save1.rxdata"), text("third"))
    }

    func testRawBackupListAndRestoreAreReversible() async throws {
        let fixture = try makeFixture()
        let importDirectory = try RGSSGuestTestSupport.temporaryDirectory("rgss-import")
        let source = importDirectory.appendingPathComponent("Save1.rxdata")
        try text("A").write(to: source)
        _ = try await fixture.manager.importFile(from: source, policy: .rejectExisting)

        try text("B").write(to: source)
        let toB = try await fixture.manager.importFile(
            from: source, expectedSHA256: sha(text("A")), keepBackup: true)
        let aBackup = try XCTUnwrap(toB.rawBackupID)

        try await Task.sleep(nanoseconds: 10_000_000)
        try text("C").write(to: source)
        let toC = try await fixture.manager.importFile(
            from: source, expectedSHA256: sha(text("B")), keepBackup: true)
        let bBackup = try XCTUnwrap(toC.rawBackupID)

        let list = try await fixture.manager.listRawBackups()
        XCTAssertEqual(list.count, 2)
        XCTAssertEqual(list.first?.id, bBackup)
        let latest = try await fixture.manager.latestRawBackup(for: "Save1.rxdata")
        XCTAssertEqual(latest?.id, bBackup)
        XCTAssertEqual(try fixture.store.read("Save1.rxdata"), text("C"))

        let restoredB = try await fixture.manager.restoreRawBackup(
            id: bBackup, expectedSHA256: sha(text("C")))
        XCTAssertEqual(restoredB.outcome, .committed)
        XCTAssertEqual(restoredB.rawBackupID, bBackup)
        XCTAssertEqual(try fixture.store.read("Save1.rxdata"), text("B"))

        let maybeSafety = try await fixture.manager.latestRawBackup(for: "Save1.rxdata")
        let safety = try XCTUnwrap(maybeSafety)
        XCTAssertEqual(safety.sha256, sha(text("C")))
        let restoredC = try await fixture.manager.restoreLatestRawBackup(
            for: "Save1.rxdata", expectedSHA256: sha(text("B")))
        XCTAssertEqual(restoredC.rawBackupID, safety.id)
        XCTAssertEqual(try fixture.store.read("Save1.rxdata"), text("C"))

        do {
            _ = try await fixture.manager.restoreRawBackup(
                id: aBackup, expectedSHA256: sha(text("not-current")))
            XCTFail("a stale expected digest must not restore a backup")
        } catch let error as RGSSGuestRunError {
            guard case .savePreconditionFailed = error else {
                return XCTFail("unexpected \(error)")
            }
        }
        do {
            _ = try await fixture.manager.restoreRawBackup(
                id: UUID(), expectedSHA256: nil)
            XCTFail("a missing backup must fail")
        } catch let error as RGSSGuestRunError {
            guard case .saveRawBackupMissing = error else {
                return XCTFail("unexpected \(error)")
            }
        }
    }

    func testRenameIsAtomicAndDuplicateRequiresExplicitRetry() throws {
        let fixture = try makeFixture(hooks: RGSSGuestSaveTransactionHooks(
            failpoint: { point, name in
                if point == .renameLinked && name == "Save4.rxdata" {
                    throw RGSSGuestSaveInjectedIOFailure()
                }
            }))
        try fixture.store.write(text("one"), name: "Save1.rxdata")
        let first = try fixture.store.renameTransaction(
            "Save1.rxdata", to: "Save2.rxdata",
            expectedSHA256: sha(text("one")))
        XCTAssertEqual(first.outcome, .committed)
        XCTAssertEqual(try fixture.store.list().map(\.name), ["Save2.rxdata"])

        try fixture.store.write(text("two"), name: "Save1.rxdata")
        let duplicate = try fixture.store.renameTransaction(
            "Save1.rxdata", to: "Save4.rxdata",
            expectedSHA256: sha(text("two")))
        XCTAssertEqual(duplicate.outcome, .requiresRetry)
        XCTAssertEqual(Set(try fixture.store.list().map(\.name)),
                       Set(["Save1.rxdata", "Save2.rxdata", "Save4.rxdata"]))

        let clean = try RGSSGuestSaveStore(root: fixture.saveRoot,
                                           engine: .rpgMakerXP,
                                           sourceRoot: fixture.source)
        let finished = try clean.renameTransaction(
            "Save1.rxdata", to: "Save4.rxdata",
            expectedSHA256: sha(text("two")))
        XCTAssertEqual(finished.outcome, .committed)
        XCTAssertEqual(try clean.list().map(\.name), ["Save2.rxdata", "Save4.rxdata"])
        XCTAssertEqual(try clean.read("Save4.rxdata"), text("two"))

        try clean.write(text("four"), name: "Save3.rxdata")
        do {
            _ = try clean.renameTransaction(
                "Save4.rxdata", to: "Save3.rxdata", expectedSHA256: nil)
            XCTFail("rename must not overwrite different destination bytes")
        } catch let error as RGSSGuestRunError {
            guard case .saveDestinationExists = error else {
                return XCTFail("unexpected \(error)")
            }
        }
        XCTAssertEqual(try clean.read("Save4.rxdata"), text("two"))
        XCTAssertEqual(try clean.read("Save3.rxdata"), text("four"))
    }

    func testInterruptedCommitRollsBackToPreviousBytesOnNextStore() async throws {
        let fixture = try makeFixture()
        try fixture.store.write(text("old1"), name: "Save1.rxdata")
        try fixture.store.write(text("old2"), name: "Save2.rxdata")
        _ = try await fixture.manager.checkpoint()
        try fixture.store.write(text("current1"), name: "Save1.rxdata")
        try fixture.store.write(text("current2"), name: "Save2.rxdata")

        let crashingStore = try RGSSGuestSaveStore(
            root: fixture.saveRoot, engine: .rpgMakerXP,
            sourceRoot: fixture.source,
            qualificationLimits: .standard,
            hooks: crashHook(at: .newInstalled, name: "Save1.rxdata"))
        let crashingManager = RGSSGuestSaveManager(
            store: crashingStore, checkpointRepository: fixture.repository)
        do {
            _ = try await crashingManager.restoreCheckpointTransaction()
            XCTFail("the injected crash must abort the restore")
        } catch is RGSSGuestSaveInjectedCrash {
        }
        XCTAssertEqual(try Data(contentsOf: fixture.saveRoot
            .appendingPathComponent("Save1.rxdata")), text("old1"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.saveRoot
            .appendingPathComponent("Save2.rxdata").path))
        XCTAssertFalse(try transactionNames(for: crashingStore).isEmpty)

        let recovered = try RGSSGuestSaveStore(root: fixture.saveRoot,
                                               engine: .rpgMakerXP,
                                               sourceRoot: fixture.source)
        XCTAssertEqual(try recovered.list().map(\.name),
                       ["Save1.rxdata", "Save2.rxdata"])
        XCTAssertEqual(try recovered.read("Save1.rxdata"), text("current1"))
        XCTAssertEqual(try recovered.read("Save2.rxdata"), text("current2"))
        XCTAssertTrue(try transactionNames(for: recovered).isEmpty)
    }

    func testInterruptedCommitAfterAllInstallsRollsForward() async throws {
        let fixture = try makeFixture()
        try fixture.store.write(text("old1"), name: "Save1.rxdata")
        try fixture.store.write(text("old2"), name: "Save2.rxdata")
        _ = try await fixture.manager.checkpoint()
        try fixture.store.write(text("current1"), name: "Save1.rxdata")
        try fixture.store.write(text("current2"), name: "Save2.rxdata")

        let crashingStore = try RGSSGuestSaveStore(
            root: fixture.saveRoot, engine: .rpgMakerXP,
            sourceRoot: fixture.source,
            qualificationLimits: .standard,
            hooks: crashHook(at: .commitComplete))
        let crashingManager = RGSSGuestSaveManager(
            store: crashingStore, checkpointRepository: fixture.repository)
        do {
            _ = try await crashingManager.restoreCheckpointTransaction()
            XCTFail("the injected crash must abort the restore")
        } catch is RGSSGuestSaveInjectedCrash {
        }
        XCTAssertEqual(try Data(contentsOf: fixture.saveRoot
            .appendingPathComponent("Save1.rxdata")), text("old1"))
        XCTAssertEqual(try Data(contentsOf: fixture.saveRoot
            .appendingPathComponent("Save2.rxdata")), text("old2"))

        let recovered = try RGSSGuestSaveStore(root: fixture.saveRoot,
                                               engine: .rpgMakerXP,
                                               sourceRoot: fixture.source)
        XCTAssertEqual(try recovered.read("Save1.rxdata"), text("old1"))
        XCTAssertEqual(try recovered.read("Save2.rxdata"), text("old2"))
        XCTAssertTrue(try transactionNames(for: recovered).isEmpty)
    }

    func testAmbiguousRecoveryPreservesEveryByteAndReportsRequirement() async throws {
        let fixture = try makeFixture()
        try fixture.store.write(text("old1"), name: "Save1.rxdata")
        try fixture.store.write(text("old2"), name: "Save2.rxdata")
        _ = try await fixture.manager.checkpoint()
        try fixture.store.write(text("current1"), name: "Save1.rxdata")
        try fixture.store.write(text("current2"), name: "Save2.rxdata")

        let crashingStore = try RGSSGuestSaveStore(
            root: fixture.saveRoot, engine: .rpgMakerXP,
            sourceRoot: fixture.source,
            qualificationLimits: .standard,
            hooks: crashHook(at: .newInstalled, name: "Save1.rxdata"))
        let crashingManager = RGSSGuestSaveManager(
            store: crashingStore, checkpointRepository: fixture.repository)
        do {
            _ = try await crashingManager.restoreCheckpointTransaction()
            XCTFail("the injected crash must abort the restore")
        } catch is RGSSGuestSaveInjectedCrash {
        }
        let liveSave1 = fixture.saveRoot.appendingPathComponent("Save1.rxdata")
        try text("external").write(to: liveSave1)

        let recovered = try RGSSGuestSaveStore(root: fixture.saveRoot,
                                               engine: .rpgMakerXP,
                                               sourceRoot: fixture.source)
        do {
            _ = try recovered.list()
            XCTFail("ambiguous bytes must require explicit recovery")
        } catch let error as RGSSGuestRunError {
            guard case .saveTransactionRecoveryRequired = error else {
                return XCTFail("unexpected \(error)")
            }
        }
        XCTAssertEqual(try Data(contentsOf: liveSave1), text("external"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.saveRoot
            .appendingPathComponent("Save2.rxdata").path))
        let pending = try transactionNames(for: recovered)
        XCTAssertFalse(pending.isEmpty)
        guard let firstTransaction = pending.first else {
            return XCTFail("the ambiguous transaction directory disappeared")
        }
        let oldDirectory = controlDirectory(for: recovered)
            .appendingPathComponent("transactions", isDirectory: true)
            .appendingPathComponent(firstTransaction, isDirectory: true)
            .appendingPathComponent("old", isDirectory: true)
        XCTAssertEqual(try Data(contentsOf: oldDirectory
            .appendingPathComponent("Save1.rxdata")), text("current1"))
        XCTAssertEqual(try Data(contentsOf: oldDirectory
            .appendingPathComponent("Save2.rxdata")), text("current2"))
    }

    func testCollectCapacityFailureImportsNothing() throws {
        let limits = try RGSSGuestSaveLimitsOverride(
            maximumFiles: 3, maximumFileBytes: 8, maximumTotalBytes: 12)
        let fixture = try makeFixture(limits: limits)
        try fixture.store.write(text("aaaa"), name: "Save1.rxdata")
        try fixture.store.write(text("bbbb"), name: "Save2.rxdata")
        let run = try RGSSGuestTestSupport.temporaryDirectory("rgss-collect")
        try RGSSGuestTestSupport.write("cccccccc",
                                       to: run.appendingPathComponent("Save1.rxdata"))
        try RGSSGuestTestSupport.write("dddd",
                                       to: run.appendingPathComponent("Save3.rxdata"))
        do {
            _ = try fixture.store.collect(from: run)
            XCTFail("the final inventory exceeds the total byte limit")
        } catch let error as RGSSGuestRunError {
            guard case .saveLimitExceeded = error else {
                return XCTFail("unexpected \(error)")
            }
        }
        XCTAssertEqual(try fixture.store.read("Save1.rxdata"), text("aaaa"))
        XCTAssertEqual(try fixture.store.read("Save2.rxdata"), text("bbbb"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.saveRoot
            .appendingPathComponent("Save3.rxdata").path))
        XCTAssertTrue(try transactionNames(for: fixture.store).isEmpty)
    }

    func testDiskSpacePreflightFailsBeforeStaging() throws {
        let fixture = try makeFixture(hooks: RGSSGuestSaveTransactionHooks(
            availableBytes: { _ in Int64(0) }))
        let run = try RGSSGuestTestSupport.temporaryDirectory("rgss-space")
        try RGSSGuestTestSupport.write("new",
                                       to: run.appendingPathComponent("Save1.rxdata"))
        do {
            _ = try fixture.store.collect(from: run)
            XCTFail("zero available bytes must fail before staging")
        } catch let error as RGSSGuestRunError {
            guard case .saveInsufficientSpace = error else {
                return XCTFail("unexpected \(error)")
            }
        }
        XCTAssertTrue(try fixture.store.list().isEmpty)
        XCTAssertTrue(try transactionNames(for: fixture.store).isEmpty)
    }

    func testCancellationBeforeCommitPreservesOldBytes() async throws {
        let signal = SaveTransactionSignal()
        let fixture = try makeFixture(hooks: RGSSGuestSaveTransactionHooks(
            failpoint: { point, _ in
                if point == .beforeCommit {
                    try signal.pauseIfArmed()
                }
            }))
        try fixture.store.write(text("checkpoint"), name: "Save1.rxdata")
        _ = try await fixture.manager.checkpoint()
        try fixture.store.write(text("live"), name: "Save1.rxdata")

        signal.arm()
        defer { signal.release.signal() }
        let task = Task.detached {
            try await fixture.manager.restoreCheckpointTransaction()
        }
        try await requireSignal(signal.entered)
        task.cancel()
        signal.release.signal()
        do {
            _ = try await task.value
            XCTFail("cancellation before the commit point must abort")
        } catch is CancellationError {
        }
        XCTAssertEqual(try fixture.store.read("Save1.rxdata"), text("live"))
        XCTAssertTrue(try transactionNames(for: fixture.store).isEmpty)
    }

    func testCancellationAfterCommitPointStillCommits() async throws {
        let signal = SaveTransactionSignal()
        let fixture = try makeFixture(hooks: RGSSGuestSaveTransactionHooks(
            failpoint: { point, _ in
                if point == .backupMoved {
                    try signal.pauseIfArmed()
                }
            }))
        try fixture.store.write(text("checkpoint"), name: "Save1.rxdata")
        _ = try await fixture.manager.checkpoint()
        try fixture.store.write(text("live"), name: "Save1.rxdata")

        signal.arm()
        defer { signal.release.signal() }
        let task = Task.detached {
            try await fixture.manager.restoreCheckpointTransaction()
        }
        try await requireSignal(signal.entered)
        task.cancel()
        signal.release.signal()
        let receipt = try await task.value
        XCTAssertEqual(receipt.outcome, .committed)
        XCTAssertEqual(try fixture.store.read("Save1.rxdata"), text("checkpoint"))
        XCTAssertTrue(try transactionNames(for: fixture.store).isEmpty)
    }

    func testSecondStoreWaitsForTheLayerLock() async throws {
        let signal = SaveTransactionSignal()
        let fixture = try makeFixture(hooks: RGSSGuestSaveTransactionHooks(
            failpoint: { point, _ in
                if point == .beforeCommit {
                    try signal.pauseIfArmed()
                }
            }))
        let other = try RGSSGuestSaveStore(root: fixture.saveRoot,
                                           engine: .rpgMakerXP,
                                           sourceRoot: fixture.source)
        signal.arm()
        defer { signal.release.signal() }
        let first = Task.detached {
            try fixture.store.importContent(text("one"), name: "Save1.rxdata",
                                            policy: .rejectExisting)
        }
        try await requireSignal(signal.entered)
        let second = Task.detached {
            signal.started.signal()
            try other.write(text("two"), name: "Save2.rxdata")
            signal.finished.signal()
        }
        try await requireSignal(signal.started)
        let early = await waitForSignal(signal.finished, seconds: 0.2)
        if case .success = early {
            XCTFail("a second store instance did not wait for the layer lock")
        }
        signal.release.signal()
        _ = try await first.value
        let late = await waitForSignal(signal.finished, seconds: 2)
        if case .timedOut = late {
            XCTFail("the second store instance did not finish after unlock")
        }
        try await second.value
        XCTAssertEqual(try fixture.store.read("Save1.rxdata"), text("one"))
        XCTAssertEqual(try fixture.store.read("Save2.rxdata"), text("two"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.saveRoot
            .appendingPathComponent(".floe-rgss-save-control").path))
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: controlDirectory(for: fixture.store).path))
    }

    func testConcurrentStoreInstancesSerializeOnOneLayer() async throws {
        let fixture = try makeFixture()
        let other = try RGSSGuestSaveStore(root: fixture.saveRoot,
                                           engine: .rpgMakerXP,
                                           sourceRoot: fixture.source)
        try await withThrowingTaskGroup(of: Void.self) { group in
            for index in 0..<20 {
                let store = index.isMultiple(of: 2) ? fixture.store : other
                group.addTask {
                    try store.write(text("value-\(index)"),
                                    name: "Save\(index).rxdata")
                }
            }
            try await group.waitForAll()
        }
        XCTAssertEqual(try fixture.store.list().count, 20)
        for index in 0..<20 {
            XCTAssertEqual(try fixture.store.read("Save\(index).rxdata"),
                           text("value-\(index)"))
        }
    }

    func testDeleteRequiresMatchingRevisionWhenProvided() throws {
        let fixture = try makeFixture()
        try fixture.store.write(text("one"), name: "Save1.rxdata")
        do {
            _ = try fixture.store.delete("Save1.rxdata",
                                         expectedSHA256: sha(text("other")))
            XCTFail("a stale expected digest must not delete")
        } catch let error as RGSSGuestRunError {
            guard case .savePreconditionFailed = error else {
                return XCTFail("unexpected \(error)")
            }
        }
        XCTAssertEqual(try fixture.store.read("Save1.rxdata"), text("one"))
        let receipt = try fixture.store.delete(
            "Save1.rxdata", expectedSHA256: sha(text("one")))
        XCTAssertEqual(receipt.outcome, .committed)
        XCTAssertEqual(receipt.removedNames, ["Save1.rxdata"])
        XCTAssertTrue(try fixture.store.list().isEmpty)
    }
}
