// SPDX-License-Identifier: MPL-2.0
import Foundation
import Testing
import FloeCore
import FloeModels
import FloeProviders
@testable import FloeMacSelfCore

@Suite("Mac question answer delivery")
struct OptionalQuestionDeliveryTests {
    @Test("Optional answers keep their task and respect the terminal fence", arguments: [false, true])
    func optionalAnswerJoinsTheOriginalTask(afterCompletion: Bool) async throws {
        try await withSelfCoreFixture { fixture in
            let (provider, adapter) = fixture.makeProvider(scripts: [
                [.textDelta(.init(text: "First")), .completed(.init(stopReason: .endTurn))],
                [.textDelta(.init(text: "Received")), .completed(.init(stopReason: .endTurn))]
            ], holdFirstEvent: true)
            let handle = try await fixture.runtime.startSession(
                .init(goal: "Choose an output", allowsUserQuestions: true), provider: provider
            )
            let center = try await fixture.runtime.userQuestionCenter()
            let owner = handle.identity
            _ = try await center.coordinator.ask(
                .init(waitPolicy: .optionalContinue, questions: [
                    .init(question: "Which format?", options: [.init(id: "csv", label: "CSV")])
                ]), runID: owner.runID, conversationID: owner.conversationID, toolCallID: "choose-format",
                cancellation: CancellationToken(), temporaryReadOnly: false
            )
            let snapshot = try #require(try await center.pendingSnapshot(runID: owner.runID))
            let question = try #require(snapshot.currentQuestion)
            if afterCompletion {
                await adapter.openGate()
                #expect(await handle.waitForTerminal(timeout: 15)?.confirmed == true)
                _ = try await handle.close()
            }
            let result = try await center.submitHumanAnswer(
                target: snapshot.target(for: question), answer: .init(selectedOptionIDs: ["csv"])
            )
            if afterCompletion {
                #expect(!result.accepted && result.status == .cancelled && result.answer == nil)
                #expect(try await center.pendingDeliveries(conversationID: owner.conversationID).isEmpty)
                return
            }
            #expect(result.accepted)
            try await fixture.runtime.deliverOptionalQuestionAnswers(conversationID: owner.conversationID)
            let store = try await fixture.runtime.runningInputStore()
            let pending = try await store.pending(conversationID: owner.conversationID)
            #expect(pending.count == 1)
            let row = try #require(pending.first)
            #expect(row.workspaceID == owner.workspaceID && row.selectedModelID == provider.model.id)
            #expect(row.targetRunID == owner.runID && row.content.contains("CSV"))
            #expect(row.executionMode == "chat")
            #expect(try await center.pendingDeliveries(conversationID: owner.conversationID).isEmpty)
            await adapter.openGate()
            #expect(await handle.waitForTerminal(timeout: 15)?.confirmed == true)
            _ = try await handle.close()
        }
    }

    @Test("Credential text cannot enter a question draft or answer history")
    func keepsCredentialOutOfHistory() async throws {
        try await withSelfCoreFixture { fixture in
            let (provider, adapter) = fixture.makeProvider(
                scripts: [[.textDelta(.init(text: "OK")), .completed(.init(stopReason: .endTurn))]],
                holdFirstEvent: true
            )
            let handle = try await fixture.runtime.startSession(
                .init(goal: "Check configuration", allowsUserQuestions: true), provider: provider
            )
            let center = try await fixture.runtime.userQuestionCenter()
            let owner = handle.identity
            _ = try await center.coordinator.ask(.init(waitPolicy: .optionalContinue, questions: [
                .init(question: "Credential?", answerSensitivity: .credential, allowsFreeText: true)
            ]), runID: owner.runID, conversationID: owner.conversationID, toolCallID: "settings",
                cancellation: CancellationToken(), temporaryReadOnly: false)
            let snapshot = try #require(try await center.pendingSnapshot(runID: owner.runID))
            let question = try #require(snapshot.currentQuestion)
            let target = snapshot.target(for: question)
            let fixtureValue = UserQuestionAnswer(freeText: "synthetic-credential-fixture")
            await #expect(throws: UserQuestionError.self) {
                _ = try await center.saveDraft(target: target, draft: fixtureValue)
            }
            await #expect(throws: UserQuestionError.self) {
                _ = try await center.submitHumanAnswer(target: target, answer: fixtureValue)
            }
            let stored = try #require(try await center.store.snapshot(requestID: snapshot.requestID))
            #expect(stored.currentQuestion?.draftAnswer == nil && stored.currentQuestion?.answer == nil)
            try await center.cancelRequest(requestID: snapshot.requestID)
            await adapter.openGate()
            #expect(await handle.waitForTerminal(timeout: 15)?.confirmed == true)
            _ = try await handle.close()
        }
    }

}
