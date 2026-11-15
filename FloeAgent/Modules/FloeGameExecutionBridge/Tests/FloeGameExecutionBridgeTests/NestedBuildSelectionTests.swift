// SPDX-License-Identifier: MPL-2.0
import Foundation
import XCTest
import FloeGameCore
import FloeGameBuildKit
@testable import FloeGameExecutionBridge

private actor ExecutionRecordingExporter: GameBuildExporterPort {
    private var recorded: [GameBuildExporterRequest] = []

    func export(_ request: GameBuildExporterRequest) async throws -> GameBuildExporterResult {
        recorded.append(request)
        try FileManager.default.createDirectory(at: request.outputURL,
                                                withIntermediateDirectories: true)
        let entry = request.entryPoint ?? "index.html"
        try Data("<!doctype html><title>selected</title>".utf8)
            .write(to: request.outputURL.appendingPathComponent(entry))
        return .init(engine: request.engine, outputURL: request.outputURL,
                     entry: entry, producerID: "execution-nested-test")
    }

    func requests() -> [GameBuildExporterRequest] { recorded }
}

private struct ExecutionNestedFixture {
    let directory: ExecutionTemporaryDirectory
    let projectRoot: URL
    let context: GameProjectContext
    let stored: GameStoredProject
    let repository: FileGameProjectRepository

    static func make() async throws -> ExecutionNestedFixture {
        let directory = try ExecutionTemporaryDirectory()
        let projectRoot = directory.url.appendingPathComponent("project", isDirectory: true)
            .standardizedFileURL.resolvingSymlinksInPath()
        try FileManager.default.createDirectory(
            at: projectRoot.appendingPathComponent("games/a"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: projectRoot.appendingPathComponent("games/b"), withIntermediateDirectories: true)
        try Data("root story".utf8).write(to: projectRoot.appendingPathComponent("story.ink"))
        try Data("A".utf8).write(to: projectRoot.appendingPathComponent("games/a/story.ink"))
        try Data("B".utf8).write(to: projectRoot.appendingPathComponent("games/b/story.ink"))
        try Data(":: Start\nB\n".utf8)
            .write(to: projectRoot.appendingPathComponent("games/b/story.twee"))
        let repository = try FileGameProjectRepository(
            directory: directory.url.appendingPathComponent("repo", isDirectory: true))
        let id = UUID()
        let owner = GameProjectOwner.space(recordID: id)
        let created = try await repository.createProject(
            projectID: id, owner: owner, title: "Nested", engine: .ink)
        let stored = try await repository.importContents(
            from: projectRoot, into: id, owner: owner, expectedRevision: created.revision)
        let context = try GameProjectContext(
            projectID: id, owner: owner, rootURL: projectRoot,
            savedRevision: stored.revision, environmentID: "linux-guest")
        return .init(directory: directory, projectRoot: projectRoot,
                     context: context, stored: stored, repository: repository)
    }

    func service(records: String, context: @escaping @MainActor @Sendable () async throws -> GameProjectContext,
                 exporter: (any GameBuildExporterPort)?) throws -> GameExecutionBuildService {
        try GameExecutionBuildService(configuration: .init(
            projectID: self.context.projectID,
            repository: repository,
            recordsDirectory: directory.url.appendingPathComponent(records, isDirectory: true),
            currentContext: context,
            host: nil,
            ci: nil,
            sourcePublisher: nil,
            repositoryCoordinates: nil,
            exporter: exporter))
    }
}

final class NestedBuildSelectionTests: XCTestCase {
    func testCapabilityPlanInspectsTheSelectedRootAndRejectsAnotherEngine() async throws {
        let fixture = try await ExecutionNestedFixture.make()
        defer { fixture.directory.cleanup() }
        let currentContext = fixture.context
        let service = try fixture.service(records: "records-plan",
                                          context: { @MainActor in currentContext },
                                          exporter: nil)
        let selection = try GameBuildProjectSelection(
            context: fixture.context, engine: .ink,
            gameRoot: try GameRelativePath("games/a"))
        let plan = try await service.capabilityPlan(engine: .ink, selection: selection)
        XCTAssertEqual(plan.engine, .ink)
        XCTAssertTrue(plan.routes.contains(where: { $0.id == "ink-web" && $0.producer == .hostExporter }))
        do {
            _ = try await service.capabilityPlan(engine: .twine, selection: selection)
            XCTFail("a selection for ink must not plan twine")
        } catch let error as GameExecutionError {
            guard case .selectionInvalid(let detail) = error else {
                return XCTFail("wrong error: \(error)")
            }
            XCTAssertTrue(detail.contains("twine"))
        }
    }

