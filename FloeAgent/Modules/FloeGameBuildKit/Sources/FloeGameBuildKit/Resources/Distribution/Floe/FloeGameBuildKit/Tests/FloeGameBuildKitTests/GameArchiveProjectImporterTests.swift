// SPDX-License-Identifier: MPL-2.0
import Foundation
import XCTest
import FloeGameCore
@testable import FloeGameBuildKit

final class GameArchiveProjectImporterTests: XCTestCase {
    private func makeRepository(_ fixture: GameArchiveFixture) throws -> FileGameProjectRepository {
        try FileGameProjectRepository(directory: fixture.root.appendingPathComponent("repo"))
    }

    private func workspace(_ fixture: GameArchiveFixture) -> URL {
        fixture.root.appendingPathComponent("workspace")
    }

    func testCreateEmptyThenImportUnknownEngineArchivePreservesEveryByte() async throws {
        let fixture = try GameArchiveFixture()
        defer { fixture.cleanup() }
        // Unknown-engine archive: random files, no markers anywhere.
        let zip = fixture.root.appendingPathComponent("unknown.zip")
        try GameTestZIPCraft.makeZIP([
            .entry("stuff/readme.txt", data: Data("hello 世界".utf8)),
            .entry("stuff/raw/blob.bin", data: Data([9, 0, 255, 3])),
            .entry("top-level.dat", data: Data("top".utf8)),
        ]).write(to: zip)

        let repository = try makeRepository(fixture)
        let store = try GameArchiveOriginalStore(directory: fixture.root.appendingPathComponent("originals"))
        let importer = GameArchiveProjectImporter(exchange: .init(), originalStore: store)
        let id = UUID(), owner = GameProjectOwner.space(recordID: id)
        let result = try await importer.createProjectAndImport(archive: zip, repository: repository,
                                                               projectID: id, owner: owner, title: "Unknown",
                                                               workspace: workspace(fixture))
        XCTAssertEqual(result.created?.files.count, 0)
        XCTAssertEqual(result.project.files.count, 3)
        XCTAssertEqual(result.preview.contentClass, .unknown)
        XCTAssertTrue(result.preview.recognizedEngines.isEmpty)
        XCTAssertTrue(result.preservedOriginal)
        XCTAssertEqual(result.originalArchiveSHA256, GameDigest.sha256(try Data(contentsOf: zip)))

        // Reopen and export: byte preservation through the whole sequence.
        let reopened = try await repository.open(id, owner: owner)
        XCTAssertEqual(Set(reopened.files.map(\.path)), Set(result.project.files.map(\.path)))
        let bytes = try await repository.read(id, owner: owner, revision: reopened.revision,
                                              path: GameRelativePath("stuff/raw/blob.bin"))
        XCTAssertEqual(bytes, Data([9, 0, 255, 3]))
        let out = fixture.root.appendingPathComponent("export")
        _ = try await repository.export(id, owner: owner, expectedRevision: reopened.revision, to: out)
        XCTAssertEqual(try Data(contentsOf: out.appendingPathComponent("stuff/readme.txt")),
                       Data("hello 世界".utf8))
        XCTAssertEqual(try Data(contentsOf: out.appendingPathComponent("top-level.dat")), Data("top".utf8))
        // History keeps the empty creation revision.
        let history = try await repository.history(id, owner: owner)
        XCTAssertEqual(history.map(\.revision), [result.project.revision, result.created!.revision])
    }

