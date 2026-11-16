// SPDX-License-Identifier: MPL-2.0
import Foundation
import XCTest
@testable import FloeGameCore

private final class RepositoryFixture {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("FloeGameRepository-" + UUID().uuidString)
    init() throws { try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true) }
    func directory(_ name: String) throws -> URL {
        let url = root.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
    func source() throws -> URL {
        let source = try directory("source")
        try Data(#"{"actors":[null,{"name":"Hero","hp":100,"unknown":{"keep":[1,true,null]}}],"extra":"保留"}"#.utf8).write(to: source.appendingPathComponent("data.json"))
        try Data([0, 255, 127, 0, 42]).write(to: source.appendingPathComponent("unknown.bin"))
        let script = source.appendingPathComponent("build.sh")
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: script)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        try FileManager.default.createDirectory(at: source.appendingPathComponent("Assets/Empty"), withIntermediateDirectories: true)
        return source
    }
    deinit { try? FileManager.default.removeItem(at: root) }
}

private func commitAttempt(_ repository: FileGameProjectRepository, id: UUID, owner: GameProjectOwner,
                           revision: String, value: String) async throws -> Bool {
    do {
        _ = try await repository.commit(id, owner: owner, expectedRevision: revision,
            changes: [.write(GameRelativePath("new.txt"), Data(value.utf8))])
        return true
    } catch GameProjectError.conflict { return false }
}

