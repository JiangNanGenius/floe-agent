// SPDX-License-Identifier: MPL-2.0
import Foundation
import XCTest
import FloeGameCore
@testable import FloeGameBuildKit

private struct TestTokenProvider: GameBuildGitHubTokenProvider {
    let value: String?
    func token() async throws -> String? { value }
}

private actor TestGitHubTransport: GameBuildGitHubActionsTransport {
    let workflow: GameBuildCIWorkflowRef
    var triggerRunID: Int64?
    var runs: [Int64: GameBuildCIRun]
    var artifactsByRun: [Int64: [GameBuildCIArtifact]]
    var bytesByArtifact: [Int64: Data]
    var lastInputs: [String: String] = [:]
    var cancelled: [Int64] = []

    init(workflow: GameBuildCIWorkflowRef, triggerRunID: Int64?,
         runs: [Int64: GameBuildCIRun], artifactsByRun: [Int64: [GameBuildCIArtifact]],
         bytesByArtifact: [Int64: Data]) {
        self.workflow = workflow; self.triggerRunID = triggerRunID
        self.runs = runs; self.artifactsByRun = artifactsByRun
        self.bytesByArtifact = bytesByArtifact
    }

    func workflows(owner: String, repository: String, token: String) async throws -> [GameBuildCIWorkflowRef] {
        [workflow]
    }

    func workflowRuns(owner: String, repository: String, workflowID: Int64,
                      branch: String, event: String, token: String) async throws -> [GameBuildCIRun] {
        runs.values.filter { $0.workflowID == workflowID && $0.event == event }
            .sorted { $0.id < $1.id }
    }

    func run(owner: String, repository: String, runID: Int64, token: String) async throws -> GameBuildCIRun {
        guard let run = runs[runID] else { throw GameBuildCIError.http(404) }
        return run
    }

    func artifacts(owner: String, repository: String, runID: Int64, token: String) async throws -> [GameBuildCIArtifact] {
        artifactsByRun[runID] ?? []
    }

    func downloadArtifact(owner: String, repository: String, runID: Int64,
                          artifactID: Int64, token: String, maximumBytes: Int) async throws -> Data {
        guard let data = bytesByArtifact[artifactID] else { throw GameBuildCIError.http(404) }
        guard data.count <= maximumBytes else { throw GameBuildCIError.artifact("too large") }
        return data
    }

    func triggerDispatch(owner: String, repository: String, workflowID: Int64,
                         ref: String, inputs: [String: String], token: String) async throws -> GameBuildCITrigger {
        lastInputs = inputs
        return .init(runID: triggerRunID, htmlURL: nil)
    }

    func cancelRun(owner: String, repository: String, runID: Int64, token: String) async throws {
        cancelled.append(runID)
    }
}

final class GameBuildCITests: XCTestCase {
    private let revision = "rev-1"
    private let digest = String(repeating: "a", count: 64)

    private func template() throws -> GameCIWorkflowTemplate {
        try XCTUnwrap(GameCIWorkflowTemplates.template(for: .phaser))
    }

    private func repository() throws -> GameBuildRepositoryReference {
        try .init(owner: "floe", repository: "games", branch: "floe/run-1")
    }

    private func source() throws -> GameBuildSourceTransport {
        .repositorySnapshot(try .init(
            owner: "floe", repository: "games", branch: "floe/run-1",
            commitSHA: String(repeating: "b", count: 40),
            treeSHA: String(repeating: "c", count: 40),
            manifestDigest: digest, revision: revision))
    }

    private func binding() -> GameBuildBinding {
        let projectID = UUID()
        return .init(id: UUID(), projectID: projectID, revision: revision,
                     sourceDigest: digest, engine: .phaser, engineVersion: "3.80",
                     sourceRoot: URL(fileURLWithPath: "/tmp/floe-source"),
                     owner: .space(recordID: projectID), environmentID: "linux-guest")
    }

