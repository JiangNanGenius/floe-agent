// SPDX-License-Identifier: MPL-2.0
import Foundation
import XCTest
import FloeGameCore
@testable import FloeGameBuildKit

private actor RecordingNestedExporter: GameBuildExporterPort {
    private var recordedRequests: [GameBuildExporterRequest] = []

    func export(_ request: GameBuildExporterRequest) async throws -> GameBuildExporterResult {
        recordedRequests.append(request)
        try FileManager.default.createDirectory(at: request.outputURL,
                                                withIntermediateDirectories: true)
        let entry = request.entryPoint ?? "index.html"
        try Data("<!doctype html><title>nested</title>".utf8)
            .write(to: request.outputURL.appendingPathComponent(entry))
        return .init(engine: request.engine, outputURL: request.outputURL,
                     entry: entry, producerID: "nested-test-exporter")
    }

    func requests() -> [GameBuildExporterRequest] { recordedRequests }
}

private struct NestedBuildFixture {
    let root: URL
    let projectRoot: URL
    let context: GameProjectContext
    let stored: GameStoredProject
    let repository: FileGameProjectRepository

    func cleanup() { try? FileManager.default.removeItem(at: root) }
}

final class GameNestedBuildSelectionTests: XCTestCase {
    private func makeFixture() async throws -> NestedBuildFixture {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("FloeNestedSelection-" + UUID().uuidString.lowercased(),
                                    isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let projectRoot = root.appendingPathComponent("project", isDirectory: true)
            .standardizedFileURL.resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: projectRoot.appendingPathComponent("games/a"),
                                                withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: projectRoot.appendingPathComponent("games/b"),
                                                withIntermediateDirectories: true)
        try Data("whole project".utf8).write(to: projectRoot.appendingPathComponent("README.md"))
        try Data("ROOT = 0\n".utf8)
            .write(to: projectRoot.appendingPathComponent("story.ink"))
        try Data("VAR A = 1\n".utf8)
            .write(to: projectRoot.appendingPathComponent("games/a/story.ink"))
        try Data("VAR B = 2\n".utf8)
            .write(to: projectRoot.appendingPathComponent("games/b/story.ink"))
        try Data(":: Start\nA\n".utf8)
            .write(to: projectRoot.appendingPathComponent("games/b/story.twee"))
        try Data("{\"dependencies\":{\"phaser\":\"3.80.1\"}}".utf8)
            .write(to: projectRoot.appendingPathComponent("games/b/package.json"))

        let repository = try FileGameProjectRepository(
            directory: root.appendingPathComponent("repo", isDirectory: true))
        let id = UUID()
        let owner = GameProjectOwner.space(recordID: id)
        let created = try await repository.createProject(projectID: id, owner: owner,
                                                         title: "Nested", engine: nil)
        let stored = try await repository.importContents(
            from: projectRoot, into: id, owner: owner, expectedRevision: created.revision)
        let context = try GameProjectContext(
            projectID: id, owner: owner, rootURL: projectRoot,
            savedRevision: stored.revision, environmentID: "linux-guest")
        return .init(root: root, projectRoot: projectRoot, context: context,
                     stored: stored, repository: repository)
    }

    private func plan(_ engine: GameEngineID, context: GameProjectContext) throws
        -> GameBuildCapabilityPlan {
        let inspection = GameProjectInspection(
            rootURL: context.rootURL, context: context,
            candidates: [GameEngineCandidate(engine: engine, evidence: [])],
            inspectedPaths: [])
        return try GameBuildCapabilityRegistry.plan(for: engine, inspection: inspection)
    }

    private func records(_ fixture: NestedBuildFixture, _ name: String) throws
        -> GameBuildRecordStore {
        try GameBuildRecordStore(
            directory: fixture.root.appendingPathComponent(name, isDirectory: true))
    }

    // MARK: - Selection capture and rejection

