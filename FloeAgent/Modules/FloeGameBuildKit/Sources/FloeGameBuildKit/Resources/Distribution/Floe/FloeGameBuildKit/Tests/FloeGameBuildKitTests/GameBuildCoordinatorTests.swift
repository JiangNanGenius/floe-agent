// SPDX-License-Identifier: MPL-2.0
import Foundation
import XCTest
import FloeGameCore
@testable import FloeGameBuildKit

/// Controlled CI jobs client: no network, no real dispatch. Scripted statuses
/// echo the dispatched digest/revision unless told to be stale.
actor FakeCIJobsPort: GameBuildCIJobsPort {
    struct Dispatch { let templateID: String; let digest: String; let revision: String }
    private(set) var dispatches: [Dispatch] = []
    private(set) var cancelledJobs: [String] = []
    private var statuses: [GameCIJobStatus]
    private let staleDigest: String?
    private var artifactPayloads: [String: Data]
    private var failArtifactNames: Set<String>

    init(statuses: [GameCIJobStatus], payloads: [String: Data],
         staleDigest: String? = nil, failArtifactNames: Set<String> = []) {
        self.statuses = statuses
        self.artifactPayloads = payloads
        self.staleDigest = staleDigest
        self.failArtifactNames = failArtifactNames
    }

    func dispatch(template: GameCIWorkflowTemplate, sourceDigest: String,
                  revision: String, engineVersion: String?) async throws -> GameCIJobHandle {
        dispatches.append(.init(templateID: template.id, digest: sourceDigest, revision: revision))
        return .init(jobID: "job-\(dispatches.count)")
    }

    func status(_ handle: GameCIJobHandle) async throws -> GameCIJobStatus {
        guard !statuses.isEmpty else {
            return .init(handle: handle, state: .running)
        }
        let status = statuses.removeFirst()
        if let staleDigest {
            return .init(handle: handle, state: status.state, sourceDigest: staleDigest, revision: status.revision)
        }
        return status
    }

    func artifact(_ handle: GameCIJobHandle, named: String) async throws -> Data {
        if failArtifactNames.contains(named) { throw GameBuildError.artifactMissing(named) }
        guard let data = artifactPayloads[named] else { throw GameBuildError.artifactMissing(named) }
        return data
    }

    func cancel(_ handle: GameCIJobHandle) async throws {
        cancelledJobs.append(handle.jobID)
    }
}

/// Controlled host execution client: records commands, never spawns anything.
actor FakeHostPort: GameBuildHostPort {
    private(set) var commands: [GameHostCommand] = []
    private let exitCode: Int32

    init(exitCode: Int32 = 0) { self.exitCode = exitCode }

    func run(_ command: GameHostCommand) async throws -> GameHostResult {
        commands.append(command)
        return .init(exitCode: exitCode, stdout: Data(), stderr: Data())
    }

    func terminate(jobID: String) async throws {}
}

final class GameBuildCoordinatorTests: XCTestCase {
    private func boundContext(repository: FileGameProjectRepository,
                              fixture: GameArchiveFixture) async throws -> (GameProjectContext, GameStoredProject) {
        let id = UUID(), owner = GameProjectOwner.space(recordID: id)
        let created = try await repository.createProject(projectID: id, owner: owner, title: "Build", engine: .phaser)
        let stored = try await repository.importContents(from: fixture.project(), into: id,
                                                         owner: owner, expectedRevision: created.revision)
        let context = try GameProjectContext(projectID: id, owner: owner,
                                             rootURL: fixture.root.appendingPathComponent("project-root"),
                                             savedRevision: stored.revision)
        return (context, stored)
    }

    private func webBundleZIP() throws -> Data {
        GameTestZIPCraft.makeZIP([
            .entry("index.html", data: Data("<!doctype html><title>t</title>".utf8)),
            .entry("game.js", data: Data("console.log(1)".utf8)),
        ])
    }