    func testBuildForwardsTheValidatedSelectionToTheExporterAndRecord() async throws {
        let fixture = try await ExecutionNestedFixture.make()
        defer { fixture.directory.cleanup() }
        let exporter = ExecutionRecordingExporter()
        let currentContext = fixture.context
        let service = try fixture.service(records: "records-build",
                                          context: { @MainActor in currentContext },
                                          exporter: exporter)
        let selection = try GameBuildProjectSelection(
            context: fixture.context, engine: .ink,
            gameRoot: try GameRelativePath("games/a"))
        let outcome = try await service.build(.init(
            engine: .ink, selectedRouteIDs: ["ink-web"], providedTools: ["node-lts"],
            selection: selection))
        XCTAssertTrue(outcome.ready)
        XCTAssertEqual(outcome.record.gameRoot, "games/a")
        XCTAssertEqual(outcome.record.rootSelectionState, .nestedRoot)
        XCTAssertEqual(outcome.record.selectionSchemaVersion, 1)
        XCTAssertEqual(outcome.selection, selection)
        let recorded = await exporter.requests()
        let request = try XCTUnwrap(recorded.first)
        XCTAssertEqual(try XCTUnwrap(request.gameRoot), try GameRelativePath("games/a"))
        XCTAssertEqual(request.projectRoot.lastPathComponent, "source-folder")
        XCTAssertEqual(request.sourceRoot.lastPathComponent, "a")
        XCTAssertEqual(request.selectedSourceDigest, outcome.binding.selectedSourceDigest)
        let restored = try await service.restoredRecords()
        XCTAssertEqual(restored.count, 1)
        XCTAssertEqual(restored.first?.rootSelectionState, .nestedRoot)
    }

    func testStaleSelectionIsRejectedBeforeAnyRecordOrExporterSideEffect() async throws {
        let fixture = try await ExecutionNestedFixture.make()
        defer { fixture.directory.cleanup() }
        let selection = try GameBuildProjectSelection(
            context: fixture.context, engine: .ink,
            gameRoot: try GameRelativePath("games/a"))
        let moved = try GameProjectContext(
            projectID: fixture.context.projectID, owner: fixture.context.owner,
            rootURL: fixture.projectRoot,
            savedRevision: fixture.context.savedRevision + "-moved",
            environmentID: "linux-guest")
        let exporter = ExecutionRecordingExporter()
        let service = try fixture.service(records: "records-stale", context: { @MainActor in moved },
                                          exporter: exporter)
        do {
            _ = try await service.build(.init(
                engine: .ink, selectedRouteIDs: ["ink-web"], providedTools: ["node-lts"],
                selection: selection))
            XCTFail("expected stale selection rejection")
        } catch let error as GameExecutionError {
            guard case .selectionInvalid(let detail) = error else {
                return XCTFail("wrong error: \(error)")
            }
            XCTAssertTrue(detail.contains("revision"))
        }
        let restored = try await service.restoredRecords()
        XCTAssertTrue(restored.isEmpty)
        let recorded = await exporter.requests()
        XCTAssertTrue(recorded.isEmpty)
    }

    func testNilSelectionAndProjectRootSelectionRemainTruthful() async throws {
        let fixture = try await ExecutionNestedFixture.make()
        defer { fixture.directory.cleanup() }
        let nilSelectionExporter = ExecutionRecordingExporter()
        let currentContext = fixture.context
        let nilSelectionService = try fixture.service(
            records: "records-nil", context: { @MainActor in currentContext },
            exporter: nilSelectionExporter)
        let outcome = try await nilSelectionService.build(.init(
            engine: .ink, selectedRouteIDs: ["ink-web"], providedTools: ["node-lts"]))
        XCTAssertNil(outcome.record.gameRoot)
        XCTAssertNil(outcome.record.selectedSourceDigest)
        XCTAssertEqual(outcome.record.rootSelectionState, .projectRoot)
        let nilRecorded = await nilSelectionExporter.requests()
        let nilRequest = try XCTUnwrap(nilRecorded.first)
        XCTAssertNil(nilRequest.gameRoot)
        XCTAssertEqual(nilRequest.sourceRoot.standardizedFileURL,
                       nilRequest.projectRoot.standardizedFileURL)

        let selection = try GameBuildProjectSelection(
            context: fixture.context, engine: .ink, gameRoot: nil)
        let exporter = ExecutionRecordingExporter()
        let service = try fixture.service(records: "records-root",
                                          context: { @MainActor in currentContext },
                                          exporter: exporter)
        let rooted = try await service.build(.init(
            engine: .ink, selectedRouteIDs: ["ink-web"], providedTools: ["node-lts"],
            selection: selection))
        XCTAssertNil(rooted.record.gameRoot)
        XCTAssertEqual(rooted.record.rootSelectionState, .projectRoot)
        let recorded = await exporter.requests()
        let request = try XCTUnwrap(recorded.first)
        XCTAssertNil(request.gameRoot)
        XCTAssertEqual(request.sourceRoot.standardizedFileURL,
                       request.projectRoot.standardizedFileURL)
    }
}
