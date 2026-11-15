// SPDX-License-Identifier: MPL-2.0
import Foundation
import XCTest
import FloeGameCore
@testable import FloeGameBuildKit

private actor SourceCIJobsPort: GameBuildCISourceJobsPort {
    struct Dispatch { let templateID: String; let transport: GameBuildSourceTransport; let targets: [String]? }
    private(set) var dispatches: [Dispatch] = []
    private(set) var cancelled: [String] = []
    private var statuses: [GameCIJobStatus]
    private let payloads: [String: Data]
    private let provenance: GameBuildProvenance?

    init(statuses: [GameCIJobStatus], payloads: [String: Data], provenance: GameBuildProvenance?) {
        self.statuses = statuses; self.payloads = payloads; self.provenance = provenance
    }

    func dispatch(template: GameCIWorkflowTemplate, sourceDigest: String,
                  revision: String, engineVersion: String?) async throws -> GameCIJobHandle {
        .init(jobID: "legacy")
    }

    func dispatch(template: GameCIWorkflowTemplate, source: GameBuildSourceTransport,
                  engineVersion: String?) async throws -> GameCIJobHandle {
        dispatches.append(.init(templateID: template.id, transport: source, targets: nil))
        return .init(jobID: "job-source-1")
    }

    func dispatch(template: GameCIWorkflowTemplate, source: GameBuildSourceTransport,
                  engineVersion: String?, targets: GameCIWorkflowTargetSelection) async throws -> GameCIJobHandle {
        dispatches.append(.init(templateID: template.id, transport: source, targets: targets.targetIDs))
        return .init(jobID: "job-source-1")
    }

    func status(_ handle: GameCIJobHandle) async throws -> GameCIJobStatus {
        if cancelled.contains(handle.jobID) {
            return .init(handle: handle, state: .cancelled)
        }
        if statuses.isEmpty { return .init(handle: handle, state: .running) }
        return statuses.removeFirst()
    }

    func artifact(_ handle: GameCIJobHandle, named: String) async throws -> Data {
        guard let data = payloads[named] else { throw GameBuildError.artifactMissing(named) }
        return data
    }

    func cancel(_ handle: GameCIJobHandle) async throws {
        cancelled.append(handle.jobID)
    }

    func verifyExistingArtifact(_ reference: GameBuildRemoteArtifactReference) async throws -> GameBuildArtifactIdentity {
        .init(name: reference.name, sha256: reference.sha256, bytes: reference.bytes,
              runID: reference.runID, artifactID: reference.artifactID,
              sourceDigest: reference.sourceDigest, revision: reference.revision ?? "",
              engine: "", templateID: "source-transport", expired: false)
    }
}

final class GameBuildSourceCoordinatorTests: XCTestCase {
    private func context(repository: FileGameProjectRepository,
                         fixture: GameArchiveFixture) async throws -> (GameProjectContext, GameStoredProject) {
        let id = UUID(), owner = GameProjectOwner.space(recordID: id)
        let created = try await repository.createProject(projectID: id, owner: owner, title: "Build", engine: .phaser)
        let stored = try await repository.importContents(from: fixture.project(), into: id,
                                                         owner: owner, expectedRevision: created.revision)
        let context = try GameProjectContext(projectID: id, owner: owner,
                                             rootURL: fixture.root.appendingPathComponent("project-root"),
                                             savedRevision: stored.revision, environmentID: "linux-guest")
        return (context, stored)
    }

    func testSourceTransportPathCarriesProvenanceSourceArchiveAndRecordIdentity() async throws {
        let fixture = try GameArchiveFixture()
        defer { fixture.cleanup() }
        let repository = try FileGameProjectRepository(directory: fixture.root.appendingPathComponent("repo"))
        let (context, stored) = try await context(repository: repository, fixture: fixture)
        let records = try GameBuildRecordStore(directory: fixture.root.appendingPathComponent("records"))
        let inspection = GameProjectInspection(rootURL: context.rootURL, context: context,
                                               candidates: [GameEngineCandidate(engine: .phaser, evidence: [])],
                                               inspectedPaths: [])
        let plan = try GameBuildCapabilityRegistry.plan(for: .phaser, inspection: inspection)
        let digest = GameBuildCoordinator.sourceDigest(of: stored)
        let web = GameTestZIPCraft.makeZIP([
            .entry("index.html", data: Data("<!doctype html><title>t</title>".utf8)),
            .entry("assets/game.js", data: Data("console.log(1)".utf8)),
        ])
        let provenance = GameBuildProvenance(
            sourceSHA256: digest, sourceRevision: stored.revision, engine: "phaser",
            template: plan.workflowTemplateID, sourceTransport: "repositorySnapshot",
            artifacts: ["phaser-web.zip": .init(sha256: GameDigest.sha256(web), bytes: web.count)])
        let fake = SourceCIJobsPort(
            statuses: [.init(handle: .init(jobID: "job-source-1"), state: .succeeded,
                             sourceDigest: digest, revision: stored.revision)],
            payloads: ["phaser-web.zip": web,
                       GameBuildCILimits.provenanceArtifactName: try JSONEncoder().encode(provenance)],
            provenance: provenance)
        let coordinator = GameBuildCoordinator(hostPort: nil, ciPort: fake, records: records)
        let source = try GameBuildSourceTransport.repositorySnapshot(.init(
            owner: "floe", repository: "games", branch: "floe/run-1",
            commitSHA: String(repeating: "b", count: 40),
            treeSHA: String(repeating: "c", count: 40),
            manifestDigest: digest, revision: stored.revision))
        let outcome = try await coordinator.run(
            plan: plan, source: context, repository: repository, provided: ["node-lts"],
            sourceTransport: source,
            selectedRouteIDs: Set(plan.outputs.map(\.routeID)))
        XCTAssertTrue(outcome.ready)
        XCTAssertNotNil(outcome.sourceTransport)
        XCTAssertEqual(outcome.sourceTransport?.kind, .repositorySnapshot)
        XCTAssertNotNil(outcome.sourceArchive)
        XCTAssertTrue(outcome.artifacts.allSatisfy { $0.provenanceAttested })
        let record = try await records.load(buildID: outcome.binding.id.uuidString.lowercased())
        XCTAssertEqual(record?.sourceRoot, context.rootURL.path)
        XCTAssertEqual(record?.environmentID, "linux-guest")
        XCTAssertEqual(record?.transportKind, "repositorySnapshot")
        XCTAssertEqual(record?.sourceArchive?.name, "phaser-source.zip")
        let dispatches = await fake.dispatches
        XCTAssertEqual(dispatches.count, 1)
        XCTAssertEqual(dispatches.first?.templateID, plan.workflowTemplateID)
    }

