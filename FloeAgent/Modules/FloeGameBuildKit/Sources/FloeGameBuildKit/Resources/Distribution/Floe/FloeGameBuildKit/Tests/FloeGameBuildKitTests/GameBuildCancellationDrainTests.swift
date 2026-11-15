// SPDX-License-Identifier: MPL-2.0
import Foundation
import XCTest
import FloeGameCore
@testable import FloeGameBuildKit

/// A controlled CI port whose running status carries a non-nil source digest.
/// This is the exact shape that the old `if status.sourceDigest != nil { break }`
/// incorrectly treated as terminal.
private actor DigestRunningCI: GameBuildCIJobsPort {
    private(set) var dispatches = 0
    private(set) var cancelCalls = 0
    private var rejectCancel: Bool
    private var released = false
    private var digest = ""
    private var revision = ""

    init(rejectCancel: Bool) {
        self.rejectCancel = rejectCancel
    }

    func dispatch(template: GameCIWorkflowTemplate, sourceDigest: String,
                  revision: String, engineVersion: String?) async throws -> GameCIJobHandle {
        dispatches += 1
        digest = sourceDigest
        self.revision = revision
        return .init(jobID: "job-cancel")
    }

    func status(_ handle: GameCIJobHandle) async throws -> GameCIJobStatus {
        if released {
            return .init(handle: handle, state: .cancelled)
        }
        return .init(handle: handle, state: .running,
                     sourceDigest: digest, revision: revision)
    }

    func artifact(_ handle: GameCIJobHandle, named: String) async throws -> Data {
        throw GameBuildError.artifactMissing(named)
    }

    func cancel(_ handle: GameCIJobHandle) async throws {
        cancelCalls += 1
        if rejectCancel, !released {
            throw GameBuildError.dispatchFailed("cancel transport unavailable")
        }
        released = true
    }

    func release() {
        released = true
        rejectCancel = false
    }

    func dispatchCount() -> Int { dispatches }
}

final class GameBuildCancellationDrainTests: XCTestCase {
    private func makeBuild() async throws -> (fixture: GameArchiveFixture,
                                              context: GameProjectContext,
                                              plan: GameBuildCapabilityPlan) {
        let fixture = try GameArchiveFixture()
        let repository = try FileGameProjectRepository(
            directory: fixture.root.appendingPathComponent("repo"))
        let id = UUID(), owner = GameProjectOwner.space(recordID: id)
        let created = try await repository.createProject(
            projectID: id, owner: owner, title: "Cancel", engine: .phaser)
        let stored = try await repository.importContents(
            from: fixture.project(), into: id, owner: owner,
            expectedRevision: created.revision)
        let context = try GameProjectContext(
            projectID: id, owner: owner,
            rootURL: fixture.root.appendingPathComponent("project-root"),
            savedRevision: stored.revision)
        let inspection = GameProjectInspection(
            rootURL: context.rootURL, context: context,
            candidates: [GameEngineCandidate(engine: .phaser, evidence: [])],
            inspectedPaths: [])
        let plan = try GameBuildCapabilityRegistry.plan(for: .phaser, inspection: inspection)
        return (fixture, context, plan)
    }

