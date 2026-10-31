// SPDX-License-Identifier: MPL-2.0
//
// G07.3B launch-path tests against the REAL FacadeRunDomain pipeline.
//
// The scheduled launch is the ordinary create-intent run transaction with
// deterministic occurrence identities, a frozen project workspace and a
// project-environment ownership proof. These tests use the reviewed
// `RunDomainFixture` (REAL stores/runtime, scripted model stream) and assert
// durable rows, ownership and refusal behavior. They are authored for Main's
// combined freeze; this lane does not execute them.
import XCTest
import Foundation
import GRDB
import FloeCore
import FloeModels
import FloePersistence
import FloeEnvironments
@testable import FloeAndroidCore

final class G073TaskScheduleLaunchTests: XCTestCase {

    private func request(
        occurrenceID: UUID = UUID(),
        workspaceID: UUID?,
        environmentID: String? = nil,
        environmentMetadata: G073EnvironmentMetadata? = nil,
        fixture: RunDomainFixture,
        prompt: String = "Check the weekly project status and summarize it."
    ) -> G073ScheduledLaunchRequest {
        G073ScheduledLaunchRequest(
            occurrenceID: occurrenceID,
            conversationID: G073ScheduleIdentity.conversationID(occurrenceID: occurrenceID),
            runID: G073ScheduleIdentity.runID(occurrenceID: occurrenceID),
            workspaceID: workspaceID,
            title: "Weekly project status",
            prompt: prompt,
            providerID: fixture.providerID,
            modelID: fixture.modelID,
            environmentID: environmentID,
            environmentMetadata: environmentMetadata,
            policy: DraftTaskPolicy(approvalMode: .automatic))
    }

    func testScheduledLaunchCommitsDeterministicIndependentTask() async throws {
        let fixture = try await RunDomainFixture.make()
        addTeardownBlock { await fixture.tearDown() }
        let domain = fixture.makeDomain()
        let occurrenceID = UUID()
        let scheduled = request(occurrenceID: occurrenceID, workspaceID: nil,
                                fixture: fixture)

        let reply = await domain.startScheduled(scheduled)
        guard case .mutationAccepted(let detail) = reply.outcome else {
            return XCTFail("scheduled launch refused: \(reply.outcome)")
        }
        XCTAssertEqual(detail["runID"], scheduled.runID.uuidString)

        let run = try await fixture.runStore.run(id: scheduled.runID)
        let persistedRun = try XCTUnwrap(run)
        XCTAssertEqual(persistedRun.conversationID, scheduled.conversationID)
        XCTAssertEqual(persistedRun.modelID, fixture.modelID)
        XCTAssertEqual(persistedRun.providerID, fixture.providerID)
        XCTAssertEqual(persistedRun.conversationMode, "chat")

        let conversation = try await fixture.conversationStore.conversation(
            id: scheduled.conversationID)
        XCTAssertNotNil(conversation)
        XCTAssertEqual(conversation?.purpose, .ordinary)

        let owningWorkspace = try await fixture.workspaceStore.workspaceID(
            conversationID: scheduled.conversationID)
        let workspaceID = try XCTUnwrap(owningWorkspace)
        let workspace = try await fixture.workspaceStore.workspace(id: workspaceID)
        let persistedWorkspace = try XCTUnwrap(workspace)
        // The launch transaction minted a NEW independent private task
        // workspace per occurrence (never a reused old task workspace).
        XCTAssertEqual(persistedWorkspace.kind, .privateTask)
        XCTAssertEqual(persistedWorkspace.name, "Weekly project status")

        let messages = try await fixture.conversationStore.messages(
            conversationID: scheduled.conversationID)
        XCTAssertTrue(messages.contains { $0.runID == scheduled.runID })
    }

    func testScheduledLaunchRefusesNonDeterministicIdentities() async throws {
        let fixture = try await RunDomainFixture.make()
        addTeardownBlock { await fixture.tearDown() }
        let domain = fixture.makeDomain()
        var scheduled = request(workspaceID: nil, fixture: fixture)
        scheduled.runID = UUID() // caller-chosen arbitrary id

        let reply = await domain.startScheduled(scheduled)
        if case .rejected(let error) = reply.outcome {
            XCTAssertEqual(error.code, .invalidState)
            XCTAssertEqual(error.reason, .payloadInvalid)
        } else {
            XCTFail("a non-occurrence run identity must be refused")
        }
        let run = try await fixture.runStore.run(id: scheduled.runID)
        XCTAssertNil(run)
    }

