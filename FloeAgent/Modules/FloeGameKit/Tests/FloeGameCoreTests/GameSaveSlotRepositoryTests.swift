// SPDX-License-Identifier: MPL-2.0
import Foundation
import XCTest
@testable import FloeGameCore

@MainActor
final class GameSaveSlotRepositoryTests: XCTestCase {
    private let projectID = UUID(uuidString: "11111111-2222-4333-8444-555555555555")!

    // MARK: - Helpers

    private func root() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("FloeSaveSlotTests-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func context(projectID: UUID? = nil,
                         owner: GameProjectOwner? = nil,
                         revision: String = "r1",
                         environmentID: String? = "env-1",
                         gameRoot: String = ".") throws -> GameProjectContext {
        let id = projectID ?? self.projectID
        return try GameProjectContext(projectID: id, owner: owner ?? .space(recordID: id),
            rootURL: FileManager.default.temporaryDirectory
                .appendingPathComponent("save-source-" + UUID().uuidString, isDirectory: true),
            savedRevision: revision, environmentID: environmentID)
    }

    private func identity(projectID: UUID? = nil,
                          owner: GameProjectOwner? = nil,
                          engine: GameEngineID = .phaser,
                          environmentID: String? = "env-1",
                          gameRoot: String = ".") throws -> GameWebStorageIdentity {
        let id = projectID ?? self.projectID
        return try GameWebStorageIdentity(projectID: id,
            owner: owner ?? .space(recordID: id), engine: engine,
            environmentID: environmentID, gameRoot: gameRoot)
    }

    private func repository(_ root: URL,
                            _ identity: GameWebStorageIdentity,
                            limits: GameSaveSlotLimits = try! .init()) throws -> FileGameSaveSlotRepository {
        try FileGameSaveSlotRepository(directory: root, identity: identity, limits: limits)
    }

    private func state(_ step: Int) -> Data {
        Data("{\"step\":\(step)}".utf8)
    }

    private func date(_ value: Int) -> Date {
        Date(timeIntervalSinceReferenceDate: TimeInterval(value))
    }

    private func validState(bytes: Int) -> Data {
        let prefix = "{\"blob\":\""
        let suffix = "\"}"
        let fill = max(0, bytes - prefix.utf8.count - suffix.utf8.count)
        return Data((prefix + String(repeating: "a", count: fill) + suffix).utf8)
    }

    private let tinyPNG = Data(base64Encoded:
        "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==")!

    private func legacyURL(root: URL, identity: GameWebStorageIdentity) throws -> URL {
        let directory = root.appendingPathComponent(identity.originHost, isDirectory: true)
        let names = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        guard let name = names.first(where: { $0.hasSuffix(".json") }) else {
            throw GameSaveSlotError.legacyStoreMissing
        }
        return directory.appendingPathComponent(name)
    }

    // MARK: - Slots and CAS

    func testCreateReopenAndCASAcrossTwoRepositoryInstances() async throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        let identity = try identity()
        let first = try repository(root, identity)
        let created = try await first.create(state: state(1), title: "First",
            sourceRevision: "r1", at: date(1))
        XCTAssertEqual(created.revision, 1)
        XCTAssertEqual(created.stateBytes, state(1).count)
        XCTAssertEqual(created.stateDigest, GameDigest.sha256(state(1)))

        let reopened = try repository(root, identity)
        let listed = try await reopened.list()
        XCTAssertEqual(listed.revision, 1)
        XCTAssertEqual(listed.slots.map(\.id), [created.id])
        let firstState = try await reopened.load(created.id).state
        XCTAssertEqual(firstState, state(1))

        let updated = try await first.update(created.id, state: state(2), thumbnail: nil,
            sourceRevision: "r2", expectedRevision: created.revision, at: date(2))
        XCTAssertEqual(updated.revision, 2)
        XCTAssertEqual(updated.sourceRevision, "r2")
        let secondState = try await reopened.load(created.id).state
        XCTAssertEqual(secondState, state(2))