    func testCocosWebOnlyDispatchDoesNotRequireAndroidSDKAndCarriesTargets() async throws {
        let fixture = try GameArchiveFixture()
        defer { fixture.cleanup() }
        let repository = try FileGameProjectRepository(directory: fixture.root.appendingPathComponent("repo"))
        let id = UUID(), owner = GameProjectOwner.space(recordID: id)
        let created = try await repository.createProject(projectID: id, owner: owner,
                                                          title: "Cocos Web", engine: .cocosCreator)
        let stored = try await repository.importContents(from: fixture.project(), into: id,
                                                          owner: owner, expectedRevision: created.revision)
        let context = try GameProjectContext(projectID: id, owner: owner,
                                             rootURL: fixture.root.appendingPathComponent("project-root"),
                                             savedRevision: stored.revision, environmentID: "linux-guest")
        let records = try GameBuildRecordStore(directory: fixture.root.appendingPathComponent("records"))
        let inspection = GameProjectInspection(rootURL: context.rootURL, context: context,
                                               candidates: [GameEngineCandidate(engine: .cocosCreator, evidence: [])],
                                               inspectedPaths: [])
        let plan = try GameBuildCapabilityRegistry.plan(for: .cocosCreator, inspection: inspection)
        XCTAssertTrue(plan.missingPrerequisites(configured: ["cocos-creator"],
                                                selectedRouteIDs: ["cocos-web"]).isEmpty,
                      "a Web-only request must not require the Android SDK/NDK")
        XCTAssertEqual(Set(plan.missingPrerequisites(configured: ["cocos-creator"],
                                                     selectedRouteIDs: ["cocos-android-apk"]).map(\.tool.id)),
                       Set(["android-sdk", "android-ndk"]))
        let digest = GameBuildCoordinator.sourceDigest(of: stored)
        let web = GameTestZIPCraft.makeZIP([
            .entry("index.html", data: Data("<!doctype html><title>cocos</title>".utf8)),
            .entry("assets/main.js", data: Data("console.log(1)".utf8)),
        ])
        let provenance = GameBuildProvenance(
            sourceSHA256: digest, sourceRevision: stored.revision, engine: "cocosCreator",
            template: plan.workflowTemplateID, sourceTransport: "repositorySnapshot",
            artifacts: ["cocos-web.zip": .init(sha256: GameDigest.sha256(web), bytes: web.count)],
            targets: ["web"])
        let fake = SourceCIJobsPort(
            statuses: [.init(handle: .init(jobID: "job-source-1"), state: .succeeded,
                             sourceDigest: digest, revision: stored.revision)],
            payloads: ["cocos-web.zip": web,
                       GameBuildCILimits.provenanceArtifactName: try JSONEncoder().encode(provenance)],
            provenance: provenance)
        let coordinator = GameBuildCoordinator(hostPort: nil, ciPort: fake, records: records)
        let source = try GameBuildSourceTransport.repositorySnapshot(.init(
            owner: "floe", repository: "games", branch: "floe/run-1",
            commitSHA: String(repeating: "b", count: 40),
            treeSHA: String(repeating: "c", count: 40),
            manifestDigest: digest, revision: stored.revision))
        let outcome = try await coordinator.run(
            plan: plan, source: context, repository: repository,
            provided: ["cocos-creator"], sourceTransport: source,
            selectedRouteIDs: ["cocos-web"])
        XCTAssertTrue(outcome.ready)
        XCTAssertEqual(outcome.artifacts.map(\.name), ["cocos-web.zip"])
        XCTAssertEqual(outcome.record.requestedTargets ?? [], ["web"])
        let dispatches = await fake.dispatches
        XCTAssertEqual(dispatches.first?.targets ?? [], ["web"])
        let record = try await records.load(buildID: outcome.binding.id.uuidString.lowercased())
        XCTAssertEqual(record?.requestedTargets ?? [], ["web"])
    }

