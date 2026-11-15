// SPDX-License-Identifier: MPL-2.0
import Foundation
import XCTest
import FloeGameCore
@testable import FloeGameEditingCore

@MainActor final class UndoMemoryBudgetTests: XCTestCase {
    private struct Fixture {
        let root: URL
        let repository: FileGameProjectRepository
        let id: UUID
        let owner: GameProjectOwner
        let path: GameRelativePath
        let session: GameEditingSession
    }

    private func fixture(budget: Int = 16 * 1_024 * 1_024) async throws -> Fixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("sprite-undo-" + UUID().uuidString)
        let source = root.appendingPathComponent("Source")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        let path = try GameRelativePath("sprite.bin")
        try Data(repeating: 1, count: 64).write(to: source.appendingPathComponent(path.value))
        try Data("unknown-original".utf8).write(to: source.appendingPathComponent("unknown.bin"))
        let repository = try FileGameProjectRepository(directory: root.appendingPathComponent("History"))
        let id = UUID(), owner = GameProjectOwner.space(recordID: id)
        _ = try await repository.importProject(from: source, projectID: id, owner: owner, title: "Sprite")
        let session = try await GameEditingSession.open(repository: repository, projectID: id, owner: owner,
            adapter: GameUnknownEditingAdapter(engine: .phaser), maximumUndoBytes: budget)
        return .init(root: root, repository: repository, id: id, owner: owner, path: path, session: session)
    }

    private func edit(_ f: Fixture, byte: UInt8) async throws {
        try await f.session.replaceAsset(at: f.path, with: Data(repeating: byte, count: 64))
    }

    func testByteBudgetRetainsNearestUndoRedoAndSavedBytes() async throws {
        let f = try await fixture(budget: 256)
        defer { try? FileManager.default.removeItem(at: f.root) }
        for byte in [UInt8(2), 3, 4] { try await edit(f, byte: byte) }
        try await f.session.undo()
        var bytes = try await f.session.documentBytes(at: f.path)
        XCTAssertEqual(bytes, Data(repeating: 3, count: 64))
        try await f.session.undo()
        bytes = try await f.session.documentBytes(at: f.path)
        XCTAssertEqual(bytes, Data(repeating: 2, count: 64))
        XCTAssertFalse(f.session.canUndo)
        try await f.session.redo()
        try await f.session.redo()
        let saved = try await f.session.save()
        bytes = try await f.repository.read(f.id, owner: f.owner, revision: saved.revision, path: f.path)
        XCTAssertEqual(bytes, Data(repeating: 4, count: 64))
        let unknown = try await f.repository.read(f.id, owner: f.owner, revision: saved.revision,
            path: GameRelativePath("unknown.bin"))
        XCTAssertEqual(unknown, Data("unknown-original".utf8))
    }

    func testRecoveredDraftUsesCurrentBudgetAndKeepsCurrentPixels() async throws {
        let f = try await fixture(budget: 1_024)
        defer { try? FileManager.default.removeItem(at: f.root) }
        for byte in [UInt8(2), 3, 4] { try await edit(f, byte: byte) }
        let reopened = try await GameEditingSession.open(repository: f.repository, projectID: f.id, owner: f.owner,
            adapter: GameUnknownEditingAdapter(engine: .phaser), maximumUndoBytes: 128)
        XCTAssertNotNil(reopened.pendingDraft)
        try await reopened.recoverDraft()
        var bytes = try await reopened.documentBytes(at: f.path)
        XCTAssertEqual(bytes, Data(repeating: 4, count: 64))
        try await reopened.undo()
        bytes = try await reopened.documentBytes(at: f.path)
        XCTAssertEqual(bytes, Data(repeating: 3, count: 64))
        XCTAssertFalse(reopened.canUndo)
        try await reopened.redo()
        let saved = try await reopened.save()
        bytes = try await f.repository.read(f.id, owner: f.owner, revision: saved.revision, path: f.path)
        XCTAssertEqual(bytes, Data(repeating: 4, count: 64))
    }

    func testOversizeSingleEditKeepsDraftAndSaveDespiteNoUndo() async throws {
        let f = try await fixture(budget: 32)
        defer { try? FileManager.default.removeItem(at: f.root) }
        try await edit(f, byte: 7)
        XCTAssertTrue(f.session.isDirty)
        XCTAssertFalse(f.session.canUndo)
        let reopened = try await GameEditingSession.open(repository: f.repository, projectID: f.id, owner: f.owner,
            adapter: GameUnknownEditingAdapter(engine: .phaser))
        XCTAssertNotNil(reopened.pendingDraft)
        try await reopened.recoverDraft()
        let saved = try await reopened.save()
        let bytes = try await f.repository.read(f.id, owner: f.owner, revision: saved.revision, path: f.path)
        XCTAssertEqual(bytes, Data(repeating: 7, count: 64))
    }

    func testFirstEditAfterExternalSaveRetainsBothVersionsUntilDecision() async throws {
        let f = try await fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        let original = try await f.session.documentBytes(at: f.path)
        let external = Data(repeating: 9, count: 128)
        let head = try await f.repository.commit(f.id, owner: f.owner,
            expectedRevision: f.session.expectedRevision, changes: [.write(f.path, external)])
        try await f.session.editDocument(at: f.path, summary: .init("Paint", "绘制")) { bytes in
            XCTAssertEqual(bytes, original)
            return bytes + Data([7])
        }
        var actual = try await f.repository.read(f.id, owner: f.owner, revision: head.revision, path: f.path)
        XCTAssertEqual(actual, external)
        do { _ = try await f.session.save(); XCTFail("Expected explicit save conflict") }
        catch GameProjectError.conflict { }
        XCTAssertNotNil(f.session.conflict)
        try await f.session.reloadForRebase()
        XCTAssertNotNil(f.session.fileConflicts[f.path])
        try f.session.resolveConflict(at: f.path, .keepMine)
        let saved = try await f.session.save()
        actual = try await f.repository.read(f.id, owner: f.owner, revision: saved.revision, path: f.path)
        XCTAssertEqual(actual, original + Data([7]))
        let preservedExternal = try await f.repository.readHistorical(f.id, owner: f.owner,
            expectedRevision: saved.revision, historicalRevision: head.revision, path: f.path)
        XCTAssertEqual(preservedExternal, external)
    }

    func testHistoryCountBoundLeavesNearestTwoHundredEditsUsable() async throws {
        let f = try await fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        for value in UInt16(1)...UInt16(205) {
            try await f.session.replaceAsset(at: f.path,
                with: Data([UInt8(value & 255), UInt8(value >> 8)]))
        }
        var count = 0
        while f.session.canUndo { try await f.session.undo(); count += 1 }
        XCTAssertEqual(count, 200)
        let bytes = try await f.session.documentBytes(at: f.path)
        XCTAssertEqual(bytes, Data([5, 0]))
    }

    func testOversizeDraftAndSymlinkAreRejectedWithOriginalsIntact() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let id = UUID(), owner = GameProjectOwner.space(recordID: id)
        let folder = root.appendingPathComponent("EditingDrafts/" + id.uuidString.lowercased())
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appendingPathComponent("draft.json")
        XCTAssertTrue(FileManager.default.createFile(atPath: file.path, contents: nil))
        let handle = try FileHandle(forWritingTo: file)
        try handle.truncate(atOffset: 33 * 1_024 * 1_024)
        try handle.close()
        let store = EditingDraftStore(repositoryDirectory: root)
        XCTAssertThrowsError(try store.loadRetained(projectID: id, owner: owner))
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
        try FileManager.default.removeItem(at: file)
        let external = root.appendingPathComponent("original.json")
        let original = Data("preserved-original".utf8)
        try original.write(to: external)
        try FileManager.default.createSymbolicLink(at: file, withDestinationURL: external)
        XCTAssertThrowsError(try store.loadRetained(projectID: id, owner: owner))
        XCTAssertEqual(try Data(contentsOf: external), original)
    }
}
