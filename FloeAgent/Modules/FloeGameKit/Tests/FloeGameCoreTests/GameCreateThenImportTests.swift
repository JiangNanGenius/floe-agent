// SPDX-License-Identifier: MPL-2.0
import Foundation
import XCTest
@testable import FloeGameCore

@MainActor final class GameCreateThenImportTests: XCTestCase {
    func testCreateImportUnknownNestedTreesOrganizeAndRollback() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("downloaded")
        try FileManager.default.createDirectory(at: source.appendingPathComponent("outer/Unknown/Empty"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: source.appendingPathComponent("outer/Godot"), withIntermediateDirectories: true)
        let original = Data([0, 255, 1, 127])
        try original.write(to: source.appendingPathComponent("outer/Unknown/asset.bin"))
        try Data("config_version=5\n".utf8).write(to: source.appendingPathComponent("outer/Godot/project.godot"))
        try Data("unrecognized project".utf8).write(to: source.appendingPathComponent("README.txt"))
        let repo = try FileGameProjectRepository(directory: root.appendingPathComponent("store")), id = UUID(), owner = GameProjectOwner.space(recordID: id)
        let empty = try await repo.createProject(projectID: id, owner: owner, title: "My game")
        XCTAssertTrue(empty.files.isEmpty); XCTAssertNil(empty.engine)
        let imported = try await repo.importContents(from: source, into: id, owner: owner, expectedRevision: empty.revision)
        XCTAssertEqual(imported.projectID, empty.projectID); XCTAssertEqual(imported.parent, empty.revision)
        XCTAssertEqual(imported.files.count, 3)
        XCTAssertTrue(imported.directories.contains { $0.value == "outer/Unknown/Empty" })
        let bytes = try await repo.read(id, owner: owner, revision: imported.revision, path: GameRelativePath("outer/Unknown/asset.bin"))
        XCTAssertEqual(bytes, original)
        let arranged = try await repo.relocateFiles(id, owner: owner, expectedRevision: imported.revision,
            moves: [GameFileRelocation(from: GameRelativePath("outer/Unknown/asset.bin"), to: GameRelativePath("Assets/asset.bin"))], removeEmptyDirectories: true)
        XCTAssertEqual(arranged.files.first { $0.path.value == "Assets/asset.bin" }?.sha256, imported.files.first { $0.path.value == "outer/Unknown/asset.bin" }?.sha256)
        let restored = try await repo.restore(id, owner: owner, expectedRevision: arranged.revision, historicalRevision: imported.revision)
        XCTAssertEqual(restored.files, imported.files)
        XCTAssertEqual(try Data(contentsOf: source.appendingPathComponent("outer/Unknown/asset.bin")), original)
        let history = try await repo.history(id, owner: owner)
        XCTAssertEqual(history.count, 4)
    }

