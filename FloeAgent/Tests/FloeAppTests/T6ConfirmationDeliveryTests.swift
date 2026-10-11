// FloeAppTests — T6 trusted confirmation delivery to the original task.
//
// The exact defect this locks down: the "authorize assistant" button minted a
// grant and stored only transient @Published state — the originating task
// never received the confirmation, so the assistant could never learn it was
// allowed to adopt. The trusted UI now mints the SAME single-use confirmation
// the `design.adopt` tool consumes AND delivers a structured event to the
// frozen originating task through the existing ConversationCenter durable
// ingress:
//   * idempotent transcript upsert under a stable event id;
//   * a steer only while the originating task is actually RUNNING;
//   * a finished task retains the transcript continuation and is never
//     auto-restarted by the notice;
//   * the transient "authorized" state is set only AFTER the durable write;
//   * a consumed/expired grant is never reused (fresh confirmation required).
//
// These execute in the FloeApp unit-test bundle (full App target, T7).

#if canImport(SwiftUI) && canImport(UIKit)
import Foundation
import Testing
import FloeCore
import FloePersistence
import FloeTools
@testable import FloeApp

@Suite("T6 assistant confirmation delivery")
@MainActor
struct T6ConfirmationDeliveryTests {

    private func makeEnvironment() async throws -> AppEnvironment {
        let environment = AppEnvironment.preview()
        try await environment.database.migrate()
        return environment
    }

    @discardableResult
    private func makeTask(_ environment: AppEnvironment, title: String) async throws -> UUID {
        let conversationID = UUID()
        try await environment.conversationStore.saveConversation(ConversationRecord(
            id: conversationID, title: title, createdAt: Date(), updatedAt: Date()))
        return conversationID
    }

    @discardableResult
    private func saveAsset(
        _ environment: AppEnvironment, bytes: Data, name: String
    ) async throws -> (id: UUID, url: URL) {
        let assetID = UUID()
        let relative = "Materials/t6-confirm-\(name)-\(assetID.uuidString).png"
        let url = try FloeArtifactStore.root().appendingPathComponent(relative)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try bytes.write(to: url, options: [.atomic])
        try await environment.creativeAssetStore.save(CreativeAssetRecord(
            id: assetID, contentHash: FloeDigest.sha256Hex(bytes), kind: .image,
            displayName: "\(name).png", mimeType: "image/png",
            localRelativePath: relative, byteCount: Int64(bytes.count),
            tags: ["test"], referenceCount: 0))
        return (assetID, url)
    }

    private struct Prepared {
        let environment: AppEnvironment
        let target: DesignTarget
        let task: UUID?
        let candidateID: String
        let assetURL: URL
    }

    /// A creative request with one pending candidate and a real first result.
    private func prepare(
        environment: AppEnvironment,
        origin: UUID?,
        name: String
    ) async throws -> Prepared {
        let workflow = environment.designOwnerWorkflow
        let target = DesignTarget(
            kind: .creativeDocument,
            ownerID: "creative-library",
            documentID: "",
            sourceID: UUID().uuidString,
            originConversationID: origin?.uuidString,
            requestedOutputKind: .image)
        let begun = try await workflow.beginCreativeRequest(
            target: target, operationID: "t6-confirm-begin-\(name)",
            expectedOwnerRevision: 0,
            brief: DesignBrief(goal: "Confirmation \(name)"), runID: nil)
        let (assetID, assetURL) = try await saveAsset(
            environment, bytes: Data("first result \(name)".utf8), name: name)
        let bound = try await workflow.bindFirstResult(
            target: target, operationID: "t6-confirm-bind-\(name)",
            expectedOwnerRevision: begun.envelope.revision,
            bytes: Data("first result \(name)".utf8),
            format: "png", displayName: "\(name).png",
            boundResultID: assetID.uuidString, runID: nil)
        let artifact = try #require(bound.envelope.project.artifacts.first)
        let baseRevisionID = try #require(artifact.currentRevisionID)
        let proposal = try await workflow.propose(
            target: target, operationID: "t6-confirm-propose-\(name)",
            expectedOwnerRevision: bound.envelope.revision,
            artifactID: artifact.id,
            baseRevisionID: baseRevisionID,
            bytes: Data("candidate \(name)".utf8),
            format: "png",
            summary: "Candidate \(name)",
            runID: nil)
        return Prepared(
            environment: environment, target: target, task: origin,
            candidateID: proposal.candidate.id, assetURL: assetURL)
    }