    func testBeginReplacementFencesAnActiveSourceBuild() async throws {
        let fixture = try GameArchiveFixture()
        defer { fixture.cleanup() }
        let repository = try FileGameProjectRepository(directory: fixture.root.appendingPathComponent("repo"))
        let (context, stored) = try await context(repository: repository, fixture: fixture)
        let records = try GameBuildRecordStore(directory: fixture.root.appendingPathComponent("records"))
        let inspection = GameProjectInspection(rootURL: context.rootURL, context: context,
                                               candidates: [GameEngineCandidate(engine: .phaser, evidence: [])],
                                               inspectedPaths: [])
        let plan = try GameBuildCapabilityRegistry.plan(for: .phaser, inspection: inspection)
        let digest = GameBuildCoordinator.sourceDigest(of: stored)
        let fake = SourceCIJobsPort(statuses: [], payloads: [:], provenance: nil)
        let coordinator = GameBuildCoordinator(hostPort: nil, ciPort: fake, records: records)
        let source = try GameBuildSourceTransport.repositorySnapshot(.init(
            owner: "floe", repository: "games", branch: "floe/run-1",
            commitSHA: String(repeating: "b", count: 40),
            treeSHA: String(repeating: "c", count: 40),
            manifestDigest: digest, revision: stored.revision))
        let task = Task {
            try await coordinator.run(plan: plan, source: context, repository: repository,
                                      provided: ["node-lts"], sourceTransport: source,
                                      selectedRouteIDs: ["phaser-web"],
                                      pollInterval: .milliseconds(20))
        }
        var active: Set<UUID> = []
        for _ in 0..<200 {
            active = await coordinator.activeBuilds(projectID: context.projectID)
            if !active.isEmpty { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        let buildID = try XCTUnwrap(active.first)
        let replaced = await coordinator.beginReplacement(projectID: context.projectID)
        XCTAssertEqual(Set(replaced), active)
        do {
            _ = try await task.value
            XCTFail("a replaced build must not complete")
        } catch GameBuildError.cancelled {
            // expected
        }
        let record = try await records.load(buildID: buildID.uuidString.lowercased())
        XCTAssertEqual(record?.state, .cancelled)
        let cancelled = await fake.cancelled
        XCTAssertTrue(cancelled.isEmpty || cancelled == ["job-source-1"])
    }
}

private struct TestHostExporter: GameBuildExporterPort {
    func export(_ request: GameBuildExporterRequest) async throws -> GameBuildExporterResult {
        try FileManager.default.createDirectory(at: request.outputURL, withIntermediateDirectories: true)
        try Data("<!doctype html><title>ink</title>".utf8)
            .write(to: request.outputURL.appendingPathComponent("index.html"))
        return .init(engine: request.engine, outputURL: request.outputURL,
                     entry: "index.html", producerID: "test-host-exporter")
    }
}

final class GameBuildHostExporterTests: XCTestCase {
    func testHostExporterPathWorksWithoutACIJobAndPreservesSource() async throws {
        let fixture = try GameArchiveFixture()
        defer { fixture.cleanup() }
        let repository = try FileGameProjectRepository(directory: fixture.root.appendingPathComponent("repo"))
        let id = UUID(), owner = GameProjectOwner.space(recordID: id)
        let created = try await repository.createProject(projectID: id, owner: owner, title: "Ink", engine: .ink)
        let stored = try await repository.importContents(from: fixture.project(), into: id,
                                                         owner: owner, expectedRevision: created.revision)
        let context = try GameProjectContext(projectID: id, owner: owner,
                                             rootURL: fixture.root.appendingPathComponent("project-root"),
                                             savedRevision: stored.revision, environmentID: "linux-guest")
        let inspection = GameProjectInspection(rootURL: context.rootURL, context: context,
                                               candidates: [GameEngineCandidate(engine: .ink, evidence: [])],
                                               inspectedPaths: [])
        let plan = try GameBuildCapabilityRegistry.plan(for: .ink, inspection: inspection)
        let records = try GameBuildRecordStore(directory: fixture.root.appendingPathComponent("records"))
        let coordinator = GameBuildCoordinator(hostPort: nil, ciPort: nil, records: records)
        let outcome = try await coordinator.run(
            plan: plan, source: context, repository: repository, provided: [],
            exporter: TestHostExporter(), selectedRouteIDs: ["ink-web"])
        XCTAssertTrue(outcome.ready)
        XCTAssertNil(outcome.job)
        XCTAssertNotNil(outcome.sourceArchive)
        XCTAssertEqual(outcome.artifacts.first?.name, "ink-web.zip")
        XCTAssertNotNil(outcome.artifacts.first?.sealed)
    }
}