    private func webZIP() -> Data {
        GameTestZIPCraft.makeZIP([
            .entry("index.html", data: Data("<!doctype html><title>t</title>".utf8)),
            .entry("assets/game.js", data: Data("console.log(1)".utf8)),
        ])
    }

    private func provenanceData(for template: GameCIWorkflowTemplate, web: Data,
                                overridesDigest: String? = nil) throws -> Data {
        let provenance = GameBuildProvenance(
            sourceSHA256: overridesDigest ?? digest,
            sourceRevision: revision,
            engine: "phaser",
            template: template.id,
            sourceTransport: "repository",
            artifacts: ["phaser-web.zip": .init(sha256: GameDataDigest.hex(web), bytes: web.count)],
            jobID: "42", schemaVersion: 2)
        return try JSONEncoder().encode(provenance)
    }

    func testRepositoryDispatchAssociatesAndVerifiesProvenanceAndArtifact() async throws {
        let template = try template()
        let web = webZIP()
        let run = GameBuildCIRun(id: 42, workflowID: 7, status: "completed", conclusion: "success",
                                 headSHA: String(repeating: "b", count: 40),
                                 headBranch: "floe/run-1", event: "workflow_dispatch",
                                 createdAt: Date(), htmlURL: nil)
        let provenance = try provenanceData(for: template, web: web)
        let transport = TestGitHubTransport(
            workflow: .init(id: 7, name: "floe", path: ".github/workflows/floe-game-build-script-web.yml"),
            triggerRunID: 42, runs: [42: run],
            artifactsByRun: [42: [
                .init(id: 1001, name: "floe-build-provenance", sizeInBytes: 512, expired: false),
                .init(id: 1002, name: "phaser-web.zip", sizeInBytes: Int64(web.count),
                      expired: false, digest: "sha256:" + GameDataDigest.hex(web)),
            ]],
            bytesByArtifact: [1001: provenance, 1002: web])
        let adapter = GitHubActionsBuildCIAdapter(
            transport: transport, tokens: TestTokenProvider(value: "test-token"),
            repository: try repository(), expectedArtifacts: ["phaser-web.zip"])
        let handle = try await adapter.dispatch(template: template, source: try source(),
                                                engineVersion: "3.80")
        XCTAssertEqual(handle.jobID, "42")
        let inputs = await transport.lastInputs
        XCTAssertEqual(inputs["source_transport"], "repository")
        XCTAssertEqual(inputs["source_sha256"], digest)
        XCTAssertEqual(inputs["source_commit"], String(repeating: "b", count: 40))
        XCTAssertEqual(inputs["engine"], "phaser")
        let status = try await adapter.status(handle)
        XCTAssertEqual(status.sourceDigest, digest)
        XCTAssertEqual(status.revision, revision)
        if case .succeeded = status.state {} else { XCTFail("expected succeeded") }
        let data = try await adapter.artifact(handle, named: "phaser-web.zip")
        XCTAssertEqual(data, web)
        try await adapter.cancel(handle)
        let cancelled = await transport.cancelled
        XCTAssertEqual(cancelled, [42])
    }

    func testStaleProvenanceFailsInsteadOfReportingSuccess() async throws {
        let template = try template()
        let web = webZIP()
        let run = GameBuildCIRun(id: 42, workflowID: 7, status: "completed", conclusion: "success",
                                 headSHA: String(repeating: "b", count: 40),
                                 headBranch: "floe/run-1", event: "workflow_dispatch",
                                 createdAt: Date(), htmlURL: nil)
        let provenance = try provenanceData(for: template, web: web,
                                            overridesDigest: String(repeating: "d", count: 64))
        let transport = TestGitHubTransport(
            workflow: .init(id: 7, name: "floe", path: ".github/workflows/floe-game-build-script-web.yml"),
            triggerRunID: 42, runs: [42: run],
            artifactsByRun: [42: [
                .init(id: 1001, name: "floe-build-provenance", sizeInBytes: 512, expired: false),
                .init(id: 1002, name: "phaser-web.zip", sizeInBytes: Int64(web.count),
                      expired: false, digest: "sha256:" + GameDataDigest.hex(web)),
            ]],
            bytesByArtifact: [1001: provenance, 1002: web])
        let adapter = GitHubActionsBuildCIAdapter(
            transport: transport, tokens: TestTokenProvider(value: "test-token"),
            repository: try repository(), expectedArtifacts: ["phaser-web.zip"])
        let handle = try await adapter.dispatch(template: template, source: try source(),
                                                engineVersion: "3.80")
        let status = try await adapter.status(handle)
        if case .failed = status.state {} else { XCTFail("stale provenance must not succeed") }
    }