    func testNestedMultipleRootsImportWholeWithoutAnySelection() async throws {
        let fixture = try GameArchiveFixture()
        defer { fixture.cleanup() }
        // Multiple nested project roots + files outside every container.
        let zip = fixture.root.appendingPathComponent("nested.zip")
        try GameTestZIPCraft.makeZIP([
            .entry("MyGame/project.godot", data: Data("[application]".utf8)),
            .entry("MyGame/scenes/main.tscn", data: Data("[node]".utf8)),
            .entry("OtherGame/package.json", data: Data(#"{"dependencies":{"phaser":"3.90.0"}}"#.utf8)),
            .entry("OtherGame/src/main.js", data: Data("new Phaser.Game()".utf8)),
            .entry("loose-notes.txt", data: Data("outside all containers".utf8)),
        ]).write(to: zip)

        let repository = try makeRepository(fixture)
        let store = try GameArchiveOriginalStore(directory: fixture.root.appendingPathComponent("originals"))
        let importer = GameArchiveProjectImporter(originalStore: store)
        let id = UUID(), owner = GameProjectOwner.space(recordID: id)
        let result = try await importer.createProjectAndImport(archive: zip, repository: repository,
                                                               projectID: id, owner: owner, title: "Nested",
                                                               workspace: workspace(fixture))
        // Everything landed at the project root — nothing pruned, no selection needed.
        XCTAssertEqual(result.project.files.count, 5)
        XCTAssertEqual(Set(result.project.files.map(\.path.value)),
                       ["MyGame/project.godot", "MyGame/scenes/main.tscn", "OtherGame/package.json",
                        "OtherGame/src/main.js", "loose-notes.txt"])
        // Diagnostics recognized both engines and name the roots, after import.
        XCTAssertEqual(result.preview.recognizedEngines, [.godot, .phaser])
        XCTAssertEqual(Set(result.preview.rootCandidates.map(\.name)), ["MyGame", "OtherGame", "loose-notes.txt"])
        XCTAssertEqual(result.preview.contentClass, .editorSource)
        XCTAssertEqual(result.preview.dependencyHints, ["phaser 3.90.0"])
        // Bytes outside containers survive export.
        let reopened = try await repository.open(id, owner: owner)
        let out = fixture.root.appendingPathComponent("export-nested")
        _ = try await repository.export(id, owner: owner, expectedRevision: reopened.revision, to: out)
        XCTAssertEqual(try Data(contentsOf: out.appendingPathComponent("loose-notes.txt")),
                       Data("outside all containers".utf8))
    }

    func testDownloadedPublishedRPGMakerGameImportsWithHonestLimitations() async throws {
        let fixture = try GameArchiveFixture()
        defer { fixture.cleanup() }
        // A downloaded RPG Maker XP published game: runtime exe/ini, RGSS data,
        // RTP requirement, encrypted archive — none of it executed or decoded.
        let zip = fixture.root.appendingPathComponent("published-rmxp.zip")
        try GameTestZIPCraft.makeZIP([
            .entry("RPG_RT.exe", data: Data([0x4D, 0x5A, 0x90, 0, 3])),
            .entry("RPG_RT.ini", data: Data("[Game]\nLibrary=System\\RGSS100E.dll\nRTP1=Standard\n".utf8)),
            .entry("Game.rxdata", data: Data([1, 2, 3, 4])),
            .entry("Data/Map001.rxdata", data: Data([5, 6, 7, 8])),
            .entry("RGSS100E.dll", data: Data([0x4D, 0x5A])),
            .entry("Game.rgssad", data: Data([0x52, 0x47, 0x53, 0x53])),
        ]).write(to: zip)

        let repository = try makeRepository(fixture)
        let store = try GameArchiveOriginalStore(directory: fixture.root.appendingPathComponent("originals"))
        let importer = GameArchiveProjectImporter(originalStore: store)
        let id = UUID(), owner = GameProjectOwner.space(recordID: id)
        let result = try await importer.createProjectAndImport(archive: zip, repository: repository,
                                                               projectID: id, owner: owner, title: "Downloaded",
                                                               workspace: workspace(fixture))
        XCTAssertEqual(result.project.files.count, 6)
        XCTAssertEqual(result.preview.contentClass, .publishedGame)
        XCTAssertEqual(result.preview.recognizedEngines, [.rpgMakerXP])
        let kinds = Set(result.preview.limitations.map(\.kind))
        XCTAssertTrue(kinds.contains(.windowsExecutable))
        XCTAssertTrue(kinds.contains(.dynamicLibrary))
        XCTAssertTrue(kinds.contains(.encryptedAssets))
        XCTAssertTrue(kinds.contains(.rtpRequired))
        XCTAssertTrue(kinds.contains(.unsupportedPlayRoute))
        XCTAssertEqual(result.preview.executableCount, 1)
        // The EXE bytes are preserved, never executed; reopen reads them back intact.
        let reopened = try await repository.open(id, owner: owner)
        let exe = try await repository.read(id, owner: owner, revision: reopened.revision,
                                            path: GameRelativePath("RPG_RT.exe"))
        XCTAssertEqual(exe, Data([0x4D, 0x5A, 0x90, 0, 3]))
        // Original archive bytes preserved.
        let preservedBytes = try await store.read(sha256: result.originalArchiveSHA256)
        XCTAssertEqual(preservedBytes, try Data(contentsOf: zip))
    }

    func testImportIntoNonEmptyProjectRejectedUnlessExplicitReplace() async throws {
        let fixture = try GameArchiveFixture()
        defer { fixture.cleanup() }
        let zipA = fixture.root.appendingPathComponent("a.zip")
        try GameTestZIPCraft.makeZIP([.entry("a.txt", data: Data("A".utf8))]).write(to: zipA)
        let zipB = fixture.root.appendingPathComponent("b.zip")
        try GameTestZIPCraft.makeZIP([.entry("b.txt", data: Data("B".utf8))]).write(to: zipB)

        let repository = try makeRepository(fixture)
        let store = try GameArchiveOriginalStore(directory: fixture.root.appendingPathComponent("originals"))
        let importer = GameArchiveProjectImporter(originalStore: store)
        let id = UUID(), owner = GameProjectOwner.space(recordID: id)
        let first = try await importer.createProjectAndImport(archive: zipA, repository: repository,
                                                              projectID: id, owner: owner, title: "Replace",
                                                              workspace: workspace(fixture))
        // Default: importing into a non-empty project fails closed.
        do {
            _ = try await importer.importIntoProject(archive: zipB, repository: repository,
                                                     projectID: id, owner: owner,
                                                     expectedRevision: first.project.revision,
                                                     workspace: workspace(fixture))
            XCTFail("expected importDestinationNotEmpty")
        } catch GameProjectError.importDestinationNotEmpty {
        }
        // Wrong expected revision also fails before touching content.
        do {
            _ = try await importer.importIntoProject(archive: zipB, repository: repository,
                                                     projectID: id, owner: owner,
                                                     expectedRevision: "stale",
                                                     replaceExisting: true,
                                                     workspace: workspace(fixture))
            XCTFail("expected conflict")
        } catch let error as GameProjectError {
            guard case .conflict = error else {
                XCTFail("expected conflict, got \(error)")
                return
            }
        }
        // Explicit replacement imports and keeps the old content in history.
        let replaced = try await importer.importIntoProject(archive: zipB, repository: repository,
                                                            projectID: id, owner: owner,
                                                            expectedRevision: first.project.revision,
                                                            replaceExisting: true,
                                                            workspace: workspace(fixture))
        XCTAssertEqual(Set(replaced.project.files.map(\.path.value)), ["b.txt"])
        let history = try await repository.history(id, owner: owner)
        XCTAssertEqual(history.count, 3)
        // Old revision is still fully recoverable: restore it into a new
        // revision and read the original bytes back.
        let restored = try await repository.restore(id, owner: owner,
                                                    expectedRevision: replaced.project.revision,
                                                    historicalRevision: first.project.revision)
        let old = try await repository.read(id, owner: owner, revision: restored.revision,
                                            path: GameRelativePath("a.txt"))
        XCTAssertEqual(old, Data("A".utf8))
    }

    func testLegacyGBKFilenamesImportWithExplicitEncodingOnly() async throws {
        let fixture = try GameArchiveFixture()
        defer { fixture.cleanup() }
        // "地图.dat" in GBK, no UTF-8 flag — as legacy Chinese tools wrote it.
        let gbkName: [UInt8] = [0xB5, 0xD8, 0xCD, 0xBC] + Array(".dat".utf8)
        let zip = fixture.root.appendingPathComponent("gbk.zip")
        let payload = Data("map-data".utf8)
        try GameTestZIPCraft.makeZIP([.legacyEntry(rawNameBytes: gbkName, data: payload)]).write(to: zip)

        let gbk = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(
            CFStringEncoding(CFStringEncodings.GBK_95.rawValue)))
        let exchange = GameArchiveExchange()

        // Default (CP437) import succeeds but mangles the asset name — the
        // exact failure mode the explicit override exists to fix.
        let mangled = try exchange.extract(archive: zip, to: fixture.root.appendingPathComponent("mangled"))
        XCTAssertFalse(mangled.manifest.files.map(\.path.value).contains("地图.dat"))

        // Explicit GBK override decodes names correctly, bytes identical.
        let repository = try makeRepository(fixture)
        let store = try GameArchiveOriginalStore(directory: fixture.root.appendingPathComponent("originals"))
        let importer = GameArchiveProjectImporter(originalStore: store)
        let id = UUID(), owner = GameProjectOwner.space(recordID: id)
        let result = try await importer.createProjectAndImport(archive: zip, repository: repository,
                                                               projectID: id, owner: owner, title: "GBK",
                                                               workspace: workspace(fixture),
                                                               filenameEncoding: gbk)
        XCTAssertEqual(result.project.files.map(\.path.value), ["地图.dat"])
        let bytes = try await repository.read(id, owner: owner, revision: result.project.revision,
                                              path: GameRelativePath("地图.dat"))
        XCTAssertEqual(bytes, payload)
        // Original archive bytes stay byte-identical regardless of name decoding.
        XCTAssertEqual(try Data(contentsOf: zip),
                       GameTestZIPCraft.makeZIP([.legacyEntry(rawNameBytes: gbkName, data: payload)]))

        // A wrong encoding fails closed (undecodable names are rejected rather
        // than silently relabeled); the caller's explicit correct selection wins.
        let repository2 = try FileGameProjectRepository(directory: fixture.root.appendingPathComponent("repo2"))
        let wrongID = UUID()
        do {
            _ = try await importer.createProjectAndImport(archive: zip, repository: repository2,
                                                           projectID: wrongID, owner: .space(recordID: wrongID),
                                                           title: "Wrong", workspace: workspace(fixture),
                                                           filenameEncoding: .ascii)
            XCTFail("expected encoding failure")
        } catch GameArchiveError.unsafeEntryPath {
        }
    }
}
