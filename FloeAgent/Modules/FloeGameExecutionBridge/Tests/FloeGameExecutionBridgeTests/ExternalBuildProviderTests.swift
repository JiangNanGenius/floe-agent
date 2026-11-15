// SPDX-License-Identifier: MPL-2.0
import Foundation
import Testing
import FloeGameCore
import FloeGameBuildKit
import FloeGameRunKit
@testable import FloeGameExecutionBridge

@Suite("GameRunExternalBuildProvider")
struct ExternalBuildProviderTests {
    private func request(temp: ExecutionTemporaryDirectory, workspace: URL,
                         source: URL, output: URL,
                         engine: GameEngineID, kind: GameRunExternalBuildKind)
        throws -> GameRunExternalBuildRequest {
        let context = try ExecutionTestFixtures.context(workspace: workspace)
        return try GameRunExternalBuildRequest(
            engine: engine, kind: kind, context: context,
            sourceRoot: source, outputDirectory: output,
            expectedEntry: try GameRelativePath("index.html"),
            requirement: .externalTool(id: "test", detail: "test"))
    }

    @Test("Godot Web export runs the pinned CLI in the task workspace")
    func godotLocal() async throws {
        let temp = try ExecutionTemporaryDirectory(); defer { temp.cleanup() }
        let source = temp.url.appendingPathComponent("source")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try Data("config_version=5".utf8).write(to: source.appendingPathComponent("project.godot"))
        try Data("[preset.0]\nname=\"Web\"\nplatform=\"Web\"\n".utf8)
            .write(to: source.appendingPathComponent("export_presets.cfg"))
        let artifacts = try ExecutionTemporaryDirectory(); defer { artifacts.cleanup() }
        let output = artifacts.url.appendingPathComponent("out")
        try FileManager.default.createDirectory(at: output.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        let shell = FakeExecutionShell(workspaceRoot: temp.url)
        let provider = GameRunExternalBuildProvider(configuration: .init(
            shell: shell,
            authority: { _ in ExecutionTestFixtures.authority(projectID: UUID()) }))
        let result = try await provider.build(
            try request(temp: temp, workspace: temp.url, source: source,
                        output: output, engine: .godot, kind: .godotWeb))
        #expect(result.entry.value == "index.html")
        #expect(FileManager.default.fileExists(atPath: output.appendingPathComponent("index.html").path))
        let commands = await shell.commands
        #expect(commands.contains { $0.arguments.contains("--export-release") })
        #expect(commands.allSatisfy { $0.arguments.allSatisfy { !$0.contains("{{") } })
    }

    @Test("missing Godot Web preset fails before any command")
    func godotMissingPreset() async throws {
        let temp = try ExecutionTemporaryDirectory(); defer { temp.cleanup() }
        let source = temp.url.appendingPathComponent("source")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try Data("config_version=5".utf8).write(to: source.appendingPathComponent("project.godot"))
        let artifacts = try ExecutionTemporaryDirectory(); defer { artifacts.cleanup() }
        let output = artifacts.url.appendingPathComponent("out")
        try FileManager.default.createDirectory(at: output.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        let shell = FakeExecutionShell(workspaceRoot: temp.url)
        let provider = GameRunExternalBuildProvider(configuration: .init(
            shell: shell,
            authority: { _ in ExecutionTestFixtures.authority(projectID: UUID()) }))
        await #expect(throws: GameExecutionError.self) {
            _ = try await provider.build(
                try request(temp: temp, workspace: temp.url, source: source,
                            output: output, engine: .godot, kind: .godotWeb))
        }
        let commands = await shell.commands
        #expect(commands.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: output.path))
    }

    @Test("Unity WebGL uses the reviewed CI template with exact source provenance")
    func unityCI() async throws {
        let temp = try ExecutionTemporaryDirectory(); defer { temp.cleanup() }
        let source = temp.url.appendingPathComponent("source")
        try FileManager.default.createDirectory(at: source.appendingPathComponent("Assets"),
                                                withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: source.appendingPathComponent("ProjectSettings"),
                                                withIntermediateDirectories: true)
        try Data("m_EditorVersion: 2022.3.10f1".utf8).write(
            to: source.appendingPathComponent("ProjectSettings/ProjectVersion.txt"))
        let manifest = try GameWorkspaceTree.manifest(rootURL: source)

        let webDir = temp.url.appendingPathComponent("web")
        try FileManager.default.createDirectory(at: webDir.appendingPathComponent("assets"),
                                                withIntermediateDirectories: true)
        try Data("<!doctype html><title>unity</title>".utf8)
            .write(to: webDir.appendingPathComponent("index.html"))
        try Data("console.log(1)".utf8)
            .write(to: webDir.appendingPathComponent("assets/game.js"))
        let webZIP = try ExecutionTestFixtures.zip(directory: webDir)

        let wrapperDir = temp.url.appendingPathComponent("wrapper")
        try FileManager.default.createDirectory(at: wrapperDir, withIntermediateDirectories: true)
        try webZIP.write(to: wrapperDir.appendingPathComponent("unity-web.zip"))
        let wrapperZIP = try ExecutionTestFixtures.zip(directory: wrapperDir)

        let provenance = GameBuildProvenance(
            sourceSHA256: manifest.digest, sourceRevision: "rev-1", engine: "unity",
            template: "floe-game-build-unity", sourceTransport: "repository",
            artifacts: ["unity-web.zip": .init(sha256: GameDigest.sha256(webZIP),
                                                bytes: webZIP.count)],
            targets: ["web"], artifactPrefix: "unity", jobID: "42", schemaVersion: 2)
        let provenanceData = try JSONEncoder().encode(provenance)
        let transport = FakeGitHubTransport(
            workflow: .init(id: 7, name: "Floe Unity", path: ".github/workflows/floe-game-build-unity.yml"),
            runID: 42, runStatus: "completed", conclusion: "success",
            artifactsByRun: [42: [
                .init(id: 1001, name: "floe-build-provenance",
                      sizeInBytes: Int64(provenanceData.count), expired: false),
                .init(id: 1002, name: "unity-web.zip",
                      sizeInBytes: Int64(wrapperZIP.count), expired: false,
                      digest: nil)
            ]],
            bytesByArtifact: [1001: provenanceData, 1002: wrapperZIP])
        let publisher = FakeSourcePublisher()
        let repository = try GameBuildRepositoryReference(owner: "floe", repository: "games", branch: "main")
        let ci = GameRunCIExecutor(configuration: .init(
            transport: transport, tokens: FakeGitHubTokenProvider(value: "token"),
            publisher: publisher, repository: repository,
            pollInterval: .milliseconds(10), pollTimeout: .seconds(5)))
        let artifacts = try ExecutionTemporaryDirectory(); defer { artifacts.cleanup() }
        let output = artifacts.url.appendingPathComponent("out")
        try FileManager.default.createDirectory(at: output.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        let shell = FakeExecutionShell(workspaceRoot: temp.url)
        let provider = GameRunExternalBuildProvider(configuration: .init(
            shell: shell,
            authority: { _ in ExecutionTestFixtures.authority(projectID: UUID()) },
            ci: ci))
        let result = try await provider.build(
            try request(temp: temp, workspace: temp.url, source: source,
                        output: output, engine: .unity, kind: .unityWebGL))
        #expect(result.entry.value == "index.html")
        #expect(FileManager.default.fileExists(atPath: output.appendingPathComponent("index.html").path))
        #expect(FileManager.default.fileExists(atPath: output.appendingPathComponent("assets/game.js").path))
        let inputs = await transport.inputs
        #expect(inputs["source_sha256"] == manifest.digest)
        #expect(inputs["targets"] == "web")
        let snapshots = await publisher.snapshots
        #expect(snapshots.count == 1)
        #expect(snapshots.first?.digest == manifest.digest)
    }

    @Test("CI cancellation does not publish a late artifact")
    func ciCancellation() async throws {
        let temp = try ExecutionTemporaryDirectory(); defer { temp.cleanup() }
        let source = temp.url.appendingPathComponent("source")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: source.appendingPathComponent("index.html"))
        let transport = FakeGitHubTransport(
            workflow: .init(id: 7, name: "Floe Unity", path: ".github/workflows/floe-game-build-unity.yml"),
            runID: 42, runStatus: "in_progress", conclusion: nil,
            artifactsByRun: [:], bytesByArtifact: [:])
        let publisher = FakeSourcePublisher()
        let repository = try GameBuildRepositoryReference(owner: "floe", repository: "games", branch: "main")
        let ci = GameRunCIExecutor(configuration: .init(
            transport: transport, tokens: FakeGitHubTokenProvider(value: "token"),
            publisher: publisher, repository: repository,
            pollInterval: .milliseconds(20), pollTimeout: .seconds(2)))
        let artifacts = try ExecutionTemporaryDirectory(); defer { artifacts.cleanup() }
        let output = artifacts.url.appendingPathComponent("out")
        try FileManager.default.createDirectory(at: output.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        let provider = GameRunExternalBuildProvider(configuration: .init(
            shell: FakeExecutionShell(workspaceRoot: temp.url),
            authority: { _ in ExecutionTestFixtures.authority(projectID: UUID()) },
            ci: ci))
        let buildRequest = try request(temp: temp, workspace: temp.url, source: source,
                                       output: output, engine: .unity, kind: .unityWebGL)
        let task = Task { try await provider.build(buildRequest) }
        try await Task.sleep(for: .milliseconds(80))
        task.cancel()
        _ = await task.result
        #expect(!FileManager.default.fileExists(atPath: output.appendingPathComponent("index.html").path))
        let cancelled = await transport.cancelled
        #expect(cancelled.contains(42))
    }
}