    func testSelectionCapturesOriginalContextAndRejectsWrongContextAndEngine() async throws {
        let fixture = try await makeFixture()
        defer { fixture.cleanup() }
        let root = try GameRelativePath("games/a")
        let selection = try GameBuildProjectSelection(
            context: fixture.context, engine: .ink, gameRoot: root)
        XCTAssertEqual(selection.projectID, fixture.context.projectID)
        XCTAssertEqual(selection.owner, fixture.context.owner)
        XCTAssertEqual(selection.environmentID, "linux-guest")
        XCTAssertEqual(selection.projectRootURL, fixture.context.rootURL)
        XCTAssertEqual(selection.revision, fixture.context.savedRevision)
        XCTAssertEqual(selection.gameRoot, root)
        XCTAssertEqual(selection.selectedRootURL,
                       fixture.projectRoot.appendingPathComponent("games/a"))
        XCTAssertNoThrow(try selection.validate(against: fixture.context))
        XCTAssertThrowsError(try selection.validate(engine: .twine)) { error in
            XCTAssertEqual(error as? GameBuildSelectionError,
                           .wrongEngine(expected: .twine, actual: .ink))
        }

        let otherID = UUID()
        let otherProject = try GameProjectContext(
            projectID: otherID, owner: .space(recordID: otherID),
            rootURL: fixture.projectRoot, savedRevision: fixture.context.savedRevision,
            environmentID: "linux-guest")
        XCTAssertThrowsError(try selection.validate(against: otherProject)) { error in
            XCTAssertEqual(error as? GameBuildSelectionError, .staleContext(.project))
        }
        let otherEnvironment = try GameProjectContext(
            projectID: fixture.context.projectID, owner: fixture.context.owner,
            rootURL: fixture.projectRoot, savedRevision: fixture.context.savedRevision,
            environmentID: "another-guest")
        XCTAssertThrowsError(try selection.validate(against: otherEnvironment)) { error in
            XCTAssertEqual(error as? GameBuildSelectionError, .staleContext(.environment))
        }
        let otherRevision = try GameProjectContext(
            projectID: fixture.context.projectID, owner: fixture.context.owner,
            rootURL: fixture.projectRoot,
            savedRevision: fixture.context.savedRevision + "-moved",
            environmentID: "linux-guest")
        XCTAssertThrowsError(try selection.validate(against: otherRevision)) { error in
            XCTAssertEqual(error as? GameBuildSelectionError, .staleContext(.revision))
        }
    }

    func testSelectionRejectsMissingFileSymlinkAndTraversalRoots() async throws {
        let fixture = try await makeFixture()
        defer { fixture.cleanup() }
        XCTAssertThrowsError(try GameRelativePath("../escape")) { error in
            XCTAssertEqual(error as? GameProjectError, .invalidRelativePath)
        }
        let missing = try GameRelativePath("games/missing")
        XCTAssertThrowsError(try GameBuildProjectSelection(
            context: fixture.context, engine: .ink, gameRoot: missing)) { error in
            XCTAssertEqual(error as? GameBuildSelectionError, .rootMissing("games/missing"))
        }

        let file = try GameRelativePath("games/not-a-directory")
        try Data("file".utf8).write(
            to: fixture.projectRoot.appendingPathComponent("games/not-a-directory"))
        XCTAssertThrowsError(try GameBuildProjectSelection(
            context: fixture.context, engine: .ink, gameRoot: file)) { error in
            XCTAssertEqual(error as? GameBuildSelectionError,
                           .rootNotDirectory("games/not-a-directory"))
        }

        let link = fixture.projectRoot.appendingPathComponent("games/link")
        try FileManager.default.createSymbolicLink(
            atPath: link.path,
            withDestinationPath: fixture.projectRoot.appendingPathComponent("games/a").path)
        let linked = try GameRelativePath("games/link")
        XCTAssertThrowsError(try GameBuildProjectSelection(
            context: fixture.context, engine: .ink, gameRoot: linked)) { error in
            XCTAssertEqual(error as? GameBuildSelectionError, .symbolicLink("games/link"))
        }

        // A captured root replaced by a link is rejected by validate().
        let selection = try GameBuildProjectSelection(
            context: fixture.context, engine: .ink,
            gameRoot: try GameRelativePath("games/a"))
        let captured = fixture.projectRoot.appendingPathComponent("games/a")
        let backup = fixture.projectRoot.appendingPathComponent("games/a-backup")
        try FileManager.default.moveItem(at: captured, to: backup)
        try FileManager.default.createSymbolicLink(
            atPath: captured.path, withDestinationPath: backup.path)
        XCTAssertThrowsError(try selection.validate(against: fixture.context)) { error in
            XCTAssertEqual(error as? GameBuildSelectionError, .symbolicLink("games/a"))
        }
    }