    func testScheduledLaunchUsesFrozenProjectWorkspaceAndEnvironment() async throws {
        let fixture = try await RunDomainFixture.make()
        addTeardownBlock { await fixture.tearDown() }
        let workspaceID = UUID()
        let project = WorkspaceRecord(
            id: workspaceID,
            name: "Project workspace",
            rootBookmark: Data(),
            kind: .project,
            internalRelativePath: "Projects/g073")
        try await fixture.workspaceStore.saveWorkspace(project)

        let ownership = G073ScheduleEnvironmentOwnership { _ in workspaceID }
        let metadata = G073EnvironmentMetadata(
            id: "g073-launch-env",
            kind: .project,
            ownerID: workspaceID.uuidString,
            name: "Project environment",
            state: "active",
            requiresRebuild: false,
            executionBackend: G073EnvironmentMetadata.requiredExecutionBackend)
        ownership.registerHostMetadata([metadata], at: Date())
        let domain = fixture.makeCustomDomain(
            fixture.components(environmentProof: ownership))

        let scheduled = request(
            workspaceID: workspaceID,
            environmentID: metadata.id,
            environmentMetadata: metadata,
            fixture: fixture)
        let reply = await domain.startScheduled(scheduled)
        guard case .mutationAccepted = reply.outcome else {
            return XCTFail("environment-bound scheduled launch refused: \(reply.outcome)")
        }
        let owningWorkspace = try await fixture.workspaceStore.workspaceID(
            conversationID: scheduled.conversationID)
        XCTAssertEqual(owningWorkspace, workspaceID)
        let conversation = try await fixture.conversationStore.conversation(
            id: scheduled.conversationID)
        XCTAssertEqual(conversation?.purpose, .ordinary)
    }

    func testSessionEnvironmentCannotBeBorrowedByANewScheduledTask() async throws {
        let fixture = try await RunDomainFixture.make()
        addTeardownBlock { await fixture.tearDown() }
        let workspaceID = UUID()
        try await fixture.workspaceStore.saveWorkspace(WorkspaceRecord(
            id: workspaceID,
            name: "Project workspace",
            rootBookmark: Data(),
            kind: .project,
            internalRelativePath: "Projects/g073-session"))
        let oldConversation = UUID()
        let session = G073EnvironmentMetadata(
            id: "g073-old-session",
            kind: .session,
            ownerID: oldConversation.uuidString,
            state: "active",
            requiresRebuild: false,
            executionBackend: G073EnvironmentMetadata.requiredExecutionBackend,
            parentID: "g073-parent")
        let ownership = G073ScheduleEnvironmentOwnership { _ in workspaceID }
        ownership.registerHostMetadata([session], at: Date())
        let domain = fixture.makeCustomDomain(
            fixture.components(environmentProof: ownership))

        let scheduled = request(
            workspaceID: workspaceID,
            environmentID: session.id,
            environmentMetadata: session,
            fixture: fixture)
        let reply = await domain.startScheduled(scheduled)
        if case .rejected(let error) = reply.outcome {
            XCTAssertEqual(error.code, .unsupportedRole)
            XCTAssertEqual(error.reason, .environmentRoleUnresolvable)
        } else {
            XCTFail("a session environment owned by an old conversation must refuse")
        }
        let run = try await fixture.runStore.run(id: scheduled.runID)
        XCTAssertNil(run)
    }

    func testSameOccurrenceCannotLaunchASecondIndependentTask() async throws {
        let fixture = try await RunDomainFixture.make()
        addTeardownBlock { await fixture.tearDown() }
        let domain = fixture.makeDomain()
        let occurrenceID = UUID()
        let first = request(occurrenceID: occurrenceID, workspaceID: nil,
                            fixture: fixture)
        let firstReply = await domain.startScheduled(first)
        guard case .mutationAccepted = firstReply.outcome else {
            return XCTFail("first launch refused: \(firstReply.outcome)")
        }
        // Let the first real run settle so its ownership entry is retired;
        // the duplicate identity test is about the durable transaction, not
        // about racing a live owned producer.
        for _ in 0..<500 {
            let terminalRun = (try? await fixture.runStore.run(id: first.runID)).map {
                !["preparing", "streamingModel", "executingTool", "compacting",
                  "waitingApproval", "paused"].contains($0.state)
            } ?? false
            if terminalRun,
               RuntimeOwnedWorkRegistry.shared.count(for: fixture.epoch) == 0 {
                break
            }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        // The SAME occurrence identity cannot mint a second conversation/run
        // pair: the transaction's primary/unique constraints refuse it.
        let secondReply = await domain.startScheduled(first)
        if case .mutationAccepted = secondReply.outcome {
            XCTFail("the same occurrence must not launch twice")
        }
        let runs = try await fixture.runStore.runs(
            conversationID: first.conversationID)
        XCTAssertEqual(runs.count, 1)
    }
}