    func testCrossRunSourceArtifactIsVerifiedByExplicitIdentityNotNewestRun() async throws {
        let sourceZIP = webZIP()
        let wrapper = GameTestZIPCraft.makeZIP([.entry("source.zip", data: sourceZIP)])
        let reference = try GameBuildRemoteArtifactReference(
            owner: "floe", repository: "games", runID: 99, artifactID: 2002,
            name: "floe-game-source", sha256: GameDataDigest.hex(sourceZIP), bytes: sourceZIP.count,
            revision: revision, sourceDigest: GameDataDigest.hex(sourceZIP))
        let run = GameBuildCIRun(id: 99, workflowID: 7, status: "completed", conclusion: "success",
                                 headSHA: String(repeating: "e", count: 40),
                                 headBranch: "main", event: "workflow_dispatch",
                                 createdAt: Date(), htmlURL: nil)
        let transport = TestGitHubTransport(
            workflow: .init(id: 7, name: "floe", path: ".github/workflows/floe-game-build-script-web.yml"),
            triggerRunID: nil, runs: [99: run],
            artifactsByRun: [99: [
                .init(id: 2002, name: "floe-game-source", sizeInBytes: Int64(wrapper.count), expired: false),
                .init(id: 2003, name: "someone-elses-newest", sizeInBytes: 10, expired: false),
            ]],
            bytesByArtifact: [2002: wrapper, 2003: Data("wrong".utf8)])
        let adapter = GitHubActionsBuildCIAdapter(
            transport: transport, tokens: TestTokenProvider(value: "test-token"),
            repository: try repository(), expectedArtifacts: ["phaser-web.zip"])
        let identity = try await adapter.verifyExistingArtifact(reference)
        XCTAssertEqual(identity.runID, 99)
        XCTAssertEqual(identity.artifactID, 2002)
        XCTAssertEqual(identity.sha256, GameDataDigest.hex(sourceZIP))
        var wrong = reference
        // The initializer rejects a non-digest; use a valid but different digest.
        let other = String(repeating: "f", count: 64)
        wrong = try GameBuildRemoteArtifactReference(
            owner: "floe", repository: "games", runID: 99, artifactID: 2002,
            name: "floe-game-source", sha256: other, bytes: sourceZIP.count,
            revision: revision, sourceDigest: other)
        do {
            _ = try await adapter.verifyExistingArtifact(wrong)
            XCTFail("wrong source artifact digest must be rejected")
        } catch {}
    }

    func testArtifactValidatorDistinguishesWebAPKXcodeProjectAndWrongBytes() throws {
        let web = webZIP()
        XCTAssertNoThrow(try GameArtifactValidator.validate(
            data: web, name: "phaser-web.zip",
            rule: .init(kind: .webBundle, entry: "index.html")))
        let apk = GameTestZIPCraft.makeZIP([
            .entry("AndroidManifest.xml", data: Data("<manifest/>".utf8)),
            .entry("classes.dex", data: Data("dex\n035\0".utf8)),
        ])
        XCTAssertNoThrow(try GameArtifactValidator.validate(
            data: apk, name: "game.apk", rule: .init(kind: .apk)))
        let xcode = GameTestZIPCraft.makeZIP([
            .entry("Unity-iPhone.xcodeproj/project.pbxproj", data: Data("// !$*UTF8*$!".utf8)),
        ])
        XCTAssertNoThrow(try GameArtifactValidator.validate(
            data: xcode, name: "project.zip", rule: .init(kind: .xcodeProject)))
        XCTAssertThrowsError(try GameArtifactValidator.validate(
            data: web, name: "game.apk", rule: .init(kind: .apk)))
        XCTAssertThrowsError(try GameArtifactValidator.validate(
            data: Data("not a PE".utf8), name: "game.exe", rule: .init(kind: .executablePE)))
    }