    func testSameEngineNestedRootsProduceDifferentDigestsAndDispatchInputs() async throws {
        let fixture = try await makeFixture()
        defer { fixture.cleanup() }
        let aRoot = try GameRelativePath("games/a"), bRoot = try GameRelativePath("games/b")
        let a = try GameBuildProjectSelection(
            context: fixture.context, engine: .ink, gameRoot: aRoot)
        let b = try GameBuildProjectSelection(
            context: fixture.context, engine: .ink, gameRoot: bRoot)
        let aDigest = try XCTUnwrap(try a.selectedSourceDigest(from: fixture.stored.files))
        let bDigest = try XCTUnwrap(try b.selectedSourceDigest(from: fixture.stored.files))
        XCTAssertNotEqual(aDigest, bDigest)

        let base = try GameBuildRepositorySnapshot(
            owner: "floe", repository: "games", branch: "main",
            commitSHA: String(repeating: "b", count: 40),
            treeSHA: String(repeating: "c", count: 40),
            manifestDigest: GameBuildCoordinator.sourceDigest(of: fixture.stored),
            revision: fixture.stored.revision,
            gameRoot: aRoot.value, selectedSourceDigest: aDigest)
        let inputs = GameBuildSourceTransport.repositorySnapshot(base)
            .dispatchInputs(engine: .ink, engineVersion: nil)
        XCTAssertEqual(inputs["game_root"], "games/a")
        XCTAssertEqual(inputs["selected_source_sha256"], aDigest)

        let wrong = try GameBuildRepositorySnapshot(
            owner: "floe", repository: "games", branch: "main",
            commitSHA: String(repeating: "b", count: 40),
            treeSHA: String(repeating: "c", count: 40),
            manifestDigest: GameBuildCoordinator.sourceDigest(of: fixture.stored),
            revision: fixture.stored.revision,
            gameRoot: bRoot.value, selectedSourceDigest: bDigest)
        let wrongTransport = GameBuildSourceTransport.repositorySnapshot(wrong)
        let binding = GameBuildBinding(
            id: UUID(), projectID: fixture.context.projectID,
            revision: fixture.stored.revision,
            sourceDigest: GameBuildCoordinator.sourceDigest(of: fixture.stored),
            engine: .ink, engineVersion: nil, sourceRoot: fixture.projectRoot,
            owner: fixture.context.owner, environmentID: "linux-guest",
            gameRoot: aRoot, selectedSourceDigest: aDigest)
        XCTAssertThrowsError(try wrongTransport.validated(
            for: binding, allowed: [.repositorySnapshot])) { error in
            XCTAssertEqual(error as? GameBuildTransportError,
                           .provenanceInvalid("source transport does not bind the selected game root"))
        }
    }

    func testExporterLayoutCannotClaimAWholeProjectAsNestedSubtree() async throws {
        let fixture = try await makeFixture()
        defer { fixture.cleanup() }
        let request = GameBuildExporterRequest(
            engine: .ink, projectID: fixture.context.projectID,
            owner: fixture.context.owner, environmentID: "linux-guest",
            revision: fixture.stored.revision,
            sourceDigest: GameBuildCoordinator.sourceDigest(of: fixture.stored),
            sourceRoot: fixture.projectRoot, outputURL: fixture.root.appendingPathComponent("out"),
            component: "narrative-ink", entryPoint: "index.html", engineVersion: nil,
            projectRoot: fixture.projectRoot,
            gameRoot: try GameRelativePath("games/a"),
            selectedSourceDigest: String(repeating: "a", count: 64))
        XCTAssertThrowsError(try request.validateSelectionLayout()) { error in
            guard let selectionError = error as? GameBuildSelectionError,
                  case .selectionChanged = selectionError else {
                return XCTFail("expected selectionChanged, got \(error)")
            }
        }
    }

