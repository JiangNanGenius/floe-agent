// SPDX-License-Identifier: MPL-2.0
import Foundation
import XCTest
import FloeGameCore
import FloeGameStarterKit
@testable import FloeGameProjectFlow

final class SelectionStoreTests: XCTestCase {
    func testFileStoreRoundTripsAndSeparatesKeys() async throws {
        try await withSelectionWorkspace { workspace in
            let result = try await workspace.importFiles([
                "Web/package.json": Data(
                    "{\"dependencies\":{\"phaser\":\"3.90.0\"}}".utf8),
                "Legacy/Game.rvproj2": Data("VXAce".utf8)
            ])
            let web = try GameRelativePath("Web")
            let selected = try await workspace.coordinator.select(
                root: web, engine: .phaser, context: result.context)
            let directory = workspace.root.appendingPathComponent(
                "SelectionStore", isDirectory: true)
            let store = try FileGameProjectSelectionStore(directory: directory)
            let key = try GameProjectSelectionKey(context: result.context)
            let record = try GameProjectSelectionRecord(
                context: result.context, snapshot: selected)
            try await store.save(record, for: key)
            let loaded = try await store.load(for: key)
            XCTAssertEqual(loaded, record)

            let otherEnvironment = try GameProjectContext(
                projectID: result.context.projectID,
                owner: result.context.owner,
                rootURL: result.context.rootURL,
                savedRevision: result.context.savedRevision,
                environmentID: "other-environment")
            let otherKey = try GameProjectSelectionKey(context: otherEnvironment)
            XCTAssertNotEqual(key, otherKey)
            let other = try await store.load(for: otherKey)
            XCTAssertNil(other)

            let second = try GameProjectSelectionCoordinator(
                scaffolder: workspace.scaffolder, contexts: workspace.host,
                store: store)
            let restored = try await second.refresh(
                project: result.project, context: result.context)
            XCTAssertEqual(restored.selectionSource, .restored)
            XCTAssertEqual(restored.selectedEngine, .phaser)
            XCTAssertEqual(restored.selectedRoot?.value, web.value)
            XCTAssertTrue(restored.persisted)

            try await store.remove(for: key)
            let removed = try await store.load(for: key)
            XCTAssertNil(removed)
        }
    }

    func testFileStoreRejectsProjectRootOverlap() async throws {
        try await withSelectionWorkspace { workspace in
            let result = try await workspace.importFiles([
                "Game.rxproj": Data("XP".utf8)
            ])
            let selected = try await workspace.coordinator.refresh(
                project: result.project, context: result.context)
            let key = try GameProjectSelectionKey(context: result.context)
            let record = try GameProjectSelectionRecord(
                context: result.context, snapshot: selected)
            let store = try FileGameProjectSelectionStore(
                directory: result.context.rootURL.appendingPathComponent(
                    ".selection-store", isDirectory: true))
            do {
                try await store.save(record, for: key)
                XCTFail("store inside the project root was accepted")
            } catch let error as GameProjectSelectionStoreError {
                XCTAssertEqual(error, .overlapWithProjectRoot)
            }
        }
    }

    func testFileStoreRejectsCorruptOrMismatchedRecords() async throws {
        try await withSelectionWorkspace { workspace in
            let result = try await workspace.importFiles([
                "Game.rxproj": Data("XP".utf8)
            ])
            let selected = try await workspace.coordinator.refresh(
                project: result.project, context: result.context)
            let directory = workspace.root.appendingPathComponent(
                "SelectionStore", isDirectory: true)
            let store = try FileGameProjectSelectionStore(directory: directory)
            let key = try GameProjectSelectionKey(context: result.context)
            let record = try GameProjectSelectionRecord(
                context: result.context, snapshot: selected)
            try await store.save(record, for: key)
            let name = GameDigest.sha256(Data(key.canonical.utf8)) + ".json"
            let file = directory.appendingPathComponent(name)
            try Data("{}".utf8).write(to: file, options: [.atomic])
            do {
                _ = try await store.load(for: key)
                XCTFail("corrupt record was accepted")
            } catch let error as GameProjectSelectionStoreError {
                XCTAssertEqual(error, .corruptRecord)
            }
        }
    }

    func testKeyIsStableAcrossRevisionsAndSeparatesIdentity() async throws {
        try await withSelectionWorkspace { workspace in
            let result = try await workspace.importFiles([
                "Game.rxproj": Data("XP".utf8)
            ])
            let first = try GameProjectSelectionKey(context: result.context)
            let nextRevision = try GameProjectContext(
                projectID: result.context.projectID,
                owner: result.context.owner,
                rootURL: result.context.rootURL,
                savedRevision: UUID().uuidString.lowercased(),
                environmentID: result.context.environmentID)
            let second = try GameProjectSelectionKey(context: nextRevision)
            XCTAssertEqual(first, second,
                           "one persisted choice survives reevaluation at a new revision")

            let otherEnvironment = try GameProjectContext(
                projectID: result.context.projectID,
                owner: result.context.owner,
                rootURL: result.context.rootURL,
                savedRevision: result.context.savedRevision,
                environmentID: "different")
            let environmentKey = try GameProjectSelectionKey(
                context: otherEnvironment)
            XCTAssertNotEqual(first, environmentKey)

            let otherOwner = try GameProjectContext(
                projectID: result.context.projectID,
                owner: .conversation(conversationID: UUID(),
                                     workspaceID: UUID()),
                rootURL: result.context.rootURL,
                savedRevision: result.context.savedRevision,
                environmentID: result.context.environmentID)
            let ownerKey = try GameProjectSelectionKey(context: otherOwner)
            XCTAssertNotEqual(first, ownerKey)

            let otherRoot = try GameProjectContext(
                projectID: result.context.projectID,
                owner: result.context.owner,
                rootURL: workspace.root.appendingPathComponent("OtherRoot",
                                                               isDirectory: true),
                savedRevision: result.context.savedRevision,
                environmentID: result.context.environmentID)
            let rootKey = try GameProjectSelectionKey(context: otherRoot)
            XCTAssertNotEqual(first, rootKey)
        }
    }
}