    private func waitForDispatch(_ ci: DigestRunningCI) async throws {
        for _ in 0..<100 {
            if await ci.dispatchCount() > 0 { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTFail("the CI job was not dispatched")
    }

    func testNonNilDigestWithRunningStatusIsNotTerminal() async throws {
        let (fixture, context, plan) = try await makeBuild()
        defer { fixture.cleanup() }
        let ci = DigestRunningCI(rejectCancel: false)
        let records = try GameBuildRecordStore(
            directory: fixture.root.appendingPathComponent("records-cancel"))
        let repository = try FileGameProjectRepository(
            directory: fixture.root.appendingPathComponent("repo"))
        let coordinator = GameBuildCoordinator(hostPort: nil, ciPort: ci, records: records)
        let buildID = UUID()
        let task = Task {
            try await coordinator.run(
                plan: plan, source: context, repository: repository,
                provided: ["node-lts"], buildID: buildID)
        }
        try await waitForDispatch(ci)
        try await Task.sleep(for: .milliseconds(50))
        let receipt = await coordinator.cancelAndDrain(
            buildID: buildID, pollInterval: .milliseconds(10),
            drainTimeout: .seconds(2))
        XCTAssertTrue(receipt.isConfirmed)
        XCTAssertEqual(receipt.terminalState, .cancelled)
        _ = await task.result
        let record = try await records.load(buildID: buildID.uuidString.lowercased())
        XCTAssertEqual(record?.state, .cancelled)
        let cancels = await ci.cancelCalls
        XCTAssertGreaterThan(cancels, 0)
    }

    func testCancelTransportFailureRetainsExactHandleAndIsRetriable() async throws {
        let (fixture, context, plan) = try await makeBuild()
        defer { fixture.cleanup() }
        let ci = DigestRunningCI(rejectCancel: true)
        let records = try GameBuildRecordStore(
            directory: fixture.root.appendingPathComponent("records-retained"))
        let repository = try FileGameProjectRepository(
            directory: fixture.root.appendingPathComponent("repo"))
        let coordinator = GameBuildCoordinator(
            hostPort: nil, ciPort: ci, records: records,
            cancelDrainTimeout: .milliseconds(100))
        let buildID = UUID()
        let task = Task {
            try await coordinator.run(
                plan: plan, source: context, repository: repository,
                provided: ["node-lts"], buildID: buildID)
        }
        try await waitForDispatch(ci)
        try await Task.sleep(for: .milliseconds(50))
        let first = await coordinator.cancelAndDrain(
            buildID: buildID, pollInterval: .milliseconds(10),
            drainTimeout: .milliseconds(150))
        XCTAssertFalse(first.isConfirmed)
        XCTAssertEqual(first.jobID, "job-cancel")
        var retained = await coordinator.retainedBuilds(
            projectID: context.projectID)
        for _ in 0..<50 where retained.isEmpty {
            try await Task.sleep(for: .milliseconds(20))
            retained = await coordinator.retainedBuilds(
                projectID: context.projectID)
        }
        XCTAssertEqual(retained.count, 1)
        XCTAssertTrue(retained.contains(buildID))
        let record = try await records.load(buildID: buildID.uuidString.lowercased())
        XCTAssertEqual(record?.state, .dispatched)
        XCTAssertNotEqual(record?.state, .cancelled)
        do {
            try await coordinator.delete(buildID: buildID)
            XCTFail("a retained handle must not be deletable")
        } catch GameBuildError.buildActive {
            // expected
        }

        await ci.release()
        let second = await coordinator.cancelAndDrain(
            buildID: buildID, pollInterval: .milliseconds(10),
            drainTimeout: .seconds(2))
        XCTAssertTrue(second.isConfirmed)
        XCTAssertEqual(second.terminalState, .cancelled)
        _ = await task.result
        let final = try await records.load(buildID: buildID.uuidString.lowercased())
        XCTAssertEqual(final?.state, .cancelled)
        do { try await coordinator.delete(buildID: buildID) }
        catch { XCTFail("terminal retained build should be deletable: \(error)") }
    }

    func testDeleteRefusesAnActiveBuild() async throws {
        let (fixture, context, plan) = try await makeBuild()
        defer { fixture.cleanup() }
        let ci = DigestRunningCI(rejectCancel: true)
        let records = try GameBuildRecordStore(
            directory: fixture.root.appendingPathComponent("records-active"))
        let repository = try FileGameProjectRepository(
            directory: fixture.root.appendingPathComponent("repo"))
        let coordinator = GameBuildCoordinator(
            hostPort: nil, ciPort: ci, records: records,
            cancelDrainTimeout: .milliseconds(100))
        let buildID = UUID()
        let task = Task {
            try await coordinator.run(
                plan: plan, source: context, repository: repository,
                provided: ["node-lts"], buildID: buildID)
        }
        try await waitForDispatch(ci)
        try await Task.sleep(for: .milliseconds(50))
        do {
            try await coordinator.delete(buildID: buildID)
            XCTFail("an active build must not be deletable")
        } catch GameBuildError.buildActive {
            // expected
        }
        _ = await coordinator.cancelAndDrain(buildID: buildID,
                                             drainTimeout: .milliseconds(100))
        await ci.release()
        _ = await task.result
    }
}