    // MARK: - Coordinator integration over real temporary files

    func testHostExportBuildsOnlyTheSelectedSubtreeButArchivesTheWholeProject() async throws {
        let fixture = try await makeFixture()
        defer { fixture.cleanup() }
        let aRoot = try GameRelativePath("games/a")
        let bRoot = try GameRelativePath("games/b")
        let selectionA = try GameBuildProjectSelection(
            context: fixture.context, engine: .ink, gameRoot: aRoot)
        let selectionB = try GameBuildProjectSelection(
            context: fixture.context, engine: .ink, gameRoot: bRoot)
        let capabilityPlan = try plan(.ink, context: fixture.context)
        let aDigest = try XCTUnwrap(try selectionA.selectedSourceDigest(from: fixture.stored.files))
        let bDigest = try XCTUnwrap(try selectionB.selectedSourceDigest(from: fixture.stored.files))

        let recordsA = try records(fixture, "records-a")
        let exporterA = RecordingNestedExporter()
        let coordinatorA = GameBuildCoordinator(hostPort: nil, ciPort: nil, records: recordsA)
        let outcomeA = try await coordinatorA.run(
            plan: capabilityPlan, source: fixture.context, repository: fixture.repository,
            provided: ["node-lts"], exporter: exporterA, selectedRouteIDs: ["ink-web"],
            selection: selectionA)
        XCTAssertTrue(outcomeA.ready)
        XCTAssertEqual(outcomeA.record.gameRoot, "games/a")
        XCTAssertEqual(outcomeA.record.rootSelectionState, .nestedRoot)
        XCTAssertEqual(outcomeA.record.selectionSchemaVersion, 1)
        XCTAssertEqual(outcomeA.binding.selectedSourceDigest, aDigest)
        let recordedA = await exporterA.requests()
        let requestA = try XCTUnwrap(recordedA.first)
        XCTAssertEqual(try XCTUnwrap(requestA.gameRoot), aRoot)
        XCTAssertEqual(try XCTUnwrap(requestA.selectedSourceDigest), aDigest)
        XCTAssertEqual(requestA.projectRoot.lastPathComponent, "source-folder")
        XCTAssertEqual(requestA.sourceRoot.lastPathComponent, "a")
        XCTAssertEqual(requestA.sourceRoot.deletingLastPathComponent().lastPathComponent, "games")
        XCTAssertEqual(requestA.projectRoot.appendingPathComponent("games/a", isDirectory: true).standardizedFileURL,
                       requestA.sourceRoot.standardizedFileURL)

        // The preserved source archive is explicitly the whole project.
        let recordsDirectory = await recordsA.directory
        let aArtifactRoot = recordsDirectory.appendingPathComponent(
            "artifacts-" + outcomeA.binding.id.uuidString.lowercased())
        let archive = aArtifactRoot.appendingPathComponent("ink-source.zip")
        XCTAssertTrue(FileManager.default.fileExists(atPath: archive.path))
        let entries = try GameArchiveExchange().inspect(archive: archive).entries.map(\.path)
        XCTAssertTrue(entries.contains("games/a/story.ink"))
        XCTAssertTrue(entries.contains("games/b/story.ink"))
        XCTAssertTrue(entries.contains("README.md"))

        let recordsB = try records(fixture, "records-b")
        let exporterB = RecordingNestedExporter()
        let coordinatorB = GameBuildCoordinator(hostPort: nil, ciPort: nil, records: recordsB)
        let outcomeB = try await coordinatorB.run(
            plan: capabilityPlan, source: fixture.context, repository: fixture.repository,
            provided: ["node-lts"], exporter: exporterB, selectedRouteIDs: ["ink-web"],
            selection: selectionB)
        let recordedB = await exporterB.requests()
        let requestB = try XCTUnwrap(recordedB.first)
        XCTAssertEqual(outcomeB.record.gameRoot, "games/b")
        XCTAssertEqual(try XCTUnwrap(requestB.gameRoot), bRoot)
        XCTAssertEqual(try XCTUnwrap(requestB.selectedSourceDigest), bDigest)
        XCTAssertNotEqual(aDigest, bDigest)
        XCTAssertNotEqual(requestA.sourceRoot.path, requestB.sourceRoot.path)
    }

