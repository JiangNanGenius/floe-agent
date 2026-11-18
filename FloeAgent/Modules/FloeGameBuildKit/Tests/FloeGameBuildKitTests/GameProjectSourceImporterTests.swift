// SPDX-License-Identifier: MPL-2.0
import Foundation
import XCTest
import FloeGameCore
@testable import FloeGameBuildKit

final class GameProjectSourceImporterTests: XCTestCase {
    func testLargeZipAndFolderKeepTheEntireGame() async throws {
        let f = try GameArchiveFixture()
        defer { f.cleanup() }
        let source = f.root.appendingPathComponent("large-game")
        try FileManager.default.createDirectory(at: source.appendingPathComponent("www"), withIntermediateDirectories: true)
        try Data("<html></html>".utf8).write(to: source.appendingPathComponent("www/index.html"))
        let big = source.appendingPathComponent("nw.dll")
        XCTAssertTrue(FileManager.default.createFile(atPath: big.path, contents: nil))
        let handle = try FileHandle(forWritingTo: big)
        try handle.truncate(atOffset: 270 * 1_024 * 1_024)
        try handle.close()
        let repository = try FileGameProjectRepository(directory: f.root.appendingPathComponent("big-repo"))
        let store = try GameArchiveOriginalStore(directory: f.root.appendingPathComponent("big-originals"))
        let importer = GameProjectSourceImporter(originalStore: store)
        let zip = f.root.appendingPathComponent("large.zip")
        _ = try GameArchiveExchange().archive(directory: source, to: zip)
        for selected in [source, zip] {
            let id = UUID(), owner = GameProjectOwner.space(recordID: id)
            let created = try await repository.createProject(projectID: id, owner: owner, title: "Large")
            let result = try await importer.importSource(selected, into: created, repository: repository,
                                                        workspace: f.root.appendingPathComponent("big-jobs"))
            XCTAssertEqual(result.project.files.first { $0.path.value == "nw.dll" }?.bytes, 270 * 1_024 * 1_024)
            XCTAssertTrue(result.project.files.contains { $0.path.value == "www/index.html" })
            XCTAssertEqual(result.originalArchiveSHA256 != nil, selected == zip)
        }
    }

    func testWindowsWebDeploymentRetainsLargeRuntimeAndGameFiles() async throws {
        let f = try GameArchiveFixture()
        defer { f.cleanup() }
        let source = f.root.appendingPathComponent("Windows deployment")
        for path in ["www/js", "www/data", "locales"] {
            try FileManager.default.createDirectory(at: source.appendingPathComponent(path), withIntermediateDirectories: true)
        }
        for (path, contents) in [("Game.exe", "windows binary"), ("package.json", "{}"),
                                 ("www/index.html", "<html></html>"), ("www/js/rpg_core.js", "// MV"),
                                 ("www/data/System.json", "{}"), ("locales/en.pak", "locale")] {
            try Data(contents.utf8).write(to: source.appendingPathComponent(path))
        }
        let dll = source.appendingPathComponent("nw.dll")
        XCTAssertTrue(FileManager.default.createFile(atPath: dll.path, contents: nil))
        let handle = try FileHandle(forWritingTo: dll)
        try handle.truncate(atOffset: 190 * 1_024 * 1_024)
        try handle.close()
        let repository = try FileGameProjectRepository(directory: f.root.appendingPathComponent("repo"))
        let id = UUID(), owner = GameProjectOwner.space(recordID: id)
        let created = try await repository.createProject(projectID: id, owner: owner, title: "Windows")
        let store = try GameArchiveOriginalStore(directory: f.root.appendingPathComponent("originals"))
        let result = try await GameProjectSourceImporter(originalStore: store).importSource(source,
            into: created, repository: repository, workspace: f.root.appendingPathComponent("jobs"))
        XCTAssertEqual(result.project.files.first { $0.path.value == "nw.dll" }?.bytes, 190 * 1_024 * 1_024)
        XCTAssertTrue(result.project.files.contains { $0.path.value == "www/index.html" })
        XCTAssertTrue(result.project.files.contains { $0.path.value == "locales/en.pak" })
        XCTAssertTrue(result.preview.recognizedEngines.contains(.rpgMakerMV))
        XCTAssertFalse(result.preview.recognizedEngines.contains(.rpgMakerXP))
        let reopened = try await repository.open(id, owner: owner)
        XCTAssertEqual(reopened.revision, result.project.revision)
    }

