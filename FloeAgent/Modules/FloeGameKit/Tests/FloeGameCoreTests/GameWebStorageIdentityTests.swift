// SPDX-License-Identifier: MPL-2.0
import Foundation
import XCTest
@testable import FloeGameCore

final class GameWebStorageIdentityTests: XCTestCase {
    func testNestedGamesKeepIndependentStorageAcrossRebuilds() throws {
        let a = try GameWebStorageIdentity(context: context(), engine: .phaser, gameRoot: "alpha")
        let b = try GameWebStorageIdentity(context: context(), engine: .phaser, gameRoot: "beta")
        let rebuilt = try GameWebStorageIdentity(context: context(revision: "new-revision"), engine: .phaser, gameRoot: "alpha")
        XCTAssertNotEqual(a.uuid, b.uuid)
        XCTAssertEqual(a, rebuilt)
        XCTAssertNotEqual(a.uuid, try GameWebStorageIdentity(context: context(), engine: .phaser).uuid)
        XCTAssertThrowsError(try GameWebStorageIdentity(context: context(), engine: .phaser, gameRoot: "../alpha"))
        XCTAssertThrowsError(try GameWebStorageIdentity(context: context(), engine: .phaser, gameRoot: ".git"))
    }

    func testNativeSnapshotSlotsUseTheSameIndependentScopeAndReopenDurably() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let value = try context()
        func artifact(_ path: String) throws -> GamePreparedArtifact {
            try .init(id: UUID(), engine: .phaser, source: value, route: .webKit,
                sha256: String(repeating: "0", count: 64), entry: GameRelativePath("index.html"), gameRoot: path)
        }
        let alpha = try artifact("alpha"), beta = try artifact("beta")
        let a = try GameWebSaveRepositories.open(directory: root, artifact: alpha)
        let b = try GameWebSaveRepositories.open(directory: root, artifact: beta)
        let left = Data(#"{"step":11}"#.utf8), right = Data(#"{"step":2}"#.utf8)
        _ = try await a.save(left, expectedRevision: 0)
        _ = try await b.save(right, expectedRevision: 0)
        let reopened = try GameWebSaveRepositories.open(directory: root, artifact: alpha)
        let savedA = try await reopened.load(), savedB = try await b.load()
        XCTAssertEqual(savedA?.state, left)
        XCTAssertEqual(savedB?.state, right)
        XCTAssertEqual(try alpha.storageIdentity().gameRoot, "alpha")
    }

    private let projectID = UUID(uuidString: "11111111-2222-4333-8444-555555555555")!
    private let otherProjectID = UUID(uuidString: "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee")!

    private func context(projectID: UUID? = nil, owner: GameProjectOwner? = nil,
                         revision: String = "r1", environmentID: String? = "env-1") throws -> GameProjectContext {
        let id = projectID ?? self.projectID
        return try GameProjectContext(projectID: id, owner: owner ?? .space(recordID: id),
            rootURL: FileManager.default.temporaryDirectory.appendingPathComponent("storage-identity-" + UUID().uuidString),
            savedRevision: revision, environmentID: environmentID)
    }

    func testKnownVectorsAndStableOriginHost() throws {
        let space = try GameWebStorageIdentity(context: context(), engine: .rpgMakerMZ)
        XCTAssertEqual(space.uuid.uuidString.lowercased(), "c2000910-a5f1-876a-bdb8-09195cd3b1b5")
        XCTAssertEqual(space.originHost, "c2000910-a5f1-876a-bdb8-09195cd3b1b5")

        let conversation = try GameWebStorageIdentity(
            projectID: otherProjectID,
            owner: .conversation(conversationID: projectID,
                workspaceID: UUID(uuidString: "99999999-8888-4777-8666-555555555555")!),
            engine: .phaser, environmentID: nil)
        XCTAssertEqual(conversation.uuid.uuidString.lowercased(), "7dba7c4d-324e-8916-b3bc-9e70485a5bec")
    }

    func testSavedRevisionAndRootDoNotChangeTheStorageScope() throws {
        let first = try GameWebStorageIdentity(
            context: context(revision: "r1", environmentID: "env-1"), engine: .rpgMakerMZ)
        let second = try GameWebStorageIdentity(
            context: context(revision: "a-completely-different-revision", environmentID: "env-1"),
            engine: .rpgMakerMZ)
        XCTAssertEqual(first, second)
        XCTAssertNotEqual(first.uuid, try GameWebStorageIdentity(
            context: context(revision: "r1", environmentID: "env-2"), engine: .rpgMakerMZ).uuid)
    }

    func testProjectOwnerEngineAndEnvironmentAreAllIsolated() throws {
        let base = try GameWebStorageIdentity(context: context(), engine: .rpgMakerMZ)
        XCTAssertNotEqual(base.uuid, try GameWebStorageIdentity(context: context(projectID: otherProjectID), engine: .rpgMakerMZ).uuid)
        XCTAssertNotEqual(base.uuid, try GameWebStorageIdentity(
            context: context(owner: .conversation(conversationID: UUID(), workspaceID: UUID())),
            engine: .rpgMakerMZ).uuid)
        XCTAssertNotEqual(base.uuid, try GameWebStorageIdentity(context: context(), engine: .rpgMakerMV).uuid)
        XCTAssertNotEqual(base.uuid, try GameWebStorageIdentity(context: context(environmentID: nil), engine: .rpgMakerMZ).uuid)
        XCTAssertNotEqual(base.uuid, try GameWebStorageIdentity(context: context(environmentID: "env-2"), engine: .rpgMakerMZ).uuid)
    }

    func testInvalidHostIdentityIsRejected() throws {
        XCTAssertThrowsError(try GameWebStorageIdentity(
            projectID: projectID,
            owner: .space(recordID: UUID()),
            engine: .phaser, environmentID: nil))
        XCTAssertThrowsError(try GameWebStorageIdentity(
            projectID: projectID, owner: .space(recordID: projectID),
            engine: .phaser, environmentID: "bad\nscope"))
        XCTAssertThrowsError(try GameWebStorageIdentity(
            projectID: projectID, owner: .space(recordID: projectID),
            engine: .phaser, environmentID: ""))
    }

    func testPreparedArtifactUsesItsTrustedSourceContext() throws {
        let value = try context(revision: "rev-42")
        let artifact = try GamePreparedArtifact(id: UUID(), engine: .rpgMakerMZ, source: value,
            route: .webKit, sha256: String(repeating: "0", count: 64),
            entry: GameRelativePath("index.html"))
        let identity = try artifact.storageIdentity()
        XCTAssertEqual(identity, try GameWebStorageIdentity(context: value, engine: .rpgMakerMZ))
        XCTAssertEqual(identity.uuid.uuidString.lowercased(), "c2000910-a5f1-876a-bdb8-09195cd3b1b5")
    }
}