    func testFullLifecycleBindsStagesDispatchesVerifiesAndSeals() async throws {
        let fixture = try GameArchiveFixture()
        defer { fixture.cleanup() }
        let repository = try FileGameProjectRepository(directory: fixture.root.appendingPathComponent("repo"))
        let (context, stored) = try await boundContext(repository: repository, fixture: fixture)
        let records = try GameBuildRecordStore(directory: fixture.root.appendingPathComponent("records"))
        let inspection = GameProjectInspection(
            rootURL: context.rootURL, context: context,
            candidates: [GameEngineCandidate(engine: .phaser, evidence: [])], inspectedPaths: [])
        let plan = try GameBuildCapabilityRegistry.plan(for: .phaser, inspection: inspection)
        let digest = GameBuildCoordinator.sourceDigest(of: stored)
        let fake = FakeCIJobsPort(
            statuses: [.init(handle: .init(jobID: "job-1"), state: .succeeded, sourceDigest: digest, revision: stored.revision)],
            payloads: ["phaser-web.zip": try webBundleZIP()])
        let coordinator = GameBuildCoordinator(hostPort: nil, ciPort: fake, records: records)
        let outcome = try await coordinator.run(plan: plan, source: context, repository: repository,
                                                provided: ["node-lts"])
        XCTAssertTrue(outcome.ready)
        XCTAssertEqual(outcome.job?.jobID, "job-1")
        XCTAssertEqual(outcome.artifacts.count, plan.outputs.filter { $0.kind != .sourceArchive }.count)
        let sealed = try XCTUnwrap(outcome.artifacts.first(where: { $0.name == "phaser-web.zip" })?.sealed)
        XCTAssertEqual(sealed.engine, .phaser)
        XCTAssertEqual(sealed.source.savedRevision, stored.revision)
        let record = try await records.load(buildID: outcome.binding.id.uuidString.lowercased())
        XCTAssertEqual(record?.state, .succeeded)
        XCTAssertEqual(record?.artifacts.count, plan.outputs.filter { $0.kind != .sourceArchive }.count)
        // Sealed playable directory really exists and re-verifies.
        let sealedDir = fixture.root.appendingPathComponent("records")
            .appendingPathComponent("artifacts-\(outcome.binding.id.uuidString.lowercased())")
            .appendingPathComponent("playable-phaser-web.zip")
        let packageFiles = try FileManager.default.contentsOfDirectory(atPath: sealedDir.path)
        XCTAssertTrue(packageFiles.contains("index.html"))
    }

    func testStagedSourceIsPreflightedThroughTheHostPortBeforeDispatch() async throws {
        let fixture = try GameArchiveFixture()
        defer { fixture.cleanup() }
        let repository = try FileGameProjectRepository(directory: fixture.root.appendingPathComponent("repo"))
        let (context, stored) = try await boundContext(repository: repository, fixture: fixture)
        let records = try GameBuildRecordStore(directory: fixture.root.appendingPathComponent("records"))
        let inspection = GameProjectInspection(rootURL: context.rootURL, context: context,
                                               candidates: [GameEngineCandidate(engine: .phaser, evidence: [])],
                                               inspectedPaths: [])
        let plan = try GameBuildCapabilityRegistry.plan(for: .phaser, inspection: inspection)
        let digest = GameBuildCoordinator.sourceDigest(of: stored)

        // A failing preflight must abort before dispatch.
        let failingHost = FakeHostPort(exitCode: 2)
        let failingCI = FakeCIJobsPort(statuses: [], payloads: [:])
        let failingCoordinator = GameBuildCoordinator(hostPort: failingHost, ciPort: failingCI, records: records)
        do {
            _ = try await failingCoordinator.run(plan: plan, source: context, repository: repository,
                                                 provided: ["node-lts"])
            XCTFail("expected dispatchFailed after failed preflight")
        } catch GameBuildError.dispatchFailed(let reason) {
            XCTAssertTrue(reason.contains("preflight"))
        }
        let failingDispatches = await failingCI.dispatches
        XCTAssertTrue(failingDispatches.isEmpty)
        let failingCommands = await failingHost.commands
        XCTAssertEqual(failingCommands.map(\.executable), ["unzip"])

        // A passing preflight proceeds to dispatch.
        let host = FakeHostPort()
        let ci = FakeCIJobsPort(
            statuses: [.init(handle: .init(jobID: "job-1"), state: .succeeded, sourceDigest: digest, revision: stored.revision)],
            payloads: ["phaser-web.zip": try webBundleZIP()])
        let coordinator = GameBuildCoordinator(hostPort: host, ciPort: ci, records: records)
        let outcome = try await coordinator.run(plan: plan, source: context, repository: repository,
                                                provided: ["node-lts"])
        XCTAssertTrue(outcome.ready)
        let commands = await host.commands
        XCTAssertEqual(commands.first?.executable, "unzip")
        let dispatches = await ci.dispatches
        XCTAssertEqual(dispatches.count, 1)
    }

    func testMissingPrerequisiteIsAConfigurableErrorNotFakeReadiness() async throws {
        let fixture = try GameArchiveFixture()
        defer { fixture.cleanup() }
        let repository = try FileGameProjectRepository(directory: fixture.root.appendingPathComponent("repo"))
        let (context, _) = try await boundContext(repository: repository, fixture: fixture)
        let records = try GameBuildRecordStore(directory: fixture.root.appendingPathComponent("records"))
        let inspection = GameProjectInspection(rootURL: context.rootURL, context: context,
                                               candidates: [GameEngineCandidate(engine: .godot, evidence: [])],
                                               inspectedPaths: [])
        let plan = try GameBuildCapabilityRegistry.plan(for: .godot, inspection: inspection)
        let coordinator = GameBuildCoordinator(hostPort: nil, ciPort: FakeCIJobsPort(statuses: [], payloads: [:]), records: records)
        do {
            _ = try await coordinator.run(plan: plan, source: context, repository: repository, provided: [])
            XCTFail("expected prerequisite failure")
        } catch GameBuildError.prerequisiteMissing(let ids) {
            XCTAssertEqual(Set(ids), ["godot-editor", "godot-export-templates"])
        }
        let list = try await records.list()
        XCTAssertEqual(list.count, 1)
        let record = try await records.load(buildID: list[0])
        XCTAssertEqual(record?.state, .failed)
        XCTAssertEqual(record?.error?.contains("prerequisiteMissing"), true)
    }

