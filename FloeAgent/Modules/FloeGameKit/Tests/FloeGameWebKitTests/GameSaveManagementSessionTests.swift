// SPDX-License-Identifier: MPL-2.0
import Foundation
import XCTest
import FloeGameCore
@testable import FloeGameWebKit

@MainActor
final class GameSaveManagementSessionTests: XCTestCase {
    private let projectID = UUID(uuidString: "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee")!

    private let tinyPNG = Data(base64Encoded:
        "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==")!

    // MARK: - Helpers

    private func root() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("FloeSaveSessionTests-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func identity(engine: GameEngineID = .phaser,
                          environmentID: String? = "env-1",
                          gameRoot: String = ".") throws -> GameWebStorageIdentity {
        try GameWebStorageIdentity(projectID: projectID,
            owner: .space(recordID: projectID), engine: engine,
            environmentID: environmentID, gameRoot: gameRoot)
    }

    private func state(_ step: Int) -> Data {
        Data("{\"step\":\(step)}".utf8)
    }

    private func makeSession(_ port: FakeSavePort,
                             root: URL,
                             limits: GameSaveSlotLimits = try! .init()) throws -> GameSaveManagementSession {
        let repository = try FileGameSaveSlotRepository(directory: root,
            identity: port.saveIdentity, limits: limits)
        return try GameSaveManagementSession(port: port, repository: repository)
    }

    // MARK: - Readiness

    func testCaptureOnlyRunsWhenThePlayerIsReadyAndSupportsState() async throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        let port = try FakeSavePort(identity: identity())
        port.saveIsReady = false
        let session = try makeSession(port, root: root)
        try await session.refresh()
        do {
            _ = try await session.saveNew(title: "Stopped")
            XCTFail("A stopped player must not capture")
        } catch {
            XCTAssertEqual(error as? GameSaveManagementError, .stateUnavailable)
        }
        XCTAssertEqual(port.snapshotCalls, 0)

        port.saveIsReady = true
        port.saveSupportsState = false
        do {
            _ = try await session.saveNew(title: "Unsupported")
            XCTFail("An engine without native state must not capture")
        } catch {
            XCTAssertEqual(error as? GameSaveManagementError, .stateUnavailable)
        }
        XCTAssertEqual(port.snapshotCalls, 0)

