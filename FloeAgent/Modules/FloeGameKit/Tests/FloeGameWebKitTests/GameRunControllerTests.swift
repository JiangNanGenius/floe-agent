// SPDX-License-Identifier: MPL-2.0
import Foundation
import XCTest
import FloeGameCore
import FloeGameWebKit

private actor ContextHost: GameRunContextHost {
    var context: GameProjectContext
    init(_ context: GameProjectContext) { self.context = context }
    func currentContext(for captured: GameProjectContext) -> GameProjectContext { context }
    func replace(_ value: GameProjectContext) { context = value }
}
private actor PreparationHost: GameWebRunPreparationHost {
    let output: GamePreparedWebRun
    var waiting = false
    var continuation: CheckedContinuation<GamePreparedWebRun, any Error>?
    init(_ output: GamePreparedWebRun) { self.output = output }
    func prepare(_ request: GameWebRunRequest) async throws -> GamePreparedWebRun {
        try await withCheckedThrowingContinuation { continuation in self.continuation = continuation; waiting = true }
    }
    func cancel(_ request: GameWebRunRequest) {
        let pending = continuation; continuation = nil; pending?.resume(throwing: CancellationError())
    }
    func finish() { let pending = continuation; continuation = nil; pending?.resume(returning: output) }
    func waitUntilStarted() async throws {
        for _ in 0..<100 { if waiting { return }; try await Task.sleep(for: .milliseconds(10)) }
        throw GameProjectError.invalidContext
    }
}

@MainActor final class GameRunControllerTests: XCTestCase {
    func testCallerRequestIDKeepsStopScopedAndRejectsDuplicateLaunch() async throws {
        let (root, context, package) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let host = PreparationHost(package), controller = GameProjectRunController(contexts: ContextHost(context), preparation: host)
        let id = UUID(), task = Task { try await controller.run(context: context, engine: .phaser, requestID: id) }
        try await host.waitUntilStarted()
        XCTAssertEqual(controller.activeRunID, id)
        let foreignStopped = await controller.stop(runID: UUID())
        XCTAssertFalse(foreignStopped)
        XCTAssertEqual(controller.activeRunID, id)
        do { try await controller.run(context: context, engine: .phaser, requestID: id); XCTFail("duplicate ID") }
        catch GameWebPlayerError.staleRun { }
        let stopped = await controller.stop(runID: id)
        XCTAssertTrue(stopped)
        do { try await task.value; XCTFail("cancelled preparation") } catch is CancellationError { }
        XCTAssertEqual(controller.phase, .idle)
        XCTAssertNil(controller.player)
    }

    private func fixture() throws -> (URL, GameProjectContext, GamePreparedWebRun) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let source = root.appendingPathComponent("source")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try Data("<html><p>Contract fixture</p></html>".utf8).write(to: source.appendingPathComponent("index.html"))
        try Data(#"{"dependencies":{"phaser":"3.90.0"}}"#.utf8).write(to: source.appendingPathComponent("package.json"))
        let id = UUID(), context = try GameProjectContext(projectID: id, owner: .space(recordID: id), rootURL: source, savedRevision: "r1", environmentID: "existing-linux")
        let package = try GameWebArtifactPackage.build(source: context, engine: .phaser, entry: GameRelativePath("index.html"), to: root.appendingPathComponent("artifact"))
        return (root, context, .init(inspection: try GameProjectInspector().inspect(context: context), package: package))
    }
    func testStopCancelsOwnedPreparationAndCannotStartAPlayerLater() async throws {
        let (root, context, package) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let host = PreparationHost(package), controller = GameProjectRunController(contexts: ContextHost(context), preparation: host)
        let task = Task { try await controller.run(context: context, engine: .phaser) }
        try await host.waitUntilStarted()
        let stopped = await controller.stop(); XCTAssertTrue(stopped)
        do { try await task.value; XCTFail("Expected cancelled preparation") } catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertEqual(controller.phase, .idle); XCTAssertNil(controller.player); XCTAssertNil(controller.context)
    }
    func testRevisionDriftDuringBuildRejectsArtifactBeforeWebKitLaunch() async throws {
        let (root, context, package) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let host = PreparationHost(package), contexts = ContextHost(context)
        let controller = GameProjectRunController(contexts: contexts, preparation: host)
        let task = Task { try await controller.run(context: context, engine: .phaser) }
        try await host.waitUntilStarted()
        try await contexts.replace(GameProjectContext(projectID: context.projectID, owner: context.owner, rootURL: context.rootURL, savedRevision: "r2", environmentID: context.environmentID))
        await host.finish()
        do { try await task.value; XCTFail("Expected stale artifact") } catch { XCTAssertEqual(error as? GameProjectError, .contextChanged(.revision)) }
        XCTAssertNil(controller.player)
        guard case .failed = controller.phase else { return XCTFail("Expected actionable failed state") }
    }
}