    private func removeState(_ prepared: Prepared) {
        if let root = try? FloeArtifactStore.root() {
            let directory = root
                .appendingPathComponent("DesignRevisions", isDirectory: true)
                .appendingPathComponent("owners", isDirectory: true)
                .appendingPathComponent(prepared.target.stableKey, isDirectory: true)
            try? FileManager.default.removeItem(at: directory)
        }
        try? FileManager.default.removeItem(at: prepared.assetURL)
    }

    private func confirmationMessages(
        _ environment: AppEnvironment, task: UUID
    ) async throws -> [PersistedMessage] {
        let messages = try await environment.conversationStore.messages(conversationID: task)
        return messages.filter {
            $0.role == "system"
                && $0.content.contains("[Design assistant confirmation")
        }
    }

    // MARK: - Durable delivery + dedupe

    @Test("A trusted confirmation is durably delivered to the original task exactly once")
    func confirmationIsDurableAndIdempotent() async throws {
        let environment = try await makeEnvironment()
        let task = try await makeTask(environment, title: "Confirmation origin")
        let prepared = try await prepare(environment: environment, origin: task, name: "durable")
        defer { removeState(prepared) }

        let model = DesignOwnerWorkflowModel(
            target: prepared.target, environment: environment)
        await model.reload()
        #expect(model.canAuthorizeAssistant)

        await model.authorizeAssistantAdoption(
            prepared.candidateID, mode: .updateOriginal)
        #expect(model.errorMessage == nil)
        let authorization = try #require(model.authorizedAssistantAdoption)
        #expect(authorization.candidateID == prepared.candidateID)
        #expect(!authorization.grantID.isEmpty)

        let messages = try await confirmationMessages(environment, task: task)
        #expect(messages.count == 1)
        let content = try #require(messages.first?.content)
        #expect(content.contains(authorization.grantID))
        #expect(content.contains(prepared.target.stableKey))
        #expect(content.contains(prepared.candidateID))

        // The event is a retained continuation, NOT a queued user message:
        // a finished task is never auto-restarted by the notice.
        let pending = try await environment.runningInputStore.pending(
            conversationID: task)
        #expect(pending.isEmpty)

        // A repeated click for the SAME live confirmation reuses the grant and
        // upserts the SAME event instead of duplicating it.
        await model.authorizeAssistantAdoption(
            prepared.candidateID, mode: .updateOriginal)
        #expect(model.authorizedAssistantAdoption?.grantID == authorization.grantID)
        let afterRepeat = try await confirmationMessages(environment, task: task)
        #expect(afterRepeat.count == 1)
    }

    @Test("A consumed grant is not reused: a fresh confirmation is minted and delivered")
    func consumedGrantRequiresFreshConfirmation() async throws {
        let environment = try await makeEnvironment()
        let task = try await makeTask(environment, title: "Consumed grant origin")
        let prepared = try await prepare(environment: environment, origin: task, name: "consumed")
        defer { removeState(prepared) }

        let model = DesignOwnerWorkflowModel(
            target: prepared.target, environment: environment)
        await model.reload()
        await model.authorizeAssistantAdoption(
            prepared.candidateID, mode: .updateOriginal)
        let first = try #require(model.authorizedAssistantAdoption)

        // The tool path atomically claims (burns) the exact single-use grant.
        let candidate = try #require(model.project?.candidate(prepared.candidateID))
        let claimed = await environment.designOwnerAdoptionGrants.claimOwnerAdoption(
            grantID: first.grantID,
            targetStableKey: prepared.target.stableKey,
            candidateID: prepared.candidateID,
            baselineRevisionID: candidate.baseRevisionID,
            proposedRevisionID: candidate.proposedRevisionID,
            mode: .updateOriginal,
            scope: .aiTool)
        #expect(claimed)

        // Re-click: the burned grant cannot be reused, so a NEW confirmation
        // is minted and delivered.
        await model.authorizeAssistantAdoption(
            prepared.candidateID, mode: .updateOriginal)
        let second = try #require(model.authorizedAssistantAdoption)
        #expect(second.grantID != first.grantID)
        let messages = try await confirmationMessages(environment, task: task)
        #expect(messages.count == 2)
        #expect(messages.last?.content.contains(second.grantID) == true)
    }