        port.saveSupportsState = true
        port.snapshotState = state(1)
        let slot = try await session.saveNew(title: "Running")
        XCTAssertEqual(slot.kind, .manual)
        let savedState = try await session.repository.load(slot.id).state
        XCTAssertEqual(savedState, state(1))
        XCTAssertEqual(session.activeSlots.map(\.id), [slot.id])
    }

    func testRunGenerationChangeRejectsLateCapturedBytes() async throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        let port = try FakeSavePort(identity: identity())
        let session = try makeSession(port, root: root)
        try await session.refresh()

        port.beforeSnapshot = {
            // Same player, same identity/source: only the run generation
            // distinguishes the restarted run that is ready again.
            port.saveRunGeneration = 2
            port.saveIsReady = false
            port.saveIsReady = true
        }
        do {
            _ = try await session.saveNew(title: "Stale run")
            XCTFail("A capture from an older run must not be persisted")
        } catch {
            XCTAssertEqual(error as? GameSaveManagementError, .staleRun)
        }
        XCTAssertEqual(port.snapshotCalls, 1)
        XCTAssertFalse(session.runGenerationIsCurrent)
        XCTAssertFalse(session.supportsNativeState)
        let emptyList = try await session.repository.list(includeDeleted: true)
        XCTAssertTrue(emptyList.slots.isEmpty)
    }

    func testSessionCreatedBeforeStartAdoptsTheFirstReadyRunOnly() async throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        let port = try FakeSavePort(identity: identity())
        port.saveIsReady = false
        port.saveRunGeneration = 0
        let session = try makeSession(port, root: root)
        try await session.refresh()
        XCTAssertEqual(session.readiness, .notRunning)

        port.saveRunGeneration = 1
        port.saveIsReady = true
        session.refreshReadiness()
        XCTAssertTrue(session.supportsNativeState)
        let saved = try await session.saveNew(title: "First ready run")
        XCTAssertEqual(saved.kind, .manual)

        port.saveIsReady = false
        port.saveRunGeneration = 2
        port.saveIsReady = true
        session.refreshReadiness()
        XCTAssertFalse(session.runGenerationIsCurrent)
        do {
            _ = try await session.saveNew(title: "Second run")
            XCTFail("The session must not adopt a later run")
        } catch {
            XCTAssertEqual(error as? GameSaveManagementError, .staleRun)
        }
    }

    // MARK: - Load safety checkpoint

    func testLoadCreatesSafetyCheckpointAndKeepsItWhenRestoreFails() async throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        let port = try FakeSavePort(identity: identity())
        port.snapshotState = state(1)
        let session = try makeSession(port, root: root)
        let original = try await session.saveNew(title: "Original")

        port.snapshotState = state(2)
        port.restoreError = FakePortError.restore
        do {
            _ = try await session.load(original.id, checkpointTitle: "Before load")
            XCTFail("A restore failure must be reported")
        } catch {
            guard let mapped = error as? GameSaveManagementError,
                  case .restoreFailed = mapped else {
                return XCTFail("Expected a typed restore failure, got \(error)")
            }
        }
        XCTAssertEqual(port.restoreCalls, 1)
        let afterFailure = try await session.repository.list(includeDeleted: true)
        XCTAssertTrue(afterFailure.slots.contains(where: { $0.id == original.id }))
        let safety = try XCTUnwrap(afterFailure.slots.first(where: { $0.kind == .autosave }))
        let safetyState = try await session.repository.load(safety.id).state
        XCTAssertEqual(safetyState, state(2))
        XCTAssertEqual(session.activeSlots.map(\.id), [original.id])

        port.restoreError = nil
        _ = try await session.load(original.id, checkpointTitle: "Before load")
        XCTAssertEqual(port.restored.last, state(1))
        XCTAssertTrue(session.activeSlots.contains(where: { $0.id == original.id }))
    }

    func testOverwriteCASIsPinnedToTheObservedRevision() async throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        let port = try FakeSavePort(identity: identity())
        port.snapshotState = state(1)
        let session = try makeSession(port, root: root)
        let slot = try await session.saveNew(title: "CAS")

        port.snapshotState = state(2)
        let updated = try await session.overwrite(slot.id)
        XCTAssertEqual(updated.revision, 2)
        let overwrittenState = try await session.repository.load(slot.id).state
        XCTAssertEqual(overwrittenState, state(2))

        let external = try await session.repository.update(slot.id, state: state(3),
            thumbnail: nil, sourceRevision: port.saveSourceRevision,
            expectedRevision: updated.revision)
        XCTAssertEqual(external.revision, 3)
        do {
            _ = try await session.overwrite(slot.id)
            XCTFail("A stale cached revision must not overwrite")
        } catch {
            XCTAssertEqual(error as? GameSaveManagementError,
                .repository(.staleRevision(slotID: slot.id,
                    expected: 2, actual: 3)))
        }
        XCTAssertEqual(session.activeSlots.first(where: { $0.id == slot.id })?.revision, 3)
        let externalState = try await session.repository.load(slot.id).state
        XCTAssertEqual(externalState, state(3))
    }

    // MARK: - Automatic save

    func testAutomaticSaveReportsUnsupportedFailureAndDeduplicates() async throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        let port = try FakeSavePort(identity: identity())
        let session = try makeSession(port, root: root)

        port.saveSupportsState = false
        var result = await session.saveAutomaticIfSupported()
        XCTAssertEqual(result, .unsupported)

        port.saveSupportsState = true
        port.saveIsReady = false
        result = await session.saveAutomaticIfSupported()
        XCTAssertEqual(result, .notRunning)

        port.saveIsReady = true
        port.snapshotState = state(4)
        result = await session.saveAutomaticIfSupported(title: "Closing")
        guard case .saved(let first) = result else {
            return XCTFail("Expected an automatic save")
        }
        XCTAssertEqual(first.kind, .autosave)
        result = await session.saveAutomaticIfSupported(title: "Closing")
        guard case .unchanged(let unchanged) = result else {
            return XCTFail("An unchanged state should not duplicate")
        }
        XCTAssertEqual(unchanged.id, first.id)

        port.snapshotState = state(5)
        result = await session.saveAutomaticIfSupported(title: "Closing")
        guard case .saved(let second) = result else {
            return XCTFail("Expected a new automatic save")
        }
        XCTAssertNotEqual(second.id, first.id)

        port.snapshotError = FakePortError.snapshot
        result = await session.saveAutomaticIfSupported(title: "Closing")
        guard case .failed(.captureFailed) = result else {
            return XCTFail("Capture failure must be explicit")
        }
        XCTAssertNotNil(session.lastError)

        session.autosaveEnabled = false
        result = await session.saveAutomaticIfSupported()
        XCTAssertEqual(result, .disabled)

        session.invalidate()
        result = await session.saveAutomaticIfSupported()
        XCTAssertEqual(result, .invalidated)
    }

    func testAutomaticSaveRejectsAChangedGeneration() async throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        let port = try FakeSavePort(identity: identity())
        let session = try makeSession(port, root: root)
        port.saveRunGeneration = 2
        let result = await session.saveAutomaticIfSupported()
        guard case .failed(.staleRun) = result else {
            return XCTFail("A later run must not be saved by the old session")
        }
        XCTAssertEqual(port.snapshotCalls, 0)
    }

    // MARK: - Invalidation

    func testInvalidateFencesLateCaptureAndBlocksFurtherWork() async throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        let port = try FakeSavePort(identity: identity())
        let session = try makeSession(port, root: root)
        let gate = AsyncGate()
        port.beforeSnapshot = { await gate.wait() }
        let task = Task { try await session.saveNew(title: "Late") }
        var spins = 0
        while port.snapshotCalls == 0 && spins < 10_000 {
            await Task.yield()
            spins += 1
        }
        XCTAssertEqual(port.snapshotCalls, 1)
        session.invalidate()
        await gate.open()
        do {
            _ = try await task.value
            XCTFail("A late capture must be discarded")
        } catch {
            XCTAssertEqual(error as? GameSaveManagementError, .invalidated)
        }
        let emptyAfterInvalidate = try await session.repository.list(includeDeleted: true)
        XCTAssertTrue(emptyAfterInvalidate.slots.isEmpty)
        do {
            _ = try await session.saveNew(title: "Blocked")
            XCTFail("An invalidated session must reject new work")
        } catch {
            XCTAssertEqual(error as? GameSaveManagementError, .invalidated)
        }
        do {
            _ = try await session.refresh()
            XCTFail("An invalidated session must not refresh")
        } catch {
            XCTAssertEqual(error as? GameSaveManagementError, .invalidated)
        }
    }

    // MARK: - Backup and thumbnails

    func testBackupReadbackAndImportThroughSession() async throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        let port = try FakeSavePort(identity: identity())
        port.snapshotState = state(10)
        let session = try makeSession(port, root: root)
        let slot = try await session.saveNew(title: "Exportable")
        let package = try await session.exportBackup(slot.id)

        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("FloeBackup-" + UUID().uuidString + ".json")
        defer { try? FileManager.default.removeItem(at: file) }
        try package.data.write(to: file)
        let summary = try await session.inspectBackup(at: file)
        XCTAssertEqual(summary.sha256, GameDigest.sha256(package.data))
        XCTAssertEqual(summary.fileBytes, package.data.count)
        XCTAssertEqual(summary.scope, GameSaveBackupScope(identity: session.identity))

        let first = try await session.importBackup(package.data)
        let second = try await session.importBackup(from: file)
        XCTAssertNotEqual(first.slot.id, slot.id)
        XCTAssertNotEqual(second.slot.id, first.slot.id)
        let firstImportState = try await session.repository.load(first.slot.id).state
        XCTAssertEqual(firstImportState, state(10))
        XCTAssertEqual(session.activeSlots.count, 3)

        let foreignIdentity = try identity(engine: .rpgMakerMZ)
        let foreignPort = try FakeSavePort(identity: foreignIdentity)
        let foreignSession = try makeSession(foreignPort, root: root)
        do {
            _ = try await foreignSession.importBackup(package.data)
            XCTFail("A foreign-scope backup must be rejected")
        } catch {
            XCTAssertEqual(error as? GameSaveManagementError, .repository(.scopeMismatch))
        }
        XCTAssertTrue(foreignSession.activeSlots.isEmpty)

        do {
            _ = try await session.importBackup(
                Data(repeating: 0, count: session.repository.maximumBackupBytes + 1))
            XCTFail("An oversized backup must be rejected")
        } catch {
            XCTAssertEqual(error as? GameSaveManagementError,
                .repository(.limitExceeded("backupBytes")))
        }
    }

    func testThumbnailCaptureIsOptionalAndBounded() async throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        let port = try FakeSavePort(identity: identity())
        port.png = tinyPNG
        let session = try makeSession(port, root: root)
        let withImage = try await session.saveNew(title: "With preview")
        XCTAssertGreaterThan(withImage.thumbnailBytes, 0)
        let preview = try await session.repository.load(withImage.id).thumbnail
        XCTAssertNotNil(preview)

        port.png = Data([0, 1, 2, 3])
        let withoutImage = try await session.saveNew(title: "Bad preview")
        XCTAssertEqual(withoutImage.thumbnailBytes, 0)
        let noPreview = try await session.repository.load(withoutImage.id).thumbnail
        XCTAssertNil(noPreview)

        port.pngError = FakePortError.png
        let failedPreview = try await session.saveNew(title: "No preview")
        XCTAssertEqual(failedPreview.thumbnailBytes, 0)
        let failedPreviewState = try await session.repository.load(failedPreview.id).state
        XCTAssertNotNil(failedPreviewState)
    }
}

