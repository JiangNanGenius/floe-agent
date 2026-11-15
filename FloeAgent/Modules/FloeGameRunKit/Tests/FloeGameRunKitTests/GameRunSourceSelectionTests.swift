// SPDX-License-Identifier: MPL-2.0
import Foundation
import XCTest
import FloeGameCore
@testable import FloeGameRunKit

final class GameRunSourceSelectionTests: XCTestCase {
    private func makeProject() throws -> (root: URL, context: GameProjectContext) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("floe-run-selection-" + UUID().uuidString.lowercased(),
                                    isDirectory: true)
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("games/a"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("games/b"), withIntermediateDirectories: true)
        try Data("<!doctype html><title>a</title>".utf8)
            .write(to: root.appendingPathComponent("games/a/index.html"))
        try Data("<!doctype html><title>b</title>".utf8)
            .write(to: root.appendingPathComponent("games/b/index.html"))
        let phaserPackage = Data(#"{"dependencies":{"phaser":"3.90.0"}}"#.utf8)
        for gameRoot in ["games/a", "games/b"] {
            try phaserPackage.write(to: root.appendingPathComponent(gameRoot + "/package.json"))
        }
        try Data("shared".utf8).write(to: root.appendingPathComponent("README.md"))
        let projectID = UUID()
        let context = try GameProjectContext(
            projectID: projectID, owner: .space(recordID: projectID),
            rootURL: root, savedRevision: "rev-1", environmentID: "linux-guest")
        return (root, context)
    }

    private func makeSelection(_ context: GameProjectContext, root: String,
                               engine: GameEngineID = .phaser) async throws
        -> GameRunSourceSelection {
        let inventory = try GameRunProjectInventory.scan(
            context: context, limits: .default)
        let gameRoot = try GameRelativePath(root)
        let source = try GameRunPathResolver.resolve(
            root: context.rootURL, relativeRoot: root, limits: .default)
        let index = try GameRunTreeScanner.scan(
            rootURL: source.url, relativeRoot: source.relative, limits: .default)
        let preparedRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("floe-prepared-" + UUID().uuidString.lowercased(),
                                    isDirectory: true)
        defer { try? FileManager.default.removeItem(at: preparedRoot) }
        try GameRunFileIO.copyTree(index: index, to: preparedRoot, limits: .default)
        let manifest = try GameRunSourceDigest.manifest(
            rootURL: preparedRoot, limits: .default)
        let prepared = try GameRunPreparedSource(
            digest: manifest.digest, transform: .byteIdenticalCopy,
            transformID: nil, relation: "equals-selected-source")
        return try GameRunSourceSelection(
            context: context, engine: engine, gameRoot: gameRoot,
            inventory: inventory, prepared: prepared)
    }

    func testSameEngineSiblingRootsHaveDistinctSubtreeDigests() async throws {
        let (root, context) = try makeProject()
        defer { try? FileManager.default.removeItem(at: root) }
        let first = try await makeSelection(context, root: "games/a")
        let second = try await makeSelection(context, root: "games/b")
        XCTAssertEqual(first.gameRoot?.value, "games/a")
        XCTAssertEqual(second.gameRoot?.value, "games/b")
        XCTAssertNotEqual(first.selectedSourceDigest, second.selectedSourceDigest)
        XCTAssertEqual(first.wholeProjectDigest, second.wholeProjectDigest)
        XCTAssertTrue(first.inventory.files.contains {
            $0.path.value == "games/b/index.html"
        })
    }

    func testWholeProjectDigestUsesTheReviewedCanonicalRows() async throws {
        let (root, context) = try makeProject()
        defer { try? FileManager.default.removeItem(at: root) }
        let inventory = try GameRunProjectInventory.scan(context: context)
        let rows = inventory.files.map {
            "\($0.path.value):\($0.sha256):\($0.bytes):\($0.executable ? "1" : "0")"
        }.sorted()
        XCTAssertEqual(inventory.wholeProjectDigest,
                       GameDigest.sha256(Data(rows.joined(separator: "\n").utf8)))
    }

    func testPreparedCopyMustMatchSelectedBytes() async throws {
        let (root, context) = try makeProject()
        defer { try? FileManager.default.removeItem(at: root) }
        let inventory = try GameRunProjectInventory.scan(context: context)
        let selectedDigest = try XCTUnwrap(
            try inventory.selectedSourceDigest(gameRoot: try GameRelativePath("games/a")))
        let wrong = try GameRunPreparedSource(
            digest: String(repeating: "a", count: 64),
            transform: .byteIdenticalCopy, transformID: nil,
            relation: "equals-selected-source")
        XCTAssertThrowsError(try GameRunSourceSelection(
            context: context, engine: .phaser,
            gameRoot: try GameRelativePath("games/a"),
            inventory: inventory, prepared: wrong))
        XCTAssertEqual(selectedDigest.utf8.count, 64)
    }