    func testProjectRootSelectionAndNilSelectionStayTruthful() async throws {
        let fixture = try await makeFixture()
        defer { fixture.cleanup() }
        // The project root itself is not an ink root, so a nil selection still
        // means "project root" and is reported as such without guessing.
        let capabilityPlan = try plan(.ink, context: fixture.context)
        let records = try records(fixture, "records-project")
        let exporter = RecordingNestedExporter()
        let coordinator = GameBuildCoordinator(hostPort: nil, ciPort: nil, records: records)
        let outcome = try await coordinator.run(
            plan: capabilityPlan, source: fixture.context, repository: fixture.repository,
            provided: ["node-lts"], exporter: exporter, selectedRouteIDs: ["ink-web"])
        XCTAssertNil(outcome.record.gameRoot)
        XCTAssertNil(outcome.record.selectedSourceDigest)
        XCTAssertEqual(outcome.record.rootSelectionState, .projectRoot)
        let recorded = await exporter.requests()
        let request = try XCTUnwrap(recorded.first)
        XCTAssertNil(request.gameRoot)
        XCTAssertEqual(request.sourceRoot.standardizedFileURL, request.projectRoot.standardizedFileURL)

        let nilRoot = try GameBuildProjectSelection(
            context: fixture.context, engine: .ink, gameRoot: nil)
        XCTAssertNil(try nilRoot.selectedSourceDigest(from: fixture.stored.files))
    }

    func testCoordinatorRejectsStaleSelectionAndWrongEngineBeforeAnyRecord() async throws {
        let fixture = try await makeFixture()
        defer { fixture.cleanup() }
        let selection = try GameBuildProjectSelection(
            context: fixture.context, engine: .ink,
            gameRoot: try GameRelativePath("games/a"))
        let moved = try GameProjectContext(
            projectID: fixture.context.projectID, owner: fixture.context.owner,
            rootURL: fixture.projectRoot,
            savedRevision: fixture.context.savedRevision + "-moved",
            environmentID: "linux-guest")
        let capabilityPlan = try plan(.ink, context: moved)
        let records = try records(fixture, "records-stale")
        let exporter = RecordingNestedExporter()
        let coordinator = GameBuildCoordinator(hostPort: nil, ciPort: nil, records: records)
        do {
            _ = try await coordinator.run(
                plan: capabilityPlan, source: moved, repository: fixture.repository,
                provided: ["node-lts"], exporter: exporter, selectedRouteIDs: ["ink-web"],
                selection: selection)
            XCTFail("expected stale selection rejection")
        } catch GameBuildError.selectionInvalid(let detail) {
            XCTAssertTrue(detail.contains("revision"))
        }
        let list = try await records.list()
        XCTAssertTrue(list.isEmpty, "a stale selection must not write a record")
        let requests = await exporter.requests()
        XCTAssertTrue(requests.isEmpty)

        // Wrong engine: the same captured root is ink, not twine.
        let twinePlan = try plan(.twine, context: fixture.context)
        let records2 = try self.records(fixture, "records-wrong-engine")
        let exporter2 = RecordingNestedExporter()
        let coordinator2 = GameBuildCoordinator(hostPort: nil, ciPort: nil, records: records2)
        do {
            _ = try await coordinator2.run(
                plan: twinePlan, source: fixture.context, repository: fixture.repository,
                provided: ["node-lts"], exporter: exporter2, selectedRouteIDs: ["twine-web"],
                selection: selection)
            XCTFail("expected wrong engine rejection")
        } catch GameBuildError.selectionInvalid(let detail) {
            XCTAssertTrue(detail.contains("twine"))
        }
        let list2 = try await records2.list()
        XCTAssertTrue(list2.isEmpty)
    }

    // MARK: - Provenance and legacy records