// MARK: - Fakes

@MainActor
private final class FakeSavePort: GameSavePlayerPort {
    let saveIdentity: GameWebStorageIdentity
    var saveSourceRevision: String
    var saveSupportsState = true
    var saveIsReady = true
    var saveRunGeneration = 1
    var snapshotState = Data("{\"step\":1}".utf8)
    var snapshotError: (any Error)?
    var restoreError: (any Error)?
    var png: Data?
    var pngError: (any Error)?
    var snapshotCalls = 0
    var restoreCalls = 0
    var pngCalls = 0
    var restored: [Data] = []
    var beforeSnapshot: (() async -> Void)?
    var beforeRestore: (() async -> Void)?

    init(identity: GameWebStorageIdentity, revision: String = "r1") {
        saveIdentity = identity
        saveSourceRevision = revision
    }

    func saveSnapshotState() async throws -> Data {
        snapshotCalls += 1
        if let beforeSnapshot { await beforeSnapshot() }
        if let snapshotError { throw snapshotError }
        return snapshotState
    }

    func saveRestoreState(_ data: Data) async throws {
        restoreCalls += 1
        if let beforeRestore { await beforeRestore() }
        if let restoreError { throw restoreError }
        restored.append(data)
    }

    func saveCapturePNG() async throws -> Data {
        pngCalls += 1
        if let pngError { throw pngError }
        guard let png else { throw FakePortError.png }
        return png
    }
}

private enum FakePortError: Error {
    case snapshot
    case restore
    case png
}

private actor AsyncGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private var opened = false

    func wait() async {
        if opened { return }
        await withCheckedContinuation { continuation = $0 }
    }

    func open() {
        opened = true
        continuation?.resume()
        continuation = nil
    }
}