    func testStaleBindingAndStaleResultsAreRejected() async throws {
        let fixture = try GameArchiveFixture()
        defer { fixture.cleanup() }
        let repository = try FileGameProjectRepository(directory: fixture.root.appendingPathComponent("repo"))
        let (context, stored) = try await boundContext(repository: repository, fixture: fixture)
        let records = try GameBuildRecordStore(directory: fixture.root.appendingPathComponent("records"))
        let inspection = GameProjectInspection(rootURL: context.rootURL, context: context,
                                               candidates: [GameEngineCandidate(engine: .phaser, evidence: [])],
                                               inspectedPaths: [])
        let plan = try GameBuildCapabilityRegistry.plan(for: .phaser, inspection: inspection)

        // Stale binding: the saved revision moved on.
        let staleContext = try GameProjectContext(projectID: context.projectID, owner: context.owner,
                                                  rootURL: context.rootURL, savedRevision: "not-the-head")
        let coordinator = GameBuildCoordinator(hostPort: nil, ciPort: FakeCIJobsPort(statuses: [], payloads: [:]), records: records)
        do {
            _ = try await coordinator.run(plan: plan, source: staleContext, repository: repository, provided: ["node-lts"])
            XCTFail("expected stale binding rejection")
        } catch GameBuildError.staleBinding(let expected, let actual) {
            XCTAssertEqual(expected, "not-the-head")
            XCTAssertEqual(actual, stored.revision)
        }

        // Stale result: job echoes a different source digest.
        let digest = GameBuildCoordinator.sourceDigest(of: stored)
        let staleFake = FakeCIJobsPort(
            statuses: [.init(handle: .init(jobID: "job-9"), state: .succeeded, sourceDigest: "deadbeef", revision: stored.revision)],
            payloads: ["phaser-web.zip": try webBundleZIP()], staleDigest: "0".padding(toLength: 64, withPad: "0", startingAt: 0))
        let staleCoordinator = GameBuildCoordinator(hostPort: nil, ciPort: staleFake, records: records)
        do {
            _ = try await staleCoordinator.run(plan: plan, source: context, repository: repository,
                                               provided: ["node-lts"])
            XCTFail("expected stale result rejection")
        } catch GameBuildError.staleResult(let expected, let actual) {
            XCTAssertEqual(expected, digest)
            XCTAssertEqual(actual, "0".padding(toLength: 64, withPad: "0", startingAt: 0))
        }
        let list = try await records.list()
        XCTAssertEqual(list.count, 1)
        let staleRecord = try await records.load(buildID: list[0])
        XCTAssertEqual(staleRecord?.state, .failed)
    }

    func testMissingArtifactFailsVerificationAndCancellationDrains() async throws {
        let fixture = try GameArchiveFixture()
        defer { fixture.cleanup() }
        let repository = try FileGameProjectRepository(directory: fixture.root.appendingPathComponent("repo"))
        let (context, _) = try await boundContext(repository: repository, fixture: fixture)
        let records = try GameBuildRecordStore(directory: fixture.root.appendingPathComponent("records"))
        let inspection = GameProjectInspection(rootURL: context.rootURL, context: context,
                                               candidates: [GameEngineCandidate(engine: .phaser, evidence: [])],
                                               inspectedPaths: [])
        let plan = try GameBuildCapabilityRegistry.plan(for: .phaser, inspection: inspection)
        // Use a real digest echo, then fail the artifact download.
        let stored = try await repository.open(context.projectID, owner: context.owner)
        let digest = GameBuildCoordinator.sourceDigest(of: stored)
        let echoFake = FakeCIJobsPort(
            statuses: [.init(handle: .init(jobID: "job-3"), state: .succeeded, sourceDigest: digest, revision: stored.revision)],
            payloads: [:], failArtifactNames: ["phaser-web.zip"])
        let coordinator2 = GameBuildCoordinator(hostPort: nil, ciPort: echoFake, records: records)
        do {
            _ = try await coordinator2.run(plan: plan, source: context, repository: repository,
                                           provided: ["node-lts"])
            XCTFail("expected missing artifact failure")
        } catch GameBuildError.artifactMissing(let name) {
            XCTAssertEqual(name, "phaser-web.zip")
        }

        // Cancellation drains: statuses stay .running until cancel, then .cancelled.
        let hangingFake = FakeCIJobsPort(statuses: [
            .init(handle: .init(jobID: "job-4"), state: .running),
            .init(handle: .init(jobID: "job-4"), state: .cancelled),
        ], payloads: [:])
        let coordinator3 = GameBuildCoordinator(hostPort: nil, ciPort: hangingFake, records: records)
        let handle = GameCIJobHandle(jobID: "job-4")
        try await coordinator3.cancelAndDrain(buildID: UUID(), handle: handle, pollTimeout: .seconds(5))
        let cancelled = await hangingFake.cancelledJobs
        XCTAssertEqual(cancelled, ["job-4"])
    }
}