    func testFolderSelectionPreservesUnknownFilesAndEmptyDirectories() async throws {
        let f = try GameArchiveFixture()
        defer { f.cleanup() }
        let source = f.root.appendingPathComponent("chosen folder")
        try FileManager.default.createDirectory(at: source.appendingPathComponent("empty"), withIntermediateDirectories: true)
        let bytes = Data([0, 255, 71, 12])
        try bytes.write(to: source.appendingPathComponent(".unknown"))
        // A broken dependency hint must not block a complete folder import.
        let brokenPackage = Data("{unfinished".utf8)
        try brokenPackage.write(to: source.appendingPathComponent("package.json"))
        let repository = try FileGameProjectRepository(directory: f.root.appendingPathComponent("repo"))
        let id = UUID(), owner = GameProjectOwner.space(recordID: id)
        let created = try await repository.createProject(projectID: id, owner: owner, title: "Folder")
        let store = try GameArchiveOriginalStore(directory: f.root.appendingPathComponent("originals"))
        let imported = try await GameProjectSourceImporter(originalStore: store).importSource(source,
            into: created, repository: repository, workspace: f.root.appendingPathComponent("jobs"))
        XCTAssertEqual(imported.project.files.map(\.path.value), [".unknown", "package.json"])
        XCTAssertTrue(imported.project.directories.map(\.value).contains("empty"))
        XCTAssertTrue(imported.preview.rootCandidates.contains { $0.name == "empty" && $0.isDirectory })
        XCTAssertNil(imported.originalArchiveSHA256)
        let saved = try await repository.read(id, owner: owner, revision: imported.project.revision,
                                             path: GameRelativePath(".unknown"))
        XCTAssertEqual(saved, bytes)
        let savedPackage = try await repository.read(id, owner: owner, revision: imported.project.revision,
                                                    path: GameRelativePath("package.json"))
        XCTAssertEqual(savedPackage, brokenPackage)
        XCTAssertEqual(try Data(contentsOf: source.appendingPathComponent(".unknown")), bytes)
    }

    func testPickedArchiveUsesMagicAndPreservesOriginalBeforeImport() async throws {
        let f = try GameArchiveFixture()
        defer { f.cleanup() }
        let source = f.root.appendingPathComponent("chosen.data")
        let original = GameTestZIPCraft.makeZIP([
            .entry("Outer/Game/Game.rvproj2", data: Data("VXAce".utf8)),
            .entry("Outer/notes.txt", data: Data("keep".utf8))
        ])
        try original.write(to: source)
        let repository = try FileGameProjectRepository(directory: f.root.appendingPathComponent("repo"))
        let id = UUID(), owner = GameProjectOwner.space(recordID: id)
        let created = try await repository.createProject(projectID: id, owner: owner, title: "ZIP")
        let store = try GameArchiveOriginalStore(directory: f.root.appendingPathComponent("originals"))
        let result = try await GameProjectSourceImporter(originalStore: store).importSource(source,
            into: created, repository: repository, workspace: f.root.appendingPathComponent("jobs"))
        XCTAssertEqual(result.importedFiles, 2)
        XCTAssertEqual(result.preview.recognizedEngines, [.rpgMakerVXAce])
        let digest = try XCTUnwrap(result.originalArchiveSHA256)
        let preserved = try await store.read(sha256: digest)
        XCTAssertEqual(preserved, original)
        let reopened = try await repository.open(id, owner: owner)
        XCTAssertEqual(reopened.revision, result.project.revision)
    }

    func testExistingContentIsNeverSilentlyReplacedByPickedFolder() async throws {
        let f = try GameArchiveFixture()
        defer { f.cleanup() }
        let source = f.root.appendingPathComponent("source")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try Data("new".utf8).write(to: source.appendingPathComponent("name.txt"))
        let repository = try FileGameProjectRepository(directory: f.root.appendingPathComponent("repo"))
        let id = UUID(), owner = GameProjectOwner.space(recordID: id)
        let empty = try await repository.createProject(projectID: id, owner: owner, title: "Existing")
        let current = try await repository.commit(id, owner: owner, expectedRevision: empty.revision,
            changes: [.write(GameRelativePath("name.txt"), Data("old".utf8))])
        let store = try GameArchiveOriginalStore(directory: f.root.appendingPathComponent("originals"))
        do {
            _ = try await GameProjectSourceImporter(originalStore: store).importSource(source,
                into: current, repository: repository, workspace: f.root.appendingPathComponent("jobs"))
            XCTFail("Non-empty projects require an explicit separate replacement operation")
        } catch GameProjectError.importDestinationNotEmpty {}
        let saved = try await repository.read(id, owner: owner, revision: current.revision,
                                             path: GameRelativePath("name.txt"))
        XCTAssertEqual(saved, Data("old".utf8))
    }

    func testPrecancelledSelectionLeavesCreatedProjectEmpty() async throws {
        let f = try GameArchiveFixture()
        defer { f.cleanup() }
        let repository = try FileGameProjectRepository(directory: f.root.appendingPathComponent("repo"))
        let id = UUID(), owner = GameProjectOwner.space(recordID: id)
        let created = try await repository.createProject(projectID: id, owner: owner, title: "Cancelled")
        let store = try GameArchiveOriginalStore(directory: f.root.appendingPathComponent("originals"))
        let source = f.root.appendingPathComponent("does-not-need-to-be-read")
        let jobs = f.root.appendingPathComponent("jobs")
        let job = Task {
            while !Task.isCancelled { await Task.yield() }
            return try await GameProjectSourceImporter(originalStore: store).importSource(source,
                into: created, repository: repository, workspace: jobs)
        }
        job.cancel()
        do { _ = try await job.value; XCTFail("Cancellation must precede source IO") }
        catch is CancellationError {}
        let reopened = try await repository.open(id, owner: owner)
        XCTAssertEqual(reopened.revision, created.revision)
        XCTAssertTrue(reopened.files.isEmpty)
    }
}