    func testSharedSourceTransportVectorsArePresentAndWellFormed() throws {
        guard let url = GameBuildResourceLocator.url("source-transport", "json",
                                                     "Resources/TestVectors") else {
            XCTFail("missing shared source-transport vectors")
            return
        }
        let object = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
        let vectors = object?["vectors"] as? [[String: Any]]
        XCTAssertEqual(vectors?.count, 18)
        XCTAssertTrue(vectors?.allSatisfy { ($0["id"] as? String)?.isEmpty == false } == true)
    }
}

extension GameBuildCITests {
    private func targetProvenance(template: GameCIWorkflowTemplate, engine: String,
                                  targets: [String], artifacts: [String: Data],
                                  overridesDigest: String? = nil) throws -> Data {
        let records = Dictionary(uniqueKeysWithValues: artifacts.map { pair in
            (pair.key, GameBuildProvenanceArtifact(sha256: GameDataDigest.hex(pair.value),
                                                   bytes: pair.value.count))
        })
        return try JSONEncoder().encode(GameBuildProvenance(
            sourceSHA256: overridesDigest ?? digest, sourceRevision: revision,
            engine: engine, template: template.id, sourceTransport: "repository",
            artifacts: records, targets: targets))
    }

    func testWebOnlyUnityDispatchGatesJobsAndRejectsDesktopArtifacts() async throws {
        let template = try XCTUnwrap(GameCIWorkflowTemplates.template(for: .unity))
        let web = webZIP()
        let provenance = try targetProvenance(template: template, engine: "unity",
                                              targets: ["web"], artifacts: ["unity-web.zip": web])
        let run = GameBuildCIRun(id: 51, workflowID: 9, status: "completed", conclusion: "success",
                                 headSHA: String(repeating: "b", count: 40),
                                 headBranch: "floe/run-1", event: "workflow_dispatch",
                                 createdAt: Date(), htmlURL: nil)
        let transport = TestGitHubTransport(
            workflow: .init(id: 9, name: "unity", path: ".github/workflows/floe-game-build-unity.yml"),
            triggerRunID: 51, runs: [51: run],
            artifactsByRun: [51: [
                .init(id: 2001, name: "floe-build-provenance", sizeInBytes: 512, expired: false),
                .init(id: 2002, name: "unity-web.zip", sizeInBytes: Int64(web.count),
                      expired: false, digest: "sha256:" + GameDataDigest.hex(web)),
            ]],
            bytesByArtifact: [2001: provenance, 2002: web])
        let adapter = GitHubActionsBuildCIAdapter(
            transport: transport, tokens: TestTokenProvider(value: "test-token"),
            repository: try repository(),
            expectedArtifacts: ["unity-web.zip", "unity-windows.zip",
                                "unity-macos.zip", "unity-ios-xcodeproj.zip"])
        let source = try GameBuildSourceTransport.repositorySnapshot(.init(
            owner: "floe", repository: "games", branch: "floe/run-1",
            commitSHA: String(repeating: "b", count: 40),
            treeSHA: String(repeating: "c", count: 40), manifestDigest: digest, revision: revision))
        let selection = GameCIWorkflowTargetSelection(targetIDs: ["web"],
                                                       artifactNames: ["unity-web.zip"])
        let handle = try await adapter.dispatch(template: template, source: source,
                                                engineVersion: "2022.3", targets: selection)
        let inputs = await transport.lastInputs
        XCTAssertEqual(inputs["targets"], "web")
        let status = try await adapter.status(handle)
        XCTAssertEqual(status.sourceDigest, digest)
        if case .succeeded = status.state {} else { XCTFail("expected succeeded: \(status.state)") }
        let data = try await adapter.artifact(handle, named: "unity-web.zip")
        XCTAssertEqual(data, web)
        do {
            _ = try await adapter.artifact(handle, named: "unity-windows.zip")
            XCTFail("a Web-only dispatch must not expose a desktop artifact")
        } catch {}
    }