        do {
            _ = try await reopened.update(created.id, state: state(3), thumbnail: nil,
                sourceRevision: "r2", expectedRevision: created.revision, at: date(3))
            XCTFail("Expected a stale revision")
        } catch {
            XCTAssertEqual(error as? GameSaveSlotError,
                .staleRevision(slotID: created.id, expected: 1, actual: 2))
        }
        let stateAfterCAS = try await reopened.load(created.id).state
        XCTAssertEqual(stateAfterCAS, state(2))
        let listedAfterCAS = try await reopened.list()
        XCTAssertEqual(listedAfterCAS.revision, 2)
    }

    func testScopeIsolationAcrossOwnerEngineEnvironmentAndNestedRoot() async throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        let firstIdentity = try identity(engine: .phaser, gameRoot: "alpha")
        let secondIdentity = try identity(engine: .phaser, gameRoot: "beta")
        let otherEngine = try identity(engine: .rpgMakerMZ, gameRoot: "alpha")
        let otherEnvironment = try identity(environmentID: "env-2", gameRoot: "alpha")
        let otherOwner = try identity(owner: .conversation(conversationID: UUID(),
            workspaceID: UUID()), gameRoot: "alpha")
        let otherProject = try identity(projectID: UUID(), gameRoot: "alpha")

        let first = try repository(root, firstIdentity)
        let slot = try await first.create(state: state(1), title: "Alpha",
            sourceRevision: "r1", at: date(1))
        for identity in [secondIdentity, otherEngine, otherEnvironment, otherOwner, otherProject] {
            let scoped = try repository(root, identity)
            let scopedList = try await scoped.list()
            XCTAssertTrue(scopedList.slots.isEmpty)
            do {
                _ = try await scoped.load(slot.id)
                XCTFail("Saved slot leaked into another scope")
            } catch {
                XCTAssertEqual(error as? GameSaveSlotError, .slotNotFound(slot.id))
            }
        }
        let alphaOnly = try repository(root, firstIdentity)
        let alphaList = try await alphaOnly.list()
        XCTAssertEqual(alphaList.slots.count, 1)

        let distinctRoot = try self.root()
        defer { try? FileManager.default.removeItem(at: distinctRoot) }
        let movedRoot = try repository(distinctRoot, firstIdentity)
        let movedList = try await movedRoot.list()
        XCTAssertTrue(movedList.slots.isEmpty)
    }

    func testOpenSlotsRefusesADirectoryInsideTheSourceTree() throws {
        let context = try context()
        let artifact = try GamePreparedArtifact(id: UUID(), engine: .phaser,
            source: context, route: .webKit,
            sha256: String(repeating: "b", count: 64),
            entry: GameRelativePath("index.html"))
        XCTAssertThrowsError(try GameWebSaveRepositories.openSlots(
            directory: context.rootURL, artifact: artifact)) { error in
            XCTAssertEqual(error as? GameSaveSlotError, .invalidConfiguration)
        }
    }

    func testSourceRebuildKeepsOneScopeButRecordsOldRevision() async throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        let oldContext = try context(revision: "old-revision")
        let rebuiltContext = try context(revision: "completely-new-revision")
        let oldIdentity = try GameWebStorageIdentity(context: oldContext, engine: .phaser)
        let newIdentity = try GameWebStorageIdentity(context: rebuiltContext, engine: .phaser)
        XCTAssertEqual(oldIdentity, newIdentity)

        let first = try repository(root, oldIdentity)
        let slot = try await first.create(state: state(1), title: "Rebuild",
            sourceRevision: oldContext.savedRevision, at: date(1))
        let rebuilt = try repository(root, newIdentity)
        let reopened = try await rebuilt.load(slot.id)
        XCTAssertEqual(reopened.state, state(1))
        XCTAssertEqual(reopened.descriptor.sourceRevision, "old-revision")
        XCTAssertNotEqual(reopened.descriptor.sourceRevision, rebuiltContext.savedRevision)
    }

    func testOverwriteDeleteRecoverAndTitleCollision() async throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = try repository(root, try identity())
        let first = try await repository.create(state: state(1), title: "Chapter",
            sourceRevision: "r1", at: date(1))
        let updated = try await repository.update(first.id, state: state(2),
            thumbnail: tinyPNG, sourceRevision: "r1", expectedRevision: first.revision,
            at: date(2))
        XCTAssertEqual(updated.thumbnailBytes, tinyPNG.count)
        let loadedThumbnail = try await repository.load(first.id).thumbnail
        XCTAssertEqual(loadedThumbnail, tinyPNG)

        let deleted = try await repository.delete(updated.id,
            expectedRevision: updated.revision, at: date(3))
        XCTAssertTrue(deleted.isDeleted)
        let activeAfterDelete = try await repository.list()
        XCTAssertTrue(activeAfterDelete.slots.isEmpty)
        let allAfterDelete = try await repository.list(includeDeleted: true)
        XCTAssertEqual(allAfterDelete.slots.count, 1)
        do {
            _ = try await repository.load(first.id)
            XCTFail("Deleted slot must not load as an active save")
        } catch {
            XCTAssertEqual(error as? GameSaveSlotError, .slotNotFound(first.id))
        }

        let recovered = try await repository.recover(deleted.id,
            expectedRevision: deleted.revision, at: date(4))
        XCTAssertFalse(recovered.isDeleted)
        let recoveredState = try await repository.load(first.id).state
        XCTAssertEqual(recoveredState, state(2))
        XCTAssertEqual(recovered.title, "Chapter")

        // Free the title before creating a distinct slot, then create a
        // genuine collision before recovering it. Two active slots cannot
        // both have "Chapter" while duplicate creation is also rejected.
        let moved = try await repository.rename(recovered.id, to: "Original",
            expectedRevision: recovered.revision, at: date(4))
        let second = try await repository.create(state: state(5), title: "Chapter",
            sourceRevision: "r1", at: date(5))
        XCTAssertNotEqual(second.id, first.id)
        do {
            _ = try await repository.create(state: state(6), title: "Chapter",
                sourceRevision: "r1", at: date(6))
            XCTFail("Duplicate active title must be rejected")
        } catch {
            XCTAssertEqual(error as? GameSaveSlotError, .titleInUse)
        }
        _ = try await repository.delete(second.id, expectedRevision: second.revision,
            at: date(7))
        _ = try await repository.rename(moved.id, to: "Chapter",
            expectedRevision: moved.revision, at: date(7))
        let renamedOnRecovery = try await repository.recover(second.id,
            expectedRevision: second.revision + 1, at: date(8))
        XCTAssertEqual(renamedOnRecovery.title, "Chapter 2")
        let collisionList = try await repository.list()
        XCTAssertEqual(collisionList.slots.count, 2)
    }

    func testAutomaticRotationKeepsManualSlots() async throws {
        let limits = try GameSaveSlotLimits(maximumSlots: 8, maximumAutosaveSlots: 3,
            maximumTrashSlots: 4, maximumTotalBytes: 8 * 1_024 * 1_024,
            maximumTitleBytes: 32, maximumThumbnailBytes: 32_768,
            maximumCatalogBytes: 512 * 1_024)
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = try repository(root, try identity(), limits: limits)
        let manual = try await repository.create(state: state(100), title: "Manual",
            sourceRevision: "r1", at: date(1))
        for index in 1...7 {
            _ = try await repository.saveAutomatic(state: state(200 + index),
                title: "Auto \(index)", sourceRevision: "r1", at: date(index + 1))
        }
        let listed = try await repository.list()
        XCTAssertEqual(listed.slots.filter { $0.kind == .autosave }.count, 3)
        XCTAssertTrue(listed.slots.contains(where: { $0.id == manual.id }))
        let manualState = try await repository.load(manual.id).state
        XCTAssertEqual(manualState, state(100))
        let autosaves = listed.slots.filter { $0.kind == .autosave }
        XCTAssertEqual(Set(autosaves.map(\.title)), Set(["Auto 5", "Auto 6", "Auto 7"]))
        let all = try await repository.list(includeDeleted: true)
        XCTAssertLessThanOrEqual(all.slots.filter(\.isDeleted).count, 4)
    }

    func testAutomaticRotationCanPreserveTheTargetAutosave() async throws {
        let limits = try GameSaveSlotLimits(maximumSlots: 4, maximumAutosaveSlots: 2,
            maximumTrashSlots: 2, maximumTotalBytes: 4 * 1_024 * 1_024,
            maximumTitleBytes: 32, maximumThumbnailBytes: 32_768,
            maximumCatalogBytes: 512 * 1_024)
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = try repository(root, try identity(), limits: limits)
        let first = try await repository.saveAutomatic(state: state(1),
            title: "Auto A", sourceRevision: "r1", at: date(1))
        let second = try await repository.saveAutomatic(state: state(2),
            title: "Auto B", sourceRevision: "r1", at: date(2))
        let safety = try await repository.saveAutomatic(state: state(3),
            title: "Before load", sourceRevision: "r1", at: date(3),
            preserving: first.id)
        XCTAssertEqual(safety.kind, .autosave)
        let listed = try await repository.list()
        XCTAssertTrue(listed.slots.contains(where: { $0.id == first.id }))
        XCTAssertTrue(listed.slots.contains(where: { $0.id == safety.id }))
        XCTAssertFalse(listed.slots.contains(where: { $0.id == second.id }))
        let safetyState = try await repository.load(safety.id).state
        XCTAssertEqual(safetyState, state(3))
    }

    // MARK: - Backup

    func testBackupRoundTripImportAsNewForeignScopeAndValidation() async throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = try repository(root, try identity())
        let slot = try await repository.create(state: state(42), title: "Backup me",
            sourceRevision: "r1", thumbnail: tinyPNG, at: date(1))
        let package = try await repository.exportBackup(slot.id)
        XCTAssertEqual(package.summary.sha256, GameDigest.sha256(package.data))
        XCTAssertEqual(package.summary.stateBytes, state(42).count)
        XCTAssertEqual(package.summary.scope, GameSaveBackupScope(identity: repository.identity))
        let inspected = try await repository.inspectBackup(package.data)
        XCTAssertEqual(inspected, package.summary)

        let firstImport = try await repository.importBackup(package.data, at: date(2))
        let secondImport = try await repository.importBackup(package.data, at: date(3))
        XCTAssertNotEqual(firstImport.slot.id, slot.id)
        XCTAssertNotEqual(firstImport.slot.id, secondImport.slot.id)
        XCTAssertEqual(firstImport.slot.kind, .manual)
        let importedState = try await repository.load(firstImport.slot.id).state
        let secondImportedState = try await repository.load(secondImport.slot.id).state
        XCTAssertEqual(importedState, state(42))
        XCTAssertEqual(secondImportedState, state(42))
        let importedList = try await repository.list()
        XCTAssertEqual(importedList.slots.count, 3)
        XCTAssertEqual(firstImport.backup.sha256, package.summary.sha256)

        let foreignRepository = try self.repository(root, try identity(engine: .rpgMakerMZ))
        do {
            _ = try await foreignRepository.importBackup(package.data, at: date(4))
            XCTFail("Foreign scope must be rejected")
        } catch {
            XCTAssertEqual(error as? GameSaveSlotError, .scopeMismatch)
        }
        let foreignList = try await foreignRepository.list(includeDeleted: true)
        XCTAssertTrue(foreignList.slots.isEmpty)

        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: package.data) as? [String: Any])
        object["stateBase64"] = Data("{\"step\":99}".utf8).base64EncodedString()
        let tampered = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        do {
            _ = try await repository.importBackup(tampered, at: date(5))
            XCTFail("Tampered state digest must be rejected")
        } catch {
            XCTAssertEqual(error as? GameSaveSlotError, .backupDigestMismatch)
        }

        var versioned = object
        versioned["version"] = 99
        let unknown = try JSONSerialization.data(withJSONObject: versioned, options: [.sortedKeys])
        do {
            _ = try await repository.importBackup(unknown, at: date(6))
            XCTFail("Unknown version must be rejected")
        } catch {
            XCTAssertEqual(error as? GameSaveSlotError, .unsupportedBackupVersion(99))
        }

        let truncated = package.data.prefix(package.data.count / 2)
        do {
            _ = try await repository.importBackup(Data(truncated), at: date(7))
            XCTFail("Truncated backup must be rejected")
        } catch {
            XCTAssertEqual(error as? GameSaveSlotError, .invalidBackup("not JSON"))
        }

        do {
            _ = try await repository.importBackup(
                Data(repeating: 0, count: repository.maximumBackupBytes + 1), at: date(8))
            XCTFail("Oversized backup must be rejected")
        } catch {
            XCTAssertEqual(error as? GameSaveSlotError,
                .limitExceeded("backupBytes"))
        }
        let finalList = try await repository.list()
        XCTAssertEqual(finalList.slots.count, 3)
    }

    func testBackupThumbnailTamperAndMissingLegacyStore() async throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        let identity = try identity()
        let repository = try repository(root, identity)
        let slot = try await repository.create(state: state(1), title: "Preview",
            sourceRevision: "r1", thumbnail: tinyPNG, at: date(1))
        let package = try await repository.exportBackup(slot.id)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: package.data) as? [String: Any])
        var thumbnail = try XCTUnwrap(object["thumbnailBase64"] as? String)
        thumbnail = String(thumbnail.dropLast())
        object["thumbnailBase64"] = thumbnail
        let tampered = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        do {
            _ = try await repository.importBackup(tampered, at: date(2))
            XCTFail("Tampered thumbnail must be rejected")
        } catch {
            XCTAssertEqual(error as? GameSaveSlotError, .invalidBackup("thumbnail"))
        }
        do {
            _ = try await repository.importLegacySave(at: date(3))
            XCTFail("A missing legacy store must be explicit")
        } catch {
            XCTAssertEqual(error as? GameSaveSlotError, .legacyStoreMissing)
        }
    }

    // MARK: - Legacy migration

    func testLegacyImportIsIdempotentAndPreservesTheOriginalFile() async throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        let context = try context()
        let identity = try GameWebStorageIdentity(context: context, engine: .phaser)
        let artifact = try GamePreparedArtifact(id: UUID(), engine: .phaser,
            source: context, route: .webKit,
            sha256: String(repeating: "a", count: 64),
            entry: GameRelativePath("index.html"))
        let legacy = try GameWebSaveRepositories.open(directory: root, artifact: artifact)
        _ = try await legacy.save(state(7), expectedRevision: 0)
        let file = try legacyURL(root: root, identity: identity)
        let before = try Data(contentsOf: file)

        let repository = try GameWebSaveRepositories.openSlots(directory: root, artifact: artifact)
        let first = try await repository.importLegacySave(title: "Legacy", at: date(1))
        XCTAssertFalse(first.alreadyImported)
        XCTAssertEqual(first.slot.kind, .manual)
        let importedLegacyState = try await repository.load(first.slot.id).state
        XCTAssertEqual(importedLegacyState, state(7))
        XCTAssertEqual(try Data(contentsOf: file), before)

        let second = try await repository.importLegacySave(title: "Legacy", at: date(2))
        XCTAssertTrue(second.alreadyImported)
        XCTAssertEqual(second.slot.id, first.slot.id)
        let legacyList = try await repository.list()
        XCTAssertEqual(legacyList.slots.count, 1)
        XCTAssertEqual(try Data(contentsOf: file), before)
        let oldLegacyState = try await legacy.load()?.state
        XCTAssertEqual(oldLegacyState, state(7))

        let other = UUID()
        let foreign = try JSONEncoder().encode(GameSaveLegacyRecordForTest(version: 1,
            projectID: other, owner: .space(recordID: other), revision: 1, state: state(8)))
        try foreign.write(to: file)
        do {
            _ = try await repository.importLegacySave(at: date(3))
            XCTFail("A legacy file from another project must be rejected")
        } catch {
            XCTAssertEqual(error as? GameSaveSlotError, .legacyScopeMismatch)
        }

        try Data("not a legacy record".utf8).write(to: file)
        do {
            _ = try await repository.importLegacySave(at: date(4))
            XCTFail("A corrupt legacy file must be explicit")
        } catch {
            XCTAssertEqual(error as? GameSaveSlotError, .legacyStoreCorrupt)
        }
    }

    // MARK: - Corruption and cancellation

    func testCorruptMissingAndTruncatedPayloadsAreTypedAndDoNotDestroyOtherSlots() async throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = try repository(root, try identity())
        let first = try await repository.create(state: state(1), title: "One",
            sourceRevision: "r1", at: date(1))
        let second = try await repository.create(state: state(2), title: "Two",
            sourceRevision: "r1", at: date(2))
        let payloads = repository.storageDirectory.appendingPathComponent("payloads")
        let names = try FileManager.default.contentsOfDirectory(atPath: payloads.path)
        let firstPayload = payloads.appendingPathComponent(first.stateDigest + ".json")
        XCTAssertTrue(names.contains(first.stateDigest + ".json"))
        try Data("{\"step\":999}".utf8).write(to: firstPayload)
        do {
            _ = try await repository.load(first.id)
            XCTFail("Corrupt payload must be typed")
        } catch {
            XCTAssertEqual(error as? GameSaveSlotError, .corruptSlot(first.id))
        }
        let survivingSecond = try await repository.load(second.id).state
        XCTAssertEqual(survivingSecond, state(2))

        try FileManager.default.removeItem(at: firstPayload)
        do {
            _ = try await repository.load(first.id)
            XCTFail("Missing payload must be typed")
        } catch {
            XCTAssertEqual(error as? GameSaveSlotError, .payloadMissing(first.id))
        }
        let survivingSecondAgain = try await repository.load(second.id).state
        XCTAssertEqual(survivingSecondAgain, state(2))
    }

    func testCorruptCatalogIsTyped() async throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = try repository(root, try identity())
        _ = try await repository.create(state: state(1), title: "One",
            sourceRevision: "r1", at: date(1))
        let catalog = repository.storageDirectory.appendingPathComponent("catalog-v1.json")
        try Data("{}".utf8).write(to: catalog)
        do {
            _ = try await repository.list()
            XCTFail("A corrupt catalog must be typed")
        } catch {
            XCTAssertEqual(error as? GameSaveSlotError, .corruptCatalog)
        }
    }

    func testCancellationLeavesTheStoreRecoverable() async throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = try repository(root, try identity())
        let existing = try await repository.create(state: state(1), title: "Existing",
            sourceRevision: "r1", at: date(1))
        let task = Task {
            while !Task.isCancelled { await Task.yield() }
            return try await repository.create(state: state(2), title: "Cancelled",
                sourceRevision: "r1", at: date(2))
        }
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("A pre-cancelled create should not commit")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
        let listed = try await repository.list()
        XCTAssertEqual(listed.slots.map(\.id), [existing.id])
        let survivingExisting = try await repository.load(existing.id).state
        XCTAssertEqual(survivingExisting, state(1))
    }

    // MARK: - Bounds

    func testBoundsTitlesSlotCountTotalBytesStateAndThumbnail() async throws {
        let limits = try GameSaveSlotLimits(maximumSlots: 3, maximumAutosaveSlots: 1,
            maximumTrashSlots: 2, maximumTotalBytes: 1_048_576,
            maximumTitleBytes: 16, maximumThumbnailBytes: 16_384,
            maximumCatalogBytes: 262_144)
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = try repository(root, try identity(), limits: limits)
        do {
            _ = try await repository.create(state: state(1), title: "",
                sourceRevision: "r1", at: date(1))
            XCTFail("Empty title must be rejected")
        } catch {
            XCTAssertEqual(error as? GameSaveSlotError, .invalidTitle)
        }
        do {
            _ = try await repository.create(state: Data("not json".utf8), title: "Bad",
                sourceRevision: "r1", at: date(1))
            XCTFail("Malformed state must be rejected")
        } catch {
            XCTAssertEqual(error as? GameSaveSlotError, .invalidState)
        }
        do {
            _ = try await repository.create(state: Data(repeating: 0x20,
                count: GameWebRuntimePolicy(engine: .phaser).maximumStateBytes + 1),
                title: "Huge", sourceRevision: "r1", at: date(1))
            XCTFail("State beyond the engine policy must be rejected")
        } catch {
            XCTAssertEqual(error as? GameSaveSlotError,
                .stateTooLarge(GameWebRuntimePolicy(engine: .phaser).maximumStateBytes + 1))
        }
        do {
            _ = try await repository.create(state: state(1), title: "Thumb",
                sourceRevision: "r1", thumbnail: Data(repeating: 0, count: 100),
                at: date(1))
            XCTFail("Non-PNG thumbnail must be rejected")
        } catch {
            XCTAssertEqual(error as? GameSaveSlotError, .invalidThumbnail)
        }
        do {
            _ = try await repository.create(state: state(1),
                title: String(repeating: "x", count: 17),
                sourceRevision: "r1", at: date(1))
            XCTFail("Overlong title must be rejected")
        } catch {
            XCTAssertEqual(error as? GameSaveSlotError, .invalidTitle)
        }

        let one = try await repository.create(state: validState(bytes: 700_000),
            title: "One", sourceRevision: "r1", at: date(1))
        _ = try await repository.create(state: state(2), title: "Two",
            sourceRevision: "r1", at: date(2))
        _ = try await repository.create(state: state(3), title: "Three",
            sourceRevision: "r1", at: date(3))
        do {
            _ = try await repository.create(state: state(4), title: "Four",
                sourceRevision: "r1", at: date(4))
            XCTFail("Maximum slot count must be enforced")
        } catch {
            XCTAssertEqual(error as? GameSaveSlotError, .limitExceeded("slots"))
        }
        _ = try await repository.delete(one.id, expectedRevision: one.revision, at: date(5))
        do {
            _ = try await repository.create(state: validState(bytes: 700_000),
                title: "Five", sourceRevision: "r1", at: date(6))
            XCTFail("Aggregate bytes must be bounded")
        } catch {
            XCTAssertEqual(error as? GameSaveSlotError, .limitExceeded("bytes"))
        }
    }

    func testEnginePolicyStateLimitIsPerScope() async throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        let phaser = try repository(root, try identity(engine: .phaser))
        let wasm4 = try repository(root, try identity(engine: .wasm4))
        let state = validState(bytes: 2 * 1_024 * 1_024)
        do {
            _ = try await phaser.create(state: state, title: "Large",
                sourceRevision: "r1", at: date(1))
            XCTFail("Phaser state limit is 1 MiB")
        } catch {
            XCTAssertEqual(error as? GameSaveSlotError, .stateTooLarge(state.count))
        }
        let accepted = try await wasm4.create(state: state, title: "Large",
            sourceRevision: "r1", at: date(2))
        XCTAssertEqual(accepted.stateBytes, state.count)
        let loadedLargeState = try await wasm4.load(accepted.id).state
        XCTAssertEqual(loadedLargeState, state)
    }
}

private struct GameSaveLegacyRecordForTest: Codable {
    let version: Int
    let projectID: UUID
    let owner: GameProjectOwner
    let revision: UInt64
    let state: Data
}
