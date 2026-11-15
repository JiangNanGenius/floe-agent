// SPDX-License-Identifier: MPL-2.0
import XCTest
import Foundation
import CryptoKit
import FloeGameCore
import FloeGameTouch
@testable import FloeGameStarterKit

final class StarterMaterializationTests: XCTestCase {
    private let runtimePackEngines: Set<GameEngineID> = [.phaser, .kaplay, .babylon, .playcanvas]

    func testSeedsEveryEmbeddedEngineAndRejectsSecondInitialization() async throws {
        let catalog = try GameStarterCatalog.bundled()
        let engines = catalog.engines.map(\.engine).filter { !runtimePackEngines.contains($0) }
        XCTAssertEqual(engines.count, 16)
        for engine in engines {
            do {
                try await withWorkspace { workspace in
                    let result = try await workspace.seed(engine: engine, title: "QA " + engine.rawValue)
                    XCTAssertEqual(result.engine, engine)
                    XCTAssertEqual(result.project.engine, Optional(engine))
                    XCTAssertEqual(result.context.savedRevision, result.project.revision)
                    XCTAssertGreaterThan(result.files.count, 0)
                    XCTAssertEqual(result.manifestSHA256.count, 64)
                    let paths = workspace.paths(result)
                    XCTAssertTrue(paths.contains(result.descriptor.entry.value),
                                  "\(engine) entry \(result.descriptor.entry.value)")
                    XCTAssertTrue(paths.contains("floe-game.json"), engine.rawValue)
                    XCTAssertTrue(paths.contains("floe-inputs.json"), engine.rawValue)
                    XCTAssertTrue(paths.contains("licenses/FLOE-STARTER-MIT.txt")
                                  || paths.contains("LICENSE-FLOE-STARTER-MIT.txt"),
                                  engine.rawValue)
                    let inputs = try await workspace.read(result, "floe-inputs.json")
                    XCTAssertNoThrow(try GameTouchProjectBindings(json: inputs, engine: engine))
                    let metadata = try await workspace.read(result, "floe-game.json")
                    let object = try XCTUnwrap(
                        try JSONSerialization.jsonObject(with: metadata) as? [String: Any])
                    let metadataEngine = try XCTUnwrap(object["engine"] as? String)
                    let metadataTitle = try XCTUnwrap(object["title"] as? String)
                    XCTAssertEqual(metadataEngine, engine.rawValue)
                    XCTAssertEqual(metadataTitle, "QA " + engine.rawValue)
                    let history = try await workspace.repository.history(
                        result.project.projectID, owner: result.project.owner)
                    XCTAssertEqual(history.count, 2, engine.rawValue)
                    let next = try await workspace.context()
                    do {
                        _ = try await workspace.scaffolder.initializeStarter(
                            context: next, engine: engine, title: "Again")
                        XCTFail("\(engine) allowed a second initialization")
                    } catch let error as GameStarterError {
                        XCTAssertEqual(error, .nonEmptyProject, engine.rawValue)
                    }
                }
            } catch {
                XCTFail("\(engine.rawValue): \(error)")
            }
        }
    }

    func testRuntimePackEnginesFailClosedWithoutPreparedPacks() async throws {
        for engine in [GameEngineID.phaser, .kaplay, .babylon, .playcanvas] {
            try await withWorkspace { workspace in
                _ = try await workspace.create(title: "QA", engine: engine)
                let context = try await workspace.context()
                do {
                    _ = try await workspace.scaffolder.initializeStarter(
                        context: context, engine: engine, title: "QA")
                    XCTFail("\(engine) created without a runtime pack")
                } catch let error as GameStarterError {
                    guard case .missingRuntimePack(let failedEngine, let packID, let expected) = error else {
                        XCTFail("\(engine) wrong error \(error)"); return
                    }
                    XCTAssertEqual(failedEngine, engine)
                    XCTAssertFalse(packID.isEmpty)
                    XCTAssertFalse(expected.isEmpty)
                }
                let project = try await workspace.repository.open(
                    workspace.projectID, owner: workspace.owner)
                XCTAssertTrue(project.files.isEmpty)
                let history = try await workspace.repository.history(
                    workspace.projectID, owner: workspace.owner)
                XCTAssertEqual(history.count, 1)
            }
        }
    }

