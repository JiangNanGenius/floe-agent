// SPDX-License-Identifier: MPL-2.0
import Foundation
import XCTest
import FloeGameCore
@testable import FloeGameAuthoring

private struct RepositoryContexts: GameAuthoringContextHost {
    let repository: FileGameProjectRepository
    let original: GameProjectContext
    func currentContext(for context: GameProjectContext) async throws -> GameProjectContext {
        let project = try await repository.open(original.projectID, owner: original.owner)
        return try .init(projectID: project.projectID, owner: project.owner, rootURL: original.rootURL,
            savedRevision: project.revision, environmentID: original.environmentID)
    }
}
private actor RepairProvider: GameAIEditProvider {
    var sawErrors = false
    func propose(_ request: GameAIEditRequest) async throws -> GameAIEditProposal {
        let path = try GameRelativePath("game.json"), bytes = try XCTUnwrap(request.files[path])
        if request.repairAttempt > 0 { sawErrors = request.diagnostics.contains { $0.severity == .error } }
        let value = request.repairAttempt == 0 ? Data("\"fast\"".utf8) : Data("240".utf8)
        let next = try GameJSONPatch.replacing(bytes, at: [.key("speed")], with: value)
        return try .init(baseRevision: request.context.savedRevision, changes: [.write(path, next)], summary: request.repairAttempt == 0 ? "Change speed" : "Repair invalid speed")
    }
}
private actor WaitingProvider: GameAIEditProvider {
    var waiting = false
    var continuation: CheckedContinuation<Void, Never>?
    func propose(_ request: GameAIEditRequest) async throws -> GameAIEditProposal {
        await withCheckedContinuation { continuation in self.continuation = continuation; waiting = true }
        return try .init(baseRevision: request.context.savedRevision, changes: [.write(GameRelativePath("late.txt"), Data("late".utf8))], summary: "Late response")
    }
    func release() { continuation?.resume(); continuation = nil }
    func waitUntilStarted() async throws {
        for _ in 0..<100 {
            if waiting { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw GameAuthoringError.staleSession
    }
}
private final class Fixture {
    let root: URL
    let repository: FileGameProjectRepository
    let project: GameStoredProject
    let context: GameProjectContext
    init() async throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let source = root.appendingPathComponent("source")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try Data(#"{"title":"Game","speed":180,"unknown":{"preserve":true}}"#.utf8).write(to: source.appendingPathComponent("game.json"))
        repository = try FileGameProjectRepository(directory: root.appendingPathComponent("repository"))
        let id = UUID(), owner = GameProjectOwner.space(recordID: id)
        project = try await repository.importProject(from: source, projectID: id, owner: owner, title: "Game", engine: .phaser)
        context = try .init(projectID: id, owner: owner, rootURL: source, savedRevision: project.revision, environmentID: "existing-environment")
    }
    func service(_ provider: any GameAIEditProvider) -> GameAIEditingService {
        .init(repository: repository, contexts: RepositoryContexts(repository: repository, original: context), provider: provider, validators: [GameJSONValidator()])
    }
    deinit { try? FileManager.default.removeItem(at: root) }
}

@MainActor final class AuthoringTests: XCTestCase {
    func testInvalidAIEditIsRepairedWithDurableDiffsAndRollback() async throws {
        let fixture = try await Fixture(), provider = RepairProvider(), service = fixture.service(provider)
        let result = try await service.edit(goal: "Move faster", context: fixture.context, sourcePaths: [GameRelativePath("game.json")], playtest: false)
        XCTAssertTrue(result.passed); XCTAssertEqual(result.revisions.count, 2)
        let sawErrors = await provider.sawErrors; XCTAssertTrue(sawErrors)
        let bytes = try await fixture.repository.read(result.project.projectID, owner: result.project.owner, revision: result.project.revision, path: GameRelativePath("game.json"))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
        XCTAssertEqual(object["speed"] as? Int, 240); XCTAssertNotNil(object["unknown"])
        XCTAssertNotEqual(result.revisions[0].differences[0].beforeSHA256, result.revisions[0].differences[0].afterSHA256)
        let history = try await fixture.repository.history(result.project.projectID, owner: result.project.owner)
        XCTAssertEqual(history.count, 3)
        let restored = try await service.rollback(context: result.context, to: fixture.project.revision)
        let restoredBytes = try await fixture.repository.read(restored.projectID, owner: restored.owner, revision: restored.revision, path: GameRelativePath("game.json"))
        XCTAssertEqual(try XCTUnwrap(JSONSerialization.jsonObject(with: restoredBytes) as? [String: Any])["speed"] as? Int, 180)
    }
    func testCancelFencesLateModelResponseBeforeAnyWrite() async throws {
        let fixture = try await Fixture(), provider = WaitingProvider(), service = fixture.service(provider)
        let task = Task { try await service.edit(goal: "Edit", context: fixture.context, sourcePaths: [GameRelativePath("game.json")], playtest: false) }
        try await provider.waitUntilStarted(); await service.cancel(projectID: fixture.context.projectID); await provider.release()
        do { _ = try await task.value; XCTFail("Expected fenced late response") } catch { XCTAssertEqual(error as? GameAuthoringError, .staleSession) }
        let current = try await fixture.repository.open(fixture.project.projectID, owner: fixture.project.owner)
        XCTAssertEqual(current.revision, fixture.project.revision)
        XCTAssertFalse(current.files.contains { $0.path.value == "late.txt" })
    }
    func testExternalEditDuringInferenceIsPreserved() async throws {
        let fixture = try await Fixture(), provider = WaitingProvider(), service = fixture.service(provider)
        let task = Task { try await service.edit(goal: "Edit", context: fixture.context, sourcePaths: [GameRelativePath("game.json")], playtest: false) }
        try await provider.waitUntilStarted()
        let manual = try await fixture.repository.commit(fixture.project.projectID, owner: fixture.project.owner, expectedRevision: fixture.project.revision, changes: [.write(GameRelativePath("manual.txt"), Data("keep manual".utf8))])
        await provider.release()
        do { _ = try await task.value; XCTFail("Expected stale model revision") } catch { XCTAssertEqual(error as? GameProjectError, .contextChanged(.revision)) }
        let current = try await fixture.repository.open(fixture.project.projectID, owner: fixture.project.owner)
        XCTAssertEqual(current, manual)
    }
    func testRepairLimitReturnsActionableFailureAndKeepsVersions() async throws {
        let fixture = try await Fixture(), service = fixture.service(RepairProvider())
        let result = try await service.edit(goal: "Edit", context: fixture.context, sourcePaths: [GameRelativePath("game.json")], maximumRepairs: 0, playtest: false)
        XCTAssertFalse(result.passed); XCTAssertEqual(result.revisions.count, 1)
        XCTAssertTrue(result.diagnostics.contains { $0.severity == .error })
        let history = try await fixture.repository.history(fixture.project.projectID, owner: fixture.project.owner)
        XCTAssertEqual(history.count, 2)
    }
}
