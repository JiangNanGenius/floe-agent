// SPDX-License-Identifier: MPL-2.0
import Foundation
import Testing
import FloeGameCore
import FloeGameBuildKit
import FloeGameRunKit
@testable import FloeGameExecutionBridge

private actor RecordingSelectionPublisher: GameBuildSourcePublisherPort {
    struct Error: Swift.Error {}
    private(set) var snapshot: GameBuildSourceSnapshot?
    private(set) var branch: String?
    private var overrideGameRoot: String?
    private var overrideSelected: String?

    func setOverride(gameRoot: String?, selected: String?) {
        overrideGameRoot = gameRoot
        overrideSelected = selected
    }

    func publish(_ snapshot: GameBuildSourceSnapshot,
                 owner: String, repository: String, branch: String) async throws
        -> GameBuildRepositorySnapshot {
        self.snapshot = snapshot
        self.branch = branch
        return try .init(
            owner: owner, repository: repository, branch: branch,
            commitSHA: String(repeating: "b", count: 40),
            treeSHA: String(repeating: "c", count: 40),
            manifestDigest: snapshot.digest, revision: snapshot.revision,
            gameRoot: overrideGameRoot ?? snapshot.gameRoot,
            selectedSourceDigest: overrideSelected ?? snapshot.selectedSourceDigest)
    }

    func verifyExistingArtifact(_ reference: GameBuildRemoteArtifactReference) async throws
        -> GameBuildArtifactIdentity {
        throw GameBuildTransportError.artifactMissing
    }
}

private struct SelectionFixture {
    let root: URL
    let prepared: URL
    let output: URL
    let context: GameProjectContext
    let selection: GameRunSourceSelection
    let webZIP: Data
}