    func testProvenanceRejectsWrongRootAndLegacyNestedClaims() async throws {
        let fixture = try await makeFixture()
        defer { fixture.cleanup() }
        let root = try GameRelativePath("games/a")
        let selection = try GameBuildProjectSelection(
            context: fixture.context, engine: .ink, gameRoot: root)
        let digest = try XCTUnwrap(try selection.selectedSourceDigest(from: fixture.stored.files))
        let binding = GameBuildBinding(
            id: UUID(), projectID: fixture.context.projectID,
            revision: fixture.stored.revision,
            sourceDigest: GameBuildCoordinator.sourceDigest(of: fixture.stored),
            engine: .ink, engineVersion: nil, sourceRoot: fixture.projectRoot,
            owner: fixture.context.owner, environmentID: "linux-guest",
            gameRoot: root, selectedSourceDigest: digest)
        let artifact = GameBuildProvenanceArtifact(sha256: String(repeating: "d", count: 64),
                                                   bytes: 12)
        let correct = GameBuildProvenance(
            sourceSHA256: binding.sourceDigest, sourceRevision: binding.revision,
            engine: "ink", template: "floe-game-build-script-web",
            sourceTransport: "repositorySnapshot", artifacts: ["ink-web.zip": artifact],
            selectionSchemaVersion: 1, gameRoot: "games/a",
            selectedSourceSHA256: digest)
        XCTAssertNoThrow(try correct.verify(against: binding))
        var wrongRoot = correct
        wrongRoot = GameBuildProvenance(
            sourceSHA256: binding.sourceDigest, sourceRevision: binding.revision,
            engine: "ink", template: "floe-game-build-script-web",
            sourceTransport: "repositorySnapshot", artifacts: ["ink-web.zip": artifact],
            selectionSchemaVersion: 1, gameRoot: "games/b",
            selectedSourceSHA256: digest)
        XCTAssertThrowsError(try wrongRoot.verify(against: binding))
        let legacy = GameBuildProvenance(
            sourceSHA256: binding.sourceDigest, sourceRevision: binding.revision,
            engine: "ink", template: "floe-game-build-script-web",
            sourceTransport: "repositorySnapshot", artifacts: ["ink-web.zip": artifact],
            selectionSchemaVersion: 0, gameRoot: "", selectedSourceSHA256: "")
        XCTAssertThrowsError(try legacy.verify(against: binding))

        let projectBinding = GameBuildBinding(
            id: UUID(), projectID: fixture.context.projectID,
            revision: fixture.stored.revision,
            sourceDigest: GameBuildCoordinator.sourceDigest(of: fixture.stored),
            engine: .ink, engineVersion: nil, sourceRoot: fixture.projectRoot,
            owner: fixture.context.owner, environmentID: "linux-guest")
        let legacyProject = GameBuildProvenance(
            sourceSHA256: projectBinding.sourceDigest, sourceRevision: projectBinding.revision,
            engine: "ink", template: "floe-game-build-script-web",
            sourceTransport: "repositorySnapshot", artifacts: ["ink-web.zip": artifact],
            selectionSchemaVersion: 0, gameRoot: "", selectedSourceSHA256: "")
        XCTAssertNoThrow(try legacyProject.verify(against: projectBinding))
    }

    func testOldDurableRecordIsNeverRelabelledAsAValidRootSelection() async throws {
        let oldJSON = """
        {
          "version": 1,
          "buildID": "00000000-0000-0000-0000-000000000001",
          "projectID": "00000000-0000-0000-0000-000000000002",
          "revision": "rev-old",
          "sourceDigest": "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
          "engine": "ink",
          "templateID": "floe-game-build-script-web",
          "state": "succeeded",
          "jobID": null,
          "artifacts": []
        }
        """
        let decoded = try JSONDecoder().decode(
            GameBuildRecord.self, from: Data(oldJSON.utf8))
        XCTAssertNil(decoded.selectionSchemaVersion)
        XCTAssertNil(decoded.gameRoot)
        XCTAssertEqual(decoded.rootSelectionState, .legacyUnverified)

        let newProjectRoot = GameBuildRecord(
            version: 1, buildID: "new", projectID: "project", revision: "rev-new",
            sourceDigest: String(repeating: "a", count: 64), engine: "ink",
            templateID: "floe-game-build-script-web", state: .succeeded, jobID: nil,
            artifacts: [], error: nil, selectionSchemaVersion: 1)
        XCTAssertEqual(newProjectRoot.rootSelectionState, .projectRoot)
        let newNested = GameBuildRecord(
            version: 1, buildID: "new2", projectID: "project", revision: "rev-new",
            sourceDigest: String(repeating: "a", count: 64), engine: "ink",
            templateID: "floe-game-build-script-web", state: .succeeded, jobID: nil,
            artifacts: [], error: nil, gameRoot: "games/a",
            selectedSourceDigest: String(repeating: "b", count: 64),
            selectionSchemaVersion: 1)
        XCTAssertEqual(newNested.rootSelectionState, .nestedRoot)
    }

