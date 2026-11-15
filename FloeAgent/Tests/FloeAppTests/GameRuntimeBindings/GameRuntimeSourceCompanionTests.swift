// SPDX-License-Identifier: MPL-2.0
#if canImport(UIKit)
import XCTest
import Foundation
import FloeGameCore
import FloeGameBuildKit
import FloeGamePortableKit
@testable import FloeApp

/// Source-only regression portfolio for the App-owned exact-source selection,
/// its security-scope lifetime and the paired-source provider. These tests are
/// authored but NOT executed in this source-only task.
@MainActor
final class GameRuntimeSourceCompanionTests: XCTestCase {
    private struct Fixture {
        let root: URL
        let bundle: URL
        let data: Data
        let pack: GamePortableSourcePackAccompaniment
        let resolution: GamePortableSourceOfferResolution
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("floe-app-source-companion-\(UUID().uuidString)",
                                    isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    private func fixture(bundleBytes: Int = 256) throws -> Fixture {
        let root = try temporaryDirectory()
        let data = Data(repeating: 0x41, count: bundleBytes)
        let bundle = root.appendingPathComponent("love-runtime-and-source.zip")
        try data.write(to: bundle)
        let catalog = try GamePortableSourceAccompanimentCatalog(from: try JSONSerialization.data(
            withJSONObject: [
                "schemaVersion": 1,
                "kind": "floe-game-runtime-source-accompaniment",
                "productionPublication": [
                    "state": "unpublished", "distributionReady": false,
                    "writtenOfferCreated": false, "detail": "not published",
                ],
                "packs": [
                    "lovejs-11.4.1": [
                        "packID": "lovejs-11.4.1",
                        "engines": ["love"],
                        "profileID": "portable-love",
                        "pairedSourceID": "love-runtime-and-source-2",
                        "licenses": [],
                        "helperSources": [],
                        "relink": [],
                        "sourcePackages": [],
                        "sourceBundle": [
                            "id": "love-runtime-and-source.zip",
                            "sha256": GameDigest.sha256(data),
                            "bytes": data.count,
                        ],
                        "publication": [
                            "state": "unpublished",
                            "distributionReady": false,
                            "writtenOfferCreated": false,
                            "publicURL": NSNull(),
                            "detail": "exact local bytes",
                        ],
                    ],
                ],
            ], options: [.sortedKeys]))
        let pack = try XCTUnwrap(catalog.accompaniment(for: .love))
        let resolution = try GamePortableSourceOfferResolver.resolve(pack: pack, root: bundle)
        return .init(root: root, bundle: bundle, data: data, pack: pack, resolution: resolution)
    }

    private func identity(projectID: UUID = UUID(),
                          owner: GameProjectOwner = .space(recordID: UUID()),
                          engine: GameEngineID = .love,
                          rootPath: String = "/owner/game/files",
                          environmentID: String? = "linux-guest")
        -> GameSourceCompanionIdentity {
        .init(projectID: projectID, owner: owner, rootPath: rootPath,
              engine: engine, environmentID: environmentID)
    }

    private func selection(_ fixture: Fixture,
                           identity: GameSourceCompanionIdentity? = nil,
                           didAccess: Bool = false) throws -> GameSourceCompanionSelection {
        try .init(identity: identity ?? self.identity(), pack: fixture.pack,
                  resolution: fixture.resolution, rootURL: fixture.bundle,
                  didAccess: didAccess)
    }

    func testSelectionReleasesScopeOnlyAfterLastUse() throws {
        let fixture = try fixture()
        let value = try selection(fixture)
        try value.beginUse()
        value.retire()
        XCTAssertFalse(value.scopeIsReleased)
        XCTAssertTrue(value.isReadable)
        value.endUse()
        XCTAssertTrue(value.scopeIsReleased)
        XCTAssertFalse(value.isReadable)
        XCTAssertThrowsError(try value.beginUse()) { error in
            XCTAssertEqual(error as? GameSourceCompanionError, .selectionRemoved)
        }
    }

    func testStoreIsPerOwnerAndEngineNotGlobal() throws {
        let fixture = try fixture()
        let store = GameSourceCompanionStore()
        let ownerA = GameProjectOwner.space(recordID: UUID())
        let keyA = identity(owner: ownerA)
        let installed = store.install(try selection(fixture, identity: keyA))
        XCTAssertEqual(installed.bundleID, fixture.resolution.bundleID)
        XCTAssertNotNil(store.snapshot(for: keyA))
        XCTAssertNil(store.snapshot(for: identity(projectID: keyA.projectID,
            owner: .space(recordID: UUID()))))
        XCTAssertNil(store.snapshot(for: identity(projectID: keyA.projectID,
            owner: ownerA, engine: .renpy)))
        XCTAssertNil(store.snapshot(for: identity(projectID: keyA.projectID,
            owner: ownerA, rootPath: "/other")))
        XCTAssertNil(store.snapshot(for: identity(projectID: keyA.projectID,
            owner: ownerA, environmentID: "other")))
    }

    func testReplacementRetiresOldSelectionButKeepsInFlightUseReadable() throws {
        let fixture = try fixture()
        let store = GameSourceCompanionStore()
        let key = identity()
        let first = try selection(fixture, identity: key)
        store.install(first)
        try first.beginUse()
        let second = try selection(fixture, identity: key)
        store.install(second)
        XCTAssertTrue(first.scopeIsReleased == false)
        XCTAssertTrue(first.isReadable)
        XCTAssertFalse(second.scopeIsReleased)
        XCTAssertTrue(store.selection(for: key) === second)
        first.endUse()
        XCTAssertTrue(first.scopeIsReleased)
        XCTAssertTrue(second.isReadable)
        store.remove(key)
        XCTAssertTrue(second.scopeIsReleased)
        XCTAssertNil(store.snapshot(for: key))
    }

    func testRetireStaleFencesEnvironmentRootAndEngineChanges() throws {
        let fixture = try fixture()
        let store = GameSourceCompanionStore()
        let owner = GameProjectOwner.conversation(conversationID: UUID(), workspaceID: UUID())
        let current = identity(owner: owner, rootPath: "/game/files", environmentID: "linux-guest")
        store.install(try selection(fixture, identity: current))
        store.retireStale(projectID: current.projectID, owner: owner,
                          rootPath: "/game/files", keepingEngine: .love,
                          environmentID: "linux-guest")
        XCTAssertNotNil(store.snapshot(for: current))
        store.retireStale(projectID: current.projectID, owner: owner,
                          rootPath: "/game/files", keepingEngine: .love,
                          environmentID: "another-environment")
        XCTAssertNil(store.snapshot(for: current))
        XCTAssertEqual(store.count, 0)
    }

    func testProviderRehashesActualBytesAndRejectsReplacement() async throws {
        let fixture = try fixture()
        let value = try selection(fixture)
        let provider = try GameSourceCompanionPairedProvider(selection: value)
        let resolved = try await provider.resolve("love-runtime-and-source-2")
        XCTAssertEqual(resolved?.sha256, GameDigest.sha256(fixture.data))
        XCTAssertEqual(resolved?.bytes, fixture.data.count)
        let unknown = try await provider.resolve("another-source")
        XCTAssertNil(unknown)

        try Data(repeating: 0x42, count: fixture.data.count).write(to: fixture.bundle)
        do {
            _ = try await provider.resolve("love-runtime-and-source-2")
            XCTFail("a replaced bundle must fail closed")
        } catch {
            XCTAssertEqual(error as? GamePortableSourceOfferError,
                           .digestMismatch("love-runtime-and-source.zip"))
        }
        value.retire()
    }

    func testSelectionRejectsMissingPairedSourceAndMismatchedResolution() throws {
        let fixture = try fixture()
        let catalogData = try JSONSerialization.data(withJSONObject: [
            "schemaVersion": 1,
            "kind": "floe-game-runtime-source-accompaniment",
            "productionPublication": [
                "state": "unpublished", "distributionReady": false,
                "writtenOfferCreated": false, "detail": "not published",
            ],
            "packs": [
                "lovejs-11.4.1": [
                    "packID": "lovejs-11.4.1",
                    "engines": ["love"],
                    "licenses": [], "helperSources": [], "relink": [], "sourcePackages": [],
                    "sourceBundle": [
                        "id": "love-runtime-and-source.zip",
                        "sha256": GameDigest.sha256(fixture.data),
                        "bytes": fixture.data.count,
                    ],
                    "publication": [
                        "state": "unpublished", "distributionReady": false,
                        "writtenOfferCreated": false, "publicURL": NSNull(),
                        "detail": "exact local bytes",
                    ],
                ],
            ],
        ], options: [.sortedKeys])
        let catalog = try GamePortableSourceAccompanimentCatalog(from: catalogData)
        let pack = try XCTUnwrap(catalog.accompaniment(for: .love))
        XCTAssertThrowsError(try GameSourceCompanionSelection(
            identity: identity(), pack: pack, resolution: fixture.resolution,
            rootURL: fixture.bundle, didAccess: false)) { error in
            XCTAssertEqual(error as? GameSourceCompanionError, .unsupportedEngine)
        }

        let wrong = GamePortableSourceOfferResolution(
            packID: fixture.pack.packID, bundleID: fixture.resolution.bundleID,
            bundleURL: fixture.resolution.bundleURL,
            sha256: String(repeating: "0", count: 64),
            bytes: fixture.resolution.bytes,
            layout: fixture.resolution.layout,
            relativePath: fixture.resolution.relativePath)
        XCTAssertThrowsError(try GameSourceCompanionSelection(
            identity: identity(), pack: fixture.pack, resolution: wrong,
            rootURL: fixture.bundle, didAccess: false)) { error in
            XCTAssertEqual(error as? GameSourceCompanionError, .unsupportedEngine)
        }
    }
}
#endif