@Suite("Runtime CI original selection")
struct RuntimeCIOriginalSelectionTests {
    private func makeFixture() async throws -> SelectionFixture {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("floe-runtime-ci-" + UUID().uuidString.lowercased(),
                                    isDirectory: true)
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("games/a/assets"),
            withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("games/b"), withIntermediateDirectories: true)
        try Data("<!doctype html><title>a</title>".utf8)
            .write(to: root.appendingPathComponent("games/a/index.html"))
        try Data("console.log('a')".utf8)
            .write(to: root.appendingPathComponent("games/a/assets/game.js"))
        try Data(#"{"dependencies":{"phaser":"3.80.0"}}"#.utf8)
            .write(to: root.appendingPathComponent("games/a/package.json"))
        try Data("<!doctype html><title>b</title>".utf8)
            .write(to: root.appendingPathComponent("games/b/index.html"))
        try Data("outer".utf8).write(to: root.appendingPathComponent("README.md"))
        let projectID = UUID()
        let context = try GameProjectContext(
            projectID: projectID, owner: .space(recordID: projectID),
            rootURL: root, savedRevision: "rev-1", environmentID: "linux-guest")
        let inventory = try GameRunProjectInventory.scan(context: context)
        let selected = root.appendingPathComponent("games/a")
        let prepared = root.appendingPathComponent("prepared-selected")
        _ = try GameWorkspaceTree.copyTree(from: selected, to: prepared)
        let manifest = try GameWorkspaceTree.manifest(rootURL: prepared)
        let gameRoot = try GameRelativePath("games/a")
        let selectedDigest = try inventory.selectedSourceDigest(gameRoot: gameRoot)
        let selection = try GameRunSourceSelection(
            context: context, engine: .phaser, gameRoot: gameRoot,
            inventory: inventory,
            prepared: try GameRunPreparedSource(
                digest: manifest.digest, transform: .byteIdenticalCopy,
                transformID: nil, relation: "equals-selected-source"))
        let output = root.appendingPathComponent("out")
        try FileManager.default.createDirectory(at: output.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        let web = root.appendingPathComponent("web")
        try FileManager.default.createDirectory(at: web, withIntermediateDirectories: true)
        try Data("<!doctype html><title>built</title>".utf8)
            .write(to: web.appendingPathComponent("index.html"))
        let webZIP = try ExecutionTestFixtures.zip(directory: web)
        #expect(manifest.digest == selectedDigest)
        return .init(root: root, prepared: prepared, output: output,
                     context: context, selection: selection, webZIP: webZIP)
    }

    private func makeTransport(fixture: SelectionFixture,
                               jobID: String = "42",
                               selectionSchema: Int = 1,
                               gameRoot: String? = "games/a",
                               selectedDigest: String? = nil,
                               schemaVersion: Int = 2)
        throws -> (FakeGitHubTransport, GameBuildProvenance) {
        let wrapperDir = fixture.root.appendingPathComponent("wrapper")
        try FileManager.default.createDirectory(at: wrapperDir, withIntermediateDirectories: true)
        try fixture.webZIP.write(to: wrapperDir.appendingPathComponent("phaser-web.zip"))
        let wrapper = try ExecutionTestFixtures.zip(directory: wrapperDir)
        let provenance = GameBuildProvenance(
            sourceSHA256: fixture.selection.wholeProjectDigest,
            sourceRevision: "rev-1", engine: "phaser",
            template: "floe-game-build-script-web",
            sourceTransport: "repository",
            artifacts: ["phaser-web.zip": .init(
                sha256: GameDigest.sha256(fixture.webZIP), bytes: fixture.webZIP.count)],
            targets: ["web"], artifactPrefix: "phaser",
            selectionSchemaVersion: selectionSchema,
            gameRoot: gameRoot ?? "",
            selectedSourceSHA256: selectedDigest
                ?? fixture.selection.selectedSourceDigest ?? "",
            jobID: jobID, schemaVersion: schemaVersion)
        let data = try JSONEncoder().encode(provenance)
        let transport = FakeGitHubTransport(
            workflow: .init(id: 7, name: "Floe script web",
                            path: ".github/workflows/floe-game-build-script-web.yml"),
            runID: 42, runStatus: "completed", conclusion: "success",
            artifactsByRun: [42: [
                .init(id: 1001, name: "floe-build-provenance",
                      sizeInBytes: Int64(data.count), expired: false),
                .init(id: 1002, name: "phaser-web.zip",
                      sizeInBytes: Int64(wrapper.count), expired: false, digest: nil)
            ]],
            bytesByArtifact: [1001: data, 1002: wrapper])
        return (transport, provenance)
    }

    @Test("Original whole project, selected root and digests reach publication and dispatch")
    func originalSelectionReachesPublisher() async throws {
        let fixture = try await makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let (transport, _) = try makeTransport(fixture: fixture)
        let publisher = RecordingSelectionPublisher()
        let repository = try GameBuildRepositoryReference(
            owner: "floe", repository: "games", branch: "main")
        let executor = GameRunCIExecutor(configuration: .init(
            transport: transport, tokens: FakeGitHubTokenProvider(value: "token"),
            publisher: publisher, repository: repository,
            pollInterval: .milliseconds(10), pollTimeout: .seconds(5)))
        let outcome = try await executor.build(
            engine: .phaser, sourceRoot: fixture.prepared, revision: "rev-1",
            engineVersion: nil, artifactName: "phaser-web.zip",
            expectedEntry: try GameRelativePath("index.html"),
            outputDirectory: fixture.output, selection: fixture.selection)
        #expect(outcome.jobID == "42")
        #expect(outcome.evidence.contains("ci-run:42"))
        #expect(FileManager.default.fileExists(
            atPath: fixture.output.appendingPathComponent("index.html").path))
        let capturedSnapshot = await publisher.snapshot
        let snapshot = try #require(capturedSnapshot)
        #expect(snapshot.rootURL.standardizedFileURL
            == fixture.context.rootURL.standardizedFileURL)
        #expect(snapshot.files.contains { $0.path.value == "games/b/index.html" })
        #expect(snapshot.gameRoot == "games/a")
        #expect(snapshot.digest == fixture.selection.wholeProjectDigest)
        #expect(snapshot.selectedSourceDigest == fixture.selection.selectedSourceDigest)
        let inputs = await transport.inputs
        #expect(inputs["game_root"] == "games/a")
        #expect(inputs["selected_source_sha256"]
            == fixture.selection.selectedSourceDigest)
        #expect(inputs["source_sha256"] == fixture.selection.wholeProjectDigest)
    }

    @Test("A publisher that substitutes another root is rejected before dispatch")
    func publisherRootSubstitutionIsRejected() async throws {
        let fixture = try await makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let (transport, _) = try makeTransport(fixture: fixture)
        let publisher = RecordingSelectionPublisher()
        await publisher.setOverride(gameRoot: "games/b", selected: nil)
        let repository = try GameBuildRepositoryReference(
            owner: "floe", repository: "games", branch: "main")
        let executor = GameRunCIExecutor(configuration: .init(
            transport: transport, tokens: FakeGitHubTokenProvider(value: "token"),
            publisher: publisher, repository: repository,
            pollInterval: .milliseconds(10), pollTimeout: .seconds(2)))
        await #expect(throws: GameExecutionError.self) {
            _ = try await executor.build(
                engine: .phaser, sourceRoot: fixture.prepared, revision: "rev-1",
                engineVersion: nil, artifactName: "phaser-web.zip",
                expectedEntry: try GameRelativePath("index.html"),
                outputDirectory: fixture.output, selection: fixture.selection)
        }
        let inputs = await transport.inputs
        #expect(inputs.isEmpty)
    }

    @Test("Legacy provenance cannot attest a nested request")
    func legacyProvenanceRejectedForNestedRequest() async throws {
        let fixture = try await makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let (transport, _) = try makeTransport(
            fixture: fixture, selectionSchema: 0,
            gameRoot: nil, selectedDigest: nil, schemaVersion: 1)
        let publisher = RecordingSelectionPublisher()
        let repository = try GameBuildRepositoryReference(
            owner: "floe", repository: "games", branch: "main")
        let executor = GameRunCIExecutor(configuration: .init(
            transport: transport, tokens: FakeGitHubTokenProvider(value: "token"),
            publisher: publisher, repository: repository,
            pollInterval: .milliseconds(10), pollTimeout: .seconds(2)))
        await #expect(throws: GameExecutionError.self) {
            _ = try await executor.build(
                engine: .phaser, sourceRoot: fixture.prepared, revision: "rev-1",
                engineVersion: nil, artifactName: "phaser-web.zip",
                expectedEntry: try GameRelativePath("index.html"),
                outputDirectory: fixture.output, selection: fixture.selection)
        }
        #expect(FileManager.default.fileExists(
            atPath: fixture.output.appendingPathComponent("index.html").path) == false)
    }

    @Test("A generated prepared copy cannot be published as the original source")
    func generatedPreparedCopyFailsBeforePublication() async throws {
        let fixture = try await makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let inventory = fixture.selection.inventory
        let generated = try GameRunSourceSelection(
            context: fixture.context, engine: .phaser,
            gameRoot: try GameRelativePath("games/a"), inventory: inventory,
            prepared: try GameRunPreparedSource(
                digest: fixture.selection.prepared.digest,
                transform: .generated, transformID: "fixture",
                relation: "generated-from:selected-source"))
        let (transport, _) = try makeTransport(fixture: fixture)
        let publisher = RecordingSelectionPublisher()
        let repository = try GameBuildRepositoryReference(
            owner: "floe", repository: "games", branch: "main")
        let executor = GameRunCIExecutor(configuration: .init(
            transport: transport, tokens: FakeGitHubTokenProvider(value: "token"),
            publisher: publisher, repository: repository,
            pollInterval: .milliseconds(10), pollTimeout: .seconds(2)))
        await #expect(throws: GameExecutionError.self) {
            _ = try await executor.build(
                engine: .phaser, sourceRoot: fixture.prepared, revision: "rev-1",
                engineVersion: nil, artifactName: "phaser-web.zip",
                expectedEntry: try GameRelativePath("index.html"),
                outputDirectory: fixture.output, selection: generated)
        }
        let snapshot = await publisher.snapshot
        #expect(snapshot == nil)
    }
}