    func testCocosAndroidProvenanceRequiresBothProjectAndAPK() async throws {
        let template = try XCTUnwrap(GameCIWorkflowTemplates.template(for: .cocosCreator))
        let project = webZIP()
        let provenance = try targetProvenance(template: template, engine: "cocosCreator",
                                              targets: ["android"],
                                              artifacts: ["cocos-android-project.zip": project])
        let run = GameBuildCIRun(id: 61, workflowID: 10, status: "completed", conclusion: "success",
                                 headSHA: String(repeating: "b", count: 40),
                                 headBranch: "floe/run-1", event: "workflow_dispatch",
                                 createdAt: Date(), htmlURL: nil)
        let transport = TestGitHubTransport(
            workflow: .init(id: 10, name: "cocos", path: ".github/workflows/floe-game-build-cocos.yml"),
            triggerRunID: 61, runs: [61: run],
            artifactsByRun: [61: [
                .init(id: 3001, name: "floe-build-provenance", sizeInBytes: 512, expired: false),
            ]],
            bytesByArtifact: [3001: provenance])
        let adapter = GitHubActionsBuildCIAdapter(
            transport: transport, tokens: TestTokenProvider(value: "test-token"),
            repository: try repository(),
            expectedArtifacts: ["cocos-android-project.zip", "cocos-android.apk"])
        let source = try GameBuildSourceTransport.repositorySnapshot(.init(
            owner: "floe", repository: "games", branch: "floe/run-1",
            commitSHA: String(repeating: "b", count: 40),
            treeSHA: String(repeating: "c", count: 40), manifestDigest: digest, revision: revision))
        let selection = GameCIWorkflowTargetSelection(
            targetIDs: ["android"],
            artifactNames: ["cocos-android-project.zip", "cocos-android.apk"])
        let handle = try await adapter.dispatch(template: template, source: source,
                                                engineVersion: "3.8.6", targets: selection)
        let status = try await adapter.status(handle)
        if case .failed(let reason) = status.state {
            XCTAssertTrue(reason.contains("requested targets") || reason.contains("provenance"))
        } else {
            XCTFail("a project ZIP alone must not satisfy the atomic Android target")
        }
    }

    func testSelectionOutsideConfiguredTargetsIsRejectedBeforeDispatch() async throws {
        let template = try XCTUnwrap(GameCIWorkflowTemplates.template(for: .unity))
        let transport = TestGitHubTransport(
            workflow: .init(id: 9, name: "unity", path: ".github/workflows/floe-game-build-unity.yml"),
            triggerRunID: nil, runs: [:], artifactsByRun: [:], bytesByArtifact: [:])
        let adapter = GitHubActionsBuildCIAdapter(
            transport: transport, tokens: TestTokenProvider(value: "test-token"),
            repository: try repository(), expectedArtifacts: ["unity-web.zip"])
        let selection = GameCIWorkflowTargetSelection(targetIDs: ["windows"],
                                                       artifactNames: ["unity-windows.zip"])
        do {
            _ = try await adapter.dispatch(template: template, source: try source(),
                                            engineVersion: "2022.3", targets: selection)
            XCTFail("a target outside the configured set must be rejected")
        } catch let error as GameBuildCIError {
            guard case .invalidConfiguration = error else {
                XCTFail("unexpected error: \(error)")
                return
            }
        }
        let inputs = await transport.lastInputs
        XCTAssertTrue(inputs.isEmpty, "rejected selection must not reach the transport")
    }
}