@MainActor final class GameRepositoryTests: XCTestCase {
    func testImportModifyReopenRestoreAndExportPreserveOriginalAndUnknownData() async throws {
        let fixture = try RepositoryFixture(), source = try fixture.source()
        let original = try Data(contentsOf: source.appendingPathComponent("data.json"))
        let root = try fixture.directory("store"), id = UUID(), owner = GameProjectOwner.space(recordID: id)
        let store = try FileGameProjectRepository(directory: root)
        let first = try await store.importProject(from: source, projectID: id, owner: owner, title: "Project", engine: .rpgMakerMZ)
        let patched = try GameJSONPatch.replacing(original, at: [.key("actors"), .index(1), .key("hp")], with: Data("250".utf8))
        let saved = try await store.commit(id, owner: owner, expectedRevision: first.revision,
            changes: [.write(GameRelativePath("data.json"), patched)])
        let reopened = try FileGameProjectRepository(directory: root)
        let loaded = try await reopened.open(id, owner: owner)
        XCTAssertEqual(loaded, saved)
        let bytes = try await reopened.read(id, owner: owner, revision: saved.revision, path: GameRelativePath("data.json"))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
        XCTAssertEqual(object["extra"] as? String, "保留")
        let actors = try XCTUnwrap(object["actors"] as? [Any])
        let hero = try XCTUnwrap(actors[1] as? [String: Any])
        XCTAssertEqual(hero["hp"] as? Int, 250)
        XCTAssertNotNil(hero["unknown"])
        let history = try await reopened.history(id, owner: owner)
        XCTAssertEqual(history.map(\.revision), [saved.revision, first.revision])
        let restored = try await reopened.restore(id, owner: owner, expectedRevision: saved.revision, historicalRevision: first.revision)
        XCTAssertNotEqual(restored.revision, first.revision)
        let out = fixture.root.appendingPathComponent("export")
        _ = try await reopened.export(id, owner: owner, expectedRevision: restored.revision, to: out)
        XCTAssertEqual(try Data(contentsOf: out.appendingPathComponent("data.json")), original)
        XCTAssertEqual(try Data(contentsOf: out.appendingPathComponent("unknown.bin")), Data([0, 255, 127, 0, 42]))
        XCTAssertTrue(FileManager.default.fileExists(atPath: out.appendingPathComponent("Assets/Empty").path))
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: out.appendingPathComponent("build.sh").path))
        XCTAssertEqual(try Data(contentsOf: source.appendingPathComponent("data.json")), original)
    }

    func testIndependentInstancesReallyCompareAndSwapAcrossWriters() async throws {
        let fixture = try RepositoryFixture(), source = try fixture.source(), root = try fixture.directory("store")
        let id = UUID(), owner = GameProjectOwner.space(recordID: id)
        let a = try FileGameProjectRepository(directory: root), b = try FileGameProjectRepository(directory: root)
        let initial = try await a.importProject(from: source, projectID: id, owner: owner, title: "CAS")
        async let one = commitAttempt(a, id: id, owner: owner, revision: initial.revision, value: "one")
        async let two = commitAttempt(b, id: id, owner: owner, revision: initial.revision, value: "two")
        let results = try await [one, two]
        XCTAssertEqual(results.filter { $0 }.count, 1)
        let history = try await a.history(id, owner: owner)
        XCTAssertEqual(history.count, 2)
    }

    func testFailedBatchAndWrongOwnerDoNotChangeTheOriginal() async throws {
        let fixture = try RepositoryFixture(), source = try fixture.source(), root = try fixture.directory("store")
        let id = UUID(), owner = GameProjectOwner.space(recordID: id), store = try FileGameProjectRepository(directory: root)
        let initial = try await store.importProject(from: source, projectID: id, owner: owner, title: "Rollback")
        let objectsBefore = try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("Objects").path).sorted()
        do {
            _ = try await store.commit(id, owner: owner, expectedRevision: initial.revision,
                changes: [.write(GameRelativePath("new.txt"), Data("staged".utf8)), .remove(GameRelativePath("missing.txt"))])
            XCTFail("Expected an atomic batch failure")
        } catch { XCTAssertEqual(error as? GameProjectError, .invalidEdit) }
        let loaded = try await store.open(id, owner: owner)
        XCTAssertEqual(loaded, initial)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("Objects").path).sorted(), objectsBefore)
        do {
            _ = try await store.open(id, owner: .conversation(conversationID: UUID(), workspaceID: UUID()))
            XCTFail("Expected ownership rejection")
        } catch { XCTAssertEqual(error as? GameProjectError, .ownershipMismatch) }
    }

    func testCopiesHaveIndependentHeadsAndOwners() async throws {
        let fixture = try RepositoryFixture(), source = try fixture.source(), root = try fixture.directory("store")
        let id = UUID(), owner = GameProjectOwner.space(recordID: id), store = try FileGameProjectRepository(directory: root)
        let original = try await store.importProject(from: source, projectID: id, owner: owner, title: "Space")
        let copyID = UUID(), copyOwner = GameProjectOwner.conversation(conversationID: UUID(), workspaceID: UUID())
        let copy = try await store.copy(id, owner: owner, to: copyID, newOwner: copyOwner)
        _ = try await store.commit(copyID, owner: copyOwner, expectedRevision: copy.revision,
            changes: [.write(GameRelativePath("data.json"), Data("{}".utf8))])
        let remaining = try await store.open(id, owner: owner)
        XCTAssertEqual(remaining, original)
        let originalBytes = try await store.read(id, owner: owner, revision: original.revision, path: GameRelativePath("data.json"))
        XCTAssertEqual(originalBytes, try Data(contentsOf: source.appendingPathComponent("data.json")))
    }

    func testNoOverwriteSymlinkImportAndCorruptObjectsAreRejected() async throws {
        let fixture = try RepositoryFixture(), source = try fixture.source(), root = try fixture.directory("store")
        let id = UUID(), owner = GameProjectOwner.space(recordID: id), store = try FileGameProjectRepository(directory: root)
        try FileManager.default.createSymbolicLink(at: source.appendingPathComponent("escape"), withDestinationURL: fixture.root)
        do { _ = try await store.importProject(from: source, projectID: id, owner: owner, title: "Bad"); XCTFail("Expected symlink rejection") }
        catch { XCTAssertEqual(error as? GameProjectError, .unsafePath("escape")) }
        try FileManager.default.removeItem(at: source.appendingPathComponent("escape"))
        let project = try await store.importProject(from: source, projectID: id, owner: owner, title: "Good")
        do { _ = try await store.export(id, owner: owner, expectedRevision: project.revision, to: source); XCTFail("Expected no overwrite") }
        catch { XCTAssertEqual(error as? GameProjectError, .destinationExists) }
        let file = try XCTUnwrap(project.files.first)
        try Data("tampered".utf8).write(to: root.appendingPathComponent("Objects/" + file.sha256))
        do { _ = try await store.read(id, owner: owner, revision: project.revision, path: file.path); XCTFail("Expected real byte verification") }
        catch { XCTAssertEqual(error as? GameProjectError, .corruptStorage) }
    }

    func testLargeArtifactIsSealedWithoutAnUnboundedResourceRead() throws {
        let fixture = try RepositoryFixture(), source = try fixture.source()
        try Data("<!doctype html>".utf8).write(to: source.appendingPathComponent("index.html"))
        let asset = source.appendingPathComponent("large.ogg")
        XCTAssertTrue(FileManager.default.createFile(atPath: asset.path, contents: nil))
        let handle = try FileHandle(forWritingTo: asset)
        try handle.truncate(atOffset: 70 * 1_024 * 1_024)
        try handle.close()
        let id = UUID(), context = try GameProjectContext(projectID: id, owner: .space(recordID: id), rootURL: source, savedRevision: "saved")
        let artifact = try GameWebArtifactPackage.build(source: context, engine: .phaser, entry: GameRelativePath("index.html"), to: fixture.root.appendingPathComponent("artifact"))
        try artifact.verify()
        XCTAssertThrowsError(try artifact.readResource(GameRelativePath("large.ogg"))) {
            XCTAssertEqual($0 as? GameProjectError, .limitExceeded("large.ogg"))
        }
    }

    func testArtifactCopiesAndVerifiesRealBytesAndPreservesLicenses() throws {
        let fixture = try RepositoryFixture(), source = try fixture.source()
        try Data("<!doctype html><p>Artifact</p>".utf8).write(to: source.appendingPathComponent("index.html"))
        try Data("fixture license".utf8).write(to: source.appendingPathComponent("LICENSE.txt"))
        let id = UUID(), context = try GameProjectContext(projectID: id, owner: .space(recordID: id), rootURL: source, savedRevision: "saved")
        let artifact = try GameWebArtifactPackage.build(source: context, engine: .phaser, entry: GameRelativePath("index.html"), to: fixture.root.appendingPathComponent("artifact"))
        try artifact.verify()
        XCTAssertEqual(try artifact.readResource(GameRelativePath("LICENSE.txt")), Data("fixture license".utf8))
        try Data("changed".utf8).write(to: artifact.directory.appendingPathComponent("index.html"))
        XCTAssertThrowsError(try artifact.readResource(GameRelativePath("index.html"))) { XCTAssertEqual($0 as? GameProjectError, .corruptStorage) }
    }

    func testProgressPersistsWithCASAndDoesNotLeakToAnotherOwner() async throws {
        let fixture = try RepositoryFixture(), root = try fixture.directory("saves"), id = UUID()
        let owner = GameProjectOwner.space(recordID: id)
        let store = try FileGameSaveRepository(directory: root, projectID: id, owner: owner)
        let state = Data(#"{"x":80,"y":200,"score":1}"#.utf8)
        let checkpoint = try await store.save(state, expectedRevision: 0)
        let reopened = try FileGameSaveRepository(directory: root, projectID: id, owner: owner)
        let saved = try await reopened.load()
        XCTAssertEqual(saved?.state, state); XCTAssertEqual(saved?.revision, checkpoint.revision)
        do { _ = try await store.save(state, expectedRevision: 0); XCTFail("Expected save CAS conflict") }
        catch { XCTAssertEqual(error as? GameProjectError, .conflict(expected: "0", actual: "1")) }
        let other = try FileGameSaveRepository(directory: root, projectID: id, owner: .conversation(conversationID: UUID(), workspaceID: UUID()))
        let unrelated = try await other.load()
        XCTAssertNil(unrelated)
    }

    func testCorruptHistoricalRevisionCannotReplaceCurrentOriginal() async throws {
        let fixture = try RepositoryFixture(), source = try fixture.source(), root = try fixture.directory("store")
        let id = UUID(), owner = GameProjectOwner.space(recordID: id), store = try FileGameProjectRepository(directory: root)
        let initial = try await store.importProject(from: source, projectID: id, owner: owner, title: "History")
        let current = try await store.commit(id, owner: owner, expectedRevision: initial.revision,
            changes: [.write(GameRelativePath("new.txt"), Data("current".utf8))])
        let oldFile = root.appendingPathComponent(id.uuidString.lowercased() + "/Revisions/" + initial.revision + ".json")
        try Data("corrupt".utf8).write(to: oldFile)
        do {
            _ = try await store.restore(id, owner: owner, expectedRevision: current.revision, historicalRevision: initial.revision)
            XCTFail("Expected immutable history checksum rejection")
        } catch { XCTAssertEqual(error as? GameProjectError, .corruptStorage) }
        let intact = try await store.open(id, owner: owner)
        XCTAssertEqual(intact, current)
    }
}
