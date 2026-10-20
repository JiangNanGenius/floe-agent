// SPDX-License-Identifier: MPL-2.0
//
// RB-1 source tests — trusted root/identity rules and the ORIGINAL
// file-backed store owner. Real `DatabaseManager` + the real 46-migration
// chain over a test-owned app-private-style directory; nothing synthetic
// replaces the persistence authority. AUTHORED ONLY: not compiled or
// executed by this source package (the serialized qualifier runs them).
import XCTest
import Foundation
import GRDB
import FloeModels
import FloePersistence
@testable import FloeAndroidCore

final class RuntimeFacadeStoresTests: XCTestCase {

    private func makeRootDirectory() throws -> String {
        let base = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("floe-rb1-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base.standardizedFileURL.path
    }

    private func identity(in path: String,
                          token: String = "a1b2c3d4e5f60718a1b2c3d4e5f60718",
                          epoch: UInt64 = 1) -> RuntimeOwnerIdentity? {
        guard let root = RuntimeStorageRoot(validatingAbsoluteDirectory: path) else {
            return nil
        }
        return RuntimeOwnerIdentity(root: root, token: token, epoch: epoch)
    }

    // MARK: Root validation (M1 rules)

    func testRejectsNonNormalizedAndNonAbsoluteRoots() {
        XCTAssertNil(RuntimeStorageRoot(validatingAbsoluteDirectory: ""))
        XCTAssertNil(RuntimeStorageRoot(validatingAbsoluteDirectory: "relative/dir"))
        XCTAssertNil(RuntimeStorageRoot(validatingAbsoluteDirectory: "/"))
        XCTAssertNil(RuntimeStorageRoot(validatingAbsoluteDirectory: "/tmp/../tmp/dir"))
        XCTAssertNil(RuntimeStorageRoot(validatingAbsoluteDirectory: "/tmp//dir"))
        XCTAssertNil(RuntimeStorageRoot(validatingAbsoluteDirectory: "/tmp/dir/."))
        XCTAssertNil(RuntimeStorageRoot(validatingAbsoluteDirectory: "/tmp/dir\ncontrol"))
        let root = "/private/var/mobile/Containers/Data/Application/X/files/floe-runtime"
        XCTAssertNotNil(RuntimeStorageRoot(validatingAbsoluteDirectory: root))
        // Trailing slash is accepted exactly once and normalized.
        let slashed = RuntimeStorageRoot(validatingAbsoluteDirectory: root + "/")
        XCTAssertEqual(slashed?.path, root)
    }

    func testOwnerEqualityUsesExactFullRootNotFingerprint() throws {
        // Two DIFFERENT long paths are never ownership-equal even if a
        // short diagnostic fingerprint could collide.
        let first = try XCTUnwrap(identity(in: "/tmp/floe-a"))
        let second = try XCTUnwrap(identity(in: "/tmp/floe-b"))
        XCTAssertFalse(first.matchesOwnership(of: second))
        // Same normalized root + same token is ownership-equal even when
        // input spellings differ only by the accepted trailing slash.
        let sameNormalized = try XCTUnwrap(identity(in: "/tmp/floe-a/"))
        XCTAssertTrue(first.matchesOwnership(of: sameNormalized))
        // Same root, DIFFERENT token => different owner.
        let differentToken = try XCTUnwrap(
            identity(in: "/tmp/floe-a", token: String(repeating: "f", count: 32)))
        XCTAssertFalse(first.matchesOwnership(of: differentToken))
        // The fingerprint stays available for diagnostics but is NOT the
        // equality source.
        XCTAssertNotEqual(first.root.fingerprint.count, first.root.path.count)
    }

    func testOwnerTokenRulesAreStrictHex() {
        guard let root = RuntimeStorageRoot(validatingAbsoluteDirectory: "/tmp/floe-a") else {
            return XCTFail("root")
        }
        XCTAssertNil(RuntimeOwnerIdentity(root: root, token: "short16", epoch: 1))
        XCTAssertNil(RuntimeOwnerIdentity(root: root, token: "ZZ0123456789abcdef0123456789abcdef", epoch: 1))
        XCTAssertNil(RuntimeOwnerIdentity(root: root, token: String(repeating: "a", count: 65), epoch: 1))
        XCTAssertNil(RuntimeOwnerIdentity(root: root, token: "0123456789abcdef0123456789abcdef", epoch: 0))
        XCTAssertNotNil(RuntimeOwnerIdentity(root: root, token: "0123456789abcdef0123456789abcdef", epoch: 7))
    }

    // MARK: Original file-backed open + migrate (ONE real DatabaseManager)

    func testFileBackedOpenRunsRealMigrationsToExactCurrentVersion() async throws {
        let path = try makeRootDirectory()
        defer { try? FileManager.default.removeItem(atPath: path) }
        let owner = try XCTUnwrap(identity(in: path))
        let subject = AndroidRuntimeStoreOwner()
        await subject.openAndMigrate(with: owner)
        let phase = await subject.currentPhase
        XCTAssertEqual(phase, .migrated)
        let versionValue = await subject.currentUserVersion()
        let version = try XCTUnwrap(versionValue)
        XCTAssertEqual(version, DatabaseManager.currentSchemaVersion)
        XCTAssertEqual(version, 46)
        // The REAL file exists at the derived original location (never a
        // RAM store): flooe.sqlite + GRDB sidecars under the trusted root.
        let dbFile = URL(fileURLWithPath: path).appendingPathComponent("floe.sqlite")
        let exists = FileManager.default.fileExists(atPath: dbFile.path)
        XCTAssertTrue(exists)
        // The checkpoint directory was created under the SAME trusted root.
        let checkpoint = URL(fileURLWithPath: path).appendingPathComponent("checkpoints")
        let isDir = (try? checkpoint.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory
        XCTAssertEqual(isDir, true)
        await subject.close()
        let closedVersion = await subject.currentUserVersion()
        XCTAssertNil(closedVersion)  // closed lifecycle never claims a version
    }

    func testRepeatedOpenIsTypedConflictNotCrash() async throws {
        let path = try makeRootDirectory()
        defer { try? FileManager.default.removeItem(atPath: path) }
        let owner = try XCTUnwrap(identity(in: path))
        let subject = AndroidRuntimeStoreOwner()
        await subject.openAndMigrate(with: owner)
        await subject.openAndMigrate(with: owner)
        let failure = await subject.lastFailureCode()
        XCTAssertEqual(failure, .lifecycleConflict)
        let phase = await subject.currentPhase
        XCTAssertEqual(phase, .migrated)   // the first open still owns the lifecycle
        await subject.close()
    }

    func testCloseInvalidatesTokenAndIsIdempotent() async throws {
        let path = try makeRootDirectory()
        defer { try? FileManager.default.removeItem(atPath: path) }
        let owner = try XCTUnwrap(identity(in: path))
        let subject = AndroidRuntimeStoreOwner()
        await subject.openAndMigrate(with: owner)
        await subject.recover(token: owner.epoch)
        let ready = await subject.currentPhase
        XCTAssertEqual(ready, .ready)
        await subject.close()
        await subject.close()
        let closed = await subject.currentPhase
        XCTAssertEqual(closed, .closed)
        // A stale-token recover after close must not resurrect readiness.
        await subject.recover(token: owner.epoch)
        let still = await subject.currentPhase
        XCTAssertEqual(still, .closed)
        // Reopening on a CLOSED instance is a typed conflict, never a crash.
        await subject.openAndMigrate(with: owner)
        let phase = await subject.currentPhase
        XCTAssertEqual(phase, .closed)
        let failure = await subject.lastFailureCode()
        XCTAssertEqual(failure, .lifecycleConflict)
    }

    func testRecoverWithForeignTokenIsIgnored() async throws {
        let path = try makeRootDirectory()
        defer { try? FileManager.default.removeItem(atPath: path) }
        let owner = try XCTUnwrap(identity(in: path))
        let subject = AndroidRuntimeStoreOwner()
        await subject.openAndMigrate(with: owner)
        await subject.recover(token: owner.epoch &+ 999)
        let phase = await subject.currentPhase
        XCTAssertEqual(phase, .migrated)   // not recovered, not failed
        await subject.close()
    }

    // MARK: Real store cluster wiring (original constructors)

    func testClusterExposesRealOriginalStores() async throws {
        let path = try makeRootDirectory()
        defer { try? FileManager.default.removeItem(atPath: path) }
        let owner = try XCTUnwrap(identity(in: path))
        let subject = AndroidRuntimeStoreOwner()
        await subject.openAndMigrate(with: owner)
        let conversationStoreValue = await subject.conversationStore
        let conversationStore = try XCTUnwrap(conversationStoreValue)
        let runStoreValue = await subject.runStore
        let runStore = try XCTUnwrap(runStoreValue)
        let settingsValue = await subject.settingsStore
        let settings = try XCTUnwrap(settingsValue)
        let launchValue = await subject.runLaunchStore
        let launch = try XCTUnwrap(launchValue)
        // Round-trip through the ORIGINAL store APIs on the real file-backed
        // database.
        let conversationID = UUID()
        let now = Date()
        try await conversationStore.saveConversation(ConversationRecord(
            id: conversationID, title: "RB1 probe", createdAt: now, updatedAt: now))
        let runID = UUID()
        try await runStore.saveRun(RunRecord(
            id: runID, conversationID: conversationID,
            state: "running", goal: "probe", startedAt: now))
        let loaded = try await runStore.run(id: runID)
        XCTAssertEqual(loaded?.state, "running")
        _ = settings
        _ = launch   // constructor identity only; prepare() is RB3/RB4 scope
        await subject.close()
    }

    func testOpenAgainstRegularFileFailsTypedWithoutFallback() async throws {
        // A trusted host that hands us a NON-directory path must fail the
        // open typed — never silently fall back to RAM or another root.
        let base = try makeRootDirectory()
        defer { try? FileManager.default.removeItem(atPath: base) }
        let blocker = URL(fileURLWithPath: base).appendingPathComponent("not-a-dir")
        FileManager.default.createFile(atPath: blocker.path, contents: Data("x".utf8))
        let asDirectory = URL(fileURLWithPath: blocker.path)
            .appendingPathComponent("sub", isDirectory: true).path
        guard let root = RuntimeStorageRoot(validatingAbsoluteDirectory: asDirectory),
              let owner = RuntimeOwnerIdentity(root: root,
                                               token: "0123456789abcdef0123456789abcdef",
                                               epoch: 1) else {
            return XCTFail("identity")
        }
        let subject = AndroidRuntimeStoreOwner()
        await subject.openAndMigrate(with: owner)
        let phase = await subject.currentPhase
        XCTAssertEqual(phase, .failed)
        let failure = await subject.lastFailureCode()
        XCTAssertEqual(failure, .checkpointDirectoryFailed)
        await subject.close()
    }
}