    func testGeneratedPreparedCopyRequiresDocumentedRelation() async throws {
        let (root, context) = try makeProject()
        defer { try? FileManager.default.removeItem(at: root) }
        let inventory = try GameRunProjectInventory.scan(context: context)
        let generated = try GameRunPreparedSource(
            digest: String(repeating: "b", count: 64),
            transform: .generated, transformID: "fixture-transform",
            relation: "generated-from:selected-source")
        let selection = try GameRunSourceSelection(
            context: context, engine: .phaser,
            gameRoot: try GameRelativePath("games/a"),
            inventory: inventory, prepared: generated)
        XCTAssertThrowsError(try selection.requireCIOriginalBytes())
    }

    func testSymlinkRootAndWrongEngineFailBeforeUse() async throws {
        let (root, context) = try makeProject()
        defer { try? FileManager.default.removeItem(at: root) }
        let inventory = try GameRunProjectInventory.scan(context: context)
        try FileManager.default.createSymbolicLink(
            at: root.appendingPathComponent("games/link"),
            withDestinationURL: root.appendingPathComponent("games/a"))
        let prepared = try GameRunPreparedSource(
            digest: inventory.wholeProjectDigest,
            transform: .byteIdenticalCopy, transformID: nil,
            relation: "equals-selected-source")
        XCTAssertThrowsError(try GameRunSourceSelection(
            context: context, engine: .phaser,
            gameRoot: try GameRelativePath("games/link"),
            inventory: inventory, prepared: prepared)) { error in
            guard let value = error as? GameRunSourceSelectionError,
                  case .symbolicLink = value else {
                return XCTFail("expected symbolic-link rejection, got \(error)")
            }
        }
        XCTAssertThrowsError(try GameRunSourceSelection(
            context: context, engine: .godot,
            gameRoot: try GameRelativePath("games/a"),
            inventory: inventory, prepared: try GameRunPreparedSource(
                digest: String(repeating: "c", count: 64),
                transform: .generated, transformID: "fixture",
                relation: "generated-from:selected-source")))
    }

    func testStaleContextAndReplacedRootAreRejected() async throws {
        let (root, context) = try makeProject()
        defer { try? FileManager.default.removeItem(at: root) }
        let selection = try await makeSelection(context, root: "games/a")
        let changed = try GameProjectContext(
            projectID: context.projectID, owner: context.owner,
            rootURL: context.rootURL, savedRevision: "rev-2",
            environmentID: context.environmentID)
        XCTAssertThrowsError(try selection.validate(liveContext: changed)) { error in
            guard let value = error as? GameRunSourceSelectionError,
                  case .staleContext(.revision) = value else {
                return XCTFail("expected revision fence, got \(error)")
            }
        }
        let selected = root.appendingPathComponent("games/a")
        try FileManager.default.removeItem(at: selected)
        try FileManager.default.createDirectory(at: selected,
                                                withIntermediateDirectories: true)
        try Data("replacement".utf8).write(to: selected.appendingPathComponent("index.html"))
        XCTAssertThrowsError(try selection.validate(liveContext: context))
    }

    func testExternalBuildRequestCarriesTheExactSelectionAndRejectsMismatch() async throws {
        let (root, context) = try makeProject()
        defer { try? FileManager.default.removeItem(at: root) }
        let selection = try await makeSelection(context, root: "games/a")
        let output = root.appendingPathComponent("artifacts/out")
        try FileManager.default.createDirectory(at: output.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        let request = try GameRunExternalBuildRequest(
            engine: .phaser, kind: .webBundle, context: context,
            sourceRoot: root.appendingPathComponent("games/a"),
            outputDirectory: output,
            expectedEntry: try GameRelativePath("index.html"),
            requirement: .externalTool(id: "fixture", detail: "fixture"),
            selection: selection)
        XCTAssertEqual(request.gameRoot?.value, "games/a")
        XCTAssertEqual(request.wholeProjectDigest, selection.wholeProjectDigest)
        XCTAssertEqual(request.selectedSourceDigest, selection.selectedSourceDigest)
        XCTAssertEqual(request.projectRootURL, context.rootURL)
        let otherID = UUID()
        let other = try GameProjectContext(
            projectID: otherID, owner: .space(recordID: otherID),
            rootURL: root, savedRevision: "rev-1")
        XCTAssertThrowsError(try GameRunExternalBuildRequest(
            engine: .phaser, kind: .webBundle, context: other,
            sourceRoot: root.appendingPathComponent("games/a"),
            outputDirectory: output,
            expectedEntry: try GameRelativePath("index.html"),
            requirement: .externalTool(id: "fixture", detail: "fixture"),
            selection: selection))
    }
}