    func testRuntimePackEnginesCreateWithActuallyPreparedPacks() async throws {
        guard let root = runtimePackRootFromEnvironment() else {
            throw XCTSkip("FLOE_STARTER_TEST_RESOURCES or the local resource-packs symlink directory is unavailable")
        }
        let resources = GameStarterResources.from(root: root)
        XCTAssertNotNil(resources.phaser, "prepared Phaser pack")
        for engine in [GameEngineID.kaplay, .babylon, .playcanvas] {
            XCTAssertNotNil(resources.pack(for: engine), engine.rawValue)
        }
        for engine in [GameEngineID.phaser, .kaplay, .babylon, .playcanvas] {
            try await withWorkspace(resources: resources) { workspace in
                let result = try await workspace.seed(engine: engine, title: "Pack " + engine.rawValue)
                let paths = Set(workspace.paths(result))
                XCTAssertTrue(paths.contains("index.html"), engine.rawValue)
                XCTAssertTrue(paths.contains("floe-game.json"), engine.rawValue)
                XCTAssertTrue(paths.contains("floe-inputs.json"), engine.rawValue)
                let runtimeFile: String = engine == .phaser ? "vendor/phaser.js" : "runtime/engine.js"
                // Phaser's upstream pack stores phaser.js; the materializer
                // places that exact verified file under vendor/ in the game.
                let packSourceFile = engine == .phaser ? "phaser.js" : runtimeFile
                let descriptor = try workspace.catalog.descriptor(for: engine)
                let expected = try XCTUnwrap(descriptor.runtimePack?.files.first {
                    $0.path.value == packSourceFile
                })
                let data = try await workspace.read(result, runtimeFile)
                XCTAssertEqual(data.count, expected.bytes)
                XCTAssertEqual(sha256(data), expected.sha256)
                if engine != .phaser {
                    XCTAssertTrue(paths.contains("game.js"))
                    XCTAssertTrue(paths.contains("common.js"))
                }
            }
        }
    }

    func testBlankProjectCreatedBeforeEngineChoiceStillSeedsAndRecordsMetadata() async throws {
        try await withWorkspace { workspace in
            _ = try await workspace.scaffolder.createBlankProject(
                projectID: workspace.projectID, owner: workspace.owner,
                title: "Choose later")
            let context = try await workspace.context()
            let result = try await workspace.scaffolder.initializeStarter(
                context: context, engine: .godot, title: "Choose later")
            XCTAssertNil(result.repositoryEngine)
            XCTAssertEqual(result.engine, .godot)
            let metadata = try JSONSerialization.jsonObject(
                with: try await workspace.read(result, "floe-game.json")) as? [String: Any]
            let metadataEngine = try XCTUnwrap(metadata?["engine"] as? String)
            XCTAssertEqual(metadataEngine, "godot")
        }
    }

    func testNonEmptyProjectWrongOwnerStaleRevisionAndContextChangeAreRejected() async throws {
        try await withWorkspace { workspace in
            _ = try await workspace.create(title: "Guard", engine: .rpgMakerXP)
            let empty = try await workspace.context()
            let kept = try await workspace.repository.commit(
                workspace.projectID, owner: workspace.owner,
                expectedRevision: empty.savedRevision,
                changes: [.write(try GameRelativePath("keep.txt"), Data("keep".utf8))])
            let guarded = try await workspace.context()
            do {
                _ = try await workspace.scaffolder.initializeStarter(
                    context: guarded, engine: .rpgMakerXP)
                XCTFail("non-empty project was seeded")
            } catch let error as GameStarterError {
                XCTAssertEqual(error, .nonEmptyProject)
            }
            let still = try await workspace.repository.open(workspace.projectID, owner: workspace.owner)
            XCTAssertEqual(still.revision, kept.revision)
            let keptBytes = try await workspace.readFile(still, "keep.txt")
            XCTAssertEqual(keptBytes, Data("keep".utf8))

            let wrongOwner = try GameProjectContext(
                projectID: workspace.projectID,
                owner: .conversation(conversationID: UUID(), workspaceID: UUID()),
                rootURL: guarded.rootURL, savedRevision: guarded.savedRevision,
                environmentID: guarded.environmentID)
            do {
                _ = try await workspace.scaffolder.initializeStarter(
                    context: wrongOwner, engine: .rpgMakerXP)
                XCTFail("wrong owner accepted")
            } catch let error as GameStarterError {
                XCTAssertEqual(error, .contextChanged)
            }

            let stale = try GameProjectContext(
                projectID: workspace.projectID, owner: workspace.owner,
                rootURL: guarded.rootURL, savedRevision: "stale-revision",
                environmentID: guarded.environmentID)
            do {
                _ = try await workspace.scaffolder.initializeStarter(
                    context: stale, engine: .rpgMakerXP)
                XCTFail("stale revision accepted")
            } catch let error as GameStarterError {
                XCTAssertEqual(error, .contextChanged)
            }

            let changedEnvironment = try GameProjectContext(
                projectID: workspace.projectID, owner: workspace.owner,
                rootURL: guarded.rootURL, savedRevision: guarded.savedRevision,
                environmentID: "another-environment")
            do {
                _ = try await workspace.scaffolder.initializeStarter(
                    context: changedEnvironment, engine: .rpgMakerXP)
                XCTFail("changed environment accepted")
            } catch let error as GameStarterError {
                XCTAssertEqual(error, .contextChanged)
            }
        }
    }