    func testCIAdapterRejectsAProvenanceRecordFromAnotherNestedRoot() async throws {
        let fixture = try await makeFixture()
        defer { fixture.cleanup() }
        let root = try GameRelativePath("games/a")
        let selection = try GameBuildProjectSelection(
            context: fixture.context, engine: .ink, gameRoot: root)
        let digest = try XCTUnwrap(try selection.selectedSourceDigest(from: fixture.stored.files))
        let manifest = GameBuildCoordinator.sourceDigest(of: fixture.stored)
        let template = try XCTUnwrap(GameCIWorkflowTemplates.template(for: .ink))
        let commit = String(repeating: "b", count: 40)
        let snapshot = try GameBuildRepositorySnapshot(
            owner: "floe", repository: "games", branch: "floe/run-1",
            commitSHA: commit, treeSHA: String(repeating: "c", count: 40),
            manifestDigest: manifest, revision: fixture.stored.revision,
            gameRoot: root.value, selectedSourceDigest: digest)
        let source = GameBuildSourceTransport.repositorySnapshot(snapshot)
        let inputs = source.dispatchInputs(engine: .ink, engineVersion: nil)
        let targets = try template.selection(
            forRequestedArtifacts: ["ink-web.zip"], inputs: inputs)
        let web = Data("web".utf8)
        let provenance = GameBuildProvenance(
            sourceSHA256: manifest, sourceRevision: fixture.stored.revision,
            engine: "ink", template: template.id,
            sourceTransport: "repositorySnapshot",
            artifacts: ["ink-web.zip": .init(sha256: GameDataDigest.hex(web), bytes: web.count)],
            targets: targets.targetIDs, artifactPrefix: "ink",
            selectionSchemaVersion: 1, gameRoot: "games/b",
            selectedSourceSHA256: digest)
        let bytes = try JSONEncoder().encode(provenance)
        let transport = NestedCITransport(
            workflow: .init(id: 7, name: "floe",
                            path: ".github/workflows/" + template.fileName),
            runID: 42, commit: commit, branch: "floe/run-1",
            artifactsByRun: [42: [
                .init(id: 1001, name: "floe-build-provenance", sizeInBytes: Int64(bytes.count),
                      expired: false),
                .init(id: 1002, name: "ink-web.zip", sizeInBytes: Int64(web.count),
                      expired: false, digest: "sha256:" + GameDataDigest.hex(web)),
            ]],
            bytesByArtifact: [1001: bytes, 1002: web])
        let adapter = GitHubActionsBuildCIAdapter(
            transport: transport, tokens: NestedTokenProvider(value: "test-token"),
            repository: try GameBuildRepositoryReference(
                owner: "floe", repository: "games", branch: "floe/run-1"),
            expectedArtifacts: ["ink-web.zip"])
        _ = try await adapter.dispatch(template: template, source: source,
                                       engineVersion: nil, targets: targets)
        let dispatched = await transport.inputs
        XCTAssertEqual(dispatched["game_root"], "games/a")
        XCTAssertEqual(dispatched["selected_source_sha256"], digest)
        let wrongRootStatus = try await adapter.status(.init(jobID: "42"))
        if case .failed = wrongRootStatus.state {
            // Expected: the provenance names a different nested root.
        } else {
            XCTFail("wrong-root CI provenance must not report success")
        }
    }