    @Test("A target without an origin offers no notify button and never claims delivery")
    func noOriginTargetNeverPretendsToNotify() async throws {
        let environment = try await makeEnvironment()
        let prepared = try await prepare(environment: environment, origin: nil, name: "noorigin")
        defer { removeState(prepared) }

        let model = DesignOwnerWorkflowModel(
            target: prepared.target, environment: environment)
        await model.reload()
        #expect(model.canAuthorizeAssistant == false)
        #expect(model.confirmationOriginConversationID == nil)

        await model.authorizeAssistantAdoption(
            prepared.candidateID, mode: .updateOriginal)
        // No grant is armed and no event is fabricated.
        #expect(model.authorizedAssistantAdoption == nil)
        #expect(model.errorMessage != nil)
    }

    @Test("The center ingress writes one idempotent event per grant")
    func centerIngressIsIdempotentPerGrant() async throws {
        let environment = try await makeEnvironment()
        let task = try await makeTask(environment, title: "Center ingress")
        let center = environment.conversationCenter
        let grantA = UUID()
        let grantB = UUID()
        let candidateA = UUID()
        let expiresAt = Date().addingTimeInterval(300)

        try await center.recordDesignAssistantConfirmation(
            conversationID: task, targetStableKey: String(repeating: "a", count: 64),
            candidateID: candidateA, baselineRevisionID: "base-1",
            proposedRevisionID: "proposed-1", mode: .updateOriginal,
            grantID: grantA, grantExpiresAt: expiresAt)
        // Replaying the SAME grant upserts, never duplicates.
        try await center.recordDesignAssistantConfirmation(
            conversationID: task, targetStableKey: String(repeating: "a", count: 64),
            candidateID: candidateA, baselineRevisionID: "base-1",
            proposedRevisionID: "proposed-1", mode: .updateOriginal,
            grantID: grantA, grantExpiresAt: expiresAt)
        let first = try await confirmationMessages(environment, task: task)
        #expect(first.count == 1)

        // A different grant is a different event.
        try await center.recordDesignAssistantConfirmation(
            conversationID: task, targetStableKey: String(repeating: "b", count: 64),
            candidateID: UUID(), baselineRevisionID: "base-2",
            proposedRevisionID: "proposed-2", mode: .variant,
            grantID: grantB, grantExpiresAt: expiresAt)
        let second = try await confirmationMessages(environment, task: task)
        #expect(second.count == 2)
        // No queued input was left behind for a task with no live run.
        let pending = try await environment.runningInputStore.pending(
            conversationID: task)
        #expect(pending.isEmpty)
    }

    // MARK: - Shared proposal-decision ingress (T7R)

    private func decisionMessages(
        _ environment: AppEnvironment, task: UUID
    ) async throws -> [PersistedMessage] {
        let messages = try await environment.conversationStore.messages(conversationID: task)
        return messages.filter {
            $0.role == "system"
                && $0.content.hasPrefix("[Drawing Assistant user decision")
        }
    }

    @Test("A structured decision is retained for a stopped task without a queued row and replays idempotently")
    func proposalDecisionIsDurableWithoutQueueRow() async throws {
        let environment = try await makeEnvironment()
        let task = try await makeTask(environment, title: "Decision origin")
        let center = environment.conversationCenter
        let proposalA = UUID()
        let proposalB = UUID()
        let sha = String(repeating: "ab", count: 32)

        try await center.recordProposalDecision(
            conversationID: task, proposalID: proposalA,
            decision: "design-candidate-adopted", revision: 3, sha256: sha)
        try await center.recordProposalDecision(
            conversationID: task, proposalID: proposalB,
            decision: "rejected", revision: nil, sha256: nil)

        let decisions = try await decisionMessages(environment, task: task)
        #expect(decisions.count == 2)
        // The ids are the deterministic server-owned derivations, not random
        // row ids, so the projection can prove identity without trusting text.
        #expect(decisions.allSatisfy {
            ProposalDecisionNoticeProjection.trustedEvent(in: $0) != nil
        })

        // The stopped task keeps ONLY the transcript continuation: a queued
        // row here is exactly what the launcher could claim as a new run goal.
        #expect(try await environment.runningInputStore.pending(conversationID: task).isEmpty)

        // A replay upserts the same event and still leaves no queue row.
        try await center.recordProposalDecision(
            conversationID: task, proposalID: proposalA,
            decision: "design-candidate-adopted", revision: 3, sha256: sha)
        let afterReplay = try await decisionMessages(environment, task: task)
        #expect(afterReplay.count == 2)
        #expect(afterReplay.filter { $0.content.contains(proposalA.uuidString) }.count == 1)
        #expect(try await environment.runningInputStore.pending(conversationID: task).isEmpty)
    }
}
#endif