    func testCancelledOrFailedBeforeImportPreservesEmptyProject() async throws {
        try await withWorkspace(beforeImport: { throw GameStarterError.cancelled }) { workspace in
            _ = try await workspace.create(title: "Cancel", engine: .godot)
            let context = try await workspace.context()
            do {
                _ = try await workspace.scaffolder.initializeStarter(
                    context: context, engine: .godot)
                XCTFail("cancelled initialization committed")
            } catch let error as GameStarterError {
                XCTAssertEqual(error, .cancelled)
            }
            let project = try await workspace.repository.open(
                workspace.projectID, owner: workspace.owner)
            XCTAssertTrue(project.files.isEmpty)
            XCTAssertTrue(project.directories.isEmpty)
            let history = try await workspace.repository.history(
                workspace.projectID, owner: workspace.owner)
            XCTAssertEqual(history.count, 1)
        }
    }

    func testImportRemainsSeparateAndIsNeverAutoSeeded() async throws {
        try await withWorkspace { workspace in
            _ = try await workspace.scaffolder.createBlankProject(
                projectID: workspace.projectID, owner: workspace.owner, title: "Import")
            let context = try await workspace.context()
            let external = workspace.root.appendingPathComponent("external", isDirectory: true)
            try FileManager.default.createDirectory(at: external, withIntermediateDirectories: true)
            try Data("external".utf8).write(to: external.appendingPathComponent("game.txt"))
            let imported = try await workspace.repository.importContents(
                from: external, into: workspace.projectID, owner: workspace.owner,
                expectedRevision: context.savedRevision)
            let paths = Set(imported.files.map(\.path.value))
            XCTAssertEqual(paths, ["game.txt"])
            XCTAssertFalse(paths.contains("floe-game.json"))
            XCTAssertFalse(paths.contains("floe-inputs.json"))
        }
    }

    func testGeneratedManifestsAreDeterministicForTwineAndGDevelop() async throws {
        for engine in [GameEngineID.twine, .gdevelop] {
            let first = try await deterministicSnapshot(engine: engine)
            let second = try await deterministicSnapshot(engine: engine)
            XCTAssertEqual(first, second, engine.rawValue)
        }
    }

    func testTreePolicyRejectsCaseCollisionsReservedNamesAndLimits() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("FloeTreePolicy-" + UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        // APFS may represent A.txt/a.txt as the same file. Exercise the exact
        // production path registrar without asking the host to store both.
        var paths = Set<String>()
        try GameStarterTreePolicy.registerFilePath(try GameRelativePath("A.txt"), folded: &paths)
        XCTAssertThrowsError(try GameStarterTreePolicy.registerFilePath(
            try GameRelativePath("a.txt"), folded: &paths)) { error in
            guard let starter = error as? GameStarterError,
                  case .unsafePath = starter else {
                return XCTFail("expected case collision, got \(error)")
            }
        }
        try Data("reserved".utf8).write(to: root.appendingPathComponent("CON"))
        XCTAssertThrowsError(try GameStarterTreePolicy.validate(
            root: root, limits: try GameStarterLimits())) { error in
            guard let starter = error as? GameStarterError,
                  case .unsafePath = starter else {
                return XCTFail("expected reserved path, got \(error)")
            }
        }
        try FileManager.default.removeItem(at: root.appendingPathComponent("CON"))
        try Data("one".utf8).write(to: root.appendingPathComponent("one.txt"))
        let small = try GameStarterLimits(maximumFiles: 1, maximumFileBytes: 16,
                                          maximumTotalBytes: 32, maximumPathBytes: 64,
                                          maximumEntries: 4)
        XCTAssertNoThrow(try GameStarterTreePolicy.validate(root: root, limits: small))
        try Data("two".utf8).write(to: root.appendingPathComponent("two.txt"))
        XCTAssertThrowsError(try GameStarterTreePolicy.validate(root: root, limits: small)) { error in
            guard let starter = error as? GameStarterError,
                  case .limitExceeded = starter else {
                return XCTFail("expected file limit, got \(error)")
            }
        }
    }

    private func deterministicSnapshot(engine: GameEngineID) async throws -> [String] {
        var snapshot: [String] = []
        try await withWorkspace { workspace in
            let result = try await workspace.seed(engine: engine, title: "Deterministic " + engine.rawValue)
            snapshot = result.files.map { "\($0.path.value):\($0.sha256):\($0.bytes)" }
                + ["manifest:\(result.manifestSHA256)"]
        }
        return snapshot
    }

    private func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

private extension StarterTestWorkspace {
    func readFile(_ project: GameStoredProject, _ path: String) async throws -> Data {
        try await repository.read(project.projectID, owner: project.owner,
                                  revision: project.revision,
                                  path: GameRelativePath(path))
    }
}