    func testSnapshotAndArtifactReferenceRefuseUnpairedSelection() throws {
        let files = [GameProjectFile(path: try GameRelativePath("games/a/story.ink"),
                                     sha256: String(repeating: "a", count: 64),
                                     bytes: 4, executable: false)]
        let digest = try XCTUnwrap(try GameBuildSelectionSupport.digest(
            of: files, under: try GameRelativePath("games/a")))
        let root = URL(fileURLWithPath: "/tmp/floe-nested-project")
        XCTAssertNoThrow(try GameBuildSourceSnapshot(
            rootURL: root, files: files, directories: [], digest: String(repeating: "b", count: 64),
            revision: "rev", engine: .ink, gameRoot: "games/a",
            selectedSourceDigest: digest))
        XCTAssertThrowsError(try GameBuildSourceSnapshot(
            rootURL: root, files: files, directories: [], digest: String(repeating: "b", count: 64),
            revision: "rev", engine: .ink, gameRoot: "games/a",
            selectedSourceDigest: String(repeating: "c", count: 64)))
        XCTAssertThrowsError(try GameBuildSourceSnapshot(
            rootURL: root, files: files, directories: [], digest: String(repeating: "b", count: 64),
            revision: "rev", engine: .ink, selectedSourceDigest: digest))
        XCTAssertThrowsError(try GameBuildRemoteArtifactReference(
            owner: "floe", repository: "games", runID: 1, artifactID: 2,
            name: "source.zip", sha256: String(repeating: "a", count: 64), bytes: 4,
            revision: "rev", sourceDigest: String(repeating: "b", count: 64),
            gameRoot: "games/a"))
    }

private struct NestedTokenProvider: GameBuildGitHubTokenProvider {
    let value: String?
    func token() async throws -> String? { value }
}

private actor NestedCITransport: GameBuildGitHubActionsTransport {
    let workflow: GameBuildCIWorkflowRef
    let runID: Int64
    let commit: String
    let branch: String
    let artifactsByRun: [Int64: [GameBuildCIArtifact]]
    let bytesByArtifact: [Int64: Data]
    private(set) var inputs: [String: String] = [:]
    private(set) var cancelled: [Int64] = []

    init(workflow: GameBuildCIWorkflowRef, runID: Int64, commit: String, branch: String,
         artifactsByRun: [Int64: [GameBuildCIArtifact]], bytesByArtifact: [Int64: Data]) {
        self.workflow = workflow
        self.runID = runID
        self.commit = commit
        self.branch = branch
        self.artifactsByRun = artifactsByRun
        self.bytesByArtifact = bytesByArtifact
    }

    func workflows(owner: String, repository: String, token: String)
        async throws -> [GameBuildCIWorkflowRef] { [workflow] }

    func workflowRuns(owner: String, repository: String, workflowID: Int64,
                      branch: String, event: String, token: String)
        async throws -> [GameBuildCIRun] {
        [.init(id: runID, workflowID: workflow.id, status: "completed",
               conclusion: "success", headSHA: commit, headBranch: branch,
               event: event, createdAt: Date(), htmlURL: nil)]
    }

    func run(owner: String, repository: String, runID: Int64, token: String)
        async throws -> GameBuildCIRun {
        .init(id: runID, workflowID: workflow.id, status: "completed",
              conclusion: "success", headSHA: commit, headBranch: branch,
              event: "workflow_dispatch", createdAt: Date(), htmlURL: nil)
    }

    func artifacts(owner: String, repository: String, runID: Int64, token: String)
        async throws -> [GameBuildCIArtifact] { artifactsByRun[runID] ?? [] }

    func downloadArtifact(owner: String, repository: String, runID: Int64,
                          artifactID: Int64, token: String, maximumBytes: Int)
        async throws -> Data {
        guard let data = bytesByArtifact[artifactID], data.count <= maximumBytes else {
            throw GameBuildCIError.artifact("missing test artifact")
        }
        return data
    }

    func triggerDispatch(owner: String, repository: String, workflowID: Int64,
                         ref: String, inputs: [String: String], token: String)
        async throws -> GameBuildCITrigger {
        self.inputs = inputs
        return .init(runID: runID, htmlURL: nil)
    }

    func cancelRun(owner: String, repository: String, runID: Int64, token: String)
        async throws { cancelled.append(runID) }
}
}