    func testAIOrganizationSupportsCyclesWithoutLosingAssetsAndRejectsCollisions() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let repo = try FileGameProjectRepository(directory: root), id = UUID(), owner = GameProjectOwner.space(recordID: id)
        let empty = try await repo.createProject(projectID: id, owner: owner, title: "Game")
        let initial = try await repo.commit(id, owner: owner, expectedRevision: empty.revision, changes: [
            .write(GameRelativePath("a.bin"), Data([1, 2, 3])), .write(GameRelativePath("b.bin"), Data([4, 5, 6]))])
        do {
            _ = try await repo.relocateFiles(id, owner: owner, expectedRevision: initial.revision,
                moves: [GameFileRelocation(from: GameRelativePath("a.bin"), to: GameRelativePath("b.bin"))])
            XCTFail("Collision must preserve both original files")
        } catch { XCTAssertEqual(error as? GameProjectError, .invalidEdit) }
        let swapped = try await repo.relocateFiles(id, owner: owner, expectedRevision: initial.revision, moves: [
            GameFileRelocation(from: GameRelativePath("a.bin"), to: GameRelativePath("b.bin")),
            GameFileRelocation(from: GameRelativePath("b.bin"), to: GameRelativePath("a.bin"))])
        let a = try await repo.read(id, owner: owner, revision: swapped.revision, path: GameRelativePath("a.bin"))
        let b = try await repo.read(id, owner: owner, revision: swapped.revision, path: GameRelativePath("b.bin"))
        XCTAssertEqual(a, Data([4, 5, 6])); XCTAssertEqual(b, Data([1, 2, 3]))
    }

    func testExplicitChatToSpaceUpdateKeepsIndependentVersionsAndFencesStaleTarget() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let repo = try FileGameProjectRepository(directory: root), chatID = UUID(), spaceID = UUID()
        let chatOwner = GameProjectOwner.conversation(conversationID: UUID(), workspaceID: UUID()), spaceOwner = GameProjectOwner.space(recordID: spaceID)
        let emptyChat = try await repo.createProject(projectID: chatID, owner: chatOwner, title: "Chat game")
        let chat = try await repo.commit(chatID, owner: chatOwner, expectedRevision: emptyChat.revision, changes: [.write(GameRelativePath("game.txt"), Data("from chat".utf8))])
        let emptySpace = try await repo.createProject(projectID: spaceID, owner: spaceOwner, title: "Space game")
        let saved = try await repo.updateCopy(from: chatID, sourceOwner: chatOwner, sourceRevision: chat.revision, to: spaceID, targetOwner: spaceOwner, expectedTargetRevision: emptySpace.revision)
        let spaceEdit = try await repo.commit(spaceID, owner: spaceOwner, expectedRevision: saved.revision, changes: [.write(GameRelativePath("space-only.txt"), Data("space edit".utf8))])
        do {
            _ = try await repo.updateCopy(from: chatID, sourceOwner: chatOwner, sourceRevision: chat.revision, to: spaceID, targetOwner: spaceOwner, expectedTargetRevision: saved.revision)
            XCTFail("An old save must not overwrite another edit")
        } catch { XCTAssertEqual(error as? GameProjectError, .conflict(expected: saved.revision, actual: spaceEdit.revision)) }
        let stillChat = try await repo.open(chatID, owner: chatOwner)
        XCTAssertEqual(stillChat, chat)
        let updated = try await repo.updateCopy(from: chatID, sourceOwner: chatOwner, sourceRevision: chat.revision, to: spaceID, targetOwner: spaceOwner, expectedTargetRevision: spaceEdit.revision)
        XCTAssertEqual(updated.files, chat.files); XCTAssertEqual(updated.title, "Space game")
        let restored = try await repo.restore(spaceID, owner: spaceOwner, expectedRevision: updated.revision, historicalRevision: spaceEdit.revision)
        XCTAssertTrue(restored.files.contains { $0.path.value == "space-only.txt" })
    }

    func testExistingContentRequiresExplicitReplaceAndOldRevisionSurvives() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try Data("imported".utf8).write(to: source.appendingPathComponent("new.txt"))
        let repo = try FileGameProjectRepository(directory: root.appendingPathComponent("store")), id = UUID(), owner = GameProjectOwner.space(recordID: id)
        let created = try await repo.createProject(projectID: id, owner: owner, title: "Game")
        let edited = try await repo.commit(id, owner: owner, expectedRevision: created.revision, changes: [.write(GameRelativePath("old.txt"), Data("keep".utf8))])
        do { _ = try await repo.importContents(from: source, into: id, owner: owner, expectedRevision: edited.revision); XCTFail("Expected explicit replacement") }
        catch { XCTAssertEqual(error as? GameProjectError, .importDestinationNotEmpty) }
        let unchanged = try await repo.open(id, owner: owner); XCTAssertEqual(unchanged, edited)
        let replaced = try await repo.importContents(from: source, into: id, owner: owner, expectedRevision: edited.revision, replaceExisting: true)
        XCTAssertEqual(replaced.files.map(\.path.value), ["new.txt"])
        let restored = try await repo.restore(id, owner: owner, expectedRevision: replaced.revision, historicalRevision: edited.revision)
        XCTAssertEqual(restored.files, edited.files)
    }
}
